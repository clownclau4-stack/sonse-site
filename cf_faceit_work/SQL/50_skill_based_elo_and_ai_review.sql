-- CF FACEIT SQL/50: replace random ELO awards with skill-based Elo and require human result approval.
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

select 'CF FACEIT SQL/50: skill-based Elo, one-time admin approval, and bounded AI suggestions installed' as result;
