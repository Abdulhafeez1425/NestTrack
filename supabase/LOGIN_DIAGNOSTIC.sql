-- NestTrack login/workspace diagnostic
-- Run this in Supabase SQL Editor after replacing the email below.

WITH target AS (
  SELECT id, email, raw_user_meta_data
  FROM auth.users
  WHERE lower(email) = lower('YOUR-LOGIN-EMAIL-HERE')
),
profile AS (
  SELECT p.*
  FROM public.profiles p
  JOIN target t ON t.id = p.id
),
membership AS (
  SELECT om.*
  FROM public.organization_members om
  JOIN target t ON t.id = om.user_id
)
SELECT
  t.id AS auth_user_id,
  t.email AS auth_email,
  p.id AS profile_id,
  p.role AS profile_role,
  m.organization_id,
  m.role AS membership_role,
  m.status AS membership_status,
  CASE
    WHEN p.id IS NULL THEN 'MISSING PROFILE'
    WHEN m.user_id IS NULL THEN 'MISSING ORGANIZATION MEMBERSHIP'
    WHEN m.status <> 'active' THEN 'INACTIVE ORGANIZATION MEMBERSHIP'
    WHEN COALESCE(m.role, p.role) NOT IN ('admin','landlord','manager','tenant') THEN 'INVALID ROLE'
    ELSE 'LOGIN WORKSPACE RECORDS LOOK OK'
  END AS diagnosis
FROM target t
LEFT JOIN profile p ON true
LEFT JOIN membership m ON true;

-- If the result says MISSING PROFILE or MISSING ORGANIZATION MEMBERSHIP,
-- do not create records manually until you confirm the user's intended role.
-- The normal path is to use NestTrack signup/onboarding or assign the user
-- through your administrator workflow.
