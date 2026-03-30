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
