# Development package layout

`scripts/publish-next.sh` creates four matched package refs from one committed
source revision. The publisher validates both native build manifests before it
stages or pushes anything. Each package records its source revision in
`SOURCE_COMMIT` and `PACKAGE.json`.
The branch refs are updated with one atomic push, so a remote that cannot
accept the matched update leaves all published refs unchanged.

| Ref | Contents | Install use |
| --- | --- | --- |
| `release-next` | HEGo addon root | Standalone HEGo at `addons/hego`, the same single-addon submodule path as before. It needs no other package. |
| `strata-release-next` | Strata addon root | Standalone Strata at `addons/strata`; it needs neither HEGo nor Houdini. |
| `hego-strata-release-next` | HEGo Strata addon root | The bridge at `addons/hego_strata`, for cooking HDAs into terrain layers. Requires the other two. |
| `release-next-bundle` | `hego/`, `strata/` and `hego_strata/` | Copy the three directories into a Godot project's `addons/` directory. |

Dependencies point one way. The HEGo and Strata manifests declare no package
dependencies; the bridge manifest requires `release-next` and
`strata-release-next` at its own `SOURCE_COMMIT`. The bundle contains all three
addon trees so a consumer can install the matched set in one operation. The
bridge contains no native code, so it has no build receipt. Its native extension
is built from `SConstruct.terrain` using godot-cpp and does not invoke SCons's
Houdini-dependent HEGo build.

## Platform scope and release gate

Both extensions build for Linux x86_64 and ARM64 (host toolchain or the glibc
2.28 AlmaLinux container, which runs under qemu-user-static on a foreign host),
Windows x86_64 (MinGW-w64) and macOS (universal x86_64 + arm64, natively or with
OSXCross on Linux). The extension descriptors name all of these libraries, so a
release that lacks one of them is rejected by the receipt gate below until it is
built. `SConstruct.terrain` uses only godot-cpp and Strata sources; none of the
Strata targets requires Houdini or HEGo.
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
ARCH=arm64 scripts/build.sh linux-compat               # Linux ARM64 container (qemu on x86_64 hosts)
OSXCROSS_ROOT=~/osxcross ARCH=universal scripts/build.sh macos
```

Terrain builds independently, without `HFS`:

```bash
scripts/build-terrain.sh                          # host platform, both targets
scripts/build-terrain.sh linux-compat             # glibc 2.28 container
scripts/build-terrain.sh windows                 # MinGW-w64 cross-build
scripts/build-terrain.sh all                      # linux-compat x86_64 + Windows
ARCH=arm64 scripts/build-terrain.sh linux-compat  # Linux ARM64 container (qemu on x86_64 hosts)
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

The dry-run validates receipts, builds all three trees locally, and prints the
prospective tree IDs without contacting a remote:

```bash
scripts/publish-next.sh origin HEAD --dry-run
python3 scripts/tests/test_distribution.py
```

The distribution test uses temporary source repositories and a temporary bare
remote. It checks dry-run behavior, both dependency layouts, bundle paths,
binary receipts, branch history, and the existing development-submodule switch
workflow. It does not publish to the project's remote.
