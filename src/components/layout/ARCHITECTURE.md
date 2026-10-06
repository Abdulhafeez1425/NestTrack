# NestTrack clean architecture

Platform → Organization → Property → Unit → Tenancy

Communication crosses those boundaries through direct messages and channels:
- property channels
- organization channels
- shared cross-organization channels
- platform/admin channels

Identity (`profiles`), organization membership (`organization_members`) and occupancy (`tenancies`) remain separate concepts. PostgreSQL RLS/RPCs are authoritative; React only controls presentation and user experience.
