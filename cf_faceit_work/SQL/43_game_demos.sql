-- CF FACEIT v50: player demo gallery with private Storage and an atomic hourly upload limit.
-- Run in Supabase SQL Editor AFTER SQL/42_sponsor_badge_and_profile_customization.sql.
-- Assumption: CounterFlame replay files use the common .dem extension. If the game exports another format,
-- confirm it first and change the allowlist deliberately; arbitrary archives/executables are not accepted.

begin;

create table if not exists public.cf_player_demo_upload_limits (
  user_id uuid primary key references auth.users(id) on delete cascade,
  next_upload_at timestamptz not null default '-infinity'::timestamptz
);

create table if not exists public.cf_player_demos (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  object_path text not null unique,
  file_name text not null,
  file_size_bytes bigint not null check (file_size_bytes between 1 and 52428800),
  content_type text not null check (content_type in ('application/octet-stream','application/x-demo')),
  status text not null default 'uploading' check (status in ('uploading','ready')),
  created_at timestamptz not null default clock_timestamp(),
  uploaded_at timestamptz
);
create index if not exists cf_player_demos_public_feed_idx
  on public.cf_player_demos (uploaded_at desc) where status='ready';
create index if not exists cf_player_demos_owner_idx
  on public.cf_player_demos (user_id, created_at desc);

alter table public.cf_player_demos enable row level security;
alter table public.cf_player_demo_upload_limits enable row level security;
revoke all on public.cf_player_demos,public.cf_player_demo_upload_limits from public,anon,authenticated;

insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values ('cf-player-demos','cf-player-demos',false,52428800,
        array['application/octet-stream','application/x-demo'])
on conflict (id) do update set public=false,file_size_limit=excluded.file_size_limit,
  allowed_mime_types=excluded.allowed_mime_types;

-- Storage policies call this definer helper so the browser cannot bypass the
-- reservation table or read an unfinished/foreign upload by guessing a path.
create or replace function public.cf_demo_storage_access(p_path text,p_action text)
returns boolean
language sql
stable
security definer
set search_path=pg_catalog,public,auth
as $function$
  select auth.uid() is not null and exists (
    select 1 from public.cf_player_demos d
    where d.object_path=p_path
      and case p_action
        when 'insert' then d.user_id=auth.uid() and d.status='uploading'
        when 'read' then d.status='ready'
        when 'delete' then d.user_id=auth.uid()
        else false
      end
  )
$function$;
revoke all on function public.cf_demo_storage_access(text,text) from public,anon;
grant execute on function public.cf_demo_storage_access(text,text) to authenticated;

drop policy if exists cf_player_demos_storage_insert on storage.objects;
create policy cf_player_demos_storage_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id='cf-player-demos'
    and name ~ ('^'||auth.uid()::text||'/[0-9a-f-]{36}[.]dem$')
    and public.cf_demo_storage_access(name,'insert')
  );
drop policy if exists cf_player_demos_storage_read on storage.objects;
create policy cf_player_demos_storage_read on storage.objects
  for select to authenticated
  using (bucket_id='cf-player-demos' and public.cf_demo_storage_access(name,'read'));
drop policy if exists cf_player_demos_storage_delete on storage.objects;
create policy cf_player_demos_storage_delete on storage.objects
  for delete to authenticated
  using (bucket_id='cf-player-demos' and public.cf_demo_storage_access(name,'delete'));

-- Reserve one per-account upload slot under a row lock. A failed network upload
-- may reuse the exact reservation and same filename/size for 15 minutes.
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
  v_mime text:=lower(coalesce(p_content_type,'application/octet-stream'));
  v_id uuid;
  v_path text;
