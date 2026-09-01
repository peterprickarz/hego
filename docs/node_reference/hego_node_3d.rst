HEGoNode3D
==========

Overview
--------

``HEGoNode3D`` is the default node you will use to bring an HDA into Godot.
This page focuses on ``HEGoNode3D`` data exchange, split into Inputs and Outputs.

``HEGoNode3D`` supports:

- Feeding Path3D, MeshInstance3D, CSGShape3D, and Terrain3D into Houdini
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
        await _await_task(asset_node.set_parm("seed", seed_value))
        await hego_node.cook()
        # Outputs now exist under hego_node/Outputs

This is the same entry point the bottom panel's **Recook** button uses. For reading the
result yourself rather than letting the handlers build nodes, see
:doc:`Reading Output in Code </api/geo_output>`.

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
