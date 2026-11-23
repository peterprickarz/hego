@tool
class_name StrataAOOverlayBaker
extends RefCounted
## Bakes the tiles of a world-space AO overlay (StrataRenderer.set_ao_overlay) on the GPU:
## soft contact-shadow blobs under instances of MultiMeshInstance3D and MeshInstance3D nodes,
## one R8 map per square world tile. See "World-space AO overlay" in docs/strata/reference.md.
##
## A blob sits at an instance's mesh footprint centre (AABB centre, transformed). Its radius is
## either an absolute [code]radius[/code] (metres at instance scale 1) or [code]footprint[/code]
## times half the mesh's larger horizontal AABB side, multiplied by the instance's horizontal
## scale and clamped to [code]max_radius[/code]; its occlusion falls off as
## strength * (1 - d²/r²)². Overlapping blobs multiply: occlusion = max(floor, Π(1 - s·f)).
##
## The rule of a source node, first match wins:
## 1. its [code]metadata_key[/code] metadata (default "strata_ao"), or its mesh's: a Dictionary
##    {radius or footprint, strength}; strength 0 excludes it;
## 2. options.rules[key] for key = options.classify(node) (when given), the mesh file's base name,
##    then the mesh path;
## 3. options.default (a rule Dictionary), when set; otherwise the node is skipped.
##
## Tiles are owned: a tile's map takes the instances whose blob centre lies inside it, plus the
## blobs of neighbouring tiles' edge bands, read from their edge files (instances within
## 2 * max_radius of a tile edge). After a tile is baked, the edge bands of its already-baked
## neighbours are rebaked from these files, so tiles agree along their seams in any bake order.
##
## Needs a rendering device (Forward+ or Mobile; not headless or Compatibility).
##
## layout: {directory, origin (Vector2, world XZ of tile 0,0), tile_size (m), resolution (texels)}.
## Files: <directory>/tile_X_Z.res (Image, R8 without mipmaps, compressed: about 1-3 MB for
## 2048²; StrataAOOverlay builds the mipmaps on load in about 1 ms; absent when the tile is
## unoccluded) and <directory>/edges/tile_X_Z.f32 (float32 x, z, radius, strength per edge blob).

