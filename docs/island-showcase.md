# Bracken Isle showcase

A 4096 × 4096 m island built as a Strata layer stack: an 8 m rough base, coarse Houdini erosion, a 2 m hand-sculpted Add layer, detailed Houdini erosion (height 2 m, masks 4 m), a 0.25 m building-platform Replace layer, a mask-only terrain tint/AO stage and a mask-only material distribution. The render and collision field is compiled at 1 m (4097 × 4097 samples). Four ambientCG materials cover it: coastal sand, island grass, scree gravel and dark cliff.

The scene is `demo/scenes/terrain_island.tscn`. Open `demo/project.godot` and edit or play it like any other scene; nothing cooks on open, and no launcher or staging is needed.

## Where the data lives

The terrain's `storage_directory` is `res://island/terrain`. Every layer and every cooked result has one fixed file there, and a cook overwrites its files in place (see [StrataStorage](terrain-runtime.md#storage)):

| Path | Holds | In git |
| --- | --- | --- |
| `island/terrain/rough_base.res`, `manual_fine.res`, `building_flatten.res` | hand layers (`StrataLayerData`) | yes |
| `island/terrain/coarse_erosion/<channel>.res`, `detail_erosion/<channel>.res` | the nine erosion channels of each stage (`StrataFieldData`) | yes |
| `island/terrain/terrain_tint/<channel>.res` | the four tint/AO channels | yes |
| `island/terrain/material_distribution/material_<name>.res` | the four material weight fields | yes |
| `island/terrain/material_ids.res`, `material_weights.res` | packed material control maps | no, repacked on open |
| `island/terrain/runtime_data.res` | the bake (heights, masks, controls, macro) | no, rebaked when stale |
| `island/cache/base_height.rf32` + `.json` | the rough base the first cook starts from | yes |

A fresh clone opens the island without Houdini: the layers and cooked channels are committed, and the showcase rebakes what is missing. There are no dated generation folders, manifests or packed scene copies.

## Materials

`demo/island/materials/material_registry.json` lists the four materials with stable IDs 0–3; `demo/island/assets/ambientcg_sources.json` records their ambientCG sources. The 1K textures and their `.tres` tuning are committed (about 20 MB). To refetch or repack them:

```sh
python3 scripts/prepare_island_materials.py --output-dir demo/island/materials
```

Existing `.tres` tuning is preserved unless `--reset-resources` is given. The renderer and native packer hold 32 material slots; the registry may use any number up to that, and everything reads the count from the registry.

## Cooking

The island HDAs live in the repository's `otls/` folder with the other HEGo assets
(`HEGo_IslandErosion`, `HEGo_TerrainTint`, `HEGo_MaterialDistribution`, and the
`util_MaterialWeightLimit` helper they embed). Houdini has to find that folder at startup,
which a user-level package does once per checkout, e.g. `~/houdini22.0/packages/hego.json`:

```json
{"env": [{"HEGO": "/path/to/hego"}, {"HOUDINI_PATH": {"value": "$HEGO", "method": "prepend"}}]}
```

After that every cook is an explicit action:

In the editor, select an `HDA/*Cook` node and press **Cook** in the HEGo panel: `CoarseCook` and `DetailCook` run `HEGo_IslandErosion.hda`, `TintCook` runs `HEGo_TerrainTint.hda`, `MaterialCook` runs `HEGo_MaterialDistribution.hda`. Each writes its layer's channel files and marks the scene unsaved; save the scene to keep the updated references. The material binding on the scene root repacks the control maps whenever the material distribution commits.

Headless, from the repository root:

```sh
python3 scripts/run_terrain_island.py --prepare         # rough base -> coarse -> hand edits -> detail -> tint -> materials, then save
python3 scripts/run_terrain_island.py --cook-materials  # only the material distribution, against the saved layers
python3 scripts/run_terrain_island.py --verify          # reopen the saved island headlessly without Houdini
python3 scripts/run_terrain_island.py --editor          # open the scene in the editor
```

