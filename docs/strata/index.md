# Strata terrain

Strata is a layered terrain for Godot 4.4 and newer. You build a terrain from an ordered
stack of layers: some you paint in the editor, others are written by a producer such as a
Houdini Digital Asset. Strata composes the stack into one heightfield with materials, holes
and navigation masks, and bakes it into a single resource that collision, navigation and
your game use.

Strata stands on its own. It needs neither HEGo nor Houdini: a native extension does the
heavy data work (composition, meshing, material packing), and everything else is ordinary
GDScript nodes and resources. When you do want Houdini to generate or erode terrain, the
separate HEGo Strata bridge lets a `HEGoNode3D` cook straight into a layer; see
[Strata and Houdini](houdini.md).

**What it is not.** Strata is for static, authored terrain. It does not deform at runtime and
does not stream or page: the whole bake is one resource in memory, and you choose which
areas get collision and navigation. A terrain may be translated and rotated around Y, but
not scaled, pitched or rolled.

## How it fits together

A terrain is a `StrataTerrain3D` node with `StrataLayer` children:

```text
StrataTerrain3D          bounds, storage directory, materials, render settings, bake
├── RoughBase            manual layer: you paint it
├── Erosion              procedural layer: an HDA writes it
├── Paths                manual layer, Add composition
└── Holes                manual layer with a hole channel
```

**Layers compose in scene-tree order.** The first child is the bottom of the stack; each
later child is applied on top of what lies below it. Disable a layer (`enabled`) to take
it out of the stack without deleting it.

**A layer is manual or procedural.**

- A *manual* layer holds samples you paint with the brush, on its own grid
  (`data.sample_spacing`, `data.grid_origin`). It only *owns* the samples you touched;
  everywhere else it is transparent and the layers below show through.
- A *procedural* layer (`procedural = true`) holds the complete result of its last cook,
  one field per channel, each on its own grid. A new cook replaces the whole result. You
  cannot paint on it; put hand edits on a manual layer above it.

**Layers carry named channels.** Every value a layer stores belongs to a scalar channel:
`height`, of course, but also masks such as `grass` or `rock`, material weights,
`hole`, `nav_exclusion`, or the terrain-wide `terrain_tint_*` and `terrain_ao`. Channels
compose independently, so a layer that only paints `rock` leaves the height untouched. The
names Strata itself reads are listed in the [reference](reference.md#channels).

**Each channel of a layer composes in one of two ways** (`composition_modes`):

- **Replace** (the default) sets the value where the layer owns samples.
- **Add** adds a signed offset where the layer owns samples.

This is what lets hand work survive a regenerated base. A Replace layer keeps its absolute
values when something below it changes, so a flattened building pad stays flat. An Add
layer keeps its offsets, so a path dug into a slope follows the slope when an erosion layer
underneath is cooked again.

**Everything at runtime comes from the bake.** `StrataBake.bake()` compiles the complete,
enabled stack into a `StrataRuntimeData` resource: heights on a regular grid, hole and
navigation-exclusion masks, packed material controls, an optional terrain-wide tint and AO
map, and any custom channels you ask to keep. `StrataCollision`, `StrataNavigation`, runtime
height queries and an exported runtime scene all read the bake, never the layers. Any
change to the stack marks the bake stale (`runtime_bake_stale`) until you bake again.

**The editor shows the live stack.** With `textured_editor_preview` enabled and materials
assigned, the editor viewport renders the terrain with the real Forward+ renderer, composed
from the layers as you paint. Selecting a layer shows the stack up to and including that
layer, so you always see what you are painting on.

## Where the data lives

With `storage_directory` empty, a terrain's layers and bake are saved inside its scene,
which suits small terrains. Set it to a project folder, for example
`res://levels/valley/terrain`, and every piece gets one fixed file there instead:

| File | Holds |
| --- | --- |
| `<directory>/<layer>.res` | a manual layer's painted samples |
| `<directory>/<layer>/<channel>.res` | one channel of a procedural layer's last cook |
| `<directory>/runtime_data.res` | the published bake |
| `<directory>/material_ids.res`, `material_weights.res` | the terrain's packed material control maps, when it has any |

Layer names become snake_case file names, so `ManualFine` is saved as `manual_fine.res`;
renaming a layer changes its file. A cook overwrites its layer's channel files in place and
removes the files of channels it no longer produces, and every bake overwrites
`runtime_data.res`. Manual layers are written when you press **Save layers to storage** in
the terrain's *Storage* inspector group (or call `StrataStorage.save_all(terrain)`). Each
write goes to a temporary file first and is renamed into place, so a failed save leaves the
previous file intact.

The scene still references these files by path, so save the scene after a cook. When a
scene opens, any layer the scene stores nothing for is filled from its file, which also lets
a second scene share the same terrain by naming the same directory and layers.

## Pages

- [Getting started](getting_started.md): install, paint, materials, bake, collision and
  navigation.
- [Strata and Houdini](houdini.md): cook layers with an HDA through a `HEGoNode3D`.
- [Example: Bracken Isle](example_island.md): a complete island built this way, in the
  demo project.
- [Reference](reference.md): channel names, composition, bridge attributes, files and bake
  options.
