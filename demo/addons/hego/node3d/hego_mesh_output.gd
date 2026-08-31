@tool
class_name HEGoMeshOutput
extends RefCounted

## Turns the surfaces of a cooked HDA into [MeshInstance3D]s under [code]Outputs/[/code].
##
## Per output mesh the HDA decides, through detail attributes, whether the mesh is kept
## in the scene, saved as an [ArrayMesh] resource, or both, and which collision shape
## (if any) is generated for it.

## Category this file logs under, shown in the session panel filter.
const LOG_CATEGORY := "output"

## Point attributes read for every surface. P always comes along.
const POINT_ATTRIBS := ["N", "Cd", "uv", "uv2", "tangents"]

## Primitive attributes the output is grouped by: one mesh per instance name, one
## surface per material within it.
const MESH_INSTANCE_ATTRIB := "hego_mesh_instance"
const MATERIAL_ATTRIB := "hego_material"

## Primitive attributes this handler reads off each surface.
const SURFACE_ATTRIBS := [
	"hego_lod", "hego_col_type", "hego_col_decomp_settings",
	"hego_storage_mode", "hego_resource_save_path",
]

## Node name used when an HDA does not name its mesh output.
const DEFAULT_MESH_NODE_NAME := "hego_output_mesh_inst"

## hego_storage_mode: keep the mesh in the scene only.
const STORAGE_MODE_INSTANCE := 0
## hego_storage_mode: save the mesh as a resource, do not add it to the scene.
const STORAGE_MODE_RESOURCE := 1
## hego_storage_mode: save the mesh as a resource and add an instance of it to the scene.
const STORAGE_MODE_RESOURCE_AND_INSTANCE := 2

## hego_col_type values.
const COLLISION_NONE := 0
const COLLISION_MULTIPLE_CONVEX := 1
const COLLISION_CONVEX := 2
const COLLISION_TRIMESH := 3

## Properties of [MeshConvexDecompositionSettings] an HDA may override through
## the hego_col_decomp_settings dictionary. Names match the Godot property names.
const DECOMPOSITION_PROPERTIES := [
	"convex_hull_approximation",
	"convex_hull_downsampling",
	"max_concavity",
	"max_convex_hulls",
	"max_num_vertices_per_convex_hull",
	"min_volume_per_convex_hull",
	"mode",
	"normalize_mesh",
	"plane_downsampling",
	"project_hull_vertices",
	"resolution",
	"resolution_axes_clipping_bias",
	"symmetry_planes_clipping_bias",
]


## Fetches the surfaces of [param host]'s asset node and builds the mesh output.
static func handle(host: Node) -> void:
	var output_start_usec := Time.get_ticks_usec()
	var mesh_instance_count := 0
	var surface_count := 0
	var resource_save_count := 0
	var collision_generation_count := 0

	var fetch_start_usec := Time.get_ticks_usec()
	var output: HEGoGeoSurfaces = await HEGoNodeUtil.await_task(host,
		host.hego_asset_node.get_surface_output(PackedStringArray(POINT_ATTRIBS), PackedStringArray(SURFACE_ATTRIBS + [MESH_INSTANCE_ATTRIB, MATERIAL_ATTRIB])))
	var fetch_surfaces_msec := HEGoCookTimings.elapsed_msec(fetch_start_usec)
	if output == null or not output.is_valid():
		# Null means the task failed; it has already reported why.
		return

	var processing_start_usec := Time.get_ticks_usec()
	var by_instance := output.split_by(MESH_INSTANCE_ATTRIB)
	for mesh_instance_key in by_instance:
		mesh_instance_count += 1

		# One surface per material, each assembled only now that we know we want it.
		var by_material: Dictionary = by_instance[mesh_instance_key].split_by(MATERIAL_ATTRIB)
		var surfaces := {}
		for material_key in by_material:
			surfaces[material_key] = by_material[material_key].get_surface(PackedStringArray(SURFACE_ATTRIBS))
		if surfaces.is_empty():
			continue

		var arr_mesh := _build_array_mesh(surfaces)
		surface_count += surfaces.size()

		# The output-wide settings are detail attributes, so they are identical on
		# every surface of this mesh; read them off the first one.
		var first_surface: Dictionary = surfaces[surfaces.keys()[0]]
		var storage_mode := int(_first_or_default(first_surface, "hego_storage_mode", STORAGE_MODE_INSTANCE))
		var resource_save_path: Variant = _first_or_default(first_surface, "hego_resource_save_path", null)

		if resource_save_path == null and storage_mode > STORAGE_MODE_INSTANCE:
			HEGoLog.get_singleton().error(LOG_CATEGORY, "Save mode set to resource, but no resource save path specified.")
			HEGoLog.get_singleton().warning(LOG_CATEGORY, "Spawning as mesh instance instead.")
			storage_mode = STORAGE_MODE_INSTANCE

		if storage_mode > STORAGE_MODE_INSTANCE:
			resource_save_count += 1
			var save_result := save_mesh_resource(arr_mesh, str(resource_save_path))
			if save_result["ok"]:
				HEGoLog.get_singleton().debug(LOG_CATEGORY, "Successfully saved mesh to " + str(resource_save_path))
			else:
				HEGoLog.get_singleton().warning(LOG_CATEGORY, "%s (error %d)" % [save_result["message"], save_result["error"]])
				if save_result["fallback_to_instance"]:
					HEGoLog.get_singleton().warning(LOG_CATEGORY, "Spawning as mesh instance instead.")
					storage_mode = STORAGE_MODE_INSTANCE

		if storage_mode == STORAGE_MODE_RESOURCE:
			continue

		var mesh_instance := _spawn_mesh_instance(host, mesh_instance_key, arr_mesh, storage_mode, resource_save_path)
		if _generate_collision(mesh_instance, first_surface):
			collision_generation_count += 1

	var gds_processing_msec := HEGoCookTimings.elapsed_msec(processing_start_usec)
	HEGoLog.get_singleton().debug(
		LOG_CATEGORY,
		"Mesh output breakdown: fetch_surfaces=%.3f ms, gdscript_processing=%.3f ms, total=%.3f ms, mesh_instances=%d, surfaces=%d, saves=%d, collision_generations=%d"
		% [
			fetch_surfaces_msec,
			gds_processing_msec,
			HEGoCookTimings.elapsed_msec(output_start_usec),
			mesh_instance_count,
			surface_count,
			resource_save_count,
			collision_generation_count,
		]
	)