begin
  if v_uid is null then raise exception 'Нужно войти в онлайн-аккаунт'; end if;
  v_name:=regexp_replace(left(trim(coalesce(p_file_name,'')),180),'[[:cntrl:]]','','g');
  if v_name='' or right(lower(v_name),4)<>'.dem' then raise exception 'Разрешены только демки игры с расширением .dem'; end if;
  if p_file_size is null or p_file_size<1 or p_file_size>52428800 then raise exception 'Размер демки должен быть от 1 байта до 50 МБ'; end if;
  if v_mime not in ('application/octet-stream','application/x-demo') then raise exception 'Неподдерживаемый формат демки'; end if;

  insert into public.cf_player_demo_upload_limits(user_id,next_upload_at)
  values(v_uid,'-infinity'::timestamptz) on conflict(user_id) do nothing;
  select next_upload_at into v_next from public.cf_player_demo_upload_limits where user_id=v_uid for update;

  -- If Storage succeeded but the browser lost the final RPC response, return the
  -- completed reservation so the UI can simply refresh instead of uploading twice.
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

  -- Recover any other Storage uploads whose final RPC was interrupted; remove abandoned
  -- empty reservations after one day without touching stored objects.
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
  v_path:=v_uid::text||'/'||v_id::text||'.dem';
  insert into public.cf_player_demos(id,user_id,object_path,file_name,file_size_bytes,content_type,status)
  values(v_id,v_uid,v_path,v_name,p_file_size,v_mime,'uploading');
  v_next:=v_now+interval '1 hour';
  update public.cf_player_demo_upload_limits set next_upload_at=v_next where user_id=v_uid;
  return jsonb_build_object('id',v_id,'object_path',v_path,'status','uploading','next_upload_at',v_next,'retry',false);
end;
$function$;
revoke all on function public.cf_demo_reserve_upload(text,bigint,text) from public,anon;
grant execute on function public.cf_demo_reserve_upload(text,bigint,text) to authenticated;

create or replace function public.cf_demo_finish_upload(p_demo_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,auth,storage
as $function$
declare
  v_uid uuid:=auth.uid();
  v_path text;
  v_size bigint;
  v_storage_size text;
  v_uploaded timestamptz:=clock_timestamp();
begin
  if v_uid is null then raise exception 'Нужно войти в онлайн-аккаунт'; end if;
  select object_path,file_size_bytes into v_path,v_size
    from public.cf_player_demos where id=p_demo_id and user_id=v_uid and status='uploading' for update;
  if v_path is null then raise exception 'Заявка на загрузку не найдена'; end if;
  select o.metadata->>'size' into v_storage_size from storage.objects o
    where o.bucket_id='cf-player-demos' and o.name=v_path;
  if not found then raise exception 'Файл демки ещё не появился в хранилище'; end if;
  if v_storage_size ~ '^[0-9]+$' and v_storage_size::bigint<>v_size then
    raise exception 'Размер загруженного файла не совпадает с заявленным';
  end if;
  update public.cf_player_demos set status='ready',uploaded_at=v_uploaded where id=p_demo_id and user_id=v_uid;
  return jsonb_build_object('ok',true,'id',p_demo_id,'uploaded_at',v_uploaded);
end;
$function$;
revoke all on function public.cf_demo_finish_upload(uuid) from public,anon;
grant execute on function public.cf_demo_finish_upload(uuid) to authenticated;

-- The feed deliberately exposes only already-published replay metadata and the
-- existing safe public profile payload; files themselves remain in a private bucket.
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
  select next_upload_at into v_next from public.cf_player_demo_upload_limits where user_id=v_uid;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',q.id,'object_path',q.object_path,'file_name',q.file_name,
    'file_size_bytes',q.file_size_bytes,'uploaded_at',q.uploaded_at,
    'player',q.player,'is_mine',q.user_id=v_uid
  ) order by q.uploaded_at desc),'[]'::jsonb) into v_feed
  from (
    select d.id,d.user_id,d.object_path,d.file_name,d.file_size_bytes,d.uploaded_at,
      public.cf_lobby_user_json(d.user_id) as player
    from public.cf_player_demos d where d.status='ready'
    order by d.uploaded_at desc limit 100
  ) q;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',d.id,'file_name',d.file_name,'file_size_bytes',d.file_size_bytes,'created_at',d.created_at
  ) order by d.created_at desc),'[]'::jsonb) into v_pending
  from (select id,file_name,file_size_bytes,created_at from public.cf_player_demos
        where user_id=v_uid and status='uploading' order by created_at desc limit 10) d;
  return jsonb_build_object('demos',coalesce(v_feed,'[]'::jsonb),'pending',coalesce(v_pending,'[]'::jsonb),'next_upload_at',v_next);
