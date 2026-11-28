Inputs
======

These pages describe what ``HEGoNode3D`` sends into Houdini when you connect Godot
nodes or texture resources to an HDA input. For a one-point texture reference and a
Fetch COP authoring example, see :doc:`/api/copernicus`. Drawing a graph in the viewport is
:doc:`/node_reference/hego_graph_input_3d`.

Bridge addons add additional input types without coupling them to HEGo (see
:doc:`/bridges/index`):

- **Strata layers** (``addons/hego_strata``): :doc:`/strata/houdini`
- **Copia stores** (``addons/hego_copia``): :doc:`/copia/houdini`
- **Terrain3D** (``addons/hego_terrain3d``): :doc:`terrain3d_input`

.. toctree::
   :maxdepth: 1

   path3d_input
   graph_input
   meshinstance3d_csgshape_input
   terrain3d_input
