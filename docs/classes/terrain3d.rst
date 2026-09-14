Terrain3D
=========

Heightfields in both directions, for projects using the optional Terrain3D addon. None of it refers to Terrain3D's types directly, so HEGo runs without the addon installed.

.. list-table::
   :widths: 34 66
   :header-rows: 1

   * - Class
     - Description
   * - :ref:`HEGoTerrain3DInput<class_HEGoTerrain3DInput>`
     - Reads an existing Terrain3D node into heightfield layers Houdini can consume.
   * - :ref:`HEGoTerrain3DOutput<class_HEGoTerrain3DOutput>`
     - Builds a Terrain3D node from the heightfield layers of a cooked HDA.
   * - :ref:`HEGoTerrain3DInstancer<class_HEGoTerrain3DInstancer>`
     - Scatters scenes onto an existing Terrain3D through its instancer.
   * - :ref:`HEGoTerrain3DUtil<class_HEGoTerrain3DUtil>`
     - Helpers shared by the Terrain3D input, output and instancer paths.

.. toctree::
   :maxdepth: 1
   :hidden:

   class_hegoterrain3dinput
   class_hegoterrain3doutput
   class_hegoterrain3dinstancer
   class_hegoterrain3dutil
