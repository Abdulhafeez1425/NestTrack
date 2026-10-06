import type { Membership, Role } from '../types/domain';

export type Capability =
  | 'view_organization' | 'manage_organization' | 'manage_members'
  | 'manage_properties' | 'manage_units' | 'assign_tenants'
  | 'invite_members' | 'view_financials' | 'create_ticket'
  | 'assign_ticket' | 'change_ticket_status' | 'approve_move_out'
  | 'send_message' | 'view_audit';

const roleDefaults: Record<Exclude<Role, 'admin'>, Capability[]> = {
  landlord: ['view_organization','manage_organization','manage_members','manage_properties','manage_units','assign_tenants','invite_members','view_financials','create_ticket','assign_ticket','change_ticket_status','approve_move_out','send_message','view_audit'],
  manager: ['view_organization','manage_properties','manage_units','assign_tenants','invite_members','create_ticket','assign_ticket','change_ticket_status','approve_move_out','send_message'],
  tenant: ['view_organization','create_ticket','send_message'],
};

export function can(role: Role, capability: Capability, membership?: Membership) {
  if (role === 'admin') return true;
  if (membership?.permissions && capability in membership.permissions) return Boolean(membership.permissions[capability]);
  return roleDefaults[role]?.includes(capability) ?? false;
}
