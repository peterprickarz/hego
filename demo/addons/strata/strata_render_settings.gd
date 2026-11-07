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
## Camera-centred clipmap of the resolved terrain surface (StrataSurfaceCache), filled on the
## GPU from the terrain material. Near displacement reads its relief, and other shaders read the
## ground below them through shaders/strata_surface_cache.gdshaderinc (blending props, rocks and
## cliffs into the terrain). Needs Forward+ or Mobile. See "Surface cache" in docs/strata/reference.md.
@export var surface_cache_enabled := false:
	set(value):
		if surface_cache_enabled == value: return
		surface_cache_enabled = value
		emit_changed()
## Levels of doubling cell size. Level k covers resolution x texel x 2^k metres around the camera.
@export_range(1, 8, 1) var surface_cache_levels := 6:
	set(value):
		if value < 1 or value > 8: return
		if surface_cache_levels == value: return
		surface_cache_levels = value
		emit_changed()
## Cells per side of every level (16 bytes per cell and level).
@export_enum("256:256", "512:512", "1024:1024", "2048:2048") var surface_cache_resolution := 1024:
	set(value):
		if value not in [256, 512, 1024, 2048]: return
		if surface_cache_resolution == value: return
		surface_cache_resolution = value
		emit_changed()
## Cells per metre of level 0. Match the material texel density (128 for 128 texels/m materials)
## so level 0 copies material texels one to one.
@export_range(8.0, 512.0, 1.0) var surface_cache_texels_per_metre := 128.0:
	set(value):
		if not is_finite(value) or value <= 0.0: return
		if surface_cache_texels_per_metre == value: return
		surface_cache_texels_per_metre = value
		emit_changed()
## Near displacement reads the material relief from the cache instead of sampling every
## material per vertex. The cache level whose cells match displacement_vertex_spacing must cover
## the displacement radius; vertices outside it evaluate the material directly.
@export var surface_cache_displacement := true:
	set(value):
		if surface_cache_displacement == value: return
		surface_cache_displacement = value
		emit_changed()
## Publish the cache as the strata_cache_* global shader parameters. Only one terrain per scene
## should publish.
@export var surface_cache_publish_globals := true:
	set(value):
		if surface_cache_publish_globals == value: return
		surface_cache_publish_globals = value
		emit_changed()
