@tool
class_name StrataSurfaceWriterFar
extends RefCounted
## Whole-terrain layer of every StrataSurfaceWriter at a coarse texel (2 m by default): the far
## counterpart of StrataSurfaceCache, as an Unreal runtime virtual texture keeps its low mips. The
## writer pass draws it once in large multisampled tiles (StrataSurfaceWriterPass.FAR, after the
## cache's own tiles) and redraws only where writers change; nothing is drawn per frame
## otherwise. The terrain shader samples it where the cache does not reach (beyond its coarsest
## window, or while a window fills), over its own surface.
##
## albedo_texture: premultiplied linear albedo, stored sRGB-encoded; A = albedo coverage. The
##   texture can be viewed as sRGB, so a source_color sampler decodes before filtering and the
##   averages stay linear.
## normal_texture: premultiplied (normal x * 0.5 + 0.5, normal z * 0.5 + 0.5, roughness) in
##   ground space (Y up), A = normal coverage.
## Texel (i, j) covers terrain-local XZ [origin + (i, j), origin + (i + 1, j + 1)] * texel. Both
## textures carry a full mip chain (premultiplied box filter), and writers are drawn at
## SUPERSAMPLE x SUPERSAMPLE cells per texel and averaged, so coverage is conservative: a road
## narrower than a texel becomes a faint averaged tint instead of breaking up.

## Render cells per texel along each axis.
const SUPERSAMPLE := 2
const _COMPOSITE_GLSL := """
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0, rgba8) restrict writeonly uniform image2D albedo_out;
layout(set = 0, binding = 1, rgba8) restrict writeonly uniform image2D normal_out;
layout(set = 1, binding = 0) uniform sampler2D writer_tile;
layout(push_constant, std430) uniform Params {
	ivec2 rect_origin;
	ivec2 rect_size;
	ivec2 tile_origin;
	int tile_width;
	int writers;
} p;

vec3 linear_to_srgb(vec3 c) {
	c = clamp(c, vec3(0.0), vec3(1.0));
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

void main() {
	ivec2 local = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(local, p.rect_size))) { return; }
	ivec2 texel = p.rect_origin + local;
	vec4 albedo = vec4(0.0);
	vec4 normal = vec4(0.0);
	if (p.writers != 0) {
		// Box average of the texel's render cells (premultiplied, so coverage averages too).
		ivec2 first = texel * SUPERSAMPLE - p.tile_origin;
		for (int j = 0; j < SUPERSAMPLE; j++) {
			for (int i = 0; i < SUPERSAMPLE; i++) {
				ivec2 t = first + ivec2(i, j);
				albedo += texelFetch(writer_tile, t, 0);
				normal += texelFetch(writer_tile, t + ivec2(p.tile_width, 0), 0);
			}
		}
		albedo = clamp(albedo / float(SUPERSAMPLE * SUPERSAMPLE), vec4(0.0), vec4(1.0));
		normal = clamp(normal / float(SUPERSAMPLE * SUPERSAMPLE), vec4(0.0), vec4(1.0));
	}
	imageStore(albedo_out, texel, vec4(linear_to_srgb(albedo.rgb), albedo.a));
	imageStore(normal_out, texel, normal);
}
"""
const _MIP_GLSL := """
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0, rgba8) restrict readonly uniform image2D albedo_in;
layout(set = 0, binding = 1, rgba8) restrict readonly uniform image2D normal_in;
layout(set = 0, binding = 2, rgba8) restrict writeonly uniform image2D albedo_out;
layout(set = 0, binding = 3, rgba8) restrict writeonly uniform image2D normal_out;
layout(push_constant, std430) uniform Params { ivec2 size; ivec2 pad; } p;

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

vec3 linear_to_srgb(vec3 c) {
	c = clamp(c, vec3(0.0), vec3(1.0));
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

void main() {
	ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(texel, p.size))) { return; }
	ivec2 last = imageSize(albedo_in) - ivec2(1);
	vec4 albedo = vec4(0.0);
	vec4 normal = vec4(0.0);
	for (int i = 0; i < 4; i++) {
		ivec2 source = min(texel * 2 + ivec2(i & 1, i >> 1), last);
		vec4 a = imageLoad(albedo_in, source);
		albedo += vec4(srgb_to_linear(a.rgb), a.a);
		normal += imageLoad(normal_in, source);
	}
	imageStore(albedo_out, texel, vec4(linear_to_srgb(albedo.rgb * 0.25), albedo.a * 0.25));
	imageStore(normal_out, texel, normal * 0.25);
}
"""

