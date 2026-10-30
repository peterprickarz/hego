@tool
class_name HEGoInputNodes
extends RefCounted

## Turns the Godot nodes wired into a [HEGoNode3D] into HEGo input nodes.
##
## Which input node a Godot node needs depends on its type: paths become curve
## inputs, meshes and CSG shapes become geometry inputs, and a [HEGoGraphInput3D]
## becomes points and polyline primitives. Other addons add kinds of their own, such as
## terrains, through [HEGoInputHandler], which is consulted first. The node path of the
## source is always sent along as [code]_hego_node_path[/code] so an HDA can tell its
## inputs apart.

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

## Key under which [method sync] passes an [HEGoInputHandler] the input path it resolved,
## as stored in the input stash, so the handler can send it as [constant NODE_PATH_ATTRIB].
const INPUT_PATH_KEY := "_input_path"

## Class every extension input handler extends.
const HANDLER_BASE := &"HEGoInputHandler"

# Script paths of the handlers found last time, and one instance of each.
static var _handler_paths := PackedStringArray()
static var _handlers: Array[HEGoInputHandler] = []


## The input handlers other addons provide: one instance of every global class that extends
## [HEGoInputHandler]. Rescanned whenever the project's class list changes, so an addon
## installed in an open editor is picked up without a restart.
static func extension_handlers() -> Array[HEGoInputHandler]:
	var found := PackedStringArray(HEGoNodeUtil.global_subclasses(HANDLER_BASE).values())
	found.sort()
	if found == _handler_paths:
		return _handlers
	_handler_paths = found
	_handlers.clear()
	for path in found:
		# A handler whose own dependencies are missing fails to load. That is reported once,
		# here, rather than on every lookup.
		var script := load(path) as Script
		var handler: Variant = script.new() if script != null and script.can_instantiate() else null
		if handler is HEGoInputHandler:
			_handlers.append(handler)
		else:
			HEGoLog.get_singleton().error(LOG_CATEGORY, "Input handler %s could not be loaded; check that the addons it needs are installed." % path)
	return _handlers


## The extension handler that sends [param node], or null when HEGo handles it itself.
static func handler_for(node: Node) -> HEGoInputHandler:
	if node == null:
		return null
	for handler in extension_handlers():
		if handler.handles(node):
			return handler
	return null


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
	if handler_for(node) != null:
		return true
	if node is HEGoGraphInput3D:
		return not node.points.is_empty()
	if node is Path3D:
		return node.curve != null and node.curve.point_count > 0
	if node is MeshInstance3D:
		return node.mesh != null
	if node is CSGShape3D:
		return node.is_root_shape()
	return false


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
## Missing, non-finite or non-positive values use the one-metre default. During a strict
## cook it also carries [code]_strict[/code] and the [code]_errors[/code] array failures are
## collected in; see [method HEGoAssetAgent.sync_inputs].
static func sync(host: Node, existing_node: Variant, input_node_path: Variant, settings: Dictionary) -> Variant:
	var input := _resolve_input_node(host, input_node_path)
	if input == null:
		HEGoLog.get_singleton().warning(LOG_CATEGORY, "Input node %s could not be found, skipping it." % str(input_node_path))
		if settings.get("_strict", false):
			settings["_errors"].append("A required cook input disappeared: " + String(input_node_path))
			return null
		return existing_node

	var handler := handler_for(input)
	if handler != null:
		settings[INPUT_PATH_KEY] = str(input_node_path)
		var result: Dictionary = await handler.sync(host, existing_node, input, settings)
		if result.get("ok", false):
			return result.node
		var message := String(result.get("message", "Input %s could not be sent" % str(input_node_path)))
		HEGoLog.get_singleton().error(LOG_CATEGORY, message)
		if settings.has("_errors"):
			settings["_errors"].append(message)
		return null

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
		await _input_task(host, graph_node.instantiate(), settings)
		await _input_task(host, graph_node.set_geo(input.points, "polyline", input.connections, counts, graph_attrs), settings)
		await _input_task(host, graph_node.set_transform(input.global_transform), settings)
		return graph_node

	if input is Path3D:
		var curve_node: HEGoCurveInputNode = existing_node if existing_node is HEGoCurveInputNode else HEGoCurveInputNode.new()
		await _input_task(host, curve_node.instantiate(), settings)
		var spacing := float(settings.get("curve_sample_length", CURVE_SAMPLE_LENGTH))
		if not is_finite(spacing) or spacing <= 0.0:
			spacing = CURVE_SAMPLE_LENGTH
		await _input_task(host, curve_node.set_curve_from_path_3d(input, maxf(0.01, spacing)), settings)
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
		await _input_task(host, mesh_node.instantiate(), settings)
		await _input_task(host, mesh_node.set_geo_from_mesh(input.mesh, attrs), settings)
		await _input_task(host, mesh_node.set_transform(input.global_transform), settings)
		return mesh_node

	if input is CSGShape3D:
		var csg_node: HEGoInputNode = existing_node if existing_node is HEGoInputNode else HEGoInputNode.new()
		await _input_task(host, csg_node.instantiate(), settings)
		await _input_task(host, csg_node.set_geo_from_mesh(input.bake_static_mesh(), attrs), settings)
		await _input_task(host, csg_node.set_transform(input.global_transform), settings)
		return csg_node

	HEGoLog.get_singleton().warning(LOG_CATEGORY, "Input %s is not a Path3D, HEGoGraphInput3D, MeshInstance3D or CSGShape3D, and no input handler accepts it." % str(input_node_path))
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

## A strict cook also rejects a failed mesh, curve or graph upload, rather than cooking
## against whatever geometry the reused input node held before.
static func _input_task(host: Node, native_task: HEGoTask, settings: Dictionary) -> Variant:
	if settings.get("_strict", false):
		var completed := await HEGoNodeUtil.checked_task(host, native_task)
		if not completed.ok:
			settings["_errors"].append(completed.message)
			return null
		return completed.value
	return await HEGoNodeUtil.await_task(host, native_task)
