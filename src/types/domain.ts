export type Role = 'admin' | 'landlord' | 'manager' | 'tenant';

export type Membership = {
  organizationId: string;
  role: Exclude<Role, 'admin'>;
  status: string;
  permissions?: Record<string, boolean>;
};

export type Organization = {
  id: string;
  name: string;
  ownerId?: string;
  status?: string;
  slug?: string;
  settings?: Record<string, unknown>;
};

export type ChannelType = 'property' | 'organization' | 'shared' | 'platform';
export type ChannelVisibility = 'private' | 'organization' | 'cross_organization' | 'platform';

export type Channel = {
  id: string;
  organizationId?: string | null;
  propertyId?: string | null;
  name: string;
  type: ChannelType;
  visibility: ChannelVisibility;
};

export type UserDirectoryEntry = {
  id: string;
  fullName: string;
  email: string;
  phone?: string;
  avatarUrl?: string;
  role: Role;
  organizations: { id: string; name: string }[];
};
