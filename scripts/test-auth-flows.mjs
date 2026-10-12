import { createClient } from '@supabase/supabase-js';
import fs from 'node:fs';

const env = (fs.existsSync('.env') ? fs.readFileSync('.env', 'utf8') : '').split(/\r?\n/).reduce((values, line) => {
  const trimmed = line.trim();
  if (!trimmed || trimmed.startsWith('#')) return values;
  const separator = trimmed.indexOf('=');
  if (separator > 0) values[trimmed.slice(0, separator).trim()] = trimmed.slice(separator + 1).trim().replace(/^['"]|['"]$/g, '');
  return values;
}, {});
const url = env.VITE_SUPABASE_URL;
const anonKey = env.VITE_SUPABASE_ANON_KEY;
const serviceKey = env.SUPABASE_SERVICE_ROLE_KEY;
const projectRef = env.NESTTRACK_STAGING_PROJECT_REF;

if (env.NESTTRACK_ENV !== 'staging' || env.NESTTRACK_TEST_ALLOW_MUTATIONS !== 'YES') {
  throw new Error('This test creates and deletes disposable accounts. Set NESTTRACK_ENV=staging and NESTTRACK_TEST_ALLOW_MUTATIONS=YES only for a disposable staging project.');
}
if (!url || !anonKey || !serviceKey || !projectRef) {
  throw new Error('Set VITE_SUPABASE_URL, VITE_SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY, and NESTTRACK_STAGING_PROJECT_REF in the local .env file. Never use production credentials.');
}
const hostname = new URL(url).hostname;
if (!hostname.startsWith(`${projectRef}.`) || hostname === 'localhost' || hostname === '127.0.0.1') {
  throw new Error('The Supabase URL does not match NESTTRACK_STAGING_PROJECT_REF; refusing to mutate this project.');
}

const publicClient = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } });
const adminClient = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
const stamp = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
const createdUsers = [];
const createdOrganizations = [];
const cases = [
  { role: 'landlord', organization: `NestTrack staging auth ${stamp}` },
  { role: 'manager' },
  { role: 'tenant' },
  { role: 'technician', occupation: 'Staging electrician' },
];
let testFailure;

try {
  for (const testCase of cases) {
    const email = `nesttrack-${testCase.role}-${stamp}@example.test`;
    const password = `Staging-${stamp}-Only!`;
    const name = `NestTrack ${testCase.role} ${stamp}`;
    console.log(`\n[${testCase.role.toUpperCase()}] disposable staging auth flow`);

    const { data: signup, error: signupError } = await publicClient.auth.signUp({
      email,
      password,
      options: { data: { full_name: name, role: testCase.role, phone: '+2348000000000', occupation: testCase.occupation || '' } },
    });
    if (signupError) throw new Error(`${testCase.role} signup failed: ${signupError.message}`);
    if (!signup.user) throw new Error(`${testCase.role} signup returned no user`);
    createdUsers.push(signup.user.id);

    const { error: confirmError } = await adminClient.auth.admin.updateUserById(signup.user.id, { email_confirm: true });
    if (confirmError) throw new Error(`Could not confirm the disposable staging user: ${confirmError.message}`);
    const login = await publicClient.auth.signInWithPassword({ email, password });
    if (login.error) throw new Error(`${testCase.role} sign-in failed: ${login.error.message}`);
    const userId = login.data.user?.id;
    if (!userId) throw new Error(`${testCase.role} sign-in returned no user`);

    if (testCase.role === 'landlord') {
      const { data: organizationId, error } = await publicClient.rpc('finish_onboarding', {
        p_full_name: name,
        p_role: 'landlord',
        p_org_name: testCase.organization,
        p_invite_code: null,
      });
      if (error) throw new Error(`landlord onboarding failed: ${error.message}`);
      if (!organizationId) throw new Error('Landlord onboarding returned no organization id');
      createdOrganizations.push(organizationId);
    } else {
      const { error } = await publicClient.rpc('create_independent_profile', {
        p_full_name: name,
        p_role: testCase.role,
        p_phone: '+2348000000000',
        p_occupation: testCase.occupation || null,
      });
      if (error) throw new Error(`${testCase.role} profile creation failed: ${error.message}`);
    }

    const { data: profile, error: profileError } = await publicClient.from('profiles')
      .select('id,email,full_name,role,phone,occupation').eq('id', userId).single();
    if (profileError) throw new Error(`${testCase.role} profile read failed: ${profileError.message}`);
    if (profile.role !== testCase.role) throw new Error(`${testCase.role} role mismatch: ${profile.role}`);
    if (testCase.role === 'technician' && profile.occupation !== testCase.occupation) throw new Error('Technician occupation did not persist');

    const { data: directory, error: directoryError } = await publicClient.rpc('get_user_directory');
    if (directoryError) throw new Error(`${testCase.role} directory read failed: ${directoryError.message}`);
    if (!directory?.some((entry) => entry.user_id === userId)) throw new Error(`${testCase.role} cannot see their own directory record`);
    console.log(`PASS ${testCase.role}: signup -> sign-in -> profile -> scoped directory`);
    await publicClient.auth.signOut();
  }
} catch (error) {
  testFailure = error;
} finally {
  await publicClient.auth.signOut();
  for (const organizationId of createdOrganizations.reverse()) {
    const { error } = await adminClient.from('organizations').delete().eq('id', organizationId);
    if (error) console.error(`CLEANUP WARNING: failed to delete test organization ${organizationId}: ${error.message}`);
  }
  for (const userId of createdUsers.reverse()) {
    const { error } = await adminClient.auth.admin.deleteUser(userId);
    if (error) console.error(`CLEANUP WARNING: failed to delete test user ${userId}: ${error.message}`);
  }
}

if (testFailure) throw testFailure;
console.log('\nALL STAGING ROLE AUTH FLOWS PASSED; disposable users and organizations were removed.');
