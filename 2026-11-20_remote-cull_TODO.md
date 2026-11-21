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
- [x] L1-core: Core + Server + Host + tests build on Linux (swift:6.1-noble Docker); Darwin/ImageIO behind `#if canImport`; macOS-only app target; Linux PreviewStore serves cached previews only
- [x] L2-serve: `photocull-serve` executable, own data root, DEV default + REAL behind `--real` + marker file
- [x] L3-deploy: Dockerfile + compose (host network, 127.0.0.1) for the home server, tailscale serve :8443 docs, dev-mode e2e against the container
- [ ] Owner: verify macOS build/tests on the Mac after L1 (`scripts/test.sh`) — not checkable on Linux
- [ ] Owner: create REAL data root + token on the home server and start the service (docs/HOME-SERVER.md); pick a free tailnet port and check for an existing serve handler on the backend port
- [ ] Mac → server sync: previews first, then originals (JPG before RAW, skip RAW of rejects), resumable, hash-verified
- [ ] Per-file sync state; Mac cache eviction only after server hash match; card "safe to wipe" after 2 verified copies
- [ ] Decision sync Mac ↔ server via the same change API (offline queue on Mac)

## Wave 4 — Finalize on server → Immich
- [ ] Server-side Finalize (Linux port: no macOS Trash; server trash folder with retention)
- [ ] Immich upload API for keepers (checksum dedupe, RAW+JPG stack), delete own copy after confirm
- [ ] Cropped keepers: rendered on Mac before Finalize, uploaded as separate asset
- [ ] Optional Immich target for single-machine users

## Homelab facts (2026-11-20, read-only survey)
- Ubuntu x86_64 home server, 8 cores, 7.5 GB RAM, Tailscale on, Docker
- Immich v3 via compose, ML disabled, own RAW+JPG auto-stacker; Immich owns its upload library (never put PhotoCull data inside it)
- Shared data disk with ~400 GB free

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
- W2-wire merged (de1a944). dist/PhotoCull.app (dev) bundles pwa/. Next: owner tries phone culling on dev build; decide Linux build approach (Docker on the home server recommended).

### 2026-11-21
- Working on the home server itself (no Swift on host): build/verify Linux in `swift:6.1-noble` Docker. Baseline: PhotoCullServer already builds on Linux; Core fails on Darwin/ImageIO.
- Plan: L1-core first (blocker), then L2-serve + L3-deploy in parallel against a fixed CLI contract. Implement: Pi DeepSeek V4.1 Flash (high); review: Pi GLM-5.3 (high).
- L1-core merged. Review clean on code; fixed: Linux docs now use swift:6.2-noble (6.1 can't parse Hummingbird 2.29's tools-version and re-resolves Package.resolved). Waived: st_dev Int32 truncation in FinalizeIdentity (needs same inode+type across devices sharing low 32 bits), Ingest mtime re-apply `try?` (only affects EXIF-less fallback dates on Linux), Config fstat error text. L2-serve running.
- L2-serve merged (a3c0991). Fixed: REAL gate refuses symlinked inbox/archive/dump (a symlinked inbox could write sidecars into the real library); docs say root + parent must be writable only by the service user (checks run once). Waived: dead `?? ""` on token path, `--port=N` form unsupported. PID-1 signal handling covered by compose `init: true`. L3-deploy in review.
- L3-deploy merged (2e55ba3). Review: no high/medium. Fixed: docs set env vars before using them, warn about an existing serve handler on the backend port, .env excluded from build context, restart-loop-on-refusal noted. Final check on merged main (swift:6.2-noble): build OK, 312 checks PASS, Package.resolved untouched, image builds. Not pushed. Next: owner verifies macOS (`scripts/test.sh`) and deploys; then Mac -> server sync (previews first).
