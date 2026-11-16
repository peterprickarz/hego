@tool
class_name StrataRenderSettings
extends Resource
## Geometry density only. Height data, collision and material UVs are independent.
enum Quality { PERFORMANCE, BALANCED, HIGH, ULTRA, CUSTOM }
@export var quality: Quality = Quality.HIGH:
	set(value):
		quality = value
		emit_changed()
## Increase density for larger viewports and narrower camera fields of view.
@export var screen_relative := true:
	set(value):
		screen_relative = value
		emit_changed()
@export_group("Custom geometry (Custom preset)")
@export_enum("4:4", "8:8", "16:16", "32:32", "64:64") var cells_per_patch := 64:
	set(value):
		cells_per_patch = value
		emit_changed()
@export var min_patch_size := 8.0:
	set(value):
		min_patch_size = value
		emit_changed()
@export_range(0.5, 8.0, 0.1) var split_ratio := 3.0:
	set(value):
		split_ratio = value
		emit_changed()
@export_range(64, 4096, 64) var max_patches := 1024:
	set(value):
		max_patches = value
		emit_changed()

func parameters() -> Dictionary:
	match quality:
		Quality.PERFORMANCE: return {"cells": 32, "minimum": 8.0, "ratio": 1.8, "budget": 512}
		Quality.BALANCED: return {"cells": 32, "minimum": 8.0, "ratio": 2.5, "budget": 768}
		Quality.HIGH: return {"cells": 64, "minimum": 8.0, "ratio": 3.0, "budget": 1024}
		Quality.ULTRA: return {"cells": 64, "minimum": 8.0, "ratio": 4.0, "budget": 2048}
	return {"cells": cells_per_patch, "minimum": min_patch_size, "ratio": split_ratio, "budget": max_patches}

@export_group("Material distance appearance")
## Off keeps the same physical texture repeat at all viewing distances.
@export var distance_uv_enabled := false:
	set(value):
		distance_uv_enabled = value
		emit_changed()
@export_range(0.01, 1.0, 0.01) var far_uv_factor := 0.125:
	set(value):
		if not is_finite(value) or value <= 0.0 or value > 1.0: return
		far_uv_factor = value
		emit_changed()
@export var uv_near_distance := 16.0:
	set(value):
		if not is_finite(value) or value < 0.0: return
		uv_near_distance = value
		emit_changed()
@export var uv_far_distance := 128.0:
	set(value):
		if not is_finite(value) or value <= 0.0: return
		uv_far_distance = value
		emit_changed()
@export_group("Material sampling")
## Opt-in pixel-art look. Colour, normals and ORMH use nearest filtering with mipmaps and
## sample at texel centres (mip level still chosen from the unsnapped
## coordinates), so lighting detail and the height blend follow the same texel grid.
## Off keeps the default smooth filtering.
@export var pixel_sampling := false:
	set(value):
		if pixel_sampling == value: return
		pixel_sampling = value
		emit_changed()
## Three-cell texture bombing (hex tiling): every material texture read blends three randomly
## offset and turned copies of its tile, chosen by the material's height, so the tile grid
## stops repeating. About three times the texture reads of plain tiling.
@export var cell_bombing := false:
	set(value):
		if cell_bombing == value: return
		cell_bombing = value
		emit_changed()
## With surface cache shading, bombing is baked into the cache and pixels the terrain shades
## itself (pages not resident yet, steeper than surface_cache_shading_max_slope, custom
## fragment code) show plain tiling. On: those pixels are bombed too, at about three times the
## texture reads. Without cache shading every pixel is bombed.
@export var cell_bombing_outside_cache := false:
	set(value):
		if cell_bombing_outside_cache == value: return
		cell_bombing_outside_cache = value
		emit_changed()
## Spacing of the bombing cells' corners in tile repeats (1: about one tile).
@export_range(0.25, 4.0, 0.05) var cell_bombing_size := 1.0:
	set(value):
		if not is_finite(value) or value <= 0.0: return
		cell_bombing_size = value
		emit_changed()
@export_group("Terrain-wide tint and AO")
@export_range(0.0, 1.0, 0.01) var terrain_tint_strength := 1.0:
	set(value):
		if not is_finite(value) or value < 0.0 or value > 1.0: return
		terrain_tint_strength = value
		emit_changed()
