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

This section describes what ``HEGoNode3D`` sends into Houdini when you connect different Godot
node types as HDA inputs.

Supported Input Types
~~~~~~~~~~~~~~~~~~~~~

- Path3D
- MeshInstance3D
- CSGShape3D
- Terrain3D (if Terrain3D addon is installed)

Path3D Input
~~~~~~~~~~~~

Path3D is sent as a curve input.

.. list-table::
   :header-rows: 1
   :widths: 20 20 60

   * - Input Type
     - Houdini Data
     - Description
   * - Path3D
     - Curve
     - Path3D is converted to a curve for Houdini input

No special HEGo metadata attributes are added for Path3D inputs.

MeshInstance3D and CSGShape3D Inputs
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

MeshInstance3D and CSGShape3D are sent as mesh geometry. CSGShape3D is converted to mesh first.

The following attributes are available on the Houdini side:

.. list-table::
   :header-rows: 1
   :widths: 32 18 12 38

   * - Attribute Name
     - Attribute Type
     - Owner
     - Description
   * - ``P``
     - Float3
     - Point
     - Point positions
   * - ``Cd``
     - Float3
     - Point
     - Vertex color input. If no source color exists, defaults to white
   * - ``_hego_surface_id``
     - Int
     - Prim
     - Surface index of each primitive (useful for per-surface logic)
   * - ``_hego_surface_material``
     - String
     - Prim
     - Material path for each primitive surface (or empty)
   * - ``_hego_node_path``
     - String
     - Prim
     - Godot scene path of the source node

MeshInstance3D inputs can also include:

.. list-table::
   :header-rows: 1
   :widths: 42 15 12 31

   * - Attribute Name
     - Attribute Type
     - Owner
     - Description
   * - ``_hego_resource_path``
     - String
     - Prim
     - Mesh resource path from the source MeshInstance3D
   * - ``_hego_surface_override_material_i``
     - String
     - Prim
     - Per-surface override material path (index i), or empty if unset

Terrain3D Input
~~~~~~~~~~~~~~~

Terrain3D is sent as heightfield layers.

Possible layer names include:

- ``height``
- ``hegot3d_region_map``
- ``hegot3d_hole``
- ``hegot3d_texture_layer_X`` (X = texture slot index)

Layer metadata attributes:

.. list-table::
   :header-rows: 1
   :widths: 25 18 22 35

   * - Attribute Name
     - Attribute Type
     - Owner
     - Description
   * - ``_hego_node_path``
     - String
     - Layer attrs
     - Source Terrain3D node path
   * - ``_hego_texture_name``
     - String
     - Layer attrs
     - Texture name for ``hegot3d_texture_layer_X`` (when available)

Outputs
-------

All tables below describe output-side attributes read after cook.

Bespoke Geo
~~~~~~~~~~~

By default, mesh output is created on the Godot side as ``MeshInstance3D``.
Vertex attributes are not supported directly. Promote common vertex attributes
(``N``, ``Cd``, ``uv``, ``uv2``) to point attributes, and split points where needed.

.. list-table::
   :header-rows: 1
   :widths: 27 15 15 43

   * - Attribute Name
     - Attribute Type
     - Attribute Owner
     - Description
   * - ``N``
     - Vector
     - Point
     - Mesh normals
   * - ``Cd``
     - Vector
     - Point
     - Vertex colors
   * - ``uv``
     - Vector
     - Point
     - First UV channel
   * - ``uv2``
     - Vector
     - Point
     - Second UV channel
   * - ``tangentu``
     - Vector
     - Point
     - Tangent U. If missing, Godot can generate tangents
   * - ``tangentv``
     - Vector
     - Point
     - Tangent V. If missing, Godot can generate tangents
   * - ``hego_lod``
     - Float
     - Prim
     - LOD switch distance value in range 0–1. Most detailed mesh should be 0
   * - ``hego_mesh_instance``
     - String
     - Prim
     - Output node path/name under HEGoNode3D/Outputs. One HDA can create multiple meshes, split by this path attribute
   * - ``hego_material``
     - String
     - Prim
     - Material resource path assigned
   * - ``hego_storage_mode``
     - Int
     - Prim
     - 0 = MeshInstance3D in scene, 1 = save as resource only, 2 = save as resource and spawn MeshInstance3D
   * - ``hego_resource_save_path``
     - String
     - Prim
     - Mesh resource save path when ``hego_storage_mode`` > 0

You can split one output into multiple meshes by assigning different
``hego_mesh_instance`` paths across primitives.

Instancing
~~~~~~~~~~

Use these attributes to create ``MultiMeshInstance3D`` output.

