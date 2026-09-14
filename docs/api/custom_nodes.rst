Writing Your Own Node
=====================

Overview
--------

:doc:`HEGoNode3D </node_reference/hego_node_3d>` covers the great majority of tools. It picks
an HDA, shows its parameters in the bottom panel, feeds it the nodes you wire into its
inputs, cooks it and builds Godot nodes from whatever comes back.

Write your own node when you want something it does not do: your own attributes, your own
output nodes, exported properties instead of panel widgets, or several HDAs chained together.
A custom node is an ordinary ``@tool`` script with a ``cook()`` that calls
:ref:`HEGoAssetNode<class_HEGoAssetNode>` directly. :ref:`HEGoHelpers<class_HEGoHelpers>`
supplies the parts that are tedious to repeat, and stays out of the way of everything else.

Nothing in ``HEGoNode3D`` is privileged. It uses the same helper, the same output handlers
and the same panel interface as a script of your own, so reading its ``cook()`` is a fair
worked example.

The shape of a custom node
--------------------------

.. code-block:: gdscript

    @tool
    extends MeshInstance3D
    class_name FenceTool

    const ASSET_NAME := "Sop/my_fence"
    const ASSET_LABEL := "fence"

    @export_tool_button("Cook", "Bake") var action_cook = func(): cook()
    ## The HDA's parameters as a blob, so they survive a session restart and a scene reload.
    @export var parm_stash: PackedByteArray
    ## References to the Godot nodes wired into the HDA's inputs.
    @export var input_stash: Array

    var hego := HEGoHelpers.new(self)

    func cook() -> void:
        var fence := hego.asset(ASSET_NAME, ASSET_LABEL)
        if not await hego.instantiate(fence, parm_stash):
            return

        await hego.sync_inputs(fence)

        if await hego.task(fence.cook()) == null:
            return

        var meshes := await HEGoMeshOutput.fetch_meshes(await hego.output_context(fence))
        mesh = meshes.values()[0] if not meshes.is_empty() else null

        parm_stash = await hego.save_parameters(fence)

    # ── Bottom panel interface ──────────────────────────────────────────────
    func hego_use_bottom_panel() -> bool: return true
    func hego_get_asset_node() -> HEGoAssetNode: return hego.assets.get(ASSET_LABEL)
    func hego_get_asset_name() -> String: return ASSET_NAME
    func hego_set_parm_stash(preset: PackedByteArray) -> void: parm_stash = preset
    func hego_get_input_stash() -> Array: return input_stash
    func hego_set_input_stash(rows: Array) -> void: input_stash = rows

That is the whole pattern. Everything the HDA does is a call on the asset node, in the order
you write it.

``HEGoHelpers``
---------------

One per node, constructed with the node itself: ``var hego := HEGoHelpers.new(self)``.
Every call below is on that object, and every one of them is awaited.

.. list-table::
   :widths: 46 54

   * - ``hego.task(task)``
     - Awaits a :ref:`HEGoTask<class_HEGoTask>` and returns its result, or ``null`` if it
       failed. Every method on an asset node hands back one of these, so this is what most
       lines of a ``cook()`` are wrapped in
   * - ``hego.asset(operator_name, label := "")``
     - The :ref:`HEGoAssetNode<class_HEGoAssetNode>` for an operator, created on first use and
       reused afterwards. Reusing it is what keeps the Houdini node id valid between cooks.
       The label names it in the panel and defaults to the operator without its table
   * - ``hego.instantiate(asset, stashed_parameters := PackedByteArray())``
     - Makes the HDA exist in Houdini, pushes this node's transform, and restores the stashed
       parameters **only** on the cook that created it. ``false`` when it could not be created
   * - ``hego.save_parameters(asset)``
     - The HDA's current parameters as a blob to store on the node
   * - ``hego.sync_inputs(asset, skip_indices := [])``
     - Feeds the HDA the Godot nodes in the input stash, one merge node per HDA input, reusing
       the input nodes between cooks. ``skip_indices`` holds the HDA input indices to leave
       alone, for inputs something else fills
   * - ``hego.set_input(index, sources)``
     - Points an HDA input at a node, a ``NodePath``, a path string, or an array of those,
       writing to the same stash the panel's Inputs pane uses
   * - ``hego.output_context(asset)``
     - Fetches what the cook produced and wraps it for the output library
   * - ``hego.assets``
     - Every asset this node has made, keyed by label, in creation order
   * - ``hego.show_in_panel(labels)``
     - Which HDAs the panel shows, in that order. The default is all of them
   * - ``hego.highlight(label)``
     - The HDA the panel should open and scroll to on its next rebuild

Two things are worth knowing about beforehand.

``await hego.task(...) == null`` is **not** a general failure check. A task that legitimately
did nothing also completes with ``null`` — that is what HEGo returns for work it could skip.
It *is* a failure check after :ref:`cook()<class_HEGoAssetNode_method_cook>`, because a
successful cook returns ``0`` and a cook Houdini rejects fails its task.

``hego.instantiate(asset)`` restores the stash only when it is the call that created the
Houdini node — not to be confused with
:ref:`asset.instantiate()<class_HEGoBaseNode_method_instantiate>`, the task it wraps, which
restores nothing. Restoring on every cook would undo whatever the user has since changed in
the panel.

