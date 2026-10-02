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
- Invite managers and tenants with role-specific organization codes.
- View tenants and welfare states.
- Communicate with managers and tenants.
- Verify rent payments.
- Update a profile, upload or remove a profile image, and delete the account.

### Managers

- Join an existing landlord organization through a manager invite code.
- View assigned organization properties and units.
- Monitor occupancy and rent activity.
- Review tenants and welfare indicators.
- Verify payments and progress maintenance tickets from Open to In progress to Resolved.
- Communicate with tenants and landlords.

### Tenants

- Join an organization through a tenant invite code.
- View their home and unit assignment.
- See upcoming or outstanding rent information.
- View welfare status.
- Exchange direct messages with relevant people.
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

NestTrack currently uses invite codes rather than invite URLs. Codes are intended to be organization-scoped and role-scoped in production.

### Sign in

The local demo accepts either a registered email address or name, plus the password and registered full name. The last successful account name is remembered locally to support the returning-user identity check. Supabase mode delegates authentication to Supabase Auth.

### Verify a payment

Managers and landlords can verify a pending payment. In Supabase mode, a database trigger records a newly paid payment in the cashflow ledger with its organization, landlord, tenant, amount, method and timestamp.

### Manage maintenance

Maintenance tickets are presented in three operational columns: **Open**, **In progress** and **Resolved**. Operations users can assign an open issue and resolve an issue in progress. Ticket priority and tenant/unit context remain visible during the workflow.

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

Frank Wilson has a separate organization for testing organization isolation. Additional demo details are in [DEMO_DATA.md](DEMO_DATA.md).

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
- `conversations`, `conversation_members` and `messages` support direct communication.
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
- Invite codes should support expiry, maximum uses and revocation in production.
- Demo credentials and hard-coded seed records must be removed or rotated before public release.
- Configure private storage buckets and storage policies for property images and payment receipts before enabling those production workflows.
- Enable Realtime for messages, payments, maintenance tickets and welfare checks when live updates are required.
- Add backups, monitoring, error reporting and a recovery procedure before handling real tenant or financial data.

## Current limitations

NestTrack is an evolving product prototype. The current implementation has several deliberate gaps:

- Local demo data is browser-local and is not shared between devices or users.
- The local demo does not provide real payment processing; payment verification is a workflow state change.
- Some production data such as messages, property imagery and payment receipts needs further integration in the Supabase-backed UI.
- The current interface focuses on core operational flows rather than full lease, accounting and document management.
- Invite-code administration, role changes and detailed audit history need a more complete management experience.
- Accessibility, localization, automated testing and observability should be expanded before a public launch.

## Future prospects

### Near term

- Add automated unit, component and end-to-end tests for authentication, organization isolation, payment verification and ticket transitions.
- Complete Supabase realtime subscriptions so messages and operational records update without manual refreshes.
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
