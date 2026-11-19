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

**Holes in rendering** are cut in the vertex shader: a mesh vertex inside or on the edge of a
hole cell is dropped with every triangle that uses it, so a rendered hole covers all of its cells
and at most one vertex spacing more (`displacement_vertex_spacing` near the camera, wider in
distant LOD rings). The terrain shader has no `discard`, which keeps the depth prepass and shadow
passes on early depth testing; the vertex hole lookups run only while a loaded region or the
coarse hole map has a hole cell.

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
| material channel values | composition | a material channel is coverage: values below 0 count as 0 (a channel painted as a generic signed channel can be mapped later), relative values above 1 are normalized against the other channels; non-finite values fail the bake |
| `follow_terrain` | `StrataCollision`, `StrataNavigation` | use and follow the parent terrain's bake when `data` is empty (default on) |
| `track_target` / `track_targets` / `track_group` | `StrataCollision`, `StrataNavigation` | actors that need ground or navigation: one path, an array of paths, and a scene group whose Node3D members are tracked (re-scanned when the group size changes, and every 30 ticks); all are combined, duplicates and invalid paths skipped |
| `track_radius` / `look_ahead` | `StrataCollision`, `StrataNavigation` | metres kept around each actor (default 96); seconds of velocity added to an actor's planning point (default 0, velocity of a CharacterBody3D or RigidBody3D, else measured between ticks) |
| `auto_prepare` / `auto_bake` | `StrataCollision` / `StrataNavigation` | without any tracked actor, cover the whole terrain when it fits the chunk or tile budget, otherwise warn once (default on) |
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
| `StrataRuntimeData.sample_materials(position, interpolation)` | `{ok, status, ids, weights, channels, dominant, coverage}`: the blended material ids at a position, heaviest first, with their channel names from `material_channels`; `has_materials()` tests for the maps |
| `StrataTerrain3D.sample_runtime_materials(world_position)` | the same in world space, plus `materials` (the `StrataMaterial` of each id), `material` (the dominant one) and its `surface_type` |
| `StrataTerrain3D.runtime_surface_type(world_position)` | the dominant material's `surface_type` under a point, or empty |
| `StrataCollision.surface_type_at(world_position)` | the same through the collision body a ray or contact reported |
| `StrataMaterial.surface_type` | the material's gameplay tag (footsteps, impacts), the analogue of a physical material; rendering ignores it |
| `StrataMaterial.projection` | `TRIPLANAR` (default), `BIPLANAR`, `SIDES` (X and Z only) or `TOP` (Y only): the axes this material's textures project along |
| `StrataNavigation.profile` | the profile this node bakes; default `default`. A profile missing from the data is reported by the bake |
| `StrataNavigation.navigation_layers` | the layer bits of this node's regions; agents choose a population with them |

## World-space AO overlay

Optional contact shadows on the terrain from objects standing on it (ground cover, props,
plants), baked per square world tile and streamed around the camera. Off by default: a terrain
without an overlay node draws exactly as before (the shader tests one uniform bool).

