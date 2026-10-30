@tool
class_name StrataStorage
extends RefCounted
## Fixed-path files for a terrain's data, so every layer and the bake live in one known place
## and a cook overwrites them instead of adding new files.
##
## With [member StrataTerrain3D.storage_directory] set to a project directory, the layout is:
## [codeblock]
## <directory>/<layer>.res             a manual layer's samples (StrataLayerData)
## <directory>/<layer>/<channel>.res   one cooked channel of a procedural layer (StrataFieldData)
## <directory>/runtime_data.res        the published bake (StrataRuntimeData)
## <directory>/material_ids.res        the terrain's editor control maps (Image), when it has any
## <directory>/material_weights.res
## [/codeblock]
## Layer names become snake_case file names. A procedural commit saves its fields here on its
## own (see [method StrataProcedural.commit_fields]); manual layers are saved with
## [method save_layers], which the terrain exposes as an inspector button. Every write goes
## to a temporary file first and is renamed into place, so a failed save leaves the previous
## file intact. The scene then references these files by path, and a file that changes on
## disk is a visible, reviewable diff.

const RUNTIME_DATA_FILE := "runtime_data.res"
const CONTROL_IDS_FILE := "material_ids.res"
const CONTROL_WEIGHTS_FILE := "material_weights.res"
const TEMPORARY_SUFFIX := "~.res"


static func has_storage(terrain: StrataTerrain3D) -> bool:
	return is_instance_valid(terrain) and not terrain.storage_directory.strip_edges().is_empty()


## The terrain's storage directory without a trailing slash, or "" when it has none.
static func directory(terrain: StrataTerrain3D) -> String:
	if not has_storage(terrain):
		return ""
	return terrain.storage_directory.strip_edges().rstrip("/")


static func layer_file_name(layer: StrataLayer) -> String:
	return String(layer.name).to_snake_case()


static func layer_data_path(terrain: StrataTerrain3D, layer: StrataLayer) -> String:
	return directory(terrain).path_join(layer_file_name(layer) + ".res")


static func layer_directory(terrain: StrataTerrain3D, layer: StrataLayer) -> String:
	return directory(terrain).path_join(layer_file_name(layer))


static func field_path(terrain: StrataTerrain3D, layer: StrataLayer, channel: String) -> String:
	return layer_directory(terrain, layer).path_join(channel + ".res")


static func runtime_data_path(terrain: StrataTerrain3D) -> String:
	return directory(terrain).path_join(RUNTIME_DATA_FILE)


static func control_ids_path(terrain: StrataTerrain3D) -> String:
	return directory(terrain).path_join(CONTROL_IDS_FILE)


static func control_weights_path(terrain: StrataTerrain3D) -> String:
	return directory(terrain).path_join(CONTROL_WEIGHTS_FILE)


## Saves every layer and the published bake, if any. Returns [code]{ok, message, saved}[/code],
## where [code]saved[/code] lists the files written.
static func save_all(terrain: StrataTerrain3D) -> Dictionary:
	var layers := save_layers(terrain)
	if not layers.ok:
		return layers
	if terrain.runtime_data != null:
		var bake := save_runtime_data(terrain)
		if not bake.ok:
			return bake
		layers.saved.append_array(bake.saved)
	if terrain.editor_control_ids != null and terrain.editor_control_weights != null:
		var controls := save_control_maps(terrain)
		if not controls.ok:
			return controls
		layers.saved.append_array(controls.saved)
	layers.message = "Saved %d terrain files to %s" % [layers.saved.size(), directory(terrain)]
	return layers


## Saves each layer: manual layers by their samples, procedural layers by their fields.
static func save_layers(terrain: StrataTerrain3D) -> Dictionary:
	if not has_storage(terrain):
		return _error("This terrain has no storage directory")
	var saved: Array = []
	for layer in terrain.get_layers():
		var result := save_procedural_fields(terrain, layer) if layer.procedural else save_layer_data(terrain, layer)
		if not result.ok:
			return result
		saved.append_array(result.saved)
	_mark_scene_unsaved(terrain)
	return {"ok": true, "message": "Saved %d layer files" % saved.size(), "saved": saved}


