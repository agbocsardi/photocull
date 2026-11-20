// HTTP client for the PhotoCull API v1 (docs/REMOTE-CULL.md §3).
// Same-origin only: the PWA is served by the Mac host.

export class ApiError extends Error {
  constructor(status, message) {
    super(message || (status ? `HTTP ${status}` : 'network error'));
    this.name = 'ApiError';
    this.status = status; // 0 = network failure / unreachable host
  }
}

export class Api {
  constructor(token) {
    this.token = token;
  }

  async request(path, init = {}) {
    const headers = new Headers(init.headers || {});
    if (this.token) headers.set('Authorization', `Bearer ${this.token}`);
    if (init.body !== undefined) headers.set('Content-Type', 'application/json');

    let res;
    try {
      res = await fetch(path, { ...init, headers, cache: 'no-store' });
    } catch {
      throw new ApiError(0, 'offline');
    }

    if (res.status === 401) throw new ApiError(401, 'unauthorized');
    if (!res.ok) {
      let message = `HTTP ${res.status}`;
      try {
        const body = await res.json();
        if (body && typeof body.error === 'string') message = body.error;
      } catch {
        /* not JSON */
      }
      throw new ApiError(res.status, message);
    }
    return res.json();
  }

  health() {
    return this.request('/api/health');
  }

  async sessions() {
    const body = await this.request('/api/sessions');
    return Array.isArray(body.sessions) ? body.sessions : [];
  }

  session(date) {
    return this.request(`/api/sessions/${encodeURIComponent(date)}`);
  }

  /** Returns the full session body (see REMOTE-CULL.md §3). */
  changes(date, changes) {
    return this.request(`/api/sessions/${encodeURIComponent(date)}/changes`, {
      method: 'POST',
      body: JSON.stringify({ changes }),
    });
  }
}
