# Terrain material height blending

`StrataMaterial` exposes two controls in the Resource Inspector. They use the existing ORMH alpha texture to redistribute the painted material weights at each sample. No new textures or control maps are required.

| Property | Default | Valid range | Effect |
| --- | --- | --- | --- |
| `height_blend_contrast` | 0 | 0–16 | Higher values give that material's texture peaks more influence and its crevices less influence. Zero gives this material neutral height gain; its final weight can still change when other materials have positive contrast. |
| `height_blend_bias` | 0 | −0.5–0.5 | Centers a source's height distribution for weight competition; positive values raise its priority. |

For each selected material, the gain is `contrast * (clamp(alpha + bias, 0, 1) - 0.5)`. The renderer normalizes `painted_weight * exp2(gain)` using a shared exponent shift for numerical stability. A zero painted weight stays zero; materials are not threshold-pruned. Renderer `height_blend_enabled = false`, or zero contrast for every selected material, retains the previous weights exactly. Bias never offsets the sampled displacement heights: displacement still uses raw `alpha - 0.5`. Redistributing material weights can nevertheless change the resulting visual microdisplacement mixture. Collision, authored terrain heights and canonical holes do not change.

The same weight kernel is used for vertex detail and fragment shading. Fragment samples reuse the existing gradient-filtered near/far ORMH textures; vertex samples use the existing LOD0 height lookup. Their texture-height samples can therefore differ under minification. This is material shading and visual detail, not a change to the physical terrain surface.

## Island profiles and editing

The first six source resources retain these tuning profiles. The island now uses32 distinct sources and a Houdini-authored distribution; see [island material distribution](island-material-distribution.md). IDs are no longer aliases of this table:

| Source | Contrast | Bias |
| --- | ---: | ---: |
| Coastal sand | 1.2 | +0.10 |
| Island grass | 2.0 | +0.18 |
| Mossy cliff | 12.0 | +0.11 |
| Dark cliff | 14.0 | 0.00 |
| Scree gravel | 8.0 | +0.14 |
| Alpine snow | 2.5 | −0.20 |

The stronger cliff/gravel profiles let rock texture peaks emerge through softer vegetation and sand. Biases approximately center the measured alpha medians at 0.5, so a source such as snow is not favored merely because its displacement map is globally brighter. The source images and their import settings remain unchanged.

Edit and save these `.tres` resources in the Resource Inspector to retain adjustments. `make_variant(uv_multiplier)` shares source textures and follows source texture/UV/triplanar-sharpness/displacement/contrast/bias/roughness edits. The active renderer coalesces material `changed` notifications into a refresh. The island binds32 independent registered resources directly; it does not create linked variants or repeat the first six. A separately running game does not watch editor file saves; reopening it loads the saved profiles.

Saving a material or variant as `.tres`/`.res`, or inside a `PackedScene`, preserves its exported controls and texture references. A saved variant is an independent snapshot; its private live source connection is not serialized. The island compiled-runtime bootstrap loads the 32 registered distinct resources, which are included in the runtime-only project. Material tuning requires no terrain bake or Houdini cook.

The asset generator reproduces these defaults without downloading or rewriting textures:

```sh
python3 scripts/prepare_island_materials.py --resources-only
```

Asset preparation preserves existing material resources and their user tuning by default. Consult `scripts/prepare_island_materials.py --help` before explicitly resetting profiles. Texture packing does not author terrain placement.

## Physical tiling and dry-surface controls

The island no longer applies the former six per-ID UV multipliers. Each distinct registered source uses its own resource's physical `uv_scale`; `island_grass.tres` defaults to 0.1 (one repeat per 10 terrain-local metres). Other grass IDs now reference different ambientCG sources, rather than the same image. Each material resource can still choose its own physical scale, and an explicit `make_variant(multiplier)` remains available for deliberate variations.

Materials use terrain-local triplanar projection. Each source resource exposes `triplanar_sharpness` in the Inspector, default 4, with a finite valid range of 1–64. It controls the exponent of the projection-axis blend weights: lower values give broader transitions and higher values make them sharper. One setting is shared by that material's color, normal and ORMH maps, including ORMH alpha used for height blending and visual displacement. Different material IDs can use different sharpness values. `uv_scale` remains repeats per terrain-local metre on all three projection planes; terrain transforms carry the projection with the terrain.

