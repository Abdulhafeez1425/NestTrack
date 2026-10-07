# NestTrack deployment guide

## 1. Configure Supabase

Create a Supabase project and configure `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` in the deployment provider. `.env.example` is a template; do not commit real values. The browser may receive only an anon/publishable key—never a service-role key.

Set Supabase Auth to the providers and email-confirmation behavior appropriate for the organization. Set allowed redirect/site URLs before inviting users.

## 2. Apply PostgreSQL SQL

**Choose one path:**

### New/empty database

Run `supabase/merged_deployment.sql` once from the Supabase SQL editor. It combines the canonical base schema, RLS/onboarding SQL, and ordered migrations for a fresh installation.

### Existing database

Treat `supabase/migrations/` as the migration source of truth. Determine which migrations are already applied, then apply each unapplied migration once, in the dependency order listed below. Never execute the merged fresh-install script on a live database, and do not rerun older migrations merely because they appear in the file list.

The merged file is generated from the canonical base SQL and the ordered migrations. After changing those sources, regenerate it with `npm run sql:merge`; do not edit the generated file by hand.

Forward migrations, in order:

1. `20261005_feature_expansion.sql`
2. `20261005_platform_admin_messaging.sql`
3. `20261006_fix_conversation_members_rls_recursion.sql`
4. `20261006_clean_architecture.sql`
5. `20261006_property_management.sql`
6. `20261006_independent_signup_and_tenant_assignment.sql`
7. `20261006_messaging_independent_accounts.sql`
8. `20261006_messaging_end_to_end.sql`
9. `20261007_technicians_messaging_billing.sql`
10. `20261008_evidence_history_retention.sql`

Base installation files are `supabase/schema.sql`, `supabase/rls.sql`, `supabase/profile_deletion.sql`, and `supabase/onboarding.sql`; the consolidated file contains these before the forward migrations. `LOGIN_DIAGNOSTIC.sql` is an ad-hoc diagnostic, not a deployment migration.

Use a migration ledger/checklist and backup before applying changes to an existing project. Test the entire ordered migration set against a staging database first. Review the SQL and database logs before promoting to production.

## 3. Configure the application

```bash
npm ci
npm run check
```

Build with Supabase variables present:

```bash
npm run build
```

Deploy the generated `dist/` directory to a static host and set the same variables in its build environment. A production bundle without Supabase configuration displays a configuration-required screen and does not enable local accounts.

## 4. First account and onboarding

Create the first landlord through the application signup screen. Create the platform administrator only through Supabase Auth and insert its UUID into `public.platform_admins` using a controlled administrative session. Do not put administrator credentials in source, Markdown, migrations, or frontend variables.

Landlords invite managers, tenants, and technicians with secure role-scoped links. A technician must join an organization before assignment.

## 5. Storage and Realtime

This release uses a text bank/receipt reference as payment evidence; it does not upload a financial receipt file. Configure private Storage buckets only for features that are actually enabled. Enable Supabase Realtime for messages, notifications, and ticket changes if live refresh is required.

## 6. Staging acceptance checklist

Test using separate Supabase accounts for landlord, manager, tenant, and technician:

- Verify a tenant cannot see another tenant’s tickets or submit evidence for another ticket.
- Verify only the assigned technician can confirm submitted evidence.
- Verify payment confirmation at/above the configured threshold remains pending landlord/manager review.
- Verify a tenant dispute routes to the review queue and approval/dispute decisions create audit events.
- Verify resolving a dispute before technician confirmation returns the ticket to technician review rather than marking it paid.
- Verify message edits/deletes require the sender, recipients see the deletion marker, and prior text is available only to conversation participants.
- Verify tenant/invitation/ticket/payment/message notifications navigate to their relevant section.
- Verify organization isolation, profile-image access, password recovery, and account deletion.
- Confirm production has no local demo users, credentials, or seed records.
