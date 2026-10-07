-- NestTrack
-- 20261006_messaging_independent_accounts.sql
-- Messaging hardening for independently created Manager/Tenant/Landlord accounts.
--
-- RUN ORDER:
--   1. 20261006_messaging_independent_accounts.sql
--   2. 20261006_messaging_end_to_end.sql
--
-- This migration is idempotent.

begin;

-- Direct conversations can exist before an account is assigned to an
-- organization. The end-to-end migration also enforces this, but keeping the
-- change here makes this migration safe to apply on its own after the base
-- messaging schema exists.
alter table public.conversations
  alter column organization_id drop not null;

-- ---------------------------------------------------------------------------
-- Membership helper
-- ---------------------------------------------------------------------------
-- SECURITY DEFINER prevents conversation_members RLS recursion when the
-- helper is used by conversation/messages policies.
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

revoke all on function public.is_conversation_member(uuid, uuid) from public, anon;
grant execute on function public.is_conversation_member(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Read-state RPC
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
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if not public.is_conversation_member(p_conversation_id, auth.uid()) then
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

-- ---------------------------------------------------------------------------
-- RLS: conversations
-- ---------------------------------------------------------------------------
alter table public.conversations enable row level security;

drop policy if exists "conversation members read" on public.conversations;
drop policy if exists "conversation participants or admins read conversations" on public.conversations;

create policy "conversation participants or admins read conversations"
on public.conversations
for select
using (
  public.is_conversation_member(id, auth.uid())
  or public.is_platform_admin()
);

-- Clients must not create arbitrary conversations. The security-definer
-- get_or_create/send RPCs in the next migration create them safely.
drop policy if exists "conversation members insert" on public.conversations;
drop policy if exists "conversation participants insert conversations" on public.conversations;

-- ---------------------------------------------------------------------------
-- RLS: conversation_members
-- ---------------------------------------------------------------------------
alter table public.conversation_members enable row level security;

drop policy if exists "conversation members read membership" on public.conversation_members;
drop policy if exists "conversation participants read membership" on public.conversation_members;

create policy "conversation participants read membership"
on public.conversation_members
for select
using (
  user_id = auth.uid()
  or public.is_conversation_member(conversation_id, auth.uid())
  or public.is_platform_admin()
);

-- Membership changes are owned by security-definer messaging functions.
drop policy if exists "conversation members insert" on public.conversation_members;
drop policy if exists "conversation members delete" on public.conversation_members;
drop policy if exists "conversation members update" on public.conversation_members;

-- ---------------------------------------------------------------------------
-- RLS: messages
-- ---------------------------------------------------------------------------
alter table public.messages enable row level security;

drop policy if exists "conversation participants read messages" on public.messages;
drop policy if exists "conversation participants or admins read messages" on public.messages;

create policy "conversation participants or admins read messages"
on public.messages
for select
using (
  public.is_conversation_member(conversation_id, auth.uid())
  or public.is_platform_admin()
);

drop policy if exists "conversation participants send messages" on public.messages;

create policy "conversation participants send messages"
on public.messages
for insert
with check (
  sender_id = auth.uid()
  and public.is_conversation_member(conversation_id, auth.uid())
);

-- Clients cannot modify another user's message or its conversation.
drop policy if exists "conversation participants update messages" on public.messages;
drop policy if exists "conversation participants delete messages" on public.messages;

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
end
$$;

commit;
