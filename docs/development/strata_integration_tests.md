# Strata and Houdini integration tests

The user-facing bridge workflow is in [Strata and Houdini](../strata/houdini.md). This page
describes the opt-in end-to-end check that drives real Houdini cooks through the bridge, and
the fixtures behind it.

## Addon boundaries

The bridge (`addons/hego_strata`) is the only code that names classes from both HEGo and
Strata. HEGo finds its `HEGoStrataInput` and `HEGoStrataOutput` through the generic
`HEGoInputHandler` and `HEGoOutputHandler` extension points, without naming them; the HEGo
Terrain3D bridge has the same shape. `scripts/tests/test_addon_boundaries.py` fails if any
addon names a class from one it does not depend on, and `demo/tests/addon_split_runner.py`
runs HEGo alone and all addons together in disposable projects.

## Integration check

This is an opt-in Linux check for the terrain field bridge. It requires Godot 4.7.2, Houdini 22.0 with a working Engine license, the initialized `godot-cpp` submodule, and a built Linux debug library for each extension. It starts its own Houdini named-pipe session and uses only generated project data and built-in Houdini SOPs.

## Build and run

Build HEGo into an ignored integration-only path so the test never replaces the tracked demo library. Build the terrain extension separately:

```sh
HFS=/opt/hfs22.0 scons platform=linux target=template_debug terrain_integration_output=terrain/integration_bin/libhego.linux.template_debug.x86_64.so -j8
scons -f SConstruct.terrain platform=linux target=template_debug -j8
```

Then run the disposable project harness, which stages all three addons:

```sh
python3 scripts/run_terrain_houdini_integration.py \
  --godot /home/peter/Godot/Godot_v4.7.2-stable_linux.x86_64 \
  --hfs /opt/hfs22.0 \
  --hego-library terrain/integration_bin/libhego.linux.template_debug.x86_64.so
```

The harness also stages a separate project with only the terrain add-on and runs `demo/tests/terrain_cache_standalone_test.gd` and `demo/tests/procedural_transaction_test.gd` before any Houdini session starts. The first saves and reloads native layer data plus a packed scene containing procedural height and mask grids, then checks their sampling, per-channel basis, attrs, composition and producer identity while `HEGoAPI` is absent. The second covers overlapping generations, malformed ownership, atomic multi-target rejection, same-name channels and invalidated read sets. In the integration project, `demo/tests/terrain_transport_lifetime_test.gd` checks pending-task host removal and native failure paths without starting Houdini. These checks establish that the cache can be persisted and sampled independently of HEGo/Houdini and that invalid tasks fail before the live HAPI fixtures run. Use `--keep-project` to inspect the staged project or `--prepare-only` to verify staging without launching Houdini. Each Godot process has a bounded timeout; the tests stop their named-pipe sessions on completion, and a timeout only terminates the process group created by the runner. The `--hfs` path is passed through the process environment and project setting.

The harness refuses to run unless the staged native classes expose `HEGoHeightfieldInputNode.set_fields()` and `HEGoAssetNode.get_heightfield_fields()`. This prevents a successful run against the older tracked HEGo binary from appearing to validate the new bridge.

## Tested fixture

The SceneTree fixture creates a 7×5 RF heightfield with negative world offsets and a mask channel, uploads it through `HEGoHeightfieldInputNode`, cooks a built-in `Sop/volumewrangle`, then fetches all volume fields and commits the complete output through `StrataProcedural`. It checks output dimensions, sample origin/steps, height values, mask preservation, and that the manual base remains unchanged.

It then exercises this ordered terrain stack:

1. A manually owned coarse base.
2. A procedural replacement produced by the first live Houdini cook.
3. A manual fine Add layer, including an explicitly owned sample whose delta is zero.
4. A procedural detail replacement built from the cumulative stack through the manual fine layer.
5. A manual Replace sample used as a building/flatten edit.

The fixture recooks the coarse layer and verifies that its cache is replaced without changing either manual layer. The detail output remains cached until the second cook is explicitly refreshed. It also verifies that a stale read set and a partial two-target result are rejected without partial cache publication, and that raw mask/ownership companion fields and a separate later `constraint` channel survive a second native upload and Houdini fetch.

Finally, a runtime `HEGoNode3D.cook()` drives a built-in primitive `Sop/attribwrangle` from the cumulative manual-fine layer. The wrangle adds target path, channel, role and composition primitive attributes; the bridge's `HEGoStrataInput` and `HEGoStrataOutput` handlers upload, fetch, route and commit the result. A cook with an incompatible extra input row and a cook that deliberately routes to a missing target are then both rejected: the earlier committed cache remains intact, and the target layer is marked stale with the reason in its `procedural_status`.

The two Volume Wrangle snippets add fixed offsets to `height`; they are deterministic bridge fixtures, not erosion, terrain generation, or a production HDA. The test validates native transport, the standalone atomic transaction API, and the runtime `HEGoNode3D.cook()` adapter route. It does not validate the editor panel or reusable production-HDA packaging. See [Packaging](packaging.md) for how the three addons are published.

## Material channel transport

`demo/tests/stage_material_transport_test.gd` uses small artificial scalar fields in a disposable project. It checks transport of simulation fields and all 32 stable material channels through independent hand height edits, common endpoint-aligned resampling, owned zero versus unassigned zero, raw binary ownership, atomic height/material publication, stale material inputs, stage preview IDs and bounded rejection at production dimensions. It never cooks Houdini or inserts fixtures into the normal showcase. The fixture also checks mixed 2 m height/4 m material grids, binary persistence and the explicit input-row migration using the existing native libraries. The final isolated run passed 114 checks.

## Verification record

Last verified on Linux x86_64 with Godot 4.4.1 and Houdini Engine 22.0.429, after the switch to `HEGoStrataOutput`: the runner command above completed with `TERRAIN_TRANSPORT_LIFETIME_TEST: PASS`, `HEGO_HEIGHTFIELD_FIELDS_NATIVE_PASS`, `HEGO_TERRAIN_HOUDINI_ROUNDTRIP_PASS` and `HEGO_TERRAIN_HOUDINI_INTEGRATION_PASS`.

A fresh Godot 4.4.1 import can emit the existing `asset_picker_dialog.tscn` `Busy` warning; the runner repeats the import after the first scan. Test processes also emit ObjectDB leak warnings at exit. These test results do not establish production lifetime or cleanup guarantees.

The tested HEGo integration library SHA-256 was `a144cefdf01d6176303a30aaa83e9142925bb478cad26584ff1cc0dceafef8c6`; the terrain extension SHA-256 was `042e2122eb95863f3c28ac0a7dbe8e490087099ff7f2efe425abe5a7ff8fd671`. The live fixture used built-in Houdini SOPs with fixed height offsets; no erosion HDA or production terrain generator was tested.

No user scene, HDA, GUI Houdini session, or Terrain3D installation is read or modified by the harness.

## History

Strata began as a set of prototype fixtures for layered terrain data and sculpting, which
still live in `demo/scenes/terrain_prototype/` (see [Prototype scenes](terrain_prototype.md)).
It was called HEGo Terrain (`addons/hego_terrain`, `HEGoTerrain*` classes, `hego_terrain_*`
Houdini attributes) until it was renamed; the demo's saved data was converted then, and
Strata no longer loads files saved under the old names. The bridge first published through
a `StrataTargets` child node with a target list; it now routes purely by the
`hegostrata_layer_path` attribute, and the fixture above was rerun after that switch.
