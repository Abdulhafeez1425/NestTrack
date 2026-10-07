# NestTrack

NestTrack is a multi-role property operations web app for landlords, property managers and tenants. It brings portfolio visibility, rent tracking, maintenance, tenant welfare and communication into one organization-based workspace.

The project currently supports two operating modes:

- **Local demo mode:** runs without a backend and stores demo state in browser `localStorage`.
- **Supabase-backed mode:** uses Supabase Auth, PostgreSQL, Row Level Security and database-backed workspace data.

## Why NestTrack

Property work is often spread across spreadsheets, chat threads, payment screenshots and maintenance follow-ups. NestTrack is designed to give each participant a focused view of the same operational record:

- Landlords see the health of their portfolio and organization.
- Managers coordinate properties, tenants, rent verification and repairs.
- Tenants can see their home, payment status, welfare state, messages and maintenance activity.
- Platform administrators can monitor landlord organizations and recorded cashflow.

## Capabilities

### Landlords

- Create and manage a property organization.
- Add properties with an image, country, address and units.
- Define unit descriptions and rent amounts.
- Review occupancy, rent collection and operational attention areas.
- Invite managers and tenants with secure expiring invitation links; legacy role-specific codes remain available for compatibility.
- View tenants and welfare states.
- Communicate with managers and tenants.
- Use property and organization channels alongside direct messages; landlords and managers can create channels and manage members.
- Verify rent payments.
- Switch between multiple organizations when the account has multiple active memberships.
- Review notifications, tenancy lifecycle and move-out requests.
- Update a profile, upload or remove a profile image, and delete the account.

### Managers

- Join an existing landlord organization through a secure manager invitation link.
- View assigned organization properties and units.
- Monitor occupancy and rent activity.
- Review tenants and welfare indicators.
- Verify payments and progress maintenance tickets from Open to In progress to Resolved.
- Communicate with tenants and landlords.
- Post in organization/property channels and manage channel membership.

### Tenants

- Join an organization through a secure tenant invitation link.
- View their home and unit assignment.
- See upcoming or outstanding rent information.
- View welfare status.
- Exchange direct messages with relevant people.
- Read and post in channels available to the tenancy or property.
- Follow maintenance issues associated with their tenancy.
- Maintain personal contact details and profile image.

### Platform administrators

- See registered landlords and organizations.
- Review portfolio size, units, occupancy and recorded rent.
- Open direct communication with landlord accounts.
- Browse the timestamped cashflow ledger.
- Export cashflow records as CSV.

## Core workflows

### Create an organization

1. Choose **Landlord** on the sign-up screen.
2. Enter a name, email, password, confirmation password and organization name.
3. NestTrack creates the landlord workspace.
4. Open **Invite** to display the manager and tenant codes.
5. Add properties and units from the property workflow.

### Join an organization

1. Choose **Manager** or **Tenant** on sign up.
2. Enter the account details and the code supplied by the landlord.
3. Select the role that matches the code.
4. NestTrack validates the role-specific code and associates the account with that organization.

NestTrack supports secure, expiring invitation links backed by hashed tokens. Legacy organization-scoped invite codes remain supported for backward compatibility.

### Sign in

The local demo accepts either a registered email address or name, plus the password and registered full name. The last successful account name is remembered locally to support the returning-user identity check. Supabase mode delegates authentication to Supabase Auth.

### Verify a payment

Managers and landlords can verify a pending payment. In Supabase mode, a database trigger records a newly paid payment in the cashflow ledger with its organization, landlord, tenant, amount, method and timestamp.

### Manage maintenance

Maintenance tickets use four operational states: **Pending**, **In progress**, **Resolved** and **Closed**. Operations users transition tickets through the controlled workflow and every status/assignment change is recorded in ticket history. Ticket priority and tenant/unit context remain visible during the workflow.

## Demo data

The local demo includes two isolated organizations and sample portfolio activity.

| Name | Email | Password | Role |
|---|---|---|---|
| Alice Johnson | `alice@nesttrack.demo` | `DemoPass#101` | Landlord |
| Brian Smith | `brian@nesttrack.demo` | `DemoPass#102` | Manager |
| Chloe Williams | `chloe@nesttrack.demo` | `DemoPass#103` | Tenant |
| Daniel Brown | `daniel@nesttrack.demo` | `DemoPass#104` | Tenant |
| Emma Davis | `emma@nesttrack.demo` | `DemoPass#105` | Manager |
| Frank Wilson | `frank@nesttrack.demo` | `DemoPass#106` | Landlord |