**Renderer.** `StrataRenderer.set_ao_overlay(layers, table, origin, tile_size, settings)` binds a
`Texture2DArray` of single-channel occlusion maps (1 = unoccluded) and a lookup table (one R8
texel per world tile: layer + 1, 0 = no map). World XZ is split into tiles of `tile_size` metres
from `origin`. The terrain's AO is multiplied by `mix(1, overlay, ao_strength)` and its albedo by
`mix(1, overlay, albedo_strength)`, and its roughness moves towards 1 by
`(1 − overlay) × roughness_strength` (ground under cover is littered and sheltered, so it does not
share the open ground's sheen); the overlay fades to 1 between `fade_start` and `fade_end`
metres from the camera (defaults: AO 1, albedo 0, roughness 0, 40 to 60 m). `clear_ao_overlay()` turns it off;
it is runtime state and is not saved. Textures are updated in place to stream tiles.

**Baker.** `StrataAOOverlayBaker` rasterizes blobs on the GPU (a local `RenderingDevice` compute
pass; needs Forward+ or Mobile, not headless) from the instances of `MultiMeshInstance3D` nodes
(their MultiMesh transforms) and `MeshInstance3D` nodes. A blob sits at the mesh's AABB centre;
its radius is `radius` (metres at instance scale 1) or `footprint` × half the mesh's larger
horizontal AABB side, times the instance's horizontal scale, clamped to `max_radius`. Its
occlusion is `strength × (1 − d²/r²)²`; blobs multiply, down to `floor`. A source's rule comes,
first match wins, from its `strata_ao` metadata (on the node or its mesh: `{radius or footprint,
strength}`; strength 0 excludes it), from `rules[key]` with key = an optional `classify(node)`,
the mesh file's base name or path, else from `default` (or the node is skipped). `max_range`
keeps only sources whose visibility range ends within it.

Procedural sources can set `options.blob_source` (or the overlay node's
`blob_source`) to a `Callable(Rect2) -> PackedFloat32Array`. Return world-space
`[x, z, radius, strength]` groups whose centres belong to the supplied tile.
These samples use the same GPU splat, persistent edge files and neighbour
rebakes as mesh sources; `procedural_blobs` reports their count. The provider
owns shape sampling, contact tests and any density normalization. This is useful
for shader-deformed splines whose MultiMesh transforms are packed curve data.

**Tiles.** `bake_tile(layout, tile, roots, options)` writes `<directory>/tile_X_Z.res` (an R8
`Image`, mip 0, compressed; none when nothing is occluded) and `edges/tile_X_Z.f32` (the blobs
within `2 × max_radius` of the tile's edges). A tile owns the instances whose blob centre lies
in it and adds its neighbours' edge blobs; afterwards the `max_radius` band along the edges of
every neighbour that has an edge file is rebaked from those files, so seams agree in any bake
order. 2048² texels per 256 m tile (0.125 m) take 1-3 MB on disk.

**Node.** `StrataAOOverlay` (child of a `StrataTerrain3D`, or `terrain` set) streams the tiles
within `load_radius` of the camera on threads into `slots` array layers (mipmaps built on a
worker thread, one layer upload per frame, about 0.5 ms), frees those beyond `unload_radius`, and
binds every `StrataRenderer` child and the editor preview (`editor_preview`). With
`editor_from_layer` set to the stage the sources belong to, the editor preview draws the overlay
only while it shows that layer or a later one. Each slot costs
resolution² × 4/3 bytes of video memory (5.6 MB at 2048²). `rebake_tiles(tiles)` (and the
inspector button **Rebake tiles near the camera**) bakes from the nodes in `source_group`
(default `strata_ao_sources`; a group on a parent covers its subtree, hand-placed objects
included) and from source providers: nodes in the group `strata_ao_source_providers` with
`get_ao_overlay_sources(rect) -> Array` of nodes, for streamed or unloaded content (nodes outside
the scene tree are freed after the bake). `get_stats()` reports residency, uploads and memory.

## Surface cache

A sparse virtual texture of the evaluated terrain surface (`StrataSurfaceCache`,
`strata_surface_cache.gd`), filled on the GPU from the terrain material. The terrain can shade
from it, reads its near displacement relief from it instead of sampling four materials per
vertex, and shows surface writers through it. Other shaders read the ground below a point from
it (rocks, cliffs and props that blend into the terrain). Off by default
(`StrataRenderSettings.surface_cache_enabled`); needs Forward+ or Mobile.

**Layout.** The cache covers the whole terrain in a mip chain. Mip 0 has one cell per material
texel (`surface_cache_texels_per_metre`, default 128: 1/128 m) and each further mip doubles the
cell; cells are world-aligned at every mip. A mip is cut into pages of
`surface_cache_page_size`² cells (default 128). Only the pages something reads are kept, in a
pool of `surface_cache_pool_pages` slots (default 1024) laid out in atlas textures. A slot is a
page with a border of 4 cells of its neighbours on every side, so filtering and corner heights
never leave the slot. A page table (one R16 texture with a mip per page mip, one texel per
page) holds each resident page's slot. It may not exceed 4096 texels per side: a terrain wider
than 4096 pages of mip 0 needs larger pages or fewer texels per metre, and the cache says so
in its status and stays off. Memory is 17 bytes per cell, 0.31 MB per slot of a 128-cell page:
360 MB at the defaults, plus the page table (45 MB at 4096 pages per side).

| Atlas (2D array) | Per cell |
| --- | --- |
| albedo, RGBA8 | sRGB albedo after the terrain tint map; A: material AO × macro AO |
| normal, RGBA8 | octahedral unit normal (terrain-local, around +Y); B: roughness; A: metallic |
| height, R32F, two layers per atlas layer | at the cell corner: base height (−1e30 in holes), and the raw material relief before `displacement_strength` and the camera fade |
| cover, R8 | how much of the cell surface writers replaced (0 none) |

**Which pages are resident.** Three things request pages each frame:

- The screen. With `surface_cache_feedback` (default on) a compute pass after the opaque pass
  (`StrataVirtualTextureFeedback`, a `CompositorEffect`) reads the depth of one pixel per 8 × 8
  tile, a different one each frame, and reports the page under it at the two mips around its
  footprint plus `surface_cache_shading_lod_bias`. The depth holds every opaque surface, so a
  pixel requests pages only when it lies on or near the terrain: its height is compared with the
  cached ground height there, read from a deciding mip (cells of at most 0.5 m, never finer than
  the pixel's next mip) that the pixel always requests. Within about 1 m of the ground (more
  with distance and while only coarse heights are resident) it counts: a rock or a trunk base
  requests the ground it blends into, while canopies and the upper parts of trunks and props
  request nothing. On surfaces steeper than 60° the footprint is the pixel's extent in space
  rather than on the ground plane, which tends to zero there. `surface_cache_feedback` in the
  stats reports the sampled pixels rejected and those waiting for their deciding page. The renderer adds the effect to the compositor its
  camera renders with (the camera's, else the `WorldEnvironment`'s, created when there is
  none). In the editor each 3D viewport camera gets a compositor of its own with the scene's
  effects and the feedback, so nothing is written into the scene. With feedback off the pages
  around the camera are requested at every mip, whatever the view.
- The displaced mesh: the pages of the mip matching `displacement_vertex_spacing` around the
  camera, since vertices cannot wait for the screen.
- The coarsest mips, which stay resident while they hold at most 64 pages together. Every
  lookup ends there at the latest.

At most `surface_cache_page_fills_per_frame` pages (default 32) are evaluated per frame,
coarse mips first. A full pool evicts the pages requested longest ago, never those requested
within one feedback cycle (the 64 frames in which the sampled pixel visits its whole tile, plus
two for the readback; two frames with feedback off): a still view keeps its pages. When one frame requests more than 85 % of the pool, the cache raises the lod bias
of every lookup until the requests fit (`stats.pressure_bias`): the surface gets softer instead
of pages going missing. It falls back once requests drop below 60 %. A 4K view at lod bias 0
requests about 1,500 to 2,500 pages, a 1440p view about a third of that. Terrain edits
(heights, holes, controls, region changes, macro and coarse maps) mark the pages over the
edited rectangle stale; they keep their content until evaluated again.

**Surface writers.** Meshes with a writer material (`StrataSurfaceWriter`) are drawn top-down and
composited over the terrain material by the same fill. A page a writer touches waits for its
writer tile and is evaluated once, with the writers, so a road never appears a moment after
its ground. Writers show at every distance, in the coarse mips too. See "Surface writers" in
the addon's `README.md`.

The cache holds the material without custom fragment code, evaluated by the same functions as
the terrain shader (`terrain_surface_core.gdshaderinc`, which the compute fill splices into
GLSL), with texture bombing applied.

**Shading from the cache (off by default).** With `surface_cache_shading` the terrain takes
colour, normal, roughness, metallic and AO of ground up to `surface_cache_shading_max_slope`
(45°) from the cache instead of evaluating its materials, at the mip matching the pixel
footprint plus `surface_cache_shading_lod_bias`. `surface_cache_filter` sets how cells are
read:

| Filter | Reads |
| --- | --- |
| Nearest (default) | the nearest cell, two mips blended: the look of nearest-texel materials with mipmaps |
| Linear | bilinear in the nearest mip |
| Trilinear | bilinear, two mips blended |
| Anisotropic | the mip of the footprint's short axis, up to `surface_cache_anisotropy` (2, 4 or 8) times finer, sampled along the long axis; grazing ground stays sharp and requests up to that factor squared more pages there |

A page that is not resident yet falls back one mip; past that the pixel is shaded directly, as
are steeper ground (the top-down cells stretch there) and materials with custom fragment code.
The far UV blend follows the pixel footprint instead of the camera distance, so each mip holds
its share: a footprint counts as the distance at which flat ground seen from
`surface_cache_shading_eye_height` has it. `surface_cache_shading_debug` tints cached pixels
green and directly shaded ones red. Albedo is stored sRGB-encoded, so the bilinear filters
blend it in that encoding.

**Displacement.** With `surface_cache_displacement` (default on) the terrain shader reads near
relief from the mip whose cell matches `displacement_vertex_spacing` (bilinear between corner
heights), and evaluates the material directly where that page is not resident yet and beyond
the near UV distance.

**Parallax (prototype, off by default).** `parallax_mode` marches each near pixel's view ray
through the relief the displaced mesh does not carry: the relief of the mip matching the pixel
footprint minus the relief mip's, scaled by `parallax_strength`, inside a shell of
±`parallax_depth` metres around the mesh surface along the smooth normal. Smooth reads the
fine mip bilinearly; Columns reads it per cell (flat-topped columns whose walls show the
column's texel darkened by `parallax_wall_shade`). `parallax_min_level` sets the finest mip
read, `parallax_radius` the fade distance, `parallax_steps` the step limit (one step per cell
crossed, plus five to refine the hit) and `parallax_debug` shows hit height and walls (1) or
mip and step share (2). With displacement off the whole relief is marched. It moves only the
position the material is evaluated at: no depth is written, nothing is cast into shadow maps,
and readers of the cache see the mesh surface as before. Each step looks its page up in the
page table; where a page the ray crosses is not resident the ray sees flat ground. Each mip
holds the height maps point-sampled at mip 0, so on noisy scanned heights single texels stand
out as spikes and the residual also contains the mesh's own sampling error; a filtered relief
per mip would be needed before this is usable.

**Readers.** With `surface_cache_publish_globals` (default on) the cache is published as the
`strata_cache_*` global shader parameters. The Strata plugin brings the project's
`[shader_globals]` up to date when it loads (or call
`StrataSurfaceCache.register_project_globals()` and save the project settings); a shader using
them does not compile without them. Include
`res://addons/strata/shaders/strata_surface_cache.gdshaderinc` in any spatial shader:

```glsl
float footprint = strata_ground_footprint(world_position);   // uniform control flow
StrataGround ground;
if (strata_ground_sample(world_position, footprint, ground)) {
    float w = strata_ground_blend_weight(ground, world_position, world_normal, 0.3, 1.0);
    // mix albedo, normal, roughness, ao, specular toward ground.* by w
}
```

`strata_ground_sample()` takes the finest resident mip at or above the pixel footprint's and
returns the ground's linear albedo, AO, world normal, roughness, metallic, the terrain's
specular level and the rendered ground height. Inside the displacement radius that height
includes the relief as the terrain mesh shows it: read at the mip whose cells match
`displacement_vertex_spacing` (published in `strata_cache_surface.z`), interpolated between
those vertices, along the smooth terrain normal, with the terrain's distance fade. It returns
false outside the terrain, in holes, before a page holding the point is resident and while the
cache is disabled. Cells are read as the terrain filters them: the nearest cell with the
Nearest filter (texel-exact, matching pixel sampling), bilinear otherwise.
`strata_ground_blend_weight()` is 1 at and below the ground and fades to 0 at `band` metres
above it, reduced on faces turned away from the sky by `facing`. The cache reaches every
distance, so a blend needs no fade toward an edge; `strata_cache_edge_fade()` remains for
shaders written against the earlier clipmap and returns 1 while the cache is enabled.

The page lookup itself is `shaders/strata_virtual_texture.gdshaderinc`: define
`STRATA_VT_TABLE`, `STRATA_VT_PARAMS` and `STRATA_VT_LAYOUT` to your page table sampler and
the two parameter vectors, include it, and call `strata_vt_locate(position, mip, atlas)` or
`strata_vt_find(position, first_mip, atlas)`.

Parameters are sent only when they change (a global texture parameter dirties every material
using it). `StrataRenderer.get_stats().surface_cache` reports the status, the pages resident,
requested and missing, those waiting for a writer tile, the pressure bias, memory and the
cells filled in the last frame; `surface_cache_feedback` and `surface_writers` report the
feedback pass and the writer tiles. `get_surface_cache()` returns the cache.

**Cost** (RX 9070 XT, 2386 × 1200 editor viewport; a 4 km island level of a game using Strata,
128 cells per metre, 1,058 slots, lod bias 0):

- Evaluating a page costs 0.06 ms GPU (136² cells), a writer tile 0.04 ms GPU and 0.04 to
  0.1 ms CPU.
- A cold start over a road reached 631 resident pages in under 120 frames, 314 of them drawn
  with a writer tile.
- Flying 180 m at 0.75 m per frame: frame time 10.0 ms median and 13.9 ms at the 90th
  percentile, at most 32 pages missing at a time.
- The feedback pass and the page lookup did not show in the frame time: the same road view
  rendered in 4.1 ms GPU with the pages against 5.3 ms with the clipmap this cache replaced.
- Anisotropic at ratio 4 fitted the 1,058 slots with a pressure bias of 0.36; at ratio 8 the
  view requested 1,316 pages.

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
| AO overlay | 255 resident tiles (layers of one `Texture2DArray`), resolution a multiple of 4 |
| Baked tint and AO map | at most 4097 texels per side: the default 4 m spacing covers terrains up to 16 km, a larger terrain needs a coarser `macro` spacing |
| Bake | 512 MiB in total for all regions and their detail levels |
| Heightfield exchanged with Houdini | 128 Mi samples per volume (`StrataProcedural.MAX_TRANSPORT_FIELD_SAMPLES`; an 8193² lattice at 0.5 m is 67 M). One native dense call takes at most 20 Mi (`MAX_FIELD_SAMPLES`), so larger snapshots and results are composed, validated and imported in row bands (`StrataProcedural.row_bands`) |
| One input row | 64 Mi samples including companions; `terrain_max_samples` raises it to 512 Mi |
| One cook's result | 512 Mi samples including ownership companions |
| One Houdini exchange | 512 Mi samples and 64 volumes in total (the island's 1 m material pass moves 18 volumes of 4097² in and 8 out) |

Volumes from Houdini must be dense, scalar, single-slice heightfields with finite values on
a horizontal grid with perpendicular axes; sheared, tapered or multi-slice volumes are
rejected.
