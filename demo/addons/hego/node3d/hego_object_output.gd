@tool
class_name HEGoObjectOutput
extends RefCounted

## Spawns one Godot node per output point.
##
## Each point decides through attributes what to spawn (a registered class, or a
## packed scene), where to put it, how to orient it and which of its properties to
## override. Points without those attributes fall back to a plain [Node3D].

## Category this file logs under, shown in the session panel filter.
const LOG_CATEGORY := "output"

## Points with this attribute set to 1 are spawned.
const SPAWN_FILTER_ATTRIB := "hego_spawn"

## Attributes this handler reads off each spawned point: the shared orientation set plus
## its own. Cd is not among them, because spawned nodes are not tinted. A function rather
## than a const, because a const cannot be built from another class's constant.
## See [HEGoPointUtil].
static func point_attribs() -> Array:
	return HEGoPointUtil.ORIENTATION_ATTRIBS + [
		"hego_node_path", "hego_spawn_type", "hego_resource_path", "hego_class_name",
		"hego_custom_properties",
	]

## Node path used when a point does not specify hego_node_path.
const DEFAULT_NODE_PATH := "Objects"

## Class spawned when a point does not specify hego_class_name, and the fallback
## whenever the requested class or scene cannot be used.
const DEFAULT_CLASS_NAME := "Node3D"

## hego_spawn_type: instantiate the class named by hego_class_name.
const SPAWN_TYPE_CLASS := 0
## hego_spawn_type: instantiate the packed scene at hego_resource_path.
const SPAWN_TYPE_SCENE := 1


## Name of the cook phase this handler is timed under.
static func output_phase() -> String:
	return "object_spawn_output"


## Whether the cook produced points flagged for spawning.
static func should_handle(summary: Dictionary) -> bool:
	return HEGoNodeUtil.output_has(summary, "has_points") \
		and HEGoNodeUtil.output_has_attribute(summary, "point_attributes", SPAWN_FILTER_ATTRIB)


## Fetches the cook's output points and spawns a node for each.
static func handle(ctx: HEGoOutputContext) -> void:
	HEGoLog.get_singleton().debug(LOG_CATEGORY, "Handling Object Spawn Output")

	var selection := await ctx.select_points(SPAWN_FILTER_ATTRIB, PackedStringArray(point_attribs()))
	if selection == null:
		HEGoLog.get_singleton().debug(LOG_CATEGORY, "No points to process")
		return

	var points := selection.get_points(PackedStringArray(point_attribs()))
	var positions: Array = points["P"]

	# Scenes are usually shared by many points, so only load each one once per cook.
	var scene_cache := {}
	# Counted rather than reported per point: a scatter with a bad N/up pair usually has it
	# on thousands of points, and one line saying how many is more use than thousands.
	var collinear_count := 0

	for i in range(positions.size()):
		var position: Variant = positions[i]
		if not position is Vector3:
			continue

		var node_path := str(HEGoNodeUtil.get_typed_point_attrib(points, "hego_node_path", i, TYPE_STRING, DEFAULT_NODE_PATH))

		var custom_properties: Variant = HEGoNodeUtil.get_typed_point_attrib(points, "hego_custom_properties", i, TYPE_DICTIONARY, {})
		var point_transform := HEGoPointUtil.transform_from_point(points, i, position)

		# unique: every point gets its own node, so names are suffixed rather than reused.
		# The transform and the HDA's overrides go through configure, so they are in place
		# before the node enters the tree and its _ready() can read them.
		ctx.place(node_path, "Object_" + str(i),
			func(): return _spawn_node(points, i, scene_cache),
			true,
			func(node: Node):
				node.transform = point_transform
				if not custom_properties.is_empty():
					HEGoPropertyUtil.apply_custom_properties(node, custom_properties))

		if HEGoPointUtil.is_orientation_collinear(points, i):
			collinear_count += 1

	if collinear_count > 0:
		HEGoLog.get_singleton().warning(LOG_CATEGORY,
			"%d spawned point(s) had a collinear N and up, so they are unrotated" % collinear_count)


## Creates the node for point [param index], falling back to a plain [Node3D]
## whenever the point asks for something that cannot be instantiated as a [Node3D].
static func _spawn_node(points: Dictionary, index: int, scene_cache: Dictionary) -> Node3D:
	var spawn_type := int(HEGoNodeUtil.get_typed_point_attrib(points, "hego_spawn_type", index, TYPE_INT, SPAWN_TYPE_CLASS))

	match spawn_type:
		SPAWN_TYPE_CLASS:
			var class_name_attr := str(HEGoNodeUtil.get_typed_point_attrib(points, "hego_class_name", index, TYPE_STRING, DEFAULT_CLASS_NAME))
			if not ClassDB.class_exists(class_name_attr):
				HEGoLog.get_singleton().warning(LOG_CATEGORY, "Invalid class name '%s', falling back to Node3D" % class_name_attr)
				return Node3D.new()
			# Checked before instantiating: assigning a non-Node3D to a Node3D
			# would abort the cook instead of falling back.
			if not ClassDB.is_parent_class(class_name_attr, DEFAULT_CLASS_NAME):
				HEGoLog.get_singleton().warning(LOG_CATEGORY, "Class '%s' is not a Node3D, falling back to Node3D" % class_name_attr)
				return Node3D.new()
			return ClassDB.instantiate(class_name_attr) as Node3D

		SPAWN_TYPE_SCENE:
			var resource_path := str(HEGoNodeUtil.get_typed_point_attrib(points, "hego_resource_path", index, TYPE_STRING, ""))
			if not ResourceLoader.exists(resource_path):
				HEGoLog.get_singleton().warning(LOG_CATEGORY, "Resource path %s does not exist, falling back to Node3D" % resource_path)
				return Node3D.new()
			if not scene_cache.has(resource_path):
				scene_cache[resource_path] = load(resource_path) as PackedScene
			var scene: PackedScene = scene_cache[resource_path]
			if scene == null or not scene.can_instantiate():
				HEGoLog.get_singleton().warning(LOG_CATEGORY, "Invalid scene at %s, falling back to Node3D" % resource_path)
				return Node3D.new()
			var instance := scene.instantiate() as Node3D
			if instance == null:
				HEGoLog.get_singleton().warning(LOG_CATEGORY, "Resource %s is not a Node3D scene, falling back to Node3D" % resource_path)
				return Node3D.new()
			return instance

	HEGoLog.get_singleton().warning(LOG_CATEGORY, "Invalid spawn type %d, falling back to Node3D" % spawn_type)
	return Node3D.new()


