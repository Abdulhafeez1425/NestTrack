import { readFile, readdir, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';

const root = process.cwd();
const baseFiles = [
  'supabase/schema.sql',
  'supabase/rls.sql',
  'supabase/profile_deletion.sql',
  'supabase/onboarding.sql',
];
// This dependency order is shared with docs/DEPLOYMENT.md. Forward migration
// files—not this generated output—remain the source of truth for schema changes.
const migrations = [
  '20261005_feature_expansion.sql',
  '20261005_platform_admin_messaging.sql',
  '20261006_fix_conversation_members_rls_recursion.sql',
  '20261006_clean_architecture.sql',
  '20261006_property_management.sql',
  '20261006_independent_signup_and_tenant_assignment.sql',
  '20261006_messaging_independent_accounts.sql',
  '20261006_messaging_end_to_end.sql',
  '20261007_technicians_messaging_billing.sql',
  '20261008_evidence_history_retention.sql',
  '20261009_rent_payment_proofs.sql',
  '20261010_rent_payment_rejection.sql',
  '20261011_rent_payment_proof_visibility.sql',
  '20261012_generate_monthly_rent_rows.sql',
];
const migrationFiles = (await readdir(resolve(root, 'supabase/migrations')))
  .filter((name) => name.endsWith('.sql') && name !== 'LOGIN_DIAGNOSTIC.sql');
const unlisted = migrationFiles.filter((name) => !migrations.includes(name));
const missing = migrations.filter((name) => !migrationFiles.includes(name));
if (unlisted.length || missing.length) {
  throw new Error(`Migration order list mismatch. Unlisted: ${unlisted.join(', ') || 'none'}; missing: ${missing.join(', ') || 'none'}`);
}
const sources = [...baseFiles, ...migrations.map((name) => `supabase/migrations/${name}`)];
const chunks = [
  '-- GENERATED FILE. Source of truth: base SQL files and supabase/migrations/*.sql.\n',
  '-- Fresh/empty database only. Existing databases apply only unapplied migrations.\n',
  '-- Regenerate with: npm run sql:merge\n',
  '-- LOGIN_DIAGNOSTIC.sql is intentionally excluded.\n',
];
for (const source of sources) {
  const text = await readFile(resolve(root, source), 'utf8');
  chunks.push(`\n\n-- ============================================================================\n-- SOURCE: ${source}\n-- ============================================================================\n`);
  chunks.push(text.trimEnd());
}
const output = resolve(root, 'supabase/merged_deployment.sql');
await writeFile(output, `${chunks.join('')}\n`);
console.log(`Generated ${output} from ${sources.length} source files.`);
