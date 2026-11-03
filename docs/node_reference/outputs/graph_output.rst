Graph Output
============

Houdini curves and polylines that carry per-point data (a radius, an up vector, ids)
come back as a :ref:`HEGoGraph3D<class_HEGoGraph3D>` under ``HEGoNode3D/Outputs``: the same
node type as an authored :doc:`graph input <../hego_graph_input_3d>`, so it can be
inspected, edited, saved and fed into another cook.

The data travels through the loose-point output, which reads every point attribute in
bulk. At the end of the HDA, keep the curve points (Add SOP, **Delete Geometry But Keep
the Points**) and link each point to the one before it on its curve.

Point Attributes
----------------

.. list-table::
   :header-rows: 1
   :widths: 27 12 61

   * - Attribute Name
     - Type
     - Description
   * - ``hego_graph``
     - Int
     - 1 on every graph point. Points without it are left to the other handlers.
   * - ``hego_graph_path``
     - String
     - Node path under ``Outputs`` of the graph the point belongs to, default ``Graph``.
       One cook can build several graphs.
   * - ``hego_graph_id``
     - Int
     - Optional id, unique within the cook; default the point number.
   * - ``hego_graph_prev``
     - Int
     - Id of the point this one connects to, ``-1`` for none. A polyline links every
       point but its first; a shared id (a fork) joins several curves.
   * - ``hego_graph_conn_<name>``
     - any
     - Connection attribute ``<name>`` of the connection from this point to its
       predecessor.
   * - every other attribute
     - Float, Int, String, Vector3
     - Point attribute of the graph, declared on an ``Attributes`` child
       (``HEGoGraphAttributes``). ``P`` and names starting ``hego_`` are not carried.

Example
-------

.. code-block:: c

   // Point wrangle on open polylines, before an Add SOP that keeps only the points
   int prims[] = pointprims(0, @ptnum);
   int pp[] = primpoints(0, prims[0]);
   int k = find(pp, @ptnum);
   i@hego_graph = 1;
   s@hego_graph_path = "Curves";
   i@hego_graph_id = @ptnum;
   i@hego_graph_prev = k > 0 ? pp[k - 1] : -1;

The points must not be renumbered between this wrangle and the output (merge other
geometry after them). The graph is built in the HDA's output space, so a host at the
origin gives world positions.
