Supported HDA parameter types
=============================

Select a cooked HEGo node in the Scene tree to edit its HDA in the HEGo bottom
panel. Changes refresh Houdini's menu choices and its Hide When and Disable When
conditions, including when **Auto Recook** is off. Use **Recook** to update the
output manually. For a host with several HDAs, each section edits its own asset.

Tooltips and the asset help page
--------------------------------

Hover over a parameter label or control to read the first paragraph of its
entry in the HDA help page's ``@parameters`` section. Use ``#id`` to match the
internal parameter name, including the template name for a multiparm child.
An entry without an ID can match its label. Give parameters with repeated
labels their own IDs. The parameter's explicit Help field supplies the hint
when the page has no matching description. Scripts receive the same hint in
the ``help`` field of ``HEGoAssetNode.get_parms_dict()``.

For Markdown help, use a table under a **Parameters** heading. A
``Parameter`` column can contain an internal name or a unique label, and
the ``Description`` column supplies its hint. Web help URLs open on request.
Hover hints come from the embedded text or the explicit parameter Help.

For example, the first paragraph below becomes the hover hint for ``spacing``.
Both paragraphs appear on the full help page.

.. code-block:: text

   @parameters

   Sample spacing:
       #id: spacing

       Set the distance between neighboring samples, in metres.

       Smaller spacing adds more samples across the same area.

Click **Help** beside **Parameters** to read the full page in your default
browser. For hosts with several HDAs, each asset has its own **Help** button.
An HDA with an authored HTTP or HTTPS help URL opens that URL directly.
For embedded Houdini wiki pages, HEGo runs the installed Houdini help renderer
in the background and caches a standalone HTML article under ``user://hego/help/``.
Headings, parameter descriptions, lists and tables are readable offline.
Embedded Markdown and systems without the Houdini help renderer use a basic
local formatter. For interactive examples, private linked pages or media stored
in HDA sections, point the HDA's help URL at a site that serves them.

Folders and lists
-----------------

.. list-table::
   :header-rows: 1
   :widths: 27 73

   * - Houdini layout
     - Behaviour in the panel
   * - Simple folder
     - A labelled group with its contents always visible.
   * - Collapsible folder
     - A foldout that honors the HDA's initial open or closed setting. Opening or closing it is local to the panel. Its state survives a parameter refresh.
   * - Tabs
     - Sibling pages share a tab bar and open on the authored default page. Switching pages preserves the local selection and sends no parameter write or cook request.
   * - Radio-button folders
     - Selecting a page writes its Houdini radio index. The HDA, scene and presets can therefore use and restore the selection.
   * - Multiparm block
     - Edit the count, append a row, or insert and remove individual instances. Rows can contain folders and nested multiparms. Row numbers follow the HDA's start offset.
   * - Scrolling multiparm
     - The rows share a scrollable region with the count and append controls above it.
   * - Tabbed multiparm
     - Each instance has a tab. Choosing an instance is local to the panel. Structural edits update the available tabs.
   * - Float and color ramps
     - An ordered key list exposes position, value and Houdini interpolation. Edit the position to move a key and use the row controls to insert or remove it.

HAPI supplies ordinary folder styles directly. For authored folder defaults
and scrolling or tabbed multiparms, HEGo reads the saved definition's
DialogScript using Houdini's installed ``hotl`` utility. When a definition is unavailable locally, a block
can supply a ``hego_multiparm_style`` tag of ``scroll`` or ``tabs``. The
fallback is an editable list.

Values and actions
------------------

.. list-table::
   :header-rows: 1
   :widths: 27 73

   * - Parameter
     - Editing behaviour
   * - Integer, float and tuples
     - Numeric fields for each component, including wide tuples. Scalar sliders use the authored UI range. Typed entry can exceed a soft bound. Logarithmic sliders, angles, UVs and min/max pairs use their script type.
   * - Toggle and button
     - A checkbox changes a toggle. Pressing an action button invokes its Houdini callback once.
   * - Integer and string menus
     - Ordered, token-valued, mini, replace, toggle and dynamic menus use the authored choices. Button and icon strips expose their individual choices. Icon strips use the choice label when an icon is unavailable.
   * - String and string tuples
     - Edit each component. Multiline fields accept line breaks and commit on focus loss or Ctrl/Cmd+Enter. Ordinary string fields support Godot file and scene-node drops.
   * - RGB and RGBA
     - A color picker and component fields preserve HDR channels and the authored alpha component.
   * - File, geometry file, image file and directory
     - Edit the raw Houdini path, including variables. The local file dialog uses the authored pattern and access mode. Enter a server-accessible path for a remote Houdini session.
   * - Node and operator list
     - Choose a compatible live HEGo source for a node parameter or clear its link. The panel stores scene-relative references alongside the HAPI preset and resolves them on rebuild or scene reload. Operator-list strings support text entry.
   * - Label and separator
     - Authored text and separators appear in layout order.
   * - Geometry data, dictionary and other opaque values
     - Visible read-only when HAPI supplies no editable components. The field identifies the declared type.

Scripting
---------

``HEGoAssetNode.get_parms_dict()`` returns ordered descriptors, evaluated
``values``, raw string values, and the folder or instance hierarchy. Await each
returned task and check its result before using the data. Examples of accepted
write shapes using the Values test HDA follow.

.. code-block:: gdscript

   for edit in [
       ["enabled", true],
       ["wide_floats", PackedFloat64Array([0, 1, 2, 3, 4, 5, 6, 7, 8])],
   ]:
       var result := await HEGoNodeUtil.checked_task(self, asset.set_parm(edit[0], edit[1]))
       if not result.ok:
           push_error(result.message)
           return

Use ``Color`` for RGB/RGBA, ``PackedStringArray`` for string tuples and matching
Godot vectors or typed packed numeric arrays for numeric tuples.
``set_node_parm(name, source)`` accepts a live HEGo node and
``set_node_parm(name, null)`` clears it. Scripts can also set a literal Houdini
node path through ``set_parm(name, path)``. A literal path follows Houdini's
own path resolution.

Named presets are stored in ``res://hego/presets/``. For operators with
characters reserved on Windows, such as a namespaced or versioned HDA,
new files use an encoded filename under ``presets/encoded/``. Previously
saved Linux preset files remain accessible on Linux.

Test scene
----------

Open ``res://tests/fixtures/parameters/parameter_types.tscn`` in the demo
project. Select **ValuesFixture** and **StructureFixture** in turn and click
**Recook** on each. Both are dedicated test HDAs with empty geometry. The first
demonstrates value editors and callbacks. The second demonstrates folder and
list layouts, ramps and source selection. Choose **ValuesFixture** for
**Source SOP** to try a reference that can be saved and reopened.
