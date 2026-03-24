@icon('res://addons/hego/assets/houdini.svg')
@tool
extends Node3D
class_name HEGoNode3D

@export_tool_button('Select HDA', "FileDialog") var select_hda_btn = _show_select_hda_dialog
## The asset definition name in Houdini, e.g. Sop/my_tool.hda
@export var asset_name: String
## Parm stash stores the parameters as a byte blob which stores parms between sessions
@export var parm_stash: PackedByteArray
## Input stash to store references to the inputs between sessions
@export var input_stash: Array


# Create var to store reference to the HEGoAssetNode in the session
var hego_asset_node: HEGoAssetNode
# Create var to store references to the input and merge nodes in the session
var hego_input_nodes: Dictionary

var input_names: PackedStringArray


func _elapsed_msec(start_usec: int) -> float:
	return float(Time.get_ticks_usec() - start_usec) / 1000.0


func _build_cook_timing_summary(timings: Dictionary, total_msec: float) -> String:
	var lines = PackedStringArray()
	lines.append("[HEGoNode3D]: Cook timing summary")
	lines.append("[HEGoNode3D]:   Instantiation phase: %.3f ms" % timings.get("instantiation", 0.0))
	lines.append("[HEGoNode3D]:   Input setup: %.3f ms" % timings.get("input_setup", 0.0))
	lines.append("[HEGoNode3D]:   Parm stash: %.3f ms" % timings.get("parm_stash", 0.0))
	lines.append("[HEGoNode3D]:   Cook: %.3f ms" % timings.get("cook", 0.0))
	lines.append("[HEGoNode3D]:   Mesh output: %.3f ms" % timings.get("mesh_output", 0.0))
	lines.append("[HEGoNode3D]:   Multimesh output: %.3f ms" % timings.get("multimesh_output", 0.0))
	lines.append("[HEGoNode3D]:   Object spawn output: %.3f ms" % timings.get("object_spawn_output", 0.0))
	lines.append("[HEGoNode3D]:   Terrain3D output: %.3f ms" % timings.get("terrain3d_output", 0.0))
	lines.append("[HEGoNode3D]:   Terrain3D instancer output: %.3f ms" % timings.get("terrain3d_instancer_output", 0.0))
	lines.append("[HEGoNode3D]:   Total cook(): %.3f ms" % total_msec)
	return "\n".join(lines)


func cook():
	var timings = {
		"instantiation": 0.0,
		"input_setup": 0.0,
		"parm_stash": 0.0,
		"cook": 0.0,
		"mesh_output": 0.0,
		"multimesh_output": 0.0,
		"object_spawn_output": 0.0,
		"terrain3d_output": 0.0,
		"terrain3d_instancer_output": 0.0,
	}
	var cook_start_usec = Time.get_ticks_usec()
	var phase_start_usec = cook_start_usec
	# Ensure valid AssetNode object
	if not hego_asset_node: hego_asset_node = HEGoAssetNode.new()
	# Assign HDA
	if asset_name.split("/").size() == 1:
		hego_asset_node.op_name = "Sop/" + asset_name
	else:
		hego_asset_node.op_name = asset_name
	# Check the id, which is -1 before instantiation
	var id = hego_asset_node.get_id()
	# Instantiate - Note, this function auto checks if it already is instantiated!
	hego_asset_node.instantiate()
	# Set transform
	hego_asset_node.set_transform(global_transform)
	# If the asset node was not instantiated beforehand, retrieve parm stash
	if id == -1 and parm_stash.size() > 0:
		hego_asset_node.set_preset(parm_stash)
		
	var outputs_node = get_node_or_null("Outputs")
	if outputs_node:
		outputs_node.free()
		timings["instantiation"] = _elapsed_msec(phase_start_usec)
		
	# SET INPUTS
	# Retrieve a string array containing the names of inputs
	if id == -1:
		input_names = hego_asset_node.get_input_names()
	# Loop over inputs
		phase_start_usec = Time.get_ticks_usec()
	for i in range(input_names.size()):
		# Retrieve godot node refs for input from input stash
		var inputs = Array()
		var settings = Dictionary()
		if input_stash.size() > i:
			var inputs_dict = input_stash[i]
			inputs = inputs_dict["inputs"]
			settings = inputs_dict["settings"]
		# If the input doesn't exist on Houdini side but does on Godot side, create it
		if not hego_input_nodes.has(i) and inputs.size() > 0:
			print("generating input nodes")
			# We always need a merge node and the array of input nodes to connect to it
			var input_array = Array()
			var merge_node = HEGoMergeNode.new()
			merge_node.instantiate()
			# fill input_array
			for input in inputs:
				var input_node = create_hego_input_node(input, settings)
				input_array.append(input_node)
			# Connect inputs to merge and merge to asset node
			merge_node.connect_inputs(input_array)
			hego_asset_node.connect_input(merge_node, i)
			# Create the dictionary to keep track
			var input_dict = Dictionary()
			input_dict["merge"] = merge_node
			input_dict["inputs"] = input_array
			hego_input_nodes[i] = input_dict
		# If the input exists on Houdini side, update it if anything changed
		elif hego_input_nodes.has(i):
			var input_dict = hego_input_nodes[i]
			var merge_node = input_dict["merge"]
			merge_node.instantiate()
			var input_array = input_dict["inputs"]
			# If there's less inputs on godo side than Houdini side, drop the extra inputs
			if inputs.size() < input_array.size():
				input_array.resize(inputs.size())
				# Update correct inputs
				for j in range(input_array.size()):
					input_array[j] = update_hego_input_node(input_array[j], inputs[j], settings)
			# If there's more inputs on godot side than houdini side
			elif inputs.size() > input_array.size():
				# loop over inputs on godot side
				for j in range(inputs.size()):
					# if input exists, update it
					if j <= input_array.size() - 1:
						input_array[j] = update_hego_input_node(input_array[j], inputs[j], settings)
					# if not, create it
					elif j > input_array.size() - 1:
						var input_node = create_hego_input_node(inputs[j], settings)
						input_array.append(input_node)
			# If counts match, just update all inputs
			elif inputs.size() == input_array.size():
				for j in range(inputs.size()):
					input_array[j] = update_hego_input_node(input_array[j], inputs[j], settings)
			# Reconnect inputs to merge
			merge_node.connect_inputs(input_array)
			# Connect merge to asset node
			hego_asset_node.connect_input(merge_node, i)
	timings["input_setup"] = _elapsed_msec(phase_start_usec)
	phase_start_usec = Time.get_ticks_usec()
	parm_stash = hego_asset_node.get_preset()
	timings["parm_stash"] = _elapsed_msec(phase_start_usec)
	# Cook once before all fetch operations
	phase_start_usec = Time.get_ticks_usec()
	hego_asset_node.cook()
	timings["cook"] = _elapsed_msec(phase_start_usec)
	# FETCH OUTPUTS
	
	phase_start_usec = Time.get_ticks_usec()
	handle_mesh_output()
	timings["mesh_output"] = _elapsed_msec(phase_start_usec)
	phase_start_usec = Time.get_ticks_usec()
	handle_multimesh_output()
	timings["multimesh_output"] = _elapsed_msec(phase_start_usec)
	phase_start_usec = Time.get_ticks_usec()
	handle_object_spawn_output()
	timings["object_spawn_output"] = _elapsed_msec(phase_start_usec)
	phase_start_usec = Time.get_ticks_usec()
	handle_terrain3d_output()
	timings["terrain3d_output"] = _elapsed_msec(phase_start_usec)
	phase_start_usec = Time.get_ticks_usec()
	handle_terrain3d_instancer_output()
	timings["terrain3d_instancer_output"] = _elapsed_msec(phase_start_usec)

	print(_build_cook_timing_summary(timings, _elapsed_msec(cook_start_usec)))


