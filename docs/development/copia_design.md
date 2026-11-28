# Copia design

Copia is an instancing store for large worlds. Points that name a thing to draw are written into
it, a native build turns them into data the renderer can take as it is, and one node draws what
is near the camera through `RenderingServer`. It needs no Houdini. The HEGo bridge
(`addons/hego_copia`) writes cooked points into it and sends its content back to HDAs.

This page is the specification the implementation follows. Status: design, nothing released.

## Terms

| Term | Meaning |
| --- | --- |
| Store | A `CopiaStore3D` node with a data directory and a cell size. Points are in the node's local space. |
| Object | A `CopiaObject` resource: the thing to instance (mesh, render settings, physics settings, impostor). Points name it by resource path. A path to a `Mesh` is accepted and drawn with default settings. |
| Cell | A square of the store's grid on the local XZ plane, `cell_size` metres wide (default 64). Cell `(cx, cz)` covers `[cx * size, (cx + 1) * size)` on each axis; Y is unbounded. Its id is the string `"cx_cz"`. |
| Set | A named input of the store. The name is its only identity: whoever writes set `a` adds to set `a`. Names are snake_case and valid file names. A point without one is in `default`. |
| Set file | The points of one set in one cell. Editor data, the source of truth. |
| Built cell | One file per cell made from all of its set files: finished batches, single-instance transforms and collider transforms. The only data the running game reads. |
| Far cell | One built file per cell of the impostor grid, holding impostor batches only. |

## Division of work

- **Native (`copia/src`, `RefCounted` classes, no nodes):** set files, the build, reading built
  cells, the streaming decision (`CopiaStreamer`), creating and freeing `RenderingServer` and
  `PhysicsServer3D` objects.
- **GDScript (`addons/copia`):** the `CopiaStore3D` node, the resource classes, the editor
  integration. The node resolves resources and hands plain values to the native side, so native
  code never loads a resource.
- **Threads:** partitioning, sorting, compression and file writes run on `WorkerThreadPool`.
  Every `RenderingServer` and `PhysicsServer3D` call is made on the main thread, under a
  per-frame time budget.

## Data directory

```
<data directory>/
  sets/index.copiaindex
  sets/<set>/<cx>_<cz>.copiaset
  cells/index.copiaindex
  cells/<cx>_<cz>.copiacell
  far/<fx>_<fz>.copiacell
```

A file is written under a temporary name (`<name>.tmp`) in the same directory and renamed over
the old one. A set file with no points is deleted, and so is a set directory left without files;
a built cell with no content is deleted, and so is an index that would list nothing. File names
use the canonical decimal spelling of the cell coordinates (`-3_0`, never `-03_+0`); other files
in these directories are ignored. One directory has one writer at a time.

The two index files (see "Index files") summarise the files beside them, so that listing a
store's cells, sets and objects, finding stale cells and skipping unchanged cells never opens a
per-cell file. Opening a file costs about 0.2 ms on the reference machine (Windows) and barely
parallelises, so a store of 7,200 files took 8 to 10 s to compare file by file.

Every format is little-endian. A string is a `u32` byte length followed by UTF-8 bytes. A
SHA-256 is 32 raw bytes in a file and 64 lower-case hex digits in the API.

## Writing points

One call applies a batch of clears and points to a store:

```
CopiaSets.apply(directory, cell_size, clears, points) -> Dictionary
```

- `clears`: `[{set: String, cell: Vector2i}]`. Each empties that set in that cell.
- `points`: packed columns, one entry per point:

| Column | Type | Required | Meaning |
| --- | --- | --- | --- |
| `transform` | `PackedFloat32Array`, 12 per point | yes | basis columns x, y, z, then origin |
| `object` | `PackedInt32Array` | yes | index into `object_paths` |
| `object_paths` | `PackedStringArray` | yes | the table `object` indexes |
| `set` | `PackedInt32Array` | no | index into `set_names`; absent = all `default` |
| `set_names` | `PackedStringArray` | with `set` | the table `set` indexes |
| `color` | `PackedFloat32Array`, 4 per point | no | instance colour; absent = the object's default |
| `custom` | `PackedFloat32Array`, 4 per point | no | instance custom data; absent = the object's default |
| `keep` | `PackedFloat32Array` | no | density priority 0..1; absent = 1 |
| `extra` | `{name: packed array}` | no | pass-through columns (int32, float32 or 3 floats per point), returned to readers |

Column rules:

- `transform` values must be finite. A cell index must fit in an `i32`.
- `object` must index a non-empty path. Duplicate paths in `object_paths` are the same object.
- Set names are 1 to 64 characters of `a-z`, `0-9` and `_`, in `set_names` and in clears.
- `color` and `custom`: a point whose first component is NaN carries none (the object's default
  applies at build time); it is stored as a quiet NaN (`0x7FC00000`) in all four components, and
  readers get those NaNs back. Any other non-finite component is invalid. Columns are therefore
  given for all points or none of a call; NaN rows mark the points without.
- `keep` must be finite and is clamped to 0..1.
- `extra`: a `PackedInt32Array` (1 per point) is int32, a `PackedFloat32Array` with 1 or 3 per
  point is float32 of that width, a `PackedVector3Array` is float32 × 3. Names are 1 to 255
  bytes. Values are stored as given. A set file keeps the union of the extra columns written into
  it; points written without one of them read back zero in it. Writing a name that a file stores
  with another type or width is invalid.

Order of work: clears first, then points are added to the set file of the cell their origin
falls in (`floor(x / cell_size)`, `floor(z / cell_size)`, computed in double precision, so a point
on an edge belongs to the cell that starts there). Within one call a set file is read at most once
and written at most once. A file whose content after the call equals its content before (same
hash) is not rewritten.

Validation, and the reading and merging of every affected file, finish before anything is
written. Invalid input, a corrupt set file, or a file whose cell size differs from `cell_size`
rejects the whole call: nothing is written, clears included. An I/O error while writing leaves
every file complete (temporary file and rename) but the call partly applied, and is reported.

Result: `ok`, `error` (empty when ok), `written`, `deleted`, `unchanged` (paths relative to the
directory, such as `sets/default/0_-1.copiaset`), `cells` (the cells whose set files were written
or deleted, sorted) and `point_count`. A clear of a file that does not exist is not listed.

The same call updates `sets/index.copiaindex` after the files: the entries of the files it wrote,
found unchanged or deleted, then the reconciliation every index load does (see "Index files"). A
failed index write is reported like a failed file write.

**Canonical order.** Inside a set file, points are sorted by object path (UTF-8 byte order), then
by the bytes of their transform, then by the bytes of their other columns: colour, custom, keep,
then the extra columns in name order (a column the file does not store compares as its default).
The same points therefore give the same file and the same hash whatever order they arrived in.

**Parallelism.** Point validation and cell assignment run in 64 Ki-point chunks on worker
threads; points are then partitioned by set and cell, and each affected file is one task for
reading and merging and one for writing.

## Set file (`.copiaset`)

| Part | Content |
| --- | --- |
| Header (60 bytes) | magic `CPST`, format version (u32, 1), cell x and z (i32 × 2), cell size (f32), point count (u32), column flags (u32), SHA-256 of the canonical uncompressed content (32 bytes) |
| Object table | count (u32), then the paths as strings, sorted |
| Extra columns | count (u32), then per column in name order: name (string), element type (u8: 0 int32, 1 float32), width (u8: 1, or 3 for float32) |
| Sections | one per object, in table order: point count (u32), uncompressed size (u32), compressed size (u32), then the columns of its points as one Zstandard block |

