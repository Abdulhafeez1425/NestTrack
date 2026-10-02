# NestTrack Authentication Fix

This version fixes the Supabase login-to-workspace flow.

## Changes

- Login no longer assumes every authenticated account is a tenant.
- The authenticated Supabase user is resolved through `profiles`, `organization_members`, and `platform_admins` before the UI session is created.
- Login/workspace loading is protected against duplicate concurrent refreshes.
- The Supabase auth listener no longer reloads the workspace a second time on `SIGNED_IN`.
- Failed workspace resolution clears the application session and shows the actual error instead of leaving the user in a misleading authenticated state.
- Invalid or missing roles now produce a clear configuration error.
- Non-admin users without an active organization membership receive a clear message explaining what is missing.
- Sign out now calls Supabase `signOut()` in Supabase mode.
- The frontend `.env` secret/service-role key has been removed. Only browser-safe `VITE_` values belong in the frontend.

## Required Supabase checks

For every user who should log in, verify:

1. `auth.users` contains the account.
2. `public.profiles` contains a row with the same UUID.
3. `public.organization_members` contains an active membership for landlord/manager/tenant users.
4. The membership role is one of `landlord`, `manager`, or `tenant`.
5. Platform administrators are present in `public.platform_admins`.

Example diagnostic query:

```sql
select
  p.id,
  p.email,
  p.full_name,
  p.role as profile_role,
  om.organization_id,
  om.role as membership_role,
  om.status as membership_status
from public.profiles p
left join public.organization_members om on om.user_id = p.id
where p.id = 'USER-UUID-HERE';
```

## Environment variables

Set these in local development and Vercel:

```env
VITE_SUPABASE_URL=https://YOUR_PROJECT.supabase.co
VITE_SUPABASE_ANON_KEY=YOUR_SUPABASE_PUBLISHABLE_KEY
```

Do **not** put `SUPABASE_SECRET_KEY`, `service_role`, or another server secret in this Vite frontend.

If the secret that was previously present in the project was real, rotate/revoke it in Supabase because it has been exposed and should no longer be trusted.