func handle_mesh_output():
	# use config to fetch output mesh
	var fetch_surfaces_default_config = load("res://addons/hego/surface_filters/fetch_surfaces_default.tres")
	# retrieve dictionary output, containing the mesh in godots surface_array format
	var dict = hego_asset_node.fetch_surfaces(fetch_surfaces_default_config, false)
	for hego_mesh_instance_key in dict.keys():
		var arr_mesh = ArrayMesh.new()
		var surface_id = 0
		for hego_material_key in dict[hego_mesh_instance_key]:
			var material_ref = hego_material_key
			var surface_array = dict[hego_mesh_instance_key][hego_material_key]["surface_array"]
			var hego_lod_array = dict[hego_mesh_instance_key][hego_material_key]["hego_lod"]
			if hego_lod_array[0] != null:
				var mesh_indices_array = surface_array[Mesh.ARRAY_INDEX]
				var lod_dict = float_to_int_triplet_dict(hego_lod_array, mesh_indices_array)
				surface_array[Mesh.ARRAY_INDEX] = lod_dict[.0]
				lod_dict.erase(.0)
				arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array, [], lod_dict)
			else:
				arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)
			if hego_material_key != null:
				var material = load(hego_material_key)
				if material is Material:
					arr_mesh.surface_set_material(surface_id, material)
			surface_id += 1
		var hego_mat_keys = dict[hego_mesh_instance_key].keys()
		var hego_storage_mode = dict[hego_mesh_instance_key][hego_mat_keys[0]]["hego_storage_mode"][0]
		var hego_resource_save_path = dict[hego_mesh_instance_key][hego_mat_keys[0]]["hego_resource_save_path"][0]
		
		if hego_storage_mode == null:
			hego_storage_mode = 0
		if hego_resource_save_path == null and hego_storage_mode > 0:
			push_error("[HEGoNode3D]: Save mode set to resource, but no resource save path specified.")
			push_warning("[HEGoNode3D]: Spawning as mesh instance instead.")
			hego_storage_mode = 0
		
		if hego_storage_mode > 0:
			var result := ResourceSaver.save(arr_mesh, hego_resource_save_path)
			if result == OK:
				print("[HEGoNode3D]: Successfully saved mesh to ", hego_resource_save_path)
			else:
				print("[HEGoNode3D]: Failed to save. Error code: %d", %result)
			
		if hego_storage_mode == 0 or hego_storage_mode == 2:
			var node_name_path = "hego_output_mesh_inst"
			if hego_mesh_instance_key != null:
				node_name_path = hego_mesh_instance_key
			# Split the path into parts
			node_name_path = "Outputs/" + node_name_path
			var parts = node_name_path.split("/")
			var current_node = self
			
			# Create intermediate Node3Ds
			for i in range(parts.size() - 1):
				var node_name = parts[i]
				var existing_node = current_node.get_node_or_null(node_name)
				
				if existing_node:
					current_node = existing_node
				else:
					var new_node = Node3D.new()
					new_node.name = node_name
					current_node.add_child(new_node)
					if Engine.is_editor_hint():
						new_node.owner = get_tree().edited_scene_root
					current_node = new_node
				
			# Create final MeshInstance3D
			var final_name = parts[parts.size() - 1]
			var mesh_instance = MeshInstance3D.new()
			mesh_instance.name = final_name
			current_node.add_child(mesh_instance)
			if Engine.is_editor_hint():
				mesh_instance.owner = get_tree().edited_scene_root
			if hego_storage_mode == 0:
				mesh_instance.mesh = arr_mesh
			else:
				mesh_instance.mesh = load(hego_resource_save_path)
			var hego_col_type = dict[hego_mesh_instance_key][hego_mat_keys[0]]["hego_col_type"][0]
			if hego_col_type == null:
				hego_col_type = 0
			if hego_col_type == 1:
				var decomp_settings = MeshConvexDecompositionSettings.new()
				var hego_col_decomp_settings: Dictionary = dict[hego_mesh_instance_key][hego_mat_keys[0]]["hego_col_decomp_settings"][0]
				if hego_col_decomp_settings != null:
					if hego_col_decomp_settings.has("convex_hull_approximation"):
						if hego_col_decomp_settings["convex_hull_approximation"] == 0:
							decomp_settings.convex_hull_approximation = false
					if hego_col_decomp_settings.has("convex_hull_downsampling"):
						decomp_settings.convex_hull_downsampling = hego_col_decomp_settings["convex_hull_downsampling"]
					if hego_col_decomp_settings.has("max_concavity"):
						decomp_settings.max_concavity = hego_col_decomp_settings["max_concavity"]
					if hego_col_decomp_settings.has("max_convex_hulls"):
						decomp_settings.max_convex_hulls = hego_col_decomp_settings["max_convex_hulls"]
					if hego_col_decomp_settings.has("max_num_vertices_per_convex_hull"):
						decomp_settings.max_num_vertices_per_convex_hull = hego_col_decomp_settings["max_num_vertices_per_convex_hull"]
					if hego_col_decomp_settings.has("min_volume_per_convex_hull"):
						decomp_settings.min_volume_per_convex_hull = hego_col_decomp_settings["min_volume_per_convex_hull"]
					if hego_col_decomp_settings.has("mode"):
						decomp_settings.mode = hego_col_decomp_settings["mode"]
					if hego_col_decomp_settings.has("normalize_mesh"):
						decomp_settings.normalize_mesh = hego_col_decomp_settings["normalize_mesh"]
					if hego_col_decomp_settings.has("plane_downsampling"):
						decomp_settings.plane_downsampling = hego_col_decomp_settings["plane_downsampling"]
					if hego_col_decomp_settings.has("project_hull_vertices"):
						decomp_settings.project_hull_vertices = hego_col_decomp_settings["project_hull_vertices"]
					if hego_col_decomp_settings.has("resolution"):
						decomp_settings.resolution = hego_col_decomp_settings["resolution"]
					if hego_col_decomp_settings.has("resolution_axes_clipping_bias"):
						decomp_settings.resolution_axes_clipping_bias = hego_col_decomp_settings["resolution_axes_clipping_bias"]
					if hego_col_decomp_settings.has("symmetry_planes_clipping_bias"):
						decomp_settings.symmetry_planes_clipping_bias = hego_col_decomp_settings["symmetry_planes_clipping_bias"]
				mesh_instance.create_multiple_convex_collisions(decomp_settings)
			elif hego_col_type == 2:
				mesh_instance.create_convex_collision()
			elif hego_col_type == 3:
				mesh_instance.create_trimesh_collision()


func handle_object_spawn_output():
	print("[HEGoNode3D]: Handling Object Spawn Output")
	var fetch_points_config = load("res://addons/hego/point_filters/fetch_points_default_object_spawning.tres")
	var output_dictionary = hego_asset_node.fetch_points(fetch_points_config, false)
	
	# Validate output dictionary
	if not output_dictionary or not output_dictionary.has("P") or not output_dictionary.P is Array:
		return
	
	var point_count = output_dictionary.P.size()
	if point_count == 0:
		print("[HEGoNode3D]: No points to process")
		return
	
	# Get the Outputs node, create if it doesn't exist
	var outputs_node = get_node_or_null("Outputs")
	if not outputs_node:
		outputs_node = Node3D.new()
		outputs_node.name = "Outputs"
		add_child(outputs_node)
		if Engine.is_editor_hint():
			outputs_node.owner = get_tree().edited_scene_root if get_tree().edited_scene_root else self
	
	# Cache for PackedScene resources
	var scene_cache = {}
	
	# Default values (aligned with multimesh)
	var default_normal = Vector3(0, 0, 1).normalized()
	var default_up = Vector3(0, 1, 0).normalized()
	var default_pscale = 1.0
	var default_scale = Vector3(1, 1, 1)
	
	# Process each point
	for i in range(point_count):
		# Fetch attributes with defaults
		var p = output_dictionary.P[i] if i < output_dictionary.P.size() else Vector3.ZERO
		var normal = output_dictionary.N[i].normalized() if output_dictionary.has("N") and i < output_dictionary.N.size() and output_dictionary.N[i] is Vector3 and output_dictionary.N[i] != null else default_normal
		var up = output_dictionary.up[i].normalized() if output_dictionary.has("up") and i < output_dictionary.up.size() and output_dictionary.up[i] is Vector3 and output_dictionary.up[i] != null else default_up
		var pscale = output_dictionary.pscale[i] if output_dictionary.has("pscale") and i < output_dictionary.pscale.size() and output_dictionary.pscale[i] is float and output_dictionary.pscale[i] != null else default_pscale
		var spawn_scale = output_dictionary.scale[i] if output_dictionary.has("scale") and i < output_dictionary.scale.size() and output_dictionary.scale[i] is Vector3 and output_dictionary.scale[i] != null else default_scale
		var node_path = output_dictionary.hego_node_path[i] if output_dictionary.has("hego_node_path") and i < output_dictionary.hego_node_path.size() and output_dictionary.hego_node_path[i] is String else "Objects"
		var spawn_type = output_dictionary.hego_spawn_type[i] if output_dictionary.has("hego_spawn_type") and i < output_dictionary.hego_spawn_type.size() and output_dictionary.hego_spawn_type[i] is int else 0
		var resource_path = output_dictionary.hego_resource_path[i] if output_dictionary.has("hego_resource_path") and i < output_dictionary.hego_resource_path.size() and output_dictionary.hego_resource_path[i] is String else ""
		var spawn_class_name = output_dictionary.hego_class_name[i] if output_dictionary.has("hego_class_name") and i < output_dictionary.hego_class_name.size() and output_dictionary.hego_class_name[i] is String else "Node3D"
		
		# Fetch custom properties dictionary
		var custom_properties = output_dictionary.hego_custom_properties[i] if output_dictionary.has("hego_custom_properties") and i < output_dictionary.hego_custom_properties.size() and output_dictionary.hego_custom_properties[i] is Dictionary else {}
		
		# Ensure valid node path and create intermediate nodes
		var parent_node = outputs_node
		var path_parts = node_path.split("/", false)
		var current_path = "Outputs"
		for j in range(path_parts.size() - 1):
			var part = path_parts[j]
			current_path += "/" + part
			var next_node = get_node_or_null(current_path)
			if not next_node:
				next_node = Node3D.new()
				next_node.name = part
				parent_node.add_child(next_node)
				if Engine.is_editor_hint():
					next_node.owner = get_tree().edited_scene_root if get_tree().edited_scene_root else self
				parent_node = next_node
			else:
				parent_node = next_node
		
		# Create the final node name (last part of hego_node_path or default)
		var final_node_name = path_parts[-1] if path_parts.size() > 0 else "Object_" + str(i)
		
		# Handle name conflicts
		var base_name = final_node_name
		var suffix = 0
		while parent_node.get_node_or_null(final_node_name):
			suffix += 1
			final_node_name = base_name + "_" + str(suffix).pad_zeros(3)
		
		# Spawn the object based on spawn_type
		var new_node: Node3D = null
		if spawn_type == 0:
			# Spawn registered class by name
			if ClassDB.class_exists(spawn_class_name):
				new_node = ClassDB.instantiate(spawn_class_name)
				if not new_node is Node3D:
					push_warning("[HEGoNode3D]: Class '%s' is not a Node3D, falling back to Node3D" % spawn_class_name)
					new_node.queue_free()
					new_node = Node3D.new()
			else:
				push_warning("[HEGoNode3D]: Invalid class name '%s', falling back to Node3D" % spawn_class_name)
				new_node = Node3D.new()
		elif spawn_type == 1:
			# Spawn scene from resource path
			if ResourceLoader.exists(resource_path):
				if not scene_cache.has(resource_path):
					scene_cache[resource_path] = load(resource_path) as PackedScene
				var scene = scene_cache[resource_path]
				if scene and scene.can_instantiate():
					new_node = scene.instantiate() as Node3D
					if not new_node:
						push_warning("[HEGoNode3D]: Resource %s is not a Node3D scene, falling back to Node3D" % resource_path)
						new_node = Node3D.new()
				else:
					push_warning("[HEGoNode3D]: Invalid scene at %s, falling back to Node3D" % resource_path)
					new_node = Node3D.new()
			else:
				push_warning("[HEGoNode3D]: Resource path %s does not exist, falling back to Node3D" % resource_path)
				new_node = Node3D.new()
		else:
			push_warning("[HEGoNode3D]: Invalid spawn type %d, falling back to Node3D" % spawn_type)
			new_node = Node3D.new()
		
		# Set node properties
		new_node.name = final_node_name
		new_node.transform.origin = p
		
		# Create basis from normal and up vectors (aligned with multimesh)
		var basis = Basis()
		var right = up.cross(normal).normalized()
		if right == Vector3.ZERO:
			push_warning("[HEGoNode3D]: Invalid normal or up vector for point %d (collinear), using default basis" % i)
			basis = Basis()
		else:
			basis.x = right
			basis.y = up
			basis.z = normal
		
		# Apply scaling
		basis = basis.scaled(spawn_scale * pscale)
		new_node.transform.basis = basis
		
		# Apply custom properties from hego_custom_properties dictionary
		if not custom_properties.is_empty():
			apply_custom_properties(new_node, custom_properties)
		
		# Add to scene tree
		parent_node.add_child(new_node)
		if Engine.is_editor_hint():
			new_node.owner = get_tree().edited_scene_root if get_tree().edited_scene_root else self
		
		# Log for debugging
		#print("[HEGoNode3D]: Spawned %s at %s under %s" % [new_node.name, p, parent_node.get_path()])


