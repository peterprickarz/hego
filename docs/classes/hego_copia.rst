HEGo Copia bridge
=================

The separate ``addons/hego_copia`` addon, which depends on HEGo and Copia: Copia store cells and points as HDA inputs, and a cook's points written into Copia stores. It plugs into HEGo through :ref:`HEGoInputHandler<class_HEGoInputHandler>` and :ref:`HEGoOutputHandler<class_HEGoOutputHandler>`.

.. list-table::
   :widths: 34 66
   :header-rows: 1

   * - Class
     - Description
   * - :ref:`HEGoCopiaInput<class_HEGoCopiaInput>`
     - Sends a Copia store to an HDA input as one point cloud, so a generator can see what the store holds and send back clear points for the cells it replaces (docs/copia/houdini.md).
   * - :ref:`HEGoCopiaOutput<class_HEGoCopiaOutput>`
     - Writes a cook's points into a Copia store, on every cook of any HEGo node whose output carries them: the panel's Recook, a Session Sync update and a batch cook() all do the same.

.. toctree::
   :maxdepth: 1
   :hidden:

   class_hegocopiainput
   class_hegocopiaoutput
