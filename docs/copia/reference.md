# Copia reference

The store node, the source node and the three resource classes document their members in the inspector and in
Godot's built-in help. This page lists them in one place and says which properties need a build.
"Build" means the descriptor the native build reads changes, so the built cells that used the
object are stale; "load" means the value is applied when a cell loads and needs no build. The
native side is specified in `docs/development/copia_design.md`.

Scale, where a rule compares it, is the length of an instance's basis Y column.

## CopiaObject

The thing to instance. Points name it by resource path.

| Property | Type | Default | Meaning | Applies |
| --- | --- | --- | --- | --- |
| `mesh` | `Mesh` | none | The mesh to draw. | build when its bounds change, else load |
| `material_override` | `Material` | none | Replaces the mesh's materials on every surface. | load |
| `surface_materials` | `Array[Material]` | `[]` | Entry i replaces the material of surface i; null or missing keeps the mesh's own. Ignored when `material_override` is set. Single instances get per-surface override materials; batches draw a copy of the mesh carrying them (`get_surface_material_mesh()`), because Godot has no per-surface materials on a multimesh instance. | load |
| `render` | `CopiaRenderSettings` | none | Draw settings. Without one a default `CopiaRenderSettings` is used. | build when replaced |
| `physics` | `CopiaPhysicsSettings` | none | Collider settings. Without them there is no collider. | build when added, removed or replaced |
| `impostor_mesh` | `Mesh` | none | Drawn in the far grid. Without one there is no impostor. | build |
| `impostor_material` | `Material` | none | Material override of the impostor mesh. | load |
| `impostor_min_scale` | `float` | 0 | Instances below this scale get no impostor, and single instances below it keep their own range instead of swapping with the impostor batch. 0 gives every instance one when `impostor_mesh` is set. | build |
| `default_color` | `Color` | white | Instance colour of points that carry none. | build |
| `default_custom` | `Color` | (0, 0, 0, 0) | Instance custom data of points that carry none. | build |

Signals: `changed` for any change, including a change inside `render` or `physics`;
`build_inputs_changed` when a build input changes, including in `render` or `physics`. The
object connects to its sub-resources when they are assigned and disconnects the old ones.

Hooks, for games that extend the class. Each returns the property by default.

