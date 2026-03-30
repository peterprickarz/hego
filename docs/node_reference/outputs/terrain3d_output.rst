Terrain3D Output
================

HEGo supports two different Terrain3D output modes: terrain generation and instancing on terrain.
You can use either mode independently or together in the same HDA.

If you are new to Terrain3D, read
`their documentation <https://terrain3d.readthedocs.io/en/stable/docs/introduction.html>`_
for extra context.

Terrain Generation
------------------

Terrain output is driven by heightfield layers and attributes. A Terrain3D node is created or
replaced at the target path on each cook.

Required Setup
~~~~~~~~~~~~~~

- Terrain3D addon must be installed
- Height layer must exist
- Height layer attribute ``hegot3d_spawn_terrain`` must be 1
- Height layer attribute ``hegot3d_data_directory`` must be a non-empty path

Height Layer Attributes
~~~~~~~~~~~~~~~~~~~~~~~

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

Control and Mask Layers
~~~~~~~~~~~~~~~~~~~~~~~

Optional layers that control terrain behavior:

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Layer Name
     - Description
   * - ``hegot3d_region_map``
     - Optional region mask. Regions with values < .5 will be skipped when creating Terrain3D regions
   * - ``hegot3d_hole``
     - Optional hole mask used when building Terrain3D control map bits

Texture Paint Layers
~~~~~~~~~~~~~~~~~~~~

Create layers named ``hegot3d_texture_layer_X`` where X is slot 0–31.
See the `Terrain3D documentation on texture assets <https://terrain3d.readthedocs.io/en/stable/api/class_terrain3dtextureasset.html#class-terrain3dtextureasset>`_
for details.

Each texture layer can contain the following attributes:

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

Texture Layer Notes
^^^^^^^^^^^^^^^^^^^

- All albedo textures must share the same resolution and format
- All normal textures must share the same resolution and format
- If validation fails, terrain height still imports, but control-map texturing is skipped

Color Map Layers
~~~~~~~~~~~~~~~~

Optional layers for storing color and roughness data:

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

Terrain Instancing
------------------

This output sends points into Terrain3D instancing (MultiMeshInstance3D) using scene resources.
This is independent from Terrain3D terrain generation — you can either generate a terrain and
spawn instances on it, or spawn instances on an existing Terrain3D.

Required Point Attributes
~~~~~~~~~~~~~~~~~~~~~~~~~~

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

Optional Transform and Color Attributes
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

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

Mesh Asset Settings
~~~~~~~~~~~~~~~~~~~

These attributes are read from the first point for each terrain node and scene resource path
combination, and applied to the generated Terrain3D mesh asset.
See the `Terrain3D mesh asset documentation <https://terrain3d.readthedocs.io/en/stable/api/class_terrain3dmeshasset.html#class-terrain3dmeshasset>`_
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
