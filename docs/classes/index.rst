HEGo Class Reference
====================

Every class HEGo registers, and those of the two bridge addons, HEGo Strata and HEGo
Terrain3D. The C++ pages come from the class reference XML in
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

- :ref:`HEGoPointOutput<class_HEGoPointOutput>`
- :ref:`HEGoPointSelection<class_HEGoPointSelection>`
- :ref:`HEGoSurfaceOutput<class_HEGoSurfaceOutput>`
- :ref:`HEGoSurfaceSelection<class_HEGoSurfaceSelection>`

Writing a node
--------------

The node HEGo ships, the helper a node of your own holds, and what the two of them pass around. See :doc:`/api/custom_nodes/index`.

- :ref:`HEGoNode3D<class_HEGoNode3D>`
- :ref:`HEGoAssetAgent<class_HEGoAssetAgent>`
- :ref:`HEGoOutputContext<class_HEGoOutputContext>`
- :ref:`HEGoNodeUtil<class_HEGoNodeUtil>`
- :ref:`HEGoInputNodes<class_HEGoInputNodes>`
- :ref:`HEGoInputHandler<class_HEGoInputHandler>`
- :ref:`HEGoCookExtension<class_HEGoCookExtension>`
- :ref:`HEGoOutputHandler<class_HEGoOutputHandler>`
- :ref:`HEGoCookTimings<class_HEGoCookTimings>`
- :ref:`HEGoGraphInput3D<class_HEGoGraphInput3D>`
- :ref:`HEGoGraphAttributes<class_HEGoGraphAttributes>`
- :ref:`HEGoGraphAttributeDef<class_HEGoGraphAttributeDef>`

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

Resources
---------

What HEGo saves to disk.

- :ref:`HDAResource<class_HDAResource>`
- :ref:`HEGoHDAPreset<class_HEGoHDAPreset>`
- :ref:`HEGoFetchPointsConfig<class_HEGoFetchPointsConfig>`
- :ref:`HEGoFetchSurfacesConfig<class_HEGoFetchSurfacesConfig>`

HEGo Strata bridge
------------------

The separate ``addons/hego_strata`` addon, which depends on HEGo and Strata: Strata layers as HDA inputs, and a cook's heightfields published into Strata layers. It plugs into HEGo through :ref:`HEGoInputHandler<class_HEGoInputHandler>` and :ref:`HEGoOutputHandler<class_HEGoOutputHandler>`.

- :ref:`HEGoStrataInput<class_HEGoStrataInput>`
- :ref:`HEGoStrataOutput<class_HEGoStrataOutput>`

HEGo Terrain3D bridge
---------------------

The separate ``addons/hego_terrain3d`` addon, which depends on HEGo and on the Terrain3D addon: heightfields in both directions, and Terrain3D instancing. It plugs into HEGo through :ref:`HEGoInputHandler<class_HEGoInputHandler>` and :ref:`HEGoOutputHandler<class_HEGoOutputHandler>`, and reaches Terrain3D only through ``ClassDB``, so its scripts still load without Terrain3D installed.

- :ref:`HEGoTerrain3DInput<class_HEGoTerrain3DInput>`
- :ref:`HEGoTerrain3DOutput<class_HEGoTerrain3DOutput>`
- :ref:`HEGoTerrain3DInstancer<class_HEGoTerrain3DInstancer>`
- :ref:`HEGoTerrain3DUtil<class_HEGoTerrain3DUtil>`

.. toctree::
   :maxdepth: 2
   :hidden:

   houdini_engine_nodes
   node_base_classes
   session_and_tasks
   reading_output
   writing_a_node
   output_handlers
   resources
   hego_strata
   terrain3d
