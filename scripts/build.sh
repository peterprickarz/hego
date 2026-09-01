#!/usr/bin/env bash
#
# Builds the HEGo GDExtension binaries into demo/addons/hego/bin/.
#
#   scripts/build.sh                          # host platform, both targets
#   scripts/build.sh windows                  # cross-compile for Windows
#   scripts/build.sh all                      # every binary a release ships
#   scripts/build.sh windows template_release # one specific target
#
# Windows binaries cross-compile from Linux with MinGW. Install the toolchain once:
#   Fedora         sudo dnf install mingw64-gcc-c++ mingw64-winpthreads-static
#   Debian/Ubuntu  sudo apt install g++-mingw-w64-x86-64
#
# HEGo loads libHAPIL at runtime and never links against it, so a cross-build needs
# only the HAPI headers. The Linux Houdini install supplies those for every platform.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$ROOT_DIR/demo/addons/hego/bin"
JOBS="$(nproc 2>/dev/null || echo 4)"
ALL_TARGETS=(template_debug template_release)

# Any Houdini 22.0 install works, since only the headers are read.
if [[ -z "${HFS:-}" ]]; then
    for candidate in /opt/hfs22.0 /opt/hfs22.0.368; do
        if [[ -d "$candidate" ]]; then HFS="$candidate"; break; fi
    done
fi
if [[ ! -d "${HFS:-}" ]]; then
    echo "error: no Houdini install found. Set HFS to one." >&2
    exit 1
fi
export HFS

case "${1:-host}" in
    host)    PLATFORMS=("$(uname -s | tr '[:upper:]' '[:lower:]')") ;;
    all)     PLATFORMS=(linux windows) ;;
    *)       PLATFORMS=("$1") ;;
esac

if [[ $# -gt 1 ]]; then TARGETS=("${@:2}"); else TARGETS=("${ALL_TARGETS[@]}"); fi

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

for platform in "${PLATFORMS[@]}"; do
    extra=()
    if [[ "$platform" == "windows" && "$(uname -s)" != *"NT"* ]]; then
        if ! command -v x86_64-w64-mingw32-g++ >/dev/null; then
            echo "error: x86_64-w64-mingw32-g++ not found; see the header of this script." >&2
            exit 1
        fi
        extra+=(use_mingw=yes)
    fi

    for target in "${TARGETS[@]}"; do
        echo "── $platform / $target ──"
        ( cd "$ROOT_DIR" && scons platform="$platform" target="$target" arch=x86_64 \
            "${extra[@]}" -j"$JOBS" )
    done
done

echo
echo "Binaries in $BIN_DIR:"
for dll in "$BIN_DIR"/hego.windows.*.dll; do
    [[ -e "$dll" ]] || continue
    verify_windows_dll "$dll"
done
ls -lh "$BIN_DIR" | grep -vE "^total|gdextension"
