begin;

-- Limit the discoverable directory to self, active coworkers in shared
-- organizations, and platform administrators. Platform admins still need the
-- complete directory for the admin dashboard.
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
  organization_name text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select p.id, p.full_name, p.email, p.phone, p.occupation, p.avatar_url, p.role,
         om.organization_id, o.name, p.created_at
  from public.profiles p
  left join public.organization_members om on om.user_id=p.id and om.status='active'
  left join public.organizations o on o.id=om.organization_id
  where auth.uid() is not null
    and (
      p.id=auth.uid()
      or public.is_platform_admin()
      or exists (
        select 1
        from public.organization_members viewer
        join public.organization_members target on target.organization_id=viewer.organization_id
        where viewer.user_id=auth.uid() and viewer.status='active'
          and target.user_id=p.id and target.status='active'
      )
    )
  order by p.full_name;
$$;
revoke all on function public.get_user_directory() from public,anon;
grant execute on function public.get_user_directory() to authenticated;

-- Serialize submissions per selected rent row before checking pending evidence.
-- A second concurrent call waits for the first, then sees Pending review and is
-- rejected rather than creating overlapping submission records.
create or replace function public.submit_rent_payment_evidence(
  p_payment_ids uuid[],
  p_receipt_path text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_org_id uuid;
  v_submission_id uuid;
  v_row_count integer;
  v_org_count integer;
  v_amount numeric(14,2);
  v_months date[];
  v_sorted_ids uuid[];
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_payment_ids is null or cardinality(p_payment_ids)=0 then raise exception 'Select at least one rent month'; end if;
  if cardinality(p_payment_ids)>36 then raise exception 'A single payment submission cannot cover more than 36 rent rows'; end if;

  perform p.id
    from public.payments p
   where p.id=any(p_payment_ids)
   order by p.id
   for update;

  select p.organization_id into v_org_id
    from public.payments p where p.id=any(p_payment_ids) limit 1;
  if v_org_id is null then raise exception 'No selected rent records were found'; end if;
  if not exists (
    select 1 from public.organization_members om
    where om.organization_id=v_org_id and om.user_id=uid
      and om.role='tenant' and om.status='active'
  ) then raise exception 'Active tenant membership required'; end if;

  select count(*),count(distinct p.organization_id),
         coalesce(sum(greatest(p.amount_due-p.amount_paid,0)),0)
    into v_row_count,v_org_count,v_amount
    from public.payments p
   where p.id=any(p_payment_ids) and p.tenant_id=uid and p.organization_id=v_org_id
     and p.status in ('Due soon','Overdue','Partially paid');
  if v_row_count<>cardinality(p_payment_ids) or v_org_count<>1 then
    raise exception 'Selected months must be unpaid rent records belonging to your active tenancy';
  end if;
  if v_amount<=0 then raise exception 'The selected months have no outstanding balance'; end if;

  select array_agg(month_start order by month_start) into v_months
    from (select distinct date_trunc('month',p.due_date)::date as month_start
          from public.payments p where p.id=any(p_payment_ids)) selected_months;
  select array_agg(p.id order by p.due_date,p.id) into v_sorted_ids
    from public.payments p where p.id=any(p_payment_ids);

  if p_receipt_path is null or p_receipt_path !~ ('^'||v_org_id::text||'/'||uid::text||'/[^/]+$') then
    raise exception 'Invalid payment proof path';
  end if;
  if not exists (
    select 1 from storage.objects o where o.bucket_id='rent-payment-proofs'
      and o.name=p_receipt_path and o.owner_id::text=uid::text
  ) then raise exception 'Upload the payment proof before submitting it'; end if;
  if exists (
    select 1 from public.rent_payment_submissions s
    where s.status='Pending' and s.payment_ids && v_sorted_ids
  ) then raise exception 'One or more selected months are already awaiting landlord confirmation'; end if;

  insert into public.rent_payment_submissions(organization_id,tenant_id,payment_ids,payment_months,amount,receipt_path)
  values(v_org_id,uid,v_sorted_ids,v_months,v_amount,p_receipt_path)
  returning id into v_submission_id;
  update public.payments p set status='Pending review',receipt_path=p_receipt_path,
    method=coalesce(nullif(p.method,''),'Bank transfer'),updated_at=now()
  where p.id=any(v_sorted_ids) and p.tenant_id=uid and p.organization_id=v_org_id
    and p.status in ('Due soon','Overdue','Partially paid');
  return v_submission_id;
end;
$$;
revoke all on function public.submit_rent_payment_evidence(uuid[],text) from public,anon;
grant execute on function public.submit_rent_payment_evidence(uuid[],text) to authenticated;

-- Reconcile the pre-generated rolling rent schedule after tenancy changes.
-- Paid/pending and partially-paid rows are deliberately never rewritten.
create or replace function public.reconcile_monthly_rent_rows(p_tenancy_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  tenancy public.tenancies%rowtype;
  last_billable_date date;
  changed_count integer := 0;
begin
  select * into tenancy from public.tenancies where id=p_tenancy_id;
  if not found or tenancy.frequency<>'monthly' then return 0; end if;
  last_billable_date:=case
    when tenancy.status='ended' then least(current_date,coalesce(tenancy.end_date,current_date))
    when tenancy.status='move_out_requested' then least(current_date+interval '12 months',coalesce(tenancy.requested_move_out_date,current_date))::date
    when tenancy.status='active' then least(current_date+interval '12 months',coalesce(tenancy.end_date,(current_date+interval '12 months')::date))::date
    else tenancy.start_date-1
  end;

  update public.payments p
     set status=case
           when p.due_date>last_billable_date then 'Waived'
           when p.due_date<current_date then 'Overdue'
           else 'Due soon'
         end,
         amount_due=case when p.due_date>=current_date then tenancy.rent_amount else p.amount_due end,
         updated_at=now()
   where p.tenancy_id=tenancy.id
     and p.amount_paid=0
     and p.status in ('Due soon','Overdue','Waived')
     and (p.due_date>last_billable_date or p.status='Waived'
          or (p.due_date>=current_date and p.amount_due is distinct from tenancy.rent_amount));
  get diagnostics changed_count=row_count;
  return changed_count;
end;
$$;
revoke all on function public.reconcile_monthly_rent_rows(uuid) from public,anon,authenticated;

create or replace function public.sync_monthly_rent_rows_for_tenancy()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.generate_monthly_rent_rows(new.id);
  perform public.reconcile_monthly_rent_rows(new.id);
  return new;
end;
$$;
revoke all on function public.sync_monthly_rent_rows_for_tenancy() from public,anon,authenticated;
drop trigger if exists tenancies_generate_monthly_rent_rows on public.tenancies;
create trigger tenancies_generate_monthly_rent_rows
  after insert or update of start_date,end_date,requested_move_out_date,rent_amount,frequency,status
  on public.tenancies for each row execute function public.sync_monthly_rent_rows_for_tenancy();

create or replace function public.ensure_my_rent_payment_schedule()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  tenancy_id uuid;
  inserted_count integer := 0;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  for tenancy_id in
    select distinct t.id from public.tenancies t
    join public.organization_members om on om.organization_id=t.organization_id and om.status='active'
    where t.status in ('active','move_out_requested','ended') and t.frequency='monthly'
      and ((om.user_id=uid and om.role='tenant' and t.tenant_id=uid)
        or (om.user_id=uid and om.role in ('landlord','manager')))
  loop
    inserted_count:=inserted_count+public.generate_monthly_rent_rows(tenancy_id);
    perform public.reconcile_monthly_rent_rows(tenancy_id);
  end loop;
  return inserted_count;
end;
$$;
revoke all on function public.ensure_my_rent_payment_schedule() from public,anon;
grant execute on function public.ensure_my_rent_payment_schedule() to authenticated;

-- Platform administrators may remove a non-admin account from the user drawer.
-- Deleting a landlord also deletes owned organizations; the UI must warn before
-- calling this RPC. Admin accounts are intentionally protected here.
create or replace function public.admin_delete_user(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  target_role text;
  org_id uuid;
begin
  if auth.uid() is null or not public.is_platform_admin() then raise exception 'Platform administrator access required'; end if;
  if p_user_id is null or p_user_id=auth.uid() then raise exception 'You cannot delete your own account from this screen'; end if;
  if exists(select 1 from public.platform_admins where id=p_user_id) then raise exception 'Platform administrator accounts cannot be deleted here'; end if;
  select role into target_role from public.profiles where id=p_user_id for update;
  if target_role is null then raise exception 'User profile not found'; end if;

  if target_role='landlord' then
    for org_id in select organization_id from public.organization_members where user_id=p_user_id and role='landlord' loop
      update public.organizations set created_by=null where id=org_id;
      delete from public.organizations where id=org_id;
    end loop;
  elsif target_role='tenant' then
    update public.tenancies set status='ended',end_date=current_date
      where tenant_id=p_user_id and status in ('active','move_out_requested');
    update public.units set status='vacant',current_tenant_id=null where current_tenant_id=p_user_id;
  end if;

  update public.maintenance_tickets set assigned_to=null,updated_at=now() where assigned_to=p_user_id;
  update public.properties set manager_id=null where manager_id=p_user_id;
  delete from auth.users where id=p_user_id;
end;
$$;
revoke all on function public.admin_delete_user(uuid) from public,anon;
grant execute on function public.admin_delete_user(uuid) to authenticated;

notify pgrst, 'reload schema';
commit;
