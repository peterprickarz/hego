Introduction
============

HEGo is a C++ GDExtension that integrates Houdini Engine into Godot 4, enabling procedural
content generation using Houdini Digital Assets (HDAs) with a scriptable API.

Community
---------

- `Discord <https://discord.gg/bAw7Pv8ETG>`_ — chat with users and contributors
- `GitHub Releases <https://github.com/peterprickarz/hego/releases/latest>`_ — latest pre-built binaries

Features
--------

- **Scriptable API**: built with GDScript integration in mind for maximum flexibility
- **Multiple node types**: geometry input, curve input, graph input, heightfield input, and HDA asset nodes
- **Session management**: in-process, TCP, named pipes, and shared memory session types
- **Bidirectional data flow**: convert between Godot and Houdini geometry formats
- **Parameter management**: automatic type conversion between Godot Variant and HAPI types
- **Mesh generation**: generate Godot meshes, instances, and scene nodes from Houdini output
- **Bridge architecture**: plug in standalone systems via thin GDScript bridge addons without coupling HEGo to them (see :doc:`/bridges/index`):

  - **Strata terrain** (``addons/strata`` + ``addons/hego_strata``): layered terrain with manual painting, procedural HDA layers, baking, collision, and navigation (:doc:`/strata/index`)
  - **Copia instancing** (``addons/copia`` + ``addons/hego_copia``): cell-based instancing store for tens of thousands to millions of meshes with streaming, impostors, and colliders (:doc:`/copia/index`)
  - **Terrain3D bridge** (``addons/hego_terrain3d``): generate `Terrain3D <https://tokisan.com/terrain3d/>`_ terrains, populate Terrain3D instancers, and feed Terrain3D heightfield inputs into Houdini

Where to Start
--------------

- Setting up HEGo for the first time: :doc:`Getting Started <getting_started>`.
- Bringing an HDA into a scene: :doc:`HEGoNode3D </node_reference/hego_node_3d>`.
- Understanding how HEGo integrates with Strata, Copia, and Terrain3D: :doc:`Bridge Architecture </bridges/index>`.
- Layered terrain (with or without Houdini): :doc:`Strata terrain </strata/index>`.
- Large-scale mesh instancing (with or without Houdini): :doc:`Copia instancing </copia/index>`.
- Driving Houdini from your own GDScript: :doc:`Scripting HEGo </api/index>` and the :doc:`class reference </classes/index>`.

Overview Video
--------------

.. youtube:: CSmCCTkfPCU
