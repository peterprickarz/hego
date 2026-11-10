@tool
class_name StrataSurfaceCache
extends RefCounted
## Camera-centred clipmap of the resolved terrain surface (a runtime "virtual texture"), filled
## on the GPU from the terrain material by a compute shader that splices the same shader
## includes as terrain_surface.gdshader. See "Surface cache" in docs/strata/reference.md.
##
## Level k has resolution² cells of texel·2^k metres in terrain-local XZ. Cell g (integer grid
## index) lives at texel g & (resolution - 1), so the window scrolls toroidally: when the camera
## moves only the newly exposed strips are evaluated. Three Texture2DArrayRD hold, per level:
##   albedo  RGBA8   sRGB-encoded albedo after the macro tint (centre of cell), A ambient occlusion
##   normal  RGBA8   octahedral terrain-local normal (RG, Y up), B roughness, A metallic
##   height  R32F    layer 2k: base height at the cell corner g * texel (-1e30 in holes),
##                   layer 2k+1: material relief there (terrain_material_relief(), metres along the
##                   normal, before displacement_strength and the camera fade)
##   cover   R8      how much of the cell surface writers replaced (StrataSurfaceWriter; 0 none)
## Surface writers (meshes with a writer material, StrataSurfaceWriter) are drawn top-down by a
## writer pass (strata_surface_writer_pass.gd) and composited over the terrain material by the
## same compute fill, one frame after the pass drew them.
## The cache holds the near-UV material without custom fragment code (both depend on the view).
##
## StrataRenderer owns one cache per terrain (StrataRenderSettings.surface_cache_enabled). It
## binds the height array to its own shader for displacement and, when publish_globals is set,
## publishes everything as the strata_cache_* global shader parameters read by
## shaders/strata_surface_cache.gdshaderinc. Needs Forward+ or Mobile (a RenderingDevice).

const MAX_LEVELS := 8
## Window origins snap to this many cells, so strips are at least this wide.
const SNAP := 16
## Cells next to the window edge that readers must not use (linear filtering, late strips).
const MARGIN := 2
## Origin published for a level that holds no valid data.
const INVALID_ORIGIN := 1.0e9
const GLOBAL_PARAMETERS := {
	"strata_cache_albedo": RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2DARRAY,
	"strata_cache_normal": RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2DARRAY,
	"strata_cache_height": RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2DARRAY,
	# texel (m) of level 0, resolution, level count, 1 when enabled
	"strata_cache_params": RenderingServer.GLOBAL_VAR_TYPE_VEC4,
	# window origins (cells) of levels 0-1, 2-3, 4-5, 6-7
	"strata_cache_windows_a": RenderingServer.GLOBAL_VAR_TYPE_VEC4,
	"strata_cache_windows_b": RenderingServer.GLOBAL_VAR_TYPE_VEC4,
	"strata_cache_windows_c": RenderingServer.GLOBAL_VAR_TYPE_VEC4,
	"strata_cache_windows_d": RenderingServer.GLOBAL_VAR_TYPE_VEC4,
	# terrain-local camera position, displacement radius (0: no displacement)
	"strata_cache_camera": RenderingServer.GLOBAL_VAR_TYPE_VEC4,
	# displacement strength, terrain specular, relief level (cells = displaced vertex spacing; -1 none), 0
	"strata_cache_surface": RenderingServer.GLOBAL_VAR_TYPE_VEC4,
	"strata_cache_world_to_local": RenderingServer.GLOBAL_VAR_TYPE_TRANSFORM,
}

const _SHADER_DIR := "res://addons/strata/shaders/"
const _INCLUDES := ["terrain_regions", "terrain_controls", "terrain_texture_dispatch", "terrain_normals", "terrain_height_blend", "terrain_triplanar", "terrain_surface_core"]
const _MATERIAL_ARRAYS := ["uv_scales", "top_texture_slots", "top_uv_scales", "triplanar_sharpnesses", "projection_modes", "material_displacement", "height_blend_contrasts", "height_blend_biases", "material_roughness_scales", "material_roughness_biases"]
const _INT_ARRAYS := ["top_texture_slots", "projection_modes"]
## Scalar uniforms read by the includes, in the float/int slots of the parameter buffer.
const _FLOAT_SLOTS := {"region_origin": 0, "region_extent": 2, "region_spacing": 3, "field_origin": 4, "field_size": 6, "crease_cosine": 8, "terrain_tint_strength": 9, "terrain_ao_strength": 10, "far_uv_factor": 11}
const _INT_SLOTS := {"region_cells": 0, "region_grid": 1, "region_lattice": 3, "height_scale": 5, "height_apron": 6, "material_ids_scale": 7, "material_ids_apron": 8, "holes_scale": 9, "holes_apron": 10, "macro_scale": 11, "macro_apron": 12, "far_level": 13, "coarse_level": 14, "has_far_tier": 15, "has_coarse_maps": 16, "has_material_maps": 17, "has_holes": 18, "has_terrain_macro_map": 19, "height_blend_enabled": 20, "triangle_height_sampling": 21, "smooth_shading": 22}
const _VECTOR_UNIFORMS := ["region_origin", "field_origin", "field_size", "region_grid", "region_lattice"]
## Sampled maps after the three material arrays (bindings 3-18): name, filter (0 nearest, 1 linear).
const _MAP_BINDINGS := [["region_table", 0], ["height_regions", 1], ["material_ids_regions", 0], ["material_weights_regions", 0], ["holes_regions", 0], ["macro_regions", 1], ["height_far_regions", 1], ["material_ids_far_regions", 0], ["material_weights_far_regions", 0], ["holes_far_regions", 0], ["macro_far_regions", 1], ["coarse_height", 1], ["coarse_material_ids", 0], ["coarse_material_weights", 0], ["coarse_holes", 0], ["coarse_macro", 1]]

