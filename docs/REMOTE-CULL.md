# Remote culling — architecture and contracts

Goal: cull from a phone (PWA) while the Mac app keeps working as a fast,
single-machine app. One HTTP API, two possible hosts:

```
PWA ──HTTPS (tailscale serve)──▶ photocull API (binds 127.0.0.1 only)
                                   ├─ embedded in the Mac app   (single-machine mode)
                                   └─ photocull-serve on a home server (later)
```

Single-machine mode needs no server: everything below is opt-in.

## 1. Truth

- **Photo bytes** are immutable after ingest. The Mac is their source until a
  server holds a hash-verified copy (later phase).
- **Decisions and edits** live in the session sidecar `.photocull.json`. Every
  writer (Mac UI, embedded API, future server) does read → merge → write under
  the session-folder lock, so concurrent writers never clobber each other. Two
  writers that collide for the few milliseconds a merge takes are absorbed by a
  short retry (~250 ms) inside the sidecar store, so a 409 from the API means a
  long owner such as Finalize, not a lost race with the Mac's own save.
- Session folders must keep containing **only photos and the sidecar**.
  Finalize's cleanup refuses folders with anything else. Previews and other
  derived data live outside the inbox.

## 2. Sidecar sync stamps (additive key, Go app ignores it)

```json
{
  "version": 1,
  "decisions": {"DSCF0001": "keep"},
  "last_index": 3,
  "stamps": {"DSCF0001": {"decision": 1763650000000, "rotation": 1763650001234}}
}
```

- `stamps[STEM][field]` = Unix milliseconds of the last change to that field.
  Fields: `decision`, `crop`, `tilt`, `rotation`. Missing stamp = 0.
- Merge, per (stem, field): the larger stamp wins. An equal stamp keeps the
  value already on disk. Clearing a value (undecided, no crop, zero tilt,
  zero rotation) removes it from its map but **keeps its stamp**, so a clear
  can win over an older set.
- `last_index` is a per-device cursor: it is not merged; the writer's own
  value is written.
- `stamps` is written only when non-empty, sorted keys, same formatting as the
  other maps. Old sidecars without `stamps` load fine.

## 3. HTTP API v1

Base path `/api`. JSON, UTF-8. Every `/api` route requires
`Authorization: Bearer <token>`; static PWA files under `/` do not.
The token is a random 32-byte base64url string the host generates. Pairing
hands it to the phone in the URL fragment: `https://<host>:8443/#token=<token>`.
The PWA stores it and removes the fragment from the address bar.

The server binds `127.0.0.1` only. Remote access goes through
`tailscale serve`, which adds HTTPS on tailnet port 8443 (never 443: this Mac
may already serve another app there).

Errors: `{"error": "<message>"}` with 400 (bad input), 401 (bad or missing
token), 404 (unknown session or stem), 409 (session locked, e.g. Finalize is
running: retry later), 500.

`date` must exactly equal a session folder name returned by `GET /api/sessions`.
`stem` must exactly equal a stem in that session (uppercased). Anything else
is a 404; never build file paths from unvalidated input.

### GET /api/health
`{"ok": true, "api": 1, "name": "<host display name>"}`. Used to check a token.

### GET /api/sessions
```json
{"sessions": [{"date": "2026-11-20", "total": 120, "keep": 30, "reject": 12,
               "undecided": 78, "status": "in progress"}]}
```
Newest first. `status` is one of `empty`, `unstarted`, `in progress`, `complete`.

### GET /api/sessions/{date}
```json
{"date": "2026-11-20", "rev": "<opaque>", "last_index": 3,
 "photos": [{"stem": "DSCF0001", "hasRaw": true, "decision": "keep",
             "rotation": 1, "tilt": 0, "crop": null,
             "preview": "/api/sessions/2026-11-20/photos/DSCF0001/preview?v=<etag>"}]}
```
Photos in the same order the Mac app shows them (ascending stem).
`rev` changes whenever the sidecar changes, so clients can poll cheaply.
`decision` is always present (`undecided` when unset). `crop` is
`{"x","y","w","h"}` or null.

### GET /api/sessions/{date}/photos/{stem}/preview
`image/jpeg`, long edge ≤ 2048 px, EXIF orientation already applied, no crop,
tilt or rotation applied (the client applies `rotation`). Sends `ETag`;
honours `If-None-Match` with 304. `Cache-Control: private, max-age=31536000,
immutable` (the URL carries `?v=<etag>`).

