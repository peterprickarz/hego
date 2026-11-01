class_name HEGoIslandMaterialRegistry
extends RefCounted
## Stable IDs and explicit resources; safe in a compiled-only project without HEGo.
const REGISTRY := "res://island/materials/material_registry.json"
## The renderer and the native packer hold this many material slots; the registry may use fewer.
const MAX_COUNT := 32

## How many materials the installed registry declares, or 0 when it is missing or invalid.
static func count() -> int:
	var checked := registry()
	return checked.entries.size() if checked.ok else 0

static func validate_registry(value: Variant) -> Dictionary:
	if not value is Array or value.is_empty() or value.size() > MAX_COUNT: return {"ok": false, "message": "The material registry must declare 1 to %d distinct sources" % MAX_COUNT}
	var names := {}; var sources := {}; var paths := {}
	for index in range(value.size()):
		var item: Variant = value[index]
		if not item is Dictionary or item.get("id", -1) != index or not item.get("name") is String or String(item.name).is_empty(): return {"ok": false, "message": "Material registry IDs must be ordered 0..%d" % (value.size() - 1)}
		if item.get("channel") != "material_" + item.name: return {"ok": false, "message": "Material channel does not match its stable name"}
		if not item.get("resource") is String or not String(item.resource).begins_with("res://island/materials/resources/"): return {"ok": false, "message": "Material resource must be an explicit island resource"}
		if not item.get("ambientcg_id") is String or String(item.ambientcg_id).is_empty(): return {"ok": false, "message": "Material source identity is missing"}
		if names.has(item.name) or paths.has(item.resource) or sources.has(item.ambientcg_id): return {"ok": false, "message": "Material names, resources and ambientCG sources must all be distinct"}
		names[item.name] = true; paths[item.resource] = true; sources[item.ambientcg_id] = true
	return {"ok": true, "entries": value}

static func registry() -> Dictionary:
	if not FileAccess.file_exists(REGISTRY): return {"ok": false, "message": "No stable material registry is installed"}
	return validate_registry(JSON.parse_string(FileAccess.get_file_as_string(REGISTRY)))

static func channels() -> PackedStringArray:
	var result := PackedStringArray()
	var checked := registry()
	if checked.ok:
		for entry in checked.entries: result.append(entry.channel)
	return result

static func pool() -> Array[StrataMaterial]:
	var result: Array[StrataMaterial] = []
	var checked := registry()
	if not checked.ok: push_error(checked.message); return result
	for entry in checked.entries:
		var material := load(String(entry.resource)) as StrataMaterial
		if material == null:
			push_error("Missing real material %d: %s; no alias fallback" % [entry.id, entry.resource])
			return []
		result.append(material)
	return result
