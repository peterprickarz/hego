Scripting HEGo
==============

:doc:`HEGoNode3D </node_reference/hego_node_3d>` covers the great majority of tools, and
none of it is privileged: it is a GDScript file calling the same API a script of your own
can call. These pages are that API.

Read :doc:`custom_nodes` first. It is the whole shape of a node that drives an HDA itself,
and the rest of this section fills in the parts of it:

- :doc:`task_pattern` -- why every call into Houdini returns a task, and how to wait for one.
- :doc:`geo_output` -- reading the points and surfaces a cook produced.
- :doc:`node3d_modules` -- the output handlers, and writing one of your own.
- :doc:`logging` -- getting your messages into the same place HEGo's go.

Each class is documented individually in the :doc:`/classes/index`.

.. toctree::
   :maxdepth: 1

   custom_nodes
   task_pattern
   geo_output
   node3d_modules
   logging
