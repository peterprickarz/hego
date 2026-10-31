# Terrain renderer: regions

Track R of [the regions plan](strata_regions_plan.md). Phase A: every region is resident at level 0;
Phase B (Track R2, [Residency tiers](#residency-tiers-phase-b)) adds the far and coarse tiers and the
slot API on top, and is off unless a residency is passed.
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
| `_region_table_image` / `_region_table_texture` | RGBA8, one texel per region: R slot low byte, G slot high byte, B level, A flag (see Residency tiers; Phase A writes B 0 and A 255 for a resident region). |

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
func set_regions(spec: Dictionary, regions: Dictionary, residency: Dictionary = {}) -> bool
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

## Residency tiers (Phase B)

Plan: [Phase B](strata_regions_plan.md#phase-b-residency). A region is in exactly one tier or none:

| Tier | Level | Storage | Shader |
| --- | --- | --- | --- |
| near | 0 | `<map>_regions` arrays, `near_slots` layers | `texelFetch` / hardware filter as in Phase A |
| far | `far_level` | `<map>_far_regions` arrays, `far_slots` layers of the level-`far_level` map size | `texel = local / (spacing * (scale << far_level)) + apron`, array size from `textureSize` |
| coarse | `coarse_level` | one terrain-wide `coarse_<map>` `Texture2D` per shader map (`StrataRegions.coarse_map_size`), no apron | `texel = (pos - origin) / (spacing * (scale << coarse_level))`, clamped sampler; sample maps `textureLod` at `(texel + 0.5) / size`, cell maps `texelFetch` |

A region without a tier (never bound, or released) is drawn from the coarse maps when there are
any, otherwise as nothing (height 0). Residency is selected by a dictionary
`{near_slots, far_slots, far_level, coarse_level, coarse_maps: {map: Image}}` passed to
`configure_regions`, `set_regions` or (as `{near_slots, far_slots, far_level}`) `configure_runtime`.
Empty is exactly Phase A: `near_slots = grid.x * grid.y`, every grid region owns the layer
`y * grid.x + x`, no far tier, no coarse maps. Missing keys with a non-empty dictionary:
`near_slots` = the number of grid regions, `far_slots` 0, `far_level` 2, no coarse maps.

### Region table

| Channel | Content |
| --- | --- |
| R, G | slot (array layer) low / high byte of the tier that holds the region |
| B | level of the bound data: 0 near, `far_level` far, 255 none |
| A | flag: 1 near, 2 far, 0 none |

Deviation: the Phase A layout (empty residency) keeps its original encoding, B 0 and A 255 for a
resident region (B 255 and A 0 for none), because the Phase A tests pin it. The shader reads A 2 as
far, A 0 as none and anything else as near, so both encodings work. `_region_resident(xy)` is
"A > 0".

### Shader

New uniforms: `<map>_far_regions` (`height_`, `material_ids_`, `material_weights_`, `holes_`,
`macro_`; same filters as the near arrays), `coarse_height` (linear), `coarse_material_ids`,
`coarse_material_weights`, `coarse_holes` (nearest), `coarse_macro` (linear), `far_level`,
`coarse_level`, `has_far_tier`, `has_coarse_maps`. Absent tiers bind 1x1 placeholders, so the shader
compiles in every configuration. Maps share `<map>_scale` and `<map>_apron` across tiers (the far
apron is the same number of texels at the coarser step).

`terrain_region_entry(region, out slot)` returns 0 none, 1 near, 2 far, 3 coarse (a tier-less region
when `has_coarse_maps`). Fetches:

- `terrain_linear_height(position)`: hardware bilinear on the tier's data. Near and far read the
  region's layer (the apron keeps the footprint inside it); coarse reads the terrain image.
- `terrain_texel_height(index)` (the normals' host interface): near is a `texelFetch`; far and coarse
  return the bilinear sample of their coarser lattice at the fine lattice point, so a finer lattice
  than the data has gets bilinear heights, and lattice points the tiers share (every
  `1 << level`-th index) return the stored value. Normals, creases and triangle sampling therefore
  need no tier knowledge.
- Controls (`terrain_control_corner`): the fine corner index maps to the nearest lattice point of the
  tier's data (`(local + (1 << level) / 2) >> level`), ids and weights are fetched exactly, never
  filtered. Holes: the fine cell maps to the covering coarser cell (the bake's "any" rule keeps a
  hole visible). Macro: `textureLod` on the tier's map.

### Seams

Level `l` texel `u` of a sample map covers lattice index `(u - a) << l`, so tiers share lattice
points. With height mips built by decimation (the coincident level-0 sample) a near region and a
far region agree exactly at every shared point, and `terrain_linear_height` is linear between far
points. A patch's vertices are position functions (no per-patch state), so adjacent patches never
disagree at a shared vertex; a chord crack can only arise where a finer patch edge has a vertex
between two points of a coarser patch edge that does not lie on the coarser surface, which is why the
vertex spacing at a tier boundary must be at least `spacing << level` of the coarser side
(`residency_render_test.gd` checks the rasterized vertex heights across near/far and near/coarse
boundaries against a CPU model, and an oblique view for background leaks).

### Slot API

```gdscript
func set_region_level(xy: Vector2i, data: StrataRegionData, level: int) -> bool
func release_region(xy: Vector2i) -> bool
func region_level(xy: Vector2i) -> int            # 0, far_level or -1
func free_slots(level: int) -> int                # 0 for any level but 0 / far_level
func set_coarse_maps(coarse_level: int, images: Dictionary) -> bool
func configure_runtime(source: Node3D, data: StrataRuntimeData, materials: Array[StrataMaterial], residency: Dictionary = {}) -> bool
```

- `set_region_level` uploads `data.get_image(map, level)` for every shader map into a free slot of
  the tier, frees the region's old slot when it moves between tiers, and updates the table, CPU data
  and patch bounds. False, with no change, when the tier is full, the level is neither 0 nor the far
  level of an existing far tier, the data lacks that level or does not match the spec. Rebinding a
  region into its own tier reuses its slot.
- `update_region` keeps the region's tier (and false for an unbound region with residency);
  `update_region_window` serves near regions only; `get_region` returns the CPU data of any bound
  region. Whole-image adapters (`set_compiled_field` and friends) are not available with residency
  and fail with a warning.
- `release_region` frees the slot (the layer keeps stale pixels the table no longer points at); the
  region renders from the coarse maps.
- `set_coarse_maps` validates one image per shader map of the spec (format, size equal to
  `coarse_map_size(spec, description, coarse_level)`, finite heights), swaps the textures and computes
  the per-region coarse height extrema once. An empty dictionary removes the coarse tier.
- Validation (`set_regions`, `configure_regions`): `near_slots` in `1..LIMIT_MAX_TEXTURE_ARRAY_LAYERS`,
  `far_slots` in `0..limit`, `far_level` in `1..deepest level every shader map has` when `far_slots > 0`,
  the passed regions fit the near slots, coarse level in `0..deepest`. Everything is checked and
  built before anything is swapped.
- `configure_runtime` with a residency reads `data.coarse_level` and `data.coarse_maps` (map name ->
  `PackedByteArray` in the map's format, sized by `coarse_map_size`) and binds no regions; a data
  object without them configures with no coarse maps. Slot counts are capped at the region count;
  defaults 25 / 256 / 2. Without a residency every region is loaded and bound as in Phase A.

### Height extrema

A bound region contributes its `height_min`/`height_max` (level 0). A region drawn from the coarse
maps contributes the extrema of its coarse height core (the `n + 1` texels it covers, computed once in
`set_coarse_maps` / at configure). The global range is the union of both, so patch `custom_aabb`s and
refinement culling stay conservative when the streamer binds and releases regions.

### CPU sampling

`sample_render_height` and `raycast_heightfield` read level-0 data of bound regions (including far
ones, whose CPU data carries every level) and the bilinear coarse height for regions without data.
They therefore show the near surface for a far region, not the far lattice the GPU draws.

### Stats and memory

`get_stats()` adds `near_resident`, `far_resident`, `near_slots`, `far_slots`, `gpu_bytes_near`
(`near_slots` x per-region bytes at level 0), `gpu_bytes_far` (`far_slots` x per-region bytes at
`far_level`) and `gpu_bytes_coarse`. Test fixture (16 cells): near 6,084 bytes per region, far
2,372 bytes (level 1); with 4 near and 6 far slots 24,336 + 14,232 bytes plus 3,924 bytes of coarse
maps, against 97,344 bytes for all 16 regions resident. The island budget with the defaults is in
the plan (about 48 MB).

Tests: `demo/tests/residency_render_test.gd` (Forward+): coarse-only rendering, slot churn, tier seams,
holes in every tier, window-update rules, stats, release to coarse; `region_renderer_test.gd` keeps
pinning Phase A.

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

## Editor preview (Tracks E and E2)

`StrataEditorPreview` composes the live authoring stack as regions and binds them to the renderer;
it no longer feeds whole-terrain images to the adapters, and it no longer uses the 4 m material
lattice (`StrataMaterialControls`) or `StrataMacro.compose` (both kept only as deprecated helpers for
fixtures and diagnostics).

- Spec: `StrataTerrain3D.region_spec()` = `StrataRegions.standard_spec(base_bounds, region_spacing,
  region_cells)`; material ids/weights only when `editor_material_channels` is not empty (as
  `StrataBake`), macro only when an enabled layer owns a tint or AO channel (scale nearest to 4 m),
  holes always. `editor_compile_spacing` is an alias of `region_spacing`.
- Renderer set-up: `configure_regions(terrain, materials, spec, {}, residency)` with no regions yet and
  no stand-in field; the composed regions are bound afterwards.
- Cache: one signature per map class (height, holes, materials, macro) from
  `StrataMaterialControls.signature` over the class's channels, without the cutoff, so moving the
  cutoff across layers that hold none of them recomposes nothing. A changed signature bumps that
  class's generation; every cache entry (a level-0 region, a far-level region, the coarse maps)
  remembers the generations it was composed from, and only the stale classes of an entry are
  recomposed.

### Tiers

A terrain with at most `near_slots` (25) regions is the Phase A layout: every region at level 0, set
with one `set_regions` once all are composed, no residency. A larger one uses the renderer's
residency tiers, chosen from the editor camera (terrain-local XZ), with the streamer's rule
(`plan_tiers`): a region is near when the closest point of its rectangle is within `near_radius`
(2.5 region extents), far within `far_radius` (8 extents), otherwise coarse only; at most `near_slots`
near (nearest win, the overflow competes for far) and `far_slots` (256) far, both capped to the
region count; `far_level` is 2 (or the deepest level every map has). A region already in a tier keeps it
out to 1.25 times the radius. The renderer is configured with `{near_slots, far_slots, far_level,
coarse_level = StrataRegions.coarse_level(spec, coarse_max_side), coarse_maps}`.

Order of events after a refresh:

1. The coarse maps are composed first, one task per map class (`compose_map` over
   `StrataRegions.coarse_window` at `coarse_level`; cell masks of a non-square terrain in square tiles),
   and bound together with the structure by `set_regions(spec, {}, residency)`. While they are
   outstanding the region tasks only get the processors they leave, so the whole terrain is visible
   within about a second.
2. Near regions, nearest first, one task each at level 0 (all classes), bound with
   `set_region_level(xy, data, 0)` as each completes.
3. Far regions, nearest first, composed directly at `far_level` (`map_window(spec, xy, description,
   far_level)`; a direct coarse composition, not a downsample of level 0: fine for a preview, never for a
   bake) and bound with `set_region_level(xy, data, far_level)`. A far `StrataRegionData` holds only
   its far-level images; the lower levels are zero byte arrays shared by all far regions (copy on
   write) so `validate()` and the renderer accept it without paying level-0 memory.

When the camera moves a quarter of a region extent (checked every frame in `_process`), the tiers are
planned again: regions that left every tier are released (`release_region`), demotions bind before
promotions (they free near slots), and regions entering a tier are composed (or taken from the cache)
and bound. Unbound level-0 regions beyond the wanted ones are kept as an LRU cache of `cache_regions`
(64); far-level regions are tiny and all kept. The knobs `near_slots`, `far_slots`, `far_level`,
`near_radius`, `far_radius`, `coarse_max_side`, `cache_regions`, `coarse_upload_ms` and `max_in_flight`
are plain properties of the bridge (tests tune them; the editor uses the defaults).

### Asynchronous composition

One `StrataRegionCompose.capture` per refresh (lazily, on the main thread, just before the first task is
submitted); tasks are `WorkerThreadPool.add_task` calls of the static `_work(task)` (one per map class
for the coarse maps, one per region and level for the others, at most `2 x processor count` in flight),
polled with `is_task_completed` in `_process`, joined with `wait_for_task_completion` and bound on the
main thread only. A task result carries the epoch it was submitted in; a new capture bumps the epoch
and results of older ones are dropped, never bound. `refresh_now()` and `compose_cache()` complete the
work synchronously (`compose_cache` without a renderer composes every region at level 0 with
`StrataRegions.compose_regions`, plus the coarse maps of a tiered terrain).

The capture references the layers' live data, it is not a snapshot, so layers must not change while
tasks run. `request_refresh()` (also called by `authoring_preview_changed`) and `can_patch_region()`
therefore wait for the tasks in flight, drop their results and discard the capture before the edit; a
dab arriving while work is outstanding returns `false` from `can_patch_region()` and falls back to a
refresh. The residual race is an edit that does not call either before changing the layers. After a
successful patch the capture is discarded too, so later tasks capture the edited stack.

### Dabs

`can_patch_region()` records which classes are current; `refresh_region()` finds the regions with
`regions_touching` and, per class:

- near (bound or still cached) regions: the texel rectangle the dab can change, on the maps' own lattices
  (`compose_map` over a window, `update_region_window`); at spacings that are not powers of two whole
  region maps;
- far regions (bound or cached): the region's far-level maps of the class are recomposed on the main
  thread and rebound with `set_region_level` (a few thousand texels);
- the coarse maps: the covered coarse texels (`compose_map` over a sub-window of the coarse lattice,
  blitted into the CPU copy), uploaded with `set_coarse_maps` at most every `coarse_upload_ms` (250 ms)
  with a trailing flush from `_process` (and `flush_coarse()`, which the plugin calls when a stroke
  ends). Coarse-only regions need nothing else.

Height dabs touch height only, material dabs ids and weights, hole dabs holes, tint/AO dabs macro. A dab
that introduces a channel's ownership (first tint sample) changes the whole class and falls back to a
refresh of it. The coarse sub-window of a dab is composed directly on the coarse lattice, so it equals a
whole-coarse composition for spacings that are powers of two and agrees to rounding otherwise.

### Stats and test hooks

`get_stats()`: the Phase A keys (`full_compiles`, `region_compiles`, `material_compositions`,
`material_regions`, `region_compositions`, `regions` = cached level-0 regions, `last_patch_ms`, `status`)
and `tiered`, `near_bound`, `far_bound`, `far_cached`, `near_composed`, `far_composed`,
`coarse_composed`, `coarse_uploads`, `far_patches`, `pending_tasks`, `coarse_level`. `status` reads
"Composing live terrain regions (coarse terrain | regions near the camera) done/total, N tasks" while
working and ends with the near/far counts for a tiered terrain; the plugin shows it in the toolbar label
while no stroke is active. `get_wanted()`, `tier_of()`, `get_far_region()`, `get_coarse_maps()`.

`renderer` may be assigned a duck-typed stand-in before the first refresh (`demo/tests/region_preview_test.gd`
records the calls of `configure_regions`, `set_regions`, `set_region_level`, `release_region`,
`set_coarse_maps`, `update_region_window` and enforces the slot rules), which lets the tier logic run
headless. `terrain_editor_smoke.gd` needs the editor and was not run.

Measured on the saved island (256 regions of 256 cells) before Track E2: a 12 m-radius dab costs 1 ms
(height) and 2.2 ms (materials); a full level-0 refresh was compute bound by the 1 m material pack (about
80 ms per region, 13 ms per height region), roughly 26 s on one thread. Track E2 timings on the island
are not measured here (the island tests were off limits).
