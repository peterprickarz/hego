# Native terrain bulk APIs

The standalone terrain extension provides dense RF transport and composition
without a GDScript call for every pixel. It has no HEGo or Houdini dependency.
Authoring channels retain their independent native grids and binary ownership.

## Height compilation

```gdscript
var compiled := StrataProcedural.compile_heightfield(
    terrain, through_layer, spacing, options)
```

`through_layer=null` compiles the complete enabled stack. A layer cutoff creates
a cumulative preview. Options are `bounds:Rect2` (default terrain bounds),
`max_samples:int` (default 20*1024*1024), and `include_coverage:bool` (false).
Resolution includes both endpoints: `ceil(extent/spacing)+1`. The returned actual
steps span the requested endpoints exactly, including nonintegral intervals.

Success returns `{ok,image:Image,min,max,bounds:Rect2,resolution:Vector2i,
sample_origin:Vector3,sample_step_x:Vector3,sample_step_y:Vector3,
token:Dictionary,samples:int}`. The image is independent RF data. Coverage is
another RF image only when requested. Failure returns `{ok:false,message}`.
Recheck `StrataProcedural.token_is_current(result.token)` before publishing
a previously captured result. The token records the source read set, layer
order, terrain bounds and transform.

Replace and Add preserve the existing ownership-weighted sampling rules.
Unowned values never bleed into interpolation; an owned zero remains an edit.
Replace height uses the imported field plane's Y datum, while Add stores deltas.

## Canonical holes and navigation exclusions

```gdscript
var masks := StrataProcedural.compile_cell_masks(
    terrain, through_layer, spacing, options)
```

Bounds, cutoff, endpoint resolution and `max_samples` match height compilation.
Additional options:

- `hole_channel:String="hole"`, `nav_exclusion_channel:String="nav_exclusion"`.
- `continuous_channels:PackedStringArray=[]`: explicit permission to convert
  continuous imported field values into categories. Manual authoring always
  retains binary Hole/Solid semantics, independent of these thresholds.
- `thresholds:Dictionary={}`: per-channel conversion threshold; default is >=0.5.
- `max_work:int=268435456`, `max_fragments:int=4096`: bounded geometric work and
  temporary polygon fragmentation. Exhaustion rejects the whole result.

Success returns `{ok,bounds,resolution,holes:PackedByteArray,
nav_exclusions:PackedByteArray,hole_image:Image|null,
nav_exclusion_image:Image|null,token,report}`. Resolution describes vertices;
each mask has `(resolution.x-1)*(resolution.y-1)` row-major cells. Bytes are
0 solid/included or 255 hole/excluded. Empty arrays and null images mean no
affected cells. Nonempty images are L8 at the cell dimensions. The no-hole path
does not allocate masks or images.

Authored categorical values require Replace composition: Hole=1, Solid=0,
Erase=unowned. Add is rejected. Nonbinary procedural samples require explicit
threshold conversion. Categories use half-step pixel regions around native
sample positions; they are never bilinearly interpolated. The compiler clips
these regions and subtracts every upper owned region before reduction. Thus
upper explicit Solid restores lower Hole, while even a narrow remaining hole
survives. Rotated, anisotropic and negative horizontal grid axes are supported.

Any positive-area overlap excludes a target cell. Merely touching its boundary
does not. This conservatively expands a hole to whole target cells, by up to
one target cell at each source boundary. The report records this policy, cell
size, counts, conversion settings and work. Feed the same canonical masks to
rendering, collision and navigation; do not independently downsample them for
distant terrain patches.

## Dense data primitives

- `replace_dense(channel,index_origin,image:RF,ownership:RF=null)->bool` validates
  and replaces one complete channel atomically. Missing ownership means all
  samples owned; explicit ownership must be exactly 0/1. One changed replacement
  advances revision once; identical data is a no-op.
- `read_dense(channel,index_origin,resolution)->{ok,image:RF,ownership:RF,
  owned_count}` returns independent images, with zero values for unowned samples.