| Method | Returns |
| --- | --- |
| `_get_default_color()` | The colour used by `descriptor()`; default `default_color`. |
| `_get_default_custom()` | The custom data used by `descriptor()`; default `default_custom`. |
| `_get_surface_materials() -> Array[Material]` | The per-surface materials drawn; default `surface_materials`. Override to supply them at load (for example copies of the mesh's materials with a parameter set per object) without saving material files; cache what you create, since it is called whenever draw params are built. |
| `_get_draw_params()` | The values the drawer applies when it creates this object's instances: `render.draw_params()` plus `mesh` and `material_override` as `RID`s (empty when unset), `surface_materials` (`Array` of `RID`s; single instances only, empty in multimesh mode, where `mesh` is the copy from `get_surface_material_mesh()`) and `impostor_min_scale` (0 without an impostor mesh). |
| `_get_impostor_draw_params()` | The values applied to the object's impostor batches: `_get_draw_params()` with `impostor_mesh` and `impostor_material` as `mesh` and `material_override`, no surface materials, begin 0, end `render.impostor_range_end`, no fade, no low-LOD shadows. Override to change them (an impostor material made at load, impostor shadows off). |

An override that depends on state outside the object's properties is not noticed by the change
signals; call `emit_changed()` and `build_inputs_changed` yourself when that state changes.

Other methods:

| Method | Meaning |
| --- | --- |
| `descriptor(impostor_cell_size := 0.0) -> Dictionary` | The build descriptor, below. The store passes its own `impostor_cell_size`. |
| `static resolve(path) -> Resource` | Loads the resource at `path`. A path to a `Mesh` gives a temporary object with that mesh and default settings. Anything else, a missing file or an empty path gives `null`. Cached by path. The result is a `CopiaObject` (typed `Resource` so the script does not need the class cache). |
| `static clear_cache()` | Forgets the resolved objects. |
| `get_surface_material_mesh() -> Mesh` | `mesh` with the per-surface materials set on its own surfaces: a copy made once and kept until the mesh or the materials change (an `ArrayMesh` keeps its LODs, blend shapes and shadow mesh; another mesh becomes an `ArrayMesh` without LODs). `mesh` itself without per-surface materials or with `material_override`. Batches and `to_nodes()` draw it; it holds the vertex data a second time. |

## CopiaRenderSettings

How an object's instances are drawn. Variations of a thing share one resource.

| Property | Type | Default | Meaning | Applies |
| --- | --- | --- | --- | --- |
| `draw_mode` | `DrawMode` | `MULTIMESH` | `MULTIMESH`: one MultiMesh per batch cell. `INSTANCE`: one rendering instance per instance. | build |
| `visibility_range_begin` | `float` | 0 | Distance in metres at which instances start to be drawn. | load |
| `visibility_range_end` | `float` | 0 | Distance in metres at which they stop. 0 is unlimited. | load |
| `visibility_range_margin` | `float` | 0 | Hysteresis in metres on both limits. | load |
| `fade_mode` | `FadeMode` | `DISABLED` | `SELF` is Godot's visibility range fade. In Forward+ a fading instance is drawn in the transparent pass. Applies to `MULTIMESH` draw mode only; ignored with `INSTANCE`. | load |
| `shadow` | `Shadow` | `ON` | `ON`, `OFF`, or `LOW_LOD`: shadows drawn from the mesh's lowest LOD by a second, shadows-only instance. | load |
| `shadow_range` | `float` | 0 | Distance in metres within which shadows are drawn. 0 is unlimited. | load |
| `shadow_range_margin` | `float` | 0 | Hysteresis in metres on `shadow_range`: shadows turn on within `shadow_range` of a source with shadows and off only beyond `shadow_range` + this margin of every such source, so an object near the limit does not flicker. 0 switches exactly at `shadow_range`. Per instance for `INSTANCE`, per batch for `MULTIMESH`. | load |
| `lod_bias` | `float` | 1.0 | Multiplier on the distance at which LODs switch. | load |
| `batch_size` | `float` | 16.0 | Batch cell edge in metres. Must divide the store's cell size. | build |
| `extra_cull_margin` | `float` | 0 | Metres added to each batch's bounds when culling. | load |
| `layers` | render layers flags | 1 | Render layers the instances are drawn on. | load |
| `gi_mode` | `GeometryInstance3D.GIMode` | `GI_MODE_STATIC` | Global illumination mode. | load |
| `impostor_range_end` | `float` | 0 | Distance in metres beyond which the impostor is not drawn. 0 is unlimited. | load |
| `debug_view` | `DebugView` | `OFF` | Viewport debug view of the instances using these settings, in every store; overrides the store's `debug_view` unless `OFF`. See "Debug views". Shown in the inspector, never saved. | load |

The far grid's cell size is the store's `impostor_cell_size`, not a render setting.

Signals: `changed` on every set; `build_inputs_changed` only when `draw_mode` or `batch_size`
change.

`draw_params() -> Dictionary` returns what the drawer applies when it creates objects:

| Key | Value |
| --- | --- |
| `visibility_begin`, `visibility_end` | `visibility_range_begin`, `visibility_range_end` |
| `visibility_begin_margin`, `visibility_end_margin` | `visibility_range_margin` for both |
| `fade_mode` | `RenderingServer.VISIBILITY_RANGE_FADE_SELF` for `SELF` with `MULTIMESH`, else `..._DISABLED` |
| `cast_shadows` | `RenderingServer.SHADOW_CASTING_SETTING_ON` for `ON`, else `..._OFF` |
| `low_lod_shadows` | true for `LOW_LOD`: the drawer adds the shadows-only instance |
| `shadow_range`, `shadow_range_margin`, `lod_bias`, `layers`, `gi_mode`, `extra_cull_margin` | the properties |

## CopiaPhysicsSettings

The collider of an object. Objects can share one resource.

| Property | Type | Default | Meaning | Applies |
| --- | --- | --- | --- | --- |
| `kind` | `Kind` | `MESH_CONVEX` | Where the shapes come from, see below. | build when the settings start or stop producing a collider, else load |
| `simplify_hull` | `bool` | true | For `MESH_CONVEX`: Godot reduces the hull to a small number of points. Off keeps the hull of the whole mesh, often hundreds of points. The hull is always cleaned (duplicate and interior points removed). Changes shapes, not the build descriptor. | load |
| `shapes` | `Array[Shape3D]` | empty | The shapes for `SHAPES`. | as `kind` |
| `shape_transforms` | `Array[Transform3D]` | empty | Local transform of each shape, parallel to `shapes`. A missing entry is the identity. | load |
| `collision_layer` | flags | 1 | Physics layers the colliders are on. | load |
| `collision_mask` | flags | 1 | Physics layers they detect. | load |
| `min_scale` | `float` | 0 | Instances below this scale get no collider. 0 gives every instance one. | build |
| `distance` | `float` | 0 | Horizontal distance in metres from a store source with colliders within which colliders exist. 0 uses the store's `collider_distance`. | load |

Kinds:

| Kind | Shapes |
| --- | --- |
| `SHAPES` | The listed shapes, each with its transform. No collider when the list is empty. |
| `MESH_CONVEX` | The convex hull of the object's mesh, built once per mesh and cached (once per mesh and `simplify_hull` value). |
| `MESH_TRIMESH` | The mesh as a triangle mesh, built once per mesh and cached. |
| `FIT_BOX` | One box of the bounds' size, centred on the bounds. |
| `FIT_CAPSULE` | One capsule along Y: radius half the larger horizontal extent, height the vertical extent (at least twice the radius), centred on the bounds. |
| `FIT_SPHERE` | One sphere centred on the bounds, radius half the largest extent. |
| `FIT_CYLINDER` | One cylinder along Y: radius half the larger horizontal extent, height the vertical extent, centred on the bounds. |

Signals: `changed` on every set; `build_inputs_changed` when `min_scale` changes or `kind` or
`shapes` switch between producing a collider and not.

| Method | Meaning |
| --- | --- |
| `has_collider() -> bool` | False only for `SHAPES` without a shape. |
| `resolve_shapes(mesh) -> Array` | `[{shape: Shape3D, transform: Transform3D}]` for any kind. A pure function of the settings and the mesh. Mesh kinds and fitted kinds give an empty array without a mesh; `SHAPES` ignores the mesh. |
| `static clear_cache()` | Frees the cached mesh-derived shapes. |

The instance's scale applies to the shapes when the store creates the bodies.

## The build descriptor

`CopiaObject.descriptor()` returns the plain dictionary the build reads for an object.

| Key | Type | Value |
| --- | --- | --- |
| `draw` | `String` | `"multimesh"` or `"instance"`, from `render.draw_mode` |
| `mesh_aabb` | `AABB` | `mesh.get_aabb()`, or an empty AABB without a mesh |
| `batch_size` | `float` | `render.batch_size` |
| `default_color` | `Color` | `_get_default_color()` |
| `default_custom` | `Color` | `_get_default_custom()` |
| `collider` | `bool` | `physics` is set and `physics.has_collider()` |
| `collider_min_scale` | `float` | `physics.min_scale`, or 0 without physics settings |
| `impostor` | `bool` | `impostor_mesh` is set |
| `impostor_cell_size` | `float` | the argument (the store's `impostor_cell_size`) when `impostor` is true, else 0 |
| `impostor_min_scale` | `float` | `impostor_min_scale` |

There is no `hash` key: the design page says the build then uses the SHA-256 of these fields as
it reads them. Without `render`, the values of a default `CopiaRenderSettings` are used.

## CopiaStore3D

The node that owns a data directory, triggers builds and draws. Points and cells are in its
local space; ranges and margins are compared on the local XZ plane, so the node is meant to be
unscaled. It creates no child nodes and nothing it creates is saved with the scene.

| Property | Type | Default | Meaning |
| --- | --- | --- | --- |
| `data_directory` | `String` | empty | Directory of `sets/`, `cells/`, `far/` and `store.json`. |
| `cell_size` | `float` | 64.0 | Cell edge in metres. Changing it needs a full rebuild. |
| `impostor_cell_size` | `float` | 128.0 | Far cell edge in metres, a multiple of `cell_size`. A build input of every object with an impostor. |
| `target` | `NodePath` | empty | The node of the default source. Empty: the viewport's current `Camera3D` in a game, the editor's 3D viewport camera in the editor. |
| `use_default_source` | `bool` | true | Stream around the default source: `target` (or the current camera) with range scale 1, the store's `density`, colliders and shadows. Off: only `CopiaSource3D` nodes are streamed around, and `update_streaming(position)` and `load_now(position)` ignore their position. |
| `frame_budget_usec` | `int` | 500 | Main-thread microseconds per frame for creating and freeing server objects. Colliders take up to half first; the drawer gets the rest. The renderer adds its own work in the next frame (about five times the step on the reference machine), so pass about a sixth of the frame time you are willing to lose. |
| `load_margin` | `float` | 16.0 | Metres beyond an object's range at which its section is requested. |
| `unload_margin` | `float` | 32.0 | Metres beyond the range at which it is freed. Must exceed `load_margin`. |
| `update_interval` | `float` | 0.1 | Seconds between streaming updates. |
| `movement_threshold` | `float` | 1.0 | Metres a source must move on the local XZ plane, from where it was at the last evaluated update, before an update decides again what to load and free. An update where no source moved further and nothing else changed (no source setting, object, cell, directory, margin or loaded section) does nothing. The margins absorb the lag: with the default 16 m `load_margin` a section is still requested at least 15 m before its range is reached, and freeing waits for `unload_margin` (32 m) anyway. 0: every move is evaluated. |
| `density` | `float` | 1.0 | Fraction of each batch drawn, by keep value. |
| `collider_distance` | `float` | 50.0 | Collider distance for objects whose physics settings give none. 0: colliders follow the draw range. |
| `editor_preview` | `bool` | true | Stream around the editor camera. |
| `debug_view` | `CopiaRenderSettings.DebugView` | `OFF` | Viewport debug view of every object whose render settings' `debug_view` is `OFF`. See "Debug views". Applied to the live groups at once; shown in the inspector, never saved. |
| `watch_objects` | `bool` | editor: true, game: false | Not exported. Rebuild what an object change makes stale and check for stale cells when the node is ready. A tool script can set it before adding the node. |

Writing and building (editor and tool scripts). Each call first waits for a background build
and for the reads in flight, so the directory has one writer and no reader while it builds.

| Method | Does |
| --- | --- |
| `write(clears, points) -> Dictionary` | `CopiaSets.apply`, then builds the touched cells and refreshes the loaded ones. Returns `{ok, error, apply, build}`. Adds the written object paths to `store.json`. |
| `build(cells := [], force := false) -> Dictionary` | Builds the given cells (`Vector2i` or `stale_cells()` entries); empty builds every stale cell. |
| `rebuild_all() -> Dictionary` | Forced build of every cell with set files or a built file, and of every stale far cell. |
| `rebuild_all_cells() -> Array` | The cells `rebuild_all` builds, from the index files, for `build_async(cells, true)`. |
| `build_async(cells := [], force := false) -> bool` | The same build as `build(cells, force)` on the node's background build thread (the one object-change rebuilds use); empty `cells` builds the stale cells, found on that thread. Returns false and starts nothing when a background build already runs or there is no data directory. Emits `build_started` now and `build_finished(report)` once the result is applied, in a later frame (the node must be in the tree; a synchronous call such as `write` or `build` waits for it first). The node keeps streaming meanwhile but reads no file until the build is done. |
| `is_building() -> bool` | True while a background build (`build_async` or an object-change rebuild) runs. |
| `stale_cells() -> Array` | `CopiaBuild.stale_cells` with the descriptors of every known object. |
| `list_sets() -> PackedStringArray`, `remove_set(name) -> Dictionary` | `remove_set` returns `{cells, build}` and rebuilds the cells the set had content in. |
| `set_summary() -> Array` | `[{set, cells, instances}]`, one entry per set with points, sorted by name: the cells it has points in and its point count, from the sets index in one call (`CopiaSets.cell_points`); no per-cell file is opened. |
| `read_points(rect, sets := [], exclude := []) -> Dictionary` | `CopiaSets.read_points` on the store. |
| `descriptors() -> Dictionary` | `{object_path: descriptor}` for every known object path that resolves. |
| `get_last_build() -> Dictionary` | Result of the last background build: the `CopiaBuild.build_cells` result plus `stale` (the stale cells it computed when given none) and `usec` (its time on the build thread). |

Known object paths are those in `store.json` (every path `write` was given) and those of the
built cells read so far. The index exists because no native call lists the object paths of a
cell's set files without reading them. `store.json` is not a resource: add it to the export's
include filter, or a game learns the objects only from the built cells and reads every cell's
directory at start-up.

Object changes: `build_inputs_changed` of an object (with `watch_objects`) schedules a rebuild
0.5 s after the last change; it runs `stale_cells` and `build_cells` on a background thread
(with the `build_started` and `build_finished` signals), and the loaded cells it rewrote are
refreshed. `changed` applies the load-time values that changed (ranges, shadows, LOD bias,
layers, cull margin, materials, the impostor swap distance) to the live groups at once, with no
build: the node compares the object's draw params with the previous ones and passes only the keys
that differ, one `CopiaDrawer.set_groups_params` call per range scale, and the drawer makes only
the server calls those keys need. Changing `extra_cull_margin` on 100 groups of 50 single
instances took about 0.5 ms instead of 8.4 ms (see the design page, "`CopiaDrawer`"). A change of
the physics shapes, layers or mask reloads that object's colliders.

Streaming:

| Method | Does |
| --- | --- |
| `update_streaming(position: Vector3)` | Updates what is loaded with the default source at the global `position` and every `CopiaSource3D` at its current position. Tests can call it directly. |
| `update_streaming_all()` | The same with the default source at `target` (or the current camera; its last position when there is none). Called every `update_interval`, and in the frame after a source entered, left or changed. |
| `load_now(position: Vector3, timeout_sec := 10.0) -> Dictionary` | Blocks until everything streaming would load for a target at the global `position` exists: directories and draw, impostor and collider sections read, every group created and ready, impostors linked, with no frame budget. It runs the same code as `update_streaming` (same ranges and margins), waits for the worker reads on the main thread and steps the drawer and colliders with a very large budget until nothing is pending. Returns `{ok, error, groups, objects, instances, bodies, usec, timed_out}` (live groups, the drawer's rendering instances, the instances they draw at the current density, and collider bodies afterwards). `position` becomes the streaming position, so the next regular update unloads nothing it loaded; with a `target`, put the target there too. `ok` is false with `error` set and nothing created when the node is not in the world, not visible, has no data directory or does not stream (`editor_preview` off in the editor); it is also false with `timed_out` true when `timeout_sec` ran out (loading then continues in later frames). It stalls the calling frame: use it behind a loading screen. |
| `load_sources_now(timeout_sec := 10.0) -> Dictionary` | `load_now` for every source: blocks until the surroundings of the default source (at `target` or the current camera, when `use_default_source` is on) and of every enabled `CopiaSource3D` exist. Same result and failures as `load_now`. |
| `is_settled() -> bool` | True when no directory or section read is in flight, nothing is queued for creation or freeing in the drawer or the colliders, no group is being replaced, no rebuild is running and no source has changed since the last update. Covers every source. |
| `get_stats() -> Dictionary` | `cells_known`, `far_known`, `cells_cached`, `far_cached`, `groups`, `groups_by_kind`, `loading`, `directory_reads`, `tasks`, `replacing`, `building`, `rebuild_scheduled`, `pending` (0 when nothing is in flight, queued or being built), `step_usec` (last frame's steps), `excluded_rects` and `draw_overrides` (how many are set), `drawer` (the drawer's stats: `objects` are its `RenderingServer` instances, `instances` the instances they draw), `colliders`, `sources`: one entry per source of the last update, `{name ("default" or the node's name), node (null for the default source), position, range_scale, density, colliders, shadows, priority, groups: {draw, impostor, collider}}`, where `groups` counts the live groups that source needs (a group needed by several sources counts for each). |
| `get_loaded_groups() -> Array` | `[{object_path, cell, kind, group, requested_usec}]`, groups being replaced included. |
| `get_drawer()`, `get_colliders()` | The native owners while the node is in the world, for reading group info and RIDs. |
| `get_collider_info(body: RID) -> Dictionary` | `{object_path, cell, index}` of a collider body (a ray hit's `rid`); `index` counts the cell's collider section. `{}` for other bodies. A ray hit's `collider` is the store node itself (the bodies carry its instance id). |
| `set_excluded_rects(rects: Array[Rect2])`, `get_excluded_rects() -> Array[Rect2]` | Leaves out every cell and far cell whose centre lies in one of the rectangles (local X and Z, `Rect2.has_point`): no directory read, no section loaded, nothing drawn and no collider there, in the editor and in a game. Cells that become excluded are unloaded at the next update (in the frame after the call), cells that stop being excluded load again as streaming decides. Replaces the previous list; empty excludes nothing. Run-time state, not saved with the scene; `to_nodes` ignores it. An impostor batch belongs to its far cell: with rectangles that are not aligned to `impostor_cell_size`, a far cell that is not excluded still draws the far cards of the excluded cells inside it, from distance 0. The decision is native (`CopiaStreamer`): the rectangles are turned into cell sets once, so a lookup per cell costs the same for any number of rectangles. |
| `set_draw_override(object_path: String, params: Dictionary, impostor_params := {})` | Merges `params` into the object's draw params (the keys of `_get_draw_params()`, for example `extra_cull_margin`) and `impostor_params` into its impostor draw params, for the live groups at once and for every group created later. The object and its resources are not changed and nothing is built. Only the keys whose value differs reach the drawer (the same path as an object change), and an object change keeps the override. Replaces an earlier override of the object; empty dictionaries remove it. Run-time state, not saved; `to_nodes` uses the object's own params. |
| `clear_draw_override(object_path: String)`, `get_draw_override(object_path) -> Dictionary` | Removes the override (the groups take the object's params again); returns `{draw, impostor}` or `{}`. |
| `to_nodes(rect: Rect2) -> Node3D` | Plain `MultiMeshInstance3D` nodes for the built cells intersecting `rect`: one per batch of a multimesh object, one per object and cell for a single-instance object, named `<cell>/<object name>_<batch>` (the object name is the object's path relative to the longest directory common to all object paths in the result, extension dropped and `/` replaced by `_`: `a/fern_01.tres` and `b/fern_01.tres` give `a_fern_01` and `b_fern_01`), with the object's range, shadow, LOD and material settings. Returned, not added. Low-LOD shadows become shadows off; impostors are left out. Per-surface materials come with the mesh (`get_surface_material_mesh()`), since a `MultiMeshInstance3D` has no per-surface override. |

Signals, on the main thread: `streaming_settled()` each time `is_settled()` turns from false to
true (not every frame); `build_started()` and `build_finished(report)` around a background build; `group_added(info)` when a group is handed to the drawer or the
colliders (its objects are created by later frames), `group_removed(info)` when it is removed.
`info` is `{object_path, cell, kind, group, requested_usec}`; `kind` is `"draw"`, `"impostor"`
(`cell` is then the far cell) or `"collider"`.

How streaming works:

- The node streams around its *sources* (see "CopiaSource3D" below): the default source and the
  enabled `CopiaSource3D` nodes that apply to it. With only the default source this is the single
  target of earlier versions, with the same results.
- The node knows the cells from the file names in `cells/` and `far/`. A cell's directory is read
  on a worker thread the first time a source comes within the largest range of any known object
  (scaled by the source's `range_scale`; for a source with colliders, at least the largest
  collider distance) plus `load_margin`, and cached; a rebuild of the cell reads it again.
- For each cached cell and object, the horizontal distance from each source to the cell's square
  is compared with the object's `visibility_range_end` times that source's `range_scale`: when any
  source is within it plus `load_margin` the draw section is read on a worker thread and handed to
  the drawer; when no source is within it plus `unload_margin` the group is removed, also when
  there is no source at all (every source disabled, no default source). Impostors
  follow the render settings' `impostor_range_end` in the same way. Colliders follow the physics
  settings' `distance` (or `collider_distance`), unscaled, and only sources with `colliders` count:
  when the last source with colliders is disabled or loses them, the collider groups go.
- Creation order: a group's priority value is the smallest distance ÷ `priority` among the
  sources that need it (for a single source of priority 1, its distance); smaller values are
  created first.
- An object with `visibility_range_end` 0 is loaded in every cell, and every cell's directory is
  read; an impostor range of 0 loads every far cell at start-up. Both cost memory and server
  objects for the whole store, so give large stores finite ranges.
- Impostors: an object with an impostor mesh gets one group per far cell (one batch per cell
  inside it). A cell's draw group is linked to its batch with the swap distance
  `visibility_range_end`; the drawer then shows exactly one of the two. Removing a linked group
  is left to the drawer, which keeps the swap gap-free.
- A rebuilt cell is read again; an object's groups are replaced (the new group is created before
  the old one is removed) unless the cell's set inputs, the object's descriptor hash and its
  counts are unchanged.
- Hiding the node (`visible = false`, or a hidden parent) unloads everything, colliders included;
  showing it streams again from the next frame, with no call needed. Leaving the tree drops the
  native owners, which free every server object.
- Worker tasks only read files and hand their results to the main thread through a queue; the
  node waits for them when it leaves the world.
- The decision itself (which sections to request, keep or free, which directories to read, and
  the quality and creation priority of each group) is made by a native `CopiaStreamer` the node
  owns; the node resolves the objects, starts the reads and does the server work. An update
  costs a few microseconds when no source moved more than `movement_threshold`, and well under a
  millisecond when one did (see the design page, "CopiaStreamer"). `CopiaStreamer` is an
  internal helper of the node, not meant to be used on its own.

Configuration warnings: no or missing data directory, `unload_margin` not above `load_margin`,
`impostor_cell_size` not a multiple of `cell_size`, an object `batch_size` that does not divide
`cell_size`.

## CopiaSource3D

A place stores stream around, for games with several live views of the same world (a main camera
plus monitor or preview cameras elsewhere): its global position. Put it under a camera, or
anywhere a neighbourhood must exist. A `Node3D`.

| Property | Type | Default | Meaning |
| --- | --- | --- | --- |
| `enabled` | `bool` | true | Off: no store streams around it. |
| `store` | `NodePath` | empty | The `CopiaStore3D` it applies to. Empty: every store in the scene tree. |
| `range_scale` | `float` | 1.0 | Scales every object's range for this source (at least 0.01): the loading distances of draw and impostor sections and, where only sources with a smaller scale need a group, the group's visibility range end and impostor swap distance. Colliders are not scaled. |
| `density` | `float` | 1.0 | Share of the instances this source wants, as the store's `density`. |
| `colliders` | `bool` | true | Whether colliders are created around it. |
| `shadows` | `bool` | true | Whether objects with a `shadow_range` cast shadows while within it of this source. |
| `priority` | `float` | 1.0 | Creation order weight (at least 0.01): larger means its work is created earlier for the same distance. |

`applies_to(store) -> bool`: enabled, inside the tree, and `store` empty or naming that node.

Sources are in the scene-tree group `copia_sources` while inside the tree. A store reads that
group at each update, so it finds sources without scanning the tree. A source that enters,
leaves or changes a property makes every store update in its next frame; a moving source is
followed at the store's `update_interval`, as the default source is.

**The default source.** A store with `use_default_source` on has one more source: `target` (or
the current camera), with range scale 1, density 1 (the store's own `density`), colliders,
shadows and priority 1. With no `CopiaSource3D` everything behaves as it did with a single target.

**Rules.**

- Loading: an object's section in a cell is loaded when any enabled source is within the
  object's range × that source's `range_scale` + `load_margin` of the cell's square (horizontal
  distance), and freed when none is within range × scale + `unload_margin`, including when there
  is no enabled source at all. The same for impostor sections (impostor range × scale) and for
  colliders (only sources with `colliders`; distance unscaled), whose groups go when no source
  with colliders is left.
- Quality per group: the sources *needing* a group are those within range × scale +
  `unload_margin` of it (the ones that keep it loaded). Its density is the store's `density` ×
  the largest `density` among them; its visibility range end (draw and impostor groups, ranges
  other than 0) is the object's range × the largest `range_scale` among them, and a linked draw
  group's impostor swap distance follows the same scale. A group loaded only for a half-range
  preview is therefore culled at half range instead of popping at the edge of what is loaded;
  when a full-range source also needs it, the full range applies. The values change on the live
  group when the needing sources change (at the next update); the group is not recreated.
- Shadows: a group's `shadow_range` is measured from every source with `shadows` on; an object
  starts casting when within its shadow range of any of them and stops when beyond shadow range +
  `shadow_range_margin` of all of them (in between it keeps its state). With no such source, no
  object with a shadow range casts. Objects without a shadow range always cast.
- Creation order: smallest distance ÷ `priority` among the needing sources first.

**What the renderer does per view.** The store's objects are ordinary `RenderingServer` instances
in the world, so every viewport's camera culls them, applies their visibility ranges (and the
impostor swap, which uses visibility parents) and picks mesh LODs from its own position and
screen size; `Viewport.mesh_lod_threshold` is a per-view LOD offset. Sources decide what exists,
not what each view draws.

**Limits.** The instances are shared by all views: a preview that looks at the same place as a
full-quality view gets full quality there, and the reduced range end of a group needed only by a
reduced source also applies to any other view that happens to see it. Values a game bakes into
instance data at build time (for example a fade distance in the instance colour read by a shader)
do not follow `range_scale`. Every separate neighbourhood is more memory, more server objects and
more creation work under the same `frame_budget_usec`.

## Debug views

`CopiaRenderSettings.debug_view` (the instances using that settings resource) and
`CopiaStore3D.debug_view` (every object of the store) colour what the drawer draws. An object
takes its settings' view unless that is `OFF`, else the store's. Both are editor and debug state:
the property is shown in the inspector but has no storage flag, so a `.tres` or a scene never
stores it and a game never ships one. Changing it emits `changed`, not `build_inputs_changed`:
the store re-applies the object's params to its live groups at once, with no build.

| View | Colours |
| --- | --- |
| `OFF` | Normal drawing. |
| `HIGHLIGHT` | Flat green, lit so shapes read, impostors included. |
| `BATCHES` | A random colour per MultiMesh batch (per object and batch cell); in `INSTANCE` draw mode a colour per instance. Impostor batches likewise, one per far cell. |
| `LOD` | The mesh LOD Godot draws: 0 green, 1 yellow, 2 orange, 3 red, 4 magenta, 5 and above purple. Impostors black. A mesh without LODs is green. |
| `SHADOW_RANGE` | What the drawer does with shadows: grey casts none (shadow off, no low-LOD shadows); red casts (no `shadow_range`, or within it); yellow in the hysteresis band (`shadow_range` to `shadow_range` + `shadow_range_margin`, where an object keeps the state it had); blue beyond. Measured to the camera drawing it rather than to the store's sources, and for a batch from the centre of its batch cell rather than its exact origin (see below), so a batch shows one state but near the boundary may show the wrong one. Impostors show their own shadow params. |
| `HIDDEN` | Every instance dim grey; instances drawn although nothing of their bounds can be seen show red and half transparent through whatever hides them, so dense hidden layers glow. |

How they work. The store applies the view in its params flow, after the object's
`_get_draw_params()` / `_get_impostor_draw_params()` hooks and its draw overrides: it replaces
`material_override` (and for `LOD` the `mesh`) and leaves every other value, so a subclass's own
material is replaced too and ranges, shadows and LOD bias stay as drawn. A material override wins
over per-surface materials, so single instances need nothing else. Materials are cached (per
shadow setting for `SHADOW_RANGE`, per mesh for `HIDDEN`) and released when no store uses the
view.

- `LOD`: no shader can read which LOD Godot chose, so the view draws a copy of the object's mesh
  made for it: per surface one copy of the vertices for the base and for each LOD, the level
  written into UV2.x, each LOD's indices moved to its own copy under the same edge lengths.
  Godot then selects exactly the LOD it would select for the real mesh, and the shader colours
  by UV2.x. The copy (no colours, bones, custom channels or blend shapes) is cached per mesh
  while any store uses the view. Godot picks one LOD per rendering instance, from its bounds:
  a whole MultiMesh batch switches LOD together, which the view shows as batch-sized patches.
- `BATCHES` and `SHADOW_RANGE` cannot tell which MultiMesh an instance belongs to: in a
  MultiMesh both `MODEL_MATRIX` and `NODE_POSITION_WORLD` include the instance's own transform.
  They find its batch the way the build forms batches, from the instance origin in store space:
  batch cell `floor(x / batch_size), floor(z / batch_size)`, or the far cell for an impostor.
  `BATCHES` hashes the cell and the object's path; `SHADOW_RANGE` measures from the cell centre
  at the instance's height, where the drawer measures from the centre of the batch's bounds, so
  its boundary is off by up to half a batch. Single instances use their own origin, exactly. A
  store that moves after the view is turned on keeps the old transform until the view is set
  again.
- `HIDDEN` tests each instance, not each pixel. A compositor effect runs before each viewport's
  transparent pass (the opaque depth is then complete; the Mobile renderer calls no post-opaque
  effect) and reduces its depth buffer to a farthest-depth pyramid (level 0 half the internal
  resolution, then halving to 1 x 1; depth is reversed, so farthest is the minimum). In the
  transparent pass of the same viewport a second material pass projects the instance's mesh
  bounds (with the MultiMesh instance transform) to a screen rectangle and its nearest depth,
  reads the pyramid at the level where the rectangle covers at most 2 x 2 texels, and marks the
  instance hidden when its nearest depth is farther than the farthest depth over the rectangle.
  Visible instances collapse to a point and cost no fragments. The test errs toward visible: an
  instance is marked hidden only when the whole of its bounds lies behind the opaque depth, so one
  whose bounds reach past an occluder's edge counts as visible even where its mesh does not, and
  bounds crossing the near plane count as visible. Its own surface cannot hide it (that surface
  is never nearer than its bounds), and a small depth tolerance keeps coplanar cases visible.
  With MSAA the resolved depth is read on Forward+; the Mobile renderer resolves no depth for
  effects, so with MSAA on Mobile every instance shows as visible. The effect is put on the
  compositor of each 3D editor viewport camera (in a game, the viewport camera of each store
  using the view) while some store uses the view, and taken off afterwards: a camera's own
  unsaved compositor gets it added, otherwise the camera gets a new compositor holding the
  effects it rendered with plus this one, and gets its previous one back afterwards. Saved
  compositors and the scene's `WorldEnvironment` are not changed in the editor, and a scene
  camera being previewed in the editor gets no effect (the view is then wrong in that viewport).
  Each frame the store checks that every camera's compositor still holds the effect and puts it
  back otherwise, so it coexists with other addons that rebuild a camera's compositor. Requires
  Forward+ or Mobile (compositor effects); the view does not work in the Compatibility renderer.
  Cost: one compute pass over the depth buffer per viewport and frame, a 32-bit pyramid texture
  sized for the largest viewport (about 22 MB at 4K), and per instance a vertex pass that projects
  eight corners and reads four texels. Multiview (XR) viewports use their first view only.

Limits. Every view replaces the material, so alpha-cutout foliage draws as solid cards and
vertex animation (wind) stops. The views are drawn with both faces. A low-LOD shadow twin takes
the view's material as well; it only draws shadows.

## Not written yet

The HEGo bridge. See `docs/development/copia_design.md`.
