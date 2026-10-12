begin;

-- Keep the technician's trade visible to landlords/managers when assigning work.
alter table public.profiles
  add column if not exists occupation text;

alter table public.profiles
  drop constraint if exists profiles_occupation_length_check;
alter table public.profiles
  add constraint profiles_occupation_length_check
  check (occupation is null or char_length(occupation) <= 100);

-- A changed return shape requires dropping/recreating this RPC.
drop function if exists public.get_user_directory();
create function public.get_user_directory()
returns table (
  user_id uuid,
  full_name text,
  email text,
  phone text,
  occupation text,
  avatar_url text,
  role text,
  organization_id uuid,
  organization_name text
)
language sql
stable
security definer
set search_path = public
as $$
  select p.id, p.full_name, p.email, p.phone, p.occupation, p.avatar_url, p.role,
         om.organization_id, o.name
  from public.profiles p
  left join public.organization_members om on om.user_id=p.id and om.status='active'
  left join public.organizations o on o.id=om.organization_id
  where auth.uid() is not null
  order by p.full_name;
$$;
revoke all on function public.get_user_directory() from public, anon;
grant execute on function public.get_user_directory() to authenticated;

-- Persist occupation even when email confirmation delays the authenticated
-- profile RPC: the Auth trigger consumes signup metadata first.
create or replace function public.handle_independent_signup_profile()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  signup_role text := coalesce(new.raw_user_meta_data->>'role','');
  signup_name text := nullif(trim(new.raw_user_meta_data->>'full_name'),'');
  signup_phone text := nullif(trim(new.raw_user_meta_data->>'phone'),'');
  signup_occupation text := case when signup_role='technician' then nullif(left(trim(coalesce(new.raw_user_meta_data->>'occupation','')),100),'') else null end;
begin
  if signup_role in ('manager','tenant','technician') then
    insert into public.profiles(id,full_name,email,role,phone,occupation)
    values(new.id,coalesce(signup_name,split_part(new.email,'@',1)),new.email,signup_role,signup_phone,signup_occupation)
    on conflict(id) do update set
      full_name=excluded.full_name,
      email=excluded.email,
      phone=coalesce(excluded.phone,profiles.phone),
      occupation=coalesce(excluded.occupation,profiles.occupation);
  end if;
  return new;
end;
$$;
revoke all on function public.handle_independent_signup_profile() from public,anon,authenticated;

-- New overload keeps the existing three-argument RPC callable by older clients.
create or replace function public.create_independent_profile(
  p_full_name text,
  p_role text,
  p_phone text,
  p_occupation text
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  uid uuid := auth.uid();
  email_address text;
  occupation_value text := nullif(left(trim(coalesce(p_occupation,'')),100),'');
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_role not in ('manager','tenant','technician') then raise exception 'Invalid independent account role'; end if;
  if nullif(trim(p_full_name),'') is null then raise exception 'Full name is required'; end if;
  if p_role='technician' and occupation_value is null then raise exception 'Technician occupation is required'; end if;
  if p_role<>'technician' then occupation_value := null; end if;
  select email into email_address from auth.users where id=uid;
  if email_address is null then raise exception 'Authenticated user email is missing'; end if;
  insert into public.profiles(id,full_name,email,role,phone,occupation)
  values(uid,trim(p_full_name),email_address,p_role,nullif(trim(p_phone),''),occupation_value)
  on conflict(id) do update set
    full_name=excluded.full_name,
    email=excluded.email,
    phone=coalesce(excluded.phone,profiles.phone),
    occupation=coalesce(excluded.occupation,profiles.occupation);
  return uid;
end;
$$;
revoke all on function public.create_independent_profile(text,text,text,text) from public,anon;
grant execute on function public.create_independent_profile(text,text,text,text) to authenticated;

notify pgrst, 'reload schema';
commit;
