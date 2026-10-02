import { supabase, isSupabaseConfigured } from './supabase';

export type BackendRole = 'admin'|'landlord'|'manager'|'tenant';

export async function loadWorkspace(userId:string) {
  if (!supabase) throw new Error('Supabase is not configured');
  const [{data: profile,error: profileError},{data: admin,error: adminError},{data: authData,error: authError}] = await Promise.all([
    supabase.from('profiles').select('*').eq('id',userId).maybeSingle(),
    supabase.from('platform_admins').select('id').eq('id',userId).maybeSingle(),
    supabase.auth.getUser()
  ]);
  if (profileError) throw profileError;
  if (adminError) throw adminError;
  if (authError) throw authError;
  if (!profile && !admin) throw new Error('Your Supabase account is authenticated, but no NestTrack profile exists for this user. Run the onboarding/profile setup or contact your administrator.');
  const profileData = profile || {
    full_name: authData.user.user_metadata?.full_name || authData.user.email?.split('@')[0] || 'Administrator',
    email: authData.user.email || '',
    phone: null,
    avatar_url: null,
    role: null
  };
  const {data: memberships,error: me} = admin
    ? await supabase.from('organization_members').select('organization_id,user_id,role').eq('status','active')
    : await supabase.from('organization_members').select('organization_id,user_id,role').eq('user_id',userId).eq('status','active');
  if (me) throw me;
  if (!admin && (memberships||[]).some(x=>x.role==='landlord')) {
    const {error}=await supabase.rpc('ensure_organization_invite_codes');
    if(error)throw error;
  }
  const membershipRole = memberships?.find(x=>x.user_id===userId)?.role;
  const resolvedRole = admin ? 'admin' : (membershipRole || profileData.role);
  if (!resolvedRole || !(['admin','landlord','manager','tenant'] as string[]).includes(resolvedRole)) throw new Error('Your NestTrack profile has no valid role. Contact your administrator.');
  if (!admin && !memberships?.length) throw new Error('Your account is authenticated, but it is not assigned to a NestTrack organization. Ask your landlord/administrator to complete your organization membership.');
  const role:BackendRole = resolvedRole as BackendRole;
  const orgId = memberships?.[0]?.organization_id || 'platform';
  const orgIds = memberships?.map(x=>x.organization_id) || [];
  const [orgRes, profilesRes, propsRes, unitsRes, tenRes, payRes, welfareRes, ticketRes, cashRes, invitesRes] = await Promise.all([
    admin ? supabase.from('organizations').select('*') : supabase.from('organizations').select('*').in('id', orgIds),
    supabase.from('profiles').select('*'),
    admin ? supabase.from('properties').select('*') : supabase.from('properties').select('*').in('organization_id', orgIds),
    admin ? supabase.from('units').select('*') : supabase.from('units').select('*').in('organization_id', orgIds),
    admin ? supabase.from('tenancies').select('*').eq('status','active') : supabase.from('tenancies').select('*').in('organization_id', orgIds).eq('status','active'),
    admin ? supabase.from('payments').select('*') : supabase.from('payments').select('*').in('organization_id', orgIds),
    admin ? supabase.from('welfare_checks').select('*').order('checked_at',{ascending:false}) : supabase.from('welfare_checks').select('*').in('organization_id', orgIds).order('checked_at',{ascending:false}),
    admin ? supabase.from('maintenance_tickets').select('*') : supabase.from('maintenance_tickets').select('*').in('organization_id', orgIds),
    admin ? supabase.from('cashflow_ledger').select('*').order('recorded_at',{ascending:false}) : supabase.from('cashflow_ledger').select('*').in('organization_id',orgIds).order('recorded_at',{ascending:false}),
    admin ? supabase.from('invite_codes').select('organization_id,role,code').eq('active',true) : supabase.from('invite_codes').select('organization_id,role,code').eq('active',true).in('organization_id',orgIds)
  ]);
  for (const r of [orgRes,profilesRes,propsRes,unitsRes,tenRes,payRes,welfareRes,ticketRes,cashRes,invitesRes]) if (r.error) throw r.error;
  const users = (profilesRes.data||[]).map((p:any)=>{
    const membership=(memberships||[]).find(x=>x.user_id===p.id);
    return {id:p.id,name:p.full_name,email:p.email,phone:p.phone||'',avatar_url:p.avatar_url||undefined,password:'',role:(p.id===userId?role:membership?.role||p.role),orgId:membership?.organization_id||orgId,welfare:(welfareRes.data||[]).find((w:any)=>w.tenant_id===p.id)?.status||'Good'};
  });
  if (admin && !users.some((u:any)=>u.id===userId)) users.push({id:userId,name:profileData.full_name,email:profileData.email,phone:profileData.phone||'',avatar_url:profileData.avatar_url||undefined,password:'',role,orgId,welfare:'Good'});
  const properties = (propsRes.data||[]).map((p:any)=>({id:p.id,orgId:p.organization_id,name:p.name,address:p.address,image:'https://images.unsplash.com/photo-1600585154340-be6161a56a0c?auto=format&fit=crop&w=1200&q=80',units:(unitsRes.data||[]).filter((u:any)=>u.property_id===p.id).map((u:any)=>({id:u.id,name:u.label,description:'',tenantId:u.current_tenant_id||undefined,rent:Number((tenRes.data||[]).find((t:any)=>t.unit_id===u.id)?.rent_amount||0)}))}));
  const tenancyById=new Map((tenRes.data||[]).map((t:any)=>[t.id,t]));
  const payments=(payRes.data||[]).map((p:any)=>({id:p.id,tenantId:p.tenant_id,amount:Number(p.amount_due),due:p.due_date,status:p.status,method:p.method||''}));
  const tickets=(ticketRes.data||[]).map((t:any)=>({id:t.id,tenantId:t.tenant_id,title:t.title,category:t.category||'',status:t.status,priority:t.priority}));
  const cashflow=(cashRes.data||[]).map((c:any)=>({id:c.id,landlordId:c.landlord_id,orgId:c.organization_id,paymentId:c.payment_id||'',tenantId:c.tenant_id||'',amount:Number(c.amount),type:c.type,status:c.status,timestamp:c.recorded_at,method:c.method||''}));
  const orgs=(orgRes.data||[]).map((o:any)=>({id:o.id,name:o.name,ownerId:'',inviteManager:(invitesRes.data||[]).find((i:any)=>i.organization_id===o.id&&i.role==='manager')?.code||'',inviteTenant:(invitesRes.data||[]).find((i:any)=>i.organization_id===o.id&&i.role==='tenant')?.code||''}));
  return {current:{id:userId,name:profileData.full_name,email:profileData.email,password:'',role,orgId,welfare:'Good'},users,orgs,props:properties,payments,cashflow,messages:[] as any[],tickets};
}

