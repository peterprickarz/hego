Terrain3D Input
===============

Terrain3D nodes are sent to Houdini as heightfield layers. Each layer represents a different
aspect of the terrain (height, hole mask, region map, and textures).

Layer Conversion
----------------

Terrain3D is sent as heightfield layers. The available layers include:

- ``height`` — Main height layer
- ``hegot3d_region_map`` — Region mask for controlling which areas are active
- ``hegot3d_hole`` — Hole mask for carving out terrain
- ``hegot3d_texture_layer_X`` — Texture paint layer (X = slot index 0–31)

Layer Metadata Attributes
--------------------------

All heightfield layers include the following metadata attributes:

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