@export_range(0.0, 1.0, 0.01) var terrain_ao_strength := 1.0:
	set(value):
		if not is_finite(value) or value < 0.0 or value > 1.0: return
		terrain_ao_strength = value
		emit_changed()
@export_group("Surface response")
## Dielectric specular level of every terrain material (Godot SPECULAR; 0.5 is Godot's default,
## F0 0.04). Godot also limits the grazing-angle Fresnel by F0, so rough natural ground such as
## soil, moss and weathered rock reads better around 0.1, without a sheen towards the sun. Rain
## wetness raises it towards the water film's 0.5.
@export_range(0.0, 1.0, 0.01) var terrain_specular := 0.5:
	set(value):
		if not is_finite(value) or value < 0.0 or value > 1.0: return
		terrain_specular = value
		emit_changed()

@export_group("Near displacement geometry")
## Additional native quadtree leaves near the camera; base geometry settings
## above keep their independent budget and are never coarsened to pay for these.
@export var displacement_refinement_enabled := true:
	set(value):
		if displacement_refinement_enabled == value: return
		displacement_refinement_enabled = value
		emit_changed()
## Desired vertex spacing in metres. Snapped to compatible dyadic patches;
## depth and extra-budget limits may make the actual spacing coarser.
@export_range(0.001, 8.0, 0.001, "or_greater") var displacement_vertex_spacing := 0.0625:
	set(value):
		if not is_finite(value) or value <= 0.0:
			push_warning("Displacement vertex spacing must be finite and positive; previous setting retained.")
			return
		if displacement_vertex_spacing == value: return
		displacement_vertex_spacing = value
		emit_changed()
## Also drives the shader's displacement fade radius. Native geometry includes
## a small camera movement guard band beyond this radius.
@export_range(0.0, 512.0, 1.0, "or_greater") var displacement_refinement_radius := 32.0:
	set(value):
		if not is_finite(value) or value < 0.0:
			push_warning("Displacement refinement radius must be finite and nonnegative; previous setting retained.")
			return
		if displacement_refinement_radius == value: return
		displacement_refinement_radius = value
		emit_changed()
## Extra leaves, including balancing. The combined native hard cap is 4,096.
@export_range(0, 4096, 16) var displacement_refinement_budget := 1024:
	set(value):
		if value < 0 or value > 4096:
			push_warning("Displacement extra patch budget must be within 0..4096; previous setting retained.")
			return
		if displacement_refinement_budget == value: return
		displacement_refinement_budget = value
		emit_changed()

@export_group("Surface cache")
## Virtual texture of the resolved terrain surface (StrataSurfaceCache): pages over the whole
## terrain in a mip chain, of which those the screen reads are kept in a pool and filled on the
## GPU from the terrain material. Near displacement reads its relief, surface writers are drawn
## into it, the terrain can shade from it (surface_cache_shading), and other shaders read the
## ground below them through shaders/strata_surface_cache.gdshaderinc (blending props, rocks and
## cliffs into the terrain). Needs Forward+ or Mobile. See "Surface cache" in docs/strata/reference.md.
@export var surface_cache_enabled := false:
	set(value):
		if surface_cache_enabled == value: return
		surface_cache_enabled = value
		emit_changed()
## Cells per metre of mip 0. Match the material texel density (128 for 128 texels/m materials)
## so mip 0 copies material texels one to one. The page table has one texel per page of mip 0:
## it may not exceed 4096 pages per side (raise surface_cache_page_size on large terrains).
@export_range(8.0, 512.0, 1.0) var surface_cache_texels_per_metre := 128.0:
	set(value):
		if not is_finite(value) or value <= 0.0: return
		if surface_cache_texels_per_metre == value: return
		surface_cache_texels_per_metre = value
		emit_changed()
## Near displacement reads the material relief from the cache instead of sampling every
## material per vertex: the pages of the mip whose cells match displacement_vertex_spacing are
## kept around the camera, and a vertex whose page is not there yet evaluates the material
## directly.
@export var surface_cache_displacement := true:
	set(value):
		if surface_cache_displacement == value: return
		surface_cache_displacement = value
		emit_changed()
