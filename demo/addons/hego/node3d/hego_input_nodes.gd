@tool
class_name HEGoInputNodes
extends RefCounted

## Turns the Godot nodes wired into a [HEGoNode3D] into HEGo input nodes.
##
## Which input node a Godot node needs depends on its type: paths become curve
## inputs, meshes and CSG shapes become geometry inputs, a [HEGoGraphInput3D]
## becomes points and polyline primitives, and a Terrain3D becomes a heightfield
## input. The node path of the source is always sent along as
## [code]_hego_node_path[/code] so an HDA can tell its inputs apart.

## Category this file logs under, shown in the session panel filter.
const LOG_CATEGORY := "input"

## Attributes attached to every input.
const NODE_PATH_ATTRIB := "_hego_node_path"
const RESOURCE_PATH_ATTRIB := "_hego_resource_path"
const SURFACE_MATERIAL_ATTRIB_PREFIX := "_hego_surface_override_material_"

## Value used for a surface that has no override material.
const NO_MATERIAL := "empty"

## Spacing, in metres, a Path3D input is resampled at before it is sent to Houdini.
const CURVE_SAMPLE_LENGTH := 1.0


## Expands input roots when settings.include_children is enabled. The stored paths
## remain compact; descendants are discovered again on every cook in scene order.
## Overlapping selections contribute each source once. Hidden authoring nodes are
## included, but this host's generated Outputs and CSG Boolean operands are not.
static func resolve_paths(host: Node, paths: Array, settings: Dictionary) -> Array:
	if not settings.get("include_children", false):
		var explicit: Array = []
		for path in paths:
			var node := _resolve_input_node(host, path)
			if node != null and is_compatible_source(node) and not node.is_queued_for_deletion():
				explicit.append(path)
			elif not str(path).is_empty():
				HEGoLog.get_singleton().warning(LOG_CATEGORY, "Input %s has no compatible source; containers need Include Children enabled." % str(path))
		# Removing invalid sources also disconnects an old child when a user turns
		# expansion off but leaves its parent selected.
		return explicit
	var resolved: Array = []
	var visited := {}
	var outputs := host.get_node_or_null(HEGoNodeUtil.OUTPUTS_ROOT_NAME)
	for path in paths:
		var source := _resolve_input_node(host, path)
		if source == null:
			if not str(path).is_empty():
				HEGoLog.get_singleton().warning(LOG_CATEGORY, "Input parent %s could not be found, skipping it." % str(path))
			continue
		_collect_sources(host, source, outputs, visited, resolved)
	return resolved


## Whether a node supplies one of HEGo's supported input kinds. CSG assemblies
## bake from their root shape, including all of their Boolean children.
static func is_compatible_source(node: Node) -> bool:
	if node is HEGoGraphInput3D:
		return not node.points.is_empty()
	if node is Path3D:
		return node.curve != null and node.curve.point_count > 0
	if node is MeshInstance3D:
		return node.mesh != null
	if node is CSGShape3D:
		return node.is_root_shape()
	return HEGoTerrain3DUtil.is_available() and node.is_class("Terrain3D")


static func _collect_sources(host: Node, node: Node, outputs: Node, visited: Dictionary, resolved: Array) -> void:
	if (outputs != null and (node == outputs or outputs.is_ancestor_of(node))) or node.is_queued_for_deletion() or visited.has(node.get_instance_id()):
		return
	visited[node.get_instance_id()] = true
	if is_compatible_source(node):
		resolved.append(_source_path(host, node))
	# A baked CSG root already contains its operands; uploading them again changes
	# the Boolean result and can duplicate faces. Treat that assembly as one source.
	if node is CSGShape3D:
		return
	for child in node.get_children():
		_collect_sources(host, child, outputs, visited, resolved)


static func _source_path(host: Node, node: Node) -> String:
	var tree := host.get_tree()
	if tree != null:
		for scene in [tree.edited_scene_root, tree.current_scene]:
			if scene != null and (scene == node or scene.is_ancestor_of(node)):
				return str(scene.get_path_to(node))
	# Also support tools/tests without a current scene. Absolute paths avoid an
	# ambiguous host-relative path resolving against a different scene node.
	return str(node.get_path())


