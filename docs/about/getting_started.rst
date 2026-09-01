Getting Started
===============

License Requirements
--------------------

You need a full Houdini FX, Core, or commercial Houdini Engine license to use this integration.

Houdini
-------

Make sure you have the correct Houdini version installed. Currently **22.0.368**. It may work with
other versions, but that is what it is built with. It works on Windows and Linux. Linux testing is
done on Linux Mint, so other distros may have issues. Please create an issue on GitHub or let us
know on the Discord if you run into issues.

Installation
------------

Simply download the release and unzip into your Godot project. In the project settings, make sure
to enable the ``HEGo`` addon under the **Plugins** tab, and set your Houdini installation path
(filter by ``Houdini Installation Path`` under the **General** tab).

- **Windows:** ``C:/Program Files/Side Effects Software/Houdini 22.0.368``
- **Linux:** ``/opt/hfs22.0.368``

You will need to restart Godot after enabling the plugin.

Git submodule method
~~~~~~~~~~~~~~~~~~~~

.. code-block:: bash

   # Add HEGo as a submodule in your Godot project
   git submodule add -b release https://github.com/peterprickarz/hego.git addons/hego
   git submodule update --init --recursive

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
     - The default. HEGo starts a Houdini Engine server and talks to it over a pipe.
   * - **TCP Socket**
     - The same, over a socket. The connection data is the port number.
   * - **In Process**
     - Backed by a shared memory server. Fastest, and Houdini closes with Godot.

A session outlives a single cook, so cooking several HDAs reuses it. Stopping the
session resets every HEGo node's Houdini state; the next cook re-instantiates from the
parameters stashed in the scene.

Examples
--------

The ``demo`` folder in the repo contains the project used for testing and development. Even if you
only download the binaries, it is still recommended to look at this demo project. The demo project
also comes with `Terrain3D <https://github.com/TokisanGames/Terrain3D>`_ installed and contains
examples for generating terrains using Terrain3D.

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