func handle_terrain3d_output():
	if not ClassDB.class_exists("Terrain3D"):
		push_warning("[HEGoNode3D]: Terrain3D addon is not installed, skipping Terrain3D output.")
		return

	var requested_attrs = PackedStringArray([
		"hegot3d_spawn_terrain",
		"hegot3d_data_directory",
		"hegot3d_node_path",
		"hegot3d_region_size",
		"hegot3d_albedo_texture",
		"hegot3d_normal_texture",
		"hegot3d_ao_strength",
		"hegot3d_detiling_rotation",
		"hegot3d_detiling_shift",
		"hegot3d_id",
		"hegot3d_name",
		"hegot3d_normal_depth",
		"hegot3d_roughness",
		"hegot3d_uv_scale"
	])
	var layers = hego_asset_node.get_heightfield_layers(requested_attrs, false)
	var height_layer = _t3d_get_layer_by_name(layers, "height")
	if height_layer.is_empty():
		return

	var spawn_terrain_attr = _t3d_get_attr_value(height_layer, "hegot3d_spawn_terrain")
	if spawn_terrain_attr == null or int(spawn_terrain_attr) != 1:
		return

	var transform_rotation = height_layer.get("transform_rotation", Vector3.ZERO)
	if not _t3d_approx_equal_vec3(transform_rotation, Vector3(-90.0, -90.0, 0.0), 0.5):
		push_warning("[HEGoNode3D]: Heightfield rotation is not default (-90,-90,0). Terrain3D output may be incorrect.")

	var voxel_scale_x = float(height_layer.get("voxel_scale_x", 1.0))
	var voxel_scale_y = float(height_layer.get("voxel_scale_y", voxel_scale_x))
	if abs(voxel_scale_x - voxel_scale_y) > 0.0001:
		push_warning("[HEGoNode3D]: voxel_scale_x and voxel_scale_y differ. Terrain3D uses uniform vertex spacing.")

	if voxel_scale_x <= 0.0:
		push_error("[HEGoNode3D]: Invalid voxel_scale_x for Terrain3D output.")
		return

	var node_path_attr = _t3d_get_attr_value(height_layer, "hegot3d_node_path")
	var terrain_node_path = "Terrain3D"
	if node_path_attr != null and node_path_attr is String and not node_path_attr.strip_edges().is_empty():
		terrain_node_path = node_path_attr.strip_edges()

	var data_dir_attr = _t3d_get_attr_value(height_layer, "hegot3d_data_directory")
	if data_dir_attr == null or not data_dir_attr is String or data_dir_attr.strip_edges().is_empty():
		push_error("[HEGoNode3D]: hegot3d_data_directory is required for Terrain3D output.")
		return
	var terrain_data_directory = data_dir_attr.strip_edges()

	var region_size_attr = _t3d_get_attr_value(height_layer, "hegot3d_region_size")
	var region_size = 256
	if _t3d_is_valid_region_size(region_size_attr):
		region_size = int(region_size_attr)
	elif region_size_attr != null:
		push_warning("[HEGoNode3D]: Invalid hegot3d_region_size. Using default value 256.")

	var region_map_layer = _t3d_get_layer_by_name(layers, "hegot3d_region_map")
	var hole_layer = _t3d_get_layer_by_name(layers, "hegot3d_hole")
	var texture_layers = _t3d_collect_texture_layers(layers)
	var validated_texture_layers: Array = []
	var control_generation_enabled = false
	var lowest_valid_texture_slot = -1
	var terrain3d_util = null
	if not texture_layers.is_empty():
		var validation_result = _t3d_validate_texture_layers(texture_layers)
		if not validation_result.get("ok", false):
			push_warning(validation_result.get("warning", "[HEGoNode3D]: Skipping Terrain3D control maps."))
		else:
			if not ClassDB.class_exists("Terrain3DUtil"):
				push_warning("[HEGoNode3D]: Terrain3DUtil is unavailable, skipping Terrain3D control maps.")
			else:
				terrain3d_util = ClassDB.instantiate("Terrain3DUtil")
				if terrain3d_util == null:
					push_warning("[HEGoNode3D]: Failed to instantiate Terrain3DUtil, skipping Terrain3D control maps.")
				else:
					validated_texture_layers = validation_result.get("layers", [])
					lowest_valid_texture_slot = int(validation_result.get("lowest_slot", -1))
					control_generation_enabled = lowest_valid_texture_slot >= 0

	var path_parts = terrain_node_path.split("/", false)
	if path_parts.is_empty():
		push_error("[HEGoNode3D]: hegot3d_node_path is invalid.")
		return

	var current_node = self
	for i in range(path_parts.size() - 1):
		var part_name = path_parts[i]
		if part_name.is_empty():
			continue
		var next_node = current_node.get_node_or_null(part_name)
		if not next_node:
			next_node = Node3D.new()
			next_node.name = part_name
			current_node.add_child(next_node)
			if Engine.is_editor_hint():
				next_node.owner = get_tree().edited_scene_root
		current_node = next_node

	var terrain_name = path_parts[path_parts.size() - 1]
	if terrain_name.is_empty():
		push_error("[HEGoNode3D]: hegot3d_node_path is invalid.")
		return

	var existing_terrain = current_node.get_node_or_null(terrain_name)
	if existing_terrain:
		existing_terrain.free()

	var terrain = ClassDB.instantiate("Terrain3D")
	if terrain == null:
		push_error("[HEGoNode3D]: Failed to instantiate Terrain3D.")
		return

	terrain.name = terrain_name
	current_node.add_child(terrain)
	if Engine.is_editor_hint():
		terrain.owner = get_tree().edited_scene_root

	terrain.set("region_size", region_size)
	terrain.set("vertex_spacing", voxel_scale_x)
	terrain.set("data_directory", terrain_data_directory)

	var terrain_material = terrain.get("material")
	if terrain_material != null:
		# 0 corresponds to Terrain3DMaterial.WorldBackground.NONE.
		if terrain_material.has_method("set_world_background"):
			terrain_material.call("set_world_background", 0)
		else:
			terrain_material.set("world_background", 0)

	var terrain_data = terrain.get("data")
	if terrain_data == null:
		push_error("[HEGoNode3D]: Terrain3D data object is not available.")
		return

	var terrain_assets = terrain.get("assets")
	if control_generation_enabled:
		if terrain_assets == null:
			if ClassDB.class_exists("Terrain3DAssets"):
				terrain_assets = ClassDB.instantiate("Terrain3DAssets")
				terrain.set("assets", terrain_assets)
		if terrain_assets == null:
			push_warning("[HEGoNode3D]: Terrain3D assets object is unavailable, skipping Terrain3D control maps.")
			control_generation_enabled = false
		else:
			var weight_fetch_failed = false
			for texture_layer in validated_texture_layers:
				var texture_asset = ClassDB.instantiate("Terrain3DTextureAsset")
				if texture_asset == null:
					push_warning("[HEGoNode3D]: Failed to instantiate Terrain3DTextureAsset, skipping Terrain3D control maps.")
					control_generation_enabled = false
					break

				texture_asset.call("set_albedo_texture", texture_layer["albedo_texture"])
				if texture_asset.has_method("set_normal_texture"):
					texture_asset.call("set_normal_texture", texture_layer["normal_texture"])
				else:
					_t3d_set_optional_property(texture_asset, "normal_texture", texture_layer["normal_texture"])

				for optional_property in texture_layer["optional_properties"].keys():
					_t3d_set_optional_property(texture_asset, optional_property, texture_layer["optional_properties"][optional_property])

				terrain_assets.call("set_texture", int(texture_layer["slot"]), texture_asset)

				var weight_image = hego_asset_node.fetch_heightfield_layer_image(int(texture_layer["part_id"]), false)
				if weight_image != null:
					weight_image = _t3d_fix_heightfield_image_transform(weight_image)
				if weight_image == null:
					push_warning("[HEGoNode3D]: Failed to fetch weight image for layer %s, skipping Terrain3D control maps." % texture_layer["layer_name"])
					weight_fetch_failed = true
					break
				texture_layer["weight_image"] = weight_image

			if terrain_assets.has_signal("textures_changed"):
				terrain_assets.emit_signal("textures_changed")

			if weight_fetch_failed:
				control_generation_enabled = false
				validated_texture_layers.clear()

	var hole_image = null
	if control_generation_enabled and not hole_layer.is_empty() and hole_layer.has("part_id"):
		hole_image = hego_asset_node.fetch_heightfield_layer_image(int(hole_layer["part_id"]), false)
		if hole_image != null:
			hole_image = _t3d_fix_heightfield_image_transform(hole_image)
		if hole_image == null:
			push_warning("[HEGoNode3D]: Failed to fetch hegot3d_hole layer, continuing without hole control bits.")

	# Clear all regions to avoid stale content when reusing an existing data directory.
	var active_regions = terrain_data.call("get_regions_active")
	for region in active_regions:
		terrain_data.call("remove_region", region, false)
	terrain_data.call("update_maps", 3, true, false)

	var part_id = int(height_layer.get("part_id", -1))
	if part_id < 0:
		push_error("[HEGoNode3D]: Height layer has invalid part_id.")
		return

	var height_image = hego_asset_node.fetch_heightfield_layer_image(part_id, false)
	if height_image != null:
		height_image = _t3d_fix_heightfield_image_transform(height_image)
	if height_image == null:
		push_error("[HEGoNode3D]: Failed to fetch height image for Terrain3D output.")
		return

	var region_map_image = null
	if not region_map_layer.is_empty() and region_map_layer.has("part_id"):
		region_map_image = hego_asset_node.fetch_heightfield_layer_image(int(region_map_layer["part_id"]), false)
		if region_map_image != null:
			region_map_image = _t3d_fix_heightfield_image_transform(region_map_image)

	var color_layer_r = _t3d_get_layer_by_name(layers, "hegot3d_color_map_r")
	var color_layer_g = _t3d_get_layer_by_name(layers, "hegot3d_color_map_g")
	var color_layer_b = _t3d_get_layer_by_name(layers, "hegot3d_color_map_b")
	var color_layer_roughness = _t3d_get_layer_by_name(layers, "hegot3d_color_map_roughness")
	var has_any_color_layer = not color_layer_r.is_empty() or not color_layer_g.is_empty() or not color_layer_b.is_empty() or not color_layer_roughness.is_empty()

	var color_image_r = null
	var color_image_g = null
	var color_image_b = null
	var color_image_roughness = null
	if has_any_color_layer:
		if not color_layer_r.is_empty() and color_layer_r.has("part_id"):
			color_image_r = hego_asset_node.fetch_heightfield_layer_image(int(color_layer_r["part_id"]), false)
			if color_image_r != null:
				color_image_r = _t3d_fix_heightfield_image_transform(color_image_r)
		if not color_layer_g.is_empty() and color_layer_g.has("part_id"):
			color_image_g = hego_asset_node.fetch_heightfield_layer_image(int(color_layer_g["part_id"]), false)
			if color_image_g != null:
				color_image_g = _t3d_fix_heightfield_image_transform(color_image_g)
		if not color_layer_b.is_empty() and color_layer_b.has("part_id"):
			color_image_b = hego_asset_node.fetch_heightfield_layer_image(int(color_layer_b["part_id"]), false)
			if color_image_b != null:
				color_image_b = _t3d_fix_heightfield_image_transform(color_image_b)
		if not color_layer_roughness.is_empty() and color_layer_roughness.has("part_id"):
			color_image_roughness = hego_asset_node.fetch_heightfield_layer_image(int(color_layer_roughness["part_id"]), false)
			if color_image_roughness != null:
				color_image_roughness = _t3d_fix_heightfield_image_transform(color_image_roughness)

	var voxel_count_x = int(height_layer.get("voxel_count_x", height_image.get_width()))
	var voxel_count_y = int(height_layer.get("voxel_count_y", height_image.get_height()))
	var transform_position = height_layer.get("transform_position", Vector3.ZERO)

	var corner_x = transform_position.x - (voxel_scale_x * 0.5)
	var corner_z = transform_position.z - (voxel_scale_x * 0.5)
	var region_world_size = float(region_size) * voxel_scale_x
	if region_world_size <= 0.0:
		push_error("[HEGoNode3D]: Invalid region world size for Terrain3D output.")
		return

	var snapped_x = snapped(corner_x, region_world_size)
	var snapped_z = snapped(corner_z, region_world_size)
	if abs(snapped_x - corner_x) > 0.0001 or abs(snapped_z - corner_z) > 0.0001:
		push_warning("[HEGoNode3D]: Heightfield offset snapped to Terrain3D region grid.")

	var image_world_end_x = corner_x + (float(voxel_count_x) * voxel_scale_x)
	var image_world_end_z = corner_z + (float(voxel_count_y) * voxel_scale_x)
	var rx_start = int(floor((corner_x - snapped_x) / region_world_size))
	var rx_end = int(ceil((image_world_end_x - snapped_x) / region_world_size)) - 1
	var rz_start = int(floor((corner_z - snapped_z) / region_world_size))
	var rz_end = int(ceil((image_world_end_z - snapped_z) / region_world_size)) - 1

	var wrote_any_region = false
	for rz in range(rz_start, rz_end + 1):
		for rx in range(rx_start, rx_end + 1):
			var world_region_x = snapped_x + (float(rx) * region_world_size)
			var world_region_z = snapped_z + (float(rz) * region_world_size)

			var pixel_start_x = int(round((world_region_x - corner_x) / voxel_scale_x))
			var pixel_start_z = int(round((world_region_z - corner_z) / voxel_scale_x))
			var pixel_end_x = pixel_start_x + region_size
			var pixel_end_z = pixel_start_z + region_size

			if pixel_end_x <= 0 or pixel_end_z <= 0 or pixel_start_x >= voxel_count_x or pixel_start_z >= voxel_count_y:
				continue

			if region_map_image != null:
				var map_sample_x = clamp(pixel_start_x + (region_size / 2), 0, voxel_count_x - 1)
				var map_sample_z = clamp(pixel_start_z + (region_size / 2), 0, voxel_count_y - 1)
				if region_map_image.get_pixel(map_sample_x, map_sample_z).r < 0.5:
					continue

			var clip_x0 = maxi(pixel_start_x, 0)
			var clip_z0 = maxi(pixel_start_z, 0)
			var clip_x1 = mini(pixel_end_x, voxel_count_x)
			var clip_z1 = mini(pixel_end_z, voxel_count_y)
			if clip_x1 <= clip_x0 or clip_z1 <= clip_z0:
				continue

			var src_rect = Rect2i(clip_x0, clip_z0, clip_x1 - clip_x0, clip_z1 - clip_z0)
			var clipped_region = height_image.get_region(src_rect)
			var region_image = Image.create(region_size, region_size, false, Image.FORMAT_RF)
			region_image.fill(Color(0.0, 0.0, 0.0, 1.0))
			var dest_x = clip_x0 - pixel_start_x
			var dest_z = clip_z0 - pixel_start_z
			region_image.blit_rect(clipped_region, Rect2i(0, 0, clipped_region.get_width(), clipped_region.get_height()), Vector2i(dest_x, dest_z))

			var imported_images: Array[Image] = []
			imported_images.resize(3)
			imported_images[0] = region_image

			if control_generation_enabled:
				var region_control_image = Image.create(region_size, region_size, false, Image.FORMAT_RF)
				var default_control_bits = _t3d_build_control_bits_for_pixel(validated_texture_layers, terrain3d_util, -1, -1, lowest_valid_texture_slot, hole_image)
				region_control_image.fill(Color(float(terrain3d_util.call("as_float", default_control_bits)), 0.0, 0.0, 1.0))
				for local_z in range(clipped_region.get_height()):
					var src_z = clip_z0 + local_z
					var dst_z = dest_z + local_z
					for local_x in range(clipped_region.get_width()):
						var src_x = clip_x0 + local_x
						var dst_x = dest_x + local_x
						var control_bits = _t3d_build_control_bits_for_pixel(validated_texture_layers, terrain3d_util, src_x, src_z, lowest_valid_texture_slot, hole_image)
						region_control_image.set_pixel(dst_x, dst_z, Color(float(terrain3d_util.call("as_float", control_bits)), 0.0, 0.0, 1.0))

				imported_images[1] = region_control_image

			if has_any_color_layer:
				var region_color_image = Image.create(region_size, region_size, false, Image.FORMAT_RGBA8)
				region_color_image.fill(Color(1.0, 1.0, 1.0, 0.5))
				for local_z in range(clipped_region.get_height()):
					var src_z = clip_z0 + local_z
					var dst_z = dest_z + local_z
					for local_x in range(clipped_region.get_width()):
						var src_x = clip_x0 + local_x
						var dst_x = dest_x + local_x

						var channel_r = 1.0
						if color_image_r != null and src_x < color_image_r.get_width() and src_z < color_image_r.get_height():
							channel_r = clampf(color_image_r.get_pixel(src_x, src_z).r, 0.0, 1.0)

						var channel_g = 1.0
						if color_image_g != null and src_x < color_image_g.get_width() and src_z < color_image_g.get_height():
							channel_g = clampf(color_image_g.get_pixel(src_x, src_z).r, 0.0, 1.0)

						var channel_b = 1.0
						if color_image_b != null and src_x < color_image_b.get_width() and src_z < color_image_b.get_height():
							channel_b = clampf(color_image_b.get_pixel(src_x, src_z).r, 0.0, 1.0)

						var channel_roughness = 0.5
						if color_image_roughness != null and src_x < color_image_roughness.get_width() and src_z < color_image_roughness.get_height():
							channel_roughness = clampf(color_image_roughness.get_pixel(src_x, src_z).r, 0.0, 1.0)

						region_color_image.set_pixel(dst_x, dst_z, Color(channel_r, channel_g, channel_b, channel_roughness))

				imported_images[2] = region_color_image

			terrain_data.call("import_images", imported_images, Vector3(world_region_x, 0.0, world_region_z), 0.0, 1.0)
			wrote_any_region = true

	if not wrote_any_region:
		push_warning("[HEGoNode3D]: Terrain3D output produced no regions.")

	terrain_data.call("calc_height_range", true)
	terrain_data.call("save_directory", terrain_data_directory)