Alice Johnson owns **Alice Johnson Properties**, with Palm Grove Apartments, Oak Residences, units, rent records, welfare states, maintenance tickets and conversations preloaded.

Alice's invite codes:

- Manager: `NT-MGR-A7K9`
- Tenant: `NT-TEN-A2P4`

Frank Wilson has a separate organization for testing organization isolation. Demo credentials are documented in the source seed data and should not be used in production.

> Demo credentials are for local evaluation only. Rotate or remove them before any public deployment.

## Getting started

### Requirements

- Node.js with npm
- A modern browser
- Optional: a Supabase project for production-like mode

### Install and run locally

```bash
npm install
npm run dev
```

Vite will print the local development URL. The app starts in local demo mode when Supabase environment variables are absent.

### Available commands

```bash
npm run dev       # Start the Vite development server
npm run build     # Create a production build in dist/
npm run preview   # Preview the production build locally
npm run typecheck # Run TypeScript without emitting files
npm run check     # Run typecheck followed by the production build
```

## Technical architecture

NestTrack is a small React and TypeScript single-page application built with Vite.

| Area | Technology or approach |
|---|---|
| UI | React 19 with functional components and hooks |
| Language | TypeScript |
| Build tooling | Vite 8 |
| Navigation | React Router dependency, with role-aware application views |
| Styling | Tailwind CSS 4 through the Vite integration, plus component classes in `src/index.css` |
| Authentication | Local demo identity store or Supabase Auth |
| Data | Local React state and `localStorage`, or Supabase PostgreSQL |
| Files | Browser previews locally; Supabase Storage for profile images in production mode |
| Export | Client-side CSV generation for administrator cashflow records |

Important source locations:

- [src/App.tsx](src/App.tsx): role models, seeded demo data, authentication screens and primary application views.
- [src/lib/backend.ts](src/lib/backend.ts): Supabase workspace loading and mutations.
- [src/lib/supabase.ts](src/lib/supabase.ts): Supabase client configuration.
- [src/index.css](src/index.css): shared visual styles.
- [supabase/schema.sql](supabase/schema.sql): database tables, indexes, triggers and account-deletion functions.
- [supabase/rls.sql](supabase/rls.sql): Row Level Security policies.
- [supabase/onboarding.sql](supabase/onboarding.sql): organization onboarding and invite-code procedures.

## Data model

The production schema is organized around an organization boundary:

- `organizations` stores landlord workspaces and defaults such as currency and timezone.
- `profiles` stores authenticated user profile information and role.
- `organization_members` connects users to organizations with an active, invited or disabled status.
- `properties` and `units` model the physical portfolio.
- `tenancies` connect tenants to units and rent terms.
- `payments` store due dates, amounts, status, payment method and verification metadata.
- `welfare_checks` store tenant welfare states and notes.
- `channels` and `channel_members` define property, organization, shared and platform communication spaces; each channel owns a `conversation`, so `conversation_members` and `messages` provide the shared message and read-state model.
- `maintenance_tickets` store property issues, priority, assignment and workflow status.
- `audit_events` provides a foundation for operational history.
- `invite_codes` stores role-specific onboarding codes.
- `cashflow_ledger` stores timestamped rent records for platform and landlord reporting.

## Supabase-backed mode

Create a `.env` file from the available environment template and set:

```env
VITE_SUPABASE_URL=https://your-project.supabase.co
VITE_SUPABASE_ANON_KEY=your-anon-key
```

Then apply the SQL files in this order from the Supabase SQL editor:

1. `supabase/schema.sql`
2. `supabase/rls.sql`
3. `supabase/onboarding.sql`

Create the first platform administrator in Supabase Auth, then insert that Auth user's UUID into `platform_admins`:

```sql
insert into public.platform_admins(id) values ('AUTH_USER_UUID');
```

For a complete deployment checklist, see [PRODUCTION_SETUP.md](PRODUCTION_SETUP.md) and [supabase/README_DEPLOY.md](supabase/README_DEPLOY.md).

## Security and production considerations

- Supabase Auth is the production authentication boundary; plaintext passwords must never be stored in application tables or committed to source control.
- The browser must receive only the Supabase anon key. Never expose a service-role key in Vite environment variables.
- Row Level Security is the authoritative authorization boundary. Test policies with landlord, manager, tenant and administrator accounts before launch.
- Organization membership and role checks should be tested for every read and mutation path.
- Secure invitation links use hashed tokens, expiry, maximum uses and revocation; legacy invite codes remain only for backward compatibility.
- Demo credentials and hard-coded seed records must be removed or rotated before public release.
- Configure private storage buckets and storage policies for property images and payment receipts before enabling those production workflows.
- Enable Supabase Realtime replication for messages, notifications, payments, maintenance tickets and welfare checks before launch.
- Add backups, monitoring, error reporting and a recovery procedure before handling real tenant or financial data.

