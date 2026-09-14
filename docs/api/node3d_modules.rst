HEGoNode3D Modules
==================

Overview
--------

:doc:`HEGoNode3D </node_reference/hego_node_3d>` orchestrates a cook; the work lives
in modules under ``addons/hego/node3d/``. Each is a plain GDScript class of static
functions, so you can call them from your own scripts, replace one of them, or read
one to see how an output type is built. Writing a node of your own around them is
:doc:`custom_nodes`.

.. list-table::
   :widths: 32 68
   :header-rows: 1

   * - Class
     - Responsibility
   * - ``HEGoNodeUtil``
     - Awaiting tasks, building the ``Outputs/`` hierarchy, reading attribute dictionaries
   * - ``HEGoCookTimings``
     - Per-phase timings of one cook
   * - ``HEGoMeshOutput``
     - Surfaces to ``MeshInstance3D``, resource saving, collision generation
   * - ``HEGoMultiMeshOutput``
     - Points to ``MultiMeshInstance3D``
   * - ``HEGoObjectOutput``
     - Points to spawned nodes and packed scenes
   * - ``HEGoCurveOutput``
     - Curves to ``Path3D``
   * - ``HEGoCurveBuilder``
     - Poly, NURBS and Bezier ``Curve3D`` construction, no scene access
   * - ``HEGoPropertyUtil``
     - Applying ``hego_custom_properties`` to a spawned object
   * - ``HEGoInputNodes``
     - Turning a Godot node into the right HEGo input node
   * - ``HEGoOutputContext``
     - What one handler is given: the host node, the HDA, the cook summary, and the node
       building it needs
   * - ``HEGoPointUtil``
     - Orientation, scale and colour attributes to a ``Transform3D`` or a ``Color``
   * - ``HEGoHelpers``
     - The tedious parts of driving an HDA, for a node writing its own ``cook()``. See
       :doc:`custom_nodes`
   * - ``HEGoTerrain3DUtil``
     - Terrain3D helpers shared by input, output and instancing
   * - ``HEGoTerrain3DOutput``
     - Heightfield layers to a Terrain3D node
   * - ``HEGoTerrain3DInstancer``
     - Points to Terrain3D instancer transforms
   * - ``HEGoTerrain3DInput``
     - An existing Terrain3D to heightfield layers for Houdini

Every output handler exposes the same three entry points: ``output_phase()``, the name it is
timed under; ``should_handle(summary)``, which decides from
:ref:`get_output_summary()<class_HEGoAssetNode_method_get_output_summary>` whether the cook
produced anything it cares about; and ``handle(context)``, which does the work.
:doc:`HEGoNode3D </node_reference/hego_node_3d>` asks for the summary once, then calls each
handler that wants it and times them all.

``context`` is a ``HEGoOutputContext``, which is what a handler is given instead of the host
node. It carries ``host``, ``asset`` and ``summary``, and the node building every handler was
repeating:

.. list-table::
   :widths: 46 54

   * - ``await_task(task)``
     - Waits for a task and returns its result, or ``null``
   * - ``outputs_root()``
     - The ``Outputs`` node, created if missing
   * - ``place(node_path, default_name, factory, unique := false, configure := Callable())``
     - A node under ``Outputs/``, created, named, parented and owned. Reuses one already there
       of the right class and replaces one of the wrong class, so a handler that runs twice
       does not orphan what it built the first time
   * - ``ensure_parent(root, path_parts)``
     - The intermediate ``Node3D``\ s of a path, returning the deepest
   * - ``own(node)``
     - Makes a spawned node part of the saved scene, in the editor only
   * - ``select_points(filter_attrib, attribs)``
     - The cook's points with ``attribs`` loaded, filtered to the ones flagged, or ``null``
       when there are none

Handlers used to reach into the host node for a member literally named ``hego_asset_node``,
which meant any node reusing one had to declare a member by that name whether or not it
suited it. The context names what they actually need instead.

Writing your own output handler
-------------------------------

The shape to copy, in a script of your own:

.. code-block:: gdscript

    @tool
    class_name MyScatterOutput
    extends RefCounted

    const LOG_CATEGORY := "output"
    const POINT_ATTRIBS := ["N", "up", "pscale"]
    const FILTER_ATTRIB := "my_scatter"

    static func should_handle(summary: Dictionary) -> bool:
        return HEGoNodeUtil.output_has(summary, "has_points") \
            and HEGoNodeUtil.output_has_attribute(summary, "point_attributes", FILTER_ATTRIB)

    static func output_phase() -> String:
        return "my_scatter_output"

    static func handle(context: HEGoOutputContext) -> void:
        var selection = await context.select_points(FILTER_ATTRIB, PackedStringArray(POINT_ATTRIBS))
        if selection == null:
            return

        var groups = selection.split_by("my_group")
        for group_name in groups:
            var points = groups[group_name].get_points(PackedStringArray(POINT_ATTRIBS))
            for i in range(points["P"].size()):
                var node := context.place(str(group_name) + "/scatter", "scatter",
                    Node3D.new, true) as Node3D
                node.position = points["P"][i]

