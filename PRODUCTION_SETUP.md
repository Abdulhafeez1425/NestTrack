# NestTrack production setup

The application remains usable as a local demo when Supabase variables are absent. For production, configure Supabase before deployment.

## 1. Create Supabase project
Set `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` in the deployment environment using `.env.example` as the template.

## 2. Apply database migrations
Run `supabase/schema.sql`, then `supabase/rls.sql` in the Supabase SQL editor. The schema includes organizations, memberships, properties, units, tenancies, payments, welfare, conversations, messages, maintenance, audit events, platform admins, invite codes and the cashflow ledger.

## 3. Configure authentication
Enable Email/Password in Supabase Auth. Production users must authenticate through Supabase Auth; never store plaintext passwords in the frontend or database tables.

## 4. Create the platform Administrator securely
Create the Administrator user in Supabase Auth using the platform email. Then insert that Auth user's UUID into `platform_admins`. Do not put the Administrator password in source code, SQL migrations, or `.env` files committed to git.

## 5. Storage
Create a private `property-images` bucket and a private `payment-receipts` bucket. Add storage RLS policies so organization members can access only files belonging to their organization.

## 6. Realtime
Enable Realtime for `messages`, `payments`, `maintenance_tickets` and `welfare_checks` for live collaboration.

## 7. Deployment
Build with `npm run build` and deploy the generated `dist/` directory to Vercel, Netlify, Cloudflare Pages, or another static host. Set the same Supabase environment variables in the host.

## Security notes
- The browser must never receive a Supabase service-role key.
- RLS is the authoritative authorization boundary.
- Invite codes are organization-scoped and role-scoped.
- Cashflow is written by a database trigger when a payment becomes Paid, creating a timestamped audit-friendly ledger record.
- Rotate any demo credentials before public launch.