const DEFAULT_OPTIONS := {
	"metadata_key": "strata_ao",
	"rules": {},
	"default": null,
	"classify": null,
	"max_radius": 2.5,
	"floor": 0.3,
	# Only MultiMeshes and meshes drawn no farther than this (visibility_range_end, 0 = no
	# limit) contribute; the overlay fades out at a similar distance.
	"max_range": 0.0,
}
const _FIXED := 65536.0
const _GLSL := """
#version 450
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
layout(set = 0, binding = 0, std430) restrict readonly buffer Data { float d[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer GroupOf { uint group_of[]; };
// Per group, 6 vec4: node transform rows (3), AABB centre + half extent, radius/footprint/strength,
// first instance / float offset / stride.
layout(set = 0, binding = 2, std430) restrict readonly buffer Groups { vec4 groups[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Blobs { vec4 blobs[]; };
layout(set = 0, binding = 4, std430) restrict buffer Density { uint density[]; };
layout(set = 0, binding = 5, std430) restrict buffer Edges { uint edge_count; uint edge_capacity; uint pad0; uint pad1; vec4 edges[]; };
layout(set = 0, binding = 6, std430) restrict writeonly buffer Packed { uint packed_out[]; };
layout(set = 0, binding = 7, std430) restrict buffer Histogram { uint histogram[]; };
layout(push_constant, std430) uniform Params {
	vec2 origin; float texel; float max_radius;
	uint res; uint count; uint mode; float band;
	vec2 size; float floor_value; float pad;
} p;

void splat(vec2 c, float r, float s) {
	r = min(max(r, p.texel), p.max_radius);
	if (s <= 0.0) { return; }
	ivec2 i0 = max(ivec2(ceil((c - vec2(r) - p.origin) / p.texel - 0.5)), ivec2(0));
	ivec2 i1 = min(ivec2(floor((c + vec2(r) - p.origin) / p.texel - 0.5)), ivec2(int(p.res) - 1));
	float inv = 1.0 / (r * r);
	for (int y = i0.y; y <= i1.y; y++) {
		for (int x = i0.x; x <= i1.x; x++) {
			vec2 w = p.origin + (vec2(x, y) + 0.5) * p.texel - c;
			float q = dot(w, w) * inv;
			if (q >= 1.0) { continue; }
			float f = (1.0 - q) * (1.0 - q);
			uint add = uint(-log(1.0 - min(s * f, 0.95)) * 65536.0 + 0.5);
			if (add > 0u) { atomicAdd(density[y * int(p.res) + x], add); }
		}
	}
}

vec3 row_transform(vec4 r0, vec4 r1, vec4 r2, vec3 v, float w) {
	return vec3(dot(r0.xyz, v) + r0.w * w, dot(r1.xyz, v) + r1.w * w, dot(r2.xyz, v) + r2.w * w);
}

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= p.count) { return; }
	if (p.mode == 0u) {
		uint g = group_of[i] * 6u;
		vec4 n0 = groups[g]; vec4 n1 = groups[g + 1u]; vec4 n2 = groups[g + 2u];
		vec4 bounds = groups[g + 3u]; vec4 rule = groups[g + 4u]; vec4 at = groups[g + 5u];
		uint b = uint(at.y) + (i - uint(at.x)) * uint(at.z);
		vec4 i0 = vec4(d[b], d[b + 1u], d[b + 2u], d[b + 3u]);
		vec4 i1 = vec4(d[b + 4u], d[b + 5u], d[b + 6u], d[b + 7u]);
		vec4 i2 = vec4(d[b + 8u], d[b + 9u], d[b + 10u], d[b + 11u]);
		vec3 centre = row_transform(n0, n1, n2, row_transform(i0, i1, i2, bounds.xyz, 1.0), 1.0);
		vec3 column_x = row_transform(n0, n1, n2, vec3(i0.x, i1.x, i2.x), 0.0);
		vec3 column_z = row_transform(n0, n1, n2, vec3(i0.z, i1.z, i2.z), 0.0);
		float scale = max(length(column_x.xz), length(column_z.xz));
		float r = (rule.x > 0.0 ? rule.x : rule.y * bounds.w) * scale;
		vec2 local = centre.xz - p.origin;
		// Owned instances only: neighbours contribute through their edge files.
		if (local.x < 0.0 || local.y < 0.0 || local.x >= p.size.x || local.y >= p.size.y) { return; }
		splat(centre.xz, r, rule.z);
		if (p.band > 0.0 && (local.x < p.band || local.y < p.band || local.x >= p.size.x - p.band || local.y >= p.size.y - p.band)) {
			uint k = atomicAdd(edge_count, 1u);
			if (k < edge_capacity) { edges[k] = vec4(centre.xz, min(max(r, p.texel), p.max_radius), rule.z); }
		}
	} else if (p.mode == 1u) {
		vec4 blob = blobs[i];
		splat(blob.xy, blob.z, blob.w);
	} else {
		uint word = 0u;
		for (uint k = 0u; k < 4u; k++) {
			float occlusion = max(p.floor_value, exp(-float(density[i * 4u + k]) / 65536.0));
			uint value = uint(clamp(occlusion, 0.0, 1.0) * 255.0 + 0.5);
			atomicAdd(histogram[value], 1u);
			word |= value << (8u * k);
		}
		packed_out[i] = word;
	}
}
"""

static var _rd: RenderingDevice
static var _shader: RID
static var _pipeline: RID


static func options_with_defaults(options: Dictionary) -> Dictionary:
	var result := DEFAULT_OPTIONS.duplicate(true)
	result.merge(options, true)
	return result


