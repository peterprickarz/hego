# Terrain lighting normals

`StrataRenderer` now uses smooth lighting by default. Geometry retains the canonical RF triangle interpolation, including its collision/query contract. Height samples, holes, authoring ownership, displacement and the native LOD partition are unchanged.

```gdscript
renderer.smooth_shading = true          # default
renderer.crease_angle_degrees = 180.0   # default: crease processing disabled
renderer.crease_angle_degrees = 60.0    # opt in to angle-limited hard edges
renderer.debug_shading_normals = true   # diagnostic: encoded terrain-local final normal
```

The properties are exported on the renderer. Setting `smooth_shading = false` restores the prior lighting calculation for comparison and ignores the crease setting. It does not change geometry. The diagnostic includes material normal maps; use a flat `(0.5, 0.5, 1)` normal texture when inspecting the field's base normals alone.

The smooth path computes central derivatives of the bilinearly filtered RF field at one native sample spacing: four filtered height fetches. At the outer boundary it uses the actual one-sided span, so a planar ramp keeps its normal. This yields a continuous lighting normal across native sample cells and canonical triangle diagonals. Sampling uses terrain-local coordinates and the complete field, independently of patch size or LOD. The same smooth base normal supplies vertex shadow bias and the direction of near-camera material displacement. Fragment lighting reorients each triplanar projection's normal-map detail onto the selected lighting normal, combines those results and transforms the final normal through the terrain's model and view matrices. Translation and yaw remain supported with unit scale.

Color, normal and ORMH now use three terrain-local projections from the undisplaced surface point. The continuous smooth field normal controls their shared axis weights; each material has its own `triplanar_sharpness` (default 4, range 1–64). Crease and legacy settings affect lighting only, so they do not change projection phase, weights or displaced geometry. Reoriented normal mapping preserves the underlying lighting normal exactly for a flat normal texture at every sharpness, including across a split ridge. Signed side frames keep cliff images upright. The top frame retains image U toward +X and image V toward +Z; OpenGL normal-map green points toward image up (−Z on top). This corrects the previous top basis's opposite green direction, so directional normal detail may light differently even on shallow ground. A probe using Godot's generated mesh `BINORMAL` confirmed this image-up convention.

The optional crease angle compares the dihedral between **adjacent canonical field triangles**, not their slope relative to up. At each of the current triangle's three corners, the six incident faces form smoothing groups connected only across edges within the threshold. The corner normal is the area-weighted normal of its group; fixed summation order makes the same shared group identical from either triangle. The three corner normals interpolate inside the current triangle. A steep plane therefore stays smooth, while a sharp ridge can split its normals. A smaller angle preserves more hard edges; 0 degrees is effectively faceted except where faces are coplanar.

Crease processing uses a separate cached shader variant generated from the loaded shared shader source. The default 180-degree shader is compiled without the crease functions, avoiding their register/code cost. Variant selection and uniform rebinding occur only on an explicit setting change, with no per-frame CPU mesh rebuild. The enabled path evaluates about 21 point height fetches and 18 incident face normals per fragment. In the tested 1920×1080 house and erosion-slope views on the RX 9070 XT, the final 60-degree variant added 0.344 ms (14%) near the houses and 0.251 ms (9%) on the slope to whole-viewport GPU median time. It is optional rather than a free default. See the [island benchmark record](island-benchmark.md) for the paired measurements and fixed cameras.

Smooth normals do not increase geometric resolution. A coarse distant LOD can still approximate terrain height or show an angular silhouette; this change does not blur, move, or repair those vertices. Creases likewise describe the canonical heightfield triangles, which may be finer than the currently rendered mesh. Material displacement remains visual and is not added to collision. It always follows the continuous base normal, including in legacy and crease modes, so these lighting settings never move displaced geometry. No Houdini cook or runtime field bake is needed merely to change lighting settings.

## Focused verification

Run the real Forward+ test after staging the standalone terrain addon into a disposable Godot project:

```sh
DISPLAY=:0 /home/peter/Godot/Godot_v4.4.1-stable_linux.x86_64 \
  --path /path/to/disposable/terrain-project --rendering-method forward_plus \
  --resolution 1920x1080 --script res://tests/terrain_shading_test.gd \
  -- --output=/tmp/hego-terrain-prototype/smooth-shading
```

Godot 4.4.1 on AMD Radeon RX 9070 XT / RADV GFX1201, Vulkan 1.4.354 passed with `TERRAIN_SHADING_TEST failures=0`. The focused checks cover:

- GPU normals for analytic planar ramps, including physical spacing and all outer edges.
- Continuity across sample-cell and canonical diagonal boundaries.
- A 90-degree ridge split at 30 degrees and joined at 120 degrees; a steep plane remains smooth at 5 degrees.
- The full spatial shader's material normal map and translation/yaw transform.
- Stable normal output with actual native partitions changing from 112 patches to one patch: maximum sampled RGB difference was zero.
- Pixel-identical rendered geometry coverage for compatibility, smooth and crease settings, unchanged RF bytes and mesh references.
- Cached shader reuse and preservation of height, control, color, normal and ORMH bindings through enable/disable roundtrips.

The test emits neutral-material lit and normal images for the previous and smooth paths. Actual-island before/after captures used the same house-platform and erosion-slope poses, field cache, resolution and LOD settings. Their normal diagnostics neutralized material normal maps. The initial smooth-only comparison kept whole-viewport GPU cost effectively unchanged: house median 1.466 → 1.446 ms and slope 1.702 → 1.680 ms. The final split-variant measurements are recorded in the benchmark document; startup and shader compilation are excluded from steady-state timings.

After the triplanar change, `terrain_shading_test.gd` again passed with zero failures, including an unchanged normal image across 172 patches versus one patch and mapped-normal translation/yaw. The focused `terrain_triplanar_test.gd` passed 134 checks on Godot 4.4.1 / RX 9070 XT. It uses explicit synthetic planes and a ridge, never showcase assets: positive and negative X/Z cliffs, flat normals at sharpness 1/4/64, both signs of red/green directional detail, shortest-arc CPU normal references, independent material sharpness, physical vertical texture scale, shared color/ORMH/vertex-height phase, height competition, distance-UV blending and flat-normal invariance across a crease. Patterned cliff color and ORMH errors stayed below 0.0008 and displacement errors below 0.0009 m in linear RGBA16F readback. The existing normal-displacement suite separately passed its mixed refined/coarse LOD watertightness and shading-mode geometry checks with the new projections. These results establish correctness for those fixtures; earlier GPU timings on this page predate triplanar projection.


A matched idle repeat compared the original smooth-only source with the final split default: house GPU median/p95 2.409/2.476 vs 2.412/2.473 ms; erosion slope 2.667/2.988 vs 2.685/2.986 ms. There was no measurable default-variant overhead in that matched comparison. Absolute timings shifted between sessions, so the earlier 1.4–1.7 ms results must not be compared directly with these later runs. The final 60-degree variant measured 2.756/3.119 ms near the houses and 2.936/3.808 ms on the slope (median/p95), paired with the same idle default runs above.
