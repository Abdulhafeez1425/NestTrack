begin;

-- Keep a receipt's review state separate from the underlying rent-period balance.
-- New submissions target exactly one scheduled rent row; a later receipt for the
-- same row is allowed after the first has been confirmed or rejected.
alter table public.rent_payment_submissions
  add column if not exists payment_date date,
  add column if not exists rent_period date,
  add column if not exists property_id uuid references public.properties(id) on delete set null,
  add column if not exists unit_id uuid references public.units(id) on delete set null,
  add column if not exists confirmed_amount numeric(14,2),
  add column if not exists refunded_amount numeric(14,2) not null default 0;

update public.rent_payment_submissions s
   set payment_date=coalesce(s.payment_date,s.submitted_at::date),
       rent_period=coalesce(s.rent_period,s.payment_months[1]),
       confirmed_amount=case when s.status in ('Confirmed','Refunded') then coalesce(s.confirmed_amount,s.amount) else s.confirmed_amount end
 where s.payment_date is null or s.rent_period is null
    or (s.status in ('Confirmed','Refunded') and s.confirmed_amount is null);

update public.rent_payment_submissions s
   set unit_id=t.unit_id, property_id=u.property_id
  from public.payments p
  join public.tenancies t on t.id=p.tenancy_id
  join public.units u on u.id=t.unit_id
 where p.id=s.payment_ids[1]
   and (s.unit_id is null or s.property_id is null);

alter table public.rent_payment_submissions
  drop constraint if exists rent_payment_submissions_status_check;
alter table public.rent_payment_submissions
  add constraint rent_payment_submissions_status_check
  check (status in ('Pending','Confirmed','Rejected','Refunded'));

alter table public.rent_payment_submissions
  drop constraint if exists rent_payment_submissions_decision_state_check;
alter table public.rent_payment_submissions
  add constraint rent_payment_submissions_decision_state_check check (
    (status='Pending'
      and confirmed_by is null and confirmed_at is null and confirmed_amount is null
      and rejected_by is null and rejected_at is null and rejection_note is null
      and refunded_amount=0)
    or
    (status='Confirmed'
      and confirmed_by is not null and confirmed_at is not null
      and confirmed_amount > 0 and refunded_amount >= 0 and refunded_amount < confirmed_amount
      and rejected_by is null and rejected_at is null and rejection_note is null)
    or
    (status='Refunded'
      and confirmed_by is not null and confirmed_at is not null
      and confirmed_amount > 0 and refunded_amount=confirmed_amount
      and rejected_by is null and rejected_at is null and rejection_note is null)
    or
    (status='Rejected'
      and confirmed_by is null and confirmed_at is null and confirmed_amount is null
      and rejected_by is not null and rejected_at is not null
      and nullif(trim(rejection_note),'') is not null and refunded_amount=0)
  );

-- Monthly schedule generation also locks each tenancy; this unique expression
-- index is the final database guard against duplicate rent rows for one period.
do $$
begin
  if exists (
    select 1 from public.payments
     where tenancy_id is not null
     group by tenancy_id,date_trunc('month',due_date::timestamp)
    having count(*)>1
  ) then
    raise exception 'Duplicate tenancy/month rent rows exist; reconcile those ledger rows before applying this migration';
  end if;
end;
$$;
create unique index if not exists payments_tenancy_rent_period_unique_idx
  on public.payments(tenancy_id,(date_trunc('month',due_date::timestamp)))
  where tenancy_id is not null;

create index if not exists rent_payment_submissions_period_idx
  on public.rent_payment_submissions(tenant_id,rent_period,submitted_at desc);
create index if not exists rent_payment_submissions_property_unit_idx
  on public.rent_payment_submissions(property_id,unit_id,submitted_at desc);

-- Previous releases stored receipt review as payments.status='Pending review'.
-- Restore the actual rent-period state; receipt review now lives on submissions.
update public.payments p
   set status=case
       when p.amount_paid >= p.amount_due then 'Paid'
       when p.amount_paid > 0 then 'Partially paid'
       when p.due_date < current_date then 'Overdue'
       else 'Due soon'
     end,
     updated_at=now()
 where p.status='Pending review';

