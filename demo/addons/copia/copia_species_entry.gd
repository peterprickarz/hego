@tool
class_name CopiaSpeciesEntry
extends Resource
## One [CopiaObject] variant inside a [CopiaSpecies], with its relative selection weight and
## optional brush radial-falloff band (e.g. large variants concentrated in the brush centre
## [code]0.55..1.0[/code] and medium/small variants along the rim [code]0.0..0.65[/code]).

const ObjectScript := preload("res://addons/copia/copia_object.gd")
const PlacementScript := preload("res://addons/copia/copia_placement_settings.gd")

## The object variant to place.
@export var object: ObjectScript:
	set(value):
		object = value
		emit_changed()
## Relative selection weight within the species.
@export_range(0.0, 100.0, 0.05, "or_greater") var weight := 1.0:
	set(value):
		weight = maxf(value, 0.0)
		emit_changed()
## Lower bound of brush strength (0 = outer rim, 1 = brush centre) where this variant may spawn.
## Ignored when [member brush_strength_curve] is assigned.
@export_range(0.0, 1.0, 0.01) var brush_strength_min := 0.0:
	set(value):
		brush_strength_min = clampf(value, 0.0, 1.0)
		emit_changed()
## Upper bound of brush strength (0 = outer rim, 1 = brush centre) where this variant may spawn.
@export_range(0.0, 1.0, 0.01) var brush_strength_max := 1.0:
	set(value):
		brush_strength_max = clampf(value, 0.0, 1.0)
		emit_changed()
## Optional custom curve mapping brush strength t (0 = rim, 1 = centre) to weight multiplier.
## Overrides [member brush_strength_min] and [member brush_strength_max] when set.
@export var brush_strength_curve: Curve:
	set(value):
		brush_strength_curve = value
		emit_changed()
## Extra scale multiplier applied on top of the species' scale range for this variant.
@export_range(0.05, 10.0, 0.01, "or_greater") var scale_multiplier := 1.0:
	set(value):
		scale_multiplier = maxf(value, 0.01)
		emit_changed()
## Minimum spacing override in metres for this variant (-1 uses the species/object placement spacing).
@export_range(-1.0, 50.0, 0.05, "or_greater", "suffix:m") var spacing_override := -1.0:
	set(value):
		spacing_override = maxf(value, -1.0)
		emit_changed()
## Optional per-variant placement settings overriding the species' shared settings.
@export var placement_override: PlacementScript:
	set(value):
		placement_override = value
		emit_changed()


## Evaluates this entry's weight multiplier at brush strength [param strength] (0 = rim, 1 = centre).
func weight_at(strength: float) -> float:
	if object == null or weight <= 0.0:
		return 0.0
	var t := clampf(strength, 0.0, 1.0)
	if brush_strength_curve != null:
		return weight * maxf(0.0, brush_strength_curve.sample_baked(t))
	var lo := minf(brush_strength_min, brush_strength_max)
	var hi := maxf(brush_strength_min, brush_strength_max)
	return weight if (t >= lo and t <= hi) else 0.0
