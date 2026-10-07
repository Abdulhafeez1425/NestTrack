-- Independent manager/tenant signup and assignment without invitation links.
-- Apply after 20261006_property_management.sql.

create or replace function public.create_independent_profile(
  p_full_name text,
  p_role text,
  p_phone text default null
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  uid uuid := auth.uid();
  email_address text;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_role not in ('manager','tenant') then raise exception 'Only manager and tenant accounts can use independent signup'; end if;
  if nullif(trim(p_full_name),'') is null then raise exception 'Full name is required'; end if;

  select email into email_address from auth.users where id=uid;
  if email_address is null then raise exception 'Authenticated user email is missing'; end if;

  insert into public.profiles(id,full_name,email,role,phone)
  values(uid,trim(p_full_name),email_address,p_role,nullif(trim(p_phone),''))
  on conflict(id) do update set
    full_name=excluded.full_name,
    email=excluded.email,
    phone=excluded.phone;

  return uid;
end;
$$;

revoke all on function public.create_independent_profile(text,text,text) from public,anon;
grant execute on function public.create_independent_profile(text,text,text) to authenticated;

-- A manager/landlord can assign a standalone tenant account directly to a unit.
-- If the tenant is not yet a member of the organization, membership is created
-- as part of the assignment. This removes the invitation-link dependency while
-- keeping all writes inside a security-definer authorization boundary.
create or replace function public.assign_tenant_to_unit(
  p_organization_id uuid,
  p_unit_id uuid,
  p_tenant_id uuid,
  p_start_date date,
  p_rent_amount numeric,
  p_frequency text default 'monthly',
  p_deposit_amount numeric default 0
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  tid uuid;
  unit_org uuid;
  tenant_member boolean;
  tenant_role text;
begin
  if not public.has_org_capability(p_organization_id,'assign_tenants') then raise exception 'Not authorized'; end if;
  select organization_id into unit_org from public.units where id=p_unit_id for update;
  if unit_org is distinct from p_organization_id then raise exception 'Unit is outside organization'; end if;

  select role into tenant_role from public.profiles where id=p_tenant_id;
  if tenant_role is distinct from 'tenant' then raise exception 'Selected account is not a tenant'; end if;

  select exists(
    select 1 from public.organization_members
    where organization_id=p_organization_id and user_id=p_tenant_id and role='tenant' and status='active'
  ) into tenant_member;

  if not tenant_member then
    insert into public.organization_members(organization_id,user_id,role,status,invited_by,joined_at)
    values(p_organization_id,p_tenant_id,'tenant','active',auth.uid(),now())
    on conflict (organization_id,user_id) do update set role='tenant',status='active',joined_at=coalesce(organization_members.joined_at,now());
  end if;

  if exists(select 1 from public.tenancies where unit_id=p_unit_id and status in ('active','move_out_requested')) then
    raise exception 'Unit already has an active tenancy';
  end if;
  if exists(select 1 from public.tenancies where tenant_id=p_tenant_id and status in ('active','move_out_requested')) then
    raise exception 'Tenant already has an active tenancy';
  end if;

  insert into public.tenancies(
    organization_id,unit_id,tenant_id,start_date,rent_amount,frequency,deposit_amount,status
  ) values(p_organization_id,p_unit_id,p_tenant_id,p_start_date,p_rent_amount,p_frequency,p_deposit_amount,'active')
  returning id into tid;

  update public.units set status='occupied',current_tenant_id=p_tenant_id where id=p_unit_id;

  insert into public.audit_events(organization_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_organization_id,auth.uid(),'tenant_assigned','tenancy',tid,jsonb_build_object('unit_id',p_unit_id,'tenant_id',p_tenant_id));

  insert into public.notifications(recipient_user_id,organization_id,event_type,title,body,related_entity_type,related_entity_id)
  values(p_tenant_id,p_organization_id,'tenant_joined','Unit assigned','You have been assigned to a unit.','tenancy',tid);

  return tid;
end;
$$;

revoke all on function public.assign_tenant_to_unit(uuid,uuid,uuid,date,numeric,text,numeric) from public,anon;
grant execute on function public.assign_tenant_to_unit(uuid,uuid,uuid,date,numeric,text,numeric) to authenticated;

-- Create manager/tenant profiles at auth-user creation time as well. This makes
-- signup work when Supabase email confirmation is enabled, because no browser
-- session is required to establish the basic profile.
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
begin
  if signup_role in ('manager','tenant') then
    insert into public.profiles(id,full_name,email,role,phone)
    values(new.id,coalesce(signup_name,split_part(new.email,'@',1)),new.email,signup_role,signup_phone)
    on conflict(id) do update set
      full_name=excluded.full_name,
      email=excluded.email,
      phone=coalesce(excluded.phone,profiles.phone);
  end if;
  return new;
end;
$$;

drop trigger if exists on_auth_user_independent_signup on auth.users;
create trigger on_auth_user_independent_signup
after insert on auth.users
for each row execute function public.handle_independent_signup_profile();
