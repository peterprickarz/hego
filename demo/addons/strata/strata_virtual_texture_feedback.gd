@tool
class_name StrataVirtualTextureFeedback
extends CompositorEffect
## Feedback pass of StrataSurfaceCache: a compute pass after the opaque pass that reads the
## depth buffer of one pixel per 8 x 8 tile (the pixel rotates through the tile over 64 frames),
## rebuilds its terrain-local position and footprint, and records the virtual texture pages
## that pixel reads (the mip its footprint selects and the next one, as the terrain shader
## blends them). The page keys are read back asynchronously and handed to the page manager a
## frame or two later (take_requests()).
##
## The depth buffer holds every opaque surface, not only the terrain. With the cache's page table
## and heights bound (set_ground()), a pixel requests pages only when it lies on or near the
## terrain surface: its height is compared with the cached ground height at its position, read
## from the page of a deciding mip (at most DECISION_CELL metres per cell, and never finer than
## the pixel's next mip), which the pixel always requests so the answer stays available. Pixels of
## canopies, trunks and props well above the ground request nothing; those near it (where other
## shaders blend into the ground) still do. A steep pixel's footprint is its full extent in space
## rather than on the ground plane, as readers of the ground below it measure it: on vertical
## surfaces the ground-plane extent tends to zero.
##
## A key is mip << 28 | table y << 14 | table x, the page's texel in the page table of its mip
## (see StrataSurfaceCache). Keys are deduplicated on the GPU in a hash set, so a frame
## returns each visible page once, up to CAPACITY pages per viewport.
##
## The effect runs for every camera whose compositor holds it; each viewport adds its pages to
## the same request set. The owner sets the lookup on the main thread; the render callback
## reads it under a mutex.

## Pages one viewport can report per frame.
const CAPACITY := 4096
const _SEEN_SLOTS := 16384
const _PARAMS_BYTES := 224
const _STRIDE := 8
## A pixel within GROUND_BAND metres of the cached ground height (plus GROUND_CELLS cells of the
## deciding mip for the interpolation between cell corners, plus GROUND_PER_METRE of its distance
## for coarser terrain meshes far away) counts as on the terrain.
const GROUND_BAND := 1.0
const GROUND_CELLS := 2.0
const GROUND_PER_METRE := 0.01
## Cell size (m) of the deciding mip at most (see the class description).
const DECISION_CELL := 0.5
## Frames the sampled pixel takes to visit every pixel of its tile: a page on a still screen is
## reported at least once in this many frames, not necessarily in every one.
const CYCLE_FRAMES := _STRIDE * _STRIDE