static func tile_rect(layout: Dictionary, tile: Vector2i) -> Rect2:
	var size := float(layout.tile_size)
	return Rect2(Vector2(layout.get("origin", Vector2.ZERO)) + Vector2(tile) * size, Vector2(size, size))


static func tile_of(layout: Dictionary, world_xz: Vector2) -> Vector2i:
	var local := (world_xz - Vector2(layout.get("origin", Vector2.ZERO))) / float(layout.tile_size)
	return Vector2i(floori(local.x), floori(local.y))


static func tile_path(layout: Dictionary, tile: Vector2i) -> String:
	return str(layout.directory).path_join("tile_%d_%d.res" % [tile.x, tile.y])


static func edges_path(layout: Dictionary, tile: Vector2i) -> String:
	return str(layout.directory).path_join("edges").path_join("tile_%d_%d.f32" % [tile.x, tile.y])


## True when a rendering device for the bake is available.
static func available() -> bool:
	return _device()


static func _device() -> bool:
	if _rd != null: return true
	if DisplayServer.get_name() == "headless": return false
	var device := RenderingServer.create_local_rendering_device()
	if device == null: return false
	var source := RDShaderSource.new()
	source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	source.source_compute = _GLSL
	var spirv := device.shader_compile_spirv_from_source(source)
	if not spirv.compile_error_compute.is_empty():
		push_error("StrataAOOverlayBaker: compute shader: " + spirv.compile_error_compute)
		device.free()
		return false
	_shader = device.shader_create_from_spirv(spirv)
	_pipeline = device.compute_pipeline_create(_shader)
	_rd = device
	return true


# ─────────────────────────────────────────────
# Sources
# ─────────────────────────────────────────────

## The rule of [param node] (see the class description), or {} when it does not contribute.
static func rule_for(node: GeometryInstance3D, mesh: Mesh, options: Dictionary) -> Dictionary:
	var key := str(options.get("metadata_key", "strata_ao"))
	for holder: Object in [node, mesh]:
		if holder != null and holder.has_meta(key) and holder.get_meta(key) is Dictionary:
			return holder.get_meta(key)
	var rules: Dictionary = options.get("rules", {})
	var classify: Variant = options.get("classify")
	if classify is Callable and (classify as Callable).is_valid():
		var name := str((classify as Callable).call(node))
		if rules.has(name): return rules[name]
	if mesh != null and not mesh.resource_path.is_empty():
		var base := mesh.resource_path.get_file().get_basename()
		if rules.has(base): return rules[base]
		if rules.has(mesh.resource_path): return rules[mesh.resource_path]
	var fallback: Variant = options.get("default")
	return fallback if fallback is Dictionary else {}


## World transform of [param node], also for nodes outside the scene tree (loaded scenes).
static func world_transform(node: Node3D) -> Transform3D:
	if node.is_inside_tree(): return node.global_transform
	var result := node.transform
	var parent := node.get_parent()
	while parent is Node3D:
		result = (parent as Node3D).transform * result
		parent = parent.get_parent()
	return result