- `get_owned_rect(channel)->Rect2i` finds native ownership bounds without creating
  an array of sample indices.
- `validate_dense(image,ownership=null)->{ok,samples,owned_count,min,max}` validates
  finite RF values and binary ownership. Min/max cover every image pixel,
  including unowned pixels, so cached full-height images can be checked natively.
- Static `compose_dense` accepts captured source descriptors containing `data`,
  physical `origin/step_x/step_y`, `mode` (0 Replace/1 Add) and `height_offset`.
  The GDScript compiler supplies these descriptors; native code performs sampling.
  A trailing `index_offset:Vector2i` composes a window of a larger lattice: output
  texel (x, y) is lattice point (x + offset.x, y + offset.y), computed with the same
  expression as the whole lattice, so the window is bit-identical to that rectangle of
  a complete composition. The editor preview uses it to recompose only a brush dab's
  rectangle of the 4 m material controls and the scalar channel view.
- `get_channel_revision(channel)->int` is the resource revision at which that channel
  last changed. Sample, region, replace and clear edits advance only their channel;
  grid changes and whole-resource loads or restores advance every channel.
  `get_revision()` still advances on every change. Caches keyed on a few channels,
  such as the editor's material controls (`StrataMaterialControls.signature`), use it
  so a height or mask dab on a layer that also holds material samples keeps them.

Raw procedural snapshots preserve each channel's physical basis and native
resolution, with separate binary `__ownership` images. `compact_empty:true`
requests a 1x1 zero-owner footprint for empty overlay inputs. The default empty
raw snapshot retains its established full-bounds behavior. Exported images and
imported native data cannot alias caller-owned image mutations.

## Channel value formats and serialization

`StrataLayerData` stores each channel's values in one of three formats, declared per channel
with `set_channel_format(channel, format) -> bool` (`VALUE_FLOAT32` 0, the default;
`VALUE_UNORM8` 1; `VALUE_UNORM16` 2) and read with `get_channel_format(channel)`. A format can
be set only while the channel has no samples; otherwise (or for an invalid format) the call
returns false and changes nothing. The declaration persists across `clear_channel`, sample
erasure and serialization. Per sample a tile retains the value bytes plus one ownership byte:
5 bytes for float32, 2 for unorm8, 3 for unorm16 (`get_memory_bytes(channel="")` reports the
retained tile bytes of one channel, or all channels when empty).

Every API keeps its float contract. Unorm channels clamp written values to 0..1, quantize to
nearest (`floor(v * 255 + 0.5)` or `* 65535`) and return `q / 255` or `q / 65535`. This
covers `set_sample`, `patch_dense`, `restore_dense` and `replace_dense` (a value outside 0..1 is
clamped, not rejected); `get_sample`, `sample_channel`, `read_dense`, `get_owned_rect`,
`compose_dense` and `compile_cell_mask` read the dequantized values. A write that quantizes to
the stored byte is a no-op and does not advance the revision. `get_channels()` stays the
legacy float-tile view (dequantized); `set_channels()` keeps the formats already declared on
the resource and quantizes into them.

The 512 MiB dense-import budget of `replace_dense`/`patch_dense` is now counted in retained
bytes (value plus ownership bytes per tile) instead of tiles, so unorm channels fit
proportionally more tiles. For float32 it is the same 1638-tile limit as before.

`serialized_data` is format version 2:
`channels[name] = {format:int, tiles:{Vector2i:{values, ownership}}}`. Float32 tiles carry a
65536-element `PackedFloat32Array`; unorm tiles a little-endian `PackedByteArray` (65536 or
131072 bytes); ownership is a 65536-byte 0/1 `PackedByteArray`. Tiles without owned samples are
dropped; a channel with a non-default format and no samples is kept (empty `tiles`) so its
format round-trips. `restore()` accepts version 1 (channels map straight to float32 tile
dictionaries, every channel is float32 and previously declared formats are reset) and version
2, rejecting anything else atomically; `snapshot()` always writes version 2, so committed
version 1 resources keep loading and are upgraded on the next save. `get_format_version()`
returns 2.