## Current limitations

NestTrack is an evolving product prototype. The current implementation has several deliberate gaps:

- Local demo data is browser-local and is not shared between devices or users.
- The local demo does not provide real payment processing; payment verification is a workflow state change.
- Property imagery and payment receipts still need private Supabase Storage integration; messaging and operational live refresh are implemented when Realtime is enabled.
- The current interface focuses on core operational flows rather than full lease, accounting and document management.
- Invite-code administration, role changes and detailed audit history need a more complete management experience.
- Accessibility, localization, automated testing and observability should be expanded before a public launch.

## Future prospects

### Near term

- Add automated unit, component and end-to-end tests for authentication, organization isolation, payment verification and ticket transitions.
- Add automated tests and monitoring around the implemented Supabase Realtime subscriptions.
- Add tenant maintenance submission, payment receipt upload and payment history details.
- Add property image and payment-receipt storage flows with private, organization-scoped policies.
- Improve invite management with expiry, revocation, usage limits and resend workflows.

### Product expansion

- Lease and tenancy lifecycle management, including renewals, deposits and move-in or move-out checklists.
- Recurring rent schedules, partial payments, arrears, receipts and reconciliation.
- Maintenance assignment to vendors, scheduling, cost tracking, photos and service-level targets.
- Rich welfare check-ins, reminders and escalation workflows for urgent cases.
- Portfolio reports, occupancy trends, income forecasting and configurable exports.
- Notifications through email, SMS, push and WhatsApp integrations.
- More granular permissions for owners, accountants, regional managers and contractors.

### Long-term direction

NestTrack can grow into a property operations system that combines financial accuracy with human-centered tenant care. The strongest long-term opportunity is a reliable shared record: every payment, repair, welfare check and conversation can become searchable operational history, while analytics help property teams act before small issues become expensive ones.

## Contributing

Keep changes focused and consistent with the existing React and TypeScript structure. Before opening a pull request:

```bash
npm run check
```

Document new environment variables, SQL changes, role permissions and user-visible workflows alongside the implementation. Never commit secrets, service-role keys or real tenant data.

## License

No license has been declared for this repository yet. Add an explicit license before distributing the project or accepting external contributions.


## Feature expansion migration

The October 2026 feature expansion is delivered as a forward-only migration:

```text
supabase/migrations/20261005_feature_expansion.sql
supabase/migrations/20261005_platform_admin_messaging.sql
```

The conversation-policy recursion fix is delivered as a follow-up migration:

```text
supabase/migrations/20261006_fix_conversation_members_rls_recursion.sql
```

Apply the recursion-fix migration after the feature-expansion and platform-admin messaging migrations. It installs a security-definer membership helper and replaces policies that queried `conversation_members` recursively during their own RLS evaluation.

Apply it **after** `supabase/schema.sql` and the existing security/onboarding SQL on an existing Supabase installation. The migration adds:

- Multiple active organization memberships with an explicit active-organization client context.
- Secure invitation links with hashed, expiring tokens and role validation.
- Organization settings/status/limits and server-side property/unit limit checks.
- Explicit tenancy and move-out lifecycle with atomic assignment and approval RPCs.
- In-app notifications and unread/read handling.
- Pending → In progress → Resolved → Closed ticket workflow and immutable ticket history.
- Organization-scoped conversation/message loading and participant checks.
- Additional RLS policies and security-definer RPCs for privileged multi-row workflows.
- Safer property/unit/tenant/landlord/account deletion paths.

### Production verification

```bash
npm ci
npm run typecheck
npm run build
```

Do not deploy from an archive containing `node_modules`. A clean install must be performed on the deployment/CI platform so Vite/Rolldown installs the native dependency for that platform.

The browser environment must contain only:

```text
VITE_SUPABASE_URL
VITE_SUPABASE_ANON_KEY
```

Never add a Supabase service-role/secret key to Vite environment variables or frontend source.

## Messaging after independent signup

Manager and tenant accounts can message before they belong to an organization. Direct conversations are participant-scoped and may have a NULL organization_id. Apply `supabase/migrations/20261006_messaging_independent_accounts.sql` after the other migrations.

If a newly created account cannot see the Messages page, make sure the frontend is using the latest build: unprovisioned accounts are intentionally allowed to access Dashboard/Profile/Messages while organization-only features remain unavailable until membership is assigned.
