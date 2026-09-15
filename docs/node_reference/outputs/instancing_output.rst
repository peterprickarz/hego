Instancing Output
=================

Use MultiMeshInstance3D output to efficiently render many instances of the same mesh with
different transforms and colors. This is ideal for trees, rocks, and other repeated elements.

Point Attributes
----------------

Transform and color data is specified via point attributes:

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

Example
-------

A point wrangle over scattered points, instancing a rock scene with random scale and
orientation:

.. code-block:: c

   // Point wrangle on the scatter output
   i@hego_use_multimesh = 1;                              // required
   s@hego_multimesh = "Rocks";                            // node name under Outputs
   s@hego_mesh_resource = "res://meshes/rock_01.res";     // the mesh to instance

   f@pscale = fit01(rand(@ptnum), 0.6, 1.4);
   v@up = {0, 1, 0};
   v@N = normalize(set(rand(@ptnum + 11) - 0.5, 0, rand(@ptnum + 27) - 0.5));

Every attribute except ``hego_use_multimesh`` and ``hego_mesh_resource`` is optional:
without ``N`` and ``up`` the instances keep the default orientation, without
``pscale`` or ``scale`` they stay at unit size, and ``Cd`` only needs to be there if
you want per-instance colour.

Splitting into Multiple Instancers
-----------------------------------

You can split one output into multiple MultiMesh instancers by assigning different
``hego_multimesh`` paths across points. This allows you to create separate instancer
groups with different meshes or configurations.
