# Copia

Copia is an instancing store for large worlds: tens of thousands to millions of instances of
meshes such as rocks, plants and props, kept on disk in cells and drawn only near the camera. It
needs no Houdini. Points are written into it from GDScript, from native code, or from HEGo cooks
through the separate HEGo Copia bridge (`addons/hego_copia`; see {doc}`/bridges/index`).

```{note}
Copia is a standalone addon with no dependency on HEGo or Houdini and is planned to move into its
own repository in the future. While it is developed on HEGo's `next` channel, its package and full
documentation live here.
```

Pages: [Getting started](getting_started.md) (install, a first store, the demo scene),
[Reference](reference.md) (every property and method), [Copia and Houdini](houdini.md) (the HEGo
bridge) and the [design specification](../development/copia_design.md).

## Who needs it

Use Copia when a scene has more instances than a `MultiMeshInstance3D` or a set of nodes can
carry: the instances must be loaded by area, drawn in batches that cull well, and given colliders
only where the player can reach them. A level with a few hundred props does not need it.

## Parts

**Store.** A `CopiaStore3D` node with a data directory and a cell size (default 64 m). Points
are in the node's local space.

**Object.** A [`CopiaObject`](reference.md#copiaobject) resource is the thing to instance: a
mesh, a material override, render settings, optional physics settings and an optional impostor.
A point names its object by resource path. A path to a `Mesh` is also accepted and drawn with
default settings, so a first test needs no object. A game can extend `CopiaObject` in GDScript
and override its hooks to derive values from its own conventions.

**Render settings.** A [`CopiaRenderSettings`](reference.md#copiarendersettings) resource says
how an object is drawn: as MultiMesh batches or as single instances, the visibility range, fade,
shadows, LOD bias, batch size and render layers. Variations of one thing share one resource.

**Physics settings.** A [`CopiaPhysicsSettings`](reference.md#copiaphysicssettings) resource
says what collider an object gets: listed shapes, the convex hull or triangle mesh of the mesh,
or one primitive fitted to its bounds, with a collision layer and mask, a smallest instance
scale and the distance within which colliders exist. An object without it has no collider.

**Source.** A [`CopiaSource3D`](reference.md#copiasource3d) node marks another place the store
streams around, for games with several views of the same world (a preview or monitor camera),
with its own range scale, density, colliders and shadows. The store's own camera is its default
source.

**Cell.** A square of the store's grid on the local XZ plane. Cell `(cx, cz)` covers
`[cx * size, (cx + 1) * size)` on each axis; Y is unbounded.

**Set.** A named input of the store. Whoever writes set `a` adds to set `a`; a point without a
set is in `default`. Each set has one file per cell, which is the editor data and the source of
truth.

**Build.** A native step that turns the set files of a cell into one built cell: finished
batches with the instance buffers MultiMesh takes as they are, single-instance transforms, and
collider transforms. Impostors are built into a coarser far grid. The build reads each object as
a plain *descriptor* (see [the reference](reference.md#the-build-descriptor)), so it never loads
a resource. The running game reads built cells only.

**Drawing.** The store node reads the cells around the camera on worker threads and creates the
`RenderingServer` and `PhysicsServer3D` objects on the main thread, nearest first, within a
frame budget. They are freed when the camera has left. Ranges, shadows, materials and collision
shapes apply here, which is why changing them needs no build.

**HEGo bridge.** Writes cooked points into a store and sends its content back to HDAs; see
[Copia and Houdini](houdini.md).

## What a change costs

A change to the mesh's bounds, an object's default colour or custom data, the draw mode, the
batch size, the physics minimum scale, whether an object has a collider or an impostor, or the
impostor settings changes the build descriptor, so the cells that used the object are rebuilt.
Everything else (ranges, shadows, fade, LOD bias, materials, layers, GI mode, collision layers
and shapes) is applied when a cell loads. The resources tell you which: they emit
`build_inputs_changed` for the first group and only `changed` for the second.
[The reference](reference.md) lists every property.

## Enabling the addon

Copy `addons/copia` into the project and enable the plugin in Project Settings. The plugin adds
a panel to the inspector of the store node; the node and the resource classes are available as
soon as the files are in the project. [Getting started](getting_started.md) goes on from there.