## Seconds at least between redraws of changed areas (a writer that changes every frame then
## redraws its far tiles a few times a second, not every frame).
var redraw_interval := 0.25
## Texel edge in metres (a power-of-two multiple of the cache's level-0 cell).
var texel := 2.0
## Writer pass level of the render cells (texel / SUPERSAMPLE).
var render_level := 0
## Texel index (terrain-local XZ / texel) of texel (0, 0).
var origin := Vector2i.ZERO
var size := Vector2i.ZERO
var albedo_texture := Texture2DRD.new()
var normal_texture := Texture2DRD.new()
var stats := {"size": Vector2i.ZERO, "texel": 0.0, "memory_mb": 0.0, "tiles_composited": 0, "clears": 0, "pending": 0, "status": "Not configured"}

var _rd: RenderingDevice
## Render thread: [albedo, normal] and the per-mip storage views.
var _textures: Array[RID] = []
var _mip_views: Array[RID] = []
var _mip_sets: Array[RID] = []
var _shaders: Array[RID] = []
var _pipelines: Array[RID] = []
var _sampler := RID()
var _output_set := RID()
var _tile_sets := {}
var _clear_set := RID()
var _blank := RID()
var _allocate := true
## Main thread: texel rectangles waiting to be queued with the writer pass.
var _pending: Array[Rect2i] = []
var _flushed := -1000000
var _key := []


## True when a RenderingDevice exists (Forward+ or Mobile; not Compatibility or headless).
static func available() -> bool:
	return RenderingServer.get_rendering_device() != null and DisplayServer.get_name() != "headless"


## Sizes the layer for terrain-local XZ [param bounds]: the texel is [param texel_size] snapped to
## a power-of-two multiple of [param cache_texel] (at least SUPERSAMPLE of them) and doubled
## until no side exceeds [param max_size] texels. Reallocates and redraws everything on change;
## returns true when it did.
func configure(bounds: Rect2, cache_texel: float, texel_size: float, max_size: int) -> bool:
	var level := maxi(roundi(log(maxf(texel_size, cache_texel) / cache_texel) / log(2.0)), 1)
	var edge := cache_texel * float(1 << level)
	var first := Vector2i.ZERO
	var count := Vector2i.ZERO
	while true:
		first = Vector2i(floori(bounds.position.x / edge), floori(bounds.position.y / edge))
		var last := Vector2i(ceili(bounds.end.x / edge), ceili(bounds.end.y / edge))
		count = last - first
		if maxi(count.x, count.y) <= max_size or level >= 30: break
		level += 1
		edge *= 2.0
	var key := [level, cache_texel, first, count]
	if key == _key: return false
	_key = key
	texel = edge
	render_level = level - 1
	origin = first
	size = count
	_allocate = true
	_pending = [Rect2i(Vector2i.ZERO, size)]
	var bytes := 0.0
	for k in _mip_count(): bytes += float(maxi(size.x >> k, 1) * maxi(size.y >> k, 1)) * 8.0
	stats.size = size
	stats.texel = texel
	stats.memory_mb = bytes / 1048576.0
	stats.status = "Filling"
	return true


