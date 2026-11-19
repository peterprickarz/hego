# Building HEGo on Linux

HEGo is a Godot 4.7+ C++ GDExtension. The pinned `godot-cpp` submodule supplies
Godot's bindings. HEGo reads Houdini 22.0.429 HAPI headers at compile time and loads
Houdini Engine dynamically when a session starts. Cross-compiling therefore does
not require a Houdini installation for the target operating system.

HEGo, Strata and Copia ship Linux x86_64 and Windows x86_64 libraries only. **macOS is not
supported**: there is no macOS build, no macOS library in the extension descriptors and no
macOS package.

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

The wrapper defaults to the host CPU (`x86_64` or `arm64`; `aarch64` is also accepted
as an `ARCH` override). The host build uses the host glibc. For x86_64, its
compatibility check can reject a successful compile on a newer distro;
for redistributable x86_64 binaries, use the existing glibc 2.28 container build:

```sh
scripts/build.sh linux-compat
```

This requires Podman. `scripts/build.sh all` retains its existing meaning: the
Linux compatibility build plus the Windows MinGW build.

### Linux ARM64 testing

ARM64 support is experimental until tested with an ARM Houdini runtime. Use an
ARM64 Godot 4.7+ executable and the **Houdini 22 Linux ARM Technical Preview**,
preferably 22.0.429 to match this checkout's bindings. SideFX requires a CPU
implementing the Neoverse-N1 instruction set; see the
[Houdini system requirements](https://www.sidefx.com/Support/system-requirements/).
An x86_64 `libHAPIL.so` cannot load in ARM64 Godot, even for a network session.

The `codex/linux-arm64` testing branch includes cross-compiled debug and release
binaries built with Debian 12's GCC 12 toolchain, requiring **glibc 2.36 or newer**.
To try those binaries without building, clone the branch and run the smoke tests
below. Submodules are only needed if you rebuild.

```sh
git clone --single-branch -b codex/linux-arm64 https://github.com/peterprickarz/hego.git
cd hego
export HFS=/path/to/your/arm64/houdini
```

On the ARM Linux machine, after the common setup:

```sh
export HFS=/path/to/your/arm64/houdini
ARCH=arm64 scripts/build.sh linux
```

Both debug and release outputs have `.arm64.so` filenames and are selected by
`hego.gdextension`. The build checks the ELF CPU, exported Godot entry point and
static C++ runtime, and prints the minimum glibc version. ARM builds do not enforce
the x86 release's glibc 2.28 ceiling. For a specific deployment baseline, set e.g.
`GLIBC_FLOOR=2.36`; a newer requirement then fails verification. Build on the oldest
supported target distro or against an appropriate sysroot for redistribution.
`linux-compat` and `all` still only produce x86_64 Linux binaries.

To cross-compile on Debian/Ubuntu x86_64 (HAPI headers alone are sufficient):

```sh
sudo apt install g++-aarch64-linux-gnu binutils
CC=aarch64-linux-gnu-gcc CXX=aarch64-linux-gnu-g++ \
AR=aarch64-linux-gnu-gcc-ar RANLIB=aarch64-linux-gnu-gcc-ranlib \
ARCH=arm64 scripts/build.sh linux
```

`ARCH` selects code generation, not a cross-compiler. On a different host CPU,
set the toolchain explicitly as above. Both godot-cpp and HEGo use these tools.

Run these checks on the ARM machine, using the actual Godot executable rather
than a terminal-launcher script:

```sh
file demo/addons/hego/bin/libhego.linux.*.arm64.so "$HFS/dsolib/libHAPIL.so"
python3 scripts/smoke_test.py --godot /path/to/godot --load-only
python3 scripts/smoke_test.py --godot /path/to/godot --hfs "$HFS"
```

The first smoke test needs no Houdini installation or license. The second needs a
working licensed ARM Houdini runtime: it creates a private named-pipe session,
cooks a box, reads its surface output and closes the session. Both use a temporary
project containing only HEGo. **Do not use the full demo for the first ARM test:**
its bundled Terrain3D Linux binaries are x86_64 and need a separate ARM build.
For an editor test, copy `demo/addons/hego` into a fresh ARM Godot project, enable
HEGo and set `hego/houdini_installation_path` to the ARM Houdini installation.

When reporting results, include the CPU model, distro, `ldd --version`, Godot and
Houdini versions, the `file` output above and the full smoke-test output. A
successful extension-load test alone does not establish Houdini cooking support.

## Runtime and verification

Open `demo/project.godot` in Godot after building. To start an actual Houdini
session, install Houdini for the same CPU architecture as Godot and configure
`hego/houdini_installation_path` in the project's settings. On Linux HEGo loads
`dsolib/libHAPIL.so` relative to it.

An existing project setting takes priority over `$HFS`. Launching from a desktop
launcher does not normally inherit your shell's environment, so use the project
setting there. A Houdini session also needs an appropriate Houdini Engine license.

A successful compile or extension-load test does not test Houdini cooking; test
a real session with a compatible Houdini installation before distribution.
