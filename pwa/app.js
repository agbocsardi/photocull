// PhotoCull remote — mobile culling. Contract: docs/REMOTE-CULL.md §3.
//
// Decisions are applied optimistically to local state and queued in IndexedDB
// (see store.js); sync.js flushes the queue and hands back the authoritative
// session body. The PWA never finalizes, deletes or moves anything.

import { Api, ApiError } from './api.js';
import * as store from './store.js';
import { Sync } from './sync.js';

const POLL_MS = 5000;
const SWIPE_NAV = 64; // px of vertical travel to move to the next photo

const state = {
  token: null,
  api: null,
  sync: null,
  hostName: '',
  view: 'boot',
  serial: 0,

  sessions: [],
  date: null,
  session: null, // { date, rev, photos: [{ stem, hasRaw, preview, decision, rotation }] }
  stem: null,
  filter: 'all',

  pending: new Map(), // "STEM|field" -> value, for the open session
  lastAt: new Map(), // store key -> highest `at` used (keeps stamps monotonic)
  syncStatus: { pending: 0, offline: false, limited: false },

  pollTimer: 0,
  polling: false,
  pushedCull: false,
  unreachable: false,
};

const el = {};
const views = {};
const preloads = new Map();

// ---------------------------------------------------------------- bootstrap

init();

async function init() {
  cacheElements();
  wireEvents();
  await registerServiceWorker();

  const fromHash = takeTokenFromHash();
  const token = fromHash || (await store.getToken());
  if (fromHash) await store.setToken(fromHash);

  if (token) {
    startWithToken(token);
  } else {
    showPairing();
    return;
  }

  history.replaceState({ v: currentRoute().view }, '', location.href);
  render();
}

function cacheElements() {
  const ids = [
    'view-pair', 'view-sessions', 'view-cull',
    'pair-title', 'pair-body',
    'host-name', 'list-sync', 'refresh', 'session-scroll', 'session-list',
    'session-empty', 'list-error', 'list-error-text', 'list-error-retry', 'unpair',
    'back', 'cull-date', 'cull-pos', 'cull-stem', 'cull-raw', 'cull-badge', 'sync-pill',
    'stage', 'frame', 'stage-img', 'stage-msg', 'hint-left', 'hint-right',
    'btn-keep', 'btn-reject', 'btn-prev', 'btn-next', 'btn-rotate', 'toast',
  ];
  for (const id of ids) el[toCamel(id)] = document.getElementById(id);
  views.pair = el.viewPair;
  views.sessions = el.viewSessions;
  views.cull = el.viewCull;
}

function toCamel(id) {
  return id.replace(/-([a-z])/g, (_, c) => c.toUpperCase());
}

function wireEvents() {
  addEventListener('popstate', () => {
    state.pushedCull = false;
    render();
  });

  el.back.addEventListener('click', goBack);
  el.btnKeep.addEventListener('click', () => decide('keep'));
  el.btnReject.addEventListener('click', () => decide('reject'));
  el.btnPrev.addEventListener('click', () => step(-1));
  el.btnNext.addEventListener('click', () => step(1));
  el.btnRotate.addEventListener('click', () => rotate());

  for (const btn of document.querySelectorAll('.filter-btn')) {
    btn.addEventListener('click', () => setFilter(btn.dataset.filter));
  }

  el.refresh.addEventListener('click', () => loadSessions());
  el.listErrorRetry.addEventListener('click', () => loadSessions());
  el.unpair.addEventListener('click', unpair);

  wireStageGestures();
  addEventListener('keydown', onKeyDown);
  addEventListener('resize', fitStage);
  addEventListener('orientationchange', () => setTimeout(fitStage, 120));
  if ('ResizeObserver' in window) new ResizeObserver(() => fitStage()).observe(el.stage);

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') {
      if (state.view === 'cull') {
        pollOnce();
        startPoll();
      } else if (state.view === 'sessions') {
        loadSessions({ silent: true });
      }
      state.sync?.kick();
    } else {
      stopPoll();
    }
  });
}

// ------------------------------------------------------------- pairing/token

