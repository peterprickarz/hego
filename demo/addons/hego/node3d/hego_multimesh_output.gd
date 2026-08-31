@tool
class_name HEGoMultiMeshOutput
extends RefCounted

## Instances an existing mesh resource once per output point through a [MultiMesh].
##
## The fetch returns points grouped by output name and then by mesh resource path, so
## one HDA can drive several [MultiMeshInstance3D]s with a different mesh each.

## Category this file logs under, shown in the session panel filter.
const LOG_CATEGORY := "output"

## Points with this attribute set to 1 are instanced.
const INSTANCING_FILTER_ATTRIB := "hego_use_multimesh"

## Attribute naming the output a point belongs to, and the mesh to instance.
const OUTPUT_NAME_ATTRIB := "hego_multimesh"
const MESH_RESOURCE_ATTRIB := "hego_mesh_resource"

## Per-instance attributes this handler reads.
const POINT_ATTRIBS := ["N", "Cd", "up", "pscale", "scale"]

## Node name prefix used when an HDA does not name its multimesh output.
const DEFAULT_MULTIMESH_NAME := "MultiMesh"


## Fetches the instancing points of [param host]'s asset node and builds the multimeshes.
static func handle(host: Node) -> void:
	HEGoLog.get_singleton().debug(LOG_CATEGORY, "Handling Multimesh Output")

	var output: HEGoGeoOutput = await HEGoNodeUtil.await_task(host, host.hego_asset_node.get_geo_output())
	if output == null or not output.is_valid():
		return

	await HEGoNodeUtil.await_task(host,
		output.load_attributes(PackedStringArray(POINT_ATTRIBS + [INSTANCING_FILTER_ATTRIB, OUTPUT_NAME_ATTRIB, MESH_RESOURCE_ATTRIB])))

	var selection := output.filter_by(INSTANCING_FILTER_ATTRIB, 1)
	if selection.size() == 0:
		return

	# Grouped by output first, then by mesh, so one HDA can drive several
	# multimeshes and each of those several meshes.
	var by_output := selection.split_by(OUTPUT_NAME_ATTRIB)
	for output_key in by_output:
		var output_name := DEFAULT_MULTIMESH_NAME if output_key == null else str(output_key)

		var by_mesh: Dictionary = by_output[output_key].split_by(MESH_RESOURCE_ATTRIB)
		for resource_path in by_mesh:
			if resource_path == null:
				continue
			var mesh_resource: Resource = load(resource_path)
			if not mesh_resource is Mesh:
				HEGoLog.get_singleton().warning(LOG_CATEGORY, "Multimesh resource %s is not a Mesh, skipping." % resource_path)
				continue

			# One multimesh per (output, mesh) pair, named after both so several
			# meshes coming out of the same output do not collide.
			var mesh_file_name: String = str(resource_path).get_file().get_basename()
			var point_dict: Dictionary = by_mesh[resource_path].get_points(PackedStringArray(POINT_ATTRIBS))
			setup_multimesh(host, mesh_resource, output_name + "_" + mesh_file_name, point_dict)


## Creates a [MultiMeshInstance3D] named [param multimesh_name] under [code]Outputs/[/code]
## and fills it with one instance per point in [param point_dict].
static func setup_multimesh(host: Node, mesh_resource: Mesh, multimesh_name: String, point_dict: Dictionary) -> void:
	if not point_dict.has("P") or not point_dict["P"] is Array:
		HEGoLog.get_singleton().warning(LOG_CATEGORY, "Multimesh output %s has no P attribute, skipping." % multimesh_name)
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
