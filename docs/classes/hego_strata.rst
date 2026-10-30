HEGo Strata bridge
==================

The separate ``addons/hego_strata`` addon, which depends on HEGo and Strata: Strata layers as HDA inputs, and a cook's heightfields published into Strata layers. It plugs into HEGo through :ref:`HEGoInputHandler<class_HEGoInputHandler>` and :ref:`HEGoCookExtension<class_HEGoCookExtension>`.

.. list-table::
   :widths: 34 66
   :header-rows: 1

   * - Class
     - Description
   * - :ref:`HEGoStrataInput<class_HEGoStrataInput>`
     - Sends Strata layers to HDA inputs as heightfield volumes.
   * - :ref:`HEGoStrataTargets<class_HEGoStrataTargets>`
     - Publishes the heightfields an HEGo node's HDA outputs into procedural terrain layers.
   * - :ref:`HEGoStrataOutput<class_HEGoStrataOutput>`
     - Routes a cook's heightfields into the terrain layers an :ref:`HEGoStrataTargets<class_HEGoStrataTargets>` binds, and publishes them in one transaction. A volume names its target with the primitive attribute hegostrata_layer_path; the other attributes below describe its role.

.. toctree::
   :maxdepth: 1
   :hidden:

   class_hegostratainput
   class_hegostratatargets
   class_hegostrataoutput
