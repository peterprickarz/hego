The Asset Agent
===============

:ref:`HEGoAssetAgent<class_HEGoAssetAgent>` holds the Houdini-side objects belonging to one
Godot node and does the fiddly parts of driving them. One per node, constructed with the
node itself::

    var agent := HEGoAssetAgent.new(self)

It is optional. Every method below is a short sequence of ordinary
:ref:`HEGoAssetNode<class_HEGoAssetNode>` calls, and each is written out here as the code you
would write instead. Two of those sequences are easy to get silently wrong, which is the
honest reason the agent exists; the rest are just repetitive.

What it holds, and why that matters
-----------------------------------

The part you cannot skip by not using an agent is the *keeping*. Three things have to survive
from one cook to the next:

- **The asset nodes**, keyed by label. A :ref:`HEGoAssetNode<class_HEGoAssetNode>` carries
  the Houdini node id, so building a new one each cook abandons the Houdini node along with
  its parameters and makes a second one beside it.
- **The merge node** behind each HDA input, for the same reason.
- **The input nodes** behind each merge node, so geometry that has not changed is not sent
  to Houdini again.

Without an agent these are members of your script. With one they are
:ref:`agent.assets<class_HEGoAssetAgent_property_assets>` and its private input table. Either
way, a local variable is the wrong place for them.

.. list-table::
   :widths: 46 54
   :header-rows: 1

   * - Method
     - What it does
   * - ``agent.task(task)``
     - Awaits a :ref:`HEGoTask<class_HEGoTask>` and returns its result, or ``null`` if it
       failed
   * - ``agent.asset(operator_name, label := "")``
     - The :ref:`HEGoAssetNode<class_HEGoAssetNode>` for an operator, created on first use
       and reused afterwards
   * - ``agent.instantiate(asset, stashed_parameters := PackedByteArray())``
     - Makes the HDA exist in Houdini, pushes this node's transform, and restores the
       stashed parameters on the cook that created it. ``false`` when it could not be created
   * - ``agent.save_parameters(asset)``
     - The HDA's current parameters as a blob to store on the node
   * - ``agent.sync_inputs(asset, skip_indices := [])``
     - Feeds the HDA the Godot nodes in the input stash, one merge node per HDA input
   * - ``agent.set_input(index, sources)``
     - Points an HDA input at a node, a ``NodePath``, a path string, or an array of those
   * - ``agent.output_context(asset)``
     - Fetches what the cook produced and wraps it for the :doc:`output library <output>`
   * - ``agent.assets``
     - Every asset this node has made, keyed by label, in creation order
   * - ``agent.show_in_panel(labels)`` / ``agent.highlight(label)``
     - Which HDAs the panel shows and which it opens; see :doc:`several_hdas`

Each of them, by hand
---------------------

``agent.task(task)``
~~~~~~~~~~~~~~~~~~~~

Waits for a task and returns its result, or ``null`` if it failed.

.. code-block:: gdscript

    # Identical, as a static call, with no agent involved:
    var result = await HEGoNodeUtil.await_task(self, some_task)

    # Or in full, which is all either of them is:
    func _wait(task: HEGoTask) -> Variant:
        while task.get_status() < HEGoTask.COMPLETED:
            await get_tree().process_frame
        if task.get_status() == HEGoTask.FAILED:
            push_error(task.get_error_message())
            return null
        return task.get_result()

``await agent.task(...) == null`` is **not** a general failure check. A task that legitimately
did nothing also completes with ``null`` — that is what HEGo returns for work it could skip.
It *is* a failure check after :ref:`cook()<class_HEGoAssetNode_method_cook>`, because a
successful cook returns ``0`` and a cook Houdini rejects fails its task.

``agent.asset(operator_name, label)``
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Returns the asset node for an operator, making it on first use and handing back the same one
afterwards. The label names it in the bottom panel and defaults to the operator without its
table, so ``"Sop/my_fence"`` is labelled ``my_fence``.

.. code-block:: gdscript

    # By hand: a member, so the Houdini node id survives the cook.
    var _fence: HEGoAssetNode

    func _asset() -> HEGoAssetNode:
        if _fence == null:
            _fence = HEGoAssetNode.new()
            _fence.op_name = "Sop/my_fence"   # the agent prefixes "Sop/" if you leave it off
        return _fence

The agent does one thing more, which only matters if your node can change its HDA: when a
label is asked for with a different operator than last time, it calls
:ref:`reset_node_id()<class_HEGoBaseNode_method_reset_node_id>` before changing ``op_name``.
Without that the node keeps cooking the old HDA.

