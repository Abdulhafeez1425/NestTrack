-- NestTrack
-- 20261006_messaging_end_to_end.sql
-- End-to-end direct messaging, notifications, RLS and Realtime hardening.
--
-- RUN AFTER:
--   20261006_messaging_independent_accounts.sql
--
-- IMPORTANT:
-- The frontend should call send_direct_message() for direct messages.
-- The RPC performs recipient validation, conversation creation/reuse and
-- message insertion in one database transaction.
--
-- This migration is idempotent.

begin;

-- ---------------------------------------------------------------------------
-- Direct conversations may exist without an organization.
-- ---------------------------------------------------------------------------
alter table public.conversations
  alter column organization_id drop not null;

create index if not exists conversations_org_idx
  on public.conversations(organization_id);

create index if not exists conversation_members_pair_idx
  on public.conversation_members(conversation_id, user_id);

-- ---------------------------------------------------------------------------
-- Reuse one direct conversation for a participant pair.
-- ---------------------------------------------------------------------------
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
  if uid is null then
    raise exception 'Not authenticated';
  end if;

  if p_other is null or p_other = uid then
    raise exception 'Invalid message recipient';
  end if;

  if not exists (
    select 1 from auth.users where id = p_other
  ) then
    raise exception 'Recipient account does not exist';
  end if;

  if not exists (
    select 1 from public.profiles where id = p_other
  ) then
    raise exception 'Recipient is not a NestTrack user';
  end if;

  -- Serialize creation for the same two users so concurrent first messages
  -- cannot create two direct threads.
  pair_key :=
    least(uid::text, p_other::text) || ':' ||
    greatest(uid::text, p_other::text);

  perform pg_advisory_xact_lock(hashtextextended(pair_key, 0));

  -- Prefer the explicitly supplied organization only if both users belong
  -- to it. Otherwise find a shared active organization.
  if p_organization_id is not null
     and exists (
       select 1
         from public.organization_members
        where organization_id = p_organization_id
          and user_id = uid
          and status = 'active'
     )
     and exists (
       select 1
         from public.organization_members
        where organization_id = p_organization_id
          and user_id = p_other
          and status = 'active'
     ) then

    common_org := p_organization_id;

  else

    select om1.organization_id
      into common_org
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

  -- Never reuse a channel conversation as a direct thread.
  select c.id
    into cid
    from public.conversations c
   where not exists (
           select 1
             from public.channels ch
            where ch.conversation_id = c.id
         )
     and exists (
           select 1
             from public.conversation_members cm
            where cm.conversation_id = c.id
              and cm.user_id = uid
         )
     and exists (
           select 1
             from public.conversation_members cm
            where cm.conversation_id = c.id
              and cm.user_id = p_other
         )
     and (
           select count(*)
             from public.conversation_members cm
            where cm.conversation_id = c.id
         ) = 2
   order by c.created_at
   limit 1
   for update;

  if cid is null then
    insert into public.conversations(organization_id)
    values (common_org)
    returning id into cid;

    insert into public.conversation_members(conversation_id, user_id)
    values
      (cid, uid),
      (cid, p_other)
    on conflict (conversation_id, user_id) do nothing;

  elsif common_org is not null then
    update public.conversations
       set organization_id = coalesce(organization_id, common_org)
     where id = cid;
  end if;

  return cid;
end;
$$;

revoke all on function public.get_or_create_direct_conversation(uuid, uuid)
  from public, anon;
