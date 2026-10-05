-- Fix conversation_members infinite RLS recursion.
-- Apply this migration to an existing Supabase database after the current
-- feature and platform-admin migrations.

CREATE OR REPLACE FUNCTION public.is_conversation_member(
  p_conversation_id uuid,
  p_user_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.conversation_members cm
    WHERE cm.conversation_id = p_conversation_id
      AND cm.user_id = p_user_id
      AND p_user_id = auth.uid()
  );
$$;

REVOKE ALL ON FUNCTION public.is_conversation_member(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_conversation_member(uuid, uuid) TO authenticated;

DROP POLICY IF EXISTS "conversation members read" ON public.conversations;
DROP POLICY IF EXISTS "conversation participants or admins read conversations" ON public.conversations;
CREATE POLICY "conversation participants or admins read conversations"
ON public.conversations FOR SELECT
USING (
  public.is_platform_admin()
  OR public.is_conversation_member(conversations.id, auth.uid())
);

DROP POLICY IF EXISTS "conversation members read membership" ON public.conversation_members;
DROP POLICY IF EXISTS "conversation participants read membership" ON public.conversation_members;
CREATE POLICY "conversation participants read membership"
ON public.conversation_members FOR SELECT
USING (
  user_id = auth.uid()
  OR public.is_conversation_member(conversation_members.conversation_id, auth.uid())
  OR public.is_platform_admin()
);

DROP POLICY IF EXISTS "conversation participants read messages" ON public.messages;
DROP POLICY IF EXISTS "conversation participants or admins read messages" ON public.messages;
CREATE POLICY "conversation participants or admins read messages"
ON public.messages FOR SELECT
USING (
  public.is_platform_admin()
  OR public.is_conversation_member(messages.conversation_id, auth.uid())
);

DROP POLICY IF EXISTS "conversation participants send messages" ON public.messages;
CREATE POLICY "conversation participants send messages"
ON public.messages FOR INSERT
WITH CHECK (
  sender_id = auth.uid()
  AND public.is_conversation_member(messages.conversation_id, auth.uid())
);