.. list-table::
   :header-rows: 1
   :widths: 27 15 15 43

   * - Attribute Name
     - Attribute Type
     - Attribute Owner
     - Description
   * - ``N``
     - Vector
     - Point
     - Forward direction (positive Z)
   * - ``Cd``
     - Vector
     - Point
     - Per-instance color (enables MultiMesh colors)
   * - ``up``
     - Vector
     - Point
     - Up vector (Copy to Points style)
   * - ``pscale``
     - Float
     - Point
     - Uniform scale
   * - ``scale``
     - Vector
     - Point
     - Non-uniform scale, multiplied by pscale
   * - ``hego_use_multimesh``
     - Int
     - Point
     - Required. Set to 1 to enable MultiMesh output
   * - ``hego_multimesh``
     - String
     - Point
     - Target node path under HEGoNode3D/Outputs
   * - ``hego_mesh_resource``
     - String
     - Point
     - Mesh resource path to instance

You can split one output into multiple MultiMesh instancers by assigning different
``hego_multimesh`` paths across points.

Object Spawning
~~~~~~~~~~~~~~~

Use these attributes to spawn arbitrary Node3D objects or scenes.

.. list-table::
   :header-rows: 1
   :widths: 30 15 15 40

   * - Attribute Name
     - Attribute Type
     - Attribute Owner
     - Description
   * - ``N``
     - Vector
     - Point
     - Forward direction (positive Z)
   * - ``up``
     - Vector
     - Point
     - Up vector
   * - ``pscale``
     - Float
     - Point
     - Uniform scale
   * - ``scale``
     - Vector
     - Point
     - Non-uniform scale, multiplied by pscale
   * - ``hego_spawn``
     - Int
     - Point
     - Required. Set to 1 to enable object spawning
   * - ``hego_spawn_type``
     - Int
     - Point
     - 0 = spawn registered class, 1 = spawn PackedScene by path
   * - ``hego_class_name``
     - String
     - Point
     - Class name when ``hego_spawn_type`` = 0
   * - ``hego_resource_path``
     - String
     - Point
     - Scene resource path when ``hego_spawn_type`` = 1
   * - ``hego_node_path``
     - String
     - Point
     - Spawn path under HEGoNode3D/Outputs. Make unique per point to avoid name conflicts
   * - ``hego_custom_properties``
     - Dictionary
     - Point
     - Nested property assignment dictionary using ``hego_val`` entries

``hego_custom_properties`` can set almost any property on spawned objects. It must follow a
specific dictionary format:

- Each top-level key is a property name.
- The value must be another dictionary containing at least ``hego_val``.
- Additional nested keys can define sub-properties for complex value types.

This allows creating objects and configuring them in one pass. Example:

.. code-block:: json

   {
     "shape": {
       "hego_val": "CapsuleShape3D",
       "height": {"hego_val": 0.72},
       "radius": {"hego_val": 0.5}
     }
   }

The example creates a ``CapsuleShape3D``, sets ``height`` and ``radius``, and assigns it to the
target node's ``shape`` property.

Terrain3D Terrain Output
~~~~~~~~~~~~~~~~~~~~~~~~

Terrain output is driven by heightfield layers and attributes. A Terrain3D node is created or
replaced at the target path on each cook.

If you are new to Terrain3D, read
`their documentation <https://terrain3d.readthedocs.io/en/stable/docs/introduction.html>`_
for extra context.

Required setup:

- Terrain3D addon must be installed
- Height layer must exist
- Height layer attribute ``hegot3d_spawn_terrain`` must be 1
- Height layer attribute ``hegot3d_data_directory`` must be a non-empty path

**Height layer attributes**

.. list-table::
   :header-rows: 1
   :widths: 28 15 22 35

   * - Attribute Name
     - Attribute Type
     - Attribute Owner
     - Description
   * - ``hegot3d_spawn_terrain``
     - Int
     - Prim (height layer)
     - Required trigger. 1 enables Terrain3D generation
   * - ``hegot3d_data_directory``
     - String
     - Prim (height layer)
     - Required Terrain3D data directory. *NOTE: OUTPUT WILL OVERWRITE EXISTING DATA*
   * - ``hegot3d_node_path``
     - String
     - Prim (height layer)
     - Optional node path. Default is ``Terrain3D``
   * - ``hegot3d_region_size``
     - Int
     - Prim (height layer)
     - Optional region size. Must be power-of-two between 64 and 2048. Default is 256

**Optional control and mask layers**

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Layer Name
     - Description
   * - ``hegot3d_region_map``
     - Optional region mask. Regions with values < .5 will be skipped when creating Terrain3D regions
   * - ``hegot3d_hole``
     - Optional hole mask used when building Terrain3D control map bits

**Optional texture paint layers**

Create layers named ``hegot3d_texture_layer_X`` where X is slot 0–31.
Please check the
`Terrain3D documentation on texture assets <https://terrain3d.readthedocs.io/en/stable/api/class_terrain3dtextureasset.html#class-terrain3dtextureasset>`_
for details. Each such layer can contain the following attributes:

