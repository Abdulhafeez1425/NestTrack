-- NestTrack end-to-end messaging hardening.
-- Run after all existing migrations, including:
--   20261006_messaging_independent_accounts.sql
-- This migration is intentionally idempotent.

-- Direct conversations are participant based and may exist before either user
-- belongs to an organization.
alter table public.conversations
  alter column organization_id drop not null;

create index if not exists conversations_org_idx
  on public.conversations(organization_id);
create index if not exists conversation_members_pair_idx
  on public.conversation_members(conversation_id, user_id);

-- Keep a direct conversation created before assignment when the tenant later
-- joins an organization. Channel conversations are excluded because a channel
-- is not a direct conversation.
create or replace function public.associate_direct_conversations_after_membership()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'active' then
    update public.conversations c
       set organization_id = new.organization_id
     where c.organization_id is null
       and not exists (
         select 1 from public.channels ch
         where ch.conversation_id = c.id
       )
       and exists (
         select 1 from public.conversation_members cm
         where cm.conversation_id = c.id and cm.user_id = new.user_id
       )
       and exists (
         select 1
         from public.conversation_members cm
         join public.organization_members om on om.user_id = cm.user_id
         where cm.conversation_id = c.id
           and cm.user_id <> new.user_id
           and om.organization_id = new.organization_id
           and om.status = 'active'
       );
  end if;
  return new;
end;
$$;

drop trigger if exists associate_direct_conversations_on_membership
  on public.organization_members;
create trigger associate_direct_conversations_on_membership
after insert or update of organization_id, status on public.organization_members
for each row execute function public.associate_direct_conversations_after_membership();

-- A single direct thread is reused for a participant pair even when the pair
-- started outside an organization. The advisory lock prevents duplicate
-- threads during concurrent first messages.
create or replace function public.get_or_create_direct_conversation(
  p_other uuid,
  p_organization_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  cid uuid;
  common_org uuid;
  pair_key text;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_other is null or p_other = uid then raise exception 'Invalid message recipient'; end if;
  if not exists (select 1 from auth.users where id = p_other) then
    raise exception 'Recipient account does not exist';
  end if;
  if not exists (select 1 from public.profiles where id = p_other) then
    raise exception 'Recipient is not a NestTrack user';
  end if;

  pair_key := least(uid::text, p_other::text) || ':' || greatest(uid::text, p_other::text);
  perform pg_advisory_xact_lock(hashtextextended(pair_key, 0));

  if p_organization_id is not null
     and exists (select 1 from public.organization_members
                 where organization_id = p_organization_id and user_id = uid and status = 'active')
     and exists (select 1 from public.organization_members
                 where organization_id = p_organization_id and user_id = p_other and status = 'active') then
    common_org := p_organization_id;
  else
    select om1.organization_id into common_org
      from public.organization_members om1
      join public.organization_members om2
        on om2.organization_id = om1.organization_id
       and om2.user_id = p_other
       and om2.status = 'active'
     where om1.user_id = uid
       and om1.status = 'active'
     order by om1.organization_id
     limit 1;
  end if;

  -- Do not accidentally reuse a two-person channel as a direct thread.
  select c.id into cid
    from public.conversations c
   where not exists (select 1 from public.channels ch where ch.conversation_id = c.id)
     and exists (select 1 from public.conversation_members cm
                 where cm.conversation_id = c.id and cm.user_id = uid)
     and exists (select 1 from public.conversation_members cm
                 where cm.conversation_id = c.id and cm.user_id = p_other)
   order by c.created_at
   limit 1
   for update;

  if cid is null then
    insert into public.conversations(organization_id)
    values (common_org)
    returning id into cid;
    insert into public.conversation_members(conversation_id, user_id)
    values (cid, uid), (cid, p_other)
    on conflict do nothing;
  elsif common_org is not null then
    update public.conversations
       set organization_id = coalesce(organization_id, common_org)
     where id = cid;
  end if;

  return cid;
end;
$$;
revoke all on function public.get_or_create_direct_conversation(uuid, uuid) from public, anon;
grant execute on function public.get_or_create_direct_conversation(uuid, uuid) to authenticated;

-- Server-side notification creation. Browser clients never choose recipients.
create or replace function public.notify_message_recipients()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  conversation_org uuid;
  channel_message boolean;
  sender_name text;
  notification_title text;
begin
  select c.organization_id into conversation_org
    from public.conversations c where c.id = new.conversation_id;
  select exists (select 1 from public.channels ch where ch.conversation_id = new.conversation_id)
    into channel_message;
  select coalesce(p.full_name, 'A NestTrack user') into sender_name
    from public.profiles p where p.id = new.sender_id;

  notification_title := case when channel_message then 'New channel message' else 'New direct message' end;
  insert into public.notifications(
    recipient_user_id, organization_id, event_type, title, body,
    related_entity_type, related_entity_id
  )
  select cm.user_id,
         conversation_org,
         case when channel_message then 'channel_message' else 'direct_message' end,
         notification_title,
         sender_name || ': ' || left(new.body, 240),
         'message',
         new.id
    from public.conversation_members cm
   where cm.conversation_id = new.conversation_id
     and cm.user_id is distinct from new.sender_id;
  return new;
end;
$$;

drop trigger if exists message_notification_trigger on public.messages;
create trigger message_notification_trigger
after insert on public.messages
for each row execute function public.notify_message_recipients();

-- Read state is changed only through scoped RPCs.
create or replace function public.mark_conversation_read(p_conversation_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_conversation_member(p_conversation_id, auth.uid()) then
    raise exception 'Not authorized';
  end if;
  update public.messages
     set read_at = now()
   where conversation_id = p_conversation_id
     and sender_id is distinct from auth.uid()
     and read_at is null;
end;
$$;
revoke all on function public.mark_conversation_read(uuid) from public, anon;
grant execute on function public.mark_conversation_read(uuid) to authenticated;

create or replace function public.mark_notification_read(p_notification_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.notifications
     set read_at = coalesce(read_at, now())
   where id = p_notification_id
     and recipient_user_id = auth.uid();
end;
$$;
revoke all on function public.mark_notification_read(uuid) from public, anon;
grant execute on function public.mark_notification_read(uuid) to authenticated;

create or replace function public.mark_all_notifications_read()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.notifications
     set read_at = now()
   where recipient_user_id = auth.uid()
     and read_at is null;
end;
$$;
revoke all on function public.mark_all_notifications_read() from public, anon;
grant execute on function public.mark_all_notifications_read() to authenticated;

-- Notification access is recipient-scoped; inserts are trigger/RPC-owned.
alter table public.notifications enable row level security;
drop policy if exists "notifications own read" on public.notifications;
create policy "notifications own read"
on public.notifications for select
using (recipient_user_id = auth.uid());
drop policy if exists "notifications own update" on public.notifications;
create policy "notifications own update"
on public.notifications for update
using (recipient_user_id = auth.uid())
with check (recipient_user_id = auth.uid());
drop policy if exists "notifications browser insert" on public.notifications;

-- Realtime is required for live messages, membership/channel changes, and
-- notification badges. Duplicate publication entries are harmlessly ignored.
do $$
begin
  begin alter publication supabase_realtime add table public.messages;
  exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.conversation_members;
  exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.channel_members;
  exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.channels;
  exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.notifications;
  exception when duplicate_object then null; end;
end $$;
