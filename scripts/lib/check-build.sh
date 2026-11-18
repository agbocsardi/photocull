# Sourced by run-checks.sh. All binaries, modules and compiler caches are local
# to the checkout. No files in a run's disposable OUT are build inputs.
build_package() {
  # Swift Build in Swift 6.4's Command Line Tools rebuilt the app on the
  # second invocation after a clean build. Use SwiftPM's incremental native backend.
  local pm=(--package-path "$ROOT" -c debug --build-system native
    --cache-path "$ROOT/.build/swiftpm-cache"
    --config-path "$ROOT/.build/swiftpm-config"
    --security-path "$ROOT/.build/swiftpm-security")
  swift build "${pm[@]}" "$@"
  PM_BIN="$ROOT/.build/debug"
}

# Stage writes in the same directory tree and replace the destination, never
# open an existing cache file for writing. BSD mv -h also refuses to follow a
# destination symlink to a directory.
publish_check_file() {
  [[ ! -d "$2" || -L "$2" ]] || refuse "Expected check cache file, found directory: $2"
  mv -fh -- "$1" "$2"
}

cache_source() (
  local src=$1 dest=$2 stage
  shift 2
  stage=$(mktemp "${dest%/*}/.source-XXXXXXXX")
  trap 'rm -f -- "$stage"' EXIT
  if [[ $# == 0 ]]; then
    cp -- "$src" "$stage"
  else
    perl -0777 -pe "$1" "$src" > "$stage"
  fi
  if ! cmp -s "$stage" "$dest"; then publish_check_file "$stage" "$dest"; fi
)

init_check_build() {
  local sdk sdk_build target
  sdk=$(xcrun --sdk macosx --show-sdk-path)
  target="$(uname -m)-apple-macosx14.0"
  SWIFTC=$(xcrun --sdk macosx --find swiftc)
  sdk_build=$(xcrun --sdk macosx --show-sdk-build-version)
  TOOLCHAIN=$("$SWIFTC" -version 2>&1)
  TOOLCHAIN="$TOOLCHAIN $sdk_build"
  export CLANG_MODULE_CACHE_PATH="$BUILD/module-cache"
  FLAGS=(-Onone -D DEBUG -swift-version 5 -target "$target" -sdk "$sdk"
    -package-name PhotoCull -module-cache-path "$BUILD/module-cache")
  CORE="$BUILD/core"
  CORE_SOURCES=("$ROOT"/Sources/PhotoCullCore/*.swift)
  APP_SOURCES=()
  local src
  for src in "$ROOT"/Sources/PhotoCullApp/*.swift; do
    [[ ${src##*/} == PhotoCullApp.swift ]] || APP_SOURCES+=("$src")
  done
}

# Fingerprint compiler arguments and input contents, including module build keys
# for the static libraries. A failed build must not leave a usable cache stamp.
compile_check() (
  local dest=$1 stamp=$1.key arg key previous= dir stage file
  local args=()
  shift
  local inputs=("$ROOT/Package.swift")
  for arg in "$@"; do
    if [[ "$previous" == -I ]]; then
      inputs+=("$arg"/*.a.key)
    else
      case "$arg" in
        *.swift|*.a) inputs+=("$arg") ;;
      esac
    fi
    previous=$arg
  done
  key=$({
    printf '%s\0' "$SWIFTC" "$TOOLCHAIN" "$dest" "${FLAGS[@]}" "$@"
    /usr/bin/shasum -a 256 "${inputs[@]}"
  } | /usr/bin/shasum -a 256)
  if [[ -f "$dest" && -f "$stamp" && $(<"$stamp") == "$key" ]]; then return; fi
  printf 'Building %s\n' "${dest#"$BUILD/"}"
  dir=${dest%/*}
  mkdir -p -- "$dir"
  stage=$(mktemp -d "$dir/.build-XXXXXXXX")
  trap 'rm -rf -- "$stage"' EXIT
  previous=
  for arg in "$@"; do
    if [[ "$previous" == -emit-module-path ]]; then
      args+=("$stage/${arg##*/}")
    else
      args+=("$arg")
    fi
    previous=$arg
  done
  rm -f -- "$stamp"
  "$SWIFTC" "${FLAGS[@]}" "${args[@]}" -o "$stage/${dest##*/}"
  for file in "$stage"/*; do publish_check_file "$file" "$dir/${file##*/}"; done
  printf '%s\n' "$key" > "$stage/key"
  publish_check_file "$stage/key" "$stamp"
)

build_check_module() {
  local dir=$1 name=$2
  shift 2
  # If the module was removed independently of its archive, rebuild both.
  [[ -f "$dir/$name.swiftmodule" ]] || rm -f -- "$dir/lib$name.a.key"
  compile_check "$dir/lib$name.a" -parse-as-library -emit-library -static \
    -emit-module -emit-module-path "$dir/$name.swiftmodule" -module-name "$name" "$@"
}

