@tool
extends HEGoNode3D
## Loads the parameter test fixture into the active Houdini session on first use.

## The HDA file. A remote server and Godot must both be able to read the same absolute path.
@export var fixture_library: String


func _ensure_library() -> bool:
	var live := hego_get_asset_node()
	if live != null and live.get_id() >= 0:
		return true
	var api := HEGoAPI.get_singleton()
	if not api.is_session_active():
		HEGoLog.get_singleton().error("fixture", "Start a HEGo session to use the parameter test fixture.")
		return false
	var result := await HEGoNodeUtil.checked_task(self, api.load_hda_library(fixture_library))
	if not result.ok:
		HEGoLog.get_singleton().error("fixture", "Could not load %s: %s" % [fixture_library, result.message])
	return result.ok


func cook() -> void:
	_last_cook_succeeded = false
	if await _ensure_library():
		await super.cook()


func hego_rebuild() -> bool:
	_last_cook_succeeded = false
	if not await _ensure_library():
		return false
	return await super.hego_rebuild()
