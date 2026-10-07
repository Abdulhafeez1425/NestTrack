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