create table if not exists public.rent_payment_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  tenant_id uuid references auth.users(id) on delete set null,
  payment_id uuid references public.payments(id) on delete set null,
  submission_id uuid references public.rent_payment_submissions(id) on delete set null,
  actor_id uuid references auth.users(id) on delete set null,
  event_type text not null check (event_type in (
    'receipt_submitted','receipt_confirmed','receipt_rejected','receipt_refunded','rent_period_status_changed'
  )),
  rent_period date,
  amount numeric(14,2) not null default 0,
  old_status text,
  new_status text,
  details text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists rent_payment_events_tenant_time_idx
  on public.rent_payment_events(tenant_id,created_at desc);
create index if not exists rent_payment_events_payment_time_idx
  on public.rent_payment_events(payment_id,created_at desc);

alter table public.rent_payment_events enable row level security;
revoke all on public.rent_payment_events from public,anon,authenticated;
grant select on public.rent_payment_events to authenticated;
drop policy if exists "Rent payment participants read history" on public.rent_payment_events;
create policy "Rent payment participants read history"
  on public.rent_payment_events for select to authenticated
  using (
    tenant_id=auth.uid()
    or public.is_platform_admin()
    or exists (
      select 1 from public.organization_members om
       where om.organization_id=rent_payment_events.organization_id
         and om.user_id=auth.uid() and om.status='active'
         and om.role in ('landlord','manager')
    )
  );

-- Platform administrators may review rent evidence too. Receipts remain private.
drop policy if exists "Tenant and operations view rent payment submissions" on public.rent_payment_submissions;
create policy "Tenant and operations view rent payment submissions"
  on public.rent_payment_submissions for select to authenticated
  using (
    tenant_id=auth.uid()
    or public.is_platform_admin()
    or exists (
      select 1 from public.organization_members om
       where om.organization_id=rent_payment_submissions.organization_id
         and om.user_id=auth.uid() and om.status='active'
         and om.role in ('landlord','manager')
    )
  );

drop policy if exists "Tenant and landlord view rent payment proof" on storage.objects;
create policy "Tenant and landlord view rent payment proof"
  on storage.objects for select to authenticated
  using (
    bucket_id='rent-payment-proofs'
    and (
      (storage.foldername(name))[2]=auth.uid()::text
      or public.is_platform_admin()
      or exists (
        select 1 from public.organization_members om
         where om.organization_id::text=(storage.foldername(name))[1]
           and om.user_id=auth.uid() and om.role in ('landlord','manager')
           and om.status='active'
      )
    )
  );

-- Do not change a rent period's balance while its receipt is being reviewed.
-- Once rejected, ordinary reconciliation may safely update it; after partial or
-- full confirmation, the recorded allocation and due amount remain auditable.
create or replace function public.reconcile_monthly_rent_rows(p_tenancy_id uuid)
returns integer
language plpgsql
security definer
set search_path=public
as $$
declare
  tenancy public.tenancies%rowtype;
  last_billable_date date;
  changed_count integer:=0;
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
     set status=case when p.due_date>last_billable_date then 'Waived'
                     when p.due_date<current_date then 'Overdue' else 'Due soon' end,
         amount_due=case when p.due_date>=current_date then tenancy.rent_amount else p.amount_due end,
         updated_at=now()
   where p.tenancy_id=tenancy.id and p.amount_paid=0
     and p.status in ('Due soon','Overdue','Waived')
     and (p.due_date>last_billable_date or p.status='Waived'
          or (p.due_date>=current_date and p.amount_due is distinct from tenancy.rent_amount))
     and not exists (
       select 1 from public.rent_payment_submissions s
        where s.status='Pending' and s.payment_ids @> array[p.id]
     );
  get diagnostics changed_count=row_count;
  return changed_count;
end;
$$;
revoke all on function public.reconcile_monthly_rent_rows(uuid) from public,anon,authenticated;

