@tool
class_name CopiaPlacementSettings
extends Resource
## Authoring placement and brush-painting rules for a [CopiaObject] or [CopiaSpecies].
## Editor-only authoring metadata: never a build input, so changing any property here never marks
## cells stale or triggers a store rebuild.
##
## Color and custom data default to [constant ColorMode.NONE] (quiet NaN in the set file), so
## [CopiaBuild] applies the object's [method CopiaObject._get_default_color] and
## [method CopiaObject._get_default_custom] without clobbering packed shader channels (such as
## shader fade in colour alpha or plant bend data in custom.w).

enum ColorMode {
	## Do not write per-instance colour (stores NaN; object default applies at build time).
	NONE,
	## Interpolate RGB between [member color_min] and [member color_max], preserving the object's
	## default colour alpha (safe for shaders that pack fade/flags into colour.a).
	TINT_RGB_PRESERVE_ALPHA,
	## Interpolate full RGBA between [member color_min] and [member color_max].
	TINT_RGBA,
}

## Target placement density (instances per square metre at brush centre, before brush multiplier).
@export_range(0.01, 50.0, 0.05, "or_greater", "suffix:/m2") var density := 1.0:
	set(value):
		density = maxf(value, 0.001)
		emit_changed()
## Minimum centre-to-centre distance in metres between instances during brush painting.
@export_range(0.0, 50.0, 0.05, "or_greater", "suffix:m") var min_spacing := 0.5:
	set(value):
		min_spacing = maxf(value, 0.0)
		emit_changed()

@export_group("Transform")
## Minimum uniform scale.
@export_range(0.01, 20.0, 0.01, "or_greater") var scale_min := 0.85:
	set(value):
		scale_min = maxf(value, 0.01)
		emit_changed()
## Maximum uniform scale.
@export_range(0.01, 20.0, 0.01, "or_greater") var scale_max := 1.15:
	set(value):
		scale_max = maxf(value, 0.01)
		emit_changed()
## Per-axis non-uniform scale jitter fraction (0 = uniform, 0.1 = +/- 10% per axis).
@export_range(0.0, 0.5, 0.01) var scale_jitter := 0.0:
	set(value):
		scale_jitter = clampf(value, 0.0, 0.9)
		emit_changed()
## How strongly placed instances align their local +Y axis to the hit surface normal (0 = world up,
## 1 = full surface normal).
@export_range(0.0, 1.0, 0.01) var align_to_normal := 0.25:
	set(value):
		align_to_normal = clampf(value, 0.0, 1.0)
		emit_changed()
## Randomise yaw around the instance's up axis (0..360 deg).
@export var random_yaw := true:
	set(value):
		random_yaw = value
		emit_changed()
## Maximum random tilt off the aligned up axis, in degrees.
@export_range(0.0, 45.0, 0.5, "suffix:deg") var random_tilt_deg := 0.0:
	set(value):
		random_tilt_deg = clampf(value, 0.0, 90.0)
		emit_changed()
## Minimum vertical offset along the aligned up axis (negative sinks the base into the ground).
@export_range(-5.0, 5.0, 0.01, "or_less", "or_greater", "suffix:m") var y_offset_min := -0.02:
	set(value):
		y_offset_min = value
		emit_changed()
## Maximum vertical offset along the aligned up axis.
@export_range(-5.0, 5.0, 0.01, "or_less", "or_greater", "suffix:m") var y_offset_max := 0.0:
	set(value):
		y_offset_max = value
		emit_changed()

@export_group("Surface & Brush")
## Minimum surface slope angle from horizontal, in degrees.
@export_range(0.0, 180.0, 1.0, "suffix:deg") var slope_min_deg := 0.0:
	set(value):
		slope_min_deg = clampf(value, 0.0, 180.0)
		emit_changed()
## Maximum surface slope angle from horizontal, in degrees.
@export_range(0.0, 180.0, 1.0, "suffix:deg") var slope_max_deg := 45.0:
	set(value):
		slope_max_deg = clampf(value, 0.0, 180.0)
		emit_changed()
## Optional curve mapping brush strength t (0 = brush rim, 1 = brush centre) to relative spawn weight.
@export var brush_falloff: Curve:
	set(value):
		brush_falloff = value
		emit_changed()