## Builds one [ArrayMesh] from a { material path: surface data } dictionary,
## adding a surface per material and wiring up LODs and materials.
static func _build_array_mesh(surfaces: Dictionary) -> ArrayMesh:
	var arr_mesh := ArrayMesh.new()
	var surface_id := 0
	for material_key in surfaces:
		var surface: Dictionary = surfaces[material_key]
		var surface_array: Array = surface["surface_array"]

		# An HDA that sets no LOD attribute simply has no such key here.
		var hego_lod_array: Array = surface.get("hego_lod", [])

		if not hego_lod_array.is_empty() and hego_lod_array[0] != null:
			# hego_lod holds one screen-space distance per LOD, and the index array
			# holds the triangles of all LODs back to back. Group the triangles by
			# distance; distance 0.0 is the base surface, the rest become Godot LODs.
			var lod_dict := _group_indices_by_lod_distance(hego_lod_array, surface_array[Mesh.ARRAY_INDEX])
			surface_array[Mesh.ARRAY_INDEX] = lod_dict[0.0]
			lod_dict.erase(0.0)
			arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array, [], lod_dict)
		else:
			arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)

		if material_key != null:
			var material: Resource = load(material_key)
			if material is Material:
				arr_mesh.surface_set_material(surface_id, material)
		surface_id += 1
	return arr_mesh


## Adds the mesh to the scene at the path the HDA asked for and returns the instance.
static func _spawn_mesh_instance(host: Node, mesh_instance_key: Variant, arr_mesh: ArrayMesh, storage_mode: int, resource_save_path: Variant) -> MeshInstance3D:
	var node_path := DEFAULT_MESH_NODE_NAME
	if mesh_instance_key != null:
		node_path = str(mesh_instance_key)

	var outputs_root := HEGoNodeUtil.ensure_outputs_root(host)
	var path_parts := node_path.split("/", false)
	var parent_node := HEGoNodeUtil.ensure_parent_path(host, outputs_root, path_parts)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = path_parts[path_parts.size() - 1] if path_parts.size() > 0 else DEFAULT_MESH_NODE_NAME
	parent_node.add_child(mesh_instance)
	HEGoNodeUtil.set_editor_owner(host, mesh_instance)

	if storage_mode == STORAGE_MODE_INSTANCE:
		mesh_instance.mesh = arr_mesh
	else:
		# Instance the resource that was just written, so the scene references the
		# saved file rather than an identical in-memory copy of it.
		var saved_mesh := load_mesh_resource_fresh(str(resource_save_path))
		mesh_instance.mesh = saved_mesh if saved_mesh != null else arr_mesh
	return mesh_instance


## Generates the collision shape the HDA asked for. Returns true if one was generated.
static func _generate_collision(mesh_instance: MeshInstance3D, surface_data: Dictionary) -> bool:
	var collision_type: int = _first_or_default(surface_data, "hego_col_type", COLLISION_NONE)
	match collision_type:
		COLLISION_MULTIPLE_CONVEX:
			var decomp_settings := MeshConvexDecompositionSettings.new()
			var overrides: Variant = _first_or_default(surface_data, "hego_col_decomp_settings", null)
			if overrides is Dictionary:
				for property_name in DECOMPOSITION_PROPERTIES:
					if overrides.has(property_name):
						decomp_settings.set(property_name, overrides[property_name])
			mesh_instance.create_multiple_convex_collisions(decomp_settings)
			return true
		COLLISION_CONVEX:
			mesh_instance.create_convex_collision()
			return true
		COLLISION_TRIMESH:
			mesh_instance.create_trimesh_collision()
			return true
	return false


