import { supabase, isSupabaseConfigured } from '../supabase';

export type BackendRole = 'admin'|'landlord'|'manager'|'tenant'|'technician';
export type Membership = {organization_id:string; user_id:string; role:'landlord'|'manager'|'tenant'|'technician'; status:string; permissions?:Record<string,boolean>};
export type Workspace = {
  current:any;
  memberships: Membership[];
  users:any[];
  orgs:any[];
  props:any[];
  payments:any[];
  cashflow:any[];
  messages:any[];
  paymentSubmissions:any[];
  tickets:any[];
  notifications:any[];
  tenancies:any[];
  channels:any[];
};

const requireSupabase=()=>{if(!supabase)throw new Error('Supabase is not configured');return supabase;};

export async function loadWorkspace(userId:string, requestedOrganizationId?:string):Promise<Workspace>{
  const db=requireSupabase();
  const [{data:profile,error:profileError},{data:admin,error:adminError},{data:authData,error:authError}] = await Promise.all([
    db.from('profiles').select('*').eq('id',userId).maybeSingle(),
    db.from('platform_admins').select('id').eq('id',userId).maybeSingle(),
    db.auth.getUser()
  ]);
  if(profileError)throw profileError;if(adminError)throw adminError;if(authError)throw authError;
  if(!profile&&!admin)throw new Error('Your authenticated account has no NestTrack profile. Complete onboarding or contact an administrator.');

  const profileData=profile||{
    full_name:authData.user.user_metadata?.full_name||authData.user.email?.split('@')[0]||'Administrator',
    email:authData.user.email||'',phone:null,avatar_url:null,role:null
  };
  const {data:membershipRows,error:membershipError}=admin
    ? await db.from('organization_members').select('organization_id,user_id,role,status,permissions').eq('status','active')
    : await db.from('organization_members').select('organization_id,user_id,role,status,permissions').eq('user_id',userId).eq('status','active');
  if(membershipError)throw membershipError;
  const memberships=(membershipRows||[]) as Membership[];

  // Managers and tenants may create an individual account before joining an
  // organization. In that state there is intentionally no active organization;
  // return a valid empty workspace so the UI can show the unprovisioned state
  // instead of treating the account as broken or inventing an organization.
  const validRequested=memberships.some(m=>m.organization_id===requestedOrganizationId);
  const activeOrganizationId=validRequested?requestedOrganizationId:(memberships[0]?.organization_id||'');
  const hasOrganization=admin||!!activeOrganizationId;
  const orgIds=memberships.map(m=>m.organization_id);
  const scopedIds=admin?orgIds:hasOrganization?[activeOrganizationId]:[];

  const [
    orgRes, membersRes, propsRes, unitsRes, tenRes, payRes, paymentSubmissionsRes, welfareRes,
    ticketRes, historyRes, paymentEventsRes, cashRes, convRes, convMembersRes, messageRes, notificationRes, channelsRes, channelMembersRes
  ]=await Promise.all([
    admin?db.from('organizations').select('*'):db.from('organizations').select('*').in('id',orgIds),
    admin?db.from('organization_members').select('*').eq('status','active'):hasOrganization?db.from('organization_members').select('*').eq('organization_id',activeOrganizationId).eq('status','active'):db.from('organization_members').select('*').in('organization_id',[]),
    admin?db.from('properties').select('*'):hasOrganization?db.from('properties').select('*').eq('organization_id',activeOrganizationId):db.from('properties').select('*').in('organization_id',[]),
    admin?db.from('units').select('*'):hasOrganization?db.from('units').select('*').eq('organization_id',activeOrganizationId):db.from('units').select('*').in('organization_id',[]),
    admin?db.from('tenancies').select('*'):hasOrganization?db.from('tenancies').select('*').eq('organization_id',activeOrganizationId):db.from('tenancies').select('*').in('organization_id',[]),
    admin?db.from('payments').select('*'):hasOrganization?db.from('payments').select('*').eq('organization_id',activeOrganizationId):db.from('payments').select('*').in('organization_id',[]),
    admin?db.from('rent_payment_submissions').select('*').order('submitted_at',{ascending:false}):hasOrganization?db.from('rent_payment_submissions').select('*').eq('organization_id',activeOrganizationId).order('submitted_at',{ascending:false}):db.from('rent_payment_submissions').select('*').in('organization_id',[]).order('submitted_at',{ascending:false}),
    admin?db.from('welfare_checks').select('*').order('checked_at',{ascending:false}):hasOrganization?db.from('welfare_checks').select('*').eq('organization_id',activeOrganizationId).order('checked_at',{ascending:false}):db.from('welfare_checks').select('*').in('organization_id',[]).order('checked_at',{ascending:false}),
    admin?db.from('maintenance_tickets').select('*'):hasOrganization?db.from('maintenance_tickets').select('*').eq('organization_id',activeOrganizationId):db.from('maintenance_tickets').select('*').in('organization_id',[]),
    admin?db.from('ticket_history').select('*').order('created_at',{ascending:false}):hasOrganization?db.from('ticket_history').select('*').eq('organization_id',activeOrganizationId).order('created_at',{ascending:false}):db.from('ticket_history').select('*').in('organization_id',[]).order('created_at',{ascending:false}),
    admin?db.from('ticket_payment_events').select('*').order('created_at',{ascending:false}):hasOrganization?db.from('ticket_payment_events').select('*').eq('organization_id',activeOrganizationId).order('created_at',{ascending:false}):db.from('ticket_payment_events').select('*').in('organization_id',[]).order('created_at',{ascending:false}),
    admin?db.from('cashflow_ledger').select('*').order('recorded_at',{ascending:false}):hasOrganization?db.from('cashflow_ledger').select('*').eq('organization_id',activeOrganizationId).order('recorded_at',{ascending:false}):db.from('cashflow_ledger').select('*').in('organization_id',[]).order('recorded_at',{ascending:false}),
    admin?db.from('conversations').select('*'):db.from('conversations').select('*'),
    db.rpc('get_my_conversation_members'),
    db.rpc('get_my_messages'),
    db.from('notifications').select('*').eq('recipient_user_id',userId).order('created_at',{ascending:false}).limit(100),
    db.from('channels').select('*'),
    db.from('channel_members').select('*')
  ]);

  for(const r of [orgRes,membersRes,propsRes,unitsRes,tenRes,payRes,paymentSubmissionsRes,welfareRes,ticketRes,cashRes,convRes,convMembersRes,messageRes,notificationRes,channelsRes,channelMembersRes]){
    if(r.error)throw r.error;
  }

  // The platform directory is intentionally separate from organization data.
  // It lets authenticated users discover message recipients without granting
  // them direct access to arbitrary organization records.
  const {data:directory,error:directoryError}=await db.rpc('get_user_directory');
  if(directoryError)throw directoryError;
  const directoryRows=(directory||[]) as any[];
  const profileMap=new Map<string,any>();
  for(const row of directoryRows){
    const existing=profileMap.get(row.user_id);
    if(existing){
      if(row.organization_id) existing.directoryOrganizations.push({id:row.organization_id,name:row.organization_name});
    } else {
      profileMap.set(row.user_id,{
        id:row.user_id, full_name:row.full_name, email:row.email, phone:row.phone,
        avatar_url:row.avatar_url, role:row.role,
        directoryOrganizations:row.organization_id?[{id:row.organization_id,name:row.organization_name}]:[]
      });
    }
  }
  const profiles=Array.from(profileMap.values());
  const activeTenancies=(tenRes.data||[]).filter((t:any)=>['active','move_out_requested'].includes(t.status));
  const tenancyFor=(tenantId:string)=>activeTenancies.find((t:any)=>t.tenant_id===tenantId);
  const unitFor=(unitId?:string)=>unitId?(unitsRes.data||[]).find((u:any)=>u.id===unitId):undefined;
  const propertyFor=(propertyId?:string)=>propertyId?(propsRes.data||[]).find((p:any)=>p.id===propertyId):undefined;

  const role:BackendRole=admin?'admin':((memberships.find(m=>m.organization_id===activeOrganizationId)?.role||profileData.role) as BackendRole);
  if(!role||!['admin','landlord','manager','tenant','technician'].includes(role))throw new Error('Your NestTrack profile has no valid role.');

  const orgs=(orgRes.data||[]).map((o:any)=>({
    id:o.id,name:o.name,ownerId:o.created_by||'',
    inviteManager:'',inviteTenant:'',status:o.status,slug:o.slug,settings:o.settings,paymentDetails:o.settings?.payment_details||{bankName:'',accountName:'',accountNumber:'',instructions:''}
  }));
  const activeOrg=orgs.find((o:any)=>o.id===activeOrganizationId)||{id:'platform',name:'NestTrack Platform',ownerId:'',inviteManager:'',inviteTenant:'',status:'active'};

  const users=(profiles||[]).map((p:any)=>{
    const ms=(membersRes.data||[]).filter((m:any)=>m.user_id===p.id);
    const m=ms.find((x:any)=>x.organization_id===activeOrganizationId)||ms[0];
    const welfare=(welfareRes.data||[]).find((w:any)=>w.tenant_id===p.id);
    const tenancy=tenancyFor(p.id);
    const tenancyUnit=unitFor(tenancy?.unit_id);
    const tenancyProperty=propertyFor(tenancyUnit?.property_id);
    return {
      id:p.id,name:p.full_name,email:p.email,phone:p.phone||'',avatar_url:p.avatar_url||undefined,password:'',
      role:(p.id===userId?role:(m?.role||p.role)) as BackendRole,
      orgId:m?.organization_id||'',propertyId:tenancyProperty?.id,unit:tenancyUnit?.label,welfare:welfare?.status||'Good',
      memberships:ms.map((x:any)=>({organizationId:x.organization_id,role:x.role,status:x.status,permissions:x.permissions||{}}))
    };
  });
  if(!users.some(u=>u.id===userId)){
    const ownTenancy=tenancyFor(userId);
    const ownUnit=unitFor(ownTenancy?.unit_id);
    const ownProperty=propertyFor(ownUnit?.property_id);
    users.push({id:userId,name:profileData.full_name,email:profileData.email,phone:profileData.phone||'',avatar_url:profileData.avatar_url||undefined,password:'',role,orgId:activeOrganizationId||'',propertyId:ownProperty?.id,unit:ownUnit?.label,welfare:'Good',memberships:memberships.map(m=>({organizationId:m.organization_id,role:m.role,status:m.status,permissions:m.permissions||{}}))});
  }

  const properties=(propsRes.data||[]).map((p:any)=>({
    id:p.id,orgId:p.organization_id,name:p.name,address:p.address,
    image:p.image_url||'',
    units:(unitsRes.data||[]).filter((u:any)=>u.property_id===p.id).map((u:any)=>{
      const tenancy=activeTenancies.find((t:any)=>t.unit_id===u.id);
      return {id:u.id,name:u.label,description:u.description||'',tenantId:tenancy?.tenant_id||u.current_tenant_id||undefined,rent:Number(tenancy?.rent_amount||u.rent_amount||0),status:u.status};
    })
  }));
  const payments=(payRes.data||[]).map((p:any)=>({id:p.id,tenantId:p.tenant_id,tenancyId:p.tenancy_id,amount:Number(p.amount_due),amountPaid:Number(p.amount_paid||0),due:p.due_date,status:p.status,method:p.method||'',receiptPath:p.receipt_path||null}));
  const paymentSubmissions=await Promise.all((paymentSubmissionsRes.data||[]).map(async(s:any)=>{
    const {data,error}=await db.storage.from('rent-payment-proofs').createSignedUrl(s.receipt_path,3600);
    return {id:s.id,organizationId:s.organization_id,tenantId:s.tenant_id,paymentIds:s.payment_ids||[],months:(s.payment_months||[]).map((month:string)=>String(month).slice(0,7)),amount:Number(s.amount),status:s.status,receiptPath:s.receipt_path,receiptUrl:error?null:data?.signedUrl||null,receiptUrlError:error?.message||null,submittedAt:s.submitted_at,confirmedBy:s.confirmed_by||null,confirmedAt:s.confirmed_at||null,rejectedBy:s.rejected_by||null,rejectedAt:s.rejected_at||null,rejectionNote:s.rejection_note||null};
  }));
  const tickets=(ticketRes.data||[]).map((t:any)=>({id:t.id,tenantId:t.tenant_id,title:t.title,description:t.description||'',category:t.category||'',status:t.status,priority:t.priority,assignedTo:t.assigned_to,propertyId:t.property_id,unitId:t.unit_id,history:(historyRes.data||[]).filter((h:any)=>h.ticket_id===t.id),paymentHistory:(paymentEventsRes.data||[]).filter((h:any)=>h.ticket_id===t.id),estimatedCost:t.estimated_cost==null?null:Number(t.estimated_cost),billingStatus:t.billing_status||'Not billable',paymentReference:t.payment_reference||null,paidConfirmedAt:t.paid_confirmed_at||null,paidConfirmedBy:t.paid_confirmed_by||null,tenantPaymentReference:t.tenant_payment_reference||null,reviewNote:t.payment_review_note||null}));
  const cashflow=(cashRes.data||[]).map((c:any)=>({id:c.id,landlordId:c.landlord_id,orgId:c.organization_id,paymentId:c.payment_id||'',tenantId:c.tenant_id||'',amount:Number(c.amount),type:c.type,status:c.status,timestamp:c.recorded_at,method:c.method||''}));
  const channelRows=(channelsRes.data||[]) as any[];
  const channelMembers=(channelMembersRes.data||[]) as any[];
  const channels=channelRows.map((c:any)=>({id:c.id,name:c.name,type:c.channel_type,visibility:c.visibility,organizationId:c.organization_id||null,propertyId:c.property_id||null,conversationId:c.conversation_id,members:channelMembers.filter((m:any)=>m.channel_id===c.id).map((m:any)=>m.user_id)}));
  const channelByConversation=new Map(channels.map((c:any)=>[c.conversationId,c]));
  const convIds=new Set((convMembersRes.data||[]).filter((m:any)=>m.user_id===userId).map((m:any)=>m.conversation_id));
  const visibleMessages=(messageRes.data||[]).filter((m:any)=>convIds.has(m.conversation_id));
  const participantPairs=(convMembersRes.data||[]).reduce((map:any,m:any)=>{
    if(!convIds.has(m.conversation_id))return map;
    const members=(convMembersRes.data||[]).filter((x:any)=>x.conversation_id===m.conversation_id);
    // Map each sender to the other conversation participant. Comparing to the
    // logged-in user here mis-mapped inbound messages as addressed to the
    // sender, causing the direct-thread UI filter to hide them.
    const other=members.find((x:any)=>x.user_id!==m.user_id);
    if(other)map[`${m.conversation_id}:${m.user_id}`]=other.user_id;
    return map;
  },{});
  const messages=visibleMessages.map((m:any)=>{
    const other=participantPairs[`${m.conversation_id}:${m.sender_id}`]||'';
    const channel=channelByConversation.get(m.conversation_id);
    return {id:m.id,from:m.sender_id,to:other,text:m.body,time:new Date(m.created_at).toLocaleTimeString([], {hour:'numeric',minute:'2-digit'}),conversationId:m.conversation_id,channelId:channel?.id,readAt:m.read_at,editedAt:m.edited_at||null,deletedAt:m.deleted_at||null};
  });
  const tenancies=(tenRes.data||[]).map((t:any)=>({
    id:t.id,organizationId:t.organization_id,unitId:t.unit_id,tenantId:t.tenant_id,
    startDate:t.start_date,endDate:t.end_date,rentAmount:Number(t.rent_amount||0),
    status:t.status,noticeDate:t.notice_date,requestedMoveOutDate:t.requested_move_out_date,
    reason:t.move_out_reason,tenantNote:t.tenant_note,managerNote:t.manager_note
  }));
  const notifications=(notificationRes.data||[]).map((n:any)=>({id:n.id,title:n.title,body:n.body,eventType:n.event_type,readAt:n.read_at,createdAt:n.created_at,organizationId:n.organization_id,relatedEntityType:n.related_entity_type||null,relatedEntityId:n.related_entity_id||null}));

  const ownTenancy=tenancyFor(userId);
  const ownUnit=unitFor(ownTenancy?.unit_id);
  const ownProperty=propertyFor(ownUnit?.property_id);
  return {
    current:{id:userId,name:profileData.full_name,email:profileData.email,password:'',role,orgId:activeOrganizationId||'',propertyId:ownProperty?.id,unit:ownUnit?.label,welfare:'Good',
      memberships:memberships.map(m=>({organizationId:m.organization_id,role:m.role,status:m.status,permissions:m.permissions||{}}))},
    memberships,users,orgs,props:properties,payments,paymentSubmissions,cashflow,messages,tickets,notifications,tenancies,channels
  };
}

