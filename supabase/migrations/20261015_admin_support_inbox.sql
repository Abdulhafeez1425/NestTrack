-- NestTrack support conversations routed into the platform-admin Messages inbox.
-- Existing conversations and direct-message privacy remain unchanged.

alter table public.conversations
  add column if not exists is_support boolean not null default false;

alter table public.conversations
  add column if not exists support_requester_id uuid
  references auth.users(id) on delete cascade;

create unique index if not exists conversations_one_support_thread_per_requester_idx
  on public.conversations(support_requester_id)
  where is_support and support_requester_id is not null;

comment on column public.conversations.is_support is
  'True only for a private requester-to-platform-support conversation.';
comment on column public.conversations.support_requester_id is
  'The account that opened this support conversation; unique per requester.';

-- Contact Support creates or reopens the authenticated user's single support
-- conversation. Every current platform admin is a participant, so the thread is
-- visible in each administrator's normal Messages workspace and unread badge.
create or replace function public.get_or_create_support_conversation()
returns table(conversation_id uuid, support_admin_id uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  cid uuid;
  first_admin uuid;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if public.is_platform_admin() then
    raise exception 'Platform administrators should use the Support inbox.';
  end if;

  select pa.id into first_admin
    from public.platform_admins pa
   order by pa.id
   limit 1;
  if first_admin is null then
    raise exception 'NestTrack Support is not available yet. Please try again later.';
  end if;

  -- Serialize first-time creation so repeated clicks cannot create duplicate
  -- conversations for the same requester.
  perform 1 from auth.users where id = uid for update;

  select c.id into cid
    from public.conversations c
   where c.is_support and c.support_requester_id = uid
   limit 1;

  if cid is null then
    insert into public.conversations(organization_id,is_support,support_requester_id)
    values (null,true,uid)
    returning id into cid;
  end if;

  insert into public.conversation_members(conversation_id,user_id)
  select cid, uid
  union
  select cid, pa.id from public.platform_admins pa
  on conflict (conversation_id,user_id) do nothing;

  return query select cid, first_admin;
end;
$$;

revoke all on function public.get_or_create_support_conversation() from public, anon;
grant execute on function public.get_or_create_support_conversation() to authenticated;

-- New platform admins automatically gain membership in existing support
-- threads. This keeps future support replies and read receipts participant-safe.
create or replace function public.add_platform_admin_to_support_conversations()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.conversation_members(conversation_id,user_id)
  select c.id, new.id
    from public.conversations c
   where c.is_support and c.support_requester_id is not null
  on conflict (conversation_id,user_id) do nothing;
  return new;
end;
$$;

revoke all on function public.add_platform_admin_to_support_conversations() from public, anon;
drop trigger if exists platform_admin_support_membership on public.platform_admins;
create trigger platform_admin_support_membership
after insert on public.platform_admins
for each row execute function public.add_platform_admin_to_support_conversations();

-- The requester and any platform administrator may reply. Other participants
-- cannot be added through this RPC, and messages continue to use the existing
-- audit history, soft-delete and RLS protections.
create or replace function public.reply_to_support_conversation(
  p_conversation_id uuid,
  p_body text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  requester uuid;
  new_message_id uuid;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_conversation_id is null then raise exception 'Support conversation is required'; end if;
  if p_body is null or btrim(p_body) = '' then raise exception 'Message cannot be empty'; end if;
  if length(p_body) > 5000 then raise exception 'Message is too long'; end if;

  select c.support_requester_id into requester
    from public.conversations c
   where c.id = p_conversation_id and c.is_support
   for update;
  if requester is null then raise exception 'Support conversation not found'; end if;
  if uid <> requester and not public.is_platform_admin() then
    raise exception 'Only the requester or a platform administrator can reply';
  end if;
  if uid = requester and not exists (
    select 1 from public.conversation_members cm
     where cm.conversation_id = p_conversation_id and cm.user_id = uid
  ) then
    raise exception 'You are not a participant in this support conversation';
  end if;

  insert into public.messages(conversation_id,sender_id,body)
  values (p_conversation_id,uid,btrim(p_body))
  returning id into new_message_id;
  return new_message_id;
end;
$$;

revoke all on function public.reply_to_support_conversation(uuid,text) from public, anon;
grant execute on function public.reply_to_support_conversation(uuid,text) to authenticated;
