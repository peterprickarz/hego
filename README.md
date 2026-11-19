# Strata addon package

This standalone package is built from source commit a37d08d385e04492a739dc8f4594ab9e29eed16c. It depends on Godot
and godot-cpp, but does not require HEGo or Houdini. See `PACKAGE.json` for
the package dependency declaration and `native-build.json` for binary receipts.

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
`textureGrad` picks the mip matching the page's. View space is the terrain's frame seen from above
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
so a tile costs one viewport render. A tile covers one page slot of the cache (the page and its
border, 136² cells for 128-cell pages, plus one cell of apron) at the page's mip. The cache asks
for a tile when it needs a page that a writer touches, waits for it, and evaluates the page
once: the terrain material with the writers composited over it, after the terrain tint map,
recording the writers' coverage per cell (R8 `cover` atlas). A page therefore never shows its
ground first and its road a moment later. At most `tiles_per_frame` (16) tiles are drawn per
frame; the rest queue, and tiles of pages no longer wanted are dropped. A moved or edited
writer keeps the old content of its pages until their new tiles are drawn, so nothing
flickers.

Whether a writer touches a page is decided from the writers' mesh boxes: the registry keeps a
16 m grid of the cells they cover (`StrataSurfaceWriterRegistry.FOOTPRINT_CELL`), so a writer
of many meshes spread over the terrain does not claim the ground between them. The test is
conservative: a page beside a writer may get a tile that turns out empty.

**Terrain.** With cache shading the terrain takes writers with everything else from the
pages. Pixels it shades itself (steep ground, materials with custom fragment code, pages not
resident yet) read the cell's writer coverage from the finest resident page at their footprint
and take the cached albedo, normal, roughness, metallic and AO in proportion. Writers are in
every mip of the cache, so they show at any distance. `StrataRenderer.debug_surface_writers`
tints the writers on directly shaded pixels cyan.

**Cost** (RX 9070 XT, 2386 × 1200; measured in a 4 km island level of a game using Strata,
whose roads are 209 writer meshes, not in this repository's demo):

- Writers that do not change cost nothing per frame.
- A tile is one viewport render: 0.04 ms GPU and 0.04 to 0.1 ms CPU. The first tiles after
  load took about 1 ms CPU each.
- A cold start over a road drew 314 tiles for 631 pages in under 120 frames (at 8 tiles per
  frame).
- A writer change over a 40 m square redrew the 24 pages on screen there.
- Memory: the cover atlas is one of the cache's 17 bytes per cell. Writer viewports take about
  1 MB each for 128-cell pages, at most `max_viewports` (32); they are created on demand and
  freed after `idle_release_seconds` (5) unused, one kept.