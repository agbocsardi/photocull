#!/bin/bash
set -euo pipefail
umask 077
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
BUILD="$ROOT/.build/checks"

refuse() { echo "$*" >&2; exit 2; }

# Hold the lock through execution as well as compilation: Finalize also
# launches a probe of its own cached runner.
if [[ ${1:-} != --locked ]]; then
  [[ ! -L "$ROOT/.build" && ! -L "$BUILD" && ! -L "$BUILD/lock" ]] || refuse 'Check cache must not contain symlinks'
  mkdir -p -- "$BUILD"
  exec /usr/bin/lockf -k "$BUILD/lock" /bin/bash "$0" --locked "$@"
fi
shift
# Check under the lock before using any cached paths. Include dangling links.
link=$(/usr/bin/find -P "$BUILD" -type l -print -quit)
[[ -z "$link" ]] || refuse "Check cache must not contain symlinks: $link"

mode=${1:?check group required}
usage() {
  case "$mode" in
    all) refuse 'usage: check-all.sh [--with-fixture-startup]' ;;
    *) refuse "usage: check-$mode.sh" ;;
  esac
}
shift
fixture=false
regular=(core edit-rendering image-loading navigation finalize-core finalize-descriptors finalize-operation ingest-collectors)
case "$mode" in
  all)
    case $# in
      0) ;;
      1) [[ "$1" == --with-fixture-startup ]] || usage; fixture=true ;;
      *) usage ;;
    esac
    group=("${regular[@]}") ;;
  fixture-startup) group=(finalize-operation navigation); fixture=true ;;
  finalize-safety)
    [[ -n ${OUT:-} ]] || refuse 'OUT must be an absolute dedicated output directory'
    group=(core finalize-core finalize-descriptors finalize-operation navigation) ;;
  finalize-planning) group=(core finalize-core) ;;
  ingest-collectors) group=(core ingest-collectors) ;;
  edit-rendering|image-loading|navigation) group=("$mode") ;;
  *) usage ;;
esac
[[ "$mode" == all || $# == 0 ]] || usage

make_run_root() {
  local requested=${OUT:-} parent name
  if [[ -z "$requested" ]]; then
    mktemp -d /private/tmp/photocull-checks-XXXXXXXX
    return
  fi
  [[ "$requested" == /* ]] || refuse 'OUT must be absolute'
  requested=${requested%/}
  name=${requested##*/}
  [[ -n "$name" && "$name" != . && "$name" != .. ]] || refuse 'Dedicated OUT required'
  parent=$(CDPATH= cd -- "$(dirname -- "$requested")" && pwd -P) || refuse 'OUT parent must exist'
  case "$parent" in
    /private/tmp|/private/tmp/*) ;;
    *) refuse "OUT must be a dedicated directory under /tmp: $requested" ;;
  esac
  requested="$parent/$name"
  [[ ! -L "$requested" && "$requested" != "$ROOT" && "$requested" != "$ROOT/"* ]] || \
    refuse "Refusing symlink/source output root: $requested"
  mkdir -p -- "$requested"
  [[ -O "$requested" ]] || refuse "OUT must be owned by the caller: $requested"
  if [[ "$mode" == finalize-safety ]]; then
    # Continue rejecting previously used legacy build/fixture paths. Never
    # delete caller-owned files; even caller-supplied OUT gets a fresh child.
    local name
    for name in scratch cache config security pm-swift pm-clang core-swift core-clang fd-swift fd-clang app-swift app-clang nav-swift nav-clang synthetic; do
      [[ ! -e "$requested/$name" && ! -L "$requested/$name" ]] || refuse "Output already used: $requested/$name"
    done
  fi
  mktemp -d "$requested/photocull-checks-XXXXXXXX"
}

run_regular() (
  export OUT="$RUN" TMPDIR="$RUN/" PC_TEST_ROOT="$RUN" PC_FINALIZE_SAFETY_OUT="$RUN" \
    PC_FINALIZE_TEST_OUT="$RUN" PC_NAVIGATION_OUT="$RUN"
  unset PC_FIXTURES
  case "$mode" in
    all) "$PM_BIN/PhotoCullTests" ;;
    finalize-safety|finalize-planning) "$PM_BIN/PhotoCullTests" --finalize-safety-only ;;
    ingest-collectors)
      "$PM_BIN/PhotoCullTests" --suite IngestConcurrent
      "$PM_BIN/PhotoCullTests" --finalize-safety-only ;;
  esac
  local check
  for check in "${group[@]}"; do
    case "$check" in
      edit-rendering) "$BUILD/EditRenderingChecks" ;;
      image-loading) "$BUILD/ImageLoadingChecks" ;;
      navigation) "$BUILD/NavigationChecks" ;;
      finalize-core)
        if [[ "$mode" == finalize-planning ]]; then
          "$BUILD/FinalizeCoreChecks" --planning-only
        else
          "$BUILD/FinalizeCoreChecks"
        fi ;;
      finalize-descriptors) "$BUILD/FinalizeDescriptorChecks" ;;
      finalize-operation) "$BUILD/FinalizeOperationChecks" ;;
      ingest-collectors)
        check_invalid_selections
        "$BUILD/IngestCollectorChecks" "$RUN" ;;
    esac
  done
)

check_invalid_selections() {
  reject_selection --suite
  reject_selection --suite MissingSuite
  reject_selection --bogus
  printf '%s\n' 'PASS — three invalid CLI selections rejected before suite execution'
}

reject_selection() {
  local log="$RUN/invalid-selection.log"
  if "$PM_BIN/PhotoCullTests" "$@" >"$log" 2>&1; then
    echo "Expected invalid selection to fail: $*" >&2; return 1
  fi
  if grep -q 'Selected .*suite' "$log"; then
    echo "Invalid selection executed a suite: $*" >&2; return 1
  fi
}

if $fixture; then
  source "$ROOT/scripts/lib/fixture-startup.sh"
  if [[ "$mode" == fixture-startup && -n ${OUT:-} ]]; then
    FIXTURE_OUT=$OUT
  else
    FIXTURE_OUT=$(mktemp -d /private/tmp/photocull-manual-launch-XXXXXXXX)
  fi
  prepare_fixture_out "$FIXTURE_OUT"
fi
if [[ "$mode" == fixture-startup ]]; then
  RUN="$FIXTURE_OUT/regressions"
  mkdir -- "$RUN"
else
  RUN=$(make_run_root)
fi
printf 'Check output: %s\n' "$RUN"

source "$ROOT/scripts/lib/check-build.sh"
# Build the actual package (including the app entry point) without launching it.
# Standalone checks that need the core runner can build just that product.
# Do not vary TMPDIR between SwiftPM invocations: Swift Build keys on it.
if [[ "$mode" == all ]] || $fixture; then
  build_package
elif [[ ${group[0]} == core ]]; then
  build_package --product PhotoCullTests
fi
export TMPDIR="$RUN/"
init_check_build
build_regular_checks "${group[@]}"
if $fixture; then build_fixture_checks; fi
run_regular
if $fixture; then run_fixture_startup "$FIXTURE_OUT"; fi

# Keep explicit OUT artifacts and any failure's artifacts for diagnosis.
if [[ "$mode" != fixture-startup && -z ${OUT:-} ]]; then rm -rf -- "$RUN"; fi