const _GLSL_PRELUDE := """
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D color_maps[32];
layout(set = 0, binding = 1) uniform sampler2D normal_maps[32];
layout(set = 0, binding = 2) uniform sampler2D ormh_maps[32];
layout(set = 0, binding = 3) uniform sampler2D region_table;
layout(set = 0, binding = 4) uniform sampler2DArray height_regions;
layout(set = 0, binding = 5) uniform sampler2DArray material_ids_regions;
layout(set = 0, binding = 6) uniform sampler2DArray material_weights_regions;
layout(set = 0, binding = 7) uniform sampler2DArray holes_regions;
layout(set = 0, binding = 8) uniform sampler2DArray macro_regions;
layout(set = 0, binding = 9) uniform sampler2DArray height_far_regions;
layout(set = 0, binding = 10) uniform sampler2DArray material_ids_far_regions;
layout(set = 0, binding = 11) uniform sampler2DArray material_weights_far_regions;
layout(set = 0, binding = 12) uniform sampler2DArray holes_far_regions;
layout(set = 0, binding = 13) uniform sampler2DArray macro_far_regions;
layout(set = 0, binding = 14) uniform sampler2D coarse_height;
layout(set = 0, binding = 15) uniform sampler2D coarse_material_ids;
layout(set = 0, binding = 16) uniform sampler2D coarse_material_weights;
layout(set = 0, binding = 17) uniform sampler2D coarse_holes;
layout(set = 0, binding = 18) uniform sampler2D coarse_macro;
layout(set = 0, binding = 19, std430) restrict readonly buffer Parameters {
	float uv_scales[32]; int top_texture_slots[32]; float top_uv_scales[32]; float triplanar_sharpnesses[32];
	int projection_modes[32]; float material_displacement[32]; float height_blend_contrasts[32]; float height_blend_biases[32];
	float material_roughness_scales[32]; float material_roughness_biases[32];
	float pf[32]; int pi[32];
};
layout(set = 0, binding = 20, rgba8) restrict writeonly uniform image2DArray albedo_out;
layout(set = 0, binding = 21, rgba8) restrict writeonly uniform image2DArray normal_out;
layout(set = 0, binding = 22, r32f) restrict writeonly uniform image2DArray height_out;
layout(set = 0, binding = 23, r8) restrict writeonly uniform image2DArray cover_out;
// Writer pass tile (strata_surface_writer_pass.gd), premultiplied over-composite of the writers,
// three outputs side by side (fill.tile_width texels each):
//   0 albedo   linear albedo, A coverage
//   1 normal   ground-space normal xz * 0.5 + 0.5, roughness, A coverage
//   2 surface  AO, relief * 0.25 + 0.5, metallic, A coverage
layout(set = 1, binding = 0) uniform sampler2D writer_tile;
layout(push_constant, std430) uniform Fill { ivec2 rect_origin; ivec2 rect_size; int level; int resolution; float texel; int writers; ivec2 tile_origin; int tile_width; int pad; } fill;
#define writer_albedo_at(t) texelFetch(writer_tile, (t), 0)
#define writer_normal_at(t) texelFetch(writer_tile, (t) + ivec2(fill.tile_width, 0), 0)
#define writer_surface_at(t) texelFetch(writer_tile, (t) + ivec2(2 * fill.tile_width, 0), 0)

// The includes read the terrain shader's uniforms by name; these map them to the buffer.
#define region_origin vec2(pf[0], pf[1])
#define region_extent pf[2]
#define region_spacing pf[3]
#define field_origin vec2(pf[4], pf[5])
#define field_size vec2(pf[6], pf[7])
#define crease_cosine pf[8]
#define terrain_tint_strength pf[9]
#define terrain_ao_strength pf[10]
#define far_uv_factor pf[11]
#define region_cells pi[0]
#define region_grid ivec2(pi[1], pi[2])
#define region_lattice ivec2(pi[3], pi[4])
#define height_scale pi[5]
#define height_apron pi[6]
#define material_ids_scale pi[7]
#define material_ids_apron pi[8]
#define holes_scale pi[9]
#define holes_apron pi[10]
#define macro_scale pi[11]
#define macro_apron pi[12]
#define far_level pi[13]
#define coarse_level pi[14]
#define has_far_tier (pi[15] != 0)
#define has_coarse_maps (pi[16] != 0)
#define has_material_maps (pi[17] != 0)
#define has_holes (pi[18] != 0)
#define has_terrain_macro_map (pi[19] != 0)
#define height_blend_enabled (pi[20] != 0)
#define triangle_height_sampling (pi[21] != 0)
#define smooth_shading (pi[22] != 0)
"""

