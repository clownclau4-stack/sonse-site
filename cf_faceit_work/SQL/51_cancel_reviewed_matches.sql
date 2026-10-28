-- CF FACEIT SQL/51: let admins cancel a submitted, unreviewed match with a required reason.
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

select 'CF FACEIT SQL/51: reviewed-result cancellation with required reason and private support notices installed' as result;
