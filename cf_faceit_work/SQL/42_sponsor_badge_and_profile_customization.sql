-- CF FACEIT v49: sponsor badge, profile nickname styles and personal site wallpaper.
-- Run in Supabase SQL Editor AFTER SQL/41_player_host_and_moderation.sql.
-- A sponsor badge is admin-issued; profile perks are guarded by a server-side RPC.

begin;

alter table public.profiles
  add column if not exists sponsor_badge boolean not null default false,
  add column if not exists sponsor_site_background text not null default '',
  add column if not exists sponsor_nickname_style text not null default 'default';

alter table public.profiles drop constraint if exists profiles_sponsor_nickname_style_allowed;
alter table public.profiles add constraint profiles_sponsor_nickname_style_allowed
  check (sponsor_nickname_style in ('default','blue','gradient','rainbow'));
alter table public.profiles drop constraint if exists profiles_sponsor_background_url_check;
alter table public.profiles add constraint profiles_sponsor_background_url_check
  check (
    sponsor_site_background = ''
    or (
      char_length(sponsor_site_background) <= 1900
      and sponsor_site_background ~ '^https://[^[:space:]]+/storage/v1/object/public/cf-sponsor-backgrounds/[0-9a-f-]{36}/[A-Za-z0-9._/-]+$'
    )
  );

-- Personal wallpapers are public to render on public profiles, but each authenticated
-- account can upload/delete only objects in its own UUID folder.
insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values ('cf-sponsor-backgrounds','cf-sponsor-backgrounds',true,8388608,
        array['image/jpeg','image/png','image/webp','image/gif'])
on conflict (id) do update set public=true,file_size_limit=excluded.file_size_limit,
  allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists cf_sponsor_backgrounds_insert on storage.objects;
create policy cf_sponsor_backgrounds_insert on storage.objects for insert to authenticated
with check (bucket_id='cf-sponsor-backgrounds' and (storage.foldername(name))[1]=auth.uid()::text);
drop policy if exists cf_sponsor_backgrounds_delete on storage.objects;
create policy cf_sponsor_backgrounds_delete on storage.objects for delete to authenticated
using (bucket_id='cf-sponsor-backgrounds' and (storage.foldername(name))[1]=auth.uid()::text);

