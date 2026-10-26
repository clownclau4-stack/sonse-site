-- CF FACEIT v51: include a safe, explicit uploader name in every shared demo entry.
-- Run in Supabase SQL Editor AFTER SQL/43_game_demos.sql.
-- All authenticated accounts receive the same public feed; private demo files remain in Storage.

begin;

create or replace function public.cf_demo_state()
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,auth
as $function$
declare
  v_uid uuid:=auth.uid();
  v_next timestamptz;
  v_feed jsonb;
  v_pending jsonb;
begin
  if v_uid is null then raise exception 'Нужно войти в онлайн-аккаунт'; end if;
  select next_upload_at into v_next
    from public.cf_player_demo_upload_limits where user_id=v_uid;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',q.id,
    'object_path',q.object_path,
    'file_name',q.file_name,
    'file_size_bytes',q.file_size_bytes,
    'uploaded_at',q.uploaded_at,
    'player',q.player,
    'author',coalesce(nullif(q.player->>'display_name',''),nullif(q.player->>'nickname',''),'Игрок'),
    'is_mine',q.user_id=v_uid
  ) order by q.uploaded_at desc),'[]'::jsonb) into v_feed
  from (
    select d.id,d.user_id,d.object_path,d.file_name,d.file_size_bytes,d.uploaded_at,
      public.cf_lobby_user_json(d.user_id) as player
    from public.cf_player_demos d
    where d.status='ready'
    order by d.uploaded_at desc
    limit 100
  ) q;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',d.id,'file_name',d.file_name,'file_size_bytes',d.file_size_bytes,'created_at',d.created_at
  ) order by d.created_at desc),'[]'::jsonb) into v_pending
  from (
    select id,file_name,file_size_bytes,created_at
    from public.cf_player_demos
    where user_id=v_uid and status='uploading'
    order by created_at desc
    limit 10
  ) d;

  return jsonb_build_object(
    'demos',coalesce(v_feed,'[]'::jsonb),
    'pending',coalesce(v_pending,'[]'::jsonb),
    'next_upload_at',v_next
  );
end;
$function$;

revoke all on function public.cf_demo_state() from public,anon;
grant execute on function public.cf_demo_state() to authenticated;

commit;

select 'CF FACEIT v51 shared demo author field installed' as result;
