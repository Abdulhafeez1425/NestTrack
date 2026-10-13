begin;

-- The original support function returns a column named conversation_id. In
-- PL/pgSQL that output variable collides with ON CONFLICT (conversation_id,
-- user_id). Use the primary-key constraint name so existing deployments can
-- safely replace the function without recreating support conversations.
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
  on conflict on constraint conversation_members_pkey do nothing;

  return query select cid, first_admin;
end;
$$;

revoke all on function public.get_or_create_support_conversation() from public, anon;
grant execute on function public.get_or_create_support_conversation() to authenticated;

notify pgrst, 'reload schema';
commit;
