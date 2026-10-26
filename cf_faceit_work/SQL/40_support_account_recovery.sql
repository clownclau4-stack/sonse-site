-- CF FACEIT v45: self-service game ID change and password recovery from support chat.
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
    return 'Чтобы получить значок спонсора CF FACEIT и привилегии, поддержи проект минимум на 100 ₽ через Telegram @prisedents. После подтверждения поддержки значок выдаёт администрация. Ссылка: https://t.me/prisedents.';
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