## The terrain shades flat and gentle ground from the cache's resolved surface (colour, normal,
## roughness, metallic, AO, writers) instead of evaluating its materials, at the mip matching
## the pixel footprint, filtered by surface_cache_filter. Ground steeper than
## surface_cache_shading_max_slope (where the top-down cells stretch), materials with
## custom_fragment_code (view-dependent) and pixels whose pages are not resident yet keep direct
## shading.
@export var surface_cache_shading := false:
	set(value):
		if surface_cache_shading == value: return
		surface_cache_shading = value
		emit_changed()
## Steepest ground, in degrees, that is shaded from the cache.
@export_range(0.0, 90.0, 0.5) var surface_cache_shading_max_slope := 45.0:
	set(value):
		if not is_finite(value) or value < 0.0 or value > 90.0: return
		if surface_cache_shading_max_slope == value: return
		surface_cache_shading_max_slope = value
		emit_changed()
## Added to the cache mip a pixel footprint selects (negative: finer), for shading, for the
## pages the screen requests and for other shaders reading the ground. The GPU picks material
## mips about one level finer than the footprint formula; -1 matches direct shading by eye.
@export_range(-2.0, 2.0, 0.25) var surface_cache_shading_lod_bias := -1.0:
	set(value):
		if not is_finite(value) or surface_cache_shading_lod_bias == value: return
		surface_cache_shading_lod_bias = value
		emit_changed()
## With cache shading, the far UV blend (distance_uv_*) follows the pixel footprint instead of
## the camera distance, so each cache mip can hold its share: a footprint counts as the distance
## at which flat ground seen from this eye height has it. A standing player sees the same blend
## as before; higher views see the far tiles later, grazing views on slopes sooner.
@export_range(0.1, 100.0, 0.1) var surface_cache_shading_eye_height := 1.7:
	set(value):
		if not is_finite(value) or value <= 0.0 or surface_cache_shading_eye_height == value: return
		surface_cache_shading_eye_height = value
		emit_changed()
## How cache shading filters the cells it reads. Nearest takes one cell and blends two mips, as
## nearest-texel materials with mipmaps look. Linear is bilinear in the nearest mip, Trilinear
## bilinear with two mips blended. Anisotropic reads the mip of the footprint's short axis (up
## to surface_cache_anisotropy times finer) along the long one, which keeps grazing ground sharp
## and requests more pages. Other shaders reading the ground take the nearest cell with Nearest, else bilinear.
@export_enum("Nearest:0", "Linear:1", "Trilinear:2", "Anisotropic:3") var surface_cache_filter := 0:
	set(value):
		if value < 0 or value > 3 or surface_cache_filter == value: return
		surface_cache_filter = value
		emit_changed()
## Largest ratio of a pixel's long axis on the ground to its short one that Anisotropic follows.
## Each doubling reads one mip finer at grazing angles and needs up to four times the pages
## there: raise surface_cache_pool_pages with it.
@export_enum("2:2", "4:4", "8:8") var surface_cache_anisotropy := 4:
	set(value):
		if value not in [2, 4, 8] or surface_cache_anisotropy == value: return
		surface_cache_anisotropy = value
		emit_changed()
## The cache's pages are requested by what the screen shows: a compute pass after the opaque
## pass (StrataVirtualTextureFeedback, on the camera's compositor) reads the depth buffer and
## reports the pages under the visible pixels. Off: the pages around the camera at every mip
## (about 3.5 m around it at mip 0, doubling per mip), whatever the view.
@export var surface_cache_feedback := true:
	set(value):
		if surface_cache_feedback == value: return
		surface_cache_feedback = value
		emit_changed()
## Cells per page side. Larger pages need a smaller page table and fewer lookups of new pages,
## and keep more cells nobody reads.
@export_enum("64:64", "128:128", "256:256") var surface_cache_page_size := 128:
	set(value):
		if value not in [64, 128, 256] or surface_cache_page_size == value: return
		surface_cache_page_size = value
		emit_changed()