Column flags: 1 colour, 2 custom, 4 keep. A flag is set when a point of the file carries that
column (a colour or custom row that is not NaN, a keep other than 1); without it the column is
not stored and reads as NaN rows or 1.

A section's uncompressed block holds its points' columns one after the other, in canonical
point order: transforms (12 × f32 per point, basis x, y, z, then origin), then colour (4 × f32)
and custom (4 × f32) and keep (f32) when flagged, then each extra column (width × 4 bytes per
point) in table order.

The hash covers the column flags (u32), the object table, the extra column table and, for each
section, its point count (u32) followed by its uncompressed block. It does not cover the cell or
the cell size, which the file name and header carry.

## Reading sets

All static, on `CopiaSets`; safe from worker threads.

| Call | Returns |
| --- | --- |
| `list_sets(directory)` | set names with at least one set file, sorted (from the directory names) |
| `list_cells(directory, set, verify = false)` | `[{cell, count, hash}]` from the sets index, sorted by cell |
| `list_objects(directory, cells = [], verify = false)` | the object paths of the set files of `cells` (`Vector2i`; every cell when empty), sorted, from the sets index |
| `cell_points(directory, cell_size, rect = Rect2(), sets = [], exclude = [], verify = false)` | one row per cell and set that holds points, from the sets index (see "Point attributes") |
| `read_points(directory, cell_size, rect, sets, exclude)` | the columns above for points whose origin is inside `rect` (a `Rect2` on XZ: `x` and `y` of the rectangle are local X and Z; start inclusive, end exclusive), plus `set`, `set_names` and `count` |
| `remove_set(directory, set)` | deletes a set and returns the cells it had content in; updates the sets index |
| `reindex(directory)` | rebuilds `sets/index.copiaindex` from every set file's header and object table; `{ok, error, files, unreadable}` |

`verify` re-reads every set file's header before answering and repairs the index (see "Index
files"). `read_points` opens the files it reads, so it takes no index.

`read_points` reads the sets named in `sets` (all when empty) minus those in `exclude`. Points are
ordered by set name, cell, then canonical order. `color`, `custom` and `keep` are present when a
file read stores them (NaN rows and 1 for points without), and `extra` holds the union of the
files' extra columns (zero where a file lacks one; a name stored with different types in two
sets keeps the first set's type and reads zero from the other, with a warning).

## Objects as the build sees them

The node resolves each object path once and passes the build a plain descriptor:

| Field | Meaning |
| --- | --- |
| `draw` | `multimesh` or `instance` |
| `mesh_aabb` | the mesh's bounds, for batch bounds |
| `batch_size` | batch cell in metres; a divisor of the cell size |
| `default_color`, `default_custom` | used where a point carries none |
| `collider`, `collider_min_scale` | whether instances get a collider, and the smallest scale that does |
| `impostor`, `impostor_cell_size`, `impostor_min_scale` | whether instances get an impostor, the far grid's cell size (a multiple of the cell size; the store node's `impostor_cell_size`, which it passes to `CopiaObject.descriptor()`), and the smallest scale that does |
| `impostor_batch_size` | impostor batch cell in metres: a divisor of the cell size and, for a multimesh object, a multiple of `batch_size`; 0 or absent is the cell size |
| `hash` | hash of everything above; a change makes the built cells that used it stale |

Types and defaults: `draw` `"multimesh"`; `mesh_aabb` an `AABB`, empty at the origin; `batch_size`
the cell size; `default_color` a `Color`, white; `default_custom` a `Color` or `Vector4`, zero;
`collider` false; `collider_min_scale` 0; `impostor` false; `impostor_cell_size` 0;
`impostor_min_scale` 0; `impostor_batch_size` 0 (the cell size); `hash` a `String` or `int`. When
`hash` is absent or empty, the build uses the SHA-256 of the fields above as the build reads
them; an `impostor_batch_size` equal to the cell size is left out of it, so the default keeps the
hash of builds made before the field existed. An object path that appears in the sets
but not in `objects` is built with all defaults (batch size = cell size, white colour, zero
custom, no collider, no impostor); the result lists it under `defaulted` and its directory entry
is marked.

The store has one far grid: every object with an impostor must give the same
`impostor_cell_size`. A `batch_size` that does not divide the cell size, an `impostor_cell_size`
that is not a multiple of it, two far grid sizes, or an `impostor_batch_size` that does not divide
the cell size (or, for a multimesh object, is not a multiple of its `batch_size`) reject the call.

An instance's scale, where a rule compares it, is the length of its basis Y column.

Ranges, shadow modes, LOD bias, materials and collision shapes are not build inputs. The node
applies them when it creates the objects, so changing one needs no build.

## The build

```
CopiaBuild.build_cells(directory, cell_size, cells, objects) -> Dictionary
```

For each cell: read every set file of the cell, merge the points per object, and write the built
cell. The points of one object from all sets are put in canonical order (transform, colour,
custom, keep bytes); extra columns are not build inputs.

- **MultiMesh objects.** Instances are grouped by batch cell: batch `(floor(x / batch_size),
  floor(z / batch_size))` in store coordinates, clamped into the cell so a batch never crosses
  it. Batches are ordered by batch x, then z. Each batch gets its origin at the centre of its
  bounds (the union of `mesh_aabb` transformed by each instance), and its instances are ordered by
  `keep`, highest first, ties in canonical order. The instance buffer is written as `MultiMesh`
  expects it with colours and custom data enabled: 20 floats per instance, the 3 × 4 transform
  row by row (`basis.x.x, basis.y.x, basis.z.x, origin.x - batch origin.x`, then the y and z
  rows), then colour, then custom data, each from the point or the object's default. It is uploaded
  unchanged.
- **Single-instance objects.** Transforms in canonical order, in the set file's layout (basis x,
  y, z, origin; store coordinates).
- **Colliders.** For objects with `collider`: the transforms (same layout) of the instances whose
  scale is at least `collider_min_scale`, in canonical order. MultiMesh objects get them too.
- **Impostors.** For objects with `impostor`, the instances whose scale is at least
  `impostor_min_scale` form one impostor batch per object and cell (batch cell = the cell), or
  with a smaller `impostor_batch_size` one per non-empty impostor batch cell (batch cell in that
  grid: for a multimesh object the floor of its draw batch cell ÷ `impostor_batch_size /
  batch_size`, so a draw batch lies in one impostor batch; for single instances
  `floor(x / impostor_batch_size)` clamped into the cell), stored in the built cell as its own
  section and built like MultiMesh batches.
- **Far cells.** Far cell `(fx, fz)` covers cells `fx * n` to `fx * n + n - 1` on each axis, `n =
  impostor_cell_size / cell_size`. It is assembled from the impostor sections of the built cells
  inside it, their batches per object in cell order (x, then z), each keeping its batch cell; it
  reads no set file. A
  build of a cell rebuilds the far cell it lies in after all cells of the call are built.

A build of the same inputs is byte-identical: nothing in a file depends on time, thread order or
the machine. The Zstandard blocks use Godot's `PackedByteArray.compress`, so the bytes also depend
on the project's Zstandard settings (`compression/formats/zstd/*`); hashes cover uncompressed
content only. A rebuilt file whose bytes equal the file on disk is not rewritten. Cells, then far
cells, are built in parallel on `WorkerThreadPool`, one task per file.

