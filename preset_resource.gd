## Saved parameter presets for one HDA, as the bottom panel's preset list stores them.
##
## One resource per operator, written to [code]res://hego/presets/<operator>.tres[/code]. A preset is the
## blob [method HEGoAssetNode.get_preset] returns, which is also what a node's
## [code]parm_stash[/code] holds, so a preset and a stashed parameter set are the same thing
## saved in two places.
extends Resource
class_name HEGoHDAPreset

## Preset name to the parameter blob saved under it.
@export var presets: Dictionary

func _init():
	presets = Dictionary()
