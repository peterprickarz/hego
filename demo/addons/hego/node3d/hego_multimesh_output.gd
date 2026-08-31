@tool
class_name HEGoMultiMeshOutput
extends RefCounted

## Instances an existing mesh resource once per output point through a [MultiMesh].
##
## The fetch returns points grouped by output name and then by mesh resource path, so
## one HDA can drive several [MultiMeshInstance3D]s with a different mesh each.

## Config the point fetch is driven by.
const FETCH_CONFIG_PATH := "res://addons/hego/point_filters/fetch_points_default_multimesh_instancing.tres"

## Node name prefix used when an HDA does not name its multimesh output.
const DEFAULT_MULTIMESH_NAME := "MultiMesh"


## Fetches the instancing points of [param host]'s asset node and builds the multimeshes.
static func handle(host: Node) -> void:
	print(HEGoNodeUtil.LOG_PREFIX + "Handling Multimesh Output")
	var fetch_config: Resource = load(FETCH_CONFIG_PATH)
	var outputs: Variant = await HEGoNodeUtil.await_task(host, host.hego_asset_node.fetch_points(fetch_config))
	if not outputs is Dictionary:
		return

	for output_key in outputs.keys():
		var output_name := DEFAULT_MULTIMESH_NAME if output_key == null else str(output_key)
		var per_mesh_points: Variant = outputs[output_key]
		if not per_mesh_points is Dictionary:
			continue

		for resource_path in per_mesh_points.keys():
			if resource_path == null:
				continue
			var mesh_resource: Resource = load(resource_path)
			if not mesh_resource is Mesh:
				push_warning(HEGoNodeUtil.LOG_PREFIX + "Multimesh resource %s is not a Mesh, skipping." % resource_path)
				continue

			var point_dict: Variant = per_mesh_points[resource_path]
			if not point_dict is Dictionary:
				continue

			# One multimesh per (output, mesh) pair, named after both so several
			# meshes coming out of the same output do not collide.
			var mesh_file_name: String = str(resource_path).get_file().get_basename()
			setup_multimesh(host, mesh_resource, output_name + "_" + mesh_file_name, point_dict)


## Creates a [MultiMeshInstance3D] named [param multimesh_name] under [code]Outputs/[/code]
## and fills it with one instance per point in [param point_dict].
static func setup_multimesh(host: Node, mesh_resource: Mesh, multimesh_name: String, point_dict: Dictionary) -> void:
	if not point_dict.has("P") or not point_dict["P"] is Array:
		push_warning(HEGoNodeUtil.LOG_PREFIX + "Multimesh output %s has no P attribute, skipping." % multimesh_name)
		return

	var positions: Array = point_dict["P"]
	var point_count := positions.size()
	if point_count == 0:
		return

	var outputs_root := HEGoNodeUtil.ensure_outputs_root(host)
	var path_parts := multimesh_name.split("/", false)
	var parent_node := HEGoNodeUtil.ensure_parent_path(host, outputs_root, path_parts)

	var multimesh_instance := MultiMeshInstance3D.new()
	multimesh_instance.name = path_parts[path_parts.size() - 1] if path_parts.size() > 0 else DEFAULT_MULTIMESH_NAME
	parent_node.add_child(multimesh_instance)
	HEGoNodeUtil.set_editor_owner(host, multimesh_instance)

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh_resource

	# Instance transforms are stored relative to the node, so putting the node at the
	# centre of the point cloud keeps the numbers small and the bounds tight.
	var center := Vector3.ZERO
	for position in positions:
		center += position
	center /= point_count
	multimesh_instance.transform.origin = center

	var use_colors := _has_any_color(point_dict)
	multimesh.use_colors = use_colors
	multimesh.instance_count = point_count

	for i in range(point_count):
		var normal: Vector3 = HEGoNodeUtil.get_typed_point_attrib(point_dict, "N", i, TYPE_VECTOR3, Vector3(0, 0, 1)).normalized()
		var up: Vector3 = HEGoNodeUtil.get_typed_point_attrib(point_dict, "up", i, TYPE_VECTOR3, Vector3(0, 1, 0)).normalized()
		var point_scale: Vector3 = HEGoNodeUtil.get_typed_point_attrib(point_dict, "scale", i, TYPE_VECTOR3, Vector3.ONE)
		var pscale := float(HEGoNodeUtil.get_typed_point_attrib(point_dict, "pscale", i, TYPE_FLOAT, 1.0))

		var basis := Basis()
		var right := up.cross(normal).normalized()
		if right != Vector3.ZERO:
			basis.x = right
			basis.y = up
			basis.z = normal
		basis = basis.scaled(point_scale * pscale)

		multimesh.set_instance_transform(i, Transform3D(basis, positions[i] - center))

		if use_colors:
			multimesh.set_instance_color(i, _read_color(point_dict, i))

	multimesh_instance.multimesh = multimesh


## Whether the points carry a usable Cd attribute.
static func _has_any_color(point_dict: Dictionary) -> bool:
	if not point_dict.has("Cd") or not point_dict["Cd"] is Array:
		return false
	var colors: Array = point_dict["Cd"]
	return not colors.is_empty() and colors[0] != null


## Reads Cd for one point, accepting both [Color] and [Vector3] and defaulting to white.
static func _read_color(point_dict: Dictionary, index: int) -> Color:
	var value: Variant = HEGoNodeUtil.get_point_attrib(point_dict, "Cd", index, null)
	if value is Color:
		return value
	if value is Vector3:
		return Color(value.x, value.y, value.z, 1.0)
	return Color(1, 1, 1, 1)