## Redraws terrain-local [param rect] (everything when empty).
func invalidate(rect := Rect2()) -> void:
	if size == Vector2i.ZERO: return
	if not rect.has_area():
		_pending = [Rect2i(Vector2i.ZERO, size)]
		return
	var first := Vector2i(floori(rect.position.x / texel), floori(rect.position.y / texel)) - origin - Vector2i.ONE
	var last := Vector2i(ceili(rect.end.x / texel), ceili(rect.end.y / texel)) - origin + Vector2i.ONE
	var clipped := Rect2i(first, last - first).intersection(Rect2i(Vector2i.ZERO, size))
	if clipped.has_area(): _pending.append(clipped)


## Terrain-local XZ rectangle the textures cover.
func local_rect() -> Rect2:
	return Rect2(Vector2(origin) * texel, Vector2(size) * texel)


## Queues pending rectangles with [param writers] (the StrataSurfaceWriterPass) and composites
## the far tiles it drew last frame. Call before the pass dispatches this frame's tiles.
func update(writers: Node) -> void:
	if size == Vector2i.ZERO or writers == null: return
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
		if _rd == null:
			stats.status = "No RenderingDevice (Compatibility renderer or headless)"
			return
	var work := []
	var sets := {}
	var cells_origin := origin * SUPERSAMPLE
	for item: Array in writers.call("take_ready", 1):
		if int(item[0]) != render_level: continue
		var piece: Rect2i = item[1]
		var rect := Rect2i(piece.position / SUPERSAMPLE - origin, piece.size / SUPERSAMPLE).intersection(Rect2i(Vector2i.ZERO, size))
		if not rect.has_area(): continue
		var tile_origin: Vector2i = item[2]
		work.append([rect, int(item[3]), tile_origin - cells_origin, int(item[4])])
		if not sets.has(int(item[3])): sets[int(item[3])] = writers.call("set_texture", int(item[3]))
	var flush := _allocate or Time.get_ticks_msec() - _flushed >= redraw_interval * 1000.0
	if flush and not _pending.is_empty(): _flushed = Time.get_ticks_msec()
	var flushing: Array[Rect2i] = []
	if flush: flushing = _pending.duplicate()
	for rect: Rect2i in flushing:
		var cells := Rect2i(cells_origin + rect.position * SUPERSAMPLE, rect.size * SUPERSAMPLE)
		# Pieces no writer touches are cleared now; the others keep their content until drawn.
		for piece: Rect2i in writers.call("queue_far", render_level, cells):
			var cleared := Rect2i(piece.position / SUPERSAMPLE - origin, piece.size / SUPERSAMPLE).intersection(Rect2i(Vector2i.ZERO, size))
			if cleared.has_area(): work.append([cleared, -1, Vector2i.ZERO, 0])
	if flush: _pending.clear()
	stats.pending = int(writers.call("pending_far")) + _pending.size()
	stats.status = "Filling" if stats.pending > 0 else "Ready"
	if work.is_empty() and not _allocate: return
	for item: Array in work:
		if int(item[1]) >= 0: stats.tiles_composited = int(stats.tiles_composited) + 1
		else: stats.clears = int(stats.clears) + 1
	var request := {"work": work, "sets": sets, "allocate": _allocate, "size": size}
	_allocate = false
	RenderingServer.call_on_render_thread(_render_update.bind(request))


func release() -> void:
	# Uniform sets first (freed only while still alive: a set goes with a texture it used).
	var sets: Array[RID] = []
	sets.append_array(_mip_sets)
	for cached: Array in _tile_sets.values(): sets.append(cached[1])
	sets.append_array([_clear_set, _output_set])
	var rids: Array[RID] = []
	rids.append_array(_pipelines)
	rids.append_array(_shaders)
	rids.append_array(_mip_views)
	rids.append_array(_textures)
	rids.append_array([_sampler, _blank])
	_mip_sets = []; _tile_sets = {}; _clear_set = RID(); _output_set = RID(); _pipelines = []; _shaders = []
	_mip_views = []; _textures = []; _sampler = RID(); _blank = RID()
	_allocate = true
	_key = []
	size = Vector2i.ZERO
	if _rd != null and rids.any(func(rid: RID) -> bool: return rid.is_valid()):
		RenderingServer.call_on_render_thread(_free_rids.bind(sets, rids, [albedo_texture, normal_texture]))


