begin;

alter table public.rent_payment_submissions
  add column if not exists rejected_by uuid references auth.users(id),
  add column if not exists rejected_at timestamptz,
  add column if not exists rejection_note text;

alter table public.rent_payment_submissions
  drop constraint if exists rent_payment_submissions_status_check;
alter table public.rent_payment_submissions
  add constraint rent_payment_submissions_status_check
  check (status in ('Pending','Confirmed','Rejected'));

-- Replace the original two-state decision invariant while keeping existing
-- Pending and Confirmed rows valid and making every rejection attributable.
alter table public.rent_payment_submissions
  drop constraint if exists rent_payment_submissions_check;
alter table public.rent_payment_submissions
  drop constraint if exists rent_payment_submissions_decision_state_check;
alter table public.rent_payment_submissions
  add constraint rent_payment_submissions_decision_state_check check (
    (status='Pending'
      and confirmed_by is null and confirmed_at is null
      and rejected_by is null and rejected_at is null and rejection_note is null)
    or
    (status='Confirmed'
      and confirmed_by is not null and confirmed_at is not null
      and rejected_by is null and rejected_at is null and rejection_note is null)
    or
    (status='Rejected'
      and confirmed_by is null and confirmed_at is null
      and rejected_by is not null and rejected_at is not null
      and nullif(trim(rejection_note),'') is not null)
  );

create or replace function public.reject_rent_payment_submission(
  p_submission_id uuid,
  p_note text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  submission public.rent_payment_submissions%rowtype;
  note_text text := nullif(trim(coalesce(p_note,'')),'');
  changed integer;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if note_text is null then raise exception 'A rejection reason is required'; end if;
  if length(note_text) > 1000 then raise exception 'Rejection reasons must be 1000 characters or fewer'; end if;

  select * into submission
    from public.rent_payment_submissions
   where id = p_submission_id
   for update;
  if not found then raise exception 'Payment submission not found'; end if;
  if not exists (
    select 1 from public.organization_members om
     where om.organization_id = submission.organization_id
       and om.user_id = uid and om.role = 'landlord' and om.status = 'active'
  ) then raise exception 'Only the active landlord can reject this payment'; end if;
  if submission.status <> 'Pending' then raise exception 'Only pending submissions can be rejected'; end if;

  update public.payments p
     set status=case
           when p.amount_paid > 0 then 'Partially paid'
           when p.due_date < current_date then 'Overdue'
           else 'Due soon'
         end,
         receipt_path=null,
         updated_at=now()
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
     set status='Rejected',rejected_by=uid,rejected_at=now(),rejection_note=note_text
   where id=p_submission_id;
end;
$$;

revoke all on function public.reject_rent_payment_submission(uuid,text) from public,anon;
grant execute on function public.reject_rent_payment_submission(uuid,text) to authenticated;

notify pgrst, 'reload schema';

commit;
