-- CF FACEIT v8 migration: staff roles, shared lobby matches/timer, lobby chat and global chat.
-- Run after SETUP_ALL_ONLINE.sql and SETUP_LOBBY.sql in Supabase SQL Editor.
-- Safe to rerun. Never put the Supabase service_role key in the website.

create extension if not exists pgcrypto;

-- 1) Allow tester role (the old schema allowed only player/admin/founder).
do $$
declare c record;
begin
  for c in
    select conname from pg_constraint
    where conrelid = 'public.profiles'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%role%'
  loop
    execute format('alter table public.profiles drop constraint %I', c.conname);
  end loop;
  alter table public.profiles
    add constraint profiles_role_allowed
    check (role in ('player','tester','admin','founder'));
end $$;

-- Privileged bootstrap must target a verified auth.users UUID; never assign founder by nickname.
-- Use the explicit UUID-only owner setup template after independent identity verification.

-- 2) Reliable server-side staff management: supports email, 6-digit game ID,
--    UUID and nickname. Role/verification changes bypass browser column grants safely.
create or replace function public.cf_manage_staff_lookup(
  p_target text,
  p_role text,
  p_verified boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_actor uuid := auth.uid();
  v_actor_role text;
  v_target uuid;
  v_target_role text;
  v_nickname text;
begin
  if v_actor is null then raise exception 'Нужно войти в аккаунт'; end if;
  if nullif(trim(p_target), '') is null then raise exception 'Укажи ник, почту, игровой ID или UUID'; end if;
  if p_role is null or p_role not in ('player','tester','admin') then raise exception 'Недопустимая роль'; end if;

  select p.role into v_actor_role from public.profiles p where p.id = v_actor;
  if coalesce(v_actor_role, 'player') not in ('founder','admin') then
    raise exception 'Недостаточно прав';
  end if;

  if trim(p_target) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select p.id, p.role, p.nickname into v_target, v_target_role, v_nickname
    from public.profiles p where p.id = trim(p_target)::uuid;
  elsif position('@' in p_target) > 0 then
    select p.id, p.role, p.nickname into v_target, v_target_role, v_nickname
    from auth.users u join public.profiles p on p.id = u.id
    where lower(u.email) = lower(trim(p_target)) limit 1;
  elsif trim(p_target) ~ '^[0-9]{6}$' then
    select p.id, p.role, p.nickname into v_target, v_target_role, v_nickname
    from public.profiles p where p.game_id = trim(p_target) limit 1;
  else
    select p.id, p.role, p.nickname into v_target, v_target_role, v_nickname
    from public.profiles p where lower(p.nickname) = lower(trim(p_target)) limit 1;
  end if;

  if v_target is null then raise exception 'Игрок не найден. Проверь ник, почту или ID'; end if;
  if v_target_role = 'founder' then raise exception 'Нельзя изменить роль основателя'; end if;
  if v_actor_role = 'admin' then
    if p_role = 'admin' then raise exception 'Только основатель может выдавать админку'; end if;
    if v_target_role = 'admin' then raise exception 'Администратор не может менять права другого администратора'; end if;
    if v_target = v_actor then raise exception 'Нельзя изменять собственные права'; end if;
  end if;

  update public.profiles
     set role = p_role, verified = coalesce(p_verified, false)
   where id = v_target;

  return jsonb_build_object('ok', true, 'user_id', v_target,
    'nickname', v_nickname, 'role', p_role, 'verified', coalesce(p_verified,false));
end;
$$;
revoke all on function public.cf_manage_staff_lookup(text,text,boolean) from public, anon;
grant execute on function public.cf_manage_staff_lookup(text,text,boolean) to authenticated;

-- 3) Shared match state attached to a server-side lobby. Timestamps are stored
--    once in PostgreSQL, so all devices calculate the same countdown.
create table if not exists public.cf_lobby_matches (
  id uuid primary key default gen_random_uuid(),
  lobby_id uuid not null references public.lobbies(id) on delete cascade,
  started_by uuid not null references auth.users(id) on delete cascade,
  participant_ids uuid[] not null default '{}',
  mode text not null default 'ranked' check (mode in ('ranked','duo')),
  map_name text not null check (map_name in ('Mirage','Dust2','Vertigo','Inferno')),
  status text not null default 'searching'
    check (status in ('searching','found','pending_admin','taken','room','joined','live','done','cancelled')),
  started_at timestamptz not null default clock_timestamp(),
  found_at timestamptz,
  expires_at timestamptz,
  accepted_by uuid[] not null default '{}',
  admin_id uuid references auth.users(id) on delete set null,
  admin_nickname text not null default '',
  room_code text not null default '',
  cancel_reason text not null default '',
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp()
);

