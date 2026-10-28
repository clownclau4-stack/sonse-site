-- CF FACEIT SQL/49 — server-backed tournaments.
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

select 'CF FACEIT SQL/49 online tournaments ready' as result;
