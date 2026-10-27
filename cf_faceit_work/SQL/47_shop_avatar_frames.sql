-- CF FACEIT v55: admin-issued profile frame inventory and public rendering.
-- Run in Supabase SQL Editor after SQL/42_sponsor_badge_and_profile_customization.sql.

begin;

alter table public.profiles
  add column if not exists avatar_frame text not null default '';

alter table public.profiles drop constraint if exists profiles_avatar_frame_allowed;
alter table public.profiles add constraint profiles_avatar_frame_allowed
  check (avatar_frame in ('','violet','collab','arctic','crimson','iris'));

create table if not exists public.cf_player_avatar_frames (
  user_id uuid not null references public.profiles(id) on delete cascade,
  frame_id text not null check (frame_id in ('violet','collab','arctic','crimson','iris')),
  granted_by uuid references public.profiles(id) on delete set null,
  granted_at timestamptz not null default clock_timestamp(),
  primary key (user_id,frame_id)
);
alter table public.cf_player_avatar_frames enable row level security;
revoke all on public.cf_player_avatar_frames from public,anon,authenticated;

-- A player may equip only a frame present in their admin-issued inventory.
create or replace function public.cf_guard_profile_avatar_frame()
returns trigger
language plpgsql
security definer
set search_path=pg_catalog,public
as $function$
begin
  if new.avatar_frame is distinct from old.avatar_frame
     and new.avatar_frame<>''
     and not exists(select 1 from public.cf_player_avatar_frames f where f.user_id=new.id and f.frame_id=new.avatar_frame) then
    raise exception 'Эта рамка не выдана аккаунту';
  end if;
  return new;
end;
$function$;
drop trigger if exists cf_profile_avatar_frame_guard on public.profiles;
create trigger cf_profile_avatar_frame_guard
  before update of avatar_frame on public.profiles
  for each row execute function public.cf_guard_profile_avatar_frame();

