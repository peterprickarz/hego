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
- **Multiple node types**: geometry input, curve input, heightfield input, and HDA asset nodes
- **Session management**: in-process, TCP, named pipes, and shared memory session types
- **Bidirectional data flow**: convert between Godot and Houdini geometry formats
- **Parameter management**: automatic type conversion between Godot Variant and HAPI types
- **Mesh generation**: generate Godot meshes, instances, and scene nodes from Houdini output
- **Terrain3D bridge**: generate `Terrain3D <https://tokisan.com/terrain3d/>`_ terrains, use Terrain3D instancing, and feed Terrain3D heightfield inputs into Houdini

Where to Start
--------------

If you are setting things up for the first time, see :doc:`Getting Started <getting_started>`.

The easiest way to bring an HDA into Godot is :doc:`HEGoNode3D </node_reference/hego_node_3d>`.

If you want to work with the underlying API directly, the entire ``HEGoNode3D`` workflow and
editor bottom panel are built in GDScript on top of the core API. See the individual
:doc:`API class pages </classes/class_hegoapi>` for details.

Overview Video
--------------

.. youtube:: CSmCCTkfPCU
