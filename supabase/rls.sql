DO $$
DECLARE
t text;
BEGIN
FOREACH t IN ARRAY ARRAY[
'organizations',
'profiles',
'organization_members',
'properties',
'units',
'tenancies',
'payments',
'welfare_checks',
'conversations',
'conversation_members',
'messages',
'maintenance_tickets',
'audit_events'
]
LOOP
EXECUTE format(
'ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',
t
);
END LOOP;
END $$;

-- ============================================================
-- SECURITY HELPER FUNCTION
-- ============================================================

CREATE OR REPLACE FUNCTION public.is_org_member(target_org uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
SELECT EXISTS (
SELECT 1
FROM public.organization_members om
WHERE om.organization_id = target_org
AND om.user_id = auth.uid()
AND om.status = 'active'
);
$$;

-- ============================================================
-- REMOVE EXISTING POLICIES
-- This makes the script safe to re-run.
-- ============================================================

-- ORGANIZATIONS

DROP POLICY IF EXISTS "org members read organization"
ON public.organizations;

-- PROFILES

DROP POLICY IF EXISTS "self profile"
ON public.profiles;

-- ORGANIZATION MEMBERS

DROP POLICY IF EXISTS "members read membership"
ON public.organization_members;

-- PROPERTIES

DROP POLICY IF EXISTS "members read properties"
ON public.properties;

DROP POLICY IF EXISTS "managers manage properties"
ON public.properties;

-- UNITS

DROP POLICY IF EXISTS "members read units"
ON public.units;

-- TENANCIES

DROP POLICY IF EXISTS "members read tenancies"
ON public.tenancies;

-- PAYMENTS

DROP POLICY IF EXISTS "members read payments"
ON public.payments;

DROP POLICY IF EXISTS "tenant submit payment"
ON public.payments;

DROP POLICY IF EXISTS "manager verify payment"
ON public.payments;

-- WELFARE CHECKS

DROP POLICY IF EXISTS "welfare visible to operations"
ON public.welfare_checks;

DROP POLICY IF EXISTS "operations manage welfare"
ON public.welfare_checks;

-- CONVERSATIONS

DROP POLICY IF EXISTS "conversation members read"
ON public.conversations;

-- CONVERSATION MEMBERS

DROP POLICY IF EXISTS "conversation members read membership"
ON public.conversation_members;

-- MESSAGES

DROP POLICY IF EXISTS "conversation participants read messages"
ON public.messages;

DROP POLICY IF EXISTS "conversation participants send messages"
ON public.messages;

-- MAINTENANCE TICKETS

DROP POLICY IF EXISTS "members read tickets"
ON public.maintenance_tickets;

DROP POLICY IF EXISTS "tenant create tickets"
ON public.maintenance_tickets;

DROP POLICY IF EXISTS "operations update tickets"
ON public.maintenance_tickets;

-- AUDIT EVENTS

DROP POLICY IF EXISTS "operations read audit"
ON public.audit_events;

-- ============================================================
-- CORE POLICIES
-- ============================================================

-- ORGANIZATIONS

CREATE POLICY "org members read organization"
ON public.organizations
FOR SELECT
USING (
public.is_org_member(id)
);

-- PROFILES

CREATE POLICY "self profile"
ON public.profiles
FOR ALL
USING (
auth.uid() = id
)
WITH CHECK (
auth.uid() = id
);

-- ORGANIZATION MEMBERS

CREATE POLICY "members read membership"
ON public.organization_members
FOR SELECT
USING (
user_id = auth.uid()
OR public.is_org_member(organization_id)
);

-- PROPERTIES

CREATE POLICY "members read properties"
ON public.properties
FOR SELECT
USING (
public.is_org_member(organization_id)
);

CREATE POLICY "managers manage properties"
ON public.properties
FOR ALL
USING (
EXISTS (
SELECT 1
FROM public.organization_members om
WHERE om.organization_id = properties.organization_id
AND om.user_id = auth.uid()
AND om.role IN ('landlord', 'manager')
AND om.status = 'active'
)
)
WITH CHECK (
EXISTS (
SELECT 1
FROM public.organization_members om
WHERE om.organization_id = properties.organization_id
AND om.user_id = auth.uid()
AND om.role IN ('landlord', 'manager')
AND om.status = 'active'
)
);

-- UNITS

CREATE POLICY "members read units"
ON public.units
FOR SELECT
USING (
public.is_org_member(organization_id)
);

-- TENANCIES

CREATE POLICY "members read tenancies"
ON public.tenancies
FOR SELECT
USING (
public.is_org_member(organization_id)
AND (
tenant_id = auth.uid()
OR EXISTS (
SELECT 1
FROM public.organization_members om
WHERE om.organization_id = tenancies.organization_id
AND om.user_id = auth.uid()
AND om.role IN ('landlord', 'manager')
)
)
);

-- PAYMENTS

CREATE POLICY "members read payments"
ON public.payments
FOR SELECT
USING (
public.is_org_member(organization_id)
AND (
tenant_id = auth.uid()
OR EXISTS (
SELECT 1
FROM public.organization_members om
WHERE om.organization_id = payments.organization_id
AND om.user_id = auth.uid()
AND om.role IN ('landlord', 'manager')
)
)
);

CREATE POLICY "tenant submit payment"
ON public.payments
FOR INSERT
WITH CHECK (
tenant_id = auth.uid()
AND public.is_org_member(organization_id)
);

CREATE POLICY "manager verify payment"
ON public.payments
FOR UPDATE
USING (
EXISTS (
SELECT 1
FROM public.organization_members om
WHERE om.organization_id = payments.organization_id
AND om.user_id = auth.uid()
AND om.role IN ('landlord', 'manager')
)
);

-- WELFARE CHECKS

CREATE POLICY "welfare visible to operations"
ON public.welfare_checks
FOR SELECT
USING (
public.is_org_member(organization_id)
);

CREATE POLICY "operations manage welfare"
ON public.welfare_checks
FOR ALL
USING (
EXISTS (
SELECT 1
FROM public.organization_members om
WHERE om.organization_id = welfare_checks.organization_id
AND om.user_id = auth.uid()
AND om.role IN ('landlord', 'manager')
)
);

-- CONVERSATIONS

CREATE POLICY "conversation members read"
ON public.conversations
FOR SELECT
USING (
public.is_org_member(organization_id)
AND EXISTS (
SELECT 1
FROM public.conversation_members cm
WHERE cm.conversation_id = conversations.id
AND cm.user_id = auth.uid()
)
);

-- CONVERSATION MEMBERS

CREATE POLICY "conversation members read membership"
ON public.conversation_members
FOR SELECT
USING (
user_id = auth.uid()
OR EXISTS (
SELECT 1
FROM public.conversation_members cm
WHERE cm.conversation_id =
conversation_members.conversation_id
AND cm.user_id = auth.uid()
)
);

-- MESSAGES

CREATE POLICY "conversation participants read messages"
ON public.messages
FOR SELECT
USING (
EXISTS (
SELECT 1
FROM public.conversation_members cm
WHERE cm.conversation_id = messages.conversation_id
AND cm.user_id = auth.uid()
)
);

CREATE POLICY "conversation participants send messages"
ON public.messages
FOR INSERT
WITH CHECK (
sender_id = auth.uid()
AND EXISTS (
SELECT 1
FROM public.conversation_members cm
WHERE cm.conversation_id = messages.conversation_id
AND cm.user_id = auth.uid()
)
);

-- MAINTENANCE TICKETS

CREATE POLICY "members read tickets"
ON public.maintenance_tickets
FOR SELECT
USING (
public.is_org_member(organization_id)
AND (
tenant_id = auth.uid()
OR EXISTS (
SELECT 1
FROM public.organization_members om
WHERE om.organization_id =
maintenance_tickets.organization_id
AND om.user_id = auth.uid()
AND om.role IN ('landlord', 'manager')
)
)
);

CREATE POLICY "tenant create tickets"
ON public.maintenance_tickets
FOR INSERT
WITH CHECK (
tenant_id = auth.uid()
AND public.is_org_member(organization_id)
);

CREATE POLICY "operations update tickets"
ON public.maintenance_tickets
FOR UPDATE
USING (
EXISTS (
SELECT 1
FROM public.organization_members om
WHERE om.organization_id =
maintenance_tickets.organization_id
AND om.user_id = auth.uid()
AND om.role IN ('landlord', 'manager')
)
);

-- AUDIT EVENTS

CREATE POLICY "operations read audit"
ON public.audit_events
FOR SELECT
USING (
public.is_org_member(organization_id)
);

-- ============================================================
-- PLATFORM TABLES
-- ============================================================

ALTER TABLE public.platform_admins ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invite_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cashflow_ledger ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.is_platform_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.platform_admins WHERE id = auth.uid()
  );
