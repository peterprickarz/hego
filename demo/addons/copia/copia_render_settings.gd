@tool
class_name CopiaRenderSettings
extends Resource
## How the instances of a [CopiaObject] are drawn. Variations of one thing share one settings
## resource. Only [member draw_mode] and [member batch_size] are build inputs; every other
## property applies when a cell loads and needs no build. The far grid's cell size, which holds
## the impostor batches, is a property of the store ([member CopiaStore3D.impostor_cell_size]).

enum DrawMode {
	## One MultiMesh per batch cell: the instances of a batch are drawn together.
	MULTIMESH,
	## One rendering instance per instance. For few, large things that need their own
	## visibility range and culling.
	INSTANCE,
}

enum FadeMode {
	## No fade at the end of the visibility range.
	DISABLED,
	## Godot's own visibility range fade. In Forward+ a fading instance is drawn in the
	## transparent pass. Applies to [constant DrawMode.MULTIMESH] only; with
	## [constant DrawMode.INSTANCE] it is ignored.
	SELF,
}

enum Shadow {
	## Instances cast shadows.
	ON,
	## Instances cast no shadows.
	OFF,
	## Shadows are drawn from the lowest LOD of the mesh by a second, shadows-only instance.
	LOW_LOD,
}

## Emitted when a property that changes what the build produces is set: [member draw_mode] or
## [member batch_size]. [signal Resource.changed] is emitted too.
signal build_inputs_changed

## How instances are drawn. A build input.
@export var draw_mode: DrawMode = DrawMode.MULTIMESH:
	set(value):
		if draw_mode == value: return
		draw_mode = value
		_changed(true)
## Distance in metres from the camera at which the instances start to be drawn.
@export_range(0.0, 100000.0, 0.1, "or_greater", "suffix:m") var visibility_range_begin := 0.0:
	set(value):
		visibility_range_begin = maxf(value, 0.0)
		_changed(false)
## Distance in metres from the camera at which the instances stop being drawn. 0 is unlimited.
@export_range(0.0, 100000.0, 0.1, "or_greater", "suffix:m") var visibility_range_end := 0.0:
	set(value):
		visibility_range_end = maxf(value, 0.0)
		_changed(false)
## Hysteresis in metres applied to both range limits, so an instance does not flicker at the edge.
@export_range(0.0, 1000.0, 0.1, "or_greater", "suffix:m") var visibility_range_margin := 0.0:
	set(value):
		visibility_range_margin = maxf(value, 0.0)
		_changed(false)
## Fade at the end of the visibility range. In Forward+ a fading instance is drawn in the
## transparent pass. Applies to [constant DrawMode.MULTIMESH] only.
@export var fade_mode: FadeMode = FadeMode.DISABLED:
	set(value):
		fade_mode = value
		_changed(false)
## Whether instances cast shadows, and from which LOD.
@export var shadow: Shadow = Shadow.ON:
	set(value):
		shadow = value
		_changed(false)
## Distance in metres from the camera within which shadows are drawn. 0 is unlimited.
@export_range(0.0, 100000.0, 0.1, "or_greater", "suffix:m") var shadow_range := 0.0:
	set(value):
		shadow_range = maxf(value, 0.0)
		_changed(false)
## Hysteresis in metres on [member shadow_range]: shadows turn on within [member shadow_range] of
## a source with shadows and off only beyond [member shadow_range] + this margin of every such
## source, so an object near the boundary does not flicker while a source hovers there. 0 switches
## exactly at [member shadow_range].
@export_range(0.0, 1000.0, 0.1, "or_greater", "suffix:m") var shadow_range_margin := 0.0:
	set(value):
		shadow_range_margin = maxf(value, 0.0)
		_changed(false)
## Multiplier on the distance at which the mesh's LODs switch. Above 1 keeps detail longer.
@export_range(0.01, 16.0, 0.01, "or_greater") var lod_bias := 1.0:
	set(value):
		lod_bias = maxf(value, 0.01)
		_changed(false)
## Edge length in metres of a batch cell. It must divide the store's cell size. Smaller batches
## cull more tightly and need more draw calls. A build input.
@export_range(1.0, 1024.0, 0.5, "or_greater", "suffix:m") var batch_size := 16.0:
	set(value):
		if is_equal_approx(batch_size, value): return
		batch_size = value
		_changed(true)
## Extra margin in metres added to each batch's bounds when culling.
@export_range(0.0, 1000.0, 0.1, "or_greater", "suffix:m") var extra_cull_margin := 0.0:
	set(value):
		extra_cull_margin = maxf(value, 0.0)
		_changed(false)
## Render layers the instances are drawn on.
@export_flags_3d_render var layers := 1:
	set(value):
		layers = value
		_changed(false)
## How the instances take part in global illumination.
@export var gi_mode: GeometryInstance3D.GIMode = GeometryInstance3D.GI_MODE_STATIC:
	set(value):
		gi_mode = value
		_changed(false)
## Distance in metres from the camera beyond which the impostor is no longer drawn. 0 is
## unlimited. Only used by objects with an impostor mesh.
@export_range(0.0, 100000.0, 1.0, "or_greater", "suffix:m") var impostor_range_end := 0.0:
	set(value):
		impostor_range_end = maxf(value, 0.0)
		_changed(false)


## The values the drawer applies when it creates rendering objects. [code]fade_mode[/code] and
## [code]cast_shadows[/code] are [RenderingServer] enum values. A [constant Shadow.LOW_LOD]
## object draws with [code]cast_shadows[/code] off and [code]low_lod_shadows[/code] true: the
## drawer adds the shadows-only instance.
func draw_params() -> Dictionary:
	var fade := RenderingServer.VISIBILITY_RANGE_FADE_DISABLED
	if fade_mode == FadeMode.SELF and draw_mode == DrawMode.MULTIMESH:
		fade = RenderingServer.VISIBILITY_RANGE_FADE_SELF
	var cast := RenderingServer.SHADOW_CASTING_SETTING_ON
	if shadow != Shadow.ON:
		cast = RenderingServer.SHADOW_CASTING_SETTING_OFF
	return {
		"visibility_begin": visibility_range_begin,
		"visibility_end": visibility_range_end,
		"visibility_begin_margin": visibility_range_margin,
		"visibility_end_margin": visibility_range_margin,
		"fade_mode": fade,
		"cast_shadows": cast,
		"low_lod_shadows": shadow == Shadow.LOW_LOD,
		"shadow_range": shadow_range,
		"shadow_range_margin": shadow_range_margin,
		"lod_bias": lod_bias,
		"layers": layers,
		"gi_mode": gi_mode,
		"extra_cull_margin": extra_cull_margin,
	}


func _changed(build_input: bool) -> void:
	emit_changed()
	if build_input:
		build_inputs_changed.emit()
