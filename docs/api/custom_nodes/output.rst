Building Output From a Cook
===========================

Everything :doc:`HEGoNode3D </node_reference/hego_node_3d>` builds its output with is a
plain GDScript class you can call yourself. All of it takes a
:ref:`HEGoOutputContext<class_HEGoOutputContext>`, which carries the node the output goes
under, the HDA that produced it, and what that cook produced.

.. code-block:: gdscript

    # With the agent:
    var context := await agent.output_context(fence)

    # Without it, which is all that call is:
    var summary = await _wait(fence.get_output_summary())
    var context := HEGoOutputContext.create(self, fence, summary)

The library
-----------

.. list-table::
   :widths: 46 54

   * - ``HEGoMeshOutput.fetch_meshes(context)``
     - ``{ mesh instance name: ArrayMesh }``, with LODs and materials already applied,
       without touching the scene
   * - ``HEGoMeshOutput.fetch_surface_groups(context)``
     - The surfaces behind that, grouped by ``hego_mesh_instance`` and then
       ``hego_material``, for when your HDA tags its geometry with conventions of its own
   * - ``HEGoMeshOutput.handle(context)``
     - The whole standard mesh output: scene nodes, resource saving, collision
   * - ``HEGoMultiMeshOutput.setup_multimesh(context, mesh, name, points)``
     - One ``MultiMeshInstance3D`` from a point dictionary
   * - ``HEGoPointUtil.transform_from_point(points, index, position)``
     - The instance transform for one point, from ``N``, ``up``, ``pscale`` and ``scale``
   * - ``context.place(path, default_name, factory)``
     - A node under ``Outputs/``, created, named, parented and owned, reusing one that is
       already there and of the right class
   * - ``context.select_points(filter_attrib, attribs)``
     - The cook's points with those attributes loaded, filtered to the ones flagged

A node that puts the mesh straight onto itself, as the smallest demo does, needs only the
first of these. A node that wants the standard output entirely can run the handlers itself,
which is all ``HEGoNode3D`` does::

    var context := await agent.output_context(asset)
    for handler in [HEGoMeshOutput, HEGoMultiMeshOutput, HEGoCurveOutput]:
        if handler.should_handle(context.summary):
            await handler.handle(context)

Reading the geometry directly
-----------------------------

None of the above is required either. :doc:`/api/geo_output` is the layer underneath: points
and surfaces as they sit in C++, filtered and split without being copied into Godot until
you ask for them. Write against that when your HDA carries attributes of its own and no
built-in handler knows what to do with them.

Adding an output type
---------------------

To write a handler that ``HEGoNode3D`` and any other node can run, see
:doc:`/api/node3d_modules`.
