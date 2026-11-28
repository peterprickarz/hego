@tool
class_name CopiaBrushPalette
extends Resource
## A saved brush preset for the Copia dock: a selection of [CopiaSpecies] and/or [CopiaObject]
## items with per-item weight multipliers and default brush settings. Editor-only resource.

## Human-readable preset name shown in the dock's Palettes bar.
@export var display_name := "":
	set(value):
		display_name = value
		emit_changed()
## Active [CopiaSpecies] or [CopiaObject] resources in this palette.
@export var items: Array[Resource] = []:
	set(value):
		items = value
		emit_changed()
## Parallel weight multiplier per entry in [member items] (missing entries default to 1.0).
@export var weights: PackedFloat32Array = PackedFloat32Array():
	set(value):
		weights = value
		emit_changed()

@export_group("Brush Defaults")
@export_range(0.25, 200.0, 0.25, "or_greater", "suffix:m") var brush_radius := 5.0
@export_range(0.05, 10.0, 0.05, "or_greater") var density_scale := 1.0
@export_range(0.1, 10.0, 0.05, "or_greater") var spacing_scale := 1.0
@export var brush_falloff: Curve
@export_flags_3d_physics var collision_mask := 0xFFFFFFFF
@export var paint_on_terrain := true
@export var paint_on_meshes := true
@export var paint_on_copia := false
@export var avoid_generated_sets := false


func label() -> String:
	if not display_name.is_empty():
		return display_name
	if not resource_path.is_empty():
		return resource_path.get_file().get_basename()
	return "Palette"


func weight_for(index: int) -> float:
	if index >= 0 and index < weights.size():
		return maxf(0.0, weights[index])
	return 1.0