Sharpness edits emit the same resource notifications as other material settings and require no terrain bake or Houdini cook. Missing sharpness properties in older resources use 4; a newly added or unbound zero shader uniform also uses 4 until the renderer uploads its material array. Text/binary resources and scene export preserve explicit settings. Live UV variants follow their source's sharpness without applying the UV multiplier. Independent settings belong in separate material resources, as they do for the other controls.

Independent sharpness adds a per-material scalar and weight arithmetic; that arithmetic is small compared with the additional texture fetches of triplanar projection. Triplanar projection samples three planes rather than one. Exact GPU cost depends on hardware, texture filtering, material mixtures and distance-UV settings; the older timing measurements below predate this projection change.

Renderer `distance_uv_enabled` defaults to false. This keeps material scale stable with camera distance and avoids far-scale texture fetches. Opting in restores the near/far crossfade controlled by `far_uv_factor` (0.125), `uv_near_distance` (16 m) and `uv_far_distance` (128 m). These are appearance settings, not terrain mesh LOD settings.

Packed ORMH is still AO/roughness/metallic/height. All six packed green channels were checked byte-for-byte against their cached source `Roughness.jpg`; all metallic channels remain zero. The source maps explain the original sheen: mean roughness is 0.263 for grass, 0.496 for mossy rock and 0.497 for snow. The normal-map convention and reconstruction are retained.

Each source now exports `roughness_scale` (0–2, default 1) and `roughness_bias` (−1–1, default 0). The shader applies `clamp(source_roughness * scale + bias, 0, 1)` before material weighting, retaining the existing final minimum of 0.04. Identity defaults preserve older material resources. The island's dry-surface presets are:

| Source | Roughness scale | Roughness bias |
| --- | ---: | ---: |
| Coastal sand | 1.00 | +0.18 |
| Island grass | 0.75 | +0.52 |
| Mossy cliff | 1.00 | +0.22 |
| Dark cliff | 1.00 | +0.06 |
| Scree gravel | 1.00 | +0.18 |
| Alpine snow | 1.00 | +0.24 |

Texture images and normal maps are not repacked. The importer explicitly keeps VRAM compression, mipmaps and RG normal compression, with `detect_3d/compress_to = 0`. Godot's one-shot detector itself changes this flag to zero after detection; it does not disable the selected compression mode. This explicit profile avoids repeated editor metadata rewrites. See the [Godot 4.4 importer implementation](https://raw.githubusercontent.com/godotengine/godot/4.4-stable/editor/import/resource_importer_texture.cpp) and [importer options](https://docs.godotengine.org/en/4.4/classes/class_resourceimportertexture.html).

## Terrain-scale tint and AO

The macro texture is independent of material UVs: linear RGBAH data spans terrain-local XZ bounds, with its first/last texel centers on the declared bounds edges. RGB is a tint multiplier (neutral 1, range 0–2); alpha is ambient occlusion (neutral 1, range 0–1). Sampling is linear, clamped and non-repeating, with no sRGB decoding. Translation/yaw of the terrain does not move the tint relative to it.

`terrain_tint_strength` and `terrain_ao_strength` independently blend from neutral. RGB multiplies material albedo once; alpha multiplies material AO once and is not multiplied into albedo. This keeps optional cavity occlusion separate from authored cavity colour. A missing or white map leaves the material colour unchanged: the earlier hardcoded sine tint has been removed, so the configurable terrain map is the only macro colour multiplier. Macro tint does not alter terrain heights, displacement samples or ownership. The production shader also supports an unlit scalar channel preview for editor mask values.

