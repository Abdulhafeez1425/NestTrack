# NestTrack Demo Data

## Demo accounts
- Alice Johnson — Landlord — alice@nesttrack.demo — DemoPass#101
- Brian Smith — Manager — brian@nesttrack.demo — DemoPass#102
- Chloe Williams — Tenant — chloe@nesttrack.demo — DemoPass#103
- Daniel Brown — Tenant — daniel@nesttrack.demo — DemoPass#104
- Emma Davis — Manager — emma@nesttrack.demo — DemoPass#105
- Frank Wilson — Landlord — frank@nesttrack.demo — DemoPass#106

## Invite codes
Alice Johnson Properties:
- Manager: `NT-MGR-A7K9`
- Tenant: `NT-TEN-A2P4`

Frank Wilson Estates:
- Manager: `NT-MGR-F3Q8`
- Tenant: `NT-TEN-F5R2`

## Signup flow
1. New user selects **Landlord**, **Manager**, or **Tenant** first.
2. Landlord enters an organization name and creates a new organization.
3. Manager or Tenant enters the invite code supplied by the landlord.
4. NestTrack validates that the code belongs to the selected role and automatically attaches the new account to that organization.
5. There are no invite URLs/links; only role-specific invite codes are used.

## Platform Administrator
- Name: Administrator
- Login identifier: `Administrator` (the login accepts either name or email)
- Password: `@officialAdmin1#2*3-4`
- Role: Platform Administrator
- Access: Platform dashboard, registered landlord/organization overview, and direct communication with landlord accounts.


## Administrator cashflow
The Administrator has a timestamped landlord cashflow ledger. Every verified rent payment is recorded against the landlord and organization with timestamp, tenant, amount, method and status. The Administrator can export the ledger as CSV from the Admin dashboard or Cashflow records page.

## Returning-user identity verification
The login screen asks for the registered full name in addition to the email/name identifier and password. The last successful account name is remembered locally so returning users can confirm their identity.
