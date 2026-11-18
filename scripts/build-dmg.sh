#!/usr/bin/env bash
# Build dist/PhotoCull.dmg — the standard drag-to-Applications installer.
# Runs build-app.sh first, then stages PhotoCull.app plus an /Applications
# symlink and packs them into a UDZO image with hdiutil. Nothing is mounted
# and nothing is copied into /Applications by this script.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DMG="$ROOT/dist/PhotoCull.dmg"

"$ROOT/scripts/build-app.sh" release

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$ROOT/dist/PhotoCull.app" "$STAGE/PhotoCull.app"
ln -s /Applications "$STAGE/Applications"

echo "==> hdiutil create $DMG"
hdiutil create -volname PhotoCull -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "==> built $DMG"
echo "Verify with: hdiutil imageinfo '$DMG'"
