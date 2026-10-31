# Prototype scenes and render lab

These dedicated prototype fixtures demonstrate layered terrain data and sculpting, plus a Forward+ renderer with stitched LOD patches and material displacement. They live in `demo/scenes/terrain_prototype/` in the main demo project and use artificial terrain/material inputs. The real island remains the ordinary `demo/scenes/terrain_island.tscn` scene; prototype fixtures are not its production assets. Automated prototype suites run in disposable projects containing only the standalone Strata addon, without HEGo or Houdini.

## Build and run

From the repository root, build the Linux extension with the initialized `godot-cpp` submodule:

```sh
git submodule update --init godot-cpp
scons -f SConstruct.terrain platform=linux target=template_debug -j8
```

Launch the visible demo, selecting the Godot 4.7.2 executable if it is not on `PATH`:

```sh
python3 scripts/run_terrain_prototype.py --godot /home/peter/Godot/Godot_v4.7.2-stable_linux.x86_64
```

Open `demo/project.godot` and choose `res://scenes/terrain_prototype/main.tscn`, or use the optional launcher above. `--editor` opens that scene in the main demo editor. `--test` copies the installed Terrain addon, six suite scripts and prototype scenes into a disposable `/tmp/hego-terrain-tests-*` project, then imports and runs the four headless data, mesher, material-reference and frontend suites. `--test-renderer` uses the same isolation for its graphical suites. `--prepare-only` validates the installed addon directory without staging or starting Godot. Set `GODOT_BIN` to choose the executable without repeating `--godot`.

The extension manifest lists the available platform/target library paths; install or build the corresponding native library before opening that configuration.

## Forward+ render lab

The prototype launcher opens the sculpt fixture by default. Use `--render-lab` to open `res://scenes/terrain_prototype/render_lab.tscn`, a separate Forward+ scene with a deterministic 256 m synthetic heightfield, 32 generated 128 px material sets, LOD controls and optional height displacement. The fixture textures are generated test inputs, not finished art assets.

```sh
python3 scripts/run_terrain_prototype.py --godot /path/to/godot-4.7.2 --render-lab
python3 scripts/run_terrain_prototype.py --godot /path/to/godot-4.7.2 --render-lab --capture /tmp/hego-renderlab.png --quit-after-frames 120
```

Right drag orbits, the wheel zooms, WASD moves the camera target, and **F** toggles the fixed camera path. The panel toggles displacement, LOD colors and wireframe and reports patch/triangle counts, renderer CPU update times, and viewport CPU/GPU render times. GPU timing is reported as unavailable when Godot returns no GPU measurement.

Run a finite benchmark with at least 60 warmup frames and 300 measured frames, writing JSON to an explicit path:

```sh
python3 scripts/run_terrain_prototype.py --godot /path/to/godot-4.7.2 --benchmark --frames 3000 --report /tmp/hego-renderlab-displacement.json
python3 scripts/run_terrain_prototype.py --godot /path/to/godot-4.7.2 --benchmark --frames 3000 --report /tmp/hego-renderlab-flat.json --no-displacement
```

Each run follows the same frame-indexed near-ground camera path, forces Forward+, disables VSync and requests a 1920×1080 window. The JSON stores engine, actual viewport pixels, fixture details, script, renderer-process and viewport render CPU/GPU timing distributions (mean, median, p95 and maximum), and renderer stats. GPU timing is marked unavailable if the engine returns zero. There is no performance threshold or speed claim; compare paired reports only with matching hardware, drivers, engine version, settings and display conditions. `--test-renderer` separately runs the graphical shader/material integration and renderer lifecycle checks under Forward+ and requires a working GPU display. To save its integration frame, use:

```sh
python3 scripts/run_terrain_prototype.py --godot /path/to/godot-4.7.2 --test-renderer --capture /tmp/hego-renderlab-materials.png
```


### Exploratory paired measurement

These historical measurements displaced vertices on the ordinary terrain LOD mesh. They did not include the additional near-camera subdivision required for material relief, so they are not performance acceptance for that full feature.

One pair was measured on Godot 4.4.1 official, Forward+/Vulkan 1.4.354, AMD Radeon RX 9070 XT (RADV GFX1201), Ryzen 7 5800X3D and approximately 64 GB RAM. Each run used the same frame-indexed camera path, 1920×1080 viewport, disabled VSync, 60 warmup frames and 3000 measured frames. The **off** run was first; the **on** run followed. The generated maps validated all 32 material IDs, four distinct positive weights at every 257×257 texel, and maximum weight-sum error `1.2e-7`. At the final frame each run had 193 patches and 393,984 triangles.

| Mode | Renderer process CPU median / p95 (ms) | Viewport CPU median / p95 (ms) | Viewport GPU median / p95 (ms) |
| --- | ---: | ---: | ---: |
| Displacement off | 0.003 / 1.863 | 0.123 / 0.410 | 1.181 / 1.612 |
| Displacement on | 0.003 / 1.795 | 0.122 / 0.400 | 1.188 / 1.593 |