const _GLSL := """#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D depth_texture;
layout(set = 0, binding = 1, std140) uniform Params {
	mat4 inv_projection;
	mat4 view_to_local;
	vec4 lookup;   // mip 0 cell size (m), page size (cells), top mip, lod bias
	ivec4 table;   // first page of mip 0 (xy), table size at mip 0, capacity
	ivec4 frame;   // internal size (xy), pixel of the tile sampled this frame (zw)
	vec4 bounds;   // terrain-local x and z minimum (xy) and maximum (zw)
	vec4 filtering;   // largest anisotropy the shading follows (1: none), 0, 0, 0
	ivec4 ground;     // slots per atlas side, border (cells), 1 when the cache heights are bound, deciding mip
} P;
// count: keys; rejected: sampled pixels off the terrain surface; deferred: sampled pixels whose
// deciding page is not resident yet.
layout(set = 0, binding = 2, std430) restrict buffer Requests { uint count; uint rejected; uint deferred; uint pad2; uint keys[]; } requests;
layout(set = 0, binding = 3, std430) restrict buffer Seen { uint slots[]; } seen;
// The cache's page table (one mip per page mip, (slot + 1) / 65535, 0 absent) and height atlas
// (layer 2L: ground height at the cell corner, -1e30 in holes).
layout(set = 0, binding = 4) uniform sampler2D page_table;
layout(set = 0, binding = 5) uniform sampler2DArray heights;

const int STRIDE = 8;
const uint SEEN_MASK = 16383u;
const float GROUND_BAND = %GROUND_BAND%;
const float GROUND_CELLS = %GROUND_CELLS%;
const float GROUND_PER_METRE = %GROUND_PER_METRE%;

// Terrain-local position under a pixel; sky where nothing was drawn (reversed depth: far is 0).
vec3 local_at(ivec2 pixel, out bool sky) {
	vec2 uv = (vec2(pixel) + 0.5) / vec2(P.frame.xy);
	float depth = texelFetch(depth_texture, pixel, 0).r;
	sky = depth <= 0.0;
	vec4 view = P.inv_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
	return (P.view_to_local * vec4(view.xyz / view.w, 1.0)).xyz;
}

void request(int mip, vec2 xz) {
	float cell = P.lookup.x * exp2(float(mip));
	ivec2 page = ivec2(floor(xz / (cell * P.lookup.y)));
	ivec2 at = page - ivec2(P.table.x >> mip, P.table.y >> mip);
	int size = max(P.table.z >> mip, 1);
	if (any(lessThan(at, ivec2(0))) || any(greaterThanEqual(at, ivec2(size)))) { return; }
	uint key = (uint(mip) << 28) | (uint(at.y) << 14) | uint(at.x);
	uint slot = (key * 2654435761u) >> 18;
	for (uint i = 0u; i < 8u; i++) {
		uint previous = atomicCompSwap(seen.slots[(slot + i) & SEEN_MASK], 0u, key + 1u);
		if (previous == key + 1u) { return; }
		if (previous == 0u) {
			uint index = atomicAdd(requests.count, 1u);
			if (index < uint(P.table.w)) { requests.keys[index] = key; }
			return;
		}
	}
}

// The cached ground height at a terrain-local XZ position from the page of a mip, bilinear
// between its cell corners: 0 when the page is not resident, 1 found, 2 in a hole.
int ground_height(vec2 xz, int mip, out float height) {
	height = 0.0;
	int page_size = int(P.lookup.y);
	vec2 grid = xz / (P.lookup.x * exp2(float(mip)));
	ivec2 page = ivec2(floor(grid / float(page_size)));
	ivec2 at = page - ivec2(P.table.x >> mip, P.table.y >> mip);
	int size = max(P.table.z >> mip, 1);
	if (any(lessThan(at, ivec2(0))) || any(greaterThanEqual(at, ivec2(size)))) { return 0; }
	int entry = int(texelFetch(page_table, at, mip).r * 65535.0 + 0.5);
	if (entry == 0) { return 0; }
	int per_side = P.ground.x;
	int layer = (entry - 1) / (per_side * per_side);
	int in_layer = (entry - 1) - layer * per_side * per_side;
	ivec2 corner = ivec2(floor(grid));
	vec2 f = grid - vec2(corner);
	ivec2 texel = ivec2(in_layer % per_side, in_layer / per_side) * (page_size + 2 * P.ground.y) + ivec2(P.ground.y) + corner - page * page_size;
	float h00 = texelFetch(heights, ivec3(texel, layer * 2), 0).r;
	float h10 = texelFetch(heights, ivec3(texel + ivec2(1, 0), layer * 2), 0).r;
	float h01 = texelFetch(heights, ivec3(texel + ivec2(0, 1), layer * 2), 0).r;
	float h11 = texelFetch(heights, ivec3(texel + ivec2(1, 1), layer * 2), 0).r;
	if (min(min(h00, h10), min(h01, h11)) < -1.0e29) { return 2; }
	height = mix(mix(h00, h10, f.x), mix(h01, h11, f.x), f.y);
	return 1;
}

// Metres a point may lie from the ground height read at a mip and still count as on the terrain.
float ground_tolerance(int mip, float camera_distance) {
	return GROUND_BAND + GROUND_CELLS * P.lookup.x * exp2(float(mip)) + GROUND_PER_METRE * camera_distance;
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy) * STRIDE + P.frame.zw;
	if (pixel.x >= P.frame.x - 1 || pixel.y >= P.frame.y - 1) { return; }
	bool sky; bool sky_x; bool sky_y;
	vec3 point = local_at(pixel, sky);
	if (sky || point.x < P.bounds.x || point.z < P.bounds.y || point.x > P.bounds.z || point.z > P.bounds.w) { return; }
	vec3 point_x = local_at(pixel + ivec2(1, 0), sky_x);
	vec3 point_y = local_at(pixel + ivec2(0, 1), sky_y);
	// The footprint the terrain shader uses: the pixel's extent on the ground plane. A
	// neighbour on the sky gives none; at a depth edge the larger extent asks for a coarser
	// mip, which the pixels beside the edge refine.
	float extent_x = sky_x ? 0.0 : length(point_x.xz - point.xz);
	float extent_y = sky_y ? 0.0 : length(point_y.xz - point.xz);
	float footprint = max(extent_x, extent_y);
	// Anisotropic shading reads the mip of the short axis, up to P.filtering.x times finer.
	float short_axis = (sky_x || sky_y) ? footprint : min(extent_x, extent_y);
	footprint /= clamp(footprint / max(short_axis, 0.000001), 1.0, max(P.filtering.x, 1.0));
	if (!sky_x && !sky_y) {
		// Steeper than 60 degrees: the extent in space (readers of the ground below such a
		// surface measure the pixel so; its ground-plane extent tends to zero).
		vec3 normal = cross(point_y - point, point_x - point);
		if (abs(normal.y) < 0.5 * length(normal)) { footprint = max(length(point_x - point), length(point_y - point)); }
	}
	int top = int(P.lookup.z);
	float lod = max(log2(max(footprint, 0.000001) / P.lookup.x) + P.lookup.w, 0.0);
	int mip = min(int(floor(lod)), top);
	if (P.ground.z != 0) {
		// On or near the terrain surface only, decided at the deciding mip (always requested).
		int deciding = clamp(max(P.ground.w, mip + 1), 0, top);
		request(deciding, point.xz);
		float camera_distance = length(point - P.view_to_local[3].xyz);
		float height;
		int found = ground_height(point.xz, deciding, height);
		int read = deciding;
		if (found == 0) {
			// Not resident yet: a coarser page can still show the pixel is off the terrain.
			for (read = deciding + 1; read <= top; read++) {
				found = ground_height(point.xz, read, height);
				if (found != 0) { break; }
			}
			if (found == 1 && abs(point.y - height) <= ground_tolerance(read, camera_distance)) {
				atomicAdd(requests.deferred, 1u);
				return;
			}
			if (found == 0) { atomicAdd(requests.deferred, 1u); return; }
		}
		if (found == 2 || abs(point.y - height) > ground_tolerance(read, camera_distance)) {
			atomicAdd(requests.rejected, 1u);
			return;
		}
	}
	request(mip, point.xz);
	if (mip < top) { request(mip + 1, point.xz); }
}
"""

