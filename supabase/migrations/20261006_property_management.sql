-- Property images are public for display, while uploads are restricted to
-- authenticated members with property-management capability in that org.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('property-images','property-images',true,10485760,array['image/jpeg','image/png','image/webp','image/gif'])
on conflict(id) do update set
  public=excluded.public,
  file_size_limit=excluded.file_size_limit,
  allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists "Property images are publicly readable" on storage.objects;
create policy "Property images are publicly readable" on storage.objects
  for select using(bucket_id='property-images');

drop policy if exists "Property managers upload property images" on storage.objects;
create policy "Property managers upload property images" on storage.objects
  for insert to authenticated
  with check(
    bucket_id='property-images'
    and (storage.foldername(name))[1]=auth.uid()::text
    and public.has_org_capability(((storage.foldername(name))[2])::uuid,'create_properties')
  );

drop policy if exists "Property managers update property images" on storage.objects;
create policy "Property managers update property images" on storage.objects
  for update to authenticated
  using(
    bucket_id='property-images'
    and (storage.foldername(name))[1]=auth.uid()::text
    and public.has_org_capability(((storage.foldername(name))[2])::uuid,'create_properties')
  )
  with check(
    bucket_id='property-images'
    and (storage.foldername(name))[1]=auth.uid()::text
    and public.has_org_capability(((storage.foldername(name))[2])::uuid,'create_properties')
  );

drop policy if exists "Property managers delete property images" on storage.objects;
create policy "Property managers delete property images" on storage.objects
  for delete to authenticated
  using(
    bucket_id='property-images'
    and (storage.foldername(name))[1]=auth.uid()::text
    and public.has_org_capability(((storage.foldername(name))[2])::uuid,'create_properties')
  );

create or replace function public.create_property_with_units(
  p_organization_id uuid,
  p_name text,
  p_address text,
  p_units jsonb,
  p_image_url text
)
returns uuid
language plpgsql security definer set search_path=public
as $$
declare
  uid uuid:=auth.uid();
  pid uuid;
  item jsonb;
  property_count integer;
  unit_count integer;
begin
  if not public.has_org_capability(p_organization_id,'create_properties') then
    raise exception 'Not authorized to manage properties';
  end if;
  if nullif(trim(p_name),'') is null then raise exception 'Property name is required'; end if;
  if nullif(trim(p_address),'') is null then raise exception 'Property address is required'; end if;
  if jsonb_typeof(coalesce(p_units,'[]'::jsonb))<>'array' then raise exception 'Units must be a list'; end if;

  select count(*) into property_count
  from public.properties where organization_id=p_organization_id and active;
  if exists(
    select 1 from public.organizations
    where id=p_organization_id and max_properties is not null and property_count>=max_properties
  ) then raise exception 'Organization property limit reached'; end if;

  select count(*) into unit_count from public.units where organization_id=p_organization_id;
  if exists(
    select 1 from public.organizations
    where id=p_organization_id and max_units is not null
      and unit_count+jsonb_array_length(coalesce(p_units,'[]'::jsonb))>max_units
  ) then raise exception 'Organization unit limit reached'; end if;

  insert into public.properties(organization_id,name,address,manager_id,image_url)
  values(p_organization_id,trim(p_name),trim(p_address),
    case when public.org_role(p_organization_id)='manager' then uid end,nullif(trim(p_image_url),''))
  returning id into pid;

  for item in select value from jsonb_array_elements(coalesce(p_units,'[]'::jsonb)) loop
    if nullif(trim(item->>'name'),'') is null then raise exception 'Every unit needs a name'; end if;
    if coalesce((item->>'rent')::numeric,0)<0 then raise exception 'Unit rent cannot be negative'; end if;
    insert into public.units(organization_id,property_id,label,description,rent_amount,status)
    values(p_organization_id,pid,trim(item->>'name'),nullif(trim(item->>'description'),''),coalesce((item->>'rent')::numeric,0),'vacant');
  end loop;
  return pid;
