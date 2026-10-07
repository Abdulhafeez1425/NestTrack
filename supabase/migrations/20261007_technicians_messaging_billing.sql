-- NestTrack technician, messaging CRUD, maintenance billing, and rent-payment details.
-- Apply after the existing 20261006_* migrations. Safe to re-run.

-- Technician is a first-class account and organization membership role.
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check check (role in ('landlord','manager','tenant','technician'));
alter table public.organization_members drop constraint if exists organization_members_role_check;
alter table public.organization_members add constraint organization_members_role_check check (role in ('landlord','manager','tenant','technician'));
alter table public.organization_invitations drop constraint if exists organization_invitations_intended_role_check;
alter table public.organization_invitations add constraint organization_invitations_intended_role_check check (intended_role in ('manager','tenant','technician'));

alter table public.messages add column if not exists updated_at timestamptz not null default now();
alter table public.maintenance_tickets
  add column if not exists estimated_cost numeric(14,2),
  add column if not exists billing_status text not null default 'Not billable',
  add column if not exists payment_reference text,
  add column if not exists paid_confirmed_by uuid references auth.users(id),
  add column if not exists paid_confirmed_at timestamptz;
alter table public.maintenance_tickets drop constraint if exists maintenance_tickets_billing_status_check;
alter table public.maintenance_tickets add constraint maintenance_tickets_billing_status_check
  check (billing_status in ('Not billable','Quote submitted','Awaiting tenant payment','Paid — technician confirmed'));

-- Only the sender may edit/delete a message; the row remains visible to the recipient.
drop policy if exists "message sender edits own message" on public.messages;
create policy "message sender edits own message" on public.messages for update
  using (sender_id=auth.uid() and public.is_conversation_member(conversation_id,auth.uid()))
  with check (sender_id=auth.uid() and public.is_conversation_member(conversation_id,auth.uid()));
drop policy if exists "message sender deletes own message" on public.messages;
create policy "message sender deletes own message" on public.messages for delete
  using (sender_id=auth.uid() and public.is_conversation_member(conversation_id,auth.uid()));

-- Organization technicians may see maintenance tickets so landlords can assign them.
drop policy if exists "organization technicians read tickets" on public.maintenance_tickets;
create policy "organization technicians read tickets" on public.maintenance_tickets for select
  using (exists(select 1 from public.organization_members om where om.organization_id=maintenance_tickets.organization_id and om.user_id=auth.uid() and om.role='technician' and om.status='active'));

create or replace function public.create_independent_profile(p_full_name text,p_role text,p_phone text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); email_address text;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_role not in ('manager','tenant','technician') then raise exception 'Invalid independent account role'; end if;
  if nullif(trim(p_full_name),'') is null then raise exception 'Full name is required'; end if;
  select email into email_address from auth.users where id=uid;
  if email_address is null then raise exception 'Authenticated user email is missing'; end if;
  insert into public.profiles(id,full_name,email,role,phone) values(uid,trim(p_full_name),email_address,p_role,nullif(trim(p_phone),''))
  on conflict(id) do update set full_name=excluded.full_name,email=excluded.email,phone=excluded.phone;
  return uid;
end; $$;
revoke all on function public.create_independent_profile(text,text,text) from public,anon;
grant execute on function public.create_independent_profile(text,text,text) to authenticated;

-- Recreate invitation RPCs with technician supported while preserving secure token and role checks.
create or replace function public.create_organization_invitation(p_organization_id uuid,p_email text default null,p_role text default 'tenant',p_expires_at timestamptz default null,p_max_uses integer default 1)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare uid uuid:=auth.uid(); raw_token text; token_hash text; invitation public.organization_invitations;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_role not in ('manager','tenant','technician') then raise exception 'Invalid invitation role'; end if;
  if not public.has_org_capability(p_organization_id,'manage_members') then raise exception 'Not authorized to create invitations'; end if;
  if p_max_uses<1 then raise exception 'Invalid maximum uses'; end if;
  raw_token:=encode(extensions.gen_random_bytes(32),'hex'); token_hash:=encode(extensions.digest(raw_token,'sha256'),'hex');
  insert into public.organization_invitations(organization_id,email,intended_role,token_hash,created_by,expires_at,max_uses)
  values(p_organization_id,nullif(lower(trim(p_email)),''),p_role,token_hash,uid,coalesce(p_expires_at,now()+interval '7 days'),p_max_uses) returning * into invitation;
  return jsonb_build_object('id',invitation.id,'token',raw_token,'organization_id',invitation.organization_id,'role',invitation.intended_role,'email',invitation.email,'expires_at',invitation.expires_at);
