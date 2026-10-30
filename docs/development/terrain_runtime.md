# Runtime bake, collision and navigation internals

How Strata compiles an authoring `StrataTerrain3D` layer stack into a versioned runtime resource, and how bounded static collision and tiled navigation for selected gameplay areas are built from it. The user-facing workflow is in [Getting started](../strata/getting_started.md). The runtime resource and its collision and navigation nodes use only built-in Godot types. A saved runtime scene loads, collides and navigates without the native terrain extension, the authoring scripts, HEGo or Houdini.

| File | Class | Depends on |
| --- | --- | --- |
| `demo/addons/strata/strata_runtime_data.gd` | `StrataRuntimeData` (Resource) | Godot only |
| `demo/addons/strata/strata_collision.gd` | `StrataCollision` (Node3D) | runtime data |
| `demo/addons/strata/strata_navigation.gd` | `StrataNavigation` (Node3D) | runtime data |
| `demo/addons/strata/strata_bake.gd` | `StrataBake` (static) | authoring layers, native compiler |

## Compiled data

`StrataRuntimeData` stores one terrain-local lattice:

- `bounds` (XZ) and `resolution` (samples, including both endpoints). Spacing must be uniform. Sample `(i, j)` lies at `bounds.position + spacing * (i, j)`. This matches the renderer's height texture.
- `heights`: signed float32 values, row-major, plus `height_min` and `height_max`.
- `holes` and `nav_exclusions`: canonical cell masks with `(width - 1) × (height - 1)` bytes. 0 is solid and 255 is masked. An empty array means no masked cells. `get_hole_image()` returns the same mask as an L8 `Image`.
- Explicitly retained custom channels on the height lattice: signed, unclamped `values` plus `coverage`. A coverage above 0 means the value is defined.
- Optional material controls (`material_ids` RGBA8, `material_weights` RGBAF), stored as validated.
- `format_version`, `bake_revision` and `get_manifest()`, which gives byte counts per payload.

Heights, channels, bounds and the height range are saved as raw bytes through storage-only properties. Godot 4.4 text resources write floats with about six significant digits. Without byte storage, a bake in a `.tres`/`.tscn` would silently drift from its collision and render data. The runtime suites check that payload SHA-256 hashes are bit-identical across `.res`, `.scn` and `.tres`. Text scenes still encode bytes as decimal lists, so keep large bakes in an external binary `.res`.

The runtime resource contains no layers, ownership, layer IDs, producer IDs or Houdini state.

Resident heights and custom values/coverage receive a finite-value scan at
ingestion/first validation. The native validator is used when available; a
runtime-only project uses a Godot fallback and still needs no extension. Scans
are cached, so collision residency requests do not repeatedly scan heights.
`validate_payload()` explicitly discards the cache and revalidates. Treat a
published runtime resource as immutable: assigning heights, channel dictionaries
or material images invalidates validation, while intentional in-place packed
array, dictionary or Image edits require `validate_payload()` before reuse.
Stored extrema must match the finite resident samples, and channel coverage
must stay in 0..1.

### Canonical surface

Each cell `(x, z)` has corners `a=(x,z)`, `b=(x+1,z)`, `c=(x,z+1)` and `d=(x+1,z+1)`. It is split into triangles `(a, b, c)` and `(b, d, c)`. A probe with Godot 4.4.1 GodotPhysics confirmed this for `HeightMapShape3D`. The heightmap is centred on its sample grid and uses absolute heights. With heights `a=0, b=4, c=6, d=-3`, the cell centre hits `5.0 = (b + c) / 2`, while bilinear interpolation gives `1.75`.

CPU queries, collision and navigation source triangles all use this split. The native patch mesher uses the same diagonal.

### Queries

Every query returns `{status, value}`. `Status` is one of:

- `OK`
- `OUTSIDE`
- `ABSENT`: the channel is unknown or has no coverage at that point.
- `NOT_RESIDENT`: the payload is missing or was evicted.
- `HOLE`

A defined zero is `OK`. Values for every other status are `NAN`. The query methods are:

- `sample_height(local, interpolation = TRIANGLE, ignore_holes = false)`
- `sample_heights(PackedVector2Array)` returns `values` and `status` arrays.
- `sample_height_world(world, terrain_transform)` and `sample_heights_world(...)` add the world surface `position`.
- `sample_channel(name, local)` interpolates coverage-weighted over defined corners only.
- `is_hole_at(local)`: a point is in a hole only if every cell touching it is a hole, so the solid side of a hole edge keeps its surface.
- `create_height_image()`, `get_hole_image()` and `to_compiled_field()` are renderer inputs. `to_compiled_field()` has the same shape as `StrataProcedural.compile_heightfield()`.

`StrataTerrain3D.sample_runtime_height()` and `sample_runtime_height_world()` query the published bake. None of these queries composes layers, reads the GPU or blocks on a load.

## Bake

