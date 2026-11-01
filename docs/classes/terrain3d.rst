HEGo Terrain3D bridge
=====================

The separate ``addons/hego_terrain3d`` addon, which depends on HEGo and on the Terrain3D addon: heightfields in both directions, and Terrain3D instancing. It plugs into HEGo through :ref:`HEGoInputHandler<class_HEGoInputHandler>` and :ref:`HEGoOutputHandler<class_HEGoOutputHandler>`, and reaches Terrain3D only through ``ClassDB``, so its scripts still load without Terrain3D installed.

.. list-table::
   :widths: 34 66
   :header-rows: 1

   * - Class
     - Description
   * - :ref:`HEGoTerrain3DInput<class_HEGoTerrain3DInput>`
     - Sends an existing Terrain3D node to an HDA input as heightfield layers.
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
