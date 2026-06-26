Curve Output
============

Curves authored in Houdini are emitted on the Godot side as ``Path3D`` nodes parented under
``HEGoNode3D/Outputs``. Each curve part becomes one ``Path3D`` with a ``Curve3D`` resource
populated from the Houdini control points.

Curve Creation
--------------

Every curve primitive in the cooked HDA produces one ``Path3D`` node. In the case of polygonal curves, 
the control points (``P``) are simply added in order to the ``Path3D``'s ``Curve3D``.'

Godot's ``Curve3D`` doesn't currently seem to support NURBS curves, where the control points don't necessarily lie
on the curve itself. Consequently, Houdini NURBS curves are approximated by using the rational function for a NURBS curve, 
sampling points along the curve and adding them to the ``Curve3D``.

Godot's Curve3D works for Bezier curves, so Houdini Bezier curves are output accurately with adjustable control points.
Both open and closed curves are supported, with the curve ``is_closed`` property used to set the corresponding flag on the ``Curve3D``.

Primitive Attributes
--------------------

Curve output placement is controlled by primitive attributes:

.. list-table::
   :header-rows: 1
   :widths: 27 15 15 43

   * - Attribute Name
     - Attribute Type
     - Attribute Owner
     - Description
   * - ``hego_node_path``
     - String
     - Prim
     - Output node path/name under ``HEGoNode3D/Outputs``. Intermediate names become ``Node3D``
       containers; the last path component is the name of the ``Path3D`` itself. When
       missing, a default name of the form ``Curves/Curve3D_<type>_<index>`` is used.

Splitting Output into Multiple Curves
-------------------------------------

One HDA can emit many curves — assign different ``hego_node_path`` values across
primitives to place them under separate ``Node3D`` containers, mirroring the pattern used
for mesh output. Reusing the same path on a recook updates the existing ``Path3D`` in
place rather than creating duplicates.

Fetching Curves Directly
------------------------

For custom workflows, :ref:`HEGoAssetNode.fetch_curves()<class_HEGoAssetNode_method_fetch_curves>`
returns the raw curve data (positions, order, knots, requested prim/point attributes) as
an ``Array`` of dictionaries, so advanced users can build their own curve resources or
custom scene structures.
