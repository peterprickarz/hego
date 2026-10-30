@tool
class_name StrataLayer
extends Node
## A sparse edit layer. Its native resource stores explicit sample ownership.

enum Composition { REPLACE, ADD }

## Procedural targets are replaced by complete validated cook results. Paint on
## a separate manual layer; its data and ownership remain independent.
@export var procedural := false:
	set(value):
		if value == procedural: return
		if value and data != null and not data.get_channel_names().is_empty():
			push_warning("Move owned manual samples to a hand layer before making this a procedural target.")
			return
		if not value and (not procedural_fields.is_empty() or not producer_id.is_empty()):
			push_warning("Explicitly clear/detach the procedural cache and producer binding before making this a manual layer.")
			return
		procedural = value
		_data_changed()
@export var layer_id := ""
@export var producer_id := ""
@export var procedural_fields: Dictionary = {}
@export var procedural_revision := 0
@export var procedural_stale := true
@export_multiline var procedural_status := "Manual layer"
## How many times this layer's producer has recorded new intent, such as changed inputs or
## parameters. A runtime bake built before the latest intent is stale even while the cached
## result is unchanged. Only [method mark_producer_intent] advances it.
@export var producer_intent_revision := 0

@export var data: StrataLayerData = StrataLayerData.new():
	set(value):
		if data != null and data.changed.is_connected(_data_changed):
			data.changed.disconnect(_data_changed)
		data = value if value != null else StrataLayerData.new()
		if not data.changed.is_connected(_data_changed):
			data.changed.connect(_data_changed)
		_data_changed()

@export var enabled: bool = true:
	set(value):
		enabled = value
		_data_changed()

## Missing channels default to Replace. Channels compose independently.
@export var composition_modes: Dictionary = {}:
	set(value):
		composition_modes = value
		_data_changed()

func _ready() -> void:
	ensure_identity()
	if procedural:
		procedural_stale = true
		procedural_status = "Cached procedural result; explicit recook required" if not procedural_fields.is_empty() else "Procedural target; no result yet"
	if not data.changed.is_connected(_data_changed):
		data.changed.connect(_data_changed)
	_data_changed()

func ensure_identity() -> String:
	if layer_id.is_empty():
		layer_id = Crypto.new().generate_random_bytes(16).hex_encode()
	return layer_id

func get_channel_names() -> PackedStringArray:
	var names := data.get_channel_names()
	for channel in procedural_fields:
		if not names.has(String(channel)):
			names.append(String(channel))
	return names

func sample_channel(channel: StringName, position: Vector2) -> Dictionary:
	var field: StrataFieldData = procedural_fields.get(String(channel))
	if field == null:
		return data.sample_channel(channel, position)
	var result := field.sample(position)
	# Keep native scalar values untouched. A Replace height is projected from
	# its physical plane datum; Add height is already a signed delta.
	if channel == &"height" and get_composition(channel) == Composition.REPLACE:
		result.value = float(result.value) + field.sample_origin.y
	return result

func get_channel_data(channel: StringName) -> StrataLayerData:
	var field: StrataFieldData = procedural_fields.get(String(channel))
	return field.data if field != null else data

func _validate_property(property: Dictionary) -> void:
	if property.name in ["procedural_status", "procedural_revision", "procedural_stale", "layer_id", "producer_intent_revision"]:
		property.usage |= PROPERTY_USAGE_READ_ONLY
	if property.name == "procedural_fields" or (procedural and property.name == "data"):
		property.usage |= PROPERTY_USAGE_READ_ONLY

## Records that whatever produces this layer has new inputs or parameters, so a runtime bake
## of its current result is out of date before the producer has cooked again. Status and
## loading changes must not call this.
func mark_producer_intent() -> void:
	producer_intent_revision += 1
	_data_changed()

func get_composition(channel: StringName) -> int:
	return int(composition_modes.get(String(channel), Composition.REPLACE))

func set_composition(channel: StringName, mode: int) -> void:
	composition_modes[String(channel)] = mode
	_data_changed()

func _data_changed() -> void:
	if get_parent() is StrataTerrain3D:
		get_parent().queue_preview_update()