var _mutex := Mutex.new()
var _lookup_valid := false
var _world_to_local := Transform3D.IDENTITY
var _lookup := Vector4.ZERO
var _anisotropy := 1.0
var _table := Vector4i.ZERO
var _bounds := Rect2()
## The cache's page table and height atlas (set_ground()); their RenderingDevice textures are
## read on the render thread, where the cache replaces them.
var _ground_table: Texture2DRD
var _ground_heights: Texture2DArrayRD
var _ground_layout := Vector2i.ZERO
## Sampled pixels of the last reported viewport rejected as off the terrain, and deferred for a
## deciding page.
var _rejected := 0
var _deferred := 0
## Keys reported since the last take_requests() (a set).
var _keys := {}
var _overflowed := false
var _callbacks := 0
var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _params := RID()
var _requests := RID()
var _seen := RID()
var _sampler := RID()
var _fallback_table := RID()
var _fallback_heights := RID()
var _frame := 0


func _init() -> void:
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_OPAQUE
	access_resolved_depth = true
	RenderingServer.call_on_render_thread(_initialize_render)


## Main thread: the terrain's world-to-local transform and the virtual texture's lookup
## (StrataSurfaceCache.lookup_params() with the shading lod bias in place of the border, and
## lookup_layout()) over terrain-local [param bounds]. Clears the lookup when
## [param table_size] is 0 (the pass then does nothing).
func set_lookup(world_to_local: Transform3D, cell_size: float, page_size: int, top_mip: int, lod_bias: float, max_anisotropy: float, first_page: Vector2i, table_size: int, bounds: Rect2) -> void:
	_mutex.lock()
	_lookup_valid = table_size > 0 and cell_size > 0.0
	_world_to_local = world_to_local
	_lookup = Vector4(cell_size, page_size, top_mip, lod_bias)
	_anisotropy = maxf(max_anisotropy, 1.0)
	_table = Vector4i(first_page.x, first_page.y, table_size, CAPACITY)
	_bounds = bounds
	_mutex.unlock()