func handle_terrain3d_instancer_output():
	if not ClassDB.class_exists("Terrain3D"):
		return

	var fetch_points_config = load("res://addons/hego/point_filters/fetch_points_default_terrain3d.tres")
	if fetch_points_config == null:
		push_warning("[HEGoNode3D]: Terrain3D instancer fetch config could not be loaded.")
		return

	var output_dictionary = hego_asset_node.fetch_points(fetch_points_config, false)
	if not output_dictionary is Dictionary or output_dictionary.is_empty():
		return

	for terrain_path_value in output_dictionary.keys():
		if terrain_path_value == null:
			continue

		var terrain_path = str(terrain_path_value)
		if terrain_path.strip_edges().is_empty():
			continue

		var per_mesh_points = output_dictionary[terrain_path_value]
		if not per_mesh_points is Dictionary:
			push_warning("[HEGoNode3D]: Unexpected Terrain3D instancer fetch structure for %s." % terrain_path)
			continue

		var terrain = _t3d_find_node_from_path(terrain_path)
		if terrain == null:
			push_warning("[HEGoNode3D]: Terrain3D node %s was not found, skipping instancer output." % terrain_path)
			continue

		if not terrain.has_method("get_instancer"):
			push_warning("[HEGoNode3D]: Node %s does not expose a Terrain3D instancer." % terrain_path)
			continue

		var instancer = terrain.call("get_instancer")
		if instancer == null:
			push_warning("[HEGoNode3D]: Terrain3D instancer is unavailable on %s." % terrain_path)
			continue

		var assets = _t3d_get_terrain_assets(terrain)
		if assets == null:
			push_warning("[HEGoNode3D]: Terrain3D assets are unavailable on %s." % terrain_path)
			continue

		_t3d_clear_generated_mesh_slots(assets, instancer)
		if assets.has_signal("meshes_changed"):
			assets.emit_signal("meshes_changed")

		for scene_path_value in per_mesh_points.keys():
			if scene_path_value == null:
				continue

			var scene_path = str(scene_path_value)
			if scene_path.strip_edges().is_empty():
				continue

			var point_dict = per_mesh_points[scene_path_value]
			if not point_dict is Dictionary:
				push_warning("[HEGoNode3D]: Invalid point dictionary for Terrain3D scene %s." % scene_path)
				continue

			if not point_dict.has("P") or not point_dict["P"] is Array:
				push_warning("[HEGoNode3D]: Missing P attribute for Terrain3D scene %s." % scene_path)
				continue

			var positions: Array = point_dict["P"]
			if positions.is_empty():
				continue

			var mesh_slot = _t3d_find_mesh_slot_by_scene_path(assets, scene_path)
			if mesh_slot < 0:
				mesh_slot = _t3d_assign_generated_mesh_slot(assets, scene_path)
				if mesh_slot < 0:
					push_warning("[HEGoNode3D]: Could not allocate Terrain3D mesh slot for %s." % scene_path)
					continue

			var mesh_asset = assets.call("get_mesh_asset", mesh_slot)
			if mesh_asset != null:
				_t3d_apply_mesh_asset_instancer_settings(mesh_asset, point_dict)

			if instancer.has_method("clear_by_mesh"):
				instancer.call("clear_by_mesh", mesh_slot)

			var transforms: Array[Transform3D] = []
			var colors: Array[Color] = []

			var default_normal = Vector3(0.0, 0.0, 1.0)
			var default_up = Vector3(0.0, 1.0, 0.0)
			var default_scale = Vector3.ONE
			var default_pscale = 1.0
			var default_color = Color(1.0, 1.0, 1.0, 1.0)

			for i in range(positions.size()):
				var pos = positions[i]
				if not pos is Vector3:
					continue

				var normal = default_normal
				if point_dict.has("N") and point_dict["N"] is Array and i < point_dict["N"].size() and point_dict["N"][i] is Vector3 and point_dict["N"][i] != null:
					normal = point_dict["N"][i].normalized()

				var up = default_up
				if point_dict.has("up") and point_dict["up"] is Array and i < point_dict["up"].size() and point_dict["up"][i] is Vector3 and point_dict["up"][i] != null:
					up = point_dict["up"][i].normalized()

				var scale = default_scale
				if point_dict.has("scale") and point_dict["scale"] is Array and i < point_dict["scale"].size() and point_dict["scale"][i] is Vector3 and point_dict["scale"][i] != null:
					scale = point_dict["scale"][i]

				var pscale = default_pscale
				if point_dict.has("pscale") and point_dict["pscale"] is Array and i < point_dict["pscale"].size() and point_dict["pscale"][i] is float and point_dict["pscale"][i] != null:
					pscale = point_dict["pscale"][i]

				var basis = Basis()
				var right = up.cross(normal).normalized()
				if right != Vector3.ZERO:
					basis.x = right
					basis.y = up
					basis.z = normal
				basis = basis.scaled(scale * pscale)
				transforms.append(Transform3D(basis, pos))

				var color = default_color
				if point_dict.has("Cd") and point_dict["Cd"] is Array and i < point_dict["Cd"].size() and point_dict["Cd"][i] != null:
					if point_dict["Cd"][i] is Color:
						color = point_dict["Cd"][i]
					elif point_dict["Cd"][i] is Vector3:
						var c = point_dict["Cd"][i]
						color = Color(c.x, c.y, c.z, 1.0)
				colors.append(color)

			if transforms.is_empty():
				continue

			if not instancer.has_method("add_transforms"):
				push_warning("[HEGoNode3D]: Terrain3D instancer on %s does not support add_transforms." % terrain_path)
				break

			instancer.call("add_transforms", mesh_slot, transforms, colors, false)

		if instancer.has_method("update_mmis"):
			instancer.call("update_mmis", false)


