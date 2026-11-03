@tool
class_name StrataMaterial
extends Resource
## Individually referenced source textures. No texture-array packing contract.
## ORMH channels: occlusion, roughness, metallic, height (0.5 = neutral).

var _watched_textures: Array[Texture2D] = []
var _source_profile: StrataMaterial
var _source_uv_multiplier := 1.0

@export var color_texture: Texture2D:
	set(value):
		if color_texture == value: return
		color_texture = value
		_watch_textures()
		emit_changed()
@export var normal_texture: Texture2D:
	set(value):
		if normal_texture == value: return
		normal_texture = value
		_watch_textures()
		emit_changed()
@export var ormh_texture: Texture2D:
	set(value):
		if ormh_texture == value: return
		ormh_texture = value
		_watch_textures()
		emit_changed()
## Texture repeats per terrain-local metre.
@export_range(0.001, 16.0, 0.001) var uv_scale := 0.25:
	set(value):
		if not is_finite(value) or value <= 0.0:
			push_warning("Terrain material UV scale must be finite and positive")
			return
		if uv_scale == value: return
		uv_scale = value
		emit_changed()
## Triplanar axis-weight exponent, shared by color, normal and ORMH maps.
## Larger values make the transitions between projection axes sharper.
@export_range(1.0, 64.0, 0.1) var triplanar_sharpness := 4.0:
	set(value):
		if not is_finite(value) or value < 1.0 or value > 64.0:
			push_warning("Terrain material triplanar sharpness must be finite and in [1, 64]")
			return
		if triplanar_sharpness == value: return
		triplanar_sharpness = value
		emit_changed()
## Which terrain-local axes the textures are projected along. Triplanar blends
## all three (default). Biplanar keeps the two dominant axes per fragment. Sides
## uses X and Z only, never from above or below (cliffs); a nearly flat surface
## falls back to a single side axis. Top is a single planar projection along Y.
enum ProjectionMode { TRIPLANAR, BIPLANAR, SIDES, TOP }
@export var projection: ProjectionMode = ProjectionMode.TRIPLANAR:
	set(value):
		if projection == value: return
		projection = value
		emit_changed()
@export_range(0.0, 8.0, 0.01) var displacement_strength := 1.0:
	set(value):
		if not is_finite(value) or value < 0.0:
			push_warning("Terrain material displacement strength must be finite and nonnegative")
			return
		if displacement_strength == value: return
		displacement_strength = value
		emit_changed()

## Texture-height influence on normalized material weights. Zero gives this
## material neutral gain; larger values let its peaks emerge. Only zero
## contrast for every selected material preserves the original mixture.
@export_range(0.0, 16.0, 0.1) var height_blend_contrast := 0.0:
	set(value):
		if not is_finite(value) or value < 0.0 or value > 16.0:
			push_warning("Terrain material height blend contrast must be finite and in [0, 16]")
			return
		if height_blend_contrast == value: return
		height_blend_contrast = value
		emit_changed()

## Centers this source's height distribution for weight competition only.
## It never offsets sampled displacement heights. Redistributing material
## weights can still change the resulting visual microdisplacement mixture.
@export_range(-0.5, 0.5, 0.01) var height_blend_bias := 0.0:
	set(value):
		if not is_finite(value) or value < -0.5 or value > 0.5:
			push_warning("Terrain material height blend bias must be finite and in [-0.5, 0.5]")
			return
		if height_blend_bias == value: return
		height_blend_bias = value
		emit_changed()

## Linear remap of packed green-channel perceptual roughness before blending.
## Identity defaults preserve existing materials and their normal maps.
@export_range(0.0, 2.0, 0.01) var roughness_scale := 1.0:
	set(value):
		if not is_finite(value) or value < 0.0 or value > 2.0:
			push_warning("Terrain material roughness scale must be finite and in [0, 2]")
			return
		if roughness_scale == value: return
		roughness_scale = value
		emit_changed()
@export_range(-1.0, 1.0, 0.01) var roughness_bias := 0.0:
	set(value):
		if not is_finite(value) or value < -1.0 or value > 1.0:
			push_warning("Terrain material roughness bias must be finite and in [-1, 1]")
			return
		if roughness_bias == value: return
		roughness_bias = value
		emit_changed()

## Gameplay surface tag of this material, the analogue of a physical material: footsteps,
## impacts and similar effects read it through StrataTerrain3D.runtime_surface_type() or
## StrataCollision.surface_type_at(). Rendering ignores it; empty means untagged.
@export var surface_type: StringName = &"":
	set(value):
		if surface_type == value: return
		surface_type = value
		emit_changed()
@export_group("Top Layer", "top_")
## Optional texture set for the upward projection: where this material projects
## along +Y (triplanar, biplanar or top), the top set replaces color, normal and
## ORMH, including the ORMH height used for height blending and displacement.
## Downward (-Y) and side projections keep the main set. Leave empty (the
## default) to project the main set on every axis, exactly as before. Needs a
## free renderer texture slot per top set (material count + top sets <= 32).
@export var top_color_texture: Texture2D:
	set(value):
		if top_color_texture == value: return
		top_color_texture = value
		_watch_textures()
		emit_changed()
