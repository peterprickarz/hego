@tool
extends CompositorEffect
## Depth pass of Copia's HIDDEN debug view (see copia_debug.gd and
## shaders/copia_debug_hidden.gdshader): before the transparent pass of each viewport whose
## compositor holds it (the opaque depth is then complete), reduces the depth buffer to a
## farthest-depth pyramid that the debug materials read in that transparent pass. It runs at
## [constant CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT] because the Mobile renderer
## calls no post-opaque effect (checked in 4.7.2); Forward+ calls both.
##
## Depth is reversed (1 near, 0 far), so the farthest of several depths is their minimum. Level 0
## holds the farthest depth of each 2 x 2 pixels of the viewport's internal resolution, rounded up
## (an odd last column or row covers one pixel); level n + 1 holds the farthest of each 2 x 2
## texels of level n, rounded up the same way, down to 1 x 1. A pixel p therefore lies in texel
## p >> (n + 1) of level n, and every texel holds the farthest depth of all pixels it covers.
##
## All viewports share one square power-of-two texture, sized for the largest internal resolution
## seen and only grown: the editor renders up to four 3D viewports a frame, and each writes its
## pyramid into the top-left region before its own transparent pass and reads it there before the
## next viewport overwrites it. A larger size is noticed by the render callback,
## which skips that frame; [method update] (main thread) then reallocates before the next frame.
##
## With MSAA the effect asks for the resolved depth ([member CompositorEffect.access_resolved_depth])
## and reads the single-sample depth texture. The Mobile renderer does not resolve depth for
## effects (it warns once): with MSAA on Mobile the pyramid stays far and every instance shows as
## visible. Only the first view of a multiview (XR) viewport is reduced.

const _GROUP := 8

const _DEPTH_GLSL := """#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D depth_texture;
layout(r32f, set = 0, binding = 1) uniform restrict writeonly image2D destination;
layout(push_constant, std430) uniform Params { ivec2 source_size; ivec2 destination_size; } p;
void main() {
	ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(texel, p.destination_size))) { return; }
	ivec2 a = texel * 2;
	ivec2 b = min(a + 1, p.source_size - 1);
	float depth = min(min(texelFetch(depth_texture, a, 0).r, texelFetch(depth_texture, ivec2(b.x, a.y), 0).r),
			min(texelFetch(depth_texture, ivec2(a.x, b.y), 0).r, texelFetch(depth_texture, b, 0).r));
	imageStore(destination, texel, vec4(depth));
}
"""

const _LEVEL_GLSL := """#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(r32f, set = 0, binding = 0) uniform restrict readonly image2D source;
layout(r32f, set = 0, binding = 1) uniform restrict writeonly image2D destination;
layout(push_constant, std430) uniform Params { ivec2 source_size; ivec2 destination_size; } p;
void main() {
	ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(texel, p.destination_size))) { return; }
	ivec2 a = texel * 2;
	ivec2 b = min(a + 1, p.source_size - 1);
	float depth = min(min(imageLoad(source, a).r, imageLoad(source, ivec2(b.x, a.y)).r),
			min(imageLoad(source, ivec2(a.x, b.y)).r, imageLoad(source, b).r));
	imageStore(destination, texel, vec4(depth));
}
"""

## The pyramid, for the debug materials' [code]pyramid[/code] uniform.
var pyramid := Texture2DRD.new()

var _mutex := Mutex.new()
var _wanted := 1  # side the render callback asked for (largest seen)
var _requested := 1  # side last handed to the render thread
var _callbacks := 0
var _skipped := 0
var _rd: RenderingDevice
var _depth_shader := RID()
var _depth_pipeline := RID()
var _level_shader := RID()
var _level_pipeline := RID()
var _sampler := RID()
var _texture := RID()
var _views: Array[RID] = []  # one storage view per level
var _side := 0  # side of level 0 of _texture (render thread)


func _init() -> void:
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
	access_resolved_depth = true
	RenderingServer.call_on_render_thread(_initialize_render)


## Main thread, once a frame while the view is on: allocates a larger pyramid when a viewport
## needed one.
func update() -> void:
	_mutex.lock()
	var wanted := _wanted
	_mutex.unlock()
	if wanted > _requested:
		_requested = wanted
		RenderingServer.call_on_render_thread(_allocate.bind(wanted))


## Render callbacks run, and those skipped while the pyramid was too small, since creation; the
## pyramid's level-0 side.
func get_stats() -> Dictionary:
	_mutex.lock()
	var stats := {"callbacks": _callbacks, "skipped": _skipped, "side": _requested}
	_mutex.unlock()
	return stats


