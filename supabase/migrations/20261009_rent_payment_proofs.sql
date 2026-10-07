begin;

create table if not exists public.rent_payment_submissions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  tenant_id uuid not null references auth.users(id) on delete cascade,
  payment_ids uuid[] not null check (cardinality(payment_ids) > 0),
  payment_months date[] not null check (cardinality(payment_months) > 0),
  amount numeric(14,2) not null check (amount > 0),
  receipt_path text not null,
  status text not null default 'Pending' check (status in ('Pending','Confirmed')),
  submitted_at timestamptz not null default now(),
  confirmed_by uuid references auth.users(id),
  confirmed_at timestamptz,
  check ((status = 'Pending' and confirmed_by is null and confirmed_at is null)
      or (status = 'Confirmed' and confirmed_by is not null and confirmed_at is not null))
);

create index if not exists rent_payment_submissions_org_status_idx
  on public.rent_payment_submissions(organization_id,status,submitted_at desc);
create index if not exists rent_payment_submissions_tenant_idx
  on public.rent_payment_submissions(tenant_id,submitted_at desc);

alter table public.rent_payment_submissions enable row level security;
revoke all on public.rent_payment_submissions from public,anon,authenticated;
grant select on public.rent_payment_submissions to authenticated;

drop policy if exists "Tenant and operations view rent payment submissions" on public.rent_payment_submissions;
create policy "Tenant and operations view rent payment submissions"
  on public.rent_payment_submissions for select to authenticated
  using (
    tenant_id = auth.uid()
    or exists (
      select 1 from public.organization_members om
       where om.organization_id = rent_payment_submissions.organization_id
         and om.user_id = auth.uid()
         and om.status = 'active'
         and om.role in ('landlord','manager')
    )
  );

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('rent-payment-proofs','rent-payment-proofs',false,10485760,array['image/jpeg','image/png','image/webp','image/gif'])
on conflict(id) do update set
  public=false,
  file_size_limit=excluded.file_size_limit,
  allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists "Tenants upload own rent payment proof" on storage.objects;
create policy "Tenants upload own rent payment proof"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'rent-payment-proofs'
    and (storage.foldername(name))[2] = auth.uid()::text
    and exists (
      select 1 from public.organization_members om
       where om.organization_id::text = (storage.foldername(name))[1]
         and om.user_id = auth.uid()
         and om.role = 'tenant'
         and om.status = 'active'
    )
  );

drop policy if exists "Tenant and landlord view rent payment proof" on storage.objects;
create policy "Tenant and landlord view rent payment proof"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'rent-payment-proofs'
    and (
      (storage.foldername(name))[2] = auth.uid()::text
      or exists (
        select 1 from public.organization_members om
         where om.organization_id::text = (storage.foldername(name))[1]
           and om.user_id = auth.uid()
           and om.role in ('landlord','manager')
           and om.status = 'active'
      )
    )
  );

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
  if p_payment_ids is null or cardinality(p_payment_ids) = 0 then
    raise exception 'Select at least one rent month';
  end if;
  if cardinality(p_payment_ids) > 36 then
    raise exception 'A single payment submission cannot cover more than 36 rent rows';
  end if;

  select p.organization_id into v_org_id
    from public.payments p
   where p.id = any(p_payment_ids)
   limit 1;
  if v_org_id is null then raise exception 'No selected rent records were found'; end if;

  if not exists (
    select 1 from public.organization_members om
     where om.organization_id = v_org_id and om.user_id = uid
       and om.role = 'tenant' and om.status = 'active'
  ) then raise exception 'Active tenant membership required'; end if;

  select count(*),count(distinct p.organization_id),
         coalesce(sum(greatest(p.amount_due - p.amount_paid,0)),0)
    into v_row_count,v_org_count,v_amount
    from public.payments p
   where p.id = any(p_payment_ids)
     and p.tenant_id = uid
     and p.organization_id = v_org_id
     and p.status in ('Due soon','Overdue','Partially paid');
  if v_row_count <> cardinality(p_payment_ids) or v_org_count <> 1 then
    raise exception 'Selected months must be unpaid rent records belonging to your active tenancy';
  end if;
  if v_amount <= 0 then raise exception 'The selected months have no outstanding balance'; end if;

  select array_agg(month_start order by month_start)
    into v_months
    from (
      select distinct date_trunc('month',p.due_date)::date as month_start
        from public.payments p
       where p.id = any(p_payment_ids)
    ) selected_months;
  select array_agg(p.id order by p.due_date,p.id)
    into v_sorted_ids
    from public.payments p
   where p.id = any(p_payment_ids);

  if p_receipt_path is null
     or p_receipt_path !~ ('^' || v_org_id::text || '/' || uid::text || '/[^/]+$') then
    raise exception 'Invalid payment proof path';
  end if;
  if not exists (
    select 1 from storage.objects o
     where o.bucket_id = 'rent-payment-proofs'
       and o.name = p_receipt_path
       and o.owner_id::text = uid::text
  ) then raise exception 'Upload the payment proof before submitting it'; end if;

  if exists (
    select 1 from public.rent_payment_submissions s
     where s.status = 'Pending' and s.payment_ids && v_sorted_ids
  ) then raise exception 'One or more selected months are already awaiting landlord confirmation'; end if;

  insert into public.rent_payment_submissions(
    organization_id,tenant_id,payment_ids,payment_months,amount,receipt_path
  ) values (v_org_id,uid,v_sorted_ids,v_months,v_amount,p_receipt_path)
  returning id into v_submission_id;

  update public.payments p
     set status='Pending review',receipt_path=p_receipt_path,method=coalesce(nullif(p.method,''),'Bank transfer'),updated_at=now()
   where p.id = any(v_sorted_ids)
     and p.tenant_id = uid
     and p.organization_id = v_org_id
     and p.status in ('Due soon','Overdue','Partially paid');

  return v_submission_id;
end;
$$;

create or replace function public.confirm_rent_payment_submission(p_submission_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  submission public.rent_payment_submissions%rowtype;
  changed integer;
begin
  if uid is null then raise exception 'Not authenticated'; end if;

  select * into submission
    from public.rent_payment_submissions
   where id = p_submission_id
   for update;
  if not found then raise exception 'Payment submission not found'; end if;
  if not exists (
    select 1 from public.organization_members om
     where om.organization_id = submission.organization_id
       and om.user_id = uid and om.role = 'landlord' and om.status = 'active'
  ) then raise exception 'Only the active landlord can confirm this payment'; end if;
  if submission.status <> 'Pending' then raise exception 'This payment has already been confirmed'; end if;

  update public.payments p
     set status='Paid',amount_paid=p.amount_due,verified_by=uid,verified_at=now(),updated_at=now()
   where p.id = any(submission.payment_ids)
     and p.organization_id = submission.organization_id
     and p.tenant_id = submission.tenant_id
     and p.status = 'Pending review'
     and p.receipt_path = submission.receipt_path;
  get diagnostics changed = row_count;
  if changed <> cardinality(submission.payment_ids) then
    raise exception 'Some rent rows no longer match this pending payment submission';
  end if;

  update public.rent_payment_submissions
     set status='Confirmed',confirmed_by=uid,confirmed_at=now()
   where id=p_submission_id;
end;
$$;

revoke all on function public.submit_rent_payment_evidence(uuid[],text) from public,anon;
revoke all on function public.confirm_rent_payment_submission(uuid) from public,anon;
grant execute on function public.submit_rent_payment_evidence(uuid[],text) to authenticated;
grant execute on function public.confirm_rent_payment_submission(uuid) to authenticated;

commit;
