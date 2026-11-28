# HDA parameter support on `next`

Implemented on `next`, 25 November 2026. The audit baseline was `a5dc78b6`, Godot 4.7.2 and Houdini 22.0.429. Scope covers the public `HEGoAssetNode` parameter API, the HEGo bottom panel and parameter persistence.

The [support reference](../node_reference/parameters/supported_parameter_types.rst) describes the current editor and scripting API. Open the [two-HDA test scene](../../demo/tests/fixtures/parameters/parameter_types.tscn) to try the controls. Both fixtures cook empty geometry.

## Evidence from the baseline assets

We walked the saved parameter template group from `hou.hda.definitionsInFile()` for each of the 25 HDAs in `otls/`. The 452 authored templates include 46 simple folders, five tab folders, four collapsible folders, 22 multiparm blocks and one ordered menu. Each multiparm child template was counted once. Those templates declare 12 Disable When and two Hide When conditions. RGB/RGBA, ramps, file parameters, action buttons and Houdini node-reference templates had no authored examples in this collection.

| Live check on a private HAPI instance | Consequence for HEGo |
| --- | --- |
| `HEGo_MaterialDistribution.prior_materials` reports an integer with two choices. Its authored labels distinguish keeping stage materials from regenerating them. | The panel gives the artist an integer field. This is a first-release acceptance case for a labelled menu. [Material distribution builder](../../scripts/houdini/build_material_distribution_hda.py) |
| Turning off `HEGo_IslandErosion.manual_transition` sets HAPI's `disabled` flag for both `manual_transition_width` and `manual_height_channel`. | HEGo omits the flag. An edit must refresh dependent controls even when the user has chosen to cook manually. [Island interface](../../scripts/houdini/build_island_hda.py) |
| `HEGo_Terrain3DOutput` reports one folder list of size three, followed by three sibling folders. All four have parent ID −1. The five fields point to their respective folder IDs. | The panel renders the fields in three generic folders. An implementation that traverses only the list's `children` will miss the tabs. [Terrain3D Output HDA](../../otls/HEGo_Terrain3DOutput.hda) |

## Audit baseline before implementation