`build_cells(directory, cell_size, cells, objects, force = false, verify = false)`: `cells` holds `Vector2i` cells, or the
dictionaries `stale_cells` returns (`{cell, kind}` with kind `"cell"` or `"far"`), so its result
can be passed in unchanged. A far entry rebuilds only that far cell (and deletes it when no object
has an impostor). Result: `ok`, `error`, `written`, `unchanged`, `deleted`, `skipped` (relative paths),
`defaulted`, `cell_count`, `far_count`, `instance_count`, `threads` and `profile` (wall time of the
cell and far passes, and per-phase microseconds summed over threads). A cell whose set files cannot
be read is reported and left as it was; the other cells are built.

The set files of a cell are those the sets index lists. The call updates `cells/index.copiaindex`
after the cell pass (so the far pass reads the new inputs from it) and again after the far pass:
the entries of the files it wrote, found byte-identical or deleted; a cell that failed keeps its
entry. A set file whose content hash differs from its index entry (changed outside Copia) gets
its sets index entry repaired. `verify` re-reads every header of both directories first.

**Skipping unchanged cells.** Unless `force` is true, a cell is not rebuilt when its built file
(same kind, cell and cell size) records exactly the current set files of the cell, compared by the
hashes in the sets index, and every recorded object's current descriptor hash, with the same draw
mode and "built without a descriptor" flag, all as the cells index records them. A far cell is not
rebuilt when its file records exactly the union of the inputs of the built cells inside it and one
of them has impostors (both from the cells index). The skip opens no file. Skipped files are
listed in `unchanged` and in `skipped`; their instances and defaulted objects are still counted.
`force` rebuilds and compares bytes as before, which is what a change of the project's Zstandard
settings needs.

**What triggers a build** (editor only): a write to the sets of a cell; a change of an object's
descriptor hash, for the cells whose built file lists that object; the store's "Rebuild all"; the
command-line entry. When the editor opens a level it compares each built cell's recorded input
hashes with the set files and descriptors and rebuilds what differs.

`stale_cells(directory, cell_size, objects, verify = false)` makes that comparison and returns
`[{cell, kind, reason}]`, cells first, each sorted. It loads the two indexes (which lists the
directories and reads only the headers of files an index lacks; with `verify`, every header, in
one parallel pass on `WorkerThreadPool`) and compares their entries:

| Reason | Cell | Far cell |
| --- | --- | --- |
| `missing` | set files but no built file | a built cell inside it has impostors, but there is no far file |
| `orphan` | a built file but no set files | a far file no built cell needs, or no object has an impostor |
| `sets` | its set files (names or hashes) differ from those recorded | the set files of the cells inside it differ from those recorded |
| `objects` | a recorded descriptor hash differs from the current one | the same, for the objects recorded |
| `grid` | | a far file of another far cell size |
| `format` | unreadable, another version, kind or cell size | the same |

Invalid descriptors give one entry `{kind: "error", error}`.

`CopiaBuild.reindex(directory)` rebuilds `cells/index.copiaindex` from the header, inputs and
directory of every built and far file and returns `{ok, error, files, unreadable}`.

## Index files (`.copiaindex`)

`sets/index.copiaindex` lists every set file; `cells/index.copiaindex` lists every built file of
`cells/` and every far file of `far/`. An index is derived data:

- **Maintained by the writer.** `CopiaSets.apply` and `remove_set` update the sets index,
  `CopiaBuild.build_cells` the cells index, in the same call, written atomically (temporary file
  and rename) after the files themselves.
- **Rebuilt when missing.** An index that is missing, unreadable or of another version is rebuilt
  from the file headers on first use.
- **Reconciled on every load.** Each load lists the directory (names only, no file is opened):
  a file the index lacks has its header read and is added, an entry whose file is gone is dropped,
  and an entry marked unreadable is read again. A load that changed the index writes it back; when
  that write fails (read-only data, as in an exported game) the repaired index is used in memory.
- **Verified on request.** Every reader of an index takes `verify`: re-read every header and
  repair the entries that differ. It is the one remedy for files replaced in place outside Copia
  (a version-control checkout of some files, a copy from another machine), which keep their names
  and so look current to the reconciliation.
- **Serialised in one process.** Loading, changing and saving an index happen under one
  process-wide lock, so read-modify-write cycles from several threads do not interleave. Across
  processes the rule "one writer per directory" applies to the index as to the files.

Format: header (20 bytes): magic `CPIX`, format version (u32, 1), kind (u32: 0 sets, 1 cells),
uncompressed size (u32), compressed size (u32); then the content as one Zstandard block. The
content starts with a string table (count u32, then the strings, sorted, each used string once)
followed by the entry count (u32) and the entries, sorted by their key; strings in entries are u32
indices into the table. Equal content gives equal bytes.

| Index | Entry |
| --- | --- |
| sets | set name, cell x and z (i32 × 2), ok (u8: 0 when the file is unreadable or its header names another cell), cell size (f32), point count (u32), content hash (32 bytes), object count (u32) and the object paths (sorted) |
| cells | folder (u8: 0 `cells/`, 1 `far/`), cell x and z (i32 × 2), ok (u8), kind (u32), cell size and store cell size (f32 × 2), then the file's inputs (sets: name, cell x and z, hash; objects: path, descriptor hash) and its directory without section offsets (path, draw mode, flags and the five counts per object) |

## Built cell (`.copiacell`)

| Part | Content |
| --- | --- |
| Header (32 bytes) | magic `CPCL`, format version (u32, 1), kind (u32: 0 cell, 1 far), cell x and z (i32 × 2), cell size of this file's grid (f32), store cell size (f32), size of header, inputs and directory together (u32) |
| Inputs | set count (u32), then per set file used: set name (string), cell x and z (i32 × 2), content hash (32 bytes), sorted by name, cell, hash; object count (u32), then per object: path (string) and descriptor hash (string), sorted |
| Directory | entry count (u32), then per object in path order: path (string), draw mode (u8: 0 multimesh, 1 instance), flags (u8: 1 = built without a descriptor), instance count, batch count, collider count, impostor count, impostor batch count (u32 each), then three section slots (draw, collider, impostor), each offset (u64), uncompressed size (u32), compressed size (u32), all zero when absent |
| Sections | per object and slot, each its own Zstandard block, so one object's data is read without the rest |

A far file's inputs are the union of the inputs of all built cells inside it. Its entries are
the objects with impostors, each with draw mode multimesh and only the draw slot.

A MultiMesh section (the draw slot of a multimesh object, every impostor slot, every far entry)
holds the batch count (u32), the batch table, then the instance buffer (20 × f32 per instance,
batches one after the other). A batch record is 72 bytes: batch cell x and z (i32 × 2), origin
(f32 × 3), bounds position and size relative to the origin (f32 × 3 each), first instance and
count (u32 each), and the counts of instances with `keep` at or above 1, 0.75, 0.5, 0.25 and 0
(u32 × 5; the last equals the count). A single-instance section (the draw slot of an instance
object) and a collider section hold the transform count (u32) and 12 × f32 per transform.

`CopiaCells` reads these files for the run-time side, from any thread:
`list_cells(directory, verify = false)` returns every built and far file from the cells index,
without opening them: `[{cell, kind ("cell" or "far", by folder), ok, cell_size, store_cell_size,
objects, draw, defaulted, instance_count, batch_count, collider_count, impostor_count,
impostor_batch_count}]`, cells first, each sorted by cell. The object summary is columnar, one
entry per object in path order: `objects` (`PackedStringArray`), `draw` and `defaulted`
(`PackedByteArray`; draw 0 multimesh, 1 instance) and the counts (`PackedInt32Array`), so a large
store costs no Dictionary per object;
`transforms_to_buffer(transforms, with_color = false, with_custom = false)` turns a
`"transforms"` section's `PackedFloat32Array` (12 per instance, basis x, y, z, origin) into a
`MultiMesh` 3D buffer (the 3 × 4 matrix row by row, then white colour and zero custom data when
asked for);
`read_directory(path)` returns the header, the inputs and the entries by object path;
`read_section(path, object_path, section = "draw")` (`"draw"`, `"collider"` or `"impostor"`)
returns either `{kind: "multimesh", batch_cells, origins, bounds, first, counts, keep_counts,
buffers}` with one `PackedFloat32Array` per batch, ready for `multimesh_set_buffer`, or
`{kind: "transforms", count, transforms}`.