create or replace function public.cf_admin_manage_avatar_frame(
  p_target text,
  p_frame text,
  p_grant boolean default true
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
  v_current text;
  v_next text;
  v_do_grant boolean:=coalesce(p_grant,true);
begin
  if v_actor is null then raise exception 'Нужно войти в аккаунт'; end if;
  if nullif(trim(p_target),'') is null then raise exception 'Укажи ник, e-mail, игровой ID или UUID'; end if;
  if p_frame is null or p_frame not in ('violet','collab','arctic','crimson','iris') then raise exception 'Неизвестная рамка'; end if;
  select role into v_actor_role from public.profiles where id=v_actor;
  if coalesce(v_actor_role,'player') not in ('founder','admin') then raise exception 'Недостаточно прав'; end if;

  if trim(p_target) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select id,role,nickname,avatar_frame into v_target,v_target_role,v_nickname,v_current
      from public.profiles where id=trim(p_target)::uuid;
  elsif position('@' in p_target)>0 then
    select p.id,p.role,p.nickname,p.avatar_frame into v_target,v_target_role,v_nickname,v_current
      from auth.users u join public.profiles p on p.id=u.id
     where lower(u.email)=lower(trim(p_target)) limit 1;
  elsif trim(p_target) ~ '^[0-9]{6,7}$' then
    select id,role,nickname,avatar_frame into v_target,v_target_role,v_nickname,v_current
      from public.profiles where game_id=trim(p_target) limit 1;
  else
    select id,role,nickname,avatar_frame into v_target,v_target_role,v_nickname,v_current
      from public.profiles where lower(nickname)=lower(trim(p_target)) limit 1;
  end if;
  if v_target is null then raise exception 'Игрок не найден. Проверь ник, e-mail, ID или UUID'; end if;
  if v_actor_role='admin' and (v_target_role in ('admin','founder') or v_target=v_actor) then
    raise exception 'Администратор может выдавать рамки только игрокам';
  end if;

  if v_do_grant then
    insert into public.cf_player_avatar_frames(user_id,frame_id,granted_by,granted_at)
    values(v_target,p_frame,v_actor,clock_timestamp())
    on conflict(user_id,frame_id) do update set granted_by=excluded.granted_by,granted_at=excluded.granted_at;
    update public.profiles set avatar_frame=p_frame where id=v_target;
    v_next:=p_frame;
  else
    delete from public.cf_player_avatar_frames where user_id=v_target and frame_id=p_frame;
    select frame_id into v_next from public.cf_player_avatar_frames
     where user_id=v_target order by granted_at desc,frame_id limit 1;
    v_next:=coalesce(v_next,'');
    update public.profiles set avatar_frame=v_next where id=v_target;
  end if;

  return jsonb_build_object('ok',true,'user_id',v_target,'nickname',v_nickname,
    'avatar_frame',v_next,'granted',v_do_grant,'frame_removed',not v_do_grant and v_current=p_frame);
end;
$function$;
revoke all on function public.cf_admin_manage_avatar_frame(text,text,boolean) from public,anon;
grant execute on function public.cf_admin_manage_avatar_frame(text,text,boolean) to authenticated;

-- Include the active frame in all server-generated shared player profiles.
create or replace function public.cf_lobby_user_json(p_uid uuid)
returns jsonb
language sql stable security definer set search_path=pg_catalog,public as $$
  select jsonb_build_object(
    'id',p.id,'nickname',p.nickname,
    'display_name',coalesce(nullif(p.display_name,''),p.nickname),
    'avatar',case
      when char_length(coalesce(p.avatar,''))<=1000 and p.avatar ~* '^https://[^[:space:]]+$' then p.avatar
      when char_length(coalesce(p.avatar,''))<=40000 and p.avatar ~ '^data:image/(png|jpeg|webp|gif);base64,' then p.avatar
      when p.avatar in ('ember','steel','azure','moss','plum','sand') then p.avatar
      else 'ember' end,
    'avatar_frame',coalesce(p.avatar_frame,''),
    'elo',coalesce(p.elo,800),'verified',coalesce(p.verified,false),'role',coalesce(p.role,'player'),
    'sponsor_badge',coalesce(p.sponsor_badge,false),'sponsor_nickname_style',coalesce(p.sponsor_nickname_style,'default')
  ) from public.profiles p where p.id=p_uid
$$;

create or replace function public.cf_chat_state(p_scope text,p_lobby_id uuid default null)
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
      'avatar_frame',coalesce(p.avatar_frame,''),
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

create or replace function public.cf_leaderboard(p_limit int default 100)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if auth.uid() is null then raise exception 'Нужно войти в аккаунт'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'rank',q.rk,'nickname',q.nickname,'display_name',q.display_name,'avatar',q.avatar,
      'avatar_frame',q.avatar_frame,'elo',q.elo,'wins',q.wins,'losses',q.losses,
      'verified',q.verified,'role',q.role,'sponsor_badge',q.sponsor_badge,
      'sponsor_nickname_style',q.sponsor_nickname_style
    ) order by q.rk)
    from (
      select row_number() over (order by coalesce(p.elo,1000) desc,coalesce(p.wins,0) desc,p.created_at asc) as rk,
        p.nickname,p.display_name,p.avatar,coalesce(p.avatar_frame,'') as avatar_frame,coalesce(p.elo,1000) as elo,
        coalesce(p.wins,0) as wins,coalesce(p.losses,0) as losses,p.verified,p.role,
        coalesce(p.sponsor_badge,false) as sponsor_badge,
        coalesce(p.sponsor_nickname_style,'default') as sponsor_nickname_style
      from public.profiles p order by rk limit greatest(1,least(coalesce(p_limit,100),200))
    ) q
  ),'[]'::jsonb);
end;
$$;
revoke all on function public.cf_leaderboard(int) from public,anon;
grant execute on function public.cf_leaderboard(int) to authenticated;

commit;

select 'CF FACEIT v55 avatar frame grants installed' as result;
