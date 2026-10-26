-- CF FACEIT: enable .mp4 video uploads alongside .dem replays.
-- Run in Supabase SQL Editor AFTER SQL/43_game_demos.sql.
-- Existing .dem uploads and the one-upload-per-hour rule remain unchanged.

begin;

alter table public.cf_player_demos
  drop constraint if exists cf_player_demos_content_type_check;
alter table public.cf_player_demos
  add constraint cf_player_demos_content_type_check
  check (content_type in ('application/octet-stream','application/x-demo','video/mp4'));

insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values ('cf-player-demos','cf-player-demos',false,52428800,
        array['application/octet-stream','application/x-demo','video/mp4'])
on conflict (id) do update set public=false,file_size_limit=excluded.file_size_limit,
  allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists cf_player_demos_storage_insert on storage.objects;
create policy cf_player_demos_storage_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id='cf-player-demos'
    and name ~ ('^'||auth.uid()::text||'/[0-9a-f-]{36}[.](dem|mp4)$')
    and public.cf_demo_storage_access(name,'insert')
  );

create or replace function public.cf_demo_reserve_upload(
  p_file_name text,
  p_file_size bigint,
  p_content_type text default 'application/octet-stream'
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,auth,storage
as $function$
declare
  v_uid uuid:=auth.uid();
  v_now timestamptz:=clock_timestamp();
  v_next timestamptz;
  v_name text;
  v_ext text;
  v_mime text:=lower(coalesce(p_content_type,'application/octet-stream'));
  v_id uuid;
  v_path text;
begin
  if v_uid is null then raise exception 'Нужно войти в онлайн-аккаунт'; end if;
  v_name:=regexp_replace(left(trim(coalesce(p_file_name,'')),180),'[[:cntrl:]]','','g');
  v_ext:=lower(substring(v_name from '[.]([a-z0-9]+)$'));
  if v_name='' or v_ext is null or v_ext not in ('dem','mp4') then raise exception 'Разрешены только файлы .dem и .mp4'; end if;
  if p_file_size is null or p_file_size<1 or p_file_size>52428800 then raise exception 'Размер файла должен быть от 1 байта до 50 МБ'; end if;
  if (v_ext='mp4' and v_mime<>'video/mp4')
     or (v_ext='dem' and v_mime not in ('application/octet-stream','application/x-demo')) then
    raise exception 'Тип файла не совпадает с расширением';
  end if;

  insert into public.cf_player_demo_upload_limits(user_id,next_upload_at)
  values(v_uid,'-infinity'::timestamptz) on conflict(user_id) do nothing;
  select next_upload_at into v_next from public.cf_player_demo_upload_limits where user_id=v_uid for update;

  -- If Storage succeeded but the browser lost the final RPC response, refresh the
  -- completed reservation rather than asking the player to upload a duplicate.
  select id,object_path into v_id,v_path
    from public.cf_player_demos d
   where d.user_id=v_uid and d.status='uploading' and d.file_name=v_name
     and d.file_size_bytes=p_file_size and d.content_type=v_mime
     and exists(select 1 from storage.objects o where o.bucket_id='cf-player-demos' and o.name=d.object_path)
   order by d.created_at desc limit 1 for update;
  if v_id is not null then
    update public.cf_player_demos set status='ready',uploaded_at=coalesce(uploaded_at,v_now) where id=v_id;
    return jsonb_build_object('id',v_id,'object_path',v_path,'status','ready','next_upload_at',v_next,'retry',true);
  end if;

  -- Recover completed reservations and remove only abandoned, empty reservations.
  update public.cf_player_demos d set status='ready',uploaded_at=coalesce(uploaded_at,v_now)
   where d.user_id=v_uid and d.status='uploading'
     and exists(select 1 from storage.objects o where o.bucket_id='cf-player-demos' and o.name=d.object_path);
  delete from public.cf_player_demos d
   where d.user_id=v_uid and d.status='uploading' and d.created_at<v_now-interval '1 day'
     and not exists(select 1 from storage.objects o where o.bucket_id='cf-player-demos' and o.name=d.object_path);

  select id,object_path into v_id,v_path
    from public.cf_player_demos d
   where d.user_id=v_uid and d.status='uploading' and d.file_name=v_name
     and d.file_size_bytes=p_file_size and d.content_type=v_mime
     and d.created_at>v_now-interval '15 minutes'
     and not exists(select 1 from storage.objects o where o.bucket_id='cf-player-demos' and o.name=d.object_path)
   order by d.created_at desc limit 1 for update;
  if v_id is not null then
    return jsonb_build_object('id',v_id,'object_path',v_path,'status','uploading','next_upload_at',v_next,'retry',true);
  end if;
  if v_next>v_now then
    raise exception 'Следующая загрузка доступна после %',to_char(v_next at time zone 'UTC','YYYY-MM-DD HH24:MI UTC');
  end if;

  v_id:=gen_random_uuid();
  v_path:=v_uid::text||'/'||v_id::text||'.'||v_ext;
  insert into public.cf_player_demos(id,user_id,object_path,file_name,file_size_bytes,content_type,status)
  values(v_id,v_uid,v_path,v_name,p_file_size,v_mime,'uploading');
  v_next:=v_now+interval '1 hour';
  update public.cf_player_demo_upload_limits set next_upload_at=v_next where user_id=v_uid;
  return jsonb_build_object('id',v_id,'object_path',v_path,'status','uploading','next_upload_at',v_next,'retry',false);
end;
$function$;
revoke all on function public.cf_demo_reserve_upload(text,bigint,text) from public,anon;
grant execute on function public.cf_demo_reserve_upload(text,bigint,text) to authenticated;

commit;
