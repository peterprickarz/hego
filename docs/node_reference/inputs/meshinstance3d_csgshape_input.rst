MeshInstance3D and CSGShape3D Inputs
=====================================

Both MeshInstance3D and CSGShape3D are sent to Houdini as mesh geometry. CSGShape3D nodes
are automatically converted to mesh format before transmission.

Conversion
----------

MeshInstance3D and CSGShape3D are sent as mesh geometry. CSGShape3D is converted to mesh first.

Common Attributes
-----------------

The following attributes are available on the Houdini side for both input types:

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

MeshInstance3D-Specific Attributes
-----------------------------------

MeshInstance3D inputs include additional attributes:

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
