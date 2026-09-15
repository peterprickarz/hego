## An imported [code].hda[/code] file, as Godot's importer sees it.
##
## Importing an HDA does not read it: Houdini owns the file, and HEGo hands the path to the
## session rather than parsing it in Godot. The resource exists so an HDA can be referenced
## from a scene and shows up in the FileSystem dock.
@icon("res://icon.svg")

extends Resource
class_name HDAResource

## Path of the [code].hda[/code] file this resource was imported from.
@export var source_file: String