## A manual layer's samples to [code]<directory>/<layer>.res[/code]. An empty layer whose
## file does not exist yet is skipped; an existing file is kept current even when empty.
static func save_layer_data(terrain: StrataTerrain3D, layer: StrataLayer) -> Dictionary:
	if not has_storage(terrain):
		return _error("This terrain has no storage directory")
	var path := layer_data_path(terrain, layer)
	if layer.data.get_channel_names().is_empty() and not FileAccess.file_exists(path):
		return {"ok": true, "message": "Empty layer %s has nothing to save" % layer.name, "saved": []}
	var made := _ensure_directory(directory(terrain))
	if not made.ok:
		return made
	return _save_resources([{"resource": layer.data, "path": path}])


## A procedural layer's cooked channels to [code]<directory>/<layer>/<channel>.res[/code], all
## or nothing, with files of channels the result no longer has removed afterwards.
static func save_procedural_fields(terrain: StrataTerrain3D, layer: StrataLayer) -> Dictionary:
	if not has_storage(terrain):
		return _error("This terrain has no storage directory")
	var folder := layer_directory(terrain, layer)
	var made := _ensure_directory(folder)
	if not made.ok:
		return made
	var entries: Array = []
	for channel in layer.procedural_fields:
		var name := String(channel)
		if not name.is_valid_filename() or name.begins_with("."):
			return _error("Channel %s cannot be a file name" % name)
		entries.append({"resource": layer.procedural_fields[channel], "path": field_path(terrain, layer, name)})
	var result := _save_resources(entries)
	if not result.ok:
		return result
	# Only this layer's own channel files live here, so anything else is a stale channel.
	var keep := {}
	for entry in entries:
		keep[String(entry.path).get_file()] = true
	for file in DirAccess.get_files_at(folder):
		if file.get_extension() == "res" and not keep.has(file):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(folder.path_join(file)))
			result.saved.append("removed " + folder.path_join(file))
	return result


static func save_runtime_data(terrain: StrataTerrain3D) -> Dictionary:
	if not has_storage(terrain):
		return _error("This terrain has no storage directory")
	if terrain.runtime_data == null:
		return _error("This terrain has no published bake to save")
	var made := _ensure_directory(directory(terrain))
	if not made.ok:
		return made
	return _save_resources([{"resource": terrain.runtime_data, "path": runtime_data_path(terrain)}])


## The terrain's editor control maps (material IDs and weights) to their two files.
static func save_control_maps(terrain: StrataTerrain3D) -> Dictionary:
	if not has_storage(terrain):
		return _error("This terrain has no storage directory")
	if terrain.editor_control_ids == null or terrain.editor_control_weights == null:
		return _error("This terrain has no control maps to save")
	var made := _ensure_directory(directory(terrain))
	if not made.ok:
		return made
	return _save_resources([
		{"resource": terrain.editor_control_ids, "path": control_ids_path(terrain)},
		{"resource": terrain.editor_control_weights, "path": control_weights_path(terrain)},
	])


## The control maps saved for this terrain as [code]{ids, weights}[/code], or empty when
## either file is missing.
static func load_control_maps(terrain: StrataTerrain3D) -> Dictionary:
	if not has_storage(terrain) or not FileAccess.file_exists(control_ids_path(terrain)) or not FileAccess.file_exists(control_weights_path(terrain)):
		return {}
	var ids := ResourceLoader.load(control_ids_path(terrain), "Image", ResourceLoader.CACHE_MODE_IGNORE) as Image
	var weights := ResourceLoader.load(control_weights_path(terrain), "Image", ResourceLoader.CACHE_MODE_IGNORE) as Image
	if ids == null or weights == null:
		return {}
	return {"ids": ids, "weights": weights}


