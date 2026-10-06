# NestTrack Supabase deployment

1. Create a Supabase project.
2. Run `schema.sql`, then `rls.sql`, then `onboarding.sql` in the SQL editor. The canonical RLS script now defines the platform-admin helper before policies reference it.
3. Apply the feature migrations in this order:
   - `migrations/20261005_feature_expansion.sql`
   - `migrations/20261005_platform_admin_messaging.sql`
   - `migrations/20261006_fix_conversation_members_rls_recursion.sql`
   - `migrations/20261006_clean_architecture.sql`
4. Copy Project URL and anon key into `.env` from `.env.example`.
5. Create the first platform admin by running:

```sql
insert into public.platform_admins(id) values ('AUTH_USER_UUID');
```

The app uses Supabase Auth and refreshes messages, notifications, payments, maintenance tickets and welfare checks through Realtime database events. In Supabase, enable Realtime replication for `messages`, `notifications`, `payments`, `maintenance_tickets` and `welfare_checks` in the `supabase_realtime` publication.