## Creates or updates the input node for the Godot node at [param input_node_path].
##
## Pass the previous input node as [param existing_node] to reuse it when the source
## node still has the same type; pass null to always create a fresh one. Returns the
## input node to store, which is [param existing_node] itself when it was reused.
##
## [param settings] is the per-input settings dictionary from the input stash.
## curve_sample_length optionally controls Path3D upload spacing in metres.
## Missing, non-finite or non-positive values use the one-metre default.
static func sync(host: Node, existing_node: Variant, input_node_path: Variant, settings: Dictionary) -> Variant:
	var input := _resolve_input_node(host, input_node_path)
	if input == null:
		HEGoLog.get_singleton().warning(LOG_CATEGORY, "Input node %s could not be found, skipping it." % str(input_node_path))
		return existing_node

	var attrs := [{
		"name": NODE_PATH_ATTRIB,
		"type": "prim",
		"value": input_node_path,
	}]

	if input is HEGoGraphInput3D:
		var counts := PackedInt32Array()
		counts.resize(input.connection_count())
		counts.fill(2)
		var graph_attrs := []
		if input.connection_count() > 0:
			graph_attrs.append({
				"name": NODE_PATH_ATTRIB,
				"type": "prim",
				"value": input_node_path,
			})
		elif input.points.size() > 0:
			graph_attrs.append({
				"name": NODE_PATH_ATTRIB,
				"type": "point",
				"value": input_node_path,
			})
		graph_attrs.append_array(_graph_attribs(input))
		var graph_node: HEGoInputNode = existing_node if existing_node is HEGoInputNode else HEGoInputNode.new()
		await HEGoNodeUtil.await_task(host, graph_node.instantiate())
		await HEGoNodeUtil.await_task(host, graph_node.set_geo(input.points, "polyline", input.connections, counts, graph_attrs))
		await HEGoNodeUtil.await_task(host, graph_node.set_transform(input.global_transform))
		return graph_node

	if input is Path3D:
		var curve_node: HEGoCurveInputNode = existing_node if existing_node is HEGoCurveInputNode else HEGoCurveInputNode.new()
		await HEGoNodeUtil.await_task(host, curve_node.instantiate())
		var spacing := float(settings.get("curve_sample_length", CURVE_SAMPLE_LENGTH))
		if not is_finite(spacing) or spacing <= 0.0:
			spacing = CURVE_SAMPLE_LENGTH
		await HEGoNodeUtil.await_task(host, curve_node.set_curve_from_path_3d(input, maxf(0.01, spacing)))
		return curve_node

	if input is MeshInstance3D:
		if input.mesh == null:
			HEGoLog.get_singleton().warning(LOG_CATEGORY, "Input %s has no mesh, skipping it." % str(input_node_path))
			return existing_node
		attrs.append({
			"name": RESOURCE_PATH_ATTRIB,
			"type": "prim",
			"value": input.mesh.resource_path,
		})
		attrs.append_array(_material_attribs(input))
		var mesh_node: HEGoInputNode = existing_node if existing_node is HEGoInputNode else HEGoInputNode.new()
		await HEGoNodeUtil.await_task(host, mesh_node.instantiate())
		await HEGoNodeUtil.await_task(host, mesh_node.set_geo_from_mesh(input.mesh, attrs))
		await HEGoNodeUtil.await_task(host, mesh_node.set_transform(input.global_transform))
		return mesh_node

	if input is CSGShape3D:
		var csg_node: HEGoInputNode = existing_node if existing_node is HEGoInputNode else HEGoInputNode.new()
		await HEGoNodeUtil.await_task(host, csg_node.instantiate())
		await HEGoNodeUtil.await_task(host, csg_node.set_geo_from_mesh(input.bake_static_mesh(), attrs))
		await HEGoNodeUtil.await_task(host, csg_node.set_transform(input.global_transform))
		return csg_node

	if HEGoTerrain3DUtil.is_available() and input.is_class("Terrain3D"):
		var terrain_node: HEGoHeightfieldInputNode = existing_node if existing_node is HEGoHeightfieldInputNode else HEGoHeightfieldInputNode.new()
		await HEGoNodeUtil.await_task(host, terrain_node.instantiate())
		var layers := HEGoTerrain3DInput.read_layers(input, str(input_node_path))
		if not layers.is_empty():
			await HEGoNodeUtil.await_task(host, terrain_node.set_layers(layers, HEGoTerrain3DInput.get_vertex_spacing(input), 1.0, true))
		return terrain_node

	HEGoLog.get_singleton().warning(LOG_CATEGORY, "Input %s is not a Path3D, HEGoGraphInput3D, MeshInstance3D, CSGShape3D or Terrain3D." % str(input_node_path))
	return existing_node


## Resolves an input path against the edited scene in the editor and against the
## running scene at runtime, so cooking works in both.
static func _resolve_input_node(host: Node, input_node_path: Variant) -> Node:
	if input_node_path == null or str(input_node_path).is_empty():
		return null

	var tree := host.get_tree()
	if tree != null:
		if tree.edited_scene_root != null:
			var edited_node := tree.edited_scene_root.get_node_or_null(input_node_path)
			if edited_node != null:
				return edited_node
		if tree.current_scene != null:
			var runtime_node := tree.current_scene.get_node_or_null(input_node_path)
			if runtime_node != null:
				return runtime_node

	return host.get_node_or_null(input_node_path)


## Point and connection attributes from a [HEGoGraphInput3D], skipped when that
## owner currently has no elements.
static func _graph_attribs(graph: HEGoGraphInput3D) -> Array:
	var attrs := []
	if graph.points.size() > 0:
		for name in graph.point_attribs:
			attrs.append({
				"name": name,
				"type": "point",
				"values": graph.point_attribs[name],
			})
	if graph.connection_count() > 0:
		for name in graph.connection_attribs:
			attrs.append({
				"name": name,
				"type": "prim",
				"values": graph.connection_attribs[name],
			})
	return attrs


## One attribute per surface override material, so an HDA can rebuild the material
## assignment on the way back out. Surfaces without an override send "empty".
static func _material_attribs(mesh_instance: MeshInstance3D) -> Array:
	var attrs := []
	for i in range(mesh_instance.get_surface_override_material_count()):
		var material := mesh_instance.get_surface_override_material(i)
		attrs.append({
			"name": SURFACE_MATERIAL_ATTRIB_PREFIX + str(i),
			"type": "prim",
			"value": material.resource_path if material != null else NO_MATERIAL,
		})
	return attrs
