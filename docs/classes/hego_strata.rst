HEGo Strata bridge
==================

The separate ``addons/hego_strata`` addon, which depends on HEGo and Strata: Strata layers as HDA inputs, and a cook's heightfields published into Strata layers. It plugs into HEGo through :ref:`HEGoInputHandler<class_HEGoInputHandler>` and :ref:`HEGoOutputHandler<class_HEGoOutputHandler>`.

.. list-table::
   :widths: 34 66
   :header-rows: 1

   * - Class
     - Description
   * - :ref:`HEGoStrataInput<class_HEGoStrataInput>`
     - Sends Strata layers to HDA inputs as heightfield volumes.
   * - :ref:`HEGoStrataOutput<class_HEGoStrataOutput>`
     - Publishes the heightfields a cook outputs into Strata terrain layers.

.. toctree::
   :maxdepth: 1
   :hidden:

   class_hegostratainput
   class_hegostrataoutput
