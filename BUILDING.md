# Building HEGo on Linux

HEGo is a Godot 4.4+ C++ GDExtension. The pinned `godot-cpp` submodule supplies
Godot's bindings. HEGo reads Houdini 22.0.429 HAPI headers at compile time and loads
Houdini Engine dynamically when a session starts. Cross-compiling therefore does
not require a Houdini installation for the target operating system.

HEGo ships Linux x86_64 and Windows x86_64 libraries only. **macOS is not supported**:
there is no macOS build, no macOS library in `hego.gdextension` and no macOS package.

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
Linux compatibility build plus the Windows MinGW build.

## Runtime and verification

Open `demo/project.godot` in Godot after building. To start an actual Houdini
session, install Houdini for the same CPU architecture as Godot and configure
`hego/houdini_installation_path` in the project's settings. On Linux, HEGo loads
`dsolib/libHAPIL.so` relative to it.

An existing project setting takes priority over `$HFS`. A Houdini session also
needs an appropriate Houdini Engine license.

A successful compile or extension-load test does not test Houdini cooking; test
a real session with a compatible Houdini installation before distribution.