const _GLSL_MAIN := """
vec3 cache_linear_to_srgb(vec3 c) {
	c = clamp(c, vec3(0.0), vec3(1.0));
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

// Octahedral encoding around +Y (the terrain up axis), mapped to 0..1.
vec2 cache_octahedral(vec3 n) {
	n /= abs(n.x) + abs(n.y) + abs(n.z);
	vec2 e = n.xz;
	if (n.y < 0.0) { e = (vec2(1.0) - abs(e.yx)) * vec2(e.x >= 0.0 ? 1.0 : -1.0, e.y >= 0.0 ? 1.0 : -1.0); }
	return e * 0.5 + 0.5;
}

// Writer coverage-weighted sum of a tile texel (premultiplied: rgb is the sum of value * weight).
vec4 writer_fetch_surface_corner(ivec2 t) {
	return 0.25 * (writer_surface_at(t) + writer_surface_at(t - ivec2(1, 0)) + writer_surface_at(t - ivec2(0, 1)) + writer_surface_at(t - ivec2(1, 1)));
}

void main() {
	ivec2 local = ivec2(gl_GlobalInvocationID.xy);
	if (local.x >= fill.rect_size.x || local.y >= fill.rect_size.y) { return; }
	ivec2 cell = fill.rect_origin + local;
	ivec3 store = ivec3(cell & ivec2(fill.resolution - 1), fill.level);
	float texel = fill.texel;
	// Colour, normal and ORM at the cell centre with a footprint of one cell, so the material
	// mip matches the level (128 texels/m material on a 1/128 m level 0 is copied texel for texel).
	vec2 centre = (vec2(cell) + vec2(0.5)) * texel;
	vec2 smooth_gradient = terrain_smooth_gradient(centre);
	vec3 projection_normal = normalize(vec3(-smooth_gradient.x, 1.0, -smooth_gradient.y));
	vec3 base_point = vec3(centre.x, base_height(centre), centre.y);
	vec3 point_dx = vec3(texel, smooth_gradient.x * texel, 0.0);
	vec3 point_dy = vec3(0.0, smooth_gradient.y * texel, texel);
	vec2 gradient = base_shading_gradient(centre, smooth_gradient);
	vec3 geometric_normal = normalize(vec3(-gradient.x, 1.0, -gradient.y));
	vec3 color; vec3 orm; vec3 normal; float discarded;
	terrain_surface_evaluate(centre, base_point, point_dx, point_dy, projection_normal, geometric_normal, 0.0, color, orm, normal, discarded);
	vec4 macro = terrain_macro_sample(centre);
	color *= mix(vec3(1.0), macro.rgb, terrain_tint_strength);
	float ao = clamp(orm.r, 0.0, 1.0) * mix(1.0, macro.a, terrain_ao_strength);
	float roughness = clamp(orm.g, 0.04, 1.0);
	float metallic = clamp(orm.b, 0.0, 1.0);
	float cover = 0.0;
	ivec2 tile = cell - fill.tile_origin;
	if (fill.writers != 0) {
		// Writers over the finished terrain surface (after the macro tint: writers keep their colour).
		vec4 wa = writer_albedo_at(tile);
		vec4 wn = writer_normal_at(tile);
		vec4 ws = writer_surface_at(tile);
		color = color * (1.0 - wa.a) + max(wa.rgb, vec3(0.0));
		if (wn.a > 0.0001) {
			// Ground-space detail (Y up over flat ground) laid onto the terrain's lighting normal,
			// as the top projection's normal maps are: tangent x = +X, image up = -Z.
			vec2 xz = clamp((wn.rg - 0.5 * wn.a) * 2.0 / wn.a, vec2(-1.0), vec2(1.0));
			vec3 detail = vec3(xz.x, -xz.y, sqrt(max(0.0, 1.0 - dot(xz, xz))));
			vec3 written = terrain_reoriented_normal(terrain_triplanar_frame(1, geometric_normal), geometric_normal, detail);
			normal = normalize(mix(normal, normalize(written), clamp(wn.a, 0.0, 1.0)));
			roughness = clamp(roughness * (1.0 - wn.a) + wn.b, 0.04, 1.0);
		}
		ao = clamp(ao * (1.0 - ws.a) + ws.r, 0.0, 1.0);
		metallic = clamp(metallic * (1.0 - ws.a) + ws.b, 0.0, 1.0);
		cover = clamp(max(wa.a, max(wn.a, ws.a)), 0.0, 1.0);
	}
	imageStore(albedo_out, store, vec4(cache_linear_to_srgb(color), ao));
	imageStore(normal_out, store, vec4(cache_octahedral(normal), roughness, metallic));
	imageStore(cover_out, store, vec4(cover));
	// Heights at the cell corner: displaced vertices on the level's lattice read their own value.
	vec2 corner = vec2(cell) * texel;
	vec2 corner_gradient = terrain_smooth_gradient(corner);
	vec3 corner_normal = normalize(vec3(-corner_gradient.x, 1.0, -corner_gradient.y));
	float corner_height = base_height(corner);
	float relief = terrain_material_relief(vec3(corner.x, corner_height, corner.y), corner_normal, 0.0);
	if (fill.writers != 0) {
		vec4 ws = writer_fetch_surface_corner(tile);
		if (ws.a > 0.0001) { relief = relief * (1.0 - ws.a) + (ws.g - 0.5 * ws.a) * 4.0; }
	}
	bool hole = has_holes && terrain_cell_hole(corner);
	imageStore(height_out, ivec3(store.xy, fill.level * 2), vec4(hole ? -1.0e30 : corner_height));
	imageStore(height_out, ivec3(store.xy, fill.level * 2 + 1), vec4(hole ? 0.0 : relief));
}
"""

## Cell edge of level 0 in metres (1 / texels per metre).
var texel := 1.0 / 128.0
var resolution := 1024
var levels := 6
var publish_globals := true
## Full-window refills (start, teleports, material edits) evaluated per frame, finest first.
var full_fills_per_frame := 1
## Records GPU timestamps around the fill: stats.gpu_ms is the GPU time of the last fill that
## did work (two frames late), stats.gpu_ms_total the sum over all fills.
var measure_gpu := false
var albedo_texture := Texture2DArrayRD.new()
var normal_texture := Texture2DArrayRD.new()
var height_texture := Texture2DArrayRD.new()
## R8 per level: writer coverage of each cell (read by the terrain shader).
var cover_texture := Texture2DArrayRD.new()

var _rd: RenderingDevice
var _textures: Array[RID] = []
var _texture_key := ""
var _shader := RID()
var _pipeline := RID()
var _shader_key := ""
var _samplers: Array[RID] = []
var _sampler_key := ""
var _params := RID()
var _uniform_set := RID()
var _uniform_key := ""
## Per level: published window origin (cells), whether it holds valid data, whether a full
## refill is pending, pending rects (cells) to refill.
var _origins: Array[Vector2i] = []
var _valid: Array[bool] = []
var _needs_full: Array[bool] = []
var _pending: Array = []
## Per level: rects where writers changed (refilled once the writer pass has drawn them).
var _writer_pending: Array = []
var _writer_sets := {}
var _writer_fallback_set := RID()
var _material_signature := ""
var _parameter_bytes := PackedByteArray()
var _parameter_dirty := true
var _maps: Dictionary = {}
var _defines := ""
var _failed := false
var _textures_dirty := true
var _globals_owner := false
var _fallbacks: Array[RID] = []
var _globals_checked := -1
## Last value sent per global parameter.
var _published := {}
var stats := {"levels": 0, "resolution": 0, "texels_last_frame": 0, "dispatches_last_frame": 0, "full_fills": 0, "memory_mb": 0.0, "status": "Not configured", "gpu_ms": 0.0, "gpu_ms_total": 0.0, "gpu_samples": 0}
var _timestamp_frame := 0


