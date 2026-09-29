#!/usr/bin/env bash
#
# Builds the HEGo GDExtension binaries into demo/addons/hego/bin/.
#
#   scripts/build.sh                          # host platform, both targets
#   scripts/build.sh macos                    # native macOS, or OSXCross on Linux
#   ARCH=universal scripts/build.sh macos      # Intel + Apple Silicon
#   scripts/build.sh windows                  # cross-compile for Windows
#   scripts/build.sh linux-compat             # redistributable Linux, in a container
#   scripts/build.sh all                      # Linux + Windows release binaries
#   scripts/build.sh windows template_release # one specific target
#
# "linux" builds with the host toolchain: fast, but the result only loads on a glibc at
# least as new as this machine's. "linux-compat" builds in a glibc 2.28 container so the
# result loads anywhere the official Godot binaries do, and is what a release ships.
# "all" uses it. The two share object trees, so alternating forces a rebuild.
#
# Windows binaries cross-compile from Linux with MinGW. Install the toolchain once:
#   Fedora         sudo dnf install mingw64-gcc-c++ mingw64-winpthreads-static
#   Debian/Ubuntu  sudo apt install g++-mingw-w64-x86-64
#
# HEGo loads libHAPIL at runtime and never links against it, so a cross-build needs
# only the HAPI headers. A Houdini install supplies those for every platform.
#
# macOS builds on Linux need an existing OSXCross toolchain and macOS SDK:
#   OSXCROSS_ROOT=/opt/osxcross ARCH=arm64 scripts/build.sh macos
# OSXCROSS_SDK selects the compiler suffix (e.g. darwin23.5), not the SDK version.
# If unset, it is inferred when exactly one matching compiler is installed.
# Optional overrides: ARCH, JOBS, SCONS, PYTHON, MACOS_SDK_PATH,
# MACOS_DEPLOYMENT_TARGET. On macOS, ARCH defaults to the host architecture;
# other builds default to x86_64. linux-compat and Windows require x86_64.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$ROOT_DIR/demo/addons/hego/bin"
HOST_OS="$(uname -s)"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
SCONS="${SCONS:-scons}"
PYTHON="${PYTHON:-python3}"
ALL_TARGETS=(template_debug template_release)
IMAGE=hego-linux-compat
# The glibc the official Godot binaries target; anything they load, HEGo should load.
GLIBC_FLOOR=2.28

usage() {
    echo "Usage: scripts/build.sh [host|macos|linux|linux-compat|windows|all] [template_debug|template_release ...]"
    echo "Overrides: HFS, ARCH, JOBS, SCONS, PYTHON, OSXCROSS_ROOT, OSXCROSS_SDK, MACOS_SDK_PATH, MACOS_DEPLOYMENT_TARGET"
}

fail() { echo "error: $*" >&2; exit 1; }

case "${1:-host}" in
    -h|--help) usage; exit 0 ;;
    host)
        case "$HOST_OS" in
            Darwin) PLATFORMS=(macos) ;;
            Linux) PLATFORMS=(linux) ;;
            MINGW*|MSYS*|CYGWIN*) PLATFORMS=(windows) ;;
            *) fail "unsupported host $HOST_OS; specify a build platform." ;;
        esac ;;
    all)     PLATFORMS=(linux-compat windows) ;;
    macos|linux|linux-compat|windows) PLATFORMS=("$1") ;;
    *) usage >&2; fail "unknown platform: $1" ;;
esac

if [[ $# -gt 1 ]]; then TARGETS=("${@:2}"); else TARGETS=("${ALL_TARGETS[@]}"); fi
for target in "${TARGETS[@]}"; do
    case "$target" in
        template_debug|template_release) ;;
        *) fail "unknown target: $target" ;;
    esac
done
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || fail "JOBS must be a positive integer."

# Share discovery and header validation with SConstruct and the HAPI generator.
# On macOS HFS is the Resources directory inside Houdini.framework.
command -v "$PYTHON" >/dev/null || fail "$PYTHON not found; install Python 3 or set PYTHON."
HFS="$("$PYTHON" - "$ROOT_DIR" <<'PY'
import contextlib
import sys

sys.path.insert(0, sys.argv[1] + "/hapi_generator")
from generate_houdini_api import resolve_hfs

with contextlib.redirect_stdout(sys.stderr):
    hfs, _ = resolve_hfs(None)
print(hfs)
PY
)"
export HFS

