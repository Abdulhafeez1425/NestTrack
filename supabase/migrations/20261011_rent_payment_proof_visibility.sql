begin;

-- The bucket remains private. These grants only make the rows eligible for
-- authenticated access; the RLS policies below still restrict each row/object.
grant select on public.rent_payment_submissions to authenticated;
grant select on storage.objects to authenticated;

-- Tenants see their own submission rows; active organization landlords and
-- managers can review every submission in their organization.
drop policy if exists "Tenant and operations view rent payment submissions"
  on public.rent_payment_submissions;
create policy "Tenant and operations view rent payment submissions"
  on public.rent_payment_submissions for select to authenticated
  using (
    tenant_id = auth.uid()
    or exists (
      select 1 from public.organization_members om
       where om.organization_id = rent_payment_submissions.organization_id
         and om.user_id = auth.uid()
         and om.status = 'active'
         and om.role in ('landlord','manager')
    )
  );

-- Stored paths are organization-id / tenant-id / file. A landlord can read
-- only proofs belonging to an organization where they have active membership.
drop policy if exists "Tenant and landlord view rent payment proof"
  on storage.objects;
create policy "Tenant and landlord view rent payment proof"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'rent-payment-proofs'
    and (
      (storage.foldername(name))[2] = auth.uid()::text
      or exists (
        select 1 from public.organization_members om
         where om.organization_id::text = (storage.foldername(name))[1]
           and om.user_id = auth.uid()
           and om.role in ('landlord','manager')
           and om.status = 'active'
      )
    )
  );

notify pgrst, 'reload schema';

commit;
