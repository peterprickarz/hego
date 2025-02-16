"""

@tool
extends EditorImportPlugin

enum Presets { DEFAULT }

func _get_importer_name():
	return "hego.hda"
	
func _get_visible_name():
	return "HDA"
	
func _get_recognized_extensions():
	return ["hda"]
	
func _get_save_extension():
	return "tres"
	
func _get_resource_type():
	return "Mesh"
	

func _get_preset_count():
	return 1

func _get_preset_name(preset_index):
	return "Default"

func _get_import_options(path, preset_index):
	return [{"name": "my_option", "default_value": false}]

	
func _import(source_file: String, save_path: String, options: Dictionary, platform_variants: Array, gen_files: Array) -> int:
	var resource = Resource.new()
	return ResourceSaver.save(resource, save_path + _get_save_extension())
"""

@tool
extends EditorImportPlugin

func _get_importer_name():
	return "my.special.plugin"

func _get_visible_name():
	return "Special Mesh"

func _get_recognized_extensions():
	return ["special", "spec"]

func _get_save_extension():
	return "mesh"

func _get_resource_type():
	return "Mesh"

func _get_preset_count():
	return 1

func _get_preset_name(preset_index):
	return "Default"

func _get_import_options(path, preset_index):
	return [{"name": "my_option", "default_value": false}]

func _import(source_file, save_path, options, platform_variants, gen_files):
	var file = FileAccess.open(source_file, FileAccess.READ)
	if file == null:
		return FAILED
	var mesh = ArrayMesh.new()
	# Fill the Mesh with data read in "file", left as an exercise to the reader.

	var filename = save_path + "." + _get_save_extension()
	return ResourceSaver.save(mesh, filename)
