-- NestTrack production profile/deletion hardening. Apply after schema.sql and rls.sql.
-- These SECURITY DEFINER functions centralize destructive authorization and cascading cleanup.

alter table profiles alter column role drop not null;
alter table profiles drop constraint if exists profiles_role_check;
alter table profiles add constraint profiles_role_check check (role is null or role in ('landlord','manager','tenant'));

create or replace function public.is_active_landlord(target_org uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from organization_members om
    where om.organization_id=target_org and om.user_id=auth.uid()
      and om.role='landlord' and om.status='active');
$$;

-- Only the account owner can delete their own avatar object.
create policy "Users delete their own avatar" on storage.objects for delete
using (bucket_id='avatars' and (storage.foldername(name))[1]=auth.uid()::text);

-- Restrict destructive operations to explicit RPCs; do not grant broad DELETE policies.
create or replace function public.delete_property_as_landlord(p_property_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare org_id uuid;
begin
  select organization_id into org_id from properties where id=p_property_id;
  if org_id is null or not is_active_landlord(org_id) then raise exception 'Not authorized'; end if;
  delete from properties where id=p_property_id;
end; $$;

create or replace function public.delete_unit_as_landlord(p_unit_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare org_id uuid;
begin
  select organization_id into org_id from units where id=p_unit_id;
  if org_id is null or not is_active_landlord(org_id) then raise exception 'Not authorized'; end if;
  delete from units where id=p_unit_id;
end; $$;

create or replace function public.delete_organization_as_landlord(p_organization_id uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not is_active_landlord(p_organization_id) then raise exception 'Not authorized'; end if;
  delete from organizations where id=p_organization_id;
end; $$;

create or replace function public.delete_tenant_account(p_tenant_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare shared_org uuid;
begin
  select om.organization_id into shared_org from organization_members om
  where om.user_id=p_tenant_id and om.role='tenant'
    and exists (select 1 from organization_members me where me.organization_id=om.organization_id and me.user_id=auth.uid() and me.role='landlord' and me.status='active')
  limit 1;
  if shared_org is null then raise exception 'Not authorized'; end if;
  delete from auth.users where id=p_tenant_id;
end; $$;

-- Self deletion relies on FK ON DELETE CASCADE already present for profile/membership records.
-- Remove tenant references that are intentionally nullable before deleting auth user.
create or replace function public.delete_my_account()
returns void language plpgsql security definer set search_path=public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  update units set current_tenant_id=null, status='vacant' where current_tenant_id=auth.uid();
  delete from auth.users where id=auth.uid();
end; $$;


create or replace function public.admin_delete_landlord(p_landlord_id uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not exists (select 1 from public.profiles where id=auth.uid() and role='admin') then
    raise exception 'Not authorized';
  end if;
  if not exists (select 1 from public.profiles where id=p_landlord_id and role='landlord') then
    raise exception 'Landlord not found';
  end if;
  delete from auth.users where id=p_landlord_id;
end; $$;
revoke all on function public.admin_delete_landlord(uuid) from public;
grant execute on function public.admin_delete_landlord(uuid) to authenticated;
