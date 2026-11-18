# PhotoCull development

## Build

Requires macOS 14+ and the Swift toolchain. No Xcode project — this is a SwiftPM package,
and the app bundle is assembled by a script.

```bash
swift build                 # build the package
swift run PhotoCullTests    # run the core test suite (exit 0 = pass)
./scripts/build-icon.sh     # optional: rebuild resources/PhotoCull.icns from icon/icon-a.svg
./scripts/build-app.sh      # build dist/PhotoCull.app
open dist/PhotoCull.app
```

XCTest is not available in a CommandLineTools-only toolchain, so tests run through a small
custom harness (`Sources/PhotoCullTests/Harness.swift`) rather than `swift test`.

### Headless checks

```bash
./scripts/test.sh                            # everyday: core and focused checks
./scripts/check-all.sh                       # same checks once each, before releases
./scripts/check-all.sh --with-fixture-startup  # add startup checks and negative controls
```

Both commands build the package in debug mode with SwiftPM in `.build/` and
reuse focused check binaries in `.build/checks/`. Core tests send rejects to
synthetic Trash inside the temporary fixtures, never to macOS Trash.
Run with `--with-fixture-startup` for startup, config, `LibraryMode`, or fixture changes.
This also prepares a disposable app bundle for review; it never launches PhotoCull.
The release workflow still runs only `swift run PhotoCullTests`.

The individual `scripts/check-*.sh` commands remain available. They use fresh
synthetic data in `/tmp`, outside the build cache. To retain artifacts from a
regular check, set `OUT` to a dedicated absolute directory under `/tmp`; the
script creates a fresh child there. The standalone `check-finalize-safety.sh`
requires `OUT`. The fixture-startup script retains its logs
and candidate in a separate `/private/tmp/photocull-manual-launch-*` directory.

## Packaging and releases

To build the DMG yourself:

```bash
./scripts/build-dmg.sh         # runs build-app.sh, then packs dist/PhotoCull.dmg
open dist/PhotoCull.dmg       # then drag PhotoCull.app onto the Applications folder
```

**Releasing:** push a tag such as `v1.1.0`. `.github/workflows/release.yml` runs the tests,
builds a universal (Apple silicon + Intel) DMG and publishes it as a GitHub Release.

## LibraryMode and the development library

The DMG contains `PhotoCull.app` and an `Applications` symlink — the standard macOS
drag-to-Applications install. **Only the app installed in `/Applications` (or
`~/Applications`) uses your real library** (`~/Pictures/PhotoCull`, `~/.config/photocull`).

Every other executable is a **dev build** — `swift run`, `.build/*/PhotoCull`,
`dist/PhotoCull.app`, anything run from a mounted DMG — and is hard-sandboxed to a
throwaway library at `~/Library/Caches/PhotoCull-Dev/` (config, inbox, archive and
export all live under it, and a dev config pointing outside that root is
regenerated). Dev builds show a **DEV LIBRARY** badge in the toolbar and their
preferences go to a separate `local.photocull.swift.dev` suite, so a development
run can never read or write the real library or real config. Delete the folder to
reset it; `scripts/seed-dev-library.sh` fills the dev inbox with synthetic
JPG+RAW sessions.

### Known toolchain constraint

The `@State` SwiftUI macro needs the `SwiftUIMacros` plugin, which ships only with Xcode.
On a CommandLineTools-only machine, `@State` fails to expand. This project therefore uses
`@StateObject` plus the tiny `ViewState` wrapper in `Theme.swift` instead. Do not introduce
`@State`, `@Entry`, or `@Animatable`.

## Usage

```bash
PhotoCull                 # launch the app
PhotoCull --check         # headless diagnostic against the active library
PhotoCull --repair-pairs  # dry run: report RAW files broken by the old naming bug
PhotoCull --repair-pairs --apply
```

## Design

The app follows Apple's Human Interface Guidelines rather than the Go web app's terminal
aesthetic. `Sources/PhotoCullApp/Theme.swift` is the whole design system:

| Concern | Approach |
|---------|----------|
| Layout | `NavigationSplitView` — sidebar (sessions) + content (canvas, filmstrip) + `.inspector` (info) |
| Chrome | Real unified toolbar; traffic lights and the drag zone behave natively |
| Type | SF Pro on Apple's scale (13pt body). SF Mono only for filenames, paths and keycaps. Nothing below 9pt |
| Colour | Semantic system colours, following macOS by default; the toolbar Appearance menu can override Light or Dark |
| Depth | Materials/vibrancy for sidebar, inspector, filmstrip and status bar; layered shadows on floating chrome |
| Spacing | One `Metric.paneInset` (16pt) shared by all four panes, on an 8pt grid |

**Panes are numbered 1-4** (Sessions, Canvas, Info, Filmstrip) and addressable with those keys.
Each header shows its numeral, and the numeral lights up in the accent colour while that pane
has keyboard focus. Panes must not contain raw spacing numbers — everything routes through
`Metric` / `Typo` / `Palette`.

The icon (`icon/icon-a.svg`) pairs a six-blade camera iris with a distinct amber
scythe: camera first, scythe second. The menu bar uses a transparent monochrome outline
of the same motif (`icon/menubar-outline.svg`), tinted by macOS like other status icons.
Build both with `scripts/build-icon.sh`, which rasterizes SVG through AppKit (no third-party
renderer) into `resources/PhotoCull.icns` and `resources/PhotoCullMenuBar.png`.

### Appearance

Use the **Appearance** button in the toolbar to choose **System** (default), **Light**, or
**Dark**. System follows macOS as it changes. An override applies only to PhotoCull and is
saved in its app preferences (`PhotoCull.appearance`); it does not change the Go app's config.
The menu-bar outline remains a system-tinted template icon in every mode.