func _mip_count() -> int:
	var mips := 1
	while (size.x >> mips) > 0 or (size.y >> mips) > 0: mips += 1
	return mips


# ─────────────────────────────────────────────
# Render thread
# ─────────────────────────────────────────────

func _render_update(request: Dictionary) -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null: return
	if not _ensure_pipelines(rd): return
	if request.allocate or _textures.is_empty(): _allocate_textures(rd, request.size)
	if (request.work as Array).is_empty(): return
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _pipelines[0])
	rd.compute_list_bind_uniform_set(list, _output_set, 0)
	for item: Array in request.work:
		var rect: Rect2i = item[0]
		var index := int(item[1])
		var tile_set := _tile_set(rd, index, request.sets[index]) if index >= 0 else RID()
		if index >= 0 and not tile_set.is_valid(): continue
		rd.compute_list_bind_uniform_set(list, tile_set if tile_set.is_valid() else _clear_set, 1)
		var origin_cells: Vector2i = item[2]
		var push := PackedByteArray()
		push.resize(32)
		push.encode_s32(0, rect.position.x); push.encode_s32(4, rect.position.y)
		push.encode_s32(8, rect.size.x); push.encode_s32(12, rect.size.y)
		push.encode_s32(16, origin_cells.x); push.encode_s32(20, origin_cells.y)
		push.encode_s32(24, int(item[3])); push.encode_s32(28, 1 if tile_set.is_valid() else 0)
		rd.compute_list_set_push_constant(list, push, push.size())
		rd.compute_list_dispatch(list, ceili(rect.size.x / 8.0), ceili(rect.size.y / 8.0), 1)
	# The whole mip chain again (about 1.4 texel writes per base texel; only after changes).
	var extent: Vector2i = request.size
	for k in range(1, _mip_sets.size() + 1):
		rd.compute_list_add_barrier(list)
		rd.compute_list_bind_compute_pipeline(list, _pipelines[1])
		rd.compute_list_bind_uniform_set(list, _mip_sets[k - 1], 0)
		var mip := Vector2i(maxi(extent.x >> k, 1), maxi(extent.y >> k, 1))
		# Every pipeline takes push constants: the device keeps the last block across binds.
		var push := PackedByteArray()
		push.resize(16)
		push.encode_s32(0, mip.x); push.encode_s32(4, mip.y)
		rd.compute_list_set_push_constant(list, push, push.size())
		rd.compute_list_dispatch(list, ceili(mip.x / 8.0), ceili(mip.y / 8.0), 1)
	rd.compute_list_end()


func _ensure_pipelines(rd: RenderingDevice) -> bool:
	if not _pipelines.is_empty(): return true
	for code: String in [_COMPOSITE_GLSL.replace("#version 450", "#version 450\n#define SUPERSAMPLE %d" % SUPERSAMPLE), _MIP_GLSL]:
		var source := RDShaderSource.new()
		source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
		source.source_compute = code
		var spirv := rd.shader_compile_spirv_from_source(source)
		if spirv.compile_error_compute != "":
			push_error("StrataSurfaceWriterFar shader: " + spirv.compile_error_compute)
			return false
		var shader := rd.shader_create_from_spirv(spirv)
		_shaders.append(shader)
		_pipelines.append(rd.compute_pipeline_create(shader))
	var sampler_state := RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	_sampler = rd.sampler_create(sampler_state)
	var format := RDTextureFormat.new()
	format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	format.width = 1
	format.height = 1
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	_blank = rd.texture_create(format, RDTextureView.new(), [PackedByteArray([0, 0, 0, 0])])
	_clear_set = _sampled_set(rd, _blank)
	return true


