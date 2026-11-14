# Strata

Layered terrain for Godot 4.7+: hand-painted and procedural layers composed into one
heightfield, a quadtree mesher, a material renderer with up to 32 materials, and a bake
that produces runtime data for collision and navigation. Strata has no dependency on
HEGo or Houdini; the native extension needs only godot-cpp.

- `StrataTerrain3D` holds the layer stack and its `storage_directory`, where every layer
  and cooked channel is one file (`StrataStorage`).
- `StrataLayer` is either manual (brush data) or procedural (channels committed by a
  producer such as the HEGo Strata bridge).
- `StrataBake`, `StrataCollision` and `StrataNavigation` turn the compiled stack into
  gameplay data; the `strata_runtime_*` scripts load that data without the extension.

Documentation: `docs/development/terrain_runtime.md`, `docs/development/terrain_shading.md`,
`docs/development/terrain_material_blending.md` and `docs/development/terrain_macro.md` in the HEGo repository.
Native binaries are receipted in `native-build.json`.

## Surface writers

Any mesh can be written into the surface cache (`StrataSurfaceCache`, see "Surface cache" in
`docs/strata/reference.md`), like an Unreal Runtime Virtual Texture writer: roads, mesh decals,
anything with a writer material. The terrain then shows it, and every shader reading the cache
(rocks, trees, cliffs blending into the ground) picks it up. Needs
`StrataRenderSettings.surface_cache_enabled`; nothing in Strata is specific to roads.

**Authoring.** Add a `StrataSurfaceWriter` (Node3D) with a `mesh` and a writer `material`, or set
its `source` to a MeshInstance3D, or to a node whose MeshInstance3D descendants it should write
(for example a procedural cook's output node; Strata hides those from the main view while it
writes them and rescans when nodes are added under the source). With `material` empty, each
surface uses its own material. `priority` orders overlapping writers (higher on top; within one
priority the material's `render_priority`, then the higher geometry seen from above), and
`channels` picks which outputs it replaces. Moving, editing or freeing a writer refills only its
old and new rectangle, and so do its material's `changed` signal and `invalidate()` (call it
after setting a writer material's shader parameters from a script; ShaderMaterial parameters
do not signal a change; in the editor, writers watch their materials' parameters themselves).

**Writer material contract.** A spatial shader that includes
`res://addons/strata/shaders/strata_surface_writer.gdshaderinc` (which sets its render modes:
unshaded, alpha blended, no depth, and a `vertex()`) and ends `fragment()` with
`strata_writer_emit(o, ALBEDO, ALPHA)`. A writer that needs its own `vertex()` defines
`STRATA_WRITER_CUSTOM_VERTEX` before the include and ends `vertex()` with
`STRATA_WRITER_VERTEX;` (which sets `POSITION`):

```glsl
shader_type spatial;
#define STRATA_WRITER_TERRAIN_MATERIALS  // optional, for strata_writer_terrain_material()
#include "res://addons/strata/shaders/strata_surface_writer.gdshaderinc"
void fragment() {
    StrataWriterOutput o = strata_writer_output();
    o.albedo = ...; o.normal = ...; o.roughness = ...; o.relief = ...; o.alpha = ...;
    strata_writer_emit(o, ALBEDO, ALPHA);
}
```

| `StrataWriterOutput` | Meaning (default) |
| --- | --- |
| `vec3 albedo` | linear albedo (0.5) |
| `vec3 normal` | unit normal in ground space: terrain-local axes, Y up over flat ground. It is laid onto the terrain's slope like a normal map, so (0, 1, 0) keeps the terrain's own lighting normal |
| `float roughness`, `metallic`, `ao` | (1, 0, 1) |
| `float relief` | material relief in metres along the normal before the renderer's `displacement_strength`, as a `StrataMaterial`'s ORMH height × displacement (0); it drives the terrain's near displacement and the ground height props blend against |
| `float alpha` | coverage 0..1 of every output (1) |

The mesh is drawn from above: one pixel is one cache cell, so `dFdx`/`dFdy` are per cell and
`textureGrad` picks the mip of the cache level. View space is the terrain's frame seen from above
(`VIEW` x = +X, y = -Z, z = +Y); `strata_writer_view_to_ground()` converts it.
`strata_writer_tangent_to_ground(normal, uv_dx, uv_dy)` turns a normal map sampled with the
mesh's own UVs into ground space. With `STRATA_WRITER_TERRAIN_MATERIALS` defined,
`strata_writer_terrain_material(id, uv, uv_dx, uv_dy)` samples a terrain material (its top
projection set) by id with the writer's own UVs (in texture repeats:
`strata_writer_material_scale(id)` per metre) and returns albedo, tangent-space normal,
roughness (after the material's scale and bias), metallic, AO, relief and the ORMH height. The
renderer copies its material textures and arrays into such writer materials on the
RenderingServer (the resources are not modified). A writer material's metadata
`strata_terrain_materials` (Dictionary of int uniform name to material channel name in
`StrataTerrain3D.editor_material_channels`) sets those uniforms to the channels' ids.
Material textures use nearest filtering with mipmaps and texel-centre sampling unless
`STRATA_WRITER_LINEAR_SAMPLING` is defined.

**How it is drawn.** `strata_surface_writer_pass.gd` (an internal child of `StrataRenderer`)
draws writers into tiles, one SubViewport each with an orthographic top-down camera over a
private `World3D` (`StrataSurfaceWriterRegistry`), linear float output and premultiplied
over-blending. The viewport is three tiles wide: every writer has one instance per output
(albedo; normal + roughness; AO + relief + metallic), and the include moves each into its third,
so a tile costs one viewport render. Tiles are rows of 1024 × 32 cells and columns of 32 × 1024
for the strips a scrolling window exposes, and squares of 254² for the rest (each with one cell
of apron). A tile dispatched in one frame is composited by the cache's compute fill in the next
frame, over the evaluated terrain material and after the terrain tint map; the cache records
the writers' coverage per cell (R8 `cover` array). Only tiles a writer's bounds touch are drawn,
at most `tiles_per_frame` (6) per frame; the rest queue. Window scrolling fills new strips with terrain at once and
adds writers a frame later; a moved or edited writer keeps the old content until its tiles are
drawn, so nothing flickers.

**Terrain.** With the cache on, the terrain shader (`STRATA_SURFACE_CACHE` variant) reads the
cell's writer coverage at the level matching the pixel footprint and takes the cached albedo,
normal, roughness, metallic and AO in proportion; elsewhere it shades as before (custom fragment
code and the far-UV blend stay intact). The cache's writers fade out over the outer quarter of
the coarsest level (about ±96-128 m with 6 levels, ±400-512 m with 8), and the far layer takes
over there.

**Far layer.** `StrataSurfaceWriterFar` (`strata_surface_writer_far.gd`, owned by the renderer)
holds every writer over the whole terrain (`StrataTerrain3D.base_bounds`) at a coarse texel, the
counterpart of an Unreal runtime virtual texture's low mips, so writers stay visible at any
distance. `StrataRenderSettings.surface_writer_far_texel` (2 m; 0 disables it) is snapped to a
power-of-two multiple of the cache's level-0 cell and doubled until `surface_writer_far_max_size`
(2048) texels hold the terrain: a 4 km island gets 2048² texels of 2 m. The writer pass draws it
once, in tiles of 512² cells at half the texel, each averaged 2 × 2 into the layer, so coverage
is conservative: a road narrower than a texel becomes a faint, averaged tint instead of
breaking up. Far tiles queue behind the cache's (`far_tiles_per_frame`, 1); a writer that moves,
changes or is freed redraws only its rectangle, and nothing is drawn per frame otherwise. The
layer stores premultiplied albedo (sRGB-encoded, read through an sRGB view so filtering averages
in linear space) and premultiplied normal x/z and roughness, each with its coverage and a full mip
chain, and the terrain samples it trilinear and anisotropic, laid over its own surface exactly as
the cache's fill composites writers, cross-fading with the cache where the cache fades out (and
showing alone where a cache window is still filling). It is built at runtime from the live
writers rather than in the runtime bake: the bake runs headless without a GPU, and writers are
scene nodes the bake does not see. `StrataRenderer.debug_surface_writers` tints writers cyan
where they come from the cache and magenta where they come from the far layer.

