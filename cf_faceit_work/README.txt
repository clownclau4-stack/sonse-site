CF FACEIT v9 UPDATE
===================
For the new online 5v5 / 2v2 queue, party-preserving teams, animated match acceptance, room-host selection and Discord result review, see CF_FACEIT_V9_SETUP.txt. Run CF_FACEIT_V9_MATCHMAKING_RESULTS.sql after the existing v8 setup scripts.

CF FACEIT — онлайн-сборка с Supabase (уникальный игровой ID, вход, профиль, звуки и восстановление)

ЧТО ВНУТРИ
- Сохранён исходный интерфейс и папка images.
- Добавлена основа PWA: manifest.webmanifest, sw.js и SVG-иконка.
- В панель администратора добавлен редактор новостей (локальный режим).
- Добавлен supabase-schema.sql как стартовая схема будущей онлайн-базы.

БЫСТРЫЙ ЗАПУСК
1. Распакуй ZIP целиком.
2. Для быстрого просмотра открой index.html в браузере.
3. Для PWA и публикации используй HTTPS-хостинг (например, Cloudflare Pages). Service worker не работает при открытии через file://.

ПУБЛИКАЦИЯ НА CLOUDFLARE PAGES
1. Создай проект Pages и загрузи содержимое этой папки как статический сайт.
2. Убедись, что index.html находится в корне публикации, рядом с manifest.webmanifest и sw.js.
3. Открой сайт по HTTPS. На Android в меню браузера выбери «Установить приложение» или «Добавить на главный экран».

ДЕМО-АДМИН
Локальный демо-вход: Sonse / sonse33.
Это тестовый вход для прототипа, а не безопасная онлайн-учётная запись. Не используй этот пароль в других сервисах. Не публикуй сайт с клиентской проверкой роли как настоящую админку.

ВАЖНО ПРО ОНЛАЙН
Регистрация и вход в этой сборке используют Supabase Auth и профильную таблицу public.profiles. Для нового аккаунта требуется уникальный игровой ID из 6 или 7 цифр. Игроки входят по никнейму и паролю; игровой ID нужен для регистрации профиля, но не для входа. Почта и пароль также поддерживаются. Supabase Auth проверяет пароль. Профили, ID, роли и галочки читаются из Supabase. После установки миграции CF_FACEIT_V9_MATCHMAKING_RESULTS.sql очередь матчей, команды, выбор организатора комнаты и проверка результата работают через серверные RPC. Для исправлений отмены матчей и ускорения админки дополнительно выполни SQL/29_fix_match_cancellation_and_admin_speed.sql после v9 и остальных уже применённых миграций (включая SQL/28), затем SQL/30_play_cooldown.sql для серверного кулдауна 7 минут после подтверждённого завершения матча. Одноразовый SQL/31_clear_all_matches_once.sql очищает текущие матчи/очередь и старые матчи без связанных жалоб; жалобы, аккаунты, профили, лобби и ELO сохраняются. SQL/33_match_stats_repair.sql (после v9 и SQL/23) исправляет сохранение побед/поражений по всем подтверждённым онлайн-матчам, безопасно восстанавливает счётчики по сохранённой истории и включает обновление профиля после завершения матча. Для живого таймера и отправки скриншота выполни SQL/35_match_timer_and_screenshot_fix.sql после SQL/21, SQL/23, SQL/25, SQL/32 и SQL/33: он синхронизирует 15-минутный отсчёт с базой, возвращает время в RPC и настраивает загрузку файла в Storage. Топы, турниры, новости и некоторые исторические показатели могут по-прежнему быть локальными. Не помещай service_role key в HTML/JavaScript. Админ-роли, выдача ELO, баны и завершение матчей должны проверяться сервером. SQL нельзя просто заменить клиентским JS: тогда секреты и проверки доступа окажутся в браузере, а игроки потеряют общие серверные данные. Для ухода с Supabase нужен отдельный серверный API и безопасный перенос данных; эта версия оставляет SQL на сервере.


НОВЫЕ ВОЗМОЖНОСТИ В ЭТОЙ СБОРКЕ
- Редактирование профиля: ник, аватар из галереи (до 1 МБ), ссылки Telegram/YouTube/TikTok. В текущем демо эти изменения хранятся в localStorage данного браузера.
- Оригинальные короткие звуки интерфейса и кнопки поиска; настройка включения/выключения в профиле.
- Добавлен экран восстановления пароля через Supabase Auth. Он отправит письмо ТОЛЬКО после настройки проекта Supabase и только для аккаунтов, существующих в Supabase Auth. Локальные демо-аккаунты не имеют настоящей почтовой авторизации.
- Общий подбор v9 работает через Supabase после установки всех требуемых SQL-миграций. Если миграция v9 не установлена, интерфейс покажет подсказку о необходимости её выполнить.

