Several HDAs in One Node
========================

Chaining needs nothing from HEGo beyond
:ref:`connect_input()<class_HEGoTransformableInputReceiverNode_method_connect_input>`. The
geometry never comes back to Godot in between — Houdini hands one node's output straight to
the next — and only the last stage is cooked, because cooking it makes Houdini pull
everything upstream.

.. code-block:: gdscript

    func cook() -> void:
        var base := agent.asset("Sop/my_base", "base")
        var detail := agent.asset("Sop/my_detail", "detail")

        agent.show_in_panel(["detail", "base"])

        if not await agent.instantiate(base, base_parm_stash):
            return
        if not await agent.instantiate(detail, detail_parm_stash):
            return

        await agent.task(detail.connect_input(base, 0))

        # Everything except the chained input still comes from the stash.
        await agent.sync_inputs(detail, [0])

        if await agent.task(detail.cook()) == null:
            return
        ...

    func hego_get_panel_assets() -> Array:
        return agent.panel_assets()

Without the agent this is the same code with the asset nodes as members and
``connect_input()`` awaited directly; nothing about chaining is the agent's doing. What the
agent adds is the panel's view of the stages:

.. code-block:: gdscript

    # agent.panel_assets() returns exactly this, built from show_in_panel() and highlight():
    func hego_get_panel_assets() -> Array:
        return [
            {"label": "detail", "asset": _detail, "highlight": false},
            {"label": "base", "asset": _base, "highlight": false},
        ]

Implementing ``hego_get_panel_assets()`` is the whole of what a multi-HDA node does
differently. The panel then shows one collapsible section per HDA, titled with its label, in
the order the array gives. An entry with ``"highlight": true`` is opened and scrolled to; the
panel notices within a quarter of a second, so a tool that moves the user on to its next
stage can point them at it from its own code.

Three things to watch for, none of which will raise an error
------------------------------------------------------------

- **The chained input must be skipped.** Without that input's index in the ``skip_indices``
  argument of ``agent.sync_inputs()``, the next cook replaces the chain with an empty merge
  node and the downstream HDA cooks nothing. Doing the inputs by hand, the equivalent is
  simply not building a merge chain for that index.
- **Every stage carries the node's transform.** ``agent.instantiate()`` does this, so call it
  for the upstream stages too; leaving one at the origin moves everything downstream by
  however far the node is from it. By hand, that is
  :ref:`set_transform()<class_HEGoTransformableNode_method_set_transform>` on every stage,
  not just the last.
- **The input rows belong to the node, not to one HDA.** There is one input stash, and the
  panel shows it against the first HDA you list — so list the stage that takes the inputs
  first.

Each stage keeps its own parameter blob. A preset belongs to the HDA it was read from, and
there is nothing sensible to do with another one's.
