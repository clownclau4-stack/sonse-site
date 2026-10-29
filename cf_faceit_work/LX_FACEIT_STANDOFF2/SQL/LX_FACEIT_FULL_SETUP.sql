-- LX FACEIT for Standoff 2 — one-time full setup for a dedicated LX Supabase project.
-- Run this complete file in a new, separate LX project. Never run it against CF FACEIT or another game's database.
-- The older SQL/19 queue drop and SQL/31 match purge are intentionally excluded.
-- SQL/52 map/ID compatibility is included at the end; do not run SQL/52 separately.
-- Legacy cf_* identifiers are retained only so the current site's JS and RPC contracts match.


-- ==================== Included source: 01_setup_all_online.sql ====================
-- LX FACEIT, шаг 1: профили и вход
-- Вставь целиком в SQL Editor -> Run. Запускай строго по номерам.
-- LX FACEIT: ОДИН скрипт для онлайн-аккаунтов. Можно запускать повторно.
-- Supabase -> SQL Editor -> New query -> вставь всё -> Run.
-- Ключ service_role нигде не нужен.

create extension if not exists pgcrypto;

-- 1. Таблица профилей и все нужные колонки
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  nickname text unique not null check (char_length(nickname) between 3 and 20),
  created_at timestamptz not null default now()
);
alter table public.profiles add column if not exists game_id text;
alter table public.profiles add column if not exists display_name text not null default '';
alter table public.profiles add column if not exists avatar text not null default 'ember';
alter table public.profiles add column if not exists elo integer not null default 800;
alter table public.profiles add column if not exists wins integer not null default 0;
alter table public.profiles add column if not exists losses integer not null default 0;
alter table public.profiles add column if not exists verified boolean not null default false;
alter table public.profiles add column if not exists role text not null default 'player';
alter table public.profiles add column if not exists telegram_url text not null default '';
alter table public.profiles add column if not exists youtube_url text not null default '';
alter table public.profiles add column if not exists tiktok_url text not null default '';

-- 2. Ограничения: роли, формат ID, ссылки/аватар не бесконечные
do $$
declare c name;
begin
  for c in select conname from pg_constraint
    where conrelid='public.profiles'::regclass and contype='c'
    and (pg_get_constraintdef(oid) ilike '%role%' or conname in ('profiles_game_id_format','cf_profiles_limits')) loop
    execute format('alter table public.profiles drop constraint %I', c);
  end loop;
  alter table public.profiles add constraint profiles_role_allowed check (role in ('player','admin','founder'));
  alter table public.profiles add constraint profiles_game_id_format check (game_id is null or game_id ~ '^[0-9]{6,7}$');
  alter table public.profiles add constraint cf_profiles_limits check (
    char_length(avatar) <= 300000 and char_length(display_name) <= 40 and
    char_length(telegram_url) <= 300 and char_length(youtube_url) <= 300 and char_length(tiktok_url) <= 300);
end $$;
create unique index if not exists profiles_game_id_unique on public.profiles (game_id) where game_id is not null;
do $$ begin
  create unique index if not exists profiles_nickname_lower_unique on public.profiles (lower(nickname));
exception when others then
  raise notice 'Индекс уникальности ника без учёта регистра не создан (есть дубли). Это не критично.';
end $$;

-- 3. Остальные таблицы (задел под матчи и новости)
create table if not exists public.matches (
  id uuid primary key default gen_random_uuid(),
  mode text not null check (mode in ('ranked','duo')),
  map_name text,
  status text not null default 'queue' check (status in ('queue','ready','live','pending_review','disputed','done','cancelled')),
  team_a uuid[] not null default '{}',
  team_b uuid[] not null default '{}',
  score_a integer, score_b integer,
  winner text check (winner in ('A','B')),
  evidence_path text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  completed_at timestamptz
);
create table if not exists public.match_review_claims (
  match_id uuid primary key references public.matches(id) on delete cascade,
  claimed_by uuid not null references auth.users(id) on delete cascade,
  claimed_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '15 minutes')
);
alter table public.matches enable row level security;
alter table public.match_review_claims enable row level security;
drop policy if exists "signed-in users read matches" on public.matches;
create policy "signed-in users read matches" on public.matches for select to authenticated using (true);

-- 4. Триггер: профиль создаётся при регистрации (ник и ID берутся из формы)
create or replace function public.cf_faceit_handle_new_user()
returns trigger language plpgsql security definer set search_path = public, auth as $$
declare v_nick text; v_fallback text; v_game_id text;
begin
  v_nick := coalesce(new.raw_user_meta_data ->> 'nickname', '');
  v_game_id := coalesce(new.raw_user_meta_data ->> 'game_id', '');
  if v_game_id !~ '^[0-9]{6,7}$' then
    raise exception 'Игровой ID должен состоять из 6 или 7 цифр';
  end if;
  v_fallback := 'player_' || substr(replace(new.id::text, '-', ''), 1, 8);
  if char_length(v_nick) < 3 or char_length(v_nick) > 20 or v_nick !~ '^[A-Za-z0-9_-]+$' then
    v_nick := v_fallback;
  end if;
  begin
    insert into public.profiles (id, nickname, game_id, display_name, avatar, role, verified)
    values (new.id, v_nick, v_game_id, v_nick, 'ember', 'player', false)
    on conflict (id) do nothing;
  exception when unique_violation then
    if exists (select 1 from public.profiles where game_id = v_game_id) then
      raise exception 'Этот игровой ID уже занят';
    end if;
    insert into public.profiles (id, nickname, game_id, display_name, avatar, role, verified)
    values (new.id, v_fallback, v_game_id, v_fallback, 'ember', 'player', false)
    on conflict (id) do nothing;
  end;
  return new;
end $$;
revoke all on function public.cf_faceit_handle_new_user() from public, anon, authenticated;
drop trigger if exists on_auth_user_created on auth.users;
drop trigger if exists cf_faceit_auth_user_created on auth.users;
create trigger cf_faceit_auth_user_created after insert on auth.users
  for each row execute procedure public.cf_faceit_handle_new_user();

-- 5. Права: все читают профили; игрок меняет ТОЛЬКО своё имя, аватар и ссылки.
--    Роль, галочку, ELO, ник и ID с сайта изменить нельзя.
alter table public.profiles enable row level security;
revoke all on public.profiles from anon, authenticated;
grant select on public.profiles to anon, authenticated;
grant update (display_name, avatar, telegram_url, youtube_url, tiktok_url) on public.profiles to authenticated;
drop policy if exists "profiles are readable" on public.profiles;
drop policy if exists cf_faceit_profile_read on public.profiles;
drop policy if exists "users insert own profile" on public.profiles;
drop policy if exists "users update own profile" on public.profiles;
drop policy if exists "users update own public profile fields" on public.profiles;
drop policy if exists cf_faceit_profile_update_own on public.profiles;
create policy cf_faceit_profile_read on public.profiles for select using (true);
create policy cf_faceit_profile_update_own on public.profiles for update to authenticated
  using (auth.uid() = id) with check (auth.uid() = id);

-- 6. Проверка
select (select count(*) from public.profiles) as profiles,
       (select count(*) from pg_trigger where tgname='cf_faceit_auth_user_created') as trigger_ok;

-- ==================== Included source: 02_setup_lobby_p1.sql ====================
-- LX FACEIT, шаг 2: лобби (часть 1 из 2)
-- Вставь целиком в SQL Editor -> Run. Запускай строго по номерам.
-- LX FACEIT: онлайн-лобби и приглашения друзей.
-- Запускать ПОСЛЕ SETUP_ALL_ONLINE.sql. Можно запускать повторно.
-- Supabase -> SQL Editor -> New query -> вставь всё -> Run.

create table if not exists public.lobbies (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
create table if not exists public.lobby_members (
  lobby_id uuid not null references public.lobbies(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (lobby_id, user_id),
  unique (user_id)            -- игрок состоит максимум в одном лобби
);
create table if not exists public.lobby_invites (
  id uuid primary key default gen_random_uuid(),
  lobby_id uuid not null references public.lobbies(id) on delete cascade,
  from_user uuid not null references auth.users(id) on delete cascade,
  to_user uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  check (from_user <> to_user),
  unique (lobby_id, to_user)  -- одно приглашение на игрока в одно лобби
);
alter table public.lobbies enable row level security;
alter table public.lobby_members enable row level security;
alter table public.lobby_invites enable row level security;
revoke all on public.lobbies, public.lobby_members, public.lobby_invites from anon, authenticated;
-- Политик нет намеренно: доступ только через функции ниже.

create or replace function public.cf_lobby_user_json(p_uid uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', p.id, 'nickname', p.nickname, 'display_name', coalesce(nullif(p.display_name,''), p.nickname),
    'avatar', case when char_length(p.avatar) <= 64 then p.avatar else 'ember' end,
    'elo', p.elo, 'verified', p.verified, 'role', p.role)
  from public.profiles p where p.id = p_uid
$$;

-- Текущее состояние: моё лобби + входящие приглашения (устаревшие > 10 минут удаляются)
create or replace function public.lobby_state()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_lobby uuid; v_owner uuid; v_members jsonb; v_in jsonb; v_out jsonb;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  delete from public.lobby_invites where created_at < now() - interval '10 minutes';
  select m.lobby_id, l.owner_id into v_lobby, v_owner
    from public.lobby_members m join public.lobbies l on l.id = m.lobby_id where m.user_id = v_uid;
  if v_lobby is not null then
    select coalesce(jsonb_agg(public.cf_lobby_user_json(m.user_id) || jsonb_build_object('is_owner', m.user_id = v_owner) order by m.joined_at), '[]')
      into v_members from public.lobby_members m where m.lobby_id = v_lobby;
    select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'to', public.cf_lobby_user_json(i.to_user)) order by i.created_at), '[]')
      into v_out from public.lobby_invites i where i.lobby_id = v_lobby;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'from', public.cf_lobby_user_json(i.from_user), 'created_at', i.created_at) order by i.created_at), '[]')
    into v_in from public.lobby_invites i where i.to_user = v_uid;
  return jsonb_build_object(
    'lobby', case when v_lobby is null then null else jsonb_build_object('id', v_lobby, 'owner_id', v_owner, 'is_owner', v_owner = v_uid, 'members', v_members, 'invites', v_out) end,
    'invites_in', v_in);
end $$;

