@tool
extends Node
## Keeps the terrain's material control maps in step with the MaterialDistribution layer.
##
## When that layer commits a new cook, its mask fields are packed into the ID/weight images
## the renderer reads, and those are written to the terrain's storage directory beside the
## layers. A pack that fails leaves the previous controls, and the layer's previous fields,
## in place. This never cooks an HDA and never infers materials from height or slope.
var terrain: StrataTerrain3D
var _revision := -1
var _pending := false
var _final_state: Dictionary = {}
var status := "Saved Houdini material controls"


func setup(source: StrataTerrain3D) -> void:
	terrain = source
	if terrain.editor_material_channels.is_empty():
		var channels := HEGoIslandMaterials.channels()
		if not channels.is_empty(): terrain.editor_material_channels = channels
	var target := terrain.get_node_or_null(HEGoIslandMaterials.LAYER) as StrataLayer
	if target != null:
		_revision = target.procedural_revision
		_final_state = _state(target)
	terrain.authoring_preview_changed.connect(_changed)


func _state(target: StrataLayer) -> Dictionary:
	# A commit creates fresh field resources, so keeping references to the previous ones
	# keeps the previous complete result available without copying anything.
	return {"fields": target.procedural_fields.duplicate(), "modes": target.composition_modes.duplicate(true), "revision": target.procedural_revision, "producer": target.producer_id}


func _changed() -> void:
	if not is_instance_valid(terrain) or _pending: return
	var target := terrain.get_node_or_null(HEGoIslandMaterials.LAYER) as StrataLayer
	if target == null: return
	# A layer added after setup() is remembered as it is now, so its first cook has a
	# previous state to fall back to.
	if _final_state.is_empty():
		_final_state = _state(target)
		_revision = target.procedural_revision
	if target.procedural_stale or target.procedural_revision == _revision: return
	_pending = true
	_repack.call_deferred()


func _repack() -> void:
	_pending = false
	if not is_instance_valid(terrain): return
	var target := terrain.get_node_or_null(HEGoIslandMaterials.LAYER) as StrataLayer
	if target == null or target.procedural_stale or target.procedural_revision == _revision: return
	var packed := HEGoIslandMaterials.pack(target)
	if not packed.get("ok", false):
		_reject(target, String(packed.get("message", "Material packing failed")))
		return
	var previous_ids := terrain.editor_control_ids
	var previous_weights := terrain.editor_control_weights
	terrain.editor_control_ids = packed.ids
	terrain.editor_control_weights = packed.weights
	if StrataStorage.has_storage(terrain):
		var saved := StrataStorage.save_control_maps(terrain)
		if not saved.ok:
			terrain.editor_control_ids = previous_ids
			terrain.editor_control_weights = previous_weights
			_reject(target, String(saved.message))
			return
	_revision = target.procedural_revision
	_final_state = _state(target)
	status = "%d Houdini material masks packed into the terrain's control maps" % target.procedural_fields.size()
	if Engine.is_editor_hint(): EditorInterface.mark_scene_as_unsaved()


## Puts the previous complete fields back on the layer and reports why. Hand data and shared
## resources are never touched; the revision advances so no old token is reused.
func _reject(target: StrataLayer, message: String) -> void:
	target.procedural_fields = _final_state.fields.duplicate()
	target.composition_modes = _final_state.modes.duplicate(true)
	target.producer_id = _final_state.producer
	target.procedural_revision += 1
	_revision = target.procedural_revision
	_final_state = _state(target)
	status = message + "; previous complete material fields and controls retained"
	target.procedural_stale = true
	target.procedural_status = status
	push_error(status)
	terrain.queue_preview_update()
