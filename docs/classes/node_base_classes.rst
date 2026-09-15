Node base classes
=================

Shared by the nodes above. None can be instantiated; they are here because the methods a node inherits are documented on the class that declares them.

.. list-table::
   :widths: 34 66
   :header-rows: 1

   * - Class
     - Description
   * - :ref:`HEGoBaseNode<class_HEGoBaseNode>`
     - Virtual base class for all HEGo node wrappers.
   * - :ref:`HEGoTrackableNode<class_HEGoTrackableNode>`
     - Abstract base interface for HEGo nodes tracked by session manager.
   * - :ref:`HEGoTransformableNode<class_HEGoTransformableNode>`
     - Base node type with transform synchronization support.
   * - :ref:`HEGoTransformableNamedNode<class_HEGoTransformableNamedNode>`
     - Virtual transformable base that stores an internal node name.
   * - :ref:`HEGoInputReceiverNode<class_HEGoInputReceiverNode>`
     - Base node type that can receive node inputs.
   * - :ref:`HEGoTransformableInputReceiverNode<class_HEGoTransformableInputReceiverNode>`
     - Input receiver base that also supports transform updates.
   * - :ref:`HEGoBaseInputNode<class_HEGoBaseInputNode>`
     - Base class for nodes that send source data from Godot to Houdini.

.. toctree::
   :maxdepth: 1
   :hidden:

   class_hegobasenode
   class_hegotrackablenode
   class_hegotransformablenode
   class_hegotransformablenamednode
   class_hegoinputreceivernode
   class_hegotransformableinputreceivernode
   class_hegobaseinputnode
