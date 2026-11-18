# Sourced by run-checks.sh. All binaries, modules and compiler caches are local
# to the checkout. No files in a run's disposable OUT are build inputs.
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
compile_check() {
  local dest=$1 stamp=$1.key arg key previous=
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
  mkdir -p -- "$(dirname -- "$dest")"
  rm -f -- "$stamp"
  "$SWIFTC" "${FLAGS[@]}" "$@" -o "$dest"
  printf '%s\n' "$key" > "$stamp"
}

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
      core)
        compile_check "$BUILD/PhotoCullTests" -I "$CORE" "$harness"/*.swift "$CORE/libPhotoCullCore.a" ;;
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
        cmp -s "$tests/Core/IngestCollectorChecks.swift" "$BUILD/ingest/main.swift" || \
          cp "$tests/Core/IngestCollectorChecks.swift" "$BUILD/ingest/main.swift"
        compile_check "$BUILD/IngestCollectorChecks" -I "$CORE" \
          "$harness/Harness.swift" "$BUILD/ingest/main.swift" "$CORE/libPhotoCullCore.a" ;;
    esac
  done
}

build_fixture_checks() {
  local fixture="$BUILD/fixture" test="$ROOT/Tests/App/FixtureStartupChecks.swift"
  local kind dest variant_core src
  local variant_app=()
  # The candidate is never executed. The generator has no application sources.
  compile_check "$fixture/PhotoCull" -I "$CORE" "$ROOT"/Sources/PhotoCullApp/*.swift "$CORE/libPhotoCullCore.a"
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
        cp "$ROOT/Sources/PhotoCullCore/Config.swift" "$dest/core/Config.swift"
        perl -0777 -pi -e 's/text == cfg\.toTOML\(\),/true,/ or die "format seam missing"' "$dest/core/Config.swift"
        local sources=()
        for src in "${CORE_SOURCES[@]}"; do
          if [[ ${src##*/} == Config.swift ]]; then src="$dest/core/Config.swift"; fi
          sources+=("$src")
        done
        variant_core="$dest/core"
        build_check_module "$variant_core" PhotoCullCore -D FIXTURE_CORE_CHECKS "${sources[@]}" "$test" ;;
      identity|guard|preferences)
        local file=AppState.swift
        [[ "$kind" != identity ]] || file=StartupConfiguration.swift
        cp "$ROOT/Sources/PhotoCullApp/$file" "$dest/app/$file"
        case "$kind" in
          identity) perl -0777 -pi -e 's/UUID\(uuidString: String\(id\.dropFirst\(fixtureIdentifierPrefix\.count\)\)\) != nil/true/ or die "identity seam missing"' "$dest/app/$file" ;;
          guard) perl -0777 -pi -e 's/guard !fixtureMode else \{ toastMessage\("Unavailable in disposable fixture mode"\); return false \}/\/\/ Negative control: ordinary I\/O guard removed/ or die "guard seam missing"' "$dest/app/$file" ;;
          preferences) perl -0777 -pi -e 's/if initializeAppearance && !fixtureMode \{/if initializeAppearance {/ or die "preference seam missing"' "$dest/app/$file" ;;
        esac
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
