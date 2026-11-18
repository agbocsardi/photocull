# PhotoCull agent rules

AI agents develop this app on the owner's machine. The owner's real photo library
(`~/Pictures/PhotoCull`) and real config (`~/.config/photocull`) are LIVE DATA.

## Hard rules

- **Never write under `~/Pictures` or `~/.config/photocull`.** Do not create,
  modify, or delete anything there, in any script, build step, or command.
- **Never install into `/Applications` or `~/Applications`**, and never copy or
  move the app there. Do not mount a built DMG with the intent of installing.
- **Never run the installed app** (the copy in `/Applications`), and never launch
  any PhotoCull binary in a way that could reach real data.
- Dev builds are automatically sandboxed to the dev library at
  `~/Library/Caches/PhotoCull-Dev/` (see `Sources/PhotoCullCore/LibraryMode.swift`
  and the README "Install" section): `swift run`, `.build/*/PhotoCull`,
  `dist/PhotoCull.app` and DMG-attached copies all resolve to DEV mode and cannot
  touch the real library or config. The only REAL-mode executable is
  `/Applications/PhotoCull.app` (or `~/Applications/PhotoCull.app`) with bundle id
  `local.photocull.swift` — and launching that is the owner's job, not an agent's.
- Setting `HOME` provides NO isolation: `NSHomeDirectory()` ignores it. The mode
  gate is the only isolation. After changing startup/config code, verify with
  `find ~/Pictures/PhotoCull ~/.config/photocull -newer <marker>` (marker created
  before the run) that nothing real changed.

## Headless checks

- Run `scripts/test.sh` for everyday changes and `scripts/check-all.sh` before a release.
- For startup, config, `LibraryMode` or fixture changes, add `--with-fixture-startup`
  to `scripts/check-all.sh`. It prepares a disposable candidate but never launches it.
- The release workflow runs only `swift run PhotoCullTests`.

## Why

Dev runs must never be able to reach real data. The library-mode gate enforces
that; do not weaken it: fixture mode (`StartupConfiguration`) takes precedence,
and DEV is the default for anything that is not the installed bundle.
