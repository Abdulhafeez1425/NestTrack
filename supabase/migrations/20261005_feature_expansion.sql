-- NestTrack Feature Expansion
-- Forward-only migration. Apply after supabase/schema.sql.
-- Safe to re-run where practical.

begin;

-- ---------------------------------------------------------------------------
-- Organization metadata
-- ---------------------------------------------------------------------------
alter table public.organizations
  add column if not exists slug text,
  add column if not exists status text not null default 'active',
  add column if not exists created_by uuid references auth.users(id),
  add column if not exists settings jsonb not null default '{}'::jsonb,
  add column if not exists max_properties integer,
  add column if not exists max_units integer,
  add column if not exists max_members integer;

-- Backfill a normalized slug for organizations that do not have one.
-- Trim leading/trailing separators so values such as "-jizbo-properties-"
-- do not get introduced. Empty results remain NULL and are handled below.
update public.organizations
set slug = nullif(
  trim(both '-' from lower(regexp_replace(trim(name), '[^a-zA-Z0-9]+', '-', 'g'))),
  ''
)
where slug is null or btrim(slug) = '';

-- Existing installations can contain organizations with the same name, and
-- therefore the same generated slug. Resolve duplicates BEFORE creating the
-- unique index. The UUID suffix is deterministic per organization and keeps
-- existing non-duplicate slugs unchanged.
with ranked_slugs as (
  select
    id,
    slug,
    row_number() over (partition by slug order by id) as slug_rank
  from public.organizations
  where slug is not null
), duplicates as (
  select id, slug
  from ranked_slugs
  where slug_rank > 1
)
update public.organizations o
set slug = d.slug || '-' || replace(d.id::text, '-', '')
from duplicates d
where o.id = d.id;

-- Organizations with no usable name/slug get a unique UUID-based slug.
update public.organizations
set slug = 'org-' || replace(id::text, '-', '')
where slug is null;

-- Now that existing duplicate slugs have been resolved, enforce uniqueness.
create unique index if not exists organizations_slug_unique_idx
  on public.organizations(slug) where slug is not null;

alter table public.organizations drop constraint if exists organizations_status_check;
alter table public.organizations
  add constraint organizations_status_check
  check (status in ('active','suspended','archived'));

-- ---------------------------------------------------------------------------
-- Membership metadata / permissions
-- ---------------------------------------------------------------------------
alter table public.organization_members
  add column if not exists invited_by uuid references auth.users(id),
  add column if not exists joined_at timestamptz,
  add column if not exists permissions jsonb not null default '{}'::jsonb;

update public.organization_members
set joined_at = coalesce(joined_at, now())
where status = 'active' and joined_at is null;

-- ---------------------------------------------------------------------------
-- Secure invitations
-- ---------------------------------------------------------------------------
create table if not exists public.organization_invitations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  email text,
  intended_role text not null check (intended_role in ('manager','tenant')),
  token_hash text not null unique,
  created_by uuid not null references auth.users(id),
  expires_at timestamptz not null default (now() + interval '7 days'),
  accepted_at timestamptz,
  revoked_at timestamptz,
  max_uses integer not null default 1 check (max_uses > 0),
  used_count integer not null default 0 check (used_count >= 0),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists organization_invitations_org_idx
  on public.organization_invitations(organization_id, created_at desc);
create index if not exists organization_invitations_token_idx
  on public.organization_invitations(token_hash);

alter table public.properties add column if not exists image_url text;
alter table public.units add column if not exists description text;
alter table public.units add column if not exists rent_amount numeric(14,2);
alter table public.units add column if not exists tags text[] not null default '{}';
create index if not exists properties_org_idx on public.properties(organization_id, active);

-- ---------------------------------------------------------------------------
-- Tenancy lifecycle
-- ---------------------------------------------------------------------------
alter table public.tenancies drop constraint if exists tenancies_status_check;
alter table public.tenancies
  add constraint tenancies_status_check
  check (status in ('pending','active','move_out_requested','ended','rejected'));

alter table public.tenancies
  add column if not exists notice_date date,
  add column if not exists requested_move_out_date date,
  add column if not exists move_out_reason text,
  add column if not exists tenant_note text,
  add column if not exists manager_note text,
  add column if not exists requested_by uuid references auth.users(id),
  add column if not exists decided_by uuid references auth.users(id),
  add column if not exists decided_at timestamptz;

-- Backward-compatible normalization.
update public.tenancies set status='ended' where status='ended';
update public.tenancies set status='pending' where status='pending';
create unique index if not exists tenancies_one_active_per_unit_idx
  on public.tenancies(unit_id) where status in ('active','move_out_requested');
create unique index if not exists tenancies_one_active_per_tenant_idx
  on public.tenancies(tenant_id) where status in ('active','move_out_requested');

-- ---------------------------------------------------------------------------
-- Unit occupancy: derived from active tenancy, but retain current_tenant_id
-- for compatibility with the existing application.
-- ---------------------------------------------------------------------------
create index if not exists units_org_property_idx
  on public.units(organization_id, property_id);
create index if not exists tenancies_org_unit_status_idx
  on public.tenancies(organization_id, unit_id, status);
create index if not exists tenancies_org_tenant_status_idx
  on public.tenancies(organization_id, tenant_id, status);