-- Do not grant direct UPDATE on sponsor_badge or the perk fields. Only this
-- authenticated RPC can set profile perks, and only for accounts already granted
-- the sponsor badge by an administrator.
create or replace function public.cf_update_sponsor_profile(
  p_background text default '',
  p_nickname_style text default 'default'
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,auth,storage
as $function$
declare
  v_uid uuid:=auth.uid();
  v_path text;
  v_style text:=coalesce(p_nickname_style,'default');
  v_background text:=coalesce(p_background,'');
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  if not exists(select 1 from public.profiles where id=v_uid and sponsor_badge=true) then
    raise exception 'Настройки доступны только владельцу значка спонсора';
  end if;
  if v_style not in ('default','blue','gradient','rainbow') then
    raise exception 'Недопустимый цвет ника';
  end if;
  if v_background<>'' then
    if char_length(v_background)>1900 or v_background !~ ('^https://[^[:space:]]+/storage/v1/object/public/cf-sponsor-backgrounds/'||v_uid::text||'/[A-Za-z0-9._/-]+$') then
      raise exception 'Недопустимая ссылка на фон';
    end if;
    v_path:=substring(v_background from ('/storage/v1/object/public/cf-sponsor-backgrounds/'||v_uid::text||'/([A-Za-z0-9._/-]+)$'));
    if v_path is null or v_path ~ '(^|/)\.\.(/|$)' then raise exception 'Недопустимый путь к фону'; end if;
    if not exists(select 1 from storage.objects where bucket_id='cf-sponsor-backgrounds' and name=v_uid::text||'/'||v_path) then
      raise exception 'Файл фона не найден в личной галерее';
    end if;
  end if;
  update public.profiles
     set sponsor_site_background=v_background,
         sponsor_nickname_style=v_style
   where id=v_uid;
  return jsonb_build_object('ok',true,'sponsor_background',v_background,'sponsor_nickname_style',v_style);
end;
$function$;
revoke all on function public.cf_update_sponsor_profile(text,text) from public,anon;
grant execute on function public.cf_update_sponsor_profile(text,text) to authenticated;

-- Replace the staff RPC with an additional explicit sponsor grant/revoke control.
drop function if exists public.cf_manage_staff_lookup(text,text,boolean);
create function public.cf_manage_staff_lookup(
  p_target text,
  p_role text,
  p_verified boolean default null,
  p_sponsor boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,auth
as $function$
declare
  v_actor uuid:=auth.uid();
  v_actor_role text;
  v_target uuid;
  v_target_role text;
  v_nickname text;
  v_target_sponsor boolean;
  v_target_verified boolean;
begin
  if v_actor is null then raise exception 'Нужно войти в аккаунт'; end if;
  if nullif(trim(p_target),'') is null then raise exception 'Укажи ник, почту, игровой ID или UUID'; end if;
  if p_role is null or p_role not in ('player','tester','cooperation','admin') then
    raise exception 'Недопустимая роль';
  end if;
  select role into v_actor_role from public.profiles where id=v_actor;
  if coalesce(v_actor_role,'player') not in ('founder','admin') then raise exception 'Недостаточно прав'; end if;

  if trim(p_target) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select id,role,nickname,sponsor_badge,verified into v_target,v_target_role,v_nickname,v_target_sponsor,v_target_verified
      from public.profiles where id=trim(p_target)::uuid;
  elsif position('@' in p_target)>0 then
    select p.id,p.role,p.nickname,p.sponsor_badge,p.verified into v_target,v_target_role,v_nickname,v_target_sponsor,v_target_verified
      from auth.users u join public.profiles p on p.id=u.id
     where lower(u.email)=lower(trim(p_target)) limit 1;
  elsif trim(p_target) ~ '^[0-9]{6,7}$' then
    select id,role,nickname,sponsor_badge,verified into v_target,v_target_role,v_nickname,v_target_sponsor,v_target_verified
      from public.profiles where game_id=trim(p_target) limit 1;
  else
    select id,role,nickname,sponsor_badge,verified into v_target,v_target_role,v_nickname,v_target_sponsor,v_target_verified
      from public.profiles where lower(nickname)=lower(trim(p_target)) limit 1;
  end if;

  if v_target is null then raise exception 'Игрок не найден. Проверь ник, почту, ID или UUID'; end if;
  if v_target_role='founder' then raise exception 'Нельзя изменить права основателя'; end if;
  if v_actor_role='admin' then
    if p_role='admin' then raise exception 'Только основатель может выдавать админку'; end if;
    if v_target_role='admin' then raise exception 'Администратор не может менять права другого администратора'; end if;
    if v_target=v_actor then raise exception 'Нельзя изменять собственные права'; end if;
  end if;

  update public.profiles
     set role=p_role,verified=coalesce(p_verified,v_target_verified),sponsor_badge=coalesce(p_sponsor,v_target_sponsor)
   where id=v_target;
  return jsonb_build_object('ok',true,'user_id',v_target,'nickname',v_nickname,
    'role',p_role,'verified',coalesce(p_verified,v_target_verified),'sponsor_badge',coalesce(p_sponsor,v_target_sponsor));
end;
$function$;
revoke all on function public.cf_manage_staff_lookup(text,text,boolean,boolean) from public,anon;
grant execute on function public.cf_manage_staff_lookup(text,text,boolean,boolean) to authenticated;

-- Expose the sponsor marker and selected nickname effect in shared lobby/friend data.
create or replace function public.cf_lobby_user_json(p_uid uuid)
returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
  select jsonb_build_object(
    'id',p.id,'nickname',p.nickname,
    'display_name',coalesce(nullif(p.display_name,''),p.nickname),
    'avatar',case
      when char_length(coalesce(p.avatar,''))<=1000 and p.avatar ~* '^https://[^[:space:]]+$' then p.avatar
      when char_length(coalesce(p.avatar,''))<=40000 and p.avatar ~ '^data:image/(png|jpeg|webp|gif);base64,' then p.avatar
      when p.avatar in ('ember','steel','azure','moss','plum','sand') then p.avatar
      else 'ember' end,
    'elo',coalesce(p.elo,800),'verified',coalesce(p.verified,false),'role',coalesce(p.role,'player'),
    'sponsor_badge',coalesce(p.sponsor_badge,false),'sponsor_nickname_style',coalesce(p.sponsor_nickname_style,'default')
  ) from public.profiles p where p.id=p_uid
$$;

-- Chat messages are another public name surface. Keep all prior access checks and
-- include the badge/style fields so the UI can render them consistently.
create or replace function public.cf_chat_state(p_scope text, p_lobby_id uuid default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_uid uuid:=auth.uid(); v_my_lobby uuid; v_msgs jsonb; v_now timestamptz:=clock_timestamp();
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  if p_scope not in ('global','lobby') then raise exception 'Неизвестный чат'; end if;
  if p_scope='lobby' then
    select lobby_id into v_my_lobby from public.lobby_members where user_id=v_uid;
    if p_lobby_id is null or v_my_lobby is null or p_lobby_id<>v_my_lobby then raise exception 'Чат доступен только участникам текущего лобби'; end if;
  end if;
  select coalesce(jsonb_agg(msg order by created_at),'[]'::jsonb) into v_msgs
  from (
    select jsonb_build_object(
      'id',c.id,'channel',c.channel,'lobby_id',c.lobby_id,'user_id',c.user_id,
      'body',c.body,'created_at',c.created_at,
      'nickname',coalesce(p.nickname,'player'),
      'display_name',coalesce(nullif(p.display_name,''),p.nickname,'Игрок'),
      'avatar',case when coalesce(char_length(p.avatar),0)<=64 then coalesce(p.avatar,'ember') else 'ember' end,
      'role',coalesce(p.role,'player'),'verified',coalesce(p.verified,false),
      'sponsor_badge',coalesce(p.sponsor_badge,false),'sponsor_nickname_style',coalesce(p.sponsor_nickname_style,'default')
    ) as msg,c.created_at
    from public.cf_chat_messages c join public.profiles p on p.id=c.user_id
    where (p_scope='global' and c.channel='global')
       or (p_scope='lobby' and c.channel='lobby' and c.lobby_id=p_lobby_id)
    order by c.created_at desc limit 80
  ) q;
  return jsonb_build_object('messages',v_msgs,'server_now',v_now);
end;
$$;
revoke all on function public.cf_chat_state(text,uuid) from public,anon;
grant execute on function public.cf_chat_state(text,uuid) to authenticated;

-- The leaderboard is also a shared profile surface and must carry the same badge.
create or replace function public.cf_leaderboard(p_limit int default 100)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if auth.uid() is null then raise exception 'Нужно войти в аккаунт'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'rank',q.rk,'nickname',q.nickname,'display_name',q.display_name,'avatar',q.avatar,
      'elo',q.elo,'wins',q.wins,'losses',q.losses,'verified',q.verified,'role',q.role,
      'sponsor_badge',q.sponsor_badge,'sponsor_nickname_style',q.sponsor_nickname_style
    ) order by q.rk)
    from (
      select row_number() over (order by coalesce(p.elo,1000) desc,coalesce(p.wins,0) desc,p.created_at asc) as rk,
        p.nickname,p.display_name,p.avatar,coalesce(p.elo,1000) as elo,
        coalesce(p.wins,0) as wins,coalesce(p.losses,0) as losses,p.verified,p.role,
        coalesce(p.sponsor_badge,false) as sponsor_badge,coalesce(p.sponsor_nickname_style,'default') as sponsor_nickname_style
      from public.profiles p order by rk limit greatest(1,least(coalesce(p_limit,100),200))
    ) q
  ),'[]'::jsonb);
end;
$$;
revoke all on function public.cf_leaderboard(int) from public,anon;
grant execute on function public.cf_leaderboard(int) to authenticated;

commit;

select 'CF FACEIT v49 sponsor badge and profile customization installed' as result;
