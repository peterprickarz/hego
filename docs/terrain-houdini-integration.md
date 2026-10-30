# Strata and Houdini integration prototype

## Addon layout

Three addons, with dependencies pointing one way:

| Addon | Folder | Depends on |
| --- | --- | --- |
| HEGo | `addons/hego` | nothing |
| Strata | `addons/strata` | nothing (needs neither HEGo nor Houdini) |
| HEGo Strata | `addons/hego_strata` | HEGo and Strata |

The bridge is the only code that names classes from both sides. HEGo picks it up through
two generic extension points it exposes, without naming it: `HEGoInputHandler`, which the
bridge's `HEGoStrataInput` extends so terrain layers can feed HDA inputs, and
`HEGoCookExtension`, which the bridge's `HEGoStrataTargets` node extends to publish a
cook's heightfields into terrain layers. Enabling the bridge plugin checks that both other
addons are installed. `scripts/tests/test_addon_boundaries.py` fails if any addon names a
class from one it does not depend on, and `demo/tests/addon_split_runner.py` runs HEGo
alone and all three together in disposable projects.

## Integration check

This is an opt-in Linux integration check for the terrain field bridge. It requires Godot 4.4.1, Houdini 22.0 with a working Engine license, the initialized `godot-cpp` submodule, and a built Linux debug library for each extension. It starts its own Houdini named-pipe session and uses only generated project data and built-in Houdini SOPs.

## Build and run

Build HEGo into an ignored integration-only path so the test never replaces the tracked demo library. Build the terrain extension separately:

```sh
HFS=/opt/hfs22.0 scons platform=linux target=template_debug terrain_integration_output=terrain/integration_bin/libhego.linux.template_debug.x86_64.so -j8
scons -f SConstruct.terrain platform=linux target=template_debug -j8
```

Then run the disposable project harness, which stages all three addons:

