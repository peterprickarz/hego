@tool
class_name HEGoInputNodes
extends RefCounted

## Turns the Godot nodes wired into a [HEGoNode3D] into HEGo input nodes.
##
## Which input node a Godot node needs depends on its type: paths become curve
## inputs, meshes and CSG shapes become geometry inputs, and a Terrain3D becomes a
## heightfield input. The node path of the source is always sent along as
## [code]_hego_node_path[/code] so an HDA can tell its inputs apart.

## Attributes attached to every input.
const NODE_PATH_ATTRIB := "_hego_node_path"
const RESOURCE_PATH_ATTRIB := "_hego_resource_path"
const SURFACE_MATERIAL_ATTRIB_PREFIX := "_hego_surface_override_material_"

## Value used for a surface that has no override material.
const NO_MATERIAL := "empty"

## Curve input mode used for Path3D inputs.
const CURVE_INPUT_MODE := 1


## Creates or updates the input node for the Godot node at [param input_node_path].
##
## Pass the previous input node as [param existing_node] to reuse it when the source
## node still has the same type; pass null to always create a fresh one. Returns the
## input node to store, which is [param existing_node] itself when it was reused.
##
## [param settings] is the per-input settings dictionary from the input stash. It is
## carried through the stash for future per-input options and is not read yet.
static func sync(host: Node, existing_node: Variant, input_node_path: Variant, settings: Dictionary) -> Variant:
	var input := _resolve_input_node(host, input_node_path)
	if input == null:
		push_warning(HEGoNodeUtil.LOG_PREFIX + "Input node %s could not be found, skipping it." % str(input_node_path))
		return existing_node

	var attrs := [{
		"name": NODE_PATH_ATTRIB,
		"type": "prim",
		"value": input_node_path,
	}]

	if input is Path3D:
		var curve_node: HEGoCurveInputNode = existing_node if existing_node is HEGoCurveInputNode else HEGoCurveInputNode.new()
		await HEGoNodeUtil.await_task(host, curve_node.instantiate())
		await HEGoNodeUtil.await_task(host, curve_node.set_curve_from_path_3d(input, CURVE_INPUT_MODE))
		return curve_node

	if input is MeshInstance3D:
		if input.mesh == null:
			push_warning(HEGoNodeUtil.LOG_PREFIX + "Input %s has no mesh, skipping it." % str(input_node_path))
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

	push_warning(HEGoNodeUtil.LOG_PREFIX + "Input %s is not a Path3D, MeshInstance3D, CSGShape3D or Terrain3D." % str(input_node_path))
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