# Helper function to apply custom properties from a nested dictionary
func apply_custom_properties(obj: Object, properties: Dictionary):
	for key in properties.keys():
		var value = properties[key]
		
		if value is Dictionary and value.has("hego_val"):
			var actual_value = value["hego_val"]
			
			# Check for nested dictionaries
			var nested_properties = {}
			for sub_key in value.keys():
				if sub_key != "hego_val" and value[sub_key] is Dictionary:
					nested_properties[sub_key] = value[sub_key]
			
			# Set the property if it's a leaf value
			if nested_properties.is_empty():
				set_property(obj, key, actual_value)
			else:
				# If the property is an object, instantiate it first
				if actual_value is String and ClassDB.class_exists(actual_value):
					var new_obj = ClassDB.instantiate(actual_value)
					set_property(obj, key, new_obj)
					# Apply nested properties to the new object
					apply_custom_properties(new_obj, nested_properties)
				elif actual_value is String and ResourceLoader.exists(actual_value):
					var resource = load(actual_value)
					set_property(obj, key, resource)
					# Apply nested properties to the resource if applicable
					if resource is Object:
						apply_custom_properties(resource, nested_properties)
				else:
					set_property(obj, key, actual_value)
					# Apply nested properties to the object if it was set
					var target_obj = obj.get(key) if obj.get_property_list().any(func(p): return p.name == key) else null
					if target_obj is Object:
						apply_custom_properties(target_obj, nested_properties)
		else:
			push_warning("[HEGoNode3D]: Invalid property format for %s, expected dictionary with hego_val" % key)


# Helper function to set a single property
func set_property(obj: Object, property: String, value):
	var prop_info = obj.get_property_list().filter(func(p): return p.name == property)
	if prop_info.size() > 0:
		if is_compatible_type(value, prop_info[0].type, prop_info[0].class_name if prop_info[0].class_name else ""):
			obj.set(property, value)
			#print("[HEGoNode3D]: Set %s.%s = %s" % [obj.get_class(), property, value])
		else:
			var prop_type = prop_info[0].type
			var value_type = typeof(value)
			var prop_class = prop_info[0].class_name if prop_info[0].class_name else "unknown"
			var value_class = value.get_class() if value is Object else "none"
			push_warning("[HEGoNode3D]: Type mismatch for %s.%s (expected %s:%s, got %s:%s), skipping" % [obj.get_class(), property, prop_type, prop_class, value_type, value_class])
	else:
		push_warning("[HEGoNode3D]: Property %s does not exist on %s, skipping" % [property, obj.get_class()])


# Helper function to check type compatibility
func is_compatible_type(value, expected_type: int, expected_class: String) -> bool:
	var actual_type = typeof(value)
	
	# For TYPE_OBJECT, check if the value's class is compatible with the expected class
	if expected_type == TYPE_OBJECT and value is Object:
		if expected_class.is_empty():
			return true
		var value_class = value.get_class()
		return ClassDB.class_exists(value_class) and ClassDB.is_parent_class(value_class, expected_class)
	
	# For non-object types, check type equality
	if actual_type == expected_type:
		return true
	
	# Allow common type conversions
	if expected_type == TYPE_VECTOR3 and actual_type == TYPE_VECTOR2:
		return true # Vector2 can be converted to Vector3
	if expected_type == TYPE_COLOR and actual_type == TYPE_VECTOR3:
		return true # Vector3 can be converted to Color
	if expected_type == TYPE_FLOAT and actual_type == TYPE_INT:
		return true # Int can be converted to float
	
	return false


