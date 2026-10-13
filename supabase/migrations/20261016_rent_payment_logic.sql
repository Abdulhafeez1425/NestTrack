begin;

-- Rent-period statuses are intentionally kept on the ledger, while receipt
-- review status remains on rent_payment_submissions.
alter table public.payments drop constraint if exists payments_status_check;
alter table public.payments add constraint payments_status_check check (status in (
  'Outstanding','Receipt Submitted','Under Review','Confirmed','Rejected',
  'Partially Paid','Overdue','Due Soon','Advance Payment','Refunded',
  'Due soon','Pending review','Paid','Overdue','Partially paid','Waived'
));

alter table public.rent_payment_submissions
  add column if not exists rent_period date,
  add column if not exists payment_date date,
  add column if not exists property_id uuid references public.properties(id) on delete set null,
  add column if not exists unit_id uuid references public.units(id) on delete set null,
  add column if not exists confirmed_amount numeric(14,2),
  add column if not exists reviewer_id uuid references auth.users(id) on delete set null;

update public.rent_payment_submissions s
   set rent_period = coalesce(s.rent_period, s.payment_months[1]),
       payment_date = coalesce(s.payment_date, s.submitted_at::date),
       confirmed_amount = coalesce(s.confirmed_amount, case when s.status='Confirmed' then s.amount else null end),
       reviewer_id = coalesce(s.reviewer_id, s.confirmed_by, s.rejected_by)
 where s.rent_period is null or s.payment_date is null or s.reviewer_id is null;

create index if not exists rent_payment_submissions_period_idx
  on public.rent_payment_submissions(tenant_id, rent_period, status);

