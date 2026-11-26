'use strict';
const PREFIX = 'bilim-pwa-' + new URL(self.registration.scope).pathname + '-';
const CACHE = PREFIX + 'v1';
const OFFLINE = new URL('./offline.html', self.registration.scope).href;
// No answer keys, API responses, authentication or student records are cached.
const SHELL = ['offline.html','icon-192.png','icon-512.png','icon-maskable.png','manifest.webmanifest']
  .map(path => new URL(path, self.registration.scope).href);
self.addEventListener('install', event => {
  event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(SHELL)));
  // Wait for existing app windows to close; never interrupt an assessment.
});
self.addEventListener('activate', event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(key => key.startsWith(PREFIX) && key !== CACHE).map(key => caches.delete(key)))));
});
self.addEventListener('fetch', event => {
  const request = event.request;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);
  const scope = new URL(self.registration.scope);
  if (url.origin !== scope.origin || !url.pathname.startsWith(scope.pathname)) return;
  if (request.mode === 'navigate') {
    event.respondWith(fetch(request).catch(async () => (await caches.open(CACHE)).match(OFFLINE)));
  } else if (SHELL.includes(url.href)) {
    event.respondWith(fetch(request).catch(async () => (await caches.open(CACHE)).match(request)));
  }
});