func handle_multimesh_output():
	print("[HEGoNode3D]: Handling Multimesh Output")
	var fetch_points_config = load("res://addons/hego/point_filters/fetch_points_default_multimesh_instancing.tres")
	var output_dictionary = hego_asset_node.fetch_points(fetch_points_config, false)
	#print(output_dictionary)
	for key in output_dictionary.keys():
		var hego_multimesh = "MultiMesh"
		if key != null:
			hego_multimesh = key
		var resource_dict = output_dictionary[key]
		for resource_path in resource_dict.keys():
			if resource_path != null:
				var mesh_resource = load(resource_path)
				if mesh_resource is Mesh:
					var res_name = resource_path.get_file().get_basename()
					var hego_multimesh_name = "Outputs/" + hego_multimesh + "_" + res_name
					var point_dict = resource_dict[resource_path]
					# we now need to spawn mesh_resource in a multimesh
					# with hego_multimesh_name as path/name
					# and use points_dict to add instances with attributes
					setup_multimesh(mesh_resource, hego_multimesh_name, point_dict)


func setup_multimesh(mesh_resource: Mesh, hego_multimesh_name: String, point_dict: Dictionary) -> void:
	# Early exit if no points
	var point_count = point_dict["P"].size()
	if point_count == 0:
		return
	
	# Create the MultiMeshInstance3D node
	var multimesh_instance = MultiMeshInstance3D.new()
	var path_array = hego_multimesh_name.split("/")
	var current_node = self
	for i in range(path_array.size() - 1):
		var dir_name = path_array[i]
		if not current_node.has_node(dir_name):
			var new_dir = Node3D.new()
			new_dir.name = dir_name
			current_node.add_child(new_dir)
			new_dir.owner = get_tree().edited_scene_root
		current_node = current_node.get_node(dir_name)
	
	var multimesh_name = path_array[path_array.size() - 1]
	multimesh_instance.name = multimesh_name
	current_node.add_child(multimesh_instance)
	multimesh_instance.owner = get_tree().edited_scene_root
	
	# Create and configure MultiMesh
	var multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh_resource
	
	# Calculate center of all points
	var center = Vector3.ZERO
	for pos in point_dict["P"]:
		center += pos
	center /= point_count
	
	# Set MultiMeshInstance3D transform to center
	multimesh_instance.transform.origin = center
	
	# Set instance count
	
	
	# Default values
	var default_normal = Vector3(0, 0, 1).normalized()
	var default_up = Vector3(0, 1, 0).normalized()
	var default_color = Color(1, 1, 1, 1)
	var default_pscale = 1.0
	var default_scale = Vector3(1, 1, 1)
	var use_color = false
	
	if point_dict["Cd"] and point_dict["Cd"][0] != null:
		use_color = true
		multimesh.use_colors = true
		
	multimesh.instance_count = point_count
	# Process each point
	for i in range(point_count):
		# Get position and offset by center
		var pos = point_dict["P"][i] - center
		
		# Get orientation vectors and normalize
		var normal = point_dict["N"][i].normalized() if point_dict["N"] and point_dict["N"][i] != null else default_normal
		var up = point_dict["up"][i].normalized() if point_dict["up"] and point_dict["up"][i] != null else default_up
		
		# Create basis from normal and up vectors
		var basis = Basis()
		var right = up.cross(normal).normalized()
		basis.x = right
		basis.y = up
		basis.z = normal
		
		# Apply scaling
		var scale = point_dict["scale"][i] if point_dict["scale"] and point_dict["scale"][i] != null else default_scale
		var pscale = point_dict["pscale"][i] if point_dict["pscale"] and point_dict["pscale"][i] != null else default_pscale
		basis = basis.scaled(scale * pscale)
		
		# Create transform
		var transform = Transform3D(basis, pos)
		multimesh.set_instance_transform(i, transform)
		
		# Set color
		if use_color:
			var color = point_dict["Cd"][i] if point_dict["Cd"] and point_dict["Cd"][i] != null else default_color
			if color is Vector3:
				color = Color(color.x, color.y, color.z, 1.0)
			multimesh.set_instance_color(i, color)
	
	multimesh_instance.multimesh = multimesh
			
			
func create_mesh_instance_3d(node_name_path, arr_mesh):
	# Split the path into parts
	node_name_path = "Outputs/" + node_name_path
	var parts = node_name_path.split("/")
	var current_node = self
	
	# Create intermediate Node3Ds
	for i in range(parts.size() - 1):
		var node_name = parts[i]
		var existing_node = current_node.get_node_or_null(node_name)
		
		if existing_node:
			current_node = existing_node
		else:
			var new_node = Node3D.new()
			new_node.name = node_name
			current_node.add_child(new_node)
			if Engine.is_editor_hint():
				new_node.owner = get_tree().edited_scene_root
			current_node = new_node
		
	# Create final MeshInstance3D
	var final_name = parts[parts.size() - 1]
	var mesh_instance = MeshInstance3D.new()
	mesh_instance.name = final_name
	current_node.add_child(mesh_instance)
	if Engine.is_editor_hint():
		mesh_instance.owner = get_tree().edited_scene_root
	mesh_instance.mesh = arr_mesh
	pass
		
		
func float_to_int_triplet_dict(float_array: Array, int_array: Array) -> Dictionary:
	var result: Dictionary = {}
	
	if int_array.size() != 3 * float_array.size():
		return result # Return empty dict if sizes don't match
	
	for i in range(float_array.size()):
		var float_value: float = float_array[i]
		var triplet: PackedInt32Array = [
			int_array[3 * i],
			int_array[3 * i + 1],
			int_array[3 * i + 2]
		]
		if result.has(float_value):
			result[float_value].append_array(triplet)
		else:
			result[float_value] = triplet
			
	return result


func array_to_index_dict(float_array: Array) -> Dictionary:
	var result: Dictionary = {}
	
	for i in range(float_array.size()):
		var value: float = float_array[i]
		if result.has(value):
			result[value].append(i)
		else:
			result[value] = [i]
			
	return result


func update_hego_input_node(hego_input_node, input_node_path, settings):
	var scene_root = get_tree().edited_scene_root
	var input = scene_root.get_node_or_null(input_node_path)
	var attrs = Array()
	attrs.append({
		name = "_hego_node_path",
		type = "prim",
		value = input_node_path
	})
	if input is Path3D:
		if not hego_input_node is HEGoCurveInputNode:
			hego_input_node = HEGoCurveInputNode.new()
		hego_input_node.instantiate()
		hego_input_node.set_curve_from_path_3d(input, 1)
	elif input is MeshInstance3D:
		if not hego_input_node is HEGoInputNode:
			hego_input_node = HEGoInputNode.new()
		attrs.append({
			name = "_hego_resource_path",
			type = "prim",
			value = input.mesh.resource_path
		})
		var override_mat_count = input.get_surface_override_material_count()
		for i in range(override_mat_count):
			var mat = input.get_surface_override_material(i)
			var attr_dict = {
				name = "_hego_surface_override_material_"+str(i),
				type = "prim"
			}
			if mat:
				attr_dict["value"] = mat.resource_path
			else:
				attr_dict["value"] = "empty"
			attrs.append(attr_dict)
		hego_input_node.instantiate()
		hego_input_node.set_geo_from_mesh(input.mesh, attrs)
		hego_input_node.set_transform(input.global_transform)
	elif input is CSGShape3D:
		if not hego_input_node is HEGoInputNode:
			hego_input_node = HEGoInputNode.new()
		hego_input_node.instantiate()
		hego_input_node.set_geo_from_mesh(input.bake_static_mesh(), attrs)
		hego_input_node.set_transform(input.global_transform)
	else:
		print("[HEGoNode3D]: Input is not Path3D, Meshinstance3D or CSGShape3D")
	return hego_input_node


func create_hego_input_node(input_node_path, settings):
	var scene_root = get_tree().edited_scene_root
	var input = scene_root.get_node_or_null(input_node_path)
	var attrs = Array()
	attrs.append({
		name = "_hego_node_path",
		type = "prim",
		value = input_node_path
	})
	var input_node
	if input is Path3D:
		input_node = HEGoCurveInputNode.new()
		input_node.instantiate()
		input_node.set_curve_from_path_3d(input, 1)
	elif input is MeshInstance3D:
		attrs.append({
			name = "_hego_resource_path",
			type = "prim",
			value = input.mesh.resource_path
		})
		var override_mat_count = input.get_surface_override_material_count()
		for i in range(override_mat_count):
			var mat = input.get_surface_override_material(i)
			var attr_dict = {
				name = "_hego_surface_override_material_"+str(i),
				type = "prim"
			}
			if mat:
				attr_dict["value"] = mat.resource_path
			else:
				attr_dict["value"] = "empty"
			attrs.append(attr_dict)
		input_node = HEGoInputNode.new()
		input_node.instantiate()
		input_node.set_geo_from_mesh(input.mesh, attrs)
		input_node.set_transform(input.global_transform)
	elif input is CSGShape3D:
		input_node = HEGoInputNode.new()
		input_node.instantiate()
		input_node.set_geo_from_mesh(input.bake_static_mesh(), attrs)
		input_node.set_transform(input.global_transform)
	else:
		print("[HEGoNode3D]: Input is not Path3D, Meshinstance3D or CSGShape3D")
	return input_node


func hego_use_bottom_panel():
	return true


func hego_get_asset_node():
	return hego_asset_node;
	

func hego_stash_parms(preset: PackedByteArray):
	parm_stash = preset


func hego_get_parm_stash(preset: PackedByteArray):
	return parm_stash


func hego_get_input_stash():
	return input_stash


func hego_set_input_stash(input_array: Array):
	# input_array is an array of inputs, as each Houdini input can combine
	# multiple inputs, each input is an array itself, storing node names and ids
	# Create new array to store actual node refs
	var result = Array()
	for input in input_array:
		var ref_array = Array()
		for ref in input["inputs"]:
			if ref != "":
				ref_array.append(ref)
		var input_dict = Dictionary()
		input_dict["inputs"] = ref_array
		input_dict["settings"] = input["settings"]
		result.append(input_dict)
	input_stash = result