end; $$;

create or replace function public.accept_organization_invitation(p_token text)
returns uuid language plpgsql security definer set search_path=public,extensions as $$
declare uid uuid:=auth.uid(); inv public.organization_invitations%rowtype; existing public.organization_members%rowtype; profile_role text;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_token is null or length(trim(p_token))<20 then raise exception 'Invalid invitation'; end if;
  select * into inv from public.organization_invitations where token_hash=encode(extensions.digest(trim(p_token),'sha256'),'hex') for update;
  if not found then raise exception 'Invalid invitation'; end if;
  if inv.revoked_at is not null then raise exception 'Invitation revoked'; end if;
  if inv.accepted_at is not null and inv.max_uses=1 then raise exception 'Invitation already accepted'; end if;
  if inv.expires_at<=now() then raise exception 'Invitation expired'; end if;
  if inv.used_count>=inv.max_uses then raise exception 'Invitation use limit reached'; end if;
  select p.role into profile_role from public.profiles p where p.id=uid;
  if profile_role is not null and profile_role<>inv.intended_role then raise exception 'Invitation role does not match this account'; end if;
  if inv.email is not null and lower(inv.email)<>lower(coalesce((select email from public.profiles where id=uid),(select email from auth.users where id=uid))) then raise exception 'Invitation email does not match this account'; end if;
  select * into existing from public.organization_members where organization_id=inv.organization_id and user_id=uid for update;
  if found then update public.organization_members set role=inv.intended_role,status='active',invited_by=inv.created_by,joined_at=coalesce(joined_at,now()) where id=existing.id;
  else insert into public.organization_members(organization_id,user_id,role,status,invited_by,joined_at) values(inv.organization_id,uid,inv.intended_role,'active',inv.created_by,now()); end if;
  update public.organization_invitations set used_count=used_count+1,accepted_at=case when used_count+1>=max_uses then now() else accepted_at end where id=inv.id;
  insert into public.notifications(recipient_user_id,organization_id,event_type,title,body,related_entity_type,related_entity_id)
  select om.user_id,inv.organization_id,'invitation_accepted','Invitation accepted',coalesce((select full_name from public.profiles where id=uid),'A user')||' joined the organization.','invitation',inv.id
  from public.organization_members om where om.organization_id=inv.organization_id and om.role in ('landlord','manager') and om.status='active' and om.user_id<>uid;
  return inv.organization_id;
end; $$;