## True when a RenderingDevice exists (Forward+ or Mobile; not Compatibility or headless).
static func available() -> bool:
	return RenderingServer.get_rendering_device() != null and DisplayServer.get_name() != "headless"


## Adds the strata_cache_* global shader parameters to the project settings when missing, so
## shaders including strata_surface_cache.gdshaderinc compile. Returns true when it added any;
## the editor must save the project settings for exported games.
static func register_project_globals() -> bool:
	var added := false
	for name: String in GLOBAL_PARAMETERS:
		var key := "shader_globals/" + name
		if ProjectSettings.has_setting(key): continue
		var type_name := _global_type_name(int(GLOBAL_PARAMETERS[name]))
		var value: Variant = "" if type_name.begins_with("sampler") else (Transform3D.IDENTITY if type_name == "transform" else Vector4.ZERO)
		ProjectSettings.set_setting(key, {"type": type_name, "value": value})
		if not RenderingServer.global_shader_parameter_get_list().has(StringName(name)):
			RenderingServer.global_shader_parameter_add(name, int(GLOBAL_PARAMETERS[name]), null if type_name.begins_with("sampler") else value)
		added = true
	return added


static func _global_type_name(type: int) -> String:
	match type:
		RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2DARRAY: return "sampler2DArray"
		RenderingServer.GLOBAL_VAR_TYPE_VEC4: return "vec4"
		RenderingServer.GLOBAL_VAR_TYPE_TRANSFORM: return "transform"
	return "float"


## Sets the layout; changing it reallocates the textures and refills every level.
func configure(level_count: int, cells: int, texels_per_metre: float) -> bool:
	level_count = clampi(level_count, 1, MAX_LEVELS)
	cells = clampi(nearest_po2(cells), 64, 4096)
	if not is_finite(texels_per_metre) or texels_per_metre <= 0.0: return false
	levels = level_count
	resolution = cells
	texel = 1.0 / texels_per_metre
	var key := "%d|%d|%f" % [levels, resolution, texel]
	if key != _texture_key:
		_texture_key = key
		_origins.resize(levels); _valid.resize(levels); _needs_full.resize(levels); _pending.resize(levels); _writer_pending.resize(levels)
		for k in levels:
			_origins[k] = Vector2i(2147483647, 2147483647)
			_valid[k] = false; _needs_full[k] = true; _pending[k] = []; _writer_pending[k] = []
		_textures_dirty = true
	stats.levels = levels
	stats.resolution = resolution
	stats.memory_mb = levels * resolution * resolution * 17.0 / 1048576.0
	return true


## Texel edge (m) of a level.
func level_texel(level: int) -> float:
	return texel * float(1 << level)


## First cell of a level's window (a huge value when it holds no data).
func level_origin(level: int) -> Vector2i:
	if _failed or level < 0 or level >= levels or not _valid[level]: return Vector2i(int(INVALID_ORIGIN), int(INVALID_ORIGIN))
	return _origins[level]


## The terrain-local XZ rectangle a level holds valid data for (empty while unfilled).
func level_rect(level: int) -> Rect2:
	if _failed or level < 0 or level >= levels or not _valid[level]: return Rect2()
	var size := level_texel(level)
	return Rect2(Vector2(_origins[level] + Vector2i(MARGIN, MARGIN)) * size, Vector2.ONE * (resolution - 2 * MARGIN) * size)


## Marks terrain-local [param rect] for re-evaluation in every level, or everything when empty.
## Content stays readable (stale) until refilled.
func invalidate(rect := Rect2()) -> void:
	for k in levels:
		if not rect.has_area():
			_needs_full[k] = true
			continue
		var size := level_texel(k)
		var first := Vector2i(floori(rect.position.x / size) - 1, floori(rect.position.y / size) - 1)
		var last := Vector2i(ceili(rect.end.x / size) + 1, ceili(rect.end.y / size) + 1)
		(_pending[k] as Array).append(Rect2i(first, last - first))


## Surface writers changed over terrain-local [param rect]: refilled in every level once the
## writer pass has drawn the rect, keeping the old content readable until then (no flicker).
func invalidate_writers(rect: Rect2) -> void:
	if not rect.has_area(): return
	for k in levels:
		var size := level_texel(k)
		var first := Vector2i(floori(rect.position.x / size) - 1, floori(rect.position.y / size) - 1)
		var last := Vector2i(ceili(rect.end.x / size) + 1, ceili(rect.end.y / size) + 1)
		(_writer_pending[k] as Array).append(Rect2i(first, last - first))


## Material uniforms changed: re-read them on the next update and refill when they differ.
func mark_material_dirty() -> void:
	_parameter_dirty = true


