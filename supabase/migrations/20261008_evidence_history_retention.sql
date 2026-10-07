-- NestTrack: payment evidence/review and immutable message/payment history.
-- Apply once after all 20261007_* migrations. Existing databases should apply
-- this file only when it is not already recorded in their migration history.

begin;

-- Payment evidence and two-person review workflow for repair tickets.
alter table public.maintenance_tickets
  add column if not exists tenant_payment_reference text,
  add column if not exists payment_evidence_submitted_by uuid references auth.users(id),
  add column if not exists payment_evidence_submitted_at timestamptz,
  add column if not exists payment_reviewed_by uuid references auth.users(id),
  add column if not exists payment_reviewed_at timestamptz,
  add column if not exists payment_review_note text;

alter table public.maintenance_tickets
  drop constraint if exists maintenance_tickets_billing_status_check;
alter table public.maintenance_tickets
  add constraint maintenance_tickets_billing_status_check
  check (billing_status in (
    'Not billable','Quote submitted','Awaiting tenant payment',
    'Evidence submitted','Paid — technician confirmed',
    'Pending landlord review','Payment disputed','Paid — landlord verified'
  ));

create table if not exists public.ticket_payment_events (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.maintenance_tickets(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  actor_id uuid references auth.users(id) on delete set null,
  event_type text not null check (event_type in (
    'evidence_submitted','evidence_resubmitted','technician_confirmed',
    'landlord_review_approved','payment_disputed','landlord_review_rejected'
  )),
  reference text,
  amount numeric(14,2),
  note text,
  created_at timestamptz not null default now()
);
create index if not exists ticket_payment_events_ticket_created_idx
  on public.ticket_payment_events(ticket_id,created_at desc);

alter table public.ticket_payment_events enable row level security;
drop policy if exists "ticket payment events visible to participants" on public.ticket_payment_events;
create policy "ticket payment events visible to participants"
  on public.ticket_payment_events for select to authenticated
  using (
    public.is_platform_admin()
    or exists (
      select 1 from public.maintenance_tickets t
      where t.id=ticket_payment_events.ticket_id
        and (
          t.tenant_id=auth.uid()
          or t.assigned_to=auth.uid()
          or exists (
            select 1 from public.organization_members om
            where om.organization_id=t.organization_id
              and om.user_id=auth.uid()
              and om.status='active'
              and om.role in ('landlord','manager')
          )
        )
    )
  );
revoke all on public.ticket_payment_events from public,anon,authenticated;
grant select on public.ticket_payment_events to authenticated;

create or replace function public.save_org_payment_details(p_organization_id uuid,p_payment_details jsonb)
returns void language plpgsql security definer set search_path=public as $$
declare threshold numeric;
begin
  if not exists(select 1 from public.organization_members where organization_id=p_organization_id and user_id=auth.uid() and role='landlord' and status='active') then
    raise exception 'Only the landlord may change payment instructions';
  end if;
  if jsonb_typeof(p_payment_details)<>'object' then raise exception 'Payment details must be an object'; end if;
  if p_payment_details ? 'highValueThreshold' then
    if jsonb_typeof(p_payment_details->'highValueThreshold')<>'number' then raise exception 'High-value threshold must be numeric'; end if;
    threshold:=(p_payment_details->>'highValueThreshold')::numeric;
    if threshold<0 or threshold>1000000000000 then raise exception 'High-value threshold is out of range'; end if;
  end if;
  update public.organizations set settings=coalesce(settings,'{}'::jsonb)||jsonb_build_object('payment_details',p_payment_details),updated_at=now()
    where id=p_organization_id;
end; $$;
revoke all on function public.get_my_messages() from public,anon;

create or replace function public.submit_ticket_payment_evidence(
  p_ticket_id uuid, p_payment_reference text
) returns void language plpgsql security definer set search_path=public as $$
declare t public.maintenance_tickets%rowtype; was_disputed boolean;
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  if nullif(trim(p_payment_reference),'') is null or length(trim(p_payment_reference))>250 then
    raise exception 'A valid bank reference or receipt number is required';
  end if;
  select * into t from public.maintenance_tickets where id=p_ticket_id for update;
  if not found or t.tenant_id is distinct from auth.uid() then
    raise exception 'Only the tenant on this ticket may submit payment evidence';
  end if;
  if t.billing_status not in ('Awaiting tenant payment','Payment disputed') then
    raise exception 'This ticket is not awaiting payment evidence';
  end if;
  was_disputed := t.billing_status='Payment disputed';
  update public.maintenance_tickets set
    tenant_payment_reference=trim(p_payment_reference),
    payment_evidence_submitted_by=auth.uid(),payment_evidence_submitted_at=now(),
    payment_reviewed_by=null,payment_reviewed_at=null,payment_review_note=null,
    paid_confirmed_by=null,paid_confirmed_at=null,payment_reference=null,
    billing_status='Evidence submitted',updated_at=now()
  where id=p_ticket_id;
  insert into public.ticket_payment_events(ticket_id,organization_id,actor_id,event_type,reference,amount)
  values(t.id,t.organization_id,auth.uid(),case when was_disputed then 'evidence_resubmitted' else 'evidence_submitted' end,trim(p_payment_reference),t.estimated_cost);
  insert into public.notifications(recipient_user_id,organization_id,event_type,title,body,related_entity_type,related_entity_id)
  select om.user_id,t.organization_id,'payment_evidence_submitted','Repair payment evidence submitted',
    'The tenant submitted a transfer reference for review.','maintenance_ticket',t.id
  from public.organization_members om
  where om.organization_id=t.organization_id and om.status='active'
    and (om.user_id=t.assigned_to or om.role in ('landlord','manager'));
end; $$;

create or replace function public.dispute_ticket_payment(
  p_ticket_id uuid,p_note text
) returns void language plpgsql security definer set search_path=public as $$
declare t public.maintenance_tickets%rowtype;
begin
  if nullif(trim(p_note),'') is null then raise exception 'A dispute reason is required'; end if;
  select * into t from public.maintenance_tickets where id=p_ticket_id for update;
  if not found or t.tenant_id is distinct from auth.uid() then raise exception 'Only the tenant on this ticket may dispute payment'; end if;
  if t.billing_status not in ('Evidence submitted','Paid — technician confirmed','Pending landlord review') then
    raise exception 'There is no submitted payment to dispute';
  end if;
  update public.maintenance_tickets set billing_status='Payment disputed',payment_review_note=trim(p_note),
    payment_reviewed_by=null,payment_reviewed_at=null,updated_at=now() where id=p_ticket_id;
  insert into public.ticket_payment_events(ticket_id,organization_id,actor_id,event_type,reference,amount,note)
  values(t.id,t.organization_id,auth.uid(),'payment_disputed',t.tenant_payment_reference,t.estimated_cost,trim(p_note));
  insert into public.notifications(recipient_user_id,organization_id,event_type,title,body,related_entity_type,related_entity_id)
  select om.user_id,t.organization_id,'payment_disputed','Repair payment disputed',
    'The tenant reported a payment issue requiring landlord/manager review.','maintenance_ticket',t.id
  from public.organization_members om
  where om.organization_id=t.organization_id and om.status='active' and om.role in ('landlord','manager');
end; $$;

-- Technician confirmation is a first review only; large amounts require an
-- additional landlord/manager review using the organization threshold.
drop function if exists public.confirm_ticket_payment(uuid,text);
create or replace function public.confirm_ticket_payment(p_ticket_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare t public.maintenance_tickets%rowtype; threshold numeric; next_status text;
begin
  select * into t from public.maintenance_tickets where id=p_ticket_id for update;
  if not found or t.assigned_to is distinct from auth.uid() then raise exception 'Only the assigned technician may confirm payment'; end if;
  if not exists(select 1 from public.organization_members where organization_id=t.organization_id and user_id=auth.uid() and role='technician' and status='active') then
    raise exception 'Active technician membership is required';
  end if;
  if t.billing_status<>'Evidence submitted' or t.payment_evidence_submitted_at is null
      or nullif(trim(t.tenant_payment_reference),'') is null then
    raise exception 'Tenant payment evidence is required before confirmation';
  end if;
  select coalesce(nullif(settings#>>'{payment_details,highValueThreshold}','')::numeric,100000)
    into threshold from public.organizations where id=t.organization_id;
  next_status:=case when coalesce(t.estimated_cost,0)>=coalesce(threshold,100000)
    then 'Pending landlord review' else 'Paid — technician confirmed' end;
  update public.maintenance_tickets set billing_status=next_status,
    payment_reference=t.tenant_payment_reference,paid_confirmed_by=auth.uid(),paid_confirmed_at=now(),updated_at=now()
  where id=t.id;
  insert into public.ticket_payment_events(ticket_id,organization_id,actor_id,event_type,reference,amount,note)
  values(t.id,t.organization_id,auth.uid(),'technician_confirmed',t.tenant_payment_reference,t.estimated_cost,
    case when next_status='Pending landlord review' then 'Second review required: quote meets/exceeds organization threshold' else null end);
  insert into public.notifications(recipient_user_id,organization_id,event_type,title,body,related_entity_type,related_entity_id)
  select recipient,t.organization_id,'technician_payment_confirmed','Technician confirmed repair payment',
    case when next_status='Pending landlord review' then 'A second landlord/manager review is required.' else 'Payment evidence was checked by the assigned technician.' end,
    'maintenance_ticket',t.id
  from (
    select t.tenant_id as recipient
    union select om.user_id from public.organization_members om
      where om.organization_id=t.organization_id and om.status='active'
        and om.role in ('landlord','manager')
  ) recipients where recipient is not null;
end; $$;

create or replace function public.review_ticket_payment(
  p_ticket_id uuid,p_approved boolean,p_note text
) returns void language plpgsql security definer set search_path=public as $$
declare t public.maintenance_tickets%rowtype; next_status text;
begin
  if not exists(select 1 from public.organization_members where organization_id=(select organization_id from public.maintenance_tickets where id=p_ticket_id) and user_id=auth.uid() and role in ('landlord','manager') and status='active') then
    raise exception 'Only the landlord or manager may review this payment';
  end if;
  select * into t from public.maintenance_tickets where id=p_ticket_id for update;
  if not found or t.billing_status not in ('Pending landlord review','Payment disputed') then
    raise exception 'This payment is not awaiting a second review';
  end if;
  if not p_approved and nullif(trim(p_note),'') is null then raise exception 'A reason is required to keep the payment disputed'; end if;
  next_status:=case when p_approved and t.paid_confirmed_by is null then 'Evidence submitted' when p_approved then 'Paid — landlord verified' else 'Payment disputed' end;
  update public.maintenance_tickets set billing_status=next_status,
    payment_reviewed_by=auth.uid(),payment_reviewed_at=now(),payment_review_note=nullif(trim(p_note),''),updated_at=now()
  where id=t.id;
  insert into public.ticket_payment_events(ticket_id,organization_id,actor_id,event_type,reference,amount,note)
  values(t.id,t.organization_id,auth.uid(),case when p_approved then 'landlord_review_approved' else 'landlord_review_rejected' end,
    t.tenant_payment_reference,t.estimated_cost,nullif(trim(p_note),''));
  insert into public.notifications(recipient_user_id,organization_id,event_type,title,body,related_entity_type,related_entity_id)
  values(t.tenant_id,t.organization_id,'payment_reviewed',case when next_status='Paid — landlord verified' then 'Repair payment verified' when p_approved then 'Dispute resolved; technician verification is still required.' else 'Repair payment remains disputed' end,
    case when next_status='Paid — landlord verified' then 'The landlord/manager approved the payment after review.' when p_approved then 'The dispute was resolved. The assigned technician must still verify receipt.' else 'The payment requires follow-up. Review the note on the maintenance ticket.' end,
    'maintenance_ticket',t.id);
end; $$;

-- Immutable, participant-readable versions are separate from live message rows.
alter table public.messages
  add column if not exists edited_at timestamptz,
  add column if not exists deleted_at timestamptz,
  add column if not exists deleted_by uuid references auth.users(id) on delete set null;
create table if not exists public.message_history (
  id uuid primary key default gen_random_uuid(),
  message_id uuid references public.messages(id) on delete set null,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  actor_id uuid references auth.users(id) on delete set null,
  action text not null check (action in ('edited','deleted')),
  previous_body text not null,
  created_at timestamptz not null default now()
);
create index if not exists message_history_conversation_created_idx
  on public.message_history(conversation_id,created_at desc);

alter table public.message_history enable row level security;
drop policy if exists "conversation participants read message history" on public.message_history;
create policy "conversation participants read message history"
  on public.message_history for select to authenticated
  using (public.is_platform_admin() or public.is_conversation_member(conversation_id,auth.uid()));
revoke all on public.message_history from public,anon,authenticated;

-- Message mutations are RPC-only so every edit/delete is auditable and deletion
-- is soft by default. The original text is delivered only through a participant-checked history RPC.
revoke update,delete on public.messages from public,anon,authenticated;

drop function if exists public.get_my_messages();
create function public.get_my_messages()
returns table(id uuid,conversation_id uuid,sender_id uuid,body text,read_at timestamptz,created_at timestamptz,edited_at timestamptz,deleted_at timestamptz)
language sql stable security definer set search_path=public as $$
  select m.id,m.conversation_id,m.sender_id,m.body,m.read_at,m.created_at,m.edited_at,m.deleted_at
  from public.messages m
  where public.is_platform_admin() or public.is_conversation_member(m.conversation_id,auth.uid())
  order by m.created_at asc limit 1000;
$$;

create or replace function public.edit_message(p_message_id uuid,p_body text)
returns void language plpgsql security definer set search_path=public as $$
declare m public.messages%rowtype;
begin
  if nullif(trim(p_body),'') is null or length(p_body)>10000 then raise exception 'Message text must contain 1–10000 characters'; end if;
  select * into m from public.messages where id=p_message_id for update;
  if not found or m.sender_id is distinct from auth.uid() or not public.is_conversation_member(m.conversation_id,auth.uid()) then
    raise exception 'Only the message sender may edit this message';
  end if;
  if m.deleted_at is not null then raise exception 'Deleted messages cannot be edited'; end if;
  insert into public.message_history(message_id,conversation_id,actor_id,action,previous_body)
  values(m.id,m.conversation_id,auth.uid(),'edited',m.body);
  update public.messages set body=trim(p_body),edited_at=now(),updated_at=now() where id=m.id;
end; $$;

create or replace function public.soft_delete_message(p_message_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare m public.messages%rowtype;
begin
  select * into m from public.messages where id=p_message_id for update;
  if not found or m.sender_id is distinct from auth.uid() or not public.is_conversation_member(m.conversation_id,auth.uid()) then
    raise exception 'Only the message sender may delete this message';
  end if;
  if m.deleted_at is not null then return; end if;
  insert into public.message_history(message_id,conversation_id,actor_id,action,previous_body)
  values(m.id,m.conversation_id,auth.uid(),'deleted',m.body);
  update public.messages set body='[Message deleted]',deleted_at=now(),deleted_by=auth.uid(),updated_at=now() where id=m.id;
end; $$;

create or replace function public.get_message_history(p_message_id uuid)
returns table(id uuid,action text,previous_body text,actor_id uuid,created_at timestamptz)
language plpgsql stable security definer set search_path=public as $$
declare conversation uuid;
begin
  select m.conversation_id into conversation from public.messages m where m.id=p_message_id;
  if conversation is null or not public.is_conversation_member(conversation,auth.uid()) then raise exception 'Not authorized to view this message history'; end if;
  return query select h.id,h.action,h.previous_body,h.actor_id,h.created_at
    from public.message_history h where h.message_id=p_message_id order by h.created_at asc;
end; $$;

-- Only platform admins may run retention cleanup; the cutoff is always at least
-- 365 days old. Soft-deleted message content/history remains available before then.
create or replace function public.purge_retained_message_history(p_before timestamptz)
returns integer language plpgsql security definer set search_path=public as $$
declare removed integer;
begin
  if not public.is_platform_admin() then raise exception 'Platform administrator required'; end if;
  if p_before is null or p_before>now()-interval '365 days' then raise exception 'Retention cutoff must be at least 365 days old'; end if;
  delete from public.messages where deleted_at is not null and deleted_at<p_before;
  get diagnostics removed=row_count;
  delete from public.message_history where created_at<p_before;
  return removed;
end; $$;

revoke all on function public.get_my_messages(),public.submit_ticket_payment_evidence(uuid,text),public.dispute_ticket_payment(uuid,text),
  public.confirm_ticket_payment(uuid),public.review_ticket_payment(uuid,boolean,text),
  public.edit_message(uuid,text),public.soft_delete_message(uuid),public.get_message_history(uuid),
  public.purge_retained_message_history(timestamptz) from public,anon;
grant execute on function public.submit_ticket_payment_evidence(uuid,text),public.dispute_ticket_payment(uuid,text),
  public.confirm_ticket_payment(uuid),public.review_ticket_payment(uuid,boolean,text),
  public.edit_message(uuid,text),public.soft_delete_message(uuid),public.get_message_history(uuid),
  public.purge_retained_message_history(timestamptz) to authenticated;
grant execute on function public.get_my_messages() to authenticated;

commit;