## Reads a detail attribute that arrives as a single element array,
## returning [param fallback] when it is missing or null.
static func _first_or_default(surface_data: Dictionary, attr_name: String, fallback: Variant) -> Variant:
	if not surface_data.has(attr_name) or not surface_data[attr_name] is Array:
		return fallback
	var values: Array = surface_data[attr_name]
	if values.is_empty() or values[0] == null:
		return fallback
	return values[0]


## Groups triangle indices by their LOD distance.
##
## Returns { distance: PackedInt32Array }, the shape [method ArrayMesh.add_surface_from_arrays]
## expects for its lods argument. Returns an empty dictionary if the arrays do not line up.
static func _group_indices_by_lod_distance(lod_distances: Array, indices: Array) -> Dictionary:
	var result: Dictionary = {}
	if indices.size() != 3 * lod_distances.size():
		return result

	for i in range(lod_distances.size()):
		var distance: float = lod_distances[i]
		var triangle: PackedInt32Array = [indices[3 * i], indices[3 * i + 1], indices[3 * i + 2]]
		if result.has(distance):
			result[distance].append_array(triangle)
		else:
			result[distance] = triangle
	return result


## Writes [param mesh] to [param save_path], overwriting an existing [ArrayMesh] in place
## so that scenes already referencing it pick up the new geometry.
##
## Returns { ok, error, fallback_to_instance, message }; [code]message[/code] and
## [code]error[/code] only carry meaning when [code]ok[/code] is false.
static func save_mesh_resource(mesh: ArrayMesh, save_path: String) -> Dictionary:
	if save_path.is_empty():
		return {
			"ok": false,
			"error": ERR_INVALID_PARAMETER,
			"fallback_to_instance": true,
			"message": "Empty resource save path.",
		}

	# Ensure save directory exists before writing.
	var save_dir := save_path.get_base_dir()
	if not save_dir.is_empty() and not DirAccess.dir_exists_absolute(save_dir):
		var mkdir_result := DirAccess.make_dir_recursive_absolute(save_dir)
		if mkdir_result != OK:
			return {
				"ok": false,
				"error": mkdir_result,
				"fallback_to_instance": true,
				"message": "Could not create resource directory: %s" % save_dir,
			}

	if ResourceLoader.exists(save_path):
		var existing_resource := ResourceLoader.load(save_path, "", ResourceLoader.CACHE_MODE_REPLACE)
		if existing_resource == null:
			return {
				"ok": false,
				"error": ERR_FILE_CANT_OPEN,
				"fallback_to_instance": true,
				"message": "Existing resource could not be loaded: %s" % save_path,
			}

		if not existing_resource is ArrayMesh:
			return {
				"ok": false,
				"error": ERR_FILE_CANT_WRITE,
				"fallback_to_instance": true,
				"message": "Existing resource at %s is %s, expected ArrayMesh. Save aborted." % [save_path, existing_resource.get_class()],
			}

		copy_array_mesh_contents(existing_resource, mesh)
		var overwrite_result := ResourceSaver.save(existing_resource, save_path)
		return {
			"ok": overwrite_result == OK,
			"error": overwrite_result,
			"fallback_to_instance": overwrite_result != OK,
			"message": "Failed to overwrite existing ArrayMesh at %s." % save_path,
		}

	var create_result := ResourceSaver.save(mesh, save_path)
	return {
		"ok": create_result == OK,
		"error": create_result,
		"fallback_to_instance": create_result != OK,
		"message": "Failed to create mesh resource at %s." % save_path,
	}


## Replaces the surfaces of [param target_mesh] with those of [param source_mesh].
##
## Used instead of saving a new resource so the existing [ArrayMesh] object keeps its
## identity, and everything already pointing at it sees the update.
static func copy_array_mesh_contents(target_mesh: ArrayMesh, source_mesh: ArrayMesh) -> void:
	target_mesh.clear_surfaces()
	for surface_idx in range(source_mesh.get_surface_count()):
		var primitive_type := source_mesh.surface_get_primitive_type(surface_idx)
		var arrays := source_mesh.surface_get_arrays(surface_idx)
		var blend_shape_arrays := []
		if source_mesh.has_method("surface_get_blend_shape_arrays"):
			blend_shape_arrays = source_mesh.surface_get_blend_shape_arrays(surface_idx)
		var lods := {}
		if source_mesh.has_method("surface_get_lods"):
			lods = source_mesh.surface_get_lods(surface_idx)
		target_mesh.add_surface_from_arrays(primitive_type, arrays, blend_shape_arrays, lods)
		var surface_material := source_mesh.surface_get_material(surface_idx)
		if surface_material != null:
			target_mesh.surface_set_material(surface_idx, surface_material)


## Loads a saved mesh bypassing the resource cache, so the instance in the scene
## reflects what was just written to disk.
static func load_mesh_resource_fresh(save_path: String) -> Mesh:
	if save_path.is_empty() or not ResourceLoader.exists(save_path):
		return null
	return ResourceLoader.load(save_path, "Mesh", ResourceLoader.CACHE_MODE_REPLACE) as Mesh