$$;

REVOKE ALL ON FUNCTION public.is_platform_admin() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_platform_admin() TO authenticated;

-- ============================================================
-- REMOVE EXISTING PLATFORM POLICIES
-- ============================================================

DROP POLICY IF EXISTS "platform admins read own record"
ON public.platform_admins;

DROP POLICY IF EXISTS "platform admins manage invites"
ON public.invite_codes;

DROP POLICY IF EXISTS "org members read invites"
ON public.invite_codes;

DROP POLICY IF EXISTS "landlords create invites"
ON public.invite_codes;

DROP POLICY IF EXISTS "org members read cashflow"
ON public.cashflow_ledger;

DROP POLICY IF EXISTS "platform admins read cashflow"
ON public.cashflow_ledger;

-- ============================================================
-- PLATFORM ADMIN POLICIES
-- ============================================================

CREATE POLICY "platform admins read own record"
ON public.platform_admins
FOR SELECT
USING (
id = auth.uid()
);

-- ============================================================
-- INVITE CODE POLICIES
-- ============================================================

CREATE POLICY "platform admins manage invites"
ON public.invite_codes
FOR ALL
USING (
EXISTS (
SELECT 1
FROM public.platform_admins
WHERE id = auth.uid()
)
)
WITH CHECK (
EXISTS (
SELECT 1
FROM public.platform_admins
WHERE id = auth.uid()
)
);