## Fills every layer the scene saved nothing for from its storage files: a hand layer's
## samples, or a procedural layer's channels. Layers that already hold data are left alone,
## so the scene's own references win when they exist. Returns the layers filled.
static func load_layers(terrain: StrataTerrain3D) -> PackedStringArray:
	var filled := PackedStringArray()
	if not has_storage(terrain):
		return filled
	for layer in terrain.get_layers():
		if layer.procedural:
			if not layer.procedural_fields.is_empty():
				continue
			var folder := layer_directory(terrain, layer)
			if not DirAccess.dir_exists_absolute(folder):
				continue
			var fields := {}
			for file in DirAccess.get_files_at(folder):
				if file.get_extension() != "res" or file.ends_with(TEMPORARY_SUFFIX):
					continue
				var field := ResourceLoader.load(folder.path_join(file), "", ResourceLoader.CACHE_MODE_IGNORE) as StrataFieldData
				if field == null or String(field.channel) != file.get_basename():
					push_error("Strata: %s is not the saved channel %s; ignoring the whole layer" % [folder.path_join(file), file.get_basename()])
					fields.clear()
					break
				fields[String(field.channel)] = field
			if fields.is_empty():
				continue
			layer.procedural_fields = fields
			layer.procedural_stale = true
			layer.procedural_status = "Saved result loaded from storage; explicit recook to refresh"
			filled.append(String(layer.name))
		else:
			if not layer.data.get_channel_names().is_empty():
				continue
			var path := layer_data_path(terrain, layer)
			if not FileAccess.file_exists(path):
				continue
			var data := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as StrataLayerData
			if data == null:
				continue
			layer.data = data
			filled.append(String(layer.name))
	return filled


## The bake saved for this terrain, or null when there is none on disk.
static func load_runtime_data(terrain: StrataTerrain3D) -> StrataRuntimeData:
	if not has_storage(terrain):
		return null
	var path := runtime_data_path(terrain)
	if not FileAccess.file_exists(path):
		return null
	# A script class is not a loader type hint, so the cast does the type check.
	return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as StrataRuntimeData


# ─────────────────────────────────────────────

## Writes every resource to a temporary file, then renames them all into place and gives each
## resource its final path. On any failure the temporaries are removed and the files already
## at those paths are untouched.
static func _save_resources(entries: Array) -> Dictionary:
	var temporaries := PackedStringArray()
	for entry in entries:
		var path := String(entry.path)
		var temporary := path.get_basename() + TEMPORARY_SUFFIX
		var error := ResourceSaver.save(entry.resource, temporary, ResourceSaver.FLAG_COMPRESS)
		if error != OK:
			_remove_all(temporaries)
			return _error("Could not write %s (%s); previous file kept" % [path, error_string(error)])
		temporaries.append(temporary)
	var saved: Array = []
	for index in range(entries.size()):
		var path := String(entries[index].path)
		var error := DirAccess.rename_absolute(ProjectSettings.globalize_path(temporaries[index]), ProjectSettings.globalize_path(path))
		if error != OK:
			_remove_all(temporaries.slice(index))
			return _error("Could not replace %s (%s); %d files before it were already replaced" % [path, error_string(error), index])
		(entries[index].resource as Resource).take_over_path(path)
		saved.append(path)
	return {"ok": true, "message": "Saved %d files" % saved.size(), "saved": saved}


static func _remove_all(paths: PackedStringArray) -> void:
	for path in paths:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


static func _ensure_directory(path: String) -> Dictionary:
	if not path.begins_with("res://") and not path.begins_with("user://"):
		return _error("Storage directory must be a res:// or user:// path, not %s" % path)
	var error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path))
	if error != OK:
		return _error("Could not create %s (%s)" % [path, error_string(error)])
	return {"ok": true}


static func _mark_scene_unsaved(terrain: StrataTerrain3D) -> void:
	# The files hold the data, but the scene holds the paths, so it needs saving too.
	if Engine.is_editor_hint() and terrain.is_inside_tree() and terrain.get_tree().edited_scene_root != null:
		var editor := Engine.get_singleton("EditorInterface")
		if editor != null:
			editor.call("mark_scene_as_unsaved")


static func _error(message: String) -> Dictionary:
	return {"ok": false, "message": message, "saved": []}