create table if not exists public.rent_payment_status_history (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  tenant_id uuid not null references auth.users(id) on delete cascade,
  payment_id uuid references public.payments(id) on delete cascade,
  submission_id uuid references public.rent_payment_submissions(id) on delete cascade,
  rent_period date not null,
  entity_type text not null check (entity_type in ('rent_period','receipt')),
  from_status text,
  to_status text not null,
  amount numeric(14,2),
  reason text,
  actor_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists rent_payment_status_history_period_idx
  on public.rent_payment_status_history(tenant_id, rent_period, created_at desc);

alter table public.rent_payment_status_history enable row level security;
revoke all on public.rent_payment_status_history from public, anon, authenticated;
grant select on public.rent_payment_status_history to authenticated;
drop policy if exists "Rent status history visible to tenant and operations" on public.rent_payment_status_history;
create policy "Rent status history visible to tenant and operations"
  on public.rent_payment_status_history for select to authenticated
  using (
    tenant_id = auth.uid() or exists (
      select 1 from public.organization_members om
      where om.organization_id = rent_payment_status_history.organization_id
        and om.user_id = auth.uid() and om.status = 'active'
        and om.role in ('landlord','manager')
    ) or exists (select 1 from public.platform_admins pa where pa.id = auth.uid())
  );

-- New receipt submission contract: one rent period, explicit amount and
-- payment date. A rejected receipt does not reserve a period; confirmed
-- receipts can be repeated for legitimate instalments.
create or replace function public.submit_rent_payment_evidence(
  p_payment_ids uuid[], p_receipt_path text, p_amount numeric, p_payment_date date
)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  payment_row public.payments%rowtype;
  submission_id uuid;
  reserved numeric(14,2);
  available numeric(14,2);
  month_start date;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_payment_ids is null or cardinality(p_payment_ids) <> 1 then
    raise exception 'Select exactly one rent month';
  end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Payment amount must be greater than zero'; end if;
  if p_payment_date is null then raise exception 'Payment date is required'; end if;
  select * into payment_row from public.payments where id=p_payment_ids[1] for update;
  if not found or payment_row.tenant_id <> uid then raise exception 'Rent record not found for this tenant'; end if;
  if not exists (select 1 from public.organization_members om where om.organization_id=payment_row.organization_id and om.user_id=uid and om.role='tenant' and om.status='active') then raise exception 'Active tenant membership required'; end if;
  if payment_row.tenancy_id is null then raise exception 'This rent record has no tenancy'; end if;
  if p_receipt_path is null or p_receipt_path !~ ('^' || payment_row.organization_id::text || '/' || uid::text || '/[^/]+$') then raise exception 'Invalid payment proof path'; end if;
  if not exists (select 1 from storage.objects o where o.bucket_id='rent-payment-proofs' and o.name=p_receipt_path and o.owner_id::text=uid::text) then raise exception 'Upload the payment proof before submitting it'; end if;
  if exists (select 1 from public.rent_payment_submissions s where s.tenant_id=uid and s.status='Pending' and s.payment_ids @> array[payment_row.id]) then raise exception 'A receipt for this rent period is already under review'; end if;
  month_start := date_trunc('month', payment_row.due_date)::date;
  select coalesce(sum(s.amount),0) into reserved from public.rent_payment_submissions s where s.tenant_id=uid and s.status='Pending' and s.payment_ids @> array[payment_row.id];
  available := greatest(payment_row.amount_due - payment_row.amount_paid - reserved,0);
  if p_amount > available then raise exception 'Amount exceeds the remaining balance for this rent period'; end if;
  insert into public.rent_payment_submissions(organization_id,tenant_id,payment_ids,payment_months,amount,receipt_path,status,rent_period,payment_date,property_id,unit_id)
  select payment_row.organization_id,uid,array[payment_row.id],array[month_start],p_amount,p_receipt_path,'Pending',month_start,p_payment_date,u.property_id,u.id
    from public.tenancies t join public.units u on u.id=t.unit_id where t.id=payment_row.tenancy_id
    returning id into submission_id;
  insert into public.rent_payment_status_history(organization_id,tenant_id,payment_id,submission_id,rent_period,entity_type,to_status,amount,actor_id)
  values(payment_row.organization_id,uid,payment_row.id,submission_id,month_start,'receipt','Under Review',p_amount,uid);
  update public.payments set status=case when due_date < current_date then 'Under Review' else 'Receipt Submitted' end,receipt_path=p_receipt_path,method=coalesce(nullif(method,''),'Bank transfer'),updated_at=now() where id=payment_row.id;
  return submission_id;
end; $$;

create or replace function public.confirm_rent_payment_submission(p_submission_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); s public.rent_payment_submissions%rowtype; p public.payments%rowtype; applied numeric(14,2); next_status text;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  select * into s from public.rent_payment_submissions where id=p_submission_id for update;
  if not found then raise exception 'Payment submission not found'; end if;
  if not (exists(select 1 from public.platform_admins where id=uid) or exists(select 1 from public.organization_members om where om.organization_id=s.organization_id and om.user_id=uid and om.role in ('landlord','manager') and om.status='active')) then raise exception 'Only an authorized admin, landlord, or manager can confirm this payment'; end if;
  if s.status <> 'Pending' then raise exception 'This receipt has already been processed'; end if;
  select * into p from public.payments where id=s.payment_ids[1] for update;
  applied := least(s.amount, greatest(p.amount_due-p.amount_paid,0));
  if applied <= 0 then raise exception 'This rent period has no remaining balance'; end if;
  next_status := case when p.amount_paid + applied >= p.amount_due then (case when p.due_date > current_date then 'Advance Payment' else 'Confirmed' end) else 'Partially Paid' end;
  update public.payments set amount_paid=amount_paid+applied,status=next_status,verified_by=uid,verified_at=now(),updated_at=now() where id=p.id;
  update public.rent_payment_submissions set status='Confirmed',confirmed_by=uid,confirmed_at=now(),confirmed_amount=applied,reviewer_id=uid where id=s.id;
  insert into public.rent_payment_status_history(organization_id,tenant_id,payment_id,submission_id,rent_period,entity_type,from_status,to_status,amount,actor_id)
  values(s.organization_id,s.tenant_id,p.id,s.id,coalesce(s.rent_period,date_trunc('month',p.due_date)::date),'rent_period',p.status,next_status,applied,uid);
  insert into public.rent_payment_status_history(organization_id,tenant_id,payment_id,submission_id,rent_period,entity_type,from_status,to_status,amount,actor_id)
  values(s.organization_id,s.tenant_id,p.id,s.id,coalesce(s.rent_period,date_trunc('month',p.due_date)::date),'receipt','Pending','Confirmed',applied,uid);
  insert into public.notifications(recipient_user_id,organization_id,event_type,title,body,related_entity_type,related_entity_id)
  values(s.tenant_id,s.organization_id,'rent_payment_confirmed','Rent payment approved','Your rent receipt was approved for '||to_char(coalesce(s.rent_period,date_trunc('month',p.due_date)::date),'FMMonth YYYY')||'. Confirmed amount: '||applied::text,'rent_payment_submission',s.id);
end; $$;

create or replace function public.reject_rent_payment_submission(p_submission_id uuid,p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid:=auth.uid(); s public.rent_payment_submissions%rowtype; p public.payments%rowtype; restored text;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if nullif(trim(coalesce(p_note,'')),'') is null then raise exception 'A rejection reason is required'; end if;
  select * into s from public.rent_payment_submissions where id=p_submission_id for update;
  if not found then raise exception 'Payment submission not found'; end if;
  if not (exists(select 1 from public.platform_admins where id=uid) or exists(select 1 from public.organization_members om where om.organization_id=s.organization_id and om.user_id=uid and om.role in ('landlord','manager') and om.status='active')) then raise exception 'Only an authorized admin, landlord, or manager can reject this payment'; end if;
  if s.status <> 'Pending' then raise exception 'Only receipts under review can be rejected'; end if;
  select * into p from public.payments where id=s.payment_ids[1] for update;
  restored := case when p.amount_paid>0 then 'Partially Paid' when p.due_date<current_date then 'Overdue' else 'Due Soon' end;
  update public.payments set status=restored,receipt_path=null,updated_at=now() where id=p.id;
  update public.rent_payment_submissions set status='Rejected',rejected_by=uid,rejected_at=now(),rejection_note=trim(p_note),reviewer_id=uid where id=s.id;
  insert into public.rent_payment_status_history(organization_id,tenant_id,payment_id,submission_id,rent_period,entity_type,from_status,to_status,reason,actor_id)
  values(s.organization_id,s.tenant_id,p.id,s.id,coalesce(s.rent_period,date_trunc('month',p.due_date)::date),'receipt','Pending','Rejected',trim(p_note),uid);
  insert into public.notifications(recipient_user_id,organization_id,event_type,title,body,related_entity_type,related_entity_id)
  values(s.tenant_id,s.organization_id,'rent_payment_rejected','Rent payment needs attention','Your rent receipt was rejected for '||to_char(coalesce(s.rent_period,date_trunc('month',p.due_date)::date),'FMMonth YYYY')||'. Reason: '||trim(p_note),'rent_payment_submission',s.id);
end; $$;

revoke all on function public.submit_rent_payment_evidence(uuid[],text,numeric,date) from public,anon;
grant execute on function public.submit_rent_payment_evidence(uuid[],text,numeric,date) to authenticated;
revoke all on function public.confirm_rent_payment_submission(uuid) from public,anon;
grant execute on function public.confirm_rent_payment_submission(uuid) to authenticated;
revoke all on function public.reject_rent_payment_submission(uuid,text) from public,anon;
grant execute on function public.reject_rent_payment_submission(uuid,text) to authenticated;
notify pgrst,'reload schema';
commit;