export async function signIn(email:string,password:string){const db=requireSupabase();const {data,error}=await db.auth.signInWithPassword({email,password});if(error)throw error;return data.user!;}
export async function createIndependentProfile(fullName:string,role:'manager'|'tenant'|'technician',phone?:string){const db=requireSupabase();const {data,error}=await db.rpc('create_independent_profile',{p_full_name:fullName,p_role:role,p_phone:phone||null});if(error)throw error;return data as string;}
export async function signOut(){if(supabase)await supabase.auth.signOut();}

export async function createOrganization(name:string,slug?:string){const db=requireSupabase();const {data,error}=await db.rpc('create_organization',{p_name:name,p_slug:slug||null});if(error)throw error;return data;}
async function uploadPropertyImage(organizationId:string,file:File){
  const db=requireSupabase();
  if(!file.type.startsWith('image/'))throw new Error('Choose an image file.');
  if(file.size>10*1024*1024)throw new Error('Property images must be 10 MB or smaller.');
  const extension=file.name.split('.').pop()?.replace(/[^a-zA-Z0-9]/g,'')||'jpg';
  const path=`${(await db.auth.getUser()).data.user?.id}/${organizationId}/${crypto.randomUUID()}.${extension}`;
  const {error}=await db.storage.from('property-images').upload(path,file,{contentType:file.type,upsert:false});
  if(error)throw error;
  return db.storage.from('property-images').getPublicUrl(path).data.publicUrl;
}

