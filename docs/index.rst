HEGo Documentation
==================

HEGo brings Houdini Digital Assets into Godot: a Houdini session runs alongside the editor,
your HDAs cook there, and what they produce becomes ordinary Godot nodes in your scene.

Start with :doc:`about/getting_started`, then :doc:`node_reference/hego_node_3d`, which is
the node most projects only ever need. Everything under :doc:`api/index` is for when you
want to drive Houdini from a script of your own.

On the ``next`` channel, HEGo connects to external systems through a one-way
:doc:`bridge architecture <bridges/index>`. Two standalone addons are currently developed
alongside HEGo here — :doc:`Strata <strata/index>` for layered terrain and
:doc:`Copia <copia/index>` for large-scale cell-based instancing — together with their
HEGo bridges (``hego_strata`` and ``hego_copia``) and the ``hego_terrain3d`` bridge. Both
Strata and Copia work without Houdini and are planned to move to their own repositories
later; while they live in HEGo's ``next`` branch, their full documentation is hosted here.

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
   :caption: Bridges & Ecosystem

   bridges/index

.. toctree::
   :maxdepth: 2
   :caption: Scripting

   api/index

.. toctree::
   :maxdepth: 2
   :caption: Strata Terrain

   strata/index
   strata/getting_started
   strata/houdini
   strata/example_island
   strata/reference

.. toctree::
   :maxdepth: 2
   :caption: Copia Instancing

   copia/index
   copia/getting_started
   copia/houdini
   copia/reference

.. toctree::
   :maxdepth: 2
   :caption: Reference

   classes/index

.. toctree::
   :maxdepth: 1
   :caption: Development Notes

   development/testing
   development/packaging
   development/hda_parameter_support_plan
   development/copia_design
   development/godot_mcp
   development/strata_regions_plan
   development/terrain_renderer_regions
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