## Pages the pool holds (about 0.3 MB each at 128 cells): those on screen plus a reserve that
## saves evaluating them again. When the screen requests more than fit, the cache reads coarser
## mips until they do (stats.surface_cache.pressure_bias, a softer surface): a 4K view at lod
## bias 0 requests about 1,500 to 2,500 pages, a 1440p view about a third of that.
@export_range(64, 8192, 1) var surface_cache_pool_pages := 1024:
	set(value):
		if value < 64 or value > 8192 or surface_cache_pool_pages == value: return
		surface_cache_pool_pages = value
		emit_changed()
## Pages evaluated per frame at most (pages a surface writer touches come on top, as their
## writer tiles are drawn).
@export_range(1, 256, 1) var surface_cache_page_fills_per_frame := 32:
	set(value):
		if value < 1 or value > 256 or surface_cache_page_fills_per_frame == value: return
		surface_cache_page_fills_per_frame = value
		emit_changed()
## Tints pixels shaded from the cache green and directly shaded ones red.
@export var surface_cache_shading_debug := false:
	set(value):
		if surface_cache_shading_debug == value: return
		surface_cache_shading_debug = value
		emit_changed()
## Prototype. Per-pixel parallax of the relief that is finer than the displaced mesh, marched
## through the surface cache's relief (needs surface_cache_enabled). The mesh keeps the relief of
## its vertex spacing; the ray sees the rest, at the cache level matching the pixel. Smooth reads
## the relief bilinearly, Columns per cache cell (flat-topped texel columns with walls). No
## depth is written and nothing is cast into shadow maps.
@export_enum("Off:0", "Smooth:1", "Columns:2") var parallax_mode := 0:
	set(value):
		if value < 0 or value > 2: return
		if parallax_mode == value: return
		parallax_mode = value
		emit_changed()
## Distance in metres where the parallax has faded out (it fades from 60 % of it).
@export_range(0.0, 64.0, 0.5) var parallax_radius := 8.0:
	set(value):
		if not is_finite(value) or value < 0.0: return
		if parallax_radius == value: return
		parallax_radius = value
		emit_changed()
## Half thickness in metres of the shell around the mesh surface the ray is marched through;
## finer relief beyond it is flattened.
@export_range(0.0, 0.25, 0.005) var parallax_depth := 0.02:
	set(value):
		if not is_finite(value) or value < 0.0: return
		if parallax_depth == value: return
		parallax_depth = value
		emit_changed()
## Share of the relief the mesh does not carry that the ray sees. Material displacement is tuned
## for lumps of the mesh's vertex spacing: at 1 single texels stand out as spikes several
## centimetres tall.
@export_range(0.0, 1.0, 0.01) var parallax_strength := 0.25:
	set(value):
		if not is_finite(value) or value < 0.0 or value > 1.0: return
		if parallax_strength == value: return
		parallax_strength = value
		emit_changed()
## Finest cache level the ray reads. Level 0 is one material texel, where scanned height maps
## are noisy; level 2 keeps features of about 3 cm and up (with 128 cells per metre).
@export_range(0, 4, 1) var parallax_min_level := 0:
	set(value):
		if value < 0 or value > 4: return
		if parallax_min_level == value: return
		parallax_min_level = value
		emit_changed()
## Most steps of one ray (one per cache cell it crosses, plus five to refine the hit).
@export_range(4, 64, 1) var parallax_steps := 24:
	set(value):
		if value < 4 or value > 64: return
		if parallax_steps == value: return
		parallax_steps = value
		emit_changed()
## Columns: albedo multiplier of column walls.
@export_range(0.0, 1.0, 0.01) var parallax_wall_shade := 0.75:
	set(value):
		if not is_finite(value) or value < 0.0 or value > 1.0: return
		if parallax_wall_shade == value: return
		parallax_wall_shade = value
		emit_changed()
## 1: hit height (red above the mesh, blue below) and walls (green). 2: cache level (red) and
## share of parallax_steps used (green).
@export_range(0, 2, 1) var parallax_debug := 0:
	set(value):
		if parallax_debug == value: return
		parallax_debug = value
		emit_changed()
## Publish the cache as the strata_cache_* global shader parameters. Only one terrain per scene
## should publish.
@export var surface_cache_publish_globals := true:
	set(value):
		if surface_cache_publish_globals == value: return
		surface_cache_publish_globals = value
		emit_changed()
