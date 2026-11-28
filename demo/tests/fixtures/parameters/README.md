# HDA parameter test scene

Open `res://tests/fixtures/parameters/parameter_types.tscn` in the demo project. Select **ValuesFixture** in the Scene tree and click **Recook** in the HEGo bottom panel. Do the same for **StructureFixture**. Each host loads its own fixture library into the active Houdini session. **Auto Start Session** can start the local session on the first cook.

These are artificial test HDAs. Both produce zero points and primitives. The Structure fixture samples its ramps and reads a marker from the selected SOP into detail attributes so the automated tests can check the result of a cook.

On **ValuesFixture**, hover over **Enable conditional controls** to read the first paragraph from the asset's help page. Open **Help** to read its second paragraph. **Conditional amount** demonstrates a help entry matched by label, and **Source marker** uses its own parameter Help field. On **StructureFixture**, every **Value** in **List instances** gets the same hint from its multiparm template.

| Fixture | What to try |
| --- | --- |
| **ValuesFixture** | Switch **Enable conditional controls** with auto-recook off. Watch the conditional fields and the choices in the dynamic menu. Click **Increment action count** once. Explore the menu modes, HDR colors, two strings, nine floats, six integers and file paths. The path examples demonstrate raw Houdini expressions. |
| **StructureFixture** | On first inspection, **Pattern** is selected and **Opaque data** is expanded. These defaults are authored in the HDA. Select **Surface**, collapse **Opaque data**, then choose the **Local** or **Linked** radio page. Add rows to the nested and zero-based lists. Compare the scrolling and tabbed multiparms. Change ramp key position, value and interpolation. Choose **ValuesFixture** for **Source SOP**. Save a preset and reload it after changing values. |

The sample paths are parameter text for editing. The fixture cook does not read or write those files. For a remote Houdini session, place the HDA files on a shared path accessible to Godot and the server under the same absolute filename. Enter that filename in each node's **Fixture Library**.

From the repository root, run the following with Houdini 22's `hython` to regenerate the two saved definitions. The builder first verifies fresh instances, independent controls, empty cooks and a saved HIP round-trip in a temporary directory. Use `--verify-only` to check the committed HDAs.

```sh
hython demo/tests/fixtures/parameters/build_fixtures.py
hython demo/tests/fixtures/parameters/build_fixtures.py --verify-only
```
