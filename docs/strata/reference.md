# Strata reference

Conventions and settings in one place. The Strata classes themselves (`StrataTerrain3D`,
`StrataLayer`, `StrataBake` and so on) document their members in the inspector and in
Godot's built-in help. The bridge classes are in the class reference:
{ref}`HEGoStrataInput<class_HEGoStrataInput>`,
{ref}`HEGoStrataOutput<class_HEGoStrataOutput>` and
{ref}`HEGoStrataInputSettings<class_HEGoStrataInputSettings>`.

## Channels

Any name is a valid channel; layers store and compose whatever you paint or cook. These
names have a meaning to Strata:

| Channel | Meaning | Notes |
| --- | --- | --- |
| `height` | terrain height in metres | The stack starts from a flat 0. |
| `hole` | 1 cuts the cell out of rendering, collision and navigation; 0 is solid | Mask; Replace only. |
| `nav_exclusion` | 1 removes the cell from navigation only | Mask; Replace only. |
| `footpath` | 0 to 1 trail network, 1 on the centreline, 0 off the trail | Cooked by `HEGo_IslandErosion`; for [navigation profiles](#navigation-profile-rules). |
| `terrain_tint_r`, `terrain_tint_g`, `terrain_tint_b` | linear multiplier on material colour | Neutral 1, range 0 to 2. |
| `terrain_ao` | multiplier on ambient and indirect light | Neutral 1, range 0 to 1. |
| the names in `editor_material_channels` | the weight of the material with the same index in `editor_materials` | Zero or positive. The island calls them `material_<name>`. |

Every other channel starts from 0, except the four tint and AO channels, which start from a
neutral 1 so a layer that paints only one of them leaves the others alone. The bake keeps
the tint and AO channels as one terrain-wide map whenever a layer owns any of them.

**Masks** are categorical. A cell of the bake is masked as soon as any part of it is
covered by a masked region, so holes grow to whole bake cells and a narrow hole never
disappears. A higher layer that paints 0 restores ground over a lower layer's hole. Cooked
mask channels must be exactly 0 or 1, unless you pass
`"cell_masks": {"continuous_channels": PackedStringArray(["hole"])}` to the bake, which
thresholds them at 0.5 (or at your own value in `thresholds`).

## Composition

Each layer composes each channel in one mode, set in its `composition_modes` (missing
channels use Replace):

| Mode | Value | Result where the layer owns samples |
| --- | --- | --- |
| Replace | `StrataLayer.Composition.REPLACE` (0) | the layer's value |
| Add | `StrataLayer.Composition.ADD` (1) | the value below plus the layer's value |

Ownership is per sample. Between owned and unowned samples the layer blends in smoothly by
its interpolated coverage; unowned values never leak in. An owned sample counts even when
its value equals what is below it, so painting the same height still pins it.

A cook sets the composition of each channel it publishes from `hegostrata_composition`.

## Layer and terrain state

| Property | On | Meaning |
| --- | --- | --- |
| `procedural` | `StrataLayer` | the layer holds cooked results rather than painted samples |
| `procedural_stale` | `StrataLayer` | the cooked result is out of date and needs a recook |
| `procedural_status` | `StrataLayer` | what happened last, or why the layer is stale |
| `producer_id`, `producer_path` | `StrataLayer` | the `HEGoNode3D` that published the result |
| `enabled` | `StrataLayer` | whether the layer takes part in the stack |
| `runtime_data` | `StrataTerrain3D` | the published bake |
| `runtime_bake_stale` | `StrataTerrain3D` | the stack changed since the bake; also `is_runtime_bake_stale()` and the `runtime_bake_stale_changed(stale)` signal |
| **Bake runtime data** | `StrataTerrain3D` | inspector button, Runtime group: `bake_runtime()`, a `StrataBake.bake` with cell masks that accepts saved cooks and publishes the result |
| **Add collision** / **Add navigation** / **Add runtime renderer** | `StrataTerrain3D` | inspector buttons, Runtime group: `add_collision()`, `add_navigation()`, `add_runtime_renderer()` add child nodes that follow the terrain's bake |
| `follow_terrain` | `StrataCollision`, `StrataNavigation` | use and follow the parent terrain's bake when `data` is empty (default on) |
| `auto_prepare` / `auto_bake` | `StrataCollision` / `StrataNavigation` | without a `track_target`, cover the whole terrain when it fits the chunk or tile budget, otherwise warn once (default on) |
| `auto_start` | `StrataRegionStreamer` | start on ready from the parent terrain's bake and materials, with a sibling `StrataRenderer` and the viewport camera when unset (default on; never in the editor or headless) |

## Regions

The editor view and the bake store a terrain as square regions. These `StrataTerrain3D`
properties (the *Regions* group) set them:

| Property | Default | Meaning |
| --- | --- | --- |
| `region_spacing` | 1.0 | metres between samples of the region maps: heights, holes and material IDs and weights. The tint and AO map uses about 4 m. `editor_compile_spacing` is an alias |
| `region_cells` | 0 | cells per region side. 0 is automatic: the largest power of two at or below 256 and the terrain's smaller side in cells, at least 16 (64 m at 1 m gives 64, 4 km gives 256). Otherwise a power of two from 16 to 4096 |

`StrataBake` takes both from the terrain unless its options say otherwise, so a bake of the
default settings uses the regions you see in the editor.

Memory: with materials, a 256-cell region at 1 m is about 0.9 MB of video memory at full
resolution (height 0.27 MB, material IDs 0.27 MB, material weights 0.27 MB, holes 0.07 MB,
tint 0.04 MB) plus a CPU copy for sampling. Only the regions near the camera are held at
full resolution: farther regions use a reduced level and the rest of the terrain draws from
one coarse map set, so resident video memory depends on the streaming budgets, not on the
terrain size (about 48 MB for the 4 km island, about 51 MB for an 8 km terrain at 1 m).
Halving `region_spacing` quadruples the size of each region's data on disk.

## Bridge attributes

Primitive attributes on heightfield volumes exchanged with Houdini:

| Attribute | Direction | Meaning |
| --- | --- | --- |
| `hegostrata_layer_path` | out | the procedural layer to publish into; marks the volume as Strata's |
| `hegostrata_channel` | in, out | the channel; on a companion, the channel it belongs to |
| `hegostrata_role` | in, out | `value`, `ownership`, `coverage`, or `empty` for an empty-result marker |
| `hegostrata_composition` | in, out | `replace` or `add` |
| `hegostrata_empty` | out | 1 on an empty-result marker |
| `hegostrata_snapshot_mode` | in | `cumulative` or `raw` |
| `hegostrata_resampled_spacing` | in | the spacing an input channel was resampled to |
| `_hego_node_path` | in | the source layer's node path |

The input row settings, as stored in a `HEGoNode3D`'s `input_stash`:

| Setting | Default | Meaning |
| --- | --- | --- |
| `terrain_mode` | `cumulative` | `cumulative` or `raw` |
| `terrain_channels` | `height` | channel names, as a comma-separated string or a `PackedStringArray`; empty sends all |
| `terrain_spacing` | 0 | cumulative resampling spacing in metres; 0 keeps the layer's grid |
| `terrain_channel_spacings` | none | per-channel cumulative spacings, `{channel: metres}` |
| `terrain_max_samples` | 64 Mi | the input's sample budget, at most 512 Mi |
| `terrain_compact_empty` | false | send an unpainted raw channel as a single empty sample instead of a full-size empty grid |

## Bake options

Options of `StrataBake.bake(terrain, options)` and `StrataBake.compile()`:

| Option | Default | Meaning |
| --- | --- | --- |
| `spacing` | the terrain's `region_spacing` | metres between baked samples; `base_bounds` must be a whole number of them |
| `region_cells` | the terrain's `region_cells` | cells per region side, a power of two from 16 to 4096; 0 is automatic |
| `cell_masks` | off | `true` bakes the `hole` and `nav_exclusion` channels; a dictionary passes mask options such as `continuous_channels` and `thresholds` |
| `holes`, `nav_exclusions` | none | explicit cell masks instead of `cell_masks`: an image or bytes of (width − 1) × (height − 1) cells |
| `material_ids`, `material_weights` | none | packed material controls: an RGBA8 ID image and an RGBAF or RGBAH weight image, both covering the terrain at the bake's spacing |
| `macro` | `"auto"` | the tint and AO map: `"auto"` when a layer owns a tint or AO channel, `true` always, `false` never, or a dictionary with a `spacing` (default 4 m) |
| `channels` | none | extra channels to keep in the bake for `StrataRuntimeData.sample_channel()` and for navigation profile rules |
| `nav_profiles` | none | an array of `{"name": StringName, "rule": Dictionary}`; one walkability mask per name, one byte per cell. `default` is reserved: it is always the `nav_exclusion` mask. A rule that is invalid, or reads a channel the bake does not keep, fails the bake |
| `allow_stale_procedural` | false | bake stale or loaded procedural results as they are; the report lists them |
| `max_runtime_bytes` | 512 MiB | the size budget of a bake saved inside the scene, at most 512 MiB |
| `bake_batch` | 32 | regions baked and written together when the terrain has a storage directory |
| `lod_level` | 2 | first detail level kept in the reduced-detail region files |
| `max_directory_bytes` | 64 GiB | upper bound for the files of a bake saved to the storage directory |
| `mip_levels` | 3 | levels per map in every region; raised so the far level and the coarse maps exist |
| `far_level` | 2 | the level `StrataRegionStreamer` draws distant regions at |
| `coarse_max_side` | 1024 | longest side, in cells, of the terrain-wide coarse maps every bake stores for the streamer |

`bake()` returns `{ok, data, report}` or `{ok: false, message}`. Options of
`StrataBake.export_runtime()` and `save_runtime_scene()`: `collision` and `navigation`
(`true` or a dictionary of node properties), `name`, `share_data` (reference the
terrain's bake instead of copying it), `allow_stale_bake`, and for `save_runtime_scene()`,
`data_path` to save the bake as its own resource.

## Navigation profile rules

A rule is a Dictionary that is true where a cell is walkable. Each Dictionary is exactly
one of these forms; unknown keys, wrong types and empty lists are errors.

| Form | Walkable where | Notes |
| --- | --- | --- |
| `{"channel": name, "min": x, "max": y}` | the channel is within the range | `min` and/or `max`, inclusive. The channel must be in the bake's `channels`. |
| `{"height_min": x, "height_max": y}` | the height is within the range | Either or both, in metres. |
| `{"slope_min": x, "slope_max": y}` | the slope is within the range | Either or both, in degrees from 0 to 90. The steeper of the cell's two triangles counts. |
| `{"exclusion": true}` | the cell is not in the `nav_exclusion` mask | The mask's own per-cell value. |
| `{"not": rule}` | the inner rule is false | |
| `{"all": [rules]}` | every inner rule is true | Non-empty list. |
| `{"any": [rules]}` | at least one inner rule is true | Non-empty list. |

Channel and height tests use the mean of the cell's four corner samples. A 0/1 channel meant
as a category should use `"min": 0.5`, which means at least two corners are set. One rule may
contain at most `StrataNavProfiles.MAX_TERMS` (8) distinct tests.

Runtime API:

| Member | Meaning |
| --- | --- |
| `StrataRuntimeData.get_nav_profile_names()` | the profile names, including `default` |
| `StrataRuntimeData.has_nav_profile(name)`, `get_nav_profile_rule(name)` | whether a profile exists, and the rule it was baked from |
| `StrataRuntimeData.is_nav_blocked_cell(cell, profile)` | whether the cell is a hole or blocked for that profile |
| `StrataRuntimeData.sample_channel(name, position, interpolation)` | `{ok, status, value, coverage}` for a retained channel; `has_channel(name)` tests for one |
| `StrataTerrain3D.sample_runtime_channel(name, world_position)` | the same, in world space |
| `StrataNavigation.profile` | the profile this node bakes; default `default`. A profile missing from the data is reported by the bake |
| `StrataNavigation.navigation_layers` | the layer bits of this node's regions; agents choose a population with them |

## Custom material shader code

`StrataMaterial.custom_fragment_code` is the body of a function the renderer adds to the
terrain shader for that material:

```glsl
void strata_material_<id>(inout StrataSurface s, in StrataContext c) {
    // custom_fragment_code
}
```

It runs once per pixel for each blended material that has code, before blending, and its
result is weighted like the material's textures. All vectors are in the terrain's local space
(the `StrataTerrain3D` node's axes, Y up). `TIME` and the other global built-ins are available.

| `s` (`StrataSurface`, read and write) | Starts as |
| --- | --- |
| `vec3 albedo` | the material's linear colour, before the terrain tint map |
| `vec3 normal` | the unit normal including the material's normal map |
| `float roughness` | roughness after `roughness_scale` and `roughness_bias` |
| `float metallic` | metallic from the ORMH map |
| `float ao` | occlusion from the ORMH map |
| `vec3 emission` | 0; added to the terrain's emission |

| `c` (`StrataContext`, read only) | Meaning |
| --- | --- |
| `vec3 position` | the surface point before material displacement, in metres |
| `vec3 world_position` | the rendered point in world space |
| `vec3 view` | unit vector from the surface toward the camera |
| `vec3 geometric_normal` | the lighting normal without any material normal map |
| `vec2 uv` | the top projection's texture coordinate, `position.xz * uv_scale` |
| `vec2 screen_uv` | the screen position, as `SCREEN_UV` |
| `vec3 axis_weights` | the material's triplanar weights for the X, Y (top) and Z projections |
| `float weight` | the material's final blend weight at this point, above 0 and at most 1 |
| `float height` | the material's ORMH height, 0.5 neutral |
| `int id` | the material's ID, its index in the material list |

`custom_fragment_parameters` maps names to values. Each entry becomes a variable of that
name in the code. Names must be snake_case (lowercase letters, digits and underscores,
starting with a letter), must not be `s`, `c` or a shader keyword, and must not start with
`strata_` or `gl_`; other entries are ignored with a warning. Supported values:

| Value | Type in the code |
| --- | --- |
| `float`, `int`, `bool` | `float`, `int`, `bool` |
| `Vector2`, `Vector3`, `Vector4` | `vec2`, `vec3`, `vec4` |
| `Color` | `vec4`, converted to linear |

In the shader the values are uniforms named `strata_material_<id>_<name>`, so they never
clash with Strata's own uniforms or with another material's. Changing a value only updates
its uniform. Changing the code, or adding, removing or retyping a parameter, regenerates
the terrain shader. When no material has code, the terrain uses its plain shader unchanged.

Code that does not compile is reported with the material's path and ID, and that material is
drawn without it. The code runs in the pixel stage only: it cannot move vertices, change
displacement or the height blend, discard pixels, or declare its own textures.

## Files

With a `storage_directory`, a terrain keeps
[one file per layer, per cooked channel, for the bake and for the material controls](index.md#where-the-data-lives).
All are binary `.res` resources, written through a temporary `<name>~.res` file.

## Limits

| What | Limit |
| --- | --- |
| Brush dab | 65,536 samples of the layer's grid; radius up to 4096 m |
| Materials | 32 per terrain, at most four blended at any point |
| Terrain bounds | square, with a side of 8 m × a power of two (8 m to 32 km at the default render quality; the factor is the quality's minimum patch size); non-square or other sizes are not drawn |
| Regions | 4096 cells per side at most and at most 1,048,576 regions; resident regions are bounded by the streaming slots (25 near and 256 far by default), which must not exceed the graphics device's texture array layers |
| Precomputed control maps | `editor_control_ids` and `editor_control_weights` are at most 1025 texels per side; region composition has no such limit |
| Baked tint and AO map | at most 4097 texels per side: the default 4 m spacing covers terrains up to 16 km, a larger terrain needs a coarser `macro` spacing |
| Bake | 512 MiB in total for all regions and their detail levels |
| Heightfield exchanged with Houdini | 20 Mi samples per volume |
| One input row | 64 Mi samples including companions; `terrain_max_samples` raises it to 512 Mi |
| One cook's result | 512 Mi samples including ownership companions |
| One Houdini exchange | 512 Mi samples and 64 volumes in total (the island's 1 m material pass moves 18 volumes of 4097² in and 8 out) |

Volumes from Houdini must be dense, scalar, single-slice heightfields with finite values on
a horizontal grid with perpendicular axes; sheared, tapered or multi-slice volumes are
rejected.
