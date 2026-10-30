HEGo Documentation
==================

HEGo brings Houdini Digital Assets into Godot: a Houdini session runs alongside the editor,
your HDAs cook there, and what they produce becomes ordinary Godot nodes in your scene.

Start with :doc:`about/getting_started`, then :doc:`node_reference/hego_node_3d`, which is
the node most projects only ever need. Everything under :doc:`api/index` is for when you
want to drive Houdini from a script of your own. For layered terrain, with or without
Houdini, see :doc:`strata/index`.

.. toctree::
   :maxdepth: 1
   :caption: About

   about/introduction
   about/getting_started

.. toctree::
   :maxdepth: 2
   :caption: Using HEGo

   node_reference/hego_node_3d
   node_reference/hego_graph_input_3d

.. toctree::
   :maxdepth: 2
   :caption: Scripting

   api/index

.. toctree::
   :maxdepth: 2
   :caption: Strata terrain

   strata/index
   strata/getting_started
   strata/houdini
   strata/example_island
   strata/reference

.. toctree::
   :maxdepth: 1
   :caption: Development notes

   development/testing
   development/packaging
   development/terrain_runtime
   development/terrain_bulk
   development/strata_integration_tests
   development/terrain_shading
   development/terrain_material_blending
   development/terrain_macro
   development/island_hda
   development/island_material_distribution
   development/island_benchmark
   development/terrain_prototype

.. toctree::
   :maxdepth: 2
   :caption: Reference

   classes/index
