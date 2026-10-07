# NestTrack Supabase deployment

1. Create a Supabase project.
2. Run `schema.sql`, then `rls.sql`, then `onboarding.sql` in the SQL editor. The canonical RLS script now defines the platform-admin helper before policies reference it.
3. Apply the feature migrations in this order:
   - `migrations/20261005_feature_expansion.sql`
   - `migrations/20261005_platform_admin_messaging.sql`
   - `migrations/20261006_fix_conversation_members_rls_recursion.sql`
   - `migrations/20261006_clean_architecture.sql`
   - `migrations/20261006_independent_signup_and_tenant_assignment.sql`
   - `migrations/20261006_messaging_independent_accounts.sql`
   - `migrations/20261006_messaging_end_to_end.sql`
4. Copy Project URL and anon key into `.env` from `.env.example`.
5. Create the first platform admin by running:

```sql
insert into public.platform_admins(id) values ('AUTH_USER_UUID');
```

The app uses Supabase Auth and refreshes messages, conversation membership, channels, notifications, payments, maintenance tickets and welfare checks through Realtime database events. The final messaging migration adds `messages`, `conversation_members`, `channel_members`, `channels`, and `notifications` to the `supabase_realtime` publication. Also enable `payments`, `maintenance_tickets` and `welfare_checks` in that publication.
