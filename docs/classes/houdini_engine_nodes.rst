Houdini Engine nodes
====================

One Godot object per node in the Houdini session. Everything a cook does is a method on one of these, and every one of those methods returns a :ref:`HEGoTask<class_HEGoTask>`.

.. list-table::
   :widths: 34 66
   :header-rows: 1

   * - Class
     - Description
   * - :ref:`HEGoAssetNode<class_HEGoAssetNode>`
     - Represents an instantiated Houdini Digital Asset (HDA) node.
   * - :ref:`HEGoMergeNode<class_HEGoMergeNode>`
     - Wrapper around a Houdini Merge SOP node.
   * - :ref:`HEGoInputNode<class_HEGoInputNode>`
     - Creates Houdini input geometry from Godot mesh sources.
   * - :ref:`HEGoCurveInputNode<class_HEGoCurveInputNode>`
     - Creates Houdini curve input geometry from a ``Path3D``.
   * - :ref:`HEGoHeightfieldInputNode<class_HEGoHeightfieldInputNode>`
     - Builds Houdini HeightField input layers from Godot images.

.. toctree::
   :maxdepth: 1
   :hidden:

   class_hegoassetnode
   class_hegomergenode
   class_hegoinputnode
   class_hegocurveinputnode
   class_hegoheightfieldinputnode