.. list-table::
   :header-rows: 1
   :widths: 30 12 20 8 30

   * - Attribute Name
     - Attribute Type
     - Attribute Owner
     - Required
     - Description
   * - ``hegot3d_albedo_texture``
     - String
     - Prim (texture layer)
     - Yes
     - Path to the albedo texture resource used for this Terrain3D texture slot
   * - ``hegot3d_normal_texture``
     - String
     - Prim (texture layer)
     - Yes
     - Path to the normal texture resource used for this Terrain3D texture slot
   * - ``hegot3d_ao_strength``
     - Float
     - Prim (texture layer)
     - No
     - AO strength value passed to the Terrain3D texture asset
   * - ``hegot3d_detiling_rotation``
     - Float
     - Prim (texture layer)
     - No
     - Detiling rotation value passed to the Terrain3D texture asset
   * - ``hegot3d_detiling_shift``
     - Float
     - Prim (texture layer)
     - No
     - Detiling shift value passed to the Terrain3D texture asset
   * - ``hegot3d_id``
     - Int
     - Prim (texture layer)
     - No
     - Texture id value passed to the Terrain3D texture asset
   * - ``hegot3d_name``
     - String
     - Prim (texture layer)
     - No
     - Display name value passed to the Terrain3D texture asset
   * - ``hegot3d_normal_depth``
     - Float
     - Prim (texture layer)
     - No
     - Normal depth value passed to the Terrain3D texture asset
   * - ``hegot3d_roughness``
     - Float
     - Prim (texture layer)
     - No
     - Roughness value passed to the Terrain3D texture asset
   * - ``hegot3d_uv_scale``
     - Float
     - Prim (texture layer)
     - No
     - UV scale value passed to the Terrain3D texture asset

Notes:

- All albedo textures must share same resolution and format
- All normal textures must share same resolution and format
- If validation fails, terrain height still imports, but control-map texturing is skipped

**Optional color map layers**

.. list-table::
   :header-rows: 1
   :widths: 35 65

   * - Layer Name
     - Description
   * - ``hegot3d_color_map_r``
     - Red channel
   * - ``hegot3d_color_map_g``
     - Green channel
   * - ``hegot3d_color_map_b``
     - Blue channel
   * - ``hegot3d_color_map_roughness``
     - Roughness channel (alpha)

Terrain3D Instancer Output
~~~~~~~~~~~~~~~~~~~~~~~~~~

This output sends points into Terrain3D instancing (MMI) using scene resources. This is
independent from Terrain3D terrain generation — you can either generate a terrain and spawn
instances on it, or spawn instances on an existing Terrain3D.

**Required point attributes**

.. list-table::
   :header-rows: 1
   :widths: 37 12 14 37

   * - Attribute Name
     - Attribute Type
     - Attribute Owner
     - Description
   * - ``hegot3d_use_terrain3d_instancer``
     - Int
     - Point
     - Required trigger. Set to 1
   * - ``hegot3d_terrain3d_node_path``
     - String
     - Point
     - Required. Target Terrain3D node path. Can be relative to the HEGoNode3D or to the scene
   * - ``hegot3d_scene_resource_path``
     - String
     - Point
     - Required. PackedScene path to instance
   * - ``P``
     - Vector
     - Point
     - Required position

**Optional transform and color attributes**

.. list-table::
   :header-rows: 1
   :widths: 20 15 15 50

   * - Attribute Name
     - Attribute Type
     - Attribute Owner
     - Description
   * - ``N``
     - Vector
     - Point
     - Forward direction (default 0,0,1)
   * - ``up``
     - Vector
     - Point
     - Up vector (default 0,1,0)
   * - ``scale``
     - Vector
     - Point
     - Non-uniform scale (default 1,1,1)
   * - ``pscale``
     - Float
     - Point
     - Uniform scale multiplier (default 1.0)
   * - ``Cd``
     - Vector/Color
     - Point
     - Optional per-instance color

**Optional Terrain3D mesh-asset settings**

These are read from the first point for each terrain node and scene resource path combination,
and applied to the generated Terrain3D mesh asset.
See the
`Terrain3D mesh asset documentation <https://terrain3d.readthedocs.io/en/stable/api/class_terrain3dmeshasset.html#class-terrain3dmeshasset>`_
for details on each setting.

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Attribute Name
     - Description
   * - ``hegot3d_lod0_range``
     - LOD 0 distance range
   * - ``hegot3d_lod1_range``
     - LOD 1 distance range
   * - ``hegot3d_lod2_range``
     - LOD 2 distance range
   * - ``hegot3d_lod3_range``
     - LOD 3 distance range
   * - ``hegot3d_lod4_range``
     - LOD 4 distance range
   * - ``hegot3d_lod5_range``
     - LOD 5 distance range
   * - ``hegot3d_lod6_range``
     - LOD 6 distance range
   * - ``hegot3d_lod7_range``
     - LOD 7 distance range
   * - ``hegot3d_lod8_range``
     - LOD 8 distance range
   * - ``hegot3d_lod9_range``
     - LOD 9 distance range
   * - ``hegot3d_shadow_impostor``
     - Shadow impostor behavior
   * - ``hegot3d_last_lod``
     - Last visible LOD
   * - ``hegot3d_last_shadow_lod``
     - Last shadow LOD
   * - ``hegot3d_fade_margin``
     - LOD fade margin