ПОДКЛЮЧЕНИЕ SUPABASE И ВХОДА
1. В Supabase SQL Editor выполняй файлы в порядке: supabase-schema.sql, supabase-online-setup.sql, supabase-auth-profile-setup.sql, supabase-game-id-setup.sql.
2. Проверь в index.html параметры CF_SUPABASE_URL и CF_SUPABASE_ANON_KEY. В коде сайта допустим только публичный publishable/anon key. Service role key запрещено вставлять в HTML.
3. В Supabase → Authentication → Providers включи Email и настрой доставку писем. В Authentication → URL Configuration добавь HTTPS-адрес сайта в Site URL и Redirect URLs.
4. Разверни Edge Function login-by-nickname по инструкции из NICKNAME_LOGIN_SETUP.txt.
5. Игровой ID обязателен для регистрации и должен быть уникальным; уже существующим профилям менять ID для входа не нужно. Подробности есть в NICKNAME_LOGIN_SETUP.txt.

ЧТО ПОКА НЕ ПОЛНОСТЬЮ ОНЛАЙН
После установки миграции v9 подбор 5×5 / 2×2, сохранение друзей в одной команде, единый выбор организатора, выдача кода комнаты и подтверждение результата работают через Supabase RPC. Топы, новости и турниры могут оставаться локальными. Сайт не может сам определить окончание матча внутри CounterFlame: таймер матча показывает оставшееся время, а после его истечения сайт открывает форму, где участник прикрепляет скриншот итоговой таблицы.


CF FACEIT — SUPABASE ONLINE SETUP (2026-10-18)
================================================
1. Open Supabase Dashboard > SQL Editor.
2. Run these files in this exact order:
   a) supabase-schema.sql
   b) supabase-online-setup.sql
   c) supabase-auth-profile-setup.sql
   d) supabase-game-id-setup.sql (adds unique 6- or 7-digit game IDs and refreshes the signup trigger)
   e) supabase-founder-admin-setup.sql (after confirming the correct Sonse/Federal Auth accounts exist; assigns Sonse ID 530047 and their roles)
3. In Authentication > URL Configuration, set Site URL to your deployed HTTPS website URL. Configure Redirect URLs for signup/email confirmation links if those are enabled; password recovery on this version uses an email code, not a redirect link.
4. In Authentication > Providers, enable Email. If email confirmation is enabled, new users must click the confirmation email before they can sign in.
5. For code-based password recovery, follow PASSWORD_RECOVERY_SETUP_RU.txt: change the Reset Password email template to display {{ .Token }} (not {{ .ConfirmationURL }}) and set the email OTP length to 6 digits. This is a Supabase Dashboard setting; no SQL migration is needed.
6. Deploy the contents of PAGES_UPLOAD to Cloudflare Pages using Direct Upload.

The site uses Supabase Auth for email/password sign-in and registration and stores editable profile fields in public.profiles. Player login requires nickname, assigned 6- or 7-digit game ID, and password. Accounts whose database role is admin or founder may leave game ID blank; registration still requires a unique 6- or 7-digit ID. Existing local-demo accounts are not migrated to Supabase and are not accepted by online login.

Existing player profiles must receive a unique 6- or 7-digit game ID before they can log in. Admin/founder profiles can omit it. Run supabase-founder-admin-setup.sql after the game-ID migration to promote existing Sonse/Federal profiles and assign Sonse ID 530047; this does not create Auth accounts or change passwords.

Security notes:
- The browser contains only the Supabase project URL and public publishable key. This is expected.
- NEVER put a service_role key, sb_secret key, database password, or user password into HTML.
- Admin/verified permissions must be granted from trusted Supabase SQL/dashboard tooling, never from browser code.
- After CF_FACEIT_V9_MATCHMAKING_RESULTS.sql is installed, the v9 matchmaking queue, team assignment, host choice and screenshot result approval are server-backed. Leaderboard, news and tournaments may still use local/demo data. The website cannot inspect the game process; players submit proof when they return to the site.

CF FACEIT v30 (24.10.2026): см. CF_FACEIT_V30_SETUP.txt. Перед использованием index.html v30 выполни SQL/28_v30_prime_bans_banners.sql. Telegram Stars требует Edge Functions и секреты, перечисленные в инструкции.

