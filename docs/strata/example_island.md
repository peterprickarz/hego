# Example: Bracken Isle

Bracken Isle is a 4 km island in the repository's demo project, built with everything on
these pages: hand-painted layers, three Houdini HDAs cooked through `HEGoNode3D` nodes, four
materials, a bake, collision and navigation. It is the demo project's main scene,
`res://scenes/terrain_island.tscn`.

## The layer stack

From the bottom of the stack to the top:

| Layer | Kind | What it is |
| --- | --- | --- |
| `RoughBase` | manual, 8 m | the island's uneroded shape: massif, ridges, coves and sea floor |
| `CoarseErosion` | procedural | `HEGo_IslandErosion`, coarse pass over the whole island |
| `ManualFine` | manual, Add, 2 m | hand sculpting on top of the coarse erosion |
| `DetailErosion` | procedural | `HEGo_IslandErosion`, detail pass over everything below, protecting and blending toward the building pad |
| `BuildingFlatten` | manual, Replace, 0.25 m | a flat platform for the buildings |
| `TerrainTint` | procedural, masks only | `HEGo_TerrainTint`: terrain-wide colour variation and cavity AO |
| `MaterialDistribution` | procedural, masks only | `HEGo_MaterialDistribution`: the final weight of each material |

`MaterialDistribution` is last only in the shipped island. It reads the stack directly below
it, so you can add a manual layer above it and paint the four `material_*` channels by hand
(for example to touch up a path or a beach). The terrain's material controls then compose
your hand weights over the Houdini result, and a recook of `MaterialCook` never reads that
layer back.

The `HEGoNode3D` nodes that cook them sit under `HDA`: `CoarseCook`, `DetailCook`,
`TintCook` and `MaterialCook`. The terrain uses four ambientCG materials: coastal sand,
island grass, scree gravel and dark cliff.

## Open it

The island's layers, cooked channels and textures are stored with
[Git LFS](https://git-lfs.com). Run `git lfs install` once before cloning, or `git lfs pull`
afterwards; otherwise the scene finds pointer files instead of its data.

Open `demo/project.godot` and then the scene. It appears textured and complete without
Houdini: everything it needs is already cooked and saved under `res://island/terrain`, and
nothing cooks when it opens. Edit and play it like any other scene. From the repository root you can also run:

```sh
python3 scripts/run_terrain_island.py            # play the island
python3 scripts/run_terrain_island.py --editor   # open it in the editor
```

For a guided tour, play `res://island/island_showcase.tscn` instead. Its side panel lets you
view the stack up to any stage, show a layer's ownership, sculpt the selected hand layer,
cook each stage, save the layers, and walk the building platform with collision and
navigation. Right-drag looks around, WASD flies, Q and E move up and down, Shift is faster,
the mouse wheel changes speed, and Tab leaves walking mode.

## Recook it

Cooking needs Houdini 22.0 with HEGo set up, and Houdini must find the HDAs in the
repository's `otls/` folder. A user-level Houdini package does that once per checkout, for
example `~/houdini22.0/packages/hego.json`:

```json
{"env": [{"HEGO": "/path/to/hego"}, {"HOUDINI_PATH": {"value": "$HEGO", "method": "prepend"}}]}
```

Then select a host under `HDA` and press **Recook** in the HEGo panel. Each publishes into
the layer its `target_layer_path` parameter names and overwrites that layer's files. To
rebuild the whole island, cook `CoarseCook`, `DetailCook`, `TintCook` and `MaterialCook` in
that order. Save the scene afterwards.

## Things to try

- **Touch up materials.** Add a `StrataLayer` above `MaterialDistribution`, give it the
  `material_island_grass` (or another `material_*`) channel and paint weights. Your strokes
  win where they own a sample; everywhere else the Houdini distribution stays.
- **Paint.** Select `Terrain/ManualFine` and sculpt with the brush. It is an Add layer, so
  your strokes ride on the eroded ground.
- **Watch the dependency.** Every cooked layer opens marked stale, because it was loaded
  from disk; its `procedural_status` says so. Recook `DetailCook`, then paint `ManualFine`
  again: within a moment `DetailErosion` reports that an input changed.
- **Recook.** Cook `DetailCook` once more. The detail erosion now runs over your strokes,
  while `ManualFine` and `BuildingFlatten` keep every sample.
- **Look inside the stack.** Select any layer to see the terrain up to that layer, turn on
  **Show overrides** to see what it owns, or toggle a layer's `enabled` to see what it
  contributes.
