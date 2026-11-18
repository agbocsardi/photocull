#!/usr/bin/env bash
# Seed the DEV library (~/Library/Caches/PhotoCull-Dev) with synthetic photos:
# two sessions, the second with .RAF twins so JPG+RAW pairing can be exercised.
# Reuses the Tests/Manual/ManualFinalizeFixture.swift generator for the JPGs.
# Only ever writes under ~/Library/Caches/PhotoCull-Dev — never ~/Pictures or
# ~/.config. Remove ~/Library/Caches/PhotoCull-Dev to reset the dev library.
set -euo pipefail

REPO=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
DEV_ROOT="$HOME/Library/Caches/PhotoCull-Dev"

WORK=$(mktemp -d /private/tmp/photocull-manual-fixture-XXXXXXXX)
trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK" CLANG_MODULE_CACHE_PATH="$WORK/clang-cache" SWIFTPM_MODULECACHE_OVERRIDE="$WORK/swift-cache"
mkdir -p "$WORK/tool" "$WORK/swift-cache" "$WORK/clang-cache"

# Compile the same synthetic-photo generator the manual fixture uses.
CORE=(LibraryMode Config Session FilePair Library Exif ImagePipeline FinalizeSafety Finalize)
SOURCES=(); for name in "${CORE[@]}"; do SOURCES+=("$REPO/Sources/PhotoCullCore/$name.swift"); done
swiftc -O -swift-version 5 -package-name PhotoCullManualFixture -parse-as-library \
  -module-cache-path "$WORK/swift-cache" -Xcc "-fmodules-cache-path=$WORK/clang-cache" \
  "${SOURCES[@]}" "$REPO/Tests/Manual/ManualFinalizeFixture.swift" \
  -o "$WORK/tool/fixture" > "$WORK/build.log" 2>&1
"$WORK/tool/fixture" generate "$WORK" > "$WORK/generate.log" 2>&1

SEED="$WORK/inbox/2024-05-03"
rm -rf "$DEV_ROOT/inbox/2024-05-03" "$DEV_ROOT/inbox/2024-05-04"
mkdir -p "$DEV_ROOT/inbox"
# Session 1: the generated synthetic JPGs, fresh (no decisions sidecar).
cp -R "$SEED" "$DEV_ROOT/inbox/2024-05-03"
# Session 2: the same photos a day later, with an .RAF twin per JPG. RAW files
# are paired, moved and trashed but never decoded, so a byte copy of the JPG
# is a perfectly good synthetic RAW for the dev library.
cp -R "$SEED" "$DEV_ROOT/inbox/2024-05-04"
for jpg in "$DEV_ROOT/inbox/2024-05-04"/*.JPG; do
  cp "$jpg" "${jpg%.JPG}.RAF"
done

echo "Seeded dev library:"
find "$DEV_ROOT/inbox" -type f | sort
echo "Run any dev build (e.g. swift run, or dist/PhotoCull.app) to cull it."
