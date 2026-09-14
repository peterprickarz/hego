Writing a node
==============

The node HEGo ships, the helper a node of your own holds, and what the two of them pass around. See :doc:`/api/custom_nodes`.

.. list-table::
   :widths: 34 66
   :header-rows: 1

   * - Class
     - Description
   * - :ref:`HEGoNode3D<class_HEGoNode3D>`
     - Brings a Houdini Digital Asset into a Godot scene.
   * - :ref:`HEGoAssetAgent<class_HEGoAssetAgent>`
     - Holds the HDAs one Godot node owns, and does the fiddly parts of driving them.
   * - :ref:`HEGoOutputContext<class_HEGoOutputContext>`
     - Everything one output handler is given to work with.
   * - :ref:`HEGoNodeUtil<class_HEGoNodeUtil>`
     - Shared plumbing for :ref:`HEGoNode3D<class_HEGoNode3D>` and its output handlers.
   * - :ref:`HEGoInputNodes<class_HEGoInputNodes>`
     - Turns the Godot nodes wired into a :ref:`HEGoNode3D<class_HEGoNode3D>` into HEGo input nodes.
   * - :ref:`HEGoCookTimings<class_HEGoCookTimings>`
     - Collects the per-phase timings of a ``cook()`` call.

.. toctree::
   :maxdepth: 1
   :hidden:

   class_hegonode3d
   class_hegoassetagent
   class_hegooutputcontext
   class_hegonodeutil
   class_hegoinputnodes
   class_hegocooktimings
