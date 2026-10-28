/* =========================================================
   CF FACEIT — Supabase-backed application logic (vanilla JS)
   Authenticated profiles, matchmaking, results and published
   content are server-owned; browser storage is never authoritative.
   ========================================================= */
(function () {
'use strict';

/* ---------- Config & constants ---------- */
var KEYS = {
  session: 'cfFaceit.session.v1',
  intro: 'cfFaceit.introSeen.v1',
  link: 'cfFaceit.cfLink.v1'
};
// Remove insecure data left by the old local-only demo. It can contain plaintext passwords and fake results.
try { ['cfFaceit.accounts.v1','cfFaceit.matches.v1','cfFaceit.inbox.v1','cfFaceit.news.v1'].forEach(function(key){localStorage.removeItem(key);}); } catch (e) {}
var reduceMotion = !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);
var NICK_RE = /^[A-Za-z0-9_-]{3,20}$/;
var LEVELS = [0, 800, 950, 1100, 1250, 1400, 1550, 1700, 1850, 2000]; // ELO needed for level 1..10
var SECTIONS = ['home', 'news', 'search', 'play', 'top', 'tournaments', 'profile']; // left-to-right order in the bottom nav
var MAPS = ['Vertigo', 'Mirage', 'Dust2', 'Inferno'];
var MAP_IMAGES = {
  'Vertigo': 'images/map-vertigo.jpg',
  'Mirage': 'images/map-mirage.jpg',
  'Dust2': 'images/map-dust2.jpg',
  'Inferno': 'images/map-inferno.jpg'
};
var MODES = [
  { id: 'ranked', name: 'Соревновательный 5×5', desc: 'Классический рейтинговый режим', spread: 75, min: 3500, max: 6000 },
  { id: 'duo', name: 'Быстрый 2×2', desc: 'Короткие матчи в паре', spread: 120, min: 2500, max: 4500 }
];
var AVATARS = [
  { id: 'ember', name: 'Янтарный', c1: '#FF5500', c2: '#a83300' },
  { id: 'steel', name: 'Стальной', c1: '#7b8794', c2: '#39424c' },
  { id: 'azure', name: 'Лазурный', c1: '#3b82c4', c2: '#1b3f66' },
  { id: 'moss', name: 'Моховой', c1: '#5c9a5a', c2: '#2a4a2b' },
  { id: 'plum', name: 'Сливовый', c1: '#8e5ab0', c2: '#46285c' },
  { id: 'sand', name: 'Песочный', c1: '#b8914f', c2: '#5e4724' }
];
var CHANNEL_URL = 'https://t.me/sonsecf';
var NEWS = [];
var cfOnlineNewsPromise=null,cfOnlineNewsLoaded=false,cfOnlineNewsAttempted=false,cfOnlineNewsError='',cfNewsPreviewUrl='';
function cfMapOnlineNewsRow(row){
  var path=String(row.media_path||row.image_path||''),url='';
  if(/^https:\/\//i.test(path)||/^(?:\/|\.\/)?(?:images|assets)\//i.test(path))url=path;
  else if(path&&cfSupabaseClient&&cfSupabaseClient.storage){var pub=cfSupabaseClient.storage.from('cf-news-media').getPublicUrl(path);url=pub&&pub.data&&pub.data.publicUrl||'';}
  var description=String(row.description||'');
  return {id:'online-'+String(row.id),feature:false,tag:'Новость',date:row.created_at?new Date(row.created_at).toLocaleDateString('ru-RU'):'',title:String(row.title||''),link:String(row.link||''),img:url,mediaType:row.media_type||(localeLower(path).endsWith('.mp4')?'video':'image'),desc:description,body:description?[description]:[]};
}
function localeLower(value){return String(value||'').toLowerCase();}
async function cfLoadOnlineNews(force){
  if(!cfSupabaseClient||!cfSupabaseClient.from)return false;
  if(cfOnlineNewsPromise&&!force)return cfOnlineNewsPromise;
  cfOnlineNewsAttempted=true;
  cfOnlineNewsError='';
  cfOnlineNewsPromise=(async function(){
    var r=await cfSupabaseClient.from('news').select('id,title,description,link,image_path,media_path,media_type,published,created_at').eq('published',true).order('created_at',{ascending:false}).limit(60);
    if(r.error)throw r.error;
    var remote=(r.data||[]).map(cfMapOnlineNewsRow).filter(function(n){return n.title;});
    NEWS=remote;
    cfOnlineNewsLoaded=true;
    cfOnlineNewsError='';
    if(curSec==='news')renderSection('news');
    return true;
  })().catch(function(err){cfOnlineNewsError=String(err&&err.message||'Сервер новостей временно недоступен');console.warn('Online news could not be loaded',err);return false;}).finally(function(){cfOnlineNewsPromise=null;if(curSec==='news')renderSection('news');});
  return cfOnlineNewsPromise;
}

/* ---------- Safe localStorage wrapper ---------- */
var memStore = {};
var storageWorks = true;
var store = {
  get: function (k) {
    try { var v = window.localStorage.getItem(k); if (v !== null) return v; } catch (e) { storageWorks = false; }
    return Object.prototype.hasOwnProperty.call(memStore, k) ? memStore[k] : null;
  },
  set: function (k, v) {
    memStore[k] = v;
    try { window.localStorage.setItem(k, v); return true; } catch (e) { storageWorks = false; return false; }
  },
  remove: function (k) {
    delete memStore[k];
    try { window.localStorage.removeItem(k); } catch (e) { storageWorks = false; }
  }
};
function readJSON(k, fallback) {
  var raw = store.get(k);
  if (raw === null || raw === undefined) return fallback;
  try { return JSON.parse(raw); } catch (e) { return fallback; }
}
// Published news are loaded from Supabase only; local browser news are not authoritative.
// News are loaded from Supabase only; browser-local drafts are never shown as published news.

/* ---------- Helpers ---------- */
function $(s, r) { return (r || document).querySelector(s); }
function $$(s, r) { return Array.prototype.slice.call((r || document).querySelectorAll(s)); }
function esc(s) {
  return String(s === undefined || s === null ? '' : s).replace(/[&<>"']/g, function (c) {
    return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
  });
}
function fmt(n) { try { return Number(n).toLocaleString('ru-RU'); } catch (e) { return String(n); } }
function rand(a, b) { return Math.floor(a + Math.random() * (b - a + 1)); }
function pick(arr) { return arr[Math.floor(Math.random() * arr.length)]; }
function icon(name) { return '<svg class="ic" aria-hidden="true"><use href="#i-' + name + '"/></svg>'; }
function fmtDate(iso) {
  try {
    var d = new Date(iso);
    if (isNaN(d.getTime())) return '—';
    return d.toLocaleDateString('ru-RU', { day: 'numeric', month: 'short' });
  } catch (e) { return '—'; }
}
function fmtTime(sec) { var m = Math.floor(sec / 60), s = sec % 60; return m + ':' + (s < 10 ? '0' : '') + s; }
var LVL_COLORS = ['#b7bcc4', '#3fcf6b', '#3fcf6b', '#ffc21a', '#ffc21a', '#ffc21a', '#ffc21a', '#ff8a00', '#ff8a00', '#ff3b2f'];
function lvlIcon(level, size) {
  var c = LVL_COLORS[Math.max(1, Math.min(10, level)) - 1], sz = size || 28, fs = level >= 10 ? 13 : 15;
  return '<svg class="lvl-ic" width="' + sz + '" height="' + sz + '" viewBox="0 0 32 32" role="img" aria-label="Уровень ' + level + '"><polygon points="16,2 28,9 28,23 16,30 4,23 4,9" fill="' + c + '" fill-opacity=".14" stroke="' + c + '" stroke-width="2.4" stroke-linejoin="round"/><text x="16" y="21.2" text-anchor="middle" font-family="Tektur,Golos Text,system-ui,sans-serif" font-weight="700" font-size="' + fs + '" fill="' + c + '">' + level + '</text></svg>';
}
var cfMyRank = null, cfHist = null, cfMeAt = 0;
function histOf(u) { return (cfOnlineAccount && u === cfOnlineAccount) ? (cfHist || []) : (u.history || []); }
async function cfRefreshMe(force) {
  if (!cfSupabaseClient || !cfOnlineAccount) return;
  if (!force && Date.now() - cfMeAt < 15000) return;
  cfMeAt = Date.now();
  try {
    var ur = await cfSupabaseClient.auth.getUser(), user = ur.data && ur.data.user; if (!user) return;
    var before = cfOnlineAccount.elo + '/' + cfOnlineAccount.wins + '/' + cfOnlineAccount.losses;
    var acc = await cfLoadOnlineProfile(user);
    var h = await cfSupabaseClient.rpc('cf_my_history'), nh = (!h.error && Array.isArray(h.data)) ? h.data : cfHist;
    var changed = before !== acc.elo + '/' + acc.wins + '/' + acc.losses || JSON.stringify(nh) !== JSON.stringify(cfHist);
    cfHist = nh;
    if (changed && (curSec === 'profile' || curSec === 'home')) renderSection(curSec);
  } catch (e) {}
}
setInterval(function () { if (!document.hidden) cfRefreshMe(false); }, 20000);
function rankText(r) { return r && r.rank ? 'Топ #' + r.rank : ''; }
function paintMyRank() {
  var t = rankText(cfMyRank);
  $$('[data-myrank]').forEach(function (el) { el.textContent = t || '—'; el.hidden = !t; });
}
function levelInfo(elo) {
  var lvl = 1, i;
  for (i = 0; i < LEVELS.length; i++) { if (elo >= LEVELS[i]) lvl = i + 1; }
  var cur = LEVELS[lvl - 1], next = lvl < LEVELS.length ? LEVELS[lvl] : null;
  var pct = next ? Math.max(0, Math.min(100, (elo - cur) / (next - cur) * 100)) : 100;
  return { level: lvl, cur: cur, next: next, pct: pct };
}
function tierName(l) { return l >= 10 ? 'Легенда' : l >= 8 ? 'Элита' : l >= 5 ? 'Опытный игрок' : 'Новичок'; }
function matchStats(u) {
  var wins = Number(u && u.wins), losses = Number(u && u.losses);
  wins = isFinite(wins) ? Math.max(0, Math.floor(wins)) : 0;
  losses = isFinite(losses) ? Math.max(0, Math.floor(losses)) : 0;
  var matches = wins + losses;
  return { wins: wins, losses: losses, matches: matches, winRate: matches ? Math.round(wins / matches * 100) : 0 };
}
function winRate(u) { return matchStats(u).winRate; }
function avatar(id, name, size, frame) {
  var markup;
  if (typeof id === 'string' && (/^data:image\//i.test(id) || /^https:\/\//i.test(id))) markup = '<span class="avatar" style="--s:' + size + 'px;background:#17191f;overflow:hidden"><img src="' + esc(id) + '" alt="" style="width:100%;height:100%;object-fit:cover;border-radius:50%"></span>';
  else { var a = AVATARS.filter(function (x) { return x.id === id; })[0] || AVATARS[0]; var ch = String(name || '?').trim().charAt(0).toUpperCase() || '?'; markup = '<span class="avatar" style="--s:' + size + 'px;background:linear-gradient(135deg,' + a.c1 + ',' + a.c2 + ')" aria-hidden="true">' + esc(ch) + '</span>'; }
  var labels={violet:'Violet Flux',collab:'CFGRADE X CF FACEIT',arctic:'Arctic Pulse',crimson:'Crimson Edge',iris:'Black Iris'};
  if(!Object.prototype.hasOwnProperty.call(labels,frame))return markup;
  return '<span class="cf-player-frame cf-player-frame--'+frame+'" style="--frame-size:'+size+'px" role="img" aria-label="Рамка '+labels[frame]+' у игрока '+esc(name||'')+'">'+markup+'</span>';
}
var VERIFY_ELO = 3000; // gold badge is granted automatically from this ELO (or manually via the verified flag)
function hasBadge(u) { return !!(u && (u.verified || u.elo >= VERIFY_ELO)); }
function badgeHint(u) {
  if (hasBadge(u)) return 'Золотая галочка у тебя есть.';
  return 'Золотая галочка выдаётся за ' + fmt(VERIFY_ELO) + ' ELO — осталось ' + fmt(VERIFY_ELO - u.elo) + '.';
}
function cfNickStyleClass(u){var value=u&&(u.sponsorBadge||u.sponsor_badge)?(u.sponsorNicknameStyle||u.sponsor_nickname_style):'';return value==='blue'?'cf-nick-blue':value==='gradient'?'cf-nick-gradient':value==='rainbow'?'cf-nick-rainbow':'';}
function cfStyledNickHTML(name,u){return '<span class="cf-player-name '+cfNickStyleClass(u)+'">'+esc(name||'')+'</span>';}
function cfSponsorBadgeMarkup(u){return u&&(u.sponsorBadge||u.sponsor_badge)?'<span class="cf-sponsor-badge" data-sponsor-badge role="button" tabindex="0" aria-haspopup="dialog" aria-label="Значок спонсора CF FACEIT. Нажмите, чтобы узнать подробнее." title="Спонсор CF FACEIT"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 3h16v4H8v3h9v4H8v7H4z"/></svg></span>':'';}
function cfRoleStatusMarkup(u){var role=u&&u.role,label=role==='founder'?'Основатель':role==='admin'?'Админ':role==='tester'?'Тестер':role==='cooperation'?'Сотрудничество':'';return label?'<span class="cf-public-role cf-public-role--'+esc(role)+'">'+label+'</span>':'';}
function vbadge(u) {
  var roleBadge='';
  if (u && (u.founder || u.role === 'founder')) roleBadge='<svg class="founder-badge" viewBox="0 0 24 24" role="img" aria-label="Основатель CF FACEIT" title="Основатель"><use href="#i-founder"/></svg>';
  else if (u && u.role === 'cooperation') roleBadge='<svg class="vbadge cooperation-badge" viewBox="0 0 24 24" role="img" aria-label="Сотрудничество" title="Сотрудничество"><use href="#i-verified"/></svg>';
  else if (hasBadge(u)) roleBadge='<svg class="vbadge" viewBox="0 0 24 24" role="img" aria-label="Подтверждённый аккаунт"><use href="#i-verified"/></svg>';
  return roleBadge+cfSponsorBadgeMarkup(u)+cfRoleStatusMarkup(u);
}
function animateNumber(el, from, to, ms) {
  if (!el) return;
  if (reduceMotion || from === to) { el.textContent = fmt(to); return; }
  var t0 = performance.now(); ms = ms || 900;
  function step(t) {
    if (!el.isConnected) return;
    var p = Math.min(1, (t - t0) / ms), e = 1 - Math.pow(1 - p, 3);
    el.textContent = fmt(Math.round(from + (to - from) * e));
    if (p < 1) requestAnimationFrame(step);
  }
  requestAnimationFrame(step);
}

/* ---------- Toasts ---------- */
function toast(msg, type) {
  var box = $('#toasts');
  while (box.children.length >= 3) box.removeChild(box.firstChild);
  var t = document.createElement('div');
  t.className = 'toast ' + (type || 'info');
  t.setAttribute('role', type === 'error' ? 'alert' : 'status');
  t.innerHTML = icon(type === 'error' ? 'info' : type === 'success' ? 'check' : 'info') + '<span>' + esc(msg) + '</span>';
  box.appendChild(t);
  setTimeout(function () { t.classList.add('out'); }, 3000);
  setTimeout(function () { if (t.parentNode) t.parentNode.removeChild(t); }, 3400);
}

/* ---------- Show / hide screens with fade ---------- */
function showEl(el) {
  clearTimeout(el._t);
  el.hidden = false;
  el.classList.add('is-out');
  void el.offsetWidth;
  el.classList.remove('is-out');
}
function hideEl(el, ms, cb) {
  clearTimeout(el._t);
  el.classList.add('is-out');
  el._t = setTimeout(function () {
    el.hidden = true;
    el.classList.remove('is-out');
    if (cb) cb();
  }, reduceMotion ? 0 : ms);
}
function restartAnim(el, cls) { el.classList.remove(cls); void el.offsetWidth; el.classList.add(cls); }

/* ---------- Accounts ---------- */
function validateNick(v) {
  if (!v) return 'Введи никнейм.';
  if (v.length < 3 || v.length > 20) return 'Длина никнейма — от 3 до 20 символов.';
  if (!NICK_RE.test(v)) return 'Допустимы только латинские буквы, цифры, _ и -.';
  return '';
}
function validateGameId(v) {
  return /^[0-9]{6,7}$/.test(v) ? '' : 'Игровой ID — 6 или 7 цифр.';
}

/* ---------- Session ---------- */
var sessionNick = null;
var lastEloShown = null;
function getUser() { return sessionNick && cfOnlineAccount && cfOnlineAccount.id && cfOnlineAccount.nick.toLowerCase() === String(sessionNick).toLowerCase() ? cfOnlineAccount : null; }
function updateUser(mutator) {
  if (!cfOnlineAccount || !cfOnlineAccount.id || !sessionNick || cfOnlineAccount.nick.toLowerCase() !== String(sessionNick).toLowerCase()) return null;
  mutator(cfOnlineAccount);
  cfSaveOnlineProfile(cfOnlineAccount).then(function(){toast('Профиль синхронизирован с сервером','success');}).catch(function(err){toast('Не удалось сохранить профиль онлайн: '+(err.message||'ошибка'),'error');});
  return cfOnlineAccount;
}

/* ---------- Modal ---------- */
var modalRoot = $('#modalRoot'), modalBody = $('#modalBody'), modalBox = $('#modalBox');
var modalOpen = false, modalTimer = null, lastFocus = null;
function openModal(html, onOpen, wide) {
  clearTimeout(modalTimer);
  modalRoot.classList.remove('cf-sponsor-modal');
  if (!modalOpen) lastFocus = document.activeElement;
  modalBox.classList.toggle('wide', !!wide);
  modalBody.innerHTML = html;
  modalRoot.hidden = false;
  modalRoot.setAttribute('aria-hidden', 'false');
  void modalRoot.offsetWidth;
  modalRoot.classList.add('open');
  modalOpen = true;
  modalBox.scrollTop = 0;
  if (onOpen) onOpen(modalBody);
  cfHydrateBannerMedia(modalBody);
  var first = modalBody.querySelector('input,select,textarea');
  try { (first || modalBox).focus({ preventScroll: true }); } catch (e) {}
}
function closeModal() {
  if (!modalOpen) return;
  modalOpen = false;
  modalRoot.classList.remove('open','cf-sponsor-modal');
  modalRoot.setAttribute('aria-hidden', 'true');
  clearTimeout(modalTimer);
  modalTimer = setTimeout(function () { modalRoot.hidden = true; modalBody.innerHTML = ''; }, reduceMotion ? 0 : 240);
  if (lastFocus && lastFocus.focus && document.contains(lastFocus)) { try { lastFocus.focus({ preventScroll: true }); } catch (e) {} }
  lastFocus = null;
}
modalRoot.addEventListener('click', function (e) { if (e.target.closest('[data-close]')) closeModal(); });
document.addEventListener('click',function(e){var badge=e.target&&e.target.closest?e.target.closest('[data-sponsor-badge]'):null;if(!badge)return;e.preventDefault();e.stopPropagation();cfOpenSponsorInfo();},true);
document.addEventListener('keydown',function(e){var badge=e.target&&e.target.closest?e.target.closest('[data-sponsor-badge]'):null;if(!badge||(e.key!=='Enter'&&e.key!==' '))return;e.preventDefault();e.stopPropagation();cfOpenSponsorInfo();},true);
document.addEventListener('keydown', function (e) {
  if (!modalOpen) return;
  if (e.key === 'Escape') { e.preventDefault(); closeModal(); return; }
  if (e.key === 'Tab') {
    var f = $$('button:not([disabled]),input:not([disabled]),select,a[href],[tabindex]:not([tabindex="-1"])', modalBox).filter(function (n) { return n.offsetParent !== null; });
    if (!f.length) return;
    var first = f[0], last = f[f.length - 1];
    if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
  }
});

/* =========================================================
   Authentication UI
   ========================================================= */
var authEl = $('#auth'), authCard = $('#authCard'), welcomeEl = $('#welcome'), appEl = $('#app'), splashEl = $('#splash');
var authBusy = false;

function setFieldError(input, msg) {
  var f = input.closest('.field');
  var e = f.querySelector('.err');
  e.textContent = msg || '';
  f.classList.toggle('invalid', !!msg);
  input.setAttribute('aria-invalid', msg ? 'true' : 'false');
}
function resetAuthForms() {
  $('#formLogin').reset(); $('#formRegister').reset(); wizShow(1, false);
  $$('.field', authCard).forEach(function (f) { f.classList.remove('invalid'); var e = f.querySelector('.err'); if (e) e.textContent = ''; });
  $$('.pw input', authCard).forEach(function (i) { i.type = 'password'; });
  $$('.pw-toggle', authCard).forEach(function (b) { b.setAttribute('aria-pressed', 'false'); b.setAttribute('aria-label', 'Показать пароль'); b.innerHTML = icon('eye'); });
}
var wiz = { step: 1 };
function wizShow(n, back) {
  n = Math.max(1, Math.min(3, n)); wiz.step = n;
  $$('#formRegister .rstep').forEach(function (sec) {
    var on = +sec.dataset.step === n;
    sec.classList.toggle('on', on); sec.classList.toggle('back', !!back);
  });
  $$('#wizDots i').forEach(function (d, i) { d.classList.toggle('on', i < n); });
  $('#wizStep').textContent = 'Шаг ' + n + ' из 3'; $('#paneRegister').dataset.wstep = n;
  $('#wizBack').hidden = n === 1; $('#wizNext').hidden = n === 3; $('#registerBtn').hidden = n !== 3;
  var f = $('#formRegister .rstep.on input'); if (f && !reduceMotion) setTimeout(function () { try { f.focus({ preventScroll: true }); } catch (e) {} }, 60);
}
async function wizNext() {
  if (wiz.step === 1) {
    var g = $('#regGameId'), msg = validateGameId(g.value.trim()); setFieldError(g, msg); if (msg) { g.focus(); return; }
    if (cfSupabaseClient) {
      try {
        var chk = await cfSupabaseClient.rpc('cf_auth_check_registration', {p_nickname:'', p_game_id:g.value.trim()});
        if (chk.error) throw chk.error;
        if (chk.data && chk.data.game_id_taken) { setFieldError(g, 'Этот игровой ID уже занят. Введи другой.'); g.focus(); return; }
      } catch (e) {
        setFieldError(g, 'Не удалось проверить игровой ID. Обнови SQL регистрации в Supabase и попробуй снова.');
        g.focus(); return;
      }
    }
  } else if (wiz.step === 2) {
    var m = $('#regEmail'), v = m.value.trim().toLowerCase(), mm = !v ? 'Введи электронную почту.' : !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v) ? 'Проверь формат электронной почты.' : '';
    setFieldError(m, mm); if (mm) { m.focus(); return; }
  }
  wizShow(wiz.step + 1, false);
}
function setTab(which) {
  var login = which !== 'register';
  $('#tabLogin').setAttribute('aria-selected', login ? 'true' : 'false');
  $('#tabRegister').setAttribute('aria-selected', login ? 'false' : 'true');
  $('#tabLogin').tabIndex = login ? 0 : -1;
  $('#tabRegister').tabIndex = login ? -1 : 0;
  var fl = $('#formLogin'), fr = $('#paneRegister');
  fl.hidden = !login; fr.hidden = login;
  var shown = login ? fl : fr;
  restartAnim(shown, 'form-pane');
  $('#authTitle').textContent = login ? 'Вход' : 'Регистрация';
  if (!login) wizShow(1, false);
}
function showAuth(tab) {
  authBusy = false;
  splashEl.classList.remove('has-session');
  authCard.classList.remove('leaving');
  setTab(tab || 'login');
  showEl(authEl);
  restartAnim(authCard, 'play-in');
}

$('#wizNext').addEventListener('click', wizNext);
$('#wizBack').addEventListener('click', function () { wizShow(wiz.step - 1, true); });
$('#tabLogin').addEventListener('click', function () { setTab('login'); });
$('#tabRegister').addEventListener('click', function () { setTab('register'); });
$('#toLogin').addEventListener('click', function () { setTab('login'); $('#loginNick').focus(); });
$$('.tab').forEach(function (t) {
  t.addEventListener('keydown', function (e) {
    if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') {
      var toReg = t.id === 'tabLogin';
      setTab(toReg ? 'register' : 'login');
      (toReg ? $('#tabRegister') : $('#tabLogin')).focus();
    }
  });
});
$$('.pw-toggle').forEach(function (b) {
  b.addEventListener('click', function () {
    var inp = document.getElementById(b.dataset.target);
    var show = inp.type === 'password';
    inp.type = show ? 'text' : 'password';
    b.setAttribute('aria-pressed', show ? 'true' : 'false');
    b.setAttribute('aria-label', show ? 'Скрыть пароль' : 'Показать пароль');
    b.innerHTML = icon(show ? 'eye-off' : 'eye');
  });
});
authCard.addEventListener('input', function (e) {
  if (e.target.matches('#loginGameId, #regGameId')) e.target.value = e.target.value.replace(/[^0-9]/g, '').slice(0, 7);
  if (e.target.matches('input')) setFieldError(e.target, '');
});

function cfAuthErrorMessage(err, flow) {
  var message = String(err && (err.message || err.error_description || err.msg) || err || '').trim();
  var code = String(err && err.code || '').toLowerCase();
  var lower = (code + ' ' + message).toLowerCase();
  if (flow === 'register' && (code === 'email_exists' || /user already registered|already registered|email.{0,35}(already|exists|registered)|(?:already|exists|registered).{0,35}email/.test(lower))) return 'Этот адрес электронной почты уже зарегистрирован. Войди или восстанови пароль.';
  if (flow === 'register' && /nickname.{0,35}(already|exists|taken)|(?:already|exists|taken).{0,35}nickname|никнейм.{0,25}(занят|зарегистрирован)/.test(lower)) return 'Этот никнейм уже зарегистрирован. Введи другой.';
  if (flow === 'register' && /game.?id.{0,35}(already|exists|taken)|(?:already|exists|taken).{0,35}game.?id|игровой id.{0,25}(занят|зарегистрирован)/.test(lower)) return 'Этот игровой ID уже занят. Введи другой.';
  if (/email not confirmed|email_not_confirmed/.test(lower)) return 'Почта не подтверждена. Открой письмо от Supabase и подтверди адрес.';
  if (/invalid login credentials|invalid credentials|incorrect password|wrong password/.test(lower)) return flow === 'login' ? 'Неверный никнейм или пароль.' : 'Проверь почту и пароль.';
  if (/too many requests|rate.?limit|security purposes|try again in|after \d+ seconds/.test(lower)) return 'Слишком много попыток. Подожди немного и попробуй снова.';
  if (/password.{0,30}(weak|short|at least|minimum)|weak password/.test(lower)) return 'Пароль должен содержать не менее 8 символов.';
  if (/invalid email|email.{0,20}(invalid|malformed)|unable to validate email/.test(lower)) return 'Проверь формат электронной почты.';
  if (/sign.?ups? (are )?not allowed|sign.?ups? disabled|registration.*disabled/.test(lower)) return 'Регистрация временно недоступна. Обратись в поддержку.';
  if (/failed to fetch|fetcherror|network|timed out|timeout|connection refused/.test(lower)) return 'Не удалось связаться с сервером. Проверь интернет и попробуй снова.';
  if (/database error saving new user|profile.*not created|relation .*profiles.*does not exist|function .* does not exist|schema cache/.test(lower)) return 'Не удалось создать или найти профиль. Проверь SQL-миграцию регистрации в Supabase.';
  if (/[А-Яа-яЁё]/.test(message)) return message;
  return flow === 'register' ? 'Не удалось зарегистрироваться. Проверь данные и попробуй снова.' : flow === 'recovery' ? 'Не удалось восстановить пароль. Проверь данные и попробуй снова.' : 'Не удалось войти. Проверь данные и попробуй снова.';
}
function cfSignupOutcome(data) {
  var user=data&&data.user, identities=user&&user.identities;
  if(!user)return {status:'failure',message:'Не удалось подтвердить создание аккаунта. Попробуй снова.'};
  if(Array.isArray(identities)&&identities.length===0)return {status:'duplicate_email'};
  if(data.session)return {status:'signed-in',user:user,session:data.session};
  if(!Array.isArray(identities)||identities.length===0)return {status:'unverified'};
  return {status:'confirm-email',user:user};
}
function cfLoginUsesEmail(identifier) {
  return String(identifier || '').trim().indexOf('@') !== -1;
}
function updateLoginIdentifierUI() {
  var idField=$('#loginGameIdField'), idInput=$('#loginGameId'), hint=$('#loginIdentifierHint');
  idField.hidden=true;
  idInput.disabled=true;
  setFieldError(idInput,'');
  hint.textContent=cfLoginUsesEmail($('#loginNick').value)
    ? 'Для входа по почте нужны только адрес электронной почты и пароль.'
    : 'Для входа по нику нужны только никнейм и пароль. Игровой ID не требуется.';
}
async function onLoginSubmit(ev) {
  ev.preventDefault();
  if (authBusy) return;
  var nickEl=$('#loginNick'), passEl=$('#loginPass');
  var nick=nickEl.value.trim(), pass=passEl.value;
  var isEmail=cfLoginUsesEmail(nick);
  if(isEmail)nick=nick.toLowerCase();
  var first=null;
  var nickMsg=isEmail?(/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(nick)?'':'Проверь формат почты.'):validateNick(nick);if(nickMsg){setFieldError(nickEl,nickMsg);first=nickEl;}else setFieldError(nickEl,'');
  if(!pass){setFieldError(passEl,'Введи пароль.');first=first||passEl;}else setFieldError(passEl,'');
  if(first){var fst=first.closest('.rstep');if(fst&&+fst.dataset.step!==wiz.step)wizShow(+fst.dataset.step,true);first.focus();return;}
  if(!cfSupabaseClient){toast('Supabase не загрузился (нет интернета или заблокирован CDN). Обнови страницу.','error');return;}
  var btn=$('#loginBtn');btn.disabled=true;
  var session=null;
  try{
    if(isEmail){
      // Direct e-mail login: works even when the login-by-nickname Edge Function is not deployed.
      var er=await cfSupabaseClient.auth.signInWithPassword({email:nick,password:pass});
      if(er.error)throw new Error(cfAuthErrorMessage(er.error,'login'));
      session=er.data.session;
    }else{
      var r=await cfSupabaseClient.functions.invoke('login-by-nickname',{body:{nickname:nick,password:pass}});
      if(r.error){
        var edgeMessage='';var st=r.error.context&&r.error.context.status;
        try { if(r.error.context && typeof r.error.context.json==='function') { var errBody=await r.error.context.json(); if(errBody&&errBody.error) edgeMessage=errBody.error; } } catch(ignore) {}
        if(!edgeMessage){
          if(st===404||/FunctionsFetchError|Failed to send|fetch/i.test(String(r.error.name||'')+' '+String(r.error.message||'')))
            edgeMessage='Функция входа по никнейму не опубликована в Supabase. Войди по e-mail (впиши почту вместо никнейма) или опубликуй функцию login-by-nickname.';
          else edgeMessage=cfAuthErrorMessage(r.error,'login');
        }
        throw new Error(cfAuthErrorMessage(edgeMessage,'login'));
      }
      if(!r.data||!r.data.access_token||!r.data.refresh_token)throw new Error((r.data&&r.data.error)||'Неверный никнейм или пароль.');
      var sr0=await cfSupabaseClient.auth.setSession({access_token:r.data.access_token,refresh_token:r.data.refresh_token});
      if(sr0.error)throw sr0.error;
      session=sr0.data.session;
    }
    if(!session||!session.user)throw new Error('Сессия не создана. Попробуй ещё раз.');
    var acc=await cfLoadOnlineProfile(session.user);
    beginSession(acc);
  }catch(err){
    if(session){try{await cfSupabaseClient.auth.signOut();}catch(ignoreSignOut){}cfOnlineAccount=null;}
    var em=cfAuthErrorMessage(err,'login');
    if(/почта не подтверждена/i.test(em)){setFieldError(nickEl,em);nickEl.focus();}
    else setFieldError(passEl,em.length<90?em:'Не удалось войти.');
    toast(em,'error');
  }
  finally{btn.disabled=false;}
}
async function onRegisterSubmit(ev) {
  ev.preventDefault();
  if (authBusy) return;
  if (wiz.step < 3) { wizNext(); return; }
  var nickEl=$('#regNick'),gameIdEl=$('#regGameId'),emailEl=$('#regEmail'),regionEl=$('#regRegion'),p1=$('#regPass'),p2=$('#regPass2'),rules=$('#regRules');
  var nick=nickEl.value.trim(),gameId=gameIdEl.value.trim(),email=emailEl.value.trim().toLowerCase(),region=cfNormalizeRegion(regionEl&&regionEl.value),first=null,msg;
  msg=validateNick(nick);setFieldError(nickEl,msg);if(msg)first=nickEl;
  msg=validateGameId(gameId);setFieldError(gameIdEl,msg);if(msg)first=first||gameIdEl;
  msg=!email?'Введи электронную почту.':!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)?'Проверь формат электронной почты.':'';setFieldError(emailEl,msg);if(msg)first=first||emailEl;
  msg=!p1.value?'Придумай пароль.':p1.value.length<8?'Пароль должен быть не короче 8 символов.':'';setFieldError(p1,msg);if(msg)first=first||p1;
  msg=!p2.value?'Повтори пароль.':p1.value!==p2.value?'Пароли не совпадают.':'';setFieldError(p2,msg);if(msg)first=first||p2;
  msg=rules.checked?'':'Нужно принять правила.';setFieldError(rules,msg);if(msg)first=first||rules;
  if(first){first.focus();return;}
  if(!cfSupabaseClient){toast('Supabase не загрузился. Проверь интернет и обнови страницу.','error');return;}
  var btn=$('#formRegister button[type="submit"]');if(btn)btn.disabled=true;
  var signupSession=null;
  try{
    // Refuse signup until the region migration is installed, so a selected region cannot be silently discarded.
    var regionsReady=await cfSupabaseClient.rpc('cf_regions_enabled');
    if(regionsReady.error||regionsReady.data!==true)throw new Error('Региональный подбор ещё не настроен. Сначала запусти SQL/39_regions_and_ping.sql в Supabase.');
    // Check only the requested values; the server trigger and unique indexes remain authoritative.
    var availability=await cfSupabaseClient.rpc('cf_auth_check_registration',{p_nickname:nick,p_game_id:gameId});
    if(availability.error)throw new Error('Не удалось проверить никнейм и игровой ID. Установи SQL/38_auth_registration_login_hardening.sql в Supabase.');
    if(availability.data&&availability.data.nickname_taken){setFieldError(nickEl,'Этот никнейм уже зарегистрирован. Введи другой.');nickEl.focus();return;}
    if(availability.data&&availability.data.game_id_taken){setFieldError(gameIdEl,'Этот игровой ID уже занят. Введи другой.');wizShow(1,true);gameIdEl.focus();return;}
    var r=await cfSupabaseClient.auth.signUp({email:email,password:p1.value,options:{data:{nickname:nick,game_id:gameId,region:region},emailRedirectTo:location.origin+location.pathname}});
    if(r.error)throw r.error;
    var signup=cfSignupOutcome(r.data);
    if(signup.status==='duplicate_email')throw Object.assign(new Error('User already registered'),{code:'email_exists'});
    if(signup.status==='failure')throw new Error(signup.message);
    if(signup.status==='unverified')throw new Error('Не удалось подтвердить регистрацию. Проверь почту или попробуй войти.');
    if(signup.status==='signed-in'){
      signupSession=signup.session;
      var acc=await cfLoadOnlineProfile(signup.user);beginSession(acc);
    }else{
      toast('Аккаунт создан. Подтверди почту по ссылке из письма, затем войди.','success');
      setTab('login');$('#loginNick').value=email;$('#loginGameId').value=gameId;updateLoginIdentifierUI();
    }
  }catch(err){
    if(signupSession){try{await cfSupabaseClient.auth.signOut();}catch(ignoreSignOut){}cfOnlineAccount=null;}
    var regMessage=cfAuthErrorMessage(err,'register');
    if(/адрес электронной почты уже зарегистрирован/i.test(regMessage)){setFieldError(emailEl,regMessage);wizShow(2,true);emailEl.focus();}
    else if(/никнейм уже зарегистрирован/i.test(regMessage)){setFieldError(nickEl,regMessage);nickEl.focus();}
    else if(/игровой id уже занят/i.test(regMessage)){setFieldError(gameIdEl,regMessage);wizShow(1,true);gameIdEl.focus();}
    toast(regMessage,'error');
  }
  finally{if(btn)btn.disabled=false;}
}
$('#loginNick').addEventListener('input', updateLoginIdentifierUI);
updateLoginIdentifierUI();
$('#formLogin').addEventListener('submit', onLoginSubmit);
$('#formRegister').addEventListener('submit', onRegisterSubmit);

// Screen 3: successful login -> welcome splash -> dashboard
function beginSession(acc) {
  authBusy = true;
  lobby.state = null; lobby.seenInv = {}; lobby.unavailable = false; setTimeout(lobbyPoll, 600);
  sessionNick = acc.nick;
  if (acc && acc.id) cfOnlineAccount = acc;
  lastEloShown = null;
  store.set(KEYS.session, acc.nick);
  authCard.classList.add('leaving');
  setTimeout(function () {
    authEl.hidden = true;
    authCard.classList.remove('leaving');
    resetAuthForms();
    playWelcome(acc.display || acc.nick, function () { enterApp(); authBusy = false; });
  }, reduceMotion ? 30 : 350);
}

/* ---------- Welcome sequence: lockup animation + platform intro slides ---------- */
var wl = { timers: [], idx: 0, count: 4, done: true, cb: null, x0: null };
var WL_SKIP_KEY = 'cfFaceit.skipOnboard';
function wlLater(fn, ms) { wl.timers.push(setTimeout(fn, ms)); }
function wlClear() { wl.timers.forEach(clearTimeout); wl.timers = []; }
function wlGoTo(i) {
  wl.idx = Math.max(0, Math.min(wl.count - 1, i));
  $('#wlTrack').style.transform = 'translateX(' + (-wl.idx * 100) + '%)';
  $$('#wlDots i').forEach(function (d, k) { d.classList.toggle('on', k === wl.idx); });
  $('#wlPrev').disabled = wl.idx === 0;
  $('#wlGo').textContent = wl.idx === wl.count - 1 ? 'Начать играть' : 'Далее';
}
function finishWelcome() {
  if (wl.done) return;
  wl.done = true; wlClear();
  try { if ($('#wlOnce').checked) localStorage.setItem(WL_SKIP_KEY, '1'); } catch (e) {}
  var cb = wl.cb; wl.cb = null;
  if (cb) cb();
}
function playWelcome(name, done) {
  wlClear(); wl.done = false; wl.cb = done; wl.idx = 0;
  var el = welcomeEl, skipBoard = false;
  try { skipBoard = localStorage.getItem(WL_SKIP_KEY) === '1'; } catch (e) {}
  $('#wlTitle1').textContent = 'Добро пожаловать, ' + name + '!';
  $('#wlDots').innerHTML = new Array(wl.count + 1).join('<i></i>');
  $('#wlOnce').checked = false; $('#wlSkip').hidden = true;
  el.classList.remove('run', 'show-word', 'up', 'show-board');
  el.style.setProperty('--dy', -(Math.round(window.innerHeight / 2) - 58) + 'px');
  el.style.setProperty('--wl-top', '112px');
  wlGoTo(0);
  showEl(el);
  void el.offsetWidth;
  el.classList.add('run');
  var openBoard = function () {
    el.classList.add('show-board'); $('#wlSkip').hidden = false;
    try { $('#wlNext').focus({ preventScroll: true }); } catch (e) {}
  };
  if (reduceMotion) {
    el.classList.add('show-word', 'up');
    wlLater(skipBoard ? finishWelcome : openBoard, 350);
    return;
  }
  wlLater(function () { el.classList.add('show-word'); }, 950);    // text slides out to the right, logo shifts left
  wlLater(function () { el.classList.add('up'); }, 2350);          // lockup rises to the top and shrinks
  wlLater(skipBoard ? finishWelcome : openBoard, skipBoard ? 3500 : 3150);
}
$('#wlNext').addEventListener('click', function () { wlGoTo(wl.idx + 1); });
$('#wlPrev').addEventListener('click', function () { wlGoTo(wl.idx - 1); });
$('#wlGo').addEventListener('click', function () { if (wl.idx >= wl.count - 1) finishWelcome(); else wlGoTo(wl.idx + 1); });
$('#wlSkip').addEventListener('click', finishWelcome);
(function () {
  var vp = $('#wlViewport');
  vp.addEventListener('touchstart', function (e) { wl.x0 = e.touches[0].clientX; }, { passive: true });
  vp.addEventListener('touchend', function (e) {
    if (wl.x0 === null) return;
    var dx = e.changedTouches[0].clientX - wl.x0; wl.x0 = null;
    if (Math.abs(dx) > 45) wlGoTo(wl.idx + (dx < 0 ? 1 : -1));
  }, { passive: true });
  document.addEventListener('keydown', function (e) {
    if (wl.done || welcomeEl.hidden) return;
    if (e.key === 'ArrowRight') wlGoTo(wl.idx + 1);
    else if (e.key === 'ArrowLeft') wlGoTo(wl.idx - 1);
    else if (e.key === 'Escape') finishWelcome();
  });
})();

function enterApp() {
  setTimeout(function () { try { mgBoot(); } catch (e) {} }, 800);
  updateHeader();
  cfSitePresenceStart();
  startWatchers();
  curSec = null;
  showEl(appEl);
  navigate('home', { force: true, instant: true });
  hideEl(welcomeEl, 350);
}
function restoreApp() {
  updateHeader();
  cfSitePresenceStart();
  startWatchers();
  curSec = null;
  appEl.hidden = false;
  navigate('home', { force: true, instant: true });
}

/* ---------- Intro (Screen 1) ---------- */
var introDone = true, introTimers = [];
var LOAD_STEPS = [[2200, 'Загрузка интерфейса…'], [2900, 'Подготовка данных профиля…'], [3500, 'Проверка сессии…'], [4000, 'Запуск CF FACEIT…']];
var splashChoosing = false;
function playIntro() {
  try { if (cfSoundOn && sessionStorage.getItem('cfFaceit.introSound') !== '1') { sessionStorage.setItem('cfFaceit.introSound','1'); setTimeout(cfIntroSound,120); } } catch(e) {}
  introDone = false;
  introTimers.forEach(clearTimeout); introTimers = [];
  authEl.hidden = true;
  splashEl.classList.remove('is-out');
  splashEl.hidden = false;
  splashEl.classList.remove('cta-out', 'lift', 'cta-ready', 'quick'); splashChoosing = false;
  splashEl.classList.toggle('has-session', !!(sessionNick && getUser()));
  restartAnim(splashEl, 'run');
  if (sessionNick && getUser()) {
    introTimers.push(setTimeout(function () { finishIntro(false); }, reduceMotion ? 900 : 4500));
    introTimers.push(setTimeout(function () { finishIntro(false); }, 7000));
  } else {
    introTimers.push(setTimeout(function () { splashEl.classList.add('cta-ready'); }, reduceMotion ? 200 : 3100)); // wait for Войти / Регистрация
  }
}
function finishIntro(fast) {
  if (introDone) return;
  introDone = true;
  introTimers.forEach(clearTimeout); introTimers = [];
  store.set(KEYS.intro, '1');
  if (sessionNick && getUser()) restoreApp(); else showAuth('login');
  hideEl(splashEl, fast ? 250 : 500, function () { splashEl.classList.remove('run'); });
}
$('#skipIntro').addEventListener('click', function () {
  if (sessionNick && getUser()) finishIntro(true);
  else { introTimers.forEach(clearTimeout); introTimers = []; splashEl.classList.add('quick', 'cta-ready'); }
});
function splashChoose(tab) {
  if (splashChoosing) return;
  splashChoosing = true; introDone = true; introTimers.forEach(clearTimeout); introTimers = [];
  store.set(KEYS.intro, '1');
  $('#splashTag').textContent = tab === 'register' ? 'Создадим аккаунт за 3 шага: ID, почта, ник и пароль' : 'С возвращением! Входим в аккаунт';
  splashEl.classList.add('quick', 'cta-ready', 'cta-out');
  setTimeout(function () { splashEl.classList.add('lift'); }, reduceMotion ? 0 : 950);
  setTimeout(function () {
    showAuth(tab);
    hideEl(splashEl, 450, function () { splashEl.classList.remove('run', 'quick', 'cta-ready', 'cta-out', 'lift'); splashChoosing = false; });
  }, reduceMotion ? 60 : 1600);
}
$('#ctaLogin').addEventListener('click', function () { splashChoose('login'); });
$('#ctaReg').addEventListener('click', function () { splashChoose('register'); });
$('#authBack').addEventListener('click', function () {
  introDone = true; splashChoosing = false;
  splashEl.classList.remove('lift', 'cta-out', 'has-session', 'run'); splashEl.classList.add('quick', 'cta-ready');
  splashEl.hidden = false; showEl(splashEl);
  hideEl(authEl, 350);
});
$('#replayIntro').addEventListener('click', function () { playIntro(); });

/* ---------- Auth modals ---------- */
function openSetupHelp() {
  var saved = store.get(KEYS.link) || '';
  openModal(
    '<h2 id="modalTitle">Нет аккаунта CounterFlame?</h2>' +
    '<ol class="steps">' +
    '<li><span>Установи CounterFlame из официального источника.</span></li>' +
    '<li><span>Создай игровой аккаунт.</span></li>' +
    '<li><span>Привяжи Telegram в настройках игры, если это требуется в текущей версии игры.</span></li>' +
    '<li><span>Вернись в CF FACEIT.</span></li>' +
    '<li><span>Зарегистрируйся и найди свой первый матч.</span></li></ol>' +
    '<div class="field"><label for="cfLink">Ссылка на официальный источник (редактируемая заглушка)</label>' +
    '<input class="input" id="cfLink" type="url" inputmode="url" placeholder="https://… вставь официальную ссылку" value="' + esc(saved) + '" autocomplete="off">' +
    '<p class="err" id="cfLinkErr" role="alert"></p></div>' +
    '<p class="small">Мы не придумываем адреса загрузки: укажи ссылку, которую считаешь официальной.</p>' +
    '<div class="btn-row"><button class="btn" type="button" data-close>Закрыть</button><button class="btn primary" type="button" id="openCfLink">Открыть ссылку</button></div>',
    function (root) {
      var inp = $('#cfLink', root);
      inp.addEventListener('input', function () { setFieldError(inp, ''); });
      $('#openCfLink', root).addEventListener('click', function () {
        var v = inp.value.trim();
        if (!/^https?:\/\/\S+$/i.test(v)) { setFieldError(inp, 'Укажи корректную ссылку, начинающуюся с https://'); inp.focus(); return; }
        store.set(KEYS.link, v);
        window.open(v, '_blank', 'noopener,noreferrer');
      });
    });
}
function openRules() {
  openModal(
    '<h2 id="modalTitle">Правила платформы</h2>' +
    '<ol class="steps">' +
    '<li><span>CF FACEIT — неофициальный фан-проект, не связанный с FACEIT и разработчиками CounterFlame.</span></li>' +
    '<li><span>Не передавай пароль и данные аккаунта другим людям. Администрация никогда не просит пароль.</span></li>' +
    '<li><span>Играй честно: без читов, оскорблений и обмана администраторов.</span></li>' +
    '<li><span>Никнейм: 3–20 символов, латиница, цифры, _ и -. Никнеймы уникальны без учёта регистра.</span></li>' +
    '<li><span>Игровой ID: 6 или 7 цифр, только цифры. Он уникален и нужен для регистрации игрового профиля, но не для входа.</span></li></ol>' +
    '<div class="btn-row"><button class="btn primary" type="button" data-close>Понятно</button></div>');
}
$('#openSetup').addEventListener('click', openSetupHelp);
$('#openRules').addEventListener('click', openRules);
// Telegram registration is optional; email registration is available directly on this screen.

/* =========================================================
   App: header, navigation, rendering
   ========================================================= */
var view = $('#view');
var curSec = null, navTimer = null;

function updateHeader() {
  var u = getUser();
  cfApplySponsorWallpaper();
  if (!u) return;
  $('#userChip').innerHTML = avatar(u.avatar, u.display, 30, u.avatarFrame) + '<span class="nm ellipsis">' + cfStyledNickHTML(u.display,u) + vbadge(u) + '</span>';
  $('#bellBtn').hidden = !u.admin;
}
function updateNav(sec) {
  var navKey = sec === 'admin' ? 'profile' : sec === 'messenger' ? '' : sec; // the admin panel lives under Profile
  var idx = SECTIONS.indexOf(navKey);
  $$('.nav-item').forEach(function (b) {
    var on = b.dataset.nav === navKey;
    b.classList.toggle('active', on);
    if (on) b.setAttribute('aria-current', 'page'); else b.removeAttribute('aria-current');
  });
  var ind = $('#navInd');
  ind.style.transform = 'translateX(' + (idx * 100) + '%)';
  ind.style.opacity = idx < 0 ? '0' : '1';
}
function navigate(sec, opts) {
  opts = opts || {};
  if (SECTIONS.indexOf(sec) < 0 && sec !== 'admin' && sec !== 'messenger' && sec !== 'demos' && sec !== 'shop') sec = 'home';
  if (!getUser()) return;
  if (sec === 'admin' && !isAdmin(getUser())) sec = 'home';
  if (sec === curSec && !opts.force) { window.scrollTo(0, 0); return; }
  if (curSec === 'play' && sec !== 'play') resetPlay();
  curSec = sec;
  updateNav(sec);
  clearTimeout(navTimer);
  function apply() { renderSection(sec); view.classList.remove('dim'); window.scrollTo(0, 0); }
  if (opts.instant) apply();
  else { view.classList.add('dim'); navTimer = setTimeout(apply, reduceMotion ? 0 : 160); }
}
$$('.nav-item').forEach(function (b) { b.addEventListener('click', function () { navigate(b.dataset.nav); }); });
$('#userChip').addEventListener('click', function () { navigate('profile'); });
$('#bellBtn').addEventListener('click', function () { navigate('admin'); });

function mgBoot(){if(mgOnline())mgLoadList();}
function renderSection(sec) {
  var u = getUser();
  if (!u) return;
  if (sec === 'messenger' && !msgr.loading) { msgr.loading = true; msgr.open = null; mgLoadList().then(function () { msgr.loading = false; mgRerender(); }); }
  updateHeader();
  try {
    view.innerHTML = TEMPLATES[sec](u);
    if (BINDERS[sec]) BINDERS[sec](u);
    cfHydrateBannerMedia(view);
  } catch (err) {
    if (window.console) console.error(err);
    view.innerHTML = '<div class="card empty">' + icon('info') + '<p>Не удалось показать раздел.</p><button class="btn primary" type="button" data-act="retry">Повторить</button></div>';
  }
}

/* ---------- Templates ---------- */
function matchCard(m) {
  var win = m.res === 'W', d = Number(m.delta) || 0;
  return '<div class="match ' + (win ? 'win' : 'loss') + '"><span class="res">' + (win ? 'Победа' : 'Поражение') + '</span>' +
    '<div style="min-width:0"><b class="ellipsis">' + esc(m.map || '—') + '</b><span class="meta">' + esc(m.mode || '') + ' · ' + esc(m.score || '') + ' · ' + esc(fmtDate(m.date)) + '</span></div>' +
    '<span class="delta">' + (d > 0 ? '+' : '') + d + '</span></div>';
}
function emptyHistory() {
  return '<div class="empty">' + icon('play') + '<p>Матчей пока нет. Найди матч во вкладке «Играть».</p><button class="btn primary" type="button" data-go="play">Найти матч</button></div>';
}
function tplHome(u) {
  var lvl = levelInfo(u.elo), stats = matchStats(u), m = stats.matches;
  var news = NEWS.filter(function (n) { return !n.link; }).slice(0, 3).map(function (n) {
    return '<button type="button" class="list-row" data-news="' + n.id + '"><div class="grow"><div class="t">' + esc(n.title) + '</div><div class="d">' + esc(n.date) + '</div></div></button>';
  }).join('');
  var top = '<div id="homeTop">' + homeTopHTML() + '</div>';
  var recent = histOf(u).slice(0, 3).map(matchCard).join('') || emptyHistory();
  return '' +
    '<section class="section-head rise" style="--i:0"><h1 class="h1">Добро пожаловать, <span class="accent">' + cfStyledNickHTML(u.display,u) + vbadge(u) + cfPrimeBadge(u) + '</span></h1><p class="sub">Твой путь к вершине начинается здесь</p></section>' +
    '<section class="card rise" style="--i:1"><div class="elo-top"><div><span class="label" style="margin-bottom:2px">Рейтинг ELO</span><div class="elo-num" id="eloNum">' + fmt(u.elo) + '</div></div>' +
    '<div class="lvl-side">' + lvlIcon(lvl.level, 60) + '<span class="chip accent" data-myrank hidden></span></div></div>' +
    '<div class="bar" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="' + Math.round(lvl.pct) + '"><i id="eloBar" style="width:0"></i></div>' +
    '<p class="small muted" style="margin-bottom:14px">' + (lvl.next ? 'До уровня ' + (lvl.level + 1) + ': ' + (lvl.next - u.elo) + ' ELO' : 'Максимальный уровень') + '</p>' +
    '<button class="btn primary block" type="button" data-go="play">' + icon('play') + 'Найти матч</button></section>' +
    '<section class="stats rise" style="--i:2"><div class="tile"><b>' + lvl.level + '</b><span>Уровень</span></div><div class="tile"><b>' + m + '</b><span>Матчи</span></div><div class="tile"><b>' + stats.winRate + '%</b><span>Винрейт</span></div></section>' +
    '<p class="demo-note rise" style="--i:2">' + icon('info') + '<span>Конкурентный уровень: ' + esc(tierName(lvl.level)) + '. ' + badgeHint(u) + '</span></p>' +
    '<div class="grid-2">' +
    '<section class="card rise" style="--i:3"><div class="card-head"><h2>Последние новости</h2><button class="link-more" type="button" data-go="news">Все</button></div>' + news + '</section>' +
    '<section class="card rise" style="--i:4"><div class="card-head"><h2>Топ игроков</h2><button class="link-more" type="button" data-go="top">Весь рейтинг</button></div>' + top + '</section></div>' +
    '<section class="card rise" style="--i:5"><div class="card-head"><h2>Последние матчи</h2><button class="link-more" type="button" data-go="profile">История</button></div>' + recent + '</section>';
}
function socialHTML(u,featured) {
  var s=(u&&u.socials)||{}, items=[];
  [['telegram','Telegram'],['youtube','YouTube'],['tiktok','TikTok']].forEach(function(x){var url=String(s[x[0]]||''); if(/^https:\/\//i.test(url)) items.push('<a class="chip" href="'+esc(url)+'" target="_blank" rel="noopener noreferrer">'+x[1]+' ↗</a>');});
  if(!items.length)return '';
  return featured?'<div class="cf-profile-social"><strong>Социальные сети</strong><div class="chips">'+items.join('')+'</div></div>':'<div class="chips" style="margin-top:8px">'+items.join('')+'</div>';
}
function cfPrimeActive(u){return !!(u&&u.primeExpiresAt&&Date.parse(u.primeExpiresAt)>Date.now());}
function cfPrimeBadge(u){return cfPrimeActive(u)?'<span class="cf-prime-badge" title="FACEIT PRIME до '+esc(new Date(u.primeExpiresAt).toLocaleDateString('ru-RU'))+'">👑 PRIME</span>':'';}
function cfOpenSponsorInfo(){openModal('<section class="cf-sponsor-sheet"><span class="cf-sponsor-badge cf-sponsor-badge-preview" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M4 3h16v4H8v3h9v4H8v7H4z"/></svg></span><h2 id="modalTitle">Поддержка CF FACEIT</h2><div class="cf-sponsor-stars" aria-hidden="true"><i>✦</i><i>✦</i><i>✦</i><i>✦</i><i>✦</i></div><p>Этот значок выдаётся тем, кто поддержал проект CF FACEIT. Чтобы получить значок и привилегии, нужно поддержать проект не менее чем на 100 ₽. Значок выдаёт администрация после подтверждения поддержки.</p><a class="cf-sponsor-support" href="https://t.me/prisedents" target="_blank" rel="noopener noreferrer">Поддержать</a><div class="btn-row"><button class="btn" type="button" data-close>Закрыть</button></div></section>',null,false);modalRoot.classList.add('cf-sponsor-modal');}
function cfIsSponsorBackground(value,userId){try{var u=new URL(String(value||'')),base=window.CF_SUPABASE_URL?new URL(window.CF_SUPABASE_URL):null;if(!base||u.protocol!=='https:'||u.origin!==base.origin)return false;var id=userId||'[0-9a-f-]{36}',pattern=new RegExp('^/storage/v1/object/public/cf-sponsor-backgrounds/'+id+'/[a-z0-9-]+\\.(?:jpg|jpeg|png|webp|gif)$','i');return pattern.test(u.pathname)&&u.pathname.length<1900;}catch(e){return false;}}
function cfApplySponsorWallpaper(){var u=getUser(),body=document.body;if(!body)return;if(u&&u.sponsorBadge&&cfIsSponsorBackground(u.sponsorBackground,u.id)){document.documentElement.style.setProperty('--cf-profile-wallpaper','url("'+u.sponsorBackground.replace(/["\\\\]/g,'')+'")');body.classList.add('cf-sponsor-wallpaper');}else{document.documentElement.style.removeProperty('--cf-profile-wallpaper');body.classList.remove('cf-sponsor-wallpaper');}}
async function cfSaveSponsorProfile(background,style){if(!cfSupabaseClient||!cfOnlineAccount||!cfOnlineAccount.id)throw new Error('Войди в онлайн-аккаунт, чтобы сохранить привилегии спонсора.');var r=await cfSupabaseClient.rpc('cf_update_sponsor_profile',{p_background:background||'',p_nickname_style:style||'default'});if(r.error)throw r.error;cfOnlineAccount.sponsorBackground=r.data&&r.data.sponsor_background||'';cfOnlineAccount.sponsorNicknameStyle=r.data&&r.data.sponsor_nickname_style||'default';cfApplySponsorWallpaper();}
function cfSponsorImageExtension(type){return {'image/jpeg':'jpg','image/png':'png','image/webp':'webp','image/gif':'gif'}[type]||'';}
async function cfUploadSponsorBackground(file){if(!file)return '';var ext=cfSponsorImageExtension(file.type),u=getUser();if(!ext)throw new Error('Выбери JPG, PNG, WebP или GIF.');if(file.size>8*1024*1024)throw new Error('Фон должен быть не больше 8 МБ.');if(!u||!u.sponsorBadge||!cfOnlineAccount||u!==cfOnlineAccount)throw new Error('Загрузка фона доступна только спонсору в онлайн-аккаунте.');if(!cfSupabaseClient||!cfSupabaseClient.storage)throw new Error('Облачная галерея недоступна.');var id=crypto.randomUUID?crypto.randomUUID():Date.now()+'-'+Math.random().toString(36).slice(2),path=u.id+'/'+id+'.'+ext,up=await cfSupabaseClient.storage.from('cf-sponsor-backgrounds').upload(path,file,{cacheControl:'31536000',contentType:file.type,upsert:false});if(up.error)throw new Error(/bucket.*not found|does not exist/i.test(up.error.message||'')?'Сначала выполни SQL/42_sponsor_badge_and_profile_customization.sql.':up.error.message||'Не удалось загрузить фон.');var pub=cfSupabaseClient.storage.from('cf-sponsor-backgrounds').getPublicUrl(path),url=pub&&pub.data&&pub.data.publicUrl;if(!url||!cfIsSponsorBackground(url,u.id)){await cfSupabaseClient.storage.from('cf-sponsor-backgrounds').remove([path]);throw new Error('Ссылка на загруженный фон недействительна.');}return {url:url,path:path};}
function cfSponsorBackgroundObjectPath(url,userId){if(!cfIsSponsorBackground(url,userId))return '';try{return decodeURIComponent(new URL(url).pathname).split('/cf-sponsor-backgrounds/'+userId+'/')[1]||'';}catch(e){return '';}}
function cfBannerClass(key){return 'cf-cover-'+(['ember','inferno','dust','royal'].indexOf(key)>=0?key:'ember');}
function cfIsProfileBanner(value){if(['ember','inferno','dust','royal'].indexOf(value)>=0||/^local-banner:[a-z0-9-]{8,80}$/i.test(String(value||'')))return true;try{var u=new URL(value),base=window.CF_SUPABASE_URL?new URL(window.CF_SUPABASE_URL):null;return u.protocol==='https:'&&base&&u.origin===base.origin&&/\/storage\/v1\/object\/public\/cf-profile-banners\/[0-9a-f-]{36}\/[a-z0-9._/-]+$/i.test(u.pathname)&&u.pathname.length<1900;}catch(e){return false;}}
function cfProfileBannerMarkup(value){var local=String(value||'').match(/^local-banner:([a-z0-9-]{8,80})$/i);if(local)return '<div class="cf-profile-cover cf-cover-ember" data-banner-local="'+esc(local[1])+'"></div>';if(!cfIsProfileBanner(value)||['ember','inferno','dust','royal'].indexOf(value)>=0)return '<div class="cf-profile-cover '+cfBannerClass(value)+'"></div>';var video=/\.(mp4|webm|mov|m4v)$/i.test(new URL(value).pathname),tag=video?'<video class="cf-profile-cover-media" src="'+esc(value)+'" muted loop autoplay playsinline aria-hidden="true"></video>':'<img class="cf-profile-cover-media" src="'+esc(value)+'" alt="" aria-hidden="true">';return '<div class="cf-profile-cover cf-cover-custom">'+tag+'</div>';}
function cfProfileHeroMarkup(u,compact){
  var lvl=levelInfo(u.elo),size=compact?58:82;
  var role=u.founder?'<span class="chip founder">Основатель</span>':(u.admin?'<span class="chip gold">Администратор</span>':(u.role==='tester'?'<span class="chip accent">Тестер</span>':(u.role==='cooperation'?'<span class="chip" style="color:#6eabff;border-color:#2583f566;background:#2583f51a">Сотрудничество</span>':'')));
  return '<div class="cf-profile-hero'+(compact?' compact':'')+'">'+cfProfileBannerMarkup(u.profileBanner)+'<div class="cf-profile-bottom-gradient"></div><div class="cf-profile-hero-content"><div class="cf-profile-userpic">'+avatar(u.avatar,u.display,size,u.avatarFrame)+'</div><div class="ph-info cf-profile-identity"><h1 class="h1 ellipsis">'+cfStyledNickHTML(u.display,u)+vbadge(u)+'</h1><p class="muted small ellipsis cf-profile-account">Аккаунт: '+esc(u.nick)+'</p>'+(u.gameId?'<p class="muted small ellipsis cf-profile-gameid">Игровой ID: <b>'+esc(u.gameId)+'</b></p>':'')+'<div class="cf-profile-rankline">'+lvlIcon(lvl.level,compact?27:32)+'<span class="cf-profile-level-label">FACEIT · <span>Ур. '+lvl.level+'</span></span><span class="cf-profile-elo-chip"><small>ELO</small><b '+(!compact?'id="pfElo"':'')+'>'+fmt(u.elo)+'</b></span></div><div class="cf-profile-perks">'+cfPrimeBadge(u)+'<span class="chip">'+esc(tierName(lvl.level))+'</span><span class="chip accent" data-myrank hidden></span>'+role+'</div></div></div></div>';
}function cfHydrateBannerMedia(scope){if(!scope)return;$$('[data-banner-local]',scope).forEach(function(el){if(el.dataset.hydrating)return;el.dataset.hydrating='1';cfLoadLocalBanner(el.dataset.bannerLocal).then(function(url){if(!url||!el.isConnected)return;var type=url.type||'';var media=document.createElement(type.indexOf('video/')===0?'video':'img');media.className='cf-profile-cover-media';if(media.tagName==='VIDEO'){media.muted=true;media.loop=true;media.autoplay=true;media.playsInline=true;media.setAttribute('aria-hidden','true');media.src=url.src;var play=media.play();if(play&&play.catch)play.catch(function(){});}else{media.alt='';media.setAttribute('aria-hidden','true');media.src=url.src;}el.appendChild(media);}).catch(function(){el.dataset.hydrating='';});});}
function cfOpenPrime(){var u=getUser();if(!u)return;var until=cfPrimeActive(u)?new Date(u.primeExpiresAt).toLocaleString('ru-RU'):'не активен';openModal('<h2 id="modalTitle">👑 FACEIT PRIME</h2><section class="cf-prime-card card"><div class="cf-prime-hero">FACEIT PRIME</div><p>Особый статус в профиле CF FACEIT.</p><div class="stats s4" style="margin:12px 0"><div class="tile"><b>300 ⭐</b><span>Стоимость</span></div><div class="tile"><b>30 дней</b><span>Срок</span></div></div><p class="small muted">Текущий статус: <b>'+esc(until)+'</b></p><p class="small muted">Оплата подтверждается Telegram. После оплаты вернись сюда и нажми «Обновить статус».</p><div class="btn-row"><button class="btn" type="button" data-close>Закрыть</button><button class="btn" type="button" id="cfPrimeRefresh">Обновить статус</button><button class="btn primary" type="button" id="cfPrimeBuy">Купить за 300 ⭐</button></div><p class="small muted" id="cfPrimeMsg"></p></section>',function(root){var ref=$('#cfPrimeRefresh',root),buy=$('#cfPrimeBuy',root),msg=$('#cfPrimeMsg',root);ref.addEventListener('click',async function(){ref.disabled=true;try{await cfLoadOnlineProfile((await cfSupabaseClient.auth.getUser()).data.user);closeModal();renderSection(curSec==='profile'?'profile':curSec||'home');cfOpenPrime();}catch(e){msg.textContent=e.message||'Не удалось обновить статус';}finally{ref.disabled=false;}});buy.addEventListener('click',async function(){if(!cfSupabaseClient||!cfOnlineAccount){msg.textContent='Для покупки войди в онлайн-аккаунт.';return;}buy.disabled=true;msg.textContent='Создаём счёт Telegram Stars…';try{var r=await cfSupabaseClient.functions.invoke('cf-prime-invoice',{body:{}});if(r.error)throw r.error;var url=r.data&&(r.data.invoice_link||r.data.url);if(!url)throw new Error((r.data&&r.data.error)||'Ссылка оплаты не вернулась. Проверь публикацию Edge Function и TELEGRAM_BOT_TOKEN.');msg.textContent='Счёт создан. Открываем оплату Telegram Stars…';window.location.href=url;}catch(e){msg.textContent='Оплата не подключена: '+(e.message||'ошибка')+'. Нужна Edge Function cf-prime-invoice и секрет TELEGRAM_BOT_TOKEN.';}finally{buy.disabled=false;}});});}
async function cfSaveProfileBanner(acc){if(!cfSupabaseClient||!cfOnlineAccount||!acc||acc!==cfOnlineAccount)throw new Error('Войди в онлайн-аккаунт, чтобы сохранить баннер.');var value=cfIsProfileBanner(acc.profileBanner)&&String(acc.profileBanner).indexOf('local-banner:')!==0?acc.profileBanner:'ember';var r=await cfSupabaseClient.from('profiles').update({profile_banner:value}).eq('id',cfOnlineAccount.id).select('id').maybeSingle();if(r.error){var message=String(r.error.message||'');if(/profile_banner|column .*does not exist|schema cache/i.test(message))throw new Error('Сначала выполни SQL/48_profile_banner_upload_fix.sql в Supabase.');if(/row-level security|permission denied|not allowed/i.test(message))throw new Error('Supabase запретил сохранить баннер. Выполни SQL/48_profile_banner_upload_fix.sql и проверь, что ты вошёл в онлайн-аккаунт.');throw r.error;}if(!r.data)throw new Error('Профиль не найден для сохранения баннера. Обнови страницу и войди снова.');}
async function cfSetBanner(key){if(['ember','inferno','dust','royal'].indexOf(key)<0)return;try{var u=getUser();if(!u)return;var old=u.profileBanner;u.profileBanner=key;if(cfOnlineAccount&&u===cfOnlineAccount){try{await cfSaveProfileBanner(u);}catch(e){u.profileBanner=old;throw e;}var oldPath=cfBannerObjectPath(old,u.id);if(oldPath)cfSupabaseClient.storage.from('cf-profile-banners').remove([u.id+'/'+oldPath]).catch(function(){});}else{updateUser(function(a){a.profileBanner=key;});var prev=String(old||'').match(/^local-banner:([a-z0-9-]{8,80})$/i);if(prev)cfDeleteLocalBanner(prev[1]);}if(curSec==='profile')renderSection('profile');toast('Баннер профиля сохранён','success');}catch(e){toast('Не удалось сохранить баннер: '+(e.message||'ошибка'),'error');}}
function cfBannerDb(){if(!window.indexedDB)return Promise.reject(new Error('Браузерное хранилище файлов недоступно'));return new Promise(function(resolve,reject){var req=indexedDB.open('cf-faceit-media',1);req.onupgradeneeded=function(){if(!req.result.objectStoreNames.contains('profileBanners'))req.result.createObjectStore('profileBanners');};req.onsuccess=function(){resolve(req.result);};req.onerror=function(){reject(req.error||new Error('Не удалось открыть галерею профиля'));};});}
function cfStoreLocalBanner(file,key,type){return cfBannerDb().then(function(db){return new Promise(function(resolve,reject){var tx=db.transaction('profileBanners','readwrite');tx.objectStore('profileBanners').put({blob:file,type:type||file.type,name:file.name},key);tx.oncomplete=function(){db.close();resolve('local-banner:'+key);};tx.onerror=function(){db.close();reject(tx.error||new Error('Не удалось сохранить медиа в браузере'));};});});}
var cfBannerObjectUrls={};
function cfLoadLocalBanner(key){if(cfBannerObjectUrls[key])return Promise.resolve(cfBannerObjectUrls[key]);return cfBannerDb().then(function(db){return new Promise(function(resolve,reject){var req=db.transaction('profileBanners','readonly').objectStore('profileBanners').get(key);req.onsuccess=function(){db.close();if(!req.result||!req.result.blob){resolve(null);return;}var result={src:URL.createObjectURL(req.result.blob),type:req.result.type};cfBannerObjectUrls[key]=result;resolve(result);};req.onerror=function(){db.close();reject(req.error||new Error('Не удалось прочитать медиа профиля'));};});});}
function cfDeleteLocalBanner(key){if(cfBannerObjectUrls[key]){URL.revokeObjectURL(cfBannerObjectUrls[key].src);delete cfBannerObjectUrls[key];}return cfBannerDb().then(function(db){return new Promise(function(resolve){var tx=db.transaction('profileBanners','readwrite');tx.objectStore('profileBanners').delete(key);tx.oncomplete=tx.onerror=function(){db.close();resolve();};});}).catch(function(){});}
function cfBannerExtension(type){return {'image/jpeg':'jpg','image/png':'png','image/webp':'webp','image/gif':'gif','video/mp4':'mp4','video/webm':'webm','video/quicktime':'mov','video/x-m4v':'m4v'}[type]||'';}
function cfBannerMime(file){var allowed=['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm','video/quicktime','video/x-m4v'],type=String(file&&file.type||'').split(';')[0].trim().toLowerCase();if(type==='image/jpg')type='image/jpeg';if(allowed.indexOf(type)>=0)return type;if(type&&type!=='application/octet-stream'&&type!=='binary/octet-stream')return '';var ext=String(file&&file.name||'').split('.').pop().toLowerCase(),byExt={jpg:'image/jpeg',jpeg:'image/jpeg',png:'image/png',webp:'image/webp',gif:'image/gif',mp4:'video/mp4',webm:'video/webm',mov:'video/quicktime',m4v:'video/x-m4v'};return allowed.indexOf(byExt[ext])>=0?byExt[ext]:'';}
function cfBannerObjectPath(url,userId){try{var path=decodeURIComponent(new URL(url).pathname),prefix='/storage/v1/object/public/cf-profile-banners/'+userId+'/';return path.indexOf(prefix)===0?path.slice(prefix.length):'';}catch(e){return '';}}
var cfBannerPreviewObjectUrl='';
function cfBannerBytes(bytes){if(bytes<1024*1024)return Math.max(1,Math.round(bytes/1024))+' КБ';return (bytes/(1024*1024)).toFixed(1)+' МБ';}
function cfBannerSetStatus(state,message){var status=$('#cfProfileBannerStatus'),button=$('#cfProfileBannerPick'),action=$('[data-banner-pick-action]');if(status){status.dataset.state=state||'';status.textContent=message||'';}if(button)button.disabled=state==='uploading';if(action)action.textContent=state==='uploading'?'Загрузка…':'Выбрать';}
function cfPreviewProfileBannerFile(file){var preview=$('#cfProfileBannerPreview');if(!preview)return;if(cfBannerPreviewObjectUrl){URL.revokeObjectURL(cfBannerPreviewObjectUrl);cfBannerPreviewObjectUrl='';}preview.innerHTML='';if(!file){cfBannerSetStatus('','Перетащи сюда фото или видео или нажми «Выбрать». Максимум 20 МБ.');return;}var type=cfBannerMime(file);if(type){cfBannerPreviewObjectUrl=URL.createObjectURL(file);var media=document.createElement(type.indexOf('video/')===0?'video':'img');media.className='cf-banner-preview-media';media.src=cfBannerPreviewObjectUrl;if(media.tagName==='VIDEO'){media.muted=true;media.loop=true;media.playsInline=true;media.controls=true;}else{media.alt='Предпросмотр баннера';}preview.appendChild(media);}var name=document.createElement('span');name.className='cf-banner-preview-name';name.textContent=file.name+' · '+cfBannerBytes(file.size);preview.appendChild(name);cfBannerSetStatus('selected',type?'Файл выбран. Загружаю баннер…':'Проверяю формат файла…');}
function cfBannerErrorText(err){var message=String(err&&err.message||'');if(/bucket.*not found|bucket.*does not exist|profile_banner|schema cache|column .*does not exist/i.test(message))return 'Хранилище баннеров не настроено. Выполни SQL/48_profile_banner_upload_fix.sql в Supabase.';if(/row-level security|permission denied|not allowed|unauthorized|\b403\b/i.test(message))return 'Нет доступа к хранилищу баннеров. Проверь вход в онлайн-аккаунт и выполни SQL/48_profile_banner_upload_fix.sql.';if(/payload too large|file size|exceed.*size|\b413\b/i.test(message))return 'Файл больше лимита хранилища. Выбери баннер размером до 20 МБ.';if(/mime|content.?type|unsupported.*type/i.test(message))return 'Формат файла не разрешён хранилищем. Выполни SQL/48_profile_banner_upload_fix.sql или выбери JPG, PNG, WebP, GIF, MP4, WebM или MOV.';return message||'Не удалось сохранить баннер. Проверь соединение и попробуй ещё раз.';}
async function cfUploadProfileBanner(file,input){if(!file)return;var type=cfBannerMime(file);if(!type){var formatError='Не удалось определить формат. Выбери JPG, PNG, WebP, GIF, MP4, WebM, MOV или M4V.';cfBannerSetStatus('error',formatError);toast(formatError,'error');input.value='';return;}if(!file.size){var emptyError='Файл пустой. Выбери другое фото или видео.';cfBannerSetStatus('error',emptyError);toast(emptyError,'error');input.value='';return;}if(file.size>20*1024*1024){var sizeError='Размер баннера не должен превышать 20 МБ.';cfBannerSetStatus('error',sizeError);toast(sizeError,'error');input.value='';return;}input.disabled=true;cfBannerSetStatus('uploading','Загружаю баннер… Не закрывай профиль до завершения.');var u=getUser(),old=u&&u.profileBanner;try{if(!u)throw new Error('Сначала войди в аккаунт');if(cfOnlineAccount&&u===cfOnlineAccount){if(!cfSupabaseClient||!cfSupabaseClient.storage)throw new Error('Облачная загрузка недоступна.');var ext=cfBannerExtension(type),randomId=window.crypto&&typeof window.crypto.randomUUID==='function'?window.crypto.randomUUID():Date.now()+'-'+Math.random().toString(36).slice(2),path=u.id+'/'+randomId+'.'+ext,storage=cfSupabaseClient.storage.from('cf-profile-banners'),up=await storage.upload(path,file,{cacheControl:'31536000',contentType:type,upsert:false});if(up.error)throw up.error;var pub=storage.getPublicUrl(path),url=pub&&pub.data&&pub.data.publicUrl;if(!url||!cfIsProfileBanner(url)||['ember','inferno','dust','royal'].indexOf(url)>=0){try{await storage.remove([path]);}catch(ignoreInvalidUrlCleanup){}throw new Error('Supabase не вернул корректную публичную ссылку на баннер.');}u.profileBanner=url;try{await cfSaveProfileBanner(u);}catch(saveErr){u.profileBanner=old;try{await storage.remove([path]);}catch(ignoreFailedSaveCleanup){}throw saveErr;}var oldPath=cfBannerObjectPath(old,u.id);if(oldPath)storage.remove([u.id+'/'+oldPath]).catch(function(){});}else{var localId=window.crypto&&typeof window.crypto.randomUUID==='function'?window.crypto.randomUUID():'banner-'+Date.now()+'-'+Math.random().toString(36).slice(2),localValue=await cfStoreLocalBanner(file,localId,type);updateUser(function(a){a.profileBanner=localValue;});var prev=String(old||'').match(/^local-banner:([a-z0-9-]{8,80})$/i);if(prev&&prev[1]!==localId)cfDeleteLocalBanner(prev[1]);}if(curSec==='profile')renderSection('profile');if(cfBannerPreviewObjectUrl){URL.revokeObjectURL(cfBannerPreviewObjectUrl);cfBannerPreviewObjectUrl='';}cfBannerSetStatus('success','Баннер профиля обновлён.');toast('Баннер профиля обновлён','success');}catch(err){var readable=cfBannerErrorText(err);cfBannerSetStatus('error',readable);toast('Не удалось сохранить баннер: '+readable,'error');}finally{input.disabled=false;input.value='';var button=$('#cfProfileBannerPick');if(button)button.disabled=false;var action=$('[data-banner-pick-action]');if(action)action.textContent='Выбрать';}}
function tplProfile(u) {
  var lvl = levelInfo(u.elo), stats = matchStats(u), m = stats.matches;
  var hist = histOf(u).slice(0, 10).map(matchCard).join('') || emptyHistory();
  return '' +
    '<section class="card rise cf-profile-overview" style="--i:0;padding:14px">' + cfProfileHeroMarkup(u,false) + socialHTML(u,true) + '</section>' +
    '<section class="card rise" style="--i:1"><div class="cf-profile-progress-head"><span class="label" style="margin-bottom:2px">Прогресс уровня</span><span class="chip accent">FACEIT · <span>Ур. ' + lvl.level + '</span></span></div><div class="bar" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="' + Math.round(lvl.pct) + '"><i id="eloBar" style="width:0"></i></div><p class="small muted" style="margin:8px 0 14px">' + (lvl.next ? 'До уровня ' + (lvl.level + 1) + ': ' + (lvl.next - u.elo) + ' ELO' : 'Максимальный уровень') + '</p>' +
    '<div class="stats s4" style="margin-bottom:8px"><div class="tile"><b>' + stats.wins + '</b><span>Победы</span></div><div class="tile"><b>' + stats.losses + '</b><span>Поражения</span></div>' +
    '<div class="tile"><b>' + stats.winRate + '%</b><span>Винрейт</span></div><div class="tile"><b>' + m + '</b><span>Матчей</span></div></div>' +
    '<p class="demo-note" style="margin:8px 0 0">' + icon('info') + '<span>' + badgeHint(u) + '</span></p></section>' +
    '<section class="card rise" style="--i:2"><div class="card-head"><h2>Баннер профиля</h2><span class="chip">Галерея</span></div><p class="small muted">Выбери готовый фон или загрузи свой — он появится за аватаром в профиле.</p><div class="cf-cover-grid">' + ['ember','inferno','dust','royal'].map(function(k){return '<button type="button" class="cf-cover-pick '+cfBannerClass(k)+' '+(u.profileBanner===k?'selected':'')+'" data-banner="'+k+'" aria-label="Баннер '+k+'" title="'+k+'"></button>';}).join('') + '</div><div class="cf-banner-uploader" id="cfProfileBannerDropzone"><input class="cf-banner-native-input" id="cfProfileBannerUpload" type="file" accept="image/jpeg,image/png,image/webp,image/gif,video/mp4,video/webm,video/quicktime,video/x-m4v" aria-label="Выбрать изображение или видео для баннера"><button class="cf-banner-pick" type="button" id="cfProfileBannerPick" aria-controls="cfProfileBannerUpload"><span class="cf-banner-pick-icon" aria-hidden="true">↥</span><span class="cf-banner-pick-copy"><b>Загрузить фото или видео</b><small>Нажми, чтобы выбрать, или перетащи файл сюда</small></span><span class="cf-banner-pick-action" data-banner-pick-action>Выбрать</span></button><div class="cf-banner-preview" id="cfProfileBannerPreview"></div><p class="cf-banner-status" id="cfProfileBannerStatus" role="status" aria-live="polite">Фото и видео до 20 МБ · JPG, PNG, WebP, GIF, MP4, WebM, MOV или M4V. Загрузка начнётся сразу после выбора.</p></div><button class="btn primary" type="button" data-drawer-prime>👑 FACEIT PRIME · 300 ⭐</button></section>' +
    '<section class="card rise" style="--i:3"><div class="card-head"><h2>История матчей</h2></div>' + hist + '</section>' +
    '<section class="card rise" style="--i:3"><div class="card-head"><h2>Звуки</h2><span class="chip">Настройки</span></div><p class="small muted">Во время поиска играет звук и повторяются сигналы; всё останавливается при нахождении или отмене матча.</p><button class="btn" type="button" id="toggleSounds">' + (cfSoundOn ? '🔊 Звуки включены' : '🔇 Звуки выключены') + '</button></section>' +
    '<div class="btn-row rise" style="--i:3">' + (u.admin ? '<button class="btn primary" type="button" data-go="admin">' + icon('bell') + 'Панель администратора</button>' : '') + '<button class="btn" type="button" data-act="edit">' + icon('edit') + 'Редактировать профиль</button>' +
    '<button class="btn danger" type="button" data-act="logout">' + icon('logout') + 'Выйти</button></div>';
}
function tplPlay() {
  return '<section class="section-head rise" style="--i:0"><h1 class="h1">Играть</h1><p class="sub">Найди матч за пару нажатий</p></section>' +
    '<div id="lobbyBox" class="rise" style="--i:1"></div><div id="cfSharedMatchPlay"></div><div id="playBody" class="rise" style="--i:2" aria-live="polite"></div>' +
    '';
}
/* ---------- Реальный рейтинг (SQL 24: cf_leaderboard) ---------- */
var cfLb = null, cfLbAt = 0, cfLbErr = '';
function lbOnline() { return !!(cfSupabaseClient && cfOnlineAccount); }
function lbRows() {
  if (lbOnline()) return (cfLb || []).map(function (r) { return { nick: r.display_name || r.nickname, elo: r.elo, wins: r.wins, av: r.avatar || 'ember', avatarFrame:r.avatar_frame||'', rank: r.rank, role:r.role, verified:r.verified===true, founder:r.role==='founder', sponsorBadge:r.sponsor_badge===true, sponsorNicknameStyle:r.sponsor_nickname_style||'default' }; });
  return [];
}
function homeTopHTML() {
  if (lbOnline() && cfLb === null) return '<p class="small muted" style="padding:8px 0">' + (cfLbErr ? esc(cfLbErr) : 'Загружаем рейтинг…') + '</p>';
  var rows = lbRows().slice(0, 5);
  if (!rows.length) return '<p class="small muted" style="padding:8px 0">Пока нет игроков в рейтинге.</p>';
  return rows.map(function (p) {
    return '<div class="list-row"><span class="rankno">' + p.rank + '</span>' + avatar(p.av, p.nick, 34, p.avatarFrame) + '<div class="grow"><div class="t ellipsis">' + cfStyledNickHTML(p.nick,p) + vbadge(p) + '</div><div class="d">Ур. ' + levelInfo(p.elo).level + '</div></div><b class="lb-elo">' + lvlIcon(levelInfo(p.elo).level, 24) + fmt(p.elo) + '</b></div>';
  }).join('');
}
async function cfLoadLeaderboard(force) {
  if (!lbOnline()) return;
  if (!force && cfLb !== null && Date.now() - cfLbAt < 20000) return;
  try {
    var r = await cfSupabaseClient.rpc('cf_leaderboard', { p_limit: 100 });
    if (r.error) throw r.error;
    cfLb = Array.isArray(r.data) ? r.data : []; cfLbAt = Date.now(); cfLbErr = '';
    try { var rk = await cfSupabaseClient.rpc('cf_my_rank'); if (!rk.error) cfMyRank = rk.data; } catch (e2) {}
    paintMyRank();
  } catch (e) { cfLbErr = 'Рейтинг не настроен: запусти SQL 24 в Supabase.'; if (cfLb === null) cfLb = null; }
  var ht = $('#homeTop'); if (ht) ht.innerHTML = homeTopHTML();
  if ($('#lbList')) renderLeaderboard();
}
setInterval(function () { if (!document.hidden && (curSec === 'top' || curSec === 'home')) cfLoadLeaderboard(true); }, 30000);
function tplTop() {
  return '<section class="section-head rise" style="--i:0"><h1 class="h1">Топы</h1><p class="sub">Рейтинг игроков</p></section>' +
    '<div class="filters rise" style="--i:1"><div class="search">' + icon('search') + '<label class="sr-only" for="lbSearch">Поиск по нику</label><input class="input" id="lbSearch" type="search" placeholder="Поиск по нику" autocomplete="off"></div>' +
    '<div><label class="sr-only" for="lbFilter">Фильтр по рейтингу</label><select class="input" id="lbFilter"><option value="all">Любой рейтинг</option><option value="2000">ELO 2000+</option><option value="1800">ELO 1800–1999</option><option value="low">ELO до 1800</option></select></div></div>' +
    '<section class="card lbcard rise" style="--i:2"><div class="lb-head"><span>#</span><span></span><span>Игрок</span><span>Победы</span><span>Ур.</span><span>ELO</span></div><div id="lbList"></div></section>' +
    '<p class="demo-note rise" style="--i:3">' + icon('info') + '<span>Рейтинг считается по ELO из базы и меняется после подтверждённых матчей.</span></p>';
}
// Image with an automatic SVG fallback (see the capture-phase error handler below)
function newsImg(n, i, cls, eager) {
  var fb = n.link ? 'tg' : (i % 5);
  if (!n.img) return coverSVG(n.link ? 'tg' : i);
  if (n.mediaType === 'video' || /\.mp4(?:$|[?#])/i.test(n.img)) return '<video class="' + (cls || 'cover') + '" src="' + esc(n.img) + '" aria-label="' + esc(n.title) + '" controls muted playsinline preload="metadata"' + (eager ? '' : ' loading="lazy"') + '></video>';
  return '<img class="' + (cls || 'cover') + '" src="' + esc(n.img) + '" alt="' + esc(n.title) + '"' + (eager ? '' : ' loading="lazy"') + ' decoding="async" data-fb="' + fb + '">';
}
function cfAdminNewsFileInfo(file){
  if(!file)return null;
  var ext=String(file.name||'').split('.').pop().toLowerCase(),types={jpg:{mime:'image/jpeg',media:'image',max:10*1024*1024},jpeg:{mime:'image/jpeg',media:'image',max:10*1024*1024},png:{mime:'image/png',media:'image',max:10*1024*1024},webp:{mime:'image/webp',media:'image',max:10*1024*1024},gif:{mime:'image/gif',media:'image',max:10*1024*1024},mp4:{mime:'video/mp4',media:'video',max:50*1024*1024}},info=types[ext],reported=String(file.type||'').toLowerCase();
  if(reported==='image/jpg')reported='image/jpeg';
  if(!info||(reported&&reported!=='application/octet-stream'&&reported!==info.mime))return null;
  return {ext:ext==='jpeg'?'jpg':ext,mime:info.mime,media:info.media,max:info.max};
}
function cfPreviewAdminNewsMedia(input){
  var preview=$('#cfNewsMediaPreview'),file=input&&input.files&&input.files[0],info=file&&cfAdminNewsFileInfo(file);
  if(cfNewsPreviewUrl){URL.revokeObjectURL(cfNewsPreviewUrl);cfNewsPreviewUrl='';}
  if(!preview)return;
  preview.innerHTML='';
  if(!file)return;
  if(!info){input.value='';preview.textContent='Формат не поддерживается. Выбери JPG, PNG, WebP, GIF или MP4.';toast(preview.textContent,'error');return;}
  if(file.size>info.max){input.value='';preview.textContent=info.media==='video'?'MP4 должен быть не больше 50 МБ.':'Фото должно быть не больше 10 МБ.';toast(preview.textContent,'error');return;}
  cfNewsPreviewUrl=URL.createObjectURL(file);
  preview.innerHTML=(info.media==='video'?'<video class="cf-news-preview-media" controls muted playsinline preload="metadata"></video>':'<img class="cf-news-preview-media" alt="Предпросмотр фото новости">')+'<div class="cf-news-preview-meta"><span>'+esc(file.name)+' · '+cfDemoBytes(file.size)+'</span><button class="btn sm" type="button" id="cfNewsMediaRemove">Убрать файл</button></div>';
  var media=preview.querySelector(info.media==='video'?'video':'img');if(media)media.src=cfNewsPreviewUrl;
}
function cfAdminNewsError(err,stage){
  var msg=String(err&&(err.message||err.error_description||err.error)||'Неизвестная ошибка'),low=msg.toLowerCase(),status=Number(err&&err.statusCode||err&&err.status||0),code=String(err&&err.code||'');
  if(/bucket.*not found|bucket.*does not exist|bucket.*missing/.test(low))return 'В Supabase не найдено хранилище cf-news-media. Выполни SQL/46_owner_news_media.sql.';
  if(/нужно войти|jwt|session.*missing|auth session missing|not authenticated/.test(low)||((status===401||status===403)&&stage==='auth'))return 'Сеанс Supabase истёк. Выйди и снова войди в аккаунт владельца.';
  if(/row-level security|violates row-level|permission denied|not authorized|unauthorized/.test(low)||status===401||status===403)return stage==='upload'?'Supabase запретил загрузку файла. Проверь, что ты вошёл именно в аккаунт владельца и в профиле role = founder; затем проверь политики SQL/46_owner_news_media.sql. Подробность: '+msg:'Недостаточно прав владельца для публикации. Войди в аккаунт с ролью founder. Подробность: '+msg;
  if(/mime|content.?type|not allowed/.test(low))return 'Supabase не принимает этот формат. Разрешены JPG, PNG, WebP, GIF и MP4; проверь настройки bucket cf-news-media в SQL/46.';
  if(/too large|payload|entity too large|size limit|exceed.*limit/.test(low)||status===413)return 'Файл больше лимита хранилища. Фото — до 10 МБ, MP4 — до 50 МБ; в Supabase для bucket cf-news-media нужен лимит не меньше 50 МБ.';
  if(/could not find the function|function .* does not exist|schema cache|pgrst202/.test(low)||code==='PGRST202')return 'Supabase не видит функцию публикации. Примени или повторно выполни SQL/46_owner_news_media.sql, затем обнови страницу.';
  if(/публиковать новости может только владелец/.test(low))return 'В базе у аккаунта должна быть роль founder. Проверь public.profiles.role и SQL/46_owner_news_media.sql.';
  return (stage==='upload'?'Ошибка загрузки медиа: ':'Ошибка публикации новости: ')+msg;
}
async function cfAdminPublishNews(){
  var button=$('#cfAdminNewsPublish'),picker=$('#cfNewsMediaPick'),status=$('#cfAdminNewsStatus'),title=($('#newsTitle')&&$('#newsTitle').value||'').trim(),description=($('#newsDesc')&&$('#newsDesc').value||'').trim(),link=($('#newsLink')&&$('#newsLink').value||'').trim(),input=$('#cfNewsMedia'),file=input&&input.files&&input.files[0],info=file&&cfAdminNewsFileInfo(file);
  if(!cfOnlineAccount||cfOnlineAccount.role!=='founder'){toast('Публиковать новости может только владелец онлайн-аккаунта','error');return;}
  if(!cfSupabaseClient||!cfSupabaseClient.storage){toast('Облачное хранилище не подключено. Проверь настройки Supabase на сайте.','error');return;}
  if(!title||!description){toast('Заполни заголовок и описание новости','error');return;}
  if(link&&!/^https:\/\//i.test(link)){toast('Ссылка должна начинаться с https://','error');return;}
  if(file&&(!info||file.size>info.max)){toast(!info?'Выбери JPG, PNG, WebP, GIF или MP4.':info.media==='video'?'MP4 должен быть не больше 50 МБ.':'Фото должно быть не больше 10 МБ.','error');return;}
  var path='',mediaType='',uploaded=false,rpcReturnedError=false,stage='auth';
  if(button)button.disabled=true;if(picker)picker.disabled=true;if(status)status.textContent='Проверяем вход владельца…';
  try{
    var auth=await cfSupabaseClient.auth.getUser();
    if(auth.error)throw auth.error;
    if(!auth.data||!auth.data.user||auth.data.user.id!==cfOnlineAccount.id)throw new Error('Сеанс Supabase истёк или сменился. Выйди и снова войди в аккаунт владельца.');
    if(file){stage='upload';if(status)status.textContent='Загружаем медиа…';var id=window.crypto&&crypto.randomUUID?crypto.randomUUID():Date.now()+'-'+Math.random().toString(36).slice(2);path=cfOnlineAccount.id+'/'+id+'.'+info.ext;mediaType=info.media;var up=await cfSupabaseClient.storage.from('cf-news-media').upload(path,file,{contentType:info.mime,cacheControl:'3600',upsert:false});if(up.error)throw up.error;uploaded=true;}
    stage='publish';if(status)status.textContent='Публикуем новость…';
    var published=await cfSupabaseClient.rpc('cf_owner_publish_news',{p_title:title,p_description:description,p_link:link||null,p_media_path:path||null,p_media_type:mediaType||null});
    if(published.error){rpcReturnedError=true;throw published.error;}
    if(status)status.textContent='Опубликовано. Новость доступна всем посетителям.';
    $('#newsTitle').value='';$('#newsDesc').value='';$('#newsLink').value='';if(input)input.value='';
    if(cfNewsPreviewUrl){URL.revokeObjectURL(cfNewsPreviewUrl);cfNewsPreviewUrl='';}var preview=$('#cfNewsMediaPreview');if(preview)preview.innerHTML='';
    toast('Новость опубликована для всех','success');
    await cfLoadOnlineNews(true);
  }catch(e){
    var msg=cfAdminNewsError(e,stage);
    if(uploaded&&rpcReturnedError)try{await cfSupabaseClient.storage.from('cf-news-media').remove([path]);}catch(cleanupError){}
    if(status)status.textContent=msg;toast(msg,'error');
  }finally{if(button)button.disabled=false;if(picker)picker.disabled=false;}
}
document.addEventListener('error', function (e) {
  var t = e.target;
  if (!t || t.tagName !== 'IMG' || !t.dataset || t.dataset.fb === undefined || !t.parentNode) return;
  var tmp = document.createElement('div');
  tmp.innerHTML = coverSVG(t.dataset.fb === 'tg' ? 'tg' : Number(t.dataset.fb));
  var svg = tmp.firstChild;
  if (svg) { svg.setAttribute('class', t.className || 'cover'); t.parentNode.replaceChild(svg, t); }
}, true);
function bannerHTML(n) {
  var tg = !!n.link, i = NEWS.indexOf(n);
  return '<article class="banner' + (tg ? ' tgb' : '') + '" aria-label="' + esc(n.title) + '">' + newsImg(n, i, 'cover', true) +
    '<div class="banner-over"><span class="chip ' + (tg ? 'tgchip' : 'accent') + '">' + esc(n.tag) + ' · ' + esc(n.date) + '</span><h3>' + esc(n.title) + '</h3>' +
    '<button class="btn ' + (tg ? 'tg' : 'primary') + '" type="button" data-news="' + n.id + '">Подробнее</button></div></article>';
}
function tplNews() {
  if (!NEWS.length) {
    var message=cfOnlineNewsLoaded?'Пока нет опубликованных новостей.':cfOnlineNewsError?'Не удалось загрузить новости с сервера.':'Загружаем новости…';
    return '<section class="section-head rise"><h1 class="h1">Новости</h1><p class="sub">Публикации из общей онлайн-базы</p></section><div class="card empty" role="status">'+icon('info')+'<p>'+esc(message)+'</p>'+(cfOnlineNewsError?'<button class="btn primary" type="button" data-act="news-retry">Повторить</button>':'')+'<a href="'+esc(CHANNEL_URL)+'" target="_blank" rel="noopener noreferrer">Канал разработчика ↗</a></div>';
  }
  var feat = NEWS.filter(function (n) { return n.feature; }), rest = NEWS.filter(function (n) { return !n.feature; });
  var dots = feat.map(function (n, i) { return '<button type="button" aria-label="Новость ' + (i + 1) + '"></button>'; }).join('');
  var cards = rest.map(function (n, k) {
    return '<article class="news-card rise" style="--i:' + (k + 4) + '">' + newsImg(n, NEWS.indexOf(n), 'cover') +
      '<div class="news-body"><div class="news-meta"><span class="chip accent">' + esc(n.tag) + '</span><span>' + esc(n.date) + '</span></div>' +
      '<h3>' + esc(n.title) + '</h3><p>' + esc(n.desc) + '</p><button class="btn" type="button" data-news="' + n.id + '">Подробнее</button></div></article>';
  }).join('');
  return '<section class="section-head rise" style="--i:0"><h1 class="h1">Новости</h1><p class="sub">Баннеры листаются сами — или проведи пальцем</p></section>' +
    '<div class="carousel rise" style="--i:1" id="newsCar" tabindex="0" role="region" aria-label="Главные новости">' + feat.map(bannerHTML).join('') + '</div>' +
    '<div class="car-ctl rise" style="--i:2"><button class="icon-btn" type="button" id="newsPrev" aria-label="Назад">' + icon('chev-l') + '</button>' +
    '<button class="icon-btn" type="button" id="newsPause" aria-pressed="false" aria-label="Остановить автопрокрутку">' + icon('pause') + '</button>' +
    '<div class="dots" id="newsDots">' + dots + '</div><button class="icon-btn" type="button" id="newsNext" aria-label="Вперёд">' + icon('chev-r') + '</button></div>' +
    '<h2 class="section-title rise" style="--i:3">Все новости</h2><div class="news-grid">' + cards + '</div>' +
    '<p class="demo-note rise" style="--i:5">' + icon('info') + '<span>Актуальные новости — в канале разработчика.</span></p>';
}
var cfTournaments=[],cfTournamentsLoaded=false,cfTournamentsAttempted=false,cfTournamentsLoading=false,cfTournamentsError='',cfTournamentPoll=null;
var MAP_INFO={ 'Mirage':{name:'Мираж',cls:'Mirage'}, 'Dust II':{name:'Даст 2',cls:'Dust II'}, 'Vertigo':{name:'Вертиго',cls:'Vertigo'}, 'Inferno':{name:'Инферно',cls:'Inferno'} };
function escList(a){return (Array.isArray(a)?a:[]).map(function(x){return esc(x);}).join(', ')||'Пока нет игроков';}
var TV_MAPS={'Dust II':{n:'Dust II',a:'#d9a45b',b:'#6b4a1f'},'Vertigo':{n:'Vertigo',a:'#7fb4d6',b:'#26475f'},'Inferno':{n:'Inferno',a:'#e0643a',b:'#5a2312'},'Mirage':{n:'Mirage',a:'#e6c07a',b:'#3f5f73'}};
function cfTournamentImageUrl(value){try{var u=new URL(String(value||''));return u.protocol==='https:'&&!u.username&&!u.password&&u.href.length<=500?u.href:'';}catch(e){return '';}}
function tvMapBg(map,url){var safe=cfTournamentImageUrl(url);if(safe)return 'url('+JSON.stringify(safe)+')';var i=TV_MAPS[map]||TV_MAPS.Mirage;var svg="<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 600 360' preserveAspectRatio='xMidYMid slice'><defs><linearGradient id='g' x1='0' y1='0' x2='1' y2='1'><stop offset='0' stop-color='"+i.a+"'/><stop offset='1' stop-color='"+i.b+"'/></linearGradient></defs><rect width='600' height='360' fill='url(#g)'/><g fill='none' stroke='#000' stroke-opacity='.28' stroke-width='14'><path d='M40 300 L40 120 L210 120 L210 40 L400 40 L400 200 L560 200'/><path d='M120 340 L120 220 L320 220 L320 120'/><path d='M470 40 L560 40 L560 140'/></g><g fill='#000' fill-opacity='.2'><rect x='240' y='250' width='70' height='50'/><rect x='430' y='90' width='60' height='60'/><rect x='70' y='60' width='80' height='40'/></g></svg>";return 'url("data:image/svg+xml;utf8,'+encodeURIComponent(svg)+'")';}
var tvLogos={a:'',b:''};
function tvNicks(a){return (Array.isArray(a)?a:[]).map(function(n){return '<li>'+esc(n)+'</li>';}).join('')||'<li class="muted">—</li>';}
function tvLogo(t){return t.logo?'<img class="tv-logo" alt="" src="'+esc(t.logo)+'">':'<span class="tv-logo">'+esc((t.name||'?').charAt(0).toUpperCase())+'</span>';}
function tvResizeLogo(file,cb){if(!file||file.size>5*1024*1024){toast('Логотип должен быть не больше 5 МБ','error');return;}if(!/^image\/(?:jpeg|png|webp)$/i.test(file.type||'')){toast('Выбери PNG, JPG или WebP','error');return;}var r=new FileReader();r.onload=function(){var im=new Image();im.onload=function(){var c=document.createElement('canvas'),S=128;c.width=c.height=S;var x=c.getContext('2d'),k=Math.max(S/im.width,S/im.height),w=im.width*k,h=im.height*k;x.drawImage(im,(S-w)/2,(S-h)/2,w,h);cb(c.toDataURL('image/jpeg',.82));};im.onerror=function(){toast('Не удалось открыть картинку','error');};im.src=r.result;};r.onerror=function(){toast('Не удалось прочитать логотип','error');};r.readAsDataURL(file);}
async function cfLoadTournaments(force){if(!cfSupabaseClient||!cfOnlineAccount){cfTournaments=[];cfTournamentsError='Войди в онлайн-аккаунт Supabase, чтобы просматривать турниры.';return false;}if(cfTournamentsLoading)return false;if(cfTournamentsLoaded&&!force)return true;if(cfTournamentsAttempted&&!force)return false;cfTournamentsAttempted=true;cfTournamentsLoading=true;cfTournamentsError='';try{var r=await cfSupabaseClient.rpc('cf_tournament_state');if(r.error)throw r.error;if(!Array.isArray(r.data))throw new Error('Сервер вернул некорректный список турниров');cfTournaments=r.data;cfTournamentsLoaded=true;cfTournamentsError='';return true;}catch(e){cfTournamentsError=String(e&&e.message||'Не удалось загрузить турниры');return false;}finally{cfTournamentsLoading=false;if(curSec==='tournaments')renderSection('tournaments');}}
function cfTournamentError(err){var m=String(err&&err.message||'');if(/function .* does not exist|Could not find the function|schema cache/i.test(m))return 'Турниры ещё не подключены к базе. Выполни SQL/49_online_tournaments.sql после SQL/48.';if(/already registered/i.test(m))return 'Ты уже записан на этот турнир.';if(/full/i.test(m))return 'Свободных мест больше нет.';if(/registration is closed|cannot be started|only a live tournament/i.test(m))return 'Статус турнира изменился. Обнови список и попробуй ещё раз.';if(/administrator access required|permission denied|42501/i.test(m))return 'Недостаточно прав для этого действия.';return m||'Не удалось обновить турнир. Проверь соединение и повтори попытку.';}
function tplTourneyCard(t,u){var admin=isAdmin(u),players=Array.isArray(t.players)?t.players:[],A=t.teamA||{name:'Синяя команда',players:[]},B=t.teamB||{name:'Красная команда',players:[]},state={open:'Регистрация открыта',live:'Матч идёт',done:'Завершён'}[t.status]||'Статус неизвестен',joined=players.some(function(p){return p.user_id===cfOnlineAccount.id||p.id===cfOnlineAccount.id;}),room=t.room?'<p class="small"><b>Код комнаты:</b> <code>'+esc(t.room)+'</code></p>':'',registration='<section class="tv-registrations"><b>Заявки · '+players.length+' / '+Number(t.maxPlayers||0)+'</b>'+(players.length?'<ul>'+players.map(function(p){return '<li><span>'+esc(p.nick||'Игрок')+'</span><span>'+((p.team==='CT')?'Синяя сторона CT':'Красная сторона T')+'</span></li>';}).join('')+'</ul>':'<p class="small muted">Пока никто не записался.</p>')+(t.status==='open'?(joined?'<p class="small muted" role="status">Ты уже зарегистрирован.</p>':'<button class="btn primary" type="button" data-act="tour-join" data-id="'+esc(t.id)+'">Записаться на турнир</button>'):'')+'</section>',adm=admin?'<div class="btn-row">'+(t.status==='open'?'<button class="btn" type="button" data-act="tour-start" data-id="'+esc(t.id)+'">Начать / выдать код</button>':'')+(t.status==='live'?'<button class="btn" type="button" data-act="tour-bluewin" data-id="'+esc(t.id)+'">Победа слева</button><button class="btn" type="button" data-act="tour-redwin" data-id="'+esc(t.id)+'">Победа справа</button>':'')+'<button class="btn danger" type="button" data-act="tour-delete" data-id="'+esc(t.id)+'">Удалить</button></div>':'';return '<article class="tv-card"><div class="tv-bg" style="background-image:'+esc(tvMapBg(t.map,t.mapImg))+'"></div><div class="tv-top"><div><h3 class="ellipsis">'+esc(t.title)+'</h3><div class="tv-map">'+esc((TV_MAPS[t.map]||{}).n||t.map)+' · '+esc(t.date||'Время уточняется')+'</div></div><span class="chip">'+state+'</span></div><div class="tv-vs"><div class="tv-team l"><div class="tv-head">'+tvLogo(A)+'<span class="tv-name">'+esc(A.name)+'</span></div><ul class="tv-nicks">'+tvNicks(A.players)+'</ul></div><div class="tv-mid">VS</div><div class="tv-team r"><div class="tv-head">'+tvLogo(B)+'<span class="tv-name">'+esc(B.name)+'</span></div><ul class="tv-nicks">'+tvNicks(B.players)+'</ul></div></div><div class="tv-foot">'+room+(t.winner?'<p class="chip accent">Победитель: '+esc(t.winner)+'</p>':'')+registration+adm+'</div></article>';}
function tvForm(){return '<section class="tv-form"><h3>Создать турнир · Администратор</h3><input class="input" id="tourTitle" maxlength="70" placeholder="Название турнира"><label class="small muted" for="tourDate">Дата и время начала</label><input class="input" id="tourDate" type="datetime-local"><div class="tv-maps" id="tourMaps">'+Object.keys(TV_MAPS).map(function(k,i){return '<button type="button" data-tvmap="'+esc(k)+'" class="'+(i===0?'on':'')+'" style="background-image:'+esc(tvMapBg(k))+'">'+esc(TV_MAPS[k].n)+'</button>';}).join('')+'</div><input class="input" id="tourMapImg" maxlength="500" placeholder="Ссылка на фото карты (HTTPS, необязательно)"><div class="tv-two"><div><input class="input" id="tvNameA" maxlength="24" placeholder="Команда слева"><label class="tv-logo-pick"><input type="file" accept="image/jpeg,image/png,image/webp" id="tvLogoA"><span id="tvPrevA">＋ Логотип</span></label><textarea class="input" id="tvPlayersA" maxlength="300" placeholder="Ники команды слева, по одному в строке"></textarea></div><div><input class="input" id="tvNameB" maxlength="24" placeholder="Команда справа"><label class="tv-logo-pick"><input type="file" accept="image/jpeg,image/png,image/webp" id="tvLogoB"><span id="tvPrevB">＋ Логотип</span></label><textarea class="input" id="tvPlayersB" maxlength="300" placeholder="Ники команды справа, по одному в строке"></textarea></div></div><button class="btn primary" type="button" data-act="tour-create">Опубликовать турнир</button><p class="small muted">Турниры сохраняются в общей базе. Сервер проверяет права администратора, заявки и доступные места.</p></section>';}
function tplTournaments(u){var list=cfTournaments,admin=isAdmin(u),state=cfTournamentsLoading?'<div class="card empty"><p>Загружаем турниры с сервера…</p></div>':cfTournamentsError?'<div class="card empty"><p>'+esc(cfTournamentError(new Error(cfTournamentsError)))+'</p><button class="btn primary" type="button" data-act="tour-reload">Повторить</button></div>':list.length?list.map(function(t){return tplTourneyCard(t,u);}).join(''):'<div class="card empty"><p>Турниров пока нет. Создай первый — заявки будут видны всем игрокам.</p></div>';return '<section class="tourney-hero"><h2>Турниры CF FACEIT</h2><p>Соревнуйся за свою команду. Регистрация, составы и результаты синхронизируются через Supabase.</p><a class="btn primary" style="display:inline-flex;margin-top:12px" href="https://discord.gg/ETCXJC7G3" target="_blank" rel="noopener noreferrer">Открыть Discord-сообщество ↗</a></section>'+(admin?tvForm():'')+'<section class="section-head"><h2 class="h2">Предстоящие турниры</h2><p class="sub">Выбирай турнир и регистрируйся</p></section><div class="tourney-grid">'+state+'</div><section class="card" style="margin-top:14px"><h3>Порядок проведения</h3><p class="tourney-note">1. Зарегистрируйся на турнир. 2. Следи за составом, картой и кодом комнаты. 3. После матча капитаны сообщают итог, а администратор подтверждает победителя на сайте.</p><a href="https://discord.gg/ETCXJC7G3" target="_blank" rel="noopener noreferrer">Discord: discord.gg/ETCXJC7G3</a></section>';}
function bindTournaments(){tvLogos={a:'',b:''};if(!cfTournamentsLoaded&&!cfTournamentsLoading)cfLoadTournaments();var mm=$('#tourMaps');if(mm)mm.addEventListener('click',function(e){var b=e.target.closest('[data-tvmap]');if(!b)return;Array.prototype.forEach.call(document.querySelectorAll('#tourMaps button'),function(x){x.classList.toggle('on',x===b);});});['A','B'].forEach(function(k){var f=$('#tvLogo'+k);if(f)f.addEventListener('change',function(){var fl=f.files&&f.files[0];if(!fl)return;tvResizeLogo(fl,function(d){tvLogos[k.toLowerCase()]=d;var preview=$('#tvPrev'+k);if(preview)preview.innerHTML='<img alt="" src="'+esc(d)+'"> Логотип выбран';});});});if(!cfTournamentPoll)cfTournamentPoll=setInterval(function(){if(curSec==='tournaments'&&!document.hidden)cfLoadTournaments(true);},20000);}
async function tourneyAction(act,id){if(act==='tour-reload'){await cfLoadTournaments(true);return;}if(!cfSupabaseClient||!cfOnlineAccount){toast('Войди в онлайн-аккаунт Supabase','error');return;}var user=getUser(),row=cfTournaments.find(function(x){return String(x.id)===String(id);});try{if(act==='tour-create'){if(!isAdmin(user)){toast('Только администратор может создавать турниры','error');return;}var title=$('#tourTitle').value.trim(),date=$('#tourDate').value,mapButton=$('#tourMaps .on'),map=mapButton?mapButton.dataset.tvmap:'Mirage',teamA=$('#tvNameA').value.trim(),teamB=$('#tvNameB').value.trim(),playersA=$('#tvPlayersA').value.split(/[\n,]+/).map(function(x){return x.trim();}).filter(Boolean).slice(0,10),playersB=$('#tvPlayersB').value.split(/[\n,]+/).map(function(x){return x.trim();}).filter(Boolean).slice(0,10),mapImage=cfTournamentImageUrl($('#tourMapImg').value.trim());if(title.length<3||title.length>70){toast('Название турнира должно быть длиной от 3 до 70 символов','error');return;}if(!teamA||teamA.length>24||!teamB||teamB.length>24){toast('Названия команд — от 1 до 24 символов','error');return;}if(!playersA.length||!playersB.length){toast('Добавь от 1 до 10 игроков в состав каждой команды','error');return;}if($('#tourMapImg').value.trim()&&!mapImage){toast('Ссылка на карту должна быть корректным HTTPS-адресом','error');return;}var startsAt=null;if(date){var parsed=new Date(date);if(!Number.isFinite(parsed.getTime())){toast('Проверь дату турнира','error');return;}startsAt=parsed.toISOString();}var created=await cfSupabaseClient.rpc('cf_tournament_create',{p_title:title,p_starts_at:startsAt,p_map:map,p_map_image_url:mapImage,p_team_a_name:teamA,p_team_a_logo:tvLogos.a||'',p_team_a_players:playersA,p_team_b_name:teamB,p_team_b_logo:tvLogos.b||'',p_team_b_players:playersB});if(created.error)throw created.error;toast('Турнир опубликован для всех игроков','success');await cfLoadTournaments(true);return;}if(!row){toast('Турнир не найден. Обновляю список…','error');await cfLoadTournaments(true);return;}if(act==='tour-join'){var joined=await cfSupabaseClient.rpc('cf_tournament_join',{p_tournament_id:row.id});if(joined.error)throw joined.error;toast('Ты записан на турнир · '+(joined.data&&joined.data.side==='CT'?'синяя сторона CT':'красная сторона T'),'success');await cfLoadTournaments(true);return;}if(!isAdmin(user)){toast('Недостаточно прав','error');return;}var action={},room='';if(act==='tour-start'){room=window.prompt('Введи код комнаты, который создал в игре:');if(!room)return;action={p_tournament_id:row.id,p_action:'start',p_room_code:room.trim(),p_winner:null};}else if(act==='tour-bluewin'||act==='tour-redwin'){if(!window.confirm('Подтвердить результат по сообщению капитана в Discord?'))return;action={p_tournament_id:row.id,p_action:'winner',p_room_code:null,p_winner:act==='tour-bluewin'?'A':'B'};}else if(act==='tour-delete'){if(!window.confirm('Удалить турнир и его заявки? Это действие нельзя отменить.'))return;action={p_tournament_id:row.id,p_action:'delete',p_room_code:null,p_winner:null};}else return;var result=await cfSupabaseClient.rpc('cf_tournament_admin_action',action);if(result.error)throw result.error;toast(act==='tour-delete'?'Турнир удалён из общей базы':'Изменения турнира сохранены','success');await cfLoadTournaments(true);}catch(e){toast(cfTournamentError(e),'error');}}

/* ---------- Messenger (Supabase: msgr_* RPC) ---------- */
var CF_ROBOT='data:image/svg+xml;utf8,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 96 96%22%3E%3Cdefs%3E%3ClinearGradient id=%22g%22 x1=%220%22 y1=%220%22 x2=%220%22 y2=%221%22%3E%3Cstop offset=%220%22 stop-color=%22%23ff7a2e%22/%3E%3Cstop offset=%221%22 stop-color=%22%23d93f00%22/%3E%3C/linearGradient%3E%3C/defs%3E%3Crect width=%2296%22 height=%2296%22 fill=%22%23161616%22/%3E%3Ccircle cx=%2248%22 cy=%229%22 r=%225%22 fill=%22%23ff5500%22/%3E%3Crect x=%2246%22 y=%2212%22 width=%224%22 height=%2212%22 fill=%22%23ff5500%22/%3E%3Crect x=%2214%22 y=%2224%22 width=%2268%22 height=%2256%22 rx=%2218%22 fill=%22%23242424%22 stroke=%22url(%23g)%22 stroke-width=%224%22/%3E%3Crect x=%225%22 y=%2242%22 width=%229%22 height=%2220%22 rx=%224%22 fill=%22%23ff5500%22/%3E%3Crect x=%2282%22 y=%2242%22 width=%229%22 height=%2220%22 rx=%224%22 fill=%22%23ff5500%22/%3E%3Crect x=%2222%22 y=%2233%22 width=%2252%22 height=%2238%22 rx=%2212%22 fill=%22%230b0b0b%22/%3E%3Cg transform=%22translate(27 36) scale(1.65)%22 fill=%22%23ff5500%22%3E%3Cpath d=%22M24 2.7c0-.1-.1-.1-.2-.1-.1 0-.2.1-.2.2-2 3.1-4.1 6.2-6.1 9.4H.2c-.2 0-.3.3-.1.4 7.2 2.7 17.7 6.8 23.5 9.1.2.1.4-.1.4-.2V2.7z%22/%3E%3C/g%3E%3Crect x=%2234%22 y=%2273%22 width=%2228%22 height=%223%22 rx=%221.5%22 fill=%22%23ff5500%22 opacity=%22.0%22/%3E%3C/svg%3E';
var msgr={chats:[],q:'',open:null,msgs:[],last:0,busy:false,err:''};
function mgOnline(){return !!(cfSupabaseClient&&cfOnlineAccount);}
function mgAv(c,size){if(c.kind==='support')return '<span class="mg-av bot" style="width:'+size+'px;height:'+size+'px"><img alt="" src="'+esc(c.avatar||CF_ROBOT)+'"></span>';var inner=c.avatar&&/^data:image\//i.test(c.avatar)?'<img alt="" src="'+esc(c.avatar)+'">':esc((c.title||'?').charAt(0).toUpperCase());return '<span class="mg-av '+(c.kind==='group'?'group':'')+'" style="width:'+size+'px;height:'+size+'px">'+inner+'</span>';}
function mgTick(c){return c.official?'<svg class="mg-tick" viewBox="0 0 24 24" role="img" aria-label="Официальный канал"><use href="#i-verified"/></svg>':'';}
function mgTime(iso){try{var d=new Date(iso);return ('0'+d.getHours()).slice(-2)+':'+('0'+d.getMinutes()).slice(-2);}catch(e){return '';}}
function tplMessenger(){
  if(!mgOnline())return '<div class="card empty"><p>Мессенджер работает через онлайн-аккаунт. Войди с почтой, чтобы пользоваться чатами.</p></div>';
  if(msgr.open)return mgChatHTML();
  var mine=msgr.chats.filter(function(c){return c.joined;}),other=msgr.chats.filter(function(c){return !c.joined;});
  function row(c){var sub=c.last_body?esc(c.last_body):(c.kind==='support'?'Бот':c.kind==='channel'?'Канал':'Группа')+' · '+c.members+' подп.';return '<button class="mg-row" type="button" data-mg-open="'+esc(c.id)+'">'+mgAv(c,46)+'<div class="grow"><b><span>'+esc(c.title)+'</span>'+mgTick(c)+'</b><div class="mg-sub">'+sub+'</div></div>'+(c.last_at?'<span class="small muted">'+mgTime(c.last_at)+'</span>':'')+'</button>';}
  return '<section class="section-head"><h2 class="h2">Чаты</h2><p class="sub">Каналы и группы игроков</p></section><div class="mg-bar"><input class="input" id="mgSearch" placeholder="Найти канал или группу" value="'+esc(msgr.q)+'" maxlength="40"><button class="btn primary" type="button" data-mg="create" aria-label="Создать">＋</button></div>'
   +(msgr.err?'<div class="mg-note">'+esc(msgr.err)+'</div>':'')
   +(msgr.q?'<div class="mg-sec">Результаты поиска</div>'+(msgr.chats.length?msgr.chats.map(row).join(''):'<div class="mg-empty">Ничего не найдено</div>'):
     (mine.length?'<div class="mg-sec">Мои чаты</div>'+mine.map(row).join(''):'')+(other.length?'<div class="mg-sec">Официальное</div>'+other.map(row).join(''):'')+(!mine.length&&!other.length?'<div class="mg-empty">Пока пусто. Создай группу или найди канал через поиск.</div>':''));
}
function mgChatHTML(){
  var c=msgr.chats.find(function(x){return x.id===msgr.open;})||msgr.cur;if(!c)return '';
  var isCh=c.kind==='channel',isSupport=c.kind==='support',canWrite=isCh?c.is_owner:c.joined;
  var list=msgr.msgs.map(function(m){var u=m.user||{};return '<div class="mg-msg '+(m.mine?'mine ':'')+(m.bot?'bot ':'')+(isCh?'post':'')+'">'+(isCh||m.mine||m.bot?'':'<div class="who">'+esc(u.display_name||u.nickname||'Игрок')+'</div>')+'<div class="tx">'+esc(m.body)+'</div><div class="tm">'+mgTime(m.created_at)+'</div></div>';}).join('')||'<div class="mg-empty">'+(isCh?'В канале пока нет публикаций':'Сообщений пока нет. Напиши первым!')+'</div>';
  var supportActions=isSupport?'<div class="mg-support-actions"><button class="btn sm" type="button" data-mg-support-id>Сменить игровой ID</button><button class="btn sm" type="button" data-mg-support-recovery>Восстановить пароль</button></div><p class="small muted" style="margin:0 0 8px">Не отправляй в чат пароль или код из письма.</p>':'';
  var comp=canWrite?supportActions+'<form class="mg-comp" data-mg-send><input class="input" id="mgInput" maxlength="1000" placeholder="'+(isCh?'Опубликовать в канале':'Сообщение')+'" autocomplete="off"><button class="btn primary" type="submit">➤</button></form>'
    :(c.joined?'<div class="mg-note">Писать в канале может только владелец</div>':'<button class="btn primary" type="button" data-mg="join" style="width:100%">'+(isCh?'Подписаться':'Вступить в группу')+'</button>');
  var avatarEl=(c.is_owner&&c.official&&getUser()&&getUser().founder)?'<label class="mg-av edit '+(c.kind==='group'?'group':'')+'" style="width:44px;height:44px">'+(c.avatar?'<img alt="" src="'+esc(c.avatar)+'">':esc(c.title.charAt(0).toUpperCase()))+'<input type="file" accept="image/*" id="mgAvatarFile" hidden></label>':mgAv(c,44);
  return '<div class="mg-view"><div class="mg-head"><button class="mg-back" type="button" data-mg="back" aria-label="Назад">‹</button>'+avatarEl+'<div class="grow"><b><span>'+esc(c.title)+'</span>'+mgTick(c)+'</b><div class="mg-sub">'+(c.kind==='support'?'Бот · отвечает сразу':(isCh?'Канал':'Группа')+' · '+c.members+' подп.')+'</div></div>'+(c.joined&&!c.is_owner&&!c.official&&c.kind!=='support'?'<button class="btn sm" type="button" data-mg="leave">Выйти</button>':'')+'</div>'+(c.about?'<p class="small muted" style="margin:0 0 10px">'+esc(c.about)+'</p>':'')+'<div class="mg-msgs" id="mgMsgs">'+list+'</div>'+comp+'</div>';
}
async function mgLoadList(){if(!mgOnline())return;try{var r=await cfFriendRpc('msgr_list',{p_q:msgr.q});msgr.chats=r||[];msgr.err=msgr.q?'':(msgr.chats.some(function(c){return c.kind==='support';})?'':'Чат «Поддержка» не найден. Администратору нужно выполнить SQL/17, SQL/18 и SQL/23, затем обновить автоответы через SQL/37.');}catch(e){msgr.err='Мессенджер не настроен: в Supabase выполни SQL/17, SQL/18, SQL/23 и SQL/37 из архива.';}}
function mgRerender(keepFocus){if(curSec!=='messenger')return;var f=document.activeElement,id=f&&f.id,val=f&&f.value;var near=window.innerHeight+window.scrollY>=document.body.scrollHeight-80;view.innerHTML=tplMessenger();bindMessenger();if(keepFocus&&id){var n=document.getElementById(id);if(n){n.value=val;n.focus();}}if(msgr.open&&near)window.scrollTo(0,document.body.scrollHeight);}
async function mgOpen(id){var c=msgr.chats.find(function(x){return x.id===id;});if(!c)return;msgr.open=id;msgr.cur=c;msgr.msgs=[];msgr.last=0;mgRerender();await mgFetch(true);window.scrollTo(0,document.body.scrollHeight);}
async function mgFetch(full){if(!msgr.open||!mgOnline())return;try{var r=await cfFriendRpc('msgr_messages',{p_chat:msgr.open,p_after:full?0:msgr.last});if(!msgr.open)return;if(full)msgr.msgs=r;else if(r.length)msgr.msgs=msgr.msgs.concat(r);if(r.length)msgr.last=r[r.length-1].id;if(full||r.length)mgRerender(true);}catch(e){if(full){msgr.msgs=[];toast(String(e.message||'Не удалось загрузить чат'),'error');}}}
function mgResize(file,cb){tvResizeLogo(file,cb);}
function mgSupportIdModal(){
  if(!msgr.open||!mgOnline())return;
  var chatId=msgr.open;
  openModal('<h2 id="modalTitle">Сменить игровой ID</h2><p class="small muted">Введи новый уникальный ID из 6 или 7 цифр. Меняется только ID твоего вошедшего аккаунта; для входа используй никнейм и пароль.</p><form id="mgSupportIdForm"><div class="field"><label for="mgSupportNewId">Новый игровой ID</label><input class="input" id="mgSupportNewId" type="text" inputmode="numeric" pattern="[0-9]{6,7}" minlength="6" maxlength="7" autocomplete="off" required placeholder="6 или 7 цифр"></div><div class="btn-row"><button class="btn" type="button" data-close>Отмена</button><button class="btn primary" type="submit">Отправить запрос</button></div></form>',function(root){
    var input=$('#mgSupportNewId',root),form=$('#mgSupportIdForm',root),submit=form.querySelector('[type="submit"]');
    input.addEventListener('input',function(){this.value=this.value.replace(/\D/g,'').slice(0,7);});
    form.addEventListener('submit',async function(e){e.preventDefault();var newId=input.value.trim();if(!/^[0-9]{6,7}$/.test(newId)){toast('ID должен содержать ровно 6 или 7 цифр','error');return;}submit.disabled=true;try{await cfFriendRpc('msgr_send',{p_chat:chatId,p_body:'Сменить ID '+newId});closeModal();await mgFetch(false);try{var auth=await cfSupabaseClient.auth.getUser();if(auth.data&&auth.data.user)await cfLoadOnlineProfile(auth.data.user);}catch(ignoreProfileRefresh){}toast('Ответ поддержки добавлен в чат','success');}catch(err){toast(String(err.message||'Не удалось отправить запрос'),'error');submit.disabled=false;}});
  });
}
function mgContainsSecret(text){return /(?:(?:парол[ья]?|password)(?:\s+(?:мой|моя))?\s*[:=]\s*\S+|(?:мой|моя)\s+(?:парол[ья]?|password)\s+\S+|(?:парол[ья]?|password)\s+(?:мой|моя)\s+\S+|код(?:\s+из\s+письма|\s+восстановления|\s+сброса|\s+подтверждения)?\s*[:=]\s*\d{4,10}|код(?:\s+из\s+письма|\s+восстановления|\s+сброса|\s+подтверждения)?\s+\d{4,10})/i.test(text)||/^\s*\d{6}\s*$/.test(text);}
function bindMessenger(){
  var se=$('#mgSearch');if(se){var t;se.addEventListener('input',function(){clearTimeout(t);t=setTimeout(async function(){msgr.q=se.value.trim();await mgLoadList();mgRerender(true);},350);});}
  var af=$('#mgAvatarFile');if(af)af.addEventListener('change',function(){var fl=af.files&&af.files[0];if(!fl)return;mgResize(fl,async function(d){try{await cfFriendRpc('msgr_set_avatar',{p_chat:msgr.open,p_avatar:d});await mgLoadList();msgr.cur=msgr.chats.find(function(x){return x.id===msgr.open;})||msgr.cur;mgRerender();toast('Аватарка обновлена','success');}catch(e){toast(String(e.message||'Не удалось'),'error');}});});
}
document.addEventListener('click',async function(e){
  var supportId=e.target.closest&&e.target.closest('[data-mg-support-id]');if(supportId){mgSupportIdModal();return;}
  var supportRecovery=e.target.closest&&e.target.closest('[data-mg-support-recovery]');if(supportRecovery){openPasswordRecovery();return;}
  var o=e.target.closest&&e.target.closest('[data-mg-open]');if(o){mgOpen(o.dataset.mgOpen);return;}
  var b=e.target.closest&&e.target.closest('[data-mg]');if(!b)return;var a=b.dataset.mg;
  try{
    if(a==='back'){msgr.open=null;await mgLoadList();mgRerender();}
    else if(a==='join'){await cfFriendRpc('msgr_join',{p_chat:msgr.open});await mgLoadList();msgr.cur=msgr.chats.find(function(x){return x.id===msgr.open;})||msgr.cur;if(msgr.cur)msgr.cur.joined=true;await mgFetch(true);mgRerender();toast('Готово','success');}
    else if(a==='leave'){if(!confirm('Выйти из чата?'))return;await cfFriendRpc('msgr_leave',{p_chat:msgr.open});msgr.open=null;await mgLoadList();mgRerender();}
    else if(a==='create')mgCreateModal();
  }catch(err){toast(String(err.message||'Ошибка'),'error');}
});
document.addEventListener('submit',async function(e){
  var f=e.target;if(!f.matches||!f.matches('[data-mg-send]'))return;e.preventDefault();var inp=$('#mgInput'),txt=inp.value.trim(),activeChat=msgr.chats.find(function(c){return c.id===msgr.open;})||msgr.cur;if(!txt||msgr.busy)return;if(activeChat&&activeChat.kind==='support'&&mgContainsSecret(txt)){inp.value='';toast('Не отправляй пароль или код из письма в чат. Используй кнопку восстановления пароля.','error');return;}msgr.busy=true;
  try{await cfFriendRpc('msgr_send',{p_chat:msgr.open,p_body:txt});inp.value='';await mgFetch(false);window.scrollTo(0,document.body.scrollHeight);}catch(err){toast(String(err.message||'Не отправилось'),'error');}
  msgr.busy=false;
});
function mgCreateModal(){
  openModal('<h2>Создать</h2><div class="mg-kind" id="mgKind"><button type="button" class="on" data-k="group">👥 Группа</button><button type="button" data-k="channel">📢 Канал</button></div><div class="field" style="margin-top:12px"><input class="input" id="mgTitle" maxlength="40" placeholder="Название"></div><div class="field" style="margin-top:10px"><input class="input" id="mgAbout" maxlength="200" placeholder="Описание (необязательно)"></div><p class="small muted" style="margin-top:10px">В канале пишешь только ты, в группе — все участники.</p><button class="btn primary" id="mgDo" type="button" style="width:100%">Создать</button>',function(){
    var kind='group';$('#mgKind').addEventListener('click',function(e){var b=e.target.closest('[data-k]');if(!b)return;kind=b.dataset.k;Array.prototype.forEach.call(document.querySelectorAll('#mgKind button'),function(x){x.classList.toggle('on',x===b);});});
    $('#mgDo').addEventListener('click',async function(){try{var id=await cfFriendRpc('msgr_create',{p_kind:kind,p_title:$('#mgTitle').value,p_about:$('#mgAbout').value});closeModal();msgr.q='';await mgLoadList();msgr.open=null;mgRerender();mgOpen(id);}catch(err){toast(String(err.message||'Не удалось создать'),'error');}});
  });
}
setInterval(function(){if(curSec==='messenger'&&msgr.open&&!document.hidden)mgFetch(false);},3500);
function tplDemos(){return '<section class="section-head rise" style="--i:0"><h1 class="h1">Демки игроков</h1><p class="sub">Загрузи игровую демку .dem или видео .mp4 до 50 МБ. Загрузки доступны всем игрокам; у каждого игрока одна загрузка в час.</p></section><section class="card rise cf-demo-upload-card" style="--i:1"><form id="cfDemoUploadForm" class="cf-demo-upload-form"><label class="cf-demo-drop" for="cfDemoFile"><span class="cf-demo-drop-icon" aria-hidden="true">↑</span><span class="cf-demo-drop-title">Нажми, чтобы выбрать файл</span><span class="cf-demo-drop-hint">Формат .dem или .mp4 · до 50 МБ</span><input class="cf-demo-file-input" id="cfDemoFile" type="file" accept=".dem,.mp4,application/octet-stream,video/mp4" required></label><span class="cf-demo-selected" id="cfDemoSelected" aria-live="polite">Файл не выбран</span><div class="btn-row"><button class="btn cf-demo-submit" id="cfDemoUpload" type="submit">↑ Загрузить демку</button><span class="small muted cf-demo-cooldown" id="cfDemoCooldown">Загрузка доступна после входа в онлайн-аккаунт.</span></div><p class="small muted" id="cfDemoUploadStatus" aria-live="polite"></p></form></section><section class="section rise" style="--i:2"><div class="card-head"><h2>Общие демки</h2><button class="btn sm" id="cfDemoRefresh" type="button">Обновить</button></div><div class="cf-demo-list" id="cfDemoList"><p class="cf-demo-empty">Загружаю список…</p></div></section>';}
function cfShopFramePreview(u,style,size){var label=style==='iris'?'Чёрная рамка «Чёрный глаз»':style==='collab'?'Коллаборационная рамка CFGRADE X CF FACEIT':style==='arctic'?'Ледяная синяя рамка':style==='crimson'?'Багровая рамка':'Тёмно-фиолетовая рамка';return '<div class="cf-shop-frame cf-shop-frame--'+style+'" role="img" aria-label="Аватар '+esc(u.display||u.nick)+' в рамке: '+label+'">'+avatar(u.avatar,u.display,size)+(style==='collab'?'<span class="cf-shop-grade-mark" aria-hidden="true">GRADE</span>':'')+(style==='iris'?'<span class="cf-shop-eye" aria-hidden="true"></span>':'')+'</div>';}
function cfShopBuyLink(name,price){return '<a class="btn primary cf-shop-buy" href="https://t.me/prisedents" target="_blank" rel="noopener noreferrer" aria-label="Купить рамку '+esc(name)+' за '+price+' рублей через Telegram @prisedents">Купить</a>';}
function cfShopProductCard(product,u){return '<article class="cf-shop-card">'+cfShopFramePreview(u,product.style,72)+'<div class="cf-shop-card-copy"><h3>'+esc(product.name)+'</h3><p>'+esc(product.description)+'</p></div><div class="cf-shop-card-foot"><span class="cf-shop-price"><small>Цена</small><b>'+product.price+' ₽</b></span>'+cfShopBuyLink(product.name,product.price)+'</div></article>';}
function tplShop(u){var products=[{style:'violet',name:'Violet Flux',description:'Тёмно-фиолетовое переливание вокруг аватара.',price:199},{style:'arctic',name:'Arctic Pulse',description:'Холодный голубой свет с ледяным блеском.',price:199},{style:'crimson',name:'Crimson Edge',description:'Яркая багровая рамка с мягким свечением.',price:199},{style:'iris',name:'Black Iris',description:'Чёрный глаз моргает примерно раз в 10 секунд.',price:499}];return '<section class="cf-shop-head rise"><span class="chip accent">CF FACEIT STORE</span><h1 class="h1">Магазин рамок</h1><p class="sub">Выбери оформление и посмотри, как оно выглядит с твоим аватаром.</p></section><section class="cf-shop-feature rise" aria-labelledby="cfShopCollabTitle"><div class="cf-shop-feature-copy"><span class="cf-shop-kicker">LIMITED COLLAB</span><h2 class="cf-shop-feature-title" id="cfShopCollabTitle">Тёмная коллаборация</h2><p>Глубокий фиолетовый перелив, фирменный знак GRADE и оранжево-чёрный стиль CF FACEIT.</p><strong class="cf-shop-brandline"><span>CFGRADE</span> <i>×</i> <span>CF FACEIT</span></strong></div><div class="cf-shop-feature-visual">'+cfShopFramePreview(u,'collab',92)+'<span class="cf-shop-player">'+esc(u.display||u.nick)+'</span></div><div class="cf-shop-buy-row"><span class="cf-shop-price"><small>Цена</small><b>299 ₽</b></span>'+cfShopBuyLink('CFGRADE X CF FACEIT',299)+'</div></section><section class="cf-shop-collection rise"><div class="cf-shop-collection-head"><div><h2>Другие рамки</h2><p>Цветные эффекты для твоего аватара</p></div></div><div class="cf-shop-grid">'+products.map(function(product){return cfShopProductCard(product,u);}).join('')+'</div></section><p class="cf-shop-note">Кнопка «Купить» открывает Telegram <b>@prisedents</b> для согласования оплаты. Сайт не списывает деньги; после подтверждения оплаты администратор может выдать рамку игроку через панель администратора.</p>';}
var TEMPLATES = { search: tplSearch, home: tplHome, profile: tplProfile, play: tplPlay, top: tplTop, news: tplNews, admin: tplAdmin, tournaments: tplTournaments, messenger: tplMessenger, demos: tplDemos, shop: tplShop };

var cfDemosState={demos:[],pending:[],next_upload_at:null,busy:false};
function cfDemoBytes(value){var n=Number(value)||0;return n>=1024*1024?(n/(1024*1024)).toFixed(1)+' МБ':Math.max(1,Math.round(n/1024))+' КБ';}
function cfDemoDate(value){try{return value?new Date(value).toLocaleString('ru-RU',{dateStyle:'short',timeStyle:'short'}):'—';}catch(e){return '—';}}
function cfDemoFilename(value){return String(value||'').trim().slice(0,180);}
function cfRenderDemos(){var list=document.getElementById('cfDemoList'),cool=document.getElementById('cfDemoCooldown'),upload=document.getElementById('cfDemoUpload'),status=document.getElementById('cfDemoUploadStatus');if(!list)return;var online=!!(cfSupabaseClient&&cfOnlineAccount&&cfOnlineAccount.id),next=cfDemosState.next_upload_at?Date.parse(cfDemosState.next_upload_at):0,pending=cfDemosState.pending||[],canRetry=pending.some(function(p){return Date.now()-Date.parse(p.created_at)<15*60*1000;}),blocked=next>Date.now()&&!canRetry;if(cool)cool.textContent=!online?'Войди в онлайн-аккаунт, чтобы загружать и скачивать демки.':blocked?'Следующая загрузка: '+cfDemoDate(cfDemosState.next_upload_at):canRetry?'Загрузка не завершена. Выбери тот же файл и повтори попытку в течение 15 минут.':'Одна загрузка в час на игрока.';if(upload)upload.disabled=!online||blocked||cfDemosState.busy;var demos=cfDemosState.demos||[];if(!demos.length){list.innerHTML='<p class="cf-demo-empty">Ещё нет опубликованных демо. Будь первым!</p>';return;}list.innerHTML=demos.map(function(d){var p=d.player||{},name=p.display_name||p.nickname||'Игрок',mine=d.is_mine===true;return '<article class="cf-demo-row">'+avatar(p.avatar||'ember',name,42,p.avatar_frame)+'<div class="grow"><div class="small muted">Автор: <b>'+cfStyledNickHTML(d.author||name,p)+vbadge(p)+'</b></div><div class="small muted cf-demo-file">'+esc(d.file_name||'demo.dem')+'</div><div class="small muted">'+cfDemoBytes(d.file_size_bytes)+' · '+cfDemoDate(d.uploaded_at)+'</div></div><div class="cf-demo-actions"><button class="btn sm" type="button" data-demo-download="'+esc(d.id)+'">Скачать</button>'+(mine?'<button class="btn danger sm" type="button" data-demo-delete="'+esc(d.id)+'">Удалить</button>':'')+'</div></article>';}).join('');}
async function cfRefreshDemos(){if(!cfSupabaseClient||!cfOnlineAccount||!cfOnlineAccount.id){cfDemosState={demos:[],pending:[],next_upload_at:null,busy:false};cfRenderDemos();return;}var r=await cfSupabaseClient.rpc('cf_demo_state');if(r.error)throw r.error;cfDemosState=Object.assign({demos:[],pending:[],next_upload_at:null,busy:false},r.data||{});cfRenderDemos();}
function bindDemos(){
  var form=document.getElementById('cfDemoUploadForm'),list=document.getElementById('cfDemoList'),refresh=document.getElementById('cfDemoRefresh'),input=document.getElementById('cfDemoFile'),selected=document.getElementById('cfDemoSelected');
  if(!form||!list)return;
  cfRefreshDemos().catch(function(e){list.innerHTML='<p class="cf-demo-empty">Не удалось загрузить список демо. Выполни SQL/43_game_demos.sql.</p>';var st=document.getElementById('cfDemoUploadStatus');if(st)st.textContent=e.message||'';});
  if(refresh)refresh.addEventListener('click',function(){cfRefreshDemos().catch(function(e){toast(e.message||'Не удалось обновить список демо','error');});});
  if(input)input.addEventListener('change',function(){var file=input.files&&input.files[0];if(selected){selected.textContent=file?file.name+' · '+cfDemoBytes(file.size):'Файл не выбран';selected.classList.toggle('has-file',!!file);}});
  form.addEventListener('submit',async function(e){
    e.preventDefault();if(cfDemosState.busy)return;
    var file=input&&input.files&&input.files[0],submit=document.getElementById('cfDemoUpload'),st=document.getElementById('cfDemoUploadStatus');
    if(!cfSupabaseClient||!cfOnlineAccount||!cfOnlineAccount.id){toast('Войди в онлайн-аккаунт, чтобы загружать демки','error');return;}
    if(!file){toast('Выбери файл демки','error');return;}
    var ext=String(file.name).toLowerCase().match(/\.(dem|mp4)$/),contentType=ext&&ext[1]==='mp4'?'video/mp4':'application/octet-stream';
    if(!ext||file.size<1||file.size>50*1024*1024){toast('Нужен файл .dem или .mp4 размером до 50 МБ','error');return;}
    cfDemosState.busy=true;if(submit)submit.disabled=true;if(st)st.textContent='Загрузка демки…';
    try{
      var claim=await cfSupabaseClient.rpc('cf_demo_reserve_upload',{p_file_name:cfDemoFilename(file.name),p_file_size:file.size,p_content_type:contentType});if(claim.error)throw claim.error;
      var reservation=claim.data||{};
      if(reservation.status!=='ready'){var up=await cfSupabaseClient.storage.from('cf-player-demos').upload(reservation.object_path,file,{contentType:contentType,cacheControl:'3600',upsert:false});if(up.error)throw up.error;var finish=await cfSupabaseClient.rpc('cf_demo_finish_upload',{p_demo_id:reservation.id});if(finish.error)throw finish.error;}
      if(st)st.textContent='Демка опубликована';toast('Демка опубликована','success');input.value='';if(selected){selected.textContent='Файл не выбран';selected.classList.remove('has-file');}await cfRefreshDemos();
    }catch(err){if(st)st.textContent=err&&err.message?err.message:'Не удалось загрузить демку';toast(err&&err.message||'Не удалось загрузить демку','error');try{await cfRefreshDemos();}catch(ignoreRefresh){}}
    finally{cfDemosState.busy=false;cfRenderDemos();}
  });
  list.addEventListener('click',async function(e){var down=e.target.closest&&e.target.closest('[data-demo-download]'),del=e.target.closest&&e.target.closest('[data-demo-delete]');if(!down&&!del)return;if(!cfSupabaseClient||!cfOnlineAccount){toast('Войди в онлайн-аккаунт','error');return;}var id=(down||del).dataset.demoDownload||(down||del).dataset.demoDelete,demo=(cfDemosState.demos||[]).find(function(x){return x.id===id;});if(!demo)return;try{if(down){var signed=await cfSupabaseClient.storage.from('cf-player-demos').createSignedUrl(demo.object_path,120,{download:demo.file_name||true});if(signed.error)throw signed.error;window.location.assign(signed.data.signedUrl);return;}if(!demo.is_mine){toast('Удалить демку может только её автор','error');return;}if(!window.confirm('Удалить демку?'))return;var removed=await cfSupabaseClient.storage.from('cf-player-demos').remove([demo.object_path]);if(removed.error&&!/not found|404/i.test(removed.error.message||''))throw removed.error;var deleted=await cfSupabaseClient.rpc('cf_demo_delete',{p_demo_id:id});if(deleted.error)throw deleted.error;toast('Демка удалена','success');await cfRefreshDemos();}catch(err){toast(err&&err.message||'Не удалось выполнить действие','error');}});
}
/* ---------- Binders (run after render) ---------- */
function showElo(u, id) {
  var el = document.getElementById(id);
  if (!el) return;
  var from = lastEloShown === null ? Math.round(u.elo * 0.85) : lastEloShown;
  el.textContent = fmt(from);
  animateNumber(el, from, u.elo, 900);
  lastEloShown = u.elo;
}
function cfAnimateEloBar(u) {
  var bar = $('#eloBar');
  if (!bar) return;
  var pct = levelInfo(u.elo).pct, progress = bar.closest('[role="progressbar"]');
  if (progress) progress.setAttribute('aria-valuenow', String(Math.round(pct)));
  requestAnimationFrame(function () { requestAnimationFrame(function () { bar.style.width = pct + '%'; }); });
}
var BINDERS = {
  search: function () { bindSearch(); },
  tournaments: function () { bindTournaments(); },
  messenger: function () { bindMessenger(); },
  demos: function () { bindDemos(); },
  home: function (u) {
    cfLoadLeaderboard(true); paintMyRank(); cfRefreshMe(false);
    showElo(u, 'eloNum'); cfAnimateEloBar(u);
  },
  profile: function (u) { showElo(u, 'pfElo'); cfAnimateEloBar(u); cfLoadLeaderboard(true); paintMyRank(); cfRefreshMe(false); },
  news: function () { bindNews(); },
  admin: function () { bindAdmin(); },
  play: function () { renderPlay(); renderLobby(); lobbyPoll(); },
  top: function () {
    cfLoadLeaderboard(true); renderLeaderboard();
    $('#lbSearch').addEventListener('input', renderLeaderboard);
    $('#lbFilter').addEventListener('change', renderLeaderboard);
    renderLeaderboard();
  }
};

/* ---------- Leaderboard ---------- */
function ratingMatch(elo, f) {
  if (f === '2000') return elo >= 2000;
  if (f === '1800') return elo >= 1800 && elo < 2000;
  if (f === 'low') return elo < 1800;
  return true;
}
function lbRow(p) {
  var lvl = levelInfo(p.elo).level;
  return '<div class="lb-row' + (p.rank <= 3 ? ' top top' + p.rank : '') + '"><span class="lb-rank">' + p.rank + '</span>' + avatar(p.av, p.nick, 36, p.avatarFrame) +
    '<div class="lb-name"><b class="ellipsis">' + cfStyledNickHTML(p.nick,p) + vbadge(p) + '</b><span class="lb-sub">Побед ' + p.wins + ' · Ур. ' + lvl + '</span></div>' +
    '<span class="lb-wins">' + p.wins + '</span><span class="lb-lvl">' + lvlIcon(lvl, 26) + '</span><b class="lb-elo">' + lvlIcon(lvl, 26).replace('class="lvl-ic"', 'class="lvl-ic lvl-m"') + fmt(p.elo) + '</b></div>';
}
function renderLeaderboard() {
  var s = $('#lbSearch'), f = $('#lbFilter'), box = $('#lbList');
  if (!s || !f || !box) return;
  var q = s.value.trim().toLowerCase();
  if (lbOnline() && cfLb === null) { box.innerHTML = '<div class="empty"><p>' + esc(cfLbErr || 'Загружаем рейтинг…') + '</p></div>'; return; }
  var rows = lbRows()
    .filter(function (p) { return (!q || p.nick.toLowerCase().indexOf(q) >= 0) && ratingMatch(p.elo, f.value); });
  box.innerHTML = rows.length ? rows.map(lbRow).join('') :
    '<div class="empty">' + icon('search') + '<p>Игроки не найдены. Попробуй другой ник или сбрось фильтры.</p><button class="btn" type="button" data-act="lbreset">Сбросить фильтры</button></div>';
}

/* ---------- News ---------- */
var coverUid = 0;
function coverSVG(variant) {
  var id = 'cg' + (++coverUid), v = variant === 'tg' ? 'tg' : variant % 5, s = '';
  if (v === 'tg') s = '<circle cx="160" cy="90" r="78" fill="#229ED9" opacity=".14"/><circle cx="160" cy="90" r="58" fill="#229ED9" opacity=".3"/><circle cx="160" cy="90" r="40" fill="#229ED9"/><path d="M137 92 L188 72 L177 111 L163 100 L155 109 L153 98 Z" fill="#fff"/><path d="M40 150 L120 20 H145 L65 150Z" fill="#FF5500" opacity=".35"/><path d="M225 160 L275 70 H298 L248 160Z" fill="#FF5500" opacity=".55"/>';
  else if (v === 0) s = '<path d="M60 170 L130 20 H165 L95 170Z" fill="#FF5500" opacity=".9"/><path d="M140 170 L205 45 H235 L170 170Z" fill="#FF5500" opacity=".45"/>';
  else if (v === 1) s = '<circle cx="225" cy="90" r="74" fill="none" stroke="#FF5500" stroke-width="2" opacity=".35"/><circle cx="225" cy="90" r="50" fill="none" stroke="#FF5500" stroke-width="3" opacity=".6"/><circle cx="225" cy="90" r="24" fill="#FF5500" opacity=".9"/>';
  else if (v === 2) s = '<g stroke="#FF5500" stroke-width="1" opacity=".25"><path d="M0 45H320M0 90H320M0 135H320M80 0V180M160 0V180M240 0V180"/></g><rect x="165" y="50" width="75" height="75" fill="#FF5500" opacity=".85"/><rect x="85" y="95" width="45" height="45" fill="none" stroke="#FF5500" stroke-width="3"/>';
  else if (v === 3) s = '<path d="M30 180 L110 0 H140 L60 180Z" fill="#FF5500" opacity=".25"/><path d="M110 180 L190 0 H220 L140 180Z" fill="#FF5500" opacity=".55"/><path d="M190 180 L270 0 H300 L220 180Z" fill="#FF5500" opacity=".9"/>';
  else s = '<polygon points="160,25 222,60 222,120 160,155 98,120 98,60" fill="rgba(255,85,0,.14)" stroke="#FF5500" stroke-width="3"/><polygon points="160,60 192,78 192,112 160,130 128,112 128,78" fill="#FF5500" opacity=".85"/>';
  return '<svg class="cover" viewBox="0 0 320 180" preserveAspectRatio="xMidYMid slice" role="img" aria-label="Иллюстрация к новости"><defs><linearGradient id="' + id + '" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#2d1708"/><stop offset="1" stop-color="#141414"/></linearGradient></defs><rect width="320" height="180" fill="url(#' + id + ')"/>' + s + '</svg>';
}
function openNews(id) {
  var n = NEWS.filter(function (x) { return x.id === id; })[0];
  if (!n) return;
  if (n.link) { window.open(n.link, '_blank', 'noopener,noreferrer'); return; } // developer channel
  var idx = NEWS.indexOf(n);
  var media = n.gallery && n.gallery.length
    ? '<div class="gallery">' + n.gallery.map(function (src, k) {
        return '<img class="cover" src="' + esc(src) + '" alt="' + esc(n.title) + ' — фото ' + (k + 1) + '" loading="lazy" decoding="async" data-fb="' + ((idx + k) % 5) + '">';
      }).join('') + '</div>'
    : newsImg(n, idx, 'cover');
  openModal('<article class="article">' + media +
    '<div class="meta"><span class="chip accent">' + esc(n.tag) + '</span><span class="small muted">' + esc(n.date) + '</span></div>' +
    '<h2 id="modalTitle">' + esc(n.title) + '</h2>' + n.body.map(function (p) { return '<p>' + esc(p) + '</p>'; }).join('') +
    '<p class="fiction">Актуальные новости — в канале разработчика.</p></article>' +
    '<div class="btn-row"><button class="btn" type="button" data-close>Закрыть</button>' +
    '<a class="btn tg" href="' + esc(CHANNEL_URL) + '" target="_blank" rel="noopener noreferrer">Канал разработчика</a></div>', null, true);
}
var newsTimer = null;
function bindNews() {
  if(!cfOnlineNewsLoaded&&!cfOnlineNewsAttempted){cfOnlineNewsAttempted=true;cfLoadOnlineNews(false);}
  clearInterval(newsTimer); newsTimer = null;
  var car = $('#newsCar');
  if (!car) return;
  var dots = $$('#newsDots button'), slides = $$('.banner', car), raf = null;
  var hover = false, userPaused = false, holdUntil = 0, pauseBtn = $('#newsPause');
  function step() { return slides.length > 1 ? slides[1].offsetLeft - slides[0].offsetLeft : car.clientWidth; }
  function cur() {
    if (car.scrollLeft + car.clientWidth >= car.scrollWidth - 4) return slides.length - 1;
    return Math.max(0, Math.min(slides.length - 1, Math.round(car.scrollLeft / (step() || 1))));
  }
  function sync() {
    var i = cur();
    dots.forEach(function (d, k) { d.classList.toggle('on', k === i); d.setAttribute('aria-current', k === i ? 'true' : 'false'); });
  }
  function go(i) {
    i = Math.max(0, Math.min(slides.length - 1, i));
    car.scrollTo({ left: i * step(), behavior: reduceMotion ? 'auto' : 'smooth' });
  }
  function hold(ms) { holdUntil = Date.now() + ms; }
  function tick() {
    if (!car.isConnected) { clearInterval(newsTimer); newsTimer = null; return; }
    if (userPaused || hover || modalOpen || document.hidden || Date.now() < holdUntil) return;
    var i = cur();
    go(i >= slides.length - 1 ? 0 : i + 1);
  }
  car.addEventListener('scroll', function () {
    if (raf) return;
    raf = requestAnimationFrame(function () { raf = null; sync(); });
  }, { passive: true });
  car.addEventListener('mouseenter', function () { hover = true; });
  car.addEventListener('mouseleave', function () { hover = false; });
  car.addEventListener('focusin', function () { hold(8000); });
  car.addEventListener('touchstart', function () { hold(7000); }, { passive: true });
  car.addEventListener('pointerdown', function () { hold(7000); });
  dots.forEach(function (d, k) { d.addEventListener('click', function () { hold(7000); go(k); }); });
  $('#newsPrev').addEventListener('click', function () { hold(7000); go(cur() - 1); });
  $('#newsNext').addEventListener('click', function () { hold(7000); go(cur() + 1); });
  car.addEventListener('keydown', function (e) {
    if (e.key === 'ArrowRight') { e.preventDefault(); hold(7000); go(cur() + 1); }
    else if (e.key === 'ArrowLeft') { e.preventDefault(); hold(7000); go(cur() - 1); }
  });
  if (reduceMotion) { pauseBtn.hidden = true; }
  else {
    pauseBtn.addEventListener('click', function () {
      userPaused = !userPaused;
      pauseBtn.setAttribute('aria-pressed', userPaused ? 'true' : 'false');
      pauseBtn.setAttribute('aria-label', userPaused ? 'Включить автопрокрутку' : 'Остановить автопрокрутку');
      pauseBtn.innerHTML = icon(userPaused ? 'play' : 'pause');
    });
    newsTimer = setInterval(tick, 4500); // banners rotate by themselves
  }
  sync();
}
function openTgLogin() {
  openModal('<h2 id="modalTitle">Вход через Telegram</h2>' +
    '<p>Если ты регистрировался через бота, войди так:</p>' +
    '<ol class="steps"><li><span>Закрой это окно и во вкладке «Войти» введи <b>ник</b>, <b>игровой ID</b> и <b>пароль</b> из бота.</span></li>' +
    '<li><span>Забыл пароль или данные? Открой бота → «Мой аккаунт» → «Сменить пароль».</span></li></ol>' +
    '<div class="btn-row"><button class="btn" type="button" data-close>Закрыть</button>' +
    '<a class="btn tg" href="https://t.me/CFFACET_Robot" target="_blank" rel="noopener noreferrer">Открыть бота</a></div>');
}
document.addEventListener('click', function (e) {
  var b = e.target.closest && e.target.closest('#tgRegBtn,#tgLoginBtn'); if (!b) return;
  if (b.id === 'tgRegBtn') openTgRegister(); else openTgLogin();
});
// Registration goes through the Telegram bot: show the rules first, then open the bot
function openTgRegister() {
  openModal('<h2 id="modalTitle">Регистрация через Telegram</h2>' +
    '<p>Сначала прочитай, что нужно сделать:</p>' +
    '<ol class="steps">' +
    '<li><span>Нажми «Открыть бота» — в Telegram откроется @CFFACET_Robot.</span></li>' +
    '<li><span>В боте нажми Start и следуй его инструкциям, чтобы создать аккаунт.</span></li>' +
    '<li><span>Вернись в CF FACEIT, открой вкладку «Войти» и введи ник, игровой ID и пароль, которые указал в боте.</span></li></ol>' +
    '<div class="btn-row"><button class="btn" type="button" data-close>Отмена</button>' +
    '<a class="btn tg" id="tgOpen" href="https://t.me/CFFACET_Robot" target="_blank" rel="noopener noreferrer"><svg class="logo-svg" viewBox="0 0 24 24" aria-hidden="true" style="width:20px;height:20px;color:#fff"><use href="#i-telegram"/></svg>Открыть бота</a></div>',
    function (root) {
      $('#tgOpen', root).addEventListener('click', function () {
        setTimeout(function () { closeModal(); setTab('login'); toast('После регистрации в боте войди с логином и паролем'); }, 250);
      });
    });
}

/* =========================================================
   Play / matchmaking simulation
   ========================================================= */
var play = { status: 'idle', mode: 'ranked', elapsed: 0, left: 15, map: '', result: null, tick: null, searchT: null, foundTick: null, matchT: null, matchId: null, poll: null, sig: '' };
var FOUND_SECONDS = 15;
function modeById(id) { return MODES.filter(function (m) { return m.id === id; })[0] || MODES[0]; }
function clearPlayTimers() {
  clearInterval(play.tick); clearTimeout(play.searchT); clearInterval(play.foundTick); clearTimeout(play.matchT); clearInterval(play.poll);
  play.tick = play.searchT = play.foundTick = play.matchT = play.poll = null;
}
function resetPlay() { clearPlayTimers(); play.status = 'idle'; play.result = null; play.elapsed = 0; play.matchId = null; cfSyncSearchSound(); }

var cfPlayCooldownUntil = 0, cfPlayCooldownOwner = '';
function cfPlayCooldownRemainingSeconds() {
  var until = 0, now = Date.now();
  if (cfSupabaseClient && cfOnlineAccount) {
    until = Number(cfPlayCooldownUntil) || 0;
    if (typeof cfLobbyMatch !== 'undefined' && cfLobbyMatch) now += Number(cfLobbyMatch.serverOffset) || 0;
  }
  return Math.max(0, Math.ceil((until - now) / 1000));
}
function cfApplyServerPlayCooldown(state) {
  var owner = cfOnlineAccount && cfOnlineAccount.id || '';
  if (owner !== cfPlayCooldownOwner) { cfPlayCooldownOwner = owner; cfPlayCooldownUntil = 0; }
  var parsed = Date.parse(state && state.play_cooldown_until || '');
  var next = Number.isFinite(parsed) ? parsed : 0;
  if (next !== cfPlayCooldownUntil) {
    cfPlayCooldownUntil = next;
    cfUpdatePlayCooldownUI();
    if (curSec === 'play') renderPlay();
  }
}
function cfPlayCooldownMessage() {
  var seconds = cfPlayCooldownRemainingSeconds();
  return seconds ? 'Новый матч будет доступен через ' + fmtTime(seconds) + '.' : '';
}
function cfUpdatePlayCooldownUI() {
  if (typeof document === 'undefined') return;
  var seconds = cfPlayCooldownRemainingSeconds();
  document.querySelectorAll('[data-play-cooldown]').forEach(function (button) {
    button.disabled = seconds > 0;
    var label = button.querySelector('[data-cooldown-label]');
    if (label) label.textContent = seconds > 0 ? 'Играть · ' + fmtTime(seconds) : (button.dataset.cooldownLabel || 'Играть');
  });
  document.querySelectorAll('.cf-play-cooldown-note').forEach(function (note) {
    note.hidden = seconds <= 0;
    note.textContent = seconds > 0 ? cfPlayCooldownMessage() : '';
  });
}
setInterval(cfUpdatePlayCooldownUI, 1000);
function renderPlay() {
  var body=$('#playBody'),u=getUser();
  if(!body||!u)return;
  var onlineState=(typeof cfLobbyMatch!=='undefined'&&cfLobbyMatch)?cfLobbyMatch.data:null;
  var onlineQueue=!!(cfSupabaseClient&&cfOnlineAccount&&onlineState&&onlineState.queue);
  var onlineMt=onlineState&&onlineState.match;
  var onlineActive=!!(cfSupabaseClient&&cfOnlineAccount&&onlineMt&&['found','choose_host','host_selected','pending_admin','taken','room','joined','live','result_pending'].indexOf(onlineMt.status)>=0);
  var html='';
  if(onlineQueue){
    var q=onlineState.queue,qMap=q.map_name||'';
    html='<div class="card pl-search"><div class="card-head"><h2>Поиск матча '+(q.mode==='duo'?'2×2':'5×5')+'</h2><span class="chip accent">В очереди</span></div><div class="pl-radar"><div class="radar"><svg class="logo-svg" viewBox="0 0 48 48" aria-hidden="true"><use href="#i-logo"/></svg></div><div class="timer" id="cfQueueClock">00:00</div><p class="small muted">Время в очереди</p></div><div class="pl-grid"><div class="pl-cell"><small>Режим</small><b>'+(q.mode==='duo'?'Быстрый 2×2':'Соревновательный 5×5')+'</b></div><div class="pl-cell"><small>Карта</small><b>'+esc(qMap||'Любая')+'</b></div><div class="pl-cell"><small>Твоя группа</small><b>'+Number(q.party_count||1)+' игрок.</b></div><div class="pl-cell"><small>Групп в очереди</small><b>'+Number(q.waiting_parties||1)+'</b></div></div><p class="small muted">Друзья из одного лобби всегда попадут в одну команду.</p><div class="btn-row"><button class="btn danger" type="button" data-lobby-match="cancel">Отменить поиск</button></div></div>';
    body.innerHTML=html;return;
  }
  if(onlineActive){
    var aImg=MAP_IMAGES[onlineMt.map_name]||MAP_IMAGES.Mirage;
    html='<div class="card pl-active"><div class="cf-map-card"><img src="'+esc(aImg)+'" alt="Карта '+esc(onlineMt.map_name)+'"><div class="cf-map-overlay"><span>'+esc(CF_MATCH_STATUSES[onlineMt.status]||onlineMt.status)+'</span><strong>'+esc(onlineMt.map_name)+'</strong><small>'+(onlineMt.mode==='duo'?'2×2':'5×5')+' · '+Number(onlineMt.total_count||0)+' игроков · до 16 раундов</small></div></div><p class="small muted" style="margin-top:10px">'+(onlineMt.status==='live'?(cfMatchEnded(onlineMt)?'Время матча вышло: отправь итоги в карточке матча выше.':'Матч идёт. Таймер и код комнаты в карточке выше.'):onlineMt.status==='result_pending'?'Результат ожидает проверки администратора.':'Следи за ходом матча в карточке выше.')+'</p></div>';
    body.innerHTML=html;return;
  }
  var m=modeById(play.mode),li=levelInfo(u.elo),wr=winRate(u),wait={ranked:'≈ 2–6 мин',duo:'≈ 1–3 мин'};
  var inLobby=lobby.state&&lobby.state.lobby?(lobby.state.lobby.members||[]).length:1;
  var rng=fmt(Math.max(0,u.elo-m.spread))+'–'+fmt(u.elo+m.spread);
  html='<div class="pm-card"><div class="pm-head"><h2>Найти матч</h2><p>CounterFlame · рейтинговые матчи</p></div><div class="pm-seg" role="radiogroup" aria-label="Режим игры">'+MODES.map(function(x){var on=x.id===play.mode;return '<button type="button" class="pm-seg-btn'+(on?' on':'')+'" role="radio" aria-checked="'+on+'" data-mode="'+x.id+'"><b>'+(x.id==='duo'?'2×2':'5×5')+'</b><span>'+(x.id==='duo'?'Быстрый':'Рейтинговый')+'</span></button>';}).join('')+'</div><div class="pm-info"><span><i>⏱</i>'+wait[play.mode]+'</span><span><i>◎</i>ELO '+rng+'</span><span><i>↻</i>до 16 раундов</span></div><p class="pm-lbl">Карта</p><div class="pl-maps" role="radiogroup" aria-label="Карта">'+['any'].concat(MAPS).map(function(k){var on=(play.pickMap||'any')===k;return '<button type="button" class="pl-map'+(on?' on':'')+'" role="radio" aria-checked="'+on+'" data-pmap="'+k+'"'+(k!=='any'&&MAP_IMAGES[k]?' style="background-image:linear-gradient(180deg,rgba(0,0,0,.15),rgba(0,0,0,.7)),url('+esc(MAP_IMAGES[k])+')"':'')+'>'+(k==='any'?'Любая':esc(k))+'</button>';}).join('')+'</div><button class="pm-go" type="button" data-act="start" data-play-cooldown data-cooldown-label="Найти матч"><svg class="ic" aria-hidden="true"><use href="#i-play"/></svg><span data-cooldown-label>Найти матч</span></button><p class="small muted cf-play-cooldown-note" hidden></p></div>';
  body.innerHTML=html;cfUpdatePlayCooldownUI();
}

document.addEventListener('click', function (e) { var b = e.target.closest && e.target.closest('[data-pmap]'); if (b && play.status === 'idle') { play.pickMap = b.dataset.pmap; renderPlay(); } });
function selectMode(id) { if (play.status !== 'idle') return; play.mode = id; renderPlay(); }
function startSearch() {
  if (!cfSupabaseClient || !cfOnlineAccount) { toast('Войди в онлайн-аккаунт, чтобы искать матч', 'error'); return; }
  cfStartLobbyMatch();
}
function cancelSearch() {
  if (!cfSupabaseClient || !cfOnlineAccount) { toast('Онлайн-подбор недоступен без подключения к Supabase', 'error'); return; }
  cfLobbyMatchAction('cancel');
}
function playAgain() { startSearch(); }

/* =========================================================
   Profile editing & logout
   ========================================================= */
function openEditProfile() {
  var u = getUser();
  if (!u) return;
  var selected = u.avatar, sponsorBackgroundFile=null, sponsorRetrySnapshot=null;
  var sponsorControls=u.sponsorBadge?'<section class="cf-sponsor-customize"><h3>Настройки спонсора</h3><p class="small muted">Выбери цвет ника и фон всего сайта из галереи. Эти параметры видны только в твоём аккаунте.</p><label class="label" for="cfSponsorNicknameStyle">Цвет ника</label><select class="input cf-sponsor-style-select" id="cfSponsorNicknameStyle"><option value="default">Стандартный</option><option value="blue">Синий</option><option value="gradient">Градиент</option><option value="rainbow">Радужный</option></select><label class="label" for="cfSponsorBackgroundFile" style="margin-top:10px">Фон сайта из галереи</label><input class="input" id="cfSponsorBackgroundFile" type="file" accept="image/jpeg,image/png,image/webp,image/gif"><div class="cf-sponsor-preview" data-sponsor-preview aria-label="Предпросмотр фона сайта"></div><label class="small"><input type="checkbox" id="cfSponsorBackgroundClear"> Убрать мой фон сайта</label><p class="small muted">JPG, PNG, WebP или GIF, до 8 МБ.</p></section>':'';
  openModal(
    '<h2 id="modalTitle">Редактировать профиль</h2>' +
    '<form id="editForm" novalidate><div class="field"><label for="editNick">Отображаемый никнейм</label>' +
    '<input class="input" id="editNick" maxlength="30" autocomplete="off" autocapitalize="off" spellcheck="false" value="' + esc(u.display) + '" aria-describedby="editNickErr"><p class="err" id="editNickErr" role="alert"></p></div>' +
    '<div class="field"><span class="label" id="avLbl">Аватар</span><div class="av-grid" role="radiogroup" aria-labelledby="avLbl">' +
    AVATARS.map(function (a) {
      return '<button type="button" class="av-opt" role="radio" data-av="' + a.id + '" aria-checked="' + (a.id === selected) + '" aria-label="' + esc(a.name) + '">' + avatar(a.id, u.display, 40) + '</button>';
    }).join('') + '</div><label class="label" for="customAvatar" style="margin-top:12px">Или загрузить аватар из галереи</label><input class="input" id="customAvatar" type="file" accept="image/png,image/jpeg,image/webp,image/gif"><p class="small muted">Изображение до 1 МБ. Профиль синхронизируется с Supabase.</p></div>' +
    '<div class="field"><label for="socialTelegram">Telegram-ссылка</label><input class="input" id="socialTelegram" placeholder="https://t.me/username" value="' + esc((u.socials||{}).telegram||'') + '"></div>' +
    '<div class="field"><label for="socialYoutube">YouTube-ссылка</label><input class="input" id="socialYoutube" placeholder="https://youtube.com/@name" value="' + esc((u.socials||{}).youtube||'') + '"></div>' +
    '<div class="field"><label for="socialTiktok">TikTok-ссылка</label><input class="input" id="socialTiktok" placeholder="https://tiktok.com/@name" value="' + esc((u.socials||{}).tiktok||'') + '"></div>' + sponsorControls +
    '<div class="btn-row"><button class="btn" type="button" data-close>Отмена</button><button class="btn primary" type="submit">Сохранить</button></div></form>',
    function (root) {
      var inp = $('#editNick', root), saving = false, customAvatar = '';
      var sponsorStyle=$('#cfSponsorNicknameStyle',root),sponsorPreview=$('[data-sponsor-preview]',root),sponsorBgInput=$('#cfSponsorBackgroundFile',root),sponsorClear=$('#cfSponsorBackgroundClear',root);
      if(sponsorStyle)sponsorStyle.value=['default','blue','gradient','rainbow'].indexOf(u.sponsorNicknameStyle)>=0?u.sponsorNicknameStyle:'default';
      if(sponsorPreview&&cfIsSponsorBackground(u.sponsorBackground,u.id))sponsorPreview.style.backgroundImage='url("'+u.sponsorBackground.replace(/["\\\\]/g,'')+'")';
      if(sponsorBgInput)sponsorBgInput.addEventListener('change',function(){var file=sponsorBgInput.files&&sponsorBgInput.files[0];if(!file)return;if(!cfSponsorImageExtension(file.type)){sponsorBgInput.value='';toast('Выбери JPG, PNG, WebP или GIF','error');return;}if(file.size>8*1024*1024){sponsorBgInput.value='';toast('Фон должен быть не больше 8 МБ','error');return;}sponsorBackgroundFile=file;if(sponsorClear)sponsorClear.checked=false;if(sponsorPreview){var reader=new FileReader();reader.onload=function(){sponsorPreview.style.backgroundImage='url("'+String(reader.result).replace(/["\\\\]/g,'')+'")';};reader.readAsDataURL(file);}});
      if(sponsorClear)sponsorClear.addEventListener('change',function(){if(this.checked){sponsorBackgroundFile=null;if(sponsorBgInput)sponsorBgInput.value='';if(sponsorPreview)sponsorPreview.style.backgroundImage='none';}});
      var avatarFile = $('#customAvatar', root);
      avatarFile.addEventListener('change', function(){ var f=avatarFile.files&&avatarFile.files[0]; if(!f)return; if(f.size>1024*1024){avatarFile.value='';toast('Аватар должен быть меньше 1 МБ','error');return;} var rd=new FileReader(); rd.onload=function(){ var img=new Image(); img.onload=function(){ try{var c=document.createElement('canvas');c.width=128;c.height=128;var ctx=c.getContext('2d');var side=Math.min(img.width,img.height),sx=(img.width-side)/2,sy=(img.height-side)/2;ctx.drawImage(img,sx,sy,side,side,0,0,128,128);customAvatar=c.toDataURL('image/webp',0.78);if(customAvatar.length>75000)customAvatar=c.toDataURL('image/jpeg',0.72); }catch(e){customAvatar=String(rd.result||'');} selected=customAvatar;toast('Аватар сжат и выбран — нажми «Сохранить»'); };img.onerror=function(){customAvatar=String(rd.result||'');selected=customAvatar;toast('Аватар выбран — нажми «Сохранить»');};img.src=String(rd.result||'');};rd.readAsDataURL(f); });
      inp.addEventListener('input', function () { setFieldError(inp, ''); });
      $$('.av-opt', root).forEach(function (b) {
        b.addEventListener('click', function () {
          selected = b.dataset.av;
          $$('.av-opt', root).forEach(function (x) { x.setAttribute('aria-checked', x === b ? 'true' : 'false'); });
        });
      });
      $('#editForm', root).addEventListener('submit', async function (e) {
        e.preventDefault();
        if (saving) return;
        var v = inp.value.trim();
        var msg = validateNick(v);
        setFieldError(inp, msg);
        if (msg) { inp.focus(); return; }
        var socials = {telegram:$('#socialTelegram',root).value.trim(),youtube:$('#socialYoutube',root).value.trim(),tiktok:$('#socialTiktok',root).value.trim()};
        var badSocial = Object.keys(socials).some(function(k){var x=socials[k];return x && (!/^https:\/\//i.test(x) || !/^https:\/\/(t\.me|telegram\.me|www\.youtube\.com|youtube\.com|youtu\.be|www\.tiktok\.com|tiktok\.com)\//i.test(x));});
        if(badSocial){toast('Проверь ссылки: нужны HTTPS-ссылки на Telegram, YouTube или TikTok','error');return;}
        saving=true;var submit=$('#editForm',root).querySelector('[type="submit"]');if(submit)submit.disabled=true;
        var retrySponsorOnly=!!(sponsorRetrySnapshot&&sponsorRetrySnapshot.display===v&&sponsorRetrySnapshot.avatar===selected&&sponsorRetrySnapshot.telegram===socials.telegram&&sponsorRetrySnapshot.youtube===socials.youtube&&sponsorRetrySnapshot.tiktok===socials.tiktok),previous={display:u.display,avatar:u.avatar,socials:u.socials,sponsorBackground:u.sponsorBackground,sponsorNicknameStyle:u.sponsorNicknameStyle},uploaded=null,profileSaved=false,sponsorSaved=false;
        try{
          var nextBackground=u.sponsorBackground||'',nextStyle=sponsorStyle?sponsorStyle.value:'default';
          if(u.sponsorBadge){if(sponsorBackgroundFile){uploaded=await cfUploadSponsorBackground(sponsorBackgroundFile);nextBackground=uploaded.url;}else if(sponsorClear&&sponsorClear.checked)nextBackground='';if(['default','blue','gradient','rainbow'].indexOf(nextStyle)<0)throw new Error('Выбери доступный стиль ника.');}
          u.display=v;u.avatar=selected;u.socials=socials;
          if(cfOnlineAccount&&u===cfOnlineAccount){if(!cfSupabaseClient)throw new Error('Онлайн-соединение недоступно. Попробуй ещё раз.');if(!retrySponsorOnly)await cfSaveOnlineProfile(u);profileSaved=true;if(u.sponsorBadge){await cfSaveSponsorProfile(nextBackground,nextStyle);sponsorSaved=true;sponsorRetrySnapshot=null;}}
          else throw new Error('Войди в онлайн-аккаунт Supabase, чтобы сохранить профиль.');
          if(previous.sponsorBackground&&previous.sponsorBackground!==nextBackground&&cfSupabaseClient&&cfOnlineAccount&&u===cfOnlineAccount){var oldSponsorPath=cfSponsorBackgroundObjectPath(previous.sponsorBackground,u.id);if(oldSponsorPath){try{var oldCleanup=await cfSupabaseClient.storage.from('cf-sponsor-backgrounds').remove([u.id+'/'+oldSponsorPath]);if(oldCleanup&&oldCleanup.error)toast('Профиль сохранён, но старый фон не удалось удалить.','error');}catch(ignoreOldCleanup){toast('Профиль сохранён, но старый фон не удалось удалить.','error');}}}
          updateHeader();cfApplySponsorWallpaper();closeModal();if(curSec==='profile')renderSection('profile');toast('Профиль сохранён','success');
        }catch(err){if(profileSaved){updateHeader();if(u.sponsorBadge)sponsorRetrySnapshot={display:v,avatar:selected,telegram:socials.telegram,youtube:socials.youtube,tiktok:socials.tiktok};}else{u.display=previous.display;u.avatar=previous.avatar;u.socials=previous.socials;u.sponsorBackground=previous.sponsorBackground;u.sponsorNicknameStyle=previous.sponsorNicknameStyle;}if(uploaded&&!sponsorSaved&&cfSupabaseClient&&cfOnlineAccount){try{var failedUploadCleanup=await cfSupabaseClient.storage.from('cf-sponsor-backgrounds').remove([uploaded.path]);if(failedUploadCleanup&&failedUploadCleanup.error)toast('Не удалось удалить неиспользуемый загруженный фон.','error');}catch(ignoreFailedUploadCleanup){toast('Не удалось удалить неиспользуемый загруженный фон.','error');}}saving=false;if(submit)submit.disabled=false;toast(profileSaved&&u.sponsorBadge?'Основной профиль сохранён, но настройки спонсора не сохранены. Повтори попытку: будет отправлено только изменение спонсора.':err&&err.message||'Не удалось сохранить профиль','error');return;}
      });
    });
}
function confirmLogout() {
  openModal('<h2 id="modalTitle">Выйти из аккаунта?</h2><p>Текущая сессия будет завершена. Онлайн-аккаунт останется в Supabase.</p>' +
    '<div class="btn-row"><button class="btn" type="button" data-close>Отмена</button><button class="btn danger" type="button" id="confirmLogout">Выйти</button></div>',
    function (root) { $('#confirmLogout', root).addEventListener('click', doLogout); });
}
// Screen 5: logout
function doLogout() {
  if(cfSupabaseClient) cfSupabaseClient.auth.signOut().catch(function(){});
  cfOnlineAccount=null;
  closeModal();
  resetPlay();
  stopWatchers();
  clearTimeout(navTimer);
  store.remove(KEYS.session);
  sessionNick = null; lastEloShown = null; curSec = null; cfApplySponsorWallpaper();
  hideEl(appEl, 300, function () {
    view.innerHTML = '';
    view.classList.remove('dim');
    showAuth('login');
  });
}

/* =========================================================
   Admin tools, match requests and site messages.
   LOCAL SIMULATION: data lives in this browser's localStorage, so admins and
   players only see each other inside the same browser. A real service would
   need a server (or the Telegram bot) to deliver messages across devices.
   ========================================================= */
function isAdmin(u) { return !!(u && (u.admin || u.founder || u.role === 'admin' || u.role === 'founder')); }
function sameNick(a, b) { return String(a || '').toLowerCase() === String(b || '').toLowerCase(); }
function adminName(nick) { return String(nick || ''); }
function fmtClock(ts) { try { return new Date(ts).toLocaleTimeString('ru-RU',{hour:'2-digit',minute:'2-digit'}); } catch (e) { return ''; } }
var watchTimer=null;
function refreshBadge() {
  var me=getUser(),bell=$('#bellBtn'),n=$('#bellN');
  if(!bell||!n)return;
  if(!isAdmin(me)){bell.hidden=true;return;}
  bell.hidden=false;
  var pending=(cfOnlineAdminMatches||[]).filter(function(m){return m.status==='result_pending';}).length;
  n.textContent=pending>9?'9+':String(pending);
  n.hidden=!pending;
}

function watchTick() { if(sessionNick)refreshBadge(); }
function startWatchers() { stopWatchers(); refreshBadge(); watchTimer=setInterval(watchTick,5000); }
function stopWatchers() { clearInterval(watchTimer); watchTimer=null; }

function tplAdmin() {
  return '<section class="section-head rise" style="--i:0"><h1 class="h1">Панель администратора</h1><p class="sub">Роли, общие матчи лобби и модерация</p></section>' +
    '<div class="adm" id="adm" data-tab="matches"><div class="adm-tabs" role="tablist"><button type="button" class="on" data-adm-tab="matches">Матчи<em id="admTabMatchesCount"></em></button><button type="button" data-adm-tab="roles">Роли</button><button type="button" data-adm-tab="moderation">Баны / PRIME</button><button type="button" data-adm-tab="avatar-frames">Рамки</button><button type="button" data-adm-tab="news">Новости</button></div><div class="adm-stats" id="admStats"></div>' +
    '<div data-pane="roles"><div class="cf-staff-panel"><h3>Управление ролями</h3><p class="small muted">Укажи ник, e-mail, игровой ID или UUID Supabase. Для выдачи значка спонсора сначала установи SQL/42_sponsor_badge_and_profile_customization.sql после SQL/41.</p><label for="staffNick">Ник / почта / игровой ID / UUID</label><input class="staff-target" id="staffNick" placeholder="Sonse, player@mail.com или 123456" autocomplete="off"><label for="staffRole">Роль</label><select id="staffRole"><option value="player">Игрок</option><option value="tester">Тестер</option><option value="admin">Администратор</option><option value="cooperation">Сотрудничество (синяя галочка)</option></select><label for="staffVerified">Золотая галочка подтверждения</label><select id="staffVerified"><option value="">Не менять</option><option value="true">Выдать</option><option value="false">Снять</option></select><label for="staffSponsor">Значок спонсора</label><select id="staffSponsor"><option value="">Не менять</option><option value="true">Выдать</option><option value="false">Снять</option></select><button class="btn primary" id="staffApply" type="button">Применить права на сервере</button><p class="small muted" id="staffResult"></p></div></div>' +
    '<div data-pane="matches"><div id="cfOnlineAdminMatches"><p class="small muted">Загружаем онлайн-матчи…</p></div></div>' +
    '<div data-pane="moderation"><div class="cf-admin-tools"><h3>👑 Выдать FACEIT PRIME</h3><p class="small muted">Только владелец. Выдаёт 30 дней, без списания Stars.</p><input class="input" id="cfPrimeTarget" placeholder="Ник / игровой ID / UUID" maxlength=120><button class="btn primary" id="cfAdminPrimeGrant" type="button">Выдать PRIME на 30 дней</button><p class="small muted" id="cfAdminPrimeOut"></p></div><div class="cf-admin-tools"><h3>🛡️ Бан или запрет играть</h3><p class="small muted">Доступно администраторам и владельцу. Введи игрока и выбери тип ограничения. 0 дней — постоянный бан; для снятия запрета выбери его тип и нажми «Снять».</p><label for="cfModerationTarget">Имя игрока / игровой ID / UUID</label><input class="input" id="cfModerationTarget" placeholder="Ник игрока" maxlength="120" autocomplete="off"><label for="cfModerationType">Тип ограничения</label><select class="input" id="cfModerationType"><option value="ban">Бан аккаунта</option><option value="play">Запрет запускать матчи</option></select><label for="cfModerationDays">Срок в днях</label><input class="input" id="cfModerationDays" type="number" min="0" max="3650" value="1" inputmode="numeric"><label for="cfModerationReason">Причина</label><input class="input" id="cfModerationReason" placeholder="Укажи причину" maxlength="300"><div class="btn-row"><button class="btn danger" id="cfModerationApply" type="button">Применить</button><button class="btn" id="cfModerationRemove" type="button">Снять выбранное ограничение</button></div><p class="small muted" id="cfModerationOut" aria-live="polite"></p><p class="small muted">Администраторы и владелец защищены от банов и запрета игры. Проверка прав выполняется сервером; требуется SQL/41_player_host_and_moderation.sql.</p></div></div>' +
    '<div data-pane="avatar-frames"><div class="cf-admin-tools"><h3>✦ Выдать рамку игроку</h3><p class="small muted">Администратор или владелец может выдать рамку по нику, игровому ID или UUID. Выданная рамка появится у игрока и будет видна всем в профиле и общих списках.</p><label for="cfAdminFrameTarget">Ник / игровой ID / UUID игрока</label><input class="input" id="cfAdminFrameTarget" placeholder="Ник игрока" maxlength="120" autocomplete="off"><label for="cfAdminFrameChoice">Рамка</label><select class="input" id="cfAdminFrameChoice"><option value="collab">CFGRADE X CF FACEIT · 299 ₽</option><option value="violet">Violet Flux · 199 ₽</option><option value="arctic">Arctic Pulse · 199 ₽</option><option value="crimson">Crimson Edge · 199 ₽</option><option value="iris">Black Iris · 499 ₽</option></select><div class="btn-row"><button class="btn primary" id="cfAdminFrameGrant" type="button">Выдать рамку</button><button class="btn danger" id="cfAdminFrameRemove" type="button">Снять выбранную рамку</button></div><p class="small muted" id="cfAdminFrameOut" aria-live="polite"></p><p class="small muted">Требуется SQL/47_shop_avatar_frames.sql после SQL/42. Выдача хранится в Supabase; игрок не может назначить себе невыданную рамку.</p></div></div>' +
    '<div data-pane="news"><div id="adminBody" class="rise" style="--i:1"></div></div></div>' +
    '<p class="demo-note">' + icon('info') + '<span>Роли, матчи, чат, турниры и опубликованные новости синхронизируются через Supabase; локальные демонстрационные записи не считаются игровыми данными.</span></p>';
}
async function cfAdminApplyModeration(remove) {
  var me=getUser(), target=($('#cfModerationTarget')&&$('#cfModerationTarget').value||'').trim(), kind=$('#cfModerationType')&&$('#cfModerationType').value, dayValue=$('#cfModerationDays')&&$('#cfModerationDays').value, days=dayValue===''?NaN:Number(dayValue), reason=($('#cfModerationReason')&&$('#cfModerationReason').value||'').trim(), out=$('#cfModerationOut'), button=remove?$('#cfModerationRemove'):$('#cfModerationApply');
  if(!me||!isAdmin(me)){toast('Недостаточно прав','error');return;}
  if(!cfSupabaseClient||!cfOnlineAccount||!cfOnlineAccount.id){toast('Войди в онлайн-аккаунт Supabase','error');return;}
  if(!target){toast('Введи имя игрока','error');return;}
  if(kind!=='ban'&&kind!=='play'){toast('Выбери тип ограничения','error');return;}
  if(remove&&!window.confirm(kind==='ban'?'Снять бан с '+target+'?':'Снять запрет играть для '+target+'?'))return;
  if(!remove&&(!Number.isInteger(days)||days<0||days>3650)){toast('Укажи срок от 0 до 3650 дней','error');return;}
  if(!remove&&kind==='play'&&days<1){toast('Запрет запуска матчей должен быть минимум на 1 день','error');return;}
  if(!remove&&!reason){toast('Укажи причину ограничения','error');return;}
  if(button)button.disabled=true;
  try{
    var r=kind==='ban'
      ? await cfSupabaseClient.rpc('cf_admin_set_ban',{p_target:target,p_hours:remove?-1:(days===0?0:days*24),p_reason:remove?'Блокировка снята администратором':reason})
      : await cfSupabaseClient.rpc('cf_admin_set_match_restriction',{p_target:target,p_days:remove?0:days,p_reason:remove?'':reason});
    if(r.error)throw r.error;
    var name=r.data&&r.data.nickname||target;
    var message=kind==='ban'
      ? (remove?'Бан снят: '+name:'Аккаунт заблокирован: '+name+' · '+(r.data.banned_until?new Date(r.data.banned_until).toLocaleString('ru-RU'):'навсегда'))
      : (remove?'Запрет запуска матчей снят: '+name:'Запуск матчей запрещён: '+name+' · до '+new Date(r.data.match_restricted_until).toLocaleString('ru-RU'));
    if(out)out.textContent=message;
    toast(remove?'Ограничение снято':'Ограничение применено','success');
  }catch(e){
    var msg=e&&e.message||'Ошибка';
    if(/function .* does not exist|Could not find the function/i.test(msg))msg='Сначала выполни SQL/41_player_host_and_moderation.sql в Supabase.';
    if(out)out.textContent=msg;toast(msg,'error');
  }finally{if(button)button.disabled=false;}
}
async function cfAdminManageAvatarFrame(grant) {
  var me=getUser(),target=($('#cfAdminFrameTarget')&&$('#cfAdminFrameTarget').value||'').trim(),frame=$('#cfAdminFrameChoice')&&$('#cfAdminFrameChoice').value,out=$('#cfAdminFrameOut'),button=grant?$('#cfAdminFrameGrant'):$('#cfAdminFrameRemove');
  var labels={violet:'Violet Flux',collab:'CFGRADE X CF FACEIT',arctic:'Arctic Pulse',crimson:'Crimson Edge',iris:'Black Iris'};
  if(!me||!isAdmin(me)){toast('Недостаточно прав','error');return;}
  if(!cfSupabaseClient||!cfOnlineAccount||!cfOnlineAccount.id){toast('Войди в онлайн-аккаунт Supabase','error');return;}
  if(!target){toast('Введи ник, игровой ID или UUID игрока','error');return;}
  if(!labels[frame]){toast('Выбери рамку','error');return;}
  if(!grant&&!window.confirm('Снять рамку «'+labels[frame]+'» у игрока '+target+'?'))return;
  if(button)button.disabled=true;
  try{
    var r=await cfSupabaseClient.rpc('cf_admin_manage_avatar_frame',{p_target:target,p_frame:frame,p_grant:grant});
    if(r.error)throw r.error;
    var data=r.data||{},name=data.nickname||target;
    if(data.user_id===cfOnlineAccount.id){cfOnlineAccount.avatarFrame=data.avatar_frame||'';updateHeader();}
    var message=grant?'Рамка «'+labels[frame]+'» выдана игроку '+name+'. Её увидят все игроки.':(data.frame_removed?'Рамка «'+labels[frame]+'» снята у игрока '+name+'.':'У игрока '+name+' не было этой рамки.');
    if(!grant&&data.avatar_frame)message+=' Активна рамка: '+(labels[data.avatar_frame]||data.avatar_frame)+'.';
    if(out)out.textContent=message;
    toast(grant?'Рамка выдана':'Выдача рамки обновлена','success');
  }catch(e){
    var msg=e&&e.message||'Ошибка';
    if(/function .* does not exist|Could not find the function|schema cache/i.test(msg))msg='Сначала выполни SQL/47_shop_avatar_frames.sql после SQL/42_sponsor_badge_and_profile_customization.sql.';
    if(out)out.textContent=msg;toast(msg,'error');
  }finally{if(button)button.disabled=false;}
}
function bindAdmin() {
  var admEl = $('#adm'); if (admEl) admEl.addEventListener('click', function (e) { var t = e.target.closest('[data-adm-tab]'); if (!t) return; admEl.dataset.tab = t.dataset.admTab; $$('.adm-tabs button', admEl).forEach(function (b) { b.classList.toggle('on', b === t); }); });
  refreshBadge(); renderAdmin(); cfLoadOnlineAdminMatches(true);
  var apply = $('#staffApply');
  if (apply) apply.addEventListener('click', async function () {
    var me = getUser(), target = ($('#staffNick').value || '').trim(), role = $('#staffRole').value;
    var verifiedChoice=$('#staffVerified')?$('#staffVerified').value:'',verified=verifiedChoice===''?null:verifiedChoice==='true',sponsorChoice=$('#staffSponsor')?$('#staffSponsor').value:'',sponsor=sponsorChoice===''?null:sponsorChoice==='true',out=$('#staffResult');
    if (!me || !isAdmin(me)) { toast('Недостаточно прав', 'error'); return; }
    if (!target) { toast('Введи ник, e-mail, игровой ID или UUID', 'error'); return; }
    if (role === 'admin' && !me.founder && me.role !== 'founder') { toast('Только владелец может выдавать админку', 'error'); return; }
    if (!cfSupabaseClient || !cfOnlineAccount) { toast('Нужно войти в онлайн-аккаунт Supabase', 'error'); return; }
    apply.disabled = true; apply.textContent = 'Сохраняем…';
    try {
      var r = await cfSupabaseClient.rpc('cf_manage_staff_lookup', {p_target:target,p_role:role,p_verified:verified,p_sponsor:sponsor});
      if (r.error) throw r.error;
      if (out) out.textContent = 'Сохранено на сервере: ' + (r.data.nickname || target) + ' · ' + (role==='cooperation'?'Сотрудничество':role==='admin'?'Администратор':role==='tester'?'Тестер':'Игрок') + (role==='cooperation'?' · синяя галочка':(verified===null?'':verified?' · золотая галочка выдана':' · золотая галочка снята')) + (r.data.sponsor_badge?' · значок спонсора активен':' · значок спонсора отсутствует');
      toast('Права игрока обновлены на сервере', 'success');
    } catch (e) {
      var msg = e && e.message ? e.message : 'Ошибка';
      if (/function .* does not exist|Could not find the function/i.test(msg)) msg = 'Сначала выполни SQL/42_sponsor_badge_and_profile_customization.sql в Supabase.';
      if (out) out.textContent = msg;
      toast(msg, 'error');
    } finally { apply.disabled = false; apply.textContent = 'Применить права на сервере'; }
  });
  var primeBtn=$('#cfAdminPrimeGrant'),moderationBtn=$('#cfModerationApply'),moderationRemoveBtn=$('#cfModerationRemove');
  if(primeBtn)primeBtn.addEventListener('click',async function(){var me=getUser(),target=$('#cfPrimeTarget').value.trim(),out=$('#cfAdminPrimeOut');if(!me||!me.founder){if(out)out.textContent='Выдать PRIME может только владелец.';return;}if(!target){toast('Введи ник или ID игрока','error');return;}primeBtn.disabled=true;try{var r=await cfSupabaseClient.rpc('cf_admin_grant_prime',{p_target:target,p_days:30});if(r.error)throw r.error;if(out)out.textContent='PRIME выдан: '+(r.data.nickname||target)+' до '+new Date(r.data.prime_expires_at).toLocaleString('ru-RU');toast('FACEIT PRIME выдан на 30 дней','success');}catch(e){if(out)out.textContent=e.message||'Ошибка';toast(e.message||'Не удалось выдать PRIME. Запусти SQL v30.','error');}finally{primeBtn.disabled=false;}});


  if(moderationBtn)moderationBtn.addEventListener('click',function(){cfAdminApplyModeration(false);});
  if(moderationRemoveBtn)moderationRemoveBtn.addEventListener('click',function(){cfAdminApplyModeration(true);});
  var frameGrantBtn=$('#cfAdminFrameGrant'),frameRemoveBtn=$('#cfAdminFrameRemove');
  if(frameGrantBtn)frameGrantBtn.addEventListener('click',function(){cfAdminManageAvatarFrame(true);});
  if(frameRemoveBtn)frameRemoveBtn.addEventListener('click',function(){cfAdminManageAvatarFrame(false);});
}
function renderAdmin() {
  var box = $('#adminBody'), me = getUser();
  if (!box || !isAdmin(me)) return;
  box.innerHTML =
        (me && me.founder && cfOnlineAccount && cfOnlineAccount.role==='founder' ? '<section class="card"><div class="card-head"><h2>Редактор новостей</h2><span class="chip accent">Только владелец</span></div><p class="small muted" style="margin-bottom:12px">Опубликованные новости видны всем. Можно добавить фото или MP4. Загрузка доступна только владельцу сайта.</p><div class="field"><label for="newsTitle">Заголовок</label><input class="input" id="newsTitle" maxlength="100" placeholder="Заголовок новости"></div><div class="field"><label for="newsDesc">Краткое описание</label><input class="input" id="newsDesc" maxlength="240" placeholder="Короткий текст новости"></div><div class="field"><label for="newsLink">Ссылка (необязательно)</label><input class="input" id="newsLink" maxlength="500" placeholder="https://..."></div><div class="field"><label for="cfNewsMediaPick">Фото или видео MP4</label><div class="cf-news-uploader" id="cfNewsDropzone"><input class="cf-news-native-input" id="cfNewsMedia" type="file" accept=".jpg,.jpeg,.png,.webp,.gif,.mp4,image/jpeg,image/png,image/webp,image/gif,video/mp4" aria-label="Выбрать фото или видео для новости"><button class="cf-news-pick" id="cfNewsMediaPick" type="button"><span class="cf-news-pick-icon" aria-hidden="true"><svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 16V4m0 0L7.5 8.5M12 4l4.5 4.5M5 14v5h14v-5"/></svg></span><span class="cf-news-pick-copy"><b>Добавить фото или видео</b><small>Нажми, чтобы выбрать файл, или перетащи его сюда</small></span><span class="cf-news-pick-action">Открыть</span></button><div id="cfNewsMediaPreview" class="cf-news-preview" aria-live="polite"></div></div><p class="small muted">JPG, PNG, WebP, GIF — до 10 МБ; MP4 — до 50 МБ. Для загрузки требуется SQL/46_owner_news_media.sql и вход под аккаунтом владельца.</p></div><div class="btn-row"><button class="btn primary" type="button" id="cfAdminNewsPublish" data-act="news-add">Опубликовать новость</button></div><p class="small muted" id="cfAdminNewsStatus" aria-live="polite"></p></section>' : '<section class="card"><h2>Редактор новостей</h2><p class="small muted">Публиковать новости и загружать к ним медиа может только владелец сайта.</p></section>');
}

/* ---------- Delegated clicks inside #view ---------- */
view.addEventListener('click', function (e) {
  var t = e.target.closest('[data-go],[data-news],[data-act],[data-mode],[data-banner],[data-drawer-prime]');
  if (!t || !view.contains(t)) return;
  if (t.dataset.banner) { cfSetBanner(t.dataset.banner); return; }
  if (t.hasAttribute('data-drawer-prime')) { cfOpenPrime(); return; }
  if (t.dataset.go) { navigate(t.dataset.go); return; }
  if (t.dataset.news) { openNews(t.dataset.news); return; }
  if (t.dataset.mode) { selectMode(t.dataset.mode); return; }
  switch (t.dataset.act) {
    case 'tour-create': case 'tour-join': case 'tour-start': case 'tour-bluewin': case 'tour-redwin': case 'tour-delete': tourneyAction(t.dataset.act, t.dataset.id); break;
    case 'news-retry': cfLoadOnlineNews(true); break;
    case 'start': startSearch(); break;
    case 'cancel': cancelSearch(); break;
    case 'accept': cfLobbyMatchAction('accept'); break;
    case 'decline': cfLobbyMatchAction('decline'); break;
    case 'again': playAgain(); break;
    case 'edit': openEditProfile(); break;
    case 'logout': confirmLogout(); break;
    case 'retry': if (curSec) renderSection(curSec); break;
    case 'news-add': cfAdminPublishNews(); break;
    case 'lbreset':
      var s = $('#lbSearch'), f = $('#lbFilter');
      if (s) s.value = '';
      if (f) f.value = 'all';
      renderLeaderboard();
      break;
  }
});

/* ---------- Ambient background: gradient, floating orbs, sparks, grid, beam ---------- */
function buildAmbient() {
  var host = $('.ambient');
  if (!host || host.getAttribute('data-built')) return;
  host.setAttribute('data-built', '1');
  var narrow = window.innerWidth < 600, frag = document.createDocumentFragment(), i, el;
  function add(cls) { el = document.createElement('div'); el.className = cls; frag.appendChild(el); return el; }
  add('bg-grid'); add('bg-beam'); add('bg-ring');
  var mark = document.createElement('div');
  mark.innerHTML = '<svg class="logo-svg bg-mark" viewBox="0 0 48 48" aria-hidden="true"><use href="#i-logo"/></svg>';
  frag.appendChild(mark.firstChild);
  for (i = 0; i < (narrow ? 9 : 16); i++) {
    var size = rand(24, 150);
    add('orb');
    el.style.width = el.style.height = size + 'px';
    el.style.left = rand(-5, 100) + '%'; el.style.top = rand(-5, 100) + '%';
    el.style.opacity = (0.35 + Math.random() * 0.5).toFixed(2);
    el.style.filter = 'blur(' + (size > 90 ? rand(6, 12) : rand(0, 4)) + 'px)';
    el.style.setProperty('--t', rand(16, 38) + 's');
    el.style.setProperty('--d', '-' + rand(0, 30) + 's');
    el.style.setProperty('--dx', rand(-90, 90) + 'px');
    el.style.setProperty('--dy', rand(-140, 140) + 'px');
  }
  for (i = 0; i < (narrow ? 14 : 28); i++) {
    add('spark');
    el.style.left = rand(0, 100) + '%';
    el.style.setProperty('--t', rand(10, 22) + 's');
    el.style.setProperty('--d', '-' + rand(0, 22) + 's');
    el.style.setProperty('--dx', rand(-60, 60) + 'px');
    var sz = rand(2, 4); el.style.width = el.style.height = sz + 'px';
  }
  host.appendChild(frag);
}

/* =========================================================
   Added features: UI sounds + Supabase password recovery
   ========================================================= */
var cfSoundOn = localStorage.getItem('cfFaceit.sounds') !== 'off';
function cfTone(freq, duration, type, gainValue) {
  if (!cfSoundOn) return;
  try { var AC=window.AudioContext||window.webkitAudioContext; if(!AC)return; var c=cfTone.ctx||(cfTone.ctx=new AC()); if(c.state==='suspended')c.resume(); var o=c.createOscillator(),g=c.createGain(); o.type=type||'sine';o.frequency.value=freq;g.gain.setValueAtTime(0.0001,c.currentTime);g.gain.exponentialRampToValueAtTime(gainValue||0.055,c.currentTime+0.025);g.gain.exponentialRampToValueAtTime(0.0001,c.currentTime+duration);o.connect(g);g.connect(c.destination);o.start();o.stop(c.currentTime+duration+0.03); } catch(e){}
}
function cfClickSound(){cfTone(640,.07,'triangle',.035);setTimeout(function(){cfTone(880,.09,'sine',.025)},55);}
function cfIntroSound(){cfTone(392,.16,'sine',.035);setTimeout(function(){cfTone(523,.2,'sine',.035)},100);setTimeout(function(){cfTone(659,.25,'triangle',.03)},220);}
document.addEventListener('click',function(e){var b=e.target.closest('button');if(!b)return;if(b.id==='forgotPassword')return;if(!b.disabled&&!b.matches('[data-close]'))cfClickSound();},true);
function cfSupabase(){if(!window.supabase||!window.CF_SUPABASE_URL||!window.CF_SUPABASE_ANON_KEY)return null;try{return window.supabase.createClient(window.CF_SUPABASE_URL,window.CF_SUPABASE_ANON_KEY)}catch(e){return null}}
var cfSupabaseClient=cfSupabase();
var cfOnlineAccount=null;
var CF_REGION_PROBES={ru:{name:{ru:'Россия',en:'Russia',ar:'روسيا',zh:'俄罗斯'},url:'https://storage.yandexcloud.net/'},eu:{name:{ru:'Европа',en:'Europe',ar:'أوروبا',zh:'欧洲'},url:'https://s3.eu-central-1.amazonaws.com/'},asia:{name:{ru:'Азия',en:'Asia',ar:'آسيا',zh:'亚洲'},url:'https://s3.ap-southeast-1.amazonaws.com/'}};
function cfNormalizeRegion(value){return value==='all'||value==='eu'||value==='asia'?value:'ru';}
function cfRegionLabel(value){var region=cfNormalizeRegion(value);if(region==='all')return {ru:'Все регионы',en:'All regions',ar:'كل المناطق',zh:'所有地区'}[cfLanguage]||'Все регионы';var entry=CF_REGION_PROBES[region];return entry.name[cfLanguage]||entry.name.ru;}
function cfPingMessage(kind,results){
  var lang=cfLanguage||'ru',labels={ru:{loading:'Измеряю задержку до региональных узлов…',unavailable:'недоступно',failed:'Не удалось измерить задержку. Проверь подключение или блокировку запросов.',suffix:'мс',note:'HTTP-отклик до узла проверки, не ping до игрового сервера.'},en:{loading:'Measuring latency to regional endpoints…',unavailable:'unavailable',failed:'Could not measure latency. Check your connection or request blocking.',suffix:'ms',note:'HTTP response time to a probe endpoint, not game-server ping.'},ar:{loading:'جارٍ قياس زمن الاستجابة إلى نقاط المناطق…',unavailable:'غير متاح',failed:'تعذر قياس زمن الاستجابة. تحقق من الاتصال أو حظر الطلبات.',suffix:'ms',note:'زمن استجابة HTTP لعقدة اختبار، وليس ping لخادم اللعبة.'},zh:{loading:'正在测量到区域节点的延迟…',unavailable:'不可用',failed:'无法测量延迟。请检查网络连接或请求拦截。',suffix:'ms',note:'到探测节点的 HTTP 响应时间，不是游戏服务器 ping。'}}[lang]||null;
  labels=labels||{loading:'Measuring latency…',unavailable:'unavailable',failed:'Could not measure latency.',suffix:'ms',note:'HTTP response time to a probe endpoint, not game-server ping.'};
  if(kind==='loading')return labels.loading;
  if(kind==='failed')return labels.failed;
  var parts=['ru','eu','asia'].map(function(region){var value=results&&results[region];return cfRegionLabel(region)+': '+(Number.isFinite(value)?Math.round(value)+' '+labels.suffix:labels.unavailable);});
  return parts.join(' · ')+' — '+labels.note;
}
function cfProbeRegion(region){
  var probe=CF_REGION_PROBES[region];if(!probe)return Promise.resolve(null);
  var samples=[],attempt=0;
  function sample(){return new Promise(function(resolve){
    var started=performance.now(),done=false,controller=window.AbortController?new AbortController():null;
    var timer=setTimeout(function(){if(controller)controller.abort();finish(null);},4500);
    function finish(value){if(done)return;done=true;clearTimeout(timer);resolve(value);}
    var url=probe.url+(probe.url.indexOf('?')<0?'?':'&')+'cf_ping='+Date.now().toString(36)+'-'+Math.random().toString(36).slice(2);
    fetch(url,{method:'HEAD',mode:'no-cors',cache:'no-store',credentials:'omit',signal:controller?controller.signal:undefined}).then(function(){finish(Math.max(1,Math.round(performance.now()-started)));}).catch(function(){finish(null);});
  });}
  function next(){if(attempt>=3){if(samples.length<2)return Promise.resolve(null);samples.sort(function(a,b){return a-b;});var middle=Math.floor(samples.length/2);return Promise.resolve(samples.length%2?samples[middle]:Math.round((samples[middle-1]+samples[middle])/2));}attempt++;return sample().then(function(value){if(value!==null)samples.push(value);return next();});}
  return next();
}
function cfMeasureRegionPings(){return Promise.all(['ru','eu','asia'].map(function(region){return cfProbeRegion(region).then(function(value){return [region,value];});})).then(function(rows){var result={};rows.forEach(function(row){result[row[0]]=row[1];});return result;});}
function cfBindRegionPing(buttonId,statusId){var button=$('#'+buttonId),status=$('#'+statusId);if(!button||!status)return;button.addEventListener('click',async function(){button.disabled=true;status.textContent=cfPingMessage('loading');try{var result=await cfMeasureRegionPings();status.textContent=Object.keys(result).some(function(k){return Number.isFinite(result[k]);})?cfPingMessage('result',result):cfPingMessage('failed');}catch(e){status.textContent=cfPingMessage('failed');}finally{button.disabled=false;}});}
async function cfSaveRegionPreference(value){var region=cfNormalizeRegion(value),account=getUser();if(!account)throw new Error('Войди в аккаунт, чтобы сохранить регион.');var previous=cfNormalizeRegion(account.region);if(previous===region)return;
  if(cfOnlineAccount&&cfOnlineAccount.id){cfOnlineAccount.region=region;try{await cfSaveOnlineProfile(cfOnlineAccount);}catch(err){cfOnlineAccount.region=previous;if(/region|schema cache/i.test(String(err&&err.message||'')))throw new Error('Сначала запусти SQL/39_regions_and_ping.sql в Supabase.');throw err;}}
  else updateUser(function(current){current.region=region;});
  toast('Регион сохранён. Для очереди он применяется при следующем поиске.','success');
}
cfBindRegionPing('regRegionPingBtn','regRegionPingStatus');
var cfSitePresenceChannel=null,cfSitePresenceId='';
function cfSitePresenceOffline(){var root=$('#cfSitePresence'),count=$('#cfSitePresenceCount');if(root){root.classList.remove('is-live');root.setAttribute('aria-label','Счётчик онлайна временно недоступен');}if(count)count.textContent='—';}
function cfSitePresenceRender(){var root=$('#cfSitePresence'),count=$('#cfSitePresenceCount');if(!root||!count||!cfSitePresenceChannel)return;var state=cfSitePresenceChannel.presenceState?cfSitePresenceChannel.presenceState():{},ids=Object.create(null);Object.keys(state||{}).forEach(function(key){var entries=Array.isArray(state[key])?state[key]:[];entries.forEach(function(meta,index){var id=meta&&meta.online_id?String(meta.online_id):key+':'+index;ids[id]=true;});});var total=Object.keys(ids).length;count.textContent=String(total);root.classList.add('is-live');root.setAttribute('aria-label',total+' активных посетителей сейчас');}
function cfSitePresenceStart(){if(!cfSupabaseClient||cfSitePresenceChannel)return;try{var id='';try{id=localStorage.getItem('cfFaceit.presenceId')||'';}catch(ignore){}if(!id){id=window.crypto&&crypto.randomUUID?crypto.randomUUID():'visitor-'+Date.now().toString(36)+'-'+Math.random().toString(36).slice(2);try{localStorage.setItem('cfFaceit.presenceId',id);}catch(ignore2){}}cfSitePresenceId=id;var channel=cfSupabaseClient.channel('cf-faceit-site-online',{config:{private:false,presence:{key:id}}});cfSitePresenceChannel=channel;channel.on('presence',{event:'sync'},function(){if(cfSitePresenceChannel===channel)cfSitePresenceRender();});channel.subscribe(function(status){if(cfSitePresenceChannel!==channel)return;if(status==='SUBSCRIBED'){channel.track({online_id:id,connected_at:new Date().toISOString()}).then(function(result){if(cfSitePresenceChannel===channel){if(result==='ok')cfSitePresenceRender();else cfSitePresenceOffline();}}).catch(cfSitePresenceOffline);}else if(status==='CHANNEL_ERROR'||status==='TIMED_OUT'||status==='CLOSED')cfSitePresenceOffline();});}catch(e){cfSitePresenceChannel=null;cfSitePresenceOffline();}}

function cfProfileToAccount(row,email){
  if(!row)return null;
  return {nick:row.nickname, gameId:row.game_id||'', region:cfNormalizeRegion(row.region), email:email||'', pass:'', display:row.display_name||row.nickname, avatar:row.avatar||'ember', avatarFrame:row.avatar_frame||'', profileBanner:cfIsProfileBanner(row.profile_banner)?row.profile_banner:'ember', primeExpiresAt:row.prime_expires_at||'', sponsorBadge:row.sponsor_badge===true, sponsorBackground:row.sponsor_site_background||'', sponsorNicknameStyle:['default','blue','gradient','rainbow'].indexOf(row.sponsor_nickname_style)>=0?row.sponsor_nickname_style:'default', bannedUntil:'', permanentlyBanned:false, banReason:'', socials:{telegram:row.telegram_url||'',youtube:row.youtube_url||'',tiktok:row.tiktok_url||''}, elo:Number(row.elo)||800, wins:Number(row.wins)||0, losses:Number(row.losses)||0, history:[], created:row.created_at?Date.parse(row.created_at):Date.now(), admin:row.role==='admin'||row.role==='founder', founder:row.role==='founder', role:row.role||'player', verified:row.verified===true, id:row.id};
}
async function cfLoadOnlineProfile(user){
  if(!cfSupabaseClient||!user)return null;
  var profileColumns='id,nickname,game_id,display_name,avatar,avatar_frame,elo,wins,losses,verified,created_at,role,telegram_url,youtube_url,tiktok_url,profile_banner,prime_expires_at,region,sponsor_badge,sponsor_site_background,sponsor_nickname_style';
  var r=await cfSupabaseClient.from('profiles').select(profileColumns).eq('id',user.id).maybeSingle();
  if(r.error&&/avatar_frame|column .*avatar_frame.*does not exist/i.test(String(r.error.message||''))){profileColumns=profileColumns.replace(',avatar_frame','');r=await cfSupabaseClient.from('profiles').select(profileColumns).eq('id',user.id).maybeSingle();}
  if(r.error&&/sponsor_|schema cache|column .* does not exist/i.test(String(r.error.message||''))){profileColumns=profileColumns.replace(',sponsor_badge,sponsor_site_background,sponsor_nickname_style','');r=await cfSupabaseClient.from('profiles').select(profileColumns).eq('id',user.id).maybeSingle();if(!r.error&&r.data){r.data.sponsor_badge=false;r.data.sponsor_site_background='';r.data.sponsor_nickname_style='default';}}
  if(r.error&&/region|schema cache/i.test(String(r.error.message||''))){profileColumns=profileColumns.replace(',region,sponsor_badge,sponsor_site_background,sponsor_nickname_style','');r=await cfSupabaseClient.from('profiles').select(profileColumns).eq('id',user.id).maybeSingle();if(!r.error&&r.data){r.data.region='ru';r.data.sponsor_badge=false;r.data.sponsor_site_background='';r.data.sponsor_nickname_style='default';}}
  if(r.error)throw r.error;
  if(!r.data)throw new Error('Профиль не создан в базе. Выполни файл supabase-auth-profile-setup.sql в SQL Editor.');
  cfOnlineAccount=cfProfileToAccount(r.data,user.email);
  cfApplySponsorWallpaper();
  try { var mr=await cfSupabaseClient.rpc('cf_my_moderation'); if(!mr.error && mr.data){cfOnlineAccount.bannedUntil=mr.data.banned_until||'';cfOnlineAccount.permanentlyBanned=mr.data.is_permanently_banned===true;cfOnlineAccount.banReason=mr.data.ban_reason||'';cfOnlineAccount.matchRestrictedUntil=mr.data.match_restricted_until||'';cfOnlineAccount.matchRestrictionReason=mr.data.match_restriction_reason||'';} } catch(modErr) { console.warn('Moderation status check unavailable',modErr); }
  if(cfOnlineAccount.permanentlyBanned || (cfOnlineAccount.bannedUntil && Date.parse(cfOnlineAccount.bannedUntil)>Date.now())) { var until=cfOnlineAccount.permanentlyBanned?'навсегда':new Date(cfOnlineAccount.bannedUntil).toLocaleString('ru-RU'); try{await cfSupabaseClient.auth.signOut();}catch(ignore){} cfOnlineAccount=null; throw new Error('Аккаунт заблокирован до '+until+(r.data.ban_reason?' · Причина: '+r.data.ban_reason:'')); }
  return cfOnlineAccount;
}
async function cfSaveOnlineProfile(acc){
  if(!cfSupabaseClient||!cfOnlineAccount||!cfOnlineAccount.id)return;
  var payload={display_name:acc.display||acc.nick,avatar:typeof acc.avatar==='string'&&acc.avatar.length<300000?acc.avatar:'ember',telegram_url:(acc.socials||{}).telegram||'',youtube_url:(acc.socials||{}).youtube||'',tiktok_url:(acc.socials||{}).tiktok||'',profile_banner:cfIsProfileBanner(acc.profileBanner)&&String(acc.profileBanner).indexOf('local-banner:')!==0?acc.profileBanner:'ember',region:cfNormalizeRegion(acc.region)};
  var r=await cfSupabaseClient.from('profiles').update(payload).eq('id',cfOnlineAccount.id);
  if(r.error)throw r.error;
}
function cfNickFromProfile(){return cfOnlineAccount&&cfOnlineAccount.nick;}

function openPasswordRecovery(){
  var client=null,mail='';
  function step1(){return '<h2 id="modalTitle">Восстановление пароля</h2><p class="small muted">Введи почту, указанную при регистрации. Мы отправим на неё код восстановления.</p><form id="recStep1"><div class="field"><label for="recEmail">Электронная почта</label><input class="input" id="recEmail" type="email" autocomplete="email" required maxlength="254" placeholder="name@example.com"></div><div class="btn-row"><button class="btn" type="button" data-close>Отмена</button><button class="btn primary" type="submit">Отправить код</button></div></form><p class="small muted" style="margin-top:12px">Не получается? <a href="'+esc(CHANNEL_URL)+'" target="_blank" rel="noopener noreferrer">Написать в поддержку</a></p>';}
  function step2(){return '<h2 id="modalTitle">Введи код из письма</h2><p class="small muted">Код отправлен на <b>'+esc(mail)+'</b>. Проверь «Входящие» и «Спам».</p><form id="recStep2"><div class="field"><label for="recCode">Код из письма</label><input class="input" id="recCode" type="text" inputmode="numeric" autocomplete="one-time-code" required pattern="[0-9]{6}" maxlength="6" placeholder="123456" aria-describedby="recCodeHelp"></div><div class="field"><label for="recPass">Новый пароль</label><input class="input" id="recPass" type="password" minlength="8" required autocomplete="new-password" placeholder="Минимум 8 символов"></div><div class="field"><label for="recPass2">Повтори пароль</label><input class="input" id="recPass2" type="password" minlength="8" required autocomplete="new-password"></div><div class="btn-row"><button class="btn" type="button" id="recResend">Отправить код ещё раз</button><button class="btn primary" type="submit">Сменить пароль</button></div></form><p class="small muted" id="recCodeHelp" style="margin-top:12px">Код действует недолго. Если письма нет — подожди минуту или <a href="'+esc(CHANNEL_URL)+'" target="_blank" rel="noopener noreferrer">напиши в поддержку</a>.</p>';}
  openModal(step1(),function(root){
    function getClient(){if(client)return client;if(!window.supabase||!window.CF_SUPABASE_URL||!window.CF_SUPABASE_ANON_KEY)return null;try{client=window.supabase.createClient(window.CF_SUPABASE_URL,window.CF_SUPABASE_ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false}});}catch(e){client=null;}return client;}
    async function send(btn){var c=getClient();if(!c){toast('Онлайн-восстановление не подключено к серверу','error');return false;}if(btn)btn.disabled=true;try{var r=await c.auth.resetPasswordForEmail(mail);if(r.error)throw r.error;return true;}catch(err){toast(cfAuthErrorMessage(err,'recovery'),'error');return false;}finally{if(btn)btn.disabled=false;}}
    function bind2(){
      var codeInput=$('#recCode',root);codeInput.addEventListener('input',function(){this.value=this.value.replace(/\D/g,'').slice(0,6);});
      $('#recResend',root).addEventListener('click',async function(e){if(await send(e.target))toast('Код отправлен снова','success');});
      $('#recStep2',root).addEventListener('submit',async function(e){e.preventDefault();var code=$('#recCode',root).value.replace(/\s+/g,''),p1=$('#recPass',root).value,p2=$('#recPass2',root).value,btn=e.target.querySelector('[type="submit"]');
        if(!/^\d{6}$/.test(code)){toast('Введи все 6 цифр из письма','error');return;}
        if(p1.length<8){toast('Пароль — минимум 8 символов','error');return;}
        if(p1!==p2){toast('Пароли не совпадают','error');return;}
        btn.disabled=true;
        try{var c=getClient(),v=await c.auth.verifyOtp({email:mail,token:code,type:'recovery'});if(v.error)throw v.error;var u=await c.auth.updateUser({password:p1});if(u.error)throw u.error;try{await c.auth.signOut();}catch(e2){}closeModal();toast('Пароль изменён. Войди с новым паролем','success');}
        catch(err){var m=String(err&&err.message||'');toast(/expired|invalid|token/i.test(m)?'Код неверный или устарел. Запроси новый':cfAuthErrorMessage(err,'recovery'),'error');btn.disabled=false;}});
    }
    $('#recStep1',root).addEventListener('submit',async function(e){e.preventDefault();var v=$('#recEmail',root).value.trim();if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v)){toast('Введи корректную почту','error');return;}mail=v;if(await send(e.target.querySelector('[type="submit"]'))){modalBody.innerHTML=step2();bind2();var f=$('#recCode',modalBody);if(f)f.focus();toast('Код отправлен на почту','success');}});
  });
}
var forgotBtn=document.getElementById('forgotPassword');if(forgotBtn)forgotBtn.addEventListener('click',openPasswordRecovery);
document.addEventListener('click',function(e){if(e.target&&e.target.id==='toggleSounds'){cfSoundOn=!cfSoundOn;localStorage.setItem('cfFaceit.sounds',cfSoundOn?'on':'off');cfSyncSearchSound();toast(cfSoundOn?'Звуки включены':'Звуки выключены');if(curSec==='profile')renderSection('profile');if(cfSoundOn)cfClickSound();}});
document.addEventListener('click',function(e){var bannerPick=e.target&&e.target.closest&&e.target.closest('#cfProfileBannerPick'),bannerInput=$('#cfProfileBannerUpload');if(bannerPick&&bannerInput&&!bannerInput.disabled){bannerInput.click();return;}var pick=e.target&&e.target.closest&&e.target.closest('#cfNewsMediaPick'),remove=e.target&&e.target.closest&&e.target.closest('#cfNewsMediaRemove'),input=$('#cfNewsMedia');if(pick&&input){input.click();return;}if(remove&&input){input.value='';cfPreviewAdminNewsMedia(input);}});
document.addEventListener('dragover',function(e){var bannerZone=e.target&&e.target.closest&&e.target.closest('#cfProfileBannerDropzone');if(bannerZone){e.preventDefault();bannerZone.classList.add('is-dragging');return;}var zone=e.target&&e.target.closest&&e.target.closest('#cfNewsDropzone');if(!zone)return;e.preventDefault();zone.classList.add('is-dragging');});
document.addEventListener('dragleave',function(e){var zone=e.target&&e.target.closest&&e.target.closest('#cfProfileBannerDropzone,#cfNewsDropzone');if(zone&&(!e.relatedTarget||!zone.contains(e.relatedTarget)))zone.classList.remove('is-dragging');});
document.addEventListener('drop',function(e){var bannerZone=e.target&&e.target.closest&&e.target.closest('#cfProfileBannerDropzone');if(bannerZone){e.preventDefault();bannerZone.classList.remove('is-dragging');var bannerInput=$('#cfProfileBannerUpload');if(bannerInput&&!bannerInput.disabled&&e.dataTransfer&&e.dataTransfer.files&&e.dataTransfer.files.length){bannerInput.files=e.dataTransfer.files;bannerInput.dispatchEvent(new Event('change',{bubbles:true}));}return;}var zone=e.target&&e.target.closest&&e.target.closest('#cfNewsDropzone');if(!zone)return;e.preventDefault();zone.classList.remove('is-dragging');var input=$('#cfNewsMedia');if(!input||!e.dataTransfer||!e.dataTransfer.files||!e.dataTransfer.files.length)return;input.files=e.dataTransfer.files;input.dispatchEvent(new Event('change',{bubbles:true}));});

document.addEventListener('change',function(e){if(!e.target)return;if(e.target.id==='cfProfileBannerUpload'){var bannerFile=e.target.files&&e.target.files[0];cfPreviewProfileBannerFile(bannerFile);cfUploadProfileBanner(bannerFile,e.target);}if(e.target.id==='cfNewsMedia')cfPreviewAdminNewsMedia(e.target);});
// Recovery callback is only available for a configured Supabase account.
if(location.search.indexOf('reset-password=1')!==-1){setTimeout(function(){var client=cfSupabase();if(!client)return;openModal('<h2 id="modalTitle">Новый пароль</h2><form id="newPasswordForm"><div class="field"><label for="newPassword">Новый пароль</label><input class="input" id="newPassword" type="password" minlength="8" required autocomplete="new-password"></div><div class="field"><label for="newPassword2">Повтори пароль</label><input class="input" id="newPassword2" type="password" minlength="8" required autocomplete="new-password"></div><div class="btn-row"><button class="btn primary" type="submit">Сохранить пароль</button></div></form>',function(root){$('#newPasswordForm',root).addEventListener('submit',async function(e){e.preventDefault();var a=$('#newPassword',root).value,b=$('#newPassword2',root).value;if(a.length<8||a!==b){toast('Пароли должны совпадать и содержать минимум 8 символов','error');return;}var r=await client.auth.updateUser({password:a});if(r.error){toast(cfAuthErrorMessage(r.error,'recovery'),'error');return;}toast('Пароль онлайн-аккаунта обновлён','success');closeModal();history.replaceState({},'',location.pathname);});});},800);}

/* =========================================================
   Match start sound (original synthesized cue, Web Audio)
   ========================================================= */
function cfMatchSound() {
  if (!cfSoundOn) return;
  var now = Date.now();
  if (cfMatchSound.until && now < cfMatchSound.until) return; // never stack
  cfMatchSound.until = now + 1900;
  try {
    var AC = window.AudioContext || window.webkitAudioContext; if (!AC) return;
    var c = cfTone.ctx || (cfTone.ctx = new AC()); if (c.state === 'suspended') c.resume();
    var t = c.currentTime + 0.02, master = c.createGain(); master.gain.value = 0.9; master.connect(c.destination);
    var env = function (g, t0, a, d, peak) { g.gain.setValueAtTime(0.0001, t0); g.gain.exponentialRampToValueAtTime(peak, t0 + a); g.gain.exponentialRampToValueAtTime(0.0001, t0 + d); };
    var o = c.createOscillator(), g = c.createGain();            // low impact
    o.type = 'sine'; o.frequency.setValueAtTime(140, t); o.frequency.exponentialRampToValueAtTime(48, t + 0.28);
    env(g, t, 0.01, t + 0.34, 0.16); o.connect(g); g.connect(master); o.start(t); o.stop(t + 0.4);
    var s = c.createOscillator(), sg = c.createGain(), f = c.createBiquadFilter();   // rising sweep
    s.type = 'sawtooth'; f.type = 'lowpass';
    f.frequency.setValueAtTime(500, t); f.frequency.exponentialRampToValueAtTime(3200, t + 0.4);
    s.frequency.setValueAtTime(180, t); s.frequency.exponentialRampToValueAtTime(720, t + 0.4);
    env(sg, t, 0.05, t + 0.46, 0.05); s.connect(f); f.connect(sg); sg.connect(master); s.start(t); s.stop(t + 0.5);
    [[659.25, 0.34], [880, 0.46], [1318.5, 0.58]].forEach(function (n) {   // three ascending pings
      var oo = c.createOscillator(), gg = c.createGain(); oo.type = 'triangle'; oo.frequency.value = n[0];
      env(gg, t + n[1], 0.008, t + n[1] + 0.16, 0.07); oo.connect(gg); gg.connect(master); oo.start(t + n[1]); oo.stop(t + n[1] + 0.2);
    });
    [659.25, 987.77, 1318.5].forEach(function (fq) {                      // closing chord
      var oo = c.createOscillator(), gg = c.createGain(); oo.type = 'sine'; oo.frequency.value = fq;
      env(gg, t + 0.74, 0.02, t + 1.5, 0.05); oo.connect(gg); gg.connect(master); oo.start(t + 0.74); oo.stop(t + 1.55);
    });
  } catch (e) {}
}
var cfSearchAudio = null, cfSearchAudioPlayed = false, cfSearchPingTimer = null, cfSearchStartPending = false;
function cfSearchIsActive() {
  if (cfSearchStartPending) return true;
  var state = typeof cfLobbyMatch !== 'undefined' && cfLobbyMatch ? cfLobbyMatch.data : null;
  if (state && state.match) return state.match.status === 'searching';
  return !!((state && state.queue) || (typeof play !== 'undefined' && play && play.status === 'searching'));
}
function cfStartSearchSound() {
  if (!cfSoundOn) return;
  try {
    if (!cfSearchAudio) {
      cfSearchAudio = new Audio('audio/cf-match-search-loop.mp3');
      cfSearchAudio.loop = false;
      cfSearchAudio.preload = 'auto';
      cfSearchAudio.volume = 0.38;
    }
    if (!cfSearchAudioPlayed) {
      cfSearchAudioPlayed = true;
      cfSearchAudio.currentTime = 0;
      var playback = cfSearchAudio.play();
      if (playback && playback.catch) playback.catch(function () {});
    }
  } catch (e) {}
  if (!cfSearchPingTimer) {
    cfPingSound();
    cfSearchPingTimer = setInterval(function () {
      if (cfSoundOn && cfSearchIsActive()) cfPingSound();
      else cfStopSearchSound(cfSearchIsActive());
    }, 4000);
  }
}
function cfStopSearchSound(preserveAudioPlayed) {
  if (cfSearchPingTimer) { clearInterval(cfSearchPingTimer); cfSearchPingTimer = null; }
  if (cfSearchAudio) { try { cfSearchAudio.pause(); cfSearchAudio.currentTime = 0; } catch (e) {} }
  if (!preserveAudioPlayed) cfSearchAudioPlayed = false;
}
function cfSyncSearchSound() {
  var active = cfSearchIsActive();
  if (cfSoundOn && active) cfStartSearchSound();
  else cfStopSearchSound(active);
}
function cfPingSound() { cfTone(880, 0.09, 'triangle', 0.05); setTimeout(function () { cfTone(1175, 0.14, 'sine', 0.045); }, 90); }

/* =========================================================
   Player search (by nickname or 6-digit game ID)
   ========================================================= */
var PROFILE_LIST_COLS = 'id,nickname,game_id,display_name,avatar,avatar_frame,elo,verified,role,profile_banner,prime_expires_at,sponsor_badge,sponsor_site_background,sponsor_nickname_style';
var PROFILE_FULL_COLS = 'id,nickname,game_id,display_name,avatar,avatar_frame,elo,wins,losses,verified,role,created_at,telegram_url,youtube_url,tiktok_url,profile_banner,prime_expires_at,sponsor_badge,sponsor_site_background,sponsor_nickname_style';
var srch = { seq: 0, timer: null, rows: [] };
function tplSearch() {
  return '<section class="section-head rise" style="--i:0"><h1 class="h1">Поиск</h1><p class="sub">Найди игрока по нику или игровому ID</p></section>' +
    '<div class="card rise" style="--i:1"><label class="srch-box" for="srchInput">' + icon('search') +
    '<input class="input" id="srchInput" type="search" inputmode="search" maxlength="20" autocomplete="off" autocapitalize="off" spellcheck="false" placeholder="Ник или ID из 6–7 цифр" aria-label="Поиск игрока"></label>' +
    '<div class="srch-res" id="srchRes" aria-live="polite"><p class="small muted">Введи минимум 2 символа ника или 6–7 цифр игрового ID.</p></div></div>';
}
function bindSearch() {
  var inp = $('#srchInput'); if (!inp) return;
  inp.addEventListener('input', function () {
    var clean = inp.value.replace(/[^A-Za-z0-9_-]/g, '').slice(0, 20);
    if (clean !== inp.value) inp.value = clean;
    clearTimeout(srch.timer);
    srch.timer = setTimeout(function () { runSearch(inp.value); }, 350);
  });
  inp.addEventListener('keydown', function (e) { if (e.key === 'Enter') { clearTimeout(srch.timer); runSearch(inp.value); } });
}
async function runSearch(q) {
  var res = $('#srchRes'); if (!res) return;
  q = String(q || '').trim();
  if (q.length < 2) { res.innerHTML = '<p class="small muted">Введи минимум 2 символа ника или 6–7 цифр игрового ID.</p>'; return; }
  if (!cfSupabaseClient) { res.innerHTML = '<p class="small muted">Поиск игроков работает при подключении к серверу.</p>'; return; }
  var seq = ++srch.seq;
  res.innerHTML = '<p class="small muted">Ищем…</p>';
  try {
    var r;
    if (/^[0-9]{6,7}$/.test(q)) r = await cfSupabaseClient.from('profiles').select(PROFILE_LIST_COLS).eq('game_id', q).limit(5);
    else r = await cfSupabaseClient.from('profiles').select(PROFILE_LIST_COLS).ilike('nickname', '%' + q.replace(/[\\%_]/g, function (ch) { return '\\' + ch; }) + '%').order('elo', { ascending: false }).limit(20);
    if(r.error&&/avatar_frame|column .*avatar_frame.*does not exist/i.test(String(r.error.message||''))){var fallbackCols=PROFILE_LIST_COLS.replace(',avatar_frame','');if(/^[0-9]{6,7}$/.test(q))r=await cfSupabaseClient.from('profiles').select(fallbackCols).eq('game_id',q).limit(5);else r=await cfSupabaseClient.from('profiles').select(fallbackCols).ilike('nickname','%'+q.replace(/[\\%_]/g,function(ch){return '\\'+ch;})+'%').order('elo',{ascending:false}).limit(20);}
    if (seq !== srch.seq) return; // a newer search is already running
    if (r.error) throw r.error;
    srch.rows = r.data || [];
    if (!srch.rows.length) { res.innerHTML = '<p class="small muted">Никого не нашли. Проверь ник или ID.</p>'; return; }
    res.innerHTML = srch.rows.map(function (p) {
      var a = cfProfileToAccount(p);
      return '<button type="button" class="p-row" data-player="' + esc(p.id) + '">' + avatar(a.avatar||'ember', a.display, 40, a.avatarFrame) +
        '<div class="grow"><div class="t">' + cfStyledNickHTML(a.display,a) + vbadge(a) + '</div>' +
        '<div class="d ellipsis">@' + esc(a.nick) + (a.gameId ? ' · ID ' + esc(a.gameId) : '') + '</div></div><span class="elo">' + fmt(a.elo) + '</span></button>';
    }).join('');
  } catch (err) {
    if (seq !== srch.seq) return;
    res.innerHTML = '<p class="small muted">Не удалось выполнить поиск. Проверь интернет и попробуй ещё раз.</p>';
  }
}
async function openPlayer(id) {
  if (!cfSupabaseClient || !id) return;
  openModal('<h2 id="modalTitle">Игрок</h2><p class="small muted">Загружаем профиль…</p>');
  try {
    var r = await cfSupabaseClient.from('profiles').select(PROFILE_FULL_COLS).eq('id', id).maybeSingle();
    if(r.error&&/avatar_frame|column .*avatar_frame.*does not exist/i.test(String(r.error.message||'')))r=await cfSupabaseClient.from('profiles').select(PROFILE_FULL_COLS.replace(',avatar_frame','')).eq('id',id).maybeSingle();
    if (r.error || !r.data) throw new Error('not found');
    var p = cfProfileToAccount(r.data), lvl = levelInfo(p.elo), me = getUser(), self = me && cfOnlineAccount && cfOnlineAccount.id === p.id;
    var inMyLobby = lobby.state && lobby.state.lobby && lobby.state.lobby.members.some(function (m) { return m.id === p.id; });
    var invited = lobby.state && lobby.state.lobby && (lobby.state.lobby.invites || []).some(function (i) { return i.to && i.to.id === p.id; });
    var canInvite = !self && !inMyLobby && !invited && (!lobby.state || !lobby.state.lobby || lobby.state.lobby.is_owner);
    openModal('<h2 id="modalTitle">Профиль игрока</h2>' +
      cfProfileHeroMarkup(p,true) +
      '<div class="chips" style="margin-top:10px">' + lvlIcon(lvl.level, 34) + '<span class="chip accent">Уровень ' + lvl.level + '</span>' + (function () { var f = (cfLb || []).filter(function (x) { return x.nickname === p.nick; })[0]; return f ? '<span class="chip accent">Топ #' + f.rank + '</span>' : ''; })() + '<span class="chip">' + esc(tierName(lvl.level)) + '</span>' + (p.founder ? '<span class="chip founder">Основатель</span>' : (p.admin ? '<span class="chip gold">Администратор</span>' : (p.role === 'tester' ? '<span class="chip accent">Тестер</span>' : ''))) + '</div>' +
      socialHTML(p) +
      '<div class="pl-tiles"><div class="tile"><b>' + fmt(p.elo) + '</b><span>ELO</span></div><div class="tile"><b>' + p.wins + '/' + p.losses + '</b><span>Поб. / пор.</span></div><div class="tile"><b>' + winRate(p) + '%</b><span>Винрейт</span></div></div>' +
      '<div class="btn-row">' + (canInvite ? '<button class="btn primary" type="button" data-lobby="invite" data-id="' + esc(p.id) + '">Пригласить в лобби</button>' : (inMyLobby ? '<span class="chip">Уже в твоём лобби</span>' : (invited ? '<span class="chip">Приглашение отправлено</span>' : ''))) +
      '<button class="btn" type="button" data-close>Закрыть</button></div>');
  } catch (err) {
    openModal('<h2 id="modalTitle">Игрок</h2><p class="small muted">Не удалось загрузить профиль.</p><div class="btn-row"><button class="btn primary" type="button" data-close>Закрыть</button></div>');
  }
}

/* =========================================================
   Friends: Supabase-backed requests, list, and lobby invites
   ========================================================= */
var cfFriends = {tab:'friends', friends:[], incoming:[], outgoing:[], loaded:false};
async function cfFriendRpc(name,args){var r=await cfSupabaseClient.rpc(name,args||{});if(r.error)throw r.error;return r.data;}
var cfLanguage = ['ru','en','ar','zh'].indexOf(store.get('cfFaceit.language')) >= 0 ? store.get('cfFaceit.language') : 'ru';
var cfTheme = store.get('cfFaceit.theme') === 'light' ? 'light' : 'dark';
var cfI18nRows = [
  ['Игровое меню','Game menu','قائمة اللعبة','游戏菜单'],['Открыть меню','Open menu','افتح القائمة','打开菜单'],['Боковое меню','Side menu','القائمة الجانبية','侧边菜单'],['Закрыть меню','Close menu','إغلاق القائمة','关闭菜单'],['Демки','Demos','العروض التجريبية','演示录像'],['Демо игроков · загрузка раз в час','Player demos · one upload per hour','عروض اللاعبين · رفع مرة كل ساعة','玩家录像 · 每小时可上传一次'],['Демки игроков','Player demos','عروض اللاعبين','玩家录像'],['Загрузи игровую демку .dem или видео .mp4 до 50 МБ. Загрузки доступны всем игрокам; у каждого игрока одна загрузка в час.','Upload a .dem replay or .mp4 video up to 50 MB. Uploads are available to all players; each player can upload once per hour.','ارفع إعادة لعب .dem أو فيديو .mp4 حتى 50 ميغابايت. الإعادات متاحة لكل اللاعبين؛ رفع واحد لكل لاعب كل ساعة.','上传不超过 50 MB 的 .dem 录像或 .mp4 视频。所有玩家均可查看；每位玩家每小时可上传一次。'],['Файл демки (.dem или .mp4, до 50 МБ)','Demo file (.dem or .mp4, up to 50 MB)','ملف العرض (.dem أو .mp4، حتى 50 ميغابايت)','录像文件（.dem 或 .mp4，最大 50 MB）'],['Загрузить демку','Upload demo','رفع العرض','上传录像'],['Нажми, чтобы выбрать файл','Click to choose a file','اضغط لاختيار ملف','点击选择文件'],['Формат .dem или .mp4 · до 50 МБ','.dem or .mp4 · up to 50 MB','.dem أو .mp4 · حتى 50 ميغابايت','.dem 或 .mp4 · 最大 50 MB'],['Файл не выбран','No file selected','لم يتم اختيار ملف','未选择文件'],['Социальные сети','Social networks','الشبكات الاجتماعية','社交网络'],['Прогресс уровня','Level progress','التقدم في المستوى','等级进度'],['FACEIT · Ур. ','FACEIT · Lv. ','FACEIT · المستوى ','FACEIT · 等级 '],['Следующая загрузка','Next upload','الرفع التالي','下次上传'],['Ещё нет опубликованных демо. Будь первым!','No published demos yet. Be the first!','لا توجد عروض منشورة بعد. كن أول من يرفع!','暂无已发布的录像。来上传第一份吧！'],['Войди в онлайн-аккаунт, чтобы загружать и скачивать демки.','Sign in to an online account to upload and download demos.','سجّل الدخول إلى حساب عبر الإنترنت لرفع العروض وتنزيلها.','登录在线账户以上传和下载录像。'],['Загрузка не завершена. Выбери тот же файл и повтори попытку в течение 15 минут.','Upload did not finish. Select the same file and retry within 15 minutes.','لم يكتمل الرفع. اختر الملف نفسه وحاول مجددًا خلال 15 دقيقة.','上传未完成。请在 15 分钟内选择同一文件重试。'],['Только файл .dem или .mp4 до 50 МБ можно загружать раз в час.','Only .dem or .mp4 files up to 50 MB can be uploaded once per hour.','يمكن رفع ملفات .dem أو .mp4 فقط حتى 50 ميغابايت مرة كل ساعة.','仅支持每小时上传一次、不超过 50 MB 的 .dem 或 .mp4 文件。'],['Загрузка демки…','Uploading demo…','جارٍ رفع العرض…','正在上传录像…'],['Демка опубликована','Demo published','تم نشر العرض','录像已发布'],['Скачать','Download','تنزيل','下载'],['Удалить','Delete','حذف','删除'],['Удалить демку?','Delete this demo?','هل تريد حذف هذا العرض؟','删除此录像？'],['Не удалось загрузить список демо. Выполни SQL/43_game_demos.sql.','Could not load demos. Run SQL/43_game_demos.sql.','تعذر تحميل العروض. شغّل SQL/43_game_demos.sql.','无法加载录像。请运行 SQL/43_game_demos.sql。'],['Лимит загрузки зарезервирован; повтори загрузку с тем же файлом.','Upload limit reserved; retry with the same file.','تم حجز حد الرفع؛ أعد المحاولة بالملف نفسه.','上传额度已预留；请用同一文件重试。'],['Роль','Role','الدور','角色'],['Основатель','Founder','المؤسس','创始人'],['Админ','Admin','مشرف','管理员'],['Тестер','Tester','مختبر','测试员'],['Сотрудничество','Partner','شراكة','合作'],

  ['Друзья','Friends','الأصدقاء','好友'],['Список друзей и заявки','Friends and requests','الأصدقاء والطلبات','好友和请求'],['Мессенджер','Messenger','الرسائل','消息'],['Каналы, группы и чаты','Channels, groups and chats','القنوات والمجموعات والدردشات','频道、群组和聊天'],['Найти игрока','Find a player','ابحث عن لاعب','查找玩家'],['По нику или игровому ID','By nickname or game ID','بالاسم أو معرّف اللعبة','按昵称或游戏 ID'],['Профиль','Profile','الملف الشخصي','个人资料'],['Статистика и настройки','Stats and settings','الإحصائيات والإعدادات','数据与设置'],['Настройки','Settings','الإعدادات','设置'],['Тема оформления и язык','Theme and language','المظهر واللغة','主题和语言'],['Закрыть','Close','إغلاق','关闭'],
  ['Выбери фон профиля или загрузи собственное фото или видео.','Choose a profile background or upload your own photo or video.','اختر خلفية للملف الشخصي أو حمّل صورتك أو مقطع الفيديو الخاص بك.','选择个人资料背景，或上传自己的照片或视频。'],['Загрузить фото или видео из галереи','Upload photo or video from gallery','تحميل صورة أو فيديو من المعرض','从相册上传照片或视频'],['Изображения и видео до 20 МБ. Баннер отображается фоном за аватаром.','Images and videos up to 20 MB. The banner appears behind your avatar.','صور ومقاطع فيديو حتى 20 ميغابايت. يظهر الغلاف خلف صورتك الرمزية.','图片和视频最大 20 MB。横幅将显示在头像背景中。'],['Баннер профиля обновлён','Profile banner updated','تم تحديث غلاف الملف الشخصي','个人资料横幅已更新'],['Выбери изображение или видео: MP4, WebM, MOV, PNG, JPG, WebP или GIF','Choose an image or video: MP4, WebM, MOV, PNG, JPG, WebP, or GIF','اختر صورة أو فيديو: MP4 أو WebM أو MOV أو PNG أو JPG أو WebP أو GIF','请选择图片或视频：MP4、WebM、MOV、PNG、JPG、WebP 或 GIF'],['Размер баннера не должен превышать 20 МБ','Banner must be 20 MB or smaller','يجب ألا يتجاوز حجم الغلاف 20 ميغابايت','横幅文件不能超过 20 MB'],['Сначала выполни SQL/34_profile_banner_media.sql в Supabase.','Run SQL/34_profile_banner_media.sql in Supabase first.','شغّل SQL/34_profile_banner_media.sql في Supabase أولاً.','请先在 Supabase 中运行 SQL/34_profile_banner_media.sql。'],
  ['Тема оформления','Appearance','المظهر','外观'],['Тёмная (чёрная)','Dark (black)','داكن (أسود)','深色（黑色）'],['Светлая (белая)','Light (white)','فاتح (أبيض)','浅色（白色）'],['Язык интерфейса','Interface language','لغة الواجهة','界面语言'],['Русский','Russian','الروسية','俄语'],['Английский','English','الإنجليزية','英语'],['Арабский','Arabic','العربية','阿拉伯语'],['Китайский','Chinese','الصينية','中文'],['Выбор сохраняется автоматически','Your choices are saved automatically','يتم حفظ اختياراتك تلقائيًا','选择会自动保存'],['Изменения применены','Settings updated','تم تحديث الإعدادات','设置已更新'],
  ['Главная','Home','الرئيسية','主页'],['Новости','News','الأخبار','新闻'],['Поиск','Search','بحث','搜索'],['Играть','Play','العب','开始游戏'],['Топы','Leaderboard','المتصدرون','排行榜'],['Турниры','Tournaments','البطولات','锦标赛'],
  ['Добро пожаловать, ','Welcome, ','مرحبًا، ','欢迎， '],['Твой путь к вершине начинается здесь','Your path to the top starts here','رحلتك نحو القمة تبدأ هنا','你的登顶之路从这里开始'],['Рейтинг ELO','ELO rating','تصنيف ELO','ELO 排名'],['Найти матч','Find a match','ابحث عن مباراة','寻找比赛'],['Уровень','Level','المستوى','等级'],['Матчи','Matches','المباريات','比赛'],['Винрейт','Win rate','نسبة الفوز','胜率'],['Последние новости','Latest news','آخر الأخبار','最新新闻'],['Все','All','الكل','全部'],['Топ игроков','Top players','أفضل اللاعبين','顶尖玩家'],['Весь рейтинг','Full leaderboard','كل التصنيف','完整排行榜'],['Последние матчи','Recent matches','آخر المباريات','最近比赛'],['История','History','السجل','历史'],['Победа','Victory','فوز','胜利'],['Поражение','Defeat','هزيمة','失败'],['Победы','Wins','الانتصارات','胜场'],['Поражения','Losses','الهزائم','负场'],['Матчей','Matches','المباريات','场比赛'],['Баннер профиля','Profile banner','غلاف الملف الشخصي','个人资料横幅'],['Галерея','Gallery','المعرض','图库'],['Выбери оформление, оно сохранится в профиле.','Choose a style; it will be saved to your profile.','اختر مظهرًا وسيُحفظ في ملفك الشخصي.','选择样式，它将保存到你的个人资料。'],['История матчей','Match history','سجل المباريات','比赛记录'],['Звуки','Sounds','الأصوات','声音'],['Настройки','Settings','الإعدادات','设置'],['Звуки включены','Sounds on','الأصوات مفعّلة','声音已开启'],['Звуки выключены','Sounds off','الأصوات متوقفة','声音已关闭'],
  ['Найди игрока по нику или игровому ID','Find a player by nickname or game ID','ابحث عن لاعب بالاسم أو معرّف اللعبة','按昵称或游戏 ID 查找玩家'],['Ник или ID из 6–7 цифр','Nickname or 6–7 digit ID','الاسم أو معرّف من 6 أو 7 أرقام','昵称或 6–7 位 ID'],['Введи минимум 2 символа ника или 6–7 цифр игрового ID.','Enter at least 2 nickname characters or a 6–7 digit game ID.','أدخل حرفين على الأقل من الاسم أو معرّف لعبة من 6 إلى 7 أرقام.','请输入至少 2 个昵称字符或 6–7 位游戏 ID。'],['Ищем…','Searching…','جارٍ البحث…','搜索中…'],['Никого не нашли. Проверь ник или ID.','No players found. Check the nickname or ID.','لم يتم العثور على لاعبين. تحقق من الاسم أو المعرّف.','未找到玩家。请检查昵称或 ID。'],
  ['Найди матч за пару нажатий','Find a match in a couple of taps','ابحث عن مباراة ببضع نقرات','轻点几下即可寻找比赛'],['Соревновательный 5×5','Competitive 5v5','تنافسي 5 ضد 5','竞技 5v5'],['Быстрый 2×2','Quick 2v2','سريع 2 ضد 2','快速 2v2'],['Классический рейтинговый режим','Classic ranked mode','النمط الكلاسيكي المصنّف','经典排位模式'],['Короткие матчи в паре','Short duo matches','مباريات ثنائية قصيرة','快速双人比赛'],['Отменить поиск','Cancel search','إلغاء البحث','取消搜索'],['Поиск матча','Match search','البحث عن مباراة','匹配中'],['Ожидание матча','Waiting for match','بانتظار مباراة','等待比赛'],['Матч найден','Match found','تم العثور على مباراة','找到比赛'],
  ['Новости CounterFlame','CounterFlame news','أخبار CounterFlame','CounterFlame 新闻'],['Канал разработчика','Developer channel','قناة المطور','开发者频道'],['Партнёры','Partners','الشركاء','合作伙伴'],['Скоро','Coming soon','قريبًا','即将推出'],['Загрузка…','Loading…','جارٍ التحميل…','加载中…'],['Пока нет игроков в рейтинге.','No players in the leaderboard yet.','لا يوجد لاعبون في التصنيف بعد.','排行榜中暂时没有玩家。'],['Максимальный уровень','Maximum level','أعلى مستوى','最高等级'],['Легенда','Legend','أسطورة','传奇'],['Элита','Elite','النخبة','精英'],['Опытный игрок','Experienced player','لاعب متمرس','资深玩家'],['Новичок','Rookie','مبتدئ','新手'],['Золотая галочка у тебя есть.','You have the gold verification badge.','لديك شارة التوثيق الذهبية.','你已获得金色认证标记。'],['Рейтинг считается по ELO из базы и меняется после подтверждённых матчей.','The rating is based on ELO in the database and changes after confirmed matches.','يُحسب التصنيف حسب ELO في قاعدة البيانات ويتغير بعد تأكيد المباريات.','排名根据数据库中的 ELO 计算，并在比赛确认后更新。'],['Редактировать профиль','Edit profile','تعديل الملف الشخصي','编辑个人资料'],
  ['Создай комнату','Create a room','أنشئ غرفة','创建房间'],['Активных матчей нет.','There are no active matches.','لا توجد مباريات نشطة.','暂无进行中的比赛。'],['Регистрация','Registration','التسجيل','注册'],['Завершён','Completed','مكتمل','已完成'],['Предстоящий','Upcoming','قادم','即将开始'],['Матч идёт','Match in progress','المباراة جارية','比赛进行中'],['Отменён','Cancelled','ملغى','已取消'],['Любая','Any','أي خريطة','任意'],['Режим','Mode','النمط','模式'],['Карта','Map','الخريطة','地图'],['Твоя группа','Your party','فريقك','你的小队'],['Групп в очереди','Parties in queue','المجموعات في قائمة الانتظار','排队队伍'],['В очереди','In queue','في قائمة الانتظار','排队中'],['Скопировать код','Copy code','نسخ الرمز','复制代码'],['Отправить итоги матча','Submit match results','إرسال نتيجة المباراة','提交比赛结果'],['Идёт матч…','Match in progress…','المباراة جارية…','比赛进行中…'],['Ожидаем результат','Waiting for result','بانتظار النتيجة','等待结果'],['Победитель','Winner','الفائز','获胜者'],['Команда слева','Left team','الفريق الأيسر','左侧队伍'],['Команда справа','Right team','الفريق الأيمن','右侧队伍'],['Создать турнир','Create tournament','إنشاء بطولة','创建锦标赛'],['Опубликовать турнир','Publish tournament','نشر البطولة','发布锦标赛'],['Взять матч','Take match','استلام المباراة','接管比赛'],['Отменить матч','Cancel match','إلغاء المباراة','取消比赛'],['Подтвердить','Confirm','تأكيد','确认'],['Отправить результат','Submit result','إرسال النتيجة','提交结果'],['Нейросеть проверяет скриншот…','AI is checking the screenshot…','يتحقق الذكاء الاصطناعي من لقطة الشاشة…','AI 正在检查截图…'],['Выбрать скриншот','Choose screenshot','اختر لقطة شاشة','选择截图'],['Закрыто','Closed','مغلق','已关闭'],['Создать аккаунт','Create account','إنشاء حساب','创建账号'],['Вход','Sign in','تسجيل الدخول','登录'],['Никнейм или почта','Nickname or email','اسم المستخدم أو البريد الإلكتروني','昵称或邮箱'],['Пароль','Password','كلمة المرور','密码'],['Введи пароль.','Enter your password.','أدخل كلمة المرور.','请输入密码。'],['Неверная почта или пароль.','Incorrect email or password.','البريد الإلكتروني أو كلمة المرور غير صحيحة.','邮箱或密码错误。'],['Уже есть аккаунт?','Already have an account?','هل لديك حساب بالفعل؟','已有账号？'],['Игровой ID','Game ID','معرّف اللعبة','游戏 ID'],['Назад','Back','رجوع','返回'],['Далее','Next','التالي','下一步'],['Сохранить','Save','حفظ','保存'],['Обновить','Refresh','تحديث','刷新'],['Отправить','Send','إرسال','发送'],['Удалить','Delete','حذف','删除'],['Принять','Accept','قبول','接受'],['Отклонить','Decline','رفض','拒绝'],['Показать пароль','Show password','إظهار كلمة المرور','显示密码'],['Скрыть пароль','Hide password','إخفاء كلمة المرور','隐藏密码'],['Правила платформы','Platform rules','قواعد المنصة','平台规则'],['Пока нет матчей.','No matches yet.','لا توجد مباريات بعد.','暂无比赛。'],['Матчей пока нет. Найди матч во вкладке «Играть».','No matches yet. Find a match in the Play tab.','لا توجد مباريات بعد. ابحث عن مباراة في تبويب اللعب.','暂无比赛。前往“开始游戏”查找比赛。'],['Отправить сообщение','Send message','إرسال رسالة','发送消息'],['Напиши сообщение…','Write a message…','اكتب رسالة…','输入消息…'],['Сохранить изменения','Save changes','حفظ التغييرات','保存更改'],['Настройки звука','Sound settings','إعدادات الصوت','声音设置'],['Осталось','Remaining','متبقي','剩余'],['Код комнаты','Room code','رمز الغرفة','房间代码'],['Ур.','Lv.','المستوى','等级'],['Подбор игроков','Matchmaking','مطابقة اللاعبين','匹配玩家'],['Ожидает администратора','Waiting for an administrator','بانتظار المسؤول','等待管理员'],['Результат ожидает проверки администратора.','The result is awaiting administrator review.','النتيجة بانتظار مراجعة المسؤول.','结果等待管理员审核。'],['Новости пока не опубликованы.','No news has been published yet.','لم يتم نشر أي أخبار بعد.','暂未发布新闻。'],['Нет подключения к интернету','No internet connection','لا يوجد اتصال بالإنترنت','没有网络连接'],['Ссылка скопирована','Link copied','تم نسخ الرابط','链接已复制'],['Код скопирован','Code copied','تم نسخ الرمز','代码已复制'],['Удачи!','Good luck!','بالتوفيق!','祝你好运！'],['Поиск игроков работает при подключении к серверу.','Player search is available when connected to the server.','يتوفر البحث عن اللاعبين عند الاتصال بالخادم.','连接服务器后即可搜索玩家。'],['Войди в онлайн-аккаунт','Sign in to your online account','سجّل الدخول إلى حسابك عبر الإنترنت','登录在线账号'],['Выйти','Log out','تسجيل الخروج','退出登录'],['Панель администратора','Admin panel','لوحة الإدارة','管理面板'],['Не удалось показать раздел.','Could not display this section.','تعذّر عرض هذا القسم.','无法显示此部分。'],['Повторить','Retry','إعادة المحاولة','重试'],['Открыть профиль','Open profile','افتح الملف الشخصي','打开个人资料'],['Сообщения от сайта','Site notifications','إشعارات الموقع','网站通知']
];
cfI18nRows.push(
  ['Регион подбора','Matchmaking region','منطقة المطابقة','匹配地区'],['Все регионы','All regions','كل المناطق','所有地区'],
  ['Россия','Russia','روسيا','俄罗斯'],['Европа','Europe','أوروبا','欧洲'],['Азия','Asia','آسيا','亚洲'],
  ['Измерить задержку','Measure latency','قياس زمن الاستجابة','测量延迟'],
  ['Выбери регион для поиска матчей. «Все регионы» — общий пул. Задержка измеряется из этого браузера до узла проверки; это не ping до игрового сервера.','Choose a matchmaking region. “All regions” is a shared pool. Latency is measured from this browser to a probe endpoint, not the game server.','اختر منطقة للمطابقة. «كل المناطق» هي قائمة مشتركة. يُقاس زمن الاستجابة من هذا المتصفح إلى نقطة اختبار، وليس إلى خادم اللعبة.','选择匹配地区。“所有地区”是公共匹配池。延迟从此浏览器测量到探测节点，不是游戏服务器。'],
  ['Регион влияет на подбор игроков; смена действует со следующего поиска. «Все регионы» — общий пул. Задержка измеряется из этого браузера до узла проверки, не игрового сервера.','The region affects matchmaking; changes apply to your next search. “All regions” is a shared pool. Latency is measured from this browser to a probe endpoint, not the game server.','تؤثر المنطقة على المطابقة؛ ويسري التغيير عند البحث التالي. «كل المناطق» هي قائمة مشتركة. يُقاس زمن الاستجابة من هذا المتصفح إلى نقطة اختبار، وليس إلى خادم اللعبة.','地区会影响匹配；更改将在下次搜索时生效。“所有地区”是公共匹配池。延迟从此浏览器测量到探测节点，不是游戏服务器。'],
  ['Нажми, чтобы проверить задержку до региональных узлов.','Measure latency to the regional endpoints.','اضغط لقياس زمن الاستجابة إلى نقاط المناطق.','点击以测量到区域节点的延迟。']
);
cfI18nRows.push(
  ['Магазин','Store','المتجر','商店'],['Рамки и оформление аватара','Frames and avatar styles','إطارات وتنسيق الصورة الرمزية','头像边框与装饰'],['Магазин рамок','Frame shop','متجر الإطارات','边框商店'],['Выбери оформление и посмотри, как оно выглядит с твоим аватаром.','Choose a style and preview it with your avatar.','اختر تنسيقًا وشاهده مع صورتك الرمزية.','选择一种样式并预览它与你头像的效果。'],['Тёмная коллаборация','Dark collaboration','تعاون داكن','联名暗色款'],['Глубокий фиолетовый перелив, фирменный знак GRADE и оранжево-чёрный стиль CF FACEIT.','Deep purple shimmer, the GRADE mark, and CF FACEIT orange-and-black styling.','تدرج أرجواني داكن مع شعار GRADE وأسلوب CF FACEIT البرتقالي والأسود.','深紫色流光、GRADE 标志与 CF FACEIT 橙黑风格。'],['Цена','Price','السعر','价格'],['Другие рамки','More frames','إطارات أخرى','更多边框'],['Цветные эффекты для твоего аватара','Color effects for your avatar','تأثيرات لونية لصورتك الرمزية','头像彩色效果'],['Тёмно-фиолетовое переливание вокруг аватара.','Dark purple shimmer around your avatar.','تدرج أرجواني داكن حول صورتك الرمزية.','头像周围的深紫色流光。'],['Холодный голубой свет с ледяным блеском.','Cool blue light with an icy shine.','ضوء أزرق بارد بلمعان جليدي.','冷蓝色灯光与冰晶光泽。'],['Яркая багровая рамка с мягким свечением.','A vivid crimson frame with a soft glow.','إطار قرمزي ساطع بتوهج ناعم.','鲜艳的深红边框，带柔和光晕。'],['Чёрный глаз моргает примерно раз в 10 секунд.','A black eye blinks about once every 10 seconds.','عين سوداء ترمش كل 10 ثوانٍ تقريبًا.','黑眼睛大约每 10 秒眨一次。']
);
cfI18nRows.push(
  ['Выбери готовый фон или загрузи свой — он появится за аватаром в профиле.','Choose a preset background or upload your own to display behind your profile avatar.','اختر خلفية جاهزة أو ارفع خلفيتك لتظهر خلف الصورة الرمزية في ملفك الشخصي.','选择预设背景或上传自己的背景，显示在个人资料头像后方。'],['Загрузить фото или видео','Upload a photo or video','ارفع صورة أو فيديو','上传照片或视频'],['Нажми, чтобы выбрать, или перетащи файл сюда','Click to choose, or drop a file here','اضغط للاختيار أو اسحب الملف إلى هنا','点击选择，或将文件拖到此处'],['Фото и видео до 20 МБ · JPG, PNG, WebP, GIF, MP4, WebM, MOV или M4V. Загрузка начнётся сразу после выбора.','Photos and videos up to 20 MB · JPG, PNG, WebP, GIF, MP4, WebM, MOV, or M4V. Upload starts as soon as you choose a file.','صور وفيديو حتى 20 ميغابايت · JPG وPNG وWebP وGIF وMP4 وWebM وMOV أو M4V. يبدأ الرفع فور اختيار الملف.','照片和视频最大 20 MB · JPG、PNG、WebP、GIF、MP4、WebM、MOV 或 M4V。选择文件后立即上传。'],['Перетащи сюда фото или видео или нажми «Выбрать». Максимум 20 МБ.','Drop a photo or video here, or click “Choose”. Maximum 20 MB.','اسحب صورة أو فيديو إلى هنا، أو اضغط «اختيار». الحد الأقصى 20 ميغابايت.','将照片或视频拖到此处，或点击“选择”。最大 20 MB。'],['Загружаю баннер… Не закрывай профиль до завершения.','Uploading banner… Keep this profile open until it finishes.','جارٍ رفع الغلاف… أبقِ الملف الشخصي مفتوحًا حتى يكتمل.','正在上传横幅…请保持个人资料页面打开，直到完成。'],['Баннер профиля обновлён.','Profile banner updated.','تم تحديث غلاف الملف الشخصي.','个人资料横幅已更新。'],['Файл выбран. Загружаю баннер…','File selected. Uploading banner…','تم اختيار الملف. جارٍ رفع الغلاف…','已选择文件。正在上传横幅…'],['Проверяю формат файла…','Checking the file format…','جارٍ التحقق من تنسيق الملف…','正在检查文件格式…']
);
var cfI18n = {ru:{},en:{},ar:{},zh:{}};
cfI18nRows.forEach(function(row){cfI18n.en[row[0]]=row[1];cfI18n.ar[row[0]]=row[2];cfI18n.zh[row[0]]=row[3];});
var cfTextOrigin = new WeakMap(), cfAttrOrigin = new WeakMap();
function cfLocalizedText(source){
  var table=cfI18n[cfLanguage]||{},known=table[source];if(known)return known;
  var m=source.match(/^До уровня (\d+): (.+) ELO$/);
  if(m){if(cfLanguage==='en')return 'To level '+m[1]+': '+m[2]+' ELO';if(cfLanguage==='ar')return 'للوصول إلى المستوى '+m[1]+': '+m[2]+' ELO';if(cfLanguage==='zh')return '升至 '+m[1]+' 级：'+m[2]+' ELO';}
  m=source.match(/^Конкурентный уровень: (.+)\. (.+)$/);
  if(m){var tier=table[m[1]]||m[1],hint=table[m[2]]||m[2],prefix=cfLanguage==='en'?'Competitive tier: ':cfLanguage==='ar'?'المستوى التنافسي: ':cfLanguage==='zh'?'竞技等级：':'Конкурентный уровень: ';return prefix+tier+'. '+hint;}
  m=source.match(/^Ур\. (\d+)$/);if(m)return (cfLanguage==='en'?'Lv. ':cfLanguage==='ar'?'المستوى ':cfLanguage==='zh'?'等级 ':'Ур. ')+m[1];
  return source;
}
function cfTranslateTextNode(node){
  var current=node.nodeValue,rec=cfTextOrigin.get(node);
  if(!rec){rec={original:current,last:current};cfTextOrigin.set(node,rec);}else if(current!==rec.last){rec.original=current;}
  var translated=cfLocalizedText(rec.original);
  if(current!==translated){rec.last=translated;node.nodeValue=translated;}else rec.last=current;
}
function cfTranslateElement(el){
  if(!el||el.nodeType!==1)return;
  ['placeholder','aria-label','title','alt'].forEach(function(name){
    if(!el.hasAttribute(name))return;
    var cur=el.getAttribute(name),attrs=cfAttrOrigin.get(el)||{};
    if(!attrs[name])attrs[name]={original:cur,last:cur};else if(cur!==attrs[name].last)attrs[name].original=cur;
    var translated=(cfI18n[cfLanguage]&&cfI18n[cfLanguage][attrs[name].original])||attrs[name].original;
    if(cur!==translated){attrs[name].last=translated;el.setAttribute(name,translated);}else attrs[name].last=cur;
    cfAttrOrigin.set(el,attrs);
  });
}
function cfTranslateTree(root){
  if(!root)return;
  if(root.nodeType===3){cfTranslateTextNode(root);return;}
  if(root.nodeType===1)cfTranslateElement(root);
  var walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT),n;
  while((n=walker.nextNode())){var parent=n.parentElement;if(parent&&!/^(SCRIPT|STYLE|TEXTAREA)$/.test(parent.tagName))cfTranslateTextNode(n);}
}
function cfApplyPreferences(){
  document.documentElement.dataset.theme=cfTheme;
  document.documentElement.lang=cfLanguage==='zh'?'zh-CN':cfLanguage;
  document.documentElement.dir=cfLanguage==='ar'?'rtl':'ltr';
  var meta=document.querySelector('meta[name="theme-color"]');if(meta)meta.content=cfTheme==='light'?'#f3f4f6':'#101010';
  cfTranslateTree(document.body);
}
function cfSetTheme(value){cfTheme=value==='light'?'light':'dark';store.set('cfFaceit.theme',cfTheme);cfApplyPreferences();}
function cfSetLanguage(value){cfLanguage=['ru','en','ar','zh'].indexOf(value)>=0?value:'ru';store.set('cfFaceit.language',cfLanguage);cfApplyPreferences();}
function cfOpenSettings(){
  openModal('<h2 id="modalTitle">Настройки</h2><div class="field"><label for="cfThemeSelect">Тема оформления</label><select class="input" id="cfThemeSelect"><option value="dark">Тёмная (чёрная)</option><option value="light">Светлая (белая)</option></select></div><div class="field"><label for="cfLanguageSelect">Язык интерфейса</label><select class="input" id="cfLanguageSelect"><option value="ru">Русский</option><option value="en">English</option><option value="ar">العربية</option><option value="zh">中文</option></select></div><div class="field"><label for="cfRegionSelect">Регион подбора</label><select class="input" id="cfRegionSelect"><option value="all">Все регионы</option><option value="ru">Россия</option><option value="eu">Европа</option><option value="asia">Азия</option></select><p class="small muted">Регион влияет на подбор игроков; смена действует со следующего поиска. «Все регионы» — общий пул. Задержка измеряется из этого браузера до узла проверки, не игрового сервера.</p><div class="btn-row" style="margin-top:8px"><button class="btn sm" type="button" id="settingsRegionPingBtn">Измерить задержку</button></div><p class="small muted" id="settingsRegionPingStatus" aria-live="polite">Нажми, чтобы проверить задержку до региональных узлов.</p></div><p class="small muted">Выбор сохраняется автоматически</p><div class="btn-row"><button class="btn" type="button" data-close>Закрыть</button></div>',function(root){
    var theme=$('#cfThemeSelect',root),language=$('#cfLanguageSelect',root),region=$('#cfRegionSelect',root),account=getUser();theme.value=cfTheme;language.value=cfLanguage;region.value=cfNormalizeRegion(account&&account.region);
    theme.addEventListener('change',function(){cfSetTheme(theme.value);});
    language.addEventListener('change',function(){cfSetLanguage(language.value);});
    region.addEventListener('change',async function(){var previous=cfNormalizeRegion(account&&account.region),next=cfNormalizeRegion(region.value);region.disabled=true;try{await cfSaveRegionPreference(next);if(account)account.region=next;}catch(err){region.value=previous;toast(err.message||'Не удалось сохранить регион','error');}finally{region.disabled=false;}});
    cfBindRegionPing('settingsRegionPingBtn','settingsRegionPingStatus');
  });
}
function cfOpenDrawer(){var d=$('#cfDrawer');if(d){d.hidden=false;$('#cfMenuTrigger').setAttribute('aria-expanded','true');}}
function cfCloseDrawer(){var d=$('#cfDrawer');if(d){d.hidden=true;$('#cfMenuTrigger').setAttribute('aria-expanded','false');}}
$('#cfMenuTrigger').addEventListener('click',cfOpenDrawer);
document.addEventListener('click',function(e){
  var close=e.target.closest&&e.target.closest('[data-drawer-close]');if(close){cfCloseDrawer();return;}
  var item=e.target.closest&&e.target.closest('[data-drawer]');if(!item)return;
  var action=item.dataset.drawer;cfCloseDrawer();
  if(action==='settings')cfOpenSettings();else if(action==='friends')cfOpenFriends('friends');else if(action==='global-chat')cfOpenGlobalChat();else if(action==='messenger')navigate('messenger');else if(action==='search')navigate('search');else if(action==='profile')navigate('profile');else if(action==='prime')cfOpenPrime();else if(action==='demos')navigate('demos');else if(action==='shop')navigate('shop');
});
cfApplyPreferences();
if(window.MutationObserver){var cfLocaleObserver=new MutationObserver(function(records){records.forEach(function(m){if(m.type==='characterData')cfTranslateTextNode(m.target);else if(m.type==='attributes')cfTranslateElement(m.target);else Array.prototype.forEach.call(m.addedNodes,function(n){cfTranslateTree(n);});});});cfLocaleObserver.observe(document.body,{subtree:true,childList:true,characterData:true,attributes:true,attributeFilter:['placeholder','aria-label','title','alt']});}
async function cfLoadFriends(){
  if(!cfSupabaseClient||!cfOnlineAccount)return;
  try{var st=await cfFriendRpc('cf_friend_state');cfFriends.friends=st.friends||[];cfFriends.incoming=st.incoming||[];cfFriends.outgoing=st.outgoing||[];cfFriends.loaded=true;var dot=$('#cfFriendDot');if(dot)dot.hidden=!cfFriends.incoming.length;}
  catch(e){cfFriends.loaded=false;toast('Не удалось загрузить друзей. Проверь FRIENDS_SETUP.sql в Supabase.','error');}
}
function cfFriendRow(p,kind){
  var name=p.display_name||p.nickname||'Игрок',id=p.id,buttons='';
  if(kind==='incoming')buttons='<button class="btn primary sm" data-friend="accept" data-id="'+esc(id)+'">Принять</button><button class="btn sm" data-friend="decline" data-id="'+esc(id)+'">Отклонить</button>';
  if(kind==='friends')buttons='<button class="btn primary sm" data-friend="lobby" data-id="'+esc(id)+'">В лобби</button><button class="btn sm" data-friend="remove" data-id="'+esc(id)+'">Удалить</button>';
  if(kind==='outgoing')buttons='<span class="chip">Ожидает ответа</span><button class="btn sm" data-friend="cancel" data-id="'+esc(id)+'">Отменить</button>';
  return '<div class="cf-friend-row">'+avatar(p.avatar||'ember',name,40,p.avatar_frame)+'<div class="grow"><b class="ellipsis">'+cfStyledNickHTML(name,p)+vbadge(p)+'</b><div class="small muted">@'+esc(p.nickname||'player')+' · '+fmt(p.elo||800)+' ELO</div></div><div class="cf-friend-actions">'+buttons+'</div></div>';
}
async function cfOpenFriends(tab){if(!cfOnlineAccount||!cfSupabaseClient){toast('Войди в онлайн-аккаунт, чтобы пользоваться друзьями','error');return;}cfFriends.tab=tab||'friends';await cfLoadFriends();cfRenderFriends();}
function cfRenderFriends(){
  var t=cfFriends.tab,list=t==='friends'?cfFriends.friends:t==='incoming'?cfFriends.incoming:cfFriends.outgoing;
  var rows=list.map(function(p){return cfFriendRow(p,t);}).join('');
  openModal('<h2 id="modalTitle">Друзья</h2><p class="small muted">Добавляй игроков, принимай заявки и собирай лобби.</p>'+
    '<form id="cfFriendAddForm" class="field"><label for="cfFriendTarget">Добавить по нику или игровому ID</label><div style="display:flex;gap:8px"><input class="input" id="cfFriendTarget" maxlength="80" placeholder="Ник или ID" required><button class="btn primary" type="submit">Добавить</button></div></form>'+
    '<div class="cf-friend-tabs"><button class="btn '+(t==='friends'?'active':'')+'" data-friend-tab="friends">Друзья ('+cfFriends.friends.length+')</button><button class="btn '+(t==='incoming'?'active':'')+'" data-friend-tab="incoming">Заявки ('+cfFriends.incoming.length+')</button><button class="btn '+(t==='outgoing'?'active':'')+'" data-friend-tab="outgoing">Отправленные</button></div>'+
    '<div id="cfFriendRows">'+(rows||'<p class="small muted">'+(t==='friends'?'Пока нет друзей. Найди игрока по нику или игровому ID.':t==='incoming'?'Входящих заявок пока нет.':'Нет отправленных заявок.')+'</p>')+'</div><div class="btn-row" style="margin-top:14px"><button class="btn" type="button" data-close>Закрыть</button></div>',function(root){
      $('#cfFriendAddForm',root).addEventListener('submit',async function(e){e.preventDefault();var q=$('#cfFriendTarget',root).value.trim();if(!q)return;try{await cfFriendRpc('cf_friend_request',{p_target:q});toast('Заявка в друзья отправлена','success');await cfOpenFriends(t);}catch(err){toast(err.message||'Не удалось отправить заявку','error');}});
    });
}
document.addEventListener('click',async function(e){
  var tab=e.target.closest&&e.target.closest('[data-friend-tab]');if(tab){cfFriends.tab=tab.dataset.friendTab;cfRenderFriends();return;}
  var b=e.target.closest&&e.target.closest('[data-friend]');if(!b)return;
  var act=b.dataset.friend,id=b.dataset.id;
  try{if(act==='accept')await cfFriendRpc('cf_friend_respond',{p_target:id,p_accept:true});else if(act==='decline')await cfFriendRpc('cf_friend_respond',{p_target:id,p_accept:false});else if(act==='remove'||act==='cancel')await cfFriendRpc('cf_friend_remove',{p_target:id});else if(act==='lobby'){closeModal();await lobbyAction('invite',id);return;}await cfOpenFriends(cfFriends.tab);toast('Список друзей обновлён','success');}
  catch(err){toast(err.message||'Не удалось выполнить действие','error');}
});
setInterval(function(){if(cfOnlineAccount&&!document.hidden&&$('#cfDrawer')&&!$('#cfDrawer').hidden)cfLoadFriends();},12000);

/* =========================================================
   Lobby (shared via Supabase RPC; see SETUP_LOBBY.sql)
   ========================================================= */
var lobby = { state: null, busy: false, unavailable: false, seenInv: {}, timer: null };
async function lobbyRpc(name, args) {
  var r = await cfSupabaseClient.rpc(name, args || {});
  if (r.error) { var e = new Error(r.error.message || 'Ошибка'); e.code = r.error.code; throw e; }
  return r.data;
}
function lobbyApply(st) {
  var firstLoad = lobby.state === null;
  lobby.state = st; lobby.unavailable = false;
  var fresh = (st.invites_in || []).filter(function (i) { return !lobby.seenInv[i.id]; });
  fresh.forEach(function (i) { lobby.seenInv[i.id] = 1; });
  if (fresh.length && !firstLoad) { toast('Приглашение в лобби от ' + (fresh[0].from.display_name || fresh[0].from.nickname), 'success'); cfPingSound(); }
  else if (fresh.length) { toast('У тебя приглашение в лобби', 'success'); cfPingSound(); }
  renderLobby(); updateLobbyDot();
}
async function lobbyPoll() {
  if (!cfSupabaseClient || !cfOnlineAccount || !cfOnlineAccount.id) { if (lobby.state) { lobby.state = null; renderLobby(); updateLobbyDot(); } return; }
  if (document.hidden || lobby.busy) return;
  try { lobbyApply(await lobbyRpc('lobby_state')); }
  catch (e) { if (!lobby.unavailable) { lobby.unavailable = true; renderLobby(); } }
}
function updateLobbyDot() {
  var n = lobby.state && lobby.state.invites_in ? lobby.state.invites_in.length : 0;
  var b = document.querySelector('.nav-item[data-nav="play"]'); if (b) b.classList.toggle('has-dot', n > 0);
}
function lobbySlot(m, isOwnerView, meId) {
  var kick = (isOwnerView && m.id !== meId) ? '<button class="btn sm" type="button" data-lobby="kick" data-id="' + esc(m.id) + '">Убрать</button>' : '';
  return '<div class="lb-slot" data-player="' + esc(m.id) + '" role="button" tabindex="0">' + avatar(m.avatar, m.display_name, 36, m.avatar_frame) + '<div class="grow"><div class="nm">'+cfStyledNickHTML(m.display_name,m)+vbadge({ founder: m.role === 'founder', role:m.role, verified: m.verified, elo: m.elo, sponsor_badge:m.sponsor_badge, sponsor_nickname_style:m.sponsor_nickname_style })+'</div>' +
    '<div class="sub">' + (m.is_owner ? 'Хозяин лобби' : 'Игрок') + ' · ' + fmt(m.elo) + ' ELO</div></div>' + kick + '</div>';
}
function lobbyHTML() {
  var st = lobby.state, html = '';
  if (lobby.unavailable && !st) return '<section class="card"><div class="card-head"><h2>Лобби</h2></div><p class="small muted">Лобби временно недоступно. Попробуй позже.</p></section>';
  if (!cfSupabaseClient || !cfOnlineAccount) return '<section class="card"><div class="card-head"><h2>Лобби</h2></div><p class="small muted">Лобби доступно после входа в онлайн-аккаунт.</p></section>';
  if (!st) return '<section class="card"><div class="card-head"><h2>Лобби</h2></div><p class="small muted">Загружаем…</p></section>';
  var inv = (st.invites_in || []).map(function (i) {
    return '<div class="inv-row">' + avatar(i.from.avatar, i.from.display_name, 36, i.from.avatar_frame) + '<div class="grow"><b class="ellipsis">' + cfStyledNickHTML(i.from.display_name,i.from) + vbadge(i.from) + '</b><div class="small muted">приглашает тебя в группу</div></div>' +
      '<button class="btn primary sm" type="button" data-lobby="accept" data-id="' + esc(i.id) + '">Принять</button><button class="btn sm" type="button" data-lobby="decline" data-id="' + esc(i.id) + '">Отклонить</button></div>';
  }).join('');
  var L = st.lobby, me = cfOnlineAccount.id;
  if (!inv && (!L || (L.is_auto && (L.members || []).length <= 1 && !(L.invites || []).length))) return '';
  if (!L) {
    html = '';
  } else {
    var slots = L.members.map(function (m) { return lobbySlot(m, L.is_owner, me); });
    (L.invites || []).forEach(function (i) {
      slots.push('<div class="lb-slot pending">' + avatar(i.to.avatar||'ember', i.to.display_name, 36, i.to.avatar_frame) + '<div class="grow"><div class="nm">' + cfStyledNickHTML(i.to.display_name,i.to) + vbadge(i.to) + '</div><div class="sub">Ждём ответа…</div></div>' +
        (L.is_owner ? '<button class="btn sm" type="button" data-lobby="kick" data-id="' + esc(i.to.id) + '">Отозвать</button>' : '') + '</div>');
    });
    while (slots.length < 5) slots.push('<div class="lb-slot empty-slot">Свободное место</div>');
    html = '<div class="lb-slots">' + slots.join('') + '</div><div class="btn-row">' +
      (L.is_owner ? '<button class="btn primary" type="button" data-go="search">' + icon('search') + 'Пригласить игрока</button>' : '') +
      (L.members.length >= 1 ? '<button class="btn primary" type="button" data-lobby-match="start" data-play-cooldown data-cooldown-label="Встать в очередь">' + icon('play') + '<span data-cooldown-label>Встать в очередь</span></button>' : '') +
      '<button class="btn danger" type="button" data-lobby="leave">Выйти из лобби</button></div>' +
      lobbyChatHTML();
  }
  return '<section class="card pm-party" aria-label="Группа"><div class="card-head"><h2>' + (L ? 'Твоя группа' : 'Приглашение') + '</h2>' + (st.lobby ? '<span class="chip accent">' + (L.members.length) + ' / 5</span>' : '') + '</div>' + inv + html + '</section>';
}
function renderLobby() { var box = $('#lobbyBox'); if (box) { var oldInput = $('#cfLobbyChatInput'); var draft = oldInput ? oldInput.value : null; box.innerHTML = lobbyHTML(); var newInput = $('#cfLobbyChatInput'); if (newInput && draft !== null) newInput.value = draft; renderLobbyMatch(); cfChatRender('lobby'); cfUpdatePlayCooldownUI(); } }
async function lobbyAction(act, id) {
  if (lobby.busy || !cfSupabaseClient) return;
  lobby.busy = true;
  try {
    var st;
    if (act === 'invite') { st = await lobbyRpc('lobby_invite', { p_user: id }); toast('Приглашение отправлено', 'success'); closeModal(); }
    else if (act === 'accept') { st = await lobbyRpc('lobby_respond', { p_invite: id, p_accept: true }); toast('Ты в лобби', 'success'); }
    else if (act === 'decline') { st = await lobbyRpc('lobby_respond', { p_invite: id, p_accept: false }); }
    else if (act === 'leave') { st = await lobbyRpc('lobby_leave'); toast('Ты вышел из лобби'); }
    else if (act === 'kick') { st = await lobbyRpc('lobby_kick', { p_user: id }); }
    lobby.busy = false;
    if (st) lobbyApply(st);
  } catch (e) {
    lobby.busy = false;
    var msg = String(e.message || '');
    toast(/[А-Яа-яЁё]/.test(msg) ? msg : 'Не удалось выполнить действие. Попробуй ещё раз.', 'error');
    lobbyPoll();
  }
}
document.addEventListener('click', function (e) {
  var t = e.target.closest && e.target.closest('[data-lobby],[data-player]');
  if (!t) return;
  if (t.dataset.player) { openPlayer(t.dataset.player); return; }
  var act = t.dataset.lobby;
  if (act) lobbyAction(act, t.dataset.id);
});
document.addEventListener('visibilitychange', function () {
  if (!document.hidden) {
    // When a player returns from CounterFlame to the website, reopen the report
    // dialog for an active live match. The site cannot inspect the game process,
    // so returning to the tab is the reliable user-visible signal.
    var active = cfLobbyMatch && cfLobbyMatch.data && cfLobbyMatch.data.match;
    if (active && active.status === 'live') {
      cfV9State.livePromptSuppressedFor = null;
      cfV9State.resultsShownFor = null;
    }
    lobbyPoll(); cfLobbyMatchPoll(); cfChatPoll();
  }
});
setInterval(lobbyPoll, 6000);

/* =========================================================
   v8: shared lobby match timer, public profiles, lobby chat + global chat
   ========================================================= */
var cfLobbyMatch = { data:null, busy:false, signature:'', lastMatchId:null, serverOffset:0, timer:null };
var cfOnlineAdminMatches = [];
var cfOnlineAdminSig = '';
var cfOnlineAdminLoading = false;
var CF_MATCH_STATUSES = {searching:'Подбор игроков',found:'Матч найден',choose_host:'Выбор организатора',host_selected:'Организатор выбран',pending_admin:'Ожидает администратора',taken:'Администратор ведёт матч',room:'Код комнаты готов',joined:'Игроки зашли',live:'Матч идёт',result_pending:'Проверка результата',done:'Завершён',cancelled:'Отменён'};
var cfV9State = { openKind:'', openMatchId:null, resultsShownFor:null, livePromptSuppressedFor:null, modalBusy:false };
function cfLobbyMatchRpc(name,args){var before=Date.now();return cfSupabaseClient.rpc(name,args||{}).then(function(r){var after=Date.now();if(r.error)throw r.error;if(r.data&&r.data.server_now){var serverMs=Date.parse(r.data.server_now);if(Number.isFinite(serverMs))cfLobbyMatch.serverOffset=serverMs-((before+after)/2);}return r.data;});}
function cfLobbyMatchSignature(m,q){if(!m)return q?'queue|'+[q.id,q.mode,q.waiting_parties,q.party_count].join('|'):'none';return [m.id,m.status,m.accepted_count,m.total_count,m.admin_nickname,m.room_code,m.cancel_reason,m.host_choice,m.room_host_id,m.result_screenshot_url,m.result_submitted_at,m.winner_team,m.result_score].join('|');}
function cfV9Root(){var el=document.getElementById('cfV9Layer');if(!el){el=document.createElement('div');el.id='cfV9Layer';el.className='cf-v9-layer';el.hidden=true;el.setAttribute('role','dialog');el.setAttribute('aria-modal','true');el.setAttribute('aria-live','polite');document.body.appendChild(el);}return el;}
function cfV9Player(p,i){p=p||{};var player={role:p.role,founder:p.role==='founder',verified:p.verified,elo:p.elo,sponsor_badge:p.sponsor_badge,sponsor_nickname_style:p.sponsor_nickname_style},name=p.nickname||p.display_name||'Игрок';return '<div class="cf-v9-player" style="--pi:'+i+'">'+avatar(p.avatar||'ember',name,52,p.avatar_frame)+'<b class="'+cfNickStyleClass(player)+'" title="'+esc(name)+'">'+esc(name)+vbadge(player)+'</b><small>'+fmt(Number(p.elo||0))+' ELO</small></div>';}
function cfV9Team(title,players,blue){var team=(players||[]);return '<section class="cf-v9-team '+(blue?'blue':'')+'"><div class="cf-v9-team-head"><strong>'+title+'</strong><span>'+team.length+' / '+(team.length>2?5:2)+' ИГРОКОВ</span></div><div class="cf-v9-players">'+(team.length?team.map(cfV9Player).join(''):'<p class="small muted">Загрузка состава…</p>')+'</div></section>';}
function cfTeamLabel(x){return x==='A'?'КТ':x==='B'?'Т':(x||'—');}
function cfV9Roster(mt,inline){var a=mt.team_a||[],b=mt.team_b||[];if(!a.length&&!b.length){var all=mt.players||[],half=Math.ceil(all.length/2);a=all.slice(0,half);b=all.slice(half);}return '<div class="'+(inline?'cf-v9-inline-roster':'cf-v9-team-grid')+'">'+cfV9Team('КТ · КОНТР-ТЕРРОРИСТЫ',a,true)+(inline?'':'<div class="cf-v9-vs">VS</div>')+cfV9Team('Т · ТЕРРОРИСТЫ',b,false)+'</div>';}
function cfV9Map(mt){var img=MAP_IMAGES[mt.map_name]||MAP_IMAGES.Mirage;return '<div class="cf-v9-map"><img src="'+esc(img)+'" alt="Карта '+esc(mt.map_name)+'"><div><strong>'+esc(mt.map_name)+'</strong><small>COUNTERFLAME · '+(mt.mode==='duo'?'2×2':'5×5')+' · до 16 раундов</small></div></div>';}
function cfV9Shell(kicker,title,subtitle,inner){return '<button type="button" class="cf-v9-close" data-v9-action="close" aria-label="Закрыть">×</button><div class="cf-v9-kicker"><i class="cf-v9-dot"></i>'+kicker+'</div><h2 class="cf-v9-title">'+title+'</h2><p class="cf-v9-subtitle">'+subtitle+'</p>'+inner;}
function cfV9Show(kind,mt,force){var root=cfV9Root();if(!mt)return;var me=cfOnlineAccount&&cfOnlineAccount.id;var accepted=Array.isArray(mt.accepted_by)?mt.accepted_by:[];var content='';
  if(kind==='found'){
    var already=me&&accepted.indexOf(me)>=0;
    if(already&&!force){cfV9Close();return;}
    var remaining=Math.max(0,Math.ceil((Date.parse(mt.expires_at||Date.now())-(Date.now()+(cfLobbyMatch.serverOffset||0)))/1000));
    content=cfV9Shell('MATCH FOUND','Матч найден','Подтверди участие в течение 15 секунд. Друзья из твоего лобби останутся в одной команде.',cfV9Map(mt)+cfV9Roster(mt,false)+'<div class="cf-v9-progress"><span>Приняли матч: <b>'+Number(mt.accepted_count||0)+' / '+Number(mt.total_count||0)+'</b></span><strong class="cf-v9-clock" id="cfV9Countdown">'+fmtTime(remaining)+'</strong></div>'+(already?'<p class="cf-v9-hint">✓ Ты уже принял матч. Ожидаем остальных игроков.</p>':'<div class="cf-v9-actions"><button type="button" class="cf-v9-btn primary" data-v9-action="accept">✓ Принять матч</button><button type="button" class="cf-v9-btn danger" data-v9-action="decline">✕ Отклонить</button></div>'));
  } else if(kind==='host'){
    content=cfV9Shell('ALL PLAYERS READY','Кто выдаст комнату?','Выберите, кто создаст комнату на 16 раундов и опубликует единый код для всех игроков.',cfV9Map(mt)+cfV9Roster(mt,false)+'<div class="cf-v9-choice-grid"><button type="button" class="cf-v9-choice" data-v9-action="host-player"><span class="symbol">⚡</span><strong>Игрок создаст комнату</strong><small>Сервер выберет участника матча организатором. Администратор не настраивает комнату.</small></button></div><p class="cf-v9-hint">Первый подтверждённый выбор фиксируется на сервере и применяется ко всем участникам.</p>');
  } else if(kind==='host-selected'){
    var isHost=!!(me&&me===mt.room_host_id);
    var inner=cfV9Map(mt)+cfV9Roster(mt,false)+'<div class="cf-v9-admin-proof"><b>Организатор комнаты</b><p class="cf-v9-hint">'+esc(mt.room_host_nickname||'Выбранный игрок')+(isHost?' — это ты. Введи код созданной комнаты, чтобы он появился у всех участников.':' назначен сервером случайным образом. Ожидаем, когда он опубликует код.')+'</p></div>';
    if(isHost)inner+='<label class="cf-v9-hint" for="cfV9RoomCode">Код комнаты</label><input id="cfV9RoomCode" class="cf-v9-field" maxlength="64" placeholder="Вставь код комнаты"><div class="cf-v9-actions"><button type="button" class="cf-v9-btn primary wide" data-v9-action="publish-player-code">Опубликовать код для всех</button></div>';
    content=cfV9Shell('ROOM HOST SELECTED','Организатор выбран',isHost?'Создай комнату на 16 раундов и опубликуй код.':'Игрок-организатор получил возможность выдать код комнаты.',inner);
  } else if(kind==='results'){
    cfV9State.resultsShownFor=mt.id;
    content=cfV9Shell('MATCH REPORT','Отправь итоги матча','Прикрепи скриншот итоговой таблицы (PNG, JPG или WebP; исходник до 20 МБ). ИИ предложит счёт (синие — КТ, оранжевые — Т); администратор проверит скриншот и подтвердит результат. ELO начисляется по среднему рейтингу команд.',cfV9Map(mt)+cfV9Roster(mt,false)+'<form id="cfV9ResultForm"><label class="cf-proof" for="cfProofFile"><input id="cfProofFile" type="file" accept="image/*" aria-label="Выбрать скриншот итоговой таблицы"><span class="cf-proof-ph" id="cfProofPh"><b>Выбрать скриншот</b><small>PNG, JPG или WebP; до 20 МБ</small></span><img id="cfProofPrev" alt="" hidden></label><p class="cf-v9-hint" id="cfProofStatus">Файл не выбран</p><div class="cf-v9-actions"><button class="cf-v9-btn primary" type="submit">Отправить результат</button><button class="cf-v9-btn" type="button" data-v9-action="close-results">Позже</button></div></form>');
  }
  if(!content)return;root.innerHTML='<div class="cf-v9-backdrop" data-v9-action="backdrop"></div><section class="cf-v9-dialog" tabindex="-1">'+content+'</section>';root.hidden=false;document.body.style.overflow='hidden';cfV9State.openKind=kind;cfV9State.openMatchId=mt.id;
  var dialog=root.querySelector('.cf-v9-dialog');if(dialog)dialog.focus({preventScroll:true});
}
function cfV9Close(){var root=document.getElementById('cfV9Layer');if(root){root.hidden=true;root.innerHTML='';}document.body.style.overflow='';cfV9State.openKind='';cfV9State.openMatchId=null;}
function cfV9SyncOverlay(mt,queue){if(!mt){if(cfV9State.openKind&&cfV9State.openKind!=='results')cfV9Close();return;}
  if(mt.status==='found'){var me=cfOnlineAccount&&cfOnlineAccount.id,accepted=Array.isArray(mt.accepted_by)?mt.accepted_by:[];if(me&&accepted.indexOf(me)>=0){if(cfV9State.openMatchId===mt.id&&cfV9State.openKind==='found')cfV9Close();return;}if(cfV9State.openKind!=='found'||cfV9State.openMatchId!==mt.id)cfV9Show('found',mt);return;}
  if(mt.status==='choose_host'){if(cfV9State.openKind!=='host'||cfV9State.openMatchId!==mt.id)cfV9Show('host',mt);return;}
  if(mt.status==='host_selected'){if(cfV9State.openKind!=='host-selected'||cfV9State.openMatchId!==mt.id)cfV9Show('host-selected',mt);return;}
  if(mt.status==='live'){if(cfMatchEnded(mt)){if(cfV9State.resultsShownFor!==mt.id&&cfV9State.openKind!=='results'){cfV9Show('results',mt);}}else if(cfV9State.openMatchId===mt.id&&cfV9State.openKind&&cfV9State.openKind!=='results')cfV9Close();return;}
  if(['room','joined','result_pending','done','cancelled','taken','pending_admin'].indexOf(mt.status)>=0&&cfV9State.openMatchId===mt.id&&cfV9State.openKind!=='results')cfV9Close();
}
async function cfLobbyMatchPoll(){if(!cfSupabaseClient||!cfOnlineAccount||document.hidden)return;try{var st=await cfLobbyMatchRpc('cf_lobby_match_state');var oldState=cfLobbyMatch.data||{},old=oldState.match,oldQueue=oldState.queue;var mt=st.match||null;if(old&&mt&&old.id===mt.id&&old.status!=='live'&&mt.status==='live'){toast('Матч начался! Код комнаты: '+(mt.room_code||'—'),'success');cfLobbyMatch.endedFor=null;}if(oldQueue&&!st.queue&&!mt)toast('Очередь была сброшена: истекло время ожидания или изменился состав лобби. Встань в очередь снова.','error');cfLobbyMatch.data=st;cfSyncSearchSound();if(old&&mt&&old.id===mt.id&&old.status!=='done'&&mt.status==='done')cfRefreshMe(true);cfApplyServerPlayCooldown(st);var sig=cfLobbyMatchSignature(mt,st.queue);if(sig!==cfLobbyMatch.signature){cfLobbyMatch.signature=sig;renderLobbyMatch();if(curSec==='play')renderPlay();if(mt&&mt.status!=='cancelled'&&(!old||old.id!==mt.id)){if(cfLobbyMatch.lastMatchId!==mt.id){cfLobbyMatch.lastMatchId=mt.id;if(curSec!=='play')navigate('play',{instant:true});cfPingSound();}}}cfV9SyncOverlay(mt,st.queue);}catch(e){if(e&&/function .* does not exist|Could not find the function/i.test(e.message||'')){var b=$('#lobbyMatchBox');if(b&&!b.dataset.sqlHint){b.dataset.sqlHint='1';b.innerHTML='<p class="small muted">Обновление v9 не установлено. Запусти CF_FACEIT_V9_MATCHMAKING_RESULTS.sql в Supabase после SQL v8.</p>';}}}}
function cfMatchNow(){return Date.now()+(cfLobbyMatch.serverOffset||0);}
var CF_MATCH_DURATION_MS=15*60*1000;
function cfMatchStartTime(mt){var started=Date.parse(mt&&(mt.live_started_at||mt.updated_at));if(Number.isFinite(started))return started;var ending=Date.parse(mt&&mt.play_ends_at);if(Number.isFinite(ending))return ending-CF_MATCH_DURATION_MS;var key='cf-faceit-live-start-'+(mt&&mt.id||'unknown');try{var saved=Number(localStorage.getItem(key));if(saved>0)return saved;saved=cfMatchNow();localStorage.setItem(key,String(saved));return saved;}catch(e){return cfMatchNow();}}
function cfMatchEndTime(mt){var ending=Date.parse(mt&&mt.play_ends_at);return Number.isFinite(ending)?ending:cfMatchStartTime(mt)+CF_MATCH_DURATION_MS;}
function cfMatchEnded(mt){return !!(mt&&mt.status==='live'&&cfMatchEndTime(mt)<=cfMatchNow());}
function cfMatchStepIdx(mt){var s=mt.status;if(s==='found')return 0;if(s==='choose_host')return 1;if(s==='host_selected'||s==='pending_admin'||s==='taken')return 2;if(s==='room'||s==='joined')return 3;if(s==='live')return cfMatchEnded(mt)?5:4;if(s==='result_pending')return 5;if(s==='done')return 6;return 0;}
function cfMatchSteps(mt){if(mt.status==='cancelled')return '';var idx=cfMatchStepIdx(mt),n=['Найден','Принят','Хост','Комната','Идёт матч','Итоги'];return '<ol class="cf-steps">'+n.map(function(t,i){return '<li class="'+(i<idx?'done':i===idx?'cur':'')+'"><i>'+(i<idx?'✓':(i+1))+'</i><span>'+t+'</span></li>';}).join('')+'</ol>';}
function cfLiveBlock(mt){var ended=cfMatchEnded(mt),now=cfMatchNow(),st=cfMatchStartTime(mt),en=cfMatchEndTime(mt);var left=Math.max(0,Math.ceil((en-now)/1000)),pct=Math.max(0,Math.min(100,(now-st)/Math.max(1,en-st)*100));return '<div class="cf-live"><div class="cf-live-top"><div><small>'+(ended?'Матч завершён':'Идёт матч · осталось')+'</small><b class="cf-live-clock" id="cfLiveClock">'+(ended?'00:00':fmtTime(left))+'</b></div><div class="cf-live-code"><small>Код комнаты</small><b>'+esc(mt.room_code||'—')+'</b></div></div><div class="cf-live-bar"><i id="cfLiveBar" style="width:'+(ended?100:pct)+'%"></i></div></div>';}
function cfLobbyMatchHTML(){var state=cfLobbyMatch.data||{},mt=state.match,queue=state.queue;var body='';if(!mt&&queue){body='<div class="cf-v9-queue"><div class="cf-v9-queue-orb"></div><div class="cf-v9-queue-copy"><strong>Ищем матч '+(queue.mode==='duo'?'2×2':'5×5')+'…</strong><small>Твоя группа из '+Number(queue.party_count||1)+' игрока не будет разделена. В очереди групп: '+Number(queue.waiting_parties||1)+'.</small></div></div><div class="btn-row"><button class="btn danger" type="button" data-lobby-match="cancel">Отменить поиск</button></div>';return '';}
  if(!mt)return '';var status=mt.status,labels=CF_MATCH_STATUSES,mapImg=MAP_IMAGES[mt.map_name]||MAP_IMAGES.Mirage;var accepted=Array.isArray(mt.accepted_by)?mt.accepted_by:[],meId=cfOnlineAccount&&cfOnlineAccount.id;var body='';
  if(status==='found')body='<div class="cf-v9-map"><img src="'+esc(mapImg)+'" alt="Карта"><div><b>'+esc(mt.map_name)+'</b><span class="small muted">'+(mt.mode==='duo'?'2×2':'5×5')+' · до 16 раундов · '+Number(mt.total_count||0)+' игроков</span></div></div>'+cfV9Roster(mt,true)+'<p class="small muted">Принято '+Number(mt.accepted_count||0)+' из '+Number(mt.total_count||0)+'. Окно подтверждения синхронизировано с сервером.</p>'+(meId&&accepted.indexOf(meId)>=0?'<p class="small muted" role="status">✓ Ты уже принял матч.</p>':'<div class="btn-row" style="margin-top:10px"><button class="btn primary" type="button" data-lobby-match="accept">✓ Принять матч</button><button class="btn danger" type="button" data-lobby-match="decline">Отклонить</button></div>');
  else if(status==='choose_host')body='<p class="small muted">Все '+Number(mt.total_count||0)+' игроков приняли матч. Выберите, кто выдаст комнату на 16 раундов.</p>'+cfV9Roster(mt,true)+'<button class="btn primary" type="button" data-v9-force="host">Выбрать организатора</button>';
  else if(status==='host_selected')body='<p class="small muted">Комнату выдаёт игрок <b>'+esc(mt.room_host_nickname||'Организатор')+'</b>.</p>'+(meId===mt.room_host_id?'<p class="small muted">Заполни код в окне организатора.</p>':'')+cfV9Roster(mt,true);
  else if(status==='pending_admin')body='<p class="small muted">Все приняли матч. Он появился в очереди администраторов.</p>'+cfV9Roster(mt,true);
  else if(status==='taken')body='<p class="small muted">Матч ведёт администратор <b>'+esc(mt.admin_nickname||'администратор')+'</b>. Ожидай код комнаты.</p>'+cfV9Roster(mt,true);
  else if(status==='room')body='<div class="code-box">'+esc(mt.room_code)+'</div><p class="small muted">Код комнаты опубликовал '+esc(mt.room_host_nickname||'организатор')+'. Комната рассчитана на 16 раундов.</p><div class="btn-row"><button class="btn" type="button" data-lobby-match="copy">Скопировать код</button>'+(meId===mt.room_host_id?'<button class="btn primary" type="button" data-v9-action="player-start">Все вошли — начать матч</button>':'<span class="small muted">Ожидаем начала от игрока-организатора</span>')+'</div>'+cfV9Roster(mt,true);
  else if(status==='joined')body='<p class="small muted">Организатор подтвердил, что все игроки зашли в комнату.</p>'+cfV9Roster(mt,true);
  else if(status==='live'){var endedL=cfMatchEnded(mt);body=cfLiveBlock(mt)+(endedL?'<p class="small muted">Таймер истёк. Прикрепи скриншот итоговой таблицы — он будет отправлен на проверку.</p>':'<p class="small muted">Матч идёт 15 минут. По окончании таймера откроется форма для скриншота результата.</p>')+'<div class="btn-row"><button class="btn" type="button" data-lobby-match="copy">Скопировать код</button>'+(endedL?'<button class="btn primary" type="button" data-v9-force="results">Прикрепить скриншот и отправить итоги</button>':'')+'</div>'+cfV9Roster(mt,true);}
  else if(status==='result_pending')body='<p class="small muted">Скриншот отправлен на проверку. Администратор выберет победившую команду.</p>'+(mt.result_screenshot_url?'<p class="small"><a href="'+esc(mt.result_screenshot_url)+'" target="_blank" rel="noopener noreferrer">Открыть отправленное доказательство</a></p>':'')+cfV9Roster(mt,true);
  else if(status==='done')body='<p class="small muted">Результат подтверждён: '+esc(cfTeamLabel(mt.winner_team))+' победили'+(mt.result_score?' со счётом '+esc(mt.result_score):'')+'. ELO обновлён администратором.</p>';
  else body='<p class="small muted">'+esc(mt.cancel_reason||'Матч отменён')+'</p>';
  var showCancel=['searching','found','choose_host','host_selected','pending_admin','taken','room','joined'].indexOf(status)>=0;
  return '<section class="cf-match-shared"><div class="cf-match-title"><h3>🎮 Матч · '+(mt.mode==='duo'?'2×2':'5×5')+' · '+esc(mt.map_name)+'</h3><span class="chip accent">'+esc((status==='live'&&cfMatchEnded(mt))?'Время вышло':(labels[status]||status))+'</span></div>'+cfMatchSteps(mt)+body+(showCancel?'<div class="btn-row" style="margin-top:8px"><button class="btn danger" type="button" data-lobby-match="cancel">Отменить матч</button></div>':'')+'</section>';
}
function renderLobbyMatch(){var html=cfLobbyMatchHTML(),b=$('#lobbyMatchBox'),playBox=$('#cfSharedMatchPlay');if(b)b.innerHTML=html;if(playBox)playBox.innerHTML=html;cfLobbyMatchTick();var state=cfLobbyMatch.data||{};cfV9SyncOverlay(state.match||null,state.queue||null);}
function cfLobbyMatchTick(){var state=cfLobbyMatch.data||{},mt=state.match,el=$('#cfLobbyMatchClock');if(mt&&el){var now=Date.now()+(cfLobbyMatch.serverOffset||0),sec=0;if(mt.status==='searching')sec=Math.max(0,Math.floor((now-Date.parse(mt.started_at))/1000));else if(mt.status==='found')sec=Math.max(0,Math.ceil((Date.parse(mt.expires_at)-now)/1000));el.textContent=fmtTime(sec);}var lc=$('#cfLiveClock');if(mt&&lc&&mt.status==='live'){var nowL=cfMatchNow(),enL=cfMatchEndTime(mt),stL=cfMatchStartTime(mt);lc.textContent=fmtTime(Math.max(0,Math.ceil((enL-nowL)/1000)));var lb=$('#cfLiveBar');if(lb)lb.style.width=Math.max(0,Math.min(100,(nowL-stL)/Math.max(1,enL-stL)*100))+'%';if(cfMatchEnded(mt)&&cfLobbyMatch.endedFor!==mt.id){cfLobbyMatch.endedFor=mt.id;renderLobbyMatch();}}var qc=$('#cfQueueClock');if(state.queue&&qc){qc.textContent=fmtTime(Math.max(0,Math.floor((cfMatchNow()-Date.parse(state.queue.queued_at))/1000)));}var c=$('#cfV9Countdown');if(mt&&c&&mt.status==='found'){var now2=Date.now()+(cfLobbyMatch.serverOffset||0);c.textContent=fmtTime(Math.max(0,Math.ceil((Date.parse(mt.expires_at)-now2)/1000)));}}
if(!cfLobbyMatch.timer)cfLobbyMatch.timer=setInterval(cfLobbyMatchTick,250);
async function cfStartLobbyMatch(){if(cfPlayCooldownRemainingSeconds()>0){toast(cfPlayCooldownMessage(),'error');cfUpdatePlayCooldownUI();return;}if(cfLobbyMatch.busy)return;if(!cfSupabaseClient||!cfOnlineAccount){toast('Нужно войти в онлайн-аккаунт','error');return;}cfSearchStartPending=true;cfStartSearchSound();cfLobbyMatch.busy=true;try{var map=(play.pickMap&&play.pickMap!=='any'&&MAPS.indexOf(play.pickMap)>=0)?play.pickMap:pick(MAPS);var st=await cfLobbyMatchRpc('cf_lobby_match_start',{p_mode:play.mode,p_map:map});cfLobbyMatch.data=st;cfSearchStartPending=false;cfSyncSearchSound();cfLobbyMatch.signature=cfLobbyMatchSignature(st.match,st.queue);if(st.match)cfLobbyMatch.lastMatchId=st.match.id;renderLobbyMatch();if(curSec==='play')renderPlay();if(st.match)toast('Матч найден или состояние матча обновлено','success');else toast('Ты в очереди. Друзья останутся вместе; ждём подходящие группы.','success');}catch(e){cfSearchStartPending=false;cfSyncSearchSound();toast(e.message||'Не удалось встать в очередь. Проверь SQL обновления v9.','error');}finally{cfLobbyMatch.busy=false;}}
async function cfLobbyMatchAction(action){if(action==='start'){await cfStartLobbyMatch();return;}if(cfLobbyMatch.busy)return;cfLobbyMatch.busy=true;try{var st;if(action==='accept')st=await cfLobbyMatchRpc('cf_lobby_match_respond',{p_accept:true});else if(action==='decline')st=await cfLobbyMatchRpc('cf_lobby_match_respond',{p_accept:false});else if(action==='cancel')st=await cfLobbyMatchRpc('cf_lobby_match_cancel');else if(action==='copy'){var mt=cfLobbyMatch.data&&cfLobbyMatch.data.match;if(!mt||!mt.room_code)return;if(navigator.clipboard&&navigator.clipboard.writeText)await navigator.clipboard.writeText(mt.room_code);else{toast('Код комнаты: '+mt.room_code);return;}toast('Код скопирован','success');return;}else return;cfLobbyMatch.data=st;cfSyncSearchSound();cfLobbyMatch.signature=cfLobbyMatchSignature(st.match,st.queue);renderLobbyMatch();if(curSec==='play')renderPlay();if(action==='accept')toast('Ты принял матч. Ожидаем остальные подтверждения.','success');if(action==='decline'||action==='cancel')toast('Матч или поиск отменён','error');}catch(e){toast(e.message||'Не удалось обновить матч','error');}finally{cfLobbyMatch.busy=false;}}
document.addEventListener('click',function(e){var b=e.target.closest&&e.target.closest('[data-lobby-match]');if(b)cfLobbyMatchAction(b.dataset.lobbyMatch);});
async function cfV9Action(action){if(cfV9State.modalBusy)return;var mt=cfLobbyMatch.data&&cfLobbyMatch.data.match;if(!mt)return;if(action==='close'||action==='backdrop'){if(cfV9State.openKind==='results')cfV9State.resultsShownFor=mt.id;cfV9Close();return;}if(action==='close-results'){cfV9State.resultsShownFor=mt.id;cfV9Close();return;}if(action==='results'){cfV9Show('results',mt,true);return;}if(action==='host'){cfV9Show('host',mt,true);return;}if(action==='accept'||action==='decline'){cfV9Close();await cfLobbyMatchAction(action);return;}cfV9State.modalBusy=true;try{var st;if(action==='host-player'){st=await cfLobbyMatchRpc('cf_lobby_match_choose_host',{p_choice:'player'});}else if(action==='publish-player-code'){var code=$('#cfV9RoomCode');if(!code||!code.value.trim()){toast('Введи код комнаты','error');return;}st=await cfLobbyMatchRpc('cf_lobby_match_player_publish_code',{p_code:code.value.trim()});}else if(action==='player-start'){if(!confirm('Все игроки уже вошли в комнату? После подтверждения начнётся таймер матча.'))return;st=await cfLobbyMatchRpc('cf_lobby_match_player_start');}else return;cfLobbyMatch.data=st;cfLobbyMatch.signature=cfLobbyMatchSignature(st.match,st.queue);renderLobbyMatch();if(curSec==='play')renderPlay();toast(action==='host-player'?'Игрок-организатор выбран сервером':action==='player-start'?'Матч начат игроком-организатором':'Код комнаты опубликован для всех','success');}catch(e){toast(e.message||'Не удалось выполнить действие','error');}finally{cfV9State.modalBusy=false;}}
document.addEventListener('click',function(e){var b=e.target.closest&&e.target.closest('[data-v9-action]');if(b){e.preventDefault();var act=b.dataset.v9Action;if(act==='backdrop'&&cfV9State.openKind==='results')return;cfV9Action(act);return;}var f=e.target.closest&&e.target.closest('[data-v9-force]');if(f){cfV9Action(f.dataset.v9Force);return;}});
document.addEventListener('keydown',function(e){if(e.key==='Escape'&&cfV9State.openKind&&cfV9State.openKind!=='found'&&cfV9State.openKind!=='host')cfV9Close();});
var cfProof={file:null};
document.addEventListener('change',function(e){var t=e.target;if(!t||t.id!=='cfProofFile')return;var f=t.files&&t.files[0];var pv=$('#cfProofPrev'),ph=$('#cfProofPh'),st=$('#cfProofStatus');if(!f){cfProof.file=null;if(pv)pv.hidden=true;if(ph)ph.hidden=false;if(st)st.textContent='Файл не выбран';return;}if(!/^image\//.test(f.type)||f.size>20*1024*1024){toast(f.size>20*1024*1024?'Скриншот должен быть меньше 20 МБ':'Нужен файл изображения','error');t.value='';cfProof.file=null;if(pv)pv.hidden=true;if(ph)ph.hidden=false;if(st)st.textContent='Файл не выбран';return;}cfProof.file=f;if(pv){pv.src=URL.createObjectURL(f);pv.hidden=false;}if(ph)ph.hidden=true;if(st)st.textContent='Выбрано: '+f.name;});
function cfLoadScript(src){return new Promise(function(res,rej){var s=document.createElement('script');s.src=src;s.onload=res;s.onerror=function(){rej(new Error('load'));};document.head.appendChild(s);});}
function cfFileToCanvas(file,maxW){return new Promise(function(res,rej){var u=URL.createObjectURL(file),im=new Image();im.onload=function(){var k=Math.min(1,maxW/im.width),c=document.createElement('canvas');c.width=Math.max(1,Math.round(im.width*k));c.height=Math.max(1,Math.round(im.height*k));c.getContext('2d').drawImage(im,0,0,c.width,c.height);URL.revokeObjectURL(u);res(c);};im.onerror=function(){URL.revokeObjectURL(u);rej(new Error('img'));};im.src=u;});}
async function cfCallAi(matchId){try{var r=await cfSupabaseClient.functions.invoke('cf-score-ai',{body:{match_id:matchId}});if(r&&r.error)return {error:r.error.message||'Функция проверки недоступна'};if(r&&r.data&&r.data.error)return {error:r.data.error};return r&&r.data?r.data:{error:'Функция проверки не вернула ответ'};}catch(e){return {error:e&&e.message?e.message:'Не удалось вызвать проверку скриншота'};}}
async function cfUploadProof(file,matchId){var c=await cfFileToCanvas(file,1600),blob=await new Promise(function(r){c.toBlob(r,'image/jpeg',0.85);});if(!blob)throw new Error('Не удалось обработать картинку');if(blob.size>5*1024*1024)blob=await new Promise(function(r){c.toBlob(r,'image/jpeg',0.65);});if(!blob||blob.size>5*1024*1024)throw new Error('Не удалось сжать скриншот до 5 МБ');var path=cfOnlineAccount.id+'/'+matchId+'-'+Date.now()+'.jpg',up=await cfSupabaseClient.storage.from('match-proofs').upload(path,blob,{contentType:'image/jpeg',upsert:false});if(up.error)throw new Error('Не удалось загрузить скриншот: '+up.error.message+'. Выполни SQL/35_match_timer_and_screenshot_fix.sql в Supabase.');return cfSupabaseClient.storage.from('match-proofs').getPublicUrl(path).data.publicUrl;}
document.addEventListener('submit',async function(e){if(!e.target||e.target.id!=='cfV9ResultForm')return;e.preventDefault();if(cfV9State.modalBusy)return;var mt=cfLobbyMatch.data&&cfLobbyMatch.data.match;if(!mt)return;if(!cfProof.file){toast('Прикрепи скриншот','error');return;}cfV9State.modalBusy=true;var submit=e.target.querySelector('[type="submit"]'),st=$('#cfProofStatus');if(submit)submit.disabled=true;try{if(st)st.textContent='Загружаю скриншот…';var url=await cfUploadProof(cfProof.file,mt.id);var r=await cfLobbyMatchRpc('cf_lobby_match_submit_result',{p_match:mt.id,p_screenshot_url:url,p_score:''});cfProof.file=null;if(st)st.textContent='Нейросеть проверяет скриншот…';var ai=await cfCallAi(mt.id);cfLobbyMatch.data=r;cfLobbyMatch.signature=cfLobbyMatchSignature(r.match,r.queue);cfV9Close();renderLobbyMatch();if(ai&&ai.ct!=null){toast('ИИ предлагает счёт '+ai.ct+':'+ai.t+' (КТ:Т). Администратор проверит скриншот; ELO изменится только после подтверждения.','success');}else if(ai&&ai.error){toast('Скриншот сохранён, но ИИ не ответил. Результат отправлен администратору; проверь Edge Function cf-score-ai и ключ AI-провайдера.','error');}else{toast('Скриншот принят и отправлен на проверку администратору','success');}}catch(err){toast(err.message||'Не удалось отправить результат','error');if(st)st.textContent='Ошибка. Попробуй ещё раз';if(submit)submit.disabled=false;}finally{cfV9State.modalBusy=false;}});
setInterval(cfLobbyMatchPoll,2500);

function cfNames(arr){return (arr||[]).map(function(p){var player={role:p.role,founder:p.role==='founder',verified:p.verified,elo:p.elo,sponsor_badge:p.sponsor_badge,sponsor_nickname_style:p.sponsor_nickname_style};return '<li class="cf-admin-player">'+avatar(p.avatar||'ember',p.display_name||p.nickname||'Игрок',26,p.avatar_frame)+'<span class="'+cfNickStyleClass(player)+'">'+esc(p.nickname||p.display_name||'Игрок')+vbadge(player)+'</span></li>';}).join('')||'<li class="muted">—</li>';}
function cfRenderOnlineAdminMatches(force){
  var box=$('#cfOnlineAdminMatches');if(!box)return;
  var all=cfOnlineAdminMatches||[],pending=all.filter(function(m){return m.status==='result_pending';}),done=all.filter(function(m){return m.status==='done'||m.status==='cancelled';}),active=all.filter(function(m){return m.status!=='result_pending'&&m.status!=='done'&&m.status!=='cancelled';});
  var st=$('#admStats');if(st)st.innerHTML='<div class="adm-stat'+(pending.length?' hot':'')+'"><b>'+pending.length+'</b><span>На проверке</span></div><div class="adm-stat"><b>'+active.length+'</b><span>Идут сейчас</span></div><div class="adm-stat"><b>'+done.length+'</b><span>Закрыто (7 дн.)</span></div>';
  var tb=$('#admTabMatchesCount');if(tb)tb.textContent=pending.length?String(pending.length):'';
  if(!all.length){box.innerHTML='<div class="adm-empty">Матчей пока нет. Когда игроки найдут матч, он появится здесь.</div>';return;}
  function head(m){return '<div class="adm-mhead"><div><h3>'+esc(m.mode==='duo'?'2×2':'5×5')+' · '+esc(m.map_name)+'</h3><small>'+esc(fmtClock(m.started_at))+' · игроков '+(m.players||[]).length+'</small></div><span class="chip accent">'+esc(CF_MATCH_STATUSES[m.status]||m.status)+'</span></div>';}
  function teams(m){return '<div class="adm-teams"><div class="adm-team ct"><h4>КТ</h4><ul>'+cfNames(m.team_a)+'</ul></div><div class="adm-team t"><h4>Т</h4><ul>'+cfNames(m.team_b)+'</ul></div></div>';}
  function who(m){var u=(m.players||[]).filter(function(p){return p.id===m.result_submitted_by;})[0];return esc((u&&(u.nickname||u.display_name))||'участник');}
  var html='';
  if(pending.length)html+='<div class="adm-sec">Ждут проверки</div>'+pending.map(function(m){var id=esc(m.id);return '<article class="adm-card review">'+head(m)+'<div class="adm-proof"><div><small>Результат отправил</small><b>'+who(m)+'</b></div><div><small>Счёт</small><b>'+esc(m.result_score||'не указан')+'</b></div></div>'+(m.bot_winner?'<div class="adm-bot"><b>Нейросеть: КТ '+esc(m.bot_ct_score)+' : '+esc(m.bot_t_score)+' Т</b><span>Победа '+(m.bot_winner==='A'?'КТ':'Т')+'. '+(m.ai_note?esc(m.ai_note)+' ':'')+'Сверь со скриншотом и подтверди.</span></div>':'<div class="adm-bot warn"><b>Нейросеть не смогла прочитать счёт</b><span>'+(m.ai_note?esc(m.ai_note)+' ':'')+'Открой скриншот и выбери победителя сам.</span></div>')+(m.result_screenshot_url?'<a class="btn adm-link" href="'+esc(m.result_screenshot_url)+'" target="_blank" rel="noopener noreferrer">Открыть скриншот ↗</a>':'<p class="small muted">Ссылка на скриншот не приложена</p>')+teams(m)+'<input class="input" id="cfLmScore-'+id+'" maxlength="20" placeholder="Итоговый счёт, например 16:12" value="'+esc(m.result_score||'')+'"><div class="adm-win"><button class="btn adm-ct" type="button" data-online-admin="reviewA" data-id="'+id+'">Победа КТ</button><button class="btn adm-t" type="button" data-online-admin="reviewB" data-id="'+id+'">Победа Т</button></div><div class="btn-row" style="margin-top:8px"><button class="btn danger sm" type="button" data-online-admin="cancelResult" data-id="'+id+'">Отменить матч с причиной</button></div><p class="small muted">ELO меняется по среднему рейтингу команд (формула Elo, K=32): победа над более сильной командой приносит больше очков. ИИ только предлагает счёт; начисление происходит один раз после твоего подтверждения.</p></article>';}).join('');
  if(active.length)html+='<div class="adm-sec">Идут сейчас</div>'+active.map(function(m){var me=cfOnlineAccount&&sameNick(m.admin_nickname,cfOnlineAccount.nick),actions='';
    if(m.status==='pending_admin'||m.status==='taken')actions='<span class="small muted">Ожидает выбора игрока-организатора</span>';
    else if(m.status==='room')actions='<span class="small muted">Комнату настраивает игрок: '+esc(m.room_host_nickname||'организатор')+'</span>';
    else if(m.status==='live')actions='<span class="chip">Матч идёт'+(m.room_code?' · код '+esc(m.room_code):'')+'</span>';
    else if(m.admin_nickname)actions='<span class="small muted">Организатор: '+esc(m.admin_nickname)+'</span>';
    var cancel=['searching','found','choose_host','host_selected','pending_admin','taken','room','joined','live'].indexOf(m.status)>=0?'<button class="btn danger sm" type="button" data-online-admin="cancel" data-id="'+esc(m.id)+'">Отменить</button>':'';
    return '<article class="adm-card">'+head(m)+teams(m)+'<div class="btn-row">'+actions+cancel+'</div></article>';}).join('');
  if(done.length)html+='<div class="adm-sec">Закрытые</div>'+done.map(function(m){return '<article class="adm-card done">'+head(m)+'<p class="small muted">'+(m.status==='done'?'Победа '+esc(cfTeamLabel(m.winner_team))+(m.result_score?' · '+esc(m.result_score):'')+(m.result_auto?' · принято нейросетью':''):esc(m.cancel_reason||'Отменён'))+'</p></article>';}).join('');
  box.innerHTML=html;
}
async function cfLoadOnlineAdminMatches(silent) {
  if(!cfSupabaseClient||!cfOnlineAccount||!isAdmin(getUser())||cfOnlineAdminLoading)return;
  cfOnlineAdminLoading=true;
  try{
    var r=await cfSupabaseClient.rpc('cf_lobby_match_admin_list');if(r.error)throw r.error;
    var rows=Array.isArray(r.data)?r.data:[];var sig=JSON.stringify(rows.map(function(m){return [m.id,m.status,m.admin_nickname,m.room_code,m.cancel_reason,m.result_screenshot_url,m.result_score,m.winner_team,(m.players||[]).length];}));
    cfOnlineAdminMatches=rows;
    if(sig!==cfOnlineAdminSig){cfOnlineAdminSig=sig;cfRenderOnlineAdminMatches();}
  }catch(e){var b=$('#cfOnlineAdminMatches');if(b&&!silent)b.innerHTML='<p class="small muted">Не удалось загрузить очередь. Проверь CF_FACEIT_V9_MATCHMAKING_RESULTS.sql и роль founder/admin.</p>';}
  finally{cfOnlineAdminLoading=false;}
}
async function cfOnlineAdminAction(action,id,confirmed){
  if(!cfSupabaseClient||!cfOnlineAccount||!isAdmin(getUser())){toast('Недостаточно прав','error');return;}
  if(action==='cancelResult'){
    if(typeof confirmed!=='string'){
      openModal('<h2 id="modalTitle">Отменить матч?</h2>'+
        '<p class="small muted">Матч с отправленным результатом будет отменён. Игрокам придёт сообщение от поддержки с указанной причиной. Рейтинг ELO не изменится.</p>'+
        '<form id="cfAdminCancelResultForm"><div class="field"><label for="cfAdminCancelReason">Причина отмены (обязательно)</label><textarea class="input" id="cfAdminCancelReason" name="reason" rows="4" minlength="5" maxlength="500" required placeholder="Например: скриншот не подтверждает указанный результат"></textarea></div>'+
        '<div class="btn-row"><button class="btn" type="button" data-close>Назад</button><button class="btn danger" type="submit">Отменить матч</button></div></form>',function(root){
          root.querySelector('#cfAdminCancelResultForm').addEventListener('submit',function(event){event.preventDefault();var reason=root.querySelector('#cfAdminCancelReason').value.trim();if(reason.length<5){toast('Напиши причину отмены (минимум 5 символов)','error');return;}closeModal();cfOnlineAdminAction(action,id,reason);});
        });
      return;
    }
    var cancelReason=confirmed.trim();if(cancelReason.length<5||cancelReason.length>500){toast('Причина должна содержать от 5 до 500 символов','error');return;}
    try{
      var cancellation=await cfSupabaseClient.rpc('cf_lobby_match_cancel_review',{p_match:id,p_reason:cancelReason});if(cancellation.error)throw cancellation.error;
      var cancelledMatch=cfOnlineAdminMatches.filter(function(m){return m.id===id;})[0];if(cancelledMatch){cancelledMatch.status='cancelled';cancelledMatch.cancel_reason=(cancellation.data&&cancellation.data.cancel_reason)||cancelReason;cfOnlineAdminSig='';cfRenderOnlineAdminMatches();}
      await cfLoadOnlineAdminMatches(false);cfLobbyMatchPoll();
      toast(cancellation.data&&cancellation.data.already_cancelled?'Матч уже отменён; повторное сообщение не отправлено':'Матч отменён, игрокам написала поддержка','success');
    }catch(cancelError){toast(cancelError.message||'Не удалось отменить матч','error');}
    return;
  }
  if(action==='reviewA'||action==='reviewB'){
    if(!confirmed){var lbl=action==='reviewA'?'КТ':'Т';openModal('<h2 id="modalTitle">Подтвердить победу '+lbl+'?</h2><p>Подтверди счёт по скриншоту. ELO рассчитает сервер по среднему рейтингу команд (формула Elo, K=32); ИИ только подсказывает счёт. Начисление выполняется один раз, отменить его нельзя.</p><div class="btn-row"><button class="btn" type="button" data-close>Отмена</button><button class="btn primary" type="button" id="admConfirm">Да, победа '+lbl+'</button></div>',function(root){$('#admConfirm',root).addEventListener('click',function(){closeModal();cfOnlineAdminAction(action,id,true);});});return;}
    var scoreEl=$('#cfLmScore-'+id),score=scoreEl?scoreEl.value.trim():'';
    try{var rr=await cfSupabaseClient.rpc('cf_lobby_match_review_result',{p_match:id,p_winner:action==='reviewA'?'A':'B',p_score:score||null});if(rr.error)throw rr.error;cfOnlineAdminMatches=Array.isArray(rr.data)?rr.data:[];cfOnlineAdminSig='';cfRenderOnlineAdminMatches();cfLobbyMatchPoll();toast('Результат подтверждён, ELO обновлён','success');}
    catch(er){toast(er.message||'Не удалось подтвердить результат','error');}return;
  }
  var code='';if(action==='publish'){var i=$('#cfLmCode-'+id);code=i?i.value.trim():'';if(!code){toast('Введи код комнаты','error');return;}}
  try{var r=await cfSupabaseClient.rpc('cf_lobby_match_admin_action',{p_match:id,p_action:action,p_code:code||null});if(r.error)throw r.error;
    if(Array.isArray(r.data)){cfOnlineAdminMatches=r.data;}
    else if(r.data&&r.data.ok){var updated=cfOnlineAdminMatches.filter(function(m){return m.id===id;})[0];if(updated){updated.status=r.data.status||updated.status;updated.admin_nickname=r.data.admin_nickname||updated.admin_nickname;updated.room_code=r.data.room_code||updated.room_code;updated.cancel_reason=r.data.cancel_reason||updated.cancel_reason;}}
    cfOnlineAdminSig='';cfRenderOnlineAdminMatches();cfLoadOnlineAdminMatches(true);toast(action==='take'?'Ты взял общий матч':action==='publish'?'Код комнаты опубликован':action==='cancel'?'Матч отменён':'Статус матча обновлён','success');cfLobbyMatchPoll();}
  catch(e){toast(e.message||'Не удалось выполнить действие','error');}
}
document.addEventListener('click',function(e){var b=e.target.closest&&e.target.closest('[data-online-admin]');if(b)cfOnlineAdminAction(b.dataset.onlineAdmin,b.dataset.id);});
setInterval(function(){if(curSec==='admin'&&!document.hidden)cfLoadOnlineAdminMatches(true);},4000);


/* =========================================================
   Chats: lobby chat + global chat (cf_chat_state / cf_chat_send)
   ========================================================= */
var cfChat = { lobby: { msgs: [], sig: '' }, global: { msgs: [], sig: '' }, busy: {}, polling: false };
var CF_ROLE_LABEL = { founder: 'Основатель', admin: 'Админ', tester: 'Тестер', cooperation: 'Сотрудничество' };
function cfChatTime(iso) { try { return new Date(iso).toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' }); } catch (e) { return ''; } }
function cfChatBox(scope) { return document.getElementById(scope === 'global' ? 'cfGlobalChatMsgs' : 'cfLobbyChatMsgs'); }
function cfChatMsgHTML(m) {
  var role = CF_ROLE_LABEL[m.role] ? '<span class="chip' + (m.role === 'founder' ? ' founder' : (m.role === 'cooperation' ? ' cooperation' : ' gold')) + '" style="padding:1px 7px;font-size:10px">' + CF_ROLE_LABEL[m.role] + '</span>' : '';
  return '<div class="cf-chat-msg">' + avatar(m.avatar, m.display_name, 30, m.avatar_frame) + '<div class="bubble"><div class="cf-chat-meta">' +
    '<button type="button" class="cf-chat-name '+cfNickStyleClass(m)+'" data-player="' + esc(m.user_id) + '">' + esc(m.display_name || m.nickname) + '</button>' +
    vbadge({ founder: m.role === 'founder', role:m.role, verified: m.verified, sponsor_badge:m.sponsor_badge, sponsor_nickname_style:m.sponsor_nickname_style }) + '<span>' + esc(cfChatTime(m.created_at)) + '</span></div>' + esc(m.body) + '</div></div>';
}
function cfChatRender(scope) {
  var box = cfChatBox(scope); if (!box) return;
  var msgs = cfChat[scope].msgs || [];
  var wasNew = !box.dataset.ready;
  var nearBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 70;
  box.innerHTML = msgs.length ? msgs.map(cfChatMsgHTML).join('') : '<p class="cf-chat-empty">Сообщений пока нет. Напиши первым.</p>';
  box.dataset.ready = '1'; box.dataset.sig = cfChat[scope].sig;
  if (wasNew || nearBottom) box.scrollTop = box.scrollHeight;
}
function cfChatApply(scope, data) {
  var msgs = (data && data.messages) || [];
  var sig = msgs.length + ':' + (msgs.length ? msgs[msgs.length - 1].id : '');
  cfChat[scope].msgs = msgs; cfChat[scope].sig = sig;
  var box = cfChatBox(scope);
  if (box && box.dataset.sig !== sig) cfChatRender(scope);
}
async function cfChatFetch(scope, lobbyId) {
  try {
    var r = await cfSupabaseClient.rpc('cf_chat_state', { p_scope: scope, p_lobby_id: lobbyId });
    if (r.error) throw r.error;
    cfChatApply(scope, r.data);
  } catch (e) {
    var box = cfChatBox(scope);
    if (box && !cfChat[scope].msgs.length) box.innerHTML = '<p class="cf-chat-empty">Чат временно недоступен.</p>';
  }
}
async function cfChatPoll() {
  if (!cfSupabaseClient || !cfOnlineAccount || document.hidden || cfChat.polling) return;
  var jobs = [], L = lobby.state && lobby.state.lobby;
  if (L && cfChatBox('lobby')) jobs.push(cfChatFetch('lobby', L.id));
  if (cfChatBox('global')) jobs.push(cfChatFetch('global', null));
  if (!jobs.length) return;
  cfChat.polling = true;
  try { await Promise.all(jobs); } finally { cfChat.polling = false; }
}
function lobbyChatHTML() {
  return '<section class="cf-chat" aria-label="Чат лобби"><h3>Чат лобби</h3><div class="cf-chat-messages" id="cfLobbyChatMsgs" aria-live="polite"></div>' +
    '<form class="cf-chat-form" data-chat-scope="lobby" autocomplete="off"><input class="input" id="cfLobbyChatInput" type="text" maxlength="500" placeholder="Сообщение лобби" aria-label="Сообщение лобби">' +
    '<button class="btn primary" type="submit">Отправить</button></form></section>';
}
function cfOpenGlobalChat() {
  cfCloseDrawer();
  if (!cfSupabaseClient || !cfOnlineAccount) { toast('Войди в онлайн-аккаунт, чтобы писать в общий чат', 'error'); return; }
  openModal('<h2 id="modalTitle">Общий чат</h2><p class="small muted" style="margin-bottom:8px">Общайся вежливо. Не публикуй пароли и личные данные.</p>' +
    '<div class="cf-chat-messages" id="cfGlobalChatMsgs" aria-live="polite" style="max-height:48vh"></div>' +
    '<form class="cf-chat-form" data-chat-scope="global" autocomplete="off"><input class="input" id="cfGlobalChatInput" type="text" maxlength="500" placeholder="Сообщение всем" aria-label="Сообщение в общий чат">' +
    '<button class="btn primary" type="submit">Отправить</button></form>',
    function () { cfChatRender('global'); cfChatPoll(); });
}
document.addEventListener('submit', async function (e) {
  var f = e.target; if (!f || !f.dataset || !f.dataset.chatScope) return;
  e.preventDefault();
  var scope = f.dataset.chatScope, inp = f.querySelector('input'), body = (inp.value || '').trim();
  if (!body || cfChat.busy[scope]) return;
  var L = lobby.state && lobby.state.lobby;
  if (!cfSupabaseClient || !cfOnlineAccount) { toast('Войди в онлайн-аккаунт', 'error'); return; }
  if (scope === 'lobby' && !L) { toast('Ты не в лобби', 'error'); return; }
  cfChat.busy[scope] = true;
  var btn = f.querySelector('button[type="submit"]'); if (btn) btn.disabled = true;
  try {
    var r = await cfSupabaseClient.rpc('cf_chat_send', { p_scope: scope, p_lobby_id: scope === 'lobby' ? L.id : null, p_body: body });
    if (r.error) throw r.error;
    inp.value = ''; cfChatApply(scope, r.data);
    var box = cfChatBox(scope); if (box) box.scrollTop = box.scrollHeight;
  } catch (err) {
    var m = String(err && err.message || '');
    toast(/[А-Яа-яЁё]/.test(m) ? m : 'Не удалось отправить сообщение', 'error');
  } finally { cfChat.busy[scope] = false; if (btn) btn.disabled = false; }
});
setInterval(cfChatPoll, 3500);

/* =========================================================
   Boot
   ========================================================= */
function cfSetOnlineAvailability(available, message) {
  var banner = $('#cfOnlineStatus');
  if (banner) { banner.hidden = !!available; banner.textContent = message || 'Онлайн-сервис временно недоступен. Проверь подключение к Supabase и обнови страницу.'; }
  $$('#formLogin input, #loginBtn, #forgotPassword, #paneRegister input, #paneRegister select, #wizBack, #wizNext, #registerBtn').forEach(function (control) { control.disabled = !available; });
}
function boot() {
  try { buildAmbient(); } catch (e) { if (window.console) console.error(e); }
  if (!cfSupabaseClient) {
    if (store.get(KEYS.session)) store.remove(KEYS.session);
    sessionNick = null; cfOnlineAccount = null;
    cfSetOnlineAvailability(false, 'Онлайн-сервис не подключён. Вход и регистрация доступны только при соединении с Supabase; локальные демо-аккаунты отключены.');
    showAuth('login');
    return;
  }
  cfSetOnlineAvailability(true);
  cfSupabaseClient.auth.getSession().then(async function(res){
    var user=res.data&&res.data.session&&res.data.session.user;
    if(user){try{var online=await cfLoadOnlineProfile(user);sessionNick=online.nick;store.set(KEYS.session,online.nick);lobbyPoll();cfLobbyMatchPoll();cfChatPoll();}catch(err){console.error(err);try{await cfSupabaseClient.auth.signOut();}catch(ignoreSignOut){}cfOnlineAccount=null;sessionNick=null;store.remove(KEYS.session);toast(cfAuthErrorMessage(err,'login'),'error');}}
    else {sessionNick=null;cfOnlineAccount=null;store.remove(KEYS.session);}
    playIntro();
  }).catch(function(err){
    if (window.console) console.warn('Supabase session could not be restored', err);
    sessionNick = null; cfOnlineAccount = null; store.remove(KEYS.session);
    cfSetOnlineAvailability(false, 'Не удалось подключиться к Supabase. Проверь интернет и настройки проекта, затем обнови страницу.');
    showAuth('login');
  });
}
if ('serviceWorker' in navigator && /^https?:$/.test(location.protocol)) { window.addEventListener('load', function () { navigator.serviceWorker.register('./sw.js').catch(function () {}); }); }
try { cfSitePresenceStart(); } catch (presenceError) {}
try { boot(); }
catch (err) {
  if (window.console) console.error(err);
  try { showAuth('login'); } catch (e2) { authEl.hidden = false; }
}

})();
