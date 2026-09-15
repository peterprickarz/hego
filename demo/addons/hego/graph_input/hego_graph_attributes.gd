@tool
class_name HEGoGraphAttributes
extends Node

## Schema for a [HEGoGraphInput3D]: the attributes its points and connections can carry.
##
## Parent this under a graph and fill [member attributes]. The list can be saved as its
## own scene and reused under other graphs. Several children concatenate in tree order.

## Emitted when the list of definitions, or a definition inside it, changes.
signal schema_changed

## Attribute definitions this child adds to its parent graph.
@export var attributes: Array[HEGoGraphAttributeDef] = []:
	set(value):
		_disconnect_defs(attributes)
		attributes = value
		_connect_defs(attributes)
		schema_changed.emit()
		_notify_parent()


func _enter_tree() -> void:
	_connect_defs(attributes)
	_notify_parent()


func _exit_tree() -> void:
	_disconnect_defs(attributes)


func _notify_parent() -> void:
	var parent := get_parent()
	if parent != null and parent.has_method("sync_schema"):
		parent.sync_schema()


func _connect_defs(defs: Array) -> void:
	for def in defs:
		if def is HEGoGraphAttributeDef and not def.changed.is_connected(_on_def_changed):
			def.changed.connect(_on_def_changed)


func _disconnect_defs(defs: Array) -> void:
	for def in defs:
		if def is HEGoGraphAttributeDef and def.changed.is_connected(_on_def_changed):
			def.changed.disconnect(_on_def_changed)


func _on_def_changed() -> void:
	schema_changed.emit()