## Main thread: the cache's [param page_table] and [param heights] (StrataSurfaceCache
## page_table_texture and height_texture), its atlas layout ([param slots_per_side], slot
## [param border] in cells): pixels then request pages only on or near the terrain surface (see
## the class description). Null textures turn the test off.
func set_ground(page_table: Texture2DRD, heights: Texture2DArrayRD, slots_per_side: int, border: int) -> void:
	_mutex.lock()
	_ground_table = page_table
	_ground_heights = heights
	_ground_layout = Vector2i(slots_per_side, border)
	_mutex.unlock()


## Main thread: the page keys reported since the last call, each once, and whether a viewport
## saw more pages than CAPACITY in a frame.
func take_requests() -> PackedInt32Array:
	_mutex.lock()
	var keys := PackedInt32Array(_keys.keys())
	_keys.clear()
	_mutex.unlock()
	return keys


## Render callbacks run and whether a frame overflowed CAPACITY, since the effect was created;
## of the pixels sampled in the last reported frame, those rejected as off the terrain surface and
## those waiting for their deciding page.
func get_stats() -> Dictionary:
	_mutex.lock()
	var stats := {"callbacks": _callbacks, "overflowed": _overflowed, "rejected_last_frame": _rejected, "deferred_last_frame": _deferred}
	_mutex.unlock()
	return stats


## Frees the GPU objects on the render thread. The callable carries the RIDs, not this effect,
## so it is safe while the effect is being freed.
func release() -> void:
	if _rd == null: return
	var rd := _rd
	var rids: Array[RID] = [_pipeline, _shader, _params, _requests, _seen, _sampler, _fallback_table, _fallback_heights]
	_rd = null
	_pipeline = RID(); _shader = RID(); _params = RID(); _requests = RID(); _seen = RID(); _sampler = RID(); _fallback_table = RID(); _fallback_heights = RID()
	RenderingServer.call_on_render_thread(func() -> void:
		for rid in rids:
			if rid.is_valid(): rd.free_rid(rid))


func _initialize_render() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null: return
	var source := RDShaderSource.new()
	source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	source.source_compute = _GLSL.replace("%GROUND_BAND%", "%.4f" % GROUND_BAND).replace("%GROUND_CELLS%", "%.4f" % GROUND_CELLS).replace("%GROUND_PER_METRE%", "%.4f" % GROUND_PER_METRE)
	var spirv := _rd.shader_compile_spirv_from_source(source)
	if not spirv.compile_error_compute.is_empty():
		push_error("StrataVirtualTextureFeedback: " + spirv.compile_error_compute)
		return
	_shader = _rd.shader_create_from_spirv(spirv, "StrataVirtualTextureFeedback")
	_pipeline = _rd.compute_pipeline_create(_shader)
	_params = _rd.uniform_buffer_create(_PARAMS_BYTES)
	_requests = _rd.storage_buffer_create(16 + CAPACITY * 4)
	_seen = _rd.storage_buffer_create(_SEEN_SLOTS * 4)
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(state)
	# Bound while the cache has no textures (the ground test is then off).
	var format := RDTextureFormat.new()
	format.format = RenderingDevice.DATA_FORMAT_R16_UNORM
	format.width = 1
	format.height = 1
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	_fallback_table = _rd.texture_create(format, RDTextureView.new(), [PackedByteArray([0, 0])])
	format.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	_fallback_heights = _rd.texture_create(format, RDTextureView.new(), [PackedByteArray([0, 0, 0, 0])])


