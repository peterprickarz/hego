Writing Your Own Node
=====================

:doc:`HEGoNode3D </node_reference/hego_node_3d>` covers the great majority of tools. It picks
an HDA, shows its parameters in the bottom panel, feeds it the nodes you wire into its
inputs, cooks it and builds Godot nodes from whatever comes back.

Write your own node when you want something it does not do: your own attributes, your own
output nodes, exported properties instead of panel widgets, or several HDAs chained together.

What HEGo asks of a node
------------------------

Almost nothing. A custom node is an ordinary ``@tool`` script on whatever class suits it,
with a ``cook()`` method and however many of the
:doc:`bottom panel methods <bottom_panel>` you want. There is no base class to extend and no
interface to implement; HEGo never looks at your node's type.

Everything a cook does is a method on :ref:`HEGoAssetNode<class_HEGoAssetNode>`, and every
one of those returns a :doc:`task </api/task_pattern>` you await. That is the whole API.

Nothing in ``HEGoNode3D`` is privileged either. It is a GDScript file making the same calls,
so reading its ``cook()`` is a fair worked example.

A node, written out in full
---------------------------

This is a complete custom node with nothing helping it — one HDA, its parameters kept across
sessions, its mesh put on itself:

.. code-block:: gdscript

    @tool
    extends MeshInstance3D

    const ASSET_NAME := "Sop/my_fence"

    @export_tool_button("Cook", "Bake") var action_cook = func(): cook()
    ## The HDA's parameters as a blob, so they survive a session restart and a scene reload.
    @export var parm_stash: PackedByteArray

    # The asset node is a member, not a local: it carries the Houdini node id, and building a
    # new one every cook would leave the old Houdini node behind and lose its parameters.
    var _fence: HEGoAssetNode

    func cook() -> void:
        if _fence == null:
            _fence = HEGoAssetNode.new()
            _fence.op_name = ASSET_NAME

        var existed := _fence.get_id() >= 0

        await _wait(_fence.instantiate())
        await _wait(_fence.set_transform(global_transform))

        # Houdini reports a licence failure by succeeding with an id of -1, not by failing.
        if _fence.get_id() < 0:
            push_error("Could not instantiate " + _fence.op_name)
            return

        # Only on the cook that created it: restoring every time would undo whatever the
        # user has since changed in the panel.
        if not existed and parm_stash.size() > 0:
            await _wait(_fence.set_preset(parm_stash))

        if await _wait(_fence.cook()) == null:
            return

        var summary = await _wait(_fence.get_output_summary())
        var context := HEGoOutputContext.create(self, _fence, summary)

        var meshes := await HEGoMeshOutput.fetch_meshes(context)
        mesh = meshes.values()[0] if not meshes.is_empty() else null

        var preset = await _wait(_fence.get_preset())
        parm_stash = preset if preset is PackedByteArray else PackedByteArray()

    func _wait(task: HEGoTask) -> Variant:
        while task.get_status() < HEGoTask.COMPLETED:
            await get_tree().process_frame
        if task.get_status() == HEGoTask.FAILED:
            push_error(task.get_error_message())
            return null
        return task.get_result()

    # ── Bottom panel interface ──────────────────────────────────────────────
    func hego_use_bottom_panel() -> bool: return true
    func hego_get_asset_node() -> HEGoAssetNode: return _fence
    func hego_get_asset_name() -> String: return ASSET_NAME
    func hego_set_parm_stash(preset: PackedByteArray) -> void: parm_stash = preset

That node works, and nothing in HEGo treats it as a second-class citizen. Read it once: the
rest of this section is about the parts of it worth knowing, and about the object that will
write most of them for you.

The same node, with the agent
-----------------------------

:doc:`asset_agent` does the sequences above, and holds the asset node so you do not have to:

.. code-block:: gdscript

    @tool
    extends MeshInstance3D

    const ASSET_NAME := "Sop/my_fence"

    @export_tool_button("Cook", "Bake") var action_cook = func(): cook()
    @export var parm_stash: PackedByteArray

    var agent := HEGoAssetAgent.new(self)

    func cook() -> void:
        var fence := agent.asset(ASSET_NAME)
        if not await agent.instantiate(fence, parm_stash):
            return

        if await agent.task(fence.cook()) == null:
            return

        var meshes := await HEGoMeshOutput.fetch_meshes(await agent.output_context(fence))
        mesh = meshes.values()[0] if not meshes.is_empty() else null

        parm_stash = await agent.save_parameters(fence)

    func hego_use_bottom_panel() -> bool: return true
    func hego_get_asset_node() -> HEGoAssetNode: return agent.assets.get("my_fence")
    func hego_get_asset_name() -> String: return ASSET_NAME
    func hego_set_parm_stash(preset: PackedByteArray) -> void: parm_stash = preset

Same node, same calls, same order. **Using the agent is a convenience and nothing more** —
it is a GDScript file in the addon making the calls above, and every method it has is
written out by hand on :doc:`its page <asset_agent>`. Use it where it helps, do the work
yourself where you want the control, and mix the two freely in one ``cook()``.

The rest of this section
------------------------

.. toctree::
   :maxdepth: 1

   asset_agent
   bottom_panel
   several_hdas
   output

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
