# Runtime bake, collision and navigation internals

How Strata compiles an authoring `StrataTerrain3D` layer stack into a versioned runtime resource, and how bounded static collision and tiled navigation for selected gameplay areas are built from it. The user-facing workflow is in [Getting started](../strata/getting_started.md). The runtime resource and its collision and navigation nodes use only built-in Godot types. A saved runtime scene loads, collides and navigates without the native terrain extension, the authoring scripts, HEGo or Houdini.

| File | Class | Depends on |
| --- | --- | --- |
| `demo/addons/strata/strata_regions.gd` | `StrataRegions` (static geometry, mips) | Godot only |
| `demo/addons/strata/strata_region_data.gd` | `StrataRegionData` (Resource) | `StrataRegions` |
| `demo/addons/strata/strata_runtime_data.gd` | `StrataRuntimeData` (Resource, the manifest) | the two above |
| `demo/addons/strata/strata_nav_profiles.gd` | `StrataNavProfiles` (static) | the above |
| `demo/addons/strata/strata_collision.gd` | `StrataCollision` (Node3D) | runtime data |
| `demo/addons/strata/strata_navigation.gd` | `StrataNavigation` (Node3D) | runtime data |
| `demo/addons/strata/strata_region_compose.gd` | `StrataRegionCompose` (static) | authoring layers, native compiler |
| `demo/addons/strata/strata_bake.gd` | `StrataBake` (static) | authoring layers, native compiler |

The runtime-only project of the test runner holds exactly `strata_regions.gd`, `strata_region_data.gd`, `strata_runtime_data.gd`, `strata_nav_profiles.gd`, `strata_collision.gd`, `strata_navigation.gd` and `strata_render_settings.gd`. `StrataRegions.compose_region()` finds `StrataRegionCompose` by class name at call time, because a runtime-only project cannot parse a script that names `StrataTerrain3D` or the native classes.

## Compiled data (format 2)

The bake is a grid of regions (see [Strata regions plan](strata_regions_plan.md) for the geometry: `cells` cells per region axis at the terrain `spacing`, a sample map holds `cells + 1 + 2 * apron` samples per axis, a cell map `cells + 2 * apron`, neighbours share their edge samples). `StrataRuntimeData` is the **manifest**:

