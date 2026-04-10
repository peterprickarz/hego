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
