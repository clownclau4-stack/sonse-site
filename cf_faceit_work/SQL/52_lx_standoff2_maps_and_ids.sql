-- LX FACEIT / Standoff 2 — final compatibility migration for a DEDICATED LX database.
-- Requires the existing v9 baseline chain, including SQL/38, SQL/39, SQL/41, SQL/49.
-- Do NOT apply this to the live CF FACEIT project: it changes that database's map pool.
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
