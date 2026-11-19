# Getting started with Copia

This page takes you from an empty project to thousands of drawn instances with colliders, written
from GDScript. Nothing here needs Houdini; [Copia and Houdini](houdini.md) adds that on top. The
[reference](reference.md) lists every property.

## Requirements

- Godot 4.7 or newer.
- The Copia native library for your platform, in `addons/copia/bin`. The store node and the
  build need it. Copia ships Linux x86_64 and Windows x86_64 libraries; macOS is not supported.

## Install and enable

Copy the `addons/copia` folder, `bin` included, into your project's `addons/` folder (the
development channel also publishes it on its own branch, `copia-release-next`, which you can add
as a submodule at `addons/copia`), then enable
**Copia** under **Project Settings > Plugins**. The plugin adds a panel to the inspector of the
store node (see [the inspector panel](#the-inspector-panel)); the node and resource classes
work as soon as the files are in the project.

## Add a store

Add a **CopiaStore3D** node to a scene and set its `data_directory`. Points are in the node's
local space, so keep the node unscaled. Everything Copia generates goes into that directory:

```
<data directory>/
  sets/      the points you wrote, one file per set and cell (editor data)
  cells/     built cells, one file per cell (what the game reads)
  far/       built impostor cells
  store.json the object paths that were written
```

Use a `res://` folder for data that ships with the game, or `user://` for data made at run time
(the [demo](#the-demo-scene) does). The default `cell_size` is 64 m; change it before you write.
The node draws around the current camera; set `target` to follow another node (several cameras:
see [Several cameras](#several-cameras)). In the editor it
follows the editor's 3D camera, so what you write shows up in the viewport (turn that off with
`editor_preview`).

## Make an object

An object is what a point refers to. Create a **CopiaObject** resource (**New Resource** in the
inspector, or **Create New > Resource** in the FileSystem dock), save it as a `.tres` file and
give it a mesh. That is already enough: with no settings, the object is drawn in MultiMesh batches
of 16 m with no range limit and no collider.

The settings are resources of their own, so many objects can share one:

- **Render settings** (`CopiaRenderSettings`): `draw_mode` (`MULTIMESH` batches, or `INSTANCE` for
  few large things), `visibility_range_end` (how far away the object is drawn; always set it for
  large stores), `batch_size` (a divisor of the cell size), shadows, fade and LOD bias.
- **Physics settings** (`CopiaPhysicsSettings`): the collider's `kind` (the mesh's convex hull, simplified
  by default, or triangles, a fitted box, capsule, sphere or cylinder, or your own shapes), the layers,
  `min_scale` (smaller instances get no collider) and `distance` (how close the player must be).
  An object without physics settings has no collider.

Ground cover typically shares one render settings resource: batches of 16 m, a range of 40 m. Rocks
use bigger batches (32 m), a longer range and convex colliders. Trees are few and large: draw them
as single instances with a range of 150 m, give them an `impostor_mesh` (a simple quad or
low prism, drawn from the far grid) and an `impostor_range_end` of 2,000 m, and a capsule collider
with a `min_scale`.

A point names its object by resource path, for example `res://objects/rock.tres`. A path to a
`Mesh` also works and is drawn with default settings, which is the quickest first test. The
`demo/copia_demo/objects` folder has examples.

## Write points from GDScript

Points are given as per-point attribute arrays and converted with `CopiaPoints.from_attributes`;
`store.write` then stores them and builds the cells they touch.

```gdscript
extends Node3D

@onready var store: CopiaStore3D = $CopiaStore3D


func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	var count := 10000
	var positions := PackedVector3Array()
	var scales := PackedFloat32Array()
	var objects := PackedStringArray()
	positions.resize(count)
	scales.resize(count)
	objects.resize(count)
	for i in count:
		positions[i] = Vector3(rng.randf() * 256.0, 0.0, rng.randf() * 256.0)
		scales[i] = rng.randf_range(0.7, 1.3)
		objects[i] = "res://objects/rock.tres"
	var converted := CopiaPoints.from_attributes({
		"P": positions, "pscale": scales, "object": objects,
	})
	if converted.skipped_count > 0:
		push_warning("skipped: %s" % [converted.errors])
	var report := store.write([], converted.points)
	if not report.ok:
		push_error(report.error)
```

The attribute names are the ones in [the design page](../development/copia_design.md#point-attributes):
`P` (origin), `orient` or `N` and `up` (orientation), `scale` and `pscale`, `object`, `set`, `Cd`
(colour), `custom` (custom data) and `keep` (see [density](#density)). A point without a `set` is
in the set `default`. Pass an array with one set name per point to fill several sets in one call.

`write(clears, points)` returns `{ok, error, apply, build}`. It runs on the calling thread and
returns when the cells are built, so a large write is best done at start-up or in a tool; 300,000
points take under a second on the reference machine.

## Clear and rewrite

A set is a named input: whoever writes set `a` adds to set `a`. To replace the points of a set in
some cells, clear them in the same call:

```gdscript
var clears := [{"set": "rocks", "cell": Vector2i(2, 3)}, {"set": "rocks", "cell": Vector2i(3, 3)}]
store.write(clears, new_points)
```

Clears are applied first, then the points are added, and only the cells that changed are
rebuilt and, if they are drawn, replaced on screen without a gap. Other sets in the same cells are
untouched. `store.remove_set("rocks")` deletes a whole set, and `store.list_sets()` lists them.

## What the build does and when it runs

The set files are the source of truth. A *build* turns the set files of a cell into one built
cell: finished MultiMesh batches, single-instance transforms, collider transforms and impostor
batches. The running game reads built cells only.

- `write` builds the cells it touched.
- A change to an object that changes what is built (the mesh's bounds, the draw mode, the batch
  size, whether there is a collider or impostor, `min_scale` and the default colour or custom
  data) makes the cells that use it *stale*. In the editor the store rebuilds them half a second
  after the last change, on a background thread. In a running game it does not.
- `store.build()` builds the stale cells, `store.build(cells, true)` forces the given cells and
  `store.rebuild_all()` rebuilds everything. `store.stale_cells()` lists what is stale. These
  block until the build is done.
- `store.build_async(cells, force)` runs the same build on a background thread and returns at
  once (false when a build already runs). `build_started` and `build_finished(report)` say when
  it starts and ends, `is_building()` whether one runs; `store.build_async(store.rebuild_all_cells(),
  true)` rebuilds everything in the background. The store keeps drawing meanwhile and reads no
  file until the build is done.

Everything else (ranges, shadows, fade, materials, layers and collision shapes) is applied when a
cell loads and needs no build, so you can tune it with the game running. The
[reference](reference.md#what-a-change-costs) lists which properties are which.

## The inspector panel

With the plugin enabled, selecting a `CopiaStore3D` shows a panel above its properties:

- A line of totals: sets, set files, instances and stale cells. The first three come from the
  sets index (`store.set_summary()`) and are cheap. The stale count is computed only when you
  press **Refresh**, because it compares every built cell with its inputs.
- The sets, each with its cells and instances and a **Remove** button (after a confirmation).
- **Build stale cells**, **Rebuild all** and **Refresh**.

**Build stale cells** and **Rebuild all** run on the store's background build thread
(`build_async`), so the editor keeps responding. While a build runs (also one an object change
started) the buttons are disabled and the status line counts the seconds; afterwards it shows how
many cells were built, unchanged and deleted, and the time. Removing a set and **Refresh** run on
the main thread.

## Run-time behaviour

The store reads the cells around the target on worker threads and creates the rendering and
physics objects on the main thread, nearest first.

- **Ranges.** An object's section is requested when the target is within its
  `visibility_range_end` plus `load_margin` (16 m) of the cell, and freed beyond the range plus
  `unload_margin` (32 m). Keep `unload_margin` above `load_margin`. An object with no range is
  loaded in every cell, so give large stores finite ranges.
- **Frame budget.** `frame_budget_usec` (500 by default) is the main-thread time per frame given
  to creating and freeing objects. The renderer does more work of its own in the following frame,
  so choose about a sixth of the frame time you are willing to lose. A lower budget makes things
  appear later, not stall.
- **Density.** `density` (0 to 1) draws that fraction of each batch's instances, chosen by their
  `keep` value (highest first), so a lower density is stable and can be set at run time as a
  quality option. Write `keep` per point (random 0..1 works) if you want it to take effect.
- `update_interval` is the time between two checks of the target's position.
- **Shadow range.** A render setting's `shadow_range` limits shadows to objects within that
  distance of the camera. Give it a `shadow_range_margin` (a few metres) so an object near the
  limit does not flicker: shadows turn on within `shadow_range` and off only beyond
  `shadow_range + shadow_range_margin`.
- **Changing settings at run time.** Setting a render property (for example `extra_cull_margin`
  following the wind) passes only that value to the live groups, so it is cheap even with
  thousands of objects loaded: for 5,000 single instances in 100 groups the drawer's share was
  about 0.5 ms on the reference machine, against 8.4 ms when every value was applied again.

### Teleports and level start

When a game places the camera somewhere at once (level start, respawn, fast travel, a screenshot
tool), the first frames are drawn before the store's objects exist, because they are read on
worker threads and created over several frames. Renderer state that is built once on arrival,
SDFGI's cascades for example, then misses those objects and stays wrong until it is rebuilt.

- Behind a loading screen, call `store.load_now(position)` with the new camera position. It blocks
  until everything around `position` is created, with no frame budget, and returns
  `{ok, groups, objects, instances, bodies, usec, timed_out}` (`objects` are rendering instances,
  one per batch or single instance; `instances` the instances they draw). It stalls the calling frame, so do not call
  it during play. Give the store a `target` that is already at `position`, or the next regular
  update streams around the target instead.
- Without `load_now`, wait for the `streaming_settled` signal (or poll `is_settled()`) after the
  jump, then refresh the one-time renderer state.

### Several cameras

A game with several live views of the same world (the main camera plus a security monitor, a
picture-in-picture preview or a map camera in a `SubViewport` elsewhere) needs every view's
surroundings loaded. The renderer already does its part for each view: Copia's objects are
ordinary rendering instances in the world, so every viewport's camera culls them, applies their
visibility ranges and the impostor swap, and picks mesh LODs from its own position and screen
size. `Viewport.mesh_lod_threshold` lowers the LOD detail of one view, which suits a small preview.

What the store does not know is where the other cameras are. Add a **CopiaSource3D** under each
extra camera:

```gdscript
var source := CopiaSource3D.new()
source.density = 0.5       # half the instances, by keep value
source.range_scale = 0.5   # load, and draw, within half of every object's range
source.colliders = false   # nothing collides there
source.shadows = false     # shadow ranges are not measured from this camera
preview_camera.add_child(source)
```

The store keeps loaded whatever any source needs. A group needed only by reduced sources gets
their values (here: half density, culled at half range, impostors from half range on); a group
that a full-quality source also needs gets full quality, because the instances are shared by all
views. The main camera stays the store's default source (`target`, or the current camera); turn
`use_default_source` off to use explicit sources only.

Costs and caveats:

- Every separate view is another neighbourhood: more memory, more server objects, more creation
  work under the same `frame_budget_usec`, more main-thread time in each streaming update, and a
  renderer pass of its own every frame. Use reduced `density` and `range_scale` for small views.
- A view that cuts between places (a monitor switching cameras) is a teleport for its source:
  call `store.load_sources_now()` behind a cut, or keep showing the old picture until
  `streaming_settled`.
- SDFGI, directional shadow maps, the positional shadow atlas and similar renderer state are per
  viewport; each view pays for its own and builds its own after a cut.
- Values a game bakes into instance data at build time (a fade distance in the instance colour,
  for example) do not follow `range_scale`.

## Impostors and the swap

An object with an `impostor_mesh` is also drawn in the *far grid*, whose cells are
`impostor_cell_size` metres wide (128 by default, a multiple of `cell_size`). The impostor is
visible beyond the object's own `visibility_range_end` and up to `impostor_range_end`. The swap
between the object and its impostor is made by Godot's visibility parents, so at no distance are
both drawn or neither, however the streaming is delayed. Use a cheap mesh for the impostor, such
as a crossed pair of quads or a low prism with a flat colour, and `impostor_min_scale` to leave
small instances out.

## Colliders and ray hits

Objects with physics settings get one static body per instance within `distance` of the target
(or the store's `collider_distance`), created under the same frame budget. Instances below the
settings' `min_scale` get none. To find out what a ray or a contact hit, give the store the
body's RID:

```gdscript
var query := PhysicsRayQueryParameters3D.create(from, to)
var hit := get_world_3d().direct_space_state.intersect_ray(query)
if hit and hit.has("rid"):
	var info := store.get_collider_info(hit.rid)
	if not info.is_empty():
		print(info.object_path, " in cell ", info.cell, ", instance ", info.index)
```

`info.index` counts the instances of that cell's collider section for the object (those at or
above `min_scale`); read the same section's points with `store.read_points(rect)` to find the
instance. It is an empty dictionary for bodies that are not the store's.

## Plain nodes

`store.to_nodes(rect)` returns a `Node3D` holding ordinary `MultiMeshInstance3D` nodes for the
built cells that intersect `rect` (in local X and Z), one per batch of a multimesh object and one
per object and cell for single-instance objects. Use it to bake a region into a scene, or to
use the data with other tools. The nodes are not added to the tree, impostors are left out and
low-LOD shadows become plain shadow settings. Nodes are named `<cell>/<object name>_<batch>`,
where the object name is the object's path below the directory all objects share, without the
extension and with `/` as `_`, so two `fern_01` files in different folders stay distinct.

## Export a game

A game reads the built cells, the objects and the native library, not the set files:

- **Ship:** `cells/`, `far/` and `cells/index.copiaindex` (add `*.copiacell` and `*.copiaindex` to
  the export's include filter if you do not export all resources), `store.json` (also add it to
  the filter; it is not a resource, and without it the game reads every cell's directory at
  start-up to learn the objects), the object and settings `.tres` files and everything they
  reference (a path stored in a cell is not a reference the exporter can see, so add the objects
  folder to the filter), and the `addons/copia` folder with its library.
- **Leave out:** `sets/`, which is editor data. Exclude it with the filter `sets/*`.

Data generated at run time into `user://` is not part of an export. A store whose data is in
`res://` is read-only in an exported game, so run-time `write` needs a `user://` directory.

## The demo scene

`demo/copia_demo/copia_demo.tscn` needs no Houdini and adds nothing to the repository. On the
first run it generates about 300,000 points over a 512 m square in three sets (`ground`, `rocks`,
`trees`) into `user://copia_demo` and prints how long the write and the build took. Delete that
folder to generate again.

| Control | Does |
| --- | --- |
| W A S D, Q and E | Move, down and up |
| Shift | Move faster |
| Mouse (click to capture, Esc to release) | Look |
| R | Clear and rewrite the rocks in the cells around the camera with a new seed |
| F | Toggle the store's density between 1 and 0.5 |

Run it with `--autofly` after `--` on the command line to fly a scripted path for 20 seconds and
print the frame times. `--points=N` and `--dir=PATH` set the point count and the data
directory. The objects in `demo/copia_demo/objects` are good starting points for your own:
ground cover (three objects sharing one render settings resource), rocks (shared render and
convex physics settings) and trees (single instances, impostors, capsule colliders).