**Cost** (RX 9070 XT, 1600×900, 8 levels; measured in a 4 km island level of a game using
Strata, whose roads are 218 writer meshes, not in this repository's demo):

- Writers that do not change cost nothing per frame; the terrain's coverage read is within noise.
- A tile is one viewport render: 0.03 ms GPU when the GPU is idle, about 0.1 ms under that
  level's full frame.
- Flying along roads at 6 m/s (scrolling strips with writers in every level): 2 tiles per
  frame, 0.06-0.22 ms GPU for the writer viewports and 0.10-0.13 ms more cache fill (0.29
  against 0.16 ms); the main view's GPU time and the wall frame time were unchanged within
  noise (26.6 against 26.4 ms GPU, 27.7 against 27.3-27.8 ms per frame).
- A writer that changes every frame (a turning 9 m decal, all 8 levels): 6 tiles per frame,
  0.21 ms GPU and 0.17 ms CPU for the viewports, 0.33 ms for the fill.
- Far layer (4 km, 2 m texels, the 218 road meshes): built in 43 frames after load (42 tiles
  with roads, 44 empty pieces cleared), 0.03 ms GPU per tile; nothing per frame afterwards. The
  terrain's far-layer read did not change the main view's GPU time (4.77 against 4.76-4.83 ms
  looking over the island from 1.2 km). 43 MB for the layer with mips; its viewports add about
  41 MB while it builds and are freed 5 s later.
- Memory: 17 bytes per cell per level (the cover array adds 1), 17 MB per 1024² level (136 MB
  with 8 levels). Writer viewports take 2-4 MB each (rows and columns 2, squares 4), at most
  `sets_per_shape` (4) per shape; they are created on demand and freed after
  `idle_release_seconds` (5) unused, one per shape kept: 28 MB with seven in use.
