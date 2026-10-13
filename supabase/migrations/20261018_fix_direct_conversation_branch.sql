begin;

-- Replace the direct-conversation function with equivalent guarded IF blocks.
-- This avoids parser issues around the previous ELSIF branch and preserves
-- organization association for an existing conversation.
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
  if not exists (select 1 from auth.users where id=p_other) then raise exception 'Recipient account does not exist'; end if;
  if not exists (select 1 from public.profiles where id=p_other) then raise exception 'Recipient is not a NestTrack user'; end if;

  pair_key := least(uid::text,p_other::text)||':'||greatest(uid::text,p_other::text);
  perform pg_advisory_xact_lock(hashtextextended(pair_key,0));

  if p_organization_id is not null
     and exists (select 1 from public.organization_members where organization_id=p_organization_id and user_id=uid and status='active')
     and exists (select 1 from public.organization_members where organization_id=p_organization_id and user_id=p_other and status='active') then
    common_org := p_organization_id;
  else
    select om1.organization_id into common_org
      from public.organization_members om1
      join public.organization_members om2 on om2.organization_id=om1.organization_id and om2.user_id=p_other and om2.status='active'
     where om1.user_id=uid and om1.status='active'
     order by om1.organization_id limit 1;
  end if;

  select c.id into cid
    from public.conversations c
   where not exists (select 1 from public.channels ch where ch.conversation_id=c.id)
     and exists (select 1 from public.conversation_members cm where cm.conversation_id=c.id and cm.user_id=uid)
     and exists (select 1 from public.conversation_members cm where cm.conversation_id=c.id and cm.user_id=p_other)
     and (select count(*) from public.conversation_members cm where cm.conversation_id=c.id)=2
   order by c.created_at
   limit 1
   for update;

  if cid is null then
    insert into public.conversations(organization_id) values(common_org) returning id into cid;
    insert into public.conversation_members(conversation_id,user_id)
    values(cid,uid),(cid,p_other)
    on conflict on constraint conversation_members_pkey do nothing;
  end if;

  if cid is not null and common_org is not null then
    update public.conversations
       set organization_id=coalesce(organization_id,common_org)
     where id=cid;
  end if;

  return cid;
end;
$$;

revoke all on function public.get_or_create_direct_conversation(uuid,uuid) from public,anon;
grant execute on function public.get_or_create_direct_conversation(uuid,uuid) to authenticated;
notify pgrst,'reload schema';
commit;