@export_group("Instance Data")
## Minimum keep priority (0..1) written on placed instances. High defaults prioritise hand-authored
## instances over procedural ones when store density is lowered.
@export_range(0.0, 1.0, 0.01) var keep_min := 0.85:
	set(value):
		keep_min = clampf(value, 0.0, 1.0)
		emit_changed()
## Maximum keep priority (0..1).
@export_range(0.0, 1.0, 0.01) var keep_max := 1.0:
	set(value):
		keep_max = clampf(value, 0.0, 1.0)
		emit_changed()
## Whether placed instances write a per-instance colour or leave it absent (NaN -> object default).
@export var color_mode: ColorMode = ColorMode.NONE:
	set(value):
		color_mode = value
		emit_changed()
## First colour endpoint when [member color_mode] is not [constant ColorMode.NONE].
@export var color_min := Color.WHITE:
	set(value):
		color_min = value
		emit_changed()
## Second colour endpoint when [member color_mode] is not [constant ColorMode.NONE].
@export var color_max := Color.WHITE:
	set(value):
		color_max = value
		emit_changed()
## When on, writes [member custom_value] into the point's custom data (off writes NaN -> object default).
@export var write_custom := false:
	set(value):
		write_custom = value
		emit_changed()
## Custom data value written when [member write_custom] is on.
@export var custom_value := Color(0, 0, 0, 0):
	set(value):
		custom_value = value
		emit_changed()


## Samples [param curve] into a [PackedFloat32Array] LUT of [param steps] entries over 0..1.
static func sample_curve_lut(curve: Curve, steps := 32) -> PackedFloat32Array:
	var lut := PackedFloat32Array()
	if curve == null or steps < 2:
		return lut
	lut.resize(steps)
	for i in steps:
		lut[i] = maxf(0.0, curve.sample_baked(float(i) / float(steps - 1)))
	return lut


## Builds a flat spec dictionary consumed by [code]CopiaBrush.sample_dab()[/code] for [param object].
## [param overrides] may supply weight, band_curve, band_min, band_max, scale_multiplier,
## spacing_override.
func to_dab_spec(object: Resource, overrides := {}) -> Dictionary:
	var path := object.resource_path if object != null else ""
	var scale_mult := float(overrides.get("scale_multiplier", 1.0))
	var spacing := float(overrides.get("spacing_override", -1.0))
	if spacing < 0.0:
		spacing = min_spacing
	var curve: Curve = overrides.get("band_curve", brush_falloff)
	var default_alpha := 1.0
	if object != null and object.has_method("_get_default_color"):
		default_alpha = float((object._get_default_color() as Color).a)
	var spec := {
		"object_path": path,
		"weight": maxf(0.0, float(overrides.get("weight", 1.0))) * density,
		"band_curve": sample_curve_lut(curve),
		"band_min": float(overrides.get("band_min", 0.0)),
		"band_max": float(overrides.get("band_max", 1.0)),
		"min_spacing": maxf(0.0, spacing),
		"scale_min": maxf(0.001, minf(scale_min, scale_max) * scale_mult),
		"scale_max": maxf(0.001, maxf(scale_min, scale_max) * scale_mult),
		"scale_jitter": scale_jitter,
		"align_normal": align_to_normal,
		"random_yaw": random_yaw,
		"random_tilt_deg": random_tilt_deg,
		"slope_min_deg": minf(slope_min_deg, slope_max_deg),
		"slope_max_deg": maxf(slope_min_deg, slope_max_deg),
		"y_offset_min": minf(y_offset_min, y_offset_max),
		"y_offset_max": maxf(y_offset_min, y_offset_max),
		"keep_min": minf(keep_min, keep_max),
		"keep_max": maxf(keep_min, keep_max),
		"use_color": color_mode != ColorMode.NONE,
		"color_a": color_min,
		"color_b": color_max,
		"preserve_alpha": color_mode == ColorMode.TINT_RGB_PRESERVE_ALPHA,
		"default_alpha": default_alpha,
		"use_custom": write_custom,
		"custom": custom_value,
	}
	return spec
