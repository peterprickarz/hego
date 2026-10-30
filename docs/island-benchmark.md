# Island render benchmark

The historical results below, through the terrain-tint follow-up, used displacement on the ordinary terrain LOD mesh. They did not include the separate near-camera subdivision required for material relief. Keep those results as earlier baselines, not acceptance of the complete displacement feature.

## Additional near-camera subdivision

The 29 October refinement comparison uses the compiled island in an isolated runtime, Godot 4.4.1 Forward+, RX 9070 XT/RADV, an actual 1920 × 1080 viewport, disabled VSync, 60 warmup frames and 300 measured frames per setting. The camera is fixed at (-984, 38.12524, 666), looking toward (-960, 38.43451, 630). All cases retain visual material displacement at global strength 0.2 and radius 32 m. Base High quality stays at 64 cells per patch, 8 m minimum patches, split ratio 3 and a 1,024-patch budget. Only the additional geometry settings change.

| Near geometry | Extra patch budget | Total patches | Total plan triangles | Whole-viewport GPU median / p95 |
| --- | ---: | ---: | ---: | ---: |
| Base LOD only | Disabled | 793 | 6,486,464 | 3.850 / 6.763 ms |
| 0.0625 m spacing | 1,024 | 1,009 | 8,253,504 | 5.064 / 9.010 ms |
| 0.03125 m spacing | 1,024 | 1,753 | 14,343,744 | 8.927 / 9.185 ms |

Both requested spacings were achieved without limiting in this view. A separate 0.03125 m / 2,048-extra-patch case produced the same geometry, so raising its budget had no effect. The default pass added 216 patches; the finer pass added 960. Counts cover the complete selected terrain partition, including patches outside the camera frustum. Captured shaded and wireframe views confirm the added mesh detail. The fixture retains its deliberately authored hole.

Renderer process CPU medians were 0.011 / 0.017 / 0.018 ms respectively. These are stationary-camera costs, **not** LOD-update or traversal costs. GPU p95 was variable; these single-view whole-scene measurements do not establish compliance with the agreed terrain-only performance envelope. Geometry refinement is implemented, while rendering and LOD-update optimization remain open.

The immutable material snapshot used here predates later authoring edits; the report records all 32 material profiles and distance-UV settings. See [the recorded results](benchmarks/island-refinement-2026-10-29.json). Repeat with `demo/tests/island_refinement_runtime_test.gd` in a staged compiled-only runtime project. Local captures are in `/tmp/hego-terrain-refinement/`; the preliminary 3840 × 2080 probe is superseded by this measured run.

The production native library passed 116,883 new refinement invariants and the existing 394,222 mesher checks. Original base-selector partitions retained their reference fingerprint. The settings/controller suite passed 242 checks, and the actual Forward+ renderer pool suite passed with no failures. These cover base-partition preservation, complete coverage, 2:1 balance, indexed mesh seams, whole-circle budget fallback, Inspector settings, save/bake persistence and bounded mesh instances.

## Earlier island benchmark

The benchmark uses the installed addons in `demo/addons` and loads the
diagnostic cached island scene in the main demo project without starting a
Houdini session; it does not alter the editor showcase. It runs the same four
deterministic camera phases with displacement enabled and disabled. Walk,
fast-traversal, and teleport phases keep the camera about 3 m above the sampled
surface. Each phase uses 60 warmup frames by default and at least 300 measured
frames.
Before sampling, it checks that the compiled runtime bake is marked current,
resident at 4097×4097, and that the renderer is drawing that full field. A
visual preview without the compiled cache is rejected.
If the scene has the optional first-person player, the harness disables it and
drives the showcase camera independently so collision residency and input do
not affect the measurement path.

After the cached island scene is ready, run:

```bash
scripts/benchmark_terrain_island.py \
  --godot /path/to/Godot_v4.4.1 \
  --frames 300 --warmup 60 \
  --report /tmp/hego-island/report.json \
  --capture-dir /tmp/hego-island/captures
```

This produces eight timing groups (`displacement_on` and `displacement_off`,
each with overview, walk, fast traversal, and teleport phases) and optional
`overview.png` and `ground-walk.png` captures. The report includes p50/p95/p99
and maximum viewport CPU, viewport GPU, main-loop frame interval, and terrain
renderer process CPU timings, plus adapter/driver/version and memory readings.
Scene import and startup are outside the measured intervals.

