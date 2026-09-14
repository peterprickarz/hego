Building Output From a Cook
===========================

A cook leaves its geometry in Houdini. Nothing crosses into Godot until you ask for it, and
what you ask for is up to you: HEGo's own handlers read the ``hego_`` attributes described in
:doc:`/node_reference/hego_node_3d`, but an HDA of your own can tag its geometry however it
likes and a custom node can read exactly that.

This page is about doing it yourself. The :ref:`handlers <output-handlers>` at the bottom are
the shortcut for when your HDA follows HEGo's conventions.

Two doors into a cook
---------------------

Both are on the asset node, and both return an object that still lives in C++:

.. list-table::
   :widths: 46 54

   * - ``asset.get_geo_output(preload_attribs := [])``
     - :ref:`HEGoGeoOutput<class_HEGoGeoOutput>` — the cook's **points**
   * - ``asset.get_surface_output(point_attribs := [], preload_attribs := [])``
     - :ref:`HEGoGeoSurfaces<class_HEGoGeoSurfaces>` — the cook's **primitives**

Use points for scattering, spawning and anything per-position; use surfaces for anything that
becomes a mesh. Both return a :doc:`task </api/task_pattern>`, and both take attribute names
to load while that task runs, which saves a second await.

After that, filtering and splitting are in-memory work that returns immediately. A hundred
thousand points stay a hundred thousand points in C++ until you call ``get_points()`` or
``get_surface()`` on a subset.

.. important::

   An attribute has to be **loaded** before you can filter, split or read by it. Either name
   it in the fetch above, or call ``load_attributes()`` afterwards. Reading one that was never
   loaded gives an empty array and a warning — it does not quietly fetch it for you.

Splitting points by your own attributes
---------------------------------------

``split_by()`` gives ``{ attribute value: selection }``; ``filter_by()`` gives the selection
matching one value. Both are chainable, and neither copies anything.

.. code-block:: gdscript

    var points: HEGoGeoOutput = await agent.task(asset.get_geo_output())
    await agent.task(points.load_attributes(["my_kind", "my_region", "keep", "N", "up", "pscale"]))

    # One group per value of the HDA's own "my_kind" attribute.
    var by_kind := points.split_by("my_kind")
    for kind in by_kind:
        var selection: HEGoGeoSelection = by_kind[kind]
        var group := selection.get_points(["N", "up", "pscale"])
        # group == { "P": [...], "N": [...], "up": [...], "pscale": [...] }

``get_points()`` always includes ``P``, whether or not you name it. The arrays it returns are
parallel and in the selection's own order, so index ``i`` of each describes one point.

Chained, which is the shape most custom nodes end up with:

.. code-block:: gdscript

    var wanted := points.filter_by("keep", 1)      # only the points the HDA flagged
    var by_region := wanted.split_by("my_region")  # then grouped by another attribute
    for region in by_region:
        var selection: HEGoGeoSelection = by_region[region]
        var group := selection.get_points(["N", "up", "pscale"])

        var holder := context.place(str(region), "region", Node3D.new) as Node3D
        for i in range(group["P"].size()):
            var spawned := Node3D.new()
            holder.add_child(spawned)
            spawned.transform = HEGoPointUtil.transform_from_point(group, i, group["P"][i])
            context.own(spawned)

:ref:`HEGoPointUtil.transform_from_point()<class_HEGoPointUtil_method_transform_from_point>`
turns ``N``, ``up``, ``pscale`` and ``scale`` into the orientation every built-in handler
uses, so your points land the same way HEGo's do.

.. note::

   ``demo/hda_nodes`` cooks against ``Sop/hego_testscatter_tool``, which tags its 992 points
   with ``split_attr1``, ``split_attr2`` and ``filter_attr`` for exactly this. Splitting on
   ``split_attr1`` gives ``["foo", "bar"]`` at 406 and 586 points; ``filter_by("filter_attr",
   1)`` keeps 425 of the 992, and splitting *that* by ``split_attr2`` gives ``["world",
   "hello"]`` at 262 and 163. It is a quick thing to point a scratch node at while you get
   the shape of this into your fingers.

Splitting primitives into surfaces
----------------------------------

The surface side works the same way, one level along: split the primitives, then ask each
group for a Godot surface.

.. code-block:: gdscript

    # point_attribs are baked into the surface arrays; preload_attribs are the primitive
    # attributes you intend to split or read by.
    var surfaces: HEGoGeoSurfaces = await agent.task(
        asset.get_surface_output(["N", "uv"], ["my_part"]))

    var mesh := ArrayMesh.new()
    var by_part := surfaces.split_by("my_part")
    for part in by_part:
        var selection: HEGoGeoPrimSelection = by_part[part]
        var surface := selection.get_surface(["my_part"])
        mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface["surface_array"])

``get_surface()`` returns ``{ "surface_array": [...], <requested attributes>: [...] }``.
``surface_array`` goes straight into ``ArrayMesh.add_surface_from_arrays()``: it holds only
the points those primitives use, compacted, with the indices remapped to match. The requested
attributes come back one value per primitive, in the order of
``selection.get_indices()``, and an attribute the HDA does not have is simply absent — read
them with ``Dictionary.get()``.

:ref:`HEGoMeshOutput.fetch_surface_groups()<class_HEGoMeshOutput_method_fetch_surface_groups>`
is fifteen lines of exactly this, split twice: by ``hego_mesh_instance``, then by
``hego_material``. Read it as the worked example of a two-level split.

Finding out what an HDA carries
-------------------------------

Attribute names are available before anything is loaded, so a node can adapt to the geometry
instead of naming everything up front:

.. code-block:: gdscript

    for name in points.get_attribute_names_with_prefix("my_"):
        print(name, " is on this cook")

    if surfaces.has_attribute("my_part"):
        await agent.task(surfaces.load_attributes(["my_part"]))

On the point side these take an owner — ``HEGoGeoOutput.OWNER_POINT`` (the default),
``OWNER_VERTEX``, ``OWNER_PRIM`` or ``OWNER_DETAIL``. On
:ref:`HEGoGeoSurfaces<class_HEGoGeoSurfaces>` they are primitive attributes and take none.

:ref:`get_output_summary()<class_HEGoAssetNode_method_get_output_summary>` answers the coarser
question — whether the cook produced a mesh, points, curves or volumes, and which attribute
names are on it — in one call, which is how a node skips work it has nothing to do.

Putting the result in the scene
-------------------------------

``context`` below is the :ref:`HEGoOutputContext<class_HEGoOutputContext>` that
``agent.output_context(asset)`` returns, or
``HEGoOutputContext.create(self, asset, summary)`` built by hand.

.. list-table::
   :widths: 46 54

   * - ``context.place(node_path, default_name, factory, unique := false, configure := Callable())``
     - A node under ``Outputs/``, created, named, parented and owned. Reuses one already
       there of the right class and replaces one of the wrong class, so cooking twice does
       not orphan what the first cook built. ``unique`` suffixes the name instead of
       reusing, which is what one node per point needs
   * - ``context.own(node)``
     - Makes a node you parented yourself part of the saved scene
   * - ``context.outputs_root()``
     - The ``Outputs`` node, created if missing
   * - ``context.select_points(filter_attrib, attribs)``
     - Fetch, load, and ``filter_by(filter_attrib, 1)`` in one call, or ``null`` if nothing
       matched. The common case of the first example above

**A node you create and do not own disappears when the scene is saved.** ``place()`` handles
it; if you parent a node yourself, ``own()`` is the call that keeps it. Nothing warns you.

.. _output-handlers:

Shortcuts, when the HDA follows HEGo's conventions
--------------------------------------------------

If your HDA tags its geometry the way :doc:`/node_reference/hego_node_3d` describes, none of
the above is necessary — the built-in handlers read those attributes already:

.. list-table::
   :widths: 46 54

   * - ``HEGoMeshOutput.fetch_meshes(context)``
     - ``{ mesh instance name: ArrayMesh }``, with LODs and materials applied, without
       touching the scene. Usually all a single-mesh node needs
   * - ``HEGoMeshOutput.fetch_surface_groups(context)``
     - The surfaces behind that, grouped by ``hego_mesh_instance`` then ``hego_material``
   * - ``HEGoMeshOutput.handle(context)``
     - The whole standard mesh output: scene nodes, resource saving, collision
   * - ``HEGoMultiMeshOutput.setup_multimesh(context, mesh, name, points)``
     - One ``MultiMeshInstance3D`` from a point dictionary — the one you just split out
   * - ``HEGoCurveOutput.handle(context)`` / ``HEGoObjectOutput.handle(context)``
     - Curves to ``Path3D``, points to spawned nodes and packed scenes

Mixing is normal: read your own attributes for the parts your HDA does its own way, and hand
the rest to a handler. A node that wants the standard output entirely can run them all, which
is what ``HEGoNode3D`` does::

    var context := await agent.output_context(asset)
    for handler in [HEGoMeshOutput, HEGoMultiMeshOutput, HEGoCurveOutput]:
        if handler.should_handle(context.summary):
            await handler.handle(context)

To write a handler of your own that ``HEGoNode3D`` will run too, see
:doc:`/api/node3d_modules`. For more on the geometry API itself — why it is fast, what is
cached, and porting from the deprecated fetch configs — see :doc:`/api/geo_output`.