-- Receipt submissions are append-only evidence. The rent period remains
-- Outstanding/Overdue/Partially paid until an authorized reviewer confirms an
-- amount. Row locks serialize submissions and confirmations per rent period.
create or replace function public.submit_rent_payment_evidence(
  p_payment_id uuid,
  p_amount numeric,
  p_payment_date date,
  p_receipt_path text
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  uid uuid:=auth.uid();
  payment_row public.payments%rowtype;
  tenancy_row public.tenancies%rowtype;
  unit_row public.units%rowtype;
  submission_id uuid;
  outstanding numeric(14,2);
  period_start date;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_payment_id is null then raise exception 'Select a rent month'; end if;
  if p_amount is null or p_amount<=0 then raise exception 'Enter a payment amount greater than zero'; end if;
  if p_payment_date is null or p_payment_date>current_date then raise exception 'Enter a valid payment date no later than today'; end if;
  if p_receipt_path is null then raise exception 'A receipt image is required'; end if;

  select * into payment_row from public.payments where id=p_payment_id for update;
  if not found or payment_row.tenant_id is distinct from uid then
    raise exception 'Selected rent period does not belong to your account';
  end if;
  if not exists (
    select 1 from public.organization_members om
     where om.organization_id=payment_row.organization_id and om.user_id=uid
       and om.role='tenant' and om.status='active'
  ) then raise exception 'Active tenant membership required'; end if;

  select * into tenancy_row from public.tenancies where id=payment_row.tenancy_id;
  if not found or tenancy_row.tenant_id is distinct from uid
     or tenancy_row.organization_id is distinct from payment_row.organization_id then
    raise exception 'The tenancy for this rent period could not be verified';
  end if;
  select * into unit_row from public.units where id=tenancy_row.unit_id;
  if not found then raise exception 'A valid property unit is required'; end if;

  if payment_row.status='Waived' or payment_row.amount_due<=payment_row.amount_paid then
    raise exception 'This rent period has no outstanding balance';
  end if;
  if payment_row.due_date>(current_date+interval '12 months')::date then
    raise exception 'Advance payment is available only for scheduled rent within the next 12 months';
  end if;
  outstanding:=payment_row.amount_due-payment_row.amount_paid;
  if p_amount>outstanding then raise exception 'Payment amount exceeds the selected month''s outstanding balance'; end if;
  if p_receipt_path !~ ('^'||payment_row.organization_id::text||'/'||uid::text||'/[^/]+$') then
    raise exception 'Invalid payment proof path';
  end if;
  if not exists (
    select 1 from storage.objects o where o.bucket_id='rent-payment-proofs'
      and o.name=p_receipt_path and o.owner_id::text=uid::text
  ) then raise exception 'Upload the payment proof before submitting it'; end if;
  if exists (
    select 1 from public.rent_payment_submissions s
     where s.status='Pending' and s.payment_ids @> array[p_payment_id]
  ) then raise exception 'A receipt for this rent month is already under review'; end if;

  period_start:=date_trunc('month',payment_row.due_date)::date;
  insert into public.rent_payment_submissions(
    organization_id,tenant_id,payment_ids,payment_months,amount,receipt_path,
    payment_date,rent_period,property_id,unit_id
  ) values (
    payment_row.organization_id,uid,array[p_payment_id],array[period_start],p_amount,p_receipt_path,
    p_payment_date,period_start,unit_row.property_id,unit_row.id
  ) returning id into submission_id;

  insert into public.rent_payment_events(
    organization_id,tenant_id,payment_id,submission_id,actor_id,event_type,
    rent_period,amount,old_status,new_status,metadata
  ) values (
    payment_row.organization_id,uid,payment_row.id,submission_id,uid,'receipt_submitted',
    period_start,p_amount,payment_row.status,'Under Review',
    jsonb_build_object('payment_date',p_payment_date,'property_id',unit_row.property_id,'unit_id',unit_row.id,'receipt_path',p_receipt_path)
  );

  insert into public.notifications(recipient_user_id,organization_id,event_type,title,body,related_entity_type,related_entity_id)
  select distinct recipients.user_id,payment_row.organization_id,'rent_payment_submitted','Rent receipt submitted',
         'A tenant submitted rent evidence for '||to_char(period_start,'FMMonth YYYY')||'.',
         'rent_payment_submission',submission_id
    from (
      select om.user_id from public.organization_members om
       where om.organization_id=payment_row.organization_id and om.status='active'
         and om.role in ('landlord','manager')
      union
      select pa.id from public.platform_admins pa
    ) recipients;

  return submission_id;
end;
$$;

create or replace function public.confirm_rent_payment_submission(
  p_submission_id uuid,
  p_confirmed_amount numeric
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  uid uuid:=auth.uid();
  submission public.rent_payment_submissions%rowtype;
  rent_row public.payments%rowtype;
  remaining numeric(14,2);
  allocation numeric(14,2);
  approved_amount numeric(14,2):=p_confirmed_amount;
  original_status text;
  new_status text;
  allocation_count integer:=0;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  select * into submission from public.rent_payment_submissions where id=p_submission_id for update;
  if not found then raise exception 'Payment submission not found'; end if;
  if not (public.is_platform_admin() or exists (
    select 1 from public.organization_members om
     where om.organization_id=submission.organization_id and om.user_id=uid
       and om.status='active' and om.role in ('landlord','manager')
  )) then raise exception 'Only an authorized landlord, manager, or administrator can confirm rent receipts'; end if;
  if submission.status<>'Pending' then raise exception 'This receipt has already been reviewed'; end if;
  if approved_amount is null then approved_amount:=submission.amount; end if;
  if approved_amount<=0 or approved_amount>submission.amount then
    raise exception 'Confirmed amount must be greater than zero and no more than the submitted amount';
  end if;

  perform p.id from public.payments p where p.id=any(submission.payment_ids) order by p.id for update;
  if exists (
    select 1 from public.rent_payment_submissions other
     where other.id<>submission.id and other.status='Pending'
       and other.payment_ids && submission.payment_ids
  ) then raise exception 'Another receipt for one of these rent periods is under review'; end if;
  select coalesce(sum(greatest(p.amount_due-p.amount_paid,0)),0) into remaining
    from public.payments p where p.id=any(submission.payment_ids)
      and p.tenant_id=submission.tenant_id and p.organization_id=submission.organization_id
      and p.status<>'Waived';
  if remaining<approved_amount then raise exception 'Confirmed amount exceeds the rent balance still outstanding'; end if;
  if cardinality(submission.payment_ids)=1 and submission.rent_period is not null
     and date_trunc('month',(select p.due_date from public.payments p where p.id=submission.payment_ids[1]))::date<>submission.rent_period then
    raise exception 'Receipt rent period no longer matches the selected ledger month';
  end if;

  perform set_config('app.rent_payment_submission_id',submission.id::text,true);
  remaining:=approved_amount;
  for rent_row in
    select p.* from public.payments p
     where p.id=any(submission.payment_ids) and p.tenant_id=submission.tenant_id
       and p.organization_id=submission.organization_id and p.status<>'Waived'
     order by p.due_date,p.id
  loop
    exit when remaining<=0;
    allocation:=least(remaining,greatest(rent_row.amount_due-rent_row.amount_paid,0));
    if allocation<=0 then continue; end if;
    original_status:=rent_row.status;
    new_status:=case
      when rent_row.amount_paid+allocation>=rent_row.amount_due then 'Paid'
      when rent_row.due_date<current_date then 'Overdue'
      else 'Partially paid'
    end;
    update public.payments
       set amount_paid=amount_paid+allocation,status=new_status,
           method=coalesce(nullif(method,''),'Bank transfer'),
           verified_by=uid,verified_at=now(),updated_at=now()
     where id=rent_row.id;
    remaining:=remaining-allocation;
    allocation_count:=allocation_count+1;
  end loop;
  if remaining>0 then raise exception 'Confirmed amount could not be fully allocated to the selected rent period'; end if;

  update public.rent_payment_submissions
     set status='Confirmed',confirmed_by=uid,confirmed_at=now(),confirmed_amount=approved_amount
   where id=submission.id;
  insert into public.rent_payment_events(
    organization_id,tenant_id,payment_id,submission_id,actor_id,event_type,
    rent_period,amount,old_status,new_status,metadata
  ) values (
    submission.organization_id,submission.tenant_id,submission.payment_ids[1],submission.id,uid,'receipt_confirmed',
    submission.rent_period,approved_amount,'Under Review','Confirmed',
    jsonb_build_object('payment_date',submission.payment_date,'allocation_count',allocation_count)
  );
  insert into public.notifications(recipient_user_id,organization_id,event_type,title,body,related_entity_type,related_entity_id)
  values (
    submission.tenant_id,submission.organization_id,'rent_payment_confirmed','Rent receipt approved',
    'Your receipt for '||coalesce(to_char(submission.rent_period,'FMMonth YYYY'),'your rent period')||' was approved for ₦'||to_char(approved_amount,'FM999G999G990D00')||'.',
    'rent_payment_submission',submission.id
  );
end;
$$;

-- Compatibility overload for a previously deployed frontend still calling the
-- original one-argument RPC. The current UI sends the explicit reviewed amount.
create or replace function public.confirm_rent_payment_submission(p_submission_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare submitted_amount numeric(14,2);
begin
  select amount into submitted_amount from public.rent_payment_submissions where id=p_submission_id;
  if not found then raise exception 'Payment submission not found'; end if;
  perform public.confirm_rent_payment_submission(p_submission_id,submitted_amount);
end;
$$;

create or replace function public.reject_rent_payment_submission(p_submission_id uuid,p_note text)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  uid uuid:=auth.uid();
  submission public.rent_payment_submissions%rowtype;
  note_text text:=nullif(trim(coalesce(p_note,'')),'');
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if note_text is null then raise exception 'A rejection reason is required'; end if;
  if length(note_text)>1000 then raise exception 'Rejection reasons must be 1000 characters or fewer'; end if;
  select * into submission from public.rent_payment_submissions where id=p_submission_id for update;
  if not found then raise exception 'Payment submission not found'; end if;
  if not (public.is_platform_admin() or exists (
    select 1 from public.organization_members om
     where om.organization_id=submission.organization_id and om.user_id=uid
       and om.status='active' and om.role in ('landlord','manager')
  )) then raise exception 'Only an authorized landlord, manager, or administrator can reject rent receipts'; end if;
  if submission.status<>'Pending' then raise exception 'Only receipts awaiting review can be rejected'; end if;
  if exists (
    select 1 from public.rent_payment_submissions other
     where other.id<>submission.id and other.status='Pending'
       and other.payment_ids && submission.payment_ids
  ) then raise exception 'Another receipt for one of these rent periods is under review'; end if;

  update public.rent_payment_submissions
     set status='Rejected',rejected_by=uid,rejected_at=now(),rejection_note=note_text
   where id=submission.id;
  insert into public.rent_payment_events(
    organization_id,tenant_id,payment_id,submission_id,actor_id,event_type,
    rent_period,amount,old_status,new_status,details,metadata
  ) values (
    submission.organization_id,submission.tenant_id,submission.payment_ids[1],submission.id,uid,'receipt_rejected',
    submission.rent_period,submission.amount,'Under Review','Rejected',note_text,
    jsonb_build_object('payment_date',submission.payment_date,'receipt_path',submission.receipt_path)
  );
  insert into public.notifications(recipient_user_id,organization_id,event_type,title,body,related_entity_type,related_entity_id)
  values (
    submission.tenant_id,submission.organization_id,'rent_payment_rejected','Rent receipt needs attention',
    'Your receipt for '||coalesce(to_char(submission.rent_period,'FMMonth YYYY'),'your rent period')||' was rejected: '||note_text,
    'rent_payment_submission',submission.id
  );
end;
$$;

-- A refund represents an off-platform amount returned by the landlord, recorded
-- with a reason. Partial refunds reduce the ledger balance and emit negative
-- cashflow; the receipt is marked Refunded only when fully reversed.
create or replace function public.refund_rent_payment_submission(
  p_submission_id uuid,
  p_amount numeric,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  uid uuid:=auth.uid();
  submission public.rent_payment_submissions%rowtype;
  rent_row public.payments%rowtype;
  reason_text text:=nullif(trim(coalesce(p_reason,'')),'');
  available_to_refund numeric(14,2);
  new_refunded numeric(14,2);
  new_status text;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_amount is null or p_amount<=0 then raise exception 'Refund amount must be greater than zero'; end if;
  if reason_text is null then raise exception 'A refund reason is required'; end if;
  if length(reason_text)>1000 then raise exception 'Refund reasons must be 1000 characters or fewer'; end if;
  select * into submission from public.rent_payment_submissions where id=p_submission_id for update;
  if not found then raise exception 'Payment submission not found'; end if;
  if not (public.is_platform_admin() or exists (
    select 1 from public.organization_members om
     where om.organization_id=submission.organization_id and om.user_id=uid
       and om.status='active' and om.role in ('landlord','manager')
  )) then raise exception 'Only an authorized landlord, manager, or administrator can record a refund'; end if;
  if submission.status not in ('Confirmed','Refunded') or cardinality(submission.payment_ids)<>1
     or submission.confirmed_amount is null then
    raise exception 'Only a confirmed single-month receipt can be refunded';
  end if;
  available_to_refund:=submission.confirmed_amount-submission.refunded_amount;
  if p_amount>available_to_refund then raise exception 'Refund exceeds the confirmed amount not yet refunded'; end if;

  select * into rent_row from public.payments where id=submission.payment_ids[1] for update;
  if not found or rent_row.tenant_id is distinct from submission.tenant_id
     or rent_row.organization_id is distinct from submission.organization_id
     or rent_row.amount_paid<p_amount then raise exception 'The rent ledger no longer matches this refund'; end if;
  perform set_config('app.rent_payment_submission_id',submission.id::text,true);
  update public.payments
     set amount_paid=amount_paid-p_amount,
         status=case when amount_paid-p_amount<=0 then case when due_date<current_date then 'Overdue' else 'Due soon' end
                    when amount_paid-p_amount>=amount_due then 'Paid'
                    when due_date<current_date then 'Overdue' else 'Partially paid' end,
         updated_at=now()
   where id=rent_row.id;

  new_refunded:=submission.refunded_amount+p_amount;
  update public.rent_payment_submissions
     set refunded_amount=new_refunded,
         status=case when new_refunded>=confirmed_amount then 'Refunded' else 'Confirmed' end
   where id=submission.id;
  insert into public.rent_payment_events(
    organization_id,tenant_id,payment_id,submission_id,actor_id,event_type,
    rent_period,amount,old_status,new_status,details,metadata
  ) values (
    submission.organization_id,submission.tenant_id,rent_row.id,submission.id,uid,'receipt_refunded',
    submission.rent_period,p_amount,submission.status,
    case when new_refunded>=submission.confirmed_amount then 'Refunded' else 'Partially refunded' end,
    reason_text,jsonb_build_object('total_refunded',new_refunded,'confirmed_amount',submission.confirmed_amount)
  );
  insert into public.notifications(recipient_user_id,organization_id,event_type,title,body,related_entity_type,related_entity_id)
  values (
    submission.tenant_id,submission.organization_id,'rent_payment_refunded','Rent payment refund recorded',
    'A refund of ₦'||to_char(p_amount,'FM999G999G990D00')||' was recorded for '||coalesce(to_char(submission.rent_period,'FMMonth YYYY'),'your rent period')||'. '||reason_text,
    'rent_payment_submission',submission.id
  );
end;
$$;

-- Keep cashflow synchronized with every confirmed installment and refund rather
-- than waiting for a whole month to become Paid. A refund is a negative entry.
create or replace function public.record_verified_payment_cashflow()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  landlord_user uuid;
  amount_delta numeric(14,2);
  source_submission uuid;
  bank_payment_date date;
begin
  amount_delta:=coalesce(new.amount_paid,0)-coalesce(old.amount_paid,0);
  source_submission:=nullif(current_setting('app.rent_payment_submission_id',true),'')::uuid;
  if amount_delta<>0 then
    select om.user_id into landlord_user
      from public.organization_members om
     where om.organization_id=new.organization_id and om.role='landlord' and om.status='active'
     order by om.id limit 1;
    if landlord_user is not null then
      if source_submission is not null then
        select s.payment_date into bank_payment_date from public.rent_payment_submissions s where s.id=source_submission;
      else
        select s.id,s.payment_date into source_submission,bank_payment_date
          from public.rent_payment_submissions s
         where s.payment_ids @> array[new.id] and s.status in ('Pending','Confirmed','Refunded')
         order by case when s.status='Pending' then 0 else 1 end,s.submitted_at desc limit 1;
      end if;
      insert into public.cashflow_ledger(
        organization_id,landlord_id,payment_id,tenant_id,amount,type,status,method,recorded_at,metadata
      ) values (
        new.organization_id,landlord_user,new.id,new.tenant_id,amount_delta,
        case when amount_delta<0 then 'Rent refund' else 'Rent' end,'Recorded',new.method,
        now(),
        jsonb_build_object('rent_period',date_trunc('month',new.due_date)::date,'payment_date',bank_payment_date,'receipt_submission_id',source_submission,'source','rent_receipt_review')
      );
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists payments_cashflow_trigger on public.payments;
create trigger payments_cashflow_trigger
  after update of amount_paid on public.payments
  for each row execute function public.record_verified_payment_cashflow();

-- Append-only status audit for schedule/balance changes. Existing status fields
-- remain the canonical current state; this log preserves how that state changed.
create or replace function public.audit_rent_payment_period_change()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  source_submission uuid;
begin
  source_submission:=nullif(current_setting('app.rent_payment_submission_id',true),'')::uuid;
  if old.status is distinct from new.status or old.amount_paid is distinct from new.amount_paid then
    if source_submission is null then
      select s.id into source_submission
      from public.rent_payment_submissions s
     where s.payment_ids @> array[new.id]
       and s.status in ('Pending','Confirmed','Refunded')
     order by case when s.status='Pending' then 0 else 1 end,s.submitted_at desc
     limit 1;
    end if;
    insert into public.rent_payment_events(
      organization_id,tenant_id,payment_id,submission_id,actor_id,event_type,rent_period,amount,
      old_status,new_status,metadata
    ) values (
      new.organization_id,new.tenant_id,new.id,source_submission,auth.uid(),'rent_period_status_changed',
      date_trunc('month',new.due_date)::date,new.amount_paid-old.amount_paid,
      old.status,new.status,jsonb_build_object('old_amount_paid',old.amount_paid,'new_amount_paid',new.amount_paid)
    );
  end if;
  return new;
end;
$$;
drop trigger if exists payments_rent_audit_trigger on public.payments;
create trigger payments_rent_audit_trigger
  after update of status,amount_paid on public.payments
  for each row execute function public.audit_rent_payment_period_change();

-- Legacy review records are retained as audit events, including the original
-- selected-period arrays, rather than rewritten or discarded.
insert into public.rent_payment_events(
  organization_id,tenant_id,payment_id,submission_id,actor_id,event_type,
  rent_period,amount,old_status,new_status,details,metadata,created_at
)
select s.organization_id,s.tenant_id,s.payment_ids[1],s.id,
       coalesce(s.confirmed_by,s.rejected_by),
       case when s.status='Confirmed' then 'receipt_confirmed' else 'receipt_rejected' end,
       s.rent_period,s.amount,
       'Legacy review',s.status,s.rejection_note,
       jsonb_build_object('legacy_payment_ids',s.payment_ids,'legacy_payment_months',s.payment_months),
       coalesce(s.confirmed_at,s.rejected_at,s.submitted_at)
  from public.rent_payment_submissions s
 where s.status in ('Confirmed','Rejected')
   and not exists (select 1 from public.rent_payment_events e where e.submission_id=s.id);

-- New submissions use one rent row and preserve the period's actual status.
-- The old two-argument API signature (array, path) remains removed so no stale
-- caller can submit an amount inferred only by the client.
revoke all on function public.submit_rent_payment_evidence(uuid[],text) from public,anon,authenticated;
revoke all on function public.submit_rent_payment_evidence(uuid,numeric,date,text) from public,anon,authenticated;
grant execute on function public.submit_rent_payment_evidence(uuid,numeric,date,text) to authenticated;
revoke all on function public.confirm_rent_payment_submission(uuid) from public,anon,authenticated;
revoke all on function public.confirm_rent_payment_submission(uuid,numeric) from public,anon,authenticated;
grant execute on function public.confirm_rent_payment_submission(uuid) to authenticated;
grant execute on function public.confirm_rent_payment_submission(uuid,numeric) to authenticated;
revoke all on function public.reject_rent_payment_submission(uuid,text) from public,anon,authenticated;
grant execute on function public.reject_rent_payment_submission(uuid,text) to authenticated;
revoke all on function public.refund_rent_payment_submission(uuid,numeric,text) from public,anon,authenticated;
grant execute on function public.refund_rent_payment_submission(uuid,numeric,text) to authenticated;

notify pgrst,'reload schema';
commit;
