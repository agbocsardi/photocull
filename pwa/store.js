// IndexedDB persistence: the API token (shared with the service worker, which
// needs it to fetch previews on behalf of <img>) and the change outbox.

const DB_NAME = 'photocull';
const DB_VERSION = 1;
const OUTBOX = 'outbox';
const META = 'meta';

let dbPromise = null;

function upgrade(db) {
  if (!db.objectStoreNames.contains(OUTBOX)) db.createObjectStore(OUTBOX, { keyPath: 'key' });
  if (!db.objectStoreNames.contains(META)) db.createObjectStore(META, { keyPath: 'key' });
}

export function openDB() {
  if (dbPromise) return dbPromise;
  dbPromise = new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = () => upgrade(req.result);
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
    req.onblocked = () => reject(new Error('indexedDB blocked'));
  });
  return dbPromise;
}

function one(request) {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

function done(tx) {
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error || new Error('transaction aborted'));
  });
}

// ---- token ----------------------------------------------------------------

export async function getToken() {
  try {
    const db = await openDB();
    const row = await one(db.transaction(META, 'readonly').objectStore(META).get('token'));
    return row && typeof row.value === 'string' ? row.value : null;
  } catch {
    return null;
  }
}

export async function setToken(token) {
  const db = await openDB();
  const tx = db.transaction(META, 'readwrite');
  tx.objectStore(META).put({ key: 'token', value: token });
  await done(tx);
}

export async function clearToken() {
  const db = await openDB();
  const tx = db.transaction(META, 'readwrite');
  tx.objectStore(META).delete('token');
  await done(tx);
}

// ---- outbox ---------------------------------------------------------------

export function changeKey(date, stem, field) {
  return `${date}|${stem}|${field}`;
}

/**
 * Queue one change. One entry per (date, stem, field): a later change replaces
 * the earlier one, which is all the server merge rule needs (the newest stamp
 * wins).
 */
export async function putChange({ date, stem, field, value, at }) {
  const key = changeKey(date, stem, field);
  const db = await openDB();
  const tx = db.transaction(OUTBOX, 'readwrite');
  tx.objectStore(OUTBOX).put({ key, date, stem, field, value, at });
  await done(tx);
  return key;
}

export async function allPending() {
  try {
    const db = await openDB();
    return await one(db.transaction(OUTBOX, 'readonly').objectStore(OUTBOX).getAll());
  } catch {
    return [];
  }
}

export async function pendingCount() {
  return (await allPending()).length;
}

/**
 * Delete the entries that were just accepted by the server. An entry whose
 * `at` changed while the request was in flight is a newer local edit and stays
 * in the outbox.
 */
export async function resolveSent(sent) {
  const current = new Map((await allPending()).map((rec) => [rec.key, rec]));
  // Only drop an entry that is still exactly what was sent: a newer local edit
  // may share the key (same `at`) but carry a different value.
  const keys = sent
    .filter((rec) => {
      const now = current.get(rec.key);
      return now && now.at === rec.at && now.value === rec.value;
    })
    .map((rec) => rec.key);
  if (!keys.length) return [];
  const db = await openDB();
  const tx = db.transaction(OUTBOX, 'readwrite');
  const store = tx.objectStore(OUTBOX);
  for (const key of keys) store.delete(key);
  await done(tx);
  return keys;
}
