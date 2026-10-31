# Strata regions: plan

Status: approved 2026-10-31. Phase A (tracks F, N, R, D, C, E, H and X) landed on 2026-10-31; the island is recooked at 1 m. Phase B (residency) is next. This is the engineering plan for moving
Strata from whole-terrain maps to fixed-size regions. User-facing behaviour is described in
`docs/strata/` once each phase lands; this page is the contract the implementation tracks
build against.

## Why

Every composed map is one whole-terrain image today: height (`<= 4097²`), material controls
on their own 4 m lattice (`<= 1025²`, 20 bytes per texel), cell holes, macro tint, runtime
channels. The material lattice is a constant (`StrataMaterialControls.DEFAULT_SPACING`), so a
brush or a Houdini mask cannot place a feature narrower than about 4 m, and no single image
scales to the 8–16 km terrains at 0.5–1 m the project wants (16 km at 1 m is 256 M texels).
Terrain3D, Unreal Landscape and Unity all store control data at the height sample resolution,
tiled in regions or components, with 8-bit weights, streamed by distance. Strata adopts that
model.

## Decisions

- **Region**: a square of `cells` × `cells` cells at the terrain's `spacing` (1 m default),
  covering `cells × spacing` metres. `region_cells` 0 (the default) picks the largest power of
  two at or below min(256, side / spacing), at least 16, so small terrains get small regions. Region `(i, j)` starts at
  `bounds.position + (i, j) × cells × spacing`. The region grid covers `bounds`; regions may
  extend past the far edge, where samples compose to the channel default.
- **Samples and aprons**: a sample map of a region holds `cells + 1` samples per axis
  (endpoint inclusive, sharing its edge row and column with the neighbour, like Unreal's
  `quads + 1`) plus an apron of `apron` extra samples on every side (default 2), so hardware
  bilinear filtering, central-difference normals and crease normals never read outside the
  region's own texture layer. A cell map (holes, navigation) holds `cells` cells plus the apron.
  A map may use a power-of-two `scale` divisor for coarser data (macro tint at scale 4) with
  its own apron in its own texels.
- **Formats**: no bitfields. `material_ids` RGBA8 (one material index per slot, 0–255),
  `material_weights` RGBA8 (normalized, the shader renormalizes), `height` RF (byte-exact
  bakes), `holes` and other cell masks L8, `macro` RGBAH, every other channel its own L8/RH/RF
  map chosen per channel. Baked navigation-profile masks are cell maps named `nav_<profile>`.
- **Region file**: `StrataRegionData`, a Resource of built-in types so runtime-only projects
  can load it. `maps[name] = {format, kind, scale, apron, levels: Array[PackedByteArray]}`;
  `levels[0]` is full resolution, further entries are mips the bake precomputes (filtered for
  scalars, majority for IDs, "any" for masks). Saved as `<storage>/regions/region_<i>_<j>.res`;
  small terrains and tests may embed regions in the manifest.
- **Manifest**: `StrataRuntimeData` becomes the manifest: bounds, spacing, cells, apron, grid,
  map specs, channel names, nav profile rules, render settings, height extrema (global and per
  region), bake revision, and either embedded regions or a region directory.
- **Residency** (Phase B): three tiers by camera distance, full regions, mip-reduced regions,
  and one terrain-wide coarse map for the horizon. The region table texture tells the shader
  which array layer and level a region has. Phase A keeps every region resident at level 0.
- **Composition**: a region composed alone must equal the matching window of a whole-terrain
  composition bit for bit (the native `compose_dense` window form guarantees this). A dab
  recomposes the windows of the regions it touches.
- **Unchanged**: the layer stack and manual-layer semantics, the brush (coverage painting on
  material channels), `StrataMaterial` and shader hooks, the renderer's quadtree patch LOD, the
  bake and export API shapes, navigation profile rules.

## Geometry (normative)

For region `(i, j)`, map with `scale s`, `apron a` (in that map's texels), level `l`:

- texels per cell axis: `n = cells / (s << l)`; sample map size `n + 1 + 2a`, cell map size
  `n + 2a`.
- texel `(u, v)` of a sample map is terrain-local
  `origin(i, j) + ((u - a), (v - a)) × spacing × (s << l)`; a cell texel covers the cell whose
  minimum corner is that position.
- composition window for a sample map in the map's lattice indices (lattice sample `0` at
  `bounds.position`): `first = (i, j) × n - a`, `size = n + 1 + 2a`.
- `StrataRegions` (GDScript, static) is the single implementation of these formulas; nothing
  else may compute region texel positions.

## Shader addressing

