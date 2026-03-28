Getting Started
===============

License Requirements
--------------------

You need a full Houdini FX, Core, or commercial Houdini Engine license to use this integration.

Houdini
-------

Make sure you have the correct Houdini version installed. Currently **21.0.631**. It may work with
other versions, but that is what it is built with. It works on Windows and Linux. Linux testing is
done on Linux Mint, so other distros may have issues. Please create an issue on GitHub or let us
know on the Discord if you run into issues.

Installation
------------

Simply download the release and unzip into your Godot project. In the project settings, make sure
to enable the ``HEGo`` addon under the **Plugins** tab, and set your Houdini installation path
(filter by ``Houdini Installation Path`` under the **General** tab).

- **Windows:** ``C:/Program Files/Side Effects Software/Houdini 21.0.631``
- **Linux:** ``/opt/hfs21.0.631``

You will need to restart Godot after enabling the plugin.

Git submodule method
~~~~~~~~~~~~~~~~~~~~

.. code-block:: bash

   # Add HEGo as a submodule in your Godot project
   git submodule add -b release https://github.com/peterprickarz/hego.git addons/hego
   git submodule update --init --recursive

Examples
--------

The ``demo`` folder in the repo contains the project used for testing and development. Even if you
only download the binaries, it is still recommended to look at this demo project. The demo project
also comes with `Terrain3D <https://github.com/TokisanGames/Terrain3D>`_ installed and contains
examples for generating terrains using Terrain3D.