## Gathers the instances of every MultiMeshInstance3D and MeshInstance3D in [param roots] (and
## below them) that have a rule. With a non-empty [param rect], only nodes whose world AABB
## reaches it (grown by max_radius) are kept. Returns {data, group_of, groups, instances, nodes,
## by_key}, the input of bake().
static func collect(roots: Array, options: Dictionary, rect := Rect2()) -> Dictionary:
	options = options_with_defaults(options)
	var data := PackedFloat32Array()
	var group_of := PackedInt32Array()
	var groups := PackedFloat32Array()
	var instances := 0
	var by_key := {}
	var seen := {}
	var max_range := float(options.max_range)
	var reach := rect.grow(float(options.max_radius)) if rect.has_area() else Rect2()
	var classify: Variant = options.get("classify")
	for root: Variant in roots:
		if not root is Node: continue
		var nodes: Array = [root] + (root as Node).find_children("*", "GeometryInstance3D", true, false)
		for node: Variant in nodes:
			if not (node is MultiMeshInstance3D or node is MeshInstance3D) or seen.has(node): continue
			seen[node] = true
			var geometry := node as GeometryInstance3D
			if max_range > 0.0 and (geometry.visibility_range_end <= 0.0 or geometry.visibility_range_end > max_range): continue
			var mesh: Mesh
			var buffer: PackedFloat32Array
			var count := 0
			var stride := 12
			if node is MultiMeshInstance3D:
				var multimesh := (node as MultiMeshInstance3D).multimesh
				if multimesh == null or multimesh.mesh == null or multimesh.instance_count == 0 or multimesh.transform_format != MultiMesh.TRANSFORM_3D: continue
				mesh = multimesh.mesh
				count = multimesh.visible_instance_count if multimesh.visible_instance_count >= 0 else multimesh.instance_count
				buffer = multimesh.buffer
				stride = buffer.size() / multimesh.instance_count if multimesh.instance_count > 0 else 0
				if stride < 12 or count <= 0: continue
			else:
				mesh = (node as MeshInstance3D).mesh
				if mesh == null: continue
				count = 1
				buffer = PackedFloat32Array([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0])
			var rule := rule_for(geometry, mesh, options)
			if rule.is_empty() or float(rule.get("strength", 0.0)) <= 0.0: continue
			var xform := world_transform(geometry)
			if reach.has_area():
				var box := xform * ((node as MultiMeshInstance3D).multimesh.get_aabb() if node is MultiMeshInstance3D else mesh.get_aabb())
				if not reach.intersects(Rect2(box.position.x, box.position.z, box.size.x, box.size.z), true): continue
			var aabb := mesh.get_aabb()
			var centre := aabb.get_center()
			var b := xform.basis
			var o := xform.origin
			groups.append_array([b.x.x, b.y.x, b.z.x, o.x, b.x.y, b.y.y, b.z.y, o.y, b.x.z, b.y.z, b.z.z, o.z,
				centre.x, centre.y, centre.z, maxf(aabb.size.x, aabb.size.z) * 0.5,
				float(rule.get("radius", 0.0)), float(rule.get("footprint", 1.0)), clampf(float(rule.strength), 0.0, 0.95), 0.0,
				float(instances), float(data.size()), float(stride), 0.0])
			data.append_array(buffer)
			var ids := PackedInt32Array()
			ids.resize(count)
			ids.fill(groups.size() / 24 - 1)
			group_of.append_array(ids)
			instances += count
			var key := str((classify as Callable).call(node)) if classify is Callable and (classify as Callable).is_valid() else mesh.resource_path.get_file().get_basename()
			by_key[key] = int(by_key.get(key, 0)) + count
	if data.size() >= 16777216:
		push_warning("StrataAOOverlayBaker: more than 16 M floats of instance data; split the bake.")
	return {"data": data, "group_of": group_of, "groups": groups, "instances": instances, "by_key": by_key}


# ─────────────────────────────────────────────
# GPU bake
# ─────────────────────────────────────────────

static func _storage(bytes: PackedByteArray) -> RID:
	if bytes.size() < 16: bytes.resize(16)
	return _rd.storage_buffer_create(bytes.size(), bytes)


