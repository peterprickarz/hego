# Island material distribution

The island uses four ambientCG materials with stable IDs in [`material_registry.json`](../../demo/island/materials/material_registry.json): 0 coastal sand, 1 island grass, 2 scree gravel, 3 dark cliff. Each is a `StrataMaterial` resource in `demo/island/materials/resources/` over 1K textures. The renderer and the native packer hold 32 slots, so the registry can grow to 32 entries without code changes; every count in the code comes from the registry file.

Material placement is authored in Houdini. `CoarseErosion` and `DetailErosion` publish their nine height/simulation/biome channels plus one `material_<name>` weight field per registry material, derived from each pass's flow, sediment, rested debris and protected height change. The first stage assigns materials where none exist; later stages inherit the previous mixture and update it with their own evidence. `MaterialDistribution` is the final mask-only pass after the tint stage: with **Prior Stage Materials** at **Keep Stage Materials (fill gaps)** it keeps valid stage weights exactly and fills uncovered samples from the habitat model; **Regenerate From Final Height** replaces everything.

The habitat model (`scripts/houdini/material_habitat.py`) classifies the terrain into sea, shore, cliff, talus, channel, forest, alpine, grass and snow zones, then spreads each zone over the four materials: sand on sheltered low shores and seabed shallows, grass on gentle vegetated ground, gravel on exposed shores, scree, stream beds and seabed slopes, and cliff rock on steep ground and the high massif (there is no snow material, so the summit reads as bare rock and scree). All weights pass the shared soft limiter, which publishes at most four positive weights per sample; with four materials nothing is ever discarded.