## Advances the cache for [param camera] (terrain-local) from the terrain's [param material]
## (the StrataRenderer ShaderMaterial; [param defines] its variant defines). Records the compute
## work on the render thread and returns true when every level is valid.
func update(material: ShaderMaterial, defines: String, camera: Vector3, writers: Node = null) -> bool:
	if _failed or material == null or material.shader == null: return false
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
		if _rd == null:
			_failed = true
			stats.status = "No RenderingDevice (Compatibility renderer or headless)"
			return false
	if _parameter_dirty:
		_parameter_dirty = false
		_gather_material(material)
	if defines != _defines:
		_defines = defines
		_needs_full.fill(true)
	var work := []
	var full_budget := full_fills_per_frame
	var texels := 0
	# Tiles the writer pass drew last frame: composited after this frame's plain fills.
	var ready: Array = writers.call("take_ready") if writers != null else []
	for k in levels:
		var size := level_texel(k)
		var snapped := Vector2i(floori(camera.x / (size * SNAP)) * SNAP, floori(camera.z / (size * SNAP)) * SNAP)
		var origin := snapped - Vector2i(resolution / 2, resolution / 2)
		var window := Rect2i(origin, Vector2i(resolution, resolution))
		var previous: Vector2i = _origins[k]
		var shifted := origin != previous
		if _needs_full[k] or (not _valid[k] and shifted) or absi(origin.x - previous.x) >= resolution or absi(origin.y - previous.y) >= resolution:
			if full_budget <= 0:
				# Out of budget: a valid level keeps its old window until its turn (no scroll).
				if not _valid[k]: _origins[k] = origin
				continue
			full_budget -= 1
			work.append([k, window])
			_origins[k] = origin
			_valid[k] = true
			_needs_full[k] = false
			_pending[k] = []
			_writer_pending[k] = []
			texels += resolution * resolution
			stats.full_fills = int(stats.full_fills) + 1
			# Plain terrain now, writers composited once the pass has drawn them.
			if writers != null: writers.call("queue_rect", k, window)
			continue
		if shifted:
			for strip: Rect2i in _exposed(Rect2i(previous, window.size), window):
				work.append([k, strip])
				texels += strip.get_area()
				if writers != null: writers.call("queue_rect", k, strip)
			_origins[k] = origin
		for rect: Rect2i in _pending[k]:
			var clipped := rect.intersection(window)
			if clipped.has_area():
				work.append([k, clipped])
				texels += clipped.get_area()
				if writers != null: writers.call("queue_rect", k, clipped)
		_pending[k] = []
		for rect: Rect2i in _writer_pending[k]:
			var clipped := rect.intersection(window)
			if not clipped.has_area(): continue
			# Removed writers leave plain terrain: refill now. Otherwise keep the old content
			# until the pass has drawn the new writers.
			if writers == null or not bool(writers.call("queue_rect", k, clipped)):
				work.append([k, clipped])
				texels += clipped.get_area()
		_writer_pending[k] = []
	var sets := {}
	for item: Array in ready:
		var k := int(item[0])
		if k >= levels or not _valid[k]: continue
		var clipped := (item[1] as Rect2i).intersection(Rect2i(_origins[k], Vector2i(resolution, resolution)))
		if not clipped.has_area(): continue
		work.append([k, clipped, int(item[3]), item[2], int(item[4])])
		texels += clipped.get_area()
		if not sets.has(int(item[3])): sets[int(item[3])] = writers.call("set_texture", int(item[3]))
	if writers != null: writers.call("dispatch")
	stats.texels_last_frame = texels
	stats.dispatches_last_frame = work.size()
	if not work.is_empty() or _textures_dirty:
		_timestamp_frame += 1
		var request := {"work": work, "maps": _maps.duplicate(), "bytes": _parameter_bytes, "defines": defines, "allocate": _textures_dirty, "levels": levels, "resolution": resolution, "texel": texel, "sets": sets, "measure": measure_gpu, "stamp": _timestamp_frame}
		_textures_dirty = false
		RenderingServer.call_on_render_thread(_render_update.bind(request))
	stats.status = "Ready" if _valid.all(func(v: bool) -> bool: return v) else "Filling"
	return stats.status == "Ready"


## Publishes the cache as the strata_cache_* global shader parameters (when publish_globals).
## [param terrain_transform] is the terrain node's global transform (translation/yaw);
## [param relief_level] the level whose cells match the displaced vertex spacing (-1: none).
func publish(terrain_transform: Transform3D, camera: Vector3, displacement_radius: float, displacement_strength: float, specular: float, relief_level := -1) -> void:
	if not publish_globals:
		unpublish()
		return
	if _failed:
		unpublish()
		return
	if not _globals_ready():
		stats.status = "Global shader parameters missing: enable the Strata plugin or call StrataSurfaceCache.register_project_globals()"
		return
	_globals_owner = true
	var origins := PackedFloat32Array()
	origins.resize(MAX_LEVELS * 2)
	for k in MAX_LEVELS:
		var origin := level_origin(k) if k < levels else Vector2i(int(INVALID_ORIGIN), int(INVALID_ORIGIN))
		origins[k * 2] = origin.x; origins[k * 2 + 1] = origin.y
	# Only changed values are sent: setting a global (a texture above all) dirties every
	# material that reads it.
	_set_global("strata_cache_albedo", albedo_texture)
	_set_global("strata_cache_normal", normal_texture)
	_set_global("strata_cache_height", height_texture)
	_set_global("strata_cache_params", Vector4(texel, resolution, levels, 1.0))
	_set_global("strata_cache_windows_a", Vector4(origins[0], origins[1], origins[2], origins[3]))
	_set_global("strata_cache_windows_b", Vector4(origins[4], origins[5], origins[6], origins[7]))
	_set_global("strata_cache_windows_c", Vector4(origins[8], origins[9], origins[10], origins[11]))
	_set_global("strata_cache_windows_d", Vector4(origins[12], origins[13], origins[14], origins[15]))
	_set_global("strata_cache_camera", Vector4(camera.x, camera.y, camera.z, maxf(displacement_radius, 0.0)))
	_set_global("strata_cache_surface", Vector4(displacement_strength, specular, float(relief_level), 0.0))
	_set_global("strata_cache_world_to_local", terrain_transform.affine_inverse())


func _set_global(name: String, value: Variant) -> void:
	if _published.has(name) and _published[name] == value: return
	_published[name] = value
	RenderingServer.global_shader_parameter_set(name, value)


## Disables the published cache (readers fall back to their own shading).
func unpublish() -> void:
	if not _globals_owner or not _globals_ready(): return
	_globals_owner = false
	_set_global("strata_cache_params", Vector4.ZERO)


## The global parameters exist when the project settings declare them (the renderer creates
## them from [shader_globals] at startup; the editor's list query is editor-only).
func _globals_ready() -> bool:
	if _globals_checked < 0:
		_globals_checked = 1
		for name: String in GLOBAL_PARAMETERS:
			if not ProjectSettings.has_setting("shader_globals/" + name): _globals_checked = 0
	return _globals_checked == 1


