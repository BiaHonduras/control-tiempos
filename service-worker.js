const CACHE_NAME='bia-control-v3.1.15-local-dependencies';
const APP_SHELL=[
  './','./index.html','./cambiar-password.html','./cronometros.html','./cba.html','./src.html','./tgu.html','./amt.html','./cronometros.js','./cronometros.js?v=20261016-sedes','./supabase-config.js',
  './vendor/supabase-client.mjs','./vendor/supabase-2.38.0.min.js','./vendor/exceljs-4.4.0.min.js','./vendor/jszip.min.js','./pwa.js','./offline.html','./warehouse-ui.css','./warehouse-ui.css?v=3.1.13',
  './assets/bia-honduras-logo.png','./manifest.webmanifest',
  './icons/warehouse.svg','./icons/warehouse-192.png','./icons/warehouse-512.png','./icons/warehouse-maskable-512.png'
];
// Clone synchronously before returning a response to the browser. Cache writes
// may finish later; they must never clone a body that has already been consumed.
function remember(event, request, response) {
  if (!response.ok) return response;
  const copy = response.clone();
  event.waitUntil(caches.open(CACHE_NAME).then(cache => cache.put(request, copy)).catch(() => {}));
  return response;
}
self.addEventListener('install', event => {
  event.waitUntil(caches.open(CACHE_NAME).then(cache => cache.addAll(APP_SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(
    keys.filter(key => key.startsWith('bia-control-v') && key !== CACHE_NAME).map(key => caches.delete(key))
  )).then(() => self.clients.claim()));
});
self.addEventListener('fetch', event => {
  const request = event.request, url = new URL(request.url);
  // Other apps, external libraries and APIs use the browser's normal network.
  if (request.method !== 'GET' || url.origin !== self.location.origin || !url.pathname.startsWith(new URL(self.registration.scope).pathname)) return;
  if (request.mode === 'navigate') {
    event.respondWith(fetch(request).then(response => remember(event, request, response)).catch(async () => {
      const cache = await caches.open(CACHE_NAME);
      return await cache.match(request) || await cache.match('./offline.html') || new Response('Sin conexión. Recarga cuando se restablezca la red.', {status:503, headers:{'Content-Type':'text/plain; charset=utf-8'}});
    }));
    return;
  }
  if (!/\.(?:html|js|mjs|css|png|svg|webmanifest|ico|woff2?|jpg|jpeg|pdf|sql)$/.test(url.pathname)) return;
  event.respondWith(caches.open(CACHE_NAME).then(async cache => {
    const cached = await cache.match(request);
    if (cached) return cached;
    return fetch(request).then(response => remember(event, request, response));
  }));
});
self.addEventListener('message', event => { if (event.data === 'SKIP_WAITING') self.skipWaiting(); });
