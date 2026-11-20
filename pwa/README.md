# PhotoCull remote (PWA)

The phone side of **Cull from phone**. Plain HTML/CSS/ES modules: no build step,
no npm, no CDN, works offline once installed. The Mac host serves this directory
at `/` next to the `/api` routes described in
[`docs/REMOTE-CULL.md`](../docs/REMOTE-CULL.md); the PWA adds nothing to that
contract and never finalizes, deletes or moves a file.

## Files

| file | role |
| --- | --- |
| `index.html` | app shell: pairing, session list, culling views |
| `app.js` | router, local session state, gestures, keyboard, polling |
| `api.js` | `/api` client (Bearer token, `ApiError` with the HTTP status) |
| `store.js` | IndexedDB: the token (`meta`) and the change outbox (`outbox`) |
| `sync.js` | outbox flusher: batches, 409/network backoff, returned body |
| `sw.js` | app shell (cache-first), `/api` JSON (network-only), previews (cache-first, 400 entries) |
| `manifest.webmanifest`, `icons/` | installability |
| `styles.css` | dark ink UI echoing the Mac theme and app icon |

## Pairing

Open the link PhotoCull shows on the Mac (`https://<host>/#token=<token>`). On
first load the token is read from the fragment, stored in IndexedDB and stripped
from the address bar with `history.replaceState`. A 401 anywhere clears it and
returns to the pairing screen.

The token is also handed to the service worker (`postMessage`), which needs it
because `<img>` cannot send an `Authorization` header: the worker re-issues
preview requests with the header and caches the result. That is only the fast
path: when the page is not controlled by a worker yet (hard reload, slow first
claim, workers disabled) the page fetches the same bytes with `fetch()` and
shows them from an object URL, retrying once on error.

## Culling behaviour

- `z` / Keep button = keep, `x` / Reject button = reject, the same action again
  = back to undecided (as on the Mac).
- Swipe right = keep, swipe left = reject, swipe up/down = browse. Arrow keys
  (and `j`/`k`) browse, `r` rotates a quarter turn clockwise, `f` toggles the
  all/undecided filter, `Esc` leaves the session.
- After keep/reject the next photo opens automatically. Undecided counts as a
  keeper, so the only "safe" default is to leave photos alone.
- All / Undecided filter; the filtered list keeps its own `n/total`. If the
  photo on screen is decided on the Mac while the undecided filter is on, the
  cursor moves to the next undecided photo at the same position.
- Next 3 and previous 1 previews are preloaded via `Image`/`decode()`.

## Offline-first

Every change is applied locally first, then written to the outbox as
`{date, stem, field, value, at}` (coalesced per stem+field, `at` strictly
increasing so a clear can beat an older set). The flusher POSTs per-session
batches to `/api/sessions/{date}/changes`, adopts the returned session body and
drops the sent entries; 409 and network failures back off and retry, and the
queue survives a reload. The pill reads `synced`, `N pending`, `locked`,
`offline`.

`GET /api/sessions/{date}` is polled every 5 s while the tab is visible; a new
`rev` merges the server state, except for any stem+field that still has a
pending outbox entry.

## Dev

Serve this directory and a mock of `/api` from one origin, for example with a
small script answering the contract from fake data. Because the service worker
caches the shell cache-first, clear the site caches (or bump `SHELL_CACHE` in
`sw.js`) when you change `app.js` and friends. Do not point a dev run at the
real library.

## Known limits

- No offline session list or offline photo browsing: the app shell and previews
  are cached, session JSON is not (it must stay live).
- `crop` and `tilt` are Mac-only in v1 and are not editable here.
- Icons are `purpose: any`; there is no separate maskable icon.
- Pinch-zoom on the photo is not implemented.