### POST /api/sessions/{date}/changes
```json
{"changes": [{"stem": "DSCF0001", "field": "decision", "value": "keep",
              "at": 1763650000000}]}
```
- `field`: `decision` (value `keep` | `reject` | `undecided`) or `rotation`
  (value integer quarter turns 0–3). v1 accepts only these two; `crop` and
  `tilt` stay Mac-only for now.
- `at`: client Unix ms. The server clamps `at` to at most its own now + 60 s.
- Applied with the merge rule above, so replaying a queue is idempotent.
- Response: the full session body, as `GET /api/sessions/{date}`.

## 4. Previews

Mac host: generated with ImageIO from the JPG, cached at
`<parent of inbox>/.photocull-previews/<date>/<STEM>.jpg`. Regenerated when the
source JPG's size or modification time changes (recorded beside it). Lazily on
request, plus a background warm-up after ingest. A date's cache is dropped when
that session is finalized (the photos are gone). Previews are disposable.

A host without ImageIO (the Linux server) cannot generate previews: it serves
an already-cached one while that source stamp still matches, and the preview
route answers 404 otherwise. The Mac will upload previews in a later phase.

## 5. Mac "Cull from phone"

Off by default. When on, the app:
- starts the embedded API on `127.0.0.1:<port>` (default 8723) for the current
  library (LibraryMode applies unchanged: dev builds serve the dev library);
- serves the PWA from the app bundle's `Contents/Resources/pwa`. Development
  runs (any non-REAL mode) fall back to the repository's `pwa/` folder, so a
  checkout can be served without rebuilding the app; an installed build with no
  bundled PWA serves the API only;
- shows the pairing URL as a QR code;
- detects Tailscale and shows or runs `tailscale serve --bg --https=8443 http://127.0.0.1:<port>`,
  using the Mac's MagicDNS name for the URL (`https://<magicdns>:8443/`). HTTPS
  uses the dedicated tailnet port 8443, never 443 (other apps may already serve
  there). It refuses to run when 8443 already carries something else, and
  reports "HTTPS ready" when the handler already points at this port;
- holds a "prevent idle sleep" power assertion while serving, and says so only
  when the assertion was actually taken.

## 6. Home server (`photocull-serve`)

Deployment (Docker + `tailscale serve`): [HOME-SERVER.md](HOME-SERVER.md).

A headless host for a library on a Linux home server (it builds on macOS too).
It runs the same `CullServer` + `CoreCullBackend` as the app's embedded API and
the same PWA — there is no second HTTP implementation — but it owns its data
root instead of reading the app's config.

```
photocull-serve [--real --data-root PATH] [--port N] --token-file PATH [--pwa DIR]
```

- **DEV is the default.** Without `--real` the host serves the throwaway dev
  library under `~/Library/Caches/PhotoCull-Dev/`, exactly like a dev build of
  the app. DEV never takes an arbitrary folder: `--data-root` without `--real`
  is a usage error.
- **REAL needs both `--real` and `--data-root PATH`.** PATH must be absolute,
  an existing real directory (not a symlink), and hold a regular file named
  `.photocull-serve-root` that the owner creates once; the server never creates
  it. The canonical PATH is refused if it equals, contains, or sits inside the
  dev root, `~/Pictures/PhotoCull/` or `~/.config/photocull/`. REAL uses
  `PATH/inbox`, `PATH/archive` and `PATH/dump` with the default file extensions
  and finalize settings, and never reads `~/.config/photocull`. The folders are
  not created: a missing inbox is logged and serves an empty session list.
  Any of them that exists must be a real directory, not a symlink. The checks
  run once at startup, so keep PATH and its parent writable only by the
  service user.
- `--port` defaults to 8723. The host always binds the API's loopback address
  `127.0.0.1`; remote access stays `tailscale serve`'s job. There is no host flag.
- `--token-file` is required: a regular file (not a symlink), not readable or
  writable by group or others (`chmod 600`), holding the bearer token
  (whitespace-trimmed, at least 32 characters). The token is never logged.
- `--pwa DIR` serves that folder; otherwise `PWAStaticRoot.resolve(mode:)`, the
  same resolution the app uses — a REAL host with no bundled PWA serves the API
  only.
- Startup prints the mode, data root, `127.0.0.1:<port>` and the PWA folder (or
  "API only") to stderr. SIGINT/SIGTERM stop the listener cleanly.
- Exit codes: 2 for a usage error (unknown flag, missing value, bad `--port`,
  `--pwa` not a directory, `--data-root` without `--real`), 1 for a refused data
  root or unacceptable token file.
