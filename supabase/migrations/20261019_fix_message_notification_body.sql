begin;

-- A platform administrator may not have a public profile row. SELECT INTO
-- leaves sender_name null when no row is found, which previously created a
-- notification with a null body when an Admin replied to support.
create or replace function public.notify_message_recipients()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  conversation_org uuid;
  channel_message boolean;
  sender_name text;
  notification_title text;
begin
  select c.organization_id into conversation_org
    from public.conversations c
   where c.id = new.conversation_id;

  select exists(
    select 1 from public.channels ch where ch.conversation_id = new.conversation_id
  ) into channel_message;

  select coalesce(p.full_name, 'A NestTrack user') into sender_name
    from public.profiles p where p.id = new.sender_id;
  sender_name := coalesce(sender_name, 'A NestTrack user');

  notification_title := case when channel_message then 'New channel message' else 'New direct message' end;

  insert into public.notifications(
    recipient_user_id,organization_id,event_type,title,body,related_entity_type,related_entity_id
  )
  select cm.user_id,conversation_org,
         case when channel_message then 'channel_message' else 'direct_message' end,
         notification_title,
         coalesce(sender_name, 'A NestTrack user') || ': ' || coalesce(left(new.body,240), ''),
         'message',new.id
    from public.conversation_members cm
   where cm.conversation_id = new.conversation_id
     and cm.user_id is distinct from new.sender_id;

  return new;
end;
$$;

notify pgrst,'reload schema';
commit;