The focused `terrain_appearance_test.gd` passed 78 GPU checks on Godot 4.4.1 / RX 9070 XT in an isolated project. It verifies byte-identical actual grass aliases at the same camera, roughness remapping/clamps, explicit distance scaling, material-colour neutrality without a macro map, white-map identity, linear HDR RGB, separate AO/strengths, endpoint alignment at a negative origin, edge clamping, terrain translation/yaw, material-UV independence and scalar preview. Mask grayscale and the ownership footprint coexist, including owned zero and erase, without a second ownership texture lookup. All six actual sources reported BC7 (`BPTC_RGBA`) Color/ORMH and BC5 (`RGTC_RG`) NormalGL, each with mipmaps. The resource roundtrip suite now passes 110 checks including roughness persistence and consistent source scales.

## Resource verification

After staging/importing a disposable project with a unique application name, run:

```sh
"$GODOT_BIN" --headless --path /path/to/disposable/project --script res://tests/material_resource_test.gd
"$GODOT_BIN" --headless --path /path/to/disposable/project --script res://tests/material_binding_test.gd
```

Godot 4.4.1 passed 110 checks in an isolated project containing only the material script and imported source textures, with no native extension or Houdini addon. Checks cover old serialized resources with absent properties, finite/range validation, preserved legacy scalar domains, signal deduplication and disconnection, live variant propagation/lifetime, text/binary resources, scene export, exact texture payloads and the actual 32-definition source profiles. Expected invalid-input warnings are deliberate. Resource-only regeneration preserves textures, imports and manifests; this milestone separately changes only the auto-detection enum in 18 import sidecars to the explicit profile described above.

The triplanar additions passed 133 resource checks and 8 binding checks on Godot 4.4.1 in an isolated project. They extend resource coverage with sharpness defaults, both range endpoints, rejected nonfinite/out-of-range inputs, signal deduplication, live variant propagation and independent text/binary/scene persistence. `material_binding_test.gd` uses a deliberately small synthetic shader to check the CPU binding contract, all 32 uniform slots, independent material values, default unused slots and coalesced live edits. It does not establish projection appearance or GPU normal orientation; those require the production shader GPU tests. The binding test uses the existing native library for script dependencies, without rebuilding it or loading Houdini.

## Shader and renderer verification

The focused `demo/tests/terrain_height_blend_test.gd` passed with `TERRAIN_HEIGHT_BLEND_TEST failures=0` on Godot 4.4.1 / AMD Radeon RX 9070 XT (RADV GFX1201), Vulkan 1.4.354. It was run in an isolated project containing only the standalone terrain addon:

```sh
DISPLAY=:0 "$GODOT_BIN" --path /path/to/isolated/project \
  --rendering-method forward_plus --resolution 1920x1080 \
  --script res://tests/terrain_height_blend_test.gd
```

CPU and shared-kernel GPU readback checks cover exact disabled/zero-contrast identities, single-material identity, zero-weight preservation, peak/valley response, slot permutation and duplicate-ID equivalence, extreme valid controls, and neutral handling of nonfinite texture alpha. Valid input weights come from the existing normalized categorical control selection. Bias is added before final clamping. The production two-material fixture verifies that color, mapped normal, ORM and the actual displaced vertex height all use the resulting weights. It also checks that bias does not act as a displacement offset, material edit bursts coalesce to one binding refresh, and base height/ray queries stay unchanged.

The existing `terrain_shading_test.gd` also passed with zero failures after adding the height-blend include: smooth normals, optional crease shader variants and their texture bindings remain valid. Its original 112-patch versus one-patch normal comparison had zero sampled RGB difference. The later appearance update reran it at 1920×1080 with 172 patches versus one patch and again found zero RGB difference; the full height-blend regression also passed. The existing `render_state_test.gd` passed at the height-blend milestone, including renderer removal/readdition, rejected input retention and cached displacement bounds with the deferred material watchers.

The fragment stage reuses its existing near/far RGBA ORMH samples; alpha does not add texture fetches. A matched 1920×1080 close rock/grass view measured whole-viewport GPU median/p95 of 2.102/2.161 ms disabled and 2.436/2.561 ms enabled (+0.334 ms median). Renderer process CPU median remained 0.004 ms. These are complete-scene measurements, not terrain-only GPU costs. No native rebuild or Houdini cook was needed.