## Run time

At start-up the node learns every built and far cell and the objects in them from
`CopiaCells.list_cells`, and the objects of the set files from `CopiaSets.list_objects`; it opens
no per-cell file for that. The node keeps the directory of the cells around its sources (see
"Sources"). When a source is within an object's range of a cell, it reads that object's section on
a worker thread and creates the `RenderingServer` objects on the main thread, nearest first, within
the frame budget. Objects are freed when every source has left by the range plus a margin. Ids are
held by a native object whose destructor frees them.

### Sources

A source is a place the node streams around: the *default source* (the node's `target` or the
current camera, range scale 1, density 1, colliders, shadows, priority 1; off with
`use_default_source`) and every enabled `CopiaSource3D` that applies to the node (its `store`
path empty or naming the node). Sources are in the scene-tree group `copia_sources`; the node reads
the group at each update. A source entering, leaving or changing a property bumps a revision
counter (a static of the source script); a node that sees a new value updates in its next frame
and is not settled until it has. Positions are read at each update (every `update_interval`).

Rules, with `d(s)` the horizontal distance from source `s` to a cell's square (far cell for
impostors), `k(s)` its range scale and `r` the object's reach (draw range, impostor range or
collider distance; unlimited is infinite):

- **Loading.** A section is requested when some source has `d(s) − load_margin ≤ r × k(s)`;
  colliders count only sources with colliders and use `k = 1`. A loaded section is freed when no
  source has `d(s) − unload_margin ≤ r × k(s)`, which includes the case where no source counts
  at all (no source, or no source with colliders for a collider section). The sources that satisfy the second test are the
  section's *needing* sources. Directories are read for cells within the largest draw reach × `k`
  (or the largest collider distance, for sources with colliders) plus `load_margin` of a source.