CF FACEIT v37 — фото- и видеобаннер профиля: см. WHATS_NEW_V37_PROFILE_BANNERS.txt. Для онлайн-загрузок до публикации выполни SQL/34_profile_banner_media.sql после SQL/28_v30_prime_bans_banners.sql. В локальном демо медиа сохраняется только в IndexedDB текущего браузера; онлайн-медиа становится публичным фоном профиля, а загрузка в Storage ограничена папкой владельца.

CF FACEIT v38 — исправление таймера матча и прикрепления скриншота: см. WHATS_NEW_V38_MATCH_TIMER_SCREENSHOTS.txt. После нужных старых миграций выполни SQL/35_match_timer_and_screenshot_fix.sql в Supabase; сайт публикуй из PAGES_UPLOAD/.

CF FACEIT v42 — автоматическая очистка отменённых матчей и расширенные ответы бота поддержки: см. V42_README_PLEASE_READ_FIRST.txt. После SQL/32 запусти SQL/36_cancelled_match_cleanup_20m.sql; после SQL/23 запусти SQL/37_messenger_support_answers.sql. Очистка охватывает текущие v9-таблицы cf_lobby_matches и cf_matchmaking_queue, но не legacy public.matches, чтобы сохранить данные проверки. Опубликуй содержимое PAGES_UPLOAD/. База и сайт изменяются отдельно; сами SQL-файлы автоматически не выполняются.

CF FACEIT v43 — исправления регистрации и входа: см. WHATS_NEW_V43_AUTH_FIX.txt. После SQL/01 и SQL/27 запусти SQL/38_auth_registration_login_hardening.sql, затем обнови Edge Function login-by-nickname кодом из edge-function-code/login-by-nickname.ts.txt и опубликуй PAGES_UPLOAD/ на VPS. SQL, Edge Function и сайт обновляются отдельно.

CF FACEIT v44 — выбор региона «Все регионы» (общая очередь), Россия, Европа или Азия при регистрации, сохранение и смена региона в настройках, региональная очередь матчмейкинга и HTTP-замер RTT до региональных probe-узлов. После v9 SQL/10-16, SQL/30 и SQL/38 запусти SQL/39_regions_and_ping.sql. Затем опубликуй содержимое PAGES_UPLOAD/ на VPS. Измерение показывает сетевую задержку до узла проверки, не до игрового сервера: для точного игрового ping нужны отдельные доступные игровые серверы/IP в каждом регионе.

CF FACEIT v45 — смена игрового ID из своего чата поддержки и кнопка восстановления пароля по коду email. После SQL/37, SQL/38 и SQL/39 запусти SQL/40_support_account_recovery.sql; затем опубликуй PAGES_UPLOAD/ на VPS. Смена разрешена только вошедшему пользователю для собственного профиля, ID проверяется на 6–7 цифр и уникальность. Сброс использует Supabase Auth email OTP; пароли и коды не сохраняются в чате. Для настройки письма следуй PASSWORD_RECOVERY_SETUP_RU.txt.

CF FACEIT v46 — см. WHATS_NEW_V46_PLAYER_HOST_MODERATION.txt. После SQL/10–16, SQL/21, SQL/28, SQL/30, SQL/35, SQL/39 и SQL/40 запусти SQL/41_player_host_and_moderation.sql; затем опубликуй PAGES_UPLOAD/ на VPS. Комнату создаёт выбранный игрок, отмена доступна до старта, таймер начинается по подтверждению организатора. Добавлены баны по дням, ограничения старта матчей и роль «Сотрудничество» с синей галочкой. Живой Supabase, AI Edge Function и VPS не обновлялись этим пакетом.

CF FACEIT v48 — вход по никнейму теперь работает по никнейму и паролю без игрового ID. Обнови PAGES_UPLOAD/ на VPS и разверни новую функцию из edge-function-code/login-by-nickname.ts.txt в Supabase. SQL/38 должен быть установлен; новая SQL-миграция не нужна.

CF FACEIT v49 — значок спонсора, серверная выдача/снятие через отдельное админское поле без изменения верификации, цвета ника и личный фон сайта для владельцев значка; обновлённый полноширинный профиль и FAQ-поддержка. См. PAGES_UPLOAD/WHATS_NEW_V49_SPONSOR_BADGE.txt. Для актуальных ответов и фильтра чата повторно запусти SQL/40 после SQL/37–39; затем после SQL/41 выполни SQL/42_sponsor_badge_and_profile_customization.sql и опубликуй PAGES_UPLOAD/ на VPS.