``agent.instantiate(asset, stashed_parameters)``
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

One of the two worth reading closely.

.. code-block:: gdscript

    # By hand:
    var existed := _fence.get_id() >= 0

    await _wait(_fence.instantiate())
    await _wait(_fence.set_transform(global_transform))   # spatial nodes only

    if _fence.get_id() < 0:
        push_error("Could not instantiate " + _fence.op_name)
        return    # the agent returns false here

    if not existed and parm_stash.size() > 0:
        await _wait(_fence.set_preset(parm_stash))

Three things in there are not obvious:

- **A licence failure looks like success.** Houdini reports it by completing the task with
  an id of ``-1`` rather than by failing, so checking the task is not enough; check the id.
- **An unknown operator name is not caught here at all.** Houdini hands back a valid id for
  one, and the *cook* is what rejects it.
- **The stash is restored only on the cook that created the node.** Restoring it every cook
  would undo whatever the user has since changed in the bottom panel.

``agent.save_parameters(asset)``
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

.. code-block:: gdscript

    # By hand:
    var preset = await _wait(_fence.get_preset())
    parm_stash = preset if preset is PackedByteArray else PackedByteArray()

Call it at the end of every cook. The blob is what survives a session restart and a scene
reload, and it is the same format the panel's presets are stored in.

``agent.sync_inputs(asset, skip_indices)``
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The longest one. Every HDA input goes through a merge node, because one Houdini input can
combine several Godot nodes:

.. code-block:: gdscript

    # By hand, for HDA input 0:
    var _merge: HEGoMergeNode
    var _input_nodes: Array = []

    func _sync_input_0(paths: Array, settings := {}) -> void:
        if _merge == null:
            _merge = HEGoMergeNode.new()
        await _wait(_merge.instantiate())

        # Resizing first drops the input nodes whose source is gone and pads with nulls;
        # passing the existing node back into sync() is what reuses it rather than
        # re-sending geometry that has not changed.
        _input_nodes.resize(paths.size())
        for i in range(paths.size()):
            _input_nodes[i] = await HEGoInputNodes.sync(self, _input_nodes[i], paths[i], settings)

        await _wait(_merge.connect_inputs(_input_nodes))
        await _wait(_fence.connect_input(_merge, 0))

:ref:`HEGoInputNodes.sync()<class_HEGoInputNodes_method_sync>` is what turns a Godot node
into the input node its type needs — ``Path3D`` into a curve input, ``MeshInstance3D`` or
``CSGShape3D`` into a mesh input, ``Terrain3D`` into a heightfield input — and it is worth
calling whether or not you use an agent.

The agent does this for every input the HDA has, reading the paths from the node's input
stash so the bottom panel's Inputs pane and your script write to the same place.
``skip_indices`` names the HDA input indices to leave alone, which is how an input fed by
another HDA survives; see :doc:`several_hdas`.

``agent.set_input(index, sources)``
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The other one worth reading closely, for one line of it.

.. code-block:: gdscript

    # By hand: an input row is { "inputs": [path strings], "settings": {} } per HDA input.
    var path := get_tree().edited_scene_root.get_path_to(some_node)
    input_stash = [{"inputs": [str(path)], "settings": {}}]

The paths must be **relative to the edited scene root**, which is the form the panel's Inputs
pane writes and the form HEGo resolves them in. ``get_path_to(node)`` from your own node
gives a path that resolves in the editor and not at runtime, and nothing reports it.

.. warning::

   ``agent.set_input()`` and ``agent.sync_inputs()`` reach the stash **through your node**,
   using :doc:`hego_get_input_stash() and hego_set_input_stash() <bottom_panel>`. A node that
   does not implement both gets no error: ``set_input()`` discards the row it built,
   ``sync_inputs()`` finds no rows, and the HDA cooks with its inputs unconnected.

   The cook then **succeeds** and produces nothing, so ``await agent.task(asset.cook()) ==
   null`` does not catch it either; the only sign is a line like *"Not enough sources
   specified"* from Houdini in the session log. An exported ``input_stash`` array is not
   enough on its own — those two methods are what the agent looks for.

``agent.output_context(asset)``
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

.. code-block:: gdscript

    # By hand:
    var summary = await _wait(_fence.get_output_summary())
    var context := HEGoOutputContext.create(self, _fence, summary)

See :doc:`output` for what to do with it.
