Supported HDA Parameter Types
=============================

This page documents what parameter types are currently supported by the HEGo bottom panel
for ``HEGoNode3D`` HDAs.

The following parameter families are supported in the bottom panel:

.. list-table::
   :header-rows: 1
   :widths: 35 65

   * - HAPI Family
     - UI Type
   * - Int (size 1-4)
     - Int, Int2, Int3, Int4
   * - Float (size 1-4)
     - Float, Float2, Float3, Float4
   * - Toggle
     - CheckBox
   * - String (size 1)
     - LineEdit
   * - Folder
     - Folder Container
   * - Multiparm list
     - Instance count + per-instance controls

Notes
-----

- All folders are shown as simple folders (no tabbed folder UI).
- All multiparms are shown as lists.
- For Int and Float parameters with tuple size 1, slider min/max values are taken from the HDA parameter min/max when available.
