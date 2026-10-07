# Production setup

Use the current deployment and security documents:

- [Deployment guide](docs/DEPLOYMENT.md) — environment configuration, fresh-install SQL, forward migration ordering, and staging verification.
- [Security and retention guide](docs/SECURITY_AND_RETENTION.md) — payment evidence, review controls, message audit/soft delete, and retention.

**Important:** `supabase/merged_deployment.sql` is for a fresh database only. For an existing database, apply only unapplied scripts from `supabase/migrations/`, in filename order. Do not deploy production without Supabase configuration; the application blocks local-account mode in production builds.
