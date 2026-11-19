# Copia and Houdini

With the HEGo Copia bridge, an HDA cooked by a `HEGoNode3D` can spawn instances into a Copia
store, and can read what a store already holds. The HDA decides what is spawned and what is
cleared; the bridge never removes anything on its own. Typical uses are scattering vegetation
and rocks over a level, regenerating the instances of one area, and placing one tool's points
around the instances another tool wrote.

## Install the bridge

You need three addons, all from the same source revision:

| Addon | Folder |
| --- | --- |
| HEGo | `addons/hego` |
| Copia | `addons/copia` |
| HEGo Copia | `addons/hego_copia` |

The development channel publishes each on its own branch for use as a submodule at those
folders: `release-next`, `copia-release-next` and `hego-copia-release-next`.

Enable **HEGo**, **Copia** and **HEGo Copia** under **Project Settings → Plugins**; the bridge's
plugin reports which addon is missing if one is. HEGo itself must be set up with a working
Houdini session as described in {doc}`/about/getting_started`.

The bridge adds nothing to your scene. HEGo picks up its output and input handlers
(`HEGoCopiaOutput` and `HEGoCopiaInput`) automatically, so any `HEGoNode3D` can write to a store
and any store can be wired into an input row.

## How a cook works

1. **Inputs.** An input row that names a `CopiaStore3D` sends the store's cells (and, if asked,
   some of its points) to the HDA as a point cloud. See [the Copia input](#the-copia-input).
2. **Cook.** The HDA does its work in Houdini.
3. **Routing.** Every output point with `hegocopia_object` or `hegocopia_clear` is meant for a
   store. The bridge groups these points by the store they name and writes each group with one
   call. Points without those attributes are left to HEGo's other outputs, so one HDA can
   produce meshes next to its instances.
4. **Writing.** In each store the clear points are applied first and the instances are added
   after. Cells that changed are rebuilt before the cook ends.

Nothing is cleared unless the HDA sends a clear point. A cook that only spawns adds to what the
store holds, so recooking it twice doubles its points. The next sections show how to replace.

## Point attributes

The HDA's output carries these point attributes. The ones prefixed `hegocopia_` are the
bridge's; the others are the usual Houdini names.

| Attribute | Type | Meaning |
| --- | --- | --- |
| `hegocopia_object` | string | Resource path of a `CopiaObject` (or of a `Mesh`, drawn with default settings). A non-empty value makes the point an instance. |
| `P` | vector | Position, in the store's local space. |
| `orient` | vector4 | Orientation as a quaternion (x, y, z, w). Used when present. |
| `N`, `up` | vector | Orientation as a frame, when there is no `orient`: `N` is the forward (Z) axis, default `(0, 0, 1)`, and `up` the up axis, default `(0, 1, 0)`. |
| `scale`, `pscale` | vector, float | Scale in the instance's own frame; `pscale` multiplies it. A missing value is 1. |
| `Cd` | vector | Optional instance colour. Absent means the object's default. |
| `hegocopia_custom` | vector4 or vector | Optional custom data. A vector3 takes its fourth component from `hegocopia_custom_w` (0 when absent). |
| `hegocopia_keep` | float | Optional density priority from 0 to 1. Absent means 1. |
| `hegocopia_set` | string | The set the point is written into. Blank means `default`. |
| `hegocopia_store` | string | Which store: its node path from the scene root. Blank means the only store. |
| `hegocopia_clear` | int | 1 makes the point a clear point instead of an instance. |
| `hegocopia_cell` | string | On a clear point, the cell to clear, as `cx_cz` such as `0_0` or `-3_12`. |

The output has no detail attributes. Everything is per point, so one HDA can write several sets
and several stores in one cook.

- **Sets.** A set is a named input of the store. Its name is its identity: whoever writes the
  set `roots` adds to the set `roots`. Set names are 1 to 64 characters of `a-z`, `0-9` and `_`.
  A tool should write one set of its own, so clearing it never touches another tool's points.
- **Transform.** The basis comes from `orient`, or else from `N` and `up`, or else it is the
  identity, and is then scaled by `scale` and `pscale`; the exact rule is in Copia's design page.
- **Cells.** A point's cell follows from its position. A cell is named only to clear it.
- **Other attributes.** An attribute the bridge does not know is ignored unless it is listed
  in the options below; a listed one is stored with every point and handed back to readers.
- **A point that is neither an instance nor a clear point** (no object, no clear) is skipped
  and counted in the report. It is not an error: an HDA's output may carry other points.
- **Space.** Points are written to the store as they are, in the store's local space, and the
  Copia input sends them the same way. Keep the `HEGoNode3D` and the store at the same transform,
  usually the identity.

### Options

Set these in the `HEGoNode3D`'s metadata `hegocopia`, as a dictionary; a cook extension can set
the same keys in the cook state under `hegocopia_options`, which wins.

| Key | Type | Meaning |
| --- | --- | --- |
| `extra_attributes` | `PackedStringArray` | Names of point attributes to store as pass-through columns (int, float or vector3). |

The cook state key `hegocopia` holds the report of the cook: `stores` (per store, what
`HEGoCopiaOutput.write_attributes` returned), `errors`, `warnings`, `point_count`,
`clear_count` and `skipped_count`. A `HEGoCookExtension` child of the node reads it in
`cook_finished(context)` as `context.cook_state.hegocopia`. An output with no points at all
(nothing spawned and nothing cleared) leaves the store untouched and leaves no report: HEGo
does not run the bridge for it. Errors and warnings are also
written to HEGo's log, with the prefix `Copia:`.

An error in the output (a store that cannot be found, points the store rejects) does not fail
the cook: HEGo's output handlers have no way to, so the cook still counts as successful and the
error is only in the log and the report. An error in the Copia input does fail the cook (see
[the Copia input](#the-copia-input)).

Each store's `write` result also says which files changed: `write.apply.written` lists the set
files that were rewritten and `write.apply.unchanged` those whose content came out the same. A
recook that clears and respawns exactly what was there rewrites no file and builds no cell.

## Which store

`hegocopia_store` is the node path of a `CopiaStore3D` from the scene root. The scene root is
the owner of the `HEGoNode3D` (in the running game, the current scene). `Level/Props/Stones`
names the store `Stones` under `Props` under `Level`. An output without the attribute
at all follows the blank rule below.

A blank `hegocopia_store` means the only `CopiaStore3D` in the scene. If the scene has none,
or has several, the points that name none are not written and the cook reports an error; the
other points of that cook are still written. A path to a node that is not a store is an error as
well.

**Name the store with a parameter.** The HDA's author adds a string parameter, here `store`,
and copies it onto every output point, spawned points and clear points alike, with one line in
each wrangle that writes them:

```c
s@hegocopia_store = chs("../store");
```

Set the parameter on the `HEGoNode3D` like any other HDA parameter, to the store's node path
from the scene root: the path the Scene dock shows for the store below the root node, such as
`Level/Props/Stones`, or `scene_root.get_path_to(store)` from code. Leave it blank when the scene
has one store. The Copia input does not name its store: the parameter is the one place the
store is named, so a first cook into an empty store works like every later one. Points whose
paths name the same store are written to it in one call, so their clears are applied before
their instances.

## The Copia input

Wire a `CopiaStore3D` into an input row. The HDA receives one point cloud of two kinds of point.
The cloud does not say which store it came from; the HDA names its store with a parameter (see
[Which store](#which-store)).

**Cell points** (`hegocopia_cell_point` = 1) say where the store has points without sending
them. There is one for every cell and set that holds points:

| Attribute | Meaning |
| --- | --- |
| `P` | The cell's centre on the XZ plane, at height 0. |
| `hegocopia_cell` | The cell id, `cx_cz`. |
| `hegocopia_set` | The set. |
| `hegocopia_count` | The number of points the set has in that cell (int). |
| `hegocopia_cell_min`, `hegocopia_cell_max` | The cell's corners, at height 0. |

**Instance points** (`hegocopia_cell_point` = 0) are the store's own points of the sets named in
`points_of_sets`. They carry `P`, `N`, `up` and `scale`, `hegocopia_object`, `hegocopia_set`,
`hegocopia_keep`, `Cd` and `hegocopia_custom` with `hegocopia_custom_w` when
the points have colour or custom data (a point without them carries NaN), and each stored
pass-through column under its own name. Use them when a tool places its points around another
tool's, such as vegetation that keeps clear of roads.

Every attribute has a value on every point of the cloud. A cell point has zero or an empty string
in the instance columns, and an instance point the same in the cell columns. Tell the two kinds
apart with `hegocopia_cell_point`.

When there is nothing to send (an empty store, or no cell and no point in `rect` and the sets
asked for), the input is an empty cloud with no points and no attributes. A wrangle that reads
the cloud creates the attributes it binds, so the same network cooks either way.

The instance points carry the orientation as a frame (`N`, `up`, `scale`) and custom data as a
vector3 `hegocopia_custom` beside a float `hegocopia_custom_w`, because HEGo inputs have no
vector4. To merge them with points that carry `orient` and a vector4 `hegocopia_custom`, convert
them first, as the copy branch in [a worked example](#a-worked-example) does.

### Row settings

An input row for a store takes these settings. The HEGo panel has no editor for them yet: set
them from code, as in the example below, or in the saved input stash.

| Setting | Meaning |
| --- | --- |
| `copia_input` | `true` marks the row as a Copia input. Set it; it keeps the row's settings and its strict cook in force while the store is missing. |
| `rect` | Optional `[min_x, min_z, max_x, max_z]` in store-local metres. Only the cells that touch it get cell points, and only instance points inside it are sent. Absent means every cell. |
| `sets` | Optional list of set names. Only these get cell points. Empty means every set. |
| `exclude_sets` | Optional list of set names that get no cell points. |
| `points_of_sets` | Optional list of set names whose instance points are sent as well. Empty means none. |

`sets` and `exclude_sets` limit the cell points only. A cook with a Copia input is strict:
if the store cannot be read, the cook fails instead of running on partial data.

```gdscript
var host: HEGoNode3D = $RootsGenerator
host.hego_set_input_stash([{
    "inputs": ["../Stones"],
    "settings": {
        "copia_input": true,
        "rect": [0, 0, 512, 512],
        "sets": ["roots"],
        "points_of_sets": ["roads"],
    },
}])
await host.cook()
```

## Replacing a generator's output

A store is not told which points came from which cook. The HDA says so, by clearing the cells it
is about to fill. Do it in four steps:

1. **Read the store.** Wire the store into an input row with `sets: ["roots"]` (the generator's
   own set). The cell points arrive: one for each cell that holds `roots`.
2. **Choose the cells.** Keep the cell points of your set whose whole cell lies inside the
   area you generate, and delete the rest.
3. **Turn them into clear points.** Set `hegocopia_clear` to 1 on the ones you kept. Each now
   means "empty the set `hegocopia_set` in the cell `hegocopia_cell`". They already carry the
   set and the cell; give them the store from the HDA's `store` parameter, as the spawned
   points get it, so the bridge needs nothing else.
4. **Merge** the clear points with the points you spawn.

The wrangles below are the ones of the test fixture `demo/tests/fixtures/hego_test_copia.hda`
(built by `make_copia_fixture.py`), which the round-trip test cooks through HEGo, without the
attributes only the test reads; its parameters are read with `ch("../name")`. The fixture is a
test asset, not a production tool. The clear wrangle runs over the points of the Copia input
and keeps the cell points of the asset's own sets whose whole cell lies inside a square of side
`size` centred on the origin, stamping the store on them:

```c
// Clear this asset's sets in every cell that lies within the size square.
string mine = chs("../set");
string second = chs("../second_set");
float half = ch("../size") * 0.5 + 1e-3;
int ours = s@hegocopia_set == mine || (second != "" && s@hegocopia_set == second);
int inside = v@hegocopia_cell_min.x >= -half && v@hegocopia_cell_max.x <= half
          && v@hegocopia_cell_min.z >= -half && v@hegocopia_cell_max.z <= half;
if (chi("../clear") && i@hegocopia_cell_point == 1 && ours && inside) {
    i@hegocopia_clear = 1;
    s@hegocopia_store = chs("../store");
} else
    removepoint(0, @ptnum);
```

Follow it with an Attribute Delete that keeps only what a clear point needs (point attributes
`* ^hegocopia_clear ^hegocopia_set ^hegocopia_cell ^hegocopia_store`). Otherwise the Merge gives
every spawned point the input's other columns with their zero defaults: a spawned point without
its own `scale` would get a scale of zero, one without `orient` an `N` and `up` of zero.

The points the HDA spawns (here scattered over the square, `count` of them with `seed`) carry the
object, the set, the store and every part of the transform:

```c
int seed = chi("../seed");
float id = @ptnum + 1;
vector4 yaw = quaternion(radians(rand(set(id, seed, 1)) * 360.0), {0, 1, 0});
vector4 tilt = quaternion(radians(20.0), {1, 0, 0});
p@orient = qmultiply(yaw, tilt);
v@scale = (@ptnum % 3 == 0) ? {1.0, 2.0, 0.5} : {1.0, 1.0, 1.0};
f@pscale = fit01(rand(set(id, seed, 2)), 0.5, 1.5);
v@Cd = rand(set(id, seed, 3));
f@hegocopia_keep = fit01(rand(set(id, seed, 4)), 0.2, 1.0);
p@hegocopia_custom = set(id, float(seed), @P.x, 0.5);

s@hegocopia_object = chs("../object");
string second = chs("../second_set");
s@hegocopia_set = (second != "" && @ptnum % 2 == 1) ? second : chs("../set");
s@hegocopia_store = chs("../store");
```

Every random value depends only on the seed and the point number, so an unchanged recook
produces the same points and rewrites nothing. The instance basis Copia stores is Houdini's own
instancing rule: `scale * pscale` along the local axes, then rotated by `orient`, which in
GDScript is `Basis(Quaternion(o.x, o.y, o.z, o.w)) * Basis.from_scale(scale * pscale)`.

Merge the clear points and the spawned points with a Merge SOP and end in the output. In one
cook the clears are applied first and the spawned points added after, so the cells hold exactly
the new points.

Three things to keep in mind:

- A cell is cleared whole. Choose the bounds as a whole number of cells, and spawn only inside
  them: points spawned in a cell that is not cleared are added to what is there, and
  points of the set in a cleared cell that the new cook does not respawn are gone.
- **A cell with no points has no cell point.** The first cook, and a cook over empty ground,
  clears nothing, which is right: there is nothing to clear.
- **A cook that clears and spawns nothing** removes the set from those cells. The output must
  still carry the clear points: `hegocopia_clear` alone is enough for the bridge to run.

### Spawn only

Leave the input out and send instance points only. The cook adds to the store every time it
runs, which suits one-off placement, or a tool whose set is removed by hand with `CopiaStore3D.remove_set`.

### Several sets and stores

A point names its own set and store, so one cook can fill several of each. The fixture's spawn
wrangle above puts every other point into `second_set` when that parameter is set, and its clear
wrangle clears both sets: send clear points for each set the same way (one clear point per set
and cell), and leave every other set alone, as the fixture does with sets it does not write.

### A worked example

The fixture also re-emits points it reads. With `copy_set` set and that set named in the input
row's `points_of_sets`, it takes the input's instance points of that set and writes them into its
own set and store, 1000 m along +X. The input sends their orientation as `N`, `up` and `scale` and their
custom data as vector3 plus `hegocopia_custom_w`, so the wrangle turns them into what the spawned
points carry before the Merge:

```c
// Re-emit the input's instance points of copy_set into set, 1000 m along +X.
string from = chs("../copy_set");
if (from == "" || i@hegocopia_cell_point != 0 || s@hegocopia_set != from) {
    removepoint(0, @ptnum);
} else {
    p@orient = quaternion(maketransform(normalize(v@N), normalize(v@up)));
    f@pscale = 1.0;
    @P.x += 1000.0;
    s@hegocopia_set = chs("../set");
    s@hegocopia_store = chs("../store");
    p@copy_custom = set(v@hegocopia_custom.x, v@hegocopia_custom.y, v@hegocopia_custom.z, f@hegocopia_custom_w);
}
```

An Attribute Delete then keeps `orient scale pscale Cd hegocopia_object hegocopia_set
hegocopia_store hegocopia_keep copy_custom` (and any pass-through column), and an Attribute Swap
moves `copy_custom` onto `hegocopia_custom`. A wrangle cannot change the size of an attribute that
exists, and a Merge of a vector3 with a vector4 attribute pads the vector3 with a zero `w`. The
copies come back with the same basis, object, colour, custom data and keep as the originals
(for a basis without shear, which is what N, up and scale can carry).

## From a script

`HEGoCopiaOutput.write_attributes(attributes, store, options)` does what the handler does for
one store, and is the entry point for a cook extension that reads its own points or for a test.
`attributes` maps the names above to arrays with one value per point (plain `Array`s with
`null` for a missing value, or packed arrays); `options` takes `extra`, a `PackedStringArray`
of pass-through attribute names. It returns `{ok, errors, point_count, clear_count,
skipped_count, write}`. `HEGoCopiaOutput.write_routes(host, routes, options)` is what the
handler does with all of a cook's points: `routes` maps each `hegocopia_store` value to the
attributes of its points, `options` are the cook options above (`extra_attributes`), and it
returns the report the handler leaves in the cook state. `HEGoCopiaOutput.split_routes(columns)`
makes those routes from the columns of all of a cook's points, the way the handler does: a
native split by `hegocopia_store` (`CopiaPoints.split_by`), where no store and a blank one are
both the route `""`, and the columns go on uncopied when every point names the same store.
`HEGoCopiaOutput.find_store(host, path)` resolves a store path as above,
and `HEGoCopiaInput.build_points(store, settings)` returns the cloud of a Copia input
(`{P, attributes}`, the values `HEGoInputNode.set_geo` takes) without Houdini.

## Not there yet

- The HEGo panel has no editor for a Copia input's row settings.
- There is no helper asset for the clear pattern; build it as above.
- Points are written without a transform: the store and the `HEGoNode3D` must share one.
- A store cannot be named by Godot's own node id, only by its path.
- An error in the output, such as a store that cannot be found, does not fail the cook.
