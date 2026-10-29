const CACHE = 'lx-faceit-standoff2-v1';
const ASSETS = ['./index.html', './icons/icon.svg', './manifest.webmanifest', './css/site.css', './css/lx-theme.css', './js/config.js', './js/app.js', './images/lx-map-sandstone.svg', './images/lx-map-province.svg', './images/lx-map-rust.svg', './images/lx-map-zone-7.svg', './images/lx-map-breeze.svg', './images/lx-map-hanami.svg', './images/lx-map-dune.svg', './images/lx-map-pyramid.svg'];
self.addEventListener('install', event => {
  event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(ASSETS)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(key => key !== CACHE).map(key => caches.delete(key)))).then(() => self.clients.claim()));
});
// Network-first for pages so a new deploy is never hidden behind a stale cached index.html.
self.addEventListener('fetch', event => {
  const req = event.request;
  if (req.method !== 'GET' || new URL(req.url).origin !== self.location.origin) return;
  event.respondWith(fetch(req).then(response => {
    if (response && response.ok) { const copy = response.clone(); caches.open(CACHE).then(cache => cache.put(req, copy)); }
    return response;
  }).catch(() => caches.match(req).then(c => c || caches.match('./index.html'))));
});
