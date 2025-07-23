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


func cook():
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
		
	# SET INPUTS
	# Retrieve a string array containing the names of inputs
	var input_names = hego_asset_node.get_input_names()
	# Loop over inputs
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
		if hego_input_nodes.has(i):
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
	parm_stash = hego_asset_node.get_preset()
	# FETCH OUTPUTS
	
	handle_mesh_output()
	handle_multimesh_output()
	handle_object_spawn_output()


func handle_mesh_output():
	# use config to fetch output mesh
	var fetch_surfaces_default_config = load("res://addons/hego/surface_filters/fetch_surfaces_default.tres")
	# retrieve dictionary output, containing the mesh in godots surface_array format
	var dict = hego_asset_node.fetch_surfaces(fetch_surfaces_default_config)
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
	var output_dictionary = hego_asset_node.fetch_points(fetch_points_config)
	
	# Validate output dictionary
	if not output_dictionary or not output_dictionary.has("P") or not output_dictionary.P is Array:
		push_error("[HEGoNode3D]: Invalid output dictionary or missing P attribute")
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
	var output_dictionary = hego_asset_node.fetch_points(fetch_points_config)
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
	multimesh.instance_count = point_count
	
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
	if input is Path3D:
		if not hego_input_node is HEGoCurveInputNode:
			hego_input_node = HEGoCurveInputNode.new()
		hego_input_node.instantiate()
		hego_input_node.set_curve_from_path_3d(input, 1)
	elif input is MeshInstance3D:
		if not hego_input_node is HEGoInputNode:
			hego_input_node = HEGoInputNode.new()
		hego_input_node.instantiate()
		hego_input_node.set_geo_from_mesh_instance_3d(input)
	else:
		print("[HEGoNode3D]: Input is neither Path3D nor MeshInstance3D")
	return hego_input_node


func create_hego_input_node(input_node_path, settings):
	var scene_root = get_tree().edited_scene_root
	var input = scene_root.get_node_or_null(input_node_path)
	var input_node
	if input is Path3D:
		input_node = HEGoCurveInputNode.new()
		input_node.instantiate()
		input_node.set_curve_from_path_3d(input, 1)
	elif input is MeshInstance3D:
		input_node = HEGoInputNode.new()
		input_node.instantiate()
		input_node.set_geo_from_mesh_instance_3d(input)
	else:
		print("[HEGoNode3D]: Input is neither Path3D nor MeshInstance3D")
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
	print("stash inputs")
	print(input_array)
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
