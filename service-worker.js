const CACHE_NAME='bia-tiempos-v1.1.0';
const APP_SHELL=[
  './','./index.html','./cronometros.html','./cronometros.js','./supabase-config.js',
  './pwa.js','./offline.html','./manifest.webmanifest',
  './icons/icon-192.png','./icons/icon-512.png','./icons/maskable-512.png'
];
self.addEventListener('install',event=>{
  event.waitUntil(caches.open(CACHE_NAME).then(c=>c.addAll(APP_SHELL)).then(()=>self.skipWaiting()));
});
self.addEventListener('activate',event=>{
  event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k!==CACHE_NAME).map(k=>caches.delete(k)))).then(()=>self.clients.claim()));
});
self.addEventListener('fetch',event=>{
  const req=event.request;
  if(req.method!=='GET') return;
  const url=new URL(req.url);
  // Supabase/API always goes to network. Never cache operational data.
  if(url.hostname.includes('supabase.co')) return;
  if(req.mode==='navigate'){
    event.respondWith(fetch(req).then(res=>{
      const copy=res.clone(); caches.open(CACHE_NAME).then(c=>c.put(req,copy)); return res;
    }).catch(()=>caches.match(req).then(r=>r||caches.match('./offline.html'))));
    return;
  }
  event.respondWith(caches.match(req).then(cached=>cached||fetch(req).then(res=>{
    if(url.origin===self.location.origin){const copy=res.clone();caches.open(CACHE_NAME).then(c=>c.put(req,copy));}
    return res;
  })));
});
self.addEventListener('message',event=>{if(event.data==='SKIP_WAITING') self.skipWaiting();});
