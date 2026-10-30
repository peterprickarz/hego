<div align="center">
  <img src="demo/addons/hego/assets/logo.png" alt="HEGo Logo" width="128">
  
  # HEGo - Houdini Engine in Godot
  
  A C++ GDExtension that integrates Houdini Engine into Godot 4, enabling procedural content generation using Houdini Digital Assets (HDAs) with a scriptable API.
</div>

## 🚀 Getting Started

- 📦 **[Download Latest Release](https://github.com/peterprickarz/hego/releases/latest)** - Pre-built binaries for Windows
- 📖 **[Documentation](https://hego.readthedocs.io/en/latest/about/introduction.html)** - Documentation and guides
- 💬 **[Discord](https://discord.gg/bAw7Pv8ETG)** - Chat with other users and contributors
- 🎥 **[Introduction Video](https://youtu.be/cviGlmKmFQ8)** - Visual walkthrough(outdated)


### Quick Install

**Option 1: Git Submodule (Recommended)**
```bash
# Add HEGo as a submodule in your Godot project
git submodule add -b release https://github.com/peterprickarz/hego.git addons/hego
git submodule update --init --recursive
```

**Option 2: Manual Download**
1. Download the latest release
2. Extract to your Godot project's `addons/` folder
3. Enable the plugin in Project Settings

> **Note**: The `release` branch is automatically updated with each commit to `main` and contains only the addon files, making it perfect for submodule use.

### Strata terrain and the HEGo Strata bridge

HEGo ships with two more addons that are developed in this repository but installed
separately, each with a one-way dependency:

| Addon | Folder | Depends on | What it does |
| --- | --- | --- | --- |
| **HEGo** | `addons/hego` | – | Houdini Engine integration (this addon) |
| **Strata** | `addons/strata` | – | Layered terrain: hand and procedural layers, quadtree mesher, material renderer, bake, collision and navigation. Works without Houdini. |
| **HEGo Strata** | `addons/hego_strata` | HEGo + Strata | Routes HDA heightfield volumes carrying `hegostrata_*` attributes into Strata layers |

The `next` channel publishes them as `release-next` (HEGo), `strata-release-next`,
`hego-strata-release-next` and `release-next-bundle` (all three); see
[docs/next-packaging.md](docs/next-packaging.md). Cooking a terrain is covered in
[docs/terrain-houdini-integration.md](docs/terrain-houdini-integration.md), the terrain
itself in [docs/terrain-runtime.md](docs/terrain-runtime.md).

> **Note**: The demo island's cooked terrain data and textures are stored with
> [Git LFS](https://git-lfs.com). Run `git lfs install` once before cloning (or
> `git lfs pull` afterwards), otherwise `demo/scenes/terrain_island.tscn` finds pointer
> files instead of its layers.

## Features

- **Scriptable API**: Built with GDScript integration in mind for maximum flexibility
- **Multiple Node Types**: Support for geometry input, curve input, heightfield input and HDA asset nodes
- **Session Management**: Multiple session types (in-process, TCP, named pipes, shared memory)
- **Bidirectional Data Flow**: Convert between Godot and Houdini geometry formats
- **Parameter Management**: Automatic type conversion between Godot Variant and HAPI types
- **Mesh Generation**: Generate Godot meshes, instances, and scene nodes from Houdini
- **[Terrain3D](https://tokisan.com/terrain3d/) Bridge**: Generate Terrain3D terrains, use Terrain3D instancing, Terrain3D heightfield inputs

## Requirements

- **Houdini 22.0.429** - No license needed for building, active commercial(FX,Core or Houdini Engine) license required for runtime
- **Godot 4.4+** - Stable or newer versions supported  

## Developer Setup
> If you're interested in contributing read on, otherwise check out the Releases section for the latest version

### Terrain island in the main demo

Open `demo/project.godot` and select `res://scenes/terrain_island.tscn` to edit or
play the saved island normally. The scene uses the installed addons in
`demo/addons`; no launcher, addon staging or automatic Houdini cook is required.
The terrain's layers and cooked channels live as one file each under
`demo/island/terrain/` and are committed; a cook overwrites its files in place,
and the bake and material control maps are rebuilt on open. Island assets, scripts
and HDAs are in `demo/island/`, tests in `demo/tests/`. See the
[island workflow](docs/island-showcase.md) for explicit cooking.
Artificial prototype scenes remain under `demo/scenes/terrain_prototype/`;
automated standalone/integration tests use disposable projects.

### Testing HEGo in another project

`next` is the development source branch. The **Publish next addon** workflow
stages four matched refs: `release-next` (HEGo), `strata-release-next`
(Strata, the standalone terrain), `hego-strata-release-next` (the bridge that cooks HDAs
into terrain layers), and `release-next-bundle` (all three in a consumer layout).
HEGo and Strata each stand alone; only the bridge's package manifest declares
dependencies, on the other two at the same source revision.
Every package records `SOURCE_COMMIT`; native build receipts must match the
selected source revision before staging. Each publication is a child of its
previous publication, uses an atomic non-force push, and does not
modify the source checkout. See [the package layout and build guide](docs/next-packaging.md).

The HEGo-only submodule package can be installed with:

```bash
cd /path/to/godot-project
git submodule add -b release-next https://github.com/peterprickarz/hego.git addons/hego
```

That is all HEGo needs. To cook HDAs into Strata layers, also install
`strata-release-next` at `addons/strata` and `hego-strata-release-next`
at `addons/hego_strata`, or use `release-next-bundle` and place its three
directories in the project's `addons/` directory. Strata can also be installed
alone, without HEGo or Houdini.

For an existing, genuine submodule, change its tracking branch from the consumer's
repository root, then deliberately update and commit the tested pin:

```bash
git submodule set-branch --branch release-next game/addons/hego
git submodule update --remote -- game/addons/hego
git add .gitmodules game/addons/hego
git commit -m "Update HEGo development dependency"
```

Use the actual repository-relative addon path; TheNetwork's Godot project is
`game/`. A `.gitmodules` entry alone is insufficient: `git ls-files --stage --
game/addons/hego` must show one `160000` entry. If it lists individual addon files,
preserve any local edits and migrate the vendored files to a proper submodule
first. The switch script intentionally refuses this mixed state.

For live development, close the consumer's Godot editor before either switch
(especially when changing native libraries), then run from the HEGo source repo:

```bash
python3 scripts/hego-dev.py enable ../TheNetwork/game --checkout .
python3 scripts/hego-dev.py status ../TheNetwork/game
# Reopen TheNetwork and test; edits under addons/hego affect this HEGo checkout.
# Close its editor again before restoring the published package.
python3 scripts/hego-dev.py disable ../TheNetwork/game
```

The script saves the initialized submodule directory under the consumer's Git
directory and installs an absolute directory symlink to the local checkout's
`demo/addons/hego`. It requires a clean submodule at the index's pinned revision.
Ignored files are preserved in the saved directory. Disable restores that exact
directory and refuses to overwrite a replaced link or restore against a changed
index pin. Python 3.9+ and directory-symlink support are required.

While enabled, commit HEGo changes in the **source checkout**, on a feature branch
for a PR into `next`. Do not stage the consumer's addon symlink, change its pin,
switch consumer branches, or run submodule updates until development mode is
disabled. The consumer can show a local addon change during this time; the
symlink is not a distributable dependency. After the PR is merged and published,
disable development mode, update the submodule, test the packaged version, and
commit the consumer's new pin.

Local publisher/switch integration checks (temporary repositories only):

```bash
python3 scripts/tests/test_distribution.py
```

### Prerequisites

- **Python 3.8+** with SCons: `python -m pip install scons`
- **C++17 compiler**: Xcode Command Line Tools on macOS, GCC on Linux, or Visual Studio 2022 on Windows
- **Git** for cloning and submodules

See [Building on macOS and Linux](BUILDING.md) for native builds, Apple Silicon/Intel
binaries, and cross-compiling from Linux to macOS with OSXCross. Only HAPI headers
are required to compile; Houdini itself is needed when running a session.
Experimental Linux ARM64 builds and an isolated runtime test are documented in
[Linux ARM64 testing](BUILDING.md#linux-arm64-testing).

### Quick Setup

1. **Clone the repository**
   ```bash
   git clone https://github.com/peterprickarz/hego.git
   cd hego
   ```

2. **Initialize submodules**
   ```bash
   git submodule update --init --recursive
   ```

3. **Set Houdini environment** (optional)
   ```bash
   set HFS=C:\Program Files\Side Effects Software\Houdini 22.0.429
   ```

### Building

**macOS / Linux**
```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install 'scons>=4.5,<5'
scripts/build.sh              # native debug + release; discovers Houdini via HFS
scripts/build.sh all          # redistributable Linux x86_64 (container) + Windows (MinGW)
ARCH=arm64 scripts/build.sh linux-compat                      # Linux ARM64 (qemu on x86_64 hosts)
OSXCROSS_ROOT=~/osxcross ARCH=universal scripts/build.sh macos  # universal macOS from Linux
scripts/build-terrain.sh ...  # the same platforms for the Strata extension, no Houdini needed
```

For a build without a Houdini installation, first run
`python scripts/fetch_hapi_headers.py` and set `HFS="$PWD/build/deps/houdini"`.
See [BUILDING.md](BUILDING.md) for the complete commands and runtime setup.

**Windows — Option 1: VS Code**
- Use Ctrl+Shift+P → "Tasks: Run Task" → "build"

**Windows — Option 2: Command Line**
- From VS2022 Developer Command Prompt: `scons`
- Or any terminal: `scons` (if VS2022 is in PATH)

**Build Options**
```bash
scons target=template_debug    # Debug build
scons target=template_release  # Release build  
scons -c                       # Clean build
```

### VS Code Configuration

If the build task fails, update `.vscode/tasks.json`:
```json
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "build",
      "group": "build",
      "type": "shell",
      "command": "cmd",
      "args": [
        "/c",
        "\"C:\\Program Files\\Microsoft Visual Studio\\2022\\Community\\VC\\Auxiliary\\Build\\vcvarsall.bat\" x64 && scons"
      ],
      "problemMatcher": "$msCompile"
    }
  ]
}
```

**Output**: Built library appears in `demo/addons/hego/bin/`

### Documentation

The class reference is generated, and the site is built from `docs/`:

```bash
scripts/generate_gdscript_docs.sh   # after changing a GDScript class's ## comments
scripts/generate_docs.sh            # rewrites docs/classes from the class reference XML
python -m sphinx -W -b html docs docs/_build/html
```

`generate_gdscript_docs.sh` needs Godot (set `GODOT` to pick the binary) and writes
`demo/addons/hego/doc_classes_gdscript/`, which is committed so the site builds without it.
A class with no place in the tree fails `generate_docs.sh`; add it to a group in
`scripts/class_tree.py`.

## Get Help

Join the 💬[Discord](https://discord.gg/bAw7Pv8ETG) where other users or contributors can help you.

If you don't have discord, feel free to message me on [X](https://x.com/prickarz) where I will try to help as much as I can.


## Shoutouts

- Big thanks to https://ambientcg.com/ and https://freestylized.com/ for providing CC0 textures I used in the demo project.
- There's also a [houdini2godot](https://github.com/Mandrake0/houdini2godot) plugin made by [Mandrake0](https://github.com/Mandrake0) which allows to export Godot scenes directly from Houdini.