## Frees the GPU objects on the render thread. The callable carries the RIDs, not this effect.
func release() -> void:
	if _rd == null: return
	var rd := _rd
	var wrapper := pyramid
	var textures: Array[RID] = []
	textures.append_array(_views)
	textures.append(_texture)
	var pipelines: Array[RID] = [_depth_pipeline, _level_pipeline]
	var others: Array[RID] = [_depth_shader, _level_shader, _sampler]
	_rd = null
	_views = []
	_texture = RID(); _depth_pipeline = RID(); _depth_shader = RID(); _level_pipeline = RID(); _level_shader = RID(); _sampler = RID()
	RenderingServer.call_on_render_thread(func() -> void:
		wrapper.texture_rd_rid = RID()
		# Views go with their texture, pipelines with their shader: free only what is left.
		for rid in textures:
			if rid.is_valid() and rd.texture_is_valid(rid): rd.free_rid(rid)
		for rid in pipelines:
			if rid.is_valid() and rd.compute_pipeline_is_valid(rid): rd.free_rid(rid)
		for rid in others:
			if rid.is_valid(): rd.free_rid(rid))


# Level-0 side of the square pyramid for a viewport of [param size] pixels: a power of two at
# least half the larger dimension, so every level of the viewport's region fits its mip.
static func side_for(size: Vector2i) -> int:
	var half := maxi((maxi(size.x, size.y) + 1) / 2, 1)
	return nearest_po2(half)


func _initialize_render() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null: return
	_depth_shader = _compile(_DEPTH_GLSL, "CopiaHiddenDepth")
	_level_shader = _compile(_LEVEL_GLSL, "CopiaHiddenLevel")
	if not _depth_shader.is_valid() or not _level_shader.is_valid():
		_rd = null
		return
	_depth_pipeline = _rd.compute_pipeline_create(_depth_shader)
	_level_pipeline = _rd.compute_pipeline_create(_level_shader)
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(state)
	_allocate(1)


func _compile(glsl: String, label: String) -> RID:
	var source := RDShaderSource.new()
	source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	source.source_compute = glsl
	var spirv := _rd.shader_compile_spirv_from_source(source)
	if not spirv.compile_error_compute.is_empty():
		push_error("Copia hidden view: " + spirv.compile_error_compute)
		return RID()
	return _rd.shader_create_from_spirv(spirv, label)


# Render thread: a pyramid of level-0 side [param side] (a power of two), cleared to far (0), so
# a region no pass has written yet shows every instance as visible.
func _allocate(side: int) -> void:
	if _rd == null or side <= _side: return
	var levels := int(round(log(float(side)) / log(2.0))) + 1
	var format := RDTextureFormat.new()
	format.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.width = side
	format.height = side
	format.mipmaps = levels
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	var texture := _rd.texture_create(format, RDTextureView.new(), [])
	if not texture.is_valid(): return
	_rd.texture_clear(texture, Color(0, 0, 0, 0), 0, levels, 0, 1)
	var views: Array[RID] = []
	for level in levels:
		views.append(_rd.texture_create_shared_from_slice(RDTextureView.new(), texture, 0, level, 1, RenderingDevice.TEXTURE_SLICE_2D))
	var old_views := _views
	var old := _texture
	_texture = texture
	_views = views
	_side = side
	pyramid.texture_rd_rid = texture
	for view in old_views:
		if view.is_valid() and _rd.texture_is_valid(view): _rd.free_rid(view)
	if old.is_valid() and _rd.texture_is_valid(old): _rd.free_rid(old)


func _render_callback(callback_type: int, render_data: RenderData) -> void:
	# Locals: release() clears the members on the main thread.
	var rd := _rd
	var views := _views
	if rd == null or views.is_empty() or callback_type != effect_callback_type: return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null: return
	var size := buffers.get_internal_size()
	if size.x < 1 or size.y < 1: return
	var side := side_for(size)
	_mutex.lock()
	_callbacks += 1
	if side > _side:
		_wanted = maxi(_wanted, side)
		_skipped += 1
	_mutex.unlock()
	if side > _side: return
	var source_size := size
	var destination_size := Vector2i((size.x + 1) / 2, (size.y + 1) / 2)
	var level := 0
	while true:
		var uniforms: Array[RDUniform] = []
		if level == 0:
			var depth := RDUniform.new()
			depth.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
			depth.binding = 0
			depth.add_id(_sampler)
			depth.add_id(buffers.get_depth_layer(0))
			uniforms.append(depth)
		else:
			uniforms.append(_image_uniform(0, views[level - 1]))
		uniforms.append(_image_uniform(1, views[level]))
		var uniform_set := UniformSetCacheRD.get_cache(_depth_shader if level == 0 else _level_shader, 0, uniforms)
		var push := PackedInt32Array([source_size.x, source_size.y, destination_size.x, destination_size.y]).to_byte_array()
		var list := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(list, _depth_pipeline if level == 0 else _level_pipeline)
		rd.compute_list_bind_uniform_set(list, uniform_set, 0)
		rd.compute_list_set_push_constant(list, push, push.size())
		rd.compute_list_dispatch(list, ceili(destination_size.x / float(_GROUP)), ceili(destination_size.y / float(_GROUP)), 1)
		rd.compute_list_end()
		if (destination_size.x <= 1 and destination_size.y <= 1) or level + 1 >= views.size(): break
		source_size = destination_size
		destination_size = Vector2i((source_size.x + 1) / 2, (source_size.y + 1) / 2)
		level += 1


static func _image_uniform(binding: int, texture: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = binding
	uniform.add_id(texture)
	return uniform