```gdscript
var result := StrataBake.bake(terrain, {
    "spacing": 1.0,                       # bounds must divide exactly
    "cell_masks": true,                   # from layered hole/nav_exclusion channels
    # or explicit: "holes": hole_image, "nav_exclusions": exclusion_image,
    #   (w-1)x(h-1) L8/R8 (>=128) or RF (>=0.5)
    "channels": PackedStringArray(["mask"]),
    "material_ids": ids, "material_weights": weights,
    "allow_stale_procedural": false,
})
if not result.ok: push_warning(result.message)   # previous bake untouched
```

`compile()` prepares and validates everything. `bake()` calls `compile()` and publishes with `terrain.publish_runtime_data()` only on success. A failed bake leaves the previous `runtime_data`, revision and stale state unchanged.

What the bake reads:

- Heights come from `StrataProcedural.compile_heightfield(terrain, null, spacing)`: the complete enabled stack, composed natively.
- Retained channels use the native `StrataLayerData.compose_dense` descriptor contract.
- With `cell_masks`, holes and exclusions come from `StrataProcedural.compile_cell_masks(terrain, null, spacing)`. `cell_masks` may be `true`, a compile-options dictionary, or a precompiled result. The result's token must be current and cover the complete stack, the same check as for heights. Explicit `holes`/`nav_exclusions` and `cell_masks` are mutually exclusive.
- The preview cutoff (`preview_through_layer`) is never used. A precompiled `options.compiled` field must carry a current token for the complete stack, so a preview-cutoff or outdated compile is rejected.

What the bake rejects:

- Stale or uncooked procedural layers.
- Outdated or preview-cutoff cell masks. A reloaded scene marks every procedural cache stale until it is recooked. Pass `allow_stale_procedural` to bake cached results; the report lists them.
- A stack that changes while compiling.
- Bounds that are not a whole number of `spacing` intervals.
- Malformed masks or material controls.
- Aggregate payloads above `max_runtime_bytes` (default and maximum 512 MiB).
  Custom channel requests are deduplicated, and full-lattice value/coverage
  storage is budgeted before allocation. The height compiler's per-image sample
  cap also applies. This retained payload budget does not limit process peak
  memory during atomic compilation/export.

The bake uses actual extrema returned by native RF validation, including when
an externally supplied compiled dictionary contains incorrect finite min/max.

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
- `Collision` and `Navigation` children are created with the given settings.

The authoring scene is not modified, and a stale bake cannot be exported. `save_runtime_scene(terrain, path, {"data_path": "res://…/terrain.res"})` packs the export and saves the data as an external resource.

## Storage

By default a terrain's data is saved inside its scene. Setting `StrataTerrain3D.storage_directory` to a project directory (for example `res://island/terrain`) moves it into one fixed file per piece, so cooks overwrite files in place and a saved terrain is a set of reviewable files rather than one large scene:

| Path | Holds |
| --- | --- |
| `<directory>/<layer>.res` | a hand layer's `StrataLayerData` |
| `<directory>/<layer>/<channel>.res` | one cooked channel of a procedural layer (`StrataFieldData`) |
| `<directory>/runtime_data.res` | the published bake |
| `<directory>/material_ids.res`, `material_weights.res` | the terrain's editor control maps |

Layer names become snake_case file names. `StrataProcedural.commit_fields()` saves a procedural layer's fields there as part of the commit and removes files of channels the new result no longer has; a save failure keeps the publication in memory and marks the layer's status unsaved. `StrataTerrain3D.publish_runtime_data()` saves the bake, and the island's material binding saves the control maps. Hand layers are saved by the terrain's **Save layers to storage** inspector button or `StrataStorage.save_all(terrain)`.

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
- A tracked gameplay target (`track_target`, not the camera) triggers one rebuild only when it enters a new chunk.
- A failed tracked request retries at the unchanged target when a temporary
  budget failure is resolved. Invalid/outside/nonfinite requests preserve the
  previous resident set. Programmatic chunk and budget values are checked;
  invalid assignments retain valid settings. A valid `chunk_cells` change
  clears shapes whose indexing depended on the old configuration.
- `replace_data(next)` rebuilds all resident chunks before anything is swapped. On failure, the old data and its shapes stay.
- `clear()` frees every body. `collision_layer`, `collision_mask` and `physics_material` apply to every chunk.

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

Publishing:

- Async results are published together, only after every tile of the latest request has baked.
- A superseded request or a node leaving the tree discards its results.
- `clear()` or freeing the node removes all regions from the map.
- Live clear/data/tile/configuration changes cancel pending work and notify
  `bake_finished` waiters. Invalid settings retain the previous configuration.
  Agent/cell changes leave old regions visible until the next bake; a
  `keep_existing` bake rebuilds every retained tile with the new configuration.

## Tests

The runtime suites run in disposable projects through `demo/tests/runtime_test_runner.py`;
see [Testing](testing.md#runtime-suites). Single-fixture measurements on a Ryzen 7 5800X3D
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
