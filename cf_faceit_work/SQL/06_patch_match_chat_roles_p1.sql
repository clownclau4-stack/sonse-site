-- CF FACEIT, шаг 6: матчи, чат, роли (часть 1 из 4)
-- Вставь целиком в SQL Editor -> Run. Запускай строго по номерам.
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