grant execute on function public.get_or_create_direct_conversation(uuid, uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Atomic direct-message send RPC
-- ---------------------------------------------------------------------------
-- This is the key delivery fix. The browser no longer has to:
--   1. create/find a conversation
--   2. then separately insert the message.
--
-- Both operations happen in one transaction under SECURITY DEFINER.
create or replace function public.send_direct_message(
  p_recipient_id uuid,
  p_body text,
  p_organization_id uuid default null
)
returns public.messages
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  cid uuid;
  new_message public.messages;
begin
  if uid is null then
    raise exception 'Not authenticated';
  end if;

  if p_recipient_id is null or p_recipient_id = uid then
    raise exception 'Invalid message recipient';
  end if;

  if p_body is null or btrim(p_body) = '' then
    raise exception 'Message cannot be empty';
  end if;

  if length(p_body) > 5000 then
    raise exception 'Message is too long';
  end if;

  cid := public.get_or_create_direct_conversation(
    p_recipient_id,
    p_organization_id
  );

  insert into public.messages(
    conversation_id,
    sender_id,
    body
  )
  values (
    cid,
    uid,
    btrim(p_body)
  )
  returning * into new_message;

  return new_message;
end;
$$;

revoke all on function public.send_direct_message(uuid, text, uuid)
  from public, anon;
grant execute on function public.send_direct_message(uuid, text, uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Associate an existing direct conversation after organization membership.
-- ---------------------------------------------------------------------------
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
         select 1
           from public.channels ch
          where ch.conversation_id = c.id
       )
       and exists (
         select 1
           from public.conversation_members cm
          where cm.conversation_id = c.id
            and cm.user_id = new.user_id
       )
       and exists (
         select 1
           from public.conversation_members cm
           join public.organization_members om
             on om.user_id = cm.user_id
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
after insert or update of organization_id, status
on public.organization_members
for each row
execute function public.associate_direct_conversations_after_membership();

-- ---------------------------------------------------------------------------
-- Server-side message notifications
-- ---------------------------------------------------------------------------
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
  select c.organization_id
    into conversation_org
    from public.conversations c
   where c.id = new.conversation_id;

  select exists (
    select 1
      from public.channels ch
     where ch.conversation_id = new.conversation_id
  )
  into channel_message;

  select coalesce(p.full_name, 'A NestTrack user')
    into sender_name
    from public.profiles p
   where p.id = new.sender_id;

  notification_title :=
    case
      when channel_message then 'New channel message'
      else 'New direct message'
    end;

  insert into public.notifications(
    recipient_user_id,
    organization_id,
    event_type,
    title,
    body,
    related_entity_type,
    related_entity_id
  )
  select
    cm.user_id,
    conversation_org,
    case
      when channel_message then 'channel_message'
      else 'direct_message'
    end,
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
for each row
execute function public.notify_message_recipients();

-- ---------------------------------------------------------------------------
-- Notification access
-- ---------------------------------------------------------------------------
alter table public.notifications enable row level security;

drop policy if exists "notifications own read" on public.notifications;
create policy "notifications own read"
on public.notifications
for select
using (recipient_user_id = auth.uid());

drop policy if exists "notifications own update" on public.notifications;
create policy "notifications own update"
on public.notifications
for update
using (recipient_user_id = auth.uid())
with check (recipient_user_id = auth.uid());

drop policy if exists "notifications browser insert" on public.notifications;

-- ---------------------------------------------------------------------------
-- Conversation/message read RPCs
-- ---------------------------------------------------------------------------
create or replace function public.mark_conversation_read(
  p_conversation_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null
     or not public.is_conversation_member(p_conversation_id, auth.uid()) then
    raise exception 'Not authorized';
  end if;

  update public.messages
     set read_at = now()
   where conversation_id = p_conversation_id
     and sender_id is distinct from auth.uid()
     and read_at is null;
end;
$$;

revoke all on function public.mark_conversation_read(uuid)
  from public, anon;
grant execute on function public.mark_conversation_read(uuid)
  to authenticated;

create or replace function public.mark_notification_read(
  p_notification_id uuid
)
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

revoke all on function public.mark_notification_read(uuid)
  from public, anon;
grant execute on function public.mark_notification_read(uuid)
  to authenticated;

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

revoke all on function public.mark_all_notifications_read()
  from public, anon;
grant execute on function public.mark_all_notifications_read()
  to authenticated;

-- ---------------------------------------------------------------------------
-- RLS: participant-scoped conversation/message reads
-- ---------------------------------------------------------------------------
alter table public.conversations enable row level security;

drop policy if exists "conversation members read" on public.conversations;
drop policy if exists "conversation participants or admins read conversations"
  on public.conversations;

create policy "conversation participants or admins read conversations"
on public.conversations
for select
using (
  public.is_platform_admin()
  or public.is_conversation_member(id, auth.uid())
);

alter table public.conversation_members enable row level security;

drop policy if exists "conversation members read membership"
  on public.conversation_members;
drop policy if exists "conversation participants read membership"
  on public.conversation_members;

create policy "conversation participants read membership"
on public.conversation_members
for select
using (
  user_id = auth.uid()
  or public.is_conversation_member(conversation_id, auth.uid())
  or public.is_platform_admin()
);

alter table public.messages enable row level security;

drop policy if exists "conversation participants read messages"
  on public.messages;
drop policy if exists "conversation participants or admins read messages"
  on public.messages;

create policy "conversation participants or admins read messages"
on public.messages
for select
using (
  public.is_platform_admin()
  or public.is_conversation_member(conversation_id, auth.uid())
);

drop policy if exists "conversation participants send messages"
  on public.messages;

create policy "conversation participants send messages"
on public.messages
for insert
with check (
  sender_id = auth.uid()
  and public.is_conversation_member(conversation_id, auth.uid())
);

-- ---------------------------------------------------------------------------
-- Read RPCs for the frontend
-- ---------------------------------------------------------------------------
create or replace function public.get_my_conversation_members()
returns table(
  conversation_id uuid,
  user_id uuid
)
language sql
stable
security definer
set search_path = public
as $$
  select cm.conversation_id, cm.user_id
    from public.conversation_members cm
   where public.is_platform_admin()
      or exists (
        select 1
          from public.conversation_members mine
         where mine.conversation_id = cm.conversation_id
           and mine.user_id = auth.uid()
      );
$$;

revoke all on function public.get_my_conversation_members()
  from public, anon;
grant execute on function public.get_my_conversation_members()
  to authenticated;

create or replace function public.get_my_messages()
returns table(
  id uuid,
  conversation_id uuid,
  sender_id uuid,
  body text,
  read_at timestamptz,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    m.id,
    m.conversation_id,
    m.sender_id,
    m.body,
    m.read_at,
    m.created_at
  from public.messages m
  where public.is_platform_admin()
     or exists (
       select 1
         from public.conversation_members cm
        where cm.conversation_id = m.conversation_id
          and cm.user_id = auth.uid()
     )
  order by m.created_at asc
  limit 1000;
$$;

revoke all on function public.get_my_messages()
  from public, anon;
grant execute on function public.get_my_messages()
  to authenticated;

-- ---------------------------------------------------------------------------
-- Repair old direct conversations that have no organization.
-- ---------------------------------------------------------------------------
update public.conversations c
   set organization_id = match.organization_id
  from (
    select
      c2.id,
      (array_agg(om.organization_id order by om.organization_id))[1]
        as organization_id
    from public.conversations c2
    join public.conversation_members cm1
      on cm1.conversation_id = c2.id
    join public.conversation_members cm2
      on cm2.conversation_id = c2.id
     and cm2.user_id <> cm1.user_id
    join public.organization_members om
      on om.user_id = cm2.user_id
     and om.status = 'active'
    where c2.organization_id is null
      and not exists (
        select 1
          from public.channels ch
         where ch.conversation_id = c2.id
      )
    group by c2.id
  ) match
 where c.id = match.id
   and c.organization_id is null;

-- ---------------------------------------------------------------------------
-- Realtime
-- ---------------------------------------------------------------------------
do $$
begin
  begin
    alter publication supabase_realtime add table public.messages;
  exception
    when duplicate_object then null;
  end;

  begin
    alter publication supabase_realtime add table public.conversation_members;
  exception
    when duplicate_object then null;
  end;

  begin
    alter publication supabase_realtime add table public.channel_members;
  exception
    when duplicate_object then null;
  end;

  begin
    alter publication supabase_realtime add table public.channels;
  exception
    when duplicate_object then null;
  end;

  begin
    alter publication supabase_realtime add table public.notifications;
  exception
    when duplicate_object then null;
  end;
end
$$;

commit;
