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

Raw procedural snapshots preserve each channel's physical basis and native
resolution, with separate binary `__ownership` images. `compact_empty:true`
requests a 1x1 zero-owner footprint for empty overlay inputs. The default empty
raw snapshot retains its established full-bounds behavior. Exported images and
imported native data cannot alias caller-owned image mutations.

## Allocation and work limits

Each dense RF image is limited to 20*1024*1024 samples. A snapshot has a default
64*1024*1024 aggregate image-sample budget, including its companions, which
`max_samples` can raise to 128*1024*1024; a procedural transaction's complete result,
including ownership companions and all targets, is limited to 128*1024*1024 samples. Composition accepts at most 64 descriptors.
Tile lookup acceleration is independently bounded at 262144 pointers per source.

`replace_dense` rejects a resulting resource with more than 512 MiB of retained
tile value/ownership storage, including other channels and thin-image padding.
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
