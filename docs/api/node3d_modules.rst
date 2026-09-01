HEGoNode3D Modules
==================

Overview
--------

:doc:`HEGoNode3D </node_reference/hego_node_3d>` orchestrates a cook; the work lives
in modules under ``addons/hego/node3d/``. Each is a plain GDScript class of static
functions, so you can call them from your own scripts, replace one of them, or read
one to see how an output type is built.

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
   * - ``HEGoTerrain3DUtil``
     - Terrain3D helpers shared by input, output and instancing
   * - ``HEGoTerrain3DOutput``
     - Heightfield layers to a Terrain3D node
   * - ``HEGoTerrain3DInstancer``
     - Points to Terrain3D instancer transforms
   * - ``HEGoTerrain3DInput``
     - An existing Terrain3D to heightfield layers for Houdini

Every output handler exposes the same two entry points: ``should_handle(summary)``,
which decides from :ref:`get_output_summary()<class_HEGoAssetNode_method_get_output_summary>`
whether the cook produced anything it cares about, and ``handle(host)``, which does
the work. :doc:`HEGoNode3D </node_reference/hego_node_3d>` asks for the summary once, then calls
each handler that wants it and times them all.

Writing your own output handler
-------------------------------

The shape to copy, in a script of your own. Mark it ``@tool`` so it runs in the
editor, as every HEGo handler does:

.. code-block:: gdscript

    class_name MyScatterOutput
    extends RefCounted

    const LOG_CATEGORY := "output"
    const POINT_ATTRIBS := ["N", "up", "pscale"]
    const FILTER_ATTRIB := "my_scatter"

    static func should_handle(summary: Dictionary) -> bool:
        return HEGoNodeUtil.output_has(summary, "has_points") \
            and HEGoNodeUtil.output_has_attribute(summary, "point_attributes", FILTER_ATTRIB)

    static func handle(host: Node) -> void:
        var output = await HEGoNodeUtil.await_task(host, host.hego_asset_node.get_geo_output())
        if output == null or not output.is_valid():
            return

        await HEGoNodeUtil.await_task(host,
            output.load_attributes(PackedStringArray(POINT_ATTRIBS + [FILTER_ATTRIB])))

        var groups = output.filter_by(FILTER_ATTRIB, 1).split_by("my_group")
        for group_name in groups:
            var points = groups[group_name].get_points(PackedStringArray(POINT_ATTRIBS))
            var parent = HEGoNodeUtil.ensure_parent_path(
                host, HEGoNodeUtil.ensure_outputs_root(host), PackedStringArray([str(group_name)]))

            for i in range(points["P"].size()):
                var node := Node3D.new()
                node.name = HEGoNodeUtil.unique_child_name(parent, "scatter")
                node.position = points["P"][i]
                parent.add_child(node)
                HEGoNodeUtil.set_editor_owner(host, node)

Four things matter here:

- **Ask for what you need, once.** ``load_attributes()`` is the only call that
  reaches Houdini. Use ``get_geo_output()`` / ``get_surface_output()``, not the
  deprecated fetch configs. See :doc:`geo_output`.
- **Say when you have nothing to do.** ``should_handle()`` keeps a cook from paying
  for a handler the HDA never feeds. ``HEGoNodeUtil.output_has()`` and
  ``output_has_attribute()`` follow the rule that anything unknown means run.
- **Own the nodes you create.** ``set_editor_owner()`` is what makes them survive a
  scene save in the editor; a node without an owner silently disappears.
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
   * - ``get_attrib_value(dict, dict_key, attr_name)``
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

Most handlers are just ``handle()``, but two expose parts worth calling directly:

- ``HEGoMeshOutput.save_mesh_resource(mesh, path)`` writes an ``ArrayMesh`` to disk,
  overwriting an existing one in place so scenes referencing it pick up the new
  geometry, and reports what went wrong rather than throwing.
- ``HEGoMultiMeshOutput.setup_multimesh(host, mesh, name, points)`` builds one
  ``MultiMeshInstance3D`` from a point dictionary, if you want multimesh output
  without the fetch around it.
- ``HEGoInputNodes.sync(host, existing, path, settings)`` turns the Godot node at
  ``path`` into the input node its type needs, reusing ``existing`` when the type
  still matches.
