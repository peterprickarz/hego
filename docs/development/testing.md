# Testing and maintenance

How to run the repository's test suites, rebuild the island HDAs and regenerate the island's
data. User-facing documentation is under [Strata terrain](../strata/index.md).

## The test runner

`scripts/run_tests.sh` runs every suite from one place:

```sh
scripts/run_tests.sh                 # Python suite + headless Godot tests + addon split + runtime suites
scripts/run_tests.sh --houdini       # also the tests that need a Houdini Engine licence (hython + HAPI)
scripts/run_tests.sh --gpu           # also the Forward+ tests, which need a real display
scripts/run_tests.sh --only python   # one group: python, godot, split, runtime, houdini, gpu
scripts/run_tests.sh --skip-import   # the demo project is already imported
```

`GODOT_BIN` must point at the real Godot 4.7.2 executable (a launcher that opens a terminal
window never returns), and `HFS` at the Houdini installation for the Houdini group
(default `/opt/hfs22.0`). Logs go to `build/test-logs/run.XXXXXX` (a fresh directory per run), or to `TEST_LOG_DIR`;
`TEST_TIMEOUT` (default 600 s) bounds each Godot test.

Godot 4.7 aborts while quitting a headless `--import` of a project whose GDExtensions it
discovers during that same first scan (a fresh checkout, CI, or a staged test project). The
runner and every script that stages a project write `.godot/extension_list.cfg` first, as the
editor itself would after a successful scan, so the first import exits cleanly. A second import
of the same project never shows the problem.

| Group | What runs | Needs |
| --- | --- | --- |
| `python` | `python3 -m unittest discover -s scripts/tests`: addon boundaries, terrain build script, distribution publisher, material preparation, launchers | Python |
| `godot` | the headless Godot tests listed in `GODOT_TESTS`, run against the imported demo project; `island_storage_test` and `terrain_demo_scene_test` only when the island data is present rather than Git LFS pointers | Godot |
| `split` | `demo/tests/addon_split_runner.py`: HEGo alone, and all addons together, in disposable projects | Godot |
| `runtime` | `demo/tests/runtime_test_runner.py`: the runtime suites below | Godot |
| `houdini` (opt-in) | real HAPI sessions (`HOUDINI_GODOT_TESTS`) and the hython HDA regressions (`HYTHON_TESTS`, material inheritance, weight limiter) | Houdini 22.0 and a licence |
| `gpu` (opt-in) | the Forward+ renderer and showcase tests (`GPU_TESTS`) | a real display and GPU |

The Houdini group unsets `HOUDINI_OTLSCAN_PATH` and `HOUDINI_PACKAGE_DIR` so the editor test
discovers the island HDAs through `otls/` at Houdini startup, as a user's session would.

### Where tests stage projects

Scripts that copy the demo project or its addons into a disposable project stage it under
`build/test-staging/<name>` in the repository (`build/` is git-ignored; the scripts create it),
never in `/tmp`, which is tmpfs on this machine and would keep the imported fixtures in RAM.
Logs of `scripts/run_tests.sh` go to `build/test-logs`. The staging runners clean up after a
successful run and keep the project of a failed one for inspection; `--keep` keeps them in any
case, and `--work` moves the directory (not onto tmpfs; `/tmp`, `/dev/shm` and `/run` are
refused).

| Script | Staging directory |
| --- | --- |
| `demo/tests/runtime_test_runner.py` | `build/test-staging/runtime` (`authoring/` and `runtime_only/`) |
| `demo/tests/addon_split_runner.py` | `build/test-staging/addon-split/<project>` |
| `scripts/run_terrain_prototype.py --test`, `scripts/run_terrain_houdini_integration.py`, `scripts/smoke_test.py` | `build/test-staging/<tempdir>` |

Some tests still write their output images or JSON to `/tmp` (the shading and height-blend
fixtures, the island GPU capture); those are small outputs, not staged projects.

### Editor smoke test

`demo/tests/terrain_editor_smoke.gd` is an `EditorPlugin`, not a `--script` test, and nothing in
`run_tests.sh` runs it: it needs a display, Forward+ and the saved island (not Git LFS pointers).
It opens the island scene in a real editor, checks the textured region preview (live regions,
LOD following the editor camera, the brush on a hand layer with undo and redo, a hole stroke read
back from the renderer's hole regions, a tint stroke read back from the bridge's macro regions, the
cutoff, quality and material changes, save and reopen). To run it, stage a copy of the demo under
`build/test-staging/editor-smoke`, put the script in `addons/terrain_editor_smoke/` as a plugin
(a `plugin.cfg` naming it, enabled under `[editor_plugins]` in `project.godot`), set the island scene as
the main scene and start `$GODOT_BIN --editor --path build/test-staging/editor-smoke`. It exits
the editor with code 0 and prints `TERRAIN_EDITOR_SMOKE failures=0` when it passes; failed checks
print `EDITOR_CHECK:` errors. Screenshots are written to the project's `user://` directory.
It is run by hand.

### Runtime suites

`demo/tests/runtime_test_runner.py` copies the Strata addon into a disposable project under `build/test-staging/runtime` (never
into `demo/addons/`), imports it and runs:

| Suite | Coverage |
| --- | --- |
| `runtime_data_test.gd` | the format 2 manifest: lattice, statuses, holes, thresholds, channels, region windows, external regions, validation, a 4 km grid of 256 regions with a navigation profile |
| `region_compose_test.gd` | a region equals the matching window of a whole-terrain composition bit for bit (height, materials, masks, macro, channels), mips, per-region navigation masks, embedded vs external regions |
| `runtime_collision_test.gd` | real raycasts: signed heights, chunk edges and interiors, a yaw seam sweep, holes over a floor, 2 m spacing, camera independence, bounded residency, tracking, atomic replacement, teardown |
| `runtime_navigation_test.gd` | real `NavigationServer3D` paths around a hole and an exclusion and across tiles, slope/climb settings, async publication, supersession, teardown |
| `runtime_bake_test.gd` | a five-layer stack with real procedural transactions, baked into 16-cell regions: stale rejection, preview cutoff, failure retention, stale tracking, budgets, export, save/reload, storage directory with region files |
| `runtime_roundtrip_test.gd` | a second project with only the runtime scripts (regions, region data, runtime data, profiles, collision, navigation, settings): loads the export, checks hashes and queries, collides, navigates, resaves |
| `runtime_large_bake_test.gd` (`--large`) | a 4097² 1 m bake with bounded collision and navigation |

```sh
python3 demo/tests/runtime_test_runner.py --godot "$GODOT_BIN" [--large]
```

Script errors stop only the owned test process group; every suite also has an internal
watchdog. Isolated test maps use the 0.01 navigation merge scale explicitly.

### Other entry points

- The Houdini bridge end-to-end check, `scripts/run_terrain_houdini_integration.py`, is
  described in [Strata and Houdini integration tests](strata_integration_tests.md).
- The prototype suites run with `scripts/run_terrain_prototype.py --test` (headless) and
  `--test-renderer` (Forward+); see [Prototype scenes](terrain_prototype.md).
- The publisher checks run with `python3 scripts/tests/test_distribution.py`; see
  [Packaging](packaging.md).

## Island HDAs

The island HDAs live in `otls/` and are generated from builders in `scripts/houdini/`, which
also embed each HDA's contract (`demo/island/hda/*.json`). Rebuild them with Houdini 22.0's
hython after changing a builder or the material registry, then rerun the Houdini group:

```sh
hython scripts/houdini/build_material_weight_limit_hda.py
hython scripts/houdini/build_material_distribution_hda.py
hython scripts/houdini/build_tint_hda.py
hython scripts/houdini/build_island_hda.py --skip-base
HOUDINI_PATH="$PWD:&" hython scripts/houdini/test_hda_package_graphs.py
```

`build_island_hda.py` without `--skip-base` also regenerates the rough base cache;
`--cook smoke|coarse|full` cooks the saved definition in a fresh session. Rebuilding replaces
the saved definition only; it never recooks or adopts the island scene. Details are in
[Island erosion HDA](island_hda.md), [Island material distribution](island_material_distribution.md)
and [Terrain-wide tint and AO](terrain_macro.md). Network edits follow the Houdini
conventions in the repository's `AGENTS.md`.

## Island data

The island's terrain lives at fixed paths under `demo/island/terrain/` (its
`storage_directory`), tracked with Git LFS:

| Path | Holds | In git |
| --- | --- | --- |
| `rough_base.res`, `manual_fine.res`, `building_flatten.res` | hand layers | yes |
| `coarse_erosion/<channel>.res`, `detail_erosion/<channel>.res` | the erosion stages' channels | yes |
| `terrain_tint/<channel>.res` | the tint and AO channels | yes |
| `material_distribution/material_<name>.res` | the material weight fields | yes |
| `regions/region_<i>_<j>.res` | the bake's regions | no, rebaked with the manifest |
| `runtime_data.res` | the bake | no, rebaked by the showcase when missing or stale |

The rough base the first cook starts from is `demo/island/cache/base_height.rf32` with its
`.json` description. `demo/island/materials/material_registry.json` lists the four materials
with stable IDs 0–3, and `demo/island/assets/ambientcg_sources.json` records their sources.

`scripts/run_terrain_island.py` drives the saved island headlessly:

```sh
python3 scripts/run_terrain_island.py --prepare           # rough base -> coarse -> detail -> tint -> materials, then save
python3 scripts/run_terrain_island.py --cook-materials    # only the material distribution, against the saved layers
python3 scripts/run_terrain_island.py --five-stage-check  # artificial fixture; saves nothing
python3 scripts/run_terrain_island.py --verify            # reopen the saved island without Houdini
python3 scripts/run_terrain_island.py --stage-only        # validate the installed demo addons
```

`--prepare` recooks every stage from the saved hand layers with each HDA's saved parameters
and overwrites the stage files; the hand layers are never changed. `--five-stage-check` is an
**artificial fixture**: it paints scripted strokes into the hand layers in memory, recooks the
coarse stage with other parameters, and checks that both hand layers survive byte for byte
while the detail stage goes stale. `--godot PATH` overrides the executable; the launcher never
rebuilds native code.

Captures and the render benchmark use the showcase scene:

```sh
python3 scripts/run_terrain_island.py --capture /tmp/island-overview.png --quit-after-frames 90
python3 scripts/run_terrain_island.py --capture-view platform --show-ownership --capture /tmp/island-ownership.png --quit-after-frames 90
python3 scripts/benchmark_terrain_island.py --godot "$GODOT_BIN" --report /tmp/island-benchmark.json --capture-dir /tmp/island-captures
```

See [Island render benchmark](island_benchmark.md) for recorded results. To refetch or
repack the material textures (existing `.tres` tuning is preserved unless
`--reset-resources` is given):

```sh
python3 scripts/prepare_island_materials.py --output-dir demo/island/materials
```

## Documentation

The site builds from `docs/` with Sphinx and MyST:

```sh
scripts/generate_gdscript_docs.sh   # after changing a GDScript class's ## comments
scripts/generate_docs.sh            # rewrites docs/classes from the class reference XML
python -m sphinx -W -b html docs docs/_build/html
```
