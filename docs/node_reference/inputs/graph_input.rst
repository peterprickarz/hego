HEGoGraphInput3D Input
======================

``HEGoGraphInput3D`` is sent to Houdini as points plus open polyline primitives, one
polyline per connection. Branches are several polylines sharing a point index.

Input Conversion
----------------

.. list-table::
   :header-rows: 1
   :widths: 20 20 60

   * - Input Type
     - Houdini Data
     - Description
   * - HEGoGraphInput3D
     - Points and polylines
     - Each graph point is a Houdini point. Each connection is an open linear
       polyline primitive with two vertices. Isolated points have no primitive.

This is not a ``Path3D`` input. Path3D becomes one resampled curve through
``CreateInputCurveNode``. A graph is a regular input SOP whose part is a curve
mesh of polylines, so an HDA that expected a single path should treat each
primitive as an edge.

Attributes
----------

.. list-table::
   :header-rows: 1
   :widths: 32 18 12 38

   * - Attribute Name
     - Attribute Type
     - Owner
     - Description
   * - ``P``
     - Float3
     - Point
     - Point positions, in the graph node's space, with the node's transform
       applied on the object
   * - ``_hego_node_path``
     - String
     - Prim, or Point if the graph has no connections
     - Godot scene path of the source node
   * - user-defined
     - Float, Int or String
     - Point or Prim
     - Whatever a ``HEGoGraphAttributes`` child declared. Point attributes follow
       points; connection attributes follow polyline primitives.

Example
-------

An HDA that wants one thing per edge reads primitives; one thing per vertex
reads points. A junction is a point with three or more primitives:

.. code-block:: c

   // Primitive wrangle: each connection is a 2-vertex polyline
   int pts[] = primpoints(0, @primnum);
   vector a = point(0, "P", pts[0]);
   vector b = point(0, "P", pts[1]);

   // Point wrangle: valence at a junction
   int spokes[] = pointprims(0, @ptnum);
   if (len(spokes) >= 3)
       i@branch = 1;