CREATE POLICY "org members read invites"
ON public.invite_codes
FOR SELECT
USING (
public.is_org_member(organization_id)
);

CREATE POLICY "landlords create invites"
ON public.invite_codes
FOR INSERT
WITH CHECK (
EXISTS (
SELECT 1
FROM public.organization_members om
WHERE om.organization_id =
invite_codes.organization_id
AND om.user_id = auth.uid()
AND om.role = 'landlord'
AND om.status = 'active'
)
);

-- ============================================================
-- CASHFLOW POLICIES
-- ============================================================

CREATE POLICY "org members read cashflow"
ON public.cashflow_ledger
FOR SELECT
USING (
public.is_org_member(organization_id)
);

CREATE POLICY "platform admins read cashflow"
ON public.cashflow_ledger
FOR SELECT
USING (
EXISTS (
SELECT 1
FROM public.platform_admins
WHERE id = auth.uid()
)
);

-- Platform administrators need read-only access to the data shown in their dashboard.
DROP POLICY IF EXISTS "platform admins read workspace data" ON public.organizations;
CREATE POLICY "platform admins read workspace data" ON public.organizations
FOR SELECT USING (public.is_platform_admin());

DROP POLICY IF EXISTS "platform admins read workspace data" ON public.profiles;
CREATE POLICY "platform admins read workspace data" ON public.profiles
FOR SELECT USING (public.is_platform_admin());

DROP POLICY IF EXISTS "platform admins read workspace data" ON public.organization_members;
CREATE POLICY "platform admins read workspace data" ON public.organization_members
FOR SELECT USING (public.is_platform_admin());

DROP POLICY IF EXISTS "platform admins read workspace data" ON public.properties;
CREATE POLICY "platform admins read workspace data" ON public.properties
FOR SELECT USING (public.is_platform_admin());

DROP POLICY IF EXISTS "platform admins read workspace data" ON public.units;
CREATE POLICY "platform admins read workspace data" ON public.units
FOR SELECT USING (public.is_platform_admin());

DROP POLICY IF EXISTS "platform admins read workspace data" ON public.tenancies;
CREATE POLICY "platform admins read workspace data" ON public.tenancies
FOR SELECT USING (public.is_platform_admin());

DROP POLICY IF EXISTS "platform admins read workspace data" ON public.payments;
CREATE POLICY "platform admins read workspace data" ON public.payments
FOR SELECT USING (public.is_platform_admin());

DROP POLICY IF EXISTS "platform admins read workspace data" ON public.welfare_checks;
CREATE POLICY "platform admins read workspace data" ON public.welfare_checks
FOR SELECT USING (public.is_platform_admin());

DROP POLICY IF EXISTS "platform admins read workspace data" ON public.maintenance_tickets;
CREATE POLICY "platform admins read workspace data" ON public.maintenance_tickets
FOR SELECT USING (public.is_platform_admin());

DROP POLICY IF EXISTS "platform admins read workspace data" ON public.invite_codes;
CREATE POLICY "platform admins read workspace data" ON public.invite_codes
FOR SELECT USING (public.is_platform_admin());
