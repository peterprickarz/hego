#!/usr/bin/env bash
# Build the standalone Strata extension without Houdini or HEGo.
#
#   scripts/build-terrain.sh                          # host, both targets
#   scripts/build-terrain.sh template_debug           # legacy host-target form
#   scripts/build-terrain.sh windows template_release # MinGW cross-build
#   scripts/build-terrain.sh linux-compat             # glibc 2.28 container
#   ARCH=arm64 scripts/build-terrain.sh linux         # Linux ARM64 (native or cross toolchain)
#   ARCH=arm64 scripts/build-terrain.sh linux-compat  # Linux ARM64 in the glibc 2.28 container (qemu on x86_64 hosts)
#   scripts/build-terrain.sh all                       # linux-compat + Windows
#   scripts/build-terrain.sh --dry-run all template_debug
#
# Strata ships Linux x86_64 and Windows x86_64 only. macOS is not supported.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
if [[ ! "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: JOBS must be a positive integer" >&2
    exit 1
fi
HOST_OS="$(uname -s)"
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
    macos) echo "error: macOS is not supported; Strata builds for Linux and Windows only" >&2; exit 2 ;;
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
        case "$HOST_OS" in
            Linux*) PLATFORMS=(linux) ;;
            Darwin) echo "error: macOS is not supported; Strata builds for Linux and Windows only" >&2; exit 2 ;;
            MINGW*|MSYS*|CYGWIN*) PLATFORMS=(windows) ;;
            *) echo "error: host platform is not supported: $HOST_OS" >&2; exit 2 ;;
        esac
        ;;
    linux) PLATFORMS=(linux) ;;
    linux-compat) PLATFORMS=(linux-compat) ;;
    windows) PLATFORMS=(windows) ;;
    all) PLATFORMS=(linux-compat windows) ;;
esac

# Native Linux builds follow the host CPU unless ARCH says otherwise.
linux_arch="${ARCH:-$(uname -m)}"
case "$linux_arch" in aarch64) linux_arch=arm64 ;; amd64) linux_arch=x86_64 ;; esac
for platform in "${PLATFORMS[@]}"; do
    case "$platform:$linux_arch" in
        linux:arm64|linux:x86_64|linux-compat:arm64|linux-compat:x86_64|windows:*) ;;
        *) echo "error: Linux ARCH must be arm64 or x86_64, got $linux_arch" >&2; exit 2 ;;
    esac
done
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

# The container image for $arch. A foreign architecture runs the AlmaLinux image
# under qemu-user-static (binfmt_misc), which the host has to provide.
compat_image() {
    local arch="$1"
    [[ "$arch" == "x86_64" ]] && echo "$IMAGE" || echo "$IMAGE-$arch"
}

require_container_arch() {
    local arch="$1" host binfmt
    host="$(uname -m)"
    case "$host" in aarch64) host=arm64 ;; amd64) host=x86_64 ;; esac
    [[ "$arch" == "$host" || "$DRY_RUN" == true ]] && return 0
    binfmt=/proc/sys/fs/binfmt_misc/qemu-aarch64
    [[ "$arch" == "x86_64" ]] && binfmt=/proc/sys/fs/binfmt_misc/qemu-x86_64
    if [[ ! -e "$binfmt" ]]; then
        echo "error: building $arch containers on a $host host needs qemu-user-static (binfmt_misc), e.g. dnf install qemu-user-static" >&2
        return 1
    fi
}

build_linux_compat() {
    local target="$1" arch="$2" oci image
    if [[ "$DRY_RUN" != true ]] && ! command -v podman >/dev/null; then
        echo 'error: podman is required for linux-compat; use "linux" for a host build' >&2
        return 1
    fi
    require_container_arch "$arch" || return 1
    case "$arch" in arm64) oci=linux/arm64 ;; *) oci=linux/amd64 ;; esac
    image="$(compat_image "$arch")"
    if [[ "$DRY_RUN" == true ]]; then
        if [[ "$DRY_IMAGE_PLANNED" != true ]]; then
            print_command podman build --platform "$oci" -t "$image" -f "$ROOT_DIR/scripts/linux-compat-terrain.Containerfile" "$ROOT_DIR"
            DRY_IMAGE_PLANNED=true
        fi
    else
        echo "building $image (cached layers are reused; this image has no Houdini dependency)"
        podman build --platform "$oci" -t "$image" -f "$ROOT_DIR/scripts/linux-compat-terrain.Containerfile" "$ROOT_DIR"
    fi
    run_or_print podman run --rm --platform "$oci" --security-opt label=disable \
        -e HEGO_TERRAIN_CPP_FILELIST=/src/terrain/build/godot-cpp-files.txt \
        -v "$ROOT_DIR:/src" -w /src "$image" \
        scons -f SConstruct.terrain platform=linux target="$target" arch="$arch" \
        terrain_build_profile=linux-compat -j"$JOBS"
}

for platform in "${PLATFORMS[@]}"; do
    for target in "${TARGETS[@]}"; do
        echo "── $platform / $target ──"
        case "$platform" in
            linux)
                arch="$linux_arch"
                if [[ "$DRY_RUN" == true ]]; then
                    print_command scons -f SConstruct.terrain platform=linux target="$target" arch="$arch" terrain_build_profile=host "-j$JOBS"
                else
                    (cd "$ROOT_DIR" && scons -f SConstruct.terrain platform=linux target="$target" arch="$arch" terrain_build_profile=host -j"$JOBS")
                fi
                output_platform=linux
                build_profile=host
                compiler="$("${CXX:-c++}" --version 2>/dev/null | head -n 1 || echo "${CXX:-c++}")"
                require_compat=false
                ;;
            linux-compat)
                arch="$linux_arch"
                build_linux_compat "$target" "$arch"
                output_platform=linux
                build_profile=linux-compat
                if [[ "$DRY_RUN" == true ]]; then
                    compiler="$(compat_image "$arch") (gcc-toolset-13; image ID recorded at build time)"
                else
                    image_id="$(podman image inspect --format '{{.Id}}' "$(compat_image "$arch")")"
                    compiler="$(podman run --rm "$(compat_image "$arch")" g++ --version | head -n 1)"
                    compiler="$compiler;image=$image_id"
                fi
                require_compat=true
                ;;
            windows)
                arch=x86_64
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
        context="platform=$output_platform,target=$target,arch=$arch,profile=$build_profile,compiler=$compiler,godot_cpp=$cpp_commit"
        case "$output_platform" in
            windows)
                artifact="bin/strata.windows.${target}.${arch}.dll"
                verify_windows_dll "$ROOT_DIR/demo/addons/strata/$artifact"
                ;;
            linux)
                artifact="bin/libstrata.linux.${target}.${arch}.so"
                verify_linux_so "$ROOT_DIR/demo/addons/strata/$artifact" "$require_compat"
                ;;
        esac
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