Godot does not pack the island's materials. The editor preview and `StrataBake` compose the material IDs and weights of every region straight from the stack's `editor_material_channels` fields (`StrataRegions.compose_region`, at the terrain's `region_spacing`, 1 m), so a manual layer above the procedural pass wins at the texels it owns and nothing is cached in terrain control maps. `HEGoIslandMaterials.validate(layer)` checks a committed result: every registry field, one common lattice, binary ownership on every sample, and, inside a terrain, a lattice at the terrain's `region_spacing` that covers the bounds (4097 x 4097 for the island); a result on any other lattice (for example the old 4 m cook) is rejected and the layer is marked stale. `HEGoIslandMaterials.pack(layer)` (validation plus the native strongest-four pack, `StrataLayerData.pack_material_weights`, which has no side cap any more) remains only for small fixtures and diagnostics. The island's former material binding (`island_material_binding.gd`) and the `material_ids.res` / `material_weights.res` files are retired: `StrataTerrain3D.editor_control_ids`/`editor_control_weights` are deprecated properties kept only so old scenes load, and `StrataStorage.save_all()` no longer writes control maps (`save_control_maps`/`load_control_maps` are deprecated; delete any leftover `demo/island/terrain/material_ids.res` and `material_weights.res`, which are gitignored).

The HDA itself is not tied to a spacing: it accepts any dense orthogonal lattice from 3x3 up to 4097 samples per axis (`MAX_SAMPLES` in `scripts/houdini/build_material_distribution_hda.py`, the same limit as the erosion and tint HDAs) and writes every `material_<name>` field on exactly that lattice, with no resampling. `MaterialCook` reads the final stack at `terrain.region_spacing` (1 m, 4097^2 over 4 km): `HEGoIslandMaterials.attach()` creates that row, the showcase sets it on every open and cook, and **Configure Stage Material Inputs** upgrades a saved 4 m row. The stage priors keep their bounded grids (coarse 8 m, detail 4 m) and the tint stage stays at 4 m (macro scale 4). Measured on a synthetic island: about 2 s at 1025^2 and about 75 s at 4097^2, with about 12 GB peak memory in hython at 4097^2.

## Cooking

In the editor, cook `HDA/CoarseCook`, `HDA/DetailCook`, then `HDA/MaterialCook` with the HEGo panel and save the scene. Headless:

```sh
python3 scripts/run_terrain_island.py --cook-materials
```

cooks only the material distribution against the saved layers at 1 m, then rebakes and saves the regions (see the recook steps below). A lattice above 4097 samples per axis is cooked in tiles (see Tiled cook below).

## Recooking the island at 1 m

The island data on disk may still be the earlier 4 m material cook (1025^2 fields). The scene and its bake still open (the regions are composed from whatever lattice the fields have), but `validate()` rejects the old fields after a new cook, and the 4 m fields give blocky material edges. To recook:

```sh
python3 scripts/run_terrain_island.py --prepare          # rough base, coarse, detail, tint, materials, bake, save
python3 scripts/run_terrain_island.py --cook-materials   # materials only, against the saved layers, then bake and save
```

`--prepare` recooks every procedural stage from the saved hand layers, validates the 1 m material result, bakes the regions (`StrataBake` at `terrain.region_spacing`, cell masks from the stack, material IDs and weights from `editor_material_channels`, macro tint, mips) and calls `StrataStorage.save_all()`: the stage channel files, the hand layers as loaded, `runtime_data.res` and `regions/`. Expect roughly 15 s for the coarse stage, 172 s for the detail stage, 75 s for the materials at 4097^2 and about 15 s for the bake (the total with the tint stage and the Houdini session start is a few minutes). The material HDA peaks near 12 GB of memory in hython at 4097^2; close other large applications first, and do not run it while a second large Godot or Houdini process is open on the same machine.

Manual layers survive a recook. Hand layers (`RoughBase` aside, which is reloaded from its cache) are never cooked: the showcase fingerprints every non-procedural layer, including the topmost hand-painted `StrataLayer`, before the cooks and refuses to save if any of them changed, and `save_all()` rewrites each hand layer's file from the data loaded from that same file. Because a hand layer's `.res` file is only written from memory, keep the editor from holding unsaved edits to the same layers while the headless recook runs (save the scene first, then close or reload it afterwards), otherwise the editor's later save would overwrite the recook's `runtime_data.res` and `regions/` with its own stale copies. Manual material layers above the procedural pass are composed on top of the new fields by the bake.

Each host publishes into the layer its HDA's `target_layer_path` parameter names, and every channel the HDA emits is published; the Godot side keeps no channel list. Scenes whose stages still read height only are upgraded with the **Configure Stage Material Inputs** button on the scene root (`HEGoIslandStageMaterials.migrate()`). It rewrites only the input rows of `CoarseCook`, `DetailCook` and `MaterialCook` so each stage reads height, the simulation fields and the material weights on bounded grids. It recognizes only the shipped rows and checks every host before changing any, so custom rows stay as they are. It never touches parameters, `target_layer_path` or cached fields, and it neither cooks nor saves: cook the three hosts in that order afterwards and save the scene.

## Tiled cook (lattices above 4097 samples)

The HDA takes one lattice of at most 4097 samples per axis, so the island at 0.5 m (8193 x 8193) is cooked in tiles by `HEGoIslandMaterials.cook()`; a lattice of at most `tile_samples` per axis (the island at 1 m) is still the single cook of `cook_explicit()`, unchanged. The HDA, its contract and its parameters are the same in both paths.

1. `tile_grid()` splits the lattice into the fewest tiles of at most `tile_samples` (default 4097) that share at least `tile_overlap` samples (default 32). The tiles are balanced to one size, not packed at 4097: 8193 samples with an overlap of 32 do not fit two 4097-sample tiles (they need 4113), so the island at 0.5 m is 3 x 3 tiles of 2753 samples, about 5 GB each in Houdini instead of 9 tiles of 12 GB. Each tile owns the samples between the middle of its overlaps.
2. For each tile the input row gets `terrain_bounds` (a `Rect2`, new in `HEGoStrataInput`: the snapshot lattice covers it instead of the terrain bounds, on the same global lattice, so tile samples sit on full-lattice samples). The host cooks as usual, but a `TileCapture` cook extension skips the Strata output handler and keeps the routed volumes. The input row is restored after every tile, so the host signature the layer records is the ordinary one.
3. `TileAssembler` writes each tile's owned window into one `StrataFieldData` per channel with `StrataLayerData.patch_dense`, in row bands of at most 20 Mi samples. No Image of the whole lattice exists (an 8193^2 RF image is 67 M samples, over the 20 Mi limit of one field). Storage is 8-bit (`unorm8`, the default; the native fields round to the nearest 1/255) or `float`. A tile that is not on the lattice, or a channel with unwritten samples, is refused.
4. After the last tile one transaction publishes all four channels (`StrataProcedural.begin_transaction` and `commit_fields` back to back, with the first tile's input snapshot as the read set and a guard on the host signature). `commit_fields` accepts a finished `StrataFieldData` as a result field's `field_data` (`StrataProcedural.validate_prebuilt`); until then the layer keeps its previous result, and a failed tile, a changed input stack or a changed host rejects the whole cook and marks the layer stale.

`HEGoIslandMaterials.validate()` and `layer_content_hash()` read fields in row bands, so a result above 20 Mi samples validates (its images are not returned, and `pack()` refuses it).

Options (`cook(owner, host, target, contract, options)`, and for the headless script `scripts/run_terrain_island.py --cook-materials`): `--tile-samples N` (default 4097, smaller only for tests), `--tile-overlap N|exact` (default 32), `--material-storage unorm8|float` (tiled results only), `--material-spacing M` and `--storage DIR`. **`--material-spacing` and `--storage` are scratch-experiment tools:** `--material-spacing` changes the terrain's `region_spacing` and the MaterialCook input row in memory only (the scene and the shipped island stay at 1 m), and `--storage DIR` redirects every save to a scratch copy of `demo/island/terrain` (the script refuses the shipped directory and reaches the copy through a symlink in the ignored `demo/.godot/scratch`). At 0.5 m only the material fields are cooked and saved; the rest of the pipeline (the whole-terrain height image of 67 M samples, the one-piece cell masks) is not yet at that size.

### Locality: when a tile equals the whole cook

The material model has no global statistic and no per-sample randomness: nothing is normalised over the lattice, the wave fields are functions of the world position, and every other signal is a window operation (central differences, three-pass box Gaussians, an exact 8-neighbour coast distance that the habitat rules clamp at a few shore widths). A weight therefore depends only on terrain within a finite radius, and a tile reproduces the whole cook at least that far inside its edge. The radius is large: the 150 m shelter Gaussian reaches three box radii, 450 m (900 samples at 0.5 m), further than the coast distance (3 x shore width, 180 m at the default). `HEGoIslandMaterials.exact_overlap(spacing)` is twice the radius plus the gradient stencil: 1804 samples at 0.5 m, 904 at 1 m, 226 at 4 m.

`scripts/houdini/test_material_tiling.py` (hython, in `run_tests.sh`) cooks ARTIFICIAL synthetic terrain (the test island of `test_material_distribution.py`, no prior stage materials) whole and as tiles and compares every owned weight with the whole cook:

| Lattice | Tiles | Overlap | Max abs difference | Bit-identical float32 |
| --- | --- | --- | --- | --- |
| 1025^2 at 16 m (radius 29 samples) | 2 x 2 of 545 | 64 | 0 | 100 % |
| 1025^2 at 4 m | 2 x 2 of 545 | 32 | 7.8e-2 | 98.6 % |
| 1025^2 at 4 m | 2 x 2 of 545 | 64 | 5.2e-2 | 98.9 % |
| 1025^2 at 4 m | 3 x 3 | 128 | 7.8e-3 | 99.3 % |
| 1025^2 at 4 m | 3 x 3 | 226 (exact) | 1.5e-8 | 100 % |

So a tile equals the whole cook exactly (float32 rounding at most, from the prefix sums of the box filter) when the overlap is at least twice the dependency radius, and below that differs only near its cut, on about 1 % of the samples; there is nothing global to fix, so the HDA is unchanged. The default overlap of 32 is a speed choice, not a proof: it is exact only where the weights do not depend on the habitat model. On the shipped island they do not: `MaterialDistribution` keeps the stage materials of `DetailErosion` and runs the habitat model only on uncovered samples. Cooking the shipped island at 1 m in four 2100-sample tiles with an overlap of 32 and comparing with the shipped single cook gave a maximum difference of 0.0020 on all four channels, which is exactly the 8-bit rounding (0.5/255), and no sample differing by more than that.

### The island at 0.5 m (SCRATCH measurement, 2026-10-31)

Nothing here ships: the island stays at 1 m (`region_spacing` 1, single cook) until the sizes and times below are reviewed. Measured on a scratch copy of `demo/island/terrain` (`--storage build/island-05/terrain --material-spacing 0.5`), the saved coarse, detail and tint stages as input, default options except the storage:

| | 8-bit (`unorm8`, default) | `float` |
| --- | --- | --- |
| Lattice | 8193 x 8193, 67.1 M samples per channel, 4 channels | same |
| Tiles | 3 x 3 of 2753^2 with an overlap of 32 (a 4097-sample HDA limit cannot make 2 x 2) | same |
| Wall time (script start to saved) | 5 min 07 s: 9 tiles at 30 to 40 s each, then assembly, commit and save | 5 min 10 s |
| Houdini (HARS) peak memory | about 7.5 GB per 2753^2 tile (observed by sampling every 2 s) | 7.6 GB |
| Godot peak memory (`/usr/bin/time -v`) | 3.1 GB | 3.9 GB |
| Fields in memory, 4 channels | 545 MB | 1361 MB |
| Fields on disk, 4 files | 33 MB | 312 MB |
| `validate()` | passes (lattice and every sample owned, read in row bands) | passes |

The 8-bit and float results differ by at most 0.0020 (half an 8-bit step) on every channel. For comparison the 1 m island's four float fields are 79 MB on disk. A 1024-region bake of the 0.5 m result (`StrataBake.bake` with `spacing` 0.5, 256-cell regions of 128 m, `cell_masks` true, to a directory, from a scratch script because the cook script has no whole-terrain height image at 67 M samples) took 17 s, 28 s with loading, peaked at 1.6 GB, and wrote 2048 files (full and lod files per region) of 398 MB; the manifest's region payload is 1.33 GB uncompressed (1.3 MB per region).

Tiles at 4097^2 instead of 2753^2 would be 12 GB each in hython. If the HDA's `MAX_SAMPLES` were raised to 4113 (a contract change), 8193 samples would be 2 x 2 tiles of 4113 at about 75 s and 13 GB each.

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

Godot tests without Houdini: `demo/tests/material_distribution_test.gd` (registry validation, the fixture packer, lattice validation, attachment of the producer, stack composition with a manual layer above), `stage_material_persistence_test.gd` (fixed-path saving of stage fields in a disposable storage directory, no control maps), `stage_material_transport_test.gd` (channel transport through hand layers and mixed grids), `material_preview_cutoff_test.gd` (stage previews). With a Forward+ device, `island_materials_gpu.gd` records texture residency and views of the saved scene.

`demo/tests/material_tiling_test.gd` (headless, no Houdini) checks the tile grid, the byte-exact assembly of synthetic tile results (float) and the 1/255 round trip (8-bit), the one-transaction publication of prebuilt fields, validation above 20 Mi samples and the tile bounds of the input snapshot; `scripts/houdini/test_material_tiling.py` is the locality proof above. Both are in `scripts/run_tests.sh`.