configure_macos() {
    local arch="$1" sdk_path="${MACOS_SDK_PATH:-}" compiler_arch compiler sdk tool
    case "$arch" in
        arm64|x86_64|universal) ;;
        *) fail "macOS ARCH must be arm64, x86_64, or universal." ;;
    esac

    if [[ "$HOST_OS" == "Darwin" ]]; then
        command -v xcrun >/dev/null || fail "xcrun not found; install Xcode Command Line Tools with xcode-select --install."
        xcrun --find clang++ >/dev/null || fail "no working Apple compiler; check xcode-select."
        if [[ -z "$sdk_path" ]]; then
            sdk_path="$(xcrun --sdk macosx --show-sdk-path)" || fail "no macOS SDK found; check xcode-select."
        fi
    elif [[ "$HOST_OS" == "Linux" ]]; then
        [[ -d "${OSXCROSS_ROOT:-}/target/bin" && -n "${OSXCROSS_ROOT:-}" ]] || \
            fail "macOS builds on Linux require OSXCROSS_ROOT pointing to a built OSXCross toolchain."
        OSXCROSS_ROOT="$(cd "$OSXCROSS_ROOT" && pwd)"
        export OSXCROSS_ROOT
        compiler_arch="$arch"
        [[ "$arch" != "universal" ]] || compiler_arch=x86_64
        sdk="${OSXCROSS_SDK:-}"
        if [[ -z "$sdk" ]]; then
            for compiler in "$OSXCROSS_ROOT"/target/bin/"$compiler_arch"-apple-darwin*-clang++; do
                [[ -x "$compiler" ]] || continue
                [[ -z "$sdk" ]] || fail "multiple OSXCross compiler SDKs found; set OSXCROSS_SDK to the desired darwin suffix."
                sdk="${compiler##*/}"
                sdk="${sdk#"$compiler_arch"-apple-}"
                sdk="${sdk%-clang++}"
            done
        fi
        [[ "$sdk" =~ ^darwin[0-9]+(\.[0-9]+)*$ ]] || fail "OSXCROSS_SDK must match an installed compiler suffix, e.g. darwin23.5."
        for tool in clang clang++ ar ranlib as; do
            compiler="$OSXCROSS_ROOT/target/bin/$compiler_arch-apple-$sdk-$tool"
            [[ -x "$compiler" ]] || fail "OSXCross tool not found: $compiler"
        done
        if [[ "$arch" == "universal" ]]; then
            compiler="$OSXCROSS_ROOT/target/bin/arm64-apple-$sdk-clang++"
            [[ -x "$compiler" ]] || fail "universal builds also require the OSXCross ARM compiler: $compiler"
        fi
        build_args+=("osxcross_sdk=$sdk")
    else
        fail "macOS builds require a macOS host or OSXCross on Linux."
    fi

    if [[ -n "$sdk_path" ]]; then
        [[ -d "$sdk_path/usr/include" && -d "$sdk_path/System/Library/Frameworks" ]] || \
            fail "MACOS_SDK_PATH is not a macOS SDK: $sdk_path"
        sdk_path="$(cd "$sdk_path" && pwd)"
        build_args+=("macos_sdk_path=$sdk_path")
    fi
    if [[ -n "${MACOS_DEPLOYMENT_TARGET:-}" ]]; then
        build_args+=("macos_deployment_target=$MACOS_DEPLOYMENT_TARGET")
    fi
}

# A MinGW DLL that pulls in the compiler's own runtime will not load on a machine
# without MinGW installed, so check rather than trust the link flags.
verify_windows_dll() {
    local dll="$1" objdump="x86_64-w64-mingw32-objdump"
    command -v "$objdump" >/dev/null || return 0

    # Read the headers once. Piping into `grep -q` under `set -o pipefail` fails the
    # pipeline on SIGPIPE the moment grep finds a match, which reads as a broken DLL.
    local headers runtime_imports
    headers="$("$objdump" -p "$dll")"

    runtime_imports="$(grep "DLL Name:" <<<"$headers" \
        | grep -iE "libstdc\+\+|libgcc|libwinpthread" || true)"
    if [[ -n "$runtime_imports" ]]; then
        echo "error: $(basename "$dll") depends on MinGW redistributables:" >&2
        echo "$runtime_imports" >&2
        return 1
    fi

    if ! grep -q "hego_library_init" <<<"$headers"; then
        echo "error: $(basename "$dll") does not export hego_library_init" >&2
        return 1
    fi
}

