# NestTrack production setup

The application remains usable as a local demo when Supabase variables are absent. For production, configure Supabase before deployment.

## 1. Create Supabase project
Set `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` in the deployment environment using `.env.example` as the template.

## 2. Apply database migrations
For a new project, run `supabase/schema.sql`, then `supabase/rls.sql`, then `supabase/onboarding.sql`.

For an existing production installation, apply the new forward-only migration:

`supabase/migrations/20261005_feature_expansion.sql`

Then apply:

`supabase/migrations/20261005_platform_admin_messaging.sql`

Then apply:

`supabase/migrations/20261006_fix_conversation_members_rls_recursion.sql`

Then apply:

`supabase/migrations/20261006_clean_architecture.sql`

The recursion-fix migration must run after the feature-expansion and platform-admin messaging migrations. The clean-architecture migration must run last; it adds property/organization/shared/platform channels and uses a security-definer `is_channel_member()` helper to avoid recursive channel-membership RLS evaluation.

Do not replace production SQL by copying a fresh schema over an existing database. The feature-expansion migration is designed to extend the existing installation without silently destroying data. The schema includes organizations, memberships, properties, units, tenancies, payments, welfare, conversations, messages, maintenance, audit events, platform admins, invite codes and the cashflow ledger.

## 3. Configure authentication
Enable Email/Password in Supabase Auth. Production users must authenticate through Supabase Auth; never store plaintext passwords in the frontend or database tables.

## 4. Create the platform Administrator securely
Create the Administrator user in Supabase Auth using the platform email. Then insert that Auth user's UUID into `platform_admins`. Do not put the Administrator password in source code, SQL migrations, or `.env` files committed to git.

## 5. Invitation links and onboarding
Landlords can create secure invitation links from the NestTrack Invite action. The link contains a one-time opaque token; only a SHA-256 hash is stored in PostgreSQL. Tokens expire and are role-scoped. Optional email delivery can be added by connecting an email provider; the application itself only generates/copies the secure link.

Legacy manager/tenant invite codes remain supported for compatibility, but new workflows should prefer invitation links.

## 6. Storage
Create a private `property-images` bucket and a private `payment-receipts` bucket. Add storage RLS policies so organization members can access only files belonging to their organization.

## 7. Realtime
Enable Realtime for `messages`, `payments`, `maintenance_tickets` and `welfare_checks` for live collaboration.

## 8. Deployment
Build with `npm run build` and deploy the generated `dist/` directory to Vercel, Netlify, Cloudflare Pages, or another static host. Set the same Supabase environment variables in the host.

## Security notes
- The browser must never receive a Supabase service-role key.
- RLS is the authoritative authorization boundary.
- Invite codes are organization-scoped and role-scoped.
- Cashflow is written by a database trigger when a payment becomes Paid, creating a timestamped audit-friendly ledger record.
- Rotate any demo credentials before public launch.


## 9. Manual security verification

Use separate landlord, manager and tenant accounts and verify:

1. A user with two active memberships can switch organizations without seeing the previous organization's properties, units, tenants, tickets, payments or messages.
2. A tenant cannot read another tenant's tenancy/payment/ticket by changing a UUID in the browser.
3. A tenant cannot assign a ticket, change its status, change a role, or approve a move-out.
4. An invitation token cannot be reused after its use limit is reached, cannot be used after expiry/revocation, and cannot change its intended role.
5. Move-out approval ends the tenancy and makes the unit vacant in the same database transaction.
6. Ticket status and assignment changes create `ticket_history` rows.
7. Notification rows are visible only to their recipient.
8. Property/unit/tenant deletion is rejected when the caller lacks the required organization capability.