## Material packing

`pack_material_weights(images, weights_format=Image.FORMAT_RGBAF)` and
`pack_material_weights_sparse(images, weights_format=Image.FORMAT_RGBAF)` accept 1 to 32
RF/RH images of one lattice of up to 20 Mi samples (the old 1025 per-side cap is gone), at most
256 Mi input samples in total. `weights_format` is `Image.FORMAT_RGBAF` (normalized top-4
weights) or `Image.FORMAT_RGBA8`: bytes whose four values sum to exactly 255 on every assigned
texel and are all zero on unassigned texels. The bytes use largest-remainder apportionment of
`w * 255` (floor every slot, give the remaining units to the largest fractional remainders, ties
to the lower slot), so each byte stays within 1/255 of the RGBAF weight and equals
round-to-nearest wherever that already sums to 255. (Rounding to nearest with the largest slot
absorbing the difference can deviate by up to 1.5/255.) IDs are identical for both formats.
Other formats are rejected.

`prepare_control_maps(ids, weights, material_count)` accepts RGBA8 weights as well. RGBA8
input is validated for IDs and returned as RGBA8 with every texel whose bytes sum to something
other than 0 or 255 renormalized to sum to 255 by the same apportionment; zero-sum texels are
kept. RGBAF/RGBAH input is normalized and returned as RGBAF as before.

`quantize_material_weights(rgbaf_image)` is the region composition's byte quantisation of the
sparse pack's RGBAF weights (`round(w / total * 255)` per slot, the largest slot takes the
remainder so an assigned texel sums to 255, unassigned texels stay 0). It is not the
largest-remainder apportionment of `weights_format = RGBA8` above; the region maps keep the
rounding they always had.

## Windowed composition at region scale

`compose_dense(..., index_offset)` composes a window of a lattice of any size up to the 20 Mi
sample cap per window; offsets may be negative (a region's apron before the terrain origin)
and `offset + size` is bounded by 20 Mi, so a 4097 lattice (offset up to 4096) works. A 261 x 261 window equals the matching rectangle of the
4097 x 4097 composition bit for bit for Replace and Add layers, values and coverage.

`compile_cell_mask` needs no window argument: pass the window's `bounds` (its first and last
vertex positions) and its vertex resolution; the result equals the matching cells of the full
mask because cell rectangles are computed as `bounds.position + cell * (bounds.size / cells)`.
Keep the cell size exactly representable (for example a whole number of metres, or dyadic
fractions) so window and full cell corners are identical doubles; the cost scales with the
cells inside the window, not with the whole terrain.

## Parallel region composition

`StrataRegions.compose_regions(terrain, through_layer, spec, xys, options)` composes many
regions at once, one region per `WorkerThreadPool` group task, and returns
`{ok, message, regions: {xy: StrataRegionData}}`. Each region is byte for byte what
`compose_region` returns; `options.threads = false` (or a platform without threads) runs the
same code serially. The call blocks until every region is done and stops handing out new
regions after the first failure.

Thread-safety, as audited and tested:

- **Native read paths.** `compose_dense`, `compile_cell_mask` and `pack_material_weights(_sparse)`
  keep all working state in locals. `compose_dense` and `compile_cell_mask` build their
  `GridSampler`s per call (each holds a `Ref` to the layer data, whose reference count is
  atomic, and a tile-pointer lookup it owns) and only *read* the `StrataLayerData` tile maps
  (`channels` is never touched on these paths; there are no caches, lazy indices, mutable
  members or static scratch buffers in `terrain/src`). Concurrent calls over the same
  `StrataLayerData` are therefore safe **as long as nothing writes that data**. Writes
  (`set_sample`, `replace_dense`, `patch_dense`, `restore`, ...) are not synchronized and must not
  overlap a composition: the layers are frozen between `capture()` and the end of
  `compose_regions`. `terrain_bulk_test` composes 64 windows concurrently over shared data three
  times and compares them with the serial result.
