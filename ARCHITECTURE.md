# NestTrack Clean Architecture

## Core hierarchy

**NestTrack Platform → Organization → Property → Unit → Tenancy**

Identity, membership and occupancy are deliberately separate:

- `profiles` = identity/contact information.
- `organization_members` = access to an organization and role.
- `properties` = property groups/buildings.
- `units` = physical units.
- `tenancies` = time-based tenant occupancy.

## Communication hierarchy

Communication is not forced into one organization boundary:

- Direct messages: any authenticated NestTrack user can contact another permitted account through the participant-secured conversation RPC.
- Property channels: conversations about one property.
- Organization channels: organization-wide communication.
- Shared channels: cross-organization collaboration.
- Platform channels: administrator/system communication.

## Authorization

Security is layered:

1. React UI capability checks for usability.
2. Backend RPC/service validation for business rules and atomic workflows.
3. PostgreSQL RLS as the final authorization boundary.

The active organization is selected explicitly and persisted only as a convenience. Server-side membership is always authoritative.

## Authentication model

- **Landlord signup:** creates an individual account and a new organization.
- **Manager signup:** creates an individual account; organization membership is added later through a secure invitation.
- **Tenant signup:** creates an individual account; organization/unit membership is added later through a secure invitation and tenancy workflow.
- **Login:** always authenticates through Supabase Auth, then loads the server-authoritative profile and memberships.
- **Platform admin:** is separate from organization roles and is managed through `platform_admins`.