end;
$$;
revoke all on function public.create_property_with_units(uuid,text,text,jsonb,text) from public,anon;
grant execute on function public.create_property_with_units(uuid,text,text,jsonb,text) to authenticated;

create or replace function public.update_property_as_landlord(
  p_property_id uuid,p_name text,p_address text,p_image_url text
)
returns void
language plpgsql security definer set search_path=public
as $$
declare oid uuid;
begin
  select organization_id into oid from public.properties where id=p_property_id and active for update;
  if oid is null or not public.has_org_capability(oid,'create_properties') then raise exception 'Not authorized'; end if;
  if nullif(trim(p_name),'') is null then raise exception 'Property name is required'; end if;
  if nullif(trim(p_address),'') is null then raise exception 'Property address is required'; end if;
  update public.properties set name=trim(p_name),address=trim(p_address),image_url=nullif(trim(p_image_url),'')
  where id=p_property_id;
  insert into public.audit_events(organization_id,actor_id,action,entity_type,entity_id,metadata)
  values(oid,auth.uid(),'property_updated','property',p_property_id,jsonb_build_object('name',trim(p_name)));
end;
$$;
revoke all on function public.update_property_as_landlord(uuid,text,text,text) from public,anon;
grant execute on function public.update_property_as_landlord(uuid,text,text,text) to authenticated;

create or replace function public.create_unit_as_landlord(
  p_property_id uuid,p_label text,p_description text,p_rent_amount numeric
)
returns uuid
language plpgsql security definer set search_path=public
as $$
declare oid uuid; uid uuid:=auth.uid(); new_unit uuid; unit_count integer;
begin
  select organization_id into oid from public.properties where id=p_property_id and active for update;
  if oid is null or not public.has_org_capability(oid,'create_properties') then raise exception 'Not authorized'; end if;
  if nullif(trim(p_label),'') is null then raise exception 'Unit name is required'; end if;
  if p_rent_amount is null or p_rent_amount<0 then raise exception 'Unit rent must be zero or greater'; end if;
  select count(*) into unit_count from public.units where organization_id=oid;
  if exists(select 1 from public.organizations where id=oid and max_units is not null and unit_count>=max_units) then
    raise exception 'Organization unit limit reached';
  end if;
  insert into public.units(organization_id,property_id,label,description,rent_amount,status)
  values(oid,p_property_id,trim(p_label),nullif(trim(p_description),''),p_rent_amount,'vacant')
  returning id into new_unit;
  insert into public.audit_events(organization_id,actor_id,action,entity_type,entity_id,metadata)
  values(oid,uid,'unit_created','unit',new_unit,jsonb_build_object('property_id',p_property_id));
  return new_unit;
end;
$$;
revoke all on function public.create_unit_as_landlord(uuid,text,text,numeric) from public,anon;
grant execute on function public.create_unit_as_landlord(uuid,text,text,numeric) to authenticated;

create or replace function public.update_unit_as_landlord(
  p_unit_id uuid,p_label text,p_description text,p_rent_amount numeric
)
returns void
language plpgsql security definer set search_path=public
as $$
declare oid uuid;
begin
  select organization_id into oid from public.units where id=p_unit_id for update;
  if oid is null or not public.has_org_capability(oid,'create_properties') then raise exception 'Not authorized'; end if;
  if nullif(trim(p_label),'') is null then raise exception 'Unit name is required'; end if;
  if p_rent_amount is null or p_rent_amount<0 then raise exception 'Unit rent must be zero or greater'; end if;
  update public.units set label=trim(p_label),description=nullif(trim(p_description),''),rent_amount=p_rent_amount
  where id=p_unit_id;
  insert into public.audit_events(organization_id,actor_id,action,entity_type,entity_id,metadata)
  values(oid,auth.uid(),'unit_updated','unit',p_unit_id,'{}');
end;
$$;
revoke all on function public.update_unit_as_landlord(uuid,text,text,numeric) from public,anon;
grant execute on function public.update_unit_as_landlord(uuid,text,text,numeric) to authenticated;