create index if not exists cf_lobby_matches_lobby_created_idx
  on public.cf_lobby_matches(lobby_id, created_at desc);
create unique index if not exists cf_lobby_matches_one_active_per_lobby
  on public.cf_lobby_matches(lobby_id)
  where status not in ('done','cancelled');
alter table public.cf_lobby_matches enable row level security;
revoke all on public.cf_lobby_matches from anon, authenticated;

-- Cancel an active shared match if a participant leaves or is kicked from the lobby.
create or replace function public.cf_cancel_lobby_match_on_member_leave()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.cf_lobby_matches
     set status = 'cancelled', cancel_reason = 'Игрок вышел из лобби', updated_at = clock_timestamp()
   where lobby_id = old.lobby_id
     and old.user_id = any(participant_ids)
     and status not in ('done','cancelled');
  return old;
end;
$$;
drop trigger if exists cf_cancel_lobby_match_member_leave on public.lobby_members;
create trigger cf_cancel_lobby_match_member_leave
after delete on public.lobby_members
for each row execute function public.cf_cancel_lobby_match_on_member_leave();

create or replace function public.cf_lobby_match_state()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_lobby uuid;
  v_now timestamptz := clock_timestamp();
  v_match public.cf_lobby_matches%rowtype;
  v_players jsonb := '[]'::jsonb;
  v_accepted integer := 0;
  v_total integer := 0;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select lm.lobby_id into v_lobby from public.lobby_members lm where lm.user_id = v_uid;
  if v_lobby is null then
    return jsonb_build_object('lobby_id', null, 'match', null, 'server_now', v_now);
  end if;

  select * into v_match from public.cf_lobby_matches m
   where m.lobby_id = v_lobby
   order by m.created_at desc limit 1 for update;

  if not found then
    return jsonb_build_object('lobby_id', v_lobby, 'match', null, 'server_now', v_now);
  end if;

  if v_match.status = 'searching' and v_match.started_at <= v_now - interval '8 seconds' then
    update public.cf_lobby_matches
       set status = 'found', found_at = v_now,
           expires_at = v_now + interval '15 seconds', updated_at = v_now
     where id = v_match.id returning * into v_match;
  elsif v_match.status = 'found' and v_match.expires_at <= v_now then
    update public.cf_lobby_matches
       set status = 'cancelled', cancel_reason = 'Время принятия матча истекло', updated_at = v_now
     where id = v_match.id returning * into v_match;
  end if;

  if v_match.status = 'found' then
    select count(*) into v_accepted from unnest(v_match.participant_ids) as x(uid)
      where x.uid = any(v_match.accepted_by);
    v_total := cardinality(v_match.participant_ids);
    if v_total > 0 and v_accepted >= v_total then
      update public.cf_lobby_matches set status = 'pending_admin', updated_at = v_now
       where id = v_match.id returning * into v_match;
    end if;
  end if;

  select coalesce(jsonb_agg(public.cf_lobby_user_json(x.uid) order by p.nickname), '[]'::jsonb)
    into v_players
    from unnest(v_match.participant_ids) as x(uid)
    join public.profiles p on p.id = x.uid;
  select count(*) into v_accepted from unnest(v_match.participant_ids) as x(uid)
    where x.uid = any(v_match.accepted_by);

  return jsonb_build_object(
    'lobby_id', v_lobby,
    'server_now', v_now,
    'match', jsonb_build_object(
      'id', v_match.id, 'lobby_id', v_match.lobby_id,
      'started_by', v_match.started_by, 'mode', v_match.mode,
      'map_name', v_match.map_name, 'status', v_match.status,
      'started_at', v_match.started_at, 'found_at', v_match.found_at,
      'expires_at', v_match.expires_at, 'accepted_by', to_jsonb(v_match.accepted_by),
      'accepted_count', v_accepted, 'total_count', cardinality(v_match.participant_ids),
      'players', v_players, 'admin_nickname', v_match.admin_nickname,
      'room_code', v_match.room_code, 'cancel_reason', v_match.cancel_reason
    )
  );
end;
$$;

