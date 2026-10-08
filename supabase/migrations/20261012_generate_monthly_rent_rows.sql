begin;

-- Populate the payments table from each monthly tenancy. Rent is due on the
-- same day-of-month as the tenancy start (clamped to month-end, e.g. the 31st
-- becomes the 28th/29th in February). Rows are generated through a rolling
-- 12-month horizon so tenants can select advance-payment months too.
create or replace function public.generate_monthly_rent_rows(p_tenancy_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  tenancy public.tenancies%rowtype;
  last_billable_date date;
  horizon_date date := (current_date + interval '12 months')::date;
  first_month date;
  last_month date;
  month_start date;
  due_day integer;
  due_on date;
  inserted_count integer := 0;
  inserted_this_month integer := 0;
begin
  select * into tenancy
    from public.tenancies
   where id = p_tenancy_id
   for update;
  if not found then return 0; end if;
  if tenancy.frequency <> 'monthly'
     or tenancy.status not in ('active','move_out_requested','ended') then
    return 0;
  end if;

  last_billable_date := case
    when tenancy.status='ended' then least(current_date,coalesce(tenancy.end_date,current_date))
    when tenancy.status='move_out_requested' then least(horizon_date,coalesce(tenancy.requested_move_out_date,current_date))
    else least(horizon_date,coalesce(tenancy.end_date,horizon_date))
  end;
  if last_billable_date < tenancy.start_date then return 0; end if;

  first_month := date_trunc('month',tenancy.start_date)::date;
  last_month := date_trunc('month',last_billable_date)::date;

  for month_start in
    select series_month::date
      from generate_series(first_month::timestamp,last_month::timestamp,interval '1 month') as series_month
  loop
    due_day := least(
      extract(day from tenancy.start_date)::integer,
      extract(day from (month_start + interval '1 month - 1 day'))::integer
    );
    due_on := month_start + (due_day - 1);
    if due_on < tenancy.start_date or due_on > last_billable_date then
      continue;
    end if;

    insert into public.payments(
      organization_id,tenancy_id,tenant_id,due_date,amount_due,amount_paid,status
    )
    select tenancy.organization_id,tenancy.id,tenancy.tenant_id,due_on,
           tenancy.rent_amount,0,
           case when due_on < current_date then 'Overdue' else 'Due soon' end
     where not exists (
       select 1 from public.payments existing
        where existing.tenancy_id=tenancy.id
          and existing.due_date >= month_start
          and existing.due_date < (month_start + interval '1 month')::date
     );
    get diagnostics inserted_this_month = row_count;
    inserted_count := inserted_count + inserted_this_month;
  end loop;

  -- Bring older unpaid rows up to date when this idempotent generator runs.
  update public.payments
     set status='Overdue',updated_at=now()
   where tenancy_id=tenancy.id and status='Due soon' and due_date < current_date;

  return inserted_count;
end;
$$;

revoke all on function public.generate_monthly_rent_rows(uuid) from public,anon,authenticated;

create or replace function public.sync_monthly_rent_rows_for_tenancy()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.generate_monthly_rent_rows(new.id);
  return new;
end;
$$;

revoke all on function public.sync_monthly_rent_rows_for_tenancy() from public,anon,authenticated;
drop trigger if exists tenancies_generate_monthly_rent_rows on public.tenancies;
create trigger tenancies_generate_monthly_rent_rows
  after insert or update of start_date,end_date,requested_move_out_date,rent_amount,frequency,status
  on public.tenancies
  for each row execute function public.sync_monthly_rent_rows_for_tenancy();

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
    select distinct t.id
      from public.tenancies t
      join public.organization_members om
        on om.organization_id=t.organization_id
       and om.status='active'
     where t.status in ('active','move_out_requested','ended')
       and t.frequency='monthly'
       and (
         (om.user_id=uid and om.role='tenant' and t.tenant_id=uid)
         or (om.user_id=uid and om.role in ('landlord','manager'))
       )
  loop
    inserted_count := inserted_count + public.generate_monthly_rent_rows(tenancy_id);
  end loop;
  return inserted_count;
end;
$$;

revoke all on function public.ensure_my_rent_payment_schedule() from public,anon;
grant execute on function public.ensure_my_rent_payment_schedule() to authenticated;

-- Backfill previously assigned monthly tenancies so current tenants have
-- selectable month rows immediately after this migration is applied.
do $$
declare tenancy_id uuid;
begin
  for tenancy_id in
    select id from public.tenancies
     where frequency='monthly' and status in ('active','move_out_requested','ended')
     order by start_date
  loop
    perform public.generate_monthly_rent_rows(tenancy_id);
  end loop;
end;
$$;

notify pgrst, 'reload schema';

commit;