The historical measurement below defined 32 material slots using six licensed
source texture sets. The report records distinct bound color, normal and ORMH
resources. Current reruns use the current saved catalog of 32 real source sets;
they are a different asset workload and do not replace those historical results.
For a separate upper-bound residency check, add `--texture-stress`; after normal
measurements it replaces the in-memory pool with 32 slots whose images are
individually duplicated from the current saved sources. This synthetic pass
reports the RenderingServer texture-memory delta, is labelled separately and
never changes the saved showcase. The earlier six-source synthetic pass did not
establish residency of 32 unique downloaded art sets.

Viewport CPU/GPU values measure the full rendered scene, including the
environment, lighting, shadows, material sampling, UI, and terrain. They are
not terrain-only GPU cost. GPU timing is reported unavailable if the driver
does not return positive viewport timings. The results below are one-machine
prototype measurements, not a hardware-independent guarantee or an acceptance
threshold. The first is an uncompressed VRAM baseline; the follow-up uses BC7
and BC5 imports.

## Sample run

Godot 4.4.1 Forward+ rendered at 1920×1080 on an AMD Ryzen 7 5800X3D with
64 GiB RAM and an AMD Radeon RX 9070 XT using Mesa RADV 26.2.5 / Vulkan
1.4.354. Each phase used 60 warmup and 300 measured frames. This driver printed
its non-conformance warning during startup. The walk path is a 60 m radius arc
centered at XZ (-1008, 692); its first point is XZ (-1008, 632), 40 m +Z from
the platform center at XZ (-1008, 592). It runs at a nominal 6 m/s. Fast traversal runs at
120 m/s along the recorded route and stays at least 3 m above sea level or
terrain. Teleports remain a separate stress phase. The original walk capture
landed beneath a cabin roof; the adjusted capture is on an open slope.

| Phase | Displacement | Viewport GPU p50 / p95 | Renderer process CPU p50 / p95 |
| --- | --- | ---: | ---: |
| Walk | On | 1.563 / 1.921 ms | 0.004 / 1.290 ms |
| Walk | Off | 0.870 / 1.029 ms | 0.003 / 1.208 ms |
| Fast traversal | On | 1.484 / 1.644 ms | 1.285 / 1.685 ms |
| Fast traversal | Off | 1.188 / 1.459 ms | 1.221 / 1.624 ms |

The corrected run verified all 18 bound images as 2048×2048 compressed
textures with mipmaps: Color/ORMH used BPTC_RGBA (BC7), and NormalGL used
RGTC_RG (BC5). It bound 32 material definitions to six unique color, six
unique normal and six unique ORMH resources. The synthetic residency pass
created 96 distinct resources by duplicating the six source sets across 32
slots. RenderingServer texture memory rose from 332,264,708 to 914,356,740
bytes, a 582,092,032 byte increase. Process RSS rose from 593,632 to 654,012
KiB; RenderingServer buffer memory changed from 33,279,528 to 33,280,664
bytes. The 536,873,472 bytes of copied compressed image payloads and GPU
memory delta are whole-process synthetic-stress accounting, not terrain-only
memory; the duplicated images do not represent 32 downloaded art sets.

The corrected report and immutable uncompressed-baseline reports are saved in
`docs/benchmarks` (`docs/benchmarks/`). The old mode-1 baseline's synthetic pass
increased RenderingServer texture memory by 2,192,704,768 bytes, compared with
582,092,032 bytes after BC7/BC5 import. The final capture was run with the
portable Linux template-debug artifact; its SHA-256, native source fingerprint,
compiler, and container image ID are embedded in the JSON report. The run used
the cached 4097×4097 runtime bake; load/startup were excluded from measured frames. The
initial staging import emitted regenerated-UID warnings and Godot ObjectDB
leak warnings at process exit; the benchmark process itself exited
successfully.

## Smooth-shading comparison

The renderer's default smooth-shading option changes lighting normals only;
height interpolation, displacement, patch selection, and mesh geometry remain
unchanged. The compatibility path retains the previous triangle-height
derivatives (`epsilon = 0.08`). The smooth path derives lighting normals from
the compiled height field at one native sample spacing, with one-sided samples
at its edges.