create or replace function public.cf_lobby_match_start(p_mode text, p_map text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_lobby uuid; v_count integer; v_ids uuid[]; v_active uuid;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  if p_mode not in ('ranked','duo') then raise exception 'Недопустимый режим'; end if;
  if p_map not in ('Mirage','Dust2','Vertigo','Inferno') then raise exception 'Недопустимая карта'; end if;
  select lm.lobby_id into v_lobby from public.lobby_members lm where lm.user_id = v_uid;
  if v_lobby is null then raise exception 'Сначала собери лобби'; end if;
  perform pg_advisory_xact_lock(hashtext('cf:lobby-match:' || v_lobby::text));
  update public.cf_lobby_matches set status = 'cancelled', cancel_reason = 'Время принятия матча истекло', updated_at = clock_timestamp()
   where lobby_id = v_lobby and status = 'found' and expires_at <= clock_timestamp();
  update public.cf_lobby_matches set status = 'found', found_at = clock_timestamp(),
      expires_at = clock_timestamp() + interval '15 seconds', updated_at = clock_timestamp()
   where lobby_id = v_lobby and status = 'searching'
     and started_at <= clock_timestamp() - interval '8 seconds';
  select id into v_active from public.cf_lobby_matches
   where lobby_id = v_lobby and status not in ('done','cancelled') order by created_at desc limit 1;
  if v_active is not null then return public.cf_lobby_match_state(); end if;
  select array_agg(user_id order by joined_at), count(*) into v_ids, v_count
    from public.lobby_members where lobby_id = v_lobby;
  if coalesce(v_count,0) < 2 then raise exception 'Для общего матча нужно минимум 2 игрока в лобби'; end if;
  insert into public.cf_lobby_matches(lobby_id, started_by, participant_ids, mode, map_name, status)
  values (v_lobby, v_uid, v_ids, p_mode, p_map, 'searching');
  return public.cf_lobby_match_state();
end;
$$;

create or replace function public.cf_lobby_match_respond(p_accept boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_lobby uuid; v_match public.cf_lobby_matches%rowtype;
  v_accepted integer; v_total integer; v_now timestamptz := clock_timestamp();
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select lm.lobby_id into v_lobby from public.lobby_members lm where lm.user_id = v_uid;
  if v_lobby is null then raise exception 'Ты больше не в лобби'; end if;
  select * into v_match from public.cf_lobby_matches
   where lobby_id = v_lobby and status = 'found' order by created_at desc limit 1 for update;
  if not found then raise exception 'Найденный матч уже недоступен'; end if;
  if not (v_uid = any(v_match.participant_ids)) then raise exception 'Ты не входишь в этот матч'; end if;
  if v_match.expires_at <= v_now then
    update public.cf_lobby_matches set status='cancelled',cancel_reason='Время принятия матча истекло',updated_at=v_now where id=v_match.id;
    return public.cf_lobby_match_state();
  end if;
  if not p_accept then
    update public.cf_lobby_matches set status='cancelled',cancel_reason='Один из игроков отклонил матч',updated_at=v_now where id=v_match.id;
    return public.cf_lobby_match_state();
  end if;
  update public.cf_lobby_matches
    set accepted_by = case when v_uid = any(accepted_by) then accepted_by else array_append(accepted_by,v_uid) end,
        updated_at = v_now
    where id = v_match.id returning * into v_match;
  select count(*) into v_accepted from unnest(v_match.participant_ids) as x(uid) where x.uid = any(v_match.accepted_by);
  v_total := cardinality(v_match.participant_ids);
  if v_total > 0 and v_accepted >= v_total then
    update public.cf_lobby_matches set status='pending_admin',updated_at=v_now where id=v_match.id;
  end if;
  return public.cf_lobby_match_state();
end;
$$;

create or replace function public.cf_lobby_match_cancel()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_lobby uuid;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select lobby_id into v_lobby from public.lobby_members where user_id=v_uid;
  if v_lobby is null then raise exception 'Ты не в лобби'; end if;
  update public.cf_lobby_matches set status='cancelled',cancel_reason='Матч отменён игроком',updated_at=clock_timestamp()
   where lobby_id=v_lobby and status not in ('done','cancelled') and v_uid=any(participant_ids);
  return public.cf_lobby_match_state();
end;
$$;

-- 4) Online admin panel for lobby matches. Only current admins/founder can see/change them.
create or replace function public.cf_lobby_match_admin_list()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_role text; v_result jsonb;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select role into v_role from public.profiles where id=v_uid;
  if coalesce(v_role,'player') not in ('admin','founder') then raise exception 'Недостаточно прав'; end if;
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id',m.id,'lobby_id',m.lobby_id,'mode',m.mode,'map_name',m.map_name,
      'status',m.status,'started_at',m.started_at,'found_at',m.found_at,
      'created_at',m.created_at,'admin_nickname',m.admin_nickname,
      'room_code',m.room_code,'cancel_reason',m.cancel_reason,
      'players',(select coalesce(jsonb_agg(public.cf_lobby_user_json(x.uid) order by p.nickname),'[]'::jsonb)
        from unnest(m.participant_ids) as x(uid) join public.profiles p on p.id=x.uid)
    ) order by m.created_at desc), '[]'::jsonb)
  into v_result from public.cf_lobby_matches m
  where m.status not in ('done','cancelled') or m.created_at > clock_timestamp() - interval '10 minutes';
  return v_result;