static func _uniform(binding: int, buffer: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = binding
	uniform.add_id(buffer)
	return uniform


static func _push(rect: Rect2, texel: float, resolution: int, count: int, mode: int, band: float, options: Dictionary) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(48)
	bytes.encode_float(0, rect.position.x); bytes.encode_float(4, rect.position.y)
	bytes.encode_float(8, texel); bytes.encode_float(12, float(options.max_radius))
	bytes.encode_u32(16, resolution); bytes.encode_u32(20, count); bytes.encode_u32(24, mode)
	bytes.encode_float(28, band)
	bytes.encode_float(32, rect.size.x); bytes.encode_float(36, rect.size.y)
	bytes.encode_float(40, float(options.floor)); bytes.encode_float(44, 0.0)
	return bytes


## Rasterizes [param collected] (from collect(); only instances inside [param rect]) and the
## world blobs [param blobs] (x, z, radius, strength per blob) into a [param resolution]² R8
## image over [param rect]. With [param edge_band] > 0, also returns the collected blobs within
## that distance of the rect's edges. Returns {ok, image, edges, histogram, gpu_ms}.
static func bake(rect: Rect2, resolution: int, collected: Dictionary, blobs: PackedFloat32Array, options: Dictionary, edge_band := 0.0) -> Dictionary:
	options = options_with_defaults(options)
	if not _device():
		return {"ok": false, "message": "no rendering device (headless or Compatibility renderer)"}
	if resolution < 4 or resolution % 4 != 0 or not rect.has_area():
		return {"ok": false, "message": "invalid rect or resolution"}
	var started := Time.get_ticks_usec()
	var instances := int(collected.get("instances", 0))
	var blob_count := blobs.size() / 4
	var texels := resolution * resolution
	var edge_header := PackedByteArray()
	edge_header.resize(16 + 16 * maxi(instances, 1))
	edge_header.encode_u32(4, instances)
	var buffers := [
		_storage((collected.get("data", PackedFloat32Array()) as PackedFloat32Array).to_byte_array()),
		_storage((collected.get("group_of", PackedInt32Array()) as PackedInt32Array).to_byte_array()),
		_storage((collected.get("groups", PackedFloat32Array()) as PackedFloat32Array).to_byte_array()),
		_storage(blobs.to_byte_array()),
		_rd.storage_buffer_create(texels * 4),
		_rd.storage_buffer_create(edge_header.size(), edge_header),
		_rd.storage_buffer_create(texels),
		_rd.storage_buffer_create(256 * 4),
	]
	_rd.buffer_clear(buffers[4], 0, texels * 4)
	_rd.buffer_clear(buffers[7], 0, 256 * 4)
	var uniforms: Array[RDUniform] = []
	for i in buffers.size(): uniforms.append(_uniform(i, buffers[i]))
	var uniform_set := _rd.uniform_set_create(uniforms, _shader, 0)
	var texel := rect.size.x / resolution
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	if instances > 0:
		var push := _push(rect, texel, resolution, instances, 0, edge_band, options)
		_rd.compute_list_set_push_constant(list, push, push.size())
		_rd.compute_list_dispatch(list, ceili(instances / 64.0), 1, 1)
	if blob_count > 0:
		_rd.compute_list_add_barrier(list)
		var push := _push(rect, texel, resolution, blob_count, 1, 0.0, options)
		_rd.compute_list_set_push_constant(list, push, push.size())
		_rd.compute_list_dispatch(list, ceili(blob_count / 64.0), 1, 1)
	_rd.compute_list_add_barrier(list)
	var finish := _push(rect, texel, resolution, texels / 4, 2, 0.0, options)
	_rd.compute_list_set_push_constant(list, finish, finish.size())
	_rd.compute_list_dispatch(list, ceili(texels / 4 / 64.0), 1, 1)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()
	var image := Image.create_from_data(resolution, resolution, false, Image.FORMAT_R8, _rd.buffer_get_data(buffers[6]))
	var histogram := _rd.buffer_get_data(buffers[7]).to_int32_array()
	var edges := PackedFloat32Array()
	if edge_band > 0.0 and instances > 0:
		var found := mini(_rd.buffer_get_data(buffers[5], 0, 4).decode_u32(0), instances)
		if found > 0:
			edges = _rd.buffer_get_data(buffers[5], 16, found * 16).to_float32_array()
	_rd.free_rid(uniform_set)
	for buffer: RID in buffers: _rd.free_rid(buffer)
	return {"ok": true, "image": image, "edges": edges, "histogram": histogram,
		"gpu_ms": (Time.get_ticks_usec() - started) / 1000.0}


## min, mean and the share of texels below 1 (occluded) from a bake histogram.
static func histogram_stats(histogram: PackedInt32Array) -> Dictionary:
	var total := 0
	var weighted := 0.0
	var minimum := 255
	for value in histogram.size():
		var n := histogram[value]
		if n <= 0: continue
		total += n
		weighted += value * n
		minimum = mini(minimum, value)
	var occluded := total - (histogram[255] if histogram.size() > 255 else 0)
	return {"min": minimum / 255.0, "mean": weighted / maxf(total, 1) / 255.0,
		"occluded_fraction": float(occluded) / maxf(total, 1), "texels": total}


# ─────────────────────────────────────────────
# Tiles
# ─────────────────────────────────────────────

static func _read_edges(path: String) -> PackedFloat32Array:
	if not FileAccess.file_exists(path): return PackedFloat32Array()
	return FileAccess.get_file_as_bytes(path).to_float32_array()


static func _neighbour_blobs(layout: Dictionary, tile: Vector2i) -> PackedFloat32Array:
	var blobs := PackedFloat32Array()
	for dz in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			if dx != 0 or dz != 0:
				blobs.append_array(_read_edges(edges_path(layout, tile + Vector2i(dx, dz))))
	return blobs


## Saves [param image] (mip 0) as the tile's map, or deletes the map when every texel is 255. Returns the file size in bytes (0 when removed).
static func save_tile_image(layout: Dictionary, tile: Vector2i, image: Image, occluded: bool) -> int:
	var path := tile_path(layout, tile)
	if not occluded:
		if FileAccess.file_exists(path):
			var removal := DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
			if removal != OK:
				push_error("StrataAOOverlayBaker: could not remove empty tile %s (%s)" % [path, error_string(removal)])
				return -1
		return 0
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	image.clear_mipmaps()
	var error := ResourceSaver.save(image, path, ResourceSaver.FLAG_COMPRESS)
	if error != OK:
		push_error("StrataAOOverlayBaker: could not save %s (%s)" % [path, error_string(error)])
		return -1
	return FileAccess.get_file_as_bytes(path).size()


## Bakes [param tile] from the instances of [param roots] whose blob centre lies in the tile,
## plus its neighbours' edge files; writes the map and the tile's edge file, then rebakes the
## edge bands of neighbouring tiles that have an edge file. A batch can defer
## neighbour repairs until every changed tile has published its edge file.
static func bake_tile(layout: Dictionary, tile: Vector2i, roots: Array, options: Dictionary, repair_neighbours := true) -> Dictionary:
	options = options_with_defaults(options)
	var started := Time.get_ticks_usec()
	var rect := tile_rect(layout, tile)
	var resolution := int(layout.get("resolution", 2048))
	var collected := collect(roots, options, rect)
	# Optional procedural footprints use the same GPU splat and seam cache as
	# ordinary mesh instances. The provider receives this tile's world rectangle.
	var owned_blobs := PackedFloat32Array()
	var owned_edges := PackedFloat32Array()
	var blob_source: Variant = options.get("blob_source")
	var band := 2.0 * float(options.max_radius)
	if blob_source is Callable and (blob_source as Callable).is_valid():
		var supplied: PackedFloat32Array = blob_source.call(rect)
		for i in range(0, supplied.size() - 3, 4):
			var centre := Vector2(supplied[i], supplied[i + 1])
			if not centre.is_finite() or not rect.has_point(centre): continue
			var radius := supplied[i + 2]
			var strength := supplied[i + 3]
			if not is_finite(radius) or not is_finite(strength) or radius <= 0.0 or strength <= 0.0: continue
			var blob := PackedFloat32Array([centre.x, centre.y, minf(radius, float(options.max_radius)), minf(strength, 0.95)])
			owned_blobs.append_array(blob)
			var local := centre - rect.position
			if local.x < band or local.y < band or local.x >= rect.size.x - band or local.y >= rect.size.y - band:
				owned_edges.append_array(blob)
	var collect_ms := (Time.get_ticks_usec() - started) / 1000.0
	var blobs := _neighbour_blobs(layout, tile)
	blobs.append_array(owned_blobs)
	var result := bake(rect, resolution, collected, blobs, options, band)
	if not result.ok:
		return {"ok": false, "tile": tile, "message": "AO overlay bake: " + str(result.message)}
	var stats := histogram_stats(result.histogram)
	var bytes := save_tile_image(layout, tile, result.image, stats.occluded_fraction > 0.0)
	var edges: PackedFloat32Array = result.edges
	edges.append_array(owned_edges)
	var edge_file := edges_path(layout, tile)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(edge_file.get_base_dir()))
	var file := FileAccess.open(edge_file, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "tile": tile, "message": "Cannot save AO edge file: " + edge_file}
	file.store_buffer(edges.to_byte_array())
	file.close()
	var neighbours := []
	if repair_neighbours:
		for dz in [-1, 0, 1]:
			for dx in [-1, 0, 1]:
				var other := tile + Vector2i(dx, dz)
				if (dx != 0 or dz != 0) and FileAccess.file_exists(edges_path(layout, other)):
					if rebake_tile_edges(layout, other, options):
						neighbours.append(other)
	var report := {"ok": bytes >= 0, "tile": tile, "path": tile_path(layout, tile) if bytes > 0 else "",
		"instances": collected.instances, "by_key": collected.by_key, "edge_blobs": edges.size() / 4,
		"procedural_blobs": owned_blobs.size() / 4,
		"bytes": bytes, "collect_ms": collect_ms, "gpu_ms": result.gpu_ms, "neighbours_rebaked": neighbours,
		"ms": (Time.get_ticks_usec() - started) / 1000.0}
	report.merge(stats)
	return report