function takeTokenFromHash() {
  const match = location.hash.match(/^#token=(.+)$/);
  if (!match) return null;
  let token = match[1];
  try {
    token = decodeURIComponent(token);
  } catch {
    /* keep raw */
  }
  const url = location.pathname + location.search;
  history.replaceState(null, '', url || '/');
  return token.trim() || null;
}

async function startWithToken(token) {
  state.token = token;
  state.api = new Api(token);
  state.sync = new Sync({
    api: state.api,
    onStatus: setSyncStatus,
    onSession: adoptFromSync,
    onAuthError: () => unpair({ revoked: true }),
    onDropped: (info) => toast(`Couldn’t sync ${info.count} change${info.count === 1 ? '' : 's'} (${info.message})`),
  });
  postTokenToWorker(token);
  await state.sync.refresh();

  try {
    const health = await state.api.health();
    state.hostName = (health && health.name) || '';
    el.hostName.textContent = state.hostName;
    el.hostName.title = state.hostName;
  } catch (err) {
    if (err instanceof ApiError && err.status === 401) return unpair({ revoked: true });
    /* unreachable host: the session list shows the error */
  }
}

async function unpair({ revoked = false } = {}) {
  stopPoll();
  state.token = null;
  state.api = null;
  state.session = null;
  state.stem = null;
  state.sessions = [];
  state.date = null;
  try {
    await store.clearToken();
  } catch {
    /* ignore */
  }
  postTokenToWorker(null);
  showPairing({ revoked });
}

function showPairing({ revoked = false } = {}) {
  state.view = 'pair';
  stopPoll();
  setView('pair');
  el.pairTitle.textContent = revoked ? 'Pairing expired' : 'Open the pairing link';
  el.pairBody.textContent = revoked
    ? 'This device is no longer paired. Open the pairing link from PhotoCull on your Mac again.'
    : 'On your Mac, turn on “Cull from phone” in PhotoCull and open the link it shows (or scan its QR code) on this device.';
}

function setView(name) {
  for (const [key, node] of Object.entries(views)) node.hidden = key !== name;
  if (name !== 'cull') stopPoll();
}

// ------------------------------------------------------------------ routing

function currentRoute() {
  const match = location.hash.match(/^#\/s\/(.+)$/);
  if (match) {
    let date = match[1];
    try {
      date = decodeURIComponent(date);
    } catch {
      /* keep raw */
    }
    return { view: 'cull', date };
  }
  return { view: 'sessions' };
}

function go(hash, view) {
  if (location.hash !== hash) history.pushState({ v: view }, '', hash);
  if (view === 'cull') state.pushedCull = true;
  return render();
}

function goBack() {
  if (state.pushedCull) {
    state.pushedCull = false;
    history.back();
    return;
  }
  go('#/', 'sessions');
}

async function render() {
  if (!state.token) {
    showPairing();
    return;
  }
  const route = currentRoute();
  if (route.view === 'cull') await openSession(route.date);
  else await showSessions();
}

// ------------------------------------------------------------ session list

async function showSessions() {
  state.view = 'sessions';
  state.session = null;
  stopPoll();
  setView('sessions');
  await loadSessions();
}

async function loadSessions({ silent = false } = {}) {
  if (!state.api) return;
  if (!silent) el.listError.hidden = true;
  try {
    const sessions = await state.api.sessions();
    state.sessions = sessions;
    el.listError.hidden = true;
    state.unreachable = false;
    renderSync();
    renderSessions();
  } catch (err) {
    if (err instanceof ApiError && err.status === 401) return unpair({ revoked: true });
    state.unreachable = err instanceof ApiError && err.status === 0;
    renderSync();
    if (silent && state.sessions.length) return;
    el.listError.hidden = false;
    el.listErrorText.textContent =
      err instanceof ApiError && err.status === 0
        ? 'Can’t reach your Mac. Make sure PhotoCull is running and Cull from phone is on.'
        : `Couldn’t load sessions: ${err.message}`;
    renderSessions();
  }
}

function renderSessions() {
  el.sessionList.textContent = '';
  const rows = document.createDocumentFragment();

  for (const session of state.sessions) {
    const total = num(session.total);
    const keep = num(session.keep);
    const reject = num(session.reject);
    const undecided = num(session.undecided);
    const status = typeof session.status === 'string' ? session.status : '';

    const row = document.createElement('button');
    row.type = 'button';
    row.className = 'session';

    const top = document.createElement('div');
    top.className = 's-top';
    const date = document.createElement('span');
    date.className = 's-date';
    date.textContent = session.date;
    const badge = document.createElement('span');
    badge.className = `s-status st-${status.replace(/\s+/g, '-')}`;
    badge.textContent = status || '—';
    top.append(date, badge);

    const bar = document.createElement('div');
    bar.className = 'bar';
    const keepBar = document.createElement('i');
    keepBar.className = 'bar-keep';
    keepBar.style.width = total ? `${(keep / total) * 100}%` : '0%';
    const rejectBar = document.createElement('i');
    rejectBar.className = 'bar-reject';
    rejectBar.style.width = total ? `${(reject / total) * 100}%` : '0%';
    bar.append(keepBar, rejectBar);

    const counts = document.createElement('div');
    counts.className = 's-counts';
    counts.append(
      countSpan('keep', keep),
      countSpan('reject', reject),
      countSpan('undecided', undecided),
    );
    const totalEl = document.createElement('span');
    totalEl.className = 'total mono dim';
    totalEl.textContent = `${undecided}/${total}`;
    counts.append(totalEl);

    row.append(top, bar, counts);
    row.addEventListener('click', () => go(`#/s/${encodeURIComponent(session.date)}`, 'cull'));
    rows.append(row);
  }

  el.sessionList.append(rows);
  el.sessionEmpty.hidden = state.sessions.length > 0;
}

function countSpan(kind, value) {
  const span = document.createElement('span');
  span.className = kind;
  const strong = document.createElement('b');
  strong.textContent = String(value);
  span.append(strong, ` ${kind}`);
  return span;
}

function num(value) {
  const n = Number(value);
  return Number.isFinite(n) ? n : 0;
}

// ------------------------------------------------------------- culling view

async function openSession(date) {
  if (!state.api) return;
  if (state.view === 'cull' && state.date === date && state.session) {
    setView('cull');
    startPoll();
    return;
  }

  const serial = ++state.serial;
  state.view = 'cull';
  state.date = date;
  state.session = null;
  state.stem = null;
  state.filter = 'all';
  setView('cull');
  renderFilters();
  updateTopbar();
  setStageMessage('Loading…');
  el.stageImg.hidden = true;
  el.stageImg.removeAttribute('src');
  el.stageImg.dataset.src = '';
  resetFrame();

  await loadPending(date);
  if (serial !== state.serial) return;

  try {
    const body = await state.api.session(date);
    if (serial !== state.serial) return;
    applySession(body, { initial: true });
    startPoll();
  } catch (err) {
    if (serial !== state.serial) return;
    if (err instanceof ApiError && err.status === 401) return unpair({ revoked: true });
    setStageMessage(
      err instanceof ApiError && err.status === 0
        ? 'Can’t reach your Mac. Retrying…'
        : err.message,
    );
    updateTopbar();
    startPoll();
  }
}

async function loadPending(date) {
  const records = (await store.allPending()).filter((rec) => rec.date === date);
  state.pending.clear();
  for (const rec of records) {
    state.pending.set(`${rec.stem}|${rec.field}`, rec.value);
    const previous = state.lastAt.get(rec.key) || 0;
    if (rec.at > previous) state.lastAt.set(rec.key, rec.at);
  }
  state.sync?.refresh();
}

function applySession(body, { initial = false } = {}) {
  const previousStem = state.stem;
  const photos = (Array.isArray(body.photos) ? body.photos : []).map((photo) => {
    const pendingDecision = state.pending.get(`${photo.stem}|decision`);
    const pendingRotation = state.pending.get(`${photo.stem}|rotation`);
    return {
      stem: photo.stem,
      hasRaw: !!photo.hasRaw,
      preview: photo.preview,
      decision: pendingDecision !== undefined ? pendingDecision : photo.decision || 'undecided',
      rotation:
        pendingRotation !== undefined
          ? pendingRotation
          : ((Number(photo.rotation) % 4) + 4) % 4 || 0,
    };
  });

  state.session = { date: body.date || state.date, rev: body.rev, photos };

  if (initial) {
    const last = Number(body.last_index);
    const index = Number.isFinite(last) ? Math.min(Math.max(0, Math.trunc(last)), photos.length - 1) : 0;
    state.stem = photos.length ? photos[index].stem : null;
  } else if (!photos.some((photo) => photo.stem === previousStem)) {
    state.stem = photos.length ? photos[0].stem : null;
  }

  renderCull();
}

function visiblePhotos() {
  const photos = state.session ? state.session.photos : [];
  return state.filter === 'undecided'
    ? photos.filter((photo) => photo.decision === 'undecided')
    : photos;
}

function currentPhoto() {
  const list = visiblePhotos();
  return list.find((photo) => photo.stem === state.stem) || null;
}

function renderCull() {
  updateTopbar();
  renderPhoto();
}

function updateTopbar() {
  const list = visiblePhotos();
  const index = list.findIndex((photo) => photo.stem === state.stem);
  const photo = index >= 0 ? list[index] : null;

  el.cullDate.textContent = state.date || '—';
  el.cullPos.textContent = `${photo ? index + 1 : 0}/${list.length}`;
  el.cullStem.textContent = photo ? photo.stem : state.session ? '—' : '';
  el.cullRaw.hidden = !(photo && photo.hasRaw);

  const decision = photo ? photo.decision : 'undecided';
  el.cullBadge.textContent = decision.toUpperCase();
  el.cullBadge.className = `badge ${decision}`;

  el.btnKeep.classList.toggle('active', decision === 'keep');
  el.btnReject.classList.toggle('active', decision === 'reject');
  el.btnPrev.disabled = !photo || index <= 0;
  el.btnNext.disabled = !photo || index >= list.length - 1;
  el.btnRotate.disabled = !photo;
  el.btnKeep.disabled = !photo;
  el.btnReject.disabled = !photo;
}

function renderFilters() {
  for (const btn of document.querySelectorAll('.filter-btn')) {
    btn.setAttribute('aria-pressed', String(btn.dataset.filter === state.filter));
  }
}

function setFilter(filter) {
  if (filter === state.filter) return;
  state.filter = filter === 'undecided' ? 'undecided' : 'all';
  renderFilters();
  const list = visiblePhotos();
  if (!list.some((photo) => photo.stem === state.stem) && list.length) {
    state.stem = list[0].stem;
  }
  renderCull();
}

function setStageMessage(text) {
  const hasText = Boolean(text);
  el.stageMsg.textContent = hasText ? text : '';
  el.stageMsg.classList.toggle('show', hasText);
}

function renderPhoto() {
  const photo = currentPhoto();

  if (!photo) {
    el.stageImg.hidden = true;
    el.stageImg.removeAttribute('src');
    el.stageImg.dataset.src = '';
    if (!state.session) setStageMessage('Loading…');
    else if (!state.session.photos.length) setStageMessage('No photos in this session.');
    else setStageMessage('All decided — switch to “All” to review them.');
    return;
  }

  setStageMessage(null);
  const url = photo.preview || '';
  el.stageImg.hidden = false;
  if (el.stageImg.dataset.src !== url) {
    el.stageImg.dataset.src = url;
    el.stageImg.src = url;
  }
  fitStage();
  preloadAround(visiblePhotos());
}

/** Fit the photo into the stage, accounting for the rotation quarter turns. */
function fitStage() {
  const img = el.stageImg;
  if (!img || img.hidden || !img.naturalWidth || !img.naturalHeight) return;
  const W = el.stage.clientWidth;
  const H = el.stage.clientHeight;
  if (!W || !H) return;

  const photo = currentPhoto();
  const rotation = photo ? photo.rotation % 4 : 0;
  const odd = rotation % 2 === 1;
  const naturalWidth = img.naturalWidth;
  const naturalHeight = img.naturalHeight;

  const boxWidth = odd ? naturalHeight : naturalWidth;
  const boxHeight = odd ? naturalWidth : naturalHeight;
  const scale = Math.min(W / boxWidth, H / boxHeight);

  img.style.width = `${Math.max(1, Math.round(naturalWidth * scale))}px`;
  img.style.height = `${Math.max(1, Math.round(naturalHeight * scale))}px`;
  img.style.transform = `rotate(${rotation * 90}deg)`;
}

function preloadAround(list) {
  const index = list.findIndex((photo) => photo.stem === state.stem);
  if (index < 0) return;

  for (const offset of [1, 2, 3, -1]) {
    const photo = list[index + offset];
    if (!photo || !photo.preview || preloads.has(photo.preview)) continue;
    const image = new Image();
    image.decoding = 'async';
    image.src = photo.preview; // the service worker answers from its cache
    if (image.decode) image.decode().catch(() => {});
    preloads.set(photo.preview, image);
  }
  while (preloads.size > 12) preloads.delete(preloads.keys().next().value);
}

// ------------------------------------------------------------------ actions

function decide(value) {
  const photo = currentPhoto();
  if (!photo) return;

  const listBefore = visiblePhotos();
  const indexBefore = listBefore.findIndex((entry) => entry.stem === photo.stem);
  const decision = photo.decision === value ? 'undecided' : value;
  photo.decision = decision;

  if (state.filter === 'undecided') {
    // The photo just left the filtered list; the next one takes its place.
    const list = visiblePhotos();
    const at = Math.min(indexBefore, list.length - 1);
    state.stem = list.length ? list[at].stem : photo.stem;
  } else if (decision !== 'undecided') {
    const list = visiblePhotos();
    const index = list.findIndex((entry) => entry.stem === photo.stem);
    if (index >= 0 && index + 1 < list.length) state.stem = list[index + 1].stem;
  }

  renderCull();
  commit(photo.stem, 'decision', decision);
}

function step(delta) {
  const list = visiblePhotos();
  const index = list.findIndex((photo) => photo.stem === state.stem);
  if (index < 0) return;
  const next = index + delta;
  if (next < 0 || next >= list.length) return;
  state.stem = list[next].stem;
  renderCull();
}

function rotate() {
  const photo = currentPhoto();
  if (!photo) return;
  const rotation = ((Number(photo.rotation) || 0) + 1) % 4;
  photo.rotation = rotation;
  fitStage();
  updateTopbar();
  commit(photo.stem, 'rotation', rotation);
}

async function commit(stem, field, value) {
  const date = state.date;
  if (!date) return;
  const key = store.changeKey(date, stem, field);
  const at = nextStamp(key);
  state.pending.set(`${stem}|${field}`, value);
  try {
    await store.putChange({ date, stem, field, value, at });
    state.sync?.kick();
  } catch (err) {
    console.error('outbox write failed', err);
    toast('Couldn’t save that change on this device.');
  }
}

/** Stamps must strictly increase, or a clear could lose to an older set server-side. */
function nextStamp(key) {
  const previous = state.lastAt.get(key) || 0;
  const at = Math.max(Date.now(), previous + 1);
  state.lastAt.set(key, at);
  return at;
}

// -------------------------------------------------------------------- sync

function setSyncStatus(status) {
  state.syncStatus = status;
  renderSync();
}

function renderSync() {
  const { pending, offline, limited } = state.syncStatus;
  const unreachable = state.unreachable && !offline;
  let text = 'synced';
  let tone = 'ok';
  if (offline || unreachable) {
    text = pending ? `offline · ${pending} pending` : 'offline';
    tone = 'offline';
  } else if (limited) {
    text = pending ? `locked · ${pending} pending` : 'locked';
    tone = 'offline';
  } else if (pending) {
    text = `${pending} pending`;
    tone = 'pending';
  }
  for (const node of [el.syncPill, el.listSync]) {
    if (!node) continue;
    node.textContent = text;
    node.className = `sync-pill ${tone}`;
  }
}

function adoptFromSync(date, body, removedKeys) {
  for (const key of removedKeys || []) {
    const start = key.indexOf('|') + 1;
    const end = key.lastIndexOf('|');
    if (start > 0 && end > start) state.pending.delete(`${key.slice(start, end)}|${key.slice(end + 1)}`);
  }
  if (state.view === 'cull' && state.date === date && state.session) {
    applySession(body);
  }
}

// ------------------------------------------------------------------ polling

function startPoll() {
  stopPoll();
  state.pollTimer = setInterval(pollOnce, POLL_MS);
}

function stopPoll() {
  if (state.pollTimer) clearInterval(state.pollTimer);
  state.pollTimer = 0;
}

async function pollOnce() {
  if (state.polling || !state.api || state.view !== 'cull' || !state.date) return;
  if (document.visibilityState !== 'visible') return;
  state.polling = true;
  try {
    const body = await state.api.session(state.date);
    if (state.view !== 'cull' || state.date !== body.date) return;
    state.unreachable = false;
    renderSync();
    if (!state.session || body.rev !== state.session.rev) applySession(body, { initial: !state.session });
  } catch (err) {
    if (err instanceof ApiError && err.status === 401) unpair({ revoked: true });
    else if (err instanceof ApiError && err.status === 0) {
      state.unreachable = true;
      renderSync();
    }
    /* everything else: keep the local state, the outbox retries on its own */
  } finally {
    state.polling = false;
  }
}

// ----------------------------------------------------------------- gestures

const drag = { active: false, id: 0, x0: 0, y0: 0, dx: 0, dy: 0, axis: null, t0: 0 };

function wireStageGestures() {
  el.stage.addEventListener('pointerdown', (event) => {
    if (!currentPhoto()) return;
    if (event.pointerType === 'mouse' && event.button !== 0) return;
    drag.active = true;
    drag.id = event.pointerId;
    drag.x0 = event.clientX;
    drag.y0 = event.clientY;
    drag.dx = 0;
    drag.dy = 0;
    drag.axis = null;
    drag.t0 = performance.now();
    el.frame.classList.remove('animate');
    try {
      el.stage.setPointerCapture(event.pointerId);
    } catch {
      /* not fatal */
    }
  });

  el.stage.addEventListener('pointermove', (event) => {
    if (!drag.active || event.pointerId !== drag.id) return;
    drag.dx = event.clientX - drag.x0;
    drag.dy = event.clientY - drag.y0;

    if (!drag.axis && Math.hypot(drag.dx, drag.dy) > 10) {
      drag.axis = Math.abs(drag.dx) >= Math.abs(drag.dy) ? 'x' : 'y';
    }
    if (drag.axis === 'x') {
      el.frame.style.transform = `translate3d(${drag.dx}px, 0, 0)`;
      const progress = Math.min(1, Math.abs(drag.dx) / swipeThreshold());
      el.hintLeft.style.opacity = drag.dx < 0 ? String(progress) : '0';
      el.hintRight.style.opacity = drag.dx > 0 ? String(progress) : '0';
    } else if (drag.axis === 'y') {
      el.frame.style.transform = `translate3d(0, ${drag.dy * 0.45}px, 0)`;
    }
  });

  const end = (event) => {
    if (!drag.active || event.pointerId !== drag.id) return;
    drag.active = false;
    const { dx, dy, axis } = drag;
    endDrag();
    if (axis === 'x' && Math.abs(dx) >= swipeThreshold()) {
      decide(dx > 0 ? 'keep' : 'reject');
    } else if (axis === 'y' && Math.abs(dy) >= SWIPE_NAV) {
      step(dy < 0 ? 1 : -1);
    }
  };

  el.stage.addEventListener('pointerup', end);
  el.stage.addEventListener('pointercancel', () => {
    if (!drag.active) return;
    drag.active = false;
    endDrag();
  });

  el.stageImg.addEventListener('load', () => fitStage());
  el.stageImg.addEventListener('error', () => {
    if (!el.stageImg.dataset.src) return;
    setStageMessage('Preview unavailable.');
  });
}

function swipeThreshold() {
  return Math.max(56, Math.min(120, el.stage.clientWidth * 0.25));
}

function endDrag() {
  el.frame.classList.add('animate');
  resetFrame();
  el.hintLeft.style.opacity = '0';
  el.hintRight.style.opacity = '0';
}

function resetFrame() {
  el.frame.style.transform = 'translate3d(0, 0, 0)';
}

function onKeyDown(event) {
  if (state.view !== 'cull') return;
  if (event.metaKey || event.ctrlKey || event.altKey) return;
  switch (event.key) {
    case 'z':
    case 'Z':
      event.preventDefault();
      decide('keep');
      break;
    case 'x':
    case 'X':
      event.preventDefault();
      decide('reject');
      break;
    case 'ArrowRight':
    case 'j':
      event.preventDefault();
      step(1);
      break;
    case 'ArrowLeft':
    case 'k':
      event.preventDefault();
      step(-1);
      break;
    case 'r':
    case 'R':
      event.preventDefault();
      rotate();
      break;
    case 'f':
    case 'F':
      event.preventDefault();
      setFilter(state.filter === 'all' ? 'undecided' : 'all');
      break;
    case 'Escape':
      event.preventDefault();
      goBack();
      break;
    default:
      break;
  }
}

// ------------------------------------------------------------ service worker

async function registerServiceWorker() {
  if (!('serviceWorker' in navigator)) return false;
  try {
    await navigator.serviceWorker.register('./sw.js', { scope: './' });
    await navigator.serviceWorker.ready;
    if (!navigator.serviceWorker.controller) {
      await new Promise((resolve) => {
        const timer = setTimeout(resolve, 3000);
        navigator.serviceWorker.addEventListener(
          'controllerchange',
          () => {
            clearTimeout(timer);
            resolve();
          },
          { once: true },
        );
      });
    }
    navigator.serviceWorker.addEventListener('controllerchange', () => {
      if (state.token) postTokenToWorker(state.token);
    });
    return Boolean(navigator.serviceWorker.controller);
  } catch (err) {
    console.warn('service worker unavailable', err);
    return false;
  }
}

function postTokenToWorker(token) {
  const controller = navigator.serviceWorker && navigator.serviceWorker.controller;
  if (controller) controller.postMessage({ type: 'token', token });
}

// -------------------------------------------------------------------- toast

let toastTimer = 0;

function toast(message) {
  el.toast.textContent = message;
  el.toast.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    el.toast.hidden = true;
  }, 4000);
}