create or replace function public.assign_ticket_technician(p_ticket_id uuid,p_technician_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare t public.maintenance_tickets%rowtype;
begin
  select * into t from public.maintenance_tickets where id=p_ticket_id for update;
  if not found then raise exception 'Ticket not found'; end if;
  if not exists(select 1 from public.organization_members where organization_id=t.organization_id and user_id=auth.uid() and role in ('landlord','manager') and status='active') then raise exception 'Not authorized to assign technicians'; end if;
  if p_technician_id is not null and not exists(select 1 from public.organization_members where organization_id=t.organization_id and user_id=p_technician_id and role='technician' and status='active') then raise exception 'Select an active technician in this organization'; end if;
  update public.maintenance_tickets set assigned_to=p_technician_id,updated_at=now() where id=p_ticket_id;
  insert into public.ticket_history(ticket_id,organization_id,actor_id,event_type,old_assignee,new_assignee) values(t.id,t.organization_id,auth.uid(),'technician_assignment',t.assigned_to,p_technician_id);
end; $$;

create or replace function public.submit_ticket_quote(p_ticket_id uuid,p_amount numeric)
returns void language plpgsql security definer set search_path=public as $$
declare t public.maintenance_tickets%rowtype;
begin
  if p_amount is null or p_amount<0 then raise exception 'Enter a valid non-negative quote'; end if;
  select * into t from public.maintenance_tickets where id=p_ticket_id for update;
  if not found or t.assigned_to is distinct from auth.uid() then raise exception 'Only the assigned technician may submit a quote'; end if;
  if not exists(select 1 from public.organization_members where organization_id=t.organization_id and user_id=auth.uid() and role='technician' and status='active') then raise exception 'Technician membership is required'; end if;
  update public.maintenance_tickets set estimated_cost=p_amount,billing_status='Quote submitted',updated_at=now() where id=p_ticket_id;
  insert into public.ticket_history(ticket_id,organization_id,actor_id,event_type,metadata) values(t.id,t.organization_id,auth.uid(),'quote_submitted',jsonb_build_object('amount',p_amount));
end; $$;

create or replace function public.approve_ticket_quote(p_ticket_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare t public.maintenance_tickets%rowtype;
begin
  select * into t from public.maintenance_tickets where id=p_ticket_id for update;
  if not found or t.billing_status<>'Quote submitted' then raise exception 'No pending quote to approve'; end if;
  if not exists(select 1 from public.organization_members where organization_id=t.organization_id and user_id=auth.uid() and role in ('landlord','manager') and status='active') then raise exception 'Only the landlord or manager may approve a quote'; end if;
  update public.maintenance_tickets set billing_status='Awaiting tenant payment',updated_at=now() where id=p_ticket_id;
  insert into public.ticket_history(ticket_id,organization_id,actor_id,event_type,metadata) values(t.id,t.organization_id,auth.uid(),'quote_approved',jsonb_build_object('amount',t.estimated_cost));
end; $$;

create or replace function public.confirm_ticket_payment(p_ticket_id uuid,p_payment_reference text)
returns void language plpgsql security definer set search_path=public as $$
declare t public.maintenance_tickets%rowtype;
begin
  if nullif(trim(p_payment_reference),'') is null then raise exception 'Payment reference is required'; end if;
  select * into t from public.maintenance_tickets where id=p_ticket_id for update;
  if not found or t.assigned_to is distinct from auth.uid() then raise exception 'Only the assigned technician may confirm payment'; end if;
  if t.billing_status<>'Awaiting tenant payment' then raise exception 'Ticket is not awaiting tenant payment'; end if;
  update public.maintenance_tickets set billing_status='Paid — technician confirmed',payment_reference=trim(p_payment_reference),paid_confirmed_by=auth.uid(),paid_confirmed_at=now(),updated_at=now() where id=p_ticket_id;
  insert into public.ticket_history(ticket_id,organization_id,actor_id,event_type,metadata) values(t.id,t.organization_id,auth.uid(),'payment_confirmed',jsonb_build_object('reference',trim(p_payment_reference),'amount',t.estimated_cost));
end; $$;

create or replace function public.save_org_payment_details(p_organization_id uuid,p_payment_details jsonb)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from public.organization_members where organization_id=p_organization_id and user_id=auth.uid() and role='landlord' and status='active') then raise exception 'Only the landlord may change payment instructions'; end if;
  if jsonb_typeof(p_payment_details)<>'object' then raise exception 'Payment details must be an object'; end if;
  update public.organizations set settings=coalesce(settings,'{}'::jsonb)||jsonb_build_object('payment_details',p_payment_details),updated_at=now() where id=p_organization_id;
end; $$;

revoke all on function public.create_organization_invitation(uuid,text,text,timestamptz,integer) from public,anon;
grant execute on function public.create_organization_invitation(uuid,text,text,timestamptz,integer) to authenticated;
revoke all on function public.accept_organization_invitation(text) from public,anon;
grant execute on function public.accept_organization_invitation(text) to authenticated;
revoke all on function public.assign_ticket_technician(uuid,uuid),public.submit_ticket_quote(uuid,numeric),public.approve_ticket_quote(uuid),public.confirm_ticket_payment(uuid,text),public.save_org_payment_details(uuid,jsonb) from public,anon;
grant execute on function public.assign_ticket_technician(uuid,uuid),public.submit_ticket_quote(uuid,numeric),public.approve_ticket_quote(uuid),public.confirm_ticket_payment(uuid,text),public.save_org_payment_details(uuid,jsonb) to authenticated;

-- Ensure technician profiles are provisioned at auth signup even when email
-- confirmation is enabled (the client cannot call authenticated RPCs yet).
create or replace function public.handle_independent_signup_profile()
returns trigger language plpgsql security definer set search_path=public as $$
declare signup_role text:=coalesce(new.raw_user_meta_data->>'role',''); signup_name text:=nullif(trim(new.raw_user_meta_data->>'full_name'),''); signup_phone text:=nullif(trim(new.raw_user_meta_data->>'phone'),'');
begin
  if signup_role in ('manager','tenant','technician') then
    insert into public.profiles(id,full_name,email,role,phone)
    values(new.id,coalesce(signup_name,split_part(new.email,'@',1)),new.email,signup_role,signup_phone)
    on conflict(id) do update set full_name=excluded.full_name,email=excluded.email,phone=coalesce(excluded.phone,profiles.phone);
  end if;
  return new;
end; $$;
revoke all on function public.handle_independent_signup_profile() from public,anon;
grant update,delete on table public.messages to authenticated;