- **Script side.** The scene tree (`get_children`, `is_inside_tree`, transforms) and the
  layers' properties are read once, on the calling thread, by `StrataRegionCompose.capture()`,
  which also builds the lazily initialised shared state (`StrataMacro` neutral data,
  `StrataMaterialControls` native-method table). The tasks run `compose()` with that capture
  (`options.capture`) and touch only the captured descriptor arrays, their own locals and
  engine resources they create (`Image`, `StrataRegionData`). Captured descriptor
  Dictionaries are shared read-only; the mask `mapping`/`threshold` fields are set during
  capture, never during composition. With `options.capture` set, a map the capture lacks is an
  error instead of a live read, so nothing silently falls back to the tree. `compose_map`
  and `compose` can be called from any thread with a capture; without one they read the live
  terrain and belong on the main thread.
- **Mips.** `build_mips` works on one `StrataRegionData` and calls pure native helpers, so
  one region per task is safe (tested against serial mips).
- **Limits.** The pool needs `OS.has_feature("threads")`. Memory is the regions in flight plus
  the finished ones (about 0.9 MB per region for the standard spec at 256 cells, before
  mips). The speed-up on 16 threads is about 4x for composition; it is bounded by memory
  bandwidth and by the debug build, not by locking.

### Where the time went (synthetic island, 16 x 16 regions of 256 cells at 1 m)

`tests/region_compose_benchmark.gd` (a benchmark, not part of `run_tests.sh`) builds a
synthetic fixture shaped like the island (smooth noise: it is *not* island data) and times
every region serially per map class, the whole `compose_region`, `build_mips` and the parallel
paths. Linux debug build, 16 threads:

| | before | after (serial) | after (16 threads) |
| --- | --- | --- | --- |
| height (native `compose_dense` 1.4 s of 1.5 s) | 1.6 s | 1.5 s | |
| holes | 0.6 s | 0.7 s | |
| materials (4 planes) | 13.5 s | 4.1 s | |
| macro | 0.3 s | 0.3 s | |
| `compose_region` x 256 | 16.3 s | 6.7 s | 1.7 s |
| `build_mips` x 256, 5 levels | 33.0 s | 0.4 s | 0.05 s |

Materials were dominated by the per-texel byte quantisation loop in script (now native
`quantize_material_weights`), and the mips by their per-texel filters (now native
`downsample_samples` / `downsample_materials`). What remains is native composition itself.
The saved island measures 14.1 s serial and 3.6 s with `compose_regions` for all 256 regions
(its material planes are the long pole; the island was not measured before the change).

## Mips

Level `l` texel `u` of a sample map is lattice index `(u - apron) << l`, so levels share
lattice points. `StrataRegions.build_mips` builds the **height** map by decimation: texel `u`
at level `l` is texel `2u - apron` of level `l - 1` (the coincident sample, clamped at the
edges), so heights agree exactly at shared points across tiers and with a direct composition
at that level. Other scalar sample maps keep the `[1 2 1] / 4` tent filter, material ids the
majority rule, cell maps "any". The per-texel work is native
(`downsample_samples(values, planes, source_size, target_size, apron, mode)` with mode 0 tent, 1
cell maximum, 2 decimation; `downsample_materials(ids, weights, ...)`); builds without them
fall back to script loops with identical results.

## Composing at a level

`StrataRegionCompose.compose_map` honours `window.level` of `StrataRegions.map_window(...,
level)` and `StrataRegions.coarse_window(spec, description, level)`: the window's `step` is the
map's texel step at that level and `first` an index of that coarser lattice, so the native call
composes the coarse lattice directly (a terrain-wide coarse map is one call with
`first = (0, 0)`). `step` is checked against the level.

- **Height** is bit-identical to decimating the level-0 composition at the shared lattice
  points: `origin + step * 2^l * i` and `origin + step * (i << l)` are the same single
  rounding, and equals the decimated mip texels wherever the mip is not edge-clamped.