Uniforms: `region_origin` (bounds position), `region_extent` (cells × spacing), `region_grid`
(ivec2), `region_table` (RGBA8 texture, one texel per region: layer low byte, layer high byte,
level, flags; flag 1 = resident), and one `sampler2DArray` per map with its `scale` and
`apron`. Per fragment or vertex: `rel = pos − region_origin; r = floor(rel / region_extent);
local = rel − r × region_extent; texel = local / (spacing × scale) + apron`; look up the table
at `r`, sample layer `layer` at `(texel + 0.5) / size`. Height and controls are sampled in the
vertex stage too (displacement), so this is per vertex, which is cheap. Edge clamping happens
at the terrain edge only; within the apron every fetch is local. Phase A uses one array per map
at level 0; Phase B adds per-level arrays selected by the table's level byte.

## Phase A: regions without streaming

Tracks run in parallel against the foundation (`strata_regions.gd`, `strata_region_data.gd`,
this page). Every track keeps `scripts/run_tests.sh` green at its merge and adds tests.

| Track | Scope | Files |
| --- | --- | --- |
| F foundation | `StrataRegions` geometry, `StrataRegionData`, headless test | strata_regions.gd, strata_region_data.gd, tests/region_geometry_test.gd |
| N native | Per-channel tile value formats (FLOAT32, UNORM8, UNORM16) behind the existing float APIs; serialized format 2 with v1 load; lift the 1025 cap of the material packs and add RGBA8 weight output; window form of `pack_material_weights_sparse`; `compile_cell_mask` and `compose_dense` verified for arbitrary windows up to 20 M samples | terrain/src/*, demo/tests/terrain_bulk_test.gd, native_data_test.gd, docs/development/terrain_bulk.md |
| R renderer | Region texture arrays and table, shader addressing for height, controls, holes, macro; `set_regions(spec, regions)`, `update_region(xy, data)`, `update_region_window(xy, map, image, texel_origin)`; whole-image setters kept as transitional adapters that slice into regions; per-region height extrema for patch AABBs; CPU sampling and raycast on regions; GPU tests | strata_renderer.gd, shaders/*, demo/tests render tests |
| D data | Region composition `StrataRegions.compose_region(terrain, through_layer, xy, spec)`; `StrataRuntimeData` v2 manifest with embedded or external regions, accessors (`region(xy)`, height and channel sampling, cell windows); `StrataBake` composing every region including nav profiles and mips; `StrataStorage` region directory; roundtrip byte-exactness tests | strata_regions.gd (compose), strata_runtime_data.gd, strata_bake.gd, strata_storage.gd, strata_nav_profiles.gd, runtime tests |
| C consumers | `StrataCollision` and `StrataNavigation` reading region windows (chunk and tile sizes divide `cells`), runtime-only project script list | strata_collision.gd, strata_navigation.gd, tests/runtime_test_runner.py |
| E editor | Editor preview composing regions through the selected layer; dab path recomposing touched windows; material and macro lattices retired in favour of region maps; `region_spacing`/`region_cells` terrain properties replacing `editor_compile_spacing`; channel preview and ownership overlay unchanged | strata_editor_preview.gd, strata_terrain_3d.gd, strata_material_controls.gd, strata_macro.gd, plugin.gd |
| H Houdini and island | Material HDA accepts the terrain lattice (4097² at 1 m), `HEGoIslandMaterials.attach` uses the terrain spacing, island pack and binding write region maps instead of `material_ids.res`; erosion masks keep their spacing, tint keeps 4 m (macro scale 4); island recook; island tests | scripts/houdini/*, demo/island/*.gd, otls/, contract json |
| X cleanup | Remove the caps and constants (1025, 4 m, 4097 height texture), docs for users and development, memory of limits | docs/strata/*, docs/development/* |

Order: F first (done with this page); N, R, D in parallel; C after D's accessor API; E after R
and D; H after E; X last.

## Phase B: residency

Per-level texture arrays, the table's level byte, a residency manager (distance tiers, worker
thread loading, eviction, `max_resident_regions` below the GPU's array layer limit), the
terrain-wide coarse map, bake-time mips for every map. Editor composes resident regions only
and caches composed regions on disk by stack signature.

## Phase C: large worlds

Per-region collision and navigation bakes driven by residency, HAPI tile transfer for fields
larger than one dense image, island at 0.5 m, 8–16 km test terrain.

## Budgets

Island, 4 km at 1 m, 16 × 16 regions, apron 2: height 272 KB, ids 272 KB, weights 272 KB,
holes 68 KB, macro at scale 4 36 KB per region; about 235 MB GPU resident in Phase A, which is
the price of 1 m materials (today's 4 m maps are 90 MB). 16 km at 1 m is 4096 regions and
about 3 GB on disk; Phase B keeps roughly 150 MB resident.
