Path3D Input
============

Path3D is sent to Houdini as curve geometry, useful for generating variations of shapes
along a curve or extracting curve-based information.

Input Conversion
----------------

.. list-table::
   :header-rows: 1
   :widths: 20 20 60

   * - Input Type
     - Houdini Data
     - Description
   * - Path3D
     - Curve
     - Path3D is converted to a curve for Houdini input

Attributes
----------

No special HEGo metadata attributes are added for Path3D inputs. The curve points are
directly converted from the Path3D's baked points.

Unlike mesh inputs, a curve input carries no ``_hego_node_path``, so an HDA taking
several curve inputs tells them apart by input index rather than by attribute.

Example
-------

The curve arrives as ordinary points on a polyline, so nothing special is needed to
read it:

.. code-block:: c

   // Point wrangle on input 0
   @P += normalize(@N) * 0.5;   // the baked Path3D points, in Godot's coordinates

Because the points are baked, the density you get is the one Godot resampled the
``Curve3D`` to. Resample in Houdini if you need a different one.
