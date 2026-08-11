// Home Brain service worker - network-first for the app shell so updates land
// immediately, with a cached fallback so the app still opens while the brain
// is restarting. API calls are never intercepted.
// Bump CACHE on a UI change to force every client to drop its old shell and
// take the new service worker on the next normal load — no manual hard-reload.
const CACHE = 'home-brain-v2';
const SHELL = ['/', '/manifest.json', '/icon-192.png', '/icon-512.png'];

self.addEventListener('install', e => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil((async () => {
  // Purge stale caches from older versions, then take control immediately.
  const keys = await caches.keys();
  await Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)));
  await clients.claim();
})()));

self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  const u = new URL(e.request.url);
  if (u.origin !== location.origin || !SHELL.includes(u.pathname)) return;
  e.respondWith(
    fetch(e.request).then(r => {
      const copy = r.clone();
      caches.open(CACHE).then(c => c.put(e.request, copy));
      return r;
    }).catch(() => caches.match(e.request))
  );
});
