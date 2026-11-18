#!/usr/bin/env bash
# Build PhotoCull.app — a real macOS app bundle assembled from the SwiftPM product.
# Usage: scripts/build-app.sh [debug|release]
# Optional env: UNIVERSAL=1 builds arm64+x86_64 (needs Xcode); VERSION=1.2.3 stamps Info.plist.
set -euo pipefail

CONF="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ARCH_FLAGS=()
if [ "${UNIVERSAL:-0}" = 1 ]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

echo "==> swift build -c $CONF --product PhotoCull ${ARCH_FLAGS[*]:-}"
swift build -c "$CONF" --product PhotoCull ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}

BIN="$(swift build -c "$CONF" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"
APP="$ROOT/dist/PhotoCull.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/PhotoCull" "$APP/Contents/MacOS/PhotoCull"
cp "$ROOT/resources/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/PhotoCull"
if [ -n "${VERSION:-}" ]; then
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "${BUILD_NUMBER:-$VERSION}" "$APP/Contents/Info.plist"
fi

# App icon (build it first with scripts/build-icon.sh)
if [ -f "$ROOT/resources/PhotoCull.icns" ]; then
  cp "$ROOT/resources/PhotoCull.icns" "$APP/Contents/Resources/PhotoCull.icns"
else
  echo "note: resources/PhotoCull.icns missing — run scripts/build-icon.sh"
fi
if [ -f "$ROOT/resources/PhotoCullMenuBar.png" ]; then
  cp "$ROOT/resources/PhotoCullMenuBar.png" "$APP/Contents/Resources/PhotoCullMenuBar.png"
else
  echo "note: resources/PhotoCullMenuBar.png missing — run scripts/build-icon.sh"
fi

# Ad-hoc signature so macOS treats it as a normal app.
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "note: ad-hoc codesign skipped"

echo "==> built $APP"
