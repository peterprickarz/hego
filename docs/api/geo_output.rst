Reading Output in Code
======================

Overview
--------

A cook can be read in two ways. The fetch configs (:ref:`HEGoFetchPointsConfig`,
:ref:`HEGoFetchSurfacesConfig`) describe the wanted attributes and splits ahead of
time in a resource. ``get_geo_output()`` describes them in code, at the point of use,
which is what you want as soon as the decision depends on anything:

.. code-block:: gdscript

    var output = await _await_task(asset_node.get_geo_output())
    await _await_task(output.load_attributes(["N", "up", "pscale", "hego_spawn", "hego_node_path"]))

    var groups = output.filter_by("hego_spawn", 1).split_by("hego_node_path")
    for node_path in groups:
        var points = groups[node_path].get_points(["N", "up", "pscale"])
        # points == { "P": [...], "N": [...], "up": [...], "pscale": [...] }

Both read the same cache, so mixing them costs nothing extra. A fetch config is
literally a saved set of arguments for this API: ``fetch_points()`` builds an output,
applies the config's filters and splits through it, and assembles the leaves with
``get_points()``. There is one implementation underneath both.

The built-in object spawning, multimesh and Terrain3D instancer handlers use the code
path, which is why their attribute lists live in the handler scripts rather than in a
resource beside them. Mesh output still goes through
:ref:`HEGoFetchSurfacesConfig`, since surface splitting works on vertices and
primitives rather than points.

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
