# Development package layout

`scripts/publish-next.sh` creates five matched package refs from one committed
source revision. The publisher validates both native build manifests before it
stages or pushes anything. Each package records its source revision in
`SOURCE_COMMIT` and `PACKAGE.json`.
The branch refs are updated with one atomic push, so a remote that cannot
accept the matched update leaves all published refs unchanged.

| Ref | Contents | Install use |
| --- | --- | --- |
| `release-next` | HEGo addon root | Standalone HEGo at `addons/hego`, the same single-addon submodule path as before. It needs no other package. |
| `strata-release-next` | Strata addon root | Standalone Strata at `addons/strata`; it needs neither HEGo nor Houdini. |
| `hego-strata-release-next` | HEGo Strata addon root | The bridge at `addons/hego_strata`, for cooking HDAs into Strata layers. Requires HEGo and Strata. |
| `hego-terrain3d-release-next` | HEGo Terrain3D addon root | The Terrain3D bridge at `addons/hego_terrain3d`: Terrain3D heightfield inputs, terrains and instancing. Requires HEGo and the Terrain3D addon. |
| `release-next-bundle` | `hego/`, `strata/`, `hego_strata/` and `hego_terrain3d/` | Copy the four directories into a Godot project's `addons/` directory. Terrain3D is not included. |

Dependencies point one way. The HEGo and Strata manifests declare no package
dependencies; the HEGo Strata manifest requires `release-next` and
`strata-release-next` at its own `SOURCE_COMMIT`, and the HEGo Terrain3D manifest
requires `release-next` at its own `SOURCE_COMMIT`. Terrain3D itself is
TokisanGames' addon, not one of these packages, so the HEGo Terrain3D manifest
names it under `external_requires` instead: Terrain3D at `addons/terrain_3d`,
tested with 1.0.1 and installed by the user. The bundle contains all four
addon trees so a consumer can install the matched set in one operation, and
repeats that external requirement; a project without Terrain3D leaves out
`hego_terrain3d/`. Neither bridge contains native code, so neither has a build
receipt, and the publisher validates receipts for HEGo and Strata only. Strata's
native extension is built from `SConstruct.terrain` using godot-cpp and does not
invoke SCons's Houdini-dependent HEGo build.

The HEGo Terrain3D manifest, with `<sha>` the source revision:

```json
{
  "format_version": 1,
  "package": "hego-terrain3d",
  "addon_path": "addons/hego_terrain3d",
  "source_commit": "<sha>",
  "requires": [{"package": "hego", "branch": "release-next", "addon_path": "addons/hego", "source_commit": "<sha>"}],
  "external_requires": [{"name": "Terrain3D", "author": "TokisanGames", "url": "https://github.com/TokisanGames/Terrain3D", "addon_path": "addons/terrain_3d", "tested_version": "1.0.1", "installed_by": "user"}]
}
```

## Platform scope and release gate

Both extensions ship for Linux x86_64 (glibc 2.28 AlmaLinux container), Windows
x86_64 (MinGW-w64) and macOS (universal x86_64 + arm64, natively or with OSXCross
on Linux); the extension descriptors name exactly these libraries, and a release
that lacks one of them is rejected by the receipt gate below. Linux ARM64 is
supported by the build scripts (`ARCH=arm64`, natively or in the container under
qemu-user-static) but not shipped: emulated builds take hours on an x86_64 host,
so it waits for a native ARM64 build machine or CI runner, after which the
descriptors can declare the `linux.*.arm64` libraries again. `SConstruct.terrain`
uses only godot-cpp and Strata sources; none of the Strata targets requires
Houdini or HEGo.
On 2026-10-30, HEGo's Linux-compatible and Windows debug/release artifacts were
rebuilt and receipted, and Strata's matching native receipts were validated.
All four Linux libraries require glibc no newer than 2.25. Both debug and release
pairs passed isolated native class/API/sample/mesh smoke checks in Godot 4.4.1
and 4.7.2; these checks started no Houdini session and cooked no HDA. The Windows
DLLs passed MinGW import/export checks only; Windows Godot loader acceptance
remains a release gate. The publisher rejects a package when a descriptor names
an artifact without a matching receipt.

## Build current native binaries

Build receipts live at each addon's root as `native-build.json`, alongside its
`bin/` directory. They record the SHA-256 of each library and a fingerprint
of the native source, SCons configuration, build scripts, and godot-cpp revision.
GDScript or scene-only edits do not invalidate the native fingerprint. A
changed native input does, and publishing is refused until the affected
extension binaries are rebuilt and receipted. Every library named by a
`.gdextension` descriptor must exist and match its receipt. Per-library build
context records platform, target, architecture, compiler, and (for HEGo) the
Houdini version and HAPI-header digest.

HEGo builds require the Houdini 22 headers and runtime configuration:

```bash
scripts/build.sh linux template_debug template_release
scripts/build.sh all                                   # linux-compat x86_64 + Windows
ARCH=arm64 scripts/build.sh linux-compat               # Linux ARM64 container (not shipped yet; hours under qemu)
OSXCROSS_ROOT=~/osxcross ARCH=universal scripts/build.sh macos
```

Terrain builds independently, without `HFS`:

```bash
scripts/build-terrain.sh                          # host platform, both targets
scripts/build-terrain.sh linux-compat             # glibc 2.28 container
scripts/build-terrain.sh windows                 # MinGW-w64 cross-build
scripts/build-terrain.sh all                      # linux-compat x86_64 + Windows
ARCH=arm64 scripts/build-terrain.sh linux-compat  # Linux ARM64 container (not shipped yet; hours under qemu)
OSXCROSS_ROOT=~/osxcross ARCH=universal scripts/build-terrain.sh macos
scripts/build-terrain.sh template_debug           # legacy host-target form
scripts/build-terrain.sh --dry-run all template_debug
python3 scripts/tests/test_build_terrain.py
```

The Windows output is statically linked against the MinGW C++ runtime and is
checked for unexpected MinGW/Houdini imports and the extension entry point. The
Linux-compatible output is checked for dynamic C++/Houdini dependencies, the
extension entry point, and a GLIBC symbol floor no newer than 2.28. Host Linux
builds are development artifacts and do not receive the compatibility-floor
check. These static checks do not replace loading the DLL in a Windows Godot
runtime.

Receipts are source files and should be committed with the corresponding native
binaries. If the repository ignores a generated library, force-add the freshly
built artifact explicitly (for example, `git add -f demo/addons/strata/bin/libstrata.linux.template_debug.x86_64.so`). Commit the
corresponding `native-build.json` too. Do not copy a binary from another source
revision into a package.

## Validate package staging without publishing

The dry-run validates receipts, builds all five trees locally, and prints the
prospective tree IDs without contacting a remote. An addon directory missing from
the source revision stops it with an error rather than staging an empty package:

```bash
scripts/publish-next.sh origin HEAD --dry-run
python3 scripts/tests/test_distribution.py
```

The distribution test uses temporary source repositories and a temporary bare
remote. It checks dry-run behavior, both dependency layouts, bundle paths,
binary receipts, branch history, and the existing development-submodule switch
workflow. It does not publish to the project's remote.