# Builds inside the glibc 2.28 image. Houdini is mounted at its real path so the rpath
# baked into the binary matches the host, and label=disable keeps podman from relabelling
# anything on the host.
build_linux_compat() {
    local target="$1"
    if ! command -v podman >/dev/null; then
        echo "error: podman not found; linux-compat needs it. Use \"linux\" for a host build." >&2
        exit 1
    fi
    if ! podman image exists "$IMAGE"; then
        echo "building the $IMAGE image (first run only)"
        podman build --platform linux/amd64 -t "$IMAGE" -f "$ROOT_DIR/scripts/linux-compat.Containerfile" "$ROOT_DIR"
    fi
    # Verify inside the container too: macOS does not ship GNU readelf or sort -V.
    podman run --rm --platform linux/amd64 --security-opt label=disable \
        -v "$ROOT_DIR":/src -v "$HFS":"$HFS":ro -e HFS="$HFS" -e GLIBC_FLOOR="$GLIBC_FLOOR" -w /src \
        "$IMAGE" bash -c "set -euo pipefail
$(declare -f verify_linux_so)
scons platform=linux target=\"\$1\" arch=x86_64 -j\"\$2\"
verify_linux_so \"/src/demo/addons/hego/bin/libhego.linux.\$1.x86_64.so\"" \
        hego-linux-compat "$target" "$JOBS"
}

# A Linux binary is only redistributable if it needs no symbol newer than the floor the
# official Godot builds target, and carries no libstdc++ dependency at all.
verify_linux_so() {
    local so="$1" newest
    # Bare version numbers, so the comparison against GLIBC_FLOOR below is like for like.
    newest="$(readelf -V "$so" 2>/dev/null | grep -oE "GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?" \
        | sed 's/^GLIBC_//' | sort -uV | tail -1)"
    echo "  $(basename "$so"): needs glibc ${newest:-none}"

    if readelf -d "$so" | grep -q "libstdc++"; then
        echo "error: $(basename "$so") depends on libstdc++; it should be linked statically" >&2
        return 1
    fi
    if [[ -n "$newest" ]] && [[ "$(printf '%s\n' "$newest" "$GLIBC_FLOOR" | sort -V | tail -1)" != "$GLIBC_FLOOR" ]]; then
        echo "error: $(basename "$so") needs $newest, newer than the $GLIBC_FLOOR floor." >&2
        echo "       Build it with \"scripts/build.sh linux-compat\"." >&2
        return 1
    fi
}

for platform in "${PLATFORMS[@]}"; do
    arch="${ARCH:-x86_64}"
    if [[ "$platform" == "macos" && "$HOST_OS" == "Darwin" && -z "${ARCH:-}" ]]; then
        arch="$(uname -m)"
    fi
    # Keep this array nonempty for set -u on macOS's stock Bash 3.2.
    build_args=("platform=$platform" "arch=$arch")
    case "$platform" in
        macos) configure_macos "$arch" ;;
        linux)
            [[ "$HOST_OS" == "Linux" ]] || fail "native Linux builds need a Linux host; use linux-compat for a container build."
            ;;
        linux-compat)
            [[ "$arch" == "x86_64" ]] || fail "linux-compat currently supports ARCH=x86_64 only."
            ;;
        windows)
            [[ "$arch" == "x86_64" ]] || fail "the Windows build currently supports ARCH=x86_64 only."
            case "$HOST_OS" in
                MINGW*|MSYS*|CYGWIN*) ;;
                *)
                    command -v x86_64-w64-mingw32-g++ >/dev/null || \
                        fail "x86_64-w64-mingw32-g++ not found; see the header of this script."
                    build_args+=(use_mingw=yes)
                    ;;
            esac
            ;;
    esac
    if [[ "$platform" != "linux-compat" ]]; then
        command -v "$SCONS" >/dev/null || fail "$SCONS not found; install SCons or set SCONS to its executable."
    fi

    for target in "${TARGETS[@]}"; do
        echo "── $platform / $target / $arch ──"
        if [[ "$platform" == "linux-compat" ]]; then
            build_linux_compat "$target"
        else
            ( cd "$ROOT_DIR" && "$SCONS" "${build_args[@]}" "target=$target" -j"$JOBS" )
            case "$platform" in
                windows) verify_windows_dll "$BIN_DIR/hego.windows.$target.$arch.dll" ;;
                linux) verify_linux_so "$BIN_DIR/libhego.linux.$target.$arch.so" ;;
            esac
        fi
    done
done

echo
echo "Binaries in $BIN_DIR:"
ls -lh "$BIN_DIR" | grep -vE "^total|gdextension"