end;
$$;

create or replace function public.cf_lobby_match_admin_action(p_match uuid, p_action text, p_code text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_role text; v_match public.cf_lobby_matches%rowtype; v_nick text;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select role,nickname into v_role,v_nick from public.profiles where id=v_uid;
  if coalesce(v_role,'player') not in ('admin','founder') then raise exception 'Недостаточно прав'; end if;
  select * into v_match from public.cf_lobby_matches where id=p_match for update;
  if not found then raise exception 'Матч не найден'; end if;

  if p_action='take' then
    if v_match.status <> 'pending_admin' then raise exception 'Этот матч уже недоступен для принятия'; end if;
    update public.cf_lobby_matches set status='taken',admin_id=v_uid,admin_nickname=v_nick,updated_at=clock_timestamp()
     where id=p_match and status='pending_admin' and admin_id is null;
    if not found then raise exception 'Уже выполняется другим администратором'; end if;
  elsif p_action='publish' then
    if v_match.admin_id <> v_uid then raise exception 'Уже выполняется другим администратором'; end if;
    if v_match.status <> 'taken' then raise exception 'Сначала возьми матч'; end if;
    if nullif(trim(p_code),'') is null or char_length(trim(p_code))>64 then raise exception 'Введи код комнаты до 64 символов'; end if;
    update public.cf_lobby_matches set status='room',room_code=trim(p_code),updated_at=clock_timestamp() where id=p_match;
  elsif p_action='joined' then
    if v_match.admin_id <> v_uid then raise exception 'Уже выполняется другим администратором'; end if;
    if v_match.status <> 'room' then raise exception 'Сначала опубликуй код комнаты'; end if;
    update public.cf_lobby_matches set status='joined',updated_at=clock_timestamp() where id=p_match;
  elsif p_action='live' then
    if v_match.admin_id <> v_uid then raise exception 'Уже выполняется другим администратором'; end if;
    if v_match.status <> 'joined' then raise exception 'Сначала подтверди вход игроков'; end if;
    update public.cf_lobby_matches set status='live',updated_at=clock_timestamp() where id=p_match;
  elsif p_action='cancel' then
    if v_match.admin_id is not null and v_match.admin_id <> v_uid then raise exception 'Уже выполняется другим администратором'; end if;
    if v_match.status in ('done','cancelled') then raise exception 'Матч уже завершён'; end if;
    update public.cf_lobby_matches set status='cancelled',cancel_reason='Отменено администратором',updated_at=clock_timestamp() where id=p_match;
  else
    raise exception 'Неизвестное действие администратора';
  end if;
  return public.cf_lobby_match_admin_list();
end;
$$;

-- 5) Shared global and lobby chat with server-side membership checks.
create table if not exists public.cf_chat_messages (
  id uuid primary key default gen_random_uuid(),
  channel text not null check (channel in ('global','lobby')),
  lobby_id uuid references public.lobbies(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 500),
  created_at timestamptz not null default clock_timestamp(),
  check ((channel='global' and lobby_id is null) or (channel='lobby' and lobby_id is not null))
);
create index if not exists cf_chat_global_time_idx on public.cf_chat_messages(channel,created_at desc) where channel='global';
create index if not exists cf_chat_lobby_time_idx on public.cf_chat_messages(lobby_id,created_at desc) where channel='lobby';
alter table public.cf_chat_messages enable row level security;
revoke all on public.cf_chat_messages from anon, authenticated;

