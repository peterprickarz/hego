#!/usr/bin/env bash
# Build the Copia GDExtension (no Houdini, no HEGo, no Strata) into demo/addons/copia/bin/
# and record its build receipts in demo/addons/copia/native-build.json.
#
#   scripts/build-copia.sh                          # host platform, both targets
#   scripts/build-copia.sh linux-compat             # redistributable Linux, glibc 2.28 container
#   scripts/build-copia.sh linux template_debug     # host toolchain on Linux (development only)
#   scripts/build-copia.sh windows                  # MSVC on a Windows host (Git Bash)
#   JOBS=8 scripts/build-copia.sh linux-compat
#
# Copia ships Linux x86_64 (linux-compat) and Windows x86_64 (MSVC) only. macOS is not
# supported. A Windows host needs SCons on PATH and MSVC, which SCons finds by itself.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$ROOT_DIR/demo/addons/copia/bin"
HOST_OS="$(uname -s)"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
SCONS="${SCONS:-scons}"
PYTHON="${PYTHON:-python3}"
IMAGE=hego-copia-linux-compat
GLIBC_FLOOR=2.28
TARGETS=(template_debug template_release)

fail() { echo "error: $*" >&2; exit 1; }

[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || fail "JOBS must be a positive integer."

case "${1:-host}" in
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    host)
        case "$HOST_OS" in
            Linux) platform=linux ;;
            MINGW*|MSYS*|CYGWIN*) platform=windows ;;
            Darwin) fail "macOS is not supported; Copia builds for Linux and Windows only." ;;
            *) fail "unsupported host $HOST_OS." ;;
        esac ;;
    linux|linux-compat|windows) platform="$1" ;;
    macos) fail "macOS is not supported; Copia builds for Linux and Windows only." ;;
    *) fail "unknown platform: $1 (use host, linux, linux-compat or windows)" ;;
esac
if [[ $# -gt 1 ]]; then TARGETS=("${@:2}"); fi
for target in "${TARGETS[@]}"; do
    case "$target" in template_debug|template_release) ;; *) fail "unknown target: $target" ;; esac
done

case "$platform" in
    linux|linux-compat)
        [[ "$HOST_OS" == "Linux" ]] || fail "$platform builds need a Linux host."
        [[ "$(uname -m)" == "x86_64" ]] || fail "Copia ships Linux x86_64 only."
        command -v readelf >/dev/null || fail "readelf not found; install binutils."
        ;;
    windows)
        case "$HOST_OS" in MINGW*|MSYS*|CYGWIN*) ;; *) fail "Windows builds need a Windows host with MSVC." ;; esac
        ;;
esac
[[ "$platform" == "linux-compat" ]] || command -v "$SCONS" >/dev/null || fail "$SCONS not found."
command -v "$PYTHON" >/dev/null || fail "$PYTHON not found; set PYTHON."

# Inside the container the godot-cpp submodule's .git pointer cannot be followed, so
# SConstruct.copia reads godot-cpp's tracked file list from here (copia/build is ignored).
mkdir -p "$ROOT_DIR/copia/build"
git -C "$ROOT_DIR/godot-cpp" ls-files > "$ROOT_DIR/copia/build/godot-cpp-files.txt"

verify_linux_so() {
    local so="$1" newest
    readelf -h "$so" | grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64' \
        || fail "$(basename "$so") is not an x86_64 library."
    readelf --dyn-syms --wide "$so" | grep -Eq 'GLOBAL[[:space:]]+DEFAULT[[:space:]]+[0-9]+[[:space:]]+copia_library_init$' \
        || fail "$(basename "$so") does not export copia_library_init."
    if readelf -d "$so" | grep -qiE 'libstdc\+\+|libgcc_s'; then
        fail "$(basename "$so") depends on a dynamic C++ runtime; it should be linked statically."
    fi
    newest="$(readelf -V "$so" 2>/dev/null | grep -oE 'GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?' \
        | sed 's/^GLIBC_//' | sort -uV | tail -1 || true)"
    echo "  $(basename "$so"): needs glibc ${newest:-none}"
    if [[ "$platform" == "linux-compat" && -n "$newest" ]] && \
        [[ "$(printf '%s\n' "$newest" "$GLIBC_FLOOR" | sort -V | tail -1)" != "$GLIBC_FLOOR" ]]; then
        fail "$(basename "$so") needs glibc $newest, newer than the $GLIBC_FLOOR floor."
    fi
}

if [[ "$platform" == "linux-compat" ]]; then
    command -v podman >/dev/null || fail "podman not found; linux-compat needs it. Use \"linux\" for a host build."
    echo "building $IMAGE (cached layers are reused; the image has no Houdini dependency)"
    podman build -t "$IMAGE" -f "$ROOT_DIR/scripts/linux-compat-copia.Containerfile" "$ROOT_DIR"
    image_id="$(podman image inspect --format '{{.Id}}' "$IMAGE")"
    compiler="$(podman run --rm "$IMAGE" g++ --version | head -n 1);image=$image_id"
fi

cpp_commit="$(git -C "$ROOT_DIR/godot-cpp" rev-parse HEAD)"
for target in "${TARGETS[@]}"; do
    echo "── $platform / $target ──"
    case "$platform" in
        linux-compat)
            podman run --rm --security-opt label=disable \
                -e HEGO_COPIA_CPP_FILELIST=/src/copia/build/godot-cpp-files.txt \
                -v "$ROOT_DIR:/src" -w /src "$IMAGE" \
                scons -f SConstruct.copia platform=linux target="$target" arch=x86_64 \
                copia_build_profile=linux-compat -j"$JOBS"
            artifact="bin/libcopia.linux.$target.x86_64.so"
            verify_linux_so "$ROOT_DIR/demo/addons/copia/$artifact"
            ;;
        linux)
            (cd "$ROOT_DIR" && "$SCONS" -f SConstruct.copia platform=linux target="$target" arch=x86_64 -j"$JOBS")
            artifact="bin/libcopia.linux.$target.x86_64.so"
            verify_linux_so "$ROOT_DIR/demo/addons/copia/$artifact"
            compiler="$("${CXX:-g++}" --version | head -n 1)"
            ;;
        windows)
            (cd "$ROOT_DIR" && "$SCONS" -f SConstruct.copia platform=windows target="$target" arch=x86_64 -j"$JOBS")
            artifact="bin/copia.windows.$target.x86_64.dll"
            compiler="MSVC"
            ;;
    esac
    output_platform=linux
    profile=host
    case "$platform" in
        linux-compat) profile=linux-compat ;;
        windows) output_platform=windows ;;
    esac
    context="platform=$output_platform,target=$target,arch=x86_64,profile=$profile,compiler=$compiler,godot_cpp=$cpp_commit"
    "$PYTHON" "$ROOT_DIR/scripts/native_build_manifest.py" record --addon copia \
        --artifact "$artifact" --context "$context"
done

echo
echo "Copia binaries in $BIN_DIR:"
ls -lh "$BIN_DIR" | grep -vE '^total|gdextension'
