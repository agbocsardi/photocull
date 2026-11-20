// Outbox flusher. Every cull change is written to IndexedDB first, then POSTed
// in per-session batches. The server merge rule makes replays idempotent, so a
// batch that 409s or dies on the network is simply retried later.

import { ApiError } from './api.js';
import * as store from './store.js';

const FIRST_DELAY = 2000;
const MAX_DELAY = 60000;

export class Sync {
  constructor({ api, seq, onStatus, onSession, onAuthError, onDropped }) {
    this.api = api;
    this.seq = seq || null; // numbers a request at its start; lets callers drop stale bodies
    this.onStatus = onStatus || (() => {});
    this.onSession = onSession || (() => {});
    this.onAuthError = onAuthError || (() => {});
    this.onDropped = onDropped || (() => {});

    this.pending = 0;
    // `offline` is the indicator only: reaching the host or not is decided by
    // the request itself, so a retry is never blocked by a stale guess.
    this.offline = !navigator.onLine;
    this.limited = false;

    this.busy = false;
    this.queued = false;
    this.backoff = FIRST_DELAY;
    this.timer = 0;
    this.retryTimer = 0;

    addEventListener('online', () => {
      this.offline = false;
      this.backoff = FIRST_DELAY;
      this.publish();
      this.kick();
    });
    addEventListener('offline', () => {
      this.offline = true;
      this.publish();
    });
  }

  publish() {
    this.onStatus({ pending: this.pending, offline: this.offline, limited: this.limited });
  }

  async refresh() {
    this.pending = await store.pendingCount();
    this.publish();
    return this.pending;
  }

  /** Ask for a flush soon (coalesces bursts of edits). */
  kick() {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.flush(), 100);
  }

  schedule(delay) {
    clearTimeout(this.retryTimer);
    this.retryTimer = setTimeout(() => this.flush(), delay);
  }

  async flush() {
    if (this.busy) {
      this.queued = true;
      return;
    }
    this.busy = true;
    this.queued = false;
    try {
      const records = await store.allPending();
      this.pending = records.length;
      this.publish();
      if (!records.length) return;

      const byDate = new Map();
      for (const rec of records) {
        if (!byDate.has(rec.date)) byDate.set(rec.date, []);
        byDate.get(rec.date).push(rec);
      }

      let retry = false;
      for (const [date, group] of byDate) {
        group.sort((a, b) => a.at - b.at);
        const changes = group.map(({ stem, field, value, at }) => ({ stem, field, value, at }));
        // Taken before the POST: a body is stale once a newer fetch was applied.
        const seq = this.seq ? this.seq() : 0;

        try {
          const body = await this.api.changes(date, changes);
          this.backoff = FIRST_DELAY;
          this.limited = false;
          this.offline = false;
          const removed = await store.resolveSent(group);
          await this.refresh();
          this.onSession(date, body, removed, seq);
        } catch (err) {
          if (!(err instanceof ApiError)) {
            this.offline = true;
            retry = true; // other dates still get their chance
            continue;
          }
          if (err.status === 401) {
            this.onAuthError();
            return;
          }
          if (err.status === 409) {
            // Session locked (e.g. Finalize is running): retry later.
            this.limited = true;
            this.publish();
            retry = true;
            continue;
          }
          if (err.status === 0 || err.status >= 500) {
            this.offline = err.status === 0;
            this.publish();
            retry = true;
            continue;
          }
          // 400/404: the session or stem is gone; replaying can never succeed.
          await store.resolveSent(group);
          await this.refresh();
          this.onDropped({ date, count: group.length, message: err.message });
        }
      }
      if (retry) this.schedule(this.nextDelay());
    } finally {
      this.busy = false;
      await this.refresh();
      if (this.queued) this.kick();
    }
  }

  nextDelay() {
    const delay = this.backoff;
    this.backoff = Math.min(this.backoff * 2, MAX_DELAY);
    return delay;
  }
}
