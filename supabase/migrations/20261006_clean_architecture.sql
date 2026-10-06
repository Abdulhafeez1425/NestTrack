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
