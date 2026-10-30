# HEGo island erosion HDA

`Sop/HEGo_IslandErosion` (contract version 2) turns cumulative terrain into eroded height, simulation/biome masks and 32 stable material-weight fields: 41 output volumes in total. It wraps Houdini 22.0's native `Sop/heightfield_erode::3.0` and an optional native HeightField Slump pass over this simulation's loose thermal debris. The later manual-height transition is a separate authoring operation; its correction is excluded from the simulation evidence used to update materials.

The new saved definitions have been validated on actual island inputs at draft scope: the whole island at 16 m and a 512 m building crop at 2 m height/4 m masks. No new full 4 km island cook at 2 m, saved-level adoption or production appearance/performance result is claimed here. Existing edited scenes, hand resources, material tuning and cache generations remain authoritative until an explicit migration/cook is accepted.

| Item | Path |
| --- | --- |
| HDA | `otls/HEGo_IslandErosion.hda` |
| Machine-readable contract | `demo/island/hda/contract.json` (also embedded in the HDA as section `hego_contract.json`) |
| Creation source | `scripts/houdini/build_island_hda.py` (also embedded as section `hego_build_island_hda.py`) |
| Manual-transition regression | `scripts/houdini/test_island_transition.py` |
| Stage/slump regression | `scripts/houdini/test_island_stage_materials.py` |
| Inheritance fixtures | `scripts/houdini/test_material_inheritance.py` |
| Shared material model/math | `scripts/houdini/material_habitat.py`, `material_stage.py`, `material_weight_limit.py` |
| Graph layout helper | `scripts/houdini/graph_layout.py` |
| Rough base generator | `scripts/houdini/island_base.py` (numpy only) |
| Rough base cache | `demo/island/cache/base_height.rf32` + `base_height.json` |

The consolidation into `demo/` changes builder filesystem defaults only. Saved HDA graphs and embedded builder provenance remain unchanged; source-metadata validation accepts the old directory spelling for this move and still rejects algorithm changes.

The HDA is an ordinary editable subnet asset. `build_island_hda.py` is the reproducible source; rebuilding replaces the saved definition file, without recooking or adopting a user scene. After authoring unlocked contents, save the intended definition and finish with matching instances. Network edits follow the root Houdini conventions (`AGENTS.md`, Houdini network conventions): dependency order, fitted stage boxes, local relative `OUT_`/`IN_` handoffs, semantic comments and independent HDA interfaces. The [layout helper](../scripts/houdini/graph_layout.py) supports these edits; numerical cook tests do not substitute for visual graph review.

## Build and cook

Use hython from Houdini 22.0. All logs, metrics, previews and exported outputs go to `/tmp/hego-terrain-prototype/island` (override with `--out-dir`).

```sh
# Author the HDA and export the rough base (no erosion cook, a few seconds)
/opt/hfs22.0/bin/hython scripts/houdini/build_island_hda.py

# Independent cooks: a fresh session installs only the saved .hda file
/opt/hfs22.0/bin/hython scripts/houdini/build_island_hda.py --cook smoke   # small grids + checks
/opt/hfs22.0/bin/hython scripts/houdini/build_island_hda.py --cook coarse  # 513² @ 8 m
/opt/hfs22.0/bin/hython scripts/houdini/build_island_hda.py --cook full    # coarse, then 2049² @ 2 m detail
```

`--build` combined with `--cook` rebuilds first. `--skip-base` leaves the base cache untouched. The base cache is persistent and is never removed by the script.

The smoke mode cooks a 129² grid at 32 m, then a detail pass that resamples it to 257² at 16 m. It also covers hydro-only, thermal-only and zero-strength ablations, an input in column +X/row +Z layout, a raw constraint input, the frozen result at another frame, and an empty target path. Any failed check raises an error.

## OpenCL

`heightfield_erode` runs on OpenCL. On this machine, the AMD GPU has no OpenCL ICD, so Houdini prints `No OpenCL platform has the specified device type ... GPU. Falling back to built-in CPU OpenCL driver` and uses its bundled Intel CPU driver on the Ryzen 7 5800X3D. The cook script logs `hgpuinfo -c` to the metrics. Erosion is never skipped: if the erode node fails, the HDA reports an error and produces no output.

## Interface

Inputs:

0. **Cumulative terrain** (required): a scalar `height` volume on any dense, orthogonal, horizontal lattice. Both HEGo layouts work: column +X/row +Z, and Houdini's own column +Z/row +X. An optional complete set of the 32 registry `material_*` fields supplies prior assignment. Each material can use its own valid horizontal lattice and is sampled by name/physical position at this stage's mask centres; optional matching ownership/coverage companions control where it contributes. Partial 32-channel sets or malformed fields are errors, and all-zero/uncovered samples initialize locally. A `height__ownership` companion is read-only and does not limit erosion. Previous-stage simulation masks are accepted for transport compatibility but are not reapplied as this pass's material evidence.
1. **Raw manual constraints and target height** (optional, raw snapshot of a *later* manual layer such as BuildingFlatten with `terrain_channels "constraint,height"`):
   - `<constraint_channel>` (default `constraint`) plus an optional binary `<constraint_channel>__ownership`. The protection weight is `w = clamp(value,0,1) * (ownership >= 0.5)`, sampled bilinearly and set to 0 outside the raw bounds. `w` cancels erodability, and the eroded height is `E = lerp(eroded, pre_erosion, w)`.
   - `<manual_height_channel>` (default `height`) plus its **required** `__ownership`: the absolute terrain-local height of that Replace layer, in metres, on its own lattice (any origin, spacing and orthogonal orientation; the compact owned rectangle is fine). See [Manual-height transition](#manual-height-transition).

Parameters: `target_layer_path` (string; HEGo's string parm editor accepts drag-drop, but the value must be the host-relative path declared in the host's `StrataTargets` binding), `detail_stage`, `seed`, `freeze_frame` (1–400), `feature_size` (effective ≥ 3 × output spacing), `output_spacing`, `mask_spacing`, `erosion_strength` (0–3), `constraint_channel`, `sea_level`, `manual_transition` (toggle, default on), `manual_transition_width` (metres, default 32), `manual_height_channel` (default `height`), plus Advanced `hydro_scale` / `thermal_scale`. An empty `target_layer_path` is a node error.

Outputs (exact order): `height`, `erosion_delta`, `sediment`, `debris`, `flow`, `grass`, `rock`, `sand`, `scree`, then one `material_<name>` field per entry of the [material registry](../demo/island/materials/material_registry.json), in registry order (four in the demo). Every volume carries `hegostrata_layer_path`, `hegostrata_role="value"`, `hegostrata_channel=<name>` and `hegostrata_composition="replace"`. No other primitive attributes, vector volumes, internal layers or input companions are emitted. Diagnostic `hego_island_*` detail attributes record the stage, effective feature size, freeze frame and grids. They are not routed.

`height` uses the output lattice. All other channels, including the material fields, use the mask lattice. The four legacy biome weights sum to one; independently, the material weights are finite/nonnegative, sum to one and have at most four positive contributions per sample. Both erosion targets accept all of these outputs and require `height`. The final `MaterialDistribution` target remains a separate mask-only result with one channel per registry material.

## Lattices and alignment

The output lattice starts at the input's minimum-X/minimum-Z sample centre. It uses `N = floor(span / spacing + 1e-3) + 1` samples per axis at exactly `output_spacing`. Before erosion, the HDA deliberately resamples the input with Catmull-Rom on the input sample centres. The result is exact where centres coincide, which the transposed-input smoke check confirms bit for bit. The mask spacing is `max(mask_spacing, output_spacing)`, snapped to an integer stride. Masks are tent-filtered from the height-resolution fields onto centres that coincide with every stride-th height sample. Output volumes follow Houdini's built-in heightfield layout: index 0 steps +Z and index 1 steps +X. HEGo reports `sample_origin` and both step vectors, so consumers should read the lattice from those values.

| Stage (caller preset) | Input | Height grid | Mask grid |
| --- | --- | --- | --- |
| coarse: `detail_stage=0, output_spacing=8, mask_spacing=8, feature_size=24, freeze_frame=24` | base 513² @ 8 m | 513² @ 8 m, origin (-2048, 0, -2048) | 513² @ 8 m |
| detail: `detail_stage=1, output_spacing=2, mask_spacing=4, feature_size=6, freeze_frame=16` | cumulative height through ManualFine, 2049² @ 2 m in HEGo; prior materials sampled separately at 4 m | 2049² @ 2 m, origin (-2048, 0, -2048) | 1025² @ 4 m |

Every 8 m sample coincides with a 4 m and a 2 m sample. The 4097² @ 1 m runtime compile is a consumer-side resample; this HDA authors no 1 m detail.

## Erosion setup

`heightfield_erode::3.0` runs with `dofreeze=1`, `startframe=1`, one iteration per frame and `cacheenabled=0`. Sediment and debris are added to the final height. Input 1 of the erode node carries three masks: erodability `(1-w)·lerp(0.03, 1, smooth(sea-2, sea+10, h))`, `depositmask` `lerp(0.02, 1, smooth(sea-1.5, sea+3, h))` and `removalmask` (the inverse; removal rate 0.5). As a result, the sea floor and the beach band barely erode, and sediment that reaches the sea is removed instead of filling the coves. The first coarse test, run without these masks, grew a deposition ring up to 300 m wide around the coast and erased the coves.

The hydraulic/thermal presets (`s = erosion_strength`) are:

| | flow | erosion | deposition | weathering | cut / repose |
| --- | --- | --- | --- | --- | --- |
| coarse | 0.7·s·hydro | 0.2·s·hydro | 0.5 | 0.3·s·thermal | 35° / 22° |
| detail | 0.5·s·hydro | 0.12·s·hydro | 0.6 | 0.45·s·thermal | 38° / 28° |

## Slump and stage Materials controls

The **Slump** folder exposes native debris redistribution:

| Parameter | Default | Meaning |
| --- | --- | --- |
| `slump_enable` / Slump Thermal Debris | On | Run native HeightField Slump in smooth mode on this pass's thermal `debris`. Off selects the original erode result. |
| `slump_repose_angle` | 32° | Rest angle for loose debris. |
| `slump_iterations` | 30 | Spread iterations; more iterations permit longer travel. |
| `slump_spread_rate` | 0.5 | Spread rate per iteration. |

On the enabled branch, erode leaves debris separate and Slump adds the redistributed debris to bedrock exactly once. Protection is applied afterward. The published `debris` is the rested debris layer; no extra slump channel is emitted. With Slump off, saved-definition tests reproduced the original nine coarse/detail channels byte for byte, including detail protection and manual transition. This compatibility check does not describe a default-on full-island adoption.

The **Materials** folder exposes `beach_height`, `shore_width`, `cliff_slope`, `tree_line`, `snow_line`, `sun_azimuth`, `variation_scale`, `sharpness` and `material_seed` (32). The main `sea_level` control is shared by the simulation masks and material model. `material_evidence_depth` defaults to 0.5 m; evidence below 10% of it leaves the gate exactly zero. `material_flow_evidence` defaults to 1 and controls concentrated-flow evidence, with 0 limiting evidence to simulated height change, sediment and debris.

The stage compares a base habitat model on resampled pre-simulation height with an evolved model on the protected post-simulation height and this pass's actual sediment, rested debris and flow. It transfers their difference into the prior mixture only through this pass's evidence gate, reduced by protection. Unassigned samples initialize from the base. Valid normalized prior mixtures with at most four positive weights remain byte-exact where the gate is zero. Resampling can combine neighbouring palettes into more than four contributions; the shared soft limiter then changes that representation, with explicit redistribution/tie diagnostics. Refined/generated weights also use the shared limiter.

Two different deltas must not be confused: the exported legacy `erosion_delta` remains **final height minus pre-simulation height**, so it includes manual-transition corrections. Stage material evidence instead uses the protected **post-simulation, pre-transition** delta. A manual pad correction alone therefore does not count as erosion/deposition or reassign materials. Previous-stage sediment/debris/flow/delta are not applied again.

## Manual-height transition

A later manual Replace layer (the BuildingFlatten house platform) overrides the eroded surface inside its ownership. Constraint protection alone keeps the *pre-erosion* height there, which knows nothing about the manual heights. So wherever the platform's falloff edge met terrain that a later recook had moved, the old output left a step (the saved Bracken Isle pad averaged 2.5 m with a 7.1 m maximum). With an owned raw target height on input 1, the HDA now blends its own output toward that layer explicitly. The manual values and ownership are only read, never changed.

The transition runs after erosion, optional Slump and constraint protection, before final height/mask publication. The stage material branch reads the protected pre-transition simulation result separately, so the manual correction cannot become simulation evidence. The `contract.json` key `inputs[1].manual_transition` is the normative specification. In summary:

1. **Sampling.** At each output sample centre, the four surrounding raw samples are weighted bilinearly and multiplied by binary ownership (≥ 0.5). This gives coverage `c = Σw·o` and target `t = Σw·o·value / c`, which is the HEGo runtime compositor's rule. Raw samples outside the field are unowned. An owned 0 m counts, and unowned background values never count. Samples with `c ≥ 0.5` are **anchors**; interior anchors take `t` exactly.
2. **Edge fit.** Nodes of output cells that straddle the anchor boundary only affect interpolation across the ownership edge. Each one takes the manual surface's local plane at its nearest owned raw edge sample: that sample's value plus a least-squares gradient over owned raw samples within max(0.75 m, 2 raw steps). Exact ties resolve by world position, so raw orientation does not matter.
3. **Band.** `d` is the exact Euclidean distance on the output lattice to the nearest anchor; the width is measured from the output anchors, not from the exact 0.25 m boundary. For `d < manual_transition_width`, the output is `E + w(d)·X`. Here `X` is the harmonic extension (red-black SOR to a 0.1 mm residual) of the discrepancy `fixed value − E`, and `w = 1 − smoothstep(cell diagonal, W, d)`. The weight has zero derivative at both ends. The surface is still sampled at 2 m and resampled again at runtime, so this is **not** an exact C1 guarantee; the seams are measured below.
4. **Support.** Every sample with `d ≥ W` is bit-identical to `E`. When the transition is disabled, input 1 is absent, the channel or its ownership is missing, or nothing is owned, the transition contributes no height change (status in `hego_island_transition_status`).

The stage raises an explicit node error for a target whose `hegostrata_snapshot_mode` is not `raw` (a cumulative stack would feed the layer's own result back), or whose `hegostrata_composition` is not `replace` (Add values are offsets, not heights). It also errors for an ownership role other than `ownership`. A target without `__ownership` is ignored with a warning on the internal `manual_transition` node. Manual features that cover no 2 m output centre, such as a lone 0.25 m sample, do not anchor. `erosion_delta` and the legacy biome masks describe the final height; material refinement uses the earlier simulation-only delta. Historical transition-only timings were 0.03 s for the Bracken Isle pad and 0.37 s for 40 footprints on the 2049² detail grid; these are not current full stage/slump/material cook timings.

Caller presets: coarse `manual_transition=0`; detail `manual_transition=1, manual_transition_width=32, manual_height_channel=height`.

### Historical measurements on the saved Bracken Isle pad

The saved `DetailErosion` height (a crop of ±256 m around the pad) was cooked through the HDA with `erosion_strength=0`, which reproduces it exactly, together with the exported BuildingFlatten `height` and `constraint` fields. That applies the transition alone to the actual erosion. The runtime composition is emulated as the 2 m HDA output interpolated bilinearly, with the 0.25 m BuildingFlatten Replace on top. The emulation reproduces the saved-state numbers that the integration owner measured in Godot. Each step is the height difference across an ownership-crossing neighbour edge:

| Lattice | Saved (constraint only) | Transition, W = 32 m | Manual layer's own step next to its edge |
| --- | --- | --- | --- |
| 0.25 m, 956 edges | mean 2.498, p95 6.107, max 7.114 m | mean 0.123, p95 0.204, max 0.257 m | mean 0.115, p95 0.227, max 0.275 m |
| 1 m, 236 edges | mean 2.521, p95 6.232, max 7.721 m | mean 0.518, p95 0.865, max 1.080 m | mean 0.581, p95 1.261, max 1.640 m |

The remaining step is no larger than the platform's own slope at its edge. The changed area is the 30 m footprint plus the band (up to 61 m from the pad centre). The largest change is 12.7 m, which is the old-versus-new discrepancy at the edge. Genuine detail erosion of the exported ManualFine crop gives the same seam numbers, because the fitted edge ring does not depend on erosion. The band absorbs that discrepancy: slope p95 within the band is 39.9° for W = 32 m and 37.7° for W = 48 m, against 37.2° saved. Use a wider band for a gentler apron.

### Historical transition regression

The entrypoints below belong to the transition-only verification record. The current combined Slump/material definition is covered by the separately reported stage suite; the historical old-definition comparison is not a claim that default-on Slump leaves height unchanged.

```sh
hython scripts/houdini/test_island_transition.py --hda OLD.hda --baseline-out /tmp/old.npz   # optional reference from the previous HDA
hython scripts/houdini/test_island_transition.py [--baseline /tmp/old.npz]                    # focused transition regression
hython scripts/houdini/test_island_transition.py --perf                                       # 2049² timing
hython scripts/houdini/test_island_transition.py --actual DIR                                 # exported actual fields
```

That transition suite used 257² @ 2 m fixtures around the pad, with each case installing only the saved definition. Its recorded coverage includes:

- Interface metadata against `contract.json`.
- Bit identity when the transition is disabled, input 1 is absent, input 1 has a constraint only, the height has no ownership, the height is a compact empty 1×1 field, or the channel name differs.
- Errors for Add and cumulative targets.
- Anchor counts and values against an independent numpy sampler.
- An owned zero pad that pulls a 70 m-high area to 0 m.
- Sparse samples on and off output centres.
- Raw +X/+Z, Houdini and flipped bases with a nonzero Y origin (≤ 1e-5 m; the edge fit sums in float64 in lattice order).
- 0.5 m and offset 3 m raw lattices.
- Bounded support at 32 m and 16 m, and that changing parameters recooks the stage.
- Genuine erosion: the original transition-disabled path bit-identical to its previous definition, with no transition change beyond the band.
- Per-footprint seams in the emulated runtime composition.

## Rough base

`island_base.generate()` is analytic and seeded (seed 20261028). The island has these parts:

- A domain-warped central massif with an off-centre main ridge spine reaching about 480 m.
- A western sub-massif and a southern spur.
- A separate south-east ridge peninsula, joined to the main mass by a narrow, low neck.
- A south-west headland.
- Six warped-ellipse coves.
- Ridged-multifractal ruggedness that increases with altitude.
- Gentle beach ramps and soft marine terraces in lowland zones. Rockier coasts are steeper but never vertical, because the waterline uses a ±24 m blended transition.
- A shelf that falls to a sea floor near -200 m.

The cache is little-endian float32, row-major, with rows stepping +Z and columns stepping +X. `base_height.json` records the 513² lattice at 8 m, its origin of (-2048, 0, -2048), the step vectors and statistics. This rough base is uneroded and is meant to be edited as the initial manual layer.

## Historical erosion verification record

The following numbers describe the original nine-channel definition before native Slump and per-stage material output. They are retained for comparison and do not measure the current 41-channel default. Verified on 2026-10-29 with Houdini 22.0.429 (Commercial licence, hython) on the CPU OpenCL fallback. Every cook ran in a fresh process that installed only the saved `.hda`. Raw numbers are in `/tmp/hego-terrain-prototype/island/metrics-{smoke,full}.json`, and logs are in `cook-*.log`.

| Pass | Height grid | Mask grid | Cook time | Peak RSS | Height − pre-erosion (m) | Eroded / deposited (>0.05 m) | Sediment / debris max (m) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| coarse, 24 frames, feature 24 m | 513², origin (-2048,0,-2048), 8 m | 513² @ 8 m | 15.4 s | 1.2 GiB | min -121.7, max +41.1, mean -5.6 | 82.8 % / 6.1 % | 33.9 / 37.1 |
| detail, 16 frames, feature 6 m, input = coarse 513² | 2049², origin (-2048,0,-2048), 2 m | 1025² @ 4 m | 172.3 s | 2.8 GiB | min -32.4, max +6.0, mean -0.86 (on the 4 m mask grid) | 47.9 % / 1.5 % | 3.7 / 4.7 |

The base peak of 480.7 m becomes 447.2 m after the coarse pass and 444.2 m after the detail pass. The `full` run took 3 min 11 s wall time, with a peak RSS of 3.0 GiB.

Smoke results, all on 129² @ 32 m unless noted:

- Hydro-only: max |Δ| 134.6 m, sediment max 18.9 m, debris 0.
- Thermal-only: max |Δ| 72.3 m, debris max 60.0 m, sediment 0.
- `erosion_strength=0`: Δ is exactly 0.
- Column +X/row +Z input layout vs Houdini layout: max difference 0.0 m.
- Raw constraint: 1024 owned samples moved 0.0 m, while the same region moved up to 97 m without the constraint.
- The frozen result at frame 25 equals frame 1 exactly.
- An empty `target_layer_path` produces a node error.
- The 16 m detail resample produced a 257² grid at the expected origin.
- Every historical output had exactly the original nine channels with the routing attributes, finite values, and biome sums within 1.6e-7 of 1; the current contract adds the registry's material fields.

Previews written by the cook are `base_preview.png`, `coarse_height.png`, `coarse_delta.png`, `coarse_biomes.png`, `detail_height.png`, `detail_height_crop.png`, `detail_delta.png` and `detail_biomes.png`. Raw outputs are written as `outputs/*.rf32`, with a per-stage `*_manifest.json` that records each grid.

## Stage material/slump verification, 2026-10-30

The final saved definitions passed 72 stage/slump checks, 26 dedicated inheritance checks, 125 final material-distribution checks and 35 tint checks. The actual-input stage run used whole-island 16 m draft erosion and a 512 m crop around BuildingFlatten at the real 2 m height/4 m mask spacing. It verified simulation-dependent placement, zero-strength inheritance, protection/manual-transition separation and byte-identical original nine-channel outputs with Slump disabled for both coarse and detail. Dedicated artificial fixtures separately exercised ownership gaps, mixed lattices, invalid priors and contribution crossings; they are not showcase assets.

Sources are [the stage regression](../scripts/houdini/test_island_stage_materials.py), [inheritance fixtures](../scripts/houdini/test_material_inheritance.py), [final material regression](../scripts/houdini/test_material_distribution.py) and [tint regression](../scripts/houdini/test_terrain_tint.py). The stage script accepts exported actual coarse/detail/constraint `.bgeo.sc` inputs plus an optional original-definition `--baseline-hda`; without actual detail input it skips those crop checks, so a reduced run must not be described as the full 72-check result.

These are saved-definition numerical/contract results. They do not establish a new full 4 km/2 m HEGo cook, authoring-cache adoption, production appearance or performance. The historical full-island timings above retain their original scope.

## Limitations

- Current stage/slump numerical validation used private saved-definition Houdini cooks. Publishing a newly cooked full terrain through HEGo and adopting it into the edited authoring scene are separate explicit steps.
- Erosion ran on the CPU OpenCL fallback. A GPU OpenCL device may produce slightly different floating-point results, and its memory use was not measured.
- `heightfield_erode` resamples internally to the feature size. Detail below about 3 × spacing (6 m at 2 m spacing) is not simulated.
- The detail pass treats its whole input as erodable apart from raw constraints. It does not know which parts of the cumulative input came from manual layers. Only a later layer sent as a raw target height is blended toward.
- The transition works at the output spacing (2 m for detail). Detail of the manual layer finer than that is represented only through the edge fit. Seams are small but not zero, and exact C1 continuity is not claimed. Revealing the ground under a manual layer (erasing its ownership) shows the HDA's copy of the manual surface plus the band, not the pre-erosion terrain.
- The showcase sends the cumulative stack through ManualFine at 2 m (2049²), preserving those finer edits before detail erosion. The native bulk bridge supports 20 Mi samples per image. Snapshot transport defaults to 64 Mi aggregate samples and allows an explicit bounded 128 Mi opt-in: 2 m height plus 36 simulation/material inputs at 4 m and all coverage companions require 84,041,802 samples. Per-channel spacing preserves the finer height grid. The hython-only full-cook measurement above used the coarse 8 m input and therefore measures the HDA itself, not the complete HEGo five-stage workflow.
- The four legacy biome diagnostic masks retain fixed thresholds apart from `sea_level`. The independent 32-source assignment has the Materials controls described above; it remains a heuristic habitat model driven by simulation fields, not a sediment/material transport solver.

## Final material publication stage

The erosion asset retains its original sand/grass/rock/scree diagnostics and now authors 32 stable material fields itself. The separate mask-only `MaterialDistribution` HDA receives final cumulative height, available simulation masks and those prior weights at 4 m. Its **Prior Stage Materials** menu (`prior_materials`) defaults to **Keep Stage Materials (fill gaps)** (`inherit`): valid stage mixtures pass through exactly, without applying the same erosion evidence or the soft limiter again. Only unassigned samples run the final-height habitat model. **Regenerate From Final Height** (`regenerate`) deliberately ignores prior assignment and classifies every sample; final habitat controls affect only gaps in inherit mode, or the whole map in regenerate mode.

A later height-only edit retains the last erosion stage's assignment until that stage sees the edit in an explicit recook, or final regeneration is chosen. Historical erosion caches without material fields enter the explicitly reported standalone generation path using final height and whichever simulation masks exist. They are not evidence that the earlier erosion stages authored materials.

See [the material workflow](island-material-distribution.md) for registry IDs, explicit binding migration and cook order, independent ownership, mixed-stage binary persistence, packing diagnostics and saved-cache compatibility. Material texture/roughness/height-blend tuning still needs no procedural cook. No Godot habitat classifier or fixture fallback is added.
