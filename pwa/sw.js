// PhotoCull remote — service worker.
//
// Three strategies, one job each (docs/REMOTE-CULL.md §3):
//   app shell   cache-first, versioned cache name, navigation falls back to it
//   /api/ JSON  network only — never cached, so a 401 or an error is never replayed
//   previews    cache-first (URLs are immutable, `?v=<etag>`), LRU-ish size cap
//
// Preview requests come from <img>, which cannot carry the Authorization header,
// so this worker adds it. The token lives in IndexedDB next to the outbox and is
// also pushed in by the page on every load.

const SHELL_CACHE = 'photocull-shell-v1';
const PREVIEW_CACHE = 'photocull-preview-v1';
const PREVIEW_LIMIT = 400; // ~400 previews ≈ a few hundred MB at the top end

const SHELL = [
  './',
  './index.html',
  './styles.css',
  './app.js',
  './api.js',
  './store.js',
  './sync.js',
  './manifest.webmanifest',
  './icons/icon-192.png',
  './icons/icon-512.png',
  './icons/apple-touch-icon.png',
];

// --------------------------------------------------------------- install

self.addEventListener('install', (event) => {
  event.waitUntil(
    (async () => {
      const cache = await caches.open(SHELL_CACHE);
      await Promise.all(
        SHELL.map(async (path) => {
          const url = new URL(path, self.location).href;
          try {
            // `reload` skips the HTTP cache so an update really picks up new bytes.
            const response = await fetch(url, { cache: 'reload' });
            if (response.ok) await cache.put(url, response);
          } catch {
            /* a single missing file must not abort the install */
          }
        }),
      );
      await self.skipWaiting();
    })(),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      const keep = new Set([SHELL_CACHE, PREVIEW_CACHE]);
      const names = await caches.keys();
      await Promise.all(names.filter((name) => !keep.has(name)).map((name) => caches.delete(name)));
      await self.clients.claim();
    })(),
  );
});

// ---------------------------------------------------------------- token

let cachedToken;

self.addEventListener('message', (event) => {
  const data = event.data;
  if (data && data.type === 'token') {
    cachedToken = typeof data.token === 'string' ? data.token : null;
  }
});

function openDB() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open('photocull', 1);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains('outbox')) db.createObjectStore('outbox', { keyPath: 'key' });
      if (!db.objectStoreNames.contains('meta')) db.createObjectStore('meta', { keyPath: 'key' });
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
    req.onblocked = () => reject(new Error('indexedDB blocked'));
  });
}

async function readToken() {
  if (cachedToken !== undefined) return cachedToken;
  try {
    const db = await openDB();
    const row = await new Promise((resolve, reject) => {
      const req = db.transaction('meta', 'readonly').objectStore('meta').get('token');
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
    cachedToken = row && typeof row.value === 'string' ? row.value : null;
  } catch {
    cachedToken = null;
  }
  return cachedToken;
}

// ---------------------------------------------------------------- routing

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;

  if (url.pathname.startsWith('/api/')) {
    // JSON stays live; previews are large, immutable and worth caching.
    if (url.pathname.endsWith('/preview')) event.respondWith(cachedPreview(request));
    return;
  }

  if (request.mode === 'navigate') {
    event.respondWith(shellNavigation(request));
    return;
  }

  event.respondWith(shellResource(request));
});

async function shellNavigation(request) {
  const cache = await caches.open(SHELL_CACHE);
  const indexURL = new URL('./index.html', self.location).href;
  const cached =
    (await cache.match(indexURL)) || (await cache.match(new URL('./', self.location).href));
  if (cached) return cached;
  try {
    const response = await fetch(request);
    if (response.ok && response.status === 200) await cache.put(indexURL, response.clone());
    return response;
  } catch {
    return offlineResponse();
  }
}

async function shellResource(request) {
  const cache = await caches.open(SHELL_CACHE);
  const cached = await cache.match(request.url);
  if (cached) return cached;
  try {
    const response = await fetch(request);
    if (response.ok && response.status === 200) await cache.put(request.url, response.clone());
    return response;
  } catch {
    return offlineResponse();
  }
}

async function cachedPreview(request) {
  const cache = await caches.open(PREVIEW_CACHE);
  const cached = await cache.match(request.url);
  if (cached) return cached;

  const token = await readToken();
  const headers = new Headers();
  if (token) headers.set('Authorization', `Bearer ${token}`);

  let response;
  try {
    response = await fetch(request.url, { headers, credentials: 'same-origin' });
    if (response.status === 304) {
      response = await fetch(request.url, { headers, credentials: 'same-origin', cache: 'reload' });
    }
  } catch {
    return offlineResponse();
  }

  const type = response.headers.get('Content-Type') || '';
  if (response.ok && response.status === 200 && type.startsWith('image/')) {
    await cache.put(request.url, response.clone());
    await trimPreviews(cache);
  }
  // A 401 or any error is passed through untouched and never stored.
  return response;
}

async function trimPreviews(cache) {
  try {
    const keys = await cache.keys();
    if (keys.length <= PREVIEW_LIMIT) return;
    const excess = keys.slice(0, keys.length - PREVIEW_LIMIT);
    await Promise.all(excess.map((key) => cache.delete(key)));
  } catch {
    /* trimming is best-effort */
  }
}

function offlineResponse() {
  return new Response('offline', {
    status: 503,
    statusText: 'Offline',
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  });
}