## Frees the GPU resources.
func release() -> void:
	unpublish()
	# Dependents first: the uniform set, then the pipeline before its shader.
	var rids: Array[RID] = [_uniform_set, _pipeline, _shader, _params]
	# Writer tile sets are freed with the shader they were made for.
	_writer_sets = {}
	_writer_fallback_set = RID()
	rids.append_array(_textures)
	rids.append_array(_samplers)
	rids.append_array(_fallbacks)
	_fallbacks = []
	_textures = []; _samplers = []; _uniform_set = RID(); _params = RID(); _pipeline = RID(); _shader = RID()
	_shader_key = ""; _sampler_key = ""; _uniform_key = ""
	_textures_dirty = true
	_valid.fill(false); _needs_full.fill(true)
	for k in _origins.size(): _origins[k] = Vector2i(2147483647, 2147483647)
	if _rd != null and rids.any(func(rid: RID) -> bool: return rid.is_valid()):
		RenderingServer.call_on_render_thread(_free_rids.bind(rids, [albedo_texture, normal_texture, height_texture, cover_texture]))


# ─────────────────────────────────────────────
# Main thread
# ─────────────────────────────────────────────

## Cells of [param current] that [param previous] (same size) did not cover: up to two strips.
static func _exposed(previous: Rect2i, current: Rect2i) -> Array[Rect2i]:
	var result: Array[Rect2i] = []
	var dx := current.position.x - previous.position.x
	var dy := current.position.y - previous.position.y
	if dx > 0:
		result.append(Rect2i(Vector2i(previous.end.x, current.position.y), Vector2i(dx, current.size.y)))
	elif dx < 0:
		result.append(Rect2i(current.position, Vector2i(-dx, current.size.y)))
	var x0 := maxi(current.position.x, previous.position.x)
	var x1 := mini(current.end.x, previous.end.x)
	if x1 > x0:
		if dy > 0:
			result.append(Rect2i(Vector2i(x0, previous.end.y), Vector2i(x1 - x0, dy)))
		elif dy < 0:
			result.append(Rect2i(Vector2i(x0, current.position.y), Vector2i(x1 - x0, -dy)))
	return result


func _parameter(material: ShaderMaterial, name: String) -> Variant:
	var value: Variant = material.get_shader_parameter(name)
	if value == null:
		value = RenderingServer.shader_get_parameter_default(material.shader.get_rid(), name)
	return value


## Reads the material's uniforms into the parameter buffer bytes and texture list; requests a
## full refill when anything the cache depends on changed.
func _gather_material(material: ShaderMaterial) -> void:
	var bytes := PackedByteArray()
	bytes.resize((_MATERIAL_ARRAYS.size() * 32 + 64) * 4)
	var offset := 0
	for name: String in _MATERIAL_ARRAYS:
		var values: Variant = _parameter(material, name)
		for i in 32:
			var value: Variant = values[i] if (values is PackedFloat32Array or values is PackedInt32Array or values is Array) and i < values.size() else 0
			if name in _INT_ARRAYS: bytes.encode_s32(offset + i * 4, int(value))
			else: bytes.encode_float(offset + i * 4, float(value))
		offset += 128
	var float_base := offset
	var int_base := offset + 128
	for name: String in _FLOAT_SLOTS:
		var value: Variant = _parameter(material, name)
		var slot := int(_FLOAT_SLOTS[name])
		if name in _VECTOR_UNIFORMS:
			var vector := Vector2(value) if value != null else Vector2.ZERO
			bytes.encode_float(float_base + slot * 4, vector.x); bytes.encode_float(float_base + slot * 4 + 4, vector.y)
		else:
			bytes.encode_float(float_base + slot * 4, float(value) if value != null else 0.0)
	for name: String in _INT_SLOTS:
		var value: Variant = _parameter(material, name)
		var slot := int(_INT_SLOTS[name])
		if name in _VECTOR_UNIFORMS:
			var vector := Vector2i(value) if value != null else Vector2i.ZERO
			bytes.encode_s32(int_base + slot * 4, vector.x); bytes.encode_s32(int_base + slot * 4 + 4, vector.y)
		else:
			bytes.encode_s32(int_base + slot * 4, int(value) if value != null else 0)
	var maps := {}
	var identity := PackedStringArray()
	for name: String in ["color_maps", "normal_maps", "ormh_maps"]:
		var list: Variant = _parameter(material, name)
		var rids: Array[RID] = []
		for i in 32:
			var texture: Texture = list[i] if list is Array and i < list.size() and list[i] is Texture else null
			rids.append(texture.get_rid() if texture != null else RID())
			identity.append(str(texture.get_rid().get_id()) if texture != null else "-")
		maps[name] = rids
	for entry: Array in _MAP_BINDINGS:
		var texture: Variant = _parameter(material, entry[0])
		maps[entry[0]] = (texture as Texture).get_rid() if texture is Texture else RID()
		identity.append(str(maps[entry[0]].get_id()))
	var signature := "%s|%s" % [bytes.hex_encode(), ",".join(identity)]
	_maps = maps
	_parameter_bytes = bytes
	if signature != _material_signature:
		_material_signature = signature
		_needs_full.fill(true)


# ─────────────────────────────────────────────
# Render thread
# ─────────────────────────────────────────────

