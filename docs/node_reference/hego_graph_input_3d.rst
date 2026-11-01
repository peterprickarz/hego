HEGoGraphInput3D
================

A graph of points and connections you draw in the 3D viewport and feed into an HDA.
Each point becomes a Houdini point, each connection an open polyline primitive.
Branches are allowed: a point with three or more connections is just a point several
polylines share.

The properties and methods are in :ref:`the class reference<class_HEGoGraphInput3D>`.
What a cook does with the geometry is :doc:`inputs/graph_input`. A demo scene lives at
``demo/scenes/GraphInput.tscn``.

This is not a :doc:`Path3D input <inputs/path3d_input>`. Path3D becomes one resampled
curve. A graph is many polyline edges that can meet, so an HDA written for a single
path should treat each primitive as an edge.

Setup
-----

1. Add a **HEGoGraphInput3D** to the scene.
2. Optionally add a **HEGoGraphAttributes** child and fill its ``attributes`` list.
   That list is the schema: the names, types and UI the editor offers on points and
   connections. Save the child as its own scene if several graphs should share it.
3. Select the graph. The 3D viewport takes over: a toolbar appears in the spatial
   editor menu, and a strip along the bottom edits attributes on the current selection.
4. Draw the graph, then wire the node into a :ref:`HEGoNode3D<class_HEGoNode3D>` input
   and recook. Nothing is sent to Houdini until that cook.

Positions are stored in the graph node's local space. Moving or rotating the node
moves the whole graph.

Attribute schema
----------------

Each entry on the ``HEGoGraphAttributes`` child is a
:ref:`HEGoGraphAttributeDef<class_HEGoGraphAttributeDef>`:

.. list-table::
   :header-rows: 1
   :widths: 22 78

   * - Field
     - Meaning
   * - ``attribute_name``
     - Houdini attribute name. Unique per owner on one graph. ``P``, ``Cd`` and
       names starting ``_hego_`` are reserved.
   * - ``owner``
     - **Point** or **Connection**. Connections become primitive attributes.
   * - ``value_type``
     - **Float**, **Int** or **String**.
   * - ``default_*``
     - Value given to a newly created point or connection.
   * - ``int_as_toggle``
     - For ints: the editor shows a checkbox and stores 0 or 1.
   * - ``string_options``
     - For strings: a non-empty list turns the editor into a dropdown. Empty is
       free text.

Several ``HEGoGraphAttributes`` children concatenate in tree order. Changing the
schema adds missing arrays at their defaults and drops keys that are gone. Existing
values for names that remain are kept.

Viewport
--------

Select the graph node. Camera navigation is unchanged (middle mouse, right mouse,
Alt+left). Left mouse is the graph.

Modes
~~~~~

The toolbar switches **Select** and **Draw**. Draw is the default.

**Draw**

- **Ctrl+click** empty space: add a point. With a point selected, the new point is
  connected to it; with nothing selected, it is a loose, unconnected point. The new
  point is selected, so the next **Ctrl+click** continues the polyline.
- **Ctrl+click** an existing point: connect the selected point to it, then select
  it. That is how you branch. With nothing selected it just selects the point.
- **Ctrl+click** a connection: split it, inserting a point under the cursor. Both
  new connections inherit the original connection's attributes. Float point
  attributes interpolate between the endpoints; discrete fields use the nearer endpoint.

**Select**

- Drag a box on empty space while nothing is selected: points and connection
  midpoints inside the rectangle are selected. **Shift+drag** works with a
  selection too, and adds.

**Both modes**

- **C**: connect exactly two selected points. Existing connections are left unchanged.

- Click a point: Godot's move widget (the W tool, translation only) appears on
  it. **Shift** toggles extra points into that selection. Drag an arrow or a
  plane square to move the point.
- Click a connection: select the edge (orange). **Shift** toggles it into the
  selection.
- With connections or several points selected, the move widget sits at the centre
  of the selection. Dragging it moves every selected point and both ends of every
  selected connection together, as one undo step.
- Click empty space: clear the selection. A click never places a point without Ctrl.
- Right-click a point: a menu with **Select** and **Delete**. Right-click a
  connection: **Select**, **Split** and **Delete**. Right-drag elsewhere still
  moves the camera.
- **X**, **Delete** or **Backspace**: selected connections are removed; selected points
  are removed and take their incident connections with them. The keys work while the
  mouse is over the viewport, even if another panel has keyboard focus. With nothing
  selected, Delete still deletes the node, as the editor usually does. X is ignored
  while a mouse button is held, so it still locks the axis during an arrow drag.

Undo applies to every topology and attribute change.

Placement
~~~~~~~~~

Where a new point (or a dragged point) lands:

.. list-table::
   :header-rows: 1
   :widths: 22 78

   * - Mode
     - Hit
   * - **Camera plane**
     - The plane facing the camera through the last created or selected point, or
       through the graph node if there isn't one.
   * - **World plane**
     - An axis-aligned plane through the graph origin. The toolbar picks XZ (Godot's
       ground), XY or YZ, plus an offset along the normal.
   * - **Geometry**
     - Physics first, then visible meshes and CSG, then Terrain3D if that addon is
       present. The graph node itself is ignored; cooked ``Outputs`` are valid so you
       can draw on generated geometry. If nothing is hit, it falls back to the camera
       plane.

Attribute strip
~~~~~~~~~~~~~~~

The bottom strip always lists every schema entry, so it keeps the same height and
the viewport does not jump. Entries are editable while at least one element of
their owner (point or connection) is selected, and greyed out otherwise.

- Float: a spin box.
- Int with ``int_as_toggle``: a checkbox.
- Int otherwise: an integer spin box.
- String with ``string_options``: a dropdown.
- String otherwise: a line edit.

A mixed selection shows an empty control. Committing a value writes it onto every
selected element of that owner.

Marker size
-----------

Point markers and connection lines keep a constant size on screen at any distance.
The size is in the editor settings: ``hego/graph/point_size`` (default 10 px) and
``hego/graph/line_width`` (default 2.5 px). Picking uses the same pixel sizes plus a
margin. Hovered and selected markers are drawn larger.

Path visualization
------------------

Turn on **Path Mode** (inspector group *Visualization*) to see the graph as a path
instead of thin lines: a translucent ribbon or tube along every connection, scaled by
a width attribute, with an outline. It is part of the graph's editor gizmo: it never
reaches Houdini, is never drawn in the running game or saved, and **View > Gizmos**
hides it. The mesh is rebuilt only when the graph, its attributes or these properties
change.

.. list-table::
   :header-rows: 1
   :widths: 28 72

   * - Property
     - Meaning
   * - ``path_mode``
     - Draws the path.
   * - ``path_width_attribute``
     - Attribute that gives the width in metres (default ``path_width``). A connection
       attribute of that name wins; a point attribute is interpolated along the
       connection. Missing or zero values use ``path_default_width``.
   * - ``path_shape``
     - ``Ribbon``: a flat band lying on the surface. ``Tube``: a cylinder per
       connection (the width is the diameter) with a sphere at each point.
   * - ``path_color``, ``path_outline``, ``path_outline_color``
     - Translucent fill, and the boundary: both ribbon edges and the end caps, or the
       tube's silhouette lines and end rings.
   * - ``path_drape``, ``path_sample_spacing``, ``path_lift``
     - Follow the surface between points (every ``path_sample_spacing`` metres),
       orient the ribbon to the surface normal, and lift it ``path_lift`` metres to
       avoid z-fighting. Without a surface the path is straight and faces up.
   * - ``path_tube_sides``
     - Segments around a tube.

Where connections meet, every ribbon is cut back until its edges meet its neighbours
and the gap is filled around the point, so crossings do not double the transparency.

Surface and snapping
--------------------

The *Surface* group tells the graph where the ground is, for snapping and for draping
the path. ``surface_provider`` is an optional node with
``sample_height(Vector2) -> float`` (local x/z in, local height out) and optionally
``contains_position(Vector2) -> bool``; a heightfield terrain without colliders can
plug in this way, and HEGo depends on none. Without a provider a physics ray from above
is used. The *Geometry* placement mode also asks any node that has
``raycast_surface(origin, direction) -> {"position": Vector3}``.

* ``snap_to_surface``: every point added or moved in the editor lands on the surface,
  plus ``surface_offset`` metres.
* **Snap all points to surface** (button): moves every point onto the surface as one
  undoable step. ``snap_all_to_surface()`` does the same from code.

Feeding an HDA
--------------

Drop the ``HEGoGraphInput3D`` on an input of a ``HEGoNode3D`` the same way you would a
``Path3D`` or a mesh. Recook. The graph is uploaded as a regular input SOP, not an
input-curve node:

- ``npoints()`` is the number of graph points, including isolated ones.
- ``nprims()`` is the number of connections. Each primitive is an open linear
  polyline with two vertices.
- Point attributes from the schema sit on points; connection attributes sit on
  those primitives.
- ``_hego_node_path`` is set as well, as a prim string when there are connections
  and as a point string when the graph is only points, so several graphs on one
  HDA input stay distinguishable.

A junction is a point with valence three or more:

.. code-block:: c

   // Primitive wrangle: each connection is a 2-vertex polyline
   int pts[] = primpoints(0, @primnum);
   vector a = point(0, "P", pts[0]);
   vector b = point(0, "P", pts[1]);

   // Point wrangle: a branch is a point several polylines share
   int spokes[] = pointprims(0, @ptnum);
   if (len(spokes) >= 3)
       i@branch = 1;

The cook conversion, including the attribute table, is
:doc:`inputs/graph_input`.

From a script of your own, the same upload is
:ref:`HEGoInputNode.set_geo<class_HEGoInputNode_method_set_geo>` with
``prim_type`` ``"polyline"``. ``HEGoNode3D`` already does that through
:ref:`HEGoInputNodes<class_HEGoInputNodes>`.
