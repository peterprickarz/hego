# Terrain renderer: regions

Track R of [the regions plan](strata_regions_plan.md). Phase A: every region is resident at level 0.
`StrataRenderer` keeps one `Texture2DArray` per map with a layer per region, a region table
texture, and the CPU `StrataRegionData` of each region. The shader addresses height, material
controls, cell holes and the macro tint through them. Whole-terrain images are still accepted
by transitional adapters that slice them into regions.

All geometry comes from `StrataRegions` (`map_window`, `map_size`, `texel_step`, `region_bounds`,
`regions_touching`, `grid_size`); the renderer holds no private copy of those formulas. The shader
repeats the same arithmetic in GLSL (`terrain_regions.gdshaderinc`).

## State

| Member | Content |
| --- | --- |
| `_region_spec` | The spec in effect (`StrataRegions` Dictionary). |
| `_regions` | `Vector2i` -> `StrataRegionData` of the resident regions (CPU sampling and patching). |
| `_region_arrays` | map name -> `Texture2DArray`, layer count = grid size, layer = `y * grid.x + x`. |
| `_region_table_image` / `_region_table_texture` | RGBA8, one texel per region: R layer low byte, G layer high byte, B level (0 in Phase A), A 255 when resident, else 0. |

Missing regions keep an all-zero layer and a non-resident table entry; they render as height 0, no
holes, no material and no tint. `update_region` makes a region resident.

## Shader uniforms

Declared in `terrain_surface.gdshader`; the functions live in `terrain_regions.gdshaderinc`.

