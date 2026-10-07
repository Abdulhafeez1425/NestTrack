# NestTrack

NestTrack is a responsive property-operations web app for landlords, managers, tenants, and technicians. It combines rental records, maintenance tickets, messages, notifications, and tenant welfare in an organization workspace.

## Current capabilities

- Role-aware landlord, manager, tenant, technician, and platform-admin views.
- Organization/property/unit and tenancy management, rent records, and landlord-managed payment instructions pinned in the tenant Payments page.
- Maintenance tickets visible to the organization’s technicians, assignable/removable by operations users, with technician quotes and tenant payment evidence.
- Tenant-submitted bank reference or receipt number, technician confirmation, a second landlord/manager review for disputed payments or quotes at/above the configured threshold, and an immutable ticket payment-event trail.
- Direct and channel messaging. Senders can edit messages or soft-delete them; participants can inspect prior versions. Soft-deleted messages remain available for 365 days before an administrator may purge eligible records.
- Notifications include an action to open the affected section, such as Maintenance, Payments, Messages, Move-out requests, or Properties.
- Profile-image support and responsive layouts for phones, tablets, and desktop.

> **Payments are off-platform.** NestTrack does not move money or verify bank settlement. It records evidence references and review decisions; teams must reconcile transfers with their bank.

## Start locally

Requirements: Node.js 22 or compatible and npm.

```bash
npm ci
npm run dev
```

For local development without Supabase, use the signup flow to create a fresh local account. **There are no pre-seeded demo accounts or sample credentials.** Local-only workspace data is not a substitute for a shared or production database.

## Production configuration

Configure the public Supabase project URL and anon/publishable key in the deployment environment (or a local `.env` copied from `.env.example`):

```env
VITE_SUPABASE_URL=https://your-project.supabase.co
VITE_SUPABASE_ANON_KEY=your-anon-or-publishable-key
```

Production builds without Supabase are blocked from local-account mode. Never expose a Supabase service-role key in the browser bundle or commit credentials.

## Database deployment

- **Fresh database:** execute [`supabase/merged_deployment.sql`](supabase/merged_deployment.sql) once in the Supabase SQL editor.
- **Existing database:** apply only migrations not already recorded/applied, in filename order. Do **not** rerun the consolidated script over production data.
- Deployment details, test checklist, and migration list: [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md).
- Payment review, message history, retention, and production security: [`docs/SECURITY_AND_RETENTION.md`](docs/SECURITY_AND_RETENTION.md).

## Common commands

```bash
npm run dev        # Local development
npm run typecheck  # TypeScript validation
npm run build      # Production bundle
npm run check      # Typecheck and production build
npm run sql:merge  # Regenerate the fresh-install SQL from migration sources
npm run preview    # Preview the build locally
```

## Payment and message lifecycle

For a repair bill, the technician submits a quote, an authorized landlord/manager approves it, the tenant pays outside NestTrack and submits a bank reference/receipt number, and the assigned technician verifies receipt. A landlord/manager must review a disputed payment and payments at or above the organization’s high-value threshold (defaults to ₦100,000 and can be changed in the Payments page).

Message edits create immutable prior-version entries; deletion replaces the visible body with a deletion marker rather than removing the row. An authorized platform administrator can run the retention RPC to purge only soft-deleted messages and history at least 365 days old. See the security guide for operational details.
