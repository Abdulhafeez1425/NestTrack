-- GENERATED FILE. Source of truth: base SQL files and supabase/migrations/*.sql.
-- Fresh/empty database only. Existing databases apply only unapplied migrations.
-- Regenerate with: npm run sql:merge
-- LOGIN_DIAGNOSTIC.sql is intentionally excluded.


-- ============================================================================
-- SOURCE: supabase/schema.sql
-- ============================================================================
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

create table if not exists organizations (
 id uuid primary key default gen_random_uuid(), name text not null,
 currency text not null default 'NGN', timezone text not null default 'Africa/Lagos',
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 full_name text not null, email text not null unique,
 role text not null check(role in ('landlord','manager','tenant')),
 phone text, avatar_url text, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists organization_members (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references organizations(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 role text not null check(role in ('landlord','manager','tenant')),
 status text not null default 'active' check(status in ('active','invited','disabled')),
 unique(organization_id,user_id)
);
create table if not exists properties (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references organizations(id) on delete cascade,
 name text not null, address text not null, manager_id uuid references auth.users(id), active boolean not null default true,
 created_at timestamptz not null default now()
);
create table if not exists units (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references organizations(id) on delete cascade,
 property_id uuid not null references properties(id) on delete cascade, label text not null,
 status text not null default 'vacant' check(status in ('vacant','occupied')), current_tenant_id uuid references auth.users(id)
);
create table if not exists tenancies (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references organizations(id) on delete cascade,
 unit_id uuid not null references units(id) on delete cascade, tenant_id uuid not null references auth.users(id),
 start_date date not null, end_date date, rent_amount numeric(14,2) not null, frequency text not null default 'monthly',
 deposit_amount numeric(14,2) default 0, status text not null default 'active' check(status in ('active','ended','pending'))
);
create table if not exists payments (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references organizations(id) on delete cascade,
 tenancy_id uuid not null references tenancies(id) on delete cascade, tenant_id uuid not null references auth.users(id),
 due_date date not null, amount_due numeric(14,2) not null, amount_paid numeric(14,2) not null default 0,
 status text not null default 'Due soon' check(status in ('Due soon','Pending review','Paid','Overdue','Partially paid','Waived')),
 method text, receipt_path text, verified_by uuid references auth.users(id), verified_at timestamptz,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists welfare_checks (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references organizations(id) on delete cascade,
 tenant_id uuid not null references auth.users(id), status text not null check(status in ('Good','Needs attention','Urgent')),
 note text, checked_by uuid references auth.users(id), checked_at timestamptz not null default now()
);
create table if not exists conversations (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references organizations(id) on delete cascade,
 subject text, property_id uuid references properties(id), unit_id uuid references units(id), created_at timestamptz not null default now()
);
create table if not exists conversation_members (
 conversation_id uuid not null references conversations(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 primary key(conversation_id,user_id)
);
create table if not exists messages (
 id uuid primary key default gen_random_uuid(), conversation_id uuid not null references conversations(id) on delete cascade,
 sender_id uuid not null references auth.users(id), body text not null, read_at timestamptz,
 created_at timestamptz not null default now()
);
create table if not exists maintenance_tickets (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references organizations(id) on delete cascade,
 property_id uuid not null references properties(id), unit_id uuid references units(id), tenant_id uuid references auth.users(id),
 title text not null, description text, category text, priority text not null default 'Medium',
 status text not null default 'Open' check(status in ('Open','In progress','Resolved')),
 assigned_to uuid references auth.users(id), created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists audit_events (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references organizations(id) on delete cascade,
 actor_id uuid references auth.users(id), action text not null, entity_type text not null, entity_id uuid, metadata jsonb not null default '{}', created_at timestamptz not null default now()
);

create index if not exists payments_tenant_due_idx on payments(tenant_id,due_date);
create index if not exists payments_org_status_idx on payments(organization_id,status);
create index if not exists welfare_org_tenant_idx on welfare_checks(organization_id,tenant_id,checked_at desc);
create index if not exists messages_conversation_time_idx on messages(conversation_id,created_at);
create index if not exists tickets_org_status_idx on maintenance_tickets(organization_id,status,priority);

-- Production additions: platform administration, invite codes and immutable cashflow ledger.
create table if not exists platform_admins (
 id uuid primary key references auth.users(id) on delete cascade,
 created_at timestamptz not null default now()
);

create table if not exists invite_codes (
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references organizations(id) on delete cascade,
 code text not null unique,
 role text not null check(role in ('manager','tenant')),
 active boolean not null default true,
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 expires_at timestamptz,
 max_uses integer,
 used_count integer not null default 0
);
create index if not exists invite_codes_lookup_idx on invite_codes(code, active);

create table if not exists cashflow_ledger (
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references organizations(id) on delete cascade,
 landlord_id uuid not null references auth.users(id),
 payment_id uuid references payments(id) on delete set null,
 tenant_id uuid references auth.users(id),
 amount numeric(14,2) not null,
 type text not null default 'Rent',
 status text not null default 'Recorded',
 method text,
 recorded_at timestamptz not null default now(),
 metadata jsonb not null default '{}'
);
create index if not exists cashflow_ledger_org_time_idx on cashflow_ledger(organization_id, recorded_at desc);
create index if not exists cashflow_ledger_landlord_time_idx on cashflow_ledger(landlord_id, recorded_at desc);

create or replace function public.record_verified_payment_cashflow()
returns trigger language plpgsql security definer set search_path=public as $$
declare landlord_user uuid;
begin
  if new.status='Paid' and (old.status is distinct from 'Paid') then
    select om.user_id into landlord_user
    from organization_members om
    where om.organization_id=new.organization_id and om.role='landlord' and om.status='active'
    order by om.id limit 1;
    if landlord_user is not null then
      insert into cashflow_ledger(organization_id,landlord_id,payment_id,tenant_id,amount,type,status,method,recorded_at)
      values(new.organization_id,landlord_user,new.id,new.tenant_id,new.amount_paid,'Rent','Recorded',new.method,coalesce(new.verified_at,now()))
      on conflict do nothing;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists payments_cashflow_trigger on payments;
create trigger payments_cashflow_trigger after update on payments for each row execute function public.record_verified_payment_cashflow();

-- Profile image storage (run once in Supabase SQL editor)
insert into storage.buckets (id, name, public) values ('avatars', 'avatars', true)
on conflict (id) do update set public = true;
drop policy if exists "Avatar images are publicly readable" on storage.objects;
drop policy if exists "Users upload their own avatar" on storage.objects;
drop policy if exists "Users update their own avatar" on storage.objects;
create policy "Avatar images are publicly readable" on storage.objects for select using (bucket_id = 'avatars');
create policy "Users upload their own avatar" on storage.objects for insert with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "Users update their own avatar" on storage.objects for update using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

-- Account deletion RPCs (run after reviewing your RLS policies)
create or replace function public.delete_my_account() returns void language plpgsql security definer set search_path=public as $$ begin delete from auth.users where id=auth.uid(); end; $$;
create or replace function public.delete_tenant_account(p_tenant_id uuid) returns void language plpgsql security definer set search_path=public as $$ begin if not exists (select 1 from organization_members om where om.user_id=auth.uid() and om.role='landlord' and om.organization_id in (select organization_id from organization_members where user_id=p_tenant_id)) then raise exception 'Not authorized'; end if; delete from auth.users where id=p_tenant_id; end; $$;

-- ============================================================================
-- SOURCE: supabase/rls.sql
-- ============================================================================
DO $$
DECLARE
t text;
BEGIN
FOREACH t IN ARRAY ARRAY[
'organizations',
'profiles',
'organization_members',
'properties',
'units',
'tenancies',
'payments',
'welfare_checks',
'conversations',
'conversation_members',
'messages',
'maintenance_tickets',
'audit_events'
]
LOOP
EXECUTE format(
'ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',
t
);
END LOOP;
END $$;

-- ============================================================
-- SECURITY HELPER FUNCTION
-- ============================================================

CREATE OR REPLACE FUNCTION public.is_org_member(target_org uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
SELECT EXISTS (
SELECT 1
FROM public.organization_members om
WHERE om.organization_id = target_org
AND om.user_id = auth.uid()
AND om.status = 'active'
);
$$;

-- Check conversation membership without recursively evaluating the
-- conversation_members RLS policy.
CREATE OR REPLACE FUNCTION public.is_conversation_member(
  p_conversation_id uuid,
  p_user_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.conversation_members cm
    WHERE cm.conversation_id = p_conversation_id
      AND cm.user_id = p_user_id
      AND p_user_id = auth.uid()
  );
$$;

REVOKE ALL
ON FUNCTION public.is_conversation_member(uuid, uuid)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.is_conversation_member(uuid, uuid)
TO authenticated;

-- Define this helper before any policy references it so this script also works
-- on a fresh database without relying on a later feature migration.
CREATE OR REPLACE FUNCTION public.is_platform_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (SELECT 1 FROM public.platform_admins WHERE id = auth.uid());
$$;

REVOKE ALL ON FUNCTION public.is_platform_admin() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_platform_admin() TO authenticated;

-- ============================================================
-- REMOVE EXISTING POLICIES
-- This makes the script safe to re-run.
-- ============================================================

-- ORGANIZATIONS

DROP POLICY IF EXISTS "org members read organization"
ON public.organizations;

-- PROFILES

DROP POLICY IF EXISTS "self profile"
ON public.profiles;

-- ORGANIZATION MEMBERS

DROP POLICY IF EXISTS "members read membership"
ON public.organization_members;

-- PROPERTIES

DROP POLICY IF EXISTS "members read properties"
ON public.properties;

DROP POLICY IF EXISTS "managers manage properties"
ON public.properties;

-- UNITS

DROP POLICY IF EXISTS "members read units"
ON public.units;

-- TENANCIES

DROP POLICY IF EXISTS "members read tenancies"
ON public.tenancies;

-- PAYMENTS

DROP POLICY IF EXISTS "members read payments"
ON public.payments;

DROP POLICY IF EXISTS "tenant submit payment"
ON public.payments;

DROP POLICY IF EXISTS "manager verify payment"
ON public.payments;

-- WELFARE CHECKS

DROP POLICY IF EXISTS "welfare visible to operations"
ON public.welfare_checks;

DROP POLICY IF EXISTS "operations manage welfare"
ON public.welfare_checks;

-- CONVERSATIONS

DROP POLICY IF EXISTS "conversation members read"
ON public.conversations;

DROP POLICY IF EXISTS "conversation participants or admins read conversations"
ON public.conversations;

-- CONVERSATION MEMBERS

DROP POLICY IF EXISTS "conversation members read membership"
ON public.conversation_members;

DROP POLICY IF EXISTS "conversation participants read membership"
ON public.conversation_members;

-- MESSAGES

DROP POLICY IF EXISTS "conversation participants read messages"
ON public.messages;

DROP POLICY IF EXISTS "conversation participants or admins read messages"
ON public.messages;

DROP POLICY IF EXISTS "conversation participants send messages"
ON public.messages;

-- MAINTENANCE TICKETS

DROP POLICY IF EXISTS "members read tickets"
ON public.maintenance_tickets;

DROP POLICY IF EXISTS "tenant create tickets"
ON public.maintenance_tickets;

DROP POLICY IF EXISTS "operations update tickets"
ON public.maintenance_tickets;

-- AUDIT EVENTS

DROP POLICY IF EXISTS "operations read audit"
ON public.audit_events;

-- ============================================================
-- CORE POLICIES
-- ============================================================

-- ORGANIZATIONS

CREATE POLICY "org members read organization"
ON public.organizations
FOR SELECT
USING (
public.is_org_member(id)
);

-- PROFILES

CREATE POLICY "self profile"
ON public.profiles
FOR ALL
USING (
auth.uid() = id
)
WITH CHECK (
auth.uid() = id
);

DROP POLICY IF EXISTS "org members read profiles" ON public.profiles;
CREATE POLICY "org members read profiles"
ON public.profiles
FOR SELECT
USING (
  id = auth.uid()
  OR EXISTS (
    SELECT 1
    FROM public.organization_members viewer
    JOIN public.organization_members target
      ON target.organization_id = viewer.organization_id
    WHERE viewer.user_id = auth.uid()
      AND viewer.status = 'active'
      AND target.user_id = public.profiles.id
      AND target.status = 'active'
  )
  OR public.is_platform_admin()
);

-- ORGANIZATION MEMBERS

CREATE POLICY "members read membership"
ON public.organization_members
FOR SELECT
USING (
user_id = auth.uid()
OR public.is_org_member(organization_id)
);

-- PROPERTIES

CREATE POLICY "members read properties"
ON public.properties
FOR SELECT
USING (
public.is_org_member(organization_id)
);

CREATE POLICY "managers manage properties"
ON public.properties
FOR ALL
USING (
EXISTS (
SELECT 1
FROM public.organization_members om
WHERE om.organization_id = properties.organization_id
AND om.user_id = auth.uid()
AND om.role IN ('landlord', 'manager')
AND om.status = 'active'
)
)
WITH CHECK (
EXISTS (
SELECT 1
FROM public.organization_members om
WHERE om.organization_id = properties.organization_id
AND om.user_id = auth.uid()
AND om.role IN ('landlord', 'manager')
AND om.status = 'active'
)
);

-- UNITS

CREATE POLICY "members read units"
ON public.units
FOR SELECT
USING (
public.is_org_member(organization_id)
);

-- TENANCIES

CREATE POLICY "members read tenancies"
ON public.tenancies
FOR SELECT
USING (
public.is_org_member(organization_id)
AND (
tenant_id = auth.uid()
OR EXISTS (
SELECT 1
FROM public.organization_members om
WHERE om.organization_id = tenancies.organization_id
AND om.user_id = auth.uid()
AND om.role IN ('landlord', 'manager')
)
)
);

-- PAYMENTS

CREATE POLICY "members read payments"
ON public.payments
FOR SELECT
USING (
public.is_org_member(organization_id)
AND (
tenant_id = auth.uid()
OR EXISTS (
SELECT 1
FROM public.organization_members om
WHERE om.organization_id = payments.organization_id
AND om.user_id = auth.uid()
AND om.role IN ('landlord', 'manager')
)
)
);

CREATE POLICY "tenant submit payment"
ON public.payments
FOR INSERT
WITH CHECK (
tenant_id = auth.uid()
AND public.is_org_member(organization_id)
);

CREATE POLICY "manager verify payment"
ON public.payments
FOR UPDATE
USING (
EXISTS (
SELECT 1
FROM public.organization_members om
WHERE om.organization_id = payments.organization_id
AND om.user_id = auth.uid()
AND om.role IN ('landlord', 'manager')
)
);

-- WELFARE CHECKS

CREATE POLICY "welfare visible to operations"
ON public.welfare_checks
FOR SELECT
USING (
public.is_org_member(organization_id)
);

CREATE POLICY "operations manage welfare"
ON public.welfare_checks
FOR ALL
USING (
EXISTS (
SELECT 1
FROM public.organization_members om
WHERE om.organization_id = welfare_checks.organization_id
AND om.user_id = auth.uid()
AND om.role IN ('landlord', 'manager')
)
);

-- CONVERSATIONS

CREATE POLICY "conversation members read"
ON public.conversations
FOR SELECT
USING (
 public.is_platform_admin()
 OR (
   public.is_org_member(organization_id)
   AND public.is_conversation_member(conversations.id, auth.uid())
 )
);

-- CONVERSATION MEMBERS

CREATE POLICY "conversation participants read membership"
ON public.conversation_members
FOR SELECT
USING (
user_id = auth.uid()
OR public.is_conversation_member(conversation_members.conversation_id, auth.uid())
OR public.is_platform_admin()
);

-- MESSAGES

CREATE POLICY "conversation participants or admins read messages"
ON public.messages
FOR SELECT
USING (
public.is_platform_admin()
OR public.is_conversation_member(messages.conversation_id, auth.uid())
);

CREATE POLICY "conversation participants send messages"
ON public.messages
FOR INSERT
WITH CHECK (
sender_id = auth.uid()
AND public.is_conversation_member(messages.conversation_id, auth.uid())
);

-- MAINTENANCE TICKETS

CREATE POLICY "members read tickets"
ON public.maintenance_tickets
FOR SELECT
USING (
public.is_org_member(organization_id)
AND (
tenant_id = auth.uid()
OR EXISTS (
SELECT 1
FROM public.organization_members om
WHERE om.organization_id =
maintenance_tickets.organization_id
AND om.user_id = auth.uid()
AND om.role IN ('landlord', 'manager')
)
)
);

CREATE POLICY "tenant create tickets"
ON public.maintenance_tickets
FOR INSERT
WITH CHECK (
tenant_id = auth.uid()
AND public.is_org_member(organization_id)
);

CREATE POLICY "operations update tickets"
ON public.maintenance_tickets
FOR UPDATE
USING (
EXISTS (
SELECT 1
FROM public.organization_members om
WHERE om.organization_id =
maintenance_tickets.organization_id
AND om.user_id = auth.uid()
AND om.role IN ('landlord', 'manager')
)
);

-- AUDIT EVENTS

CREATE POLICY "operations read audit"
ON public.audit_events
FOR SELECT
USING (
public.is_org_member(organization_id)
);

-- ============================================================
-- PLATFORM TABLES
-- ============================================================

ALTER TABLE public.platform_admins ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invite_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cashflow_ledger ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.is_platform_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.platform_admins WHERE id = auth.uid()
  );
$$;

REVOKE ALL ON FUNCTION public.is_platform_admin() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_platform_admin() TO authenticated;

-- ============================================================
-- REMOVE EXISTING PLATFORM POLICIES
-- ============================================================

DROP POLICY IF EXISTS "platform admins read own record"
ON public.platform_admins;

DROP POLICY IF EXISTS "platform admins manage invites"
ON public.invite_codes;

DROP POLICY IF EXISTS "org members read invites"
ON public.invite_codes;

DROP POLICY IF EXISTS "landlords create invites"
ON public.invite_codes;

DROP POLICY IF EXISTS "org members read cashflow"
ON public.cashflow_ledger;

DROP POLICY IF EXISTS "platform admins read cashflow"
ON public.cashflow_ledger;

-- ============================================================
-- PLATFORM ADMIN POLICIES
-- ============================================================

CREATE POLICY "platform admins read own record"
ON public.platform_admins
FOR SELECT
USING (
id = auth.uid()
);

-- ============================================================
-- INVITE CODE POLICIES
-- ============================================================

CREATE POLICY "platform admins manage invites"
ON public.invite_codes
FOR ALL
USING (
EXISTS (
SELECT 1
FROM public.platform_admins
WHERE id = auth.uid()
)
)
WITH CHECK (
EXISTS (
SELECT 1
FROM public.platform_admins
WHERE id = auth.uid()
)
);

CREATE POLICY "org members read invites"
ON public.invite_codes
FOR SELECT
USING (
public.is_org_member(organization_id)
);

CREATE POLICY "landlords create invites"
ON public.invite_codes
FOR INSERT
WITH CHECK (
EXISTS (
SELECT 1
FROM public.organization_members om
WHERE om.organization_id =
invite_codes.organization_id
AND om.user_id = auth.uid()
AND om.role = 'landlord'
AND om.status = 'active'
)
);

-- ============================================================
-- CASHFLOW POLICIES
-- ============================================================

CREATE POLICY "org members read cashflow"
ON public.cashflow_ledger
FOR SELECT
USING (
public.is_org_member(organization_id)
);

CREATE POLICY "platform admins read cashflow"
ON public.cashflow_ledger
FOR SELECT
USING (
EXISTS (
SELECT 1
FROM public.platform_admins
WHERE id = auth.uid()
)
);

-- Platform administrators need read-only access to the data shown in their dashboard.
DROP POLICY IF EXISTS "platform admins read workspace data" ON public.organizations;
CREATE POLICY "platform admins read workspace data" ON public.organizations
FOR SELECT USING (public.is_platform_admin());

DROP POLICY IF EXISTS "platform admins read workspace data" ON public.profiles;
CREATE POLICY "platform admins read workspace data" ON public.profiles
FOR SELECT USING (public.is_platform_admin());

DROP POLICY IF EXISTS "platform admins read workspace data" ON public.organization_members;
CREATE POLICY "platform admins read workspace data" ON public.organization_members
FOR SELECT USING (public.is_platform_admin());

DROP POLICY IF EXISTS "platform admins read workspace data" ON public.properties;
CREATE POLICY "platform admins read workspace data" ON public.properties
FOR SELECT USING (public.is_platform_admin());

DROP POLICY IF EXISTS "platform admins read workspace data" ON public.units;
CREATE POLICY "platform admins read workspace data" ON public.units
FOR SELECT USING (public.is_platform_admin());

DROP POLICY IF EXISTS "platform admins read workspace data" ON public.tenancies;
CREATE POLICY "platform admins read workspace data" ON public.tenancies
FOR SELECT USING (public.is_platform_admin());

DROP POLICY IF EXISTS "platform admins read workspace data" ON public.payments;
CREATE POLICY "platform admins read workspace data" ON public.payments
FOR SELECT USING (public.is_platform_admin());

DROP POLICY IF EXISTS "platform admins read workspace data" ON public.welfare_checks;
CREATE POLICY "platform admins read workspace data" ON public.welfare_checks
FOR SELECT USING (public.is_platform_admin());

DROP POLICY IF EXISTS "platform admins read workspace data" ON public.maintenance_tickets;
CREATE POLICY "platform admins read workspace data" ON public.maintenance_tickets
FOR SELECT USING (public.is_platform_admin());

DROP POLICY IF EXISTS "platform admins read workspace data" ON public.invite_codes;
CREATE POLICY "platform admins read workspace data" ON public.invite_codes
FOR SELECT USING (public.is_platform_admin());

-- ============================================================================
-- SOURCE: supabase/profile_deletion.sql
-- ============================================================================
-- NestTrack production profile/deletion hardening. Apply after schema.sql and rls.sql.
-- These SECURITY DEFINER functions centralize destructive authorization and cascading cleanup.

alter table profiles alter column role drop not null;
alter table profiles drop constraint if exists profiles_role_check;
alter table profiles add constraint profiles_role_check check (role is null or role in ('landlord','manager','tenant'));

create or replace function public.is_active_landlord(target_org uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from organization_members om
    where om.organization_id=target_org and om.user_id=auth.uid()
      and om.role='landlord' and om.status='active');
$$;

-- Only the account owner can delete their own avatar object.
create policy "Users delete their own avatar" on storage.objects for delete
using (bucket_id='avatars' and (storage.foldername(name))[1]=auth.uid()::text);

-- Restrict destructive operations to explicit RPCs; do not grant broad DELETE policies.
create or replace function public.delete_property_as_landlord(p_property_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare org_id uuid;
begin
  select organization_id into org_id from properties where id=p_property_id;
  if org_id is null or not is_active_landlord(org_id) then raise exception 'Not authorized'; end if;
  delete from properties where id=p_property_id;
end; $$;

create or replace function public.delete_unit_as_landlord(p_unit_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare org_id uuid;
begin
  select organization_id into org_id from units where id=p_unit_id;
  if org_id is null or not is_active_landlord(org_id) then raise exception 'Not authorized'; end if;
  delete from units where id=p_unit_id;
end; $$;

create or replace function public.delete_organization_as_landlord(p_organization_id uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not is_active_landlord(p_organization_id) then raise exception 'Not authorized'; end if;
  delete from organizations where id=p_organization_id;
end; $$;

create or replace function public.delete_tenant_account(p_tenant_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare shared_org uuid;
begin
  select om.organization_id into shared_org from organization_members om
  where om.user_id=p_tenant_id and om.role='tenant'
    and exists (select 1 from organization_members me where me.organization_id=om.organization_id and me.user_id=auth.uid() and me.role='landlord' and me.status='active')
  limit 1;
  if shared_org is null then raise exception 'Not authorized'; end if;
  delete from auth.users where id=p_tenant_id;
end; $$;

-- Self deletion relies on FK ON DELETE CASCADE already present for profile/membership records.
-- Remove tenant references that are intentionally nullable before deleting auth user.
create or replace function public.delete_my_account()
returns void language plpgsql security definer set search_path=public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  update units set current_tenant_id=null, status='vacant' where current_tenant_id=auth.uid();
  delete from auth.users where id=auth.uid();
end; $$;


create or replace function public.admin_delete_landlord(p_landlord_id uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not exists (select 1 from public.profiles where id=auth.uid() and role='admin') then
    raise exception 'Not authorized';
  end if;
  if not exists (select 1 from public.profiles where id=p_landlord_id and role='landlord') then
    raise exception 'Landlord not found';
  end if;
  delete from auth.users where id=p_landlord_id;
end; $$;
revoke all on function public.admin_delete_landlord(uuid) from public;
grant execute on function public.admin_delete_landlord(uuid) to authenticated;

-- ============================================================================
-- SOURCE: supabase/onboarding.sql
-- ============================================================================
-- Secure onboarding RPC used by the browser after Supabase Auth signup.
create or replace function public.finish_onboarding(
  p_full_name text,
  p_role text,
  p_org_name text default null,
  p_invite_code text default null
) returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  uid uuid := auth.uid();
  oid uuid;
  inv invite_codes%rowtype;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_role not in ('landlord','manager','tenant') then
    raise exception 'Invalid NestTrack role';
  end if;

  -- Every account gets a profile. Organization membership is deliberately
  -- separate from account creation for managers and tenants.
  insert into profiles(id,full_name,email,role)
  select uid,p_full_name,email,p_role from auth.users where id=uid
  on conflict(id) do update set
    full_name=excluded.full_name,
    role=excluded.role,
    email=coalesce(excluded.email,profiles.email);

  if p_role='landlord' then
    if nullif(trim(p_org_name),'') is null then
      raise exception 'Organization name is required for landlord accounts';
    end if;
    insert into organizations(name) values(trim(p_org_name)) returning id into oid;
    insert into organization_members(organization_id,user_id,role)
    values(oid,uid,'landlord')
    on conflict (organization_id,user_id) do update set role='landlord',status='active';
    return oid;
  end if;

  -- Manager and tenant accounts are independent accounts. They do not need
  -- an invite code at signup. Membership is granted only by the secure
  -- invitation-link acceptance RPC after authentication.
  return null;
end $$;

grant execute on function public.finish_onboarding(text,text,text,text) to authenticated;

create or replace function public.ensure_organization_invite_codes()
returns void language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); org record; invite_role text; code_prefix text; generated_code text; inserted_rows integer;
begin
 if uid is null then raise exception 'Not authenticated'; end if;
 for org in
   select organization_id from public.organization_members
   where user_id=uid and role='landlord' and status='active'
   order by organization_id
 loop
   perform 1 from public.organizations where id=org.organization_id for update;
   foreach invite_role in array array['manager','tenant'] loop
     update public.invite_codes set active=false
     where organization_id=org.organization_id and role=invite_role and active=true
       and ((expires_at is not null and expires_at<=now()) or (max_uses is not null and used_count>=max_uses));
     if not exists(select 1 from public.invite_codes where organization_id=org.organization_id and role=invite_role and active=true) then
       code_prefix:=case when invite_role='manager' then 'NT-MGR-' else 'NT-TEN-' end;
       loop
         generated_code:=code_prefix||upper(encode(extensions.gen_random_bytes(5),'hex'));
         insert into public.invite_codes(organization_id,code,role,created_by)
         values(org.organization_id,generated_code,invite_role,uid)
         on conflict(code) do nothing;
         get diagnostics inserted_rows=row_count;
         exit when inserted_rows=1;
       end loop;
     end if;
   end loop;
 end loop;
end $$;
revoke all on function public.ensure_organization_invite_codes() from public, anon;
grant execute on function public.ensure_organization_invite_codes() to authenticated;

create or replace function public.get_or_create_direct_conversation(p_other uuid)
returns uuid language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); cid uuid; oid uuid;
begin
 select organization_id into oid from organization_members where user_id=uid and status='active' limit 1;
 select c.id into cid from conversations c where c.organization_id=oid and exists(select 1 from conversation_members a where a.conversation_id=c.id and a.user_id=uid) and exists(select 1 from conversation_members b where b.conversation_id=c.id and b.user_id=p_other) limit 1;
 if cid is null then insert into conversations(organization_id) values(oid) returning id into cid; insert into conversation_members(conversation_id,user_id) values(cid,uid),(cid,p_other); end if;
 return cid;
end $$;
grant execute on function public.get_or_create_direct_conversation(uuid) to authenticated;

-- Standardized validation constraints
create or replace function public.validate_profile_fields()
returns trigger language plpgsql as $$
begin
  if new.email is not null and new.email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]{2,}$' then
    raise exception 'Invalid email address';
  end if;
  if new.phone is not null and new.phone !~ '^\+[1-9][0-9]{7,14}$' then
    raise exception 'Phone must include a valid country code';
  end if;
  return new;
end; $$;

drop trigger if exists validate_profile_fields on public.profiles;
create trigger validate_profile_fields before insert or update on public.profiles
for each row execute function public.validate_profile_fields();

-- ============================================================================
-- SOURCE: supabase/migrations/20261005_feature_expansion.sql
-- ============================================================================
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

-- ============================================================================
-- SOURCE: supabase/migrations/20261005_platform_admin_messaging.sql
-- ============================================================================
-- NestTrack platform administration + universal direct messaging
-- Forward-only migration. Safe to re-run.

-- Allow participant-scoped conversations that are not tied to one organization.
-- This is required when users from different organizations message each other,
-- and for platform-admin conversations.
alter table public.conversations
  alter column organization_id drop not null;

-- Platform admin management. Bootstrap the first admin through the documented
-- Supabase SQL process; thereafter only an existing platform admin can grant
-- or revoke another platform admin.
create or replace function public.grant_platform_admin(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  if not exists (select 1 from public.platform_admins where id = auth.uid()) then
    raise exception 'Platform administrator access required';
  end if;
  if not exists (select 1 from auth.users where id = p_user_id) then
    raise exception 'User does not exist';
  end if;
  insert into public.platform_admins(id) values (p_user_id)
  on conflict (id) do nothing;
end;
$$;

create or replace function public.revoke_platform_admin(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare admin_count integer;
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  if not exists (select 1 from public.platform_admins where id = auth.uid()) then
    raise exception 'Platform administrator access required';
  end if;
  select count(*) into admin_count from public.platform_admins;
  if p_user_id = auth.uid() and admin_count <= 1 then
    raise exception 'The last platform administrator cannot be removed';
  end if;
  delete from public.platform_admins where id = p_user_id;
end;
$$;

revoke all on function public.grant_platform_admin(uuid) from public, anon;
revoke all on function public.revoke_platform_admin(uuid) from public, anon;
grant execute on function public.grant_platform_admin(uuid) to authenticated;
grant execute on function public.revoke_platform_admin(uuid) to authenticated;

-- Replace direct-message creation with participant-based authorization.
-- Any authenticated NestTrack user can message any other NestTrack user.
-- When the users share an organization, the conversation is associated with
-- that organization; otherwise organization_id remains NULL.
create or replace function public.get_or_create_direct_conversation(p_other uuid, p_organization_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  cid uuid;
  oid uuid;
  other_exists boolean;
  common_org uuid;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_other is null or p_other = uid then raise exception 'Invalid message recipient'; end if;

  select exists(select 1 from auth.users where id = p_other) into other_exists;
  if not other_exists then raise exception 'Recipient account does not exist'; end if;

  -- Prefer an explicitly supplied organization only when both participants
  -- are active members of it. Otherwise derive a shared organization.
  if p_organization_id is not null
     and exists(select 1 from public.organization_members where organization_id=p_organization_id and user_id=uid and status='active')
     and exists(select 1 from public.organization_members where organization_id=p_organization_id and user_id=p_other and status='active') then
    common_org := p_organization_id;
  else
    select om1.organization_id into common_org
    from public.organization_members om1
    join public.organization_members om2 on om2.organization_id=om1.organization_id
    where om1.user_id=uid and om1.status='active'
      and om2.user_id=p_other and om2.status='active'
    order by om1.organization_id
    limit 1;
  end if;

  select c.id into cid
  from public.conversations c
  where c.organization_id is not distinct from common_org
    and exists(select 1 from public.conversation_members a where a.conversation_id=c.id and a.user_id=uid)
    and exists(select 1 from public.conversation_members b where b.conversation_id=c.id and b.user_id=p_other)
  limit 1;

  if cid is null then
    insert into public.conversations(organization_id) values(common_org) returning id into cid;
    insert into public.conversation_members(conversation_id,user_id) values(cid,uid),(cid,p_other);
  end if;
  return cid;
end;
$$;

revoke all on function public.get_or_create_direct_conversation(uuid,uuid) from public, anon;
grant execute on function public.get_or_create_direct_conversation(uuid,uuid) to authenticated;

-- Avoid recursive RLS evaluation when checking conversation membership.
create or replace function public.is_conversation_member(
  p_conversation_id uuid,
  p_user_id uuid
)
returns boolean
language sql
stable
security definer
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

revoke all on function public.is_conversation_member(uuid, uuid)
from public, anon;

grant execute on function public.is_conversation_member(uuid, uuid)
to authenticated;

-- Replace conversation policies with participant/admin-aware policies.
drop policy if exists "conversation members read" on public.conversations;
drop policy if exists "conversation participants or admins read conversations" on public.conversations;
create policy "conversation participants or admins read conversations"
on public.conversations
for select
using (
  public.is_platform_admin()
  or public.is_conversation_member(conversations.id, auth.uid())
);

-- Ensure users can read their own participant rows regardless of organization.
drop policy if exists "conversation members read membership" on public.conversation_members;
drop policy if exists "conversation participants read membership" on public.conversation_members;
create policy "conversation participants read membership"
on public.conversation_members
for select
using (
  user_id=auth.uid()
  or public.is_conversation_member(conversation_members.conversation_id, auth.uid())
  or public.is_platform_admin()
);

-- Message reads remain participant-scoped; admins may read platform conversations
-- because the admin dashboard is an authorized platform communication surface.
drop policy if exists "conversation participants read messages" on public.messages;
drop policy if exists "conversation participants or admins read messages" on public.messages;
create policy "conversation participants or admins read messages"
on public.messages
for select
using (
  public.is_platform_admin()
  or public.is_conversation_member(messages.conversation_id, auth.uid())
);

-- No client can add itself to arbitrary conversations. Conversation creation is
-- performed by the security-definer RPC above.
drop policy if exists "conversation participants send messages" on public.messages;
create policy "conversation participants send messages"
on public.messages
for insert
with check (
  sender_id=auth.uid()
  and public.is_conversation_member(messages.conversation_id, auth.uid())
);

-- Platform admins can inspect all profiles and memberships through existing
-- admin policies; keep normal users restricted by the existing RLS boundary.

-- ============================================================================
-- SOURCE: supabase/migrations/20261006_fix_conversation_members_rls_recursion.sql
-- ============================================================================
-- Fix conversation_members infinite RLS recursion.
-- Apply this migration to an existing Supabase database after the current
-- feature and platform-admin migrations.

CREATE OR REPLACE FUNCTION public.is_conversation_member(
  p_conversation_id uuid,
  p_user_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.conversation_members cm
    WHERE cm.conversation_id = p_conversation_id
      AND cm.user_id = p_user_id
      AND p_user_id = auth.uid()
  );
$$;

REVOKE ALL ON FUNCTION public.is_conversation_member(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_conversation_member(uuid, uuid) TO authenticated;

DROP POLICY IF EXISTS "conversation members read" ON public.conversations;
DROP POLICY IF EXISTS "conversation participants or admins read conversations" ON public.conversations;
CREATE POLICY "conversation participants or admins read conversations"
ON public.conversations FOR SELECT
USING (
  public.is_platform_admin()
  OR public.is_conversation_member(conversations.id, auth.uid())
);

DROP POLICY IF EXISTS "conversation members read membership" ON public.conversation_members;
DROP POLICY IF EXISTS "conversation participants read membership" ON public.conversation_members;
CREATE POLICY "conversation participants read membership"
ON public.conversation_members FOR SELECT
USING (
  user_id = auth.uid()
  OR public.is_conversation_member(conversation_members.conversation_id, auth.uid())
  OR public.is_platform_admin()
);

DROP POLICY IF EXISTS "conversation participants read messages" ON public.messages;
DROP POLICY IF EXISTS "conversation participants or admins read messages" ON public.messages;
CREATE POLICY "conversation participants or admins read messages"
ON public.messages FOR SELECT
USING (
  public.is_platform_admin()
  OR public.is_conversation_member(messages.conversation_id, auth.uid())
);

DROP POLICY IF EXISTS "conversation participants send messages" ON public.messages;
CREATE POLICY "conversation participants send messages"
ON public.messages FOR INSERT
WITH CHECK (
  sender_id = auth.uid()
  AND public.is_conversation_member(messages.conversation_id, auth.uid())
);

-- ============================================================================
-- SOURCE: supabase/migrations/20261006_clean_architecture.sql
-- ============================================================================
-- NestTrack clean architecture: platform -> organization -> property -> unit,
-- with communication that can operate at property, organization, shared and platform scope.

create table if not exists public.channels (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid references public.organizations(id) on delete cascade,
  property_id uuid references public.properties(id) on delete cascade,
  conversation_id uuid references public.conversations(id) on delete cascade,
  name text not null,
  channel_type text not null check (channel_type in ('property','organization','shared','platform')),
  visibility text not null default 'organization' check (visibility in ('private','organization','cross_organization','platform')),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  check ((channel_type='property' and property_id is not null) or channel_type<>'property'),
  check ((channel_type in ('organization','property') and organization_id is not null) or channel_type in ('shared','platform'))
);

alter table public.channels add column if not exists conversation_id uuid references public.conversations(id) on delete cascade;
create unique index if not exists channels_conversation_unique_idx on public.channels(conversation_id) where conversation_id is not null;

create table if not exists public.channel_members (
  channel_id uuid not null references public.channels(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key(channel_id,user_id)
);

create index if not exists channels_org_idx on public.channels(organization_id);
create index if not exists channels_property_idx on public.channels(property_id);
create index if not exists channel_members_user_idx on public.channel_members(user_id);

alter table public.channels enable row level security;
alter table public.channel_members enable row level security;

-- Never query channel_members directly from a channel_members policy. That
-- causes PostgreSQL to evaluate the same policy recursively. The helper runs
-- with definer privileges and is restricted to the current authenticated user.
create or replace function public.is_channel_member(
  p_channel_id uuid,
  p_user_id uuid default auth.uid()
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_user_id = auth.uid()
    and exists (
      select 1
      from public.channel_members cm
      where cm.channel_id = p_channel_id
        and cm.user_id = p_user_id
    );
$$;
revoke all on function public.is_channel_member(uuid, uuid) from public, anon;
grant execute on function public.is_channel_member(uuid, uuid) to authenticated;

drop policy if exists "channel members read channels" on public.channels;
create policy "channel members read channels" on public.channels for select using (
  public.is_platform_admin()
  or public.is_channel_member(channels.id)
  or (organization_id is not null and public.is_org_member(organization_id))
);

drop policy if exists "channel members read membership" on public.channel_members;
create policy "channel members read membership" on public.channel_members for select using (
  user_id=auth.uid() or public.is_platform_admin()
  or public.is_channel_member(channel_members.channel_id)
);

-- Channel lifecycle is backed by the existing conversation/message model.
-- Every channel gets one conversation and its members are mirrored into
-- conversation_members, so message RLS and read receipts remain consistent.
create or replace function public.create_channel(
  p_name text,
  p_channel_type text,
  p_visibility text default 'organization',
  p_organization_id uuid default null,
  p_property_id uuid default null,
  p_member_ids uuid[] default '{}'
)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
  channel_id uuid;
  conversation_id uuid;
  target_org uuid := p_organization_id;
  member_id uuid;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if nullif(trim(p_name), '') is null then raise exception 'Channel name is required'; end if;
  if p_channel_type not in ('property','organization','shared','platform') then raise exception 'Invalid channel type'; end if;
  if p_visibility not in ('private','organization','cross_organization','platform') then raise exception 'Invalid channel visibility'; end if;
  if p_channel_type in ('organization','property') and target_org is null then raise exception 'Organization is required'; end if;
  if p_channel_type='property' and p_property_id is null then raise exception 'Property is required'; end if;
  if p_channel_type='property' and not exists(select 1 from properties where id=p_property_id and organization_id=target_org) then raise exception 'Property is outside the organization'; end if;
  if p_channel_type in ('shared','platform') and not public.is_platform_admin() then raise exception 'Platform administrator access required'; end if;
  if p_channel_type in ('organization','property') and not public.has_org_capability(target_org,'manage_members') then raise exception 'Not authorized to create channels'; end if;
  insert into conversations(organization_id, property_id)
    values(case when p_channel_type in ('shared','platform') then null else target_org end, p_property_id)
    returning id into conversation_id;
  insert into channels(organization_id, property_id, conversation_id, name, channel_type, visibility, created_by)
    values(case when p_channel_type in ('shared','platform') then null else target_org end, p_property_id, conversation_id, trim(p_name), p_channel_type, p_visibility, uid)
    returning id into channel_id;
  insert into conversation_members(conversation_id,user_id) values(conversation_id,uid) on conflict do nothing;
  foreach member_id in array coalesce(p_member_ids,'{}') loop
    if member_id <> uid then
      if p_channel_type in ('organization','property') and not exists(select 1 from organization_members where organization_id=target_org and user_id=member_id and status='active') then
        raise exception 'Every channel member must belong to the organization';
      end if;
      insert into channel_members(channel_id,user_id) values(channel_id,member_id) on conflict do nothing;
      insert into conversation_members(conversation_id,user_id) values(conversation_id,member_id) on conflict do nothing;
    end if;
  end loop;
  insert into channel_members(channel_id,user_id) values(channel_id,uid) on conflict do nothing;
  return channel_id;
end;
$$;
revoke all on function public.create_channel(text,text,text,uuid,uuid,uuid[]) from public, anon;
grant execute on function public.create_channel(text,text,text,uuid,uuid,uuid[]) to authenticated;

create or replace function public.add_channel_member(p_channel_id uuid, p_user_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare uid uuid := auth.uid(); cid uuid; conv uuid; org_id uuid; channel_type text;
begin
  select id, conversation_id, organization_id, channel_type into cid, conv, org_id, channel_type from channels where id=p_channel_id;
  if cid is null then raise exception 'Channel not found'; end if;
  if not (public.is_platform_admin() or public.has_org_capability(org_id,'manage_members')) then raise exception 'Not authorized'; end if;
  if channel_type in ('organization','property') and not exists(select 1 from organization_members where organization_id=org_id and user_id=p_user_id and status='active') then raise exception 'User is not an organization member'; end if;
  insert into channel_members(channel_id,user_id) values(cid,p_user_id) on conflict do nothing;
  insert into conversation_members(conversation_id,user_id) values(conv,p_user_id) on conflict do nothing;
end; $$;
revoke all on function public.add_channel_member(uuid,uuid) from public, anon;
grant execute on function public.add_channel_member(uuid,uuid) to authenticated;

create or replace function public.remove_channel_member(p_channel_id uuid, p_user_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare uid uuid := auth.uid(); cid uuid; conv uuid; org_id uuid;
begin
  select id, conversation_id, organization_id into cid, conv, org_id from channels where id=p_channel_id;
  if cid is null then raise exception 'Channel not found'; end if;
  if p_user_id=uid then raise exception 'Use channel leave instead'; end if;
  if not (public.is_platform_admin() or public.has_org_capability(org_id,'manage_members')) then raise exception 'Not authorized'; end if;
  delete from channel_members where channel_id=cid and user_id=p_user_id;
  delete from conversation_members where conversation_id=conv and user_id=p_user_id;
end; $$;
revoke all on function public.remove_channel_member(uuid,uuid) from public, anon;
grant execute on function public.remove_channel_member(uuid,uuid) to authenticated;

-- No INSERT/UPDATE/DELETE policies are granted to the browser. The validated
-- security-definer RPCs above are the only membership write path.
drop policy if exists "channel members insert" on public.channel_members;
drop policy if exists "channel members delete" on public.channel_members;

-- Safe user directory for messaging. This exposes only contact fields needed for
-- recipient discovery; organization membership remains enforced separately.
create or replace function public.get_user_directory()
returns table (
  user_id uuid,
  full_name text,
  email text,
  phone text,
  avatar_url text,
  role text,
  organization_id uuid,
  organization_name text
)
language sql
stable
security definer
set search_path = public
as $$
  select p.id, p.full_name, p.email, p.phone, p.avatar_url, p.role,
         om.organization_id, o.name
  from public.profiles p
  left join public.organization_members om on om.user_id=p.id and om.status='active'
  left join public.organizations o on o.id=om.organization_id
  where auth.uid() is not null
  order by p.full_name;
$$;

revoke all on function public.get_user_directory() from public, anon;
grant execute on function public.get_user_directory() to authenticated;

-- ============================================================================
-- SOURCE: supabase/migrations/20261006_property_management.sql
-- ============================================================================
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

-- ============================================================================
-- SOURCE: supabase/migrations/20261006_independent_signup_and_tenant_assignment.sql
-- ============================================================================
-- Independent manager/tenant signup and assignment without invitation links.
-- Apply after 20261006_property_management.sql.

create or replace function public.create_independent_profile(
  p_full_name text,
  p_role text,
  p_phone text default null
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  uid uuid := auth.uid();
  email_address text;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_role not in ('manager','tenant') then raise exception 'Only manager and tenant accounts can use independent signup'; end if;
  if nullif(trim(p_full_name),'') is null then raise exception 'Full name is required'; end if;

  select email into email_address from auth.users where id=uid;
  if email_address is null then raise exception 'Authenticated user email is missing'; end if;

  insert into public.profiles(id,full_name,email,role,phone)
  values(uid,trim(p_full_name),email_address,p_role,nullif(trim(p_phone),''))
  on conflict(id) do update set
    full_name=excluded.full_name,
    email=excluded.email,
    phone=excluded.phone;

  return uid;
end;
$$;

revoke all on function public.create_independent_profile(text,text,text) from public,anon;
grant execute on function public.create_independent_profile(text,text,text) to authenticated;

-- A manager/landlord can assign a standalone tenant account directly to a unit.
-- If the tenant is not yet a member of the organization, membership is created
-- as part of the assignment. This removes the invitation-link dependency while
-- keeping all writes inside a security-definer authorization boundary.
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
language plpgsql
security definer
set search_path=public
as $$
declare
  tid uuid;
  unit_org uuid;
  tenant_member boolean;
  tenant_role text;
begin
  if not public.has_org_capability(p_organization_id,'assign_tenants') then raise exception 'Not authorized'; end if;
  select organization_id into unit_org from public.units where id=p_unit_id for update;
  if unit_org is distinct from p_organization_id then raise exception 'Unit is outside organization'; end if;

  select role into tenant_role from public.profiles where id=p_tenant_id;
  if tenant_role is distinct from 'tenant' then raise exception 'Selected account is not a tenant'; end if;

  select exists(
    select 1 from public.organization_members
    where organization_id=p_organization_id and user_id=p_tenant_id and role='tenant' and status='active'
  ) into tenant_member;

  if not tenant_member then
    insert into public.organization_members(organization_id,user_id,role,status,invited_by,joined_at)
    values(p_organization_id,p_tenant_id,'tenant','active',auth.uid(),now())
    on conflict (organization_id,user_id) do update set role='tenant',status='active',joined_at=coalesce(organization_members.joined_at,now());
  end if;

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

revoke all on function public.assign_tenant_to_unit(uuid,uuid,uuid,date,numeric,text,numeric) from public,anon;
grant execute on function public.assign_tenant_to_unit(uuid,uuid,uuid,date,numeric,text,numeric) to authenticated;

-- Create manager/tenant profiles at auth-user creation time as well. This makes
-- signup work when Supabase email confirmation is enabled, because no browser
-- session is required to establish the basic profile.
create or replace function public.handle_independent_signup_profile()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  signup_role text := coalesce(new.raw_user_meta_data->>'role','');
  signup_name text := nullif(trim(new.raw_user_meta_data->>'full_name'),'');
  signup_phone text := nullif(trim(new.raw_user_meta_data->>'phone'),'');
begin
  if signup_role in ('manager','tenant') then
    insert into public.profiles(id,full_name,email,role,phone)
    values(new.id,coalesce(signup_name,split_part(new.email,'@',1)),new.email,signup_role,signup_phone)
    on conflict(id) do update set
      full_name=excluded.full_name,
      email=excluded.email,
      phone=coalesce(excluded.phone,profiles.phone);
  end if;
  return new;
end;
$$;

drop trigger if exists on_auth_user_independent_signup on auth.users;
create trigger on_auth_user_independent_signup
after insert on auth.users
for each row execute function public.handle_independent_signup_profile();

-- ============================================================================
-- SOURCE: supabase/migrations/20261006_messaging_independent_accounts.sql
-- ============================================================================
-- NestTrack
-- 20261006_messaging_independent_accounts.sql
-- Messaging hardening for independently created Manager/Tenant/Landlord accounts.
--
-- RUN ORDER:
--   1. 20261006_messaging_independent_accounts.sql
--   2. 20261006_messaging_end_to_end.sql
--
-- This migration is idempotent.

begin;

-- Direct conversations can exist before an account is assigned to an
-- organization. The end-to-end migration also enforces this, but keeping the
-- change here makes this migration safe to apply on its own after the base
-- messaging schema exists.
alter table public.conversations
  alter column organization_id drop not null;

-- ---------------------------------------------------------------------------
-- Membership helper
-- ---------------------------------------------------------------------------
-- SECURITY DEFINER prevents conversation_members RLS recursion when the
-- helper is used by conversation/messages policies.
create or replace function public.is_conversation_member(
  p_conversation_id uuid,
  p_user_id uuid
)
returns boolean
language sql
stable
security definer
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

-- ---------------------------------------------------------------------------
-- Read-state RPC
-- ---------------------------------------------------------------------------
create or replace function public.mark_conversation_read(
  p_conversation_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if not public.is_conversation_member(p_conversation_id, auth.uid()) then
    raise exception 'Not authorized';
  end if;

  update public.messages
     set read_at = now()
   where conversation_id = p_conversation_id
     and sender_id is distinct from auth.uid()
     and read_at is null;
end;
$$;

revoke all on function public.mark_conversation_read(uuid) from public, anon;
grant execute on function public.mark_conversation_read(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- RLS: conversations
-- ---------------------------------------------------------------------------
alter table public.conversations enable row level security;

drop policy if exists "conversation members read" on public.conversations;
drop policy if exists "conversation participants or admins read conversations" on public.conversations;

create policy "conversation participants or admins read conversations"
on public.conversations
for select
using (
  public.is_conversation_member(id, auth.uid())
  or public.is_platform_admin()
);

-- Clients must not create arbitrary conversations. The security-definer
-- get_or_create/send RPCs in the next migration create them safely.
drop policy if exists "conversation members insert" on public.conversations;
drop policy if exists "conversation participants insert conversations" on public.conversations;

-- ---------------------------------------------------------------------------
-- RLS: conversation_members
-- ---------------------------------------------------------------------------
alter table public.conversation_members enable row level security;

drop policy if exists "conversation members read membership" on public.conversation_members;
drop policy if exists "conversation participants read membership" on public.conversation_members;

create policy "conversation participants read membership"
on public.conversation_members
for select
using (
  user_id = auth.uid()
  or public.is_conversation_member(conversation_id, auth.uid())
  or public.is_platform_admin()
);

-- Membership changes are owned by security-definer messaging functions.
drop policy if exists "conversation members insert" on public.conversation_members;
drop policy if exists "conversation members delete" on public.conversation_members;
drop policy if exists "conversation members update" on public.conversation_members;

-- ---------------------------------------------------------------------------
-- RLS: messages
-- ---------------------------------------------------------------------------
alter table public.messages enable row level security;

drop policy if exists "conversation participants read messages" on public.messages;
drop policy if exists "conversation participants or admins read messages" on public.messages;

create policy "conversation participants or admins read messages"
on public.messages
for select
using (
  public.is_conversation_member(conversation_id, auth.uid())
  or public.is_platform_admin()
);

drop policy if exists "conversation participants send messages" on public.messages;

create policy "conversation participants send messages"
on public.messages
for insert
with check (
  sender_id = auth.uid()
  and public.is_conversation_member(conversation_id, auth.uid())
);

-- Clients cannot modify another user's message or its conversation.
drop policy if exists "conversation participants update messages" on public.messages;
drop policy if exists "conversation participants delete messages" on public.messages;

-- ---------------------------------------------------------------------------
-- Realtime
-- ---------------------------------------------------------------------------
do $$
begin
  begin
    alter publication supabase_realtime add table public.messages;
  exception
    when duplicate_object then null;
  end;

  begin
    alter publication supabase_realtime add table public.conversation_members;
  exception
    when duplicate_object then null;
  end;
end
$$;

commit;

-- ============================================================================
-- SOURCE: supabase/migrations/20261006_messaging_end_to_end.sql
-- ============================================================================
-- NestTrack
-- 20261006_messaging_end_to_end.sql
-- End-to-end direct messaging, notifications, RLS and Realtime hardening.
--
-- RUN AFTER:
--   20261006_messaging_independent_accounts.sql
--
-- IMPORTANT:
-- The frontend should call send_direct_message() for direct messages.
-- The RPC performs recipient validation, conversation creation/reuse and
-- message insertion in one database transaction.
--
-- This migration is idempotent.

begin;

-- ---------------------------------------------------------------------------
-- Direct conversations may exist without an organization.
-- ---------------------------------------------------------------------------
alter table public.conversations
  alter column organization_id drop not null;

create index if not exists conversations_org_idx
  on public.conversations(organization_id);

create index if not exists conversation_members_pair_idx
  on public.conversation_members(conversation_id, user_id);

-- ---------------------------------------------------------------------------
-- Reuse one direct conversation for a participant pair.
-- ---------------------------------------------------------------------------
create or replace function public.get_or_create_direct_conversation(
  p_other uuid,
  p_organization_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  cid uuid;
  common_org uuid;
  pair_key text;
begin
  if uid is null then
    raise exception 'Not authenticated';
  end if;

  if p_other is null or p_other = uid then
    raise exception 'Invalid message recipient';
  end if;

  if not exists (
    select 1 from auth.users where id = p_other
  ) then
    raise exception 'Recipient account does not exist';
  end if;

  if not exists (
    select 1 from public.profiles where id = p_other
  ) then
    raise exception 'Recipient is not a NestTrack user';
  end if;

  -- Serialize creation for the same two users so concurrent first messages
  -- cannot create two direct threads.
  pair_key :=
    least(uid::text, p_other::text) || ':' ||
    greatest(uid::text, p_other::text);

  perform pg_advisory_xact_lock(hashtextextended(pair_key, 0));

  -- Prefer the explicitly supplied organization only if both users belong
  -- to it. Otherwise find a shared active organization.
  if p_organization_id is not null
     and exists (
       select 1
         from public.organization_members
        where organization_id = p_organization_id
          and user_id = uid
          and status = 'active'
     )
     and exists (
       select 1
         from public.organization_members
        where organization_id = p_organization_id
          and user_id = p_other
          and status = 'active'
     ) then

    common_org := p_organization_id;

  else

    select om1.organization_id
      into common_org
      from public.organization_members om1
      join public.organization_members om2
        on om2.organization_id = om1.organization_id
       and om2.user_id = p_other
       and om2.status = 'active'
     where om1.user_id = uid
       and om1.status = 'active'
     order by om1.organization_id
     limit 1;

  end if;

  -- Never reuse a channel conversation as a direct thread.
  select c.id
    into cid
    from public.conversations c
   where not exists (
           select 1
             from public.channels ch
            where ch.conversation_id = c.id
         )
     and exists (
           select 1
             from public.conversation_members cm
            where cm.conversation_id = c.id
              and cm.user_id = uid
         )
     and exists (
           select 1
             from public.conversation_members cm
            where cm.conversation_id = c.id
              and cm.user_id = p_other
         )
     and (
           select count(*)
             from public.conversation_members cm
            where cm.conversation_id = c.id
         ) = 2
   order by c.created_at
   limit 1
   for update;

  if cid is null then
    insert into public.conversations(organization_id)
    values (common_org)
    returning id into cid;

    insert into public.conversation_members(conversation_id, user_id)
    values
      (cid, uid),
      (cid, p_other)
    on conflict (conversation_id, user_id) do nothing;

  elsif common_org is not null then
    update public.conversations
       set organization_id = coalesce(organization_id, common_org)
     where id = cid;
  end if;

  return cid;
end;
$$;

revoke all on function public.get_or_create_direct_conversation(uuid, uuid)
  from public, anon;
grant execute on function public.get_or_create_direct_conversation(uuid, uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Atomic direct-message send RPC
-- ---------------------------------------------------------------------------
-- This is the key delivery fix. The browser no longer has to:
--   1. create/find a conversation
--   2. then separately insert the message.
--
-- Both operations happen in one transaction under SECURITY DEFINER.
create or replace function public.send_direct_message(
  p_recipient_id uuid,
  p_body text,
  p_organization_id uuid default null
)
returns public.messages
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  cid uuid;
  new_message public.messages;
begin
  if uid is null then
    raise exception 'Not authenticated';
  end if;

  if p_recipient_id is null or p_recipient_id = uid then
    raise exception 'Invalid message recipient';
  end if;

  if p_body is null or btrim(p_body) = '' then
    raise exception 'Message cannot be empty';
  end if;

  if length(p_body) > 5000 then
    raise exception 'Message is too long';
  end if;

  cid := public.get_or_create_direct_conversation(
    p_recipient_id,
    p_organization_id
  );

  insert into public.messages(
    conversation_id,
    sender_id,
    body
  )
  values (
    cid,
    uid,
    btrim(p_body)
  )
  returning * into new_message;

  return new_message;
end;
$$;

revoke all on function public.send_direct_message(uuid, text, uuid)
  from public, anon;
grant execute on function public.send_direct_message(uuid, text, uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Associate an existing direct conversation after organization membership.
-- ---------------------------------------------------------------------------
create or replace function public.associate_direct_conversations_after_membership()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'active' then
    update public.conversations c
       set organization_id = new.organization_id
     where c.organization_id is null
       and not exists (
         select 1
           from public.channels ch
          where ch.conversation_id = c.id
       )
       and exists (
         select 1
           from public.conversation_members cm
          where cm.conversation_id = c.id
            and cm.user_id = new.user_id
       )
       and exists (
         select 1
           from public.conversation_members cm
           join public.organization_members om
             on om.user_id = cm.user_id
          where cm.conversation_id = c.id
            and cm.user_id <> new.user_id
            and om.organization_id = new.organization_id
            and om.status = 'active'
       );
  end if;

  return new;
end;
$$;

drop trigger if exists associate_direct_conversations_on_membership
  on public.organization_members;

create trigger associate_direct_conversations_on_membership
after insert or update of organization_id, status
on public.organization_members
for each row
execute function public.associate_direct_conversations_after_membership();

-- ---------------------------------------------------------------------------
-- Server-side message notifications
-- ---------------------------------------------------------------------------
create or replace function public.notify_message_recipients()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  conversation_org uuid;
  channel_message boolean;
  sender_name text;
  notification_title text;
begin
  select c.organization_id
    into conversation_org
    from public.conversations c
   where c.id = new.conversation_id;

  select exists (
    select 1
      from public.channels ch
     where ch.conversation_id = new.conversation_id
  )
  into channel_message;

  select coalesce(p.full_name, 'A NestTrack user')
    into sender_name
    from public.profiles p
   where p.id = new.sender_id;

  notification_title :=
    case
      when channel_message then 'New channel message'
      else 'New direct message'
    end;

  insert into public.notifications(
    recipient_user_id,
    organization_id,
    event_type,
    title,
    body,
    related_entity_type,
    related_entity_id
  )
  select
    cm.user_id,
    conversation_org,
    case
      when channel_message then 'channel_message'
      else 'direct_message'
    end,
    notification_title,
    sender_name || ': ' || left(new.body, 240),
    'message',
    new.id
  from public.conversation_members cm
  where cm.conversation_id = new.conversation_id
    and cm.user_id is distinct from new.sender_id;

  return new;
end;
$$;

drop trigger if exists message_notification_trigger on public.messages;

create trigger message_notification_trigger
after insert on public.messages
for each row
execute function public.notify_message_recipients();

-- ---------------------------------------------------------------------------
-- Notification access
-- ---------------------------------------------------------------------------
alter table public.notifications enable row level security;

drop policy if exists "notifications own read" on public.notifications;
create policy "notifications own read"
on public.notifications
for select
using (recipient_user_id = auth.uid());

drop policy if exists "notifications own update" on public.notifications;
create policy "notifications own update"
on public.notifications
for update
using (recipient_user_id = auth.uid())
with check (recipient_user_id = auth.uid());

drop policy if exists "notifications browser insert" on public.notifications;

-- ---------------------------------------------------------------------------
-- Conversation/message read RPCs
-- ---------------------------------------------------------------------------
create or replace function public.mark_conversation_read(
  p_conversation_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null
     or not public.is_conversation_member(p_conversation_id, auth.uid()) then
    raise exception 'Not authorized';
  end if;

  update public.messages
     set read_at = now()
   where conversation_id = p_conversation_id
     and sender_id is distinct from auth.uid()
     and read_at is null;
end;
$$;

revoke all on function public.mark_conversation_read(uuid)
  from public, anon;
grant execute on function public.mark_conversation_read(uuid)
  to authenticated;

create or replace function public.mark_notification_read(
  p_notification_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.notifications
     set read_at = coalesce(read_at, now())
   where id = p_notification_id
     and recipient_user_id = auth.uid();
end;
$$;

revoke all on function public.mark_notification_read(uuid)
  from public, anon;
grant execute on function public.mark_notification_read(uuid)
  to authenticated;

create or replace function public.mark_all_notifications_read()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.notifications
     set read_at = now()
   where recipient_user_id = auth.uid()
     and read_at is null;
end;
$$;

revoke all on function public.mark_all_notifications_read()
  from public, anon;
grant execute on function public.mark_all_notifications_read()
  to authenticated;

-- ---------------------------------------------------------------------------
-- RLS: participant-scoped conversation/message reads
-- ---------------------------------------------------------------------------
alter table public.conversations enable row level security;

drop policy if exists "conversation members read" on public.conversations;
drop policy if exists "conversation participants or admins read conversations"
  on public.conversations;

create policy "conversation participants or admins read conversations"
on public.conversations
for select
using (
  public.is_platform_admin()
  or public.is_conversation_member(id, auth.uid())
);

alter table public.conversation_members enable row level security;

drop policy if exists "conversation members read membership"
  on public.conversation_members;
drop policy if exists "conversation participants read membership"
  on public.conversation_members;

create policy "conversation participants read membership"
on public.conversation_members
for select
using (
  user_id = auth.uid()
  or public.is_conversation_member(conversation_id, auth.uid())
  or public.is_platform_admin()
);

alter table public.messages enable row level security;

drop policy if exists "conversation participants read messages"
  on public.messages;
drop policy if exists "conversation participants or admins read messages"
  on public.messages;

create policy "conversation participants or admins read messages"
on public.messages
for select
using (
  public.is_platform_admin()
  or public.is_conversation_member(conversation_id, auth.uid())
);

drop policy if exists "conversation participants send messages"
  on public.messages;

create policy "conversation participants send messages"
on public.messages
for insert
with check (
  sender_id = auth.uid()
  and public.is_conversation_member(conversation_id, auth.uid())
);

-- ---------------------------------------------------------------------------
-- Read RPCs for the frontend
-- ---------------------------------------------------------------------------
create or replace function public.get_my_conversation_members()
returns table(
  conversation_id uuid,
  user_id uuid
)
language sql
stable
security definer
set search_path = public
as $$
  select cm.conversation_id, cm.user_id
    from public.conversation_members cm
   where public.is_platform_admin()
      or exists (
        select 1
          from public.conversation_members mine
         where mine.conversation_id = cm.conversation_id
           and mine.user_id = auth.uid()
      );
$$;

revoke all on function public.get_my_conversation_members()
  from public, anon;
grant execute on function public.get_my_conversation_members()
  to authenticated;

create or replace function public.get_my_messages()
returns table(
  id uuid,
  conversation_id uuid,
  sender_id uuid,
  body text,
  read_at timestamptz,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    m.id,
    m.conversation_id,
    m.sender_id,
    m.body,
    m.read_at,
    m.created_at
  from public.messages m
  where public.is_platform_admin()
     or exists (
       select 1
         from public.conversation_members cm
        where cm.conversation_id = m.conversation_id
          and cm.user_id = auth.uid()
     )
  order by m.created_at asc
  limit 1000;
$$;

revoke all on function public.get_my_messages()
  from public, anon;
grant execute on function public.get_my_messages()
  to authenticated;

-- ---------------------------------------------------------------------------
-- Repair old direct conversations that have no organization.
-- ---------------------------------------------------------------------------
update public.conversations c
   set organization_id = match.organization_id
  from (
    select
      c2.id,
      (array_agg(om.organization_id order by om.organization_id))[1]
        as organization_id
    from public.conversations c2
    join public.conversation_members cm1
      on cm1.conversation_id = c2.id
    join public.conversation_members cm2
      on cm2.conversation_id = c2.id
     and cm2.user_id <> cm1.user_id
    join public.organization_members om
      on om.user_id = cm2.user_id
     and om.status = 'active'
    where c2.organization_id is null
      and not exists (
        select 1
          from public.channels ch
         where ch.conversation_id = c2.id
      )
    group by c2.id
  ) match
 where c.id = match.id
   and c.organization_id is null;

-- ---------------------------------------------------------------------------
-- Realtime
-- ---------------------------------------------------------------------------
do $$
begin
  begin
    alter publication supabase_realtime add table public.messages;
  exception
    when duplicate_object then null;
  end;

  begin
    alter publication supabase_realtime add table public.conversation_members;
  exception
    when duplicate_object then null;
  end;

  begin
    alter publication supabase_realtime add table public.channel_members;
  exception
    when duplicate_object then null;
  end;

  begin
    alter publication supabase_realtime add table public.channels;
  exception
    when duplicate_object then null;
  end;

  begin
    alter publication supabase_realtime add table public.notifications;
  exception
    when duplicate_object then null;
  end;
end
$$;

commit;

-- ============================================================================
-- SOURCE: supabase/migrations/20261007_technicians_messaging_billing.sql
-- ============================================================================
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

-- ============================================================================
-- SOURCE: supabase/migrations/20261008_evidence_history_retention.sql
-- ============================================================================
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

-- ============================================================================
-- SOURCE: supabase/migrations/20261009_rent_payment_proofs.sql
-- ============================================================================
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
