# NestTrack Supabase deployment

Use the current [deployment guide](../docs/DEPLOYMENT.md) and [security/retention guide](../docs/SECURITY_AND_RETENTION.md).

- Fresh database: run [`merged_deployment.sql`](merged_deployment.sql) once.
- Existing database: apply only unapplied scripts from [`migrations/`](migrations/) in the dependency order documented in the deployment guide.
- Do not run the fresh-install consolidated script on an existing production database.
- For duplicate avatar-policy error `42710`, run [`fixes/repair_avatar_storage_policies.sql`](fixes/repair_avatar_storage_policies.sql); do not delete other SQL files or rerun a partially applied merged script.
- `LOGIN_DIAGNOSTIC.sql` is an ad-hoc diagnostic, not a migration.
- Rent receipt uploads, selected-month submissions, and landlord confirmation are introduced by `migrations/20261009_rent_payment_proofs.sql`; apply it before deploying the UI that uses those features.