## Rebakes the band of max_radius along every edge of [param tile]'s map from the edge files of
## the tile and its neighbours (its interior depends on its own instances only and is kept).
static func rebake_tile_edges(layout: Dictionary, tile: Vector2i, options: Dictionary) -> bool:
	options = options_with_defaults(options)
	var rect := tile_rect(layout, tile)
	var resolution := int(layout.get("resolution", 2048))
	var blobs := _read_edges(edges_path(layout, tile))
	blobs.append_array(_neighbour_blobs(layout, tile))
	var path := tile_path(layout, tile)
	var exists := FileAccess.file_exists(path)
	if blobs.is_empty() and not exists: return false
	var result := bake(rect, resolution, {}, blobs, options)
	if not result.ok: return false
	var image: Image
	if exists:
		image = ResourceLoader.load(path, "Image", ResourceLoader.CACHE_MODE_IGNORE) as Image
	if image == null or image.get_width() != resolution or image.get_format() != Image.FORMAT_R8:
		image = Image.create(resolution, resolution, false, Image.FORMAT_R8)
		image.fill(Color(1, 1, 1))
	image.clear_mipmaps()
	var fresh: Image = result.image
	var width := mini(ceili(float(options.max_radius) / (rect.size.x / resolution)) + 1, resolution / 2)
	for strip: Rect2i in [Rect2i(0, 0, resolution, width), Rect2i(0, resolution - width, resolution, width),
			Rect2i(0, 0, width, resolution), Rect2i(resolution - width, 0, width, resolution)]:
		image.blit_rect(fresh, strip, strip.position)
	# An existing map is kept; a tile without one gets one when the blobs reach it.
	var occluded: bool = exists or histogram_stats(result.histogram).occluded_fraction > 0.0
	return save_tile_image(layout, tile, image, occluded) >= 0
