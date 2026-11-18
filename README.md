# PhotoCull

PhotoCull is a native Mac app for photographers who shoot RAW+JPG and want to choose their keepers before importing into Apple Photos or Lightroom.

## Install

PhotoCull runs on macOS 14 or later, on Apple silicon and Intel Macs. Download the DMG from [Releases](https://github.com/agbocsardi/photocull/releases), open it, and drag **PhotoCull** into **Applications**. Launch it from there, not from the disk image. The app is unsigned: if macOS blocks the first launch, go to **System Settings → Privacy & Security** and choose **Open Anyway** once.

## Your first shoot

1. **Ingest.** Choose your SD card or a folder. PhotoCull copies the photos into the inbox, grouped by capture date. Each date is a session in the sidebar.
2. **Cull.** Open a session. Use `→` and `←` to browse the JPGs, `z` to keep and `x` to reject. Press the same letter again to undo the mark. The decision covers the matching RAW too.
3. **Adjust if needed.** Press `c` to crop or straighten a photo, then `Return` to apply. You can also rotate it using the photo toolbar.
4. **Finalize.** Right-click a session and choose **Finalize** to review the counts. When you confirm, keepers move to the archive and rejects move to the Mac Trash, each with their paired RAWs. **Undecided photos count as keepers.** You can also export keeper JPG copies, cropped or original, ready to import into Apple Photos.

PhotoCull works with local files. It isn't a catalog, RAW editor or video tool: you judge the camera's JPG, not a rendering of the RAW. PhotoCull doesn't upload your photos.

## Folders and controls

By default, sessions are in `~/Pictures/PhotoCull/inbox`, archived keepers are in `~/Pictures/PhotoCull/archive`, and exported JPGs go into dated folders in `~/Downloads`. Change any of these in **PhotoCull → Settings** (`⌘,`). Changing a folder doesn't move existing files.

The **Getting Started** guide opens on first launch and is available again from **Help**. Every action has a mouse path. Open **Controls** (`?`) to see the shortcuts alongside the buttons and menus that do the same thing.

## Safety

Ingest copies rather than moves, so the card stays untouched. Crops, tilt and rotation are saved beside the photos, never written into the originals. Rejects stay recoverable until you empty the Trash. If Finalize stops partway through, some files may already have moved. Follow the [manual recovery steps](docs/DEVELOPMENT.md#recovering-from-a-failed-finalize) before retrying.

## Building from source

See the [development guide](docs/DEVELOPMENT.md) for build and test commands.
