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

### Testing HEGo in another project

`next` is the development source branch. The **Publish next addon** workflow
publishes its committed `demo/addons/hego` contents to `release-next`, with
README, license, and a `SOURCE_COMMIT` file identifying the source revision.
Each publication is a child of the previous publication: old submodule pins stay
reachable. The initial publication creates an independent root commit. Publication
uses ordinary pushes, never force-pushes, and does not modify the source checkout.
It packages checked-in binaries; it does **not** build them. Include matching
binaries when publishing native-code changes.

After the first publication, a new consumer can install it with:

```bash
cd /path/to/godot-project
git submodule add -b release-next https://github.com/peterprickarz/hego.git addons/hego
```

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
- **Visual Studio 2022** Community edition or higher
- **Git** for cloning and submodules

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

**Option 1: VS Code (Recommended)**
- Use Ctrl+Shift+P → "Tasks: Run Task" → "build"

**Option 2: Command Line**
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
