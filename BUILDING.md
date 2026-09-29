# Building HEGo on macOS and Linux

HEGo is a Godot 4.4+ C++ GDExtension. The pinned `godot-cpp` submodule supplies
Godot's bindings. HEGo reads Houdini 22.0.429 HAPI headers at compile time and loads
Houdini Engine dynamically when a session starts. Cross-compiling therefore does
not require a Houdini installation for the target operating system.

## Common setup

```sh
git clone --recurse-submodules https://github.com/peterprickarz/hego.git
cd hego
# For an existing clone:
git submodule update --init --recursive
python3 -m venv .venv
source .venv/bin/activate
python -m pip install 'scons>=4.5,<5'
```

Python 3.8+ is required. Activate `.venv` in each new shell, or set
`SCONS="$PWD/.venv/bin/scons"` when using the build script.

Choose one source of HAPI headers:

- An existing Houdini installation: set `HFS` to the directory containing
  `toolkit/include/HAPI`. Without `HFS`, the build checks the default installation
  and then discovers installed versions. Prefer 22.0.429, which matches the
  generated bindings in this checkout.
- Headers only, for machines without Houdini:

  ```sh
  python scripts/fetch_hapi_headers.py
  export HFS="$PWD/build/deps/houdini"
  ```

The download helper extracts the HAPI headers and license from SideFX's pinned
official Houdini Engine release, verifies its archive checksum, and stores source
information beside the headers. This directory is a build dependency, not a
Houdini runtime. Do not configure it as the installation in the Godot editor.

## Native macOS

Install Apple's compiler and SDK once if they are missing:

```sh
xcode-select --install
```

With a full Houdini installation, `HFS` typically looks like this:

```sh
export HFS="/Applications/Houdini/Houdini22.0.429/Frameworks/Houdini.framework/Versions/Current/Resources"
```

Alternatively use the headers-only `HFS` from the common setup. Build both debug
and release binaries:

```sh
scripts/build.sh macos
```

The native default is the host CPU: `arm64` on Apple Silicon or `x86_64` on Intel.
To build both architectures into each binary:

```sh
ARCH=universal scripts/build.sh macos
```

Other useful commands:

```sh
ARCH=arm64 JOBS=8 scripts/build.sh macos template_debug
ARCH=x86_64 scripts/build.sh macos template_release
# Direct SCons also works (its macOS default architecture is universal):
scons platform=macos arch=arm64 target=template_debug -j8
```

Output files, already referenced by `demo/addons/hego/bin/hego.gdextension`:

```text
demo/addons/hego/bin/libhego.macos.template_debug.dylib
demo/addons/hego/bin/libhego.macos.template_release.dylib
```

Each architecture has separate intermediate files under `build/`. The last
architecture built for a target is installed at that target's stable output path.
Use `ARCH=universal` before distributing to both Intel and Apple Silicon users.
The extension's default deployment target is macOS 11.0; the installed Houdini
runtime can have a newer OS requirement. Override the extension target with
`MACOS_DEPLOYMENT_TARGET`, or the SDK with `MACOS_SDK_PATH`.

## Native Linux

Install a C++17 compiler and Python development tooling. On Debian/Ubuntu:

```sh
sudo apt install build-essential python3-venv
```

After the common setup:

```sh
export HFS=/opt/hfs22.0  # or the headers-only directory
scripts/build.sh linux
```

The wrapper retains the release's `x86_64` default. The host build uses the host
glibc. Its compatibility check can reject a successful compile on a newer distro;
for redistributable x86_64 binaries, use the existing glibc 2.28 container build:

```sh
scripts/build.sh linux-compat
```

This requires Podman. `scripts/build.sh all` retains its existing meaning: the
Linux compatibility build plus the Windows MinGW build. Build macOS separately.

## Cross-compile macOS binaries on Linux

Use an installed [OSXCross toolchain](https://github.com/tpoechtrager/osxcross#installation)
and an Apple macOS SDK. Follow the upstream
[SDK packaging instructions](https://github.com/tpoechtrager/osxcross/blob/master/README.SDK.md)
using your Xcode or Command Line Tools SDK. HEGo does not download or redistribute
an Apple SDK.

For Apple Silicon or universal binaries, use an SDK with arm64 support (macOS 11
or newer). When building OSXCross, enable both CPUs if you want universal output:

```sh
# Inside the OSXCross checkout, after placing the SDK archive in tarballs/:
ENABLE_ARCHS="arm64 x86_64" OSX_VERSION_MIN=11.0 UNATTENDED=1 ./build.sh
```

Then return to HEGo, activate its Python environment, and set:

```sh
export HFS=/path/to/houdini-or-headers
export OSXCROSS_ROOT=/path/to/osxcross
ARCH=universal scripts/build.sh macos
# Or one architecture/target:
ARCH=arm64 scripts/build.sh macos template_release
```

`OSXCROSS_ROOT` is the checkout containing `target/bin`, not `target` itself.
The wrapper detects the compiler suffix when exactly one is installed. If several
SDK toolchains are present, select the suffix in the wrapper executable names:

```sh
# For target/bin/arm64-apple-darwin23.5-clang++:
OSXCROSS_SDK=darwin23.5 ARCH=arm64 scripts/build.sh macos
```

`darwin23.5` is an example; use the suffix installed on your machine. Direct SCons
uses the same `OSXCROSS_ROOT` environment variable, with
`osxcross_sdk=darwin23.5` as a command-line option. The HEGo build explicitly selects
Mach-O dynamic-library linking on Linux as well as macOS and does not link to a
host Houdini library.

## Runtime and verification

Open `demo/project.godot` in Godot after building. To start an actual Houdini
session, install Houdini for the same CPU architecture as Godot and configure
`hego/houdini_installation_path` in the project's settings. On macOS this points
to the framework's `Resources` directory. HEGo loads `../Libraries/libHAPIL.dylib`
relative to it; on Linux it loads `dsolib/libHAPIL.so`.

An existing project setting takes priority over `$HFS`. Launching from Finder
does not normally inherit your shell's environment, so use the project setting
there. A Houdini session also needs an appropriate Houdini Engine license.

To inspect macOS binaries:

```sh
file demo/addons/hego/bin/libhego.macos.*.dylib
lipo -archs demo/addons/hego/bin/libhego.macos.template_debug.dylib
nm -gU demo/addons/hego/bin/libhego.macos.template_debug.dylib | grep hego_library_init
otool -L demo/addons/hego/bin/libhego.macos.template_debug.dylib
```

These check binary format, CPU slices, Godot entry point, and linked libraries.
A successful compile or extension-load test does not test Houdini cooking; test
a real session with a compatible Houdini installation before distribution.
