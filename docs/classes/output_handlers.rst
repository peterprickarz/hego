Output handlers
===============

What turns a cook's geometry into Godot nodes, one class per output type, plus the pieces they share. See :doc:`/api/node3d_modules`.

.. list-table::
   :widths: 34 66
   :header-rows: 1

   * - Class
     - Description
   * - :ref:`HEGoMeshOutput<class_HEGoMeshOutput>`
     - Turns the surfaces of a cooked HDA into ``MeshInstance3D``\ s under ``Outputs/``.
   * - :ref:`HEGoMultiMeshOutput<class_HEGoMultiMeshOutput>`
     - Instances an existing mesh resource once per output point through a ``MultiMesh``.
   * - :ref:`HEGoObjectOutput<class_HEGoObjectOutput>`
     - Spawns one Godot node per output point.
   * - :ref:`HEGoCurveOutput<class_HEGoCurveOutput>`
     - Turns the curves of a cooked HDA into ``Path3D`` nodes under ``Outputs/``.
   * - :ref:`HEGoCurveBuilder<class_HEGoCurveBuilder>`
     - Converts the curve dictionaries a curve fetch returns into ``Curve3D``\ s.
   * - :ref:`HEGoPointUtil<class_HEGoPointUtil>`
     - Point attribute maths shared by every handler that scatters something.
   * - :ref:`HEGoPropertyUtil<class_HEGoPropertyUtil>`
     - Applies the ``hego_custom_properties`` dictionary an HDA can attach to a spawned object onto the object itself.

.. toctree::
   :maxdepth: 1
   :hidden:

   class_hegomeshoutput
   class_hegomultimeshoutput
   class_hegoobjectoutput
   class_hegocurveoutput
   class_hegocurvebuilder
   class_hegopointutil
   class_hegopropertyutil
