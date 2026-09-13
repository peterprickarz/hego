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
## Attributes this handler reads off each instanced point: the shared orientation set plus
## colour. A function rather than a const, because a const cannot be built from another
## class's constant. See [HEGoPointUtil].
static func point_attribs() -> Array:
	return HEGoPointUtil.ORIENTATION_ATTRIBS + [HEGoPointUtil.COLOR_ATTRIB]

## Node name prefix used when an HDA does not name its multimesh output.
const DEFAULT_MULTIMESH_NAME := "MultiMesh"


## Name of the cook phase this handler is timed under.
static func output_phase() -> String:
	return "multimesh_output"


## Whether the cook produced points flagged for multimesh instancing.
static func should_handle(summary: Dictionary) -> bool:
	return HEGoNodeUtil.output_has(summary, "has_points") \
		and HEGoNodeUtil.output_has_attribute(summary, "point_attributes", INSTANCING_FILTER_ATTRIB)


## Fetches the instancing points of the cook and builds the multimeshes.
static func handle(ctx: HEGoOutputContext) -> void:
	HEGoLog.get_singleton().debug(LOG_CATEGORY, "Handling Multimesh Output")

	var selection := await ctx.select_points(INSTANCING_FILTER_ATTRIB,
		PackedStringArray(point_attribs() + [OUTPUT_NAME_ATTRIB, MESH_RESOURCE_ATTRIB]))
	if selection == null:
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
			var point_dict: Dictionary = by_mesh[resource_path].get_points(PackedStringArray(point_attribs()))
			setup_multimesh(ctx, mesh_resource, output_name + "_" + mesh_file_name, point_dict)


## Creates a [MultiMeshInstance3D] named [param multimesh_name] under [code]Outputs/[/code]
## and fills it with one instance per point in [param point_dict].
static func setup_multimesh(ctx: HEGoOutputContext, mesh_resource: Mesh, multimesh_name: String, point_dict: Dictionary) -> void:
	if not point_dict.has("P") or not point_dict["P"] is Array:
		HEGoLog.get_singleton().warning(LOG_CATEGORY, "Multimesh output %s has no P attribute, skipping." % multimesh_name)
		return

	var positions: Array = point_dict["P"]
	var point_count := positions.size()
	if point_count == 0:
		return

	var multimesh_instance := ctx.place(multimesh_name, DEFAULT_MULTIMESH_NAME, MultiMeshInstance3D.new) as MultiMeshInstance3D

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

	var use_colors := HEGoPointUtil.has_any_color(point_dict)
	multimesh.use_colors = use_colors
	multimesh.instance_count = point_count

	for i in range(point_count):
		multimesh.set_instance_transform(i,
			HEGoPointUtil.transform_from_point(point_dict, i, positions[i] - center))

		if use_colors:
			multimesh.set_instance_color(i, HEGoPointUtil.read_color(point_dict, i))

	multimesh_instance.multimesh = multimesh