```sh
python3 scripts/run_terrain_houdini_integration.py \
  --godot /home/peter/Godot/Godot_v4.4.1-stable_linux.x86_64 \
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

Finally, a runtime `HEGoNode3D.cook()` drives a built-in primitive `Sop/attribwrangle` from the cumulative manual-fine layer. The wrangle adds target path, channel, role and composition primitive attributes; the bridge's `HEGoStrataInput` handler and `HEGoStrataTargets` binding upload, fetch, route and commit the result. A second cook deliberately routes to a missing target and checks that the earlier committed cache remains intact and the host reports a stale error.

The two Volume Wrangle snippets add fixed offsets to `height`; they are deterministic bridge fixtures, not erosion, terrain generation, or a production HDA. The test validates native transport, the standalone atomic transaction API, and the runtime `HEGoNode3D.cook()` adapter route. It does not validate the editor panel or reusable production-HDA packaging. See [next-packaging.md](next-packaging.md) for how the three addons are published.

## Verification record

Verified 2026-10-28 on Linux x86_64 with Godot 4.4.1 and Houdini Engine 22.0.429. The runner command above completed with these markers: `HEGO_TERRAIN_STANDALONE_CACHE_PASS`, `PROCEDURAL_TRANSACTION_TEST: PASS (0 failures)`, `TERRAIN_TRANSPORT_LIFETIME_TEST: PASS (0 failures)`, `HEGO_HEIGHTFIELD_FIELDS_NATIVE_PASS`, `HEGO_TERRAIN_HOUDINI_ROUNDTRIP_PASS`, and `HEGO_TERRAIN_HOUDINI_INTEGRATION_PASS`. The final captured run is `/tmp/hego-terrain-prototype/final-integration.log`.

A fresh Godot 4.4.1 import can emit the existing `asset_picker_dialog.tscn` `Busy` warning; the runner repeats the import after the first scan. Test processes also emit ObjectDB leak warnings at exit. These test results do not establish production lifetime or cleanup guarantees.

The tested HEGo integration library SHA-256 was `a144cefdf01d6176303a30aaa83e9142925bb478cad26584ff1cc0dceafef8c6`; the terrain extension SHA-256 was `042e2122eb95863f3c28ac0a7dbe8e490087099ff7f2efe425abe5a7ff8fd671`. The live fixture used built-in Houdini SOPs with fixed height offsets; no erosion HDA or production terrain generator was tested.

No user scene, HDA, GUI Houdini session, or Terrain3D installation is read or modified by the harness.

## Using the bridge from a scene

Keep hand-authored work in ordinary child layers with `procedural = false`. Each stores its own sparse `StrataLayerData`; use Add for deltas such as fine sculpting, or Replace for a locally authored surface. Put each generated stage in its own child layer with `procedural = true` and no manual samples. A procedural layer is replaced by a complete cook result, while manual layers remain independent and editable.

Give the `HEGoNode3D` host a `HEGoStrataTargets` child (Add Child Node, or `HEGoStrataTargets.ensure(host)` from a script) and declare every procedural target by path and allowed channels. Paths are relative to the host, the same as its input paths:

```gdscript
var binding := HEGoStrataTargets.ensure(host)
binding.targets = [{
    "path": "../Terrain/ProceduralDetail",
    "channels": PackedStringArray(["height", "mask", "constraint"]),
    "required_channels": PackedStringArray(["height"]),
}]
```

The binding also holds the producer identity recorded on published layers (`producer_id`) and the last cook's `status` and `stale` flag. With targets declared, the host only cooks on request: the HEGo panel's auto recook skips it.

Input rows use the same source paths as the HEGo input panel. Their `settings` select the source view and channels:

```gdscript
input_stash = [{
    "inputs": ["../Terrain/ManualFine"],
    "settings": {
        "terrain_mode": "cumulative", # or "raw"
        "terrain_channels": PackedStringArray(["height", "mask", "constraint"]),
    },
}]
```

`cumulative` supplies the composed terrain through the selected input layer, plus a fractional coverage companion describing where source data contributes. `raw` supplies that layer's native scalar samples and a binary `<channel>__ownership` companion. Coverage is informational for validity and does not become editable ownership. Keep the channel grids at their own native sample spacing and basis; the bridge does not resample channels to make their grids match.

For mixed resolution inputs, `terrain_channel_spacings` maps exact exported channel names to positive finite metre spacings:

```gdscript
"settings": {
    "terrain_mode": "cumulative",
    "terrain_channels": ["height", "sediment", "material_rock"],
    "terrain_channel_spacings": {"sediment": 4.0, "material_rock": 4.0},
}
```

Here height keeps its native selected-layer grid, while sediment and material use endpoint-aligned 4 m grids over the same bounds. An optional `terrain_spacing` remains the default for channels without overrides. Each value and its coverage companion always share a lattice. Unknown channel names, nonpositive/nonfinite spacings and overrides in raw mode reject the snapshot. These overrides persist in Input Stash; the HEGo input panel labels their presence and preserves them when other input settings change. A downstream HDA must explicitly handle the independent input lattices.

The HDA output assigns each volume primitive a target route and role. Value volumes retain their channel name and may set composition to `replace` or `add`:

```c
s@hegostrata_layer_path = "../Terrain/ProceduralDetail";
s@hegostrata_role = "value";
s@hegostrata_channel = "height";
s@hegostrata_composition = "replace";
```

Return one `value` volume for each required channel. Optional channels can be omitted on a later complete result and are removed from that target's prior cache. To deliberately clear every channel in one target, emit exactly one marker volume with `hegostrata_role="empty"`, `hegostrata_empty=1`, and the declared target path; emit no value volumes for that target. Multiple targets can each return a volume named `height`; the target path disambiguates them.

The binding starts a terrain transaction before the host uploads its inputs, checks the HDA bindings and read set again before publication, then commits all routed targets together. An explicit host cook is required to refresh generated data. If the cook fails, changes its bindings, returns an unknown path or channel, omits a required channel, or goes stale while cooking, the last complete cache stays visible and the binding's `status` reports the rejection. A dependency change does not silently run downstream HDAs.

The prototype accepts dense uncompressed RF images with positive rectangular dimensions, finite scalar values, finite sample origins and nonzero orthogonal horizontal sample steps. Sheared, tapered, non-dense, non-scalar and multi-slice volumes are rejected. The generic snapshot helper defaults to a 64 Mi-sample aggregate budget, including value and companion images. An input may explicitly request `terrain_max_samples = 128 * 1024 * 1024`; this is the hard aggregate cap, while each image remains limited to 20 Mi samples. Every channel lattice is checked against the aggregate count before any images are allocated. For example, a full 32-material registry's height, four simulation fields and 32 material fields at 1025² would need 77,746,250 samples including coverage, so such a cook requires that explicit opt-in; the demo's four materials stay far below the default budget. This is a bounded prototype bridge, not a promise of production HDA compatibility or large-terrain throughput.

`demo/tests/stage_material_transport_test.gd` uses small artificial scalar fields in a disposable project. It checks transport of simulation fields and all 32 stable material channels through independent hand height edits, common endpoint-aligned resampling, owned zero versus unassigned zero, raw binary ownership, atomic height/material publication, stale material inputs, stage preview IDs and bounded rejection at production dimensions. It never cooks Houdini or inserts fixtures into the normal showcase. The fixture also checks mixed 2 m height/4 m material grids, binary persistence and explicit binding migration using the existing native libraries. The final isolated run passed 114 checks.

## Terrain-wide tint and cavity AO

Open `demo/project.godot` and the canonical `res://scenes/terrain_island.tscn` scene, select `HDA/TintCook`, and trigger **Cook** in the HEGo inspector. The island example includes a separate `Sop/hego_terrain_tint::1.0` producer. Its input is cumulative final height through the last height-edit layer (`BuildingFlatten`) at 4 m spacing, and its output targets the mask-only procedural `TerrainTint` layer. This avoids sending the 0.25 m manual layer's native grid to the tint HDA. The cook is explicit and does not recook either erosion stage. For a saved-cache migration without opening the authoring UI, use `python3 scripts/run_terrain_island.py --cook-terrain-tint`; it publishes a new cache generation only after preservation checks succeed.

The HDA returns `terrain_tint_r`, `terrain_tint_g`, `terrain_tint_b`, and `terrain_ao` on the height input's lattice. Each is an independently composed scalar field with neutral value 1; RGB is a linear albedo multiplier (packed 0–2), and AO is an ambient/indirect occlusion multiplier (packed 0–1). The bake packs them into an optional terrain-local RGBAH map, with a default 4 m endpoint-aligned spacing. A 4 km square is 1025 × 1025, about 8.4 MB. See [terrain-macro.md](terrain-macro.md) for channel composition, runtime behavior, HDA parameters, and standalone generation/regression commands.

The AO output is a cavity approximation from local mean height, not ray-traced visibility, horizon occlusion, or directional baked lighting. The HDA source is `scripts/houdini/build_tint_hda.py`; its standalone regression is `scripts/houdini/test_terrain_tint.py`. The actual island tint-only cook and saved-cache reopen/export were separately accepted on 2026-10-29; the HDA regression passed 35 checks and the saved-cache compatibility suite passed 88. This result extends the fixed-offset bridge fixtures above; it does not turn them into an erosion-HDA test. See [terrain-macro.md](terrain-macro.md) for the accepted generation and field ranges.
