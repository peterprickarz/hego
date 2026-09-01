Reading Output in Code
======================

Overview
--------

Read a cook's output in code, at the point of use:

.. code-block:: gdscript

    var output = await _await_task(asset_node.get_geo_output())
    await _await_task(output.load_attributes(["N", "up", "pscale", "hego_spawn", "hego_node_path"]))

    var groups = output.filter_by("hego_spawn", 1).split_by("hego_node_path")
    for node_path in groups:
        var points = groups[node_path].get_points(["N", "up", "pscale"])
        # points == { "P": [...], "N": [...], "up": [...], "pscale": [...] }

Points go through ``get_geo_output()``; surfaces go through ``get_surface_output()``,
which returns a :ref:`HEGoGeoSurfaces<class_HEGoGeoSurfaces>` selecting primitives
rather than points. Every built-in handler uses this API, which is why their
attribute lists live in the handler scripts rather than in a resource beside them.

.. warning::

   The fetch configs - ``HEGoFetchPointsConfig``, ``HEGoFetchSurfacesConfig`` and the
   ``.tres`` files under ``point_filters/`` and ``surface_filters/`` - are
   **deprecated**. They still work, and will keep working long enough for existing
   projects to move across, but they will be removed. **Use this API for anything
   new**, and port existing code when convenient.

   Nothing is lost in the move. A fetch config is a saved set of arguments for this
   same API: ``fetch_points()`` builds an output, applies the config's filters and
   splits through it, and assembles the leaves with ``get_points()``. One
   implementation underneath both, one cache, same results - the difference is that
   the code path can decide anything at runtime and keeps the attribute names next to
   the code that reads them.

Porting from a fetch config
---------------------------

Each config field maps onto a call:

.. list-table::
   :widths: 34 66
   :header-rows: 1

   * - Config field
     - Code
   * - ``read_attribs``
     - ``load_attributes([...])``, then the names you pass to ``get_points()``
   * - ``filter_attribs`` / ``filter_attrib_values``
     - ``filter_by(name, value)``, chained for more than one
   * - ``split_attribs``
     - ``split_by(name)``, nested for more than one level
   * - ``normal``, ``color``, ``uv``, ``uv2``, ``tangents``
     - the ``point_attribs`` argument of ``get_surface_output()``

So a points config reading ``N`` and ``pscale``, filtering on ``hego_spawn == 1`` and
splitting on ``hego_node_path`` becomes:

.. code-block:: gdscript

    var output = await _await_task(asset_node.get_geo_output())
    await _await_task(output.load_attributes(["N", "pscale", "hego_spawn", "hego_node_path"]))

    var groups = output.filter_by("hego_spawn", 1).split_by("hego_node_path")
    for node_path in groups:
        var points = groups[node_path].get_points(["N", "pscale"])

Why it is fast
--------------

The geometry never leaves C++. A selection is a list of point indices; filtering and
splitting produce new selections without copying attribute values, and only
``get_points()`` assembles data to hand over. A hundred thousand points stay a
hundred thousand points until you ask for a subset of them.

Attribute values are cached per cook and shared by every output of that cook, so
reading ``P`` here after the mesh output already read it costs nothing. The cache
invalidates itself when the node cooks again.

Loading attributes
------------------

``load_attributes()`` is the only call that talks to Houdini, so it returns a
:doc:`task <task_pattern>`. Everything after it is in-memory work and returns
immediately. Attributes another output already read are served from the cache
without a round trip.

Reading an attribute that was never loaded returns an empty array and warns; it does
not silently fetch from the main thread.

You can also preload while fetching the output, which saves an await:

.. code-block:: gdscript

    var output = await _await_task(asset_node.get_geo_output(["N", "up", "pscale"]))

Discovering what an HDA produced
--------------------------------

Attribute names are available before anything is loaded, so a handler can adapt to
whatever the HDA happens to carry instead of naming everything up front:

.. code-block:: gdscript

    for name in output.get_attribute_names_with_prefix("hego_"):
        print(name, " is present on this output")

    if output.has_attribute("Cd"):
        await _await_task(output.load_attributes(["Cd"]))

Reference
---------

``HEGoGeoOutput``

.. list-table::
   :widths: 45 55

   * - ``is_valid()``
     - Whether the cook produced points to read.
   * - ``get_point_count()``
     - Number of points in the output.
   * - ``get_attribute_names(owner)``
     - Every attribute name, without loading anything.
   * - ``get_attribute_names_with_prefix(prefix, owner)``
     - The names starting with ``prefix``.
   * - ``has_attribute(name, owner)``
     - Whether an attribute exists.
   * - ``load_attributes(names, owner)``
     - Reads attributes from Houdini. Returns a ``HEGoTask``.
   * - ``get_attribute(name, owner)``
     - The values of a loaded attribute.
   * - ``select_all()`` / ``filter_by(name, value)`` / ``split_by(name)``
     - Selections over the points.

``HEGoGeoSelection``

.. list-table::
   :widths: 45 55

   * - ``size()``
     - Points in the selection.
   * - ``get_indices()``
     - The point indices.
   * - ``filter_by(name, value)``
     - The subset matching a value. Chainable.
   * - ``split_by(name)``
     - ``{ value: selection }``, grouped by an attribute.
   * - ``get_points(names)``
     - ``{ name: values }`` for this selection, always including ``P``.

``owner`` is one of ``HEGoGeoOutput.OWNER_VERTEX``, ``OWNER_POINT`` (the default),
``OWNER_PRIM`` or ``OWNER_DETAIL``.

Skipping handlers that have nothing to do
-----------------------------------------

A cook runs every output handler, and most HDAs feed one or two of them. Rather
than have each handler ask Houdini for attributes that are not there,
``get_output_summary()`` answers once what the cook produced:

.. code-block:: gdscript

    var summary = await _await_task(asset_node.get_output_summary())
    # {
    #     "has_mesh": true, "has_points": false, "has_curves": false, "has_volumes": false,
    #     "point_attributes": [...], "prim_attributes": [...],
    # }

It costs nothing beyond the attribute name lookups, which are cached like
everything else, and the part list is already known from the cook.

Each built-in handler exposes ``should_handle(summary)`` deciding from it, so the
requirement stays next to the code that has it: mesh output wants ``has_mesh``,
object spawning wants points carrying ``hego_spawn``, Terrain3D output wants
volume parts, and so on. Your own handler can do the same.

The rule is deliberately one-sided: **anything unknown means the handler runs**. A
summary that could not be read, or that is missing a key, costs a little time
rather than silently producing no output.