| Property | Meaning |
| --- | --- |
| `format_version` | 2. Format 1 (one monolithic resource) is **not migrated**: it fails `validate()` with "bake the terrain again", and `StrataStorage.load_runtime_data()` returns null with a warning. Rebake. |
| `bake_revision` | increments on every published bake |
| `bounds`, `spacing` | terrain-local XZ bounds and sample spacing (raw float64 storage, see below) |
| `cells`, `apron`, `grid` | region size, apron, regions per axis (derived from bounds, spacing, cells) |
| `maps` | the spec maps, `name -> {format, kind, scale, apron}`; every region file holds exactly these |
| `mip_levels` | levels per map the bake computed, level 0 included (capped per map by `StrataRegions.max_level`) |
| `channel_names` | retained custom channels; each has a sample map of that name and optionally `<name>__coverage` |
| `nav_profile_rules` | `StringName -> rule`, always including `default` (`{"exclusion": true}`); bytes in the file |
| `render_settings` | the baked `StrataRenderSettings` copy |
| `height_min`, `height_max`, `region_extrema` | extrema over the terrain's own samples, global and per region (`[min, max]` pairs, row-major over the grid) |
| `regions` | embedded `Vector2i -> StrataRegionData`, the whole grid or empty |
| `region_directory` | when no regions are embedded: the folder of `region_<i>_<j>.res` (all levels) and `region_<i>_<j>.lod.res` (levels `lod_level`.. only) files |
| `lod_level` | first level of the lod files, 0..15 (default 2, the streamer's `far_level`); the bake keeps it below `mip_levels`, `region_path()` ignores the lod files when it is not. 0 writes no lod files |
| `coarse_level`, `coarse_maps` | Phase B horizon tier: `coarse_maps[name]` is the terrain-wide image of map `name` at mip level `coarse_level`, no apron, in the map's own format, as a `PackedByteArray` of `StrataRegions.coarse_map_size(spec, description, coarse_level)` texels (see *Coarse maps*). Optional: format 2 data without them stays valid |

Standard maps: `height` (RF, sample), `material_ids` and `material_weights` (RGBA8, sample, only when the terrain defines `editor_material_channels`), `holes` and `nav_exclusion` (L8, cell, only when the bake asked for cell masks), `macro` (RGBAH, sample, scale 4 apron 1 by default, only when macro channels are owned or requested), `<channel>` and `<channel>__coverage` for retained channels (RF; `rh` or `l8` quantize 0..1), and `nav_<profile>` (L8, cell, 255 = blocked) per navigation profile. Holes are never repeated in the profile maps.

Floats of the manifest (bounds, spacing, extrema) and the profile rules are saved as raw bytes through storage-only properties, because Godot text resources write floats with about six significant digits. Region maps are raw `PackedByteArray` levels, so a bake is byte-identical across `.res`, `.scn` and `.tres`; the runtime suites compare SHA-256 hashes of every region level. (`StrataRegionData` itself stores its own `origin`, `spacing` and `height_min/max` as plain floats, so a `.tres` region rounds those three; nothing reads them for sampling. The manifest's extrema are authoritative.) Keep large bakes in binary `.res` files.

The runtime resources contain no layers, ownership, layer IDs, producer IDs or Houdini state.

### Validation

`validate(deep = false)` checks the manifest (spec, grid, height map, extrema array, channel and profile bookkeeping, render settings) and every **embedded** region: structure (`StrataRegionData.validate()`), match with the manifest's maps and level counts, finite heights (apron included), canonical 0/255 cell masks, finite channel values, coverage in 0..1, macro tint 0..2 and AO 0..1, and extrema equal to the scanned region and global extrema. The scan is cached; `validate_payload()` discards it and also the whole-lattice compatibility caches, after intentional in-place edits of region bytes. External regions are validated when they load (`get_region()` rejects a file whose size, spec or index does not match) and all at once with `validate(true)`. Embedded payloads are capped at 512 MiB; external payloads are not.

### Accessors

Terrain-local XZ everywhere. `Status` is `OK`, `OUTSIDE`, `ABSENT`, `NOT_RESIDENT` or `HOLE`.

| Accessor | Result |
| --- | --- |
| `get_region(xy: Vector2i) -> StrataRegionData` | The embedded region, or the external file loaded once and kept (no eviction in Phase A). Null outside the grid, for a missing or malformed file (logged once; `clear_region_cache()` forgets that). |
| `cells_resolution() -> Vector2i` | `grid * cells`: the cell space windows are addressed in. |
| `get_cell_resolution() -> Vector2i`, `resolution` | The terrain's own cells (`bounds.size / spacing`) and samples (cells + 1). At most `cells_resolution()`. |
| `get_spacing() -> float` | `spacing`. |
| `sample_height(position, interpolation = TRIANGLE, ignore_holes = false)` | `{status, value}` as before: `OUTSIDE` beyond `bounds`, `NOT_RESIDENT` when the data or the cell's region is unavailable, `HOLE` when every cell touching the point is a hole, `NAN` value unless `OK`. A cell's four corners always lie in the one region that owns the cell, so a query reads at most one region. |
| `sample_heights(PackedVector2Array)`, `sample_height_world`, `sample_heights_world` | as before |
| `sample_channel(name, position, interpolation = BILINEAR)` | `{ok, status, value, coverage}` as before; coverage comes from the `<name>__coverage` map (absent map = defined everywhere). |
| `is_hole_at(position)`, `is_hole_cell(cell)`, `is_nav_excluded_cell(cell)`, `is_nav_blocked_cell(cell, profile)` | cell queries on the cell maps; a missing map or region means not masked, an unknown profile blocks everything. |
| `heights_window(cell_rect: Rect2i) -> PackedFloat32Array` | `(w + 1) * (h + 1)` height samples of the cell rectangle, row-major, assembled across regions with the shared edge samples (the higher region owns a shared edge, the last region owns the far edge). Empty if the rectangle leaves `cells_resolution()` or a region is unavailable. |
| `cell_mask_window(map: String, cell_rect: Rect2i) -> PackedByteArray` | `w * h` bytes (0 or 255) of a cell map: `holes`, `nav_exclusion` or `nav_<profile>` (`nav_profile_map(profile)` names it). Same emptiness rules. |
| `map_window_bytes(map, rect)` | The raw level-0 texels of any map over a rectangle in that map's own lattice units; the two above are built on it. |
| `get_height_at(index: Vector2i) -> float` | One sample by terrain lattice index. |
| `has_nav_profile`, `get_nav_profile_names`, `get_nav_profile_rule`, `get_nav_profile_mask`, `get_nav_profile_image` | as before; masks are assembled over `get_cell_resolution()`. |
| `has_macro()`, `sample_macro(position)`, `get_macro_image()`, `get_macro_bounds()`, `get_macro_binding()` | `sample_macro` reads the owning region (bilinear inside its apron); the image forms assemble the macro lattice and fail above 4097 per side. |
| `get_manifest() -> Dictionary` | byte counts (`region_bytes`, `total_bytes`, per-map `map_bytes`), grid, channels, profiles, `coarse_level`, `coarse_bytes` and per-map `coarse_maps` `{size, bytes}`; `payload_bytes()` is the planned region total plus the coarse maps. |

Renderer adapters keep working by assembling whole images from the regions: `create_height_image()`, `to_compiled_field()` (same shape as `StrataProcedural.compile_heightfield()`), `get_hole_image()`, `get_nav_exclusion_image()`. They return null or `{ok: false, message}` when a side exceeds 4097 samples or a region is unavailable.

`StrataCollision` and `StrataNavigation` read only these windows (`heights_window`, and `cell_mask_window` for `holes` and the profile's `nav_profile_map`), so chunk and tile sizes need not divide the region size. `holes` is the one remaining **transitional** whole-lattice property (assembled once and cached; only `runtime_data_test` reads it); do not use it in new code. The whole-lattice `heights` property is gone.

`StrataRenderer.configure_runtime(source, data, materials)` without a residency builds the region set from the manifest and configures through `configure_regions()`: the spec (bounds, spacing, cells, apron) with the maps the shader reads (`height`, `material_ids`, `material_weights`, `holes`, `macro`), and `set_regions()` with every region of the grid. Material ids are validated against the pool size; a missing region or invalid ids make it return false with the previous renderer state kept.

### Coarse maps

The bake stitches one terrain-wide image per map of the spec (nav profile maps and retained channels included, not only the maps the shader reads) from the regions' level-`coarse_level` cores with `StrataRegions.coarse_placement()` (`StrataBake.stitch_coarse()`). Regions are placed in row-major order, so the sample row or column a region shares with its east and south neighbours comes from the region that owns it, and the last row and column of the terrain from the last regions; every coarse texel therefore equals the matching texel of its owning region byte for byte (`region_coarse_test`). `coarse_level` is `StrataRegions.coarse_level(spec, coarse_max_side)`: the smallest level whose coarse height map has at most `coarse_max_side` (default 1024) cells per axis. The island (4 km at 1 m) gets level 2 (1025 x 1025 height, about 13 MB for all maps).

`coarse_image(name) -> Image` returns a copy (null when absent or malformed), `has_coarse_maps()` and `coarse_bytes()` summarise them. `validate()` checks every entry against the spec (map exists, `PackedByteArray`, exact size for its format, `coarse_level < mip_levels`). A manifest that holds coarse maps but no regions validates; `is_resident()` stays false for it, because it only describes a region source (embedded regions or a directory). The renderer's residency path (`configure_runtime(..., residency)`) binds only the coarse maps and never calls `get_region()`; the eager path, collision and navigation still need regions. `duplicate_runtime()`, `export_runtime()` and `save_runtime_scene()` carry the maps, so an exported scene streams.

The bake raises `mip_levels` to `max(options.mip_levels, far_level + 1, coarse_level + 1)` (`far_level` option, default 2; `coarse_max_side` option), so a default bake always carries levels 0..2. The report lists `coarse_level` and `coarse_sizes`.

### Partial regions

`StrataRegionData.first_level` (default 0) marks a partial region: levels below it are absent and `maps[name].levels[i]` is level `first_level + i` (only code that reads `levels` directly sees the shift). Every accessor takes the real level: `level_bytes` is empty and `get_image` null below `first_level`, `set_image` refuses it, `has_level(name, level)` says whether a level is held, `payload_bytes()` counts what is held, and `validate()` checks each held level's size and that `first_level + held` does not pass the map's deepest level. `level_count(name)` is the highest held level + 1, so it equals the full region's count and `level_count > far_level` still means the level can exist. `partial_copy(level)` builds the lod region (null if some map does not reach `level`). The renderer needs no change: `_region_problem` uses `validate()`, `has_map` and `level_count(name) >= 1`, and `_bind_region` reads `get_image(name, level)` for the tier's level only (`runtime_loading_test` asserts those predicates on lod data). Embedded regions must be full.

### Region loading

External regions (`region_directory`, no embedded regions) are read through `StrataRuntimeData`, which owns the cache:

| Method | Behaviour |
| --- | --- |
| `get_region(xy, min_level = 0)` | synchronous: embedded, cached, or loaded now (a pending threaded load is completed with `load_threaded_get`, then the full file is loaded if the pending one was partial and level 0 is asked); a cached region satisfies the request when its `first_level <= min_level`; validated against the manifest, failures reported once and remembered |
| `request_region(xy, min_level = 0) -> bool` | reads `region_path(xy, min_level)` (the lod file when `min_level >= lod_level` and it exists, otherwise the full file); starts `ResourceLoader.load_threaded_request(path, "", false, CACHE_MODE_IGNORE)`; false (nothing started) when the region is embedded, cached with enough levels, pending (either kind: ask again after it arrives), known missing, outside the grid or has no file (reported once). The type hint is empty because the loaders do not resolve script class names as hints |
| `poll_regions() -> Array[Vector2i]` | never blocks: moves finished loads through the same validation as `get_region` into the cache and returns the indices whose cached region is new or was replaced by fuller data; a failed or malformed load is reported once and marked missing |
| `is_region_pending(xy)`, `pending_count()`, `is_region_missing(xy)`, `has_cached_region(xy, min_level = 0)`, `cached_first_level(xy)` | state queries; `is_region_pending` is true for either kind; `has_cached_region` is true when `get_region(xy, min_level)` would not touch the disk (embedded, or cached with `first_level <= min_level`); `cached_first_level` is 0 full, `lod_level` partial, -1 not cached |
| `evict_region(xy) -> bool` | drops a cached external region; embedded regions stay |
| `cached_region_keys()`, `cache_bytes()` | the cache (embedded regions excluded) and the bytes of its maps |
| `clear_region_cache()` | forgets cached regions and failures |

The cache keeps the fullest data per region: a lod region is replaced when level 0 is loaded, a full one is never replaced by lod data. Every accessor (`heights_window`, `sample_height`, `cell_mask_window`, nav maps, `load_all_regions`) asks for level 0, so they load the full file and replace lod data; they share the cache with the streamer. Streamer: the far tier requests `request_region(xy, far_level)` and binds lod data; a promotion requests level 0 and keeps the far binding until the full region arrives; a demotion keeps the cached full data and rebinds it at the far level without a reload; leaving both tiers evicts. `stats()` adds `lod_loaded` and `full_loaded`.

### Region streamer

`StrataRegionStreamer` (Node, `strata_region_streamer.gd`) is the residency policy. Set `renderer` (a `StrataRenderer`, or any node with the same four methods), `data` and `camera`, call `start(source, materials)` and let it run: `_process` updates when the camera moved `camera_step` (default a quarter region), or while loads and binds are outstanding. `update(camera_local_xz)` is the public step used by tests; `stats()` returns `{near, far, pending, cached, lod_loaded, full_loaded, near_slots, far_slots, loads, evictions}`; `stop()` releases every region (the renderer keeps its coarse tier).

| Property | Default | Meaning |
| --- | --- | --- |
| `near_radius`, `far_radius` | 0 = 2.5 and 8 region extents | metres from the camera to the closest point of the region rectangle |
| `near_slots`, `far_slots` | 25, 256 | layers per tier; the nearest regions win when more qualify |
| `far_level` | 2 | needs `data.mip_levels > far_level`; otherwise there is no far tier (`far_slots` 0 is passed to the renderer) |
| `loads_per_frame` | 2 | new threaded requests per update; in flight is capped at four times that |
| `hysteresis` | 1.25 | a bound region stays until it is this factor beyond its tier radius (still subject to the slot cap) |
| `camera_step` | 0 = extent / 4 | camera movement that triggers an update when nothing is outstanding |

Each update: poll finished loads; compute every region's tier (near if within `near_radius`, else far if within `far_radius`), cap each tier by taking the nearest; release regions that left both tiers (`renderer.release_region`) and evict them from the data cache; demote near regions that became far before anything is promoted (their near slots free first); bind cached regions with `renderer.set_region_level(xy, region, level)`; request uncached ones nearest first. Data reaches the renderer only through `poll_regions()` or from the embedded set, and `_process` never loads synchronously. A region that is neither bound nor wanted is evicted, so the cache holds about the bound regions plus loads in flight. Renderer API used: `configure_runtime(source, data, materials, {near_slots, far_slots, far_level})`, `set_region_level`, `release_region`, `free_slots`.

Budgets with the defaults (island): 25 near regions x 0.9 MB, 231 far regions x 56 KB, 13 MB coarse maps. `region_streamer_test` covers the policy against a recording stand-in renderer (tiers, caps, nearest first, hysteresis, eviction, `loads_per_frame`, poll-only arrival), `runtime_loading_test` the loading API and coarse validation.

### Canonical surface

Each cell `(x, z)` has corners `a=(x,z)`, `b=(x+1,z)`, `c=(x,z+1)` and `d=(x+1,z+1)`. It is split into triangles `(a, b, c)` and `(b, d, c)`. A probe with Godot 4.4.1 GodotPhysics confirmed this for `HeightMapShape3D`. The heightmap is centred on its sample grid and uses absolute heights. With heights `a=0, b=4, c=6, d=-3`, the cell centre hits `5.0 = (b + c) / 2`, while bilinear interpolation gives `1.75`.

CPU queries, collision and navigation source triangles all use this split. The native patch mesher uses the same diagonal.

### Region composition

`StrataRegions.compose_region(terrain, through_layer, xy, spec, options) -> {ok, message, region}` composes every map of the spec for one region. A region composed alone equals the matching window of a whole-terrain composition bit for bit, because each map is one native windowed composition: `compose_dense` with an index offset for samples (a negative first index is folded into the origin, since the offset must be >= 0; the lattice positions must then be exact doubles, which holds for power-of-two spacings), `compile_cell_mask` on the window's bounds for holes and exclusions, and the macro, material and channel planes through the same descriptors the editor uses. `region_compose_test.gd` proves it for height, ids, weights, holes, exclusions, macro, channels and coverage on a 64 m terrain with 16-cell regions.

- **Materials.** Every `editor_material_channels` plane is composed on the window and packed with `pack_material_weights_sparse`. Weights are quantized here to RGBA8: `round(w * 255)` per slot, the largest slot absorbs the remainder so assigned texels sum to 255, unassigned texels stay 0. The native pack also offers RGBA8 output (`weights_format`) and has no per-side cap beyond the 20 Mi sample budget.
- **Height extrema** come from the samples inside the terrain bounds, apron excluded.
- **Options.** `channels` (the custom channel maps to compose), `nav_profiles` (evaluated on the composed region), `sources` (whole-lattice height / holes / nav_exclusion overrides, sliced instead of composed), `mask_options` (hole and exclusion channel names, continuous channels, thresholds).

### Mips

`StrataRegions.build_mips(region, levels)` adds levels 1.. to every map, capped per map at `max_level + 1`. Level `l + 1` texel `u` sits where level `l` texel `2u - apron` sits, so the geometry formulas stay exact. Scalar sample maps (height, channels, coverage, macro) use a separable `[1 2 1] / 4` filter at that texel with clamped edges; cell maps take the maximum over the 2 x 2 cells they cover ("any"); `material_ids` keep the up to four heaviest ids over the 2 x 2 block starting at the centre texel and `material_weights` are renormalised from those sums to 255.

## Bake

```gdscript
var result := StrataBake.bake(terrain, {
    "spacing": 1.0,                       # bounds must divide exactly
    "region_cells": 256, "region_apron": 2,
    "mip_levels": 3,                      # levels per map, level 0 included; raised to far_level + 1 and coarse_level + 1
    "far_level": 2, "coarse_max_side": 1024,   # streamer far tier, coarse map size
    "cell_masks": true,                   # from layered hole/nav_exclusion channels
    # or explicit: "holes": hole_image, "nav_exclusions": exclusion_image,
    #   (w-1)x(h-1) L8/R8 (>=128) or RF (>=0.5)
    "channels": PackedStringArray(["mask"]),
    "channel_formats": {"mask": "rf"},    # rf (default), rh or l8 quantize 0..1
    "nav_profiles": [{"name": &"wet", "rule": {"channel": "mask", "min": 0.5}}],
    "allow_stale_procedural": false,
})
if not result.ok: push_warning(result.message)   # previous bake untouched
```

`compile()` prepares and validates everything. `bake()` calls `compile()` and publishes with `terrain.publish_runtime_data()` only on success. A failed bake leaves the previous `runtime_data`, revision and stale state unchanged. `compile()` returns the data with its regions embedded in memory; publishing with a storage directory writes them to files (see [Storage](#storage)).

What the bake does:

- Builds the spec (see *Compiled data*) and composes every region of the grid through the final layer with `StrataRegions.compose_region()`, including the requested channels and navigation profiles, then `build_mips()` per region.
- Navigation profiles are evaluated per region on the region's own height map, channel maps and `nav_exclusion` map (`StrataNavProfiles.apply_region()`); the apron gives every cell of the region its four corners, so a region's masks equal the matching cells of a whole-terrain evaluation. A profile named `exclusion` is rejected (its map would be `nav_exclusion`), as are channel names that start with `nav_`, end with `__coverage` or equal a standard map.
- `cell_masks` may be `true`, a compile-options dictionary (forwarded as `mask_options`), or a precompiled `compile_cell_masks()` result whose token must be current and cover the complete stack; it is then sliced instead of composed. Explicit `holes`/`nav_exclusions` are sliced the same way and are mutually exclusive with `cell_masks`.
- A precompiled `options.compiled` height field must carry a current token for the complete stack; its heights are sliced into the regions.
- The preview cutoff (`preview_through_layer`) is never used.
- `macro` is `"auto"` (when an enabled layer owns a macro channel), `true`, `false` or an options dictionary whose `spacing` (default 4 m) must be the bake spacing times a power of two. Precompiled macro results are rejected: the map composes per region.
- `material_ids` / `material_weights` options are no longer accepted as inputs. They are ignored and listed in `report.deprecated`; the material maps come from the stack's `editor_material_channels`.

### Directory bakes

`options.region_directory` (a `res://`, `user://` or absolute path; `StrataBake.bake()` fills it with `StrataStorage.regions_directory(terrain)` when the terrain has a storage directory, pass `""` to embed anyway; note that `terrain.storage_directory` itself must be `res://` or `user://`, while a direct `compile()` target may be absolute) switches the bake to batches:

1. The stack is captured once. For each `bake_batch` (default 32) consecutive regions: compose on the worker pool, build mips on the pool, record extrema, hole/exclusion/nav counts, stitch the coarse cores into the coarse images, write `region_<i>_<j>.res` and `.lod.res` (`ResourceSaver.FLAG_COMPRESS`, concurrently), drop the batch.
2. Files go to a staging directory `<directory>.baking`. After validation and the stack-signature recheck succeed they replace the target's `region_*.res` files (files of regions the grid no longer has go with them) and the staging directory is removed. A rejected bake (stack changed, validation failure, write error, budget) removes its staging directory and leaves the previous files untouched; nothing is published. `compile()` with a directory therefore already replaces the files on success, before `publish_runtime_data()` writes the manifest (`StrataStorage.save_runtime_data` writes only the manifest when no regions are embedded and keeps the directory attached).
3. The result's data has no embedded regions, `region_directory` set, coarse maps, extrema and `lod_level`. `report` adds `written_files`, `disk_bytes`, `batches`, `peak_regions_in_memory`, `lod_level` and `region_directory`.

Memory is bounded by the batch, not the grid: with 256-cell regions and the island's maps one region is about 1.3 MB with mips (height 272 KB, ids 272 KB, weights 272 KB, holes 68 KB, macro 36 KB, plus mips), so a batch of 32 is roughly 45 MB plus the workers' composition scratch; coarse maps (about 13 MB) and the extrema stay for the whole bake. Budgets: `max_directory_bytes` (default 64 GiB) caps the planned size (regions plus lod files, uncompressed), and `DirAccess.get_space_left()` of the target drive must cover it. The optional `progress` Callable gets `(done, total)` after each batch. `lod_level` (default 2, clamped to the deepest level every map has; an explicit value must be below `mip_levels` and within that depth) is validated before anything is written. Region files embed their own path, so two bakes into different directories are equal in content, not byte for byte; batch size does not change the content. `export_runtime()` / `save_runtime_scene()` embed from the full files (`load_all_regions()`), or keep pointing at the directory with `embed_regions = false`. `runtime_bake_test` covers the directory bake against an embedded bake of the same terrain.

What the bake rejects:

- Stale or uncooked procedural layers, outdated or preview-cutoff cell masks or heights. A reloaded scene marks every procedural cache stale until it is recooked. Pass `allow_stale_procedural` to bake cached results; the report lists them.
- A stack that changes while compiling.
- Bounds that are not a whole number of `spacing` intervals, invalid region cells, mip levels, channel names or profiles.
- Malformed masks.
- Embedded payloads above `max_runtime_bytes` (default and maximum 512 MiB; directory bakes are exempt). The budget is the planned bytes of all regions, all maps and all mips (`region_bytes * regions`), checked before any region is composed. This retained payload budget does not limit process peak memory during atomic compilation/export.

The report lists `regions`, `grid`, `mip_levels`, `coarse_level`, `coarse_sizes`, `hole_cells`, `nav_excluded_cells`, per-profile `blocked_cells` and `terms`, the macro report, `deprecated`, the manifest and `cpu_ms`.

### Stale tracking

`StrataTerrain3D` gains these members:

- `runtime_data`, `runtime_bake_stale`
- `is_runtime_bake_stale()`
- signals `runtime_data_changed` and `runtime_bake_stale_changed(stale)`

Layer edits, procedural commits, enable changes, composition changes, layer order and `base_bounds` all reach `queue_preview_update()`. Each one compares a cheap stack signature and marks the bake stale. Preview-cutoff and overlay settings are not part of the signature.

A scene saved with a fresh bake reloads fresh, because the bake and its layers are saved together (or, with a storage directory, loaded from their files). The terrain records a new signature baseline at `_ready`.

The signature also includes procedural stale state, producer identity and an
explicit intent revision. HEGo input/parameter changes advance that revision,
even when a previously accepted saved cache was already marked procedural-stale.
Status text refreshes and loading do not advance it. A deliberately accepted
cache therefore remains fresh until new authoring intent or data changes.

### Export

`StrataBake.export_runtime(terrain, {"collision": {...}, "navigation": {...}})` returns a new `Node3D`:

- It has the terrain's local transform.
- An independent copy of the data is in meta `strata_runtime_data`. With `share_data`, the meta references the published resource instead, which avoids a second large payload when the export is saved right away.
- `embed_regions` (default: true when the planned payload is below 64 MiB) puts clones of every region inside the data resource, so the export is one file. With `false` the copy keeps pointing at the terrain's `region_directory`, which must then ship with it; an in-memory bake without a storage directory cannot do that and the export fails.
- `Collision` and `Navigation` children are created with the given settings.

The authoring scene is not modified, and a stale bake cannot be exported. `save_runtime_scene(terrain, path, {"data_path": "res://…/terrain.res"})` packs the export and saves the data as an external resource (regions embedded as sub-resources when embedded).

## Storage

By default a terrain's data is saved inside its scene. Setting `StrataTerrain3D.storage_directory` to a project directory (for example `res://island/terrain`) moves it into one fixed file per piece, so cooks overwrite files in place and a saved terrain is a set of reviewable files rather than one large scene:

| Path | Holds |
| --- | --- |
| `<directory>/<layer>.res` | a hand layer's `StrataLayerData` |
| `<directory>/<layer>/<channel>.res` | one cooked channel of a procedural layer (`StrataFieldData`) |
| `<directory>/runtime_data.res` | the published bake's manifest |
| `<directory>/regions/region_<i>_<j>.res` | one `StrataRegionData` per region of the bake |

Layer names become snake_case file names. `StrataProcedural.commit_fields()` saves a procedural layer's fields there as part of the commit and removes files of channels the new result no longer has; a save failure keeps the publication in memory and marks the layer's status unsaved. `StrataTerrain3D.publish_runtime_data()` saves the bake: all region files first (all or nothing, through temporary files; files of regions the grid no longer has are removed), then the manifest, which afterwards loads its regions lazily from `regions/` (the published resource keeps them in memory). `StrataStorage.save_runtime_data(terrain, true)` embeds them in the manifest file instead. At load the manifest's `region_directory` is set to the terrain's current `regions/` folder, so a moved project still finds its files; a format 1 file is refused. Hand layers are saved by the terrain's **Save layers to storage** inspector button or `StrataStorage.save_all(terrain)`.

At `_ready`, a terrain with a storage directory fills every layer its scene saved nothing for from these files, so a second scene (the island's showcase) can share the same stack by naming the same directory and layers. Layers the scene does reference keep what the scene says. Every write goes to a temporary file (`<name>~.res`) first and is renamed into place, so a failed save leaves the previous file intact. With a storage directory set, `runtime_data`, `editor_control_ids` and `editor_control_weights` are no longer stored in the scene; `_ready` loads them from their files when present. The scene keeps referencing layer files by path, so it still needs saving after a cook; the commit marks it unsaved in the editor.

## Hole policy

- One final canonical cell mask drives the render cutout, collision and navigation. The threshold is `>= 0.5`.
- Navigation exclusions are a second canonical mask. They are solid for rendering and collision, and blocked only for navigation.
- Generic numeric channels are never clamped or thresholded.

Masks come from one of two sources:

- **Layered (`cell_masks`).** The native `compile_cell_masks()` reads categorical Hole/Solid Replace regions in the `hole` and `nav_exclusion` channels. Ownership is resolved before conservative any-overlap reduction, so an upper Solid restores a lower Hole and a narrow Hole is not averaged away. It never ORs raw layer masks. Its output is already canonical 0/255 bytes, which the bake stores without a script loop.
- **Explicit (`holes`, `nav_exclusions`).** A validated, externally authored mask.

## Collision

```gdscript
var collision: StrataCollision = runtime_root.get_node("Collision")
collision.prepare_around(player.global_position, 96.0)  # or prepare_region(local_rect)
# or: collision.track_target = collision.get_path_to(player)
```

Collision is built only from compiled heights and the canonical hole mask. Camera, render LOD and material displacement have no effect on it. Chunks default to 128 × 128 cells, which is 129² shared samples at 1 m.

How each chunk is built:

- An ordinary chunk is one `HeightMapShape3D`. For non-unit spacing, the shape is uniformly scaled and its heights are divided by the spacing.
- A chunk containing any hole cell is a `ConcavePolygonShape3D` with the same triangles and the hole cells' triangles omitted. Godot 4.4 does not document true heightmap holes, so heights are never lowered or set to NaN.
- Concave chunks carry a one-cell apron of the neighbours' solid cells. The tests found that rays exactly on a heightmap/concave seam leaked through a ~1e-6 m float32 crack at 37° yaw: 295 of 800 seam rays. With the apron, every such seam lies inside one shape, and the seam sweep has no leaks.

Residency and replacement:

- Residency is explicit and bounded by `max_resident_chunks`, which defaults to 64. Nothing is built until requested, and oversized requests are rejected without changing the resident set.
- A tracked gameplay target (`track_target`, not the camera) triggers one re-plan only when it enters a new chunk (`tick()`, called from `_physics_process`; public for tests). The resident set becomes the chunks overlapping the square of `track_radius` around the target, built synchronously on that tick. Chunks outside it are released (`evictions` in `get_stats()`).
- Eviction under budget: when that square needs more than `max_resident_chunks`, chunks are ranked by centre distance to the target, the target's own chunk first, and the farthest are left out. A fast target therefore never stands on an unprepared chunk, and a too-small budget degrades to the nearest chunks instead of rejecting. A target off the terrain is tracked at the nearest terrain point. Changing `track_radius`, `max_resident_chunks` or `track_target` re-plans on the next tick.
- Explicit `prepare_region()` / `prepare_around()` still reject, without changing the resident set, a request that needs more than the budget. Invalid/outside/nonfinite requests preserve the previous resident set. Programmatic chunk and budget values are checked; invalid assignments retain valid settings. A valid `chunk_cells` change clears shapes whose indexing depended on the old configuration.
- A failed tracked re-plan (for example an invalid transform) retries every tick and warns once. Builds read regions through level 0 only (`get_region(xy, 0)`).
- `get_stats()`: `resident_chunks`, `pending` (always 0: builds are synchronous), `evictions`, `last_prepare_ms`, `tracked`, plus build counters.
- `replace_data(next)` rebuilds all resident chunks before anything is swapped. On failure, the old data and its shapes stay.
- `clear()` frees every body. `collision_layer`, `collision_mask` and `physics_material` apply to every chunk.

## Navigation profiles

A profile map is a cell map named `nav_<profile>` in every region: one byte per cell, 255 = blocked; `default` is the `nav_exclusion` map itself and holes are never written into profile maps. `StrataBake` evaluates each rule in `strata_nav_profiles.gd` per region after the channels and masks, over channels retained in the bake only, so every map can be reproduced from the data: `StrataNavProfiles.evaluate_region(region, rule, channel_names)` returns the region's mask (cells + 2 * apron per axis), and the suites assert it equals the stored map bit for bit in every region. The rules are saved in `nav_profile_rules` as bytes (`var_to_bytes`), because `.tres` rounds floats and would drift the thresholds. `strata_nav_profiles.gd` is needed at runtime only to re-evaluate a rule, not to load or navigate. Each distinct term sets one bit per cell and a 256-entry table maps the bits to the mask; slope is the costly pass. A three-term rule over a 4 km terrain (256 regions of 256 cells) evaluated in about 0.8 s in the suite. Each profile adds one L8 cell map (with its mips) per region to the payload budget.

## Navigation

```gdscript
var navigation: StrataNavigation = runtime_root.get_node("Navigation")
navigation.agent_radius = 0.5; navigation.agent_max_slope = 45.0; navigation.agent_max_climb = 0.25
navigation.bake_region(Rect2(spawn_local - Vector2(64, 64), Vector2(128, 128)))
var result: Dictionary = await navigation.bake_finished   # with use_async = true
```

Tile source and baking:

- Each tile (default 64 cells, bounded by `max_tiles`) builds real `NavigationMeshSourceGeometryData3D.add_faces()` triangles from solid cells. Hole and exclusion cells contribute no faces.
- Tiles bake with `NavigationServer3D.bake_from_source_geometry_data[_async]`.
- Godot 4.4 trims `border_size` inward from `filter_baking_aabb`. Each tile therefore bakes padded geometry, with bounds grown by the border (agent radius plus three voxels), and the result is clipped exactly at the tile edge. Erosion is consistent across tiles, and adjacent tiles connect on the world map.

Validated settings:

- Navigation cell size defaults to the map's cell size.
- The cell size must be at most half the terrain spacing, so a one-cell mask cannot be filled.
- `tile_cells * spacing` must be a multiple of the cell size.
- Agent radius, height and climb are rounded to whole voxels the way Recast does it, and the effective values are reported.
- `edge_max_error` defaults to 1.0 and cannot exceed 1.0 for these padded tiles.
- Godot 4.4.1 map merging needs a fine merge rasterizer for the tested island
  and curved fixtures. Set `navigation/3d/merge_rasterizer_cell_scale=0.01` in
  the dedicated project, or call
  `NavigationServer3D.map_set_merge_rasterizer_cell_scale(map, 0.01)` on a map
  you own. Godot clamps smaller requests (such as 0.001) to 0.01. The addon
  never changes consumer map settings implicitly. `check_merge_conflicts`
  enables an optional per-polygon diagnostic; normal bakes avoid that overhead.

Tracking (`track_target`, `track_radius`, default 96 m):

- `tick()` runs from `_physics_process` (public for tests) and compares the target's tile with the tile of the last re-plan; standing still is one node lookup and a tile lookup. The wanted set is the tiles within `track_radius` of the target's tile rectangle, so every point of that tile has the full radius around it; the keep set is the same with `track_radius * 1.25`, which is the hysteresis.
- A re-plan releases resident tiles and drops in-flight bakes outside the keep set, then starts a bake for each wanted tile that is neither resident, in flight nor known empty, nearest first. Tracked bakes are per tile (they do not use `bake_region`'s all-or-nothing publication or its generation): each tile is published as its own async result arrives; `use_async = false` bakes and publishes inside the tick.
- Budget: `max_tiles` bounds resident plus in-flight tiles. When a nearer wanted tile needs room, the farthest resident or in-flight tile (by centre distance to the target; the target's tile never) is evicted (`evictions`); a wanted tile farther than everything held is skipped. Tiles released for leaving the keep set count in `releases`.
- A result is accepted only if its tile is still in flight with the same mesh and the epoch (bumped by `clear()`, settings changes and leaving the tree) is unchanged; otherwise it is counted in `discarded_results`. A tile with no walkable polygons is remembered as empty until it leaves the keep set, so it is not baked again. A settings change releases tiles of the old configuration at the next re-plan, since one map never mixes settings.
- Cost: a re-plan builds source faces (the tile plus a padded border, about 70 × 70 cells at 1 m) for each new tile on the main thread, about 1.2 ms per tile measured, and hands the bake to the navigation server's thread pool. The 1 km fixture in `physics_tracking_test.gd` measured about 10 ms per re-plan with up to 8 tiles starting and about 2 ms for a collision re-plan of up to 12 chunks (worst 10 ms).
- `get_stats()` adds `tracked`, `resident_tiles`, `pending_tiles`, `evictions`, `releases`, `replans`, `last_track_ms`. The island player tracks both nodes and restores their previous settings on exit; it leaves the navigation tiles resident.

Publishing of `bake_region()`:

- Async results are published together, only after every tile of the latest request has baked.
- A superseded request or a node leaving the tree discards its results.
- `clear()` or freeing the node removes all regions from the map.
- Live clear/data/tile/configuration changes cancel pending work and notify
  `bake_finished` waiters. Invalid settings retain the previous configuration.
  Agent/cell changes leave old regions visible until the next bake; a
  `keep_existing` bake rebuilds every retained tile with the new configuration.

## Tests

The runtime suites run in disposable projects through `demo/tests/runtime_test_runner.py`;
see [Testing](testing.md#runtime-suites). Collision and navigation tracking on a synthetic 1 km terrain: `physics_tracking_test.gd`. Single-fixture measurements on a Ryzen 7 5800X3D
with Godot 4.4.1: a 4097² 1 m bake took about 2.1 s, collision around the player (radius
96 m, 4 chunks) about 75 ms, and a 128 m navigation area (4 tiles) 170–380 ms. The 64 MiB
height payload retained +64.3 MiB RSS; Godot's static allocation counter shows +128 MiB
because 4.4 `CowData` rounds buffers up to a power of two.

## Known limitations

- **Render agreement.** Collision and navigation match the canonical surface. The compiled-field renderer and its CPU query use triangular height sampling; its finest patch vertices therefore agree with the physical lattice. Coarser LOD triangles, stitched-corner splits and material displacement remain visual-only differences. Legacy bilinear sampling differs from the triangle split by `(b + c - a - d) / 4` at a cell centre; the test fixture demonstrates a 0.5 m gap.
- **Outer perimeter.** Rays exactly on the terrain's outer perimeter can round outside the shape under a yawed float32 transform (8 of 32 in the test); a 1 mm inset always hits. Measured collision surface error is about 1e-4 m at ~150 m world coordinates.
- **Navigation map configuration.** Default merge scale 1.0 collapsed Recast vertices within one map cell and produced already-merged-edge errors. With effective scale 0.01 and edge error 1.0, the corrected 4km island cache produced 9 synchronized regions, zero intra/cross-tile conflicts and 1,242 successful cross-tile paths among 54 points. The cone/hole/exclusion regression also has zero merge conflicts. Other geometries still require their own navigation validation; successful Recast baking alone does not establish map synchronization or path connectivity.
- **Mask conversion cost.** Explicit masks that are not already canonical 0/255 bytes, including all RF images, are thresholded in GDScript, which is slow for a full 4096² mask (pass canonical L8 or use `cell_masks`). Navigation source triangles are also built in GDScript, which is fine per tile. Concave chunk faces are built in GDScript (16k cells per chunk).
- **Physics engines.** Only GodotPhysics3D was verified. Jolt's heightfield triangulation was not tested.
- **Async navigation.** Re-parenting the navigation node discards in-flight async bakes.

## Open native API proposals

`StrataProcedural.compile_cell_masks()` now provides the masks the bake reads through
`cell_masks`. Two proposals remain:

1. `compile_channel(terrain, channel, through_layer = null, spacing, options) -> {ok, image, coverage, min, max, token}`, the public form of the descriptor capture the bake mirrors from `compile_heightfield`.
2. Optionally, a native `build_terrain_faces(heights, width, cell_rect, holes, exclusions, origin, spacing) -> PackedVector3Array` for concave collision and navigation sources over large areas.

## Persisted render quality

`StrataTerrain3D.render_settings` is an editable `StrataRenderSettings` resource. High defaults to 64-cell patches, an 8 m minimum patch, split ratio 3 and a 1,024-patch budget; lower-cost and Ultra presets plus custom controls are available. The editor camera drives the same textured renderer used for runtime. Its screen-relative refinement responds to viewport size, perspective field of view/KEEP_WIDTH and orthographic zoom. These settings govern visual geometry only: the compiled heightfield, collision, navigation and ownership are unchanged. Hard LOD switches remain; the density heuristic is not a terrain error bound.

Runtime baking snapshots the quality/appearance resource into the compiled artifact, and `configure_runtime()` uses that saved copy. Resources with no render settings use the High default. Material physical UV/roughness/height competition stay in material resources; optional distance-dependent UV scaling and terrain macro tint/AO strength are in the render settings. See [Example: Bracken Isle](../strata/example_island.md) for the saved island.

Runtime render settings also retain the independent near-displacement geometry controls: enabled, desired vertex spacing (0.0625 m), shared detail radius (32 m), and extra patch budget (1,024). `configure_runtime()` requires the matching native `select_refined_patches` API when this feature and visual displacement are enabled. The base quality budget is preserved; refinement and 2:1 balancing spend only the separate extra budget, subject to a 4,096-leaf total cap. Effective spacing may be coarser under budget/depth constraints and is reported by the renderer. Turning off subdivision changes geometry density alone; the shared shader fade radius is unchanged. The Inspector exposes these as the terrain's *Near displacement geometry* render settings.
