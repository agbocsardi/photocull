# Remote culling (PWA + home server + Immich) — TODO

Contract: `docs/REMOTE-CULL.md`. Implement with Pi DeepSeek V4.1 Flash (thinking high),
review with Pi GLM-5.3 (thinking high). One worktree per task. No new tests unless asked.

## Wave 1 — single-machine phone culling (parallel)
- [x] W1-sync: sidecar `stamps`, per-field merge, locked read→merge→write store; AppState persists via merge and reloads on external sidecar change
- [x] W1-server: `PhotoCullServer` target (Hummingbird 2), API v1 routes, bearer auth, static PWA dir, backend protocol
- [x] W1-previews: `PreviewStore` in Core (2048px, cache outside inbox, invalidation, warm-up API)
- [x] W1-pwa: `pwa/` static app (session list, swipe/keys keep/reject, preload, IndexedDB offline queue, service worker, manifest)
- [x] W1-remote-ui: Settings "Cull from phone" panel, token gen/storage, QR, Tailscale detect + serve command, power assertion

## Wave 2 — wiring
- [x] W2-wire: core-backed `CullBackend` (Library + SessionStore + PreviewStore), start/stop from the panel, bundle `pwa/` into app, warm-up after ingest
- [ ] W2-e2e: run dev build headless server against seeded dev library, drive API + PWA, verify no real-data writes

## Wave 3 — home server
- [ ] Make Core build on Linux (split ImageIO/Darwin bits behind `#if canImport`)
- [ ] `photocull-serve` executable (Linux), own data root + real/dev gate, deploy on homelab (Docker, behind tailscale serve)
- [ ] Mac → server sync: previews first, then originals (JPG before RAW, skip RAW of rejects), resumable, hash-verified
- [ ] Per-file sync state; Mac cache eviction only after server hash match; card "safe to wipe" after 2 verified copies
- [ ] Decision sync Mac ↔ server via the same change API (offline queue on Mac)

## Wave 4 — Finalize on server → Immich
- [ ] Server-side Finalize (Linux port: no macOS Trash; server trash folder with retention)
- [ ] Immich upload API for keepers (checksum dedupe, RAW+JPG stack), delete own copy after confirm
- [ ] Cropped keepers: rendered on Mac before Finalize, uploaded as separate asset
- [ ] Optional Immich target for single-machine users

## Homelab facts (2026-11-20, read-only survey)
- Host reachable as ssh `uhl`, Ubuntu, x86_64, 8 cores, 7.5 GB RAM, Tailscale on
- Immich v3 compose at `~/immich-app`, port 2283, ML disabled, own v3 RAW+JPG auto-stacker (Sat 02:00)
- Immich owns uploads: `/mnt/shared/immich` (98 GB in `library/admin`); external library mount `/mnt/photoarchive` exists but is empty
- `/mnt/shared` 916 GB, 401 GB free, Samba share `[Shared]`

## Log

### 2026-11-20
- Designed architecture with owner: local-first Mac, server holds previews + originals, server Finalize → Immich upload API; Mac-as-server + tailscale serve for single-machine users.
- Wrote `docs/REMOTE-CULL.md` contract. Launching Wave 1.
- Wave 1 launched: 5 Pi DeepSeek (high) implementers in worktrees (sync, server, previews, pwa, remote-ui). Next: GLM-5.3 review per branch, fix, merge, then Wave 2 wiring.
- W1-previews merged (00ec7d2). Fixed: striped locks, remove-after-cancel doc. Waived: cross-process write race (no 2nd host yet), error/root-inbox nits.
- W1-sync merged. Fixed: verifyVisible before save, undo stale-target reload. Waived: init casing, permissive dup-stamp order.
- W1-server merged. Fixed: static symlink/NUL containment, /api prefix, concurrent start. Waived: stop-during-start (documented), at<=0 400, wording nits. Contract moved HTTPS to tailnet :8443 (Mac :443 already used by another app).
- W1-remote-ui merged after fixes (8443, timeout, surfaced failures).
- W1-pwa merged after fixes. Wave 1 complete. W2-wire running.
- W2-wire merged (de1a944). dist/PhotoCull.app (dev) bundles pwa/. Next: owner tries phone culling on dev build; decide Linux build approach (Docker on uhl recommended).