func _allocate_textures(rd: RenderingDevice, extent: Vector2i) -> void:
	for rid: RID in _mip_sets + [_output_set]:
		if rid.is_valid() and rd.uniform_set_is_valid(rid): rd.free_rid(rid)
	var views: Array[RID] = _mip_views.duplicate()
	views.append_array(_textures)
	for rid: RID in views:
		if rid.is_valid(): rd.free_rid(rid)
	_mip_sets = []; _mip_views = []; _output_set = RID(); _textures = []
	var mips := 1
	while (extent.x >> mips) > 0 or (extent.y >> mips) > 0: mips += 1
	var format := RDTextureFormat.new()
	format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	format.width = extent.x
	format.height = extent.y
	format.mipmaps = mips
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	format.add_shareable_format(RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM)
	format.add_shareable_format(RenderingDevice.DATA_FORMAT_R8G8B8A8_SRGB)
	var albedo := rd.texture_create(format, RDTextureView.new(), [])
	var normal_format := RDTextureFormat.new()
	normal_format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	normal_format.width = extent.x
	normal_format.height = extent.y
	normal_format.mipmaps = mips
	normal_format.usage_bits = format.usage_bits
	var normal := rd.texture_create(normal_format, RDTextureView.new(), [])
	_textures = [albedo, normal]
	rd.texture_clear(albedo, Color(0, 0, 0, 0), 0, mips, 0, 1)
	rd.texture_clear(normal, Color(0, 0, 0, 0), 0, mips, 0, 1)
	var albedo_mips: Array[RID] = []
	var normal_mips: Array[RID] = []
	for k in mips:
		for pair: Array in [[albedo, albedo_mips], [normal, normal_mips]]:
			var slice := rd.texture_create_shared_from_slice(RDTextureView.new(), pair[0], 0, k, 1, RenderingDevice.TEXTURE_SLICE_2D)
			(pair[1] as Array[RID]).append(slice)
			_mip_views.append(slice)
	_output_set = _storage_set(rd, [albedo_mips[0], normal_mips[0]], _shaders[0], 0)
	for k in range(1, mips):
		_mip_sets.append(_storage_set(rd, [albedo_mips[k - 1], normal_mips[k - 1], albedo_mips[k], normal_mips[k]], _shaders[1], 0))
	albedo_texture.texture_rd_rid = albedo
	normal_texture.texture_rd_rid = normal


func _storage_set(rd: RenderingDevice, images: Array[RID], shader: RID, set_index: int) -> RID:
	var uniforms: Array[RDUniform] = []
	for i in images.size():
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		uniform.binding = i
		uniform.add_id(images[i])
		uniforms.append(uniform)
	return rd.uniform_set_create(uniforms, shader, set_index)


func _sampled_set(rd: RenderingDevice, texture: RID) -> RID:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = 0
	uniform.add_id(_sampler)
	uniform.add_id(texture)
	return rd.uniform_set_create([uniform], _shaders[0], 1)


## Uniform set 1 for a writer tile (its viewport's RD texture, resolved now).
func _tile_set(rd: RenderingDevice, index: int, texture: RID) -> RID:
	var rd_rid := RenderingServer.texture_get_rd_texture(texture)
	if not rd_rid.is_valid(): return RID()
	var cached: Array = _tile_sets.get(index, [])
	if not cached.is_empty() and cached[0] == rd_rid and rd.uniform_set_is_valid(cached[1]): return cached[1]
	if not cached.is_empty() and rd.uniform_set_is_valid(cached[1]): rd.free_rid(cached[1])
	var rid := _sampled_set(rd, rd_rid)
	_tile_sets[index] = [rd_rid, rid]
	return rid


static func _free_rids(sets: Array[RID], rids: Array[RID], wrappers: Array) -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null: return
	for wrapper: Texture2DRD in wrappers:
		if wrapper.texture_rd_rid.is_valid(): wrapper.texture_rd_rid = RID()
	for rid: RID in sets:
		if rid.is_valid() and rd.uniform_set_is_valid(rid): rd.free_rid(rid)
	for rid: RID in rids:
		if rid.is_valid(): rd.free_rid(rid)