@export var top_normal_texture: Texture2D:
	set(value):
		if top_normal_texture == value: return
		top_normal_texture = value
		_watch_textures()
		emit_changed()
@export var top_ormh_texture: Texture2D:
	set(value):
		if top_ormh_texture == value: return
		top_ormh_texture = value
		_watch_textures()
		emit_changed()
## Top-set repeats per terrain-local metre; 0 (the default) uses uv_scale.
@export_range(0.0, 16.0, 0.001) var top_uv_scale := 0.0:
	set(value):
		if not is_finite(value) or value < 0.0:
			push_warning("Terrain material top UV scale must be finite and not negative")
			return
		if top_uv_scale == value: return
		top_uv_scale = value
		emit_changed()
@export_group("Custom Shader", "custom_")
## Optional GLSL statements that adjust this material in the terrain's fragment
## shader, for example a fresnel rim. They become the body of
## [code]void strata_material_<id>(inout StrataSurface s, in StrataContext c)[/code]:
## modify [code]s.albedo[/code], [code]s.normal[/code], [code]s.roughness[/code],
## [code]s.metallic[/code], [code]s.ao[/code] or [code]s.emission[/code], reading
## [code]c.view[/code], [code]c.position[/code], [code]c.weight[/code] and the other
## context fields. The result is blended with the other materials by weight.
## Empty (the default) keeps the plain terrain shader. Code that does not
## compile is reported and this material renders without it.
@export_multiline var custom_fragment_code := "":
	set(value):
		if custom_fragment_code == value: return
		custom_fragment_code = value
		emit_changed()
## Values for [member custom_fragment_code], by name. Each entry becomes a
## local variable of that name in the code; changing a value needs no shader
## recompile. Names are snake_case GLSL identifiers; values are float, int,
## bool, Vector2, Vector3, Vector4 or Color (a linear vec4 in the shader).
## Assign a new dictionary (or call [method Resource.emit_changed]) after
## editing it from a script.
@export var custom_fragment_parameters: Dictionary = {}:
	set(value):
		custom_fragment_parameters = value.duplicate()
		emit_changed()

## A UV variant shares textures and follows its source profile's edits. Saving
## a variant stores its current exported values as an independent snapshot.
## Source edits overwrite variant-specific controls; use a separate resource
## when a material slot needs independent settings.
func make_variant(uv_multiplier: float = 1.0) -> StrataMaterial:
	if not is_finite(uv_multiplier) or uv_multiplier <= 0.0 or not is_finite(uv_scale * uv_multiplier):
		push_warning("Terrain material variant UV multiplier must be finite and positive")
		return null
	var variant := duplicate() as StrataMaterial
	variant._source_profile = self
	variant._source_uv_multiplier = uv_multiplier
	variant._sync_source_profile()
	# Method connections do not retain their target; Godot disconnects them when
	# the variant is freed. Only the variant keeps its source profile alive.
	changed.connect(variant._sync_source_profile)
	return variant

func _sync_source_profile() -> void:
	if _source_profile == null: return
	color_texture = _source_profile.color_texture
	normal_texture = _source_profile.normal_texture
	ormh_texture = _source_profile.ormh_texture
	top_color_texture = _source_profile.top_color_texture
	top_normal_texture = _source_profile.top_normal_texture
	top_ormh_texture = _source_profile.top_ormh_texture
	top_uv_scale = _source_profile.top_uv_scale * _source_uv_multiplier
	uv_scale = _source_profile.uv_scale * _source_uv_multiplier
	triplanar_sharpness = _source_profile.triplanar_sharpness
	projection = _source_profile.projection
	displacement_strength = _source_profile.displacement_strength
	height_blend_contrast = _source_profile.height_blend_contrast
	height_blend_bias = _source_profile.height_blend_bias
	roughness_scale = _source_profile.roughness_scale
	roughness_bias = _source_profile.roughness_bias
	custom_fragment_code = _source_profile.custom_fragment_code
	if custom_fragment_parameters != _source_profile.custom_fragment_parameters:
		custom_fragment_parameters = _source_profile.custom_fragment_parameters

func _watch_textures() -> void:
	for texture in _watched_textures:
		if texture.changed.is_connected(_texture_changed): texture.changed.disconnect(_texture_changed)
	_watched_textures.clear()
	for texture in [color_texture, normal_texture, ormh_texture, top_color_texture, top_normal_texture, top_ormh_texture]:
		if texture != null and not _watched_textures.has(texture):
			_watched_textures.append(texture)
			texture.changed.connect(_texture_changed)

## True when the top layer is in use (a top colour texture is set).
func has_top_textures() -> bool:
	return top_color_texture != null

func _texture_changed() -> void:
	emit_changed()
