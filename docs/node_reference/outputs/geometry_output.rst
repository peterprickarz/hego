Geometry Output
===============

By default, mesh output is created on the Godot side as ``MeshInstance3D`` nodes. This output
type is used for creating custom mesh geometry with properties like LODs, materials, and
collision shapes.

Mesh Creation
-------------

Vertex attributes are not supported directly. Promote common vertex attributes
(``N``, ``Cd``, ``uv``, ``uv2``) to point attributes, and split points where needed.

Point Attributes
----------------

Common vertex data is specified via point attributes:

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

Primitive Attributes
--------------------

Mesh output is controlled by primitive attributes:

.. list-table::
   :header-rows: 1
   :widths: 27 15 15 43

   * - Attribute Name
     - Attribute Type
     - Attribute Owner
     - Description
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
   * - ``hego_col_type``
     - Int
     - Prim
     - Collision type: 0 = no collision, 1 = multiple convex shapes, 2 = single convex shape, 3 = trimesh collision
   * - ``hego_col_decomp_settings``
     - Dictionary
     - Prim
     - Convex decomposition settings used when ``hego_col_type`` = 1. See below for accepted keys.

Splitting Output into Multiple Meshes
--------------------------------------

You can split one output into multiple meshes by assigning different
``hego_mesh_instance`` paths across primitives. This is useful for organizing outputs
or applying different materials and settings per mesh.

Convex Decomposition Settings
------------------------------

The ``hego_col_decomp_settings`` dictionary accepts the following keys when generating 
multiple convex collision shapes:

- ``convex_hull_approximation`` (bool)
- ``convex_hull_downsampling`` (int)
- ``max_concavity`` (float)
- ``max_convex_hulls`` (int)
- ``max_num_vertices_per_convex_hull`` (int)
- ``min_volume_per_convex_hull`` (float)
- ``mode`` (int)
- ``normalize_mesh`` (bool)
- ``plane_downsampling`` (int)
- ``project_hull_vertices`` (bool)
- ``resolution`` (int)
- ``resolution_axes_clipping_bias`` (float)
- ``symmetry_planes_clipping_bias`` (float)

For detailed information about these settings, see the `Godot MeshConvexDecompositionSettings documentation <https://docs.godotengine.org/en/stable/classes/class_meshconvexdecompositionsettings.html>`_.
