<div align="center">
  <img src="assets/logo.png" alt="HEGo Logo" width="128">
  
  # HEGo - Houdini Engine in Godot
  
  A C++ GDExtension that integrates Houdini Engine into Godot 4, enabling procedural content generation using Houdini Digital Assets (HDAs) with a scriptable API.
</div>

## 🚀 Getting Started

- 📦 **[Download Latest Release](https://github.com/peterprickarz/hego/releases/latest)** - Pre-built binaries for Windows
- 📖 **[Wiki](https://github.com/peterprickarz/hego/wiki)** - Complete documentation and guides  
- 🎥 **[Introduction Video](https://youtu.be/cviGlmKmFQ8)** - Visual walkthrough

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
- **Multiple Node Types**: Support for geometry input, curve input, and HDA asset nodes
- **Session Management**: Multiple session types (in-process, TCP, named pipes, shared memory)
- **Bidirectional Data Flow**: Convert between Godot and Houdini geometry formats
- **Parameter Management**: Automatic type conversion between Godot Variant and HAPI types
- **Mesh Generation**: Generate Godot meshes, instances, and scene nodes from Houdini

## Requirements

- **Houdini 20.5.654** - No license needed for building, active license required for runtime
- **Godot 4.4+** - Stable or newer versions supported  

## Developer Setup
> If you're interested in contributing read on, otherwise check out the Releases section for the latest version

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
   set HFS=C:\Program Files\Side Effects Software\Houdini 20.5.654
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

## Get Help

If you have any questions or problems, feel free to message me on [X](https://x.com/prickarz) where I will try to help as much as I can.


## Shoutouts

- Big thanks to https://ambientcg.com/ and https://freestylized.com/ for providing CC0 textures I used in the demo project.
- There's also a [houdini2godot](https://github.com/Mandrake0/houdini2godot) plugin made by [Mandrake0](https://github.com/Mandrake0) which allows to export Godot scenes directly from Houdini.