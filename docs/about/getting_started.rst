Getting Started
===============

License Requirements
--------------------

You need a Houdini FX, Core, Indie, or commercial Houdini Engine license to use this integration.

Houdini Indie requires Houdini 22.0.510 or later. HEGo identifies itself to Houdini Engine as a
Godot client by setting ``HAPI_CLIENT_NAME=godot``, which is what lets Houdini Engine accept an
Indie license. Earlier builds ignore it and still require a commercial license.

This applies to sessions HEGo starts itself. If you connect to a Houdini Engine server that was
already running, start that server with ``HAPI_CLIENT_NAME=godot`` in its environment as well.

Houdini
-------

Make sure you have the correct Houdini version installed. Currently **22.0.429** (or
**22.0.510+** if using a Houdini Indie license). It may work with other 22.0 builds, but
22.0.429 is what HEGo is built against.

HEGo ships pre-built libraries for **Windows x86_64** and **Linux x86_64** (Godot **4.7+**
on the ``next`` channel); macOS is not supported. Please create an issue on GitHub or let us
know on Discord if you run into platform issues.

Installation
------------

Simply download the release and unzip into your Godot project. In the project settings, make sure
to enable the ``HEGo`` addon under the **Plugins** tab, and set your Houdini installation path
(filter by ``Houdini Installation Path`` under the **General** tab).

- **Windows:** ``C:/Program Files/Side Effects Software/Houdini 22.0.429``
- **Linux:** ``/opt/hfs22.0`` (the symlink to the installed build)

Leaving the setting empty is fine too: HEGo then falls back to ``$HFS``, and after that to
the stock install path for your platform.

You will need to restart Godot after enabling the plugin.

Git submodule method
~~~~~~~~~~~~~~~~~~~~

For the stable channel (``main``):

.. code-block:: bash

   # Add HEGo as a submodule in your Godot project
   git submodule add -b release https://github.com/peterprickarz/hego.git addons/hego
   git submodule update --init --recursive

For the development channel (``next``), HEGo, Strata, Copia, and their bridge addons are
published on matched branches so you can install only what your project uses:

.. code-block:: bash

   # HEGo on next
   git submodule add -b release-next https://github.com/peterprickarz/hego.git addons/hego

   # Optional: Strata terrain + HEGo Strata bridge
   git submodule add -b strata-release-next https://github.com/peterprickarz/hego.git addons/strata
   git submodule add -b hego-strata-release-next https://github.com/peterprickarz/hego.git addons/hego_strata

   # Optional: Copia instancing + HEGo Copia bridge
   git submodule add -b copia-release-next https://github.com/peterprickarz/hego.git addons/copia
   git submodule add -b hego-copia-release-next https://github.com/peterprickarz/hego.git addons/hego_copia

   # Optional: Terrain3D bridge (install Terrain3D itself at addons/terrain_3d)
   git submodule add -b hego-terrain3d-release-next https://github.com/peterprickarz/hego.git addons/hego_terrain3d

See :doc:`/bridges/index` for how these addons fit together, and
:doc:`/development/packaging` for the ``release-next-bundle`` branch and native build receipts.

Your First Cook
---------------

Nothing happens until a Houdini Engine session is running. HEGo does not start one for
you, because starting Houdini takes a moment and you may not want it on every project
load.

1. Open the **HEGo** panel at the bottom of the editor and go to the **Session** tab.
2. Pick a connection type and press **Start Session**. ``Named Pipe`` is the usual
   choice; the types are described below.
3. The status line turns green and reads *SessionSync is connected*. The log beneath it
   shows what happened, and is where to look first if it does not.

Then bring in an HDA:

4. Add a **HEGoNode3D** to your scene.
5. Select it and press **Select HDA** in the inspector, or set ``asset_name`` directly
   (for example ``Sop/my_tool``). The picker lists the HDAs Houdini has loaded — see
   the **Library** tab to check what that is.
6. Press **Recook** in the bottom panel.

The HDA's parameters appear in the panel, and its output appears in the scene tree
under a child node called ``Outputs``.

After saving changes to the HDA definition in Houdini, press **Rebuild** next to
**Recook**. HEGo reloads the library from disk, creates a fresh asset instance,
restores its parameters, uploads the current Godot inputs, and cooks it.

If nothing appears, the HDA is probably not marking its output. HEGo does not guess:
geometry becomes a mesh, but points only spawn objects if they carry ``hego_spawn``,
only instance if they carry ``hego_use_multimesh``, and so on. The
:doc:`output pages </node_reference/outputs/index>` list what each output type needs,
with examples.

Session Types
-------------

.. list-table::
   :widths: 24 76
   :header-rows: 1

   * - Type
     - When to use it
   * - **Named Pipe**
     - The default. HEGo connects to an existing server on the named pipe,
       including Houdini Session Sync, or starts a server if needed.
   * - **TCP Socket**
     - The same, over a socket. The connection data is the port number.
   * - **In Process**
     - Backed by a shared memory server. Fastest, and Houdini closes with Godot.

A session outlives a single cook, so cooking several HDAs reuses it. Stopping the
session resets every HEGo node's Houdini state; the next cook re-instantiates from the
parameters stashed in the scene. When attached to an existing server, stopping
HEGo only closes its connection and preserves the Houdini scene. Servers started
by HEGo are cleaned up when it disconnects.

Saving and Opening the Session
------------------------------

The **Session** tab offers two file actions while a session is running.

- **Save HIP File…** opens a file chooser. Pick a location to save the entire
  Houdini Engine scene, including the other assets in the session.
- **Open HIP File** writes the scene to a fresh temporary directory and launches
  Houdini with that copy. You can inspect the nodes and inputs there while
  continuing to work in Godot. Use **Save As** in Houdini to keep your edits
  somewhere permanent.

Examples
--------

The ``demo`` folder in the repository contains the project used for testing and development:

- **Strata island demo** (``demo/scenes/terrain_island.tscn``): the main scene of the demo
  project — a complete 4 km island built with Strata and the HEGo Strata bridge, playable
  without Houdini (see :doc:`/strata/example_island`).
- **Copia instancing demo** (``demo/copia_demo/copia_demo.tscn``): generates ~300,000
  instances with streaming, impostors, and colliders without Houdini (see
  :doc:`/copia/getting_started`).
- **Terrain3D examples**: the demo project also bundles
  `Terrain3D <https://github.com/TokisanGames/Terrain3D>`_ together with the HEGo Terrain3D
  bridge addon (``addons/hego_terrain3d``).

Troubleshooting
---------------

The **Session** tab's log is the first place to look. It shows everything HEGo does,
filtered by level and subsystem, and **Save log...** writes it to a file worth attaching
to a bug report. See :doc:`Logging </api/logging>` for what the levels mean and how to
turn on file logging.

Two failures worth recognising:

- *Session fails to start* — usually the Houdini installation path. HEGo warns when the
  configured path does not exist. Note the path is stored in the project, so a project
  authored on another OS carries that machine's path.
- *Cook succeeds but nothing appears* — the HDA cooked, but no output was marked. See
  the note above.
