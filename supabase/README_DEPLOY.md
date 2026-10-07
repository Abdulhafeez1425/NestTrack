# NestTrack Supabase deployment

Use the current [deployment guide](../docs/DEPLOYMENT.md) and [security/retention guide](../docs/SECURITY_AND_RETENTION.md).

- Fresh database: run [`merged_deployment.sql`](merged_deployment.sql) once.
- Existing database: apply only unapplied scripts from [`migrations/`](migrations/) in the dependency order documented in the deployment guide.
- Do not run the fresh-install consolidated script on an existing production database.
- `LOGIN_DIAGNOSTIC.sql` is an ad-hoc diagnostic, not a migration.