export async function createProperty(organization_id:string,name:string,address:string,units:{name:string;description?:string;rent:number}[]=[],imageUrl?:string,imageFile?:File){
  const db=requireSupabase();
  const propertyImage=imageFile?await uploadPropertyImage(organization_id,imageFile):imageUrl||null;
  const {data,error}=await db.rpc('create_property_with_units',{p_organization_id:organization_id,p_name:name,p_address:address,p_units:units.map(u=>({name:u.name,description:u.description||'',rent:u.rent})),p_image_url:propertyImage});
  if(error)throw error;return data;
}
export async function updateProperty(id:string,organizationId:string,name:string,address:string,imageUrl:string,imageFile?:File){
  const db=requireSupabase();
  const propertyImage=imageFile?await uploadPropertyImage(organizationId,imageFile):imageUrl||null;
  const {error}=await db.rpc('update_property_as_landlord',{p_property_id:id,p_name:name,p_address:address,p_image_url:propertyImage});
  if(error)throw error;
}
export async function createUnit(propertyId:string,name:string,description:string,rent:number){
  const db=requireSupabase();
  const {data,error}=await db.rpc('create_unit_as_landlord',{p_property_id:propertyId,p_label:name,p_description:description,p_rent_amount:rent});
  if(error)throw error;return data;
}
export async function updateUnit(id:string,name:string,description:string,rent:number){
  const db=requireSupabase();
  const {error}=await db.rpc('update_unit_as_landlord',{p_unit_id:id,p_label:name,p_description:description,p_rent_amount:rent});
  if(error)throw error;
}
export async function uploadRentPaymentProof(paymentIds:string[],organizationId:string,file:File){
  const db=requireSupabase();
  if(!paymentIds.length)throw new Error('Select at least one month to submit.');
  if(!organizationId)throw new Error('Your active organization is missing.');
  const extensions:Record<string,string>={'image/jpeg':'jpg','image/png':'png','image/webp':'webp','image/gif':'gif'};
  const extension=extensions[file.type];
  if(!extension)throw new Error('Upload a JPG, PNG, WebP, or GIF screenshot/image.');
  if(file.size>10*1024*1024)throw new Error('Payment proof images must be 10 MB or smaller.');
  const {data:{user},error:userError}=await db.auth.getUser();
  if(userError)throw userError;
  if(!user)throw new Error('Sign in before submitting payment proof.');
  const path=`${organizationId}/${user.id}/${crypto.randomUUID()}.${extension}`;
  const {error:uploadError}=await db.storage.from('rent-payment-proofs').upload(path,file,{contentType:file.type,upsert:false});
  if(uploadError)throw uploadError;
  const {data,error}=await db.rpc('submit_rent_payment_evidence',{p_payment_ids:paymentIds,p_receipt_path:path});
  if(error)throw error;
  return data as string;
}
export async function confirmRentPaymentSubmission(id:string){
  const db=requireSupabase();
  const {error}=await db.rpc('confirm_rent_payment_submission',{p_submission_id:id});
  if(error)throw error;
}
export async function rejectRentPaymentSubmission(id:string,note:string){
  const trimmed=note.trim();
  if(!trimmed)throw new Error('Provide a reason before rejecting this submission.');
  const db=requireSupabase();
  const {error}=await db.rpc('reject_rent_payment_submission',{p_submission_id:id,p_note:trimmed});
  if(error)throw error;
}
export async function ensureMyRentPaymentSchedule():Promise<number>{
  const db=requireSupabase();
  const {data,error}=await db.rpc('ensure_my_rent_payment_schedule');
  if(error)throw error;
  return Number(data||0);
}
export async function updateTicket(id:string,status:string,assignee?:string,comment?:string){
  const db=requireSupabase();const {error}=await db.rpc('update_ticket_workflow',{p_ticket_id:id,p_status:status,p_assignee:assignee||null,p_comment:comment||null});
  if(error)throw error;
}
export async function sendDirectMessage(otherUserId:string,body:string,organizationId?:string){
  const db=requireSupabase();
  const {error}=await db.rpc('send_direct_message',{
    p_recipient_id:otherUserId,
    p_body:body,
    p_organization_id:organizationId||null
  });
  if(error)throw error;
}

