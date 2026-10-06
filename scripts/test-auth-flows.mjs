import { createClient } from '@supabase/supabase-js';
import fs from 'node:fs';

const env=fs.readFileSync('.env','utf8').split(/\r?\n/).reduce((a,line)=>{const i=line.indexOf('=');if(i>0)a[line.slice(0,i)]=line.slice(i+1).trim();return a},{});
const url=env.VITE_SUPABASE_URL, key=env.VITE_SUPABASE_ANON_KEY;
if(!url||!key) throw new Error('Missing VITE_SUPABASE_URL/VITE_SUPABASE_ANON_KEY');
const supabase=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});
const stamp=Date.now();
const cases=[
  {role:'landlord',org:`Clean Architecture Test ${stamp}`},
  {role:'manager'},
  {role:'tenant'}
];

for(const c of cases){
  const email=`nesttrack-${c.role}-${stamp}@example.test`;
  const password='NestTrack-Test#2026';
  const name=`NestTrack ${c.role} Test`;
  console.log(`\n[${c.role.toUpperCase()}] signup ${email}`);
  const {data:sign,error:signError}=await supabase.auth.signUp({email,password,options:{data:{full_name:name,phone:'+2348000000000'}}});
  if(signError) throw new Error(`${c.role} signup failed: ${signError.message}`);
  if(!sign.user) throw new Error(`${c.role} signup returned no user`);
  let user=sign.user;
  if(!sign.session){
    const login=await supabase.auth.signInWithPassword({email,password});
    if(login.error) throw new Error(`${c.role} login after signup failed: ${login.error.message}`);
    user=login.data.user;
  }
  const {data:onboard,error:onboardError}=await supabase.rpc('finish_onboarding',{p_full_name:name,p_role:c.role,p_org_name:c.org||null,p_invite_code:null});
  if(onboardError) throw new Error(`${c.role} onboarding failed: ${onboardError.message}`);
  const {data:profile,error:profileError}=await supabase.from('profiles').select('id,email,full_name,role,phone').eq('id',user.id).single();
  if(profileError) throw new Error(`${c.role} profile read failed: ${profileError.message}`);
  if(profile.role!==c.role) throw new Error(`${c.role} role mismatch: ${profile.role}`);
  if(c.role==='landlord' && !onboard) throw new Error('Landlord onboarding did not return an organization id');
  if(c.role!=='landlord' && onboard!==null) throw new Error(`${c.role} unexpectedly received an organization id`);
  await supabase.auth.signOut();
  const login=await supabase.auth.signInWithPassword({email,password});
  if(login.error) throw new Error(`${c.role} login failed: ${login.error.message}`);
  if(!login.data.user?.id) throw new Error(`${c.role} login returned no user`);
  console.log(`PASS ${c.role}: signup -> onboarding -> logout -> login`);
  await supabase.auth.signOut();
}
console.log('\nALL ROLE AUTH FLOWS PASSED');