- **Everything else** (material ids and weights, hole and exclusion masks, macro, channels) is
  composed directly on the coarse lattice. That is **not** the mip downsample of the level-0
  map: a coarse material texel carries the materials at its own point rather than the heaviest
  of its block, a coarse hole cell only the area of that coarse cell. It is meant for editor
  previews and far/coarse residency; baked data must come from level 0 plus `build_mips`.
- `options.sources` are level-0 lattices and are rejected at a level above 0.

## Allocation and work limits

Each dense RF image is limited to 20*1024*1024 samples. A snapshot has a default
64*1024*1024 aggregate image-sample budget, including its companions, which
`max_samples` can raise to 128*1024*1024; a procedural transaction's complete result,
including ownership companions and all targets, is limited to 128*1024*1024 samples. Composition accepts at most 64 descriptors.
Tile lookup acceleration is independently bounded at 262144 pointers per source.

`replace_dense` rejects a resulting resource with more than 512 MiB of retained
tile value/ownership storage (counted in bytes, per channel format), including other channels and thin-image padding.
It checks occupied tile count before allocating replacement tiles. This is a
dense-import guard; legacy `set_sample` and `restore` do not enforce this ceiling.
Atomic replacement keeps the old and new channels until publication, plus RF
transport buffers. Transient memory can exceed the retained ceiling, approaching
twice the tile budget plus bounded image buffers. The guard is not a process
memory limit.

Mask compilation also bounds target cells, source count, work and fragmentation.
Geometrically complex overlays can fail their budget rather than return a
partial topology map. General normalized-mask area filtering is outside this
categorical compiler's scope.

## Reproduce verification

Build from the repository root with Godot 4.7.2-compatible godot-cpp:

```sh
scons -f SConstruct.terrain platform=linux target=template_debug -j8
python3 - /path/to/Godot_v4.7.2-stable_linux.x86_64 <<'PY'
from pathlib import Path
import shutil, subprocess, sys, tempfile
root = Path.cwd()
project = Path(tempfile.mkdtemp(prefix="hego-terrain-bulk-"))
shutil.copytree(root / "demo/addons/strata", project / "addons/strata")
tests = ("terrain_bulk_test.gd", "terrain_cell_mask_test.gd",
         "native_data_test.gd", "procedural_transaction_test.gd")
(project / "tests").mkdir()
for test in tests:
    shutil.copy2(root / "demo/tests" / test, project / "tests" / test)
(project / "project.godot").write_text('config_version=5\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
print("Isolated test project:", project, flush=True)
godot = sys.argv[1]
subprocess.run([godot, "--headless", "--editor", "--import", "--path", str(project), "--quit"], check=True)
for test in tests:
    command = [godot, "--headless", "--path", str(project), "--script", "res://tests/" + test]
    if test == "terrain_bulk_test.gd": command += ["--", "--large"]
    subprocess.run(command, check=True)
PY
```

Replace the executable argument with your Godot 4.7.2 path. This staging keeps
tests separate from active demo/HAPI work and prints its temporary project path.
The main demo uses its installed `demo/addons/strata` directly;
`scripts/run_terrain_prototype.py --prepare-only` validates that location without
staging or replacing files. Its `--test` mode uses a separate disposable project.
These suites need no HAPI session. The build writes the standalone terrain extension, not the tracked
HEGo binary.

Measured locally on the island fixture: 513² at 8 m and 2049² at 2 m imports
took about 28 ms; the complete 2 m cumulative snapshot about 300 ms; 4097² at
1 m height compilation about 1.78 s with 188 MiB process peak RSS. A single
submeter hole compiled onto 4096² canonical cells in about 8 ms using 16 MiB of
mask bytes. The empty-mask path took about 0.05 ms and allocated no mask.
Timings are observations, not portable limits.

Tests cover mixed-grid numerical composition/datum, owned zero, partial
ownership, negative tile seams, no-op revisions, atomic invalid-input rejection,
image isolation, preallocation padding limits, upper Solid restoration,
rotated/negative categorical grids, explicit thresholds, exact touching
boundaries, and work/fragment exhaustion.