The bottom panel interface
--------------------------

The panel drives whatever node is selected through these methods. Implement the ones you
want; there is no base class to inherit and no type check anywhere.

.. list-table::
   :widths: 40 60
   :header-rows: 1

   * - Method
     - Effect
   * - ``hego_use_bottom_panel() -> bool``
     - Required. Returning ``true`` is what puts this node in the panel at all
   * - ``cook() -> void``
     - What the Recook button calls
   * - ``hego_get_asset_node() -> HEGoAssetNode``
     - The HDA whose parameters the panel shows
   * - ``hego_get_asset_name() -> String``
     - The operator name, which the preset list is keyed by
   * - ``hego_set_parm_stash(preset: PackedByteArray)``
     - Where the panel writes parameters back after a cook or a preset load
   * - ``hego_get_input_stash() -> Array`` / ``hego_set_input_stash(rows: Array)``
     - The input rows, as ``{ "inputs": [...], "settings": {...} }`` per HDA input
   * - ``hego_set_asset_name(name: String)``
     - Implement this **only** if the HDA should be choosable in the panel. A node with its
       operator written into its script leaves it out and gets no picker button
   * - ``hego_get_panel_assets() -> Array``
     - For a node cooking several HDAs; see below

The panel waits for an HDA to exist in Houdini before asking it anything, so returning an
asset node that has not been instantiated yet is safe: the panel shows its "recook to see
parameters" hint instead.

Several HDAs in one node
------------------------

Chaining needs nothing from HEGo beyond
:ref:`connect_input()<class_HEGoTransformableInputReceiverNode_method_connect_input>`. The geometry never comes
back to Godot in between — Houdini hands one node's output straight to the next — and only
the last stage is cooked, because cooking it makes Houdini pull everything upstream.

.. code-block:: gdscript

    func cook() -> void:
        var base := hego.asset("Sop/my_base", "base")
        var detail := hego.asset("Sop/my_detail", "detail")

        hego.show_in_panel(["detail", "base"])

        if not await hego.instantiate(base, base_parm_stash):
            return
        if not await hego.instantiate(detail, detail_parm_stash):
            return

        await hego.task(detail.connect_input(base, 0))

        # Everything except the chained input still comes from the stash.
        await hego.sync_inputs(detail, [0])

        if await hego.task(detail.cook()) == null:
            return
        ...

    func hego_get_panel_assets() -> Array:
        return hego.panel_assets()

Implementing ``hego_get_panel_assets()`` is the whole of what a multi-HDA node does
differently. The panel then shows one collapsible section per HDA, titled with its label, in
the order ``hego.show_in_panel()`` gave. ``hego.highlight(label)`` marks one to be opened and scrolled
to; the panel notices within a quarter of a second, so a tool that moves the user on to its
next stage can point them at it from its own code.

Three things to watch for, none of which will raise an error:

- **The chained input must be skipped.** Without that input's index in the
  ``skip_indices`` argument of ``hego.sync_inputs()``, the next cook replaces the chain with
  an empty merge node and the downstream HDA cooks nothing.
- **Every stage carries the node's transform.** ``hego.instantiate()`` does this, so call it
  for the upstream stages too; leaving one at the origin moves everything downstream by
  however far the node is from it.
- **The input rows belong to the node, not to one HDA.** There is one input stash, and the
  panel shows it against the first HDA you list — so list the stage that takes the inputs
  first.

Each stage keeps its own parameter blob. A preset belongs to the HDA it was read from, and
there is nothing sensible to do with another one's.

Using the output library
------------------------

The classes :doc:`HEGoNode3D builds its output with <node3d_modules>` are all callable
directly, and take a :ref:`HEGoOutputContext<class_HEGoOutputContext>` — what
``hego.output_context(asset)`` returns.

.. list-table::
   :widths: 46 54

   * - ``HEGoMeshOutput.fetch_meshes(context)``
     - ``{ mesh instance name: ArrayMesh }``, with LODs and materials already applied, without
       touching the scene
   * - ``HEGoMeshOutput.fetch_surface_groups(context)``
     - The surfaces behind that, grouped by ``hego_mesh_instance`` and then ``hego_material``,
       for when your HDA tags its geometry with conventions of its own
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

A node that wants the standard output entirely can run the handlers itself, which is all
``HEGoNode3D`` does::

    var context := await hego.output_context(asset)
    for handler in [HEGoMeshOutput, HEGoMultiMeshOutput, HEGoCurveOutput]:
        if handler.should_handle(context.summary):
            await handler.handle(context)

To add an output type of your own, see :doc:`node3d_modules`.

Demos to read
-------------

All of these are in ``demo/`` and all of them cook against a live session.

.. list-table::
   :widths: 34 66

   * - ``pighead_tool.gd``
     - The smallest complete node: one HDA, one mesh, a dozen lines
   * - ``HDACurveTest.gd``
     - Takes its input from an exported ``Path3D`` and wires the curve input itself
   * - ``hego_ScifiPanelGenerator.gd``
     - Several input meshes through one HDA input, and its own material mapping
   * - ``hda_nodes/hda_test_scatter_nodes.gd``
     - Exported properties driving HDA parameters, points to a ``MultiMesh``
   * - ``chained_hdas.gd``
     - Two HDAs chained in Houdini, with panel sections and stage buttons
