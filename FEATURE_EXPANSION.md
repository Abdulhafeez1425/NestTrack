# NestTrack Feature Expansion — 2026-10-05

This release extends the existing NestTrack Vite/React/Supabase application without replacing its architecture.

## Implemented

- Explicit active-organization context in Supabase mode.
- Multiple active memberships are returned to the client and the active organization is persisted only as a convenience.
- Secure invitation links backed by SHA-256 token hashes, expiry, role validation, revocation and use limits.
- Legacy invite-code onboarding remains available.
- Organization metadata for slug, lifecycle status, settings and server-side property/unit/member limits.
- Atomic tenant-to-unit assignment and move-out approval/rejection RPCs.
- Tenancy lifecycle: `pending`, `active`, `move_out_requested`, `ended`, `rejected`.
- In-app notifications with recipient-only RLS and read/mark-all-read behavior.
- Maintenance statuses: `Pending`, `In progress`, `Resolved`, `Closed`.
- Ticket history for status, assignment and comments.
- Tenant ticket creation restricted to the tenant's active tenancy.
- Organization-scoped messaging loaded from Supabase rather than an empty production array.
- Conversation participant checks and message read-state RPC.
- Additional RLS/RPC protections for organization isolation and privileged mutations.
- Safer account/property/unit/tenant/landlord deletion paths.
- Existing profile image, phone and account-management workflows retained.

## Migration

Apply:

`supabase/migrations/20261005_feature_expansion.sql`

after the existing base schema/security/onboarding SQL.

## Validation

`npm run typecheck` passes in the source tree.

The source tree passes `npm run typecheck` and `npm run build` after a clean dependency install. `node_modules` remains excluded from delivery archives because native dependencies are platform-specific.

On a normal development/CI machine, run:

```bash
rm -rf node_modules
npm ci
npm run typecheck
npm run build
```

Use Node.js compatible with the versions declared by the package lock/dependencies.

## Supabase verification

After applying the migration, test with separate landlord, manager and tenant accounts:

1. Landlord creates/uses an organization and creates properties/units.
2. Landlord generates a manager or tenant invitation link.
3. Invitation opens signup with the intended role and cannot be reused after its limit.
4. A tenant can only see their own tenancy, payments and tickets.
5. A tenant cannot alter ticket assignment/status or approve a move-out.
6. A tenant can submit a move-out request for their active tenancy.
7. An authorized landlord/manager can approve/reject the request atomically.
8. Approval ends the tenancy and makes the unit vacant.
9. Ticket transitions create `ticket_history` records.
10. Messages are loaded from Supabase, restricted to conversation participants, and refreshed through Supabase Realtime when enabled.
11. Notifications are visible only to their recipient.
12. A user with multiple memberships can switch organizations without stale data from the previous organization.

## Individual Manager and Tenant Account Creation

Managers and tenants no longer enter an organization invite code during account creation.

The onboarding flow is now:

1. Manager or tenant creates an individual NestTrack account.
2. The account is created with its selected role but without an organization membership.
3. A landlord/authorized organization manager creates a secure invitation link.
4. The user opens the invitation link while signed in.
5. Supabase validates the invitation token, intended role, optional invited email, expiry and use limit.
6. The user is added to the organization atomically.
7. NestTrack reloads the organization workspace.

An account without an organization is not treated as an authentication failure. It receives an explicit waiting-for-invitation state.

Legacy invite-code database support may remain for existing installations, but invite codes are no longer exposed on the Manager/Tenant account-creation form.