func hego_get_asset_name():
	return asset_name


func repeat_indent(indent: int) -> String:
	var result := ""
	for i in range(indent):
		result += "    " # 4 spaces
	return result


func pretty_print(value, indent := 0) -> String:
	var indent_str = repeat_indent(indent)
	var next_indent_str = repeat_indent(indent + 1)

	if typeof(value) == TYPE_DICTIONARY:
		var result = "{\n"
		for key in value.keys():
			var key_str = pretty_print(key, indent + 1)
			var val_str = pretty_print(value[key], indent + 1)
			result += "%s%s: %s,\n" % [next_indent_str, key_str, val_str]
		result += indent_str + "}"
		return result

	elif typeof(value) == TYPE_ARRAY:
		var result = "[\n"
		for item in value:
			result += "%s%s,\n" % [next_indent_str, pretty_print(item, indent + 1)]
		result += indent_str + "]"
		return result

	elif typeof(value) == TYPE_STRING:
		return "\"%s\"" % value

	else:
		return str(value)


func _show_select_hda_dialog():
	if Engine.is_editor_hint():
		var viewport = EditorInterface.get_editor_viewport_3d()
		var picker_scene = preload("res://addons/hego/ui/asset_picker_dialog.tscn")
		var picker = picker_scene.instantiate()
		
		# Add to the scene tree temporarily
		viewport.add_child(picker)
		
		# Connect the signal to handle the selection
		picker.asset_selected.connect(_on_asset_selected)
		
		# Show the dialog
		picker._populate_tree()
		picker.popup_centered()


func _on_asset_selected(selected_asset: String):
	# Clear old HDA data when selecting a new asset
	_clear_hda_data()
	
	asset_name = selected_asset
	notify_property_list_changed()
	print("[HEGoNode3D]: Selected asset: ", selected_asset)

func _clear_hda_data():
	# Reset the asset node's internal HAPI node ID to force re-instantiation
	if hego_asset_node:
		hego_asset_node.reset_node_id()
	
	# Clear parameter stash so we start fresh
	parm_stash = PackedByteArray()
	
	# Clear input references
	input_stash.clear()
	hego_input_nodes.clear()
	
	# Clear any existing output nodes
	var outputs_node = get_node_or_null("Outputs")
	if outputs_node:
		outputs_node.queue_free()
	
	print("[HEGoNode3D]: Cleared old HDA data and reset node ID")


func _t3d_get_layer_by_name(layers: Array, layer_name: String) -> Dictionary:
	for layer in layers:
		if layer is Dictionary and layer.get("layer_name", "") == layer_name:
			return layer
	return {}


func _t3d_get_attr_value(layer: Dictionary, attr_name: String):
	if not layer.has("attrs") or not layer["attrs"] is Array:
		return null
	for attr_pair in layer["attrs"]:
		if attr_pair is Dictionary and attr_pair.get("name", "") == attr_name:
			return attr_pair.get("value", null)
	return null


func _t3d_is_valid_region_size(value) -> bool:
	if value == null:
		return false
	if not value is int and not value is float:
		return false
	var size = int(value)
	if size < 64 or size > 2048:
		return false
	return size > 0 and (size & (size - 1)) == 0


func _t3d_approx_equal_vec3(a: Vector3, b: Vector3, tolerance: float) -> bool:
	return abs(a.x - b.x) <= tolerance and abs(a.y - b.y) <= tolerance and abs(a.z - b.z) <= tolerance


func _t3d_collect_texture_layers(layers: Array) -> Array:
	var texture_layers: Array = []
	for layer in layers:
		if not layer is Dictionary:
			continue
		var layer_name = str(layer.get("layer_name", ""))
		if not layer_name.begins_with("hegot3d_texture_layer_"):
			continue
		var slot = _t3d_parse_texture_layer_index(layer_name)
		if slot < 0 or slot > 31:
			push_warning("[HEGoNode3D]: Ignoring invalid Terrain3D texture layer name %s." % layer_name)
			continue
		texture_layers.append({
			"slot": slot,
			"layer": layer,
			"layer_name": layer_name,
			"part_id": int(layer.get("part_id", -1))
		})
	texture_layers.sort_custom(func(a, b): return int(a["slot"]) < int(b["slot"]))
	return texture_layers


func _t3d_parse_texture_layer_index(layer_name: String) -> int:
	var suffix = layer_name.trim_prefix("hegot3d_texture_layer_")
	if suffix.is_empty() or not suffix.is_valid_int():
		return -1
	return int(suffix)


func _t3d_validate_texture_layers(texture_layers: Array) -> Dictionary:
	var validated_layers: Array = []
	var albedo_reference = {}
	var normal_reference = {}
	var optional_attr_map = {
		"hegot3d_ao_strength": "ao_strength",
		"hegot3d_detiling_rotation": "detiling_rotation",
		"hegot3d_detiling_shift": "detiling_shift",
		"hegot3d_id": "id",
		"hegot3d_name": "name",
		"hegot3d_normal_depth": "normal_depth",
		"hegot3d_roughness": "roughness",
		"hegot3d_uv_scale": "uv_scale"
	}

	for texture_layer in texture_layers:
		var layer = texture_layer["layer"]
		var slot = int(texture_layer["slot"])
		var layer_name = str(texture_layer["layer_name"])
		var part_id = int(texture_layer["part_id"])
		if part_id < 0:
			return {
				"ok": false,
				"warning": "[HEGoNode3D]: Terrain3D texture layer %s has invalid part_id, skipping Terrain3D control maps." % layer_name
			}

		var albedo_path = _t3d_get_attr_string(layer, "hegot3d_albedo_texture")
		if albedo_path.is_empty():
			return {
				"ok": false,
				"warning": "[HEGoNode3D]: Terrain3D texture layer %s is missing hegot3d_albedo_texture, skipping Terrain3D control maps." % layer_name
			}

		var normal_path = _t3d_get_attr_string(layer, "hegot3d_normal_texture")
		if normal_path.is_empty():
			return {
				"ok": false,
				"warning": "[HEGoNode3D]: Terrain3D texture layer %s is missing hegot3d_normal_texture, skipping Terrain3D control maps." % layer_name
			}

		var albedo_texture = _t3d_load_texture_resource(albedo_path)
		if albedo_texture == null:
			return {
				"ok": false,
				"warning": "[HEGoNode3D]: Failed to load Terrain3D albedo texture %s for layer %s, skipping Terrain3D control maps." % [albedo_path, layer_name]
			}

		var normal_texture = _t3d_load_texture_resource(normal_path)
		if normal_texture == null:
			return {
				"ok": false,
				"warning": "[HEGoNode3D]: Failed to load Terrain3D normal texture %s for layer %s, skipping Terrain3D control maps." % [normal_path, layer_name]
			}

		var albedo_image = _t3d_get_texture_image(albedo_texture)
		if albedo_image == null:
			return {
				"ok": false,
				"warning": "[HEGoNode3D]: Failed to inspect Terrain3D albedo texture %s for layer %s, skipping Terrain3D control maps." % [albedo_path, layer_name]
			}

		var normal_image = _t3d_get_texture_image(normal_texture)
		if normal_image == null:
			return {
				"ok": false,
				"warning": "[HEGoNode3D]: Failed to inspect Terrain3D normal texture %s for layer %s, skipping Terrain3D control maps." % [normal_path, layer_name]
			}

		var albedo_info = _t3d_get_image_signature(albedo_image)
		if albedo_reference.is_empty():
			albedo_reference = albedo_info
		elif not _t3d_image_signature_matches(albedo_reference, albedo_info):
			return {
				"ok": false,
				"warning": "[HEGoNode3D]: All Terrain3D albedo textures must share the same resolution and format, skipping Terrain3D control maps."
			}

		var normal_info = _t3d_get_image_signature(normal_image)
		if normal_reference.is_empty():
			normal_reference = normal_info
		elif not _t3d_image_signature_matches(normal_reference, normal_info):
			return {
				"ok": false,
				"warning": "[HEGoNode3D]: All Terrain3D normal textures must share the same resolution and format, skipping Terrain3D control maps."
			}

		var optional_properties = {}
		for attr_name in optional_attr_map.keys():
			var attr_value = _t3d_get_attr_value(layer, attr_name)
			if attr_value != null:
				optional_properties[optional_attr_map[attr_name]] = attr_value

		validated_layers.append({
			"slot": slot,
			"layer_name": layer_name,
			"part_id": part_id,
			"albedo_texture": albedo_texture,
			"normal_texture": normal_texture,
			"optional_properties": optional_properties,
			"weight_image": null
		})

	validated_layers.sort_custom(func(a, b): return int(a["slot"]) < int(b["slot"]))
	return {
		"ok": true,
		"layers": validated_layers,
		"lowest_slot": int(validated_layers[0]["slot"]) if not validated_layers.is_empty() else -1
	}


func _t3d_get_attr_string(layer: Dictionary, attr_name: String) -> String:
	var value = _t3d_get_attr_value(layer, attr_name)
	if value == null:
		return ""
	if value is String:
		return value.strip_edges()
	return str(value).strip_edges()


func _t3d_load_texture_resource(resource_path: String) -> Texture2D:
	if resource_path.is_empty():
		return null
	if not ResourceLoader.exists(resource_path):
		return null
	var resource = load(resource_path)
	if resource is Texture2D:
		return resource
	return null


func _t3d_get_texture_image(texture: Texture2D) -> Image:
	if texture == null or not texture.has_method("get_image"):
		return null
	return texture.get_image()


func _t3d_get_image_signature(image: Image) -> Dictionary:
	return {
		"width": image.get_width(),
		"height": image.get_height(),
		"format": image.get_format()
	}


