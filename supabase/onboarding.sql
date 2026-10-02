-- Secure onboarding RPC used by the browser after Supabase Auth signup.
create or replace function public.finish_onboarding(
  p_full_name text, p_role text, p_org_name text default null, p_invite_code text default null
) returns uuid language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); oid uuid; inv invite_codes%rowtype;
begin
 if uid is null then raise exception 'Not authenticated'; end if;
 if p_role='landlord' then
   insert into profiles(id,full_name,email,role) select uid,p_full_name,email,'landlord' from auth.users where id=uid
   on conflict(id) do update set full_name=excluded.full_name,role='landlord';
   insert into organizations(name) values(coalesce(nullif(trim(p_org_name),''),p_full_name||' Properties')) returning id into oid;
   insert into organization_members(organization_id,user_id,role) values(oid,uid,'landlord');
 else
   select * into inv from invite_codes where code=p_invite_code and active=true and role=p_role and (expires_at is null or expires_at>now()) and (max_uses is null or used_count<max_uses) for update;
   if not found then raise exception 'Invalid or expired invite code'; end if;
   insert into profiles(id,full_name,email,role) select uid,p_full_name,email,p_role from auth.users where id=uid
   on conflict(id) do update set full_name=excluded.full_name,role=excluded.role;
   insert into organization_members(organization_id,user_id,role) values(inv.organization_id,uid,p_role);
   update invite_codes set used_count=used_count+1 where id=inv.id;
   oid:=inv.organization_id;
 end if;
 return oid;
end $$;
grant execute on function public.finish_onboarding(text,text,text,text) to authenticated;

create or replace function public.ensure_organization_invite_codes()
returns void language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); org record; invite_role text; code_prefix text; generated_code text; inserted_rows integer;
begin
 if uid is null then raise exception 'Not authenticated'; end if;
 for org in
   select organization_id from public.organization_members
   where user_id=uid and role='landlord' and status='active'
   order by organization_id
 loop
   perform 1 from public.organizations where id=org.organization_id for update;
   foreach invite_role in array array['manager','tenant'] loop
     update public.invite_codes set active=false
     where organization_id=org.organization_id and role=invite_role and active=true
       and ((expires_at is not null and expires_at<=now()) or (max_uses is not null and used_count>=max_uses));
     if not exists(select 1 from public.invite_codes where organization_id=org.organization_id and role=invite_role and active=true) then
       code_prefix:=case when invite_role='manager' then 'NT-MGR-' else 'NT-TEN-' end;
       loop
         generated_code:=code_prefix||upper(encode(gen_random_bytes(5),'hex'));
         insert into public.invite_codes(organization_id,code,role,created_by)
         values(org.organization_id,generated_code,invite_role,uid)
         on conflict(code) do nothing;
         get diagnostics inserted_rows=row_count;
         exit when inserted_rows=1;
       end loop;
     end if;
   end loop;
 end loop;
end $$;
revoke all on function public.ensure_organization_invite_codes() from public, anon;
grant execute on function public.ensure_organization_invite_codes() to authenticated;

create or replace function public.get_or_create_direct_conversation(p_other uuid)
returns uuid language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); cid uuid; oid uuid;
begin
 select organization_id into oid from organization_members where user_id=uid and status='active' limit 1;
 select c.id into cid from conversations c where c.organization_id=oid and exists(select 1 from conversation_members a where a.conversation_id=c.id and a.user_id=uid) and exists(select 1 from conversation_members b where b.conversation_id=c.id and b.user_id=p_other) limit 1;
 if cid is null then insert into conversations(organization_id) values(oid) returning id into cid; insert into conversation_members(conversation_id,user_id) values(cid,uid),(cid,p_other); end if;
 return cid;
end $$;
grant execute on function public.get_or_create_direct_conversation(uuid) to authenticated;

-- Standardized validation constraints
create or replace function public.validate_profile_fields()
returns trigger language plpgsql as $$
begin
  if new.email is not null and new.email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]{2,}$' then
    raise exception 'Invalid email address';
  end if;
  if new.phone is not null and new.phone !~ '^\+[1-9][0-9]{7,14}$' then
    raise exception 'Phone must include a valid country code';
  end if;
  return new;
end; $$;

drop trigger if exists validate_profile_fields on public.profiles;
create trigger validate_profile_fields before insert or update on public.profiles
for each row execute function public.validate_profile_fields();