For this comparison, the old renderer and the current renderer loaded isolated
copies of the same saved 4097×4097 island runtime cache and the same six-set
materials. Both used Godot 4.4.1 Forward+ at 1920×1080 on the Ryzen 7 5800X3D,
64 GiB RAM, and RX 9070 XT / RADV 26.2.5 / Vulkan 1.4.354. The fixed views
were the building platform at XZ (-1008, 592) and an erosion slope at XZ
(-608, 16). Each view had 120 warmup frames followed by 300 measured frames.
The visible patch and triangle counts matched between modes: 430 patches /
877,120 triangles at the house and 451 patches / 919,936 triangles at the
slope. Timing covers the full viewport, not terrain-only GPU work.

| View | Mode | Viewport GPU p50 / p95 / p99 | Renderer process CPU p50 / p95 |
| --- | --- | ---: | ---: |
| House | Previous shader | 1.466 / 2.020 / 2.171 ms | 0.004 / 0.006 ms |
| House | Smooth | 1.446 / 1.996 / 2.209 ms | 0.004 / 0.005 ms |
| Erosion slope | Previous shader | 1.702 / 2.330 / 2.534 ms | 0.005 / 0.006 ms |
| Erosion slope | Smooth | 1.680 / 2.313 / 2.549 ms | 0.004 / 0.006 ms |

These GPU differences are within run-to-run measurement noise; this run shows
no measurable performance regression from the default smooth mode. The captures
show reduced triangular lighting faceting along the eroded ridges and smoother
platform sidewalls. The regular-texture before/after captures are:

- Previous renderer: `/tmp/hego-terrain-prototype/shading-compare/baseline/baseline_house.png`
  and `baseline_erosion_slope.png` in the same directory.
- Smooth renderer: `/tmp/hego-terrain-prototype/shading-compare/after/smooth_house.png`
  and `smooth_erosion_slope.png` in the same directory.

The isolated capture and report harness is
`/tmp/hego-terrain-prototype/shading-compare/after/island/shading_probe.gd`;
its settings and per-view distributions are in the adjacent `smooth.json` and
`triangle_compat.json`. The latter measured the new renderer with smooth mode
off, for a same-code compatibility-path check. A neutral-normal diagnostic
also showed the normal-field transition without terrain material normal maps;
its tonemapped colors are overexposed and are not the presentation captures.

### Final smooth-shading cost check

The optional crease mode joins adjacent face normals when their dihedral angle
is within `crease_angle_degrees`. At 180° it is disabled. After moving crease
processing into a lazy shader variant, an isolated repeat compared the original
smooth-only shader with the final default 180° variant on the same cached field,
materials, and two views. Both projects ran after the same background cook had
finished and with no other terrain renderer active. Each view used 120 warmup
frames and 300 measured frames. The actual bound shader was the base
`terrain_surface.gdshader` in both cases, with no crease define and the crease
variant inactive. The rows show p50 / p95 GPU times:

| Shader setting | House viewport GPU p50 / p95 | Erosion-slope viewport GPU p50 / p95 |
| --- | ---: | ---: |
| Original smooth-only | 2.409 / 2.476 ms | 2.667 / 2.988 ms |
| Final smooth, crease disabled (180°) | 2.412 / 2.473 ms | 2.685 / 2.986 ms |
| Final smooth, crease enabled (60°) | 2.756 / 3.119 ms | 2.936 / 3.808 ms |

Renderer process CPU remained 0.004–0.005 ms p50. The first two versions match
within run noise; this repeat found no measurable default overhead. The 60°
row is one paired run after those checks. Its report confirmed
`active_crease_variant = true` and that the bound shader code contains the
crease define. It raised GPU p50 by about 14% at the house and 9% at the slope
over the final disabled mode. Absolute timings differ from the earlier
comparison above, which ran under a different system load and GPU clock state,
so the two sets should not be compared directly.

The 0° capture shows more triangle faceting. Its preliminary timing run
overlapped a background Houdini compute cook and is not used as a performance
measurement. These measurements cover the whole viewport, not terrain-only GPU
cost. Isolated captures and raw reports remain in
`/tmp/hego-terrain-prototype/shading-compare/`.

## Material height-blend contrast

On the saved 4097×4097 island cache, a same-process Forward+ comparison toggled
`height_blend_enabled` off then on with the same materials, camera, and 1920×1080
viewport. Each mode used 120 warmup frames and 300 measured frames at the
cliff/grass blend near XZ (-568, 20). On this Ryzen 7 5800X3D / RX 9070 XT
system, full-viewport GPU p50/p95 changed from 2.102/2.161 ms to 2.436/2.561 ms
(+0.334 ms p50 in this run); renderer-process CPU p50 remained 0.004 ms. This is
one measured view, not a hardware-independent cost estimate.