func _t3d_image_signature_matches(a: Dictionary, b: Dictionary) -> bool:
	return int(a.get("width", -1)) == int(b.get("width", -2)) and int(a.get("height", -1)) == int(b.get("height", -2)) and int(a.get("format", -1)) == int(b.get("format", -2))


func _t3d_set_optional_property(obj: Object, property_name: String, value) -> void:
	for property_info in obj.get_property_list():
		if str(property_info.get("name", "")) == property_name:
			obj.set(property_name, value)
			return


func _t3d_build_control_bits_for_pixel(texture_layers: Array, terrain3d_util: Object, pixel_x: int, pixel_z: int, lowest_valid_texture_slot: int, hole_image: Image):
	var best_slot = lowest_valid_texture_slot
	var second_slot = lowest_valid_texture_slot
	var best_weight = 0.0
	var second_weight = 0.0

	for texture_layer in texture_layers:
		var weight_image = texture_layer.get("weight_image", null)
		if weight_image == null:
			continue
		if pixel_x < 0 or pixel_z < 0 or pixel_x >= weight_image.get_width() or pixel_z >= weight_image.get_height():
			continue
		var layer_weight = clampf(weight_image.get_pixel(pixel_x, pixel_z).r, 0.0, 1.0)
		if layer_weight > best_weight:
			second_weight = best_weight
			second_slot = best_slot
			best_weight = layer_weight
			best_slot = int(texture_layer["slot"])
		elif layer_weight > second_weight:
			second_weight = layer_weight
			second_slot = int(texture_layer["slot"])

	var base_slot = lowest_valid_texture_slot
	var overlay_slot = lowest_valid_texture_slot
	var normalized_overlay_weight = 0.0

	if best_weight <= 0.0:
		base_slot = lowest_valid_texture_slot
		overlay_slot = lowest_valid_texture_slot
		normalized_overlay_weight = 0.0
	elif second_weight <= 0.0:
		base_slot = best_slot
		overlay_slot = best_slot
		normalized_overlay_weight = 0.0
	else:
		var combined_weight = best_weight + second_weight
		if best_slot <= second_slot:
			base_slot = best_slot
			overlay_slot = second_slot
			if combined_weight > 0.0:
				normalized_overlay_weight = second_weight / combined_weight
		else:
			base_slot = second_slot
			overlay_slot = best_slot
			if combined_weight > 0.0:
				normalized_overlay_weight = best_weight / combined_weight

	var blend_value = clampi(int(round(normalized_overlay_weight * 255.0)), 0, 255)
	var is_hole = false
	if hole_image != null and pixel_x >= 0 and pixel_z >= 0 and pixel_x < hole_image.get_width() and pixel_z < hole_image.get_height():
		is_hole = hole_image.get_pixel(pixel_x, pixel_z).r >= 0.5

	return _t3d_encode_control_bits(terrain3d_util, base_slot, overlay_slot, blend_value, is_hole)


func _t3d_encode_control_bits(terrain3d_util: Object, base_slot: int, overlay_slot: int, blend_value: int, is_hole: bool) -> int:
	var bits = int(terrain3d_util.call("enc_base", base_slot))
	bits |= int(terrain3d_util.call("enc_overlay", overlay_slot))
	bits |= terrain3d_util.call("enc_blend", blend_value)
	bits |= int(terrain3d_util.call("enc_uv_rotation", 0))
	bits |= int(terrain3d_util.call("enc_uv_scale", 0))
	bits |= int(terrain3d_util.call("enc_auto", false))
	bits |= int(terrain3d_util.call("enc_nav", false))
	bits |= int(terrain3d_util.call("enc_hole", is_hole))
	return bits


func _t3d_fix_heightfield_image_transform(image: Image) -> Image:
	if image == null:
		return null
	
	var orig_width = image.get_width()
	var orig_height = image.get_height()
	var orig_format = image.get_format()
	
	var corrected = Image.create(orig_height, orig_width, false, orig_format)
	
	for orig_y in range(orig_height):
		for orig_x in range(orig_width):
			var pixel = image.get_pixel(orig_x, orig_y)
			var new_x = orig_height - 1 - orig_y
			var new_y = orig_x
			corrected.set_pixel(new_x, new_y, pixel)

	# Terrain import still ends up mirrored along world X after rotation, so unflip it.
	corrected.flip_x()
	
	return corrected


func _t3d_find_node_from_path(node_path_text: String) -> Node:
	if node_path_text.is_empty():
		return null

	var direct_node = get_node_or_null(node_path_text)
	if direct_node != null:
		return direct_node

	var scene_root = get_tree().edited_scene_root
	if scene_root != null:
		return scene_root.get_node_or_null(node_path_text)

	return null


func _t3d_get_terrain_assets(terrain: Node):
	if terrain == null:
		return null

	if terrain.has_method("get_assets"):
		var assets = terrain.call("get_assets")
		if assets != null:
			return assets

	return terrain.get("assets")


func _t3d_clear_generated_mesh_slots(assets, instancer) -> Array:
	var removed_slots: Array = []
	if assets == null or not assets.has_method("get_mesh_count"):
		return removed_slots

	var mesh_count = int(assets.call("get_mesh_count"))
	for slot in range(mesh_count):
		var mesh_asset = assets.call("get_mesh_asset", slot)
		if mesh_asset == null:
			continue

		var mesh_name = _t3d_get_mesh_asset_name(mesh_asset)
		if not mesh_name.begins_with("hegot3d_"):
			continue

		if instancer != null and instancer.has_method("clear_by_mesh"):
			instancer.call("clear_by_mesh", slot)
		assets.call("set_mesh_asset", slot, null)
		removed_slots.append(slot)

	return removed_slots


func _t3d_find_mesh_slot_by_scene_path(assets, scene_path: String) -> int:
	if assets == null or scene_path.is_empty() or not assets.has_method("get_mesh_count"):
		return -1

	var mesh_count = int(assets.call("get_mesh_count"))
	for slot in range(mesh_count):
		var mesh_asset = assets.call("get_mesh_asset", slot)
		if mesh_asset == null:
			continue

		# Only reuse procedural slots owned by HEGo to avoid touching hand-authored mesh assets.
		var mesh_name = _t3d_get_mesh_asset_name(mesh_asset)
		if not mesh_name.begins_with("hegot3d_"):
			continue

		var mesh_scene_path = _t3d_get_mesh_asset_scene_path(mesh_asset)
		if mesh_scene_path == scene_path:
			return slot

	return -1


func _t3d_assign_generated_mesh_slot(assets, scene_path: String) -> int:
	if assets == null or scene_path.is_empty() or not assets.has_method("get_mesh_count"):
		return -1

	if not ResourceLoader.exists(scene_path):
		push_warning("[HEGoNode3D]: Terrain3D scene resource does not exist: %s" % scene_path)
		return -1

	var scene_res = load(scene_path)
	if not scene_res is PackedScene:
		push_warning("[HEGoNode3D]: Terrain3D mesh asset expects PackedScene at %s." % scene_path)
		return -1

	var mesh_asset = Terrain3DMeshAsset.new()
	mesh_asset.call("set_scene_file", scene_res)
	if mesh_asset.has_method("set_name"):
		var generated_name = "hegot3d_" + scene_path.get_file().get_basename()
		mesh_asset.call("set_name", generated_name)

	var mesh_count = int(assets.call("get_mesh_count"))
	for slot in range(mesh_count):
		if assets.call("get_mesh_asset", slot) == null:
			assets.call("set_mesh_asset", slot, mesh_asset)
			return slot

	if ClassDB.class_exists("Terrain3DAssets") and mesh_count >= int(Terrain3DAssets.MAX_MESHES):
		push_warning("[HEGoNode3D]: Terrain3D mesh asset limit reached, cannot assign %s." % scene_path)
		return -1

	assets.call("set_mesh_asset", mesh_count, mesh_asset)
	return mesh_count


func _t3d_apply_mesh_asset_instancer_settings(mesh_asset, point_dict: Dictionary) -> void:
	var attr_map = {
		"hegot3d_lod0_range": "lod0_range",
		"hegot3d_lod1_range": "lod1_range",
		"hegot3d_lod2_range": "lod2_range",
		"hegot3d_lod3_range": "lod3_range",
		"hegot3d_lod4_range": "lod4_range",
		"hegot3d_lod5_range": "lod5_range",
		"hegot3d_lod6_range": "lod6_range",
		"hegot3d_lod7_range": "lod7_range",
		"hegot3d_lod8_range": "lod8_range",
		"hegot3d_lod9_range": "lod9_range",
		"hegot3d_shadow_impostor": "shadow_impostor",
		"hegot3d_last_lod": "last_lod",
		"hegot3d_last_shadow_lod": "last_shadow_lod",
		"hegot3d_fade_margin": "fade_margin",
	}
	for hego_attr in attr_map.keys():
		if not point_dict.has(hego_attr):
			continue
		var arr = point_dict[hego_attr]
		if not arr is Array or arr.is_empty() or arr[0] == null:
			continue
		_t3d_set_optional_property(mesh_asset, attr_map[hego_attr], arr[0])


func _t3d_get_mesh_asset_scene_path(mesh_asset) -> String:
	if mesh_asset == null:
		return ""

	if mesh_asset.has_method("get_scene_file"):
		var scene_res = mesh_asset.call("get_scene_file")
		if scene_res is Resource and not scene_res.resource_path.is_empty():
			return scene_res.resource_path

	var scene_prop = mesh_asset.get("scene_file")
	if scene_prop is Resource and not scene_prop.resource_path.is_empty():
		return scene_prop.resource_path

	return ""


func _t3d_get_mesh_asset_name(mesh_asset) -> String:
	if mesh_asset == null:
		return ""

	if mesh_asset.has_method("get_name"):
		return str(mesh_asset.call("get_name"))

	return str(mesh_asset.get("name"))