create or replace function public.cf_chat_state(p_scope text, p_lobby_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_my_lobby uuid; v_msgs jsonb; v_now timestamptz := clock_timestamp();
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  if p_scope not in ('global','lobby') then raise exception 'Неизвестный чат'; end if;
  if p_scope='lobby' then
    select lobby_id into v_my_lobby from public.lobby_members where user_id=v_uid;
    if p_lobby_id is null or v_my_lobby is null or p_lobby_id <> v_my_lobby then raise exception 'Чат доступен только участникам текущего лобби'; end if;
  end if;
  select coalesce(jsonb_agg(msg order by created_at), '[]'::jsonb) into v_msgs
  from (
    select jsonb_build_object(
      'id',c.id,'channel',c.channel,'lobby_id',c.lobby_id,'user_id',c.user_id,
      'body',c.body,'created_at',c.created_at,
      'nickname',coalesce(p.nickname,'player'),
      'display_name',coalesce(nullif(p.display_name,''),p.nickname,'Игрок'),
      'avatar',case when coalesce(char_length(p.avatar),0)<=64 then coalesce(p.avatar,'ember') else 'ember' end,
      'role',coalesce(p.role,'player'),'verified',coalesce(p.verified,false)
    ) as msg, c.created_at
    from public.cf_chat_messages c
    join public.profiles p on p.id=c.user_id
    where (p_scope='global' and c.channel='global')
       or (p_scope='lobby' and c.channel='lobby' and c.lobby_id=p_lobby_id)
    order by c.created_at desc limit 80
  ) q;
  return jsonb_build_object('messages',v_msgs,'server_now',v_now);
end;
$$;

create or replace function public.cf_chat_send(p_scope text, p_lobby_id uuid, p_body text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_my_lobby uuid; v_body text;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  if p_scope not in ('global','lobby') then raise exception 'Неизвестный чат'; end if;
  v_body := regexp_replace(trim(coalesce(p_body,'')), '[[:cntrl:]]', '', 'g');
  if char_length(v_body)<1 then raise exception 'Напиши сообщение'; end if;
  if char_length(v_body)>500 then raise exception 'Максимум 500 символов'; end if;
  if (select count(*) from public.cf_chat_messages c where c.user_id=v_uid and c.created_at>clock_timestamp()-interval '5 seconds')>=5 then
    raise exception 'Слишком быстро. Подожди пару секунд';
  end if;
  if p_scope='global' then
    insert into public.cf_chat_messages(channel,lobby_id,user_id,body) values ('global',null,v_uid,v_body);
    return public.cf_chat_state('global',null);
  else
    select lobby_id into v_my_lobby from public.lobby_members where user_id=v_uid;
    if p_lobby_id is null or v_my_lobby is null or p_lobby_id<>v_my_lobby then raise exception 'Ты не состоишь в этом лобби'; end if;
    insert into public.cf_chat_messages(channel,lobby_id,user_id,body) values ('lobby',v_my_lobby,v_uid,v_body);
    return public.cf_chat_state('lobby',v_my_lobby);
  end if;
end;
$$;

-- Restrict all RPC execution explicitly.
do $$
declare f text;
begin
  foreach f in array array[
    'cf_lobby_match_state()',
    'cf_lobby_match_start(text,text)',
    'cf_lobby_match_respond(boolean)',
    'cf_lobby_match_cancel()',
    'cf_lobby_match_admin_list()',
    'cf_lobby_match_admin_action(uuid,text,text)',
    'cf_chat_state(text,uuid)',
    'cf_chat_send(text,uuid,text)'
  ] loop
    execute format('revoke all on function public.%s from public, anon, authenticated',f);
  end loop;
  foreach f in array array[
    'cf_lobby_match_state()',
    'cf_lobby_match_start(text,text)',
    'cf_lobby_match_respond(boolean)',
    'cf_lobby_match_cancel()',
    'cf_chat_state(text,uuid)',
    'cf_chat_send(text,uuid,text)'
  ] loop
    execute format('grant execute on function public.%s to authenticated',f);
  end loop;
  grant execute on function public.cf_lobby_match_admin_list() to authenticated;
  grant execute on function public.cf_lobby_match_admin_action(uuid,text,text) to authenticated;
end $$;

select 'CF FACEIT v8 patch installed' as result,
       (select role from public.profiles where lower(nickname)='sonse' limit 1) as sonse_role;