export async function createChannel(input:{name:string;type:'property'|'organization'|'shared'|'platform';visibility:'private'|'organization'|'cross_organization'|'platform';organizationId?:string|null;propertyId?:string|null;memberIds?:string[]}){
  const db=requireSupabase();const {data,error}=await db.rpc('create_channel',{p_name:input.name,p_channel_type:input.type,p_visibility:input.visibility,p_organization_id:input.organizationId||null,p_property_id:input.propertyId||null,p_member_ids:input.memberIds||[]});if(error)throw error;return data as string;
}
export async function addChannelMember(channelId:string,userId:string){const db=requireSupabase();const {error}=await db.rpc('add_channel_member',{p_channel_id:channelId,p_user_id:userId});if(error)throw error;}
export async function removeChannelMember(channelId:string,userId:string){const db=requireSupabase();const {error}=await db.rpc('remove_channel_member',{p_channel_id:channelId,p_user_id:userId});if(error)throw error;}
export async function sendChannelMessage(channelId:string,body:string){const db=requireSupabase();const {data:channel,error:channelError}=await db.from('channels').select('conversation_id').eq('id',channelId).single();if(channelError)throw channelError;const {data:{user}}=await db.auth.getUser();if(!user)throw new Error('You must be signed in to send messages.');const {error}=await db.from('messages').insert({conversation_id:channel.conversation_id,sender_id:user.id,body});if(error)throw error;}
export async function markConversationRead(conversationId:string){const db=requireSupabase();const {error}=await db.rpc('mark_conversation_read',{p_conversation_id:conversationId});if(error)throw error;}
export async function markNotificationRead(id:string){const db=requireSupabase();const {error}=await db.rpc('mark_notification_read',{p_notification_id:id});if(error)throw error;}
export async function markAllNotificationsRead(){const db=requireSupabase();const {error}=await db.rpc('mark_all_notifications_read');if(error)throw error;}