export async function signIn(email:string,password:string){ if(!supabase) throw new Error('Supabase is not configured'); const {data,error}=await supabase.auth.signInWithPassword({email,password}); if(error) throw error; return data.user!; }
export async function signOut(){ if(supabase) await supabase.auth.signOut(); }
export async function createProperty(organization_id:string,name:string,address:string,units:{name:string;description?:string;rent:number}[]=[]){if(!supabase)throw new Error('Supabase is not configured');const {data,error}=await supabase.from('properties').insert({organization_id,name,address}).select().single();if(error)throw error;if(units.length){const {error:uerr}=await supabase.from('units').insert(units.map(u=>({organization_id,property_id:data.id,label:u.name,status:'vacant'})));if(uerr)throw uerr;}return data;}
export async function verifyPayment(id:string){if(!supabase)throw new Error('Supabase is not configured');const {data:{user}}=await supabase.auth.getUser();const {error}=await supabase.from('payments').update({status:'Paid',verified_by:user?.id,verified_at:new Date().toISOString()}).eq('id',id);if(error)throw error;}
export async function updateTicket(id:string,status:string){if(!supabase)throw new Error('Supabase is not configured');const {error}=await supabase.from('maintenance_tickets').update({status,updated_at:new Date().toISOString()}).eq('id',id);if(error)throw error;}
export { isSupabaseConfigured };

export async function sendDirectMessage(otherUserId:string, body:string){if(!supabase)throw new Error('Supabase is not configured'); const {data:cid,error:e}=await supabase.rpc('get_or_create_direct_conversation',{p_other:otherUserId}); if(e)throw e; const {data:{user}}=await supabase.auth.getUser(); const {error}=await supabase.from('messages').insert({conversation_id:cid,sender_id:user!.id,body}); if(error)throw error;}

export async function updateProfile(userId:string, full_name:string, phone:string, avatarFile?:File, removeAvatar=false){if(!supabase)throw new Error('Supabase is not configured'); let avatar_url:string|undefined; if(avatarFile){const ext=avatarFile.name.split('.').pop()||'jpg'; const path=`${userId}/avatar-${Date.now()}.${ext}`; const up=await supabase.storage.from('avatars').upload(path,avatarFile,{upsert:true,contentType:avatarFile.type}); if(up.error)throw up.error; avatar_url=supabase.storage.from('avatars').getPublicUrl(path).data.publicUrl;} const payload:any={full_name,phone:phone||null}; if(avatar_url)payload.avatar_url=avatar_url; if(removeAvatar)payload.avatar_url=null; const {error}=await supabase.from('profiles').update(payload).eq('id',userId);if(error)throw error; return avatar_url;}

export async function deleteProfileImage(userId:string, avatarUrl?:string){if(!supabase)throw new Error('Supabase is not configured');if(avatarUrl){const marker='/avatars/';const i=avatarUrl.indexOf(marker);if(i>=0){const path=avatarUrl.slice(i+marker.length).split('?')[0];await supabase.storage.from('avatars').remove([path]);}}const {error}=await supabase.from('profiles').update({avatar_url:null}).eq('id',userId);if(error)throw error;}

export async function deleteMyAccount(){ if(!supabase) throw new Error('Supabase is not configured'); const {data:{user}}=await supabase.auth.getUser(); if(!user) throw new Error('Not signed in'); const {error}=await supabase.rpc('delete_my_account'); if(error) throw error; await supabase.auth.signOut(); }
export async function deleteOrganization(id:string){if(!supabase)throw new Error('Supabase is not configured');const {error}=await supabase.from('organizations').delete().eq('id',id);if(error)throw error;}
export async function deleteProperty(id:string){if(!supabase)throw new Error('Supabase is not configured');const {error}=await supabase.rpc('delete_property_as_landlord',{p_property_id:id});if(error)throw error;}
export async function deleteUnit(id:string){if(!supabase)throw new Error('Supabase is not configured');const {error}=await supabase.rpc('delete_unit_as_landlord',{p_unit_id:id});if(error)throw error;}
export async function deleteTenantAccount(id:string){if(!supabase)throw new Error('Supabase is not configured');const {error}=await supabase.rpc('delete_tenant_account',{p_tenant_id:id});if(error)throw error;}

export async function deleteLandlordAccount(id:string){if(!supabase)throw new Error('Supabase is not configured');const {error}=await supabase.rpc('admin_delete_landlord',{p_landlord_id:id});if(error)throw error;}