build_regular_checks() {
  local check name app_built=false app="$BUILD/app" tests="$ROOT/Tests" harness="$ROOT/Sources/PhotoCullTests"
  build_check_module "$CORE" PhotoCullCore "${CORE_SOURCES[@]}"
  for check in "$@"; do
    case "$check" in
      core) ;; # Uses the SwiftPM product.
      edit-rendering|image-loading|navigation|finalize-operation)
        # All ordinary app checks link one module of real app sources, with no
        # application entry point. Fixture checks can't use this module: their
        # shadows must be compiled in the same module as the code they guard.
        if ! $app_built; then
          build_check_module "$app" PhotoCullAppChecks -enable-testing -I "$CORE" "${APP_SOURCES[@]}"
          app_built=true
        fi
        case "$check" in
          edit-rendering) name=EditRenderingChecks ;;
          image-loading) name=ImageLoadingChecks ;;
          navigation) name=NavigationChecks ;;
          finalize-operation) name=FinalizeOperationChecks ;;
        esac
        compile_check "$BUILD/$name" -parse-as-library -I "$CORE" -I "$app" \
          "$tests/App/$name.swift" "$app/libPhotoCullAppChecks.a" "$CORE/libPhotoCullCore.a" ;;
      finalize-core)
        compile_check "$BUILD/FinalizeCoreChecks" -I "$CORE" \
          "$tests/Core/FinalizePlanningChecks.swift" "$tests/Core/FinalizeFailureChecks.swift" \
          "$tests/Core/FinalizeCoreMain.swift" "$CORE/libPhotoCullCore.a" ;;
      finalize-descriptors)
        # Test-local native syscall forwarding/reuse, not substitute constructors.
        compile_check "$BUILD/FinalizeDescriptorChecks" -D FINALIZE_DESCRIPTOR_CHECKS \
          "$ROOT/Sources/PhotoCullCore/Session.swift" "$ROOT/Sources/PhotoCullCore/FinalizeSafety.swift" \
          "$tests/Core/FinalizeFailureChecks.swift" ;;
      ingest-collectors)
        # swiftc requires main.swift for the collector's existing top-level entry point.
        mkdir -p "$BUILD/ingest"
        cache_source "$tests/Core/IngestCollectorChecks.swift" "$BUILD/ingest/main.swift"
        compile_check "$BUILD/IngestCollectorChecks" -I "$CORE" \
          "$harness/Harness.swift" "$BUILD/ingest/main.swift" "$CORE/libPhotoCullCore.a" ;;
    esac
  done
}

build_fixture_checks() {
  local fixture="$BUILD/fixture" test="$ROOT/Tests/App/FixtureStartupChecks.swift"
  local kind dest variant_core src
  local variant_app=()
  # The generator has no application sources.
  compile_check "$fixture/generator" -parse-as-library \
    "${CORE_SOURCES[@]}" "$ROOT/Tests/Manual/ManualFinalizeFixture.swift"
  # Compile actual Core plus a test-local lstat forwarding seam (ownership spoofing).
  build_check_module "$fixture/core" PhotoCullCore -D FIXTURE_CORE_CHECKS "${CORE_SOURCES[@]}" "$test"
  compile_check "$fixture/startup" -I "$fixture/core" \
    "${APP_SOURCES[@]}" "$test" "$fixture/core/libPhotoCullCore.a"
  # Each negative control also compiles AppState in the same module as the
  # shadows. Mutate only copies in the build cache, never the checkout sources.
  for kind in format identity guard preferences; do
    dest="$fixture/negative-$kind"
    mkdir -p "$dest/core" "$dest/app"
    variant_core="$fixture/core"
    variant_app=("${APP_SOURCES[@]}")
    case "$kind" in
      format)
        cache_source "$ROOT/Sources/PhotoCullCore/Config.swift" "$dest/core/Config.swift" \
          's/text == cfg\.toTOML\(\),/true,/ or die "format seam missing"'
        local sources=()
        for src in "${CORE_SOURCES[@]}"; do
          if [[ ${src##*/} == Config.swift ]]; then src="$dest/core/Config.swift"; fi
          sources+=("$src")
        done
        variant_core="$dest/core"
        build_check_module "$variant_core" PhotoCullCore -D FIXTURE_CORE_CHECKS "${sources[@]}" "$test" ;;
      identity|guard|preferences)
        local file=AppState.swift mutation
        case "$kind" in
          identity) file=StartupConfiguration.swift
            mutation='s/UUID\(uuidString: String\(id\.dropFirst\(fixtureIdentifierPrefix\.count\)\)\) != nil/true/ or die "identity seam missing"' ;;
          guard) mutation='s/guard !fixtureMode else \{ toastMessage\("Unavailable in disposable fixture mode"\); return false \}/\/\/ Negative control: ordinary I\/O guard removed/ or die "guard seam missing"' ;;
          preferences) mutation='s/if initializeAppearance && !fixtureMode \{/if initializeAppearance {/ or die "preference seam missing"' ;;
        esac
        cache_source "$ROOT/Sources/PhotoCullApp/$file" "$dest/app/$file" "$mutation"
        variant_app=()
        for src in "${APP_SOURCES[@]}"; do
          if [[ ${src##*/} == "$file" ]]; then src="$dest/app/$file"; fi
          variant_app+=("$src")
        done ;;
    esac
    compile_check "$dest/checks" -I "$variant_core" \
      "${variant_app[@]}" "$test" "$variant_core/libPhotoCullCore.a"
  done
}