func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if _rd == null or not _pipeline.is_valid() or callback_type != effect_callback_type: return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var scene_data := render_data.get_render_scene_data()
	if buffers == null or scene_data == null: return
	var size := buffers.get_internal_size()
	if size.x < _STRIDE * 2 or size.y < _STRIDE * 2: return
	_mutex.lock()
	var valid := _lookup_valid
	var world_to_local := _world_to_local
	var lookup := _lookup
	var anisotropy := _anisotropy
	var table := _table
	var bounds := _bounds
	var ground_table := _ground_table
	var ground_heights := _ground_heights
	var ground_layout := _ground_layout
	_callbacks += 1
	_mutex.unlock()
	if not valid: return
	var table_rid := ground_table.texture_rd_rid if ground_table != null else RID()
	var heights_rid := ground_heights.texture_rd_rid if ground_heights != null else RID()
	var ground := table_rid.is_valid() and _rd.texture_is_valid(table_rid) and heights_rid.is_valid() and _rd.texture_is_valid(heights_rid) and ground_layout.x > 0
	if not ground:
		table_rid = _fallback_table
		heights_rid = _fallback_heights
	var deciding := clampi(floori(log(DECISION_CELL / lookup.x) / log(2.0)), 0, int(lookup.z)) if lookup.x > 0.0 else 0
	_frame += 1
	var params := PackedByteArray()
	params.resize(_PARAMS_BYTES)
	_encode_projection(params, 0, scene_data.get_cam_projection().inverse())
	_encode_transform(params, 64, world_to_local * scene_data.get_cam_transform())
	params.encode_float(128, lookup.x); params.encode_float(132, lookup.y); params.encode_float(136, lookup.z); params.encode_float(140, lookup.w)
	params.encode_s32(144, table.x); params.encode_s32(148, table.y); params.encode_s32(152, table.z); params.encode_s32(156, table.w)
	params.encode_s32(160, size.x); params.encode_s32(164, size.y)
	# The sampled pixel visits every pixel of the tile in 64 frames, in an order that spreads.
	var step := (_frame * 37) % CYCLE_FRAMES
	params.encode_s32(168, step % _STRIDE); params.encode_s32(172, step / _STRIDE)
	params.encode_float(176, bounds.position.x); params.encode_float(180, bounds.position.y)
	params.encode_float(184, bounds.end.x); params.encode_float(188, bounds.end.y)
	params.encode_float(192, anisotropy)
	params.encode_s32(208, ground_layout.x); params.encode_s32(212, ground_layout.y); params.encode_s32(216, 1 if ground else 0); params.encode_s32(220, deciding)
	_rd.buffer_update(_params, 0, _PARAMS_BYTES, params)
	for view in buffers.get_view_count():
		_rd.buffer_clear(_requests, 0, 16)
		_rd.buffer_clear(_seen, 0, _SEEN_SLOTS * 4)
		var depth := RDUniform.new()
		depth.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		depth.binding = 0
		depth.add_id(_sampler)
		depth.add_id(buffers.get_depth_layer(view))
		var uniforms: Array[RDUniform] = [depth, _buffer_uniform(1, RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, _params), _buffer_uniform(2, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, _requests), _buffer_uniform(3, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, _seen), _texture_uniform(4, table_rid), _texture_uniform(5, heights_rid)]
		var uniform_set := UniformSetCacheRD.get_cache(_shader, 0, uniforms)
		var list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(list, _pipeline)
		_rd.compute_list_bind_uniform_set(list, uniform_set, 0)
		_rd.compute_list_dispatch(list, ceili(size.x / float(_STRIDE * 8)), ceili(size.y / float(_STRIDE * 8)), 1)
		_rd.compute_list_end()
		_rd.buffer_get_data_async(_requests, _on_requests, 0, 16 + CAPACITY * 4)


## The keys one viewport reported, a frame or more after its pass ran.
func _on_requests(data: PackedByteArray) -> void:
	if data.size() < 16: return
	var count := data.decode_u32(0)
	var keys := data.slice(16, 16 + mini(count, CAPACITY) * 4).to_int32_array()
	_mutex.lock()
	for key in keys: _keys[key] = true
	if count > CAPACITY: _overflowed = true
	_rejected = data.decode_u32(4)
	_deferred = data.decode_u32(8)
	_mutex.unlock()


static func _buffer_uniform(binding: int, type: RenderingDevice.UniformType, buffer: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = type
	uniform.binding = binding
	uniform.add_id(buffer)
	return uniform


func _texture_uniform(binding: int, texture: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = binding
	uniform.add_id(_sampler)
	uniform.add_id(texture)
	return uniform


static func _encode_projection(bytes: PackedByteArray, offset: int, p: Projection) -> void:
	var columns := [p.x, p.y, p.z, p.w]
	for c in 4:
		var v: Vector4 = columns[c]
		for r in 4: bytes.encode_float(offset + (c * 4 + r) * 4, v[r])


static func _encode_transform(bytes: PackedByteArray, offset: int, t: Transform3D) -> void:
	var columns := [Vector4(t.basis.x.x, t.basis.x.y, t.basis.x.z, 0.0), Vector4(t.basis.y.x, t.basis.y.y, t.basis.y.z, 0.0),
		Vector4(t.basis.z.x, t.basis.z.y, t.basis.z.z, 0.0), Vector4(t.origin.x, t.origin.y, t.origin.z, 1.0)]
	for c in 4:
		var v: Vector4 = columns[c]
		for r in 4: bytes.encode_float(offset + (c * 4 + r) * 4, v[r])