-- ---------------------------------------------------------------------------
-- Notifications
-- ---------------------------------------------------------------------------
create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_user_id uuid not null references auth.users(id) on delete cascade,
  organization_id uuid references public.organizations(id) on delete cascade,
  event_type text not null,
  title text not null,
  body text not null,
  related_entity_type text,
  related_entity_id uuid,
  read_at timestamptz,
  delivery_status text not null default 'in_app',
  created_at timestamptz not null default now()
);
create index if not exists notifications_recipient_idx
  on public.notifications(recipient_user_id, read_at, created_at desc);
create index if not exists notifications_org_idx
  on public.notifications(organization_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Ticket workflow/history
-- ---------------------------------------------------------------------------
alter table public.maintenance_tickets drop constraint if exists maintenance_tickets_status_check;
update public.maintenance_tickets set status='Pending' where status='Open';
update public.maintenance_tickets set status='In progress' where status='In Progress';
alter table public.maintenance_tickets
  add constraint maintenance_tickets_status_check
  check (status in ('Pending','In progress','Resolved','Closed'));

alter table public.maintenance_tickets
  add column if not exists description text,
  add column if not exists tenant_visible boolean not null default true,
  add column if not exists resolved_at timestamptz,
  add column if not exists closed_at timestamptz;

create table if not exists public.ticket_history (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.maintenance_tickets(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  actor_id uuid not null references auth.users(id),
  event_type text not null,
  old_status text,
  new_status text,
  old_assignee uuid references auth.users(id),
  new_assignee uuid references auth.users(id),
  comment text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists ticket_history_ticket_time_idx
  on public.ticket_history(ticket_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Conversation/message indexes
-- ---------------------------------------------------------------------------
create index if not exists conversation_members_user_idx
  on public.conversation_members(user_id, conversation_id);
create index if not exists messages_conversation_created_idx
  on public.messages(conversation_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Shared security helpers
-- ---------------------------------------------------------------------------
create or replace function public.is_org_member(target_org uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.organization_members om
    where om.organization_id = target_org
      and om.user_id = auth.uid()
      and om.status = 'active'
  );
$$;

-- Check conversation membership without recursively evaluating the
-- conversation_members RLS policy.
create or replace function public.is_conversation_member(
  p_conversation_id uuid,
  p_user_id uuid
)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.conversation_members cm
    where cm.conversation_id = p_conversation_id
      and cm.user_id = p_user_id
      and p_user_id = auth.uid()
  );
$$;

revoke all on function public.is_conversation_member(uuid, uuid) from public, anon;
grant execute on function public.is_conversation_member(uuid, uuid) to authenticated;

create or replace function public.org_role(target_org uuid)
returns text
language sql stable security definer
set search_path = public
as $$
  select om.role
  from public.organization_members om
  where om.organization_id = target_org
    and om.user_id = auth.uid()
    and om.status = 'active'
  limit 1;
$$;

create or replace function public.has_org_capability(target_org uuid, capability text)
returns boolean
language plpgsql stable security definer
set search_path = public
as $$
declare
  r public.organization_members%rowtype;
  granted boolean;
begin
  select * into r
  from public.organization_members
  where organization_id=target_org and user_id=auth.uid() and status='active'
  limit 1;
  if not found then return false; end if;
  if r.role='landlord' then return true; end if;
  if r.role='tenant' then
    return capability in ('view_organization','view_own_tenancy','view_own_tickets',
                          'create_tickets','view_own_payments','send_messages',
                          'request_move_out');
  end if;
  if r.role='manager' then
    if coalesce((r.permissions ->> capability)::boolean, false) then return true; end if;
    return capability in ('view_organization','view_properties','view_tenants',
                          'view_welfare','send_messages','create_tickets',
                          'assign_tickets','change_ticket_status','view_payments');
  end if;
  return false;
end;
$$;

create or replace function public.is_platform_admin()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists(select 1 from public.platform_admins where id=auth.uid());
$$;

-- ---------------------------------------------------------------------------
-- Invitation RPCs
-- ---------------------------------------------------------------------------
create or replace function public.create_organization_invitation(
  p_organization_id uuid,
  p_email text default null,
  p_role text default 'tenant',
  p_expires_at timestamptz default null,
  p_max_uses integer default 1
)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  uid uuid := auth.uid();
  raw_token text;
  token_hash text;
  invitation public.organization_invitations;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_role not in ('manager','tenant') then raise exception 'Invalid invitation role'; end if;
  if not public.has_org_capability(p_organization_id,'manage_members') then
    raise exception 'Not authorized to create invitations';
  end if;
  if p_max_uses < 1 then raise exception 'Invalid maximum uses'; end if;

  raw_token := encode(extensions.gen_random_bytes(32),'hex');
  token_hash := encode(extensions.digest(raw_token,'sha256'),'hex');

  insert into public.organization_invitations(
    organization_id,email,intended_role,token_hash,created_by,expires_at,max_uses
  )
  values(
    p_organization_id,
    nullif(lower(trim(p_email)),''),
    p_role,
    token_hash,
    uid,
    coalesce(p_expires_at,now()+interval '7 days'),
    p_max_uses
  )
  returning * into invitation;

  return jsonb_build_object(
    'id', invitation.id,
    'token', raw_token,
    'organization_id', invitation.organization_id,
    'role', invitation.intended_role,
    'email', invitation.email,
    'expires_at', invitation.expires_at
  );
end;
$$;

create or replace function public.accept_organization_invitation(p_token text)
returns uuid
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  uid uuid := auth.uid();
  inv public.organization_invitations%rowtype;
  existing public.organization_members%rowtype;
  profile_role text;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_token is null or length(trim(p_token)) < 20 then raise exception 'Invalid invitation'; end if;

  select * into inv
  from public.organization_invitations
  where token_hash=encode(extensions.digest(trim(p_token),'sha256'),'hex')
  for update;

  if not found then raise exception 'Invalid invitation'; end if;
  if inv.revoked_at is not null then raise exception 'Invitation revoked'; end if;
  if inv.accepted_at is not null and inv.max_uses=1 then raise exception 'Invitation already accepted'; end if;
  if inv.expires_at <= now() then raise exception 'Invitation expired'; end if;
  if inv.used_count >= inv.max_uses then raise exception 'Invitation use limit reached'; end if;

  select p.role into profile_role from public.profiles p where p.id=uid;
  if profile_role is not null and profile_role <> inv.intended_role then
    raise exception 'Invitation role does not match this account';
  end if;

  if inv.email is not null and lower(inv.email) <>
     lower(coalesce((select email from public.profiles where id=uid),
                    (select email from auth.users where id=uid))) then
    raise exception 'Invitation email does not match this account';
  end if;

  select * into existing
  from public.organization_members
  where organization_id=inv.organization_id and user_id=uid
  for update;

  if found then
    update public.organization_members
      set role=inv.intended_role,status='active',invited_by=inv.created_by,joined_at=coalesce(joined_at,now())
    where id=existing.id;
  else
    insert into public.organization_members(
      organization_id,user_id,role,status,invited_by,joined_at
    ) values(inv.organization_id,uid,inv.intended_role,'active',inv.created_by,now());
  end if;

  update public.organization_invitations
    set used_count=used_count+1,
        accepted_at=case when used_count+1 >= max_uses then now() else accepted_at end
  where id=inv.id;

  insert into public.notifications(
    recipient_user_id,organization_id,event_type,title,body,related_entity_type,related_entity_id
  )
  select om.user_id,inv.organization_id,'invitation_accepted','Invitation accepted',
         coalesce((select full_name from public.profiles where id=uid),'A user') ||
         ' joined the organization.', 'invitation',inv.id
  from public.organization_members om
  where om.organization_id=inv.organization_id
    and om.role in ('landlord','manager') and om.status='active' and om.user_id<>uid;

  return inv.organization_id;
end;
$$;

create or replace function public.revoke_organization_invitation(p_invitation_id uuid)
returns void
language plpgsql security definer
set search_path = public
as $$
declare oid uuid;
begin
  select organization_id into oid from public.organization_invitations where id=p_invitation_id;
  if oid is null or not public.has_org_capability(oid,'manage_members') then
    raise exception 'Not authorized';
  end if;
  update public.organization_invitations set revoked_at=now() where id=p_invitation_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Organization/property/unit workflows
-- ---------------------------------------------------------------------------
create or replace function public.create_organization(p_name text, p_slug text default null)
returns uuid
language plpgsql security definer
set search_path = public
as $$
declare uid uuid:=auth.uid(); oid uuid;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if nullif(trim(p_name),'') is null then raise exception 'Organization name is required'; end if;
  insert into public.organizations(name,slug,created_by)
  values(trim(p_name),
         coalesce(nullif(lower(regexp_replace(trim(coalesce(p_slug,p_name)),'[^a-zA-Z0-9]+','-','g')),''),
                  'org-'||substr(gen_random_uuid()::text,1,8)),
         uid)
  returning id into oid;
  insert into public.organization_members(organization_id,user_id,role,status,joined_at)
  values(oid,uid,'landlord','active',now());
  return oid;
end;
$$;

create or replace function public.create_property_with_units(
  p_organization_id uuid,
  p_name text,
  p_address text,
  p_units jsonb default '[]'::jsonb
)
returns uuid
language plpgsql security definer
set search_path = public
as $$
declare uid uuid:=auth.uid(); pid uuid; item jsonb; property_count int; unit_count int;
begin
  if not public.has_org_capability(p_organization_id,'create_properties') then
    raise exception 'Not authorized';
  end if;
  select count(*) into property_count from public.properties where organization_id=p_organization_id and active;
  if exists(select 1 from public.organizations where id=p_organization_id and max_properties is not null and property_count >= max_properties) then
    raise exception 'Organization property limit reached';
  end if;
  insert into public.properties(organization_id,name,address,manager_id)
  values(p_organization_id,trim(p_name),trim(p_address),case when public.org_role(p_organization_id)='manager' then uid end)
  returning id into pid;

  select count(*) into unit_count from public.units where organization_id=p_organization_id;
  if exists(select 1 from public.organizations where id=p_organization_id and max_units is not null and unit_count + jsonb_array_length(p_units) > max_units) then
    raise exception 'Organization unit limit reached';
  end if;

  for item in select * from jsonb_array_elements(p_units) loop
    insert into public.units(organization_id,property_id,label,status)
    values(p_organization_id,pid,trim(item->>'name'),'vacant');
  end loop;
  return pid;
end;
$$;

-- ---------------------------------------------------------------------------
-- Tenancy / move-out RPCs
-- ---------------------------------------------------------------------------
create or replace function public.assign_tenant_to_unit(
  p_organization_id uuid,
  p_unit_id uuid,
  p_tenant_id uuid,
  p_start_date date,
  p_rent_amount numeric,
  p_frequency text default 'monthly',
  p_deposit_amount numeric default 0
)
returns uuid
language plpgsql security definer
set search_path = public
as $$
declare tid uuid; unit_org uuid; tenant_member boolean;
begin
  if not public.has_org_capability(p_organization_id,'assign_tenants') then raise exception 'Not authorized'; end if;
  select organization_id into unit_org from public.units where id=p_unit_id for update;
  if unit_org is distinct from p_organization_id then raise exception 'Unit is outside organization'; end if;
  select exists(select 1 from public.organization_members where organization_id=p_organization_id and user_id=p_tenant_id and role='tenant' and status='active') into tenant_member;
  if not tenant_member then raise exception 'Tenant is not an active organization member'; end if;
  if exists(select 1 from public.tenancies where unit_id=p_unit_id and status in ('active','move_out_requested')) then
    raise exception 'Unit already has an active tenancy';
  end if;
  if exists(select 1 from public.tenancies where tenant_id=p_tenant_id and status in ('active','move_out_requested')) then
    raise exception 'Tenant already has an active tenancy';
  end if;

  insert into public.tenancies(
    organization_id,unit_id,tenant_id,start_date,rent_amount,frequency,deposit_amount,status
  ) values(p_organization_id,p_unit_id,p_tenant_id,p_start_date,p_rent_amount,p_frequency,p_deposit_amount,'active')
  returning id into tid;
  update public.units set status='occupied',current_tenant_id=p_tenant_id where id=p_unit_id;
  insert into public.audit_events(organization_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_organization_id,auth.uid(),'tenant_assigned','tenancy',tid,jsonb_build_object('unit_id',p_unit_id,'tenant_id',p_tenant_id));
  insert into public.notifications(recipient_user_id,organization_id,event_type,title,body,related_entity_type,related_entity_id)
  values(p_tenant_id,p_organization_id,'tenant_joined','Unit assigned','You have been assigned to a unit.','tenancy',tid);
  return tid;
end;
$$;

create or replace function public.request_move_out(
  p_tenancy_id uuid,
  p_requested_move_out_date date,
  p_reason text default null,
  p_tenant_note text default null
)
returns uuid
language plpgsql security definer
set search_path = public
as $$
declare t public.tenancies%rowtype;
begin
  select * into t from public.tenancies where id=p_tenancy_id for update;
  if not found then raise exception 'Tenancy not found'; end if;
  if t.tenant_id<>auth.uid() and not public.has_org_capability(t.organization_id,'approve_move_out') then raise exception 'Not authorized'; end if;
  if t.status<>'active' then raise exception 'Tenancy is not active'; end if;
  update public.tenancies
    set status='move_out_requested',notice_date=current_date,
        requested_move_out_date=p_requested_move_out_date,
        move_out_reason=p_reason,tenant_note=p_tenant_note,requested_by=auth.uid()
  where id=t.id;
  insert into public.audit_events(organization_id,actor_id,action,entity_type,entity_id,metadata)
  values(t.organization_id,auth.uid(),'move_out_requested','tenancy',t.id,jsonb_build_object('requested_move_out_date',p_requested_move_out_date));
  insert into public.notifications(recipient_user_id,organization_id,event_type,title,body,related_entity_type,related_entity_id)
  select om.user_id,t.organization_id,'move_out_requested','Move-out requested','A tenant has submitted a move-out request.','tenancy',t.id
  from public.organization_members om
  where om.organization_id=t.organization_id and om.role in ('landlord','manager') and om.status='active';
  return t.id;
end;
$$;

create or replace function public.decide_move_out(
  p_tenancy_id uuid,
  p_approve boolean,
  p_manager_note text default null
)
returns uuid
language plpgsql security definer
set search_path = public
as $$
declare t public.tenancies%rowtype;
begin
  select * into t from public.tenancies where id=p_tenancy_id for update;
  if not found then raise exception 'Tenancy not found'; end if;
  if not public.has_org_capability(t.organization_id,'approve_move_out') then raise exception 'Not authorized'; end if;
  if t.status<>'move_out_requested' then raise exception 'No pending move-out request'; end if;

  if p_approve then
    update public.tenancies
      set status='ended',end_date=coalesce(requested_move_out_date,current_date),
          manager_note=p_manager_note,decided_by=auth.uid(),decided_at=now()
    where id=t.id;
    update public.units set status='vacant',current_tenant_id=null where id=t.unit_id;
    insert into public.audit_events(organization_id,actor_id,action,entity_type,entity_id,metadata)
    values(t.organization_id,auth.uid(),'move_out_approved','tenancy',t.id,jsonb_build_object('unit_id',t.unit_id));
    insert into public.notifications(recipient_user_id,organization_id,event_type,title,body,related_entity_type,related_entity_id)
    values(t.tenant_id,t.organization_id,'move_out_approved','Move-out approved','Your move-out request was approved.','tenancy',t.id);
  else
    update public.tenancies
      set status='active',manager_note=p_manager_note,decided_by=auth.uid(),decided_at=now()
    where id=t.id;
    insert into public.audit_events(organization_id,actor_id,action,entity_type,entity_id,metadata)
    values(t.organization_id,auth.uid(),'move_out_rejected','tenancy',t.id,'{}');
    insert into public.notifications(recipient_user_id,organization_id,event_type,title,body,related_entity_type,related_entity_id)
    values(t.tenant_id,t.organization_id,'move_out_rejected','Move-out rejected','Your move-out request was rejected.','tenancy',t.id);
  end if;
  return t.id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Ticket RPCs
-- ---------------------------------------------------------------------------
create or replace function public.create_ticket(
  p_organization_id uuid,
  p_property_id uuid,
  p_unit_id uuid,
  p_title text,
  p_description text,
  p_category text default null,
  p_priority text default 'Medium'
)
returns uuid
language plpgsql security definer
set search_path = public
as $$
declare uid uuid:=auth.uid(); tid uuid; active_tenant uuid;
begin
  if not public.has_org_capability(p_organization_id,'create_tickets') then raise exception 'Not authorized'; end if;
  if public.org_role(p_organization_id)='tenant' then
    select t.tenant_id into active_tenant
    from public.tenancies t
    where t.organization_id=p_organization_id and t.unit_id=p_unit_id
      and t.tenant_id=uid and t.status in ('active','move_out_requested')
    limit 1;
    if active_tenant is null then raise exception 'You may only create tickets for your active tenancy'; end if;
  else
    active_tenant := null;
  end if;

  if not exists(select 1 from public.properties where id=p_property_id and organization_id=p_organization_id) then raise exception 'Property is outside organization'; end if;
  if not exists(select 1 from public.units where id=p_unit_id and organization_id=p_organization_id and property_id=p_property_id) then raise exception 'Unit is outside property'; end if;

  insert into public.maintenance_tickets(
    organization_id,property_id,unit_id,tenant_id,title,description,category,priority,status
  ) values(p_organization_id,p_property_id,p_unit_id,coalesce(active_tenant,uid),trim(p_title),p_description,p_category,p_priority,'Pending')
  returning id into tid;

  insert into public.ticket_history(ticket_id,organization_id,actor_id,event_type,new_status,comment)
  values(tid,p_organization_id,uid,'created','Pending',p_description);

  return tid;
end;
$$;

create or replace function public.update_ticket_workflow(
  p_ticket_id uuid,
  p_status text default null,
  p_assignee uuid default null,
  p_comment text default null
)
returns uuid
language plpgsql security definer
set search_path = public
as $$
declare old public.maintenance_tickets%rowtype; new_status text;
begin
  select * into old from public.maintenance_tickets where id=p_ticket_id for update;
  if not found then raise exception 'Ticket not found'; end if;
  if not public.has_org_capability(old.organization_id,'change_ticket_status') then raise exception 'Not authorized'; end if;
  new_status := coalesce(p_status,old.status);
  if new_status not in ('Pending','In progress','Resolved','Closed') then raise exception 'Invalid ticket status'; end if;
  if old.status='Closed' and new_status<>'Pending' then raise exception 'Closed tickets require a controlled reopen to Pending'; end if;
  if old.status='Pending' and new_status not in ('Pending','In progress') then raise exception 'Invalid status transition'; end if;
  if old.status='In progress' and new_status not in ('In progress','Resolved') then raise exception 'Invalid status transition'; end if;
  if old.status='Resolved' and new_status not in ('Resolved','Closed','In progress') then raise exception 'Invalid status transition'; end if;

  update public.maintenance_tickets
    set status=new_status,
        assigned_to=coalesce(p_assignee,assigned_to),
        updated_at=now(),
        resolved_at=case when new_status='Resolved' then coalesce(resolved_at,now()) else resolved_at end,
        closed_at=case when new_status='Closed' then coalesce(closed_at,now()) else closed_at end
  where id=p_ticket_id;

  insert into public.ticket_history(
    ticket_id,organization_id,actor_id,event_type,old_status,new_status,
    old_assignee,new_assignee,comment
  ) values(
    p_ticket_id,old.organization_id,auth.uid(),
    case when old.assigned_to is distinct from coalesce(p_assignee,old.assigned_to) then 'assignment' else 'status' end,
    old.status,new_status,old.assigned_to,coalesce(p_assignee,old.assigned_to),p_comment
  );

  if old.status is distinct from new_status or old.assigned_to is distinct from coalesce(p_assignee,old.assigned_to) then
    insert into public.notifications(recipient_user_id,organization_id,event_type,title,body,related_entity_type,related_entity_id)
    select distinct recipient,old.organization_id,'ticket_changed','Ticket updated',
           old.title || ' is now ' || new_status,'ticket',old.id
    from unnest(array_remove(array[old.tenant_id,coalesce(p_assignee,old.assigned_to)],null::uuid)) recipient;
  end if;
  return p_ticket_id;
end;
$$;

-- Message read-state RPC.
create or replace function public.mark_conversation_read(p_conversation_id uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from public.conversation_members where conversation_id=p_conversation_id and user_id=auth.uid()) then
    raise exception 'Not authorized';
  end if;
  update public.messages
    set read_at=now()
  where conversation_id=p_conversation_id
    and sender_id is distinct from auth.uid()
    and read_at is null;
end;
$$;
revoke all on function public.mark_conversation_read(uuid) from public, anon;
grant execute on function public.mark_conversation_read(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Messaging RPC + notifications
-- ---------------------------------------------------------------------------
create or replace function public.get_or_create_direct_conversation(p_other uuid, p_organization_id uuid default null)
returns uuid
language plpgsql security definer
set search_path = public
as $$
declare uid uuid:=auth.uid(); cid uuid; oid uuid;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  select coalesce(p_organization_id,
                  (select organization_id from public.organization_members
                   where user_id=uid and status='active' order by organization_id limit 1))
    into oid;
  if oid is null or not public.is_org_member(oid) then raise exception 'Invalid organization'; end if;
  if not public.is_org_member(oid) then raise exception 'Not a member'; end if;
  if not exists(select 1 from public.organization_members where organization_id=oid and user_id=p_other and status='active')
     and not public.is_platform_admin() then raise exception 'Recipient is not an organization member'; end if;

  select c.id into cid
  from public.conversations c
  where c.organization_id=oid
    and exists(select 1 from public.conversation_members a where a.conversation_id=c.id and a.user_id=uid)
    and exists(select 1 from public.conversation_members b where b.conversation_id=c.id and b.user_id=p_other)
  limit 1;

  if cid is null then
    insert into public.conversations(organization_id) values(oid) returning id into cid;
    insert into public.conversation_members(conversation_id,user_id) values(cid,uid),(cid,p_other);
  end if;
  return cid;
end;
$$;

-- ---------------------------------------------------------------------------
-- Account/organization deletion
-- ---------------------------------------------------------------------------
create or replace function public.delete_organization_as_landlord(p_organization_id uuid)
returns void
language plpgsql security definer
set search_path = public
as $$
begin
  if not exists(select 1 from public.organization_members
                where organization_id=p_organization_id and user_id=auth.uid()
                  and role='landlord' and status='active') then
    raise exception 'Not authorized';
  end if;
  update public.organizations set status='archived' where id=p_organization_id;
  insert into public.audit_events(organization_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_organization_id,auth.uid(),'organization_archived','organization',p_organization_id,'{}');
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke all on function public.create_organization_invitation(uuid,text,text,timestamptz,integer) from public, anon;
grant execute on function public.create_organization_invitation(uuid,text,text,timestamptz,integer) to authenticated;
revoke all on function public.accept_organization_invitation(text) from public, anon;
grant execute on function public.accept_organization_invitation(text) to authenticated;
revoke all on function public.revoke_organization_invitation(uuid) from public, anon;
grant execute on function public.revoke_organization_invitation(uuid) to authenticated;
revoke all on function public.create_organization(text,text) from public, anon;
grant execute on function public.create_organization(text,text) to authenticated;
revoke all on function public.create_property_with_units(uuid,text,text,jsonb) from public, anon;
grant execute on function public.create_property_with_units(uuid,text,text,jsonb) to authenticated;
revoke all on function public.assign_tenant_to_unit(uuid,uuid,uuid,date,numeric,text,numeric) from public, anon;
grant execute on function public.assign_tenant_to_unit(uuid,uuid,uuid,date,numeric,text,numeric) to authenticated;
revoke all on function public.request_move_out(uuid,date,text,text) from public, anon;
grant execute on function public.request_move_out(uuid,date,text,text) to authenticated;
revoke all on function public.decide_move_out(uuid,boolean,text) from public, anon;
grant execute on function public.decide_move_out(uuid,boolean,text) to authenticated;
revoke all on function public.create_ticket(uuid,uuid,uuid,text,text,text,text) from public, anon;
grant execute on function public.create_ticket(uuid,uuid,uuid,text,text,text,text) to authenticated;
revoke all on function public.update_ticket_workflow(uuid,text,uuid,text) from public, anon;
grant execute on function public.update_ticket_workflow(uuid,text,uuid,text) to authenticated;
revoke all on function public.get_or_create_direct_conversation(uuid,uuid) from public, anon;
grant execute on function public.get_or_create_direct_conversation(uuid,uuid) to authenticated;
revoke all on function public.delete_organization_as_landlord(uuid) from public, anon;
grant execute on function public.delete_organization_as_landlord(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.organization_invitations enable row level security;
alter table public.notifications enable row level security;
alter table public.ticket_history enable row level security;

drop policy if exists "org invitations read" on public.organization_invitations;
create policy "org invitations read"
on public.organization_invitations for select
using (public.is_org_member(organization_id) or created_by=auth.uid());

drop policy if exists "ticket history read" on public.ticket_history;
create policy "ticket history read"
on public.ticket_history for select
using (
  public.is_org_member(organization_id)
  and (
    public.has_org_capability(organization_id,'view_audit')
    or exists(select 1 from public.maintenance_tickets t
              where t.id=ticket_id and t.tenant_id=auth.uid())
  )
);

-- Replace broad legacy policies that allowed manager/tenant mutation shortcuts.
drop policy if exists "managers manage properties" on public.properties;
create policy "operations manage properties"
on public.properties for all
using (public.has_org_capability(organization_id,'create_properties'))
with check (public.has_org_capability(organization_id,'create_properties'));

drop policy if exists "members read properties" on public.properties;
create policy "members read properties"
on public.properties for select
using (public.is_org_member(organization_id) or public.is_platform_admin());

drop policy if exists "members read units" on public.units;
create policy "members read units"
on public.units for select
using (public.is_org_member(organization_id) or public.is_platform_admin());

drop policy if exists "members read tenancies" on public.tenancies;
create policy "members read tenancies"
on public.tenancies for select
using (
  public.is_org_member(organization_id)
  and (tenant_id=auth.uid() or public.has_org_capability(organization_id,'view_tenants'))
);

drop policy if exists "members read tickets" on public.maintenance_tickets;
create policy "members read tickets"
on public.maintenance_tickets for select
using (
  public.is_org_member(organization_id)
  and (
    tenant_id=auth.uid()
    or public.has_org_capability(organization_id,'view_tickets')
  )
);

drop policy if exists "operations update tickets" on public.maintenance_tickets;
create policy "operations update tickets"
on public.maintenance_tickets for update
using (public.has_org_capability(organization_id,'change_ticket_status'))
with check (public.has_org_capability(organization_id,'change_ticket_status'));

drop policy if exists "tenant create tickets" on public.maintenance_tickets;
create policy "tenant create tickets"
on public.maintenance_tickets for insert
with check (
  public.has_org_capability(organization_id,'create_tickets')
  and (tenant_id=auth.uid() or public.org_role(organization_id)<>'tenant')
);

drop policy if exists "conversation members read" on public.conversations;
drop policy if exists "conversation participants or admins read conversations" on public.conversations;
create policy "conversation members read"
on public.conversations for select
using (
  public.is_platform_admin()
  or (
    public.is_org_member(organization_id)
    and public.is_conversation_member(id, auth.uid())
  )
);

drop policy if exists "conversation participants read messages" on public.messages;
drop policy if exists "conversation participants or admins read messages" on public.messages;
create policy "conversation participants read messages"
on public.messages for select
using (
  public.is_platform_admin()
  or public.is_conversation_member(messages.conversation_id, auth.uid())
);

drop policy if exists "conversation participants send messages" on public.messages;
create policy "conversation participants send messages"
on public.messages for insert
with check (
  sender_id=auth.uid()
  and public.is_conversation_member(messages.conversation_id, auth.uid())
);

-- Read/update own notifications only.
drop policy if exists "notifications own read" on public.notifications;
create policy "notifications own read"
on public.notifications for select using (recipient_user_id=auth.uid());
drop policy if exists "notifications own update" on public.notifications;
create policy "notifications own update"
on public.notifications for update
using (recipient_user_id=auth.uid())
with check (recipient_user_id=auth.uid());


-- Profile role is membership-controlled; clients cannot self-escalate.
create or replace function public.prevent_profile_role_change()
returns trigger language plpgsql
set search_path=public
as $$
begin
  if tg_op='UPDATE' and new.role is distinct from old.role then
    raise exception 'Profile role is controlled by organization membership';
  end if;
  return new;
end;
$$;
drop trigger if exists prevent_profile_role_change on public.profiles;
create trigger prevent_profile_role_change
before update on public.profiles
for each row execute function public.prevent_profile_role_change();

drop policy if exists "self profile" on public.profiles;
create policy "self profile read"
on public.profiles for select using (id=auth.uid() or public.is_platform_admin());
create policy "self profile update"
on public.profiles for update
using (id=auth.uid())
with check (id=auth.uid());

drop policy if exists "org members update organization" on public.organizations;
create policy "org members update organization"
on public.organizations for update
using (public.has_org_capability(id,'manage_organization'))
with check (public.has_org_capability(id,'manage_organization'));


-- Historical references should not prevent an account from being deleted.
-- Allow historical rows to survive account deletion.
alter table public.organization_members alter column invited_by drop not null;
alter table public.organization_members drop constraint if exists organization_members_invited_by_fkey;
alter table public.organization_members add constraint organization_members_invited_by_fkey
  foreign key (invited_by) references auth.users(id) on delete set null;
alter table public.organization_invitations alter column created_by drop not null;
alter table public.organization_invitations drop constraint if exists organization_invitations_created_by_fkey;
alter table public.organization_invitations add constraint organization_invitations_created_by_fkey
  foreign key (created_by) references auth.users(id) on delete set null;
alter table public.tenancies drop constraint if exists tenancies_requested_by_fkey;
alter table public.tenancies add constraint tenancies_requested_by_fkey
  foreign key (requested_by) references auth.users(id) on delete set null;
alter table public.tenancies drop constraint if exists tenancies_decided_by_fkey;
alter table public.tenancies add constraint tenancies_decided_by_fkey
  foreign key (decided_by) references auth.users(id) on delete set null;
alter table public.payments drop constraint if exists payments_verified_by_fkey;
alter table public.payments add constraint payments_verified_by_fkey
  foreign key (verified_by) references auth.users(id) on delete set null;
alter table public.welfare_checks drop constraint if exists welfare_checks_checked_by_fkey;
alter table public.welfare_checks add constraint welfare_checks_checked_by_fkey
  foreign key (checked_by) references auth.users(id) on delete set null;
alter table public.maintenance_tickets drop constraint if exists maintenance_tickets_assigned_to_fkey;
alter table public.maintenance_tickets add constraint maintenance_tickets_assigned_to_fkey
  foreign key (assigned_to) references auth.users(id) on delete set null;
alter table public.cashflow_ledger drop constraint if exists cashflow_ledger_tenant_id_fkey;
alter table public.cashflow_ledger add constraint cashflow_ledger_tenant_id_fkey
  foreign key (tenant_id) references auth.users(id) on delete set null;
alter table public.payments alter column tenant_id drop not null;
alter table public.welfare_checks alter column tenant_id drop not null;
alter table public.messages alter column sender_id drop not null;
alter table public.ticket_history alter column actor_id drop not null;
alter table public.properties drop constraint if exists properties_manager_id_fkey;
alter table public.properties add constraint properties_manager_id_fkey
  foreign key (manager_id) references auth.users(id) on delete set null;
alter table public.tenancies drop constraint if exists tenancies_tenant_id_fkey;
alter table public.tenancies add constraint tenancies_tenant_id_fkey
  foreign key (tenant_id) references auth.users(id) on delete cascade;
alter table public.payments drop constraint if exists payments_tenant_id_fkey;
alter table public.payments add constraint payments_tenant_id_fkey
  foreign key (tenant_id) references auth.users(id) on delete set null;
alter table public.welfare_checks drop constraint if exists welfare_checks_tenant_id_fkey;
alter table public.welfare_checks add constraint welfare_checks_tenant_id_fkey
  foreign key (tenant_id) references auth.users(id) on delete set null;
alter table public.messages drop constraint if exists messages_sender_id_fkey;
alter table public.messages add constraint messages_sender_id_fkey
  foreign key (sender_id) references auth.users(id) on delete set null;
alter table public.audit_events drop constraint if exists audit_events_actor_id_fkey;
alter table public.audit_events add constraint audit_events_actor_id_fkey
  foreign key (actor_id) references auth.users(id) on delete set null;
alter table public.ticket_history drop constraint if exists ticket_history_actor_id_fkey;
alter table public.ticket_history add constraint ticket_history_actor_id_fkey
  foreign key (actor_id) references auth.users(id) on delete set null;
alter table public.ticket_history drop constraint if exists ticket_history_old_assignee_fkey;
alter table public.ticket_history add constraint ticket_history_old_assignee_fkey
  foreign key (old_assignee) references auth.users(id) on delete set null;
alter table public.ticket_history drop constraint if exists ticket_history_new_assignee_fkey;
alter table public.ticket_history add constraint ticket_history_new_assignee_fkey
  foreign key (new_assignee) references auth.users(id) on delete set null;

create or replace function public.delete_property_as_landlord(p_property_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare oid uuid;
begin
  select organization_id into oid from public.properties where id=p_property_id for update;
  if oid is null or not public.has_org_capability(oid,'create_properties') or public.org_role(oid)<>'landlord' then
    raise exception 'Not authorized';
  end if;
  delete from public.properties where id=p_property_id;
  insert into public.audit_events(organization_id,actor_id,action,entity_type,entity_id,metadata)
  values(oid,auth.uid(),'property_deleted','property',p_property_id,'{}');
end;
$$;

create or replace function public.delete_unit_as_landlord(p_unit_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare oid uuid; active_count integer;
begin
  select organization_id into oid from public.units where id=p_unit_id for update;
  if oid is null or public.org_role(oid)<>'landlord' then raise exception 'Not authorized'; end if;
  select count(*) into active_count from public.tenancies where unit_id=p_unit_id and status in ('active','move_out_requested');
  if active_count>0 then raise exception 'Cannot delete an occupied unit. End the tenancy first.'; end if;
  delete from public.units where id=p_unit_id;
  insert into public.audit_events(organization_id,actor_id,action,entity_type,entity_id,metadata)
  values(oid,auth.uid(),'unit_deleted','unit',p_unit_id,'{}');
end;
$$;

create or replace function public.delete_tenant_account(p_tenant_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare oid uuid;
begin
  if p_tenant_id=auth.uid() then raise exception 'Use account settings to delete your own account'; end if;
  if not exists(
    select 1 from public.organization_members actor
    join public.organization_members target on target.organization_id=actor.organization_id
    where actor.user_id=auth.uid() and actor.role='landlord' and actor.status='active'
      and target.user_id=p_tenant_id and target.role='tenant' and target.status='active'
  ) then raise exception 'Not authorized'; end if;
  select organization_id into oid from public.organization_members where user_id=p_tenant_id and role='tenant' limit 1;
  update public.tenancies set status='ended',end_date=current_date where tenant_id=p_tenant_id and status in ('active','move_out_requested');
  update public.units u set status='vacant',current_tenant_id=null
    where u.current_tenant_id=p_tenant_id;
  delete from auth.users where id=p_tenant_id;
end;
$$;

create or replace function public.admin_delete_landlord(p_landlord_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare oid uuid;
begin
  if not public.is_platform_admin() then raise exception 'Not authorized'; end if;
  for oid in select organization_id from public.organization_members where user_id=p_landlord_id and role='landlord' loop
    update public.organizations set created_by=null where id=oid;
    delete from public.organizations where id=oid;
  end loop;
  delete from auth.users where id=p_landlord_id;
end;
$$;

create or replace function public.delete_my_account()
returns void language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); oid uuid;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  for oid in select organization_id from public.organization_members where user_id=uid and role='landlord' loop
    update public.organizations set created_by=null where id=oid;
    delete from public.organizations where id=oid;
  end loop;
  update public.tenancies set status='ended',end_date=current_date where tenant_id=uid and status in ('active','move_out_requested');
  update public.units set status='vacant',current_tenant_id=null where current_tenant_id=uid;
  delete from auth.users where id=uid;
end;
$$;

revoke all on function public.delete_property_as_landlord(uuid) from public, anon;
grant execute on function public.delete_property_as_landlord(uuid) to authenticated;
revoke all on function public.delete_unit_as_landlord(uuid) from public, anon;
grant execute on function public.delete_unit_as_landlord(uuid) to authenticated;
revoke all on function public.delete_tenant_account(uuid) from public, anon;
grant execute on function public.delete_tenant_account(uuid) to authenticated;
revoke all on function public.admin_delete_landlord(uuid) from public, anon;
grant execute on function public.admin_delete_landlord(uuid) to authenticated;
revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

-- Direct tenant inserts must match an active tenancy.
drop policy if exists "tenant create tickets" on public.maintenance_tickets;
create policy "tenant create tickets"
on public.maintenance_tickets for insert
with check (
  public.has_org_capability(organization_id,'create_tickets')
  and (
    public.org_role(organization_id)<>'tenant'
    or (
      tenant_id=auth.uid()
      and exists(select 1 from public.tenancies t
                 where t.organization_id=organization_id
                   and t.unit_id=maintenance_tickets.unit_id
                   and t.tenant_id=auth.uid()
                   and t.status in ('active','move_out_requested'))
    )
  )
);

commit;