export async function createInvitation(organizationId:string,email:string|undefined,role:'manager'|'tenant'|'technician',expiresAt?:string){
  const db=requireSupabase();const {data,error}=await db.rpc('create_organization_invitation',{p_organization_id:organizationId,p_email:email||null,p_role:role,p_expires_at:expiresAt||null,p_max_uses:1});
  if(error)throw error;return data as {id:string;token:string;organization_id:string;role:string;expires_at:string};
}
export async function acceptInvitation(token:string){const db=requireSupabase();const {data,error}=await db.rpc('accept_organization_invitation',{p_token:token});if(error)throw error;return data as string;}
export async function listInvitations(organizationId:string){
  const db=requireSupabase();const {data,error}=await db.from('organization_invitations').select('*').eq('organization_id',organizationId).order('created_at',{ascending:false});if(error)throw error;return data||[];
}
export async function revokeInvitation(id:string){const db=requireSupabase();const {error}=await db.rpc('revoke_organization_invitation',{p_invitation_id:id});if(error)throw error;}

export async function assignTenantToUnit(organizationId:string,unitId:string,tenantId:string,startDate:string,rentAmount:number){
  const db=requireSupabase();const {data,error}=await db.rpc('assign_tenant_to_unit',{p_organization_id:organizationId,p_unit_id:unitId,p_tenant_id:tenantId,p_start_date:startDate,p_rent_amount:rentAmount,p_frequency:'monthly',p_deposit_amount:0});if(error)throw error;return data;
}
export async function requestMoveOut(tenancyId:string,date:string,reason?:string,note?:string){
  const db=requireSupabase();const {data,error}=await db.rpc('request_move_out',{p_tenancy_id:tenancyId,p_requested_move_out_date:date,p_reason:reason||null,p_tenant_note:note||null});if(error)throw error;return data;
}
export async function decideMoveOut(tenancyId:string,approve:boolean,note?:string){
  const db=requireSupabase();const {data,error}=await db.rpc('decide_move_out',{p_tenancy_id:tenancyId,p_approve:approve,p_manager_note:note||null});if(error)throw error;return data;
}
export async function createTicket(organizationId:string,propertyId:string,unitId:string,title:string,description:string,category?:string,priority='Medium'){
  const db=requireSupabase();const {data,error}=await db.rpc('create_ticket',{p_organization_id:organizationId,p_property_id:propertyId,p_unit_id:unitId,p_title:title,p_description:description,p_category:category||null,p_priority:priority});if(error)throw error;return data;
}
export async function updateMessage(id:string,body:string){const db=requireSupabase();const {error}=await db.rpc('edit_message',{p_message_id:id,p_body:body});if(error)throw error;}
export async function deleteMessage(id:string){const db=requireSupabase();const {error}=await db.rpc('soft_delete_message',{p_message_id:id});if(error)throw error;}
export async function loadMessageHistory(id:string){const db=requireSupabase();const {data,error}=await db.rpc('get_message_history',{p_message_id:id});if(error)throw error;return data||[];}
export async function assignTicketTechnician(ticketId:string,technicianId:string|null){const db=requireSupabase();const {error}=await db.rpc('assign_ticket_technician',{p_ticket_id:ticketId,p_technician_id:technicianId});if(error)throw error;}
export async function submitTicketQuote(ticketId:string,amount:number){const db=requireSupabase();const {error}=await db.rpc('submit_ticket_quote',{p_ticket_id:ticketId,p_amount:amount});if(error)throw error;}
export async function approveTicketQuote(ticketId:string){const db=requireSupabase();const {error}=await db.rpc('approve_ticket_quote',{p_ticket_id:ticketId});if(error)throw error;}
export async function confirmTicketPayment(ticketId:string){const db=requireSupabase();const {error}=await db.rpc('confirm_ticket_payment',{p_ticket_id:ticketId});if(error)throw error;}
export async function submitTicketPaymentEvidence(ticketId:string,reference:string){const db=requireSupabase();const {error}=await db.rpc('submit_ticket_payment_evidence',{p_ticket_id:ticketId,p_payment_reference:reference});if(error)throw error;}
export async function disputeTicketPayment(ticketId:string,note:string){const db=requireSupabase();const {error}=await db.rpc('dispute_ticket_payment',{p_ticket_id:ticketId,p_note:note});if(error)throw error;}
export async function reviewTicketPayment(ticketId:string,approved:boolean,note:string){const db=requireSupabase();const {error}=await db.rpc('review_ticket_payment',{p_ticket_id:ticketId,p_approved:approved,p_note:note});if(error)throw error;}
export async function savePaymentDetails(organizationId:string,details:{bankName:string;accountName:string;accountNumber:string;instructions:string}){const db=requireSupabase();const {error}=await db.rpc('save_org_payment_details',{p_organization_id:organizationId,p_payment_details:details});if(error)throw error;}