| Uniform | Meaning |
| --- | --- |
| `region_origin` | Terrain bounds position. |
| `region_extent` | Metres per region (`cells * spacing`). |
| `region_spacing`, `region_cells` | Spec spacing and cells. |
| `region_grid` | `ivec2` region grid. |
| `region_lattice` | `ivec2` height-sample intervals at scale 1 (the terrain's last lattice index). |
| `region_table` | The table texture, nearest. |
| `height_regions`, `height_scale`, `height_apron` | RF array, bilinear. |
| `material_ids_regions`, `material_ids_scale`, `material_ids_apron` | RGBA8 array, nearest. |
| `material_weights_regions` | RGBA8 or RGBAF array, nearest; shares the ids' scale and apron (`set_regions` rejects a spec where they differ). |
| `holes_regions`, `holes_scale`, `holes_apron` | L8 cell-map array, nearest. |
| `macro_regions`, `macro_scale`, `macro_apron` | RGBAH array, bilinear. |
| `has_material_maps`, `has_holes`, `has_terrain_macro_map` | The shader reads the map. |

Removed: `height_field`, `control_ids`, `control_weights`, `cell_holes`, `terrain_macro_map`,
`terrain_macro_origin`, `terrain_macro_size`. Unchanged: `field_origin`, `field_size` (patch
placement and terrain-edge clamp), `ownership_field` and `channel_preview_field` overlays, the
per-instance `patch_*` uniforms.

Addressing, per sample: `rel = clamp(pos - region_origin, 0, field_size)`;
`r = clamp(floor(rel / region_extent), 0, grid - 1)`; `local = rel - r * region_extent`;
`texel = local / (spacing * scale) + apron`; layer from `region_table[r]`; sample at
`(texel + 0.5) / size` (bilinear for height and macro). Point-sampled lookups
(`texelFetch`: sample-lattice indices of the normals, creases, triangle sampling and the four
control corners) resolve a lattice index to its own region (`index / (cells / scale)`, shared edges
belong to the higher region, the last region absorbs the terrain edge), so a neighbouring fetch never
depends on another region's apron. Only the hardware filter of height and macro reads the apron
(one texel); the default apron of 2 is therefore more than the shader needs. Terrain-edge clamping
happens on `rel` and on lattice indices.

### Include contracts

The includes used to read the whole-terrain textures directly; the lattice-specific parts are now
supplied by the host shader, so tests can include them with their own sources:

- `terrain_controls.gdshaderinc` needs `terrain_control_corner(position, offset, out ids, out weights, out fraction)`.
- `terrain_normals.gdshaderinc` needs `terrain_lattice_step()`, `terrain_lattice_max()`,
  `terrain_linear_height(position)` and `terrain_texel_height(index)`.
- `terrain_regions.gdshaderinc` implements all of them over the region arrays; shaders assembled
  by text substitution (tests, `override()` helpers) must inline it before `terrain_controls`.

## API

```gdscript
func set_regions(spec: Dictionary, regions: Dictionary) -> bool
func update_region(xy: Vector2i, data: StrataRegionData) -> bool
func update_region_window(xy: Vector2i, map: String, patch: Image, texel_origin: Vector2i) -> bool
func get_region(xy: Vector2i) -> StrataRegionData
func region_spec() -> Dictionary
func sample_control_blend(position: Vector2) -> Dictionary  # ids, weights, discarded_weight read from the regions
```

- `set_regions` needs a configured renderer (`configure*` first) and spec bounds equal to the
  terrain's. It validates the spec (`StrataRegions.validate_spec`), the shader's map formats (height
  RF; material ids RGBA8; weights RGBA8 or RGBAF; holes L8 cell map; macro RGBAH sample map; other
  maps are carried but not bound), every region (`StrataRegionData.validate`, geometry equal to the
  spec, every spec map present with the spec's description), the device's array layer limit, then
  builds the arrays and table and only then swaps. A rejected call changes nothing. It replaces any
  adapter state (`_height_image` and the other whole-image references become null).
- `update_region` validates like `set_regions` and rewrites that region's layers in place.
- `update_region_window` blits into the CPU region and calls `ImageTextureLayered.update_layer` for
  the region's layer; arrays keep their identity. Height windows must be finite and refresh the
  region's `height_min`/`height_max`. Weights are not normalized for you; the shader renormalizes.
- Height extrema: `custom_aabb` of a patch uses the extrema of the regions it overlaps
  (`regions_touching`), recomputed from the current regions after every change, so bounds shrink
  as well as grow. The global range (`_height_min/_height_max`, refinement culling, raycast box) is the
  union of the resident regions.
- Stats: `regions`, `region_grid`, `region_cells`, `region_bytes` (GPU bytes per region, bound
  maps only); `height_resolution` / `control_resolution` are the lattices the regions imply
  (`bounds / (spacing * scale) + 1`).

## Transitional adapters

`set_compiled_field`, `configure_compiled_field`, `configure_runtime`, `set_control_maps`,
`update_control_region`, `set_hole_image`, `set_macro_map` and `update_compiled_region` keep their
signatures and results. The whole-terrain images are kept as the CPU reference (`_height_image`,
`_control_ids`, ...) and `_sync_regions` slices them: when the layout in effect already covers the
new one only the changed maps are rewritten layer by layer, otherwise every region is rebuilt and
swapped at once. Sizes are chosen by `_adapter_plan`:

- `spacing`: the finer of the height step and the control step.
- `scale` of a map: its step / spacing (a power of two). A 1025-texel control map over the 4096 m
  island is scale 4; a 65-texel fixture over an 8 m terrain with 1 m heights makes spacing
  0.125 m and height scale 8.
- `cells`: 256, or the smallest power of two >= the lattice when smaller (>= 16), raised so that
  `apron * scale <= cells / 2` for every map.
- aprons: height 2, other maps 1; texels beyond the terrain replicate the edge sample.
- control maps whose step is not a power-of-two multiple of the spacing (or more than 32x) are
  resampled to a lattice of about 1025 texels (nearest IDs, bilinear weights by ID); macro maps
  that do not match the macro lattice (scale 4 at most) are resampled bilinearly. Both are
  GDScript loops, meant for fixtures and small maps; real data should arrive through `set_regions`.
- control weights stay RGBAF in the adapters (the old maps were RGBAF; quantizing to RGBA8 would
  change the soft-limit results the tests compare against).
- `update_compiled_region` and `update_control_region` blit only into the regions whose window
  (apron included) overlaps the patch, extending patches that reach the terrain edge by edge
  replication.

`set_hole_image(null)` and `set_macro_map(null, ...)` only clear the shader flag; the region map
stays until the next layout change.

## GPU memory

Plan layout per region at 256 cells, apron 2: height RF 261 x 261 x 4 = 272,484 bytes; material
ids RGBA8 272,484; weights RGBA8 272,484; holes L8 258 x 258 = 66,564; macro RGBAH at scale 4
(67 x 67 x 8) = 35,912; about 235 MB for the 16 x 16 island.

Measured through the adapters on the saved island (`renderer.get_stats().region_bytes`): 464,740
bytes per region, 113.5 MB for 256 regions. The 1025-texel control maps become scale 4 with apron 1
(ids 17,956 and RGBAF weights 71,824 bytes per region), which is why this is below the plan's
number; 1 m controls written by the planned producers cost the plan's figure. The 16-cell test
fixture costs 6,084 bytes per region.

## Configuring from regions (Track X)

```gdscript
func configure_regions(source: Node3D, materials: Array[StrataMaterial], spec: Dictionary, regions: Dictionary) -> bool
```

Configures the renderer straight from a spec and a (possibly empty or partial) region set. Bounds and
spacing come from the spec; `runtime_mode` is false when `source` is a `StrataTerrain3D` (the spec bounds
must then equal its `base_bounds`) and true for any other `Node3D`. The spec is cut down to the maps the
shader reads, material ids are checked against the pool, and the call is transactional like `configure`:
a rejection leaves the previous configuration and regions. `configure_runtime` builds its region set from
the manifest and calls it.

## Composing a map window

```gdscript
static func StrataRegionCompose.compose_map(terrain, through_layer, map: String, window: Dictionary, spec: Dictionary, options := {}) -> Dictionary
```

Returns `{ok, message, image}` for any window (a `StrataRegions.map_window` result or a sub-rectangle of
one) of a spec map: height; `material_ids` / `material_weights` (both composed, returned as `ids` and
`weights`, `image` being the requested one); `holes` / `nav_exclusion`; `macro`; any other sample map as a
custom channel (with `coverage` when the spec has `<name>__coverage`). Every texel is the whole-terrain
expression, so a window equals the matching rectangle of the full map bit for bit (`region_compose_test`).
Cell-mask windows must be square and macro windows at least 2 x 2 texels; `nav_<profile>` and coverage
maps are derived and rejected. `compose_region` composes each of its maps through it.

## Region size

`StrataTerrain3D.region_cells` 0 (the default) is automatic, `StrataRegions.resolve_cells(requested, bounds,
spacing)`: the largest power of two at or below min(256, smaller bounds side / spacing), at least 16.
`region_spec()` and `StrataBake` (unless its `region_cells` / `spacing` options override) both call it with
the terrain's values, so a default bake has the editor's regions. Explicit values are used as given.

## Editor preview (Track E)

`StrataEditorPreview` composes the live authoring stack as regions and binds them with
`set_regions`; it no longer feeds whole-terrain images to the adapters, and it no longer uses the
4 m material lattice (`StrataMaterialControls`) or `StrataMacro.compose` (both kept only as
deprecated helpers for fixtures and diagnostics).

- Spec: `StrataTerrain3D.region_spec()` = `StrataRegions.standard_spec(base_bounds, region_spacing,
  region_cells)`; material ids/weights only when `editor_material_channels` is not empty (as
  `StrataBake`), macro only when an enabled layer owns a tint or AO channel (scale nearest to 4 m),
  holes always. `editor_compile_spacing` is an alias of `region_spacing`.
- Renderer set-up: the bridge calls `configure_regions(terrain, materials, spec, {})` (no regions yet, no
  stand-in field) and binds the composed regions with `set_regions` afterwards.
- Full refresh, time sliced (`StrataEditorPreview.SLICE_MS` = 4 ms of composition per frame, progress in
  `status`): pass 1 composes height and holes of every region with `compose_region` (material and macro
  maps start unassigned/neutral) and binds them; pass 2 composes materials and macro per region and
  writes them with `update_region_window`. `refresh_now()` / `compose_cache()` complete a refresh
  synchronously (tests, headless).
- Cache: one signature per map class (height, holes, materials, macro) from
  `StrataMaterialControls.signature` over the class's channels, without the cutoff, so moving the
  cutoff across layers that hold none of them recomposes nothing. A changed signature recomposes that
  class only, region by region with `update_region_window`.
- Dab: `can_patch_region()` records which classes are current; `refresh_region()` finds the regions with
  `regions_touching`, composes only the texel rectangle the dab can change (windows of the maps'
  own lattices) and writes it with `update_region_window`. Height dabs touch height only, material
  dabs ids and weights, hole dabs holes, tint/AO dabs macro. A dab that introduces a channel's
  ownership (first tint sample) changes the whole class and falls back to a full refresh of it. At
  spacings that are not powers of two whole region maps are recomposed instead of windows.
- Sub-windows come from the public `StrataRegionCompose.compose_map(terrain, through, map, window, spec)`, which
  `compose_region` uses as well (see below); the bridge calls no private composer function.

Measured on the saved island (256 regions of 256 cells): a 12 m-radius dab costs 1 ms (height) and 2.2 ms
(materials); a full refresh is compute bound by the 1 m material pack (about 80 ms per region, 13 ms
per height region), roughly 26 s in total, sliced across frames.