func _render_update(request: Dictionary) -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null: return
	if request.allocate or _textures.is_empty():
		_allocate(rd, int(request.levels), int(request.resolution))
	if (request.work as Array).is_empty(): return
	if not _ensure_pipeline(rd, String(request.defines)): return
	if not _params.is_valid():
		_params = rd.storage_buffer_create((request.bytes as PackedByteArray).size(), request.bytes)
	else:
		rd.buffer_update(_params, 0, (request.bytes as PackedByteArray).size(), request.bytes)
	if not _ensure_uniform_set(rd, request.maps):
		# A map is not uploaded yet: retry these rects with the next request.
		for item: Array in request.work: (_pending[int(item[0])] as Array).append(item[1])
		return
	if bool(request.get("measure", false)): _read_timestamps(rd)
	var writer_sets := {}
	for index: int in request.sets:
		var set_rid := _writer_set(rd, index, request.sets[index])
		if set_rid.is_valid(): writer_sets[index] = set_rid
	var fallback := _writer_fallback(rd)
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _pipeline)
	rd.compute_list_bind_uniform_set(list, _uniform_set, 0)
	var bound := RID()
	var stamp := "StrataSurfaceCache fill %d" % int(request.get("stamp", 0))
	if bool(request.get("measure", false)): rd.capture_timestamp(stamp + " begin")
	for item: Array in request.work:
		var level := int(item[0])
		var rect: Rect2i = item[1]
		var tile_set := int(item[2]) if item.size() > 2 else -1
		var writer_set: RID = writer_sets.get(tile_set, RID())
		var origin: Vector2i = item[3] if writer_set.is_valid() else Vector2i.ZERO
		var set_rid := writer_set if writer_set.is_valid() else fallback
		if set_rid != bound:
			rd.compute_list_bind_uniform_set(list, set_rid, 1)
			bound = set_rid
		var push := PackedByteArray()
		push.resize(48)
		push.encode_s32(0, rect.position.x); push.encode_s32(4, rect.position.y)
		push.encode_s32(8, rect.size.x); push.encode_s32(12, rect.size.y)
		push.encode_s32(16, level); push.encode_s32(20, int(request.resolution))
		push.encode_float(24, float(request.texel) * float(1 << level)); push.encode_s32(28, 1 if writer_set.is_valid() else 0)
		push.encode_s32(32, origin.x); push.encode_s32(36, origin.y)
		push.encode_s32(40, int(item[4]) if writer_set.is_valid() else 0)
		rd.compute_list_set_push_constant(list, push, push.size())
		rd.compute_list_dispatch(list, ceili(rect.size.x / 8.0), ceili(rect.size.y / 8.0), 1)
	rd.compute_list_end()
	if bool(request.get("measure", false)): rd.capture_timestamp(stamp + " end")


## GPU time of fills recorded in an earlier frame (the device reports the frame before last).
func _read_timestamps(rd: RenderingDevice) -> void:
	var begins := {}
	for i in rd.get_captured_timestamps_count():
		var name := rd.get_captured_timestamp_name(i)
		if not name.begins_with("StrataSurfaceCache fill "): continue
		var key := name.trim_suffix(" begin").trim_suffix(" end")
		if name.ends_with(" begin"): begins[key] = rd.get_captured_timestamp_gpu_time(i)
		elif begins.has(key):
			var ms := float(rd.get_captured_timestamp_gpu_time(i) - int(begins[key])) / 1000000.0
			stats.gpu_ms = ms
			stats.gpu_ms_total = float(stats.gpu_ms_total) + ms
			stats.gpu_samples = int(stats.gpu_samples) + 1


## Uniform set 1 for a writer tile: its viewport texture (the RD texture resolved now, so a
## reallocated viewport rebinds).
func _writer_set(rd: RenderingDevice, index: int, texture: RID) -> RID:
	var rd_rid := RenderingServer.texture_get_rd_texture(texture)
	if not rd_rid.is_valid(): return RID()
	var joined := str(rd_rid.get_id()) + "|" + str(_shader.get_id())
	var cached: Array = _writer_sets.get(index, [])
	if not cached.is_empty() and cached[0] == joined and rd.uniform_set_is_valid(cached[1]): return cached[1]
	if not cached.is_empty() and rd.uniform_set_is_valid(cached[1]): rd.free_rid(cached[1])
	var rid := _texture_set(rd, rd_rid)
	_writer_sets[index] = [joined, rid]
	return rid


## Uniform set 1 for plain fills: blank textures (fill.writers is 0, so they are not read).
func _writer_fallback(rd: RenderingDevice) -> RID:
	if _writer_fallback_set.is_valid() and rd.uniform_set_is_valid(_writer_fallback_set): return _writer_fallback_set
	_writer_fallback_set = _texture_set(rd, _fallback_texture(rd, false))
	return _writer_fallback_set


func _texture_set(rd: RenderingDevice, texture: RID) -> RID:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = 0
	uniform.add_id(_samplers[1])
	uniform.add_id(texture)
	return rd.uniform_set_create([uniform], _shader, 1)


func _allocate(rd: RenderingDevice, level_count: int, cells: int) -> void:
	_uniform_set = RID()
	_uniform_key = ""
	for rid: RID in _textures:
		if rid.is_valid(): rd.free_rid(rid)
	_textures = []
	var formats := [RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM, RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM, RenderingDevice.DATA_FORMAT_R32_SFLOAT, RenderingDevice.DATA_FORMAT_R8_UNORM]
	var layers := [level_count, level_count, level_count * 2, level_count]
	var wrappers := [albedo_texture, normal_texture, height_texture, cover_texture]
	for i in 4:
		var format := RDTextureFormat.new()
		format.format = formats[i]
		format.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
		format.width = cells
		format.height = cells
		format.array_layers = layers[i]
		format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
		var rid := rd.texture_create(format, RDTextureView.new(), [])
		_textures.append(rid)
		(wrappers[i] as Texture2DArrayRD).texture_rd_rid = rid


