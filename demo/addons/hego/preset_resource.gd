## Named parameter presets for one Houdini operator in the HEGo bottom panel.
##
## The panel stores one resource per operator under [code]res://hego/presets/[/code]. For example, [code]Sop/sample[/code] uses [code]sample.tres[/code].
## Names that require encoding for Windows, such as [code]acme::sample::2.0[/code], use [code]encoded/<SHA-256>.tres[/code]. Existing namespaced preset files on Linux retain their original paths.
## Loading a named preset restores the Houdini parameter values and resolves its saved scene-node references in the current session.
extends Resource
class_name HEGoHDAPreset

## Maps each preset name to the binary [PackedByteArray] returned by [method HEGoAssetNode.get_preset].
@export var presets: Dictionary

func _init():
	presets = Dictionary()

## Maps each preset name to its Houdini node-reference parameters. Each binding records the source host's relative scene path, operator name and asset label so the panel can reconnect the source after a session restart.
@export_storage var parameter_links: Dictionary