-- Пригласить игрока (лобби создаётся автоматически; приглашать может хозяин лобби)
create or replace function public.lobby_invite(p_user uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_lobby uuid; v_owner uuid; v_count int; v_pending int;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  if p_user is null or p_user = v_uid then raise exception 'Нельзя пригласить самого себя'; end if;
  if not exists (select 1 from public.profiles where id = p_user) then raise exception 'Игрок не найден'; end if;
  perform pg_advisory_xact_lock(hashtext('cf:lobby:' || v_uid::text));
  select m.lobby_id, l.owner_id into v_lobby, v_owner from public.lobby_members m join public.lobbies l on l.id = m.lobby_id where m.user_id = v_uid;
  if v_lobby is null then
    insert into public.lobbies(owner_id) values (v_uid) returning id into v_lobby;
    insert into public.lobby_members(lobby_id, user_id) values (v_lobby, v_uid);
    v_owner := v_uid;
  end if;
  if v_owner <> v_uid then raise exception 'Приглашать может только хозяин лобби'; end if;
  if exists (select 1 from public.lobby_members where lobby_id = v_lobby and user_id = p_user) then raise exception 'Игрок уже в вашем лобби'; end if;
  select count(*) into v_count from public.lobby_members where lobby_id = v_lobby;
  select count(*) into v_pending from public.lobby_invites where lobby_id = v_lobby;
  if v_count + v_pending >= 5 then raise exception 'В лобби максимум 5 игроков (с учётом приглашений)'; end if;
  insert into public.lobby_invites(lobby_id, from_user, to_user) values (v_lobby, v_uid, p_user)
    on conflict (lobby_id, to_user) do update set created_at = now();
  return public.lobby_state();
end $$;

-- Принять или отклонить приглашение
create or replace function public.lobby_respond(p_invite uuid, p_accept boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_inv public.lobby_invites%rowtype; v_old uuid; v_count int; v_new_owner uuid;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  perform pg_advisory_xact_lock(hashtext('cf:lobby:' || v_uid::text));
  select * into v_inv from public.lobby_invites where id = p_invite and to_user = v_uid for update;
  if not found then raise exception 'Приглашение устарело или не найдено'; end if;
  if not p_accept then
    delete from public.lobby_invites where id = p_invite;
    return public.lobby_state();
  end if;
  perform pg_advisory_xact_lock(hashtext('cf:lobbyjoin:' || v_inv.lobby_id::text));
  select count(*) into v_count from public.lobby_members where lobby_id = v_inv.lobby_id;
  if not exists (select 1 from public.lobbies where id = v_inv.lobby_id) then raise exception 'Лобби уже закрыто'; end if;
  if v_count >= 5 then raise exception 'Лобби заполнено'; end if;
  -- выйти из прежнего лобби
  select lobby_id into v_old from public.lobby_members where user_id = v_uid;
  if v_old is not null then
    delete from public.lobby_members where user_id = v_uid;
    select user_id into v_new_owner from public.lobby_members where lobby_id = v_old order by joined_at limit 1;
    if v_new_owner is null then delete from public.lobbies where id = v_old;
    else update public.lobbies set owner_id = v_new_owner where id = v_old and owner_id = v_uid; end if;
  end if;
  insert into public.lobby_members(lobby_id, user_id) values (v_inv.lobby_id, v_uid);
  delete from public.lobby_invites where to_user = v_uid;   -- остальные приглашения больше не нужны
  return public.lobby_state();
end $$;

-- Выйти из лобби (если хозяин ушёл, хозяином становится самый давний участник)
create or replace function public.lobby_leave()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_lobby uuid; v_new_owner uuid;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  perform pg_advisory_xact_lock(hashtext('cf:lobby:' || v_uid::text));
  select lobby_id into v_lobby from public.lobby_members where user_id = v_uid;
  if v_lobby is not null then
    delete from public.lobby_members where user_id = v_uid;
    select user_id into v_new_owner from public.lobby_members where lobby_id = v_lobby order by joined_at limit 1;
    if v_new_owner is null then delete from public.lobbies where id = v_lobby;
    else update public.lobbies set owner_id = v_new_owner where id = v_lobby and owner_id = v_uid; end if;
  end if;
  return public.lobby_state();
end $$;

-- ==================== Included source: 03_setup_lobby_p2.sql ====================
-- LX FACEIT, шаг 3: лобби (часть 2 из 2)
-- Вставь целиком в SQL Editor -> Run. Запускай строго по номерам.
-- Хозяин убирает участника или отзывает приглашение
create or replace function public.lobby_kick(p_user uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_lobby uuid;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select l.id into v_lobby from public.lobbies l where l.owner_id = v_uid;
  if v_lobby is null then raise exception 'Вы не хозяин лобби'; end if;
  if p_user = v_uid then raise exception 'Используйте «Выйти из лобби»'; end if;
  delete from public.lobby_members where lobby_id = v_lobby and user_id = p_user;
  delete from public.lobby_invites where lobby_id = v_lobby and to_user = p_user;
  return public.lobby_state();
end $$;

do $$
declare f text;
begin
  foreach f in array array['lobby_state()','lobby_invite(uuid)','lobby_respond(uuid,boolean)','lobby_leave()','lobby_kick(uuid)','cf_lobby_user_json(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
  foreach f in array array['lobby_state()','lobby_invite(uuid)','lobby_respond(uuid,boolean)','lobby_leave()','lobby_kick(uuid)'] loop
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

select 'lobby ok' as result;

-- ==================== Included source: 04_friends_setup.sql ====================
-- LX FACEIT, шаг 4: друзья
-- Вставь целиком в SQL Editor -> Run. Запускай строго по номерам.
-- LX FACEIT Friends: friend requests + friends list + menu actions.
-- Requires public.profiles(id, nickname, display_name, avatar, elo, game_id).
create table if not exists public.cf_friendships (
  id uuid primary key default gen_random_uuid(),
  from_user uuid not null references auth.users(id) on delete cascade,
  to_user uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (from_user <> to_user),
  unique (from_user, to_user)
);
create index if not exists cf_friendships_to_status_idx
  on public.cf_friendships(to_user, status);
create index if not exists cf_friendships_from_status_idx
  on public.cf_friendships(from_user, status);
alter table public.cf_friendships enable row level security;
revoke all on public.cf_friendships from anon, authenticated;

create or replace function public.cf_friend_profile(p_uid uuid)
returns jsonb language sql stable security definer
set search_path = public as $$
  select jsonb_build_object(
    'id',p.id,'nickname',p.nickname,
    'display_name',coalesce(nullif(p.display_name,''),p.nickname),
    'avatar',case when coalesce(char_length(p.avatar),0)<=64 then coalesce(p.avatar,'ember') else 'ember' end,
    'elo',coalesce(p.elo,800),'verified',coalesce(p.verified,false),'role',coalesce(p.role,'player')
  ) from public.profiles p where p.id=p_uid
$$;

create or replace function public.cf_friend_state()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_uid uuid:=auth.uid(); v_friends jsonb; v_in jsonb; v_out jsonb;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select coalesce(jsonb_agg(public.cf_friend_profile(case when f.from_user=v_uid then f.to_user else f.from_user end) order by f.updated_at desc),'[]'::jsonb)
    into v_friends from public.cf_friendships f
    where f.status='accepted' and (f.from_user=v_uid or f.to_user=v_uid);
  select coalesce(jsonb_agg(public.cf_friend_profile(f.from_user) || jsonb_build_object('request_id',f.id,'created_at',f.created_at) order by f.created_at desc),'[]'::jsonb)
    into v_in from public.cf_friendships f where f.to_user=v_uid and f.status='pending';
  select coalesce(jsonb_agg(public.cf_friend_profile(f.to_user) || jsonb_build_object('request_id',f.id,'created_at',f.created_at) order by f.created_at desc),'[]'::jsonb)
    into v_out from public.cf_friendships f where f.from_user=v_uid and f.status='pending';
  return jsonb_build_object('friends',v_friends,'incoming',v_in,'outgoing',v_out);
end $$;

create or replace function public.cf_friend_request(p_target text)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare v_uid uuid:=auth.uid(); v_target uuid;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  if nullif(trim(p_target),'') is null then raise exception 'Введи ник или игровой ID'; end if;
  if position('@' in p_target)>0 then
    select p.id into v_target from auth.users u join public.profiles p on p.id=u.id where lower(u.email)=lower(trim(p_target)) limit 1;
  elsif trim(p_target) ~ '^[0-9]{6}$' then
    select id into v_target from public.profiles where game_id=trim(p_target) limit 1;
  else
    select id into v_target from public.profiles where lower(nickname)=lower(trim(p_target)) limit 1;
  end if;
  if v_target is null then raise exception 'Игрок не найден'; end if;
  if v_target=v_uid then raise exception 'Нельзя добавить самого себя'; end if;
  if exists(select 1 from public.cf_friendships where status='accepted' and ((from_user=v_uid and to_user=v_target) or (from_user=v_target and to_user=v_uid))) then
    raise exception 'Вы уже друзья';
  end if;
  if exists(select 1 from public.cf_friendships where from_user=v_target and to_user=v_uid and status='pending') then
    update public.cf_friendships set status='accepted',updated_at=now() where from_user=v_target and to_user=v_uid;
  else
    insert into public.cf_friendships(from_user,to_user,status) values(v_uid,v_target,'pending')
    on conflict(from_user,to_user) do update set status='pending',updated_at=now();
  end if;
  return public.cf_friend_state();
end $$;

create or replace function public.cf_friend_respond(p_target uuid,p_accept boolean)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_uid uuid:=auth.uid();
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  if not exists(select 1 from public.cf_friendships where from_user=p_target and to_user=v_uid and status='pending') then
    raise exception 'Заявка не найдена или уже обработана';
  end if;
  if p_accept then
    update public.cf_friendships set status='accepted',updated_at=now()
    where from_user=p_target and to_user=v_uid and status='pending';
  else
    delete from public.cf_friendships where from_user=p_target and to_user=v_uid and status='pending';
  end if;
  return public.cf_friend_state();
end $$;

create or replace function public.cf_friend_remove(p_target uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_uid uuid:=auth.uid();
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  delete from public.cf_friendships
   where (from_user=v_uid and to_user=p_target) or (from_user=p_target and to_user=v_uid);
  return public.cf_friend_state();
end $$;

do $$ declare f text;
begin
  foreach f in array array['cf_friend_profile(uuid)','cf_friend_state()','cf_friend_request(text)','cf_friend_respond(uuid,boolean)','cf_friend_remove(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated',f);
  end loop;
  foreach f in array array['cf_friend_state()','cf_friend_request(text)','cf_friend_respond(uuid,boolean)','cf_friend_remove(uuid)'] loop
    execute format('grant execute on function public.%s to authenticated',f);
  end loop;
end $$;
select 'LX FACEIT friends setup complete' as result;

-- ==================== Included source: 05_cf_staff_roles.sql ====================
-- LX FACEIT, шаг 5: роли персонала
-- Вставь целиком в SQL Editor -> Run. Запускай строго по номерам.
-- LX FACEIT staff roles: lookup by account email, game_id or Supabase UUID.
-- Run this after the existing profiles/Auth setup.
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
  if nullif(trim(p_target), '') is null then raise exception 'Укажи почту, игровой ID или UUID'; end if;
  if p_role not in ('player','tester','admin') then raise exception 'Недопустимая роль'; end if;

  select role into v_actor_role from public.profiles where id = v_actor;
  if coalesce(v_actor_role,'player') not in ('founder','admin') then
    raise exception 'Недостаточно прав';
  end if;

  -- Resolve UUID, 6-digit game ID, nickname, or email from Auth.
  if p_target ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select p.id, p.role, p.nickname into v_target, v_target_role, v_nickname
    from public.profiles p where p.id = p_target::uuid;
  elsif position('@' in p_target) > 0 then
    select p.id, p.role, p.nickname into v_target, v_target_role, v_nickname
    from auth.users u join public.profiles p on p.id = u.id
    where lower(u.email) = lower(trim(p_target)) limit 1;
  elsif p_target ~ '^[0-9]{6}$' then
    select p.id, p.role, p.nickname into v_target, v_target_role, v_nickname
    from public.profiles p where p.game_id = trim(p_target) limit 1;
  else
    select p.id, p.role, p.nickname into v_target, v_target_role, v_nickname
    from public.profiles p where lower(p.nickname) = lower(trim(p_target)) limit 1;
  end if;

  if v_target is null then raise exception 'Игрок не найден. Проверь почту, игровой ID или ник'; end if;
  if v_target_role = 'founder' then raise exception 'Нельзя изменить роль основателя'; end if;
  if v_actor_role = 'admin' then
    if p_role = 'admin' then raise exception 'Только основатель может выдавать админку'; end if;
    if v_target_role = 'admin' then raise exception 'Администраторы не могут менять права других администраторов'; end if;
    if v_target = v_actor then raise exception 'Нельзя изменять собственные права'; end if;
  end if;

  update public.profiles
     set role = p_role, verified = coalesce(p_verified, false)
   where id = v_target;

  return jsonb_build_object('ok',true,'user_id',v_target,'nickname',v_nickname,
    'role',p_role,'verified',coalesce(p_verified,false));
end;
$$;

revoke all on function public.cf_manage_staff_lookup(text,text,boolean) from public, anon;
grant execute on function public.cf_manage_staff_lookup(text,text,boolean) to authenticated;

-- ==================== Included source: 06_patch_match_chat_roles_p1.sql ====================
-- LX FACEIT, шаг 6: матчи, чат, роли (часть 1 из 4)
-- Вставь целиком в SQL Editor -> Run. Запускай строго по номерам.
-- LX FACEIT v8 migration: staff roles, shared lobby matches/timer, lobby chat and global chat.
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

-- ==================== Included source: 07_patch_match_chat_roles_p2.sql ====================
-- LX FACEIT, шаг 7: матчи, чат, роли (часть 2 из 4)
-- Вставь целиком в SQL Editor -> Run. Запускай строго по номерам.
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

-- ==================== Included source: 08_patch_match_chat_roles_p3.sql ====================
-- LX FACEIT, шаг 8: матчи, чат, роли (часть 3 из 4)
-- Вставь целиком в SQL Editor -> Run. Запускай строго по номерам.
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

-- ==================== Included source: 09_patch_match_chat_roles_p4.sql ====================
-- LX FACEIT, шаг 9: матчи, чат, роли (часть 4 из 4)
-- Вставь целиком в SQL Editor -> Run. Запускай строго по номерам.
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

select 'LX FACEIT v8 patch installed' as result,
       (select role from public.profiles where lower(nickname)='sonse' limit 1) as sonse_role;

-- ==================== Included source: 10_v9_matchmaking_results_p1.sql ====================
-- LX FACEIT, шаг 10: запуск матча: поиск, команды, хост, результаты (часть 1 из 7)
-- Вставь целиком в SQL Editor -> Run. Запускай строго по номерам.
-- ================================================================
-- LX FACEIT v9 — party-preserving matchmaking, room host choice,
-- post-match screenshot proof and admin result approval.
-- Run AFTER SETUP_ALL_ONLINE.sql, SETUP_LOBBY.sql and
-- CF_FACEIT_PATCH_MATCH_CHAT_ROLES.sql.
-- Supabase Dashboard -> SQL Editor -> New query -> paste all -> Run.
-- ================================================================

create extension if not exists pgcrypto;

-- Extend the existing shared-match row. We retain the old column names
-- so the v8 admin/chat setup remains compatible.
alter table public.cf_lobby_matches
  add column if not exists team_a_ids uuid[] not null default '{}',
  add column if not exists team_b_ids uuid[] not null default '{}',
  add column if not exists host_choice text,
  add column if not exists room_host_id uuid references auth.users(id) on delete set null,
  add column if not exists room_host_nickname text not null default '',
  add column if not exists result_screenshot_url text,
  add column if not exists result_submitted_by uuid references auth.users(id) on delete set null,
  add column if not exists result_submitted_at timestamptz,
  add column if not exists result_score text not null default '',
  add column if not exists winner_team text,
  add column if not exists result_reviewed_by uuid references auth.users(id) on delete set null,
  add column if not exists result_reviewed_at timestamptz;

-- Replace the old status CHECK so the new workflow can be stored.
do $$
declare c record;
begin
  for c in
    select conname from pg_constraint
    where conrelid='public.cf_lobby_matches'::regclass
      and contype='c'
      and pg_get_constraintdef(oid) ilike '%status%'
  loop
    execute format('alter table public.cf_lobby_matches drop constraint %I',c.conname);
  end loop;
  alter table public.cf_lobby_matches
    add constraint cf_lobby_matches_status_v9_check
    check (status in (
      'searching','found','choose_host','host_selected','pending_admin',
      'taken','room','joined','live','result_pending','done','cancelled'
    ));
end $$;

-- Roster JSON returns stored profile avatars only when they are reasonable-sized.
-- Very large base64 uploads fall back to the selected avatar token to keep polling light.
create or replace function public.cf_v9_user_json(p_uid uuid)
returns jsonb language sql stable security definer set search_path=public as $$
  select jsonb_build_object(
    'id',p.id,
    'nickname',p.nickname,
    'display_name',coalesce(nullif(p.display_name,''),p.nickname),
    'avatar',case
      when char_length(p.avatar)<=1000 and p.avatar ~* '^https://[^[:space:]]+$' then p.avatar
      when char_length(p.avatar)<=40000 and p.avatar ~ '^data:image/(png|jpeg|webp|gif);base64,' then p.avatar
      when p.avatar in ('ember','steel','azure','moss','plum','sand') then p.avatar
      else 'ember'
    end,
    'elo',coalesce(p.elo,800),
    'verified',coalesce(p.verified,false),
    'role',coalesce(p.role,'player')
  )
  from public.profiles p where p.id=p_uid
$$;
revoke all on function public.cf_v9_user_json(uuid) from public,anon,authenticated;

-- V8 matches had no team columns. Cancel only those legacy active rows so players do not get stuck in an incompatible match.
update public.cf_lobby_matches
set status='cancelled',cancel_reason='Матч обновлён до системы v9',updated_at=clock_timestamp()
where status not in ('done','cancelled')
  and cardinality(team_a_ids)=0 and cardinality(team_b_ids)=0;

create index if not exists cf_lobby_matches_participants_gin
  on public.cf_lobby_matches using gin(participant_ids);
create index if not exists cf_lobby_matches_status_recent_idx
  on public.cf_lobby_matches(status, created_at desc);

-- Each queue entry represents a complete lobby party. Parties are never split.
create table if not exists public.cf_matchmaking_queue (
  id uuid primary key default gen_random_uuid(),
  queue_order bigint generated by default as identity unique,
  lobby_id uuid not null references public.lobbies(id) on delete cascade,
  party_ids uuid[] not null,
  mode text not null check (mode in ('ranked','duo')),
  map_name text not null check (map_name in ('Mirage','Dust2','Vertigo','Inferno')),
  queue_status text not null default 'queued'
    check (queue_status in ('queued','matched','cancelled')),
  match_id uuid references public.cf_lobby_matches(id) on delete set null,
  queued_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp()
);
create unique index if not exists cf_matchmaking_one_queue_per_lobby
  on public.cf_matchmaking_queue(lobby_id) where queue_status='queued';
create index if not exists cf_matchmaking_queue_mode_fifo
  on public.cf_matchmaking_queue(mode, queue_status, queue_order);
alter table public.cf_matchmaking_queue enable row level security;
revoke all on public.cf_matchmaking_queue from anon, authenticated;

-- If a lobby's membership changes while queued, cancel its queue entry. This keeps
-- the locked-in party list accurate and prevents friends from being split or stale players joining.
create or replace function public.cf_v9_cancel_queue_on_member_change()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  update public.cf_matchmaking_queue
  set queue_status='cancelled',updated_at=clock_timestamp()
  where lobby_id=coalesce(new.lobby_id,old.lobby_id) and queue_status='queued';
  if tg_op='DELETE' then return old; else return new; end if;
end;
$$;
revoke all on function public.cf_v9_cancel_queue_on_member_change() from public,anon,authenticated;
drop trigger if exists cf_v9_cancel_queue_member_change on public.lobby_members;
create trigger cf_v9_cancel_queue_member_change
after insert or delete on public.lobby_members
for each row execute function public.cf_v9_cancel_queue_on_member_change();

-- ==================== Included source: 11_v9_matchmaking_results_p2.sql ====================
-- LX FACEIT, шаг 11: запуск матча: поиск, команды, хост, результаты (часть 2 из 7)
-- Вставь целиком в SQL Editor -> Run. Запускай строго по номерам.
-- Internal matcher: select whole parties whose total is exactly 4 (2v2)
-- or 10 (5v5), then find a valid whole-party 2/2 or 5/5 partition.
create or replace function public.cf_matchmaking_try_form(p_mode text)
returns boolean
language plpgsql security definer set search_path=public as $$
declare
  v_target integer;
  v_team_size integer;
  v_combo record;
  v_queue_ids uuid[];
  v_players uuid[];
  v_groups jsonb;
  v_group_count integer;
  v_anchor_lobby uuid;
  v_map text;
  v_mask integer;
  v_mask_max integer;
  v_i integer;
  v_party uuid[];
  v_team_a uuid[];
  v_team_b uuid[];
  v_sum_a integer;
  v_valid boolean;
  v_match_id uuid;
  v_started_by uuid;
begin
  if p_mode not in ('ranked','duo') then
    raise exception 'Недопустимый режим';
  end if;
  v_target := case when p_mode='duo' then 4 else 10 end;
  v_team_size := v_target / 2;
  perform pg_advisory_xact_lock(hashtext('cf:v9:matcher:' || p_mode));
  update public.cf_matchmaking_queue
    set queue_status='cancelled',updated_at=clock_timestamp()
  where mode=p_mode and queue_status='queued'
    and queued_at < clock_timestamp()-interval '10 minutes';

  -- Try up to 500 FIFO combinations. Search the oldest 16 parties per pass
  -- to bound recursive search cost. Abandoned queue entries expire after 10 minutes.
  for v_combo in
    with recursive q as materialized (
      select q0.id,q0.queue_order,q0.lobby_id,q0.party_ids,q0.mode,q0.map_name,
             cardinality(q0.party_ids) as party_size
      from public.cf_matchmaking_queue q0
      where q0.mode=p_mode and q0.queue_status='queued'
      order by q0.queue_order
      limit 16
    ), combos as (
      select array[q.id]::uuid[] as queue_ids,
             q.party_ids as player_ids,
             jsonb_build_array(jsonb_build_object(
               'queue_id',q.id,'lobby_id',q.lobby_id,
               'party_ids',to_jsonb(q.party_ids),'map_name',q.map_name
             )) as groups_json,
             q.party_size as total_players,
             q.queue_order as first_order,
             q.queue_order as last_order
      from q
      where q.party_size <= v_target
      union all
      select c.queue_ids || q.id,
             c.player_ids || q.party_ids,
             c.groups_json || jsonb_build_array(jsonb_build_object(
               'queue_id',q.id,'lobby_id',q.lobby_id,
               'party_ids',to_jsonb(q.party_ids),'map_name',q.map_name
             )),
             c.total_players + q.party_size,
             c.first_order,
             q.queue_order
      from combos c
      join q on q.queue_order > c.last_order
      where c.total_players + q.party_size <= v_target
    )
    select queue_ids,player_ids,groups_json,first_order
    from combos
    where total_players=v_target
    order by first_order, cardinality(queue_ids), queue_ids::text
    limit 500
  loop
    v_queue_ids := v_combo.queue_ids;
    v_players := v_combo.player_ids;
    v_groups := v_combo.groups_json;
    v_group_count := jsonb_array_length(v_groups);
    v_anchor_lobby := (v_groups->0->>'lobby_id')::uuid;
    v_map := v_groups->0->>'map_name';
    v_mask_max := (1 << v_group_count) - 1;
    v_valid := false;

    if v_group_count > 0 then
      for v_mask in 0..v_mask_max loop
        v_team_a := '{}'::uuid[];
        v_team_b := '{}'::uuid[];
        v_sum_a := 0;
        for v_i in 0..(v_group_count-1) loop
          select coalesce(array_agg(x.uid::uuid),'{}'::uuid[])
            into v_party
          from jsonb_array_elements_text(v_groups->v_i->'party_ids') as x(uid);
          if (v_mask & (1 << v_i)) <> 0 then
            v_team_a := v_team_a || v_party;
            v_sum_a := v_sum_a + cardinality(v_party);
          else
            v_team_b := v_team_b || v_party;
          end if;
        end loop;
        if v_sum_a=v_team_size
           and cardinality(v_team_b)=v_team_size then
          v_valid := true;
          exit;
        end if;
      end loop;
    end if;

    if v_valid then
      exit;
    else
      v_queue_ids := null;
      v_players := null;
      v_groups := null;
    end if;
  end loop;

  if v_queue_ids is null then
    return false;
  end if;

  -- Ensure no stale active match already contains one of these players.
  if exists (
    select 1 from public.cf_lobby_matches m
    where m.status not in ('done','cancelled')
      and m.participant_ids && v_players
  ) then
    update public.cf_matchmaking_queue
      set queue_status='cancelled',updated_at=clock_timestamp()
    where id=any(v_queue_ids);
    return false;
  end if;

  v_started_by := v_players[1];
  insert into public.cf_lobby_matches(
    lobby_id,started_by,participant_ids,team_a_ids,team_b_ids,
    mode,map_name,status,started_at,found_at,expires_at
  ) values (
    v_anchor_lobby,v_started_by,v_players,v_team_a,v_team_b,
    p_mode,v_map,'found',clock_timestamp(),clock_timestamp(),clock_timestamp()+interval '15 seconds'
  ) returning id into v_match_id;

  update public.cf_matchmaking_queue
    set queue_status='matched',match_id=v_match_id,updated_at=clock_timestamp()
  where id=any(v_queue_ids);

  return true;
end;
$$;

-- ==================== Included source: 12_v9_matchmaking_results_p3.sql ====================
-- LX FACEIT, шаг 12: запуск матча: поиск, команды, хост, результаты (часть 3 из 7)
-- Вставь целиком в SQL Editor -> Run. Запускай строго по номерам.
revoke all on function public.cf_matchmaking_try_form(text) from public,anon,authenticated;

-- ==================== Included source: 13_v9_matchmaking_results_p4.sql ====================
-- LX FACEIT, шаг 13: запуск матча: поиск, команды, хост, результаты (часть 4 из 7)
-- Вставь целиком в SQL Editor -> Run. Запускай строго по номерам.
-- Return the current user's match regardless of which lobby the row is anchored to.
create or replace function public.cf_lobby_match_state()
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_uid uuid := auth.uid();
  v_lobby uuid;
  v_now timestamptz := clock_timestamp();
  v_match public.cf_lobby_matches%rowtype;
  v_queue public.cf_matchmaking_queue%rowtype;
  v_players jsonb := '[]'::jsonb;
  v_team_a jsonb := '[]'::jsonb;
  v_team_b jsonb := '[]'::jsonb;
  v_accepted integer := 0;
  v_queue_count integer := 0;
  v_total integer := 0;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;

  select lm.lobby_id into v_lobby
  from public.lobby_members lm where lm.user_id=v_uid;
  if v_lobby is not null then
    update public.cf_matchmaking_queue
      set queue_status='cancelled',updated_at=v_now
    where lobby_id=v_lobby and queue_status='queued'
      and queued_at<v_now-interval '10 minutes';
  end if;

  select * into v_match
  from public.cf_lobby_matches m
  where v_uid=any(m.participant_ids)
    and m.status not in ('done','cancelled')
  order by m.created_at desc limit 1;

  if found then
    if v_match.status='found' and v_match.expires_at<=v_now then
      update public.cf_lobby_matches
      set status='cancelled',cancel_reason='Время принятия матча истекло',updated_at=v_now
      where id=v_match.id and status='found' and expires_at<=v_now returning * into v_match;
      if not found then
        select * into v_match from public.cf_lobby_matches where id=v_match.id;
      end if;
    end if;

    if v_match.status='found' then
      select count(*) into v_accepted
      from unnest(v_match.participant_ids) as x(uid)
      where x.uid=any(v_match.accepted_by);
      v_total := cardinality(v_match.participant_ids);
      if v_total>0 and v_accepted>=v_total then
        update public.cf_lobby_matches set status='choose_host',updated_at=v_now
        where id=v_match.id and status='found' returning * into v_match;
        if not found then
          select * into v_match from public.cf_lobby_matches where id=v_match.id;
        end if;
      end if;
    end if;

    select coalesce(jsonb_agg(public.cf_v9_user_json(x.uid) order by x.n),'[]'::jsonb)
      into v_players
    from unnest(v_match.participant_ids) with ordinality as x(uid,n);
    select coalesce(jsonb_agg(public.cf_v9_user_json(x.uid) order by x.n),'[]'::jsonb)
      into v_team_a
    from unnest(v_match.team_a_ids) with ordinality as x(uid,n);
    select coalesce(jsonb_agg(public.cf_v9_user_json(x.uid) order by x.n),'[]'::jsonb)
      into v_team_b
    from unnest(v_match.team_b_ids) with ordinality as x(uid,n);
    select count(*) into v_accepted
    from unnest(v_match.participant_ids) as x(uid)
    where x.uid=any(v_match.accepted_by);

    return jsonb_build_object(
      'lobby_id',v_lobby,'server_now',v_now,'queue',null,
      'match',jsonb_build_object(
        'id',v_match.id,'lobby_id',v_match.lobby_id,'started_by',v_match.started_by,
        'participant_ids',to_jsonb(v_match.participant_ids),
        'team_a_ids',to_jsonb(v_match.team_a_ids),'team_b_ids',to_jsonb(v_match.team_b_ids),
        'team_a',v_team_a,'team_b',v_team_b,'players',v_players,
        'mode',v_match.mode,'map_name',v_match.map_name,'status',v_match.status,
        'started_at',v_match.started_at,'found_at',v_match.found_at,'expires_at',v_match.expires_at,
        'accepted_by',to_jsonb(v_match.accepted_by),'accepted_count',v_accepted,
        'total_count',cardinality(v_match.participant_ids),
        'admin_nickname',v_match.admin_nickname,'room_code',v_match.room_code,
        'cancel_reason',v_match.cancel_reason,'host_choice',v_match.host_choice,
        'room_host_id',v_match.room_host_id,'room_host_nickname',v_match.room_host_nickname,
        'result_screenshot_url',v_match.result_screenshot_url,
        'result_submitted_by',v_match.result_submitted_by,
        'result_submitted_at',v_match.result_submitted_at,
        'result_score',v_match.result_score,'winner_team',v_match.winner_team,
        'result_reviewed_by',v_match.result_reviewed_by,'result_reviewed_at',v_match.result_reviewed_at
      )
    );
  end if;

  if v_lobby is not null then
    select * into v_queue from public.cf_matchmaking_queue q
    where q.lobby_id=v_lobby and q.queue_status='queued'
    order by q.queued_at desc limit 1;
    if found then
      select count(*) into v_queue_count
      from public.cf_matchmaking_queue q
      where q.mode=v_queue.mode and q.queue_status='queued';
      return jsonb_build_object(
        'lobby_id',v_lobby,'server_now',v_now,'match',null,
        'queue',jsonb_build_object(
          'id',v_queue.id,'mode',v_queue.mode,'map_name',v_queue.map_name,
          'queued_at',v_queue.queued_at,'party_count',cardinality(v_queue.party_ids),
          'waiting_parties',v_queue_count
        )
      );
    end if;
  end if;

  -- Return the most recently completed/failed match as a quiet status card.
  select * into v_match from public.cf_lobby_matches m
  where v_uid=any(m.participant_ids)
    and m.status in ('done','cancelled')
    and m.updated_at>v_now-interval '7 days'
  order by m.updated_at desc limit 1;
  if found then
    select coalesce(jsonb_agg(public.cf_v9_user_json(x.uid) order by x.n),'[]'::jsonb)
      into v_players from unnest(v_match.participant_ids) with ordinality as x(uid,n);
    select coalesce(jsonb_agg(public.cf_v9_user_json(x.uid) order by x.n),'[]'::jsonb)
      into v_team_a from unnest(v_match.team_a_ids) with ordinality as x(uid,n);
    select coalesce(jsonb_agg(public.cf_v9_user_json(x.uid) order by x.n),'[]'::jsonb)
      into v_team_b from unnest(v_match.team_b_ids) with ordinality as x(uid,n);
    return jsonb_build_object('lobby_id',v_lobby,'server_now',v_now,'queue',null,
      'match',jsonb_build_object(
        'id',v_match.id,'lobby_id',v_match.lobby_id,'participant_ids',to_jsonb(v_match.participant_ids),
        'team_a_ids',to_jsonb(v_match.team_a_ids),'team_b_ids',to_jsonb(v_match.team_b_ids),
        'team_a',v_team_a,'team_b',v_team_b,'players',v_players,
        'mode',v_match.mode,'map_name',v_match.map_name,'status',v_match.status,
        'started_at',v_match.started_at,'found_at',v_match.found_at,'expires_at',v_match.expires_at,
        'accepted_by',to_jsonb(v_match.accepted_by),'accepted_count',cardinality(v_match.accepted_by),
        'total_count',cardinality(v_match.participant_ids),'admin_nickname',v_match.admin_nickname,
        'room_code',v_match.room_code,'cancel_reason',v_match.cancel_reason,
        'host_choice',v_match.host_choice,'room_host_id',v_match.room_host_id,
        'room_host_nickname',v_match.room_host_nickname,'result_screenshot_url',v_match.result_screenshot_url,
        'result_submitted_by',v_match.result_submitted_by,'result_submitted_at',v_match.result_submitted_at,
        'result_score',v_match.result_score,'winner_team',v_match.winner_team,
        'result_reviewed_by',v_match.result_reviewed_by,'result_reviewed_at',v_match.result_reviewed_at
      ));
  end if;

  return jsonb_build_object('lobby_id',v_lobby,'server_now',v_now,'queue',null,'match',null);
end;
$$;

-- ==================== Included source: 14_v9_matchmaking_results_p5.sql ====================
-- LX FACEIT, шаг 14: запуск матча: поиск, команды, хост, результаты (часть 5 из 7)
-- Вставь целиком в SQL Editor -> Run. Запускай строго по номерам.
-- Join the matchmaking queue with the entire current lobby as one indivisible party.
-- A solo queue auto-creates a one-person lobby so solo players can fill matches.
create or replace function public.cf_lobby_match_start(p_mode text,p_map text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_uid uuid:=auth.uid();
  v_lobby uuid;
  v_owner uuid;
  v_ids uuid[];
  v_count integer;
  v_team_size integer;
  v_active uuid;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  if p_mode not in ('ranked','duo') then raise exception 'Недопустимый режим'; end if;
  if p_map not in ('Mirage','Dust2','Vertigo','Inferno') then raise exception 'Недопустимая карта'; end if;
  v_team_size := case when p_mode='duo' then 2 else 5 end;

  perform pg_advisory_xact_lock(hashtext('cf:v9:queue-user:'||v_uid::text));
  select lm.lobby_id,l.owner_id into v_lobby,v_owner
  from public.lobby_members lm join public.lobbies l on l.id=lm.lobby_id
  where lm.user_id=v_uid;
  if v_lobby is null then
    insert into public.lobbies(owner_id) values(v_uid) returning id into v_lobby;
    insert into public.lobby_members(lobby_id,user_id) values(v_lobby,v_uid);
  end if;

  select m.id into v_active from public.cf_lobby_matches m
  where v_uid=any(m.participant_ids) and m.status not in ('done','cancelled')
  order by m.created_at desc limit 1;
  if v_active is not null then return public.cf_lobby_match_state(); end if;

  select array_agg(user_id order by joined_at),count(*) into v_ids,v_count
  from public.lobby_members where lobby_id=v_lobby;
  if coalesce(v_count,0)>v_team_size then
    raise exception 'В режиме % можно сохранить в одной группе максимум % игроков. Разделите лобби или выберите 5×5.',p_mode,v_team_size;
  end if;

  -- A whole friend party must fit one team. Do not silently split friends across teams.
  if exists(select 1 from public.cf_matchmaking_queue q where q.lobby_id=v_lobby and q.queue_status='queued') then
    return public.cf_lobby_match_state();
  end if;

  insert into public.cf_matchmaking_queue(lobby_id,party_ids,mode,map_name)
  values(v_lobby,v_ids,p_mode,p_map);
  perform public.cf_matchmaking_try_form(p_mode);
  return public.cf_lobby_match_state();
end;
$$;

create or replace function public.cf_lobby_match_respond(p_accept boolean)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_uid uuid:=auth.uid();
  v_match public.cf_lobby_matches%rowtype;
  v_now timestamptz:=clock_timestamp();
  v_accepted integer;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select * into v_match from public.cf_lobby_matches m
  where v_uid=any(m.participant_ids) and m.status='found'
  order by m.created_at desc limit 1 for update;
  if not found then raise exception 'Найденный матч уже недоступен'; end if;
  if v_match.expires_at<=v_now then
    update public.cf_lobby_matches set status='cancelled',cancel_reason='Время принятия матча истекло',updated_at=v_now where id=v_match.id;
    return public.cf_lobby_match_state();
  end if;
  if not p_accept then
    update public.cf_lobby_matches set status='cancelled',cancel_reason='Один из игроков отклонил матч',updated_at=v_now where id=v_match.id;
    return public.cf_lobby_match_state();
  end if;
  update public.cf_lobby_matches
  set accepted_by=case when v_uid=any(accepted_by) then accepted_by else array_append(accepted_by,v_uid) end,
      updated_at=v_now
  where id=v_match.id returning * into v_match;
  select count(*) into v_accepted from unnest(v_match.participant_ids) x(uid) where x.uid=any(v_match.accepted_by);
  if v_accepted=cardinality(v_match.participant_ids) then
    update public.cf_lobby_matches set status='choose_host',updated_at=v_now where id=v_match.id;
  end if;
  return public.cf_lobby_match_state();
end;
$$;

create or replace function public.cf_lobby_match_choose_host(p_choice text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_uid uuid:=auth.uid();
  v_match public.cf_lobby_matches%rowtype;
  v_host uuid;
  v_host_nick text;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  if p_choice not in ('admin','player') then raise exception 'Выбери администратора или игрока'; end if;
  select * into v_match from public.cf_lobby_matches m
  where v_uid=any(m.participant_ids) and m.status='choose_host'
  order by m.created_at desc limit 1 for update;
  if not found then raise exception 'Выбор организатора уже закрыт'; end if;
  if p_choice='admin' then
    update public.cf_lobby_matches set host_choice='admin',status='pending_admin',updated_at=clock_timestamp()
    where id=v_match.id;
  else
    select uid into v_host
    from unnest(v_match.participant_ids) as x(uid)
    order by random() limit 1;
    select nickname into v_host_nick from public.profiles where id=v_host;
    update public.cf_lobby_matches
    set host_choice='player',room_host_id=v_host,
        room_host_nickname=coalesce(v_host_nick,'Игрок'),status='host_selected',updated_at=clock_timestamp()
    where id=v_match.id;
  end if;
  return public.cf_lobby_match_state();
end;
$$;

create or replace function public.cf_lobby_match_player_publish_code(p_code text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_uid uuid:=auth.uid();
  v_match public.cf_lobby_matches%rowtype;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  if nullif(trim(p_code),'') is null or char_length(trim(p_code))>64 then
    raise exception 'Введи код комнаты длиной до 64 символов';
  end if;
  select * into v_match from public.cf_lobby_matches m
  where v_uid=m.room_host_id and m.status='host_selected'
  order by m.created_at desc limit 1 for update;
  if not found then raise exception 'Ты не выбран организатором этой комнаты'; end if;
  update public.cf_lobby_matches
  set status='room',room_code=trim(p_code),admin_nickname=room_host_nickname,updated_at=clock_timestamp()
  where id=v_match.id;
  return public.cf_lobby_match_state();
end;
$$;

-- ==================== Included source: 15_v9_matchmaking_results_p6.sql ====================
-- LX FACEIT, шаг 15: запуск матча: поиск, команды, хост, результаты (часть 6 из 7)
-- Вставь целиком в SQL Editor -> Run. Запускай строго по номерам.
create or replace function public.cf_lobby_match_cancel()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_uid uuid:=auth.uid(); v_lobby uuid; v_cancelled integer:=0;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select lobby_id into v_lobby from public.lobby_members where user_id=v_uid;
  if v_lobby is not null then
    update public.cf_matchmaking_queue set queue_status='cancelled',updated_at=clock_timestamp()
    where lobby_id=v_lobby and queue_status='queued';
  end if;
  update public.cf_lobby_matches
  set status='cancelled',cancel_reason='Матч отменён игроком',updated_at=clock_timestamp()
  where v_uid=any(participant_ids)
    and status in ('searching','found','choose_host','host_selected','pending_admin','taken','room','joined');
  get diagnostics v_cancelled = row_count;
  if v_cancelled=0 and exists (
    select 1 from public.cf_lobby_matches
    where v_uid=any(participant_ids) and status in ('live','result_pending')
  ) then
    raise exception 'Матч уже начался. Обратись к администратору для отмены';
  end if;
  return public.cf_lobby_match_state();
end;
$$;

-- Submit Discord proof. Only participant-authored HTTPS Discord links are accepted.
create or replace function public.cf_lobby_match_submit_result(
  p_match uuid,p_screenshot_url text,p_score text default null
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_uid uuid:=auth.uid(); v_url text; v_match public.cf_lobby_matches%rowtype;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  v_url:=trim(coalesce(p_screenshot_url,''));
  if char_length(v_url)>1500 or v_url !~* '^https://(cdn\.discordapp\.com|media\.discordapp\.net|discord\.com|discordapp\.com)/' then
    raise exception 'Вставь HTTPS-ссылку на скриншот или сообщение Discord';
  end if;
  if p_score is not null and char_length(trim(p_score))>20 then raise exception 'Счёт слишком длинный'; end if;
  select * into v_match from public.cf_lobby_matches m where m.id=p_match for update;
  if not found or not (v_uid=any(v_match.participant_ids)) then raise exception 'Матч не найден или ты не его участник'; end if;
  if v_match.status not in ('live','result_pending') then raise exception 'Отправить итоги можно после начала матча'; end if;
  if v_match.status='result_pending' and v_match.result_submitted_by<>v_uid then
    raise exception 'Другой участник уже отправил результат. Дождись проверки администратора';
  end if;
  update public.cf_lobby_matches
  set result_screenshot_url=v_url,result_submitted_by=v_uid,
      result_submitted_at=clock_timestamp(),result_score=coalesce(nullif(trim(p_score),''),''),
      status='result_pending',updated_at=clock_timestamp()
  where id=p_match;
  return public.cf_lobby_match_state();
end;
$$;

-- An admin chooses the winner. Elo is applied exactly once inside the same locked transaction.
create or replace function public.cf_lobby_match_review_result(
  p_match uuid,p_winner text,p_score text default null
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_uid uuid:=auth.uid(); v_role text; v_match public.cf_lobby_matches%rowtype;
  v_score text:=trim(coalesce(p_score,''));
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select role into v_role from public.profiles where id=v_uid;
  if coalesce(v_role,'player') not in ('admin','founder') then raise exception 'Недостаточно прав'; end if;
  if p_winner not in ('A','B') then raise exception 'Выбери победившую команду'; end if;
  if char_length(v_score)>20 then raise exception 'Счёт слишком длинный'; end if;
  select * into v_match from public.cf_lobby_matches where id=p_match for update;
  if not found then raise exception 'Матч не найден'; end if;
  if v_match.status<>'result_pending' then raise exception 'Этот результат уже проверен или ещё не отправлен'; end if;
  if nullif(v_match.result_screenshot_url,'') is null then raise exception 'У матча нет ссылки на доказательство'; end if;

  update public.profiles p
  set elo=greatest(0,coalesce(p.elo,1000)+case
      when p_winner='A' and p.id=any(v_match.team_a_ids) then 25
      when p_winner='A' and p.id=any(v_match.team_b_ids) then -25
      when p_winner='B' and p.id=any(v_match.team_b_ids) then 25
      when p_winner='B' and p.id=any(v_match.team_a_ids) then -25
      else 0 end)
  where p.id=any(v_match.participant_ids);

  update public.cf_lobby_matches
  set status='done',winner_team=p_winner,
      result_score=coalesce(nullif(v_score,''),result_score),
      result_reviewed_by=v_uid,result_reviewed_at=clock_timestamp(),updated_at=clock_timestamp()
  where id=p_match;
  return public.cf_lobby_match_admin_list();
end;
$$;

-- Admin list: active matches plus result submissions from the previous 7 days.
create or replace function public.cf_lobby_match_admin_list()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_uid uuid:=auth.uid(); v_role text; v_result jsonb;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select role into v_role from public.profiles where id=v_uid;
  if coalesce(v_role,'player') not in ('admin','founder') then raise exception 'Недостаточно прав'; end if;
  select coalesce(jsonb_agg(row_data order by created_at desc),'[]'::jsonb) into v_result
  from (
    select m.created_at,
      jsonb_build_object(
        'id',m.id,'lobby_id',m.lobby_id,'mode',m.mode,'map_name',m.map_name,
        'status',m.status,'started_at',m.started_at,'found_at',m.found_at,
        'created_at',m.created_at,'admin_nickname',m.admin_nickname,
        'room_code',m.room_code,'cancel_reason',m.cancel_reason,
        'team_a',(select coalesce(jsonb_agg(public.cf_v9_user_json(x.uid) order by x.n),'[]'::jsonb) from unnest(m.team_a_ids) with ordinality x(uid,n)),
        'team_b',(select coalesce(jsonb_agg(public.cf_v9_user_json(x.uid) order by x.n),'[]'::jsonb) from unnest(m.team_b_ids) with ordinality x(uid,n)),
        'players',(select coalesce(jsonb_agg(public.cf_v9_user_json(x.uid) order by x.n),'[]'::jsonb) from unnest(m.participant_ids) with ordinality x(uid,n)),
        'host_choice',m.host_choice,'room_host_id',m.room_host_id,
        'room_host_nickname',m.room_host_nickname,'admin_id',m.admin_id,'result_screenshot_url',m.result_screenshot_url,
        'result_submitted_by',m.result_submitted_by,'result_submitted_at',m.result_submitted_at,
        'result_score',m.result_score,'winner_team',m.winner_team,
        'result_reviewed_by',m.result_reviewed_by,'result_reviewed_at',m.result_reviewed_at
      ) as row_data
    from public.cf_lobby_matches m
    where m.status not in ('done','cancelled')
       or m.updated_at>clock_timestamp()-interval '7 days'
  ) q;
  return v_result;
end;
$$;

-- ==================== Included source: 16_v9_matchmaking_results_p7.sql ====================
-- LX FACEIT, шаг 16: запуск матча: поиск, команды, хост, результаты (часть 7 из 7)
-- Вставь целиком в SQL Editor -> Run. Запускай строго по номерам.
-- Replace the original admin-action signature with equivalent safe transitions.
create or replace function public.cf_lobby_match_admin_action(p_match uuid,p_action text,p_code text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_uid uuid:=auth.uid(); v_role text; v_match public.cf_lobby_matches%rowtype; v_nick text;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select role,nickname into v_role,v_nick from public.profiles where id=v_uid;
  if coalesce(v_role,'player') not in ('admin','founder') then raise exception 'Недостаточно прав'; end if;
  select * into v_match from public.cf_lobby_matches where id=p_match for update;
  if not found then raise exception 'Матч не найден'; end if;

  if p_action='take' then
    if v_match.status<>'pending_admin' then raise exception 'Этот матч не ожидает администратора'; end if;
    update public.cf_lobby_matches set status='taken',admin_id=v_uid,admin_nickname=v_nick,updated_at=clock_timestamp()
      where id=p_match and status='pending_admin' and admin_id is null;
    if not found then raise exception 'Уже выполняется другим администратором'; end if;
    v_match.status:='taken';v_match.admin_id:=v_uid;v_match.admin_nickname:=v_nick;
  elsif p_action='publish' then
    if v_match.admin_id<>v_uid then raise exception 'Матч ведёт другой администратор'; end if;
    if v_match.status<>'taken' then raise exception 'Сначала возьми матч'; end if;
    if nullif(trim(p_code),'') is null or char_length(trim(p_code))>64 then raise exception 'Введи код комнаты до 64 символов'; end if;
    update public.cf_lobby_matches set status='room',room_code=trim(p_code),updated_at=clock_timestamp() where id=p_match;
    v_match.status:='room';v_match.room_code:=trim(p_code);
  elsif p_action='joined' then
    if v_match.status<>'room' then raise exception 'Сначала опубликуй код комнаты'; end if;
    if v_match.admin_id is not null and v_match.admin_id<>v_uid then
      raise exception 'Матч ведёт другой администратор';
    end if;
    update public.cf_lobby_matches
      set status='joined',admin_id=coalesce(admin_id,v_uid),
          admin_nickname=case when admin_id is null then v_nick else admin_nickname end,
          updated_at=clock_timestamp()
    where id=p_match;
    v_match.status:='joined';if v_match.admin_id is null then v_match.admin_id:=v_uid;v_match.admin_nickname:=v_nick;end if;
  elsif p_action='live' then
    if v_match.admin_id is null or v_match.admin_id<>v_uid then raise exception 'Сначала возьми матч на сопровождение'; end if;
    if v_match.status<>'joined' then raise exception 'Сначала подтверди вход игроков'; end if;
    update public.cf_lobby_matches set status='live',updated_at=clock_timestamp() where id=p_match;
    v_match.status:='live';
  elsif p_action='cancel' then
    if v_match.status in ('done','cancelled') then raise exception 'Матч уже завершён'; end if;
    update public.cf_lobby_matches set status='cancelled',cancel_reason='Отменено администратором',updated_at=clock_timestamp()
      where id=p_match and status not in ('done','cancelled');
    if not found then raise exception 'Матч уже завершён'; end if;
    v_match.status:='cancelled';v_match.cancel_reason:='Отменено администратором';
  else
    raise exception 'Неизвестное действие администратора';
  end if;
  return jsonb_build_object('ok',true,'match_id',v_match.id,'status',v_match.status,
    'admin_nickname',v_match.admin_nickname,'room_code',v_match.room_code,
    'cancel_reason',v_match.cancel_reason);
end;
$$;

-- No client can access these tables directly; all writes go through validated RPCs.
revoke all on public.cf_matchmaking_queue from anon,authenticated;
revoke all on function public.cf_lobby_match_state() from public,anon;
revoke all on function public.cf_lobby_match_start(text,text) from public,anon;
revoke all on function public.cf_lobby_match_respond(boolean) from public,anon;
revoke all on function public.cf_lobby_match_choose_host(text) from public,anon;
revoke all on function public.cf_lobby_match_player_publish_code(text) from public,anon;
revoke all on function public.cf_lobby_match_cancel() from public,anon;
revoke all on function public.cf_lobby_match_submit_result(uuid,text,text) from public,anon;
revoke all on function public.cf_lobby_match_review_result(uuid,text,text) from public,anon;
revoke all on function public.cf_lobby_match_admin_list() from public,anon;
revoke all on function public.cf_lobby_match_admin_action(uuid,text,text) from public,anon;
grant execute on function public.cf_lobby_match_state() to authenticated;
grant execute on function public.cf_lobby_match_start(text,text) to authenticated;
grant execute on function public.cf_lobby_match_respond(boolean) to authenticated;
grant execute on function public.cf_lobby_match_choose_host(text) to authenticated;
grant execute on function public.cf_lobby_match_player_publish_code(text) to authenticated;
grant execute on function public.cf_lobby_match_cancel() to authenticated;
grant execute on function public.cf_lobby_match_submit_result(uuid,text,text) to authenticated;
grant execute on function public.cf_lobby_match_review_result(uuid,text,text) to authenticated;
grant execute on function public.cf_lobby_match_admin_list() to authenticated;
grant execute on function public.cf_lobby_match_admin_action(uuid,text,text) to authenticated;

select 'LX FACEIT v9 matchmaking + results migration installed' as result;

-- ==================== Included source: 17_setup_messenger_1_tables.sql ====================
-- LX FACEIT, шаг 17: мессенджер: таблицы
-- Вставь целиком в SQL Editor -> Run. Запускай строго по номерам.
-- LX FACEIT Мессенджер, ЧАСТЬ 1 из 2: таблицы. Запускай первой. Можно повторно.
create table if not exists public.msgr_chats (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('channel','group')),
  title text not null check (char_length(title) between 2 and 40),
  about text not null default '' check (char_length(about) <= 200),
  avatar text not null default '' check (char_length(avatar) <= 60000),
  owner_id uuid not null references auth.users(id) on delete cascade,
  official boolean not null default false,
  created_at timestamptz not null default now()
);
create table if not exists public.msgr_members (
  chat_id uuid not null references public.msgr_chats(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (chat_id, user_id)
);
create table if not exists public.msgr_messages (
  id bigserial primary key,
  chat_id uuid not null references public.msgr_chats(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now()
);
create index if not exists msgr_messages_chat_idx on public.msgr_messages (chat_id, id desc);
create index if not exists msgr_members_user_idx on public.msgr_members (user_id);
alter table public.msgr_chats enable row level security;
alter table public.msgr_members enable row level security;
alter table public.msgr_messages enable row level security;
revoke all on public.msgr_chats, public.msgr_members, public.msgr_messages from anon, authenticated;
-- Политик нет намеренно: доступ только через функции из части 2.

-- ==================== Included source: 18_setup_messenger_2_functions.sql ====================
-- LX FACEIT, шаг 18: мессенджер: функции
-- Вставь целиком в SQL Editor -> Run. Запускай строго по номерам.
-- LX FACEIT Мессенджер, ЧАСТЬ 2 из 2: функции. Запускай после части 1. Можно повторно.
create or replace function public.msgr_ensure_official()
returns void language plpgsql security definer set search_path = public as $$
declare v_f uuid;
begin
  if exists (select 1 from public.msgr_chats where official) then return; end if;
  select id into v_f from public.profiles where role = 'founder' order by id limit 1;
  if v_f is null then return; end if;
  insert into public.msgr_chats (kind, title, about, owner_id, official)
    values ('channel', 'LX FACEIT', 'Официальный канал LX FACEIT: новости и обновления', v_f, true);
end $$;

create or replace function public.msgr_list(p_q text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_role text; v_res jsonb; v_q text := left(coalesce(trim(p_q), ''), 40);
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select role into v_role from public.profiles where id = v_uid;
  perform public.msgr_ensure_official();
  insert into public.msgr_members (chat_id, user_id) select id, v_uid from public.msgr_chats where official on conflict do nothing;
  select coalesce(jsonb_agg(s.x order by s.sort_key desc), '[]'::jsonb) into v_res from (
    select jsonb_build_object(
        'id', c.id, 'kind', c.kind, 'title', c.title, 'about', c.about, 'avatar', c.avatar, 'official', c.official,
        'members', (select count(*) from public.msgr_members m where m.chat_id = c.id),
        'joined', exists (select 1 from public.msgr_members m where m.chat_id = c.id and m.user_id = v_uid),
        'is_owner', c.owner_id = v_uid,
        'last_body', (select left(b.body, 80) from public.msgr_messages b where b.chat_id = c.id order by b.id desc limit 1),
        'last_at', (select b.created_at from public.msgr_messages b where b.chat_id = c.id order by b.id desc limit 1)
      ) as x,
      coalesce((select max(b.created_at) from public.msgr_messages b where b.chat_id = c.id), c.created_at) as sort_key
    from public.msgr_chats c
    where (v_q = '' and (c.official or exists (select 1 from public.msgr_members m where m.chat_id = c.id and m.user_id = v_uid)))
       or (v_q <> '' and c.title ilike '%' || replace(replace(v_q, '%', ''), '_', '') || '%')
    order by 2 desc limit 50
  ) s;
  return v_res;
end $$;

create or replace function public.msgr_create(p_kind text, p_title text, p_about text default '')
returns uuid language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_id uuid; v_title text := trim(coalesce(p_title, ''));
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  if p_kind not in ('channel','group') then raise exception 'Неверный тип'; end if;
  if char_length(v_title) < 2 or char_length(v_title) > 40 then raise exception 'Название: от 2 до 40 символов'; end if;
  if lower(v_title) in ('cf faceit', 'cf faceit official') then raise exception 'Это название зарезервировано'; end if;
  if (select count(*) from public.msgr_chats where owner_id = v_uid) >= 10 then raise exception 'Можно создать не больше 10 чатов'; end if;
  insert into public.msgr_chats (kind, title, about, owner_id) values (p_kind, v_title, left(coalesce(p_about, ''), 200), v_uid) returning id into v_id;
  insert into public.msgr_members (chat_id, user_id) values (v_id, v_uid);
  return v_id;
end $$;

create or replace function public.msgr_join(p_chat uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Нужно войти в аккаунт'; end if;
  if not exists (select 1 from public.msgr_chats where id = p_chat) then raise exception 'Чат не найден'; end if;
  insert into public.msgr_members (chat_id, user_id) values (p_chat, auth.uid()) on conflict do nothing;
end $$;

create or replace function public.msgr_leave(p_chat uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Нужно войти в аккаунт'; end if;
  if exists (select 1 from public.msgr_chats where id = p_chat and owner_id = auth.uid()) then
    raise exception 'Владелец не может выйти из своего чата'; end if;
  if exists (select 1 from public.msgr_chats where id = p_chat and official) then
    raise exception 'Подписка на официальный канал обязательна'; end if;
  delete from public.msgr_members where chat_id = p_chat and user_id = auth.uid();
end $$;

create or replace function public.msgr_messages(p_chat uuid, p_after bigint default 0)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_chat public.msgr_chats; v_res jsonb;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select * into v_chat from public.msgr_chats where id = p_chat;
  if not found then raise exception 'Чат не найден'; end if;
  if v_chat.kind = 'group' and not exists (select 1 from public.msgr_members where chat_id = p_chat and user_id = v_uid) then
    raise exception 'Вступи в группу, чтобы читать сообщения'; end if;
  select coalesce(jsonb_agg(j order by (j->>'id')::bigint), '[]'::jsonb) into v_res from (
    select jsonb_build_object('id', m.id, 'body', m.body, 'created_at', m.created_at, 'mine', m.user_id = v_uid,
      'user', public.cf_lobby_user_json(m.user_id)) as j
    from public.msgr_messages m where m.chat_id = p_chat and m.id > coalesce(p_after, 0)
    order by m.id desc limit 60) s;
  return v_res;
end $$;

create or replace function public.msgr_send(p_chat uuid, p_body text)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_chat public.msgr_chats; v_body text := trim(coalesce(p_body, '')); v_id bigint;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select * into v_chat from public.msgr_chats where id = p_chat;
  if not found then raise exception 'Чат не найден'; end if;
  if v_chat.kind = 'channel' and v_chat.owner_id <> v_uid then raise exception 'В канале пишет только владелец'; end if;
  if not exists (select 1 from public.msgr_members where chat_id = p_chat and user_id = v_uid) then raise exception 'Сначала вступи в чат'; end if;
  if v_body = '' or char_length(v_body) > 1000 then raise exception 'Сообщение: от 1 до 1000 символов'; end if;
  if exists (select 1 from public.msgr_messages where user_id = v_uid and created_at > now() - interval '700 milliseconds') then
    raise exception 'Слишком часто'; end if;
  insert into public.msgr_messages (chat_id, user_id, body) values (p_chat, v_uid, v_body) returning id into v_id;
  return v_id;
end $$;

create or replace function public.msgr_set_avatar(p_chat uuid, p_avatar text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Нужно войти в аккаунт'; end if;
  if p_avatar is null or (p_avatar <> '' and p_avatar not like 'data:image/%') or char_length(p_avatar) > 60000 then
    raise exception 'Неверная картинка'; end if;
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'founder') then
    raise exception 'Аватарку меняет только основатель'; end if;
  update public.msgr_chats set avatar = p_avatar where id = p_chat and owner_id = auth.uid();
  if not found then raise exception 'Чат не найден'; end if;
end $$;

-- Автоподписка: новые игроки подписываются на официальный канал сами
create or replace function public.msgr_autosub()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.msgr_members (chat_id, user_id) select id, new.id from public.msgr_chats where official on conflict do nothing;
  return new;
end $$;
drop trigger if exists msgr_autosub_trg on public.profiles;
create trigger msgr_autosub_trg after insert on public.profiles for each row execute function public.msgr_autosub();

-- Создать канал сейчас и подписать всех, кто уже зарегистрирован
select public.msgr_ensure_official();
insert into public.msgr_members (chat_id, user_id)
  select c.id, p.id from public.msgr_chats c cross join public.profiles p where c.official on conflict do nothing;

revoke all on function public.msgr_ensure_official(), public.msgr_list(text), public.msgr_create(text,text,text), public.msgr_join(uuid), public.msgr_leave(uuid),
  public.msgr_messages(uuid,bigint), public.msgr_send(uuid,text), public.msgr_set_avatar(uuid,text) from public, anon;
grant execute on function public.msgr_list(text), public.msgr_create(text,text,text), public.msgr_join(uuid), public.msgr_leave(uuid),
  public.msgr_messages(uuid,bigint), public.msgr_send(uuid,text), public.msgr_set_avatar(uuid,text) to authenticated;

-- ==================== Included source: 20_telegram_bot.sql ====================
-- LX FACEIT: привязка Telegram-аккаунтов (для бота). Запусти один раз в Supabase SQL Editor.
create table if not exists public.tg_accounts (
  tg_id bigint primary key,
  user_id uuid not null unique references auth.users(id) on delete cascade,
  tg_username text,
  created_at timestamptz not null default now()
);
alter table public.tg_accounts enable row level security;
revoke all on public.tg_accounts from anon, authenticated;
-- Политик нет: к таблице имеет доступ только бот через service_role.

-- ==================== Included source: 21_auto_match_live.sql ====================
-- LX FACEIT, шаг 21: матч стартует САМ, когда выдан код комнаты, и идёт 30-40 минут.
-- Запускай после 01-20. Можно повторно.
alter table public.cf_lobby_matches
  add column if not exists live_started_at timestamptz,
  add column if not exists play_ends_at timestamptz;

create or replace function public.cf_match_auto_live()
returns trigger language plpgsql as $$
begin
  if new.status = 'room' and old.status is distinct from 'room' then
    new.status := 'live';
    new.live_started_at := clock_timestamp();
    new.play_ends_at := clock_timestamp() + make_interval(secs => 1800 + floor(random() * 601)::int);
  end if;
  return new;
end $$;
drop trigger if exists cf_match_auto_live_trg on public.cf_lobby_matches;
create trigger cf_match_auto_live_trg before update of status on public.cf_lobby_matches
  for each row execute function public.cf_match_auto_live();

-- Состояние матча отдаёт время окончания игры
do $$
declare d text;
begin
  d := pg_get_functiondef('public.cf_lobby_match_state()'::regprocedure);
  if position('play_ends_at' in d) = 0 then
    d := replace(d, '''result_reviewed_at'',v_match.result_reviewed_at',
      '''result_reviewed_at'',v_match.result_reviewed_at,''play_ends_at'',v_match.play_ends_at,''live_started_at'',v_match.live_started_at');
    execute d;
  end if;
end $$;

-- Итоги можно отправить только когда время матча вышло
do $$
declare d text;
begin
  d := pg_get_functiondef('public.cf_lobby_match_submit_result(uuid,text,text)'::regprocedure);
  if position('Матч ещё идёт' in d) = 0 then
    d := replace(d, 'if v_match.status=''result_pending'' and v_match.result_submitted_by<>v_uid then',
      'if v_match.status=''live'' and v_match.play_ends_at is not null and v_match.play_ends_at > clock_timestamp() then raise exception ''Матч ещё идёт. Итоги можно отправить, когда время матча выйдет''; end if;
  if v_match.status=''result_pending'' and v_match.result_submitted_by<>v_uid then');
    execute d;
  end if;
end $$;

-- ==================== Included source: 22_no_visible_lobby.sql ====================
-- LX FACEIT, шаг 22: при запуске матча лобби больше не появляется у игрока.
-- Для очереди нужна служебная запись, она помечается is_auto и скрыта от игрока.
-- Запускай после 01-21. Можно повторно.
alter table public.lobbies add column if not exists is_auto boolean not null default false;

do $$
declare d text;
begin
  d := pg_get_functiondef('public.cf_lobby_match_start(text,text)'::regprocedure);
  if position('is_auto' in d) = 0 then
    d := replace(d, 'insert into public.lobbies(owner_id) values(v_uid) returning id into v_lobby;',
                    'insert into public.lobbies(owner_id,is_auto) values(v_uid,true) returning id into v_lobby;');
    execute d;
  end if;
end $$;

do $$
declare d text;
begin
  d := pg_get_functiondef('public.lobby_invite(uuid)'::regprocedure);
  if position('is_auto' in d) = 0 then
    d := replace(d, '  if v_owner <> v_uid then raise exception ''Приглашать может только хозяин лобби''; end if;',
                    '  if v_owner <> v_uid then raise exception ''Приглашать может только хозяин лобби''; end if;
  update public.lobbies set is_auto = false where id = v_lobby and is_auto;');
    execute d;
  end if;
end $$;

do $$
declare d text;
begin
  d := pg_get_functiondef('public.lobby_state()'::regprocedure);
  if position('is_auto' in d) = 0 then
    d := replace(d, '''is_owner'', v_owner = v_uid, ''members''',
                    '''is_owner'', v_owner = v_uid, ''is_auto'', (select l2.is_auto from public.lobbies l2 where l2.id = v_lobby), ''members''');
    execute d;
  end if;
end $$;

-- ==================== Included source: 23_screenshot_bot_support.sql ====================
-- LX FACEIT, шаг 23: скриншот файлом + авто-результат от бота + чат «Поддержка».
-- Запускай после 01-22. Вставь целиком в SQL Editor -> Run. Можно повторно.

-- ===== 1. Хранилище скриншотов (публичное чтение, загрузка только в свою папку) =====
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('match-proofs','match-proofs',true,5242880,array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public=true, file_size_limit=5242880, allowed_mime_types=excluded.allowed_mime_types;
drop policy if exists cf_proofs_insert on storage.objects;
create policy cf_proofs_insert on storage.objects for insert to authenticated
  with check (bucket_id='match-proofs' and (storage.foldername(name))[1]=auth.uid()::text);

-- ===== 2. Поля бота в матче =====
alter table public.cf_lobby_matches
  add column if not exists bot_ct_score int,
  add column if not exists bot_t_score int,
  add column if not exists bot_winner text,
  add column if not exists result_auto boolean not null default false;

-- ===== 3. Общее применение результата (ELO ±25 ровно один раз) =====
create or replace function public.cf_apply_match_result(p_match uuid, p_winner text, p_score text, p_by uuid, p_auto boolean)
returns void language plpgsql security definer set search_path=public as $$
declare v_match public.cf_lobby_matches%rowtype;
begin
  select * into v_match from public.cf_lobby_matches where id=p_match for update;
  if not found or v_match.status<>'result_pending' then raise exception 'Результат уже обработан'; end if;
  update public.profiles p set elo=greatest(0,coalesce(p.elo,1000)+case
      when p_winner='A' and p.id=any(v_match.team_a_ids) then 25
      when p_winner='A' and p.id=any(v_match.team_b_ids) then -25
      when p_winner='B' and p.id=any(v_match.team_b_ids) then 25
      when p_winner='B' and p.id=any(v_match.team_a_ids) then -25
      else 0 end)
  where p.id=any(v_match.participant_ids);
  update public.cf_lobby_matches set status='done',winner_team=p_winner,
      result_score=coalesce(nullif(trim(coalesce(p_score,'')),''),result_score),
      result_reviewed_by=p_by,result_reviewed_at=clock_timestamp(),result_auto=p_auto,updated_at=clock_timestamp()
  where id=p_match;
end $$;
revoke all on function public.cf_apply_match_result(uuid,text,text,uuid,boolean) from public,anon,authenticated;

-- ===== 4. Отправка результата: файл из нашего хранилища + чтение счёта ботом =====
drop function if exists public.cf_lobby_match_submit_result(uuid,text,text);
create or replace function public.cf_lobby_match_submit_result(
  p_match uuid, p_screenshot_url text, p_score text default null,
  p_bot_ct int default null, p_bot_t int default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_uid uuid:=auth.uid(); v_url text; v_match public.cf_lobby_matches%rowtype;
        v_ok boolean:=false; v_win text; v_mine text; v_score text;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  v_url:=trim(coalesce(p_screenshot_url,''));
  if char_length(v_url)>1500 or v_url !~ ('^https://[a-z0-9]+\.supabase\.co/storage/v1/object/public/match-proofs/'||v_uid::text||'/') then
    raise exception 'Прикрепи скриншот файлом';
  end if;
  if p_score is not null and char_length(trim(p_score))>20 then raise exception 'Счёт слишком длинный'; end if;
  select * into v_match from public.cf_lobby_matches m where m.id=p_match for update;
  if not found or not (v_uid=any(v_match.participant_ids)) then raise exception 'Матч не найден или ты не его участник'; end if;
  if v_match.status not in ('live','result_pending') then raise exception 'Отправить итоги можно после начала матча'; end if;
  if v_match.status='result_pending' and v_match.result_submitted_by<>v_uid then
    raise exception 'Другой участник уже отправил результат. Дождись проверки';
  end if;
  v_ok := p_bot_ct is not null and p_bot_t is not null and p_bot_ct between 0 and 40 and p_bot_t between 0 and 40
          and p_bot_ct<>p_bot_t and greatest(p_bot_ct,p_bot_t)>=5;
  v_win := case when not v_ok then null when p_bot_ct>p_bot_t then 'A' else 'B' end;
  v_score := case when v_ok then p_bot_ct||':'||p_bot_t else coalesce(nullif(trim(p_score),''),'') end;
  update public.cf_lobby_matches
  set result_screenshot_url=v_url,result_submitted_by=v_uid,result_submitted_at=clock_timestamp(),
      result_score=v_score,bot_ct_score=case when v_ok then p_bot_ct end,bot_t_score=case when v_ok then p_bot_t end,
      bot_winner=v_win,status='result_pending',updated_at=clock_timestamp()
  where id=p_match;
  -- Автопринятие: бот уверенно прочитал счёт И отправитель сам в проигравшей команде
  -- (признавать своё поражение невыгодно). Если отправитель в выигравшей — подтверждает админ.
  v_mine := case when v_uid=any(v_match.team_a_ids) then 'A' when v_uid=any(v_match.team_b_ids) then 'B' end;
  if v_ok and v_mine is not null and v_mine<>v_win then
    perform public.cf_apply_match_result(p_match,v_win,v_score,null,true);
  end if;
  return public.cf_lobby_match_state();
end $$;
revoke all on function public.cf_lobby_match_submit_result(uuid,text,text,int,int) from public,anon;
grant execute on function public.cf_lobby_match_submit_result(uuid,text,text,int,int) to authenticated;

-- Админ-список: добавляем вывод бота
do $$
declare d text;
begin
  d := pg_get_functiondef('public.cf_lobby_match_admin_list()'::regprocedure);
  if position('bot_winner' in d)=0 then
    d := replace(d, '''result_score'',m.result_score,', '''result_score'',m.result_score,''bot_ct_score'',m.bot_ct_score,''bot_t_score'',m.bot_t_score,''bot_winner'',m.bot_winner,''result_auto'',m.result_auto,');
    execute d;
  end if;
end $$;

-- ===== 5. Чат «Поддержка» (бот на SQL) =====
alter table public.msgr_chats drop constraint if exists msgr_chats_kind_check;
alter table public.msgr_chats add constraint msgr_chats_kind_check check (kind in ('channel','group','support'));
alter table public.msgr_messages add column if not exists is_bot boolean not null default false;
create unique index if not exists msgr_support_one on public.msgr_chats (owner_id) where kind='support';

create or replace function public.msgr_support_reply(p_text text)
returns text
language plpgsql
immutable
as $support$
declare
  t text := replace(lower(coalesce(p_text, '')), 'ё', 'е');
begin
  t := regexp_replace(t, '[[:space:][:punct:]]+', ' ', 'g');
  t := trim(t);

  if t = '' then
    return 'Напиши вопрос — помогу с регистрацией, входом, поиском матча, таймером, результатом, ELO или турнирами.';
  elsif t ~ '(привет|здравств|добрый|хай|hello)' and char_length(t) < 60 then
    return 'Привет! Я бот поддержки LX FACEIT. Спроси про регистрацию, игровой ID, пароль, матч, таймер, скриншот результата, ELO или турнир.';
  elsif t ~ '(длина.*парол|парол.*длин|сколько.*символ.*парол|минимум.*парол)' then
    return 'Пароль должен содержать не менее 8 символов. Не используй пароль от других сайтов.';
  elsif t ~ '(забыл.*парол|forgot.*password|reset.*password|восстанов.*парол|сброс.*парол|парол.*(код|почт)|код.*(парол|восстанов)|invalid login credentials|user already registered|password)' then
    return 'Чтобы восстановить пароль, нажми «Забыл пароль» на экране входа, введи почту аккаунта и укажи 6-значный код из письма. Затем задай новый пароль длиной не менее 8 символов. Проверь папку «Спам»; если код не приходит, попробуй позже или напиши в поддержку.';
  elsif t ~ '(игров.{0,12}(id|айди|номер)|id.{0,12}игрок|айди|game id|игровой идентификатор|сколько цифр)' then
    return 'Игровой ID при регистрации — ровно 6 или 7 цифр. Он должен быть уникальным. Введи цифры без пробелов; начальные нули допустимы.';
  elsif t ~ '(регистрац|зарегистрир|создат.*аккаунт|новый аккаунт|уже зарегистрир|подтвержден.*почт)' then
    return 'Для регистрации укажи ник, почту, игровой ID из 6 или 7 цифр и пароль от 8 символов. Если сайт сообщает, что пользователь уже зарегистрирован, войди в существующий аккаунт или восстанови пароль по коду на почту.';
  elsif t ~ '(войти|вход|логин|не могу войти|не пускает|аккаунт)' then
    return 'Игрок входит по нику, игровому ID из 6 или 7 цифр и паролю. Если забыл пароль — используй «Забыл пароль» и код из письма. Если видишь ошибку, скопируй её текст в поддержку, не отправляя пароль.';
  elsif t ~ '(таймер|сколько.*минут|сколько.*идет|время.*матч|конец.*матч)' then
    return 'После начала игры сайт показывает таймер на 15 минут. Когда он закончится, открой матч и отправь скриншот итоговой таблицы. Сайт не может сам определить окончание игры внутри Standoff 2.';
  elsif t ~ '(скрин|прикреп|загруз.*файл|файл.*результат|итог.*матч|счет|счёт|результат)' then
    return 'После окончания 15-минутного таймера открой карточку матча, нажми кнопку отправки результата и выбери скриншот итоговой таблицы. Поддерживаются JPG, PNG и WebP; файл загружается через форму сайта. Если не удаётся прикрепить, напиши об этом в поддержку и приложи текст ошибки.';
  elsif t ~ '(отмен.*матч|матч.*отмен|отклон.*матч|не приняли|отмена)' then
    return 'Если матч отменён до начала игры, вернись в раздел «Играть» и запусти поиск заново. Отменённые записи остаются видны не менее 20 минут, затем удаляются ближайшим запуском очистки. Уже начавшийся матч через обычную кнопку отмены не завершается — обратись к администратору.';
  elsif t ~ '(код комнат|комнат|организатор|создат.*лобби)' then
    return 'После того как игроки примут найденный матч, выберите организатора комнаты. Администратор публикует код комнаты в карточке матча; скопируй его в Standoff 2.';
  elsif t ~ '(матч|поиск|очеред|найти|подбор|не находит|долго.*катк|играть)' then
    return 'Открой «Играть», выбери режим и карту и нажми «Найти матч». Для подбора нужны другие игроки в очереди. Когда матч найден, участники должны его принять; если поиск или принятие завершились отменой, запусти поиск ещё раз.';
  elsif t ~ '(elo|эло|рейтинг|ранг)' then
    return 'После подтверждения результата победители получают от +40 до +65 ELO, проигравшие теряют столько же. Изменение можно посмотреть в профиле и истории матчей.';
  elsif t ~ '(турнир)' then
    return 'Открой раздел «Турниры»: там публикуются доступные турниры, карты, команды и расписание. Создавать турниры может администрация.';
  elsif t ~ '(бан|чит|жалоб|нарушит|оскорб|токсич)' then
    return 'Чтобы сообщить о нарушении, напиши в поддержку или основателю в Telegram: администратору LX FACEIT. Укажи ник игрока, что произошло, и приложи скриншот без паролей и личных кодов.';
  elsif t ~ '(telegram|телеграм|официальн.*канал|новост)' then
    return 'Официальный канал LX FACEIT: официальный канал LX FACEIT. Для связи с основателем: администратору LX FACEIT.';
  elsif t ~ '(поддержк|помог|оператор|человек|связаться|контакт)' then
    return 'Я автоматически отвечаю на частые вопросы. Если ответ не подошёл, переформулируй вопрос или напиши основателю в Telegram: администратору LX FACEIT. Не отправляй пароль, код из письма или другие секретные данные.';
  elsif t ~ '(спасиб|благодар)' then
    return 'Пожалуйста! Если что-то ещё понадобится — напиши вопрос здесь.';
  end if;

  return 'Я не нашёл точного ответа в справке LX FACEIT. Уточни вопрос — например, про регистрацию, ID, пароль, поиск матча, таймер, скриншот или ELO. Если проблема не решится, напиши основателю: администратору LX FACEIT. Не отправляй пароль или код из письма.';
end;
$support$;

create or replace function public.msgr_support_ensure(p_uid uuid)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  select id into v_id from public.msgr_chats where kind='support' and owner_id=p_uid;
  if v_id is null then
    insert into public.msgr_chats(kind,title,about,avatar,owner_id)
      values ('support','Поддержка','Бот поддержки LX FACEIT: ответы на частые вопросы','data:image/svg+xml;utf8,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 96 96%22%3E%3Cdefs%3E%3ClinearGradient id=%22g%22 x1=%220%22 y1=%220%22 x2=%220%22 y2=%221%22%3E%3Cstop offset=%220%22 stop-color=%22%23ff7a2e%22/%3E%3Cstop offset=%221%22 stop-color=%22%23d93f00%22/%3E%3C/linearGradient%3E%3C/defs%3E%3Crect width=%2296%22 height=%2296%22 fill=%22%23161616%22/%3E%3Ccircle cx=%2248%22 cy=%229%22 r=%225%22 fill=%22%23ff5500%22/%3E%3Crect x=%2246%22 y=%2212%22 width=%224%22 height=%2212%22 fill=%22%23ff5500%22/%3E%3Crect x=%2214%22 y=%2224%22 width=%2268%22 height=%2256%22 rx=%2218%22 fill=%22%23242424%22 stroke=%22url(%23g)%22 stroke-width=%224%22/%3E%3Crect x=%225%22 y=%2242%22 width=%229%22 height=%2220%22 rx=%224%22 fill=%22%23ff5500%22/%3E%3Crect x=%2282%22 y=%2242%22 width=%229%22 height=%2220%22 rx=%224%22 fill=%22%23ff5500%22/%3E%3Crect x=%2222%22 y=%2233%22 width=%2252%22 height=%2238%22 rx=%2212%22 fill=%22%230b0b0b%22/%3E%3Cg transform=%22translate(27 36) scale(1.65)%22 fill=%22%23ff5500%22%3E%3Cpath d=%22M24 2.7c0-.1-.1-.1-.2-.1-.1 0-.2.1-.2.2-2 3.1-4.1 6.2-6.1 9.4H.2c-.2 0-.3.3-.1.4 7.2 2.7 17.7 6.8 23.5 9.1.2.1.4-.1.4-.2V2.7z%22/%3E%3C/g%3E%3Crect x=%2234%22 y=%2273%22 width=%2228%22 height=%223%22 rx=%221.5%22 fill=%22%23ff5500%22 opacity=%22.0%22/%3E%3C/svg%3E',p_uid) returning id into v_id;
    insert into public.msgr_members(chat_id,user_id) values (v_id,p_uid) on conflict do nothing;
    insert into public.msgr_messages(chat_id,user_id,body,is_bot)
      values (v_id,p_uid,'Привет! Я бот поддержки LX FACEIT. Спроси про регистрацию, игровой ID, пароль, матч, таймер, скриншот результата, ELO или турнир.',true);
  end if;
  return v_id;
end $$;
revoke all on function public.msgr_support_ensure(uuid) from public,anon,authenticated;
revoke all on function public.msgr_support_reply(text) from public,anon;

create or replace function public.msgr_list(p_q text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_res jsonb; v_q text := left(coalesce(trim(p_q), ''), 40);
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  perform public.msgr_ensure_official();
  perform public.msgr_support_ensure(v_uid);
  insert into public.msgr_members (chat_id, user_id) select id, v_uid from public.msgr_chats where official on conflict do nothing;
  select coalesce(jsonb_agg(s.x order by s.pin desc, s.sort_key desc), '[]'::jsonb) into v_res from (
    select jsonb_build_object(
        'id', c.id, 'kind', c.kind, 'title', c.title, 'about', c.about, 'avatar', c.avatar, 'official', c.official,
        'members', (select count(*) from public.msgr_members m where m.chat_id = c.id),
        'joined', exists (select 1 from public.msgr_members m where m.chat_id = c.id and m.user_id = v_uid),
        'is_owner', c.owner_id = v_uid,
        'last_body', (select left(b.body, 80) from public.msgr_messages b where b.chat_id = c.id order by b.id desc limit 1),
        'last_at', (select b.created_at from public.msgr_messages b where b.chat_id = c.id order by b.id desc limit 1)
      ) as x,
      (c.kind='support') as pin,
      coalesce((select max(b.created_at) from public.msgr_messages b where b.chat_id = c.id), c.created_at) as sort_key
    from public.msgr_chats c
    where (v_q = '' and (c.official or exists (select 1 from public.msgr_members m where m.chat_id = c.id and m.user_id = v_uid)))
       or (v_q <> '' and c.kind <> 'support' and c.title ilike '%' || replace(replace(v_q, '%', ''), '_', '') || '%')
    limit 50
  ) s;
  return v_res;
end $$;

create or replace function public.msgr_join(p_chat uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Нужно войти в аккаунт'; end if;
  if not exists (select 1 from public.msgr_chats where id = p_chat and kind <> 'support') then raise exception 'Чат не найден'; end if;
  insert into public.msgr_members (chat_id, user_id) values (p_chat, auth.uid()) on conflict do nothing;
end $$;

create or replace function public.msgr_messages(p_chat uuid, p_after bigint default 0)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_chat public.msgr_chats; v_res jsonb;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select * into v_chat from public.msgr_chats where id = p_chat;
  if not found then raise exception 'Чат не найден'; end if;
  if v_chat.kind = 'support' and v_chat.owner_id <> v_uid then raise exception 'Чат не найден'; end if;
  if v_chat.kind = 'group' and not exists (select 1 from public.msgr_members where chat_id = p_chat and user_id = v_uid) then
    raise exception 'Вступи в группу, чтобы читать сообщения'; end if;
  select coalesce(jsonb_agg(j order by (j->>'id')::bigint), '[]'::jsonb) into v_res from (
    select jsonb_build_object('id', m.id, 'body', m.body, 'created_at', m.created_at,
      'mine', (m.user_id = v_uid and not m.is_bot), 'bot', m.is_bot,
      'user', case when m.is_bot then jsonb_build_object('id',null,'nickname','Поддержка','display_name','Поддержка')
                   else public.cf_lobby_user_json(m.user_id) end) as j
    from public.msgr_messages m where m.chat_id = p_chat and m.id > coalesce(p_after, 0)
    order by m.id desc limit 60) s;
  return v_res;
end $$;

create or replace function public.msgr_send(p_chat uuid, p_body text)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_chat public.msgr_chats; v_body text := trim(coalesce(p_body, '')); v_id bigint;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select * into v_chat from public.msgr_chats where id = p_chat;
  if not found then raise exception 'Чат не найден'; end if;
  if v_chat.kind = 'channel' and v_chat.owner_id <> v_uid then raise exception 'В канале пишет только владелец'; end if;
  if v_chat.kind = 'support' and v_chat.owner_id <> v_uid then raise exception 'Чат не найден'; end if;
  if not exists (select 1 from public.msgr_members where chat_id = p_chat and user_id = v_uid) then raise exception 'Сначала вступи в чат'; end if;
  if v_body = '' or char_length(v_body) > 1000 then raise exception 'Сообщение: от 1 до 1000 символов'; end if;
  if exists (select 1 from public.msgr_messages where user_id = v_uid and not is_bot and created_at > now() - interval '700 milliseconds') then
    raise exception 'Слишком часто'; end if;
  insert into public.msgr_messages (chat_id, user_id, body) values (p_chat, v_uid, v_body) returning id into v_id;
  if v_chat.kind = 'support' then
    insert into public.msgr_messages (chat_id, user_id, body, is_bot) values (p_chat, v_uid, public.msgr_support_reply(v_body), true);
  end if;
  return v_id;
end $$;

-- Чат поддержки для всех, кто уже зарегистрирован
select public.msgr_support_ensure(id) from public.profiles;

revoke all on function public.msgr_list(text), public.msgr_join(uuid), public.msgr_messages(uuid,bigint), public.msgr_send(uuid,text) from public, anon;
grant execute on function public.msgr_list(text), public.msgr_join(uuid), public.msgr_messages(uuid,bigint), public.msgr_send(uuid,text) to authenticated;

-- ==================== Included source: 24_real_leaderboard.sql ====================
-- LX FACEIT, шаг 24: реальный рейтинг (Топы) из базы вместо демо-игроков.
-- Запускай после 01-23. Вставь целиком в SQL Editor -> Run. Можно повторно.
create or replace function public.cf_leaderboard(p_limit int default 100)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Нужно войти в аккаунт'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
        'rank', q.rk, 'nickname', q.nickname, 'display_name', q.display_name, 'avatar', q.avatar,
        'elo', q.elo, 'wins', q.wins, 'losses', q.losses, 'verified', q.verified, 'role', q.role
      ) order by q.rk)
    from (
      select row_number() over (order by coalesce(p.elo,1000) desc, coalesce(p.wins,0) desc, p.created_at asc) as rk,
             p.nickname, p.display_name, p.avatar, coalesce(p.elo,1000) as elo,
             coalesce(p.wins,0) as wins, coalesce(p.losses,0) as losses, p.verified, p.role
      from public.profiles p
      order by rk
      limit greatest(1, least(coalesce(p_limit,100), 200))
    ) q
  ), '[]'::jsonb);
end $$;
revoke all on function public.cf_leaderboard(int) from public, anon;
grant execute on function public.cf_leaderboard(int) to authenticated;

-- Место текущего игрока в топе (для профиля): {rank, total}
create or replace function public.cf_my_rank()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_me public.profiles%rowtype; v_rank int; v_total int;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select * into v_me from public.profiles where id = v_uid;
  if not found then return null; end if;
  select count(*) + 1 into v_rank from public.profiles p
   where (coalesce(p.elo,1000), coalesce(p.wins,0), -extract(epoch from p.created_at))
       > (coalesce(v_me.elo,1000), coalesce(v_me.wins,0), -extract(epoch from v_me.created_at));
  select count(*) into v_total from public.profiles;
  return jsonb_build_object('rank', v_rank, 'total', v_total);
end $$;
revoke all on function public.cf_my_rank() from public, anon;
grant execute on function public.cf_my_rank() to authenticated;

-- ==================== Included source: 25_ai_elo_stats_time.sql ====================
-- LX FACEIT, шаг 25: нейросеть проверяет скрин и выдаёт ELO, счёт побед/поражений, матч 15 минут, история матчей.
-- Запускай после 01-24. Вставь целиком в SQL Editor -> Run. Можно повторно.

-- ===== 1. Матч идёт 15 минут =====
create or replace function public.cf_match_auto_live()
returns trigger language plpgsql as $$
begin
  if new.status = 'room' and old.status is distinct from 'room' then
    new.status := 'live';
    new.live_started_at := clock_timestamp();
    new.play_ends_at := clock_timestamp() + interval '15 minutes';
  end if;
  return new;
end $$;

-- ===== 2. Применение результата: ELO ±25 + победы/поражения =====
alter table public.cf_lobby_matches
  add column if not exists ai_note text;

create or replace function public.cf_apply_match_result(p_match uuid, p_winner text, p_score text, p_by uuid, p_auto boolean)
returns void language plpgsql security definer set search_path=public as $$
declare v_match public.cf_lobby_matches%rowtype;
begin
  select * into v_match from public.cf_lobby_matches where id=p_match for update;
  if not found or v_match.status<>'result_pending' then raise exception 'Результат уже обработан'; end if;
  update public.profiles p set
    elo=greatest(0,coalesce(p.elo,1000)+case
      when p_winner='A' and p.id=any(v_match.team_a_ids) then 25
      when p_winner='A' and p.id=any(v_match.team_b_ids) then -25
      when p_winner='B' and p.id=any(v_match.team_b_ids) then 25
      when p_winner='B' and p.id=any(v_match.team_a_ids) then -25
      else 0 end),
    wins=coalesce(p.wins,0)+case
      when p_winner='A' and p.id=any(v_match.team_a_ids) then 1
      when p_winner='B' and p.id=any(v_match.team_b_ids) then 1 else 0 end,
    losses=coalesce(p.losses,0)+case
      when p_winner='A' and p.id=any(v_match.team_b_ids) then 1
      when p_winner='B' and p.id=any(v_match.team_a_ids) then 1 else 0 end
  where p.id=any(v_match.participant_ids);
  update public.cf_lobby_matches set status='done',winner_team=p_winner,
      result_score=coalesce(nullif(trim(coalesce(p_score,'')),''),result_score),
      result_reviewed_by=p_by,result_reviewed_at=clock_timestamp(),result_auto=p_auto,updated_at=clock_timestamp()
  where id=p_match;
end $$;
revoke all on function public.cf_apply_match_result(uuid,text,text,uuid,boolean) from public,anon,authenticated;

-- Ручное подтверждение админом теперь тоже считает победы/поражения
create or replace function public.cf_lobby_match_review_result(
  p_match uuid,p_winner text,p_score text default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_uid uuid:=auth.uid(); v_role text; v_match public.cf_lobby_matches%rowtype; v_score text:=trim(coalesce(p_score,''));
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select role into v_role from public.profiles where id=v_uid;
  if coalesce(v_role,'player') not in ('admin','founder') then raise exception 'Недостаточно прав'; end if;
  if p_winner not in ('A','B') then raise exception 'Выбери победившую команду'; end if;
  if char_length(v_score)>20 then raise exception 'Счёт слишком длинный'; end if;
  select * into v_match from public.cf_lobby_matches where id=p_match for update;
  if not found then raise exception 'Матч не найден'; end if;
  if v_match.status<>'result_pending' then raise exception 'Этот результат уже проверен или ещё не отправлен'; end if;
  if nullif(v_match.result_screenshot_url,'') is null then raise exception 'У матча нет скриншота'; end if;
  perform public.cf_apply_match_result(p_match,p_winner,v_score,v_uid,false);
  return public.cf_lobby_match_admin_list();
end $$;
revoke all on function public.cf_lobby_match_review_result(uuid,text,text) from public,anon;
grant execute on function public.cf_lobby_match_review_result(uuid,text,text) to authenticated;

-- ===== 3. Нейросеть: сервер (Edge Function) присылает прочитанный счёт =====
-- Доступно только service_role (ключ Edge Function), игрок вызвать не может.
create or replace function public.cf_ai_apply_result(p_match uuid, p_ct int, p_t int, p_conf text, p_note text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_m public.cf_lobby_matches%rowtype; v_ok boolean; v_win text; v_score text;
begin
  select * into v_m from public.cf_lobby_matches where id=p_match for update;
  if not found then raise exception 'Матч не найден'; end if;
  if v_m.status<>'result_pending' then
    return jsonb_build_object('applied',false,'status',v_m.status,'reason','not_pending');
  end if;
  v_ok := p_ct is not null and p_t is not null and p_ct between 0 and 40 and p_t between 0 and 40
          and p_ct<>p_t and greatest(p_ct,p_t)>=5;
  v_win := case when not v_ok then null when p_ct>p_t then 'A' else 'B' end;
  v_score := case when v_ok then p_ct||':'||p_t else null end;
  update public.cf_lobby_matches set bot_ct_score=case when v_ok then p_ct end,bot_t_score=case when v_ok then p_t end,
         bot_winner=v_win,ai_note=left(coalesce(p_note,''),300),result_score=coalesce(v_score,result_score)
  where id=p_match;
  if v_ok and p_conf='high' then
    perform public.cf_apply_match_result(p_match,v_win,v_score,null,true);
    return jsonb_build_object('applied',true,'winner',v_win,'score',v_score);
  end if;
  return jsonb_build_object('applied',false,'status','result_pending','reason',case when v_ok then 'low_confidence' else 'unreadable' end,'winner',v_win,'score',v_score);
end $$;
revoke all on function public.cf_ai_apply_result(uuid,int,int,text,text) from public,anon,authenticated;
grant execute on function public.cf_ai_apply_result(uuid,int,int,text,text) to service_role;

-- Админ-список: добавляем заметку нейросети
do $$
declare d text;
begin
  d := pg_get_functiondef('public.cf_lobby_match_admin_list()'::regprocedure);
  if position('ai_note' in d)=0 then
    d := replace(d, '''bot_winner'',m.bot_winner,', '''bot_winner'',m.bot_winner,''ai_note'',m.ai_note,');
    execute d;
  end if;
end $$;

-- ===== 4. История матчей игрока из базы =====
create or replace function public.cf_my_history()
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_uid uuid:=auth.uid();
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  return coalesce((
    select jsonb_agg(h order by (h->>'date') desc) from (
      select jsonb_build_object(
        'map', m.map_name, 'mode', case when m.mode='duo' then '2×2' else '5×5' end,
        'res', case when (m.winner_team='A' and v_uid=any(m.team_a_ids)) or (m.winner_team='B' and v_uid=any(m.team_b_ids)) then 'W' else 'L' end,
        'score', coalesce(nullif(m.result_score,''),'—'),
        'delta', case when (m.winner_team='A' and v_uid=any(m.team_a_ids)) or (m.winner_team='B' and v_uid=any(m.team_b_ids)) then 25 else -25 end,
        'date', coalesce(m.result_reviewed_at, m.updated_at)) as h
      from public.cf_lobby_matches m
      where m.status='done' and v_uid=any(m.participant_ids)
      order by coalesce(m.result_reviewed_at, m.updated_at) desc limit 30) s
  ), '[]'::jsonb);
end $$;
revoke all on function public.cf_my_history() from public,anon;
grant execute on function public.cf_my_history() to authenticated;

-- ==================== Included source: 26_elo_random_40_65.sql ====================
-- LX FACEIT, шаг 26: ELO за матч случайное от 40 до 65.
-- Победителям +N, проигравшим -N (N одно на матч, 40..65). Запускай после 01-25. Можно повторно.
alter table public.cf_lobby_matches add column if not exists elo_delta int;

create or replace function public.cf_apply_match_result(p_match uuid, p_winner text, p_score text, p_by uuid, p_auto boolean)
returns void language plpgsql security definer set search_path=public as $$
declare v_match public.cf_lobby_matches%rowtype; v_d int := 40 + floor(random()*26)::int;
begin
  select * into v_match from public.cf_lobby_matches where id=p_match for update;
  if not found or v_match.status<>'result_pending' then raise exception 'Результат уже обработан'; end if;
  update public.profiles p set
    elo=greatest(0,coalesce(p.elo,1000)+case
      when p_winner='A' and p.id=any(v_match.team_a_ids) then v_d
      when p_winner='A' and p.id=any(v_match.team_b_ids) then -v_d
      when p_winner='B' and p.id=any(v_match.team_b_ids) then v_d
      when p_winner='B' and p.id=any(v_match.team_a_ids) then -v_d
      else 0 end),
    wins=coalesce(p.wins,0)+case
      when p_winner='A' and p.id=any(v_match.team_a_ids) then 1
      when p_winner='B' and p.id=any(v_match.team_b_ids) then 1 else 0 end,
    losses=coalesce(p.losses,0)+case
      when p_winner='A' and p.id=any(v_match.team_b_ids) then 1
      when p_winner='B' and p.id=any(v_match.team_a_ids) then 1 else 0 end
  where p.id=any(v_match.participant_ids);
  update public.cf_lobby_matches set status='done',winner_team=p_winner,elo_delta=v_d,
      result_score=coalesce(nullif(trim(coalesce(p_score,'')),''),result_score),
      result_reviewed_by=p_by,result_reviewed_at=clock_timestamp(),result_auto=p_auto,updated_at=clock_timestamp()
  where id=p_match;
end $$;
revoke all on function public.cf_apply_match_result(uuid,text,text,uuid,boolean) from public,anon,authenticated;

-- История: реальное изменение ELO (для старых матчей — 25)
create or replace function public.cf_my_history()
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_uid uuid:=auth.uid();
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  return coalesce((
    select jsonb_agg(h order by (h->>'date') desc) from (
      select jsonb_build_object(
        'map', m.map_name, 'mode', case when m.mode='duo' then '2×2' else '5×5' end,
        'res', case when (m.winner_team='A' and v_uid=any(m.team_a_ids)) or (m.winner_team='B' and v_uid=any(m.team_b_ids)) then 'W' else 'L' end,
        'score', coalesce(nullif(m.result_score,''),'—'),
        'delta', coalesce(m.elo_delta,25) * case when (m.winner_team='A' and v_uid=any(m.team_a_ids)) or (m.winner_team='B' and v_uid=any(m.team_b_ids)) then 1 else -1 end,
        'date', coalesce(m.result_reviewed_at, m.updated_at)) as h
      from public.cf_lobby_matches m
      where m.status='done' and v_uid=any(m.participant_ids)
      order by coalesce(m.result_reviewed_at, m.updated_at) desc limit 30) s
  ), '[]'::jsonb);
end $$;
revoke all on function public.cf_my_history() from public,anon;
grant execute on function public.cf_my_history() to authenticated;

-- Тексты бота поддержки: больше не «±25»
do $$
declare d text;
begin
  d := pg_get_functiondef('public.msgr_support_reply(text)'::regprocedure);
  d := replace(d, 'победителям +25, проигравшим −25', 'победители получают от +40 до +65, проигравшие теряют столько же');
  execute d;
end $$;

-- ==================== Included source: 27_game_id_6_7.sql ====================
-- LX FACEIT, шаг 27: игровой ID — 6 или 7 цифр (раньше ровно 6). Запускай после 01-26. Можно повторно.
alter table public.profiles drop constraint if exists profiles_game_id_format;
alter table public.profiles add constraint profiles_game_id_format check (game_id is null or game_id ~ '^[0-9]{6,7}$');

-- Все функции, где ID проверялся как «ровно 6 цифр» (регистрация, друзья, роли), переписываем на 6-7
do $$
declare r record; d text;
begin
  for r in
    select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f' and pg_get_functiondef(p.oid) like '%[0-9]{6}$%'
  loop
    d := pg_get_functiondef(r.oid);
    d := replace(d, '^[0-9]{6}$', '^[0-9]{6,7}$');
    d := replace(d, 'должен состоять ровно из 6 цифр', 'должен состоять из 6 или 7 цифр');
    execute d;
  end loop;
end $$;

-- ==================== Included source: 28_v30_prime_bans_banners.sql ====================
-- LX FACEIT v30: FACEIT PRIME, profile banners, moderation and Telegram Stars ledger
-- Run once in Supabase SQL Editor AFTER current LX FACEIT SQL files 01-27.
-- Does NOT reset wins, losses, ELO, player IDs or accounts.

begin;

alter table public.profiles add column if not exists profile_banner text not null default 'ember';
alter table public.profiles add column if not exists prime_expires_at timestamptz;
alter table public.profiles drop constraint if exists profiles_profile_banner_check;
alter table public.profiles add constraint profiles_profile_banner_check
  check (profile_banner in ('ember','inferno','dust','royal'));

-- Ban details are stored separately so the publicly readable profiles table does not reveal them.
create table if not exists public.cf_player_moderation (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  banned_until timestamptz,
  is_permanently_banned boolean not null default false,
  ban_reason text not null default '',
  updated_at timestamptz not null default clock_timestamp(),
  updated_by uuid references public.profiles(id) on delete set null
);
alter table public.cf_player_moderation enable row level security;
revoke all on public.cf_player_moderation from public, anon, authenticated;

create table if not exists public.cf_prime_payments (
  telegram_charge_id text primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  amount integer not null check (amount = 300),
  currency text not null check (currency = 'XTR'),
  paid_at timestamptz not null default clock_timestamp()
);
alter table public.cf_prime_payments enable row level security;
revoke all on public.cf_prime_payments from public, anon, authenticated;

-- Limit direct profile updates: users may edit visual/profile fields but cannot grant themselves PRIME or change ELO/roles/stats.
revoke update on public.profiles from anon, authenticated;
grant update (display_name, avatar, telegram_url, youtube_url, tiktok_url, profile_banner) on public.profiles to authenticated;

create or replace function public.cf_my_moderation()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_row public.cf_player_moderation%rowtype;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select * into v_row from public.cf_player_moderation where user_id=v_uid;
  if not found then return jsonb_build_object('is_permanently_banned',false,'banned_until',null,'ban_reason',''); end if;
  if not v_row.is_permanently_banned and v_row.banned_until is not null and v_row.banned_until <= clock_timestamp() then
    return jsonb_build_object('is_permanently_banned',false,'banned_until',null,'ban_reason','');
  end if;
  return jsonb_build_object('is_permanently_banned',v_row.is_permanently_banned,'banned_until',v_row.banned_until,'ban_reason',v_row.ban_reason);
end $$;

create or replace function public.cf_admin_grant_prime(p_target text, p_days integer default 30)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_role text; v_target public.profiles%rowtype; v_until timestamptz;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select role into v_role from public.profiles where id = v_uid;
  if coalesce(v_role,'player') <> 'founder' then raise exception 'Выдать PRIME может только основатель'; end if;
  if p_days is null or p_days < 1 or p_days > 365 then raise exception 'Срок PRIME должен быть от 1 до 365 дней'; end if;
  select * into v_target from public.profiles
   where lower(nickname)=lower(trim(p_target)) or game_id=trim(p_target) or id::text=trim(p_target)
   order by case when lower(nickname)=lower(trim(p_target)) then 0 when game_id=trim(p_target) then 1 else 2 end
   limit 1 for update;
  if not found then raise exception 'Игрок не найден'; end if;
  v_until := greatest(coalesce(v_target.prime_expires_at, clock_timestamp()), clock_timestamp()) + make_interval(days => p_days);
  update public.profiles set prime_expires_at=v_until where id=v_target.id;
  return jsonb_build_object('ok',true,'id',v_target.id,'nickname',v_target.nickname,'prime_expires_at',v_until);
end $$;

create or replace function public.cf_admin_set_ban(p_target text, p_hours integer, p_reason text default '')
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_role text; v_target public.profiles%rowtype; v_until timestamptz; v_perm boolean := false; v_reason text := left(trim(coalesce(p_reason,'')),300);
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select role into v_role from public.profiles where id=v_uid;
  if coalesce(v_role,'player') not in ('admin','founder') then raise exception 'Недостаточно прав'; end if;
  if p_hours is null or p_hours < -1 or p_hours > 87600 then raise exception 'Недопустимый срок блокировки'; end if;
  select * into v_target from public.profiles
   where lower(nickname)=lower(trim(p_target)) or game_id=trim(p_target) or id::text=trim(p_target)
   order by case when lower(nickname)=lower(trim(p_target)) then 0 when game_id=trim(p_target) then 1 else 2 end
   limit 1 for update;
  if not found then raise exception 'Игрок не найден'; end if;
  if v_target.id=v_uid then raise exception 'Нельзя заблокировать самого себя'; end if;
  if coalesce(v_target.role,'player') in ('admin','founder') then raise exception 'Нельзя заблокировать администратора или основателя через эту форму'; end if;
  if p_hours=-1 then
    delete from public.cf_player_moderation where user_id=v_target.id;
    return jsonb_build_object('ok',true,'id',v_target.id,'nickname',v_target.nickname,'banned_until',null,'is_permanently_banned',false,'unbanned',true);
  elsif p_hours=0 then
    v_perm := true; v_until := null;
  else
    v_until := clock_timestamp() + make_interval(hours => p_hours);
  end if;
  if v_reason='' then raise exception 'Укажи причину блокировки'; end if;
  insert into public.cf_player_moderation(user_id,banned_until,is_permanently_banned,ban_reason,updated_at,updated_by)
  values(v_target.id,v_until,v_perm,v_reason,clock_timestamp(),v_uid)
  on conflict(user_id) do update set banned_until=excluded.banned_until,is_permanently_banned=excluded.is_permanently_banned,ban_reason=excluded.ban_reason,updated_at=excluded.updated_at,updated_by=excluded.updated_by;
  return jsonb_build_object('ok',true,'id',v_target.id,'nickname',v_target.nickname,'banned_until',v_until,'is_permanently_banned',v_perm,'ban_reason',v_reason);
end $$;

-- Called only after Telegram webhook verifies a successful 300 XTR payment.
-- Charge IDs are unique: Telegram webhook retries cannot grant PRIME twice for one charge.
create or replace function public.cf_prime_apply_payment(p_user_id uuid, p_telegram_charge_id text, p_amount integer, p_currency text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_inserted integer; v_until timestamptz; v_nick text;
begin
  if p_user_id is null or coalesce(trim(p_telegram_charge_id),'')='' then raise exception 'Invalid payment payload'; end if;
  if p_amount <> 300 or p_currency <> 'XTR' then raise exception 'Неверная сумма или валюта'; end if;
  insert into public.cf_prime_payments(telegram_charge_id,user_id,amount,currency)
  values(p_telegram_charge_id,p_user_id,p_amount,p_currency) on conflict(telegram_charge_id) do nothing;
  get diagnostics v_inserted = row_count;
  if v_inserted=0 then
    select prime_expires_at,nickname into v_until,v_nick from public.profiles where id=p_user_id;
    return jsonb_build_object('ok',true,'already_processed',true,'nickname',v_nick,'prime_expires_at',v_until);
  end if;
  update public.profiles set prime_expires_at=greatest(coalesce(prime_expires_at,clock_timestamp()),clock_timestamp())+interval '30 days'
    where id=p_user_id returning prime_expires_at,nickname into v_until,v_nick;
  if not found then raise exception 'Profile not found'; end if;
  return jsonb_build_object('ok',true,'already_processed',false,'nickname',v_nick,'prime_expires_at',v_until);
end $$;

revoke all on function public.cf_my_moderation() from public,anon;
revoke all on function public.cf_admin_grant_prime(text,integer) from public,anon;
revoke all on function public.cf_admin_set_ban(text,integer,text) from public,anon;
revoke all on function public.cf_prime_apply_payment(uuid,text,integer,text) from public,anon,authenticated;
grant execute on function public.cf_my_moderation() to authenticated;
grant execute on function public.cf_admin_grant_prime(text,integer) to authenticated;
grant execute on function public.cf_admin_set_ban(text,integer,text) to authenticated;
grant execute on function public.cf_prime_apply_payment(uuid,text,integer,text) to service_role;

commit;

-- Stats remain in profiles.wins/losses. Existing SQL 25/26 increments them once during
-- cf_apply_match_result. This migration does not reset ELO or match counters.

-- ==================== Included source: 29_fix_match_cancellation_and_admin_speed.sql ====================
-- LX FACEIT v32 fix: fast admin cancellation and player pre-match cancellation.
-- Run once in Supabase SQL Editor AFTER the v9 matchmaking migration (steps 10-16)
-- and any later schema migrations already applied to this project.

begin;

-- Match-state polling is frequent. A read must not lock the active match row and
-- queue behind every other participant's 2.5-second poll.
do $migration$
declare
  v_definition text;
  v_changed boolean := false;
begin
  v_definition := pg_get_functiondef('public.cf_lobby_match_state()'::regprocedure);
  if v_definition ~* 'order by m\.created_at desc limit 1 for update;' then
    v_definition := regexp_replace(
      v_definition,
      'order by m\.created_at desc limit 1 for update;',
      'order by m.created_at desc limit 1;',
      'i'
    );
    v_changed := true;
  end if;
  if v_definition ~* $pattern$set status='cancelled',cancel_reason='Время принятия матча истекло',updated_at=v_now\s+where id=v_match.id returning \* into v_match;$pattern$ then
    v_definition := regexp_replace(
      v_definition,
      $pattern$set status='cancelled',cancel_reason='Время принятия матча истекло',updated_at=v_now\s+where id=v_match.id returning \* into v_match;$pattern$,
      $replacement$set status='cancelled',cancel_reason='Время принятия матча истекло',updated_at=v_now
      where id=v_match.id and status='found' and expires_at<=v_now returning * into v_match;
      if not found then
        select * into v_match from public.cf_lobby_matches where id=v_match.id;
      end if;$replacement$,
      'i'
    );
    v_changed := true;
  end if;
  if v_definition ~* $pattern$update public.cf_lobby_matches set status='choose_host',updated_at=v_now\s+where id=v_match.id returning \* into v_match;$pattern$ then
    v_definition := regexp_replace(
      v_definition,
      $pattern$update public.cf_lobby_matches set status='choose_host',updated_at=v_now\s+where id=v_match.id returning \* into v_match;$pattern$,
      $replacement$update public.cf_lobby_matches set status='choose_host',updated_at=v_now
        where id=v_match.id and status='found' returning * into v_match;
        if not found then
          select * into v_match from public.cf_lobby_matches where id=v_match.id;
        end if;$replacement$,
      'i'
    );
    v_changed := true;
  end if;
  if v_changed then
    if v_definition ~* 'for update' or v_definition ~* 'where id=v_match\.id returning \* into v_match;' then
      raise exception 'Could not safely make cf_lobby_match_state polling read-only';
    end if;
    execute v_definition;
  end if;
end;
$migration$;

create index if not exists cf_lobby_matches_admin_recent_idx
  on public.cf_lobby_matches(updated_at desc, created_at desc);

create or replace function public.cf_lobby_match_cancel()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_uid uuid:=auth.uid(); v_lobby uuid; v_cancelled integer:=0;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select lobby_id into v_lobby from public.lobby_members where user_id=v_uid;
  if v_lobby is not null then
    update public.cf_matchmaking_queue set queue_status='cancelled',updated_at=clock_timestamp()
    where lobby_id=v_lobby and queue_status='queued';
  end if;
  update public.cf_lobby_matches
  set status='cancelled',cancel_reason='Матч отменён игроком',updated_at=clock_timestamp()
  where v_uid=any(participant_ids)
    and status in ('searching','found','choose_host','host_selected','pending_admin','taken','room','joined');
  get diagnostics v_cancelled = row_count;
  if v_cancelled=0 and exists (
    select 1 from public.cf_lobby_matches
    where v_uid=any(participant_ids) and status in ('live','result_pending')
  ) then
    raise exception 'Матч уже начался. Обратись к администратору для отмены';
  end if;
  return public.cf_lobby_match_state();
end;
$$;

create or replace function public.cf_lobby_match_admin_action(p_match uuid,p_action text,p_code text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_uid uuid:=auth.uid(); v_role text; v_match public.cf_lobby_matches%rowtype; v_nick text;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select role,nickname into v_role,v_nick from public.profiles where id=v_uid;
  if coalesce(v_role,'player') not in ('admin','founder') then raise exception 'Недостаточно прав'; end if;
  select * into v_match from public.cf_lobby_matches where id=p_match for update;
  if not found then raise exception 'Матч не найден'; end if;

  if p_action='take' then
    if v_match.status<>'pending_admin' then raise exception 'Этот матч не ожидает администратора'; end if;
    update public.cf_lobby_matches set status='taken',admin_id=v_uid,admin_nickname=v_nick,updated_at=clock_timestamp()
      where id=p_match and status='pending_admin' and admin_id is null;
    if not found then raise exception 'Уже выполняется другим администратором'; end if;
    v_match.status:='taken';v_match.admin_id:=v_uid;v_match.admin_nickname:=v_nick;
  elsif p_action='publish' then
    if v_match.admin_id<>v_uid then raise exception 'Матч ведёт другой администратор'; end if;
    if v_match.status<>'taken' then raise exception 'Сначала возьми матч'; end if;
    if nullif(trim(p_code),'') is null or char_length(trim(p_code))>64 then raise exception 'Введи код комнаты до 64 символов'; end if;
    update public.cf_lobby_matches set status='room',room_code=trim(p_code),updated_at=clock_timestamp() where id=p_match;
    v_match.status:='room';v_match.room_code:=trim(p_code);
  elsif p_action='joined' then
    if v_match.status<>'room' then raise exception 'Сначала опубликуй код комнаты'; end if;
    if v_match.admin_id is not null and v_match.admin_id<>v_uid then
      raise exception 'Матч ведёт другой администратор';
    end if;
    update public.cf_lobby_matches
      set status='joined',admin_id=coalesce(admin_id,v_uid),
          admin_nickname=case when admin_id is null then v_nick else admin_nickname end,
          updated_at=clock_timestamp()
    where id=p_match;
    v_match.status:='joined';if v_match.admin_id is null then v_match.admin_id:=v_uid;v_match.admin_nickname:=v_nick;end if;
  elsif p_action='live' then
    if v_match.admin_id is null or v_match.admin_id<>v_uid then raise exception 'Сначала возьми матч на сопровождение'; end if;
    if v_match.status<>'joined' then raise exception 'Сначала подтверди вход игроков'; end if;
    update public.cf_lobby_matches set status='live',updated_at=clock_timestamp() where id=p_match;
    v_match.status:='live';
  elsif p_action='cancel' then
    if v_match.status in ('done','cancelled') then raise exception 'Матч уже завершён'; end if;
    update public.cf_lobby_matches set status='cancelled',cancel_reason='Отменено администратором',updated_at=clock_timestamp()
      where id=p_match and status not in ('done','cancelled');
    if not found then raise exception 'Матч уже завершён'; end if;
    v_match.status:='cancelled';v_match.cancel_reason:='Отменено администратором';
  else
    raise exception 'Неизвестное действие администратора';
  end if;
  return jsonb_build_object('ok',true,'match_id',v_match.id,'status',v_match.status,
    'admin_nickname',v_match.admin_nickname,'room_code',v_match.room_code,
    'cancel_reason',v_match.cancel_reason);
end;
$$;

revoke all on function public.cf_lobby_match_cancel() from public,anon;
revoke all on function public.cf_lobby_match_admin_action(uuid,text,text) from public,anon;
grant execute on function public.cf_lobby_match_cancel() to authenticated;
grant execute on function public.cf_lobby_match_admin_action(uuid,text,text) to authenticated;

commit;

-- This migration never alters player data, roles, ELO, or match history.

-- ==================== Included source: 30_play_cooldown.sql ====================
-- LX FACEIT: server-enforced 7-minute cooldown after a match is confirmed done.
-- Run AFTER SQL/29_fix_match_cancellation_and_admin_speed.sql and other installed migrations.
-- A cancelled match does not trigger a cooldown. The timer starts when an admin or AI
-- changes the match to status='done'.

begin;

create table if not exists public.cf_play_cooldowns (
  user_id uuid primary key references auth.users(id) on delete cascade,
  cooldown_until timestamptz not null
);

alter table public.cf_play_cooldowns enable row level security;
revoke all on public.cf_play_cooldowns from public, anon, authenticated;

-- Carry over the remaining cooldown for matches completed within the last 7 minutes.
insert into public.cf_play_cooldowns(user_id,cooldown_until)
select participant_id,max(completed_at + interval '7 minutes')
from (
  select unnest(m.participant_ids) as participant_id,
         coalesce(m.result_reviewed_at,m.updated_at) as completed_at
  from public.cf_lobby_matches m
  where m.status='done'
) recent
where participant_id is not null
  and completed_at > clock_timestamp()-interval '7 minutes'
group by participant_id
on conflict (user_id) do update
  set cooldown_until=greatest(public.cf_play_cooldowns.cooldown_until,excluded.cooldown_until);

create or replace function public.cf_v33_record_play_cooldown()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  v_until timestamptz := clock_timestamp() + interval '7 minutes';
begin
  if new.status='done' and old.status is distinct from 'done' then
    insert into public.cf_play_cooldowns(user_id,cooldown_until)
    select distinct participant_id,v_until
    from unnest(new.participant_ids) as p(participant_id)
    where participant_id is not null
    on conflict (user_id) do update
      set cooldown_until=greatest(public.cf_play_cooldowns.cooldown_until,excluded.cooldown_until);

    -- Prevent a stale queue entry from forming another match as the current one closes.
    update public.cf_matchmaking_queue q
    set queue_status='cancelled',updated_at=clock_timestamp()
    where q.queue_status='queued' and q.party_ids && new.participant_ids;
  end if;
  return new;
end;
$$;
revoke all on function public.cf_v33_record_play_cooldown() from public,anon,authenticated;
drop trigger if exists cf_v33_match_done_cooldown on public.cf_lobby_matches;
create trigger cf_v33_match_done_cooldown
after update of status on public.cf_lobby_matches
for each row
when (new.status='done' and old.status is distinct from new.status)
execute function public.cf_v33_record_play_cooldown();

create or replace function public.cf_v33_guard_play_cooldown_queue()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  v_until timestamptz;
  v_seconds integer;
begin
  if new.queue_status='queued' then
    select max(c.cooldown_until) into v_until
    from public.cf_play_cooldowns c
    where c.user_id=any(new.party_ids)
      and c.cooldown_until>clock_timestamp();
    if v_until is not null then
      v_seconds := greatest(1,ceil(extract(epoch from (v_until-clock_timestamp())))::integer);
      raise exception using message=format(
        'Новый матч можно начать через %s:%s',
        v_seconds/60,
        lpad((v_seconds%60)::text,2,'0')
      );
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public.cf_v33_guard_play_cooldown_queue() from public,anon,authenticated;
drop trigger if exists cf_v33_guard_matchmaking_queue_cooldown on public.cf_matchmaking_queue;
create trigger cf_v33_guard_matchmaking_queue_cooldown
before insert or update on public.cf_matchmaking_queue
for each row
execute function public.cf_v33_guard_play_cooldown_queue();

-- Wrap the existing status RPC so all its existing payload variants also carry
-- the caller's private cooldown timestamp, without changing match-state logic.
do $$
begin
  if to_regprocedure('public.cf_lobby_match_state_cooldown_core()') is null then
    if to_regprocedure('public.cf_lobby_match_state()') is null then
      raise exception 'cf_lobby_match_state() is missing; install the v9 matchmaking migration first';
    end if;
    execute 'alter function public.cf_lobby_match_state() rename to cf_lobby_match_state_cooldown_core';
  end if;
end;
$$;

create or replace function public.cf_lobby_match_state()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_uid uuid := auth.uid();
  v_state jsonb;
  v_cooldown_until timestamptz;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  v_state := public.cf_lobby_match_state_cooldown_core();
  select c.cooldown_until into v_cooldown_until
  from public.cf_play_cooldowns c
  where c.user_id=v_uid and c.cooldown_until>clock_timestamp();
  return coalesce(v_state,'{}'::jsonb)
      || jsonb_build_object('play_cooldown_until',v_cooldown_until);
end;
$$;
revoke all on function public.cf_lobby_match_state_cooldown_core() from public,anon,authenticated;
revoke all on function public.cf_lobby_match_state() from public,anon;
grant execute on function public.cf_lobby_match_state() to authenticated;

commit;

select '7-minute server-enforced play cooldown installed' as result;

-- ==================== Included source: 32_auto_cancel_live_matches_after_40m.sql ====================
-- LX FACEIT: cancel matches that remain live for more than 40 minutes.
-- Run AFTER SQL/21_auto_match_live.sql and the current matchmaking migrations.
-- The database cron runs once per minute, so cancellation occurs within 1 minute
-- after the 40-minute limit. Only status='live' matches are cancelled; matches
-- awaiting result review and completed/cancelled matches are left untouched.

begin;

-- Ensure older live matches have a timestamp column available for the timeout.
alter table public.cf_lobby_matches
  add column if not exists live_started_at timestamptz;

-- Keep the live timestamp correct even for transitions that do not pass through
-- the older room-to-live trigger.
create or replace function public.cf_track_match_live_started_at()
returns trigger
language plpgsql
set search_path = public
as $function$
begin
  if new.status = 'live' and old.status is distinct from 'live' then
    new.live_started_at := clock_timestamp();
  end if;
  return new;
end;
$function$;

drop trigger if exists cf_match_z_track_live_started_at on public.cf_lobby_matches;
create trigger cf_match_z_track_live_started_at
before update of status on public.cf_lobby_matches
for each row
execute function public.cf_track_match_live_started_at();

create or replace function public.cf_cancel_overdue_live_matches()
returns bigint
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_cancelled bigint;
begin
  update public.cf_lobby_matches
     set status = 'cancelled',
         cancel_reason = 'Матч автоматически отменён: прошло более 40 минут',
         updated_at = clock_timestamp()
   where status = 'live'
     and coalesce(live_started_at, updated_at, created_at)
           <= clock_timestamp() - interval '40 minutes';

  get diagnostics v_cancelled = row_count;
  return v_cancelled;
end;
$function$;

-- This function changes matches, so it must not be callable by site visitors.
revoke all on function public.cf_cancel_overdue_live_matches() from public, anon, authenticated;

-- Replace an earlier copy of this job rather than creating duplicate schedules.
create extension if not exists pg_cron with schema pg_catalog;

do $schedule$
declare
  v_job_id bigint;
begin
  for v_job_id in
    select jobid
      from cron.job
     where jobname = 'cf-auto-cancel-live-matches-40m'
  loop
    perform cron.unschedule(v_job_id);
  end loop;

  perform cron.schedule(
    'cf-auto-cancel-live-matches-40m',
    '* * * * *',
    'select public.cf_cancel_overdue_live_matches();'
  );
end;
$schedule$;

commit;

select jobname, schedule, active
  from cron.job
 where jobname = 'cf-auto-cancel-live-matches-40m';

-- ==================== Included source: 33_match_stats_repair.sql ====================
-- LX FACEIT v33: repair persistent wins/losses and keep the profile win rate current.
-- Run once in Supabase SQL Editor after the v9 match/result schema and SQL/23.
-- Safe to re-run: counters are backfilled with GREATEST (never decremented),
-- and a match can apply its result only while it is still result_pending.

begin;

alter table public.profiles
  add column if not exists wins integer not null default 0,
  add column if not exists losses integer not null default 0;

alter table public.cf_lobby_matches
  add column if not exists elo_delta integer,
  add column if not exists ai_note text,
  add column if not exists bot_ct_score integer,
  add column if not exists bot_t_score integer,
  add column if not exists bot_winner text,
  add column if not exists result_auto boolean not null default false;

-- Recover any counts missing from stored completed matches without double-counting
-- values already present in profiles. Cleared/deleted match history cannot be recovered.
with match_counts as (
  select p.id,
    count(distinct m.id) filter (
      where (m.winner_team = 'A' and p.id = any(m.team_a_ids))
         or (m.winner_team = 'B' and p.id = any(m.team_b_ids))
    ) as wins,
    count(distinct m.id) filter (
      where (m.winner_team = 'A' and p.id = any(m.team_b_ids))
         or (m.winner_team = 'B' and p.id = any(m.team_a_ids))
    ) as losses
  from public.profiles p
  join public.cf_lobby_matches m
    on p.id = any(coalesce(m.participant_ids, '{}'::uuid[]))
  where m.status = 'done' and m.winner_team in ('A','B')
  group by p.id
)
update public.profiles p
set wins = greatest(coalesce(p.wins, 0), coalesce(mc.wins, 0)::integer),
    losses = greatest(coalesce(p.losses, 0), coalesce(mc.losses, 0)::integer)
from match_counts mc
where p.id = mc.id;

-- Shared exactly-once result path used by both administrator approval and AI.
create or replace function public.cf_apply_match_result(
  p_match uuid, p_winner text, p_score text, p_by uuid, p_auto boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_match public.cf_lobby_matches%rowtype;
  v_delta integer := 40 + floor(random() * 26)::integer;
begin
  if p_winner is null or p_winner not in ('A','B') then
    raise exception 'Выбери победившую команду';
  end if;

  select * into v_match
  from public.cf_lobby_matches
  where id = p_match
  for update;

  if not found or v_match.status <> 'result_pending' then
    raise exception 'Результат уже обработан';
  end if;

  update public.profiles p
  set elo = greatest(0, coalesce(p.elo, 1000) + case
        when p_winner = 'A' and p.id = any(v_match.team_a_ids) then v_delta
        when p_winner = 'A' and p.id = any(v_match.team_b_ids) then -v_delta
        when p_winner = 'B' and p.id = any(v_match.team_b_ids) then v_delta
        when p_winner = 'B' and p.id = any(v_match.team_a_ids) then -v_delta
        else 0 end),
      wins = coalesce(p.wins, 0) + case
        when (p_winner = 'A' and p.id = any(v_match.team_a_ids))
          or (p_winner = 'B' and p.id = any(v_match.team_b_ids)) then 1 else 0 end,
      losses = coalesce(p.losses, 0) + case
        when (p_winner = 'A' and p.id = any(v_match.team_b_ids))
          or (p_winner = 'B' and p.id = any(v_match.team_a_ids)) then 1 else 0 end
  where p.id = any(v_match.participant_ids);

  update public.cf_lobby_matches
  set status = 'done',
      winner_team = p_winner,
      elo_delta = v_delta,
      result_score = coalesce(nullif(trim(coalesce(p_score, '')), ''), result_score),
      result_reviewed_by = p_by,
      result_reviewed_at = clock_timestamp(),
      result_auto = p_auto,
      updated_at = clock_timestamp()
  where id = p_match and status = 'result_pending';

  if not found then
    raise exception 'Матч уже обработан';
  end if;
end;
$function$;
revoke all on function public.cf_apply_match_result(uuid,text,text,uuid,boolean)
  from public, anon, authenticated;

-- Ensure manual result approval from older v9 SQL versions uses the same counter path.
create or replace function public.cf_lobby_match_review_result(
  p_match uuid, p_winner text, p_score text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_uid uuid := auth.uid();
  v_role text;
  v_match public.cf_lobby_matches%rowtype;
  v_score text := trim(coalesce(p_score, ''));
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select role into v_role from public.profiles where id = v_uid;
  if coalesce(v_role, 'player') not in ('admin','founder') then
    raise exception 'Недостаточно прав';
  end if;
  if p_winner is null or p_winner not in ('A','B') then
    raise exception 'Выбери победившую команду';
  end if;
  if char_length(v_score) > 20 then raise exception 'Счёт слишком длинный'; end if;

  select * into v_match from public.cf_lobby_matches where id = p_match for update;
  if not found then raise exception 'Матч не найден'; end if;
  if v_match.status <> 'result_pending' then
    raise exception 'Этот результат уже проверен или ещё не отправлен';
  end if;
  if nullif(v_match.result_screenshot_url, '') is null then
    raise exception 'У матча нет скриншота';
  end if;

  perform public.cf_apply_match_result(p_match, p_winner, v_score, v_uid, false);
  return public.cf_lobby_match_admin_list();
end;
$function$;
revoke all on function public.cf_lobby_match_review_result(uuid,text,text) from public, anon;
grant execute on function public.cf_lobby_match_review_result(uuid,text,text) to authenticated;

-- Ensure the AI's high-confidence path also increments each participant exactly once.
create or replace function public.cf_ai_apply_result(
  p_match uuid, p_ct integer, p_t integer, p_conf text, p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_match public.cf_lobby_matches%rowtype;
  v_ok boolean;
  v_winner text;
  v_score text;
begin
  select * into v_match from public.cf_lobby_matches where id = p_match for update;
  if not found then raise exception 'Матч не найден'; end if;
  if v_match.status <> 'result_pending' then
    return jsonb_build_object('applied', false, 'status', v_match.status, 'reason', 'not_pending');
  end if;

  v_ok := p_ct is not null and p_t is not null
    and p_ct between 0 and 40 and p_t between 0 and 40
    and p_ct <> p_t and greatest(p_ct, p_t) >= 5;
  v_winner := case when not v_ok then null when p_ct > p_t then 'A' else 'B' end;
  v_score := case when v_ok then p_ct::text || ':' || p_t::text else null end;

  update public.cf_lobby_matches
  set bot_ct_score = case when v_ok then p_ct end,
      bot_t_score = case when v_ok then p_t end,
      bot_winner = v_winner,
      ai_note = left(coalesce(p_note, ''), 300),
      result_score = coalesce(v_score, result_score)
  where id = p_match;

  if v_ok and p_conf = 'high' then
    perform public.cf_apply_match_result(p_match, v_winner, v_score, null, true);
    return jsonb_build_object('applied', true, 'winner', v_winner, 'score', v_score);
  end if;

  return jsonb_build_object(
    'applied', false,
    'status', 'result_pending',
    'reason', case when v_ok then 'low_confidence' else 'unreadable' end,
    'winner', v_winner,
    'score', v_score
  );
end;
$function$;
revoke all on function public.cf_ai_apply_result(uuid,integer,integer,text,text)
  from public, anon, authenticated;
grant execute on function public.cf_ai_apply_result(uuid,integer,integer,text,text)
  to service_role;

-- Make the profile's recent result history available on projects that missed SQL/25.
create or replace function public.cf_my_history()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $function$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;

  return coalesce((
    select jsonb_agg(h order by (h->>'date') desc)
    from (
      select jsonb_build_object(
        'map', m.map_name,
        'mode', case when m.mode = 'duo' then '2×2' else '5×5' end,
        'res', case
          when (m.winner_team = 'A' and v_uid = any(m.team_a_ids))
            or (m.winner_team = 'B' and v_uid = any(m.team_b_ids)) then 'W'
          else 'L'
        end,
        'score', coalesce(nullif(m.result_score, ''), '—'),
        'delta', coalesce(m.elo_delta, 25) * case
          when (m.winner_team = 'A' and v_uid = any(m.team_a_ids))
            or (m.winner_team = 'B' and v_uid = any(m.team_b_ids)) then 1
          else -1
        end,
        'date', coalesce(m.result_reviewed_at, m.updated_at)
      ) as h
      from public.cf_lobby_matches m
      where m.status = 'done'
        and v_uid = any(m.participant_ids)
      order by coalesce(m.result_reviewed_at, m.updated_at) desc
      limit 30
    ) recent
  ), '[]'::jsonb);
end;
$function$;
revoke all on function public.cf_my_history() from public, anon;
grant execute on function public.cf_my_history() to authenticated;

commit;

select 'Match wins/losses, win rate and result history are repaired' as result;

-- ==================== Included source: 34_profile_banner_media.sql ====================
-- LX FACEIT v37: allow profile backgrounds from uploaded photos and videos.
-- Run in Supabase SQL Editor after SQL/28_v30_prime_bans_banners.sql.
-- The public bucket is for user-selected profile media; uploads/deletes are limited to each authenticated user's folder.

begin;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'cf-profile-banners',
  'cf-profile-banners',
  true,
  20971520,
  array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm','video/quicktime','video/x-m4v']
)
on conflict (id) do update
set public = true,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists cf_profile_banners_insert on storage.objects;
create policy cf_profile_banners_insert
on storage.objects for insert to authenticated
with check (
  bucket_id = 'cf-profile-banners'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists cf_profile_banners_delete on storage.objects;
create policy cf_profile_banners_delete
on storage.objects for delete to authenticated
using (
  bucket_id = 'cf-profile-banners'
  and (storage.foldername(name))[1] = auth.uid()::text
);

-- V30 only allowed preset names; uploaded media is stored as its public Storage URL.
alter table public.profiles drop constraint if exists profiles_profile_banner_check;
alter table public.profiles add constraint profiles_profile_banner_check
check (
  profile_banner in ('ember','inferno','dust','royal')
  or (
    char_length(profile_banner) <= 1900
    and profile_banner ~ '^https://[^[:space:]]+/storage/v1/object/public/cf-profile-banners/[0-9a-f-]{36}/[a-zA-Z0-9._/-]+$'
  )
);

commit;

-- ==================== Included source: 35_match_timer_and_screenshot_fix.sql ====================
-- LX FACEIT v35: repair the live-match countdown and screenshot upload path.
-- Run AFTER SQL/21_auto_match_live.sql, SQL/23_screenshot_bot_support.sql,
-- SQL/25_ai_elo_stats_time.sql, SQL/32_auto_cancel_live_matches_after_40m.sql
-- and SQL/33_match_stats_repair.sql. Safe to run again.

begin;

-- Ensure the match clock columns exist in projects whose older setup missed SQL/21.
alter table public.cf_lobby_matches
  add column if not exists live_started_at timestamptz,
  add column if not exists play_ends_at timestamptz;

-- Upload screenshots from the site to the user's own folder in a public proof bucket.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('match-proofs','match-proofs',true,5242880,array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
set public=true,file_size_limit=5242880,allowed_mime_types=excluded.allowed_mime_types;
drop policy if exists cf_proofs_insert on storage.objects;
create policy cf_proofs_insert on storage.objects for insert to authenticated
  with check (bucket_id='match-proofs' and (storage.foldername(name))[1]=auth.uid()::text);

-- A room starts a live match automatically. Admin-started matches also get the same
-- 15-minute deadline. The 40-minute cleanup job leaves time to submit the screenshot.
create or replace function public.cf_match_auto_live()
returns trigger language plpgsql set search_path=public as $$
declare v_now timestamptz:=clock_timestamp();
begin
  if new.status='room' and old.status is distinct from 'room' then
    new.status:='live';
    new.live_started_at:=v_now;
    new.play_ends_at:=v_now+interval '15 minutes';
  elsif new.status='live' and old.status is distinct from 'live' then
    new.live_started_at:=v_now;
    new.play_ends_at:=v_now+interval '15 minutes';
  end if;
  return new;
end $$;
drop trigger if exists cf_match_auto_live_trg on public.cf_lobby_matches;
create trigger cf_match_auto_live_trg
before update of status on public.cf_lobby_matches
for each row execute function public.cf_match_auto_live();
drop trigger if exists cf_match_z_track_live_started_at on public.cf_lobby_matches;

-- Repair legacy live rows and return the dates through the authenticated state RPC.
update public.cf_lobby_matches
set live_started_at=coalesce(live_started_at,updated_at,created_at,clock_timestamp()),
    play_ends_at=coalesce(play_ends_at,coalesce(live_started_at,updated_at,created_at,clock_timestamp())+interval '15 minutes')
where status='live' and (live_started_at is null or play_ends_at is null);

do $$
declare d text; patched text;
begin
  d:=pg_get_functiondef('public.cf_lobby_match_state()'::regprocedure);
  if position('''play_ends_at'',v_match.play_ends_at' in d)=0 then
    patched:=replace(d,
      '''result_reviewed_at'',v_match.result_reviewed_at',
      '''result_reviewed_at'',v_match.result_reviewed_at,''play_ends_at'',v_match.play_ends_at,''live_started_at'',v_match.live_started_at,''updated_at'',v_match.updated_at');
    if patched=d then
      raise exception 'Could not add match timer fields to cf_lobby_match_state(); check the current matchmaking SQL version';
    end if;
    execute patched;
  end if;
end $$;

-- Keep the current client upload contract (3 named args with optional bot scores),
-- validate that the URL belongs to this player's uploaded screenshot, and enforce
-- the same server-side match deadline shown by the browser.
drop function if exists public.cf_lobby_match_submit_result(uuid,text,text);
create or replace function public.cf_lobby_match_submit_result(
  p_match uuid,
  p_screenshot_url text,
  p_score text default null,
  p_bot_ct int default null,
  p_bot_t int default null
) returns jsonb
language plpgsql security definer set search_path=public as $$
declare
  v_uid uuid:=auth.uid();
  v_url text:=trim(coalesce(p_screenshot_url,''));
  v_match public.cf_lobby_matches%rowtype;
  v_ok boolean:=false;
  v_win text;
  v_mine text;
  v_score text;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  if char_length(v_url)>1500 or v_url !~ ('^https://[a-z0-9-]+\.supabase\.co/storage/v1/object/public/match-proofs/'||v_uid::text||'/') then
    raise exception 'Прикрепи скриншот через форму сайта';
  end if;
  if p_score is not null and char_length(trim(p_score))>20 then raise exception 'Счёт слишком длинный'; end if;
  select * into v_match from public.cf_lobby_matches m where m.id=p_match for update;
  if not found or not (v_uid=any(v_match.participant_ids)) then raise exception 'Матч не найден или ты не его участник'; end if;
  if v_match.status not in ('live','result_pending') then raise exception 'Отправить итоги можно после начала матча'; end if;
  if v_match.status='live' and v_match.play_ends_at is not null and v_match.play_ends_at>clock_timestamp() then
    raise exception 'Матч ещё идёт. Итоги можно отправить, когда время матча выйдет';
  end if;
  if v_match.status='result_pending' and v_match.result_submitted_by<>v_uid then
    raise exception 'Другой участник уже отправил результат. Дождись проверки';
  end if;
  v_ok:=p_bot_ct is not null and p_bot_t is not null
    and p_bot_ct between 0 and 40 and p_bot_t between 0 and 40
    and p_bot_ct<>p_bot_t and greatest(p_bot_ct,p_bot_t)>=5;
  v_win:=case when not v_ok then null when p_bot_ct>p_bot_t then 'A' else 'B' end;
  v_score:=case when v_ok then p_bot_ct||':'||p_bot_t else coalesce(nullif(trim(p_score),''),'') end;
  update public.cf_lobby_matches
  set result_screenshot_url=v_url,result_submitted_by=v_uid,result_submitted_at=clock_timestamp(),
      result_score=v_score,bot_ct_score=case when v_ok then p_bot_ct end,
      bot_t_score=case when v_ok then p_bot_t end,bot_winner=v_win,
      status='result_pending',updated_at=clock_timestamp()
  where id=p_match;
  v_mine:=case when v_uid=any(v_match.team_a_ids) then 'A' when v_uid=any(v_match.team_b_ids) then 'B' end;
  if v_ok and v_mine is not null and v_mine<>v_win then
    perform public.cf_apply_match_result(p_match,v_win,v_score,null,true);
  end if;
  return public.cf_lobby_match_state();
end $$;
revoke all on function public.cf_lobby_match_submit_result(uuid,text,text,int,int) from public,anon;
grant execute on function public.cf_lobby_match_submit_result(uuid,text,text,int,int) to authenticated;

commit;
select 'LX FACEIT v35 match timer and screenshot upload fix installed' as result;

-- ==================== Included source: 36_cancelled_match_cleanup_20m.sql ====================
-- LX FACEIT v42: очистка отменённых матчей каждые 20 минут.
-- Запускай после matchmaking migrations SQL/10 и SQL/32.
-- Отменённые записи остаются видимыми не менее 20 минут, чтобы игроки успели
-- увидеть причину отмены; затем удаляются ближайшим 20-минутным запуском.
-- Удаляются только отменённые матчи и очередь, включая matched-записи,
-- привязанные к отменённому матчу. Завершённые матчи не трогаются.
-- Завершённые матчи, матчи на проверке, профили, ELO и жалобы не затрагиваются.

begin;

create extension if not exists pg_cron with schema pg_catalog;

create index if not exists cf_lobby_matches_cancelled_cleanup_idx
  on public.cf_lobby_matches (updated_at)
  where status = 'cancelled';

create index if not exists cf_matchmaking_queue_cancelled_cleanup_idx
  on public.cf_matchmaking_queue (updated_at)
  where queue_status = 'cancelled';

create index if not exists cf_matchmaking_queue_cancelled_match_cleanup_idx
  on public.cf_matchmaking_queue (match_id)
  where queue_status = 'matched';

create or replace function public.cf_cleanup_cancelled_matches_20m()
returns bigint
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_cutoff timestamptz := clock_timestamp() - interval '20 minutes';
  v_deleted_queue bigint := 0;
  v_deleted_matches bigint := 0;
begin
  -- Delete explicitly cancelled queue entries and matched queue entries whose
  -- linked match was cancelled long enough ago. This prevents orphaned 'matched'
  -- rows after the match is deleted below.
  delete from public.cf_matchmaking_queue q
   where (q.queue_status = 'cancelled' and q.updated_at < v_cutoff)
      or (q.queue_status = 'matched' and exists (
        select 1
          from public.cf_lobby_matches m
         where m.id = q.match_id
           and m.status = 'cancelled'
           and m.updated_at < v_cutoff
      ));
  get diagnostics v_deleted_queue = row_count;

  -- The FK from queue.match_id uses ON DELETE SET NULL. Only cancelled matches
  -- older than the retention window are removed; all other statuses are kept.
  delete from public.cf_lobby_matches m
   where m.status = 'cancelled'
     and m.updated_at < v_cutoff;
  get diagnostics v_deleted_matches = row_count;

  return v_deleted_queue + v_deleted_matches;
end;
$function$;

revoke all on function public.cf_cleanup_cancelled_matches_20m()
  from public, anon, authenticated;

-- Replace only this named job to make this migration safe to run again.
do $schedule$
declare
  v_job_id bigint;
begin
  for v_job_id in
    select jobid
      from cron.job
     where jobname = 'cf-clean-cancelled-matches-20m'
  loop
    perform cron.unschedule(v_job_id);
  end loop;

  perform cron.schedule(
    'cf-clean-cancelled-matches-20m',
    '*/20 * * * *',
    'select public.cf_cleanup_cancelled_matches_20m();'
  );
end;
$schedule$;

commit;

-- Expected: one active cron job named cf-clean-cancelled-matches-20m.
select jobname, schedule, active
  from cron.job
 where jobname = 'cf-clean-cancelled-matches-20m';

-- ==================== Included source: 37_messenger_support_answers.sql ====================
-- LX FACEIT v42: обновлённые автоматические ответы бота поддержки.
-- Запускай после SQL/23_screenshot_bot_support.sql.
-- Не использует внешние AI API или ключи: отвечает по проверенным правилам проекта,
-- а для неизвестных вопросов честно предлагает уточнить формулировку или обратиться к поддержке.

begin;

do $check$
begin
  if to_regprocedure('public.msgr_support_ensure(uuid)') is null then
    raise exception 'Сначала запусти SQL/23_screenshot_bot_support.sql: чат поддержки ещё не установлен';
  end if;
  if to_regclass('public.profiles') is null then
    raise exception 'Таблица public.profiles не найдена';
  end if;
end;
$check$;

create or replace function public.msgr_support_reply(p_text text)
returns text
language plpgsql
immutable
as $support$
declare
  t text := replace(lower(coalesce(p_text, '')), 'ё', 'е');
begin
  t := regexp_replace(t, '[[:space:][:punct:]]+', ' ', 'g');
  t := trim(t);

  if t = '' then
    return 'Напиши вопрос — помогу с регистрацией, входом, поиском матча, таймером, результатом, ELO или турнирами.';
  elsif t ~ '(привет|здравств|добрый|хай|hello)' and char_length(t) < 60 then
    return 'Привет! Я бот поддержки LX FACEIT. Спроси про регистрацию, игровой ID, пароль, матч, таймер, скриншот результата, ELO или турнир.';
  elsif t ~ '(длина.*парол|парол.*длин|сколько.*символ.*парол|минимум.*парол)' then
    return 'Пароль должен содержать не менее 8 символов. Не используй пароль от других сайтов.';
  elsif t ~ '(забыл.*парол|forgot.*password|reset.*password|восстанов.*парол|сброс.*парол|парол.*(код|почт|не подходит|неверн|не работает|ошиб|принима)|код.*(парол|восстанов)|invalid login credentials|user already registered|password)' then
    return 'Чтобы восстановить пароль, нажми «Забыл пароль» на экране входа, введи почту аккаунта и укажи 6-значный код из письма. Затем задай новый пароль длиной не менее 8 символов. Проверь папку «Спам»; если код не приходит, попробуй позже или напиши в поддержку.';
  elsif t ~ '(игров.{0,12}(id|айди|номер)|id.{0,12}игрок|айди|game id|игровой идентификатор|сколько цифр)' then
    return 'Игровой ID при регистрации — ровно 6 или 7 цифр. Он должен быть уникальным. Введи цифры без пробелов; начальные нули допустимы.';
  elsif t ~ '(регистрац|зарегистрир|создат.*аккаунт|новый аккаунт|уже зарегистрир|подтвержден.*почт)' then
    return 'Для регистрации укажи ник, почту, игровой ID из 6 или 7 цифр и пароль от 8 символов. Если сайт сообщает, что пользователь уже зарегистрирован, войди в существующий аккаунт или восстанови пароль по коду на почту.';
  elsif t ~ '(войти|вход|логин|не могу войти|не пускает|аккаунт)' then
    return 'Войди по никнейму или адресу электронной почты и паролю. Игровой ID для входа не нужен; он используется при регистрации. Если пароль не подходит, проверь ник/почту и восстанови пароль через «Забыл пароль» — не отправляй пароль или код из письма в чат.';
  elsif t ~ '(таймер|сколько.*минут|сколько.*идет|время.*матч|конец.*матч)' then
    return 'После начала игры сайт показывает таймер на 15 минут. Когда он закончится, открой матч и отправь скриншот итоговой таблицы. Сайт не может сам определить окончание игры внутри Standoff 2.';
  elsif t ~ '(скрин|прикреп|загруз.*файл|файл.*результат|итог.*матч|счет|счёт|результат)' then
    return 'После окончания 15-минутного таймера открой карточку матча, нажми кнопку отправки результата и выбери скриншот итоговой таблицы. Поддерживаются JPG, PNG и WebP; файл загружается через форму сайта. Если не удаётся прикрепить, напиши об этом в поддержку и приложи текст ошибки.';
  elsif t ~ '(отмен.*матч|матч.*отмен|отклон.*матч|не приняли|отмена)' then
    return 'Если матч отменён до начала игры, вернись в раздел «Играть» и запусти поиск заново. Отменённые записи остаются видны не менее 20 минут, затем удаляются ближайшим запуском очистки. Уже начавшийся матч через обычную кнопку отмены не завершается — обратись к администратору.';
  elsif t ~ '(код комнат|комнат|организатор|создат.*лобби)' then
    return 'После того как игроки примут найденный матч, выберите организатора комнаты. Администратор публикует код комнаты в карточке матча; скопируй его в Standoff 2.';
  elsif t ~ '(матч|поиск|очеред|найти|подбор|не находит|долго.*катк|играть)' then
    return 'Открой «Играть», выбери режим и карту и нажми «Найти матч». Для подбора нужны другие игроки в очереди. Когда матч найден, участники должны его принять; если поиск или принятие завершились отменой, запусти поиск ещё раз.';
  elsif t ~ '(elo|эло|рейтинг|ранг)' then
    return 'После подтверждения результата победители получают от +40 до +65 ELO, проигравшие теряют столько же. Изменение можно посмотреть в профиле и истории матчей.';
  elsif t ~ '(турнир)' then
    return 'Открой раздел «Турниры»: там публикуются доступные турниры, карты, команды и расписание. Создавать турниры может администрация.';
  elsif t ~ '(бан|чит|жалоб|нарушит|оскорб|токсич)' then
    return 'Чтобы сообщить о нарушении, напиши в поддержку или основателю в Telegram: администратору LX FACEIT. Укажи ник игрока, что произошло, и приложи скриншот без паролей и личных кодов.';
  elsif t ~ '(telegram|телеграм|официальн.*канал|новост)' then
    return 'Официальный канал LX FACEIT: официальный канал LX FACEIT. Для связи с основателем: администратору LX FACEIT.';
  elsif t ~ '(спонсор|значок|поддержать|привилег|100 ?₽|100 ?руб)' then
    return 'Чтобы получить значок спонсора LX FACEIT и привилегии, поддержи проект минимум на 100 ₽ через Telegram @prisedents. После подтверждения поддержки значок выдаёт администрация. Ссылка: https://t.me/prisedents.';
  elsif t ~ '(поддержк|помог|оператор|человек|связаться|контакт)' then
    return 'Я автоматически отвечаю на частые вопросы. Если ответ не подошёл, переформулируй вопрос или напиши основателю в Telegram: администратору LX FACEIT. Не отправляй пароль, код из письма или другие секретные данные.';
  elsif t ~ '(спасиб|благодар)' then
    return 'Пожалуйста! Если что-то ещё понадобится — напиши вопрос здесь.';
  end if;

  return 'Я не нашёл точного ответа в справке LX FACEIT. Уточни вопрос — например, про регистрацию, ID, вход, пароль, поиск матча, таймер, скриншот, ELO или значок спонсора. Если проблема не решится, напиши основателю: администратору LX FACEIT. Не отправляй пароль или код из письма.';
end;
$support$;

revoke all on function public.msgr_support_reply(text)
  from public, anon, authenticated;

-- Ensure every current account has its own support conversation; safe to rerun.
select public.msgr_support_ensure(id)
  from public.profiles;

-- Refresh only the standard first greeting; do not rewrite user chat history.
update public.msgr_messages m
   set body = 'Привет! Я бот поддержки LX FACEIT. Спроси про регистрацию, игровой ID, пароль, матч, таймер, скриншот результата, ELO или турнир.'
 where m.is_bot
   and m.body = 'Привет! Я бот поддержки LX FACEIT. Спроси про матч, ELO, результат, турнир, пароль или жалобу.'
   and m.chat_id in (select c.id from public.msgr_chats c where c.kind = 'support');

commit;

-- ==================== Included source: 38_auth_registration_login_hardening.sql ====================
-- LX FACEIT v43: harden registration and nickname login.
-- Run after SQL/01_setup_all_online.sql and SQL/27_game_id_6_7.sql.
-- This does not create accounts, modify passwords, or change existing profile data.

begin;

-- Required profile fields for the signup trigger.
alter table public.profiles add column if not exists game_id text;
alter table public.profiles add column if not exists role text not null default 'player';

-- A case-insensitive unique name is required for deterministic nickname login.
-- Stop rather than silently renaming existing users if older data contains duplicates.
do $$
begin
  if exists (
    select 1
    from public.profiles
    group by lower(btrim(nickname))
    having count(*) > 1
  ) then
    raise exception 'Найдены повторяющиеся никнеймы без учёта регистра. Исправь дубли в public.profiles.nickname и запусти миграцию снова.';
  end if;

  if exists (
    select 1 from public.profiles
    where game_id is not null and btrim(game_id) <> ''
    group by btrim(game_id)
    having count(*) > 1
  ) then
    raise exception 'Найдены повторяющиеся игровые ID. Исправь дубли в public.profiles.game_id и запусти миграцию снова.';
  end if;

  if exists (
    select 1 from public.profiles
    where game_id is not null and btrim(game_id) <> '' and btrim(game_id) !~ '^[0-9]{6,7}$'
  ) then
    raise exception 'В public.profiles есть игровой ID не из 6 или 7 цифр. Исправь его перед запуском миграции.';
  end if;
end;
$$;

update public.profiles set game_id = null where game_id is not null and btrim(game_id) = '';

alter table public.profiles drop constraint if exists profiles_game_id_format;
alter table public.profiles
  add constraint profiles_game_id_format
  check (game_id is null or game_id ~ '^[0-9]{6,7}$');

create unique index if not exists profiles_nickname_lower_unique
  on public.profiles (lower(nickname));
create unique index if not exists profiles_game_id_unique
  on public.profiles (game_id)
  where game_id is not null;

-- The database, not just the browser, validates new profiles and rejects duplicate nicknames/IDs.
create or replace function public.cf_faceit_handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_nick text := btrim(coalesce(new.raw_user_meta_data ->> 'nickname', ''));
  v_game_id text := btrim(coalesce(new.raw_user_meta_data ->> 'game_id', ''));
begin
  if v_nick !~ '^[A-Za-z0-9_-]{3,20}$' then
    raise exception 'Никнейм должен быть от 3 до 20 символов: латинские буквы, цифры, _ или -';
  end if;

  if v_game_id !~ '^[0-9]{6,7}$' then
    raise exception 'Игровой ID должен состоять из 6 или 7 цифр';
  end if;

  begin
    insert into public.profiles (id, nickname, game_id, display_name, avatar, role, verified)
    values (new.id, v_nick, v_game_id, v_nick, 'ember', 'player', false)
    on conflict (id) do nothing;
  exception when unique_violation then
    if exists (select 1 from public.profiles p where lower(p.nickname) = lower(v_nick)) then
      raise exception 'Этот никнейм уже зарегистрирован';
    elsif exists (select 1 from public.profiles p where p.game_id = v_game_id) then
      raise exception 'Этот игровой ID уже занят';
    else
      raise;
    end if;
  end;

  return new;
end;
$$;

revoke all on function public.cf_faceit_handle_new_user() from public, anon, authenticated;
drop trigger if exists on_auth_user_created on auth.users;
drop trigger if exists cf_faceit_auth_user_created on auth.users;
create trigger cf_faceit_auth_user_created
  after insert on auth.users
  for each row execute function public.cf_faceit_handle_new_user();

-- Anonymous signup checks return only whether the submitted nickname/ID is unavailable.
create or replace function public.cf_auth_check_registration(p_nickname text, p_game_id text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'nickname_taken', case
      when nullif(btrim(p_nickname), '') is null then false
      else exists (
        select 1 from public.profiles p
        where lower(p.nickname) = lower(btrim(p_nickname))
      )
    end,
    'game_id_taken', case
      when nullif(btrim(p_game_id), '') is null then false
      else exists (
        select 1 from public.profiles p
        where p.game_id = btrim(p_game_id)
      )
    end
  );
$$;
revoke all on function public.cf_auth_check_registration(text, text) from public, anon, authenticated;
grant execute on function public.cf_auth_check_registration(text, text) to anon, authenticated;

-- Nickname lookup is only available to the login Edge Function using service_role.
create or replace function public.cf_auth_profile_by_nickname(p_nickname text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', p.id,
    'nickname', p.nickname,
    'game_id', p.game_id,
    'role', p.role
  )
  from public.profiles p
  where lower(p.nickname) = lower(btrim(p_nickname))
  limit 1;
$$;
revoke all on function public.cf_auth_profile_by_nickname(text) from public, anon, authenticated;
grant execute on function public.cf_auth_profile_by_nickname(text) to service_role;

commit;

select 'LX FACEIT v43 registration/login hardening installed' as result;

-- ==================== Included source: 39_regions_and_ping.sql ====================
-- LX FACEIT v44: profile regions, regional matchmaking queues and queue ping status.
-- Run in Supabase SQL Editor AFTER SQL/38_auth_registration_login_hardening.sql,
-- the v9 matchmaking migrations SQL/10-16, and SQL/30_play_cooldown.sql.
-- Existing accounts/queue entries default to Russia (ru). Safe to run again.

begin;

-- Persist each player's preferred matchmaking region.
alter table public.profiles add column if not exists region text;
update public.profiles set region='ru' where region is null or region not in ('ru','eu','asia','all');
alter table public.profiles alter column region set default 'ru';
alter table public.profiles alter column region set not null;
alter table public.profiles drop constraint if exists profiles_region_allowed;
alter table public.profiles add constraint profiles_region_allowed check (region in ('ru','eu','asia','all'));
grant update (region) on public.profiles to authenticated;

-- Signup checks this RPC so the UI cannot silently ignore region data if SQL/39 is missing.
create or replace function public.cf_regions_enabled()
returns boolean
language sql
stable
security definer
set search_path=public
as $$ select true; $$;
revoke all on function public.cf_regions_enabled() from public,anon,authenticated;
grant execute on function public.cf_regions_enabled() to anon,authenticated;

-- The signup trigger created by SQL/38 creates the profile first; this final
-- AFTER trigger copies only one of the allowed region codes from signup metadata.
create or replace function public.cf_faceit_apply_signup_region()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  v_region text := coalesce(new.raw_user_meta_data->>'region','ru');
begin
  if v_region not in ('ru','eu','asia','all') then v_region := 'ru'; end if;
  update public.profiles set region=v_region where id=new.id;
  return new;
end;
$$;
revoke all on function public.cf_faceit_apply_signup_region() from public,anon,authenticated;
drop trigger if exists cf_zz_faceit_apply_signup_region on auth.users;
create trigger cf_zz_faceit_apply_signup_region
after insert on auth.users
for each row execute function public.cf_faceit_apply_signup_region();

-- Queue rows are isolated by region. Older queued rows remain in Russia.
alter table public.cf_matchmaking_queue add column if not exists region text;
update public.cf_matchmaking_queue set region='ru' where region is null or region not in ('ru','eu','asia','all');
alter table public.cf_matchmaking_queue alter column region set default 'ru';
alter table public.cf_matchmaking_queue alter column region set not null;
alter table public.cf_matchmaking_queue drop constraint if exists cf_matchmaking_queue_region_allowed;
alter table public.cf_matchmaking_queue add constraint cf_matchmaking_queue_region_allowed check (region in ('ru','eu','asia','all'));
create index if not exists cf_matchmaking_queue_region_fifo
  on public.cf_matchmaking_queue(mode,region,queue_status,queue_order);

-- Match parties in one mode; specific regions stay isolated, while 'all' is the shared wildcard pool.
create or replace function public.cf_matchmaking_try_form(p_mode text,p_region text)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare
  v_target integer;
  v_team_size integer;
  v_combo record;
  v_queue_ids uuid[];
  v_players uuid[];
  v_groups jsonb;
  v_group_count integer;
  v_anchor_lobby uuid;
  v_map text;
  v_mask integer;
  v_mask_max integer;
  v_i integer;
  v_party uuid[];
  v_team_a uuid[];
  v_team_b uuid[];
  v_sum_a integer;
  v_valid boolean;
  v_match_id uuid;
  v_started_by uuid;
begin
  if p_mode is null or p_mode not in ('ranked','duo') then raise exception 'Недопустимый режим'; end if;
  if p_region is null or p_region not in ('ru','eu','asia','all') then raise exception 'Недопустимый регион'; end if;
  v_target := case when p_mode='duo' then 4 else 10 end;
  v_team_size := v_target / 2;
  -- Serialize all region pools for a mode: global and regional searches can consume the same rows.
  perform pg_advisory_xact_lock(hashtext('cf:v9:matcher:'||p_mode));

  update public.cf_matchmaking_queue
    set queue_status='cancelled',updated_at=clock_timestamp()
  where mode=p_mode and (p_region='all' or region=p_region or region='all') and queue_status='queued'
    and queued_at < clock_timestamp()-interval '10 minutes';

  -- Bound recursive search to the oldest 16 compatible parties in this region/global pool.
  for v_combo in
    with recursive q as materialized (
      select q0.id,q0.queue_order,q0.lobby_id,q0.party_ids,q0.mode,q0.map_name,
             cardinality(q0.party_ids) as party_size
      from public.cf_matchmaking_queue q0
      where q0.mode=p_mode and (p_region='all' or q0.region=p_region or q0.region='all') and q0.queue_status='queued'
      order by q0.queue_order
      limit 16
    ), combos as (
      select array[q.id]::uuid[] as queue_ids,
             q.party_ids as player_ids,
             jsonb_build_array(jsonb_build_object(
               'queue_id',q.id,'lobby_id',q.lobby_id,
               'party_ids',to_jsonb(q.party_ids),'map_name',q.map_name
             )) as groups_json,
             q.party_size as total_players,
             q.queue_order as first_order,
             q.queue_order as last_order
      from q
      where q.party_size <= v_target
      union all
      select c.queue_ids || q.id,
             c.player_ids || q.party_ids,
             c.groups_json || jsonb_build_array(jsonb_build_object(
               'queue_id',q.id,'lobby_id',q.lobby_id,
               'party_ids',to_jsonb(q.party_ids),'map_name',q.map_name
             )),
             c.total_players + q.party_size,
             c.first_order,
             q.queue_order
      from combos c
      join q on q.queue_order > c.last_order
      where c.total_players + q.party_size <= v_target
    )
    select queue_ids,player_ids,groups_json,first_order
    from combos
    where total_players=v_target
    order by first_order,cardinality(queue_ids),queue_ids::text
    limit 500
  loop
    v_queue_ids := v_combo.queue_ids;
    v_players := v_combo.player_ids;
    v_groups := v_combo.groups_json;
    v_group_count := jsonb_array_length(v_groups);
    v_anchor_lobby := (v_groups->0->>'lobby_id')::uuid;
    v_map := v_groups->0->>'map_name';
    v_mask_max := (1 << v_group_count) - 1;
    v_valid := false;

    if v_group_count > 0 then
      for v_mask in 0..v_mask_max loop
        v_team_a := '{}'::uuid[];
        v_team_b := '{}'::uuid[];
        v_sum_a := 0;
        for v_i in 0..(v_group_count-1) loop
          select coalesce(array_agg(x.uid::uuid),'{}'::uuid[])
            into v_party
          from jsonb_array_elements_text(v_groups->v_i->'party_ids') as x(uid);
          if (v_mask & (1 << v_i)) <> 0 then
            v_team_a := v_team_a || v_party;
            v_sum_a := v_sum_a + cardinality(v_party);
          else
            v_team_b := v_team_b || v_party;
          end if;
        end loop;
        if v_sum_a=v_team_size and cardinality(v_team_b)=v_team_size then
          v_valid := true;
          exit;
        end if;
      end loop;
    end if;

    if v_valid then
      exit;
    else
      v_queue_ids := null;
      v_players := null;
      v_groups := null;
    end if;
  end loop;

  if v_queue_ids is null then return false; end if;

  if exists (
    select 1 from public.cf_lobby_matches m
    where m.status not in ('done','cancelled')
      and m.participant_ids && v_players
  ) then
    update public.cf_matchmaking_queue
      set queue_status='cancelled',updated_at=clock_timestamp()
    where id=any(v_queue_ids);
    return false;
  end if;

  v_started_by := v_players[1];
  insert into public.cf_lobby_matches(
    lobby_id,started_by,participant_ids,team_a_ids,team_b_ids,
    mode,map_name,status,started_at,found_at,expires_at
  ) values (
    v_anchor_lobby,v_started_by,v_players,v_team_a,v_team_b,
    p_mode,v_map,'found',clock_timestamp(),clock_timestamp(),clock_timestamp()+interval '15 seconds'
  ) returning id into v_match_id;

  update public.cf_matchmaking_queue
    set queue_status='matched',match_id=v_match_id,updated_at=clock_timestamp()
  where id=any(v_queue_ids);
  return true;
end;
$$;
revoke all on function public.cf_matchmaking_try_form(text,text) from public,anon,authenticated;
revoke all on function public.cf_matchmaking_try_form(text) from public,anon,authenticated;

-- Use the signed-in player's saved region when a party enters the queue.
create or replace function public.cf_lobby_match_start(p_mode text,p_map text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_uid uuid := auth.uid();
  v_lobby uuid;
  v_owner uuid;
  v_ids uuid[];
  v_count integer;
  v_team_size integer;
  v_active uuid;
  v_region text;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  if p_mode not in ('ranked','duo') then raise exception 'Недопустимый режим'; end if;
  if p_map not in ('Mirage','Dust2','Vertigo','Inferno') then raise exception 'Недопустимая карта'; end if;
  v_team_size := case when p_mode='duo' then 2 else 5 end;

  select coalesce(p.region,'ru') into v_region
  from public.profiles p where p.id=v_uid;
  if not found then raise exception 'Профиль не найден. Перезайди в аккаунт'; end if;
  if v_region not in ('ru','eu','asia','all') then raise exception 'Недопустимый регион'; end if;

  perform pg_advisory_xact_lock(hashtext('cf:v9:queue-user:'||v_uid::text));
  select lm.lobby_id,l.owner_id into v_lobby,v_owner
  from public.lobby_members lm join public.lobbies l on l.id=lm.lobby_id
  where lm.user_id=v_uid;
  if v_lobby is null then
    insert into public.lobbies(owner_id) values(v_uid) returning id into v_lobby;
    insert into public.lobby_members(lobby_id,user_id) values(v_lobby,v_uid);
  end if;

  select m.id into v_active from public.cf_lobby_matches m
  where v_uid=any(m.participant_ids) and m.status not in ('done','cancelled')
  order by m.created_at desc limit 1;
  if v_active is not null then return public.cf_lobby_match_state(); end if;

  select array_agg(user_id order by joined_at),count(*) into v_ids,v_count
  from public.lobby_members where lobby_id=v_lobby;
  if coalesce(v_count,0)>v_team_size then
    raise exception 'В режиме % можно сохранить в одной группе максимум % игроков. Разделите лобби или выберите 5×5.',p_mode,v_team_size;
  end if;

  -- A global ('all') preference is a wildcard; a regional party may include global members,
  -- but cannot mix distinct specific regions.
  if v_region<>'all' and exists (
    select 1 from unnest(v_ids) as member(user_id)
    left join public.profiles p on p.id=member.user_id
    where p.id is null or coalesce(p.region,'ru') not in (v_region,'all')
  ) then
    raise exception 'У всех игроков в лобби должен совпадать регион или стоять «Все регионы». Попроси друзей изменить регион в настройках.';
  end if;

  if exists(select 1 from public.cf_matchmaking_queue q where q.lobby_id=v_lobby and q.queue_status='queued') then
    return public.cf_lobby_match_state();
  end if;

  insert into public.cf_matchmaking_queue(lobby_id,party_ids,mode,map_name,region)
  values(v_lobby,v_ids,p_mode,p_map,v_region);
  perform public.cf_matchmaking_try_form(p_mode,v_region);
  return public.cf_lobby_match_state();
end;
$$;

-- Show parties in the same region plus the global pool; a global queue sees all regions.
do $$
declare
  v_target regprocedure;
  v_definition text;
  v_patched text;
begin
  v_target := to_regprocedure('public.cf_lobby_match_state_cooldown_core()');
  if v_target is null then v_target := to_regprocedure('public.cf_lobby_match_state()'); end if;
  if v_target is null then raise exception 'Функция cf_lobby_match_state() не найдена'; end if;

  v_definition := pg_get_functiondef(v_target);
  v_patched := replace(
    v_definition,
    'where q.mode=v_queue.mode and q.queue_status=''queued'';',
    'where q.mode=v_queue.mode and (v_queue.region=''all'' or q.region=v_queue.region or q.region=''all'') and q.queue_status=''queued'';'
  );
  v_patched := replace(
    v_patched,
    '''id'',v_queue.id,''mode'',v_queue.mode,''map_name'',v_queue.map_name',
    '''id'',v_queue.id,''mode'',v_queue.mode,''region'',v_queue.region,''map_name'',v_queue.map_name'
  );
  if position('v_queue.region=''all''' in v_patched)=0
     or position('q.region=''all''' in v_patched)=0
     or position($needle$'region',v_queue.region$needle$ in v_patched)=0 then
    raise exception 'Не удалось обновить подсчёт очереди по регионам. Проверь версию SQL/30_play_cooldown.sql.';
  end if;
  if v_patched<>v_definition then execute v_patched; end if;
end;
$$;

commit;

select 'Регион профиля и раздельный региональный подбор установлены' as result;

-- ==================== Included source: 40_support_account_recovery.sql ====================
-- LX FACEIT v45: self-service game ID change and password recovery from support chat.
-- Run after SQL/23_screenshot_bot_support.sql, SQL/37_messenger_support_answers.sql,
-- SQL/38_auth_registration_login_hardening.sql and SQL/39_regions_and_ping.sql.
-- Passwords and email OTPs are never stored in support chat. Safe to run again.

begin;

do $check$
begin
  if to_regclass('public.profiles') is null
     or to_regclass('public.msgr_chats') is null
     or to_regclass('public.msgr_messages') is null then
    raise exception 'Сначала установи таблицы профилей и мессенджера (SQL/01, SQL/17, SQL/18 и SQL/23).';
  end if;
  if to_regprocedure('public.msgr_support_reply(text)') is null then
    raise exception 'Сначала установи SQL/37_messenger_support_answers.sql.';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='profiles' and column_name='game_id'
  ) then
    raise exception 'Игровой ID не настроен. Сначала установи SQL/27 и SQL/38.';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='msgr_messages' and column_name='is_bot'
  ) then
    raise exception 'Чат поддержки не настроен. Сначала установи SQL/23.';
  end if;
end;
$check$;

-- Enforce uniqueness at the database level; existing duplicates must be resolved first.
create unique index if not exists profiles_game_id_unique
  on public.profiles(game_id) where game_id is not null;

-- A signed-in user can update only their own game ID. No user-id argument is accepted.
create or replace function public.cf_support_change_game_id(p_new_game_id text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_uid uuid := auth.uid();
  v_new_id text := btrim(coalesce(p_new_game_id,''));
  v_current_id text;
begin
  if v_uid is null then
    raise exception 'Нужно войти в аккаунт';
  end if;
  if v_new_id !~ '^[0-9]{6,7}$' then
    return jsonb_build_object('status','invalid_format');
  end if;

  select p.game_id into v_current_id
  from public.profiles p
  where p.id=v_uid;
  if not found then
    return jsonb_build_object('status','profile_missing');
  end if;
  if v_current_id=v_new_id then
    return jsonb_build_object('status','unchanged');
  end if;
  if exists(select 1 from public.profiles p where p.game_id=v_new_id and p.id<>v_uid) then
    return jsonb_build_object('status','taken');
  end if;

  begin
    update public.profiles set game_id=v_new_id where id=v_uid;
  exception when unique_violation then
    return jsonb_build_object('status','taken');
  end;
  return jsonb_build_object('status','updated');
end;
$$;
revoke all on function public.cf_support_change_game_id(text) from public,anon;
grant execute on function public.cf_support_change_game_id(text) to authenticated;

-- Extend the help text; the account-specific action is handled by msgr_send below.
create or replace function public.msgr_support_reply(p_text text)
returns text
language plpgsql
immutable
as $support$
declare
  t text := replace(lower(coalesce(p_text, '')), 'ё', 'е');
begin
  t := regexp_replace(t, '[[:space:][:punct:]]+', ' ', 'g');
  t := trim(t);

  if t = '' then
    return 'Напиши вопрос — помогу с регистрацией, ID, входом, восстановлением пароля, матчами и турнирами.';
  elsif t ~ '(сменить|изменить|поменять|обновить|смени|поменяй|change).*(id|айди|идентификатор)' then
    return 'Нажми «Сменить игровой ID» под чатом и введи новый уникальный ID из 6 или 7 цифр. Изменить можно только ID своего вошедшего аккаунта.';
  elsif t ~ '(забыл.*парол|forgot.*password|reset.*password|восстанов.*парол|сброс.*парол|парол.*(код|почт)|код.*(парол|восстанов)|invalid login credentials|user already registered)' then
    return 'Нажми «Восстановить пароль» под чатом: откроется защищённая форма. Код придёт на почту аккаунта; введи его только на сайте и задай новый пароль. Не отправляй пароль или код в чат поддержки.';
  elsif t ~ '(длина.*парол|парол.*длин|сколько.*символ.*парол|минимум.*парол)' then
    return 'Пароль должен содержать не менее 8 символов. Не используй пароль от других сайтов и никогда не отправляй его в чат.';
  elsif t ~ '(парол|password)' then
    return 'Войди по никнейму или адресу электронной почты и паролю. Если пароль не подходит, проверь ник/почту и восстанови пароль через кнопку «Восстановить пароль» под чатом. Не отправляй пароль или код из письма в чат.';
  elsif t ~ '(игров.{0,12}(id|айди|номер)|id.{0,12}игрок|айди|game id|игровой идентификатор|сколько цифр)' then
    return 'Игровой ID должен содержать 6 или 7 цифр и быть уникальным. Чтобы сменить его в своём аккаунте, нажми «Сменить игровой ID» под чатом.';
  elsif t ~ '(регистрац|зарегистрир|создат.*аккаунт|новый аккаунт|уже зарегистрир|подтвержден.*почт)' then
    return 'Для регистрации укажи ник, почту, игровой ID из 6 или 7 цифр и пароль от 8 символов. Если почта уже зарегистрирована, войди или восстанови пароль по email-коду.';
  elsif t ~ '(войти|вход|логин|не могу войти|не пускает|аккаунт)' then
    return 'Войди по никнейму или адресу электронной почты и паролю. Игровой ID для входа не нужен; он используется при регистрации. Если забыл пароль, используй кнопку «Восстановить пароль» под чатом или «Забыл пароль» на экране входа.';
  elsif t ~ '(таймер|сколько.*минут|сколько.*идет|время.*матч|конец.*матч)' then
    return 'После начала игры сайт показывает таймер на 15 минут. Когда он закончится, открой матч и отправь скриншот итоговой таблицы.';
  elsif t ~ '(скрин|прикреп|загруз.*файл|файл.*результат|итог.*матч|счет|счёт|результат)' then
    return 'После окончания 15-минутного таймера открой карточку матча, нажми отправку результата и выбери JPG, PNG или WebP со скриншотом итоговой таблицы.';
  elsif t ~ '(отмен.*матч|матч.*отмен|отклон.*матч|не приняли|отмена)' then
    return 'Если матч отменён до начала игры, вернись в раздел «Играть» и запусти поиск заново. Отменённые матчи и связанные записи очереди удаляются не раньше чем через 20 минут, ближайшим запуском очистки.';
  elsif t ~ '(матч|поиск|очеред|найти|подбор|играть)' then
    return 'Открой «Играть», выбери режим и карту и нажми «Найти матч». Для подбора нужны другие игроки в очереди.';
  elsif t ~ '(elo|эло|рейтинг|ранг)' then
    return 'После подтверждения результата изменение ELO можно посмотреть в профиле и истории матчей.';
  elsif t ~ '(турнир)' then
    return 'Открой раздел «Турниры»: там публикуются доступные турниры, карты, команды и расписание.';
  elsif t ~ '(парол|код из письма|одноразов.*код|otp)' then
    return 'Для восстановления используй кнопку «Восстановить пароль» под чатом. Пароль и одноразовый email-код нельзя отправлять в переписку.';
  elsif t ~ '(спонсор|значок|поддержать|привилег|100 ?₽|100 ?руб)' then
    return 'Чтобы получить значок спонсора LX FACEIT и привилегии, поддержи проект минимум на 100 ₽ через Telegram @prisedents. После подтверждения поддержки значок выдаёт администрация. Ссылка: https://t.me/prisedents.';
  elsif t ~ '(поддержк|помог|оператор|человек|связаться|контакт)' then
    return 'Я автоматически отвечаю на частые вопросы. По смене ID и восстановлению пароля используй кнопки под чатом. Не отправляй пароль или email-код.';
  elsif t ~ '(спасиб|благодар)' then
    return 'Пожалуйста! Если что-то ещё понадобится — напиши вопрос здесь.';
  end if;

  return 'Я не нашёл точного ответа в справке. Спроси про игровой ID, вход, восстановление пароля, матч, ELO или значок спонсора. Не отправляй пароль или код из письма.';
end;
$support$;

-- Support chat actions are scoped to auth.uid(); sensitive credentials are discarded before storage.
create or replace function public.msgr_send(p_chat uuid, p_body text)
returns bigint
language plpgsql
security definer
set search_path=public
as $$
declare
  v_uid uuid := auth.uid();
  v_chat public.msgr_chats;
  v_body text := trim(coalesce(p_body,''));
  v_id bigint;
  v_match text[];
  v_change jsonb;
  v_reply text;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select * into v_chat from public.msgr_chats where id=p_chat;
  if not found then raise exception 'Чат не найден'; end if;
  if v_chat.kind='channel' and v_chat.owner_id<>v_uid then raise exception 'В канале пишет только владелец'; end if;
  if v_chat.kind='support' and v_chat.owner_id<>v_uid then raise exception 'Чат не найден'; end if;
  if not exists(select 1 from public.msgr_members where chat_id=p_chat and user_id=v_uid) then
    raise exception 'Сначала вступи в чат';
  end if;
  if v_body='' or char_length(v_body)>1000 then raise exception 'Сообщение: от 1 до 1000 символов'; end if;
  if exists(select 1 from public.msgr_messages where user_id=v_uid and created_at>now()-interval '700 milliseconds') then
    raise exception 'Слишком часто';
  end if;

  if v_chat.kind='support' and (
    v_body ~* '((парол[ья]?|password)([[:space:]]+(мой|моя))?[[:space:]]*[:=][[:space:]]*[^[:space:]]+|(мой|моя)[[:space:]]+(парол[ья]?|password)[[:space:]]+[^[:space:]]+|(парол[ья]?|password)[[:space:]]+(мой|моя)[[:space:]]+[^[:space:]]+)'
    or v_body ~* 'код([[:space:]]+из[[:space:]]+письма|[[:space:]]+восстановления|[[:space:]]+сброса|[[:space:]]+подтверждения)?[[:space:]]*[:=][[:space:]]*[0-9]{4,10}|код([[:space:]]+из[[:space:]]+письма|[[:space:]]+восстановления|[[:space:]]+сброса|[[:space:]]+подтверждения)?[[:space:]]+[0-9]{4,10}'
    or v_body ~ '^[0-9]{6}$'
  ) then
    insert into public.msgr_messages(chat_id,user_id,body,is_bot)
    values(p_chat,v_uid,'Не отправляй пароль или код из письма в чат. Такие данные не сохраняются. Используй кнопку восстановления пароля под чатом.',true)
    returning id into v_id;
    return v_id;
  end if;

  insert into public.msgr_messages(chat_id,user_id,body) values(p_chat,v_uid,v_body) returning id into v_id;

  if v_chat.kind='support' then
    v_match := regexp_match(v_body,'(сменить|изменить|поменять|обновить|смени|поменяй|change)[[:space:]]+((игровой|game)[[:space:]]+)?(идентификатор|айди|id|ид)([[:space:]]+на)?[[:space:]:#-]*([0-9]{1,12})','i');
    if v_match is not null then
      v_change := public.cf_support_change_game_id(v_match[6]);
      v_reply := case (v_change->>'status')
        when 'updated' then 'Игровой ID изменён. Для следующего входа используй новый ID. Если ты не запрашивал это изменение, сразу восстанови пароль по email.'
        when 'unchanged' then 'Этот ID уже установлен в твоём аккаунте.'
        when 'taken' then 'Этот ID уже используется другим игроком. Выбери другой уникальный ID.'
        when 'invalid_format' then 'ID должен содержать ровно 6 или 7 цифр.'
        else 'Не удалось найти профиль аккаунта. Перезайди на сайт и попробуй ещё раз.'
      end;
    elsif v_body ~* '(сменить|изменить|поменять|обновить|смени|поменяй|change).*(id|айди|идентификатор)' then
      v_reply := 'Чтобы сменить ID, нажми кнопку «Сменить игровой ID» под чатом или отправь сообщение в формате: Сменить ID 123456. Нужен уникальный ID из 6 или 7 цифр.';
    else
      v_reply := public.msgr_support_reply(v_body);
    end if;
    insert into public.msgr_messages(chat_id,user_id,body,is_bot) values(p_chat,v_uid,v_reply,true);
  end if;
  return v_id;
end;
$$;
revoke all on function public.msgr_send(uuid,text) from public,anon;
grant execute on function public.msgr_send(uuid,text) to authenticated;

commit;

select 'Support chat can securely change the signed-in user game ID and open email-code password recovery' as result;

-- ==================== Included source: 41_player_host_and_moderation.sql ====================
-- LX FACEIT v46: player-owned room flow, enforced matchmaking restrictions,
-- staff cooperation badge, day-based bans and temporary match-launch limits.
-- Run after matchmaking SQL/10-16, timer SQL/21 and SQL/35, moderation SQL/28,
-- cooldown SQL/30, regional matchmaking SQL/39 and support SQL/40. Does not alter Elo/results.

begin;

do $roles$
declare c record;
begin
  for c in
    select conname from pg_constraint
    where conrelid='public.profiles'::regclass
      and contype='c'
      and pg_get_constraintdef(oid) ilike '%role%'
  loop
    execute format('alter table public.profiles drop constraint %I',c.conname);
  end loop;
  alter table public.profiles
    add constraint profiles_role_allowed
    check (role in ('player','tester','cooperation','admin','founder'));
end;
$roles$;

-- Require SQL/28's private moderation table; never expose ban data on profiles.
do $check$
begin
  if to_regclass('public.cf_player_moderation') is null then
    raise exception 'Сначала выполни SQL/28_v30_prime_bans_banners.sql.';
  end if;
  if to_regprocedure('public.cf_lobby_match_state()') is null
     or to_regprocedure('public.cf_matchmaking_try_form(text,text)') is null then
    raise exception 'Сначала установи matchmaking SQL/10-16 и SQL/39.';
  end if;
  if not exists (
    select 1 from pg_trigger t
    join pg_proc p on p.oid=t.tgfoid
    where t.tgrelid='public.cf_lobby_matches'::regclass
      and p.proname='cf_match_auto_live' and not t.tgisinternal
  ) then
    raise exception 'Сначала установи SQL/21_auto_match_live.sql и SQL/35_match_timer_and_screenshot_fix.sql.';
  end if;
end;
$check$;

-- Keep stored, bounded HTTPS/custom-image avatars in every server-backed list.
create or replace function public.cf_lobby_user_json(p_uid uuid)
returns jsonb language sql stable security definer set search_path=public as $$
  select jsonb_build_object(
    'id',p.id,'nickname',p.nickname,
    'display_name',coalesce(nullif(p.display_name,''),p.nickname),
    'avatar',case
      when char_length(coalesce(p.avatar,''))<=1000 and p.avatar ~* '^https://[^[:space:]]+$' then p.avatar
      when char_length(coalesce(p.avatar,''))<=40000 and p.avatar ~ '^data:image/(png|jpeg|webp|gif);base64,' then p.avatar
      when p.avatar in ('ember','steel','azure','moss','plum','sand') then p.avatar
      else 'ember' end,
    'elo',coalesce(p.elo,800),'verified',coalesce(p.verified,false),'role',coalesce(p.role,'player')
  ) from public.profiles p where p.id=p_uid
$$;
create or replace function public.cf_friend_profile(p_uid uuid)
returns jsonb language sql stable security definer set search_path=public as $$
  select public.cf_lobby_user_json(p_uid)
$$;

alter table public.cf_lobby_matches
  add column if not exists live_started_at timestamptz,
  add column if not exists play_ends_at timestamptz;

alter table public.cf_player_moderation
  add column if not exists match_restricted_until timestamptz,
  add column if not exists match_restriction_reason text not null default '';

-- Staff lookup: only trusted admins/founder can assign roles. Cooperation is
-- a separate role, not an admin privilege; its blue badge is rendered by role.
create or replace function public.cf_manage_staff_lookup(
  p_target text,
  p_role text,
  p_verified boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth
as $function$
declare
  v_actor uuid:=auth.uid();
  v_actor_role text;
  v_target uuid;
  v_target_role text;
  v_nickname text;
begin
  if v_actor is null then raise exception 'Нужно войти в аккаунт'; end if;
  if nullif(trim(p_target),'') is null then raise exception 'Укажи ник, почту, игровой ID или UUID'; end if;
  if p_role is null or p_role not in ('player','tester','cooperation','admin') then
    raise exception 'Недопустимая роль';
  end if;
  select role into v_actor_role from public.profiles where id=v_actor;
  if coalesce(v_actor_role,'player') not in ('founder','admin') then raise exception 'Недостаточно прав'; end if;

  if trim(p_target) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select id,role,nickname into v_target,v_target_role,v_nickname
    from public.profiles where id=trim(p_target)::uuid;
  elsif position('@' in p_target)>0 then
    select p.id,p.role,p.nickname into v_target,v_target_role,v_nickname
    from auth.users u join public.profiles p on p.id=u.id
    where lower(u.email)=lower(trim(p_target)) limit 1;
  elsif trim(p_target) ~ '^[0-9]{6,7}$' then
    select id,role,nickname into v_target,v_target_role,v_nickname
    from public.profiles where game_id=trim(p_target) limit 1;
  else
    select id,role,nickname into v_target,v_target_role,v_nickname
    from public.profiles where lower(nickname)=lower(trim(p_target)) limit 1;
  end if;

  if v_target is null then raise exception 'Игрок не найден. Проверь ник, почту, ID или UUID'; end if;
  if v_target_role='founder' then raise exception 'Нельзя изменить роль основателя'; end if;
  if v_actor_role='admin' then
    if p_role='admin' then raise exception 'Только основатель может выдавать админку'; end if;
    if v_target_role='admin' then raise exception 'Администратор не может менять права другого администратора'; end if;
    if v_target=v_actor then raise exception 'Нельзя изменять собственные права'; end if;
  end if;

  update public.profiles set role=p_role,verified=coalesce(p_verified,false) where id=v_target;
  return jsonb_build_object('ok',true,'user_id',v_target,'nickname',v_nickname,
    'role',p_role,'verified',coalesce(p_verified,false));
end;
$function$;
revoke all on function public.cf_manage_staff_lookup(text,text,boolean) from public,anon;
grant execute on function public.cf_manage_staff_lookup(text,text,boolean) to authenticated;

-- Status endpoint reports only the signed-in player's own moderation details.
create or replace function public.cf_my_moderation()
returns jsonb
language plpgsql
stable
security definer
set search_path=public
as $function$
declare v_uid uuid:=auth.uid(); v_row public.cf_player_moderation%rowtype;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select * into v_row from public.cf_player_moderation where user_id=v_uid;
  if not found then
    return jsonb_build_object('is_permanently_banned',false,'banned_until',null,'ban_reason','',
      'match_restricted_until',null,'match_restriction_reason','');
  end if;
  return jsonb_build_object(
    'is_permanently_banned',coalesce(v_row.is_permanently_banned,false),
    'banned_until',case when v_row.banned_until>clock_timestamp() then v_row.banned_until else null end,
    'ban_reason',case when v_row.is_permanently_banned or v_row.banned_until>clock_timestamp() then v_row.ban_reason else '' end,
    'match_restricted_until',case when v_row.match_restricted_until>clock_timestamp() then v_row.match_restricted_until else null end,
    'match_restriction_reason',case when v_row.match_restricted_until>clock_timestamp() then v_row.match_restriction_reason else '' end);
end;
$function$;
revoke all on function public.cf_my_moderation() from public,anon;
grant execute on function public.cf_my_moderation() to authenticated;

-- Set/remove a temporary match-launch limit. 0 days removes the limit.
create or replace function public.cf_admin_set_match_restriction(
  p_target text,
  p_days integer,
  p_reason text default ''
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $function$
declare
  v_actor uuid:=auth.uid();
  v_actor_role text;
  v_target public.profiles%rowtype;
  v_until timestamptz;
  v_reason text:=left(trim(coalesce(p_reason,'')),300);
begin
  if v_actor is null then raise exception 'Нужно войти в аккаунт'; end if;
  select role into v_actor_role from public.profiles where id=v_actor;
  if coalesce(v_actor_role,'player') not in ('admin','founder') then raise exception 'Недостаточно прав'; end if;
  if p_days is null or p_days<0 or p_days>3650 then raise exception 'Срок должен быть от 0 до 3650 дней'; end if;
  select * into v_target from public.profiles
  where lower(nickname)=lower(trim(p_target)) or game_id=trim(p_target) or id::text=trim(p_target)
  order by case when lower(nickname)=lower(trim(p_target)) then 0 when game_id=trim(p_target) then 1 else 2 end
  limit 1 for update;
  if not found then raise exception 'Игрок не найден'; end if;
  if v_target.id=v_actor then raise exception 'Нельзя ограничить самого себя'; end if;
  if coalesce(v_target.role,'player') in ('admin','founder') then raise exception 'Нельзя ограничить запуск матчей администратору или основателю'; end if;

  if p_days=0 then
    update public.cf_player_moderation
      set match_restricted_until=null,match_restriction_reason='',updated_at=clock_timestamp(),updated_by=v_actor
      where user_id=v_target.id;
    return jsonb_build_object('ok',true,'id',v_target.id,'nickname',v_target.nickname,'match_restricted_until',null,'removed',true);
  end if;
  if v_reason='' then raise exception 'Укажи причину ограничения'; end if;
  v_until:=clock_timestamp()+make_interval(days=>p_days);
  insert into public.cf_player_moderation(user_id,match_restricted_until,match_restriction_reason,updated_at,updated_by)
  values(v_target.id,v_until,v_reason,clock_timestamp(),v_actor)
  on conflict(user_id) do update set match_restricted_until=excluded.match_restricted_until,
    match_restriction_reason=excluded.match_restriction_reason,updated_at=excluded.updated_at,updated_by=excluded.updated_by;

  update public.cf_matchmaking_queue q set queue_status='cancelled',updated_at=clock_timestamp()
  where q.queue_status='queued' and v_target.id=any(q.party_ids);
  update public.cf_lobby_matches m set status='cancelled',cancel_reason='Запуск матчей временно ограничен администратором',updated_at=clock_timestamp()
  where v_target.id=any(m.participant_ids)
    and m.status in ('searching','found','choose_host','host_selected','pending_admin','taken','room','joined');

  return jsonb_build_object('ok',true,'id',v_target.id,'nickname',v_target.nickname,'match_restricted_until',v_until,'reason',v_reason);
end;
$function$;
revoke all on function public.cf_admin_set_match_restriction(text,integer,text) from public,anon;
grant execute on function public.cf_admin_set_match_restriction(text,integer,text) to authenticated;

-- Recreate the existing ban RPC with queue/pre-start cleanup. p_hours remains
-- compatible with SQL/28 and the deployed site; the UI now accepts days.
create or replace function public.cf_admin_set_ban(p_target text,p_hours integer,p_reason text default '')
returns jsonb
language plpgsql
security definer
set search_path=public
as $function$
declare
  v_uid uuid:=auth.uid(); v_role text; v_target public.profiles%rowtype;
  v_until timestamptz; v_perm boolean:=false; v_reason text:=left(trim(coalesce(p_reason,'')),300);
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select role into v_role from public.profiles where id=v_uid;
  if coalesce(v_role,'player') not in ('admin','founder') then raise exception 'Недостаточно прав'; end if;
  if p_hours is null or p_hours < -1 or p_hours > 87600 then raise exception 'Недопустимый срок блокировки'; end if;
  select * into v_target from public.profiles
  where lower(nickname)=lower(trim(p_target)) or game_id=trim(p_target) or id::text=trim(p_target)
  order by case when lower(nickname)=lower(trim(p_target)) then 0 when game_id=trim(p_target) then 1 else 2 end
  limit 1 for update;
  if not found then raise exception 'Игрок не найден'; end if;
  if v_target.id=v_uid then raise exception 'Нельзя заблокировать самого себя'; end if;
  if coalesce(v_target.role,'player') in ('admin','founder') then raise exception 'Нельзя заблокировать администратора или основателя через эту форму'; end if;

  if p_hours=-1 then
    update public.cf_player_moderation set banned_until=null,is_permanently_banned=false,ban_reason='',updated_at=clock_timestamp(),updated_by=v_uid
    where user_id=v_target.id;
    return jsonb_build_object('ok',true,'id',v_target.id,'nickname',v_target.nickname,'banned_until',null,'is_permanently_banned',false,'unbanned',true);
  elsif p_hours=0 then
    v_perm:=true; v_until:=null;
  else
    v_until:=clock_timestamp()+make_interval(hours=>p_hours);
  end if;
  if v_reason='' then raise exception 'Укажи причину блокировки'; end if;
  insert into public.cf_player_moderation(user_id,banned_until,is_permanently_banned,ban_reason,updated_at,updated_by)
  values(v_target.id,v_until,v_perm,v_reason,clock_timestamp(),v_uid)
  on conflict(user_id) do update set banned_until=excluded.banned_until,is_permanently_banned=excluded.is_permanently_banned,
    ban_reason=excluded.ban_reason,updated_at=excluded.updated_at,updated_by=excluded.updated_by;

  update public.cf_matchmaking_queue q set queue_status='cancelled',updated_at=clock_timestamp()
  where q.queue_status='queued' and v_target.id=any(q.party_ids);
  update public.cf_lobby_matches m set status='cancelled',cancel_reason='Аккаунт заблокирован администратором',updated_at=clock_timestamp()
  where v_target.id=any(m.participant_ids)
    and m.status in ('searching','found','choose_host','host_selected','pending_admin','taken','room','joined');

  return jsonb_build_object('ok',true,'id',v_target.id,'nickname',v_target.nickname,'banned_until',v_until,'is_permanently_banned',v_perm,'ban_reason',v_reason);
end;
$function$;
revoke all on function public.cf_admin_set_ban(text,integer,text) from public,anon;
grant execute on function public.cf_admin_set_ban(text,integer,text) to authenticated;

-- Queue inserts are a second server-side guard in addition to the RPC check.
create or replace function public.cf_v46_guard_restricted_queue()
returns trigger
language plpgsql
security definer
set search_path=public
as $function$
begin
  if new.queue_status='queued' and exists (
    select 1 from unnest(new.party_ids) as member(user_id)
    join public.cf_player_moderation moderation on moderation.user_id=member.user_id
    where moderation.is_permanently_banned
       or moderation.banned_until>clock_timestamp()
       or moderation.match_restricted_until>clock_timestamp()
  ) then
    raise exception 'В составе лобби есть игрок, которому запрещено запускать матчи';
  end if;
  return new;
end;
$function$;
revoke all on function public.cf_v46_guard_restricted_queue() from public,anon,authenticated;
drop trigger if exists cf_v46_guard_restricted_queue on public.cf_matchmaking_queue;
create trigger cf_v46_guard_restricted_queue
before insert or update of queue_status,party_ids on public.cf_matchmaking_queue
for each row execute function public.cf_v46_guard_restricted_queue();

-- An unaccepted/single player is still a valid matchmaking party: create exactly
-- one private lobby on demand, but never create duplicate solo lobbies.
create or replace function public.cf_lobby_match_start(p_mode text,p_map text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $function$
declare
  v_uid uuid:=auth.uid(); v_lobby uuid; v_ids uuid[]; v_count integer;
  v_team_size integer; v_active uuid; v_region text;
  v_banned boolean:=false; v_ban_until timestamptz; v_ban_reason text;
  v_restricted_until timestamptz; v_restriction_reason text;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  if p_mode not in ('ranked','duo') then raise exception 'Недопустимый режим'; end if;
  if p_map not in ('Mirage','Dust2','Vertigo','Inferno') then raise exception 'Недопустимая карта'; end if;
  v_team_size:=case when p_mode='duo' then 2 else 5 end;

  select coalesce(p.region,'ru') into v_region from public.profiles p where p.id=v_uid;
  if not found then raise exception 'Профиль не найден. Перезайди в аккаунт'; end if;
  select m.is_permanently_banned,m.banned_until,m.ban_reason,m.match_restricted_until,m.match_restriction_reason
    into v_banned,v_ban_until,v_ban_reason,v_restricted_until,v_restriction_reason
  from public.cf_player_moderation m where m.user_id=v_uid;
  if coalesce(v_banned,false) or v_ban_until>clock_timestamp() then
    raise exception 'Аккаунт заблокирован: %',coalesce(nullif(v_ban_reason,''),'обратись в поддержку');
  end if;
  if v_restricted_until>clock_timestamp() then
    raise exception 'Запуск матчей ограничен до %: %',to_char(v_restricted_until at time zone 'UTC','YYYY-MM-DD HH24:MI UTC'),coalesce(nullif(v_restriction_reason,''),'обратись к администратору');
  end if;
  if v_region not in ('ru','eu','asia','all') then raise exception 'Недопустимый регион'; end if;

  perform pg_advisory_xact_lock(hashtext('cf:v9:queue-user:'||v_uid::text));
  select lm.lobby_id into v_lobby from public.lobby_members lm where lm.user_id=v_uid;
  if v_lobby is null then
    insert into public.lobbies(owner_id) values(v_uid) returning id into v_lobby;
    insert into public.lobby_members(lobby_id,user_id) values(v_lobby,v_uid);
  end if;

  select m.id into v_active from public.cf_lobby_matches m
  where v_uid=any(m.participant_ids) and m.status not in ('done','cancelled')
  order by m.created_at desc limit 1;
  if v_active is not null then return public.cf_lobby_match_state(); end if;

  select array_agg(user_id order by joined_at),count(*) into v_ids,v_count
  from public.lobby_members where lobby_id=v_lobby;
  if coalesce(v_count,0)<1 then raise exception 'Лобби пустое. Создай группу и попробуй ещё раз'; end if;
  if v_count>v_team_size then
    raise exception 'В режиме % можно сохранить в одной группе максимум % игроков. Разделите лобби или выберите 5×5.',p_mode,v_team_size;
  end if;
  if exists (
    select 1 from unnest(v_ids) as member(user_id)
    join public.cf_player_moderation moderation on moderation.user_id=member.user_id
    where moderation.is_permanently_banned or moderation.banned_until>clock_timestamp()
       or moderation.match_restricted_until>clock_timestamp()
  ) then raise exception 'В составе лобби есть игрок, которому запрещено запускать матчи'; end if;

  if v_region<>'all' and exists (
    select 1 from unnest(v_ids) as member(user_id)
    left join public.profiles p on p.id=member.user_id
    where p.id is null or coalesce(p.region,'ru') not in (v_region,'all')
  ) then raise exception 'У всех игроков в лобби должен совпадать регион или стоять «Все регионы». Попроси друзей изменить регион в настройках.'; end if;

  if exists(select 1 from public.cf_matchmaking_queue q where q.lobby_id=v_lobby and q.queue_status='queued') then
    return public.cf_lobby_match_state();
  end if;
  insert into public.cf_matchmaking_queue(lobby_id,party_ids,mode,map_name,region)
  values(v_lobby,v_ids,p_mode,p_map,v_region);
  perform public.cf_matchmaking_try_form(p_mode,v_region);
  return public.cf_lobby_match_state();
end;
$function$;
revoke all on function public.cf_lobby_match_start(text,text) from public,anon;
grant execute on function public.cf_lobby_match_start(text,text) to authenticated;

-- Matchmaking participants choose a player host only; admins cannot create or publish rooms.
create or replace function public.cf_lobby_match_choose_host(p_choice text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $function$
declare v_uid uuid:=auth.uid(); v_match public.cf_lobby_matches%rowtype; v_host uuid; v_host_nick text;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  if p_choice is distinct from 'player' then raise exception 'Комнату может создать только игрок-участник матча'; end if;
  select * into v_match from public.cf_lobby_matches m
  where v_uid=any(m.participant_ids) and m.status='choose_host'
  order by m.created_at desc limit 1 for update;
  if not found then raise exception 'Выбор организатора уже закрыт'; end if;
  select uid into v_host from unnest(v_match.participant_ids) as x(uid) order by random() limit 1;
  select nickname into v_host_nick from public.profiles where id=v_host;
  update public.cf_lobby_matches
  set host_choice='player',room_host_id=v_host,room_host_nickname=coalesce(v_host_nick,'Игрок'),
      admin_id=null,admin_nickname='',status='host_selected',updated_at=clock_timestamp()
  where id=v_match.id;
  return public.cf_lobby_match_state();
end;
$function$;
revoke all on function public.cf_lobby_match_choose_host(text) from public,anon;
grant execute on function public.cf_lobby_match_choose_host(text) to authenticated;

-- Publishing a room code leaves it cancellable; it must not start the timer.
create or replace function public.cf_lobby_match_player_publish_code(p_code text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $function$
declare v_uid uuid:=auth.uid(); v_match public.cf_lobby_matches%rowtype; v_nick text;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  if nullif(trim(p_code),'') is null or char_length(trim(p_code))>64 then
    raise exception 'Введи код комнаты длиной от 1 до 64 символов';
  end if;
  select * into v_match from public.cf_lobby_matches m
  where v_uid=m.room_host_id and m.status='host_selected'
  order by m.created_at desc limit 1 for update;
  if not found then raise exception 'Только выбранный игрок-организатор может опубликовать код'; end if;
  select nickname into v_nick from public.profiles where id=v_uid;
  update public.cf_lobby_matches
  set status='room',room_code=trim(p_code),admin_id=null,
      admin_nickname=coalesce(v_nick,'Игрок'),updated_at=clock_timestamp()
  where id=v_match.id;
  return public.cf_lobby_match_state();
end;
$function$;
revoke all on function public.cf_lobby_match_player_publish_code(text) from public,anon;
grant execute on function public.cf_lobby_match_player_publish_code(text) to authenticated;

-- Start the game only after the selected player confirms everyone is in the room.
create or replace function public.cf_lobby_match_player_start()
returns jsonb
language plpgsql
security definer
set search_path=public
as $function$
declare v_uid uuid:=auth.uid(); v_match public.cf_lobby_matches%rowtype;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select * into v_match from public.cf_lobby_matches m
  where m.room_host_id=v_uid and m.status='room'
  order by m.created_at desc limit 1 for update;
  if not found then raise exception 'Только организатор может начать матч после публикации кода комнаты'; end if;
  update public.cf_lobby_matches set status='joined',updated_at=clock_timestamp() where id=v_match.id;
  return public.cf_lobby_match_state();
end;
$function$;
revoke all on function public.cf_lobby_match_player_start() from public,anon;
grant execute on function public.cf_lobby_match_player_start() to authenticated;

-- Replace the old auto-live-on-room trigger behavior. Creating/publishing a
-- room leaves status='room'; the player-start RPC transitions joined -> live.
create or replace function public.cf_match_auto_live()
returns trigger
language plpgsql
set search_path=public
as $function$
declare v_now timestamptz:=clock_timestamp();
begin
  if new.status='joined' and old.status is distinct from 'joined' then
    new.status:='live';
    new.live_started_at:=v_now;
    new.play_ends_at:=v_now+interval '15 minutes';
  elsif new.status='live' and old.status is distinct from 'live' then
    new.live_started_at:=coalesce(new.live_started_at,v_now);
    new.play_ends_at:=coalesce(new.play_ends_at,new.live_started_at+interval '15 minutes');
  end if;
  return new;
end;
$function$;

-- Admins may still cancel a match and review submitted results, but cannot take
-- over or publish room codes. The room lifecycle belongs to the player host.
create or replace function public.cf_lobby_match_admin_action(p_match uuid,p_action text,p_code text default null)
returns jsonb
language plpgsql
security definer
set search_path=public
as $function$
declare v_uid uuid:=auth.uid(); v_role text; v_match public.cf_lobby_matches%rowtype;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select role into v_role from public.profiles where id=v_uid;
  if coalesce(v_role,'player') not in ('admin','founder') then raise exception 'Недостаточно прав'; end if;
  if p_action is distinct from 'cancel' then raise exception 'Комнату и код настраивает выбранный игрок-организатор'; end if;
  select * into v_match from public.cf_lobby_matches where id=p_match for update;
  if not found then raise exception 'Матч не найден'; end if;
  if v_match.status in ('done','cancelled') then raise exception 'Матч уже завершён'; end if;
  update public.cf_lobby_matches set status='cancelled',cancel_reason='Отменено администратором',updated_at=clock_timestamp()
  where id=p_match and status not in ('done','cancelled');
  if not found then raise exception 'Матч уже завершён'; end if;
  return jsonb_build_object('ok',true,'match_id',v_match.id,'status','cancelled','cancel_reason','Отменено администратором');
end;
$function$;
revoke all on function public.cf_lobby_match_admin_action(uuid,text,text) from public,anon;
grant execute on function public.cf_lobby_match_admin_action(uuid,text,text) to authenticated;

-- Reopen legacy matches that were waiting for an administrator to set up a room.
-- The next participant poll returns them to player-only host selection.
update public.cf_lobby_matches
set status='choose_host',admin_id=null,admin_nickname='',updated_at=clock_timestamp()
where status in ('pending_admin','taken')
  and cardinality(accepted_by)>=cardinality(participant_ids)
  and cardinality(participant_ids)>0;

-- Existing restricted queue entries and pre-start matches cannot slip through
-- just because they were created before this migration was installed.
update public.cf_matchmaking_queue q set queue_status='cancelled',updated_at=clock_timestamp()
where q.queue_status='queued' and exists (
  select 1 from unnest(q.party_ids) as member(user_id)
  join public.cf_player_moderation moderation on moderation.user_id=member.user_id
  where moderation.is_permanently_banned or moderation.banned_until>clock_timestamp()
     or moderation.match_restricted_until>clock_timestamp()
);
update public.cf_lobby_matches m
set status='cancelled',cancel_reason='Запуск матчей запрещён действующей модерацией',updated_at=clock_timestamp()
where m.status in ('searching','found','choose_host','host_selected','pending_admin','taken','room','joined')
  and exists (
    select 1 from unnest(m.participant_ids) as member(user_id)
    join public.cf_player_moderation moderation on moderation.user_id=member.user_id
    where moderation.is_permanently_banned or moderation.banned_until>clock_timestamp()
       or moderation.match_restricted_until>clock_timestamp()
  );

commit;

select 'LX FACEIT v46 player room flow, match restrictions and staff cooperation role installed' as result;

-- ==================== Included source: 42_sponsor_badge_and_profile_customization.sql ====================
-- LX FACEIT v49: sponsor badge, profile nickname styles and personal site wallpaper.
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

select 'LX FACEIT v49 sponsor badge and profile customization installed' as result;

-- ==================== Included source: 43_game_demos.sql ====================
-- LX FACEIT v50: player demo gallery with private Storage and an atomic hourly upload limit.
-- Run in Supabase SQL Editor AFTER SQL/42_sponsor_badge_and_profile_customization.sql.
-- Assumption: Standoff 2 replay files use the common .dem extension. If the game exports another format,
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

select 'LX FACEIT v50 demo gallery and hourly server-side upload limit installed' as result;

-- ==================== Included source: 44_demo_author_attribution.sql ====================
-- LX FACEIT v51: include a safe, explicit uploader name in every shared demo entry.
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

select 'LX FACEIT v51 shared demo author field installed' as result;

-- ==================== Included source: 45_mp4_game_demos.sql ====================
-- LX FACEIT: enable .mp4 video uploads alongside .dem replays.
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

-- ==================== Included source: 46_owner_news_media.sql ====================
-- LX FACEIT v53: owner-only publishing of shared news with photo/MP4 media.
-- Run in Supabase SQL Editor after the base online schema and role/moderation SQL.

begin;

do $requirements$
begin
  if to_regclass('public.profiles') is null then
    raise exception 'Сначала установи основную схему онлайн-аккаунтов и таблицу public.profiles.';
  end if;
end;
$requirements$;

create table if not exists public.news (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text not null default '',
  link text,
  image_path text,
  published boolean not null default false,
  author_id uuid references auth.users(id),
  created_at timestamptz not null default now()
);

alter table public.news
  add column if not exists title text not null default '',
  add column if not exists description text not null default '',
  add column if not exists link text,
  add column if not exists image_path text,
  add column if not exists media_path text,
  add column if not exists media_type text,
  add column if not exists published boolean not null default false,
  add column if not exists author_id uuid references auth.users(id),
  add column if not exists created_at timestamptz not null default now();

do $constraint$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid='public.news'::regclass and conname='cf_news_media_type_allowed'
  ) then
    alter table public.news add constraint cf_news_media_type_allowed
      check (media_type is null or media_type in ('image','video'));
  end if;
end;
$constraint$;

alter table public.news enable row level security;
-- Remove any legacy write policies: publishing is only through the checked RPC below.
do $policies$
declare p record;
begin
  for p in select policyname from pg_policies where schemaname='public' and tablename='news' loop
    execute format('drop policy %I on public.news',p.policyname);
  end loop;
end;
$policies$;
create policy cf_news_public_read_published on public.news
  for select to anon,authenticated using (published=true);
revoke all on public.news from public,anon,authenticated;
grant select on public.news to anon,authenticated;

insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values ('cf-news-media','cf-news-media',true,52428800,
        array['image/jpeg','image/png','image/webp','image/gif','video/mp4']::text[])
on conflict (id) do update set name=excluded.name,public=true,
  file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

-- Public media is deliberately readable; only a founder can create, replace or delete it.
drop policy if exists cf_news_media_public_read on storage.objects;
create policy cf_news_media_public_read on storage.objects
  for select to anon,authenticated using (bucket_id='cf-news-media');
drop policy if exists cf_news_media_founder_insert on storage.objects;
create policy cf_news_media_founder_insert on storage.objects
  for insert to authenticated with check (
    bucket_id='cf-news-media'
    and (storage.foldername(name))[1]=auth.uid()::text
    and exists (select 1 from public.profiles p where p.id=auth.uid() and p.role='founder')
  );
drop policy if exists cf_news_media_founder_update on storage.objects;
create policy cf_news_media_founder_update on storage.objects
  for update to authenticated using (
    bucket_id='cf-news-media'
    and (storage.foldername(name))[1]=auth.uid()::text
    and exists (select 1 from public.profiles p where p.id=auth.uid() and p.role='founder')
  ) with check (
    bucket_id='cf-news-media'
    and (storage.foldername(name))[1]=auth.uid()::text
    and exists (select 1 from public.profiles p where p.id=auth.uid() and p.role='founder')
  );
drop policy if exists cf_news_media_founder_delete on storage.objects;
create policy cf_news_media_founder_delete on storage.objects
  for delete to authenticated using (
    bucket_id='cf-news-media'
    and (storage.foldername(name))[1]=auth.uid()::text
    and exists (select 1 from public.profiles p where p.id=auth.uid() and p.role='founder')
  );

create or replace function public.cf_owner_publish_news(
  p_title text,
  p_description text,
  p_link text default null,
  p_media_path text default null,
  p_media_type text default null
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,auth,storage
as $function$
declare
  v_uid uuid:=auth.uid();
  v_role text;
  v_title text:=btrim(coalesce(p_title,''));
  v_description text:=btrim(coalesce(p_description,''));
  v_link text:=nullif(btrim(coalesce(p_link,'')),'');
  v_path text:=nullif(btrim(coalesce(p_media_path,'')),'');
  v_type text:=nullif(btrim(coalesce(p_media_type,'')),'');
  v_news public.news%rowtype;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт владельца'; end if;
  select p.role into v_role from public.profiles p where p.id=v_uid;
  if coalesce(v_role,'player')<>'founder' then raise exception 'Публиковать новости может только владелец'; end if;
  if v_title='' or char_length(v_title)>100 then raise exception 'Заголовок должен содержать от 1 до 100 символов'; end if;
  if v_description='' or char_length(v_description)>240 then raise exception 'Описание должно содержать от 1 до 240 символов'; end if;
  if v_link is not null and (char_length(v_link)>500 or v_link !~ '^https://[^[:space:]]+$') then
    raise exception 'Ссылка должна быть HTTPS и не длиннее 500 символов';
  end if;
  if v_path is null and v_type is not null then raise exception 'Укажи файл для типа медиа'; end if;
  if v_path is not null then
    if v_type not in ('image','video') then raise exception 'Недопустимый тип медиа'; end if;
    if v_path !~ ('^'||v_uid::text||'/[A-Za-z0-9-]+[.](jpg|jpeg|png|webp|gif|mp4)$') then
      raise exception 'Недопустимый путь медиа';
    end if;
    if v_type='video' and v_path !~* '[.]mp4$' then raise exception 'Для видео разрешён только MP4'; end if;
    if v_type='image' and v_path ~* '[.]mp4$' then raise exception 'Укажи тип видео для MP4'; end if;
    if not exists (select 1 from storage.objects o where o.bucket_id='cf-news-media' and o.name=v_path) then
      raise exception 'Загруженный файл не найден';
    end if;
  end if;
  insert into public.news(title,description,link,image_path,media_path,media_type,published,author_id,created_at)
  values(v_title,v_description,v_link,v_path,v_path,v_type,true,v_uid,clock_timestamp())
  returning * into v_news;
  return jsonb_build_object('ok',true,'id',v_news.id,'title',v_news.title,'published',v_news.published,'created_at',v_news.created_at);
end;
$function$;
revoke all on function public.cf_owner_publish_news(text,text,text,text,text) from public,anon;
grant execute on function public.cf_owner_publish_news(text,text,text,text,text) to authenticated;

-- Refresh PostgREST so the newly installed RPC is immediately visible to the site.
notify pgrst, 'reload schema';

commit;

-- ==================== Included source: 47_shop_avatar_frames.sql ====================
-- LX FACEIT v55: admin-issued profile frame inventory and public rendering.
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

select 'LX FACEIT v55 avatar frame grants installed' as result;

-- ==================== Included source: 48_profile_banner_upload_fix.sql ====================
-- LX FACEIT v56: repair profile banner uploads and profile_banner writes.
-- Run in Supabase SQL Editor after SQL/28_v30_prime_bans_banners.sql.
-- Safe to re-run: the bucket and policies are created/upserted idempotently.

begin;

alter table public.profiles
  add column if not exists profile_banner text not null default 'ember';

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'cf-profile-banners',
  'cf-profile-banners',
  true,
  20971520,
  array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm','video/quicktime','video/x-m4v']
)
on conflict (id) do update
set name = excluded.name,
    public = true,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

-- Files are written below the authenticated player's UUID folder.
drop policy if exists cf_profile_banners_insert on storage.objects;
create policy cf_profile_banners_insert
on storage.objects for insert to authenticated
with check (
  bucket_id = 'cf-profile-banners'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists cf_profile_banners_delete on storage.objects;
create policy cf_profile_banners_delete
on storage.objects for delete to authenticated
using (
  bucket_id = 'cf-profile-banners'
  and (storage.foldername(name))[1] = auth.uid()::text
);

-- A player's profile row may keep either a preset or their public bucket URL.
alter table public.profiles drop constraint if exists profiles_profile_banner_check;
alter table public.profiles add constraint profiles_profile_banner_check
check (
  profile_banner in ('ember','inferno','dust','royal')
  or (
    char_length(profile_banner) <= 1900
    and profile_banner ~ '^https://[^[:space:]]+/storage/v1/object/public/cf-profile-banners/[0-9a-f-]{36}/[A-Za-z0-9._/-]+$'
  )
);

-- Preserve the existing profile RLS policy; grant only the field this migration enables.
grant update (profile_banner) on public.profiles to authenticated;

commit;

select 'LX FACEIT v56 profile banner storage repaired' as result;

-- ==================== Included source: 49_online_tournaments.sql ====================
-- LX FACEIT SQL/49 — server-backed tournaments.
-- Run after SQL/48_profile_banner_upload_fix.sql.
-- Existing `public.tournaments` tables from older experiments are intentionally untouched.
-- All writes go through authenticated, role-checked RPCs; clients receive read-only access.

begin;

create table if not exists public.cf_tournaments (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 3 and 70),
  starts_at timestamptz,
  map_name text not null check (map_name in ('Mirage', 'Dust II', 'Vertigo', 'Inferno')),
  map_image_url text not null default '' check (
    char_length(map_image_url) <= 500
    and (map_image_url = '' or map_image_url ~ '^https://[^[:space:]]+$')
  ),
  team_a_name text not null check (char_length(team_a_name) between 1 and 24),
  team_a_logo text not null default '' check (
    char_length(team_a_logo) <= 20000
    and (team_a_logo = '' or team_a_logo ~ '^data:image/jpeg;base64,[A-Za-z0-9+/]+={0,2}$')
  ),
  team_a_players text[] not null default '{}',
  team_b_name text not null check (char_length(team_b_name) between 1 and 24),
  team_b_logo text not null default '' check (
    char_length(team_b_logo) <= 20000
    and (team_b_logo = '' or team_b_logo ~ '^data:image/jpeg;base64,[A-Za-z0-9+/]+={0,2}$')
  ),
  team_b_players text[] not null default '{}',
  max_players integer not null check (max_players between 2 and 20),
  status text not null default 'open' check (status in ('open', 'live', 'done')),
  room_code text not null default '' check (char_length(room_code) <= 64),
  winner_team text check (winner_team in ('A', 'B')),
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (cardinality(team_a_players) between 1 and 10),
  check (cardinality(team_b_players) between 1 and 10),
  check (status <> 'done' or winner_team is not null)
);

create table if not exists public.cf_tournament_players (
  tournament_id uuid not null references public.cf_tournaments(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  side text not null check (side in ('CT', 'T')),
  joined_at timestamptz not null default now(),
  primary key (tournament_id, user_id)
);

create index if not exists cf_tournament_players_by_tournament
  on public.cf_tournament_players (tournament_id, side, joined_at);

alter table public.cf_tournaments enable row level security;
alter table public.cf_tournament_players enable row level security;
revoke all on public.cf_tournaments, public.cf_tournament_players from public, anon, authenticated;
-- The only read surface is the security-definer state RPC, which omits owner IDs and filters room codes.
drop policy if exists cf_tournaments_authenticated_read on public.cf_tournaments;
drop policy if exists cf_tournament_players_authenticated_read on public.cf_tournament_players;

create or replace function public.cf_tournament_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_uid uuid := auth.uid();
  v_result jsonb;
begin
  if v_uid is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', t.id,
        'title', t.title,
        'starts_at', t.starts_at,
        'date', case when t.starts_at is null then 'Уточняется' else to_char(t.starts_at, 'DD.MM.YYYY HH24:MI') end,
        'map', t.map_name,
        'mapImg', t.map_image_url,
        'teamA', jsonb_build_object('name', t.team_a_name, 'logo', t.team_a_logo, 'players', to_jsonb(t.team_a_players)),
        'teamB', jsonb_build_object('name', t.team_b_name, 'logo', t.team_b_logo, 'players', to_jsonb(t.team_b_players)),
        'maxPlayers', t.max_players,
        'status', t.status,
        'room', case
          when (t.status = 'live' and exists (select 1 from public.cf_tournament_players rp where rp.tournament_id = t.id and rp.user_id = v_uid))
            or exists (select 1 from public.profiles ap where ap.id = v_uid and ap.role in ('admin', 'founder'))
          then t.room_code else '' end,
        'winner', case when t.winner_team = 'A' then t.team_a_name when t.winner_team = 'B' then t.team_b_name else null end,
        'winner_team', t.winner_team,
        'players', (
          select coalesce(
            jsonb_agg(jsonb_build_object('id', p.user_id, 'user_id', p.user_id, 'nick', pr.nickname, 'team', p.side) order by p.joined_at),
            '[]'::jsonb
          )
          from public.cf_tournament_players p
          join public.profiles pr on pr.id = p.user_id
          where p.tournament_id = t.id
        )
      ) order by t.starts_at nulls last, t.created_at desc
    ),
    '[]'::jsonb
  ) into v_result
  from public.cf_tournaments t;

  return v_result;
end;
$function$;

create or replace function public.cf_tournament_create(
  p_title text,
  p_starts_at timestamptz,
  p_map text,
  p_map_image_url text,
  p_team_a_name text,
  p_team_a_logo text,
  p_team_a_players text[],
  p_team_b_name text,
  p_team_b_logo text,
  p_team_b_players text[]
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
  v_title text := btrim(coalesce(p_title, ''));
  v_a text[] := coalesce(p_team_a_players, '{}');
  v_b text[] := coalesce(p_team_b_players, '{}');
begin
  if v_uid is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if not exists (select 1 from public.profiles pr where pr.id = v_uid and pr.role in ('admin', 'founder')) then
    raise exception 'Administrator access required' using errcode = '42501';
  end if;
  if char_length(v_title) not between 3 and 70 then raise exception 'Tournament title must be 3–70 characters'; end if;
  if p_map not in ('Mirage', 'Dust II', 'Vertigo', 'Inferno') then raise exception 'Invalid tournament map'; end if;
  if char_length(btrim(coalesce(p_team_a_name, ''))) not between 1 and 24
     or char_length(btrim(coalesce(p_team_b_name, ''))) not between 1 and 24 then
    raise exception 'Team names must be 1–24 characters';
  end if;
  if cardinality(v_a) not between 1 and 10 or cardinality(v_b) not between 1 and 10 then
    raise exception 'Each team roster must contain 1–10 players';
  end if;
  if exists (select 1 from unnest(v_a || v_b) as names(name) where name is null or char_length(btrim(name)) not between 1 and 30) then
    raise exception 'Player names must be 1–30 characters';
  end if;
  if char_length(coalesce(p_map_image_url, '')) > 500
     or (coalesce(p_map_image_url, '') <> '' and p_map_image_url !~ '^https://[^[:space:]]+$') then
    raise exception 'Map image must be an HTTPS URL';
  end if;
  if char_length(coalesce(p_team_a_logo, '')) > 20000
     or (coalesce(p_team_a_logo, '') <> '' and p_team_a_logo !~ '^data:image/jpeg;base64,[A-Za-z0-9+/]+={0,2}$')
     or char_length(coalesce(p_team_b_logo, '')) > 20000
     or (coalesce(p_team_b_logo, '') <> '' and p_team_b_logo !~ '^data:image/jpeg;base64,[A-Za-z0-9+/]+={0,2}$') then
    raise exception 'Team logo is invalid or too large';
  end if;

  insert into public.cf_tournaments (
    title, starts_at, map_name, map_image_url,
    team_a_name, team_a_logo, team_a_players,
    team_b_name, team_b_logo, team_b_players,
    max_players, created_by
  ) values (
    v_title, p_starts_at, p_map, coalesce(p_map_image_url, ''),
    btrim(p_team_a_name), coalesce(p_team_a_logo, ''), v_a,
    btrim(p_team_b_name), coalesce(p_team_b_logo, ''), v_b,
    least(20, greatest(2, cardinality(v_a) + cardinality(v_b))), v_uid
  ) returning id into v_id;

  return v_id;
end;
$function$;

create or replace function public.cf_tournament_join(p_tournament_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_uid uuid := auth.uid();
  v_tournament public.cf_tournaments%rowtype;
  v_ct integer;
  v_t_count integer;
  v_total integer;
  v_side text;
begin
  if v_uid is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  select * into v_tournament from public.cf_tournaments where id = p_tournament_id for update;
  if not found then raise exception 'Tournament not found' using errcode = 'P0002'; end if;
  if v_tournament.status <> 'open' then raise exception 'Registration is closed'; end if;
  select count(*)::integer, count(*) filter (where side = 'CT')::integer, count(*) filter (where side = 'T')::integer
    into v_total, v_ct, v_t_count
    from public.cf_tournament_players where tournament_id = p_tournament_id;
  if v_total >= v_tournament.max_players then
    raise exception 'Tournament is full';
  end if;
  if exists (select 1 from public.cf_tournament_players where tournament_id = p_tournament_id and user_id = v_uid) then
    raise exception 'Already registered';
  end if;
  v_side := case when v_ct <= v_t_count then 'CT' else 'T' end;
  insert into public.cf_tournament_players (tournament_id, user_id, side) values (p_tournament_id, v_uid, v_side);
  return jsonb_build_object('ok', true, 'side', v_side, 'tournament_id', p_tournament_id);
end;
$function$;

create or replace function public.cf_tournament_admin_action(
  p_tournament_id uuid,
  p_action text,
  p_room_code text default null,
  p_winner text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_uid uuid := auth.uid();
  v_tournament public.cf_tournaments%rowtype;
begin
  if v_uid is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if not exists (select 1 from public.profiles pr where pr.id = v_uid and pr.role in ('admin', 'founder')) then
    raise exception 'Administrator access required' using errcode = '42501';
  end if;
  select * into v_tournament from public.cf_tournaments where id = p_tournament_id for update;
  if not found then raise exception 'Tournament not found' using errcode = 'P0002'; end if;

  if p_action = 'start' then
    if v_tournament.status <> 'open' then raise exception 'Tournament cannot be started'; end if;
    if coalesce(p_room_code, '') !~ '^[^[:space:]]{3,64}$' then raise exception 'Room code must be 3–64 characters without spaces'; end if;
    update public.cf_tournaments set status = 'live', room_code = p_room_code, updated_at = now() where id = p_tournament_id;
  elsif p_action = 'winner' then
    if v_tournament.status <> 'live' then raise exception 'Only a live tournament can be completed'; end if;
    if p_winner not in ('A', 'B') then raise exception 'Invalid winner'; end if;
    update public.cf_tournaments set status = 'done', winner_team = p_winner, updated_at = now() where id = p_tournament_id;
  elsif p_action = 'delete' then
    delete from public.cf_tournaments where id = p_tournament_id;
    return jsonb_build_object('ok', true, 'status', 'deleted');
  else
    raise exception 'Unsupported tournament action';
  end if;

  return jsonb_build_object('ok', true, 'status', case when p_action = 'start' then 'live' else 'done' end);
end;
$function$;

revoke all on function public.cf_tournament_state() from public, anon;
revoke all on function public.cf_tournament_create(text, timestamptz, text, text, text, text, text[], text, text, text[]) from public, anon;
revoke all on function public.cf_tournament_join(uuid) from public, anon;
revoke all on function public.cf_tournament_admin_action(uuid, text, text, text) from public, anon;
grant execute on function public.cf_tournament_state() to authenticated;
grant execute on function public.cf_tournament_create(text, timestamptz, text, text, text, text, text[], text, text, text[]) to authenticated;
grant execute on function public.cf_tournament_join(uuid) to authenticated;
grant execute on function public.cf_tournament_admin_action(uuid, text, text, text) to authenticated;

commit;

select 'LX FACEIT SQL/49 online tournaments ready' as result;

-- ==================== Included source: 50_skill_based_elo_and_ai_review.sql ====================
-- LX FACEIT SQL/50: replace random ELO awards with skill-based Elo and require human result approval.
-- Install after SQL/49_online_tournaments.sql (and the v9 match schema / SQL/33).
-- Additive and re-runnable: preserves existing profiles, match history, and current ELO.
-- Only future, manually approved match results use the new rating calculation.

begin;

-- Keep AI review throttling private. One match can trigger at most three paid OCR attempts.
create table if not exists public.cf_ai_review_claims (
  match_id uuid primary key references public.cf_lobby_matches(id) on delete cascade,
  attempts smallint not null default 0 check (attempts between 0 and 3),
  updated_at timestamptz not null default clock_timestamp()
);
alter table public.cf_ai_review_claims enable row level security;
revoke all on public.cf_ai_review_claims from public, anon, authenticated;

create or replace function public.cf_ai_review_claim(p_match uuid, p_user uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_match public.cf_lobby_matches%rowtype;
  v_role text;
  v_attempts integer;
begin
  if p_user is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;

  select pr.role into v_role
  from public.profiles pr
  where pr.id = p_user;

  if not found then
    raise exception 'Profile not found' using errcode = '28000';
  end if;

  select m.* into v_match
  from public.cf_lobby_matches m
  where m.id = p_match
  for update;

  if not found then
    raise exception 'Match not found' using errcode = 'P0002';
  end if;
  if v_match.status <> 'result_pending' then
    return jsonb_build_object('allowed', false, 'reason', 'not_pending', 'status', v_match.status);
  end if;
  if nullif(v_match.result_screenshot_url, '') is null then
    raise exception 'Match has no result screenshot';
  end if;
  if coalesce(v_role, 'player') not in ('admin', 'founder')
     and not (p_user = any(coalesce(v_match.participant_ids, '{}'::uuid[]))) then
    raise exception 'Not authorized to review this match' using errcode = '42501';
  end if;

  insert into public.cf_ai_review_claims (match_id, attempts)
  values (p_match, 0)
  on conflict (match_id) do nothing;

  select c.attempts into v_attempts
  from public.cf_ai_review_claims c
  where c.match_id = p_match
  for update;

  if v_attempts >= 3 then
    return jsonb_build_object('allowed', false, 'reason', 'rate_limited', 'attempts', v_attempts);
  end if;

  update public.cf_ai_review_claims c
  set attempts = c.attempts + 1,
      updated_at = clock_timestamp()
  where c.match_id = p_match
  returning c.attempts into v_attempts;

  return jsonb_build_object(
    'allowed', true,
    'attempts', v_attempts,
    'screenshot_url', v_match.result_screenshot_url
  );
end;
$function$;
revoke all on function public.cf_ai_review_claim(uuid, uuid) from public, anon, authenticated;
grant execute on function public.cf_ai_review_claim(uuid, uuid) to service_role;

-- Internal exactly-once mutation. Authenticated users cannot call this directly;
-- only the admin review RPC may award rating points.
create or replace function public.cf_apply_match_result(
  p_match uuid, p_winner text, p_score text, p_by uuid, p_auto boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_match public.cf_lobby_matches%rowtype;
  v_team_a_ids uuid[];
  v_team_b_ids uuid[];
  v_participant_ids uuid[];
  v_role text;
  v_team_a_count integer;
  v_team_b_count integer;
  v_team_a_rating double precision;
  v_team_b_rating double precision;
  v_expected_a double precision;
  v_actual_a double precision;
  v_delta integer;
  v_score text := left(trim(coalesce(p_score, '')), 20);
begin
  if p_auto is distinct from false then
    raise exception 'AI results are suggestions only; an administrator must approve the result';
  end if;
  if p_winner is null or p_winner not in ('A', 'B') then
    raise exception 'Choose the winning team';
  end if;
  if p_by is null then
    raise exception 'Administrator identity is required';
  end if;
  select pr.role into v_role from public.profiles pr where pr.id = p_by;
  if coalesce(v_role, 'player') not in ('admin', 'founder') then
    raise exception 'Administrator approval required' using errcode = '42501';
  end if;

  select m.* into v_match
  from public.cf_lobby_matches m
  where m.id = p_match
  for update;

  if not found or v_match.status <> 'result_pending' then
    raise exception 'Result has already been processed or is not pending';
  end if;

  v_team_a_ids := coalesce(v_match.team_a_ids, '{}'::uuid[]);
  v_team_b_ids := coalesce(v_match.team_b_ids, '{}'::uuid[]);
  v_participant_ids := coalesce(v_match.participant_ids, '{}'::uuid[]);

  if cardinality(v_team_a_ids) = 0 or cardinality(v_team_b_ids) = 0
     or v_team_a_ids && v_team_b_ids then
    raise exception 'Match teams are incomplete or overlap';
  end if;
  if cardinality(v_participant_ids) <> cardinality(v_team_a_ids) + cardinality(v_team_b_ids)
     or not (v_participant_ids @> (v_team_a_ids || v_team_b_ids))
     or not ((v_team_a_ids || v_team_b_ids) @> v_participant_ids) then
    raise exception 'Match participant roster is inconsistent';
  end if;

  select count(distinct pr.id)::integer, avg(coalesce(pr.elo, 800))::double precision
    into v_team_a_count, v_team_a_rating
  from public.profiles pr
  where pr.id = any(v_team_a_ids);

  select count(distinct pr.id)::integer, avg(coalesce(pr.elo, 800))::double precision
    into v_team_b_count, v_team_b_rating
  from public.profiles pr
  where pr.id = any(v_team_b_ids);

  if v_team_a_count <> cardinality(v_team_a_ids)
     or v_team_b_count <> cardinality(v_team_b_ids) then
    raise exception 'A match participant profile is missing or duplicated';
  end if;

  -- Standard team Elo expectation (400-point scale), K=32; the rounded change
  -- is zero-sum across teams. Upsets earn more; expected wins earn less.
  v_expected_a := 1.0 / (1.0 + power(10.0, (v_team_b_rating - v_team_a_rating) / 400.0));
  v_actual_a := case when p_winner = 'A' then 1.0 else 0.0 end;
  v_delta := round(32.0 * (v_actual_a - v_expected_a))::integer;

  update public.profiles pr
  set elo = greatest(0, coalesce(pr.elo, 800) + case
        when pr.id = any(v_team_a_ids) then v_delta
        when pr.id = any(v_team_b_ids) then -v_delta
        else 0 end),
      wins = coalesce(pr.wins, 0) + case
        when (p_winner = 'A' and pr.id = any(v_team_a_ids))
          or (p_winner = 'B' and pr.id = any(v_team_b_ids)) then 1 else 0 end,
      losses = coalesce(pr.losses, 0) + case
        when (p_winner = 'A' and pr.id = any(v_team_b_ids))
          or (p_winner = 'B' and pr.id = any(v_team_a_ids)) then 1 else 0 end
  where pr.id = any(v_participant_ids);

  update public.cf_lobby_matches
  set status = 'done',
      winner_team = p_winner,
      elo_delta = abs(v_delta),
      result_score = coalesce(nullif(v_score, ''), result_score),
      result_reviewed_by = p_by,
      result_reviewed_at = clock_timestamp(),
      result_auto = false,
      updated_at = clock_timestamp()
  where id = p_match and status = 'result_pending';

  if not found then
    raise exception 'Result has already been processed';
  end if;
end;
$function$;
revoke all on function public.cf_apply_match_result(uuid, text, text, uuid, boolean)
  from public, anon, authenticated;

create or replace function public.cf_lobby_match_review_result(
  p_match uuid, p_winner text, p_score text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_uid uuid := auth.uid();
  v_role text;
  v_match public.cf_lobby_matches%rowtype;
  v_score text := trim(coalesce(p_score, ''));
begin
  if v_uid is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  select pr.role into v_role from public.profiles pr where pr.id = v_uid;
  if coalesce(v_role, 'player') not in ('admin', 'founder') then
    raise exception 'Administrator access required' using errcode = '42501';
  end if;
  if p_winner is null or p_winner not in ('A', 'B') then
    raise exception 'Choose the winning team';
  end if;
  if char_length(v_score) > 20 then
    raise exception 'Score is too long';
  end if;

  select m.* into v_match
  from public.cf_lobby_matches m
  where m.id = p_match
  for update;

  if not found then
    raise exception 'Match not found' using errcode = 'P0002';
  end if;
  if v_match.status <> 'result_pending' then
    raise exception 'This result is already reviewed or has not been submitted';
  end if;
  if nullif(v_match.result_screenshot_url, '') is null then
    raise exception 'Match has no result screenshot';
  end if;

  perform public.cf_apply_match_result(p_match, p_winner, v_score, v_uid, false);
  return public.cf_lobby_match_admin_list();
end;
$function$;
revoke all on function public.cf_lobby_match_review_result(uuid, text, text) from public, anon;
grant execute on function public.cf_lobby_match_review_result(uuid, text, text) to authenticated;

-- AI may store a bounded score suggestion but is never permitted to finalize a result or award ELO.
create or replace function public.cf_ai_apply_result(
  p_match uuid, p_ct integer, p_t integer, p_conf text, p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_match public.cf_lobby_matches%rowtype;
  v_ok boolean;
  v_winner text;
  v_score text;
begin
  if coalesce(p_conf, '') not in ('high', 'low') then
    raise exception 'Invalid AI confidence value';
  end if;

  select m.* into v_match
  from public.cf_lobby_matches m
  where m.id = p_match
  for update;

  if not found then
    raise exception 'Match not found' using errcode = 'P0002';
  end if;
  if v_match.status <> 'result_pending' then
    return jsonb_build_object('applied', false, 'status', v_match.status, 'reason', 'not_pending');
  end if;

  v_ok := p_ct is not null and p_t is not null
    and p_ct between 0 and 40 and p_t between 0 and 40
    and p_ct <> p_t and greatest(p_ct, p_t) >= 5;
  v_winner := case when not v_ok then null when p_ct > p_t then 'A' else 'B' end;
  v_score := case when v_ok then p_ct::text || ':' || p_t::text else null end;

  update public.cf_lobby_matches m
  set bot_ct_score = case when v_ok then p_ct else null end,
      bot_t_score = case when v_ok then p_t else null end,
      bot_winner = v_winner,
      ai_note = left(coalesce(p_note, ''), 300),
      result_score = coalesce(v_score, m.result_score)
  where m.id = p_match and m.status = 'result_pending';

  return jsonb_build_object(
    'applied', false,
    'status', 'result_pending',
    'review_required', true,
    'reason', case when v_ok then 'awaiting_admin_review' else 'unreadable' end,
    'winner', v_winner,
    'score', v_score,
    'confidence', p_conf
  );
end;
$function$;
revoke all on function public.cf_ai_apply_result(uuid, integer, integer, text, text)
  from public, anon, authenticated;
grant execute on function public.cf_ai_apply_result(uuid, integer, integer, text, text)
  to service_role;

commit;

select 'LX FACEIT SQL/50: skill-based Elo, one-time admin approval, and bounded AI suggestions installed' as result;

-- ==================== Included source: 51_cancel_reviewed_matches.sql ====================
-- LX FACEIT SQL/51: let admins cancel a submitted, unreviewed match with a required reason.
-- Run after SQL/50_skill_based_elo_and_ai_review.sql and SQL/23_screenshot_bot_support.sql.
-- The match transition and both support messages commit or roll back together.

do $preflight$
declare
  v_matches regclass := to_regclass('public.cf_lobby_matches');
  v_messages regclass := to_regclass('public.msgr_messages');
begin
  if v_matches is null then
    raise exception 'Install the v9 match schema before SQL/51';
  end if;
  if not exists (
    select 1 from pg_attribute
    where attrelid = v_matches and attname = 'participant_ids' and not attisdropped
  ) or not exists (
    select 1 from pg_attribute
    where attrelid = v_matches and attname = 'cancel_reason' and not attisdropped
  ) then
    raise exception 'The v9 match schema is incomplete; install the current match migrations first';
  end if;
  if to_regclass('public.cf_ai_review_claims') is null then
    raise exception 'Install SQL/50_skill_based_elo_and_ai_review.sql before SQL/51';
  end if;
  if v_messages is null or to_regclass('public.msgr_chats') is null
     or to_regclass('public.msgr_members') is null
     or to_regprocedure('public.msgr_support_ensure(uuid)') is null then
    raise exception 'Install SQL/23_screenshot_bot_support.sql before SQL/51';
  end if;
  if not exists (
    select 1 from pg_attribute
    where attrelid = v_messages and attname = 'is_bot' and not attisdropped
  ) then
    raise exception 'The support messenger is incomplete; install SQL/23_screenshot_bot_support.sql first';
  end if;
end;
$preflight$;

begin;

-- Keep the legacy active-match cancel RPC from bypassing the required review reason/notices.
create or replace function public.cf_lobby_match_admin_action(p_match uuid, p_action text, p_code text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_uid uuid := auth.uid();
  v_role text;
  v_match public.cf_lobby_matches%rowtype;
begin
  if v_uid is null then
    raise exception 'Нужно войти в аккаунт' using errcode = '28000';
  end if;
  select pr.role into v_role from public.profiles pr where pr.id = v_uid;
  if coalesce(v_role, 'player') not in ('admin', 'founder') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if p_action is distinct from 'cancel' then
    raise exception 'Комнату и код настраивает выбранный игрок-организатор';
  end if;

  select m.* into v_match
  from public.cf_lobby_matches m
  where m.id = p_match
  for update;
  if not found then
    raise exception 'Матч не найден';
  end if;
  if v_match.status = 'result_pending' then
    raise exception 'Для отмены отправленного результата укажи причину через отмену с уведомлением игроков';
  end if;
  if v_match.status in ('done', 'cancelled') then
    raise exception 'Матч уже завершён';
  end if;

  update public.cf_lobby_matches m
  set status = 'cancelled',
      cancel_reason = 'Отменено администратором',
      updated_at = clock_timestamp()
  where m.id = p_match and m.status not in ('done', 'cancelled', 'result_pending');
  if not found then
    raise exception 'Матч уже завершён';
  end if;
  return jsonb_build_object(
    'ok', true,
    'match_id', v_match.id,
    'status', 'cancelled',
    'cancel_reason', 'Отменено администратором'
  );
end;
$function$;
revoke all on function public.cf_lobby_match_admin_action(uuid, text, text) from public, anon;
grant execute on function public.cf_lobby_match_admin_action(uuid, text, text) to authenticated;

create or replace function public.cf_lobby_match_cancel_review(p_match uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_uid uuid := auth.uid();
  v_role text;
  v_match public.cf_lobby_matches%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_participants uuid[];
  v_player uuid;
  v_chat uuid;
  v_notified integer := 0;
begin
  if v_uid is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;

  select pr.role into v_role
  from public.profiles pr
  where pr.id = v_uid;
  if coalesce(v_role, 'player') not in ('admin', 'founder') then
    raise exception 'Administrator access required' using errcode = '42501';
  end if;

  if char_length(v_reason) < 5 or char_length(v_reason) > 500 then
    raise exception 'Укажи причину отмены длиной от 5 до 500 символов';
  end if;

  select m.* into v_match
  from public.cf_lobby_matches m
  where m.id = p_match
  for update;
  if not found then
    raise exception 'Match not found' using errcode = 'P0002';
  end if;

  -- Safe to retry after a lost response: never create duplicate player notices.
  if v_match.status = 'cancelled' then
    return jsonb_build_object(
      'ok', true,
      'status', 'cancelled',
      'already_cancelled', true,
      'cancel_reason', v_match.cancel_reason
    );
  end if;
  if v_match.status <> 'result_pending' then
    raise exception 'Отменить можно только матч с результатом на проверке';
  end if;

  v_participants := coalesce(v_match.participant_ids, '{}'::uuid[]);
  if cardinality(v_participants) < 2 then
    raise exception 'Не удалось определить игроков матча';
  end if;
  if exists (
    select 1
    from unnest(v_participants) as u(player_id)
    where u.player_id is null
       or not exists (select 1 from auth.users au where au.id = u.player_id)
  ) then
    raise exception 'Не удалось найти всех игроков матча; обратись к поддержке';
  end if;

  -- Notifications are authored as Support and visible only in each player's private support chat.
  for v_player in
    select distinct u.player_id
    from unnest(v_participants) as u(player_id)
    order by u.player_id
  loop
    v_chat := public.msgr_support_ensure(v_player);
    insert into public.msgr_members (chat_id, user_id)
    values (v_chat, v_player)
    on conflict do nothing;
    insert into public.msgr_messages (chat_id, user_id, body, is_bot)
    values (
      v_chat,
      v_player,
      'Поддержка: ваш матч отменён администрацией после проверки результата. Причина: ' || v_reason,
      true
    );
    v_notified := v_notified + 1;
  end loop;

  -- The result-review RPC and ELO mutation both require result_pending and lock this row.
  -- This mutually exclusive state transition prevents a canceled match from awarding ELO.
  update public.cf_lobby_matches m
  set status = 'cancelled',
      cancel_reason = v_reason,
      updated_at = clock_timestamp()
  where m.id = p_match and m.status = 'result_pending';
  if not found then
    raise exception 'Результат уже обработан';
  end if;

  return jsonb_build_object(
    'ok', true,
    'match_id', p_match,
    'status', 'cancelled',
    'already_cancelled', false,
    'players_notified', v_notified,
    'cancel_reason', v_reason
  );
end;
$function$;

revoke all on function public.cf_lobby_match_cancel_review(uuid, text) from public, anon;
grant execute on function public.cf_lobby_match_cancel_review(uuid, text) to authenticated;

commit;

select 'LX FACEIT SQL/51: reviewed-result cancellation with required reason and private support notices installed' as result;

-- ==================== Included source: 52_lx_standoff2_maps_and_ids.sql ====================
-- LX FACEIT / Standoff 2 — final compatibility migration for a DEDICATED LX database.
-- Requires the existing v9 baseline chain, including SQL/38, SQL/39, SQL/41, SQL/49.
-- Do NOT apply this to the live LX FACEIT project: it changes that database's map pool.
-- It refuses to replace constraints if legacy map rows exist; it does not delete or rewrite match data.

begin;

do $migration$
declare
  v_constraint record;
  v_oid oid;
  v_definition text;
  v_updated text;
  v_old text;
  v_new text;
  v_proc record;
  v_maps text[] := array['Sandstone','Province','Rust','Zone 7','Breeze','Hanami','Dune','Pyramid'];
begin
  if to_regclass('public.profiles') is null
     or to_regclass('public.cf_matchmaking_queue') is null
     or to_regclass('public.cf_tournaments') is null then
    raise exception 'Install the LX-compatible auth, matchmaking and tournament baseline before SQL/52';
  end if;
  if to_regprocedure('public.cf_lobby_match_start(text,text)') is null
     or to_regprocedure('public.cf_tournament_create(text,timestamp with time zone,text,text,text,text,text[],text,text,text[])') is null then
    raise exception 'Expected v9 matchmaking/tournament functions are missing; install the required baseline first';
  end if;
  if exists (select 1 from public.cf_matchmaking_queue q where q.map_name is not null and not (q.map_name = any(v_maps))) then
    raise exception 'Queue contains legacy map values; archive or resolve them before switching this dedicated LX database';
  end if;
  if exists (select 1 from public.cf_tournaments t where t.map_name is not null and not (t.map_name = any(v_maps))) then
    raise exception 'Tournaments contain legacy map values; resolve them before switching this dedicated LX database';
  end if;

  -- Expand the numeric player-ID range to match this prototype's 6–16 digit form; verify the real game ID format before production.
  alter table public.profiles drop constraint if exists profiles_game_id_format;
  alter table public.profiles
    add constraint profiles_game_id_format
    check (game_id is null or game_id ~ '^[0-9]{6,16}$');

  -- Update only known public functions whose source contains the former ID-length regex.
  for v_proc in
    select p.oid
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prosrc like '%[0-9]{6,7}%'
  loop
    v_definition := pg_get_functiondef(v_proc.oid);
    v_updated := replace(v_definition, '[0-9]{6,7}', '[0-9]{6,16}');
    if v_updated <> v_definition then
      execute v_updated;
    end if;
  end loop;

  -- Change the trusted server-side matchmaking allowlist without changing any other function logic.
  v_oid := to_regprocedure('public.cf_lobby_match_start(text,text)');
  v_definition := pg_get_functiondef(v_oid);
  v_old := 'if p_map not in (''Mirage'',''Dust2'',''Vertigo'',''Inferno'') then raise exception ''Недопустимая карта''; end if;';
  v_new := 'if p_map is null or p_map not in (''Sandstone'',''Province'',''Rust'',''Zone 7'',''Breeze'',''Hanami'',''Dune'',''Pyramid'') then raise exception ''Недопустимая карта''; end if;';
  if position(v_old in v_definition) = 0 then
    raise exception 'Could not safely locate the expected map check in cf_lobby_match_start; no map logic was changed';
  end if;
  execute replace(v_definition, v_old, v_new);

  -- Change the tournament RPC allowlist; all other authorization and validation logic is preserved.
  v_oid := to_regprocedure('public.cf_tournament_create(text,timestamptz,text,text,text,text,text[],text,text,text[])');
  v_definition := pg_get_functiondef(v_oid);
  v_old := 'if p_map not in (''Mirage'', ''Dust II'', ''Vertigo'', ''Inferno'') then raise exception ''Invalid tournament map''; end if;';
  v_new := 'if p_map is null or p_map not in (''Sandstone'', ''Province'', ''Rust'', ''Zone 7'', ''Breeze'', ''Hanami'', ''Dune'', ''Pyramid'') then raise exception ''Invalid tournament map''; end if;';
  if position(v_old in v_definition) = 0 then
    raise exception 'Could not safely locate the expected map check in cf_tournament_create; no tournament logic was changed';
  end if;
  execute replace(v_definition, v_old, v_new);

  -- Replace only existing map-name CHECK constraints; reject old queue/tournament rows above first.
  for v_constraint in
    select c.conname from pg_constraint c
    where c.conrelid = 'public.cf_matchmaking_queue'::regclass
      and c.contype = 'c' and pg_get_constraintdef(c.oid) ilike '%map_name%'
  loop
    execute format('alter table public.cf_matchmaking_queue drop constraint %I', v_constraint.conname);
  end loop;
  alter table public.cf_matchmaking_queue
    add constraint lx_matchmaking_queue_map_check
    check (map_name = any (array['Sandstone','Province','Rust','Zone 7','Breeze','Hanami','Dune','Pyramid']::text[]));

  for v_constraint in
    select c.conname from pg_constraint c
    where c.conrelid = 'public.cf_tournaments'::regclass
      and c.contype = 'c' and pg_get_constraintdef(c.oid) ilike '%map_name%'
  loop
    execute format('alter table public.cf_tournaments drop constraint %I', v_constraint.conname);
  end loop;
  alter table public.cf_tournaments
    add constraint lx_tournaments_map_name_check
    check (map_name = any (array['Sandstone','Province','Rust','Zone 7','Breeze','Hanami','Dune','Pyramid']::text[]));
end;
$migration$;

commit;

select 'LX FACEIT Standoff 2 map and player ID rules installed' as result;

-- Final install verification: required app data and entry-point RPCs must exist.
do $lx_verify$
begin
  if to_regclass('public.profiles') is null
     or to_regclass('public.cf_matchmaking_queue') is null
     or to_regclass('public.cf_lobby_matches') is null
     or to_regclass('public.cf_tournaments') is null then
    raise exception 'LX installation incomplete: a required table is missing';
  end if;
  if to_regprocedure('public.cf_auth_check_registration(text,text)') is null
     or to_regprocedure('public.cf_regions_enabled()') is null
     or to_regprocedure('public.cf_lobby_match_state()') is null
     or to_regprocedure('public.cf_lobby_match_start(text,text)') is null
     or to_regprocedure('public.cf_tournament_state()') is null
     or to_regprocedure('public.cf_tournament_create(text,timestamp with time zone,text,text,text,text,text[],text,text,text[])') is null then
    raise exception 'LX installation incomplete: a required app RPC is missing';
  end if;
end;
$lx_verify$;

select 'LX FACEIT Standoff 2 full schema installed; SQL/52 compatibility is included' as result;
