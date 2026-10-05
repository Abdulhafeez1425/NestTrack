# NestTrack Platform Administrator Setup Guide

## Purpose

NestTrack platform administrators are separate from organization roles. A platform admin is identified by a row in `public.platform_admins`; the `profiles.role` field remains one of `landlord`, `manager`, or `tenant`.

This separation prevents a normal organization user from becoming an administrator by changing a browser value.

## 1. Create the first administrator

The first platform administrator must be bootstrapped from the Supabase SQL Editor by a trusted system owner.

### Step 1 — Create the user through Supabase Auth

In **Supabase Dashboard → Authentication → Users**, create the administrator's Auth user.

Use the normal Supabase Auth account creation process. Do not put a service-role key in the NestTrack frontend or any `VITE_*` variable.

Copy the user's UUID from the Auth user record.

### Step 2 — Apply the platform-admin migration

Run the NestTrack migration that contains the platform-admin and universal-messaging changes:

```text
supabase/migrations/20261005_platform_admin_messaging.sql
```

### Step 3 — Bootstrap the first administrator

In the Supabase SQL Editor, replace `ADMIN_USER_UUID` with the Auth user's UUID:

```sql
insert into public.platform_admins (id)
values ('ADMIN_USER_UUID')
on conflict (id) do nothing;
```

Then verify:

```sql
select
  pa.id,
  au.email,
  pa.created_at
from public.platform_admins pa
join auth.users au on au.id = pa.id;
```

The administrator can now sign in through the normal NestTrack login screen.

## 2. Do not create an admin through the signup screen

There is deliberately no **Administrator** option on the public signup form.

Do not add one.

An attacker must not be able to select `admin` during account registration.

The browser only receives the administrator experience after Supabase authentication succeeds and the authenticated user's ID is present in `public.platform_admins`.

## 3. Adding another administrator

After at least one administrator exists, an existing platform administrator can grant administrator access using the secured RPC:

```sql
select public.grant_platform_admin('USER_UUID');
```

The function verifies that the caller is already a platform administrator.

It also verifies that the target UUID belongs to a real Supabase Auth user.

A normal landlord, manager, or tenant cannot execute this operation successfully.

## 4. Removing an administrator

An existing platform administrator can revoke another administrator:

```sql
select public.revoke_platform_admin('USER_UUID');
```

The last remaining platform administrator cannot remove themselves. This prevents the platform from accidentally being left without an administrator.

## 5. Admin dashboard

After login, a platform administrator receives the **Admin dashboard**.

The dashboard provides:

- Total platform users
- Landlord count
- Organization count
- Unit count
- Occupied-unit count
- Users who have not joined an organization yet
- Platform user directory
- Landlord/organization portfolio overview
- Cashflow access
- Direct communication with platform users

### User directory fields

The user directory displays:

| Field | Description |
|---|---|
| Picture | Current profile image, or initials when no image exists |
| Full name | Name stored in `profiles.full_name` |
| Email | Auth/profile email |
| Phone number | Profile phone number |
| Role | Landlord, Manager, or Tenant |
| Organization | Organization membership(s), if present |

Users who created an individual Manager or Tenant account but have not accepted an organization invitation appear with no organization instead of being incorrectly assigned to an organization.

## 6. Invitation flow

Landlords create organization invitations from their NestTrack workspace.

The landlord selects:

- Manager, or
- Tenant

NestTrack generates a secure invitation token. The token is not the user's organization membership itself.

The landlord can:

1. Copy the secure link.
2. Select an existing Manager/Tenant account and send the invitation directly through NestTrack Messages.
3. Share the copied link through another communication channel.

Invitation acceptance validates the token server-side before creating the organization membership.

## 7. Universal messaging

NestTrack direct messaging is participant-based rather than role-based.

A signed-in user can message another NestTrack user regardless of whether they are:

- Landlord
- Manager
- Tenant
- Platform administrator

Platform administrators can communicate with users across organizations.

For users who do not share an organization, the conversation is stored without an organization ID and is protected by conversation membership. This prevents cross-organization conversations from being incorrectly attached to one organization's data.

## 8. Security rules

Never expose these values in frontend code:

- `SUPABASE_SERVICE_ROLE_KEY`
- Supabase service-role JWTs
- database passwords
- SMTP/API secrets
- admin bootstrap credentials

Only browser-safe values such as these belong in the Vite client environment:

```text
VITE_SUPABASE_URL
VITE_SUPABASE_ANON_KEY
```

The service-role key must never be used as a replacement for RLS.

## 9. Recommended first-admin procedure for production

1. Enable appropriate Supabase Auth controls.
2. Create the first administrator's Auth user.
3. Apply the NestTrack SQL migrations.
4. Insert that UUID into `public.platform_admins` from the Supabase SQL Editor.
5. Sign in using the administrator account.
6. Verify the Admin dashboard loads.
7. Verify the Users table shows the expected user information.
8. Create a test Manager account without an organization.
9. Create a Manager invitation from a landlord account.
10. Send the invitation through NestTrack Messages.
11. Accept the invitation as the Manager.
12. Verify the Manager becomes a member of exactly the invited organization.
13. Verify an ordinary user cannot grant themselves administrator access.
14. Verify a second administrator can be granted using `grant_platform_admin()`.
15. Verify the final administrator cannot remove themselves.

## 10. Useful verification queries

### List platform administrators

```sql
select
  pa.id,
  au.email,
  pa.created_at
from public.platform_admins pa
join auth.users au on au.id = pa.id
order by pa.created_at;
```

### List users and organization memberships

```sql
select
  p.id,
  p.full_name,
  p.email,
  p.phone,
  p.role,
  o.name as organization_name,
  om.status as membership_status
from public.profiles p
left join public.organization_members om
  on om.user_id = p.id
left join public.organizations o
  on o.id = om.organization_id
order by p.full_name;
```

### Find users waiting for an organization invitation

```sql
select
  p.id,
  p.full_name,
  p.email,
  p.phone,
  p.role
from public.profiles p
left join public.organization_members om
  on om.user_id = p.id
where om.user_id is null
  and p.role in ('manager', 'tenant')
order by p.created_at desc;
```

## 11. Important operational note

The Admin dashboard is an oversight interface, not a replacement for PostgreSQL authorization. Every organization-scoped operation continues to rely on RLS/RPC validation.

Do not weaken RLS simply because an administrator needs visibility. Platform-wide read access should be granted through explicit administrator policies and functions only.
