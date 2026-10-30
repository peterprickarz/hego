# Island material distribution

The island uses four ambientCG materials with stable IDs in [`material_registry.json`](../../demo/island/materials/material_registry.json): 0 coastal sand, 1 island grass, 2 scree gravel, 3 dark cliff. Each is a `StrataMaterial` resource in `demo/island/materials/resources/` over 1K textures. The renderer and the native packer hold 32 slots, so the registry can grow to 32 entries without code changes; every count in the code comes from the registry file.

Material placement is authored in Houdini. `CoarseErosion` and `DetailErosion` publish their nine height/simulation/biome channels plus one `material_<name>` weight field per registry material, derived from each pass's flow, sediment, rested debris and protected height change. The first stage assigns materials where none exist; later stages inherit the previous mixture and update it with their own evidence. `MaterialDistribution` is the final mask-only pass after the tint stage: with **Prior Stage Materials** at **Keep Stage Materials (fill gaps)** it keeps valid stage weights exactly and fills uncovered samples from the habitat model; **Regenerate From Final Height** replaces everything.

The habitat model (`scripts/houdini/material_habitat.py`) classifies the terrain into sea, shore, cliff, talus, channel, forest, alpine, grass and snow zones, then spreads each zone over the four materials: sand on sheltered low shores and seabed shallows, grass on gentle vegetated ground, gravel on exposed shores, scree, stream beds and seabed slopes, and cliff rock on steep ground and the high massif (there is no snow material, so the summit reads as bare rock and scree). All weights pass the shared soft limiter, which publishes at most four positive weights per sample; with four materials nothing is ever discarded.

Godot only packs. `StrataLayerData.pack_material_weights(images)` takes the registry's fields on one lattice up to 1025 samples per side and writes an RGBA8 ID image and an RGBAF weight image, choosing the four largest weights per texel with ascending-ID tie breaks. Negative, nonfinite, mismatched or zero-total inputs fail the pack and the previous controls stay in place. The island's material binding (`demo/island/island_material_binding.gd`) runs that pack whenever the `MaterialDistribution` layer commits a new cook, sets the terrain's `editor_control_ids`/`editor_control_weights`, and writes them to `res://island/terrain/material_ids.res` and `material_weights.res`. Those two files and the bake are not committed; the showcase repacks them from the committed material fields when they are missing.

## Cooking

In the editor, cook `HDA/CoarseCook`, `HDA/DetailCook`, then `HDA/MaterialCook` with the HEGo panel and save the scene. Headless:

```sh
python3 scripts/run_terrain_island.py --cook-materials
```

cooks only the material distribution against the saved layers and writes `island/terrain/material_distribution/material_<name>.res` plus the control maps and bake.

Each host publishes into the layer its HDA's `target_layer_path` parameter names, and every channel the HDA emits is published; the Godot side keeps no channel list. Scenes whose stages still read height only are upgraded with the **Configure Stage Material Inputs** button on the scene root (`HEGoIslandStageMaterials.migrate()`). It rewrites only the input rows of `CoarseCook`, `DetailCook` and `MaterialCook` so each stage reads height, the simulation fields and the material weights on bounded grids. It recognizes only the shipped rows and checks every host before changing any, so custom rows stay as they are. It never touches parameters, `target_layer_path` or cached fields, and it neither cooks nor saves: cook the three hosts in that order afterwards and save the scene.

## Reusable Houdini material weight limiter

`Sop/util_MaterialWeightLimit` (`otls/util_MaterialWeightLimit.hda`) limits any set of material weight volumes to four positive contributions per voxel. For each voxel, with `t` the fifth-largest weight, it keeps `q_i = max(w_i - t, 0)` and normalizes, so a changing fourth contribution fades out continuously; ties with five or more equal maxima fall back to the first four in channel order and are counted in `hego_material_limit_tie_fallback_voxels`. Only the selected volumes change. The shared source is `scripts/houdini/material_weight_limit.py`, embedded by both HDAs so cooks need no project imports.

## Generators and tests

```sh
hython scripts/houdini/build_material_weight_limit_hda.py
hython scripts/houdini/build_material_distribution_hda.py
hython scripts/houdini/build_island_hda.py --skip-base
HOUDINI_PATH="$PWD:&" hython scripts/houdini/test_hda_package_graphs.py
hython scripts/houdini/test_material_distribution.py --out-dir /tmp/hego-materials/test
hython scripts/houdini/test_island_stage_materials.py --out-dir /tmp/hego-materials/stages
hython scripts/houdini/test_material_inheritance.py --erosion-hda otls/HEGo_IslandErosion.hda --material-hda otls/HEGo_MaterialDistribution.hda
hython scripts/houdini/test_material_weight_limit.py --hda otls/util_MaterialWeightLimit.hda
```

`build_material_distribution_hda.py` refuses a registry whose entries are not `id == material_id == index` with `channel == material_<name>`, or that disagrees with `material_contract.json`'s registry sha256 and channel list, or that names a material the habitat rules never produce. `test_material_distribution.py` checks the contract, the interface, a synthetic island's placement (sea floor without grass, rock on slopes over 50°, bare summit, sandy low coast, grassy lowland), determinism, optional erosion masks, prior-stage inheritance, orientation and spacing invariance, parameter response and error handling; `--actual PATH.rf32` additionally cooks an exported saved-scene height.

Godot tests without Houdini: `demo/tests/material_distribution_test.gd` (registry validation, packing, diagnostics, attachment of the producer), `stage_material_persistence_test.gd` (fixed-path saving and control-map rollback in a disposable storage directory), `stage_material_transport_test.gd` (channel transport through hand layers and mixed grids), `material_preview_cutoff_test.gd` (stage previews). With a Forward+ device, `island_materials_gpu.gd` records texture residency and views of the saved scene.