- **Quality.** A draw or impostor group gets the drawer's group density = the largest source
  density among its needing sources (the drawer multiplies it with the store's `density`), and a
  visibility range end = the object's range end (impostor groups: its impostor range end) × the
  largest `k` among them (ends of 0 stay 0).
  A linked draw group's impostor swap distance is the object's range end × the same scale. When
  the needing sources change, the next update applies the new values to the live group
  (`set_group_density`, `set_group_params`, `link_impostor` again); the group keeps its id. A
  group being replaced gets them on both ids.
- **Shadows.** The drawer gets the positions of the sources with shadows through
  `update_cameras()` every frame.
- **Creation order.** A group's priority is the smallest `d(s) ÷ priority(s)` among its needing
  sources, taken at the last update.

**Cost per update.** Per cell near a source: one distance per source and a threshold
`min over s of (d(s) − margin) ÷ k(s)`, so each section of the cell is decided by one comparison
of its reach with the threshold, whatever the number of sources. With one source every needed
section of a cell gets the same values, so the records pass assigns them; with several, each
staying section looks at each source once. The work is O(live sections × sources + cells near a
source × objects in their directories), done natively by `CopiaStreamer` (below), and skipped
when no source moved more than `movement_threshold` and nothing else changed.

**No change, no work.** An update first compares the sources with those of the last evaluated
update: same count, same settings, and none moved more than the store's `movement_threshold`
(default 1 m) on the local XZ plane. If so, and no object, margin, grid, known cell, directory,
pending read or loaded section changed since, nothing is evaluated. The first update after any
such change evaluates. The threshold is measured from the position of the last evaluation, so
slow movement still evaluates every metre. A decision can therefore be up to 1 m late, which the
margins absorb: a section is requested 16 m before its range (at worst 15 m) and freed 32 m after
it; the creation priority of a group created between evaluations is its distance at the last
evaluation.

**No counting source.** A threshold over no counting source is NaN. Loading compares
`r ≥ threshold`, which is false against NaN, so nothing is requested. Freeing keeps a record only
while `r ≥ threshold` holds, so a NaN threshold frees it: with every source disabled (and no
default source) every section goes at the next update, and when the last source with colliders
is disabled or loses them, the collider sections go while the draw and impostor sections the
other sources need stay. (The GDScript decision, and `CopiaStreamer` until this was fixed, freed
on `r < threshold` instead, which is also false against NaN, so such sections stayed loaded until
the node was hidden or a counting source came back and was far enough away.)

**Per view.** The objects are ordinary instances in the world, so each viewport's camera applies
the visibility ranges, the impostor visibility parents and mesh LOD selection itself; sources only
decide what exists. Checked windowed in `demo/tests/copia_sources_timing.gd`: a group with range
50 m was drawn by a camera 12 m away and not by one 120 m away looking at it through a narrow lens
(0 red pixels; with the range unlimited, the same view showed it), and a viewport's
`mesh_lod_threshold` changed only that viewport's drawn primitives.

**Limits.** The instances are shared: a reduced source looking at the same place as a full one
sees full quality, and a group needed only by reduced sources is culled at the reduced range in
every view that sees it. Values baked into instance data at build time (a fade distance in the
instance colour) do not follow `k`.

### `CopiaStreamer`

The streaming decision of one store, native, `RefCounted`, owned by the node (created with its
first drawer). It makes no server call and reads no file. It holds:

- the grid and far grid sizes, the margins and the movement threshold;
- per object (by path; the node resolves the resource and hands over plain values): resolved or
  not, has a mesh, draw reach, has a collider, collider reach (the physics settings' distance,
  else the store's `collider_distance`, else the draw reach), has an impostor, impostor reach;
  unlimited ranges are `INF`;
- the largest draw, collider and impostor reach of the known objects (the node computes them as
  before), which decide the directories read;
- per cell and far cell: known (cells index), pending (a directory read in flight), cached (its
  directory has been read) and, when cached, its entries: object, has instances, has colliders;
- the records: one per live (or loading) section, by cell, object and kind, with its density,
  range scale, creation priority, a stale flag (read from an older directory than the cell's
  current one) and a drawn flag (its group exists);
- the excluded rectangles (`set_excluded_rects`, from the node's method of the same name), turned
  into a set of excluded cells and far cells (centre in a rectangle) whenever they or the grid
  change; a rectangle over more than 2^20 cells, or with an infinite edge, is tested per cell
  instead. An excluded cell's directory is not requested, nothing is requested in it, and the
  records pass frees its live records like those no source needs.

`update(points, scales, densities, colliders, priorities, load)` takes the sources and returns
`{evaluated: false}` or only the changes: the records whose density or range scale changed or
that are freed (cells before far cells), the directories to read (now pending), the new records
to request (kind, cell, object path, density, range scale), and the stale records within the
load reach (reloads). With `load` false (a background build is writing) only the records are
decided and the next update evaluates again. The rules are those of "Sources", with the GDScript
arithmetic kept bit for bit: a cell's corner in single precision (`Vector2(cell) × size`), the
source points in single precision, the rest in double, `minf`/`maxf` with their NaN behaviour,
and the same choice between walking the reach's square and scanning every cell. One rule differs
from that decision: a record is freed unless its reach reaches the unload threshold (`!(r ≥
threshold)` rather than `r < threshold`), so a NaN threshold frees it (see "No counting source").
`demo/tests/copia_streamer_test.gd` keeps the GDScript decision as its reference, with that one
change.

The node keeps everything only it can do, driven by the returned changes: resolving objects and
their draw parameters, starting the worker reads, adding, changing and removing groups in the
drawer and the colliders (`set_group_density`, `set_group_params`, `link_impostor` on a quality
change, as before), signals, and the per-cell revisions. It tells the streamer what changed on
its side: known cells (scan, build results), directories read or invalidated, pending reads,
records it freed itself (a directory without the object, a deleted cell, hiding), stale records
(a rebuilt cell's sections, a changed collider shape, a stale section whose read arrived) and
drawn records. A group's creation priority is read from the streamer when the group is created
or its parameters are set. `get_source_counts()` gives `get_stats().sources[*].groups`.

Measured with the million-point setup (reference machine, the 4.7.2 editor binary, windowed;
`demo/tests/copia_sources_timing.gd`, `COPIA_SOURCES_UPDATE` and `COPIA_SOURCES_STRESS`), main
thread per update call, median / p99 over 200 calls with nothing left to load:

| Case | GDScript decision | `CopiaStreamer`, sources still | `CopiaStreamer`, sources 2 m apart each call |
| --- | --- | --- | --- |
| 1 source, 867 groups, 29 cells | 5.7 / 8.3 ms | 7 / 9 µs | 39 / 53 µs |
| 2 sources, 1,199 groups, 43 cells | 10.7 / 13.9 ms | 9 / 23 µs | 72 / 159 µs |
| 4 sources, 10,080 cell-object records, 10,500 groups | 96 / 113 ms | 19 / 31 µs | 323 / 428 µs |

In the GDScript decision the 5 ms "directory" part was the loop over the cached directory
summaries (Dictionaries) of the cells near a source, not file access: the steady state opened no
file on the main thread then and opens none now. While flying at 20 m/s an update takes about
0.35 to 0.5 ms (p99 about 1.1 ms), of which about 0.1 ms is the streamer and the rest the
node's work on the few sections that change per update (freeing groups with their signals,
starting worker reads).

Two native `RefCounted` classes do the server work: `CopiaDrawer` (`RenderingServer`) and
`CopiaColliders` (`PhysicsServer3D`). Both queue creation and freeing and do them in `step()`
under a time budget the caller gives; every server call is made on the calling thread, which must
be the main thread. Each owns the ids it creates and frees them all, created or queued, when it
is freed itself.

### `CopiaDrawer`

A **group** is what one built-cell section becomes: all batches of one object in one cell (a
multimesh group, from a `"multimesh"` section: draw slot of a multimesh object, impostor slot, far
cell entry), or all single instances of one object in one cell (an instance group, from a
`"transforms"` section). An **object** below is one batch (a multimesh and its instance, plus its
shadow twin) or one single instance.

| Call | Does |
| --- | --- |
| `set_scenario(RID)`, `scenario` | the scenario every instance is created in; changing it moves the live ones |
| `set_transform(Transform3D)`, `transform` | the store node's global transform; every batch and instance transform is relative to it; changing it updates every live object at once |
| `add_multimesh_group(section, params = {}) -> int` | `section` exactly as `CopiaCells.read_section` returns it; queues the creation and returns the group id (> 0; 0 on invalid input) |
| `add_instance_group(section, params = {}) -> int` | the same for a `"transforms"` section |
| `set_group_params(group, params)` | merges the given keys into the group's params and applies to its created objects, at once (not budgeted), only the values that differ from the group's current ones, each with the server calls that set it (below); a queued group simply uses them when created |
| `set_groups_params(groups: PackedInt64Array, params)` | `set_group_params` for each listed group in one call; an unknown id is reported and skipped |
| `remove_group(group)` | queues the frees of its created objects; what was never created is dropped |
| `step(budget_usec) -> Dictionary` | frees first, then creations by `priority` (smallest first, then in order of adding), until the budget is spent; returns `{created, freed, pending_create, pending_free, usec}` in objects |
| `update_camera(position: Vector3)` | switches shadows of groups with a `shadow_range` (global position); the one-position form of `update_cameras` |
| `update_cameras(positions: PackedVector3Array)` | the same for several positions: an object starts casting within its `shadow_range` of any of them and stops beyond `shadow_range` + `shadow_range_margin` of all of them; with no position, no object with a `shadow_range` casts |
| `set_density(fraction)`, `density` | visible instance count of every batch from its keep counts |
| `set_group_density(group, fraction)`, `get_group_density(group)` | the group's share of `density` (default 1): its batches show the keep counts of `density` × `fraction`, by the same rule; applied to created batches at once |
| `get_group_rids(group) -> Array[RID]` | the instance RIDs created so far, in batch or instance order (no shadow twins) |
| `get_group_info(group) -> Dictionary` | `{id, kind ("multimesh" or "instance"), state ("queued", "partial", "created"), ready, count, created, instance_count, density (the group's share), params (every key, defaults included), bounds (AABB of the object origins, store space), shadows_on, visible_counts (multimesh), visibility_begins (per created object, the begin it has now), impostor_link ({impostor, batch, swap_distance, parent}, on a linked child; linked per object, `batch` is -1, `batches` holds the per-object batches and `parent` is empty), linked_children (PackedInt64Array)}`; `{}` for an unknown id |
| `get_group_count()`, `get_stats()` | `get_stats()`: `{groups, queued_groups, objects (live RenderingServer instances: batches, single instances, shadow twins and warm-up), instances (the instances the live groups' created objects draw: a batch's visible count at the current density, 1 per single instance; visibility ranges and impostor swaps are not considered), multimeshes (live RIDs, warm-up included), pending_create, pending_free, warm_up, created_total, freed_total}` |
| `warm_up(mesh, material = RID(), uses_color = true, uses_custom = true)` | see below |
| `link_impostor(impostor_group, child_group, swap_distance, batch = 0)`, `unlink_impostor(impostor_group, child_group)` | see "Impostor swap" |

`params` keys, all optional:

| Key | Default | Meaning |
| --- | --- | --- |
| `mesh` | none | the mesh RID drawn (the multimesh's mesh, or the instance base) |
| `material_override` | none | `instance_geometry_set_material_override` |
| `surface_materials` | `[]` | an `Array` of material `RID`s, one per surface (an empty `RID` keeps the mesh's own): `instance_set_surface_override_material` on every single instance of an instance group, for each surface of `mesh`. A params update that carries the key sets every surface again, so surfaces it no longer lists go back to the mesh's own. Ignored by multimesh groups: the `RenderingServer` rejects a surface override on an instance whose base is a multimesh (an error, and the mesh's material is drawn), so a batch needs `material_override` or a mesh whose surfaces carry the materials; `CopiaObject` passes such a copy (`get_surface_material_mesh()`). `material_override`, when set, wins as usual |
| `visibility_begin`, `visibility_end`, `visibility_begin_margin`, `visibility_end_margin` | 0 | `instance_geometry_set_visibility_range` |
| `fade_mode` | 0 (disabled) | `RenderingServer.VisibilityRangeFadeMode` |
| `cast_shadows` | 1 (on) | `RenderingServer.ShadowCastingSetting` |
| `low_lod_shadows` | false | the batch casts nothing; a second, shadows-only instance of the same multimesh with LOD bias 0.001 does (multimesh groups) |
| `shadow_range` | 0 (always) | shadows only while the camera is within this distance of the object's origin (batch origin or instance origin) |
| `shadow_range_margin` | 0 | hysteresis on `shadow_range`: an object's shadows turn on within `shadow_range` of a position and off only beyond `shadow_range` + this margin of every position; in between they keep their state (a new object there starts without). Per instance for an instance group, per batch for a multimesh group. 0 switches exactly at `shadow_range` |
| `lod_bias` | 1 | `instance_geometry_set_lod_bias` |
| `layers` | 1 | `instance_set_layer_mask` |
| `gi_mode` | 1 (static) | as `GeometryInstance3D.gi_mode`: 0 disabled, 1 baked light flag, 2 dynamic GI flag |
| `extra_cull_margin` | 0 | `instance_set_extra_visibility_margin` |
| `visibility_parent` | none | every batch or instance gets it; for an instance group, `parented` (`PackedByteArray`, one byte per instance, in params or in the section) selects which |
| `impostor_min_scale` | 0 | instance groups: an instance whose scale (the length of its basis Y column, as the build measures it) is below this takes no impostor link and keeps its own range; the build gave it no impostor. Multimesh groups take the link as a whole |
| `object_id` | 0 | `instance_attach_object_instance_id`, so editor picking selects the owner node |
| `priority` | 0 | creation order; the caller passes the distance to the camera |

**Changing params.** `set_group_params` (and `set_groups_params`) merge the given keys into a
copy of the group's params, compare the result with the current values, and make for each created
object only the calls of the values that changed:

| Changed | Server calls per object (and per shadow twin, where it has one) |
| --- | --- |
| `material_override` | `instance_geometry_set_material_override` |
| `lod_bias` | `instance_geometry_set_lod_bias` (not the twin, which keeps 0.001) |
| `layers` | `instance_set_layer_mask` |
| `gi_mode` | `instance_geometry_set_flag` × 2 (baked light, dynamic GI) |
| `extra_cull_margin` | `instance_set_extra_visibility_margin` |
| `object_id` | `instance_attach_object_instance_id` |
| `visibility_begin`, `visibility_end`, their margins, `fade_mode`, `visibility_parent`, `impostor_min_scale` | `instance_geometry_set_visibility_range` and `instance_set_visibility_parent` |
| `cast_shadows`, `shadow_range`, `shadow_range_margin` | the shadow state: `instance_set_visible` and `instance_geometry_set_cast_shadows_setting` (low-LOD shadows: the twin's `instance_set_visible`) |
| `surface_materials` (instance groups) | `mesh_get_surface_count` and `instance_set_surface_override_material` per surface |
| `priority` | none (the creation order of a queued group) |
| `mesh`, `low_lod_shadows` | everything, as at creation (the base or the twin changes) |

A dictionary of four keys or fewer is read by walking its keys; a larger one by looking up each
known key. Before, every call re-applied every value: 13 calls per single instance without
per-surface materials (seven settings, the surface override reset with its surface count, the
range and parent, the visibility and shadow setting). Measured with a throwaway script (windowed,
Forward+ on Vulkan, debug library, reference machine): changing `extra_cull_margin` on 100
single-instance groups of 50 instances each (5,000 objects) took 8.4 to 9.4 ms per change
(median of 30) with the store's old call (the object's whole draw params per group) and 7.9 to
8.8 ms with only the changed key; it now takes 0.50 ms with only the changed key (5,000 server
calls instead of 65,000), 0.46 ms through one `set_groups_params` call and 0.9 ms when the whole
draw params are passed. A call that changes nothing costs 1.6 µs per group in a GDScript loop and
1.0 µs per group through `set_groups_params`. `CopiaStore3D` passes only the keys of the object's
draw params that changed, one `set_groups_params` call per range scale.

The store builds an object's params as: the object's hook (`_get_draw_params()` or
`_get_impostor_draw_params()`), then the store's draw override merged in, then the debug view
(`copia_debug.gd`, see the reference page, "Debug views"), which replaces only
`material_override` and, for the LOD view, `mesh` with cached resources. A debug view change
therefore reaches the live groups through the same diff as any object change: one
`material_override` key (and a mesh swap for LOD), no build.

A batch's transform is the store transform × a translation to the batch origin; its multimesh is
allocated with colour and custom data, gets the section's buffer unchanged (the drawer does not
read or convert it) and `multimesh_set_custom_aabb` with the batch bounds. A single instance's
transform is the store transform × the section transform. A buffer is released once its batch is
created.

**Budget.** `step()` checks the clock before each object and always does at least one, so it
overshoots its budget by at most one object's work (one batch: a few microseconds; the first
object of a session can take about 0.1 ms). The renderer pays more again in the frame after
creation. Creating 2,000 batches at once (12.4 ms) made the next frame about 17 ms longer and
the two after it about 3 ms longer each; loading the same batches in 0.5 ms steps made every frame
of the load about 2.5 ms longer than the baseline, five times the step
(`demo/tests/copia_draw_timing.gd`, debug library, Forward+, one shadowed directional light). A
caller willing to lose `t` per frame therefore passes about a sixth of `t` (a third only covers
the large single loads), and should measure its own scene: the renderer's share depends on
shadows and the number of views.

**Shadow range.** `update_cameras()` (and `update_camera()`, its one-position form) does nothing
when the number of positions is unchanged and none moved 0.25 m or more since the last
evaluation. Otherwise it tests each group with a `shadow_range` by its bounds (the AABB of its
object origins) against each position: wholly inside the range of one position, every object
casts; beyond range + `shadow_range_margin` of every position, none does; either way no object is
visited unless its state changes. Only the other groups test their objects one by one (against
each position): an object within the range of a position casts, one beyond range + margin of
every position does not, and one in the band between keeps its state (hysteresis, so an object
near the boundary does not flicker while a source hovers there). The work is therefore one box test per such group and position plus the
objects of the groups on a boundary, never a scan of every object. Out of range, an object's
shadow casting is off (`cast_shadows` = shadows only: the instance is hidden; low-LOD shadows: the
twin is hidden). Before the first call every object casts; after a call with no position, none
with a `shadow_range` does.

**Density.** At `fraction` 1, 0.75, 0.5, 0.25 and 0 a batch shows exactly its instances with
`keep` at or above 1 − `fraction` (keep count 4, 3, 2, 1, 0); between those levels the count is
interpolated (instances are ordered by `keep`, highest first). At 0 the instances with `keep` 1
remain. The fraction is the global `density` times the group's `set_group_density` share,
clamped to 0..1.

**Warm-up.** `warm_up()` creates a 1-instance multimesh of the given format and a single instance
of the mesh, both with the material, shrunk to nothing at the camera (or the store origin before
`update_camera()`), with huge bounds so they are never culled and casting shadows; `step()` frees
them once two frames have been drawn (or 60 process frames when nothing is drawn, as headless).
Its purpose is to move a first-use pipeline compile to a moment the caller chooses. On the
reference machine no first-use stall could be reproduced in 4.7.2 (the worst frame after the
first batch was 3 to 4 ms, with fresh project shader and pipeline caches, with or without
warm-up), so its benefit is unmeasured, and `CopiaStore3D` does not call it.

A one-off frame of 279 ms seen once in the first fly of `demo/tests/copia_store_timing.gd` was
looked for again (November 2026, Vulkan on an AMD RX 9070 XT, debug library): four launches of a
scratch copy of the test project with its `shader_cache` and `vulkan` directories deleted before
each, and one launch of the demo project, with every frame's store phases, render time and
pipeline compilations (`RenderingServer.get_rendering_info`) recorded. No such frame came back:
the worst frame of the first fly was 15.1, 25.2, 13.6, 11.9 and 11.3 ms, and no pipeline was
compiled during any fly. Every compilation of a launch happens during the initial load: 11 (4
surface, 7 specialization), of which 6 come in the first drawn frame (43 to 50 ms) before any
Copia group exists, so they are the test scene's own, and the rest in frames of 1.1 to 3.4 ms. The
worst fly frames (up to 41 ms) carried under 0.5 ms of store work and about 4 ms of render CPU
time. The driver's own pipeline cache, outside the project, could not be cleared, so a launch
with a cold driver cache was not measured. The script now prints this breakdown
(COPIA_STORE_WORST, COPIA_STORE_PIPELINES, COPIA_STORE_LOAD_WORST and COPIA_STORE_LOAD_COMPILES),
so a recurrence can be placed.

### Impostor swap

The swap between an object and its impostor never shows a gap (nothing drawn) or an overlap (both
drawn), whatever the streaming and budget delays. The drawer enforces it with Godot's visibility
parents (HLOD: a child is drawn exactly while its parent is hidden by the parent's
`visibility_range_begin`; one range test drives both).

- `link_impostor(impostor_group, child_group, swap_distance, batch = 0)`: the impostor group is a
  multimesh group; `batch` is the batch that stands for the child (a built cell's impostor section
  has one per object and cell; for a far cell group, the batch of the child's cell), or a
  `PackedInt32Array` with one impostor batch per child object (batch or instance; -1: that object
  keeps its own range), for an object whose `impostor_batch_size` is smaller than the cell. The
  child is the same object's instance or multimesh group of that cell. Linking a child that is
  linked elsewhere unlinks it first. The rules below apply per impostor batch: to the child
  objects it stands for.
- The child's objects flagged by `parented` (all when absent) and, for an instance group, at or
  above its `impostor_min_scale` get the impostor batch's instance as visibility parent and no
  range of their own (begin and end 0); the others keep their own range and `visibility_parent`. A child object created before its impostor batch exists keeps its own
  range until the batch is created, which parents it in the same step.
- The impostor batch gets `visibility_range_begin = swap_distance` only while every child linked
  to it is fully created (`ready`). Until the child's last object exists it keeps begin 0 and stays
  drawn, and the children it parents stay hidden. Its own `visibility_begin_margin` applies
  (hysteresis); fade modes are out of scope (no cross-fade).
- `remove_group` on a linked child sets the impostor batch's begin back to 0 at once, before any
  of the child's objects is freed, and the batch keeps begin 0 until a child is linked to it
  again. The child's objects stay parented, so hidden, until freed.
- `remove_group` on an impostor with linked children first unparents them and gives them their own
  range back; the impostor's objects are hidden at once and freed by later steps.
- `unlink_impostor` returns both groups to their own params in the same call.

Measured in `demo/tests/copia_draw_timing.gd` (`--only=swap`): a camera flying from 220 m to 20 m
and back across a 100 m swap while a 40-instance child group streams in and later out at one
object per frame; of 260 rendered images none showed neither or both (two runs).

### Per-surface materials

A mesh with several surfaces (a tree's bark and foliage) may need its own material per surface
and object, for example copies of the mesh's materials with a shader parameter set per object.
`CopiaObject.surface_materials`, or its hook `_get_surface_materials()`, gives them; the draw params
carry them in two ways, because Godot treats the two draw modes differently:

- Single instances: `surface_materials` (RIDs), set on each instance with
  `instance_set_surface_override_material`. Instances that share mesh and materials are still
  drawn together.
- Batches: `instance_set_surface_override_material` fails on an instance whose base is a multimesh
  (checked windowed in 4.7.2: the call reports the surface index as out of bounds and the batch
  draws the mesh's own material; `demo/tests/copia_draw_timing.gd --only=surface` shows the
  drawer's result). `CopiaObject.get_surface_material_mesh()` therefore makes a copy of the mesh
  with the materials set on its surfaces, once per object (an `ArrayMesh` is duplicated with its
  LODs, blend shapes and shadow mesh), and the batch draws that copy. It holds the mesh's vertex
  data a second time on the GPU, per object that uses it. `to_nodes()` uses the same copy, since a
  `MultiMeshInstance3D` has no per-surface override property.

Impostor batches take one `material_override` (`CopiaObject.impostor_material`, or the hook
`_get_impostor_draw_params()`); an impostor is usually a single-surface card mesh.

### `CopiaColliders`

| Call | Does |
| --- | --- |
| `set_space(RID)`, `space`; `set_transform(Transform3D)`, `transform` | the physics space and the store's global transform; changing either updates live bodies |
| `add_group(transforms, shapes, params = {}) -> int` | `transforms`: a collider section's `PackedFloat32Array` (12 per instance, store space); `shapes`: `[{shape: RID, transform: Transform3D}]`; `params`: `collision_layer` (1), `collision_mask` (1), `object_id` (0: none), `priority` (0) |
| `remove_group(group)`, `step(budget_usec)` | as the drawer's; `step()` returns `{created, freed, pending_create, pending_free, usec}` in bodies |
| `find_body(body: RID) -> Dictionary` | `{group, index}` of a body, so a ray hit resolves to its group and instance; `{}` when unknown |
| `get_group_info(group) -> Dictionary` | `{ready (every body created), count, created}`; `{}` for an unknown id |
| `get_group_rids(group)`, `get_group_count()`, `get_stats()` | `get_stats()`: `{groups, bodies, pending_create, pending_free, created_total, freed_total}` |

Each instance becomes one static body carrying every shape; `object_id` goes to
`body_attach_object_instance_id`, so `collider` in a ray result is the owner node. Godot's
documentation does not say whether a scaled basis on a body is supported (by Godot Physics or by
Jolt, the default 3D engine since 4.6), so the body gets the orthonormal part of store transform ×
instance transform, and the rest of the basis (scale, and shear if any) is baked into each shape's
transform; body × shape then equals the full transform × the shape's own transform. What a scaled
shape transform does is up to the physics engine. Checked in 4.7.2 with the default engine
(`physics/3d/physics_engine` = `DEFAULT`): rays along the three axes hit spheres, capsules,
cylinders and boxes at their scaled extents for uniform scale 2 and for scales (1, 3, 1) and
(3, 1, 1), with no warning. Rays off the axes, contacts between bodies and Godot Physics were not
checked, so non-uniform scale on round primitives is unverified beyond that.

## Files and the exporter

The three file types (`.copiaset`, `.copiacell`, `.copiaindex`) have a `ResourceFormatLoader`
(`CopiaFileLoader`, registered when the library initialises and removed when it unloads), so the
editor lists them and an export includes them. Loading one returns a `CopiaFile` with header data
only: `file_path`, `kind` (`"set"`, `"cell"`, `"far"` or `"index"`), `cell`, `cell_size`, `counts`
(`{points}` for a set file; `{objects, instances, batches, colliders, impostors}` for a built
file; `{files, index ("sets" or "cells")}` for an index) and `hash` (a set file's content hash;
for a built file the SHA-256 of its header, inputs and directory; for an index the SHA-256 of its
uncompressed content). Reading goes through `FileAccess` by offset, not through the loaded
resource. Set files and the sets index are editor data and can be excluded from an export; the
cells index is run-time data.

## Point attributes

`CopiaPoints` converts per-point attribute arrays, as any point-producing tool delivers them, to
the columns `CopiaSets.apply` takes, and store points back. Static methods, safe on any thread.

`from_attributes(attributes, names = {}, extra = []) -> Dictionary`

- `attributes`: `{name: one value per point}`, each either a packed array or a plain `Array` of
  Variants with `null` for a missing value; both give identical output. Every attribute has the
  length of the first of `P`, `clear`, `object` present; another length is reported and the
  attribute ignored. A value of a type the attribute does not take reads as missing and is
  counted in `errors`.
- `names`: `{default name: name used}`. Defaults and accepted types:

| Default | Meaning | Types |
| --- | --- | --- |
| `P` | origin | Vector3 |
| `orient` | orientation, x y z w | Vector4, Quaternion |
| `N`, `up` | frame | Vector3 |
| `scale` | scale in the instance's frame | Vector3, or a number for all axes |
| `pscale` | uniform scale | number |
| `object` | object path | String |
| `set` | set name; missing or empty = `default` | String |
| `Cd` | colour | Vector3 (alpha 1), Color, Vector4 |
| `custom` | custom data | Vector4, Color; or Vector3 with `custom_w` (number, 0 when absent) as w |
| `keep` | density priority; missing = 1 | number |
| `clear` | 1 = clear point | number |
| `cell` | cell id of a clear point, `"cx_cz"` | String |

- **Transform.** If `orient` exists and the point's value is not missing, the basis is that
  quaternion, normalised (a zero quaternion gives identity). Otherwise, if `N` or `up` exists:
  `n = normalize(N or (0, 0, 1))`, `u = normalize(up or (0, 1, 0))`, `right = normalize(u × n)`;
  if `u × n` is zero (length ≤ 1e-12) the basis is identity, else its columns are
  `(right, normalize(n × right), n)`. Otherwise identity. Then each basis column is multiplied by
  the matching component of `scale` (a number applies to all three) times `pscale`, so the scale
  applies in the instance's own frame. The origin is `P`. Computed in double precision, stored as
  float.
- **Classification.** A point with `clear` 1 is a clear point: it needs a valid `cell` and a valid
  set name, and is never an instance; equal clears are given once, sorted by set and cell. Any
  other point with a non-empty `object` is an instance; it needs a `P` value, a valid set name and
  a finite transform. Every other point is skipped and counted (`skipped_count`), with the
  reasons summarised in `errors`.
- **Columns.** `transform`, `object` + `object_paths` and `set` + `set_names` (tables in order of
  first appearance) always; `color` when `Cd` exists, `custom` when `custom` exists, `keep` when
  `keep` exists. A missing or NaN colour or custom value becomes the NaN row (the object's default
  applies), a missing keep 1. `keep` is not clamped here (`apply` clamps it).
- **Extra.** Each name in `extra` becomes a pass-through column in `points.extra`: int (packed
  integer arrays, or a plain Array whose first value is an int or bool) as `PackedInt32Array`,
  float as `PackedFloat32Array`, Vector3 as `PackedVector3Array`; missing values are zero.
- Returns `{points, clears: [{set, cell: Vector2i}], point_count, clear_count, skipped_count,
  errors: PackedStringArray}`. `points` and `clears` go to `CopiaSets.apply` unchanged.

`to_attributes(points, names = {}) -> Dictionary` is the reverse, for sending store points (the
columns `read_points` returns) to a tool, using only int32, float32, Vector3 and String arrays:
`P`, `N` and `up` (the basis Z and Y columns, normalised), `scale` (the three column lengths),
`object` and `set` (`PackedStringArray`), `keep` (`PackedFloat32Array`, 1 where absent), `Cd`
(`PackedVector3Array`; alpha is dropped) when colour is present, `custom` (`PackedVector3Array`,
x y z) and `custom_w` (`PackedFloat32Array`) when custom data is present, and the extra columns
(int32 and float32 as given, three-wide float32 as `PackedVector3Array`; a core name wins over an
extra column of the same name). NaN rows stay NaN, which `from_attributes` reads as missing.
`names` renames the outputs as above. A round trip reproduces each transform to float precision
when the basis is orthogonal and right-handed; a sheared or mirrored basis does not survive (the
frame is rebuilt from Z and Y, and a mirror becomes a rotation).

`split_by(attributes, name) -> Dictionary` groups points by the value of one column, for a tool
whose points carry their destination: `{value: attributes}` with the groups in order of first
appearance. A String value is the key as it is, `null` (and a missing or empty column) is `""`,
any other value its text. Every column with one value per point is split in its own type (plain
`Array` or packed array); other entries are passed on unchanged. When every point has the same
value, the only group is `attributes` itself, uncopied. Linear in the point count.

`CopiaSets.cell_points(directory, cell_size, rect = Rect2(), sets = [], exclude = [], verify =
false) -> Dictionary` describes where a store has points without reading them: one row per cell
and set that holds points, from the sets index, ordered by cell x, z, then set name, for the cells
that intersect `rect` (every cell when `rect` has no area) and the sets selected as for
`read_points`. Columns: `P` (cell centre on XZ, y 0), `cell` (`PackedStringArray` of ids),
`set` (`PackedStringArray`), `count` (`PackedInt32Array`), `cell_min` and `cell_max`
(`PackedVector3Array`, y 0).

## Interactive authoring (set ownership, brush & edit overlay)

- **Set ownership manifest (`sets/manifest.json`):** Plain UTF-8 JSON written atomically alongside
  `sets/index.copiaindex`, recording each set's `kind` (`"generated"` or `"authored"`) and `locked`
  boolean. Sets absent from the manifest default to `"generated"`, unlocked. Because the manifest is
  source-of-truth (not derived data), it survives `CopiaSets.reindex()` and preserves empty authored
  sets (such as `handplaced` before its first placement).
- **Write intent enforcement:** `CopiaSets.apply(..., intent = "any")`, `edit_points(..., intent =
  "authored")`, `erase_in_sphere(..., intent = "authored")` and `remove_set_checked(..., intent =
  "any")` validate every touched set against the manifest before modifying any file. Procedural
  writers (`HEGoCopiaOutput` via `CopiaStore3D.write_generated`) pass `"generated"` and are refused
  on `"authored"` sets; editor authoring tools pass `"authored"` and are refused on `"generated"`
  sets. Brand-new sets written with `"authored"` intent are auto-registered as `"authored"`.
- **Atomic point edits:** `CopiaSets.edit_points` removes matching rows (exact transform match with
  `1e-4` float fallback) and adds new rows across all touched cells in one call (handling cross-cell
  moves). `CopiaSets.erase_in_sphere` removes matching points within a sphere and returns them as
  apply-format columns for atomic Undo.
- **`CopiaBrush` (native `RefCounted`):** Editor-side XZ spatial hash holding editable authored
  points and optional read-only avoidance points. Provides `sample_dab` (min-spacing rejection,
  slope limits, species radial-band selection, transform/keep/color generation preserving NaN
  defaults), `pick_ray` (ray-vs-OBB authored instance picking without physics colliders) and
  `query_sphere` (live erase queries).
- **`CopiaEditOverlay` & `CopiaDrawer` suppression:** `CopiaEditOverlay` draws uncommitted brush
  strokes via dynamic `RenderingServer` MultiMeshes and a single drag-drop ghost at 60 FPS.
  `CopiaDrawer.suppress_transforms` / `clear_suppressions` temporarily hides moved or erased
  instances in live draw groups until the post-commit rebuild replaces the cell.

## Not decided here

- The `CopiaObject`, `CopiaRenderSettings` and `CopiaPhysicsSettings` properties (the node's side).
- The point attributes of the HEGo bridge and its input (see the bridge's own page).
