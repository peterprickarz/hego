HEGoNode3D
==========

Overview
--------

``HEGoNode3D`` is the default node you will use to bring an HDA into Godot.
This page focuses on ``HEGoNode3D`` data exchange, split into Inputs and Outputs.
Its properties and methods are listed in :ref:`the class reference<class_HEGoNode3D>`,
and what it does with them is :doc:`/api/node3d_modules`.

``HEGoNode3D`` supports:

- Feeding Path3D, :doc:`HEGoGraphInput3D <hego_graph_input_3d>`, MeshInstance3D, CSGShape3D, and Terrain3D into Houdini
- Generating bespoke geo as MeshInstance3D nodes, including LODs and material assignment
- Instancing meshes via MultiMeshInstance3D nodes
- Generating Terrain3D terrains from heightfields
- Spawning Terrain3D instancer content from points
- Spawning nodes by class name and setting most properties
- Spawning scenes by resource path

Usage
-----

Create a ``HEGoNode3D`` in your scene, open the HEGo bottom panel, assign an HDA, then recook.
Inputs are converted to Houdini data before cook, and outputs are regenerated after cook based on
attributes described below.

Including Children
------------------

In the bottom panel's **Inputs** section, enable **Include Children** for an HDA
input and drop a parent node into its path field. One parent can replace a long
list of individual sources, for example ``Inputs/Concrete`` on a concrete input.
The setting is saved with that input in the scene and restored when the panel
reopens. It is off by default for existing scenes.

Each cook discovers the selected nodes and their compatible descendants,
recursively and in scene-tree order. Supported sources are Path3D,
HEGoGraphInput3D, MeshInstance3D, CSGShape3D and Terrain3D. Empty mesh/path/graph
sources are skipped; hidden authoring sources are included. Adding, removing,
renaming or reparenting children takes effect on the next cook without editing
the list. Overlapping selections feed each source only once.

A CSG root is one baked assembly, including its Boolean operands; those operands
are not uploaded separately. The current generator's ``Outputs`` subtree is
excluded to prevent its own generated geometry feeding back into its input.

The adjacent **Visible** toggle shows or hides the referenced input nodes without
recooking or disabling them as Houdini inputs. A referenced 3D parent controls its
subtree while preserving its children's individual visibility flags. With mixed
visibility the control reads **Mixed**; click once to hide all, then again to show
all. It follows scene-tree visibility changes and supports editor undo/redo.
Visibility is stored on the scene nodes, not in the input settings. Ancestors that
are themselves hidden still need to be shown in the scene tree.

From code, use the same persisted setting the panel edits:

.. code-block:: gdscript

    input_stash = [{
        "inputs": ["../Inputs/Concrete"],
        "settings": {"include_children": true},
    }]

Custom cookers using ``HEGoAssetAgent.sync_inputs()`` get this behavior too.
``HEGoInputNodes.resolve_paths(host, paths, settings)`` exposes the same discovery
for any preprocessing a custom tool needs before cooking.

What a Cook Does
----------------

Every recook runs the same sequence, and the timing of each step is printed to the
session log when it finishes:

1. **Instantiate.** The HDA is created in the running session if it is not there yet,
   and the node's transform is sent across. On the first instantiation the parameters
   stashed in the scene are restored, which is how a cooked scene survives a session
   restart.
2. **Inputs.** Each Godot node wired to an input is converted and connected. See
   :doc:`Inputs <inputs/index>`.
3. **Cook.** Houdini does the work.
4. **Outputs.** The ``Outputs`` child is deleted and rebuilt from the cooked geometry.

.. warning::

   ``Outputs`` is destroyed and recreated on every cook. Anything you parent under it
   by hand disappears. Put your own nodes beside the ``HEGoNode3D``, not inside its
   output.

HEGo only runs the output handlers the cook actually fed: an HDA emitting a mesh does
not pay for the point, curve or terrain paths. Nothing is needed from you for that —
it is derived from the cooked geometry.

Cooking From Code
-----------------

``cook()`` is a coroutine, so a script can drive it:

.. code-block:: gdscript

    @tool
    extends Node3D

    @onready var hego_node: HEGoNode3D = $MyHDA

    func regenerate(seed_value: int) -> void:
        var asset_node := hego_node.hego_get_asset_node()
        await hego_node.agent.task(asset_node.set_parm("seed", seed_value))
        await hego_node.cook()
        # Outputs now exist under hego_node/Outputs

This is the same entry point the bottom panel's **Recook** button uses. For reading the
result yourself rather than letting the handlers build nodes, see
:doc:`Reading Output in Code </api/geo_output>`.

For a node that does something ``HEGoNode3D`` does not -- its own attributes, its own output
nodes, several HDAs chained together -- write your own rather than subclassing this one. It is
an ordinary script over the same helper and the same output library; see
:doc:`Writing Your Own Node </api/custom_nodes/index>`.

Inputs
------

The following sections describe what ``HEGoNode3D`` sends into Houdini when you connect different
Godot node types as HDA inputs.

Supported input types include Path3D, MeshInstance3D, CSGShape3D, and Terrain3D.

.. toctree::
   :maxdepth: 2

   inputs/index

Outputs
-------

The following sections describe output-side attributes read after cook. Choose the output type
that best fits your use case: geometry, instancing, object spawning, or Terrain3D.

.. toctree::
   :maxdepth: 2

   outputs/index

Parameters
----------

The following sections describe how HDA parameter UI is generated in the HEGo bottom panel,
which parameter families are supported, and known limitations.

.. toctree::
   :maxdepth: 2

   parameters/index
