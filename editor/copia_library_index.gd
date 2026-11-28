@tool
extends RefCounted
## Discovers Copia authoring resources in the project without eagerly loading every mesh:
## - [CopiaObject] and any subclass (e.g. game-specific subclasses like KellCopiaObject)
## - [CopiaSpecies]
## - [CopiaBrushPalette]
## - [CopiaRenderSettings], [CopiaPhysicsSettings], [CopiaPlacementSettings]
##
## Uses lightweight `.tres` header inspection for fast scanning even in projects with 800+ objects.

const OBJECT_SCRIPT := "res://addons/copia/copia_object.gd"
const SPECIES_SCRIPT := "res://addons/copia/copia_species.gd"
const PALETTE_SCRIPT := "res://addons/copia/copia_brush_palette.gd"
const RENDER_SCRIPT := "res://addons/copia/copia_render_settings.gd"
const PHYSICS_SCRIPT := "res://addons/copia/copia_physics_settings.gd"
const PLACEMENT_SCRIPT := "res://addons/copia/copia_placement_settings.gd"

const SETTING_OBJECT_SCRIPT := "copia/editor/default_object_script"
const SETTING_OBJECT_DIR := "copia/editor/default_object_directory"
const SETTING_SPECIES_DIR := "copia/editor/default_species_directory"
const SETTING_PALETTE_DIR := "copia/editor/default_palette_directory"

var objects: Array[Dictionary] = []  # {path, name, category, folder}
var species: Array[Dictionary] = []  # {path, name, category, folder}
var palettes: Array[Dictionary] = []  # {path, name, folder}
var render_settings: PackedStringArray = PackedStringArray()
var physics_settings: PackedStringArray = PackedStringArray()
var placement_settings: PackedStringArray = PackedStringArray()

var _object_scripts := {}  # script_path -> bool (extends CopiaObject)
var _script_kind_cache := {}  # script_path -> "object" | "species" | "palette" | "render" | "physics" | "placement" | ""


static func register_project_settings() -> void:
	_define_setting(SETTING_OBJECT_SCRIPT, OBJECT_SCRIPT, PROPERTY_HINT_FILE, "*.gd")
	_define_setting(SETTING_OBJECT_DIR, "res://", PROPERTY_HINT_DIR, "")
	_define_setting(SETTING_SPECIES_DIR, "res://", PROPERTY_HINT_DIR, "")
	_define_setting(SETTING_PALETTE_DIR, "res://", PROPERTY_HINT_DIR, "")


static func _define_setting(key: String, default_value: String, hint: int, hint_string: String) -> void:
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, default_value)
	ProjectSettings.set_initial_value(key, default_value)
	ProjectSettings.add_property_info({"name": key, "type": TYPE_STRING, "hint": hint, "hint_string": hint_string})


static func default_object_script_path() -> String:
	var val := str(ProjectSettings.get_setting(SETTING_OBJECT_SCRIPT, OBJECT_SCRIPT))
	return val if not val.is_empty() and ResourceLoader.exists(val) else OBJECT_SCRIPT


static func default_directory(setting_key: String) -> String:
	var val := str(ProjectSettings.get_setting(setting_key, "res://"))
	return val if not val.is_empty() else "res://"


func refresh() -> void:
	objects.clear()
	species.clear()
	palettes.clear()
	render_settings = PackedStringArray()
	physics_settings = PackedStringArray()
	placement_settings = PackedStringArray()
	_script_kind_cache.clear()
	_script_kind_cache[OBJECT_SCRIPT] = "object"
	_script_kind_cache[SPECIES_SCRIPT] = "species"
	_script_kind_cache[PALETTE_SCRIPT] = "palette"
	_script_kind_cache[RENDER_SCRIPT] = "render"
	_script_kind_cache[PHYSICS_SCRIPT] = "physics"
	_script_kind_cache[PLACEMENT_SCRIPT] = "placement"

	var tres_files: Array[String] = []
	_collect_tres("res://", tres_files)
	for path in tres_files:
		var kind := _classify_tres(path)
		if kind.is_empty():
			continue
		var folder := path.get_base_dir()
		var base := path.get_file().get_basename()
		var category := _category_from_folder(folder)
		match kind:
			"object":
				objects.append({"path": path, "name": base, "category": category, "folder": folder})
			"species":
				species.append({"path": path, "name": base, "category": category, "folder": folder})
			"palette":
				palettes.append({"path": path, "name": base, "folder": folder})
			"render":
				render_settings.append(path)
			"physics":
				physics_settings.append(path)
			"placement":
				placement_settings.append(path)

	objects.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.path < b.path)
	species.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.path < b.path)
	palettes.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.path < b.path)
	render_settings.sort()
	physics_settings.sort()
	placement_settings.sort()


