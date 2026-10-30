#!/usr/bin/env bash
# Build the standalone Strata extension without Houdini or HEGo.
#
#   scripts/build-terrain.sh                          # host, both targets
#   scripts/build-terrain.sh template_debug           # legacy host-target form
#   scripts/build-terrain.sh windows template_release # MinGW cross-build
#   scripts/build-terrain.sh linux-compat             # glibc 2.28 container
#   scripts/build-terrain.sh all                       # linux-compat + Windows
#   scripts/build-terrain.sh --dry-run all template_debug

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOBS="$(nproc 2>/dev/null || echo 4)"
ALL_TARGETS=(template_debug template_release)
TARGETS=("${ALL_TARGETS[@]}")
IMAGE=hego-terrain-linux-compat
GLIBC_FLOOR=2.28
DRY_RUN=false
DRY_IMAGE_PLANNED=false

if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    shift
fi

requested_platform=host
case "${1:-}" in
    host|linux|linux-compat|windows|all)
        requested_platform="$1"
        shift
        ;;
esac

if [[ $# -gt 0 ]]; then TARGETS=("$@"); fi
for target in "${TARGETS[@]}"; do
    case "$target" in
        template_debug|template_release) ;;
        *) echo "error: unsupported target: $target" >&2; exit 2 ;;
    esac
done

# The godot-cpp submodule's .git pointer may reference a host-only worktree path
# and therefore cannot be followed inside Podman. Pass its tracked source list
# into the container through the shared checkout.
if [[ "$DRY_RUN" != true ]]; then
    # terrain/build is ignored by git, so a fresh checkout does not have it yet.
    mkdir -p "$ROOT_DIR/terrain/build"
    python3 -c 'import pathlib, subprocess, sys; root=pathlib.Path(sys.argv[1]); paths=subprocess.check_output(["git", "-C", str(root / "godot-cpp"), "ls-files", "-z"]).decode().split("\0"); (root / "terrain/build/godot-cpp-files.txt").write_text("\n".join(p for p in paths if p) + "\n")' "$ROOT_DIR"
fi

case "$requested_platform" in
    host)
        case "$(uname -s)" in
            Linux*) PLATFORMS=(linux) ;;
            MINGW*|MSYS*|CYGWIN*) PLATFORMS=(windows) ;;
            *) echo "error: host platform is not supported: $(uname -s)" >&2; exit 2 ;;
        esac
        ;;
    linux) PLATFORMS=(linux) ;;
    linux-compat) PLATFORMS=(linux-compat) ;;
    windows) PLATFORMS=(windows) ;;
    all) PLATFORMS=(linux-compat windows) ;;
esac

print_command() {
    printf '  '
    printf '%q ' "$@"
    printf '\n'
}

run_or_print() {
    if [[ "$DRY_RUN" == true ]]; then
        print_command "$@"
    else
        "$@"
    fi
}

verify_linux_so() {
    local so="$1" require_compat="$2" newest
    local dynamic version_info
    dynamic="$(readelf -d "$so")"
    version_info="$(readelf -V "$so" 2>/dev/null || true)"
    newest="$(grep -oE 'GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?' <<<"$version_info" \
        | sed 's/^GLIBC_//' | sort -uV | tail -1 || true)"
    echo "  $(basename "$so"): requires glibc ${newest:-none}"

    if grep -qiE 'libstdc\+\+|libgcc_s|libHAPIL|houdini' <<<"$dynamic"; then
        echo "error: $(basename "$so") has a dynamic C++ runtime or Houdini dependency:" >&2
        grep -iE 'libstdc\+\+|libgcc_s|libHAPIL|houdini' <<<"$dynamic" >&2
        return 1
    fi
    if ! nm -D --defined-only "$so" | awk '{print $3}' | grep -qx 'strata_library_init'; then
        echo "error: $(basename "$so") does not export strata_library_init" >&2
        return 1
    fi
    if [[ "$require_compat" == true && -n "$newest" ]] && \
        [[ "$(printf '%s\n' "$newest" "$GLIBC_FLOOR" | sort -V | tail -1)" != "$GLIBC_FLOOR" ]]; then
        echo "error: $(basename "$so") needs glibc $newest, newer than $GLIBC_FLOOR" >&2
        return 1
    fi
}

verify_windows_dll() {
    local dll="$1" objdump="x86_64-w64-mingw32-objdump" headers bad_imports
    if ! command -v "$objdump" >/dev/null; then
        echo "error: $objdump is required to inspect the Windows DLL" >&2
        return 1
    fi
    headers="$("$objdump" -p "$dll")"
    bad_imports="$(grep 'DLL Name:' <<<"$headers" | grep -iE 'libstdc\+\+|libgcc|libwinpthread|libHAPIL|houdini' || true)"
    if [[ -n "$bad_imports" ]]; then
        echo "error: $(basename "$dll") has non-system runtime/Houdini imports:" >&2
        echo "$bad_imports" >&2
        return 1
    fi
    if ! grep -q 'strata_library_init' <<<"$headers"; then
        echo "error: $(basename "$dll") does not export strata_library_init" >&2
        return 1
    fi
}