`--prepare` also recooks the coarse stage with changed parameters and checks that both hand layers survive byte for byte and that the detail stage goes stale. It takes several minutes with Houdini 22.0. `--godot PATH` overrides the Godot executable; the launcher never rebuilds native code.

The HDAs are generated from `scripts/houdini/build_*.py` and embed their contracts (`demo/island/hda/*.json`). After changing a builder or the registry, regenerate with `hython` and rerun the Houdini tests listed in [island-material-distribution.md](island-material-distribution.md).

## Showcase scene

`res://island/island_showcase.tscn` is the diagnostic play scene: a fly camera, a side panel with the stage selector, ownership overlay, sculpting, the four cook buttons, **Save layers to storage**, and a collision-driven walk around the building platform. Right-drag looks, WASD flies, Q/E move vertically, Shift is fast, the wheel changes speed, Tab leaves the player. Procedural layers are read-only; sculpting works on the selected hand layer, and undo/redo restores values and ownership together.

Captures and the benchmark use it:

```sh
"$GODOT_BIN" --path demo res://island/island_showcase.tscn -- --capture=/tmp/island-overview.png --quit-after-frames=90
"$GODOT_BIN" --path demo res://island/island_showcase.tscn -- --capture-view=platform --show-ownership --capture=/tmp/island-ownership.png --quit-after-frames=90
python3 scripts/benchmark_terrain_island.py --godot "$GODOT_BIN" --report /tmp/island-benchmark.json --capture-dir /tmp/island-captures
```

Collision follows the character in 128-cell chunks and navigation bakes only the platform area; both consume the compiled `hole` and `nav_exclusion` cell masks. The demo's navigation map uses merge rasterizer scale 0.01, a project setting.

## Editing in the Godot editor

The editor viewport runs the Forward+ material renderer against a native-compiled 1 m heightfield, with the editor camera driving patch LOD. **Terrain → Render Settings** chooses the geometry density; **Near Displacement Geometry** adds local subdivisions for material relief (see the table below). Select a hand layer to show the brush toolbar; Alt + mouse stays Godot navigation. **Show overrides** displays the layer's ownership; **Show channel** displays scalar values.

Brushes accept radii up to 4096 m with a 65,536-sample budget per dab on the selected layer's grid. A dab is one region edit, so the layer emits one change, and undo keeps only the touched rectangles.

| Near displacement setting | Default | Meaning |
| --- | --- | --- |
| Displacement Refinement Enabled | On | Add local geometry while visual displacement is enabled. |
| Displacement Vertex Spacing | 0.0625 m | Desired local vertex spacing, snapped to the dyadic root lattice. |
| Displacement Refinement Radius | 32 m | Geometry and shader displacement fade radius. Zero disables the zone. |
| Displacement Refinement Budget | 1,024 | Extra leaves beyond the base patch budget; total leaves stay at most 4,096. |

Material relief moves each vertex along the smooth terrain normal, so rock bulges outward on cliffs; it is visual only and never enters physics. Render settings are saved in the scene and snapshotted into bakes.

## Tests

No Houdini:

- `demo/tests/island_storage_test.gd`: every layer of the saved scene references its file under `res://island/terrain`, the files match the loaded layers, and the rebuildable files are not referenced by the scene.
- `demo/tests/terrain_demo_scene_test.gd`: the saved scene loads and its hand layers keep their saved content.
- `demo/tests/stage_material_persistence_test.gd`: fixed-path saves in a disposable `user://` storage directory, including a partial-write failure that leaves the previous files intact, and control-map packing with rollback.
- `demo/tests/stage_material_transport_test.gd`, `material_distribution_test.gd`, `island_transition_test.gd`: transport, packing and transition acceptance on small fixtures.

Graphical Forward+: `island_showcase_test.gd` (renderer, collision, navigation and UI undo), `island_materials_gpu.gd` (material residency and views), `terrain_appearance_test.gd`.

With Houdini: `editor_hda_package_test.gd` runs a real coarse cook through the HEGo panel in a private session. Run it in a disposable copy of the demo with `HOUDINI_OTLSCAN_PATH` and `HOUDINI_PACKAGE_DIR` unset.