The renderer-process p95 is above the 1 ms planning target, so CPU work still needs tuning. These two single runs show no meaningful GPU difference between displacement settings and do not establish an incremental displacement cost. Treat the values as one machine-specific fixture measurement, not a performance claim. The [full paired results](../benchmarks/terrain-2026-10-28.json) are saved with this prototype.

## Editor fixture

Run `res://scenes/terrain_prototype/main.tscn` in the main demo project and use its **Save layers** control to write an editor fixture at `demo/generated/editor_example.tscn`. The runtime also accepts `--prepare-editor-example` to generate that fixture and exit. Open it with:

```sh
/home/peter/Godot/Godot_v4.7.2-stable_linux.x86_64 --editor --path demo res://generated/editor_example.tscn
```

The fixture contains the finite terrain and its three selectable layers. Its `.res` data and full-tile snapshots are experimental prototype formats, not production storage or a production undo format.

## Trying the preservation workflow

1. Select the fine Replace layer and paint with the left mouse button. Use the right mouse button to orbit and the wheel to zoom.
2. Enable **Show overrides** to see its authored footprint, including samples whose height matches the lower terrain. The orange display interpolates native binary ownership; it is not brush opacity.
3. Select **Regenerate synthetic base**. Owned Replace heights stay fixed while the surrounding terrain changes.
4. Use **Erase** to release ownership and reveal the new base. Undo restores both values and ownership.
5. Try the coarse Add layer: its deltas stay fixed after regeneration, so its final heights follow changes below it.
6. Save and reload the layers, or open the generated scene and select a layer in Godot's scene tree to use the editor toolbar.

The viewport displays the cumulative surface through the selected layer. Named scalar channels can be painted and saved; the geometric preview always uses `height`, while the override overlay uses the selected channel.

## Verification

```sh
python3 scripts/run_terrain_prototype.py --godot /path/to/godot-4.7.2 --test
```

This creates and imports the disposable test project, then runs the native data, native mesher, material-composition reference, and prototype interaction suites. Negative tests deliberately print rejection diagnostics for unsupported versions, invalid ownership and changing a populated grid. A successful run ends with all four suites passing and exit code zero. The native mesher suite reported 394,222 invariant checks, including 18,312 bit-identical shared UV vertices. The separate `--test-renderer` graphical shader/material and renderer-lifecycle suites passed on Forward+ with a real GPU, including the CPU/GPU blend reference and readback checks.

Verified on Godot 4.4.1: sparse negative tile boundaries, decimal and mixed grids, soft and same-value ownership, Replace/Add regeneration semantics, erase, isolated snapshots, monotonic undo revisions, resource save/load, scene-instance independence, viewport picking and the ownership overlay. The graphical smoke test also captures an optional frame:

```sh
godot --path demo --script res://tests/frontend_smoke_test.gd -- --capture=/tmp/hego-terrain.png
```

Initial Compatibility sculpt verification used a Ryzen 7 5800X3D, approximately 64 GB system memory, and Radeon RX 9070 XT with Mesa 26.2.5. The separate Forward+ fixture measurements above use the same machine. They are not the planned 4 km performance benchmark and do not support production performance claims.

## Renderer constraints and open work

The direct material backend binds 32 sets of Color, Normal and ORMH textures plus three terrain maps (99 texture bindings), so it requires a per-stage texture/sampler limit of 256 to leave room for engine bindings. Compiled height fields are limited to 4097 samples per axis (2049 on the GDScript fallback without the native compiler) and control maps to 1025. Terrain-local coordinates must retain float32 vertex precision at the selected resolution; translation and yaw belong on the parent terrain node. The geometry selector is a bounded distance quadtree without geomorphing or a measured pixel-error guarantee, and there is no streaming or paging.

Four material slots per control texel can still produce sixteen candidate IDs in a bilinear neighborhood. Before sampling source materials, the shared vertex/fragment control kernel subtracts the fifth aggregate weight from the leading four and renormalizes them. Ordinary fourth/fifth exchanges fade to zero instead of switching a nonzero contribution. One-to-four input ratios and empty assignments are preserved; equal leading palettes retain a deterministic hard fallback and can still be discontinuous. The raw dropped-mass diagnostic excludes the additional threshold subtraction. See [material blending](terrain_material_blending.md#soft-material-cap-across-control-texels) for the exact rule and focused synthetic GPU verification.

The Compatibility sculpt demo demonstrates sparse per-layer sample ownership, independent channel composition, Replace and Add sculpting, base regeneration, erase-to-reveal, and a finite mesh preview; its preview mesh is intentionally small. The render lab adds native patch LOD and synthetic multi-material shading. Production scenes instead enable `StrataTerrain3D.textured_editor_preview`, as the [island](../strata/example_island.md) does.

Implemented brushes are raise/lower, flatten, smooth and erase. Ramp/stamp tools, advanced stroke controls and channel-type-specific filtering remain planned. The native resource uses a versioned serialized payload; a rejected payload produces diagnostics, but Godot can still instantiate an empty resource, so migration and error presentation need further work.
