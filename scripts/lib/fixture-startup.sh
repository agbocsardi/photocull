# Sourced by run-checks.sh. Native checks and disposable candidate preparation
# only: the app executable is copied and signed, never executed.
prepare_fixture_out() {
  local out=$1 name
  case "$out" in /private/tmp/photocull-manual-launch-*) ;; *) refuse 'Dedicated canonical launch OUT required' ;; esac
  [[ "$out" == "$(CDPATH= cd -- "$out" && pwd -P)" && "$(dirname "$out")" == /private/tmp && -O "$out" ]] || \
    refuse 'Dedicated canonical launch OUT required'
  for name in scratch cache config security pm-swift pm-clang tmp generator check-core startup operation navigation bundle evidence negative-format negative-identity negative-guard negative-preferences regressions; do
    [[ ! -e "$out/$name" && ! -L "$out/$name" ]] || refuse "Output already used: $out/$name"
  done
  mkdir "$out"/{tmp,generator,startup,bundle,evidence,negative-format,negative-identity,negative-guard,negative-preferences}
  printf 'Fixture artifacts: %s\n' "$out"
}

run_fixture_startup() (
  local OUT=$1 tool="$BUILD/fixture/generator" root kind dest status
  local FIXTURE NEG_FIXTURE APP ID
  export TMPDIR="$OUT/tmp/"
  unset PC_FIXTURE_OWNER_SPOOF
  # Shared fixtures are read-only evidence, never test targets or launch targets.
  local shared=()
  for root in /private/tmp/photocull-manual-fixture-*; do
    if [[ -d "$root" && ! -L "$root" && -O "$root" && -f "$root/manifest.json" ]]; then
      shared+=("$root")
    fi
  done
  shared_hashes() {
    # macOS Bash 3.2 treats an empty array as unset under set -u.
    for root in ${shared[@]+"${shared[@]}"}; do
      if [[ -d "$root" ]]; then find "$root" -type f -exec shasum -a 256 {} +; fi
    done | LC_ALL=C sort
  }
  shared_hashes > "$OUT/evidence/shared-before.sha256"
  FIXTURE=$(mktemp -d /private/tmp/photocull-manual-launch-XXXXXXXX)
  printf '%s\n' "$FIXTURE" > "$OUT/fixture-root.txt"
  "$tool" generate "$FIXTURE" > "$OUT/generator/generate.log" 2>&1
  mkdir "$FIXTURE/tool"
  cp "$tool" "$FIXTURE/tool/fixture"
  cp "$ROOT/Tests/Manual/README.md" "$FIXTURE/CHECKLIST.md"
  "$FIXTURE/tool/fixture" validate "$FIXTURE" > "$OUT/generator/validate-before.log" 2>&1
  if ! PC_FIXTURE_STARTUP_OUT="$FIXTURE" "$BUILD/fixture/startup" > "$OUT/startup/checks.log" 2>&1; then
    echo "Fixture startup checks failed; see $OUT/startup/checks.log" >&2; exit 1
  fi
  tail -n 1 "$OUT/startup/checks.log"
  "$FIXTURE/tool/fixture" validate "$FIXTURE" > "$OUT/generator/validate-after.log" 2>&1

  # Each negative control gets a virgin fixture and must fail with status 1.
  for kind in format identity guard preferences; do
    dest="$OUT/negative-$kind"
    NEG_FIXTURE=$(mktemp -d /private/tmp/photocull-manual-launch-XXXXXXXX)
    printf '%s\n' "$NEG_FIXTURE" > "$dest/fixture-root.txt"
    "$tool" generate "$NEG_FIXTURE" > "$dest/generate.log" 2>&1
    status=0
    PC_FIXTURE_STARTUP_OUT="$NEG_FIXTURE" "$BUILD/fixture/negative-$kind/checks" > "$dest/checks.log" 2>&1 || status=$?
    if [[ $status != 1 ]]; then
      echo "Negative control $kind returned $status, expected 1; see $dest/checks.log" >&2; exit 1
    fi
    printf 'PASS effective negative control: %s\n' "$kind" >> "$OUT/evidence/negative-controls.log"
  done

  # Separate unique bundle identity is required by production fixture startup.
  ID="local.photocull.fixture.$(uuidgen | tr '[:upper:]' '[:lower:]')"
  APP="$OUT/bundle/PhotoCullFixture.app"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$PM_BIN/PhotoCull" "$APP/Contents/MacOS/PhotoCull"
  cp "$ROOT/resources/Info.plist" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleName PhotoCull Fixture' "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName PhotoCull Fixture' "$APP/Contents/Info.plist"
  for name in PhotoCull.icns PhotoCullMenuBar.png; do
    if [[ -f "$ROOT/resources/$name" ]]; then cp "$ROOT/resources/$name" "$APP/Contents/Resources/"; fi
  done
  plutil -lint "$APP/Contents/Info.plist" > "$OUT/bundle/plist.log"
  codesign --force --sign - "$APP" > "$OUT/bundle/sign.log" 2>&1
  codesign --verify --deep --strict "$APP" > "$OUT/bundle/verify.log" 2>&1
  codesign --display --verbose=4 "$APP" > "$OUT/bundle/identity.log" 2>&1
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" == "$ID" ]]
  grep -Fx "Identifier=$ID" "$OUT/bundle/identity.log" > "$OUT/bundle/identity-match.log"
  printf '%s\n' "$ID" > "$OUT/bundle/identifier.txt"
  shasum -a 256 "$APP/Contents/MacOS/PhotoCull" > "$OUT/bundle/executable.sha256"
  git -C "$ROOT" rev-parse HEAD > "$OUT/source-commit.txt"
  shasum -a 256 "$ROOT"/Sources/PhotoCullCore/*.swift "$ROOT"/Sources/PhotoCullApp/*.swift > "$OUT/evidence/source-sha256.txt"
  shared_hashes > "$OUT/evidence/shared-after.sha256"
  cmp "$OUT/evidence/shared-before.sha256" "$OUT/evidence/shared-after.sha256"
  printf 'PASS shared fixtures byte-unchanged; never launched candidate or ordinary app.\n' > "$OUT/evidence/shared-preservation.log"
  printf 'PASS preparation/checks. Candidate (NOT launch-cleared): %s\nFixture: %s\n' "$APP" "$FIXTURE"
  printf 'Proposed ONLY after parent review + user GUI authorization:\n"%s/Contents/MacOS/PhotoCull" --fixture-config "%s/config/config.toml"\n' "$APP" "$FIXTURE" > "$OUT/proposed-launch.txt"
)