Houdini 22 declares 17 concrete `HAPI_ParmType` values. Menus, ramps and specialized widgets also depend on parameter metadata. For types absent from the shipped assets, we checked the code paths and used disposable test parameters in a private Houdini session to verify ambiguous cases. [SideFX parameter metadata](https://www.sidefx.com/docs/hengine/struct_h_a_p_i___parm_info.html)

| Parameter family | Native read and write at baseline | Bottom panel at baseline |
| --- | --- | --- |
| `INT`, `FLOAT`, `TOGGLE` | Scalar numbers and matching 2–4 component Godot vectors work. Toggles use integer 0/1. A Godot `bool` is rejected. | Numeric controls and checkboxes work. Numeric widgets use hard-range fields and miss the authored slider range. |
| Integer and string menus | Discovery returns choice labels and tokens. Setters accept the underlying integer or string. Discovery omits the menu mode and integer token-as-value flag. | Raw number or text field. Dynamic options, editable menus and multi-selection have no corresponding controls. |
| `STRING` and wider tuples | Discovery reads all evaluated string components and numeric tuple components. Writes support one string or at most four numeric components. | String tuples show only their first component. Wide numeric tuples get a four-component editor. Both produce edits the setter rejects. |
| `COLOR` | Reads RGB/RGBA components and accepts a matching `Vector3` or `Vector4`. The setter rejects Godot `Color`. | No color control. |
| `PATH_FILE`, `PATH_FILE_GEO`, `PATH_FILE_IMAGE`, `PATH_FILE_DIR` | The scalar string write path includes all four. Reads use evaluated strings for the first three. Directory sits outside HAPI's string enum range and HEGo omits its value, although HAPI supplies it. | All four are skipped. Ordinary string fields do accept Godot file and scene-node drops. |
| `BUTTON` | Integer writes invoke the HAPI callback. | One click in the actual panel incremented an artificial test HDA's callback counter from 0 to 1 with auto-recook off on 22.0.511. The widget also printed an incorrect “not supported yet” warning. [SideFX parameter guide](https://www.sidefx.com/docs/hengine/_h_a_p_i__parameters.html) |
| `FOLDER`, `FOLDERLIST`, `FOLDERLIST_RADIO`, `LABEL`, `SEPARATOR` | Discovery returns hierarchy records. Radio selection is missing, and label text can include multiple string components that the reader skips. | One generic folder control. Folder lists, radio selectors, labels and separators are skipped. |
| `MULTIPARMLIST` and float/color ramps | Counts, instances, children and insert/remove exist. Discovery omits `rampType`. Structural HAPI errors can be logged while the task reports completion. | Ordinary lists support resizing and per-instance edits. Ramps fall through to the generic list, with no dedicated key editor and no control for a color key's value. |
| `NODE` and operator-path lists | A valid Houdini path string can bind a single node. The resolved node ID and typed connection operations are missing from HEGo. The probed operator list was a `STRING` with script type `OPLIST`. | Single-node controls are skipped. Operator lists get ordinary text editing. |

The relevant code is the [parameter reader](../../src/util/parm/get_parms.cpp), [validated setters](../../src/util/parm/set_parms.cpp), [asset task bindings](../../src/hego_nodes/hego_asset_node.cpp) and [panel dispatch and edit handlers](../../demo/addons/hego/ui/hda_tab.gd). The [current support reference](../node_reference/parameters/supported_parameter_types.rst) documents the implementation on `next`.

## Implementation stages

### 1. Make the shipped interfaces behave as authored

- Extend `get_parms_dict()` additively. Keep its existing keys, evaluated `values`, ordering, `children` and `instances` for script callers. Expose script type, choice mode and token policy, effective disabled/visible state, UI range flags and bounds, and the folder ordering needed by the panel. Check HAPI read results so an unreadable value cannot appear as zero or an empty menu. Use a read-only explanation for visible, unhandled controls and continue rendering accessible descendants.
- Choose widgets by semantic type and tuple size. Give toggles precedence over choice metadata because HAPI can advertise choices on a toggle. Render ordinary and mini menus with their labels. Commit the ordinal for an ordered integer, the numeric token for a token-valued integer, and the string token for a string menu. Preserve free entry for replace menus and Houdini's token selection for toggle menus. Refresh dynamic choices after cooks and preserve an existing unlisted value until the user makes a selection.
- Group the consecutive folder descriptors identified by a list's size and HAPI order, then attach each folder's contents. Consume every descriptor once. Render simple folders as permanently open labelled groups. Honor the authored initial foldout state and default tab index from the saved definition. Retain the user's local open state on refresh. Give sibling tab folders a shared tab bar and preserve the selected page across redraws without writing a parameter. Give radio folders a marked selection and read/write component 0. A radio list's size counts tabs. Render labels, including their authored text, and separators as display elements. [SideFX folder settings](https://www.sidefx.com/docs/houdini/ref/windows/optype.html#in-header-collapsing)
- After successful edits, refresh HAPI's effective state for the owning asset and preserve focus and the existing recook policy. Use soft bounds for sliders, enforce only hard bounds on entry, and report write failures before recooking or saving a preset. Remove the incorrect button warning and retain one checked write per click. Verify that opening the panel or restoring a preset never replays the action. Accept Godot `bool` for toggles alongside existing integer callers.

**First release check.** Choose each mode on Prior Stage Materials, flip Manual Transition with auto-recook off, and open each Terrain3D Output tab. Verify the stored choice, the two disabled fields, all five tab fields exactly once, and zero parameter writes from opening ordinary tabs.

### 2. Add color and path editors, then complete tuple editing

- Accept Godot `Color` for `COLOR` and retain vector callers. Select RGB or RGBA from the declared arity, preserve HDR values and verify the stored components after a picker edit.
- Expose raw path text alongside evaluated values, including directory values. Use the authored wildcard pattern (`typeInfoSH`) and browse mode (`permissions`) for open, save and directory pickers. Keep manual entry for Houdini paths such as `$HIP`, `$F` and `opdef:`. Resolve a local Godot file selection to a Houdini-readable path only when appropriate for the session. A remote server needs a path on its own filesystem. Preserve ordinary string drag-and-drop used by `target_layer_path`.
- Support `PackedStringArray` for string tuples and typed packed numeric arrays for wider tuples. Validate the full element count, component types, bounds and numeric conversion before writing. String writes must address each component index. Keep existing vector calls and the existing rejection of an untyped Array for a vector. Generate the correct number of component fields instead of clamping the editor to four.

**Release check.** Round-trip RGB, RGBA with alpha, HDR, all four path types, a two-string tuple and a nine-float tuple. Include an authored path containing a variable, an invalid last component, and a neighbouring parameter that must retain its value.

### 3. Build ramp editing on reliable multiparm operations

Expose `rampType` and templated child names. Read each key's position, scalar or RGB value, and interpolation from its instance. Implement add, remove, move and edit using the existing multiparm operations. Re-read instance metadata after every structural edit before addressing children. Preserve per-key interpolation, including modes a Godot preview cannot display exactly. A key list with editable numeric positions can ship before a graphical curve editor.

Make structural tasks report HAPI failures and guard against an asset rebuild or session change. Render normal blocks as rows, scrolling blocks as a bounded list and tabbed blocks as one page per instance. Keep nested controls accessible. Discover the layout from the saved HDA DialogScript where HAPI omits it. Test both HAPI start offsets, empty lists, middle insertion/deletion, and two instances with different values. Confirm a preset restored on a fresh instance reproduces the ordered ramp keys and interpolation and gives the same sampled cook result.

### 4. Add typed Houdini node references and triage specialized controls

Use the existing `GetParmNodeValue` and `SetParmNodeValue` bindings for single-node parameters. Expose the accepted node type and flags. Offer compatible live HEGo sources, support clearing, and re-resolve a durable source reference when the asset or session is rebuilt. Preserve the existing string API where HAPI accepts it. Handle operator-list text separately. Verify connect, replace, clear and rebuild against a cooked output, including a rejected incompatible source. [SideFX node parameter APIs](https://www.sidefx.com/docs/hengine/group___parms.html)

Angles, UVs, directions, min/max pairs, logarithmic sliders, multiline strings and button/icon strips use the scalar, tuple and menu editors. In a private 22.0.429 probe, dictionary and geometry-data templates both appeared as integer descriptors with size zero. Show their declared type read-only and defer editable support until a lossless HAPI read/write path is demonstrated.

## Verification

The [widget suite](../../demo/tests/hego_parameter_widgets_test.gd) checks visual layout and emitted edits. The [native regression](../../demo/tests/hego_parameter_native_test.gd) checks typed writes and batch validation. The [licensed fixture suite](../../demo/tests/hego_parameter_fixtures_test.gd) checks live descriptors, ramp samples and source output. The [scene suite](../../demo/tests/hego_parameter_scene_test.gd) exercises panel edits, structural changes, named presets and scene restoration on a fresh session. Use the [fixture guide](../../demo/tests/fixtures/parameters/README.md) to reproduce the HDAs or inspect them in the editor.
