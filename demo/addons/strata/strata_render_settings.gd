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
