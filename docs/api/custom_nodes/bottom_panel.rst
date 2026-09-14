The Bottom Panel Interface
==========================

The panel drives whatever node is selected through the methods below. Implement the ones you
want: there is no base class to inherit, no interface to declare, and no type check anywhere
in the panel. It asks your node whether it has a method, and calls it if it does.

None of this involves :doc:`the asset agent <asset_agent>`. A node that holds no agent gets
exactly the same panel.

.. list-table::
   :widths: 40 60
   :header-rows: 1

   * - Method
     - Effect
   * - ``hego_use_bottom_panel() -> bool``
     - Required. Returning ``true`` is what puts this node in the panel at all
   * - ``cook() -> void``
     - What the Recook button calls
   * - ``hego_get_asset_node() -> HEGoAssetNode``
     - The HDA whose parameters the panel shows
   * - ``hego_get_asset_name() -> String``
     - The operator name, which the preset list is keyed by
   * - ``hego_set_parm_stash(preset: PackedByteArray)``
     - Where the panel writes the HDA's parameters back after each recook
   * - ``hego_get_input_stash() -> Array`` / ``hego_set_input_stash(rows: Array)``
     - The input rows, as ``{ "inputs": [...], "settings": {...} }`` per HDA input
   * - ``hego_set_asset_name(name: String)``
     - Implement this **only** if the HDA should be choosable in the panel. A node with its
       operator written into its script leaves it out and gets no picker button
   * - ``hego_get_panel_assets() -> Array``
     - For a node cooking several HDAs; see :doc:`several_hdas`

What each one costs you to leave out
------------------------------------

- Without ``hego_get_asset_node()`` the panel has no parameters to show, and says so rather
  than erroring. A node driving its HDA entirely from exported properties can leave it out
  on purpose.
- Without ``hego_get_asset_name()`` there is no preset list, because presets are stored per
  operator.
- Without ``hego_set_parm_stash()`` the panel has nowhere to put the parameters after a
  recook. A node whose own ``cook()`` ends with ``agent.save_parameters()`` has already
  stored them and loses nothing; one that does not will find the user's panel edits gone on
  the next scene load.
- Without the input stash pair, the Inputs pane has nothing to read or write and stays
  empty. Your node can still feed the HDA from its own exported properties.

The panel waits for an HDA to exist in Houdini before asking it anything, so returning an
asset node that has not been instantiated yet is safe: it shows a "recook to see parameters"
hint instead of querying a Houdini node that is not there.
