-- NestTrack platform administration + universal direct messaging
-- Forward-only migration. Safe to re-run.

-- Allow participant-scoped conversations that are not tied to one organization.
-- This is required when users from different organizations message each other,
-- and for platform-admin conversations.
alter table public.conversations
  alter column organization_id drop not null;

-- Platform admin management. Bootstrap the first admin through the documented
-- Supabase SQL process; thereafter only an existing platform admin can grant
-- or revoke another platform admin.
create or replace function public.grant_platform_admin(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  if not exists (select 1 from public.platform_admins where id = auth.uid()) then
    raise exception 'Platform administrator access required';
  end if;
  if not exists (select 1 from auth.users where id = p_user_id) then
    raise exception 'User does not exist';
  end if;
  insert into public.platform_admins(id) values (p_user_id)
  on conflict (id) do nothing;
end;
$$;

create or replace function public.revoke_platform_admin(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare admin_count integer;
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  if not exists (select 1 from public.platform_admins where id = auth.uid()) then
    raise exception 'Platform administrator access required';
  end if;
  select count(*) into admin_count from public.platform_admins;
  if p_user_id = auth.uid() and admin_count <= 1 then
    raise exception 'The last platform administrator cannot be removed';
  end if;
  delete from public.platform_admins where id = p_user_id;
end;
$$;

revoke all on function public.grant_platform_admin(uuid) from public, anon;
revoke all on function public.revoke_platform_admin(uuid) from public, anon;
grant execute on function public.grant_platform_admin(uuid) to authenticated;
grant execute on function public.revoke_platform_admin(uuid) to authenticated;

-- Replace direct-message creation with participant-based authorization.
-- Any authenticated NestTrack user can message any other NestTrack user.
-- When the users share an organization, the conversation is associated with
-- that organization; otherwise organization_id remains NULL.
create or replace function public.get_or_create_direct_conversation(p_other uuid, p_organization_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  cid uuid;
  oid uuid;
  other_exists boolean;
  common_org uuid;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_other is null or p_other = uid then raise exception 'Invalid message recipient'; end if;

  select exists(select 1 from auth.users where id = p_other) into other_exists;
  if not other_exists then raise exception 'Recipient account does not exist'; end if;

  -- Prefer an explicitly supplied organization only when both participants
  -- are active members of it. Otherwise derive a shared organization.
  if p_organization_id is not null
     and exists(select 1 from public.organization_members where organization_id=p_organization_id and user_id=uid and status='active')
     and exists(select 1 from public.organization_members where organization_id=p_organization_id and user_id=p_other and status='active') then
    common_org := p_organization_id;
  else
    select om1.organization_id into common_org
    from public.organization_members om1
    join public.organization_members om2 on om2.organization_id=om1.organization_id
    where om1.user_id=uid and om1.status='active'
      and om2.user_id=p_other and om2.status='active'
    order by om1.organization_id
    limit 1;
  end if;

  select c.id into cid
  from public.conversations c
  where c.organization_id is not distinct from common_org
    and exists(select 1 from public.conversation_members a where a.conversation_id=c.id and a.user_id=uid)
    and exists(select 1 from public.conversation_members b where b.conversation_id=c.id and b.user_id=p_other)
  limit 1;

  if cid is null then
    insert into public.conversations(organization_id) values(common_org) returning id into cid;
    insert into public.conversation_members(conversation_id,user_id) values(cid,uid),(cid,p_other);
  end if;
  return cid;
end;
$$;

revoke all on function public.get_or_create_direct_conversation(uuid,uuid) from public, anon;
grant execute on function public.get_or_create_direct_conversation(uuid,uuid) to authenticated;

-- Avoid recursive RLS evaluation when checking conversation membership.
create or replace function public.is_conversation_member(
  p_conversation_id uuid,
  p_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.conversation_members cm
    where cm.conversation_id = p_conversation_id
      and cm.user_id = p_user_id
      and p_user_id = auth.uid()
  );
$$;

revoke all on function public.is_conversation_member(uuid, uuid)
from public, anon;

grant execute on function public.is_conversation_member(uuid, uuid)
to authenticated;

-- Replace conversation policies with participant/admin-aware policies.
drop policy if exists "conversation members read" on public.conversations;
drop policy if exists "conversation participants or admins read conversations" on public.conversations;
create policy "conversation participants or admins read conversations"
on public.conversations
for select
using (
  public.is_platform_admin()
  or public.is_conversation_member(conversations.id, auth.uid())
);

-- Ensure users can read their own participant rows regardless of organization.
drop policy if exists "conversation members read membership" on public.conversation_members;
drop policy if exists "conversation participants read membership" on public.conversation_members;
create policy "conversation participants read membership"
on public.conversation_members
for select
using (
  user_id=auth.uid()
  or public.is_conversation_member(conversation_members.conversation_id, auth.uid())
  or public.is_platform_admin()
);

-- Message reads remain participant-scoped; admins may read platform conversations
-- because the admin dashboard is an authorized platform communication surface.
drop policy if exists "conversation participants read messages" on public.messages;
drop policy if exists "conversation participants or admins read messages" on public.messages;
create policy "conversation participants or admins read messages"
on public.messages
for select
using (
  public.is_platform_admin()
  or public.is_conversation_member(messages.conversation_id, auth.uid())
);

-- No client can add itself to arbitrary conversations. Conversation creation is
-- performed by the security-definer RPC above.
drop policy if exists "conversation participants send messages" on public.messages;
create policy "conversation participants send messages"
on public.messages
for insert
with check (
  sender_id=auth.uid()
  and public.is_conversation_member(messages.conversation_id, auth.uid())
);

-- Platform admins can inspect all profiles and memberships through existing
-- admin policies; keep normal users restricted by the existing RLS boundary.