func categories_for(items: Array[Dictionary]) -> PackedStringArray:
	var seen := {}
	for entry in items:
		var cat := str(entry.get("category", ""))
		if not cat.is_empty():
			seen[cat] = true
	var list := seen.keys()
	list.sort()
	return PackedStringArray(list)


func _collect_tres(dir_path: String, out: Array[String]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var entry := dir.get_next()
		if entry.is_empty():
			break
		if entry.begins_with("."):
			continue
		var full := dir_path.path_join(entry) if dir_path != "res://" else "res://" + entry
		if dir.current_is_dir():
			if full == "res://addons" or full == "res://.godot":
				continue
			_collect_tres(full, out)
		elif entry.ends_with(".tres"):
			out.append(full)
	dir.list_dir_end()


# Parses only the first ~30 lines of a .tres file to find its root script path or script_class.
func _classify_tres(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var header := file.get_line()
	if not header.begins_with("[gd_resource"):
		return ""
	if header.contains("script_class=\"CopiaObject\""):
		return "object"
	if header.contains("script_class=\"CopiaSpecies\""):
		return "species"
	if header.contains("script_class=\"CopiaBrushPalette\""):
		return "palette"
	if header.contains("script_class=\"CopiaRenderSettings\""):
		return "render"
	if header.contains("script_class=\"CopiaPhysicsSettings\""):
		return "physics"
	if header.contains("script_class=\"CopiaPlacementSettings\""):
		return "placement"
	# Only Resource files can be Copia resources.
	if not header.contains("type=\"Resource\""):
		return ""
	var ext_scripts := {}  # id -> res:// path
	var root_script_id := ""
	var in_resource := false
	for _i in 40:
		if file.eof_reached():
			break
		var line := file.get_line()
		if line.begins_with("[ext_resource") and line.contains("type=\"Script\""):
			var spath := _extract_quoted(line, "path=\"")
			var sid := _extract_quoted(line, "id=\"")
			if not spath.is_empty() and not sid.is_empty():
				ext_scripts[sid] = spath
		elif line == "[resource]":
			in_resource = true
		elif in_resource and line.begins_with("script = ExtResource("):
			root_script_id = _extract_quoted(line, "ExtResource(\"")
			break
		elif in_resource and line.begins_with("["):
			break
	if root_script_id.is_empty() or not ext_scripts.has(root_script_id):
		return ""
	return _script_kind(ext_scripts[root_script_id])


func _script_kind(script_path: String) -> String:
	if _script_kind_cache.has(script_path):
		return _script_kind_cache[script_path]
	var kind := ""
	if ResourceLoader.exists(script_path):
		var script := ResourceLoader.load(script_path) as Script
		var cur := script
		while cur != null:
			var p := cur.resource_path
			if _script_kind_cache.has(p) and not _script_kind_cache[p].is_empty():
				kind = _script_kind_cache[p]
				break
			cur = cur.get_base_script()
	_script_kind_cache[script_path] = kind
	return kind


static func _extract_quoted(line: String, prefix: String) -> String:
	var start := line.find(prefix)
	if start < 0:
		return ""
	start += prefix.length()
	var end := line.find("\"", start)
	return line.substr(start, end - start) if end > start else ""


static func _category_from_folder(folder: String) -> String:
	var rel := folder.trim_prefix("res://")
	var parts := rel.split("/", false)
	if parts.is_empty():
		return ""
	# Prefer a meaningful species/group folder name over size buckets like "large"/"small".
	var last := parts[parts.size() - 1]
	if parts.size() >= 2 and last.to_lower() in ["large", "medium", "small", "tiny", "huge", "tall", "low", "variants"]:
		return parts[parts.size() - 2] + "/" + last
	return last