build_linux_compat() {
    local target="$1"
    if [[ "$DRY_RUN" != true ]] && ! command -v podman >/dev/null; then
        echo 'error: podman is required for linux-compat; use "linux" for a host build' >&2
        return 1
    fi
    if [[ "$DRY_RUN" == true ]]; then
        if [[ "$DRY_IMAGE_PLANNED" != true ]]; then
            print_command podman build -t "$IMAGE" -f "$ROOT_DIR/scripts/linux-compat-terrain.Containerfile" "$ROOT_DIR"
            DRY_IMAGE_PLANNED=true
        fi
    else
        echo "building $IMAGE (cached layers are reused; this image has no Houdini dependency)"
        podman build -t "$IMAGE" -f "$ROOT_DIR/scripts/linux-compat-terrain.Containerfile" "$ROOT_DIR"
    fi
    run_or_print podman run --rm --security-opt label=disable \
        -e HEGO_TERRAIN_CPP_FILELIST=/src/terrain/build/godot-cpp-files.txt \
        -v "$ROOT_DIR:/src" -w /src "$IMAGE" \
        scons -f SConstruct.terrain platform=linux target="$target" arch=x86_64 \
        terrain_build_profile=linux-compat -j"$JOBS"
}

for platform in "${PLATFORMS[@]}"; do
    for target in "${TARGETS[@]}"; do
        echo "── $platform / $target ──"
        case "$platform" in
            linux)
                if [[ "$DRY_RUN" == true ]]; then
                    print_command scons -f SConstruct.terrain platform=linux target="$target" arch=x86_64 terrain_build_profile=host "-j$JOBS"
                else
                    (cd "$ROOT_DIR" && scons -f SConstruct.terrain platform=linux target="$target" arch=x86_64 terrain_build_profile=host -j"$JOBS")
                fi
                output_platform=linux
                build_profile=host
                compiler="${CXX:-c++}"
                require_compat=false
                ;;
            linux-compat)
                build_linux_compat "$target"
                output_platform=linux
                build_profile=linux-compat
                if [[ "$DRY_RUN" == true ]]; then
                    compiler="$IMAGE (gcc-toolset-13; image ID recorded at build time)"
                else
                    image_id="$(podman image inspect --format '{{.Id}}' "$IMAGE")"
                    compiler="$(podman run --rm "$IMAGE" g++ --version | head -n 1)"
                    compiler="$compiler;image=$image_id"
                fi
                require_compat=true
                ;;
            windows)
                if ! command -v x86_64-w64-mingw32-g++ >/dev/null && [[ "$DRY_RUN" != true ]]; then
                    echo "error: x86_64-w64-mingw32-g++ not found; install the MinGW-w64 cross-toolchain" >&2
                    exit 1
                fi
                if [[ "$DRY_RUN" == true ]]; then
                    print_command scons -f SConstruct.terrain platform=windows target="$target" arch=x86_64 use_mingw=yes terrain_build_profile=windows "-j$JOBS"
                else
                    (cd "$ROOT_DIR" && scons -f SConstruct.terrain platform=windows target="$target" arch=x86_64 use_mingw=yes terrain_build_profile=windows -j"$JOBS")
                fi
                output_platform=windows
                build_profile=windows
                compiler="$(x86_64-w64-mingw32-g++ --version | head -n 1 2>/dev/null || echo MinGW-w64)"
                require_compat=false
                ;;
        esac

        if [[ "$DRY_RUN" == true ]]; then
            echo "  would verify and record $output_platform / $target ($build_profile)"
            continue
        fi

        cpp_commit="$(git -C "$ROOT_DIR/godot-cpp" rev-parse HEAD)"
        context="platform=$output_platform,target=$target,arch=x86_64,profile=$build_profile,compiler=$compiler,godot_cpp=$cpp_commit"
        if [[ "$output_platform" == windows ]]; then
            artifact="bin/strata.windows.${target}.x86_64.dll"
            full_artifact="$ROOT_DIR/demo/addons/strata/$artifact"
            verify_windows_dll "$full_artifact"
        else
            artifact="bin/libstrata.linux.${target}.x86_64.so"
            full_artifact="$ROOT_DIR/demo/addons/strata/$artifact"
            verify_linux_so "$full_artifact" "$require_compat"
        fi
        python3 "$ROOT_DIR/scripts/native_build_manifest.py" record --addon strata \
            --artifact "$artifact" --context "$context"
    done
done

if [[ "$DRY_RUN" == true ]]; then
    exit 0
fi

echo
echo "Terrain extension artifacts in $ROOT_DIR/demo/addons/strata/bin:"
ls -lh "$ROOT_DIR/demo/addons/strata/bin" | grep -v '^total'
