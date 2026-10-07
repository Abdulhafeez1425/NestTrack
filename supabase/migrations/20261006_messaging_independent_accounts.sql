-- NestTrack messaging hardening for independently created manager/tenant accounts.
-- Run after the existing messaging/RLS migrations.

-- The read-state RPC must remain independent of conversation_members RLS.
create or replace function public.mark_conversation_read(p_conversation_id uuid)
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

-- Keep the messaging tables in Realtime. These blocks are idempotent if the
-- tables have already been added to the publication in Supabase.
do $$
begin
  begin
    alter publication supabase_realtime add table public.messages;
  exception when duplicate_object then null;
  end;
  begin
    alter publication supabase_realtime add table public.conversation_members;
  exception when duplicate_object then null;
  end;
end $$;

-- A direct message is created only through the security-definer RPC. The
-- sender must be a participant when inserting the actual message row.
drop policy if exists "conversation participants send messages" on public.messages;
create policy "conversation participants send messages"
on public.messages for insert
with check (
  sender_id = auth.uid()
  and public.is_conversation_member(messages.conversation_id, auth.uid())
);

-- Conversation membership is never writable directly by clients.
drop policy if exists "conversation members insert" on public.conversation_members;
drop policy if exists "conversation members delete" on public.conversation_members;