end;
$function$;
revoke all on function public.cf_demo_state() from public,anon;
grant execute on function public.cf_demo_state() to authenticated;

create or replace function public.cf_demo_delete(p_demo_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,auth,storage
as $function$
declare
  v_uid uuid:=auth.uid();
  v_path text;
begin
  if v_uid is null then raise exception 'Нужно войти в онлайн-аккаунт'; end if;
  select object_path into v_path from public.cf_player_demos
   where id=p_demo_id and user_id=v_uid for update;
  if v_path is null then raise exception 'Демка не найдена'; end if;
  if exists(select 1 from storage.objects where bucket_id='cf-player-demos' and name=v_path) then
    raise exception 'Сначала удали файл демки из хранилища';
  end if;
  delete from public.cf_player_demos where id=p_demo_id and user_id=v_uid;
  return jsonb_build_object('ok',true,'id',p_demo_id);
end;
$function$;
revoke all on function public.cf_demo_delete(uuid) from public,anon;
grant execute on function public.cf_demo_delete(uuid) to authenticated;

-- Shared chat previously discarded custom avatars longer than 64 characters.
-- Keep access checks intact and use the same bounded avatar validation as the lobby helper.
create or replace function public.cf_chat_state(p_scope text,p_lobby_id uuid default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth as $function$
declare v_uid uuid:=auth.uid(); v_my_lobby uuid; v_msgs jsonb; v_now timestamptz:=clock_timestamp();
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  if p_scope not in ('global','lobby') then raise exception 'Неизвестный чат'; end if;
  if p_scope='lobby' then
    select lobby_id into v_my_lobby from public.lobby_members where user_id=v_uid;
    if p_lobby_id is null or v_my_lobby is null or p_lobby_id<>v_my_lobby then
      raise exception 'Чат доступен только участникам текущего лобби';
    end if;
  end if;
  select coalesce(jsonb_agg(msg order by created_at),'[]'::jsonb) into v_msgs
  from (
    select jsonb_build_object(
      'id',c.id,'channel',c.channel,'lobby_id',c.lobby_id,'user_id',c.user_id,
      'body',c.body,'created_at',c.created_at,
      'nickname',coalesce(p.nickname,'player'),
      'display_name',coalesce(nullif(p.display_name,''),p.nickname,'Игрок'),
      'avatar',case
        when char_length(coalesce(p.avatar,''))<=1000 and p.avatar ~* '^https://[^[:space:]]+$' then p.avatar
        when char_length(coalesce(p.avatar,''))<=40000 and p.avatar ~ '^data:image/(png|jpeg|webp|gif);base64,' then p.avatar
        when p.avatar in ('ember','steel','azure','moss','plum','sand') then p.avatar
        else 'ember' end,
      'role',coalesce(p.role,'player'),'verified',coalesce(p.verified,false),
      'sponsor_badge',coalesce(p.sponsor_badge,false),
      'sponsor_nickname_style',coalesce(p.sponsor_nickname_style,'default')
    ) as msg,c.created_at
    from public.cf_chat_messages c join public.profiles p on p.id=c.user_id
    where (p_scope='global' and c.channel='global')
       or (p_scope='lobby' and c.channel='lobby' and c.lobby_id=p_lobby_id)
    order by c.created_at desc limit 80
  ) q;
  return jsonb_build_object('messages',v_msgs,'server_now',v_now);
end;
$function$;
revoke all on function public.cf_chat_state(text,uuid) from public,anon;
grant execute on function public.cf_chat_state(text,uuid) to authenticated;

commit;

select 'CF FACEIT v50 demo gallery and hourly server-side upload limit installed' as result;
