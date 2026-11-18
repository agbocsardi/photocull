# PhotoCull (Swift)

A native macOS app for the full RAW+JPG photo culling workflow: ingest from an SD card,
cull with the keyboard, crop non-destructively, and finalize — archiving keepers, trashing
rejects with their paired RAWs, and dropping keep-JPGs into a folder ready for Apple Photos.

This is a Swift/SwiftUI port of the Go web app in `../photocull`. It shares the same config
file, the same directory layout, and the same `.photocull.json` sidecar format, so both apps
can work on the same library.

## Status

Working end to end, covered by the automated checks below.

| Area | State |
|------|-------|
| Ingest (SD card, EXIF dates, collision-safe copy) | done |
| Sessions sidebar, filters, multi-select | done |
| Cull (keep/reject/undecided, vim keys, filmstrip) | done |
| EXIF inspector | done |
| Preview (zoom, pan, fit, 1:1) | done |
| **Non-destructive crop** (new in the Swift port) | done |
| Finalize (single + multi-session, Trash, archive, dump) | done |
| Menu bar extra with ingest progress | done |
| RAW pair repair tool | done |
| App icon (SVG to .icns) | done |
| Native macOS design pass | done |

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

## Install

Download the latest `PhotoCull-<version>.dmg` from
[Releases](https://github.com/agbocsardi/swift-photocull/releases), open it, and drag
**PhotoCull** onto **Applications**. Builds aren't signed with an Apple Developer ID, so
the first launch is blocked: open **System Settings → Privacy & Security** and click
**Open Anyway**. Requires macOS 14 or later.

To build the DMG yourself:

```bash
./scripts/build-dmg.sh         # runs build-app.sh, then packs dist/PhotoCull.dmg
open dist/PhotoCull.dmg       # then drag PhotoCull.app onto the Applications folder
```

**Releasing:** push a tag such as `v1.1.0`. `.github/workflows/release.yml` runs the tests,
builds a universal (Apple silicon + Intel) DMG and publishes it as a GitHub Release.

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
PhotoCull --check         # headless diagnostic against the real inbox
PhotoCull --repair-pairs  # dry run: report RAW files broken by the old naming bug
PhotoCull --repair-pairs --apply
```

### Getting started

On first launch PhotoCull shows a short **Getting Started** guide — what the
app is for, the Ingest → Cull → Crop → Finalize workflow, where files live,
and the safety promises (the card is never modified, originals are never
modified, rejects go to the Trash). Reopen it any time from the toolbar
**Help** menu or **Help ▸ PhotoCull Getting Started**.

**Controls** (`?`) lists every action with both its key and its mouse path —
every button in the photo bar and the crop bar is named there, so the app is
fully drivable without memorising a single key.

## Layout

```
+---------------------------------------------------------------+
| traffic lights   [3/81] DSCF0679.JPG  UNDECIDED  +RAF   ingest |
+--------------+--------------------------------+---------------+
| (1) SESSIONS | (2) CANVAS            100%      | (3) INFO      |
| 2026-08-18   |                                | PHOTO         |
| 2026-08-16   |        [ the photo ]           | CAMERA        |
| 2026-08-15   |                                | CULL          |
|              |   ( keep reject crop zoom )    | LOCATION      |
|              +--------------------------------+               |
|              | (4) FILMSTRIP        3 of 81   |               |
+--------------+--------------------------------+---------------+
| z keep  x reject  c crop  j/k next/prev  :f finalize ...      |
+---------------------------------------------------------------+
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
inspect the interface from a terminal or an agent context.

## Keyboard

| Key | Action |
|-----|--------|
| `z` / `x` | mark keep / reject (press again to undo) |
| `j` / `k` | next / previous photo |
| `→` / `←` | next / previous photo (in any pane) |
| `↓` / `↑` | next / previous photo, or session when pane 1 has focus (stepping onto a session opens it) |
| `J` / `K` | next / previous **undecided** photo |
| `c` | enter crop mode |
| `o` | open the current JPG in Preview |
| `f` | reveal in Finder |
| `+` / `-` / `0` | zoom in / out / fit |
| `1`-`4` | focus sidebar, canvas, info, filmstrip |
| `Tab` | cycle the session filter (pane 1) |
| `Space` | select a session for multi-finalize (pane 1) |
| `Enter` | open the selected session / apply the crop |
| `:f` `:F` `:i` `:c` `:R` `:q` | finalize / finalize all / ingest / crop / repair pairs / quit |
| `?` | controls |

**Crop mode:** arrows move the region, `Shift`+arrows resize, drag the handles with the mouse,
`a` cycles the aspect ratio, `r` resets to full frame, `p` toggles the cropped preview,
`Enter` applies, `Esc` cancels.

## Mouse

Use these controls to cull and crop without memorising shortcuts:

- **Floating action bar** over the photo: previous / next / next undecided
  flanking keep / reject, then crop, cropped preview, rotation, zoom and fit,
  and Open in Preview / Reveal in Finder. At the app's minimum window width
  the bar wraps into two rows instead of dropping actions; the navigation
  buttons dim at the ends of the session.
- **Crop toolbar** (shown while crop mode is open): pick the aspect ratio from
  the RATIO menu (or cycle with `a`), reset the region to the full frame,
  choose whether to show the cropped preview after applying, drag the tilt slider — click it to focus it and
  then use the arrow keys — or reset the tilt, then Apply or Cancel, the
  same as `Enter` / `Esc`. Drag the region and its handles to move and resize.
- **Status bar**: every key hint is a button that runs the same action —
  `z keep` marks keep, `:f finalize` opens the finalize sheet, `1-4 pane`
  cycles pane focus, `tab filter` cycles the session filter, `? help` opens
  the help. In crop mode the hints run the crop actions.
- Click a session in the sidebar to open it (same as stepping onto it with the
  keyboard), `⌘`-click to mark it for multi-finalize (same as `Space`), and
  click a filmstrip thumbnail to jump to a photo. Clicking any pane gives it
  focus (same as `1`–`4`), so `↑`/`↓` afterwards move the session cursor or the
  photo cursor accordingly. Right-click a session for open / finalize /
  multi-select.

## Crop is non-destructive

A crop is stored as a normalised rectangle in `.photocull.json` next to the cull decisions.
**The original JPG and RAW are never modified.** The crop is applied only when the finalize
step writes a keep-JPG into the dump folder; you can choose "originals" instead in the
finalize sheet. `Esc` or "Clear" in the inspector removes a crop.

## Data compatibility

| Thing | Location |
|-------|----------|
| Config | `~/.config/photocull/config.toml` (TOML, shared shape with the Go app plus a `[finalize]` section) |
| Finalize defaults | `[finalize]` in the config — `export_jpgs` (keeper JPG copies on/off), `crop_export` (`crop`/`original`) |
| Inbox | `~/Pictures/PhotoCull/inbox/<YYYY-MM-DD>/` |
| Archive | `~/Pictures/PhotoCull/archive/<YYYY-MM-DD>/` |
| Dump | `~/Downloads/<date>/` (or `<first> to <last>` for multi-session) |
| Session state | `<date>/.photocull.json` — `version`, `decisions`, `last_index`, plus `crops` |
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
4. Delete `.photocull-recovery.json` and the (now file-free) claims folder, then finalize again.

## Not implemented

- RAW decoding for display. RAW files are paired, moved and trashed, but only JPGs render.
  (Core Image could decode RAF/RW2 if wanted — `ImagePipeline` already goes through ImageIO.)
- Video files.
- Duplicate detection across sessions.

## Development notes

- `Sources/PhotoCullCore/` — no UI. Config, session sidecar, file pairing, EXIF, ingest,
  finalize, image pipeline, pair repair. Fully unit-tested.
- `Sources/PhotoCullApp/` — SwiftUI. `AppState` owns the whole cull model and dispatches keys;
  views are thin. `KeyMonitor` installs one `NSEvent` local monitor.
- `docs/CORE-SPEC.md` — the behaviour spec the core was implemented against.
- `docs/DESIGN.md` — the UX/visual design pass.
