@tool
class_name HEGoObjectOutput
extends RefCounted

## Spawns one Godot node per output point.
##
## Each point decides through attributes what to spawn (a registered class, or a
## packed scene), where to put it, how to orient it and which of its properties to
## override. Points without those attributes fall back to a plain [Node3D].

## Config the point fetch is driven by.
const FETCH_CONFIG_PATH := "res://addons/hego/point_filters/fetch_points_default_object_spawning.tres"

## Node path used when a point does not specify hego_node_path.
const DEFAULT_NODE_PATH := "Objects"

## Class spawned when a point does not specify hego_class_name, and the fallback
## whenever the requested class or scene cannot be used.
const DEFAULT_CLASS_NAME := "Node3D"

## hego_spawn_type: instantiate the class named by hego_class_name.
const SPAWN_TYPE_CLASS := 0
## hego_spawn_type: instantiate the packed scene at hego_resource_path.
const SPAWN_TYPE_SCENE := 1


## Fetches the output points of [param host]'s asset node and spawns a node for each.
static func handle(host: Node) -> void:
	print(HEGoNodeUtil.LOG_PREFIX + "Handling Object Spawn Output")
	var fetch_config: Resource = load(FETCH_CONFIG_PATH)
	var points: Variant = await HEGoNodeUtil.await_task(host, host.hego_asset_node.fetch_points(fetch_config))

	if not points is Dictionary or not points.has("P") or not points["P"] is Array:
		return

	var positions: Array = points["P"]
	if positions.is_empty():
		print(HEGoNodeUtil.LOG_PREFIX + "No points to process")
		return

	var outputs_root := HEGoNodeUtil.ensure_outputs_root(host)
	# Scenes are usually shared by many points, so only load each one once per cook.
	var scene_cache := {}

	for i in range(positions.size()):
		var position: Variant = positions[i]
		if not position is Vector3:
			continue

		var node_path := str(HEGoNodeUtil.get_typed_point_attrib(points, "hego_node_path", i, TYPE_STRING, DEFAULT_NODE_PATH))
		var path_parts := node_path.split("/", false)
		var parent_node := HEGoNodeUtil.ensure_parent_path(host, outputs_root, path_parts)

		var new_node := _spawn_node(points, i, scene_cache)
		var base_name := path_parts[path_parts.size() - 1] if path_parts.size() > 0 else "Object_" + str(i)
		new_node.name = HEGoNodeUtil.unique_child_name(parent_node, base_name)
		new_node.transform = _build_transform(points, i, position)

		var custom_properties: Variant = HEGoNodeUtil.get_typed_point_attrib(points, "hego_custom_properties", i, TYPE_DICTIONARY, {})
		if not custom_properties.is_empty():
			HEGoPropertyUtil.apply_custom_properties(new_node, custom_properties)

		parent_node.add_child(new_node)
		HEGoNodeUtil.set_editor_owner(host, new_node)


## Creates the node for point [param index], falling back to a plain [Node3D]
## whenever the point asks for something that cannot be instantiated as a [Node3D].
static func _spawn_node(points: Dictionary, index: int, scene_cache: Dictionary) -> Node3D:
	var spawn_type := int(HEGoNodeUtil.get_typed_point_attrib(points, "hego_spawn_type", index, TYPE_INT, SPAWN_TYPE_CLASS))

	match spawn_type:
		SPAWN_TYPE_CLASS:
			var class_name_attr := str(HEGoNodeUtil.get_typed_point_attrib(points, "hego_class_name", index, TYPE_STRING, DEFAULT_CLASS_NAME))
			if not ClassDB.class_exists(class_name_attr):
				push_warning(HEGoNodeUtil.LOG_PREFIX + "Invalid class name '%s', falling back to Node3D" % class_name_attr)
				return Node3D.new()
			# Checked before instantiating: assigning a non-Node3D to a Node3D
			# would abort the cook instead of falling back.
			if not ClassDB.is_parent_class(class_name_attr, DEFAULT_CLASS_NAME):
				push_warning(HEGoNodeUtil.LOG_PREFIX + "Class '%s' is not a Node3D, falling back to Node3D" % class_name_attr)
				return Node3D.new()
			return ClassDB.instantiate(class_name_attr) as Node3D

		SPAWN_TYPE_SCENE:
			var resource_path := str(HEGoNodeUtil.get_typed_point_attrib(points, "hego_resource_path", index, TYPE_STRING, ""))
			if not ResourceLoader.exists(resource_path):
				push_warning(HEGoNodeUtil.LOG_PREFIX + "Resource path %s does not exist, falling back to Node3D" % resource_path)
				return Node3D.new()
			if not scene_cache.has(resource_path):
				scene_cache[resource_path] = load(resource_path) as PackedScene
			var scene: PackedScene = scene_cache[resource_path]
			if scene == null or not scene.can_instantiate():
				push_warning(HEGoNodeUtil.LOG_PREFIX + "Invalid scene at %s, falling back to Node3D" % resource_path)
				return Node3D.new()
			var instance := scene.instantiate() as Node3D
			if instance == null:
				push_warning(HEGoNodeUtil.LOG_PREFIX + "Resource %s is not a Node3D scene, falling back to Node3D" % resource_path)
				return Node3D.new()
			return instance

	push_warning(HEGoNodeUtil.LOG_PREFIX + "Invalid spawn type %d, falling back to Node3D" % spawn_type)
	return Node3D.new()


## Builds the spawn transform from the point's orientation and scale attributes.
## Kept identical to the multimesh output so both spawn modes line up.
static func _build_transform(points: Dictionary, index: int, position: Vector3) -> Transform3D:
	var normal: Vector3 = HEGoNodeUtil.get_typed_point_attrib(points, "N", index, TYPE_VECTOR3, Vector3(0, 0, 1)).normalized()
	var up: Vector3 = HEGoNodeUtil.get_typed_point_attrib(points, "up", index, TYPE_VECTOR3, Vector3(0, 1, 0)).normalized()
	var point_scale: Vector3 = HEGoNodeUtil.get_typed_point_attrib(points, "scale", index, TYPE_VECTOR3, Vector3.ONE)
	var pscale := float(HEGoNodeUtil.get_typed_point_attrib(points, "pscale", index, TYPE_FLOAT, 1.0))

	var basis := Basis()
	var right := up.cross(normal).normalized()
	if right == Vector3.ZERO:
		push_warning(HEGoNodeUtil.LOG_PREFIX + "Invalid normal or up vector for point %d (collinear), using default basis" % index)
	else:
		basis.x = right
		basis.y = up
		basis.z = normal

	return Transform3D(basis.scaled(point_scale * pscale), position)