func _ensure_pipeline(rd: RenderingDevice, defines: String) -> bool:
	if _shader_key == defines and _pipeline.is_valid(): return true
	if _shader.is_valid(): rd.free_rid(_shader)
	_shader = RID(); _pipeline = RID(); _uniform_set = RID(); _uniform_key = ""
	# Sets made for the old shader went with it.
	_writer_sets = {}; _writer_fallback_set = RID()
	_shader_key = defines
	var code := "#version 450\n" + defines + _GLSL_PRELUDE
	for name: String in _INCLUDES:
		var include := load(_SHADER_DIR + name + ".gdshaderinc") as ShaderInclude
		if include == null:
			push_error("StrataSurfaceCache: missing shader include %s" % name)
			_failed = true
			return false
		code += "\n// ---- %s ----\n" % name + include.code
	code += _GLSL_MAIN
	var source := RDShaderSource.new()
	source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	source.source_compute = code
	var spirv := rd.shader_compile_spirv_from_source(source)
	if not spirv.compile_error_compute.is_empty():
		push_error("StrataSurfaceCache: compute shader: " + spirv.compile_error_compute)
		_failed = true
		return false
	_shader = rd.shader_create_from_spirv(spirv, "StrataSurfaceCache")
	_pipeline = rd.compute_pipeline_create(_shader)
	return _pipeline.is_valid()


func _ensure_samplers(rd: RenderingDevice, pixel: bool) -> void:
	var key := "pixel" if pixel else "linear"
	if key == _sampler_key and not _samplers.is_empty(): return
	for rid: RID in _samplers: rd.free_rid(rid)
	_samplers = []
	_sampler_key = key
	# 0 material (nearest or linear with mipmaps, repeating), 1 nearest clamp, 2 linear clamp.
	var states := []
	var material := RDSamplerState.new()
	material.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST if pixel else RenderingDevice.SAMPLER_FILTER_LINEAR
	material.min_filter = material.mag_filter
	material.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	material.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	material.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	material.max_lod = 1000.0
	states.append(material)
	for filter in [RenderingDevice.SAMPLER_FILTER_NEAREST, RenderingDevice.SAMPLER_FILTER_LINEAR]:
		var state := RDSamplerState.new()
		state.mag_filter = filter
		state.min_filter = filter
		state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		states.append(state)
	for state: RDSamplerState in states:
		_samplers.append(rd.sampler_create(state))


## Binds the maps' current RenderingDevice textures; false when one is not available yet.
func _ensure_uniform_set(rd: RenderingDevice, maps: Dictionary) -> bool:
	_ensure_samplers(rd, _shader_key.contains("STRATA_PIXEL_SAMPLING"))
	var resolved := {}
	var key := PackedStringArray()
	for name: String in ["color_maps", "normal_maps", "ormh_maps"]:
		var list: Array[RID] = []
		for rid: RID in maps[name]:
			var rd_rid := RenderingServer.texture_get_rd_texture(rid, name == "color_maps") if rid.is_valid() else RID()
			if name == "color_maps" and rid.is_valid() and not rd_rid.is_valid():
				rd_rid = RenderingServer.texture_get_rd_texture(rid, false)
			if not rd_rid.is_valid(): return false
			list.append(rd_rid)
			key.append(str(rd_rid.get_id()))
		resolved[name] = list
	for entry: Array in _MAP_BINDINGS:
		var rid: RID = maps[entry[0]]
		var rd_rid := RID()
		if rid.is_valid():
			rd_rid = RenderingServer.texture_get_rd_texture(rid)
			if not rd_rid.is_valid(): return false
		else:
			# Unbound map (no far tier, coarse maps or holes): a blank stand-in, as Godot binds
			# for an unset sampler; the parameter flags keep the shader from reading it.
			rd_rid = _fallback_texture(rd, String(entry[0]).ends_with("_regions"))
		resolved[entry[0]] = rd_rid
		key.append(str(rd_rid.get_id()))
	for rid: RID in _textures: key.append(str(rid.get_id()))
	key.append(str(_params.get_id()))
	key.append(_sampler_key)
	var joined := ",".join(key)
	if joined == _uniform_key and _uniform_set.is_valid() and rd.uniform_set_is_valid(_uniform_set): return true
	if _uniform_set.is_valid() and rd.uniform_set_is_valid(_uniform_set): rd.free_rid(_uniform_set)
	var uniforms: Array[RDUniform] = []
	var binding := 0
	for name: String in ["color_maps", "normal_maps", "ormh_maps"]:
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		uniform.binding = binding
		for rd_rid: RID in resolved[name]:
			uniform.add_id(_samplers[0])
			uniform.add_id(rd_rid)
		uniforms.append(uniform)
		binding += 1
	for entry: Array in _MAP_BINDINGS:
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		uniform.binding = binding
		uniform.add_id(_samplers[1 + int(entry[1])])
		uniform.add_id(resolved[entry[0]])
		uniforms.append(uniform)
		binding += 1
	var buffer := RDUniform.new()
	buffer.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	buffer.binding = binding
	buffer.add_id(_params)
	uniforms.append(buffer)
	binding += 1
	for rid: RID in _textures:
		var image := RDUniform.new()
		image.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		image.binding = binding
		image.add_id(rid)
		uniforms.append(image)
		binding += 1
	_uniform_set = rd.uniform_set_create(uniforms, _shader, 0)
	_uniform_key = joined
	return _uniform_set.is_valid()


## A 1x1 blank RGBA8 texture (2D, or a one-layer 2D array) for unbound map bindings.
func _fallback_texture(rd: RenderingDevice, array: bool) -> RID:
	var index := 1 if array else 0
	if _fallbacks.size() < 2: _fallbacks = [RID(), RID()]
	if _fallbacks[index].is_valid(): return _fallbacks[index]
	var format := RDTextureFormat.new()
	format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY if array else RenderingDevice.TEXTURE_TYPE_2D
	format.width = 1
	format.height = 1
	format.array_layers = 1
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var blank := PackedByteArray([0, 0, 0, 0])
	_fallbacks[index] = rd.texture_create(format, RDTextureView.new(), [blank])
	return _fallbacks[index]


static func _free_rids(rids: Array[RID], wrappers: Array) -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null: return
	for wrapper: Texture2DArrayRD in wrappers: wrapper.texture_rd_rid = RID()
	# The uniform set may already be gone with a texture it used (freed by a reallocation).
	if rids[0].is_valid() and not rd.uniform_set_is_valid(rids[0]): rids[0] = RID()
	for rid: RID in rids:
		if rid.is_valid(): rd.free_rid(rid)
