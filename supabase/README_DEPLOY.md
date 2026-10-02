# NestTrack Supabase deployment

1. Create a Supabase project.
2. Run `schema.sql`, then `rls.sql`, then `onboarding.sql` in the SQL editor.
   If the database is already set up, rerun `rls.sql` to install platform-admin dashboard access and `onboarding.sql` to install the invite-code generator.
3. Copy Project URL and anon key into `.env` from `.env.example`.
4. Create the first platform admin by running:

```sql
insert into public.platform_admins(id) values ('AUTH_USER_UUID');
```

The app uses Supabase Auth for login, database tables for organizations, properties, units, tenancies, payments, cashflow, welfare and maintenance, and Realtime database events to refresh workspace data.
