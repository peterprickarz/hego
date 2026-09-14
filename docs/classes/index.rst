HEGo Class Reference
====================

Every class HEGo registers. The C++ pages come from the class reference XML in
``demo/addons/hego/doc_classes``; the GDScript pages are generated from the scripts'
own ``##`` comments, so a class page and the editor's built-in help say the same thing.

Houdini Engine nodes
--------------------

One Godot object per node in the Houdini session. Everything a cook does is a method on one of these, and every one of those methods returns a :ref:`HEGoTask<class_HEGoTask>`.

- :ref:`HEGoAssetNode<class_HEGoAssetNode>`
- :ref:`HEGoMergeNode<class_HEGoMergeNode>`
- :ref:`HEGoInputNode<class_HEGoInputNode>`
- :ref:`HEGoCurveInputNode<class_HEGoCurveInputNode>`
- :ref:`HEGoHeightfieldInputNode<class_HEGoHeightfieldInputNode>`

Node base classes
-----------------

Shared by the nodes above. None can be instantiated; they are here because the methods a node inherits are documented on the class that declares them.

- :ref:`HEGoBaseNode<class_HEGoBaseNode>`
- :ref:`HEGoTrackableNode<class_HEGoTrackableNode>`
- :ref:`HEGoTransformableNode<class_HEGoTransformableNode>`
- :ref:`HEGoTransformableNamedNode<class_HEGoTransformableNamedNode>`
- :ref:`HEGoInputReceiverNode<class_HEGoInputReceiverNode>`
- :ref:`HEGoTransformableInputReceiverNode<class_HEGoTransformableInputReceiverNode>`
- :ref:`HEGoBaseInputNode<class_HEGoBaseInputNode>`

Session, tasks and logging
--------------------------

The session itself, the queue every Houdini call goes through, and where messages come out. See :doc:`/api/task_pattern` and :doc:`/api/logging`.

- :ref:`HEGoAPI<class_HEGoAPI>`
- :ref:`HEGoTask<class_HEGoTask>`
- :ref:`HEGoLog<class_HEGoLog>`

Reading a cook's output
-----------------------

Points and surfaces as they sit in C++, filtered and split without being copied into Godot until asked for. See :doc:`/api/geo_output`.

- :ref:`HEGoGeoOutput<class_HEGoGeoOutput>`
- :ref:`HEGoGeoSelection<class_HEGoGeoSelection>`
- :ref:`HEGoGeoSurfaces<class_HEGoGeoSurfaces>`
- :ref:`HEGoGeoPrimSelection<class_HEGoGeoPrimSelection>`

Writing a node
--------------

The node HEGo ships, the helper a node of your own holds, and what the two of them pass around. See :doc:`/api/custom_nodes`.

- :ref:`HEGoNode3D<class_HEGoNode3D>`
- :ref:`HEGoHelpers<class_HEGoHelpers>`
- :ref:`HEGoOutputContext<class_HEGoOutputContext>`
- :ref:`HEGoNodeUtil<class_HEGoNodeUtil>`
- :ref:`HEGoInputNodes<class_HEGoInputNodes>`
- :ref:`HEGoCookTimings<class_HEGoCookTimings>`

Output handlers
---------------

What turns a cook's geometry into Godot nodes, one class per output type, plus the pieces they share. See :doc:`/api/node3d_modules`.

- :ref:`HEGoMeshOutput<class_HEGoMeshOutput>`
- :ref:`HEGoMultiMeshOutput<class_HEGoMultiMeshOutput>`
- :ref:`HEGoObjectOutput<class_HEGoObjectOutput>`
- :ref:`HEGoCurveOutput<class_HEGoCurveOutput>`
- :ref:`HEGoCurveBuilder<class_HEGoCurveBuilder>`
- :ref:`HEGoPointUtil<class_HEGoPointUtil>`
- :ref:`HEGoPropertyUtil<class_HEGoPropertyUtil>`

Terrain3D
---------

Heightfields in both directions, for projects using the optional Terrain3D addon. None of it refers to Terrain3D's types directly, so HEGo runs without the addon installed.

- :ref:`HEGoTerrain3DInput<class_HEGoTerrain3DInput>`
- :ref:`HEGoTerrain3DOutput<class_HEGoTerrain3DOutput>`
- :ref:`HEGoTerrain3DInstancer<class_HEGoTerrain3DInstancer>`
- :ref:`HEGoTerrain3DUtil<class_HEGoTerrain3DUtil>`

Resources
---------

What HEGo saves to disk.

- :ref:`HDAResource<class_HDAResource>`
- :ref:`HEGoHDAPreset<class_HEGoHDAPreset>`
- :ref:`HEGoFetchPointsConfig<class_HEGoFetchPointsConfig>`
- :ref:`HEGoFetchSurfacesConfig<class_HEGoFetchSurfacesConfig>`

.. toctree::
   :maxdepth: 2
   :hidden:

   houdini_engine_nodes
   node_base_classes
   session_and_tasks
   reading_output
   writing_a_node
   output_handlers
   terrain3d
   resources