### Settings

Open **PhotoCull > Settings** (⌘,) to edit `config.toml`.

- **Folders:** Use **Choose…** to change the inbox, archive or exports folder.
  Use **Reveal** to find it in Finder. PhotoCull uses the new folder without
  moving or renaming existing files.
- **Files:** Separate RAW and JPG extensions with commas. PhotoCull saves them
  in uppercase without dots. Files pair by filename, excluding the extension.
- **Finalize:** Turn JPG export on or off and choose cropped or full-frame
  copies. You can change the crop option in the Finalize sheet.
- **General:** Set PhotoCull’s appearance or reveal the configuration file.
  **Restore Defaults** resets the configuration, not appearance.

Settings shows invalid or overlapping folder paths and empty or overlapping
extension lists. **Apply** is unavailable while there are errors or a bulk
file operation is running. Apply saves the configuration and reloads the
library. It creates missing folders and saves home paths as `~/…`.

The configuration is read-only in disposable fixture mode. Safety checks do
not change it. `--check` can write a default configuration if the file is
missing or unreadable — in development builds only the dev library's. In a
development build, Settings accepts only folders inside the dev library.

### Verifying the UI without Screen Recording permission

```bash
swift build
.build/debug/PhotoCull --snapshot /tmp/ui.png --appearance dark   # renders its own window to PNG
.build/debug/PhotoCull --snapshot /tmp/crop.png --crop            # with crop mode open
```

An app may snapshot its own window without Screen Recording permission, so this is the way to
inspect the interface from a terminal.

## Data compatibility

| Thing | Location |
|-------|----------|
| Config | `~/.config/photocull/config.toml` (TOML, shared shape with the Go app plus a `[finalize]` section) |
| Finalize defaults | `[finalize]` in the config — `export_jpgs` (keeper JPG copies on/off), `crop_export` (`crop`/`original`) |
| Inbox | `~/Pictures/PhotoCull/inbox/<YYYY-MM-DD>/` |
| Archive | `~/Pictures/PhotoCull/archive/<YYYY-MM-DD>/` |
| Dump | `~/Downloads/<date>/` (or `<first> to <last>` for multi-session) |
| Session state | `<date>/.photocull.json` — `version`, `decisions`, `last_index`, plus optional crop, tilt and rotation maps |
| Repair logs | `~/.config/photocull/pair-repair-<timestamp>.json` |

`crops` is additive: the Go app ignores it, and this app ignores nothing the Go app writes.

## Deliberate divergences from the Go app

1. **Ingest collision naming.** Go counted collisions per uppercased *stem*, so ingesting
   `DSCF0001.JPG` and `DSCF0001.RAF` in one run renamed the RAW to `DSCF0001_2.RAF` and
   destroyed the pair. This port counts collisions per full filename, which still handles the
   case Go's tests describe (the same filename from two camera folders) but keeps pairs intact.
   `--repair-pairs` fixes libraries already damaged by the old rule.
2. **`j`/`k` direction.** The Go app's `keys.js` maps `j` to *previous* while its own README
   and footer say next/previous. This port uses the vim convention: `j` = next, `k` = previous.
3. **RAW extension defaults.** Go shipped only `RAF` and `RW2`; the port's defaults cover
   the common camera brands (RAF, RW2, CR2, CR3, NEF, ARW, DNG, ORF, PEF) so a stock
   config pairs most libraries. An existing config file keeps whatever it lists, and
   the extension lists are editable in the Settings window.
4. **Finalize cleans up sidecar-only folders.** After a successful Finalize, PhotoCull
   checks the pinned inbox folder. It only unlinks `.photocull.json` if it is the sole
   entry and is a regular, single-link file. Recovery records, claims and other files
   prevent cleanup. If a late arrival prevents the folder from being removed, the folder
   is reported as retained; cleanup does not fail Finalize. Use *Cull ▸ Remove Empty
   Sessions…* to review and remove older sidecar-only leftovers, or right-click an empty
   session row to check that session alone.
5. **Pair-consistent collision names.** If either the JPG or the RAW name already exists in
   the archive, both get the same `_2` suffix so the pair stays together.
6. **No silent re-run after a failed Finalize.** See *Recovering from a failed Finalize*.

## Recovering from a failed Finalize

If a Finalize is interrupted (crash, full disk, failed export), PhotoCull leaves a
`.photocull-recovery.json` and a `.photocull-claims-…` folder in that session's inbox folder
and refuses to finalize the session again until you resolve them:

1. Open the session folder in Finder (right-click the session, or *Reveal in Finder*).
2. Read `.photocull-recovery.json`: it lists every planned move. The claims folder's
   `.progress.jsonl` records which steps completed.
3. Move any photo files found inside the claims folder back into the session folder
   (they were claimed but not yet archived or trashed). Check the archive and Trash for
   pairs that already moved.
   Check the exports folder too. Do not overwrite a file to reunite a pair; account for both originals first.
4. Only after reconciling all planned moves, delete `.photocull-recovery.json` and the (now file-free) claims folder, then finalize again.

## Development notes

- `Sources/PhotoCullCore/` — no UI. Config, session sidecar, file pairing, EXIF, ingest,
  finalize, image pipeline, pair repair. Fully unit-tested.
- `Sources/PhotoCullApp/` — SwiftUI. `AppState` owns the whole cull model and dispatches keys;
  views are thin. `KeyMonitor` installs one `NSEvent` local monitor.
- `docs/CORE-SPEC.md` — the behaviour spec the core was implemented against.
- `docs/DESIGN.md` — the UX/visual design pass.
