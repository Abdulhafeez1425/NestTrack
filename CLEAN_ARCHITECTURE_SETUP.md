# NestTrack Clean Architecture Setup

## Architecture

`Platform → Organization → Property → Unit → Tenancy`

Communication is layered independently as direct messages and property/organization/shared/platform channels.

## Supabase migration order

Run the existing schema and migrations in the repository's normal order, then apply:

1. `supabase/migrations/20261005_feature_expansion.sql`
2. `supabase/migrations/20261005_platform_admin_messaging.sql`
3. `supabase/migrations/20261006_fix_conversation_members_rls_recursion.sql`
4. `supabase/migrations/20261006_clean_architecture.sql`

Do not expose a service-role key in the browser.

## Authentication roles

### Landlord
1. Sign up with name, phone, email and password.
2. Select Landlord.
3. Supply organization name.
4. NestTrack creates the profile and organization membership atomically through `finish_onboarding`.
5. Login reloads the server-authoritative organization membership.

### Manager
1. Sign up with name, phone, email and password.
2. Select Manager.
3. No organization is required.
4. The account remains unprovisioned until an authorized organization invitation is accepted.
5. Login works before and after membership is added.

### Tenant
1. Sign up with name, phone, email and password.
2. Select Tenant.
3. No organization or unit is required at account creation.
4. Accepting a secure invitation creates the organization membership; unit assignment is a separate tenancy operation.
5. Login works before and after membership is added.

## Test

With network access to the configured Supabase project:

```bash
npm ci
npm run typecheck
npm run build
npm run test:auth
```

`test:auth` creates timestamped test accounts for all three roles, verifies onboarding, signs out, and verifies password login again. It does not use the service-role key.

If email confirmation is enabled in Supabase, the test requires the project's confirmation policy to allow the test login, or the test accounts must be confirmed first.

## Current environment limitation

The supplied archive contained unusable `node_modules` permissions. A clean reinstall was attempted, but this execution environment could not retrieve the missing Vite package. Live Supabase testing was also blocked by DNS/network access to the configured Supabase host. These are validation-environment limitations, not claims that the production project has passed those tests.