export async function updateProfile(userId:string,full_name:string,phone:string,avatarFile?:File,removeAvatar=false){
  const db=requireSupabase();let avatar_url:string|undefined;
  if(avatarFile){
    const ext=avatarFile.name.split('.').pop()||'jpg';const path=`${userId}/avatar-${Date.now()}.${ext}`;
    const up=await db.storage.from('avatars').upload(path,avatarFile,{upsert:false,contentType:avatarFile.type});
    if(up.error)throw up.error;
    avatar_url=db.storage.from('avatars').getPublicUrl(path).data.publicUrl;
  }
  const payload:any={full_name,phone:phone||null};if(avatar_url)payload.avatar_url=avatar_url;if(removeAvatar)payload.avatar_url=null;
  const {error}=await db.from('profiles').update(payload).eq('id',userId);if(error)throw error;return avatar_url;
}
export async function deleteProfileImage(userId:string,avatarUrl?:string){
  const db=requireSupabase();if(avatarUrl){const marker='/avatars/';const i=avatarUrl.indexOf(marker);if(i>=0)await db.storage.from('avatars').remove([avatarUrl.slice(i+marker.length).split('?')[0]]);}
  const {error}=await db.from('profiles').update({avatar_url:null}).eq('id',userId);if(error)throw error;
}
export async function deleteMyAccount(){const db=requireSupabase();const {data:{user}}=await db.auth.getUser();if(!user)throw new Error('Not signed in');const {error}=await db.rpc('delete_my_account');if(error)throw error;await db.auth.signOut();}
export async function deleteOrganization(id:string){const db=requireSupabase();const {error}=await db.rpc('delete_organization_as_landlord',{p_organization_id:id});if(error)throw error;}
export async function deleteProperty(id:string){const db=requireSupabase();const {error}=await db.rpc('delete_property_as_landlord',{p_property_id:id});if(error)throw error;}
export async function deleteUnit(id:string){const db=requireSupabase();const {error}=await db.rpc('delete_unit_as_landlord',{p_unit_id:id});if(error)throw error;}
export async function deleteTenantAccount(id:string){const db=requireSupabase();const {error}=await db.rpc('delete_tenant_account',{p_tenant_id:id});if(error)throw error;}
export async function deleteLandlordAccount(id:string){const db=requireSupabase();const {error}=await db.rpc('admin_delete_landlord',{p_landlord_id:id});if(error)throw error;}

export {isSupabaseConfigured};
