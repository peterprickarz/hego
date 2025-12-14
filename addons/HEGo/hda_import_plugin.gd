
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
	return "HDAResource"
	

func _get_preset_count():
	return 1

func _get_preset_name(preset_index):
	return "Default"

func _get_import_options(path, preset_index):
	return [{"name": "my_option", "default_value": false}]
	
func _get_priority():
	return 1.0

func _get_import_order():
	return 0
	
func _get_option_visibility(path, option_name, options):
	return true
	
func _import(source_file: String, save_path: String, options: Dictionary, platform_variants: Array, gen_files: Array) -> int:
	print("Importing:", source_file)
	
	var resource = HDAResource.new()
	resource.source_file = source_file
	
	var save_file_path = "%s.%s" % [save_path, _get_save_extension()]
	var err = ResourceSaver.save(resource, save_file_path)
	
	if err != OK:
		print("Error saving resource:", err)
		return err
	
	print("Successfully imported:", source_file)
	return OK
