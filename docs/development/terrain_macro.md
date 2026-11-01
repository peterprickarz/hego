# Terrain-wide tint and cavity AO

The terrain macro map adds broad color variation and cavity occlusion without changing authored heights, collision, holes, or material weights. It is an optional, standalone runtime resource: a scene with no macro map keeps neutral tint and AO.

## Packed channels

`StrataMacro` composes four ordinary scalar channels into one linear RGBAH image:

| Channel | Meaning | Neutral | Packed range |
| --- | --- | ---: | ---: |
| `terrain_tint_r` | Red albedo multiplier | 1 | 0–2 |
| `terrain_tint_g` | Green albedo multiplier | 1 | 0–2 |
| `terrain_tint_b` | Blue albedo multiplier | 1 | 0–2 |
| `terrain_ao` | Ambient and indirect occlusion multiplier | 1 | 0–1 |

Each channel composes independently on an implicit full-coverage value of 1. `Replace` interpolates from the value below toward the layer value by sample coverage. `Add` adds a signed offset scaled by coverage. An unowned channel remains exactly 1, so a tint-only layer cannot change AO and a missing channel needs no storage.

RGB is a linear multiplier on material albedo. Alpha multiplies material AO once and affects ambient/indirect lighting; it is not a baked shadow or a second albedo darkening term. The shader exposes `terrain_tint_strength` and `terrain_ao_strength`, each 0–1, to blend its field independently from neutral. Zero strength disables that contribution.

## Grid, bounds, and storage

The default `StrataMacro.DEFAULT_SPACING` is 4 m. The map spans terrain-local XZ bounds, with the first and last texel centers aligned to the bounds edges. Resolution is endpoint-aligned; if the extent is not an exact multiple of the requested spacing, the returned `spacing` is the actual step. Sampling is linear, clamped, and non-repeating. The CPU sampler returns neutral outside the declared bounds; the GPU texture lookup clamps to the edge.

A 4 km square at 4 m spacing is 1025 × 1025 texels. RGBAH uses 8 bytes per texel, or about 8.4 MB. The compose helper limits each side to 4097 texels and reports the actual resolution, spacing, owned channels, clamping, packed byte count, and CPU time. Runtime resources validate the image and its bounds when assigned and when baked. Older runtime resources without a macro image remain valid.

`StrataMacro.compose(terrain, options)` composes enabled macro channels on a bounded endpoint-aligned grid. `options` can set `spacing`, `bounds`, `through_layer`, and `max_side`. The bake option `macro` defaults to `"auto"`: it composes only if an enabled layer owns one of these channels. Set it to `false` to omit the field, `true` to use the default options, a dictionary to choose compose options, or a current compose result to reuse a precompiled image. Exported runtime data carries the image and terrain-local bounds with it; the runtime renderer does not need HEGo or Houdini to load that cache.

## Explicit Houdini tint cook

For the editable level, open `demo/project.godot` and `res://scenes/terrain_island.tscn`, select `HDA/TintCook`, and use the HEGo inspector's **Cook** action. Its input is cumulative `height` through `BuildingFlatten`, sampled at 4 m; its output target is the mask-only procedural `Terrain/TerrainTint` layer. It cooks only `Sop/HEGo_TerrainTint`; it does not recook either erosion stage or modify the source height layers. The saved-cache convenience flow is `python3 scripts/run_terrain_island.py --cook-terrain-tint`; this explicitly migrates the existing saved level to a new cache generation after the same tint-only cook and preservation checks.

The HDA produces the four fields on the input height lattice. It derives broad ridge brightening, low-amplitude world-space color variation, and cavity occlusion. Cavity AO is a height-neighborhood approximation, not ray-traced visibility or horizon occlusion. The HDA does not bake directional sunlight, and it never darkens the tint based on cavity depth; cavity darkening comes from `terrain_ao` alone. Its controls include relief radius/strength, AO radius/strength, variation scale/strength, and deterministic seed. Parameter values are checked before the cook.

The source generator and contract are [build_tint_hda.py](../../scripts/houdini/build_tint_hda.py) and `demo/island/hda/tint_contract.json`. With Houdini 22.0 installed, build or run the standalone HDA regression with:

```sh
HFS=/opt/hfs22.0
"$HFS/bin/hython" scripts/houdini/build_tint_hda.py
"$HFS/bin/hython" scripts/houdini/test_terrain_tint.py
```

The standalone generator regression uses temporary Houdini data and writes nothing into the island. On the island, a tint cook writes the four channels to `demo/island/terrain/terrain_tint/`, and the next bake packs them into a 1025 × 1025 RGBAH map (8,405,000 bytes); the first accepted cook took 2.059 s. The verification preserved all five height/manual stages, their ownership, attrs and lattices, the erosion presets, compiled/runtime heights, holes, navigation masks and material controls. Saved-cache reopen/export and compatibility with the previous generation passed 88 checks. Macro composition took 0.584 s and runtime bake 1.205 s. The accepted field ranges were RGB minimum `(0.9443, 0.9520, 0.9384)`, maximum `(1.1813, 1.1756, 1.1722)`, and AO `0.55–1.0`. The HDA's separate synthetic regression passed 35 checks.

