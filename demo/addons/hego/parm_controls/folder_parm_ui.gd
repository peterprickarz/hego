@tool
extends Control

@onready var header_label = $PanelContainer/VBoxContainer/HeaderLabel
@onready var content_container = $PanelContainer/VBoxContainer/VBoxContainer/ContentContainer

var param: Dictionary = {}

func setup(_param: Dictionary):
	param = _param.duplicate()
	header_label.text = param["label"]
	visible = param["visible"]
	
	if param["help"]:
		tooltip_text = param["help"]
	
	if Engine.is_editor_hint():
		queue_redraw()

func get_container() -> VBoxContainer:
	return content_container