The cliff/grass view shows stronger rocky peaks and less uniform blending when
height contrast is enabled. A second off/on capture at the softer sand/grass
blend near XZ (508, 700) remained visually soft, with no obvious banding. At the
384 m UV-variant boundary near X=-512, the paired captures showed no obvious
material pop. Saved enabled captures: rock/grass (`demo/island/screenshots/material-height-blend-rock.png`, regenerated locally)
and sand/grass (`demo/island/screenshots/material-height-blend-sand.png`, regenerated locally).
Off/on hero and UV-boundary captures, plus per-frame distributions, are in
`/tmp/hego-terrain-prototype/material-height-contrast/paired-captures/`.

## 4K distant LOD density check

I compared the saved island runtime field at the primary 3840×2160 display size
(Godot 4.4.1 Forward+, 75° perspective FOV, RX 9070 XT) in one process. The
baseline used 32 cells per patch, ratio 1.8, budget 512, with screen-relative
scaling disabled. Balanced used 32/2.5/768 and High used 64/3/1024; both used
the renderer's 4K screen-relative ratio multiplier (√2 at this FOV/viewport).
Each fixed far-slope view used 150 warmup frames and 300 measured frames.
Timings are whole-viewport GPU time; the selector's camera movement/update cost
is not paid on static frames.

| Setting | Patches / triangles | GPU p50 / p95 | Renderer process CPU p50 / p95 |
| --- | ---: | ---: | ---: |
| Baseline 32/1.8/512 | 388 / 790,976 | 2.827 / 3.538 ms | 0.005 / 0.006 ms |
| Balanced 32/2.5/768 | 685 / 1,399,584 | 3.066 / 4.172 ms | 0.007 / 0.008 ms |
| High 64/3/1024 | 877 / 7,177,088 | 4.523 / 8.226 ms | 0.007 / 0.009 ms |

To estimate geometric LOD error, the native selector's patch containing the
same slope target (XZ -608, 16) was sampled at each mesh-triangle centroid and
compared with the continuous 1 m compiled field. Near camera, Baseline uses a
16 m patch / 0.5 m vertex spacing and has p95/max error 0.019/0.028 m;
Balanced uses 32 m / 1 m and 0.065/0.111 m; High uses 32 m / 0.5 m and
0.016/0.028 m. At the far view, Baseline and Balanced both select a 128 m patch
with 4 m vertex spacing (0.786/2.311 m p95/max), while High selects 64 m / 1 m
(0.055/0.111 m). At the very-far view, Baseline and Balanced use 256 m / 8 m
(1.440/2.891 m); High uses 128 m / 2 m (0.158/0.442 m). These are localized
patch interpolation measurements, not a screen-space image error guarantee.
The original 1 m field differs from its own bilinear 8 m resample by roughly
1.3–1.6 m p95 at these slope samples, so distant geometry should preserve that
relief rather than collapse to a coarse silhouette.

Balanced materially improves the near patch but does not reduce the far-target
error in this view. High reduces both far and very-far interpolation error;
its GPU p95 was 8.226 ms in this single run, with the full 7.18 million triangle
scene. These numbers are a one-machine development comparison, not a
hardware-independent guarantee. Captures and selector sample reports are in
`/tmp/hego-terrain-prototype/lod-quality/`.

The LOD comparison above predates the final authored terrain-tint cache and is a
matched geometry-density check, not final-scene acceptance. A separate HIGH
preset camera-motion sample at the same 3840×2160 viewport moved 0.1 m in X and
0.05 m in Z per frame for 300 frames after 150 warmup frames. LOD replanned on
16 of the 300 frames. On those update frames, renderer process CPU was 3.664 ms
p50 / 4.501 ms p95; the plan+mesh+patch-update total was 3.505 / 4.355 ms, with
native selection 1.481 / 2.038 ms and patch application 1.760 / 2.129 ms. Across
all frames renderer process CPU was 0.007 ms p50 / 3.325 ms p95. This small
camera-motion sample is not a broad motion workload; it shows that static frames
are cheap and camera-triggered LOD updates are the current CPU spike. The raw
report is `/tmp/hego-terrain-prototype/lod-quality/moving_cpu_report.json`.