Same-camera island captures from the earlier height-blend milestone show stronger rock texture relief through vegetation and a softer sand/grass transition: rock blend (`demo/island/screenshots/material-height-blend-rock.png`, regenerated locally), sand blend (`demo/island/screenshots/material-height-blend-sand.png`, regenerated locally). Those captures and the timing pair above use the prior per-ID/distance UV behavior; they are not evidence for the subsequent physical-scale fix or soft material cap. Categorical by-ID selection still precedes height competition. Base terrain data, collision, navigation and ownership were not modified by the blend kernel.

## Soft material cap across control texels

Each control texel stores at most four material IDs, but bilinear interpolation merges the contributions of four neighboring texels by ID. That neighborhood can contain up to sixteen IDs. A per-texel authoring cap alone therefore cannot prevent a second fourth/fifth exchange in the shader. Previously the shader dropped the fifth candidate while the fourth still had a nonzero weight, which could abruptly switch color, normal response and relief.

After the by-ID merge, sort the positive aggregate weights in descending order, resolving equal weights by ascending material ID. Let `t` be the fifth weight, or zero when there are at most four positive IDs. The shader retains the leading four with `q_i = max(w_i - t, 0)` and normalizes their `q` values. This subtracts the threshold from all retained weights, rather than only fading the last slot. At an ordinary fourth/fifth exchange, both competing contributions reach zero before their IDs swap. One to four positive materials retain their original ratios; unassigned controls stay exactly zero. Threshold subtraction emphasizes the stronger materials and can leave fewer than four active contributions.

The shared kernel runs in both vertex relief and fragment shading. Bounded texture-height gains multiply these softened weights, so they cannot restore a finite jump at an ordinary fourth/fifth exchange. Strong height contrast can still make the transition visually narrow. Exactly five or more equal leading weights leave no positive remainder: that degenerate case deliberately uses the previous normalized hard top-four result with ascending-ID tie resolution. It can still be discontinuous, and near-degenerate inputs can be sensitive to float precision. This rule does not promise global continuity for arbitrary tied palettes or recover information already removed by authored masks or per-texel packing.

`discarded_weight` remains the fraction of raw interpolated mass outside the leading four, before threshold subtraction. It excludes the additional mass removed by softening and is not a perceptual-error estimate. The renderer's maximum remains a sampled control-cell-midpoint diagnostic, not a bound over the field. No new source texture fetches, material slots, field channels or control-map format are added.

`terrain_material_soft_limit_test.gd` uses dedicated synthetic four-slot neighborhoods whose union contains five or sixteen materials. It verifies the analytic subtraction rule, preserved one-to-four ratios, exact zeros, deterministic tied fallback, CPU/GPU agreement, raw discard diagnostics and convergence through a fourth/fifth exchange with height contrast 16. A positive control restores the previous hard cap and demonstrates its finite surface-response jump. The production shader check compares color, ORMH height competition and actual vertex displacement with the CPU reference. The mixed refined/coarse LOD regression checks watertight geometry in smooth, legacy and crease modes, with deliberately patch-dependent displacement as a crack-producing control. These fixtures do not change the normal island showcase or establish a worst-case continuity guarantee.

Godot 4.4.1 / RX 9070 XT passed 553 checks, including the 58 CPU checks available headless. At positions 0.5 ± 0.000001 across the ordinary exchange, the CPU surface-response difference was 0.0000295 and GPU difference was below 0.001; restoring the old hard cap gave a GPU difference of 0.853. Production color/alpha errors were below 0.0005 and vertex displacement error below 0.0006 m. The five-source mixed-LOD fixture used 523 patches, including 207 refined leaves, with zero background cracks in all three lighting modes; its deliberately patch-dependent control opened 2153 background pixels. The previous `render_material_test.gd` CPU regressions also passed.

Run the CPU checks headless, then the GPU cases on a real Forward+ device, in a disposable project with a unique application name and the existing standalone addon/native library:

```sh
"$GODOT_BIN" --headless --path /path/to/disposable/project --script res://tests/terrain_material_soft_limit_test.gd
DISPLAY=:0 "$GODOT_BIN" --path /path/to/disposable/project --rendering-method forward_plus --script res://tests/terrain_material_soft_limit_test.gd
```