Four things matter here:

- **Ask for what you need, once.** ``load_attributes()`` is the only call that
  reaches Houdini. Use ``get_geo_output()`` / ``get_surface_output()``, not the
  deprecated fetch configs. See :doc:`geo_output`.
- **Say when you have nothing to do.** ``should_handle()`` keeps a cook from paying
  for a handler the HDA never feeds. ``HEGoNodeUtil.output_has()`` and
  ``output_has_attribute()`` follow the rule that anything unknown means run.
- **Own the nodes you create.** ``context.place()`` does this for you; if you parent a node
  yourself, ``context.own()`` is what makes it survive a scene save in the editor. A node
  without an owner silently disappears.
- **Log through** :ref:`HEGoLog<class_HEGoLog>` so your messages show up in the
  session panel next to HEGo's. See :doc:`logging`.

Shared helpers
--------------

``HEGoNodeUtil``
~~~~~~~~~~~~~~~~

.. list-table::
   :widths: 48 52

   * - ``await_task(host, task)``
     - Waits for a :ref:`HEGoTask<class_HEGoTask>`, returns its result or ``null``
   * - ``ensure_outputs_root(host)``
     - The ``Outputs`` node, created if missing
   * - ``ensure_parent_path(host, root, path_parts)``
     - Creates the intermediate ``Node3D``\ s of a path and returns the deepest one
   * - ``unique_child_name(parent, base_name)``
     - ``base_name``, or ``base_name_001`` and so on if taken
   * - ``set_editor_owner(host, node)``
     - Makes a spawned node part of the saved scene, in the editor only
   * - ``get_attrib_value(fetch_result, list_key, attr_name)``
     - Reads a named attribute out of a HAPI attribute list
   * - ``get_point_attrib(points, key, index, fallback)``
     - Element ``index`` of an attribute array, with a fallback for missing data
   * - ``get_typed_point_attrib(points, key, index, type, fallback)``
     - The same, but also falls back when the value is of the wrong type
   * - ``output_has(summary, key)``
     - Whether a cook produced a kind of geometry; unknown means yes
   * - ``output_has_attribute(summary, list_key, attribute)``
     - Whether the geometry carries an attribute; unknown means yes

``HEGoPropertyUtil``
~~~~~~~~~~~~~~~~~~~~

Applies the nested ``hego_custom_properties`` dictionary an HDA can attach to a
spawned point, instantiating sub-resources as it goes:
``apply_custom_properties(obj, properties)``, plus ``set_property()``,
``has_property()`` and ``is_compatible_type()`` if you want the pieces.

``HEGoCurveBuilder``
~~~~~~~~~~~~~~~~~~~~

Pure geometry, no scene access. ``build(curve)`` picks the right constructor for a
curve dictionary's type; ``build_linear_curve()``, ``build_nurbs_curve()`` and
``build_bezier_curve()`` are there individually, along with the spline evaluation
they use.

``HEGoTerrain3DUtil``
~~~~~~~~~~~~~~~~~~~~~

Everything the Terrain3D paths share: ``is_available()`` before anything else, then
layer and attribute lookups (``get_layer_by_name()``, ``get_attr_value()``),
texture layer collection and validation, control map encoding, and the heightfield
image rotation Houdini and Terrain3D disagree about.

Terrain3D is an optional addon, so none of this refers to its types directly;
everything goes through ``ClassDB`` and ``Object.call()``, and degrades to a warning
when the addon or a method is missing.

``HEGoCookTimings``
~~~~~~~~~~~~~~~~~~~

``begin_phase()`` / ``end_phase(name)`` around each phase, ``format_summary()`` at
the end. Phases print in the order they were recorded, so adding a handler needs no
change here.

Reusable pieces of the output handlers
--------------------------------------

Most handlers are just ``handle()``, but some expose parts worth calling directly:

- ``HEGoMeshOutput.save_mesh_resource(mesh, path)`` writes an ``ArrayMesh`` to disk,
  overwriting an existing one in place so scenes referencing it pick up the new
  geometry, and reports what went wrong rather than throwing.
- ``HEGoMeshOutput.fetch_meshes(context)`` returns ``{ mesh instance name: ArrayMesh }``
  with LODs and materials applied and nothing added to the scene, which is usually what a
  custom node wants; ``fetch_surface_groups(context)`` is the layer under it.
- ``HEGoMultiMeshOutput.setup_multimesh(context, mesh, name, points)`` builds one
  ``MultiMeshInstance3D`` from a point dictionary, if you want multimesh output
  without the fetch around it.
- ``HEGoInputNodes.sync(host, existing, path, settings)`` turns the Godot node at
  ``path`` into the input node its type needs, reusing ``existing`` when the type
  still matches.
