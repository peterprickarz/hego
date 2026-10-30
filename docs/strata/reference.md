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
| `terrain_max_samples` | 64 Mi | the input's sample budget, at most 128 Mi |
| `terrain_compact_empty` | false | send an unpainted raw channel as a single empty sample instead of a full-size empty grid |

## Bake options

Options of `StrataBake.bake(terrain, options)` and `StrataBake.compile()`:

| Option | Default | Meaning |
| --- | --- | --- |
| `spacing` | 1.0 | metres between baked samples; `base_bounds` must be a whole number of them |
| `cell_masks` | off | `true` bakes the `hole` and `nav_exclusion` channels; a dictionary passes mask options such as `continuous_channels` and `thresholds` |
| `holes`, `nav_exclusions` | none | explicit cell masks instead of `cell_masks`: an image or bytes of (width − 1) × (height − 1) cells |
| `material_ids`, `material_weights` | none | packed material controls: an RGBA8 ID image and an RGBAF or RGBAH weight image, both at most 1025 per side |
| `macro` | `"auto"` | the tint and AO map: `"auto"` when a layer owns a tint or AO channel, `true` always, `false` never, or a dictionary with a `spacing` (default 4 m) |
| `channels` | none | extra channels to keep in the bake for `StrataRuntimeData.sample_channel()` |
| `allow_stale_procedural` | false | bake stale or loaded procedural results as they are; the report lists them |
| `max_runtime_bytes` | 512 MiB | the bake's size budget, at most 512 MiB |

`bake()` returns `{ok, data, report}` or `{ok: false, message}`. Options of
`StrataBake.export_runtime()` and `save_runtime_scene()`: `collision` and `navigation`
(`true` or a dictionary of node properties), `name`, `share_data` (reference the
terrain's bake instead of copying it), `allow_stale_bake`, and for `save_runtime_scene()`,
`data_path` to save the bake as its own resource.

## Files

With a `storage_directory`, a terrain keeps
[one file per layer, per cooked channel, for the bake and for the material controls](index.md#where-the-data-lives).
All are binary `.res` resources, written through a temporary `<name>~.res` file.

## Limits

| What | Limit |
| --- | --- |
| Brush dab | 65,536 samples of the layer's grid; radius up to 4096 m |
| Materials | 32 per terrain, at most four blended at any point |
| Material control maps | 1025 texels per side; the editor composes them at 4 m |
| Rendered heightfield | 4097 samples per side: the editor compiles at `editor_compile_spacing` (1 m by default), the runtime renderer uses the bake's spacing |
| Tint and AO map | 4097 texels per side; 4 m spacing by default |
| Bake | 20 Mi samples (4097 × 4097 fits) and 512 MiB in total |
| Heightfield exchanged with Houdini | 20 Mi samples per volume |
| One input row | 64 Mi samples including companions; `terrain_max_samples` raises it to 128 Mi |
| One cook's result | 128 Mi samples including ownership companions |

Volumes from Houdini must be dense, scalar, single-slice heightfields with finite values on
a horizontal grid with perpendicular axes; sheared, tapered or multi-slice volumes are
rejected.
