Bridge Architecture
===================

HEGo is built around a **one-way bridge architecture**: HEGo itself handles Houdini Engine
sessions, inputs, parameters, and standard Godot outputs (meshes, multimeshes, curves,
graphs, and spawned nodes), while specialised systems such as terrain and large-scale
instancing live in **standalone addons** with zero dependency on HEGo or Houdini.

Thin, GDScript-only **bridge addons** sit above HEGo and one target addon, connecting them
through HEGo's extension points without introducing any dependency in the other direction:

.. code-block:: text

    HEGo (addons/hego)           Strata (addons/strata)         Copia (addons/copia)
      standalone                   standalone                     standalone
        ▲                            ▲                              ▲
        │                            │                              │
        ├────────────────────────────┘                              │
        │   HEGo Strata (addons/hego_strata)                        │
        │                                                           │
        ├───────────────────────────────────────────────────────────┘
        │   HEGo Copia (addons/hego_copia)
        │
        └────────────────────────────┐
            HEGo Terrain3D           ▼
            (addons/hego_terrain3d)  Terrain3D (addons/terrain_3d, external)

.. note::

   **Strata** and **Copia** are designed as independent addons and are planned to move into
   their own repositories and documentation sites in the future. While they are developed
   alongside HEGo on the ``next`` channel, their packages and full documentation live here.

Why One-Way Bridges
-------------------

- **Zero Houdini runtime dependency for standalone addons.** A project can install
  :doc:`Strata </strata/index>` or :doc:`Copia </copia/index>` without installing HEGo or
  Houdini, and exported games ship only the runtime pieces they use.
- **No cross-coupling in HEGo.** HEGo never imports or names Strata, Copia, or Terrain3D.
  You install only the bridges your project uses, and unused integrations add zero overhead.
- **Coexistence by attribute contract.** Multiple bridges can be installed in the same
  project and even driven by the same HDA cook. Each output handler inspects only the
  geometry or attributes it owns and leaves the rest untouched.
- **No native code in bridges.** Every bridge is pure GDScript. Native libraries and build
  receipts live solely in the standalone addons (``hego``, ``strata``, ``copia``).

Packages on the ``next`` Channel
--------------------------------

The ``next`` channel publishes matched packages from one source revision (each carrying a
``SOURCE_COMMIT`` and ``PACKAGE.json`` manifest):

.. list-table::
   :widths: 18 22 24 18 18
   :header-rows: 1

   * - Addon
     - Folder
     - ``next`` branch
     - Depends on
     - Native library
   * - **HEGo**
     - ``addons/hego``
     - ``release-next``
     - None
     - Yes
   * - **Strata**
     - ``addons/strata``
     - ``strata-release-next``
     - None
     - Yes
   * - **Copia**
     - ``addons/copia``
     - ``copia-release-next``
     - None
     - Yes
   * - **HEGo Strata**
     - ``addons/hego_strata``
     - ``hego-strata-release-next``
     - HEGo + Strata
     - No (GDScript)
   * - **HEGo Copia**
     - ``addons/hego_copia``
     - ``hego-copia-release-next``
     - HEGo + Copia
     - No (GDScript)
   * - **HEGo Terrain3D**
     - ``addons/hego_terrain3d``
     - ``hego-terrain3d-release-next``
     - HEGo + Terrain3D (external)
     - No (GDScript)

For convenience, ``release-next-bundle`` packages ``hego/``, ``strata/``, ``hego_strata/``,
and ``hego_terrain3d/`` together in one tree (Terrain3D itself is installed separately at
``addons/terrain_3d``; Copia and HEGo Copia are installed from ``copia-release-next`` and
``hego-copia-release-next``). See :doc:`/development/packaging` for full manifest and release
details.

How Bridges Plug Into HEGo
--------------------------

A bridge does not patch HEGo or register itself in a central list. HEGo discovers bridges
automatically through Godot's global class list (``class_name``) via three base classes:

.. list-table::
   :widths: 30 70
   :header-rows: 1

   * - Extension point
     - Role
   * - :ref:`HEGoInputHandler<class_HEGoInputHandler>`
     - Adds a Godot node type that can be wired into an HDA input row. HEGo asks every
       global subclass ``handles(node)`` before falling back to built-in input types, then
       calls ``sync()`` to upload geometry. A handler can also provide input-row settings UI,
       force explicit recooks (``requires_explicit_cook()``), or make cooks strict
       (``requires_strict_cook()``) so missing or unreadable inputs abort the cook.
   * - :ref:`HEGoOutputHandler<class_HEGoOutputHandler>`
     - Adds a post-cook output consumer. HEGo reads the cook summary once, asks each global
       subclass ``should_handle(summary)``, and runs ``handle(context)`` only for handlers
       whose attributes or geometry are present. Handlers share ``context.cook_state`` with
       input handlers and cook extensions.
   * - :ref:`HEGoCookExtension<class_HEGoCookExtension>`
     - Per-node lifecycle hook attached as a direct child of a
       :ref:`HEGoNode3D<class_HEGoNode3D>`. Exposes ``cook_prepare()``, ``cook_before()``,
       ``cook_commit()``, ``cook_finished()``, and ``cook_failed()`` for custom validation,
       cook-state options, or post-processing.

Each bridge also ships a small ``EditorPlugin`` (``plugin.gd``) that checks whether its
required addons are installed and enabled without hard-referencing their classes at parse
time, so a missing dependency prints a clear warning instead of breaking script loading.
Bridges can also subscribe to
:ref:`HEGoNode3D.cook_inputs_changed<class_HEGoNode3D_signal_cook_inputs_changed>` to react
immediately when inputs or parameters are edited (for example, marking published terrain
layers stale).

Shipped Bridges
---------------

HEGo Strata (``addons/hego_strata``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Connects HEGo to :doc:`Strata </strata/index>`, the layered terrain addon:

- **Input** (:ref:`HEGoStrataInput<class_HEGoStrataInput>`): sends ``StrataLayer`` nodes
  (cumulative stack or raw layer, with optional channel filtering and resampling) to Houdini
  as heightfield volumes plus ownership/coverage companions. Makes cooks explicit and strict.
- **Output** (:ref:`HEGoStrataOutput<class_HEGoStrataOutput>`): routes heightfield volumes
  carrying ``hegostrata_layer_path`` into procedural Strata layers in one all-or-nothing
  transaction per cook.
- **Editor tracking**: its editor plugin listens to ``cook_inputs_changed`` and polls
  producer state so published layers are marked stale whenever inputs, parameters, or
  transforms change.

See :doc:`/strata/houdini` and :doc:`/classes/hego_strata`.

HEGo Copia (``addons/hego_copia``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Connects HEGo to :doc:`Copia </copia/index>`, the cell-based instancing store for large
worlds:

- **Input** (:ref:`HEGoCopiaInput<class_HEGoCopiaInput>`): sends a ``CopiaStore3D``'s
  populated cells (and optionally instance points for selected sets within a region) as a
  point cloud so generators can inspect existing content and emit clear points. Makes cooks
  strict.
- **Output** (:ref:`HEGoCopiaOutput<class_HEGoCopiaOutput>`): routes points carrying
  ``hegocopia_object`` or ``hegocopia_clear`` into one or more ``CopiaStore3D`` nodes,
  applying clears before spawns and rebuilding only changed cells.

See :doc:`/copia/houdini` and :doc:`/classes/hego_copia`.

HEGo Terrain3D (``addons/hego_terrain3d``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Connects HEGo to TokisanGames' external `Terrain3D <https://tokisan.com/terrain3d/>`_ addon
(installed separately at ``addons/terrain_3d``):

- **Input** (:ref:`HEGoTerrain3DInput<class_HEGoTerrain3DInput>`): uploads an existing
  Terrain3D node as height, region, hole, and texture paint heightfield layers.
- **Output** (:ref:`HEGoTerrain3DOutput<class_HEGoTerrain3DOutput>` and
  :ref:`HEGoTerrain3DInstancer<class_HEGoTerrain3DInstancer>`): builds Terrain3D terrains
  from heightfields carrying ``hegot3d_*`` attributes and populates Terrain3D instancers
  from tagged points.
- Reaches Terrain3D strictly through ``ClassDB`` so the bridge scripts still parse cleanly
  when Terrain3D is absent.

See :doc:`/node_reference/inputs/terrain3d_input`,
:doc:`/node_reference/outputs/terrain3d_output`, and :doc:`/classes/terrain3d`.

Writing Your Own Bridge
-----------------------

Any project or third-party addon can extend HEGo the exact same way — define a ``@tool``
script with a ``class_name`` extending :ref:`HEGoInputHandler<class_HEGoInputHandler>` or
:ref:`HEGoOutputHandler<class_HEGoOutputHandler>`, and HEGo picks it up automatically on the
next cook. See :doc:`/api/node3d_modules` for worked handler templates, context helpers, and
extension-point contracts.
