## Attributes, filters and splits for a surface fetch, saved as a resource.
##
## @deprecated: Use HEGoAssetNode.get_surface_output() instead. Fetch configs are kept
## only so existing projects can move across, and will be removed. The code API
## takes the same arguments, shares the same implementation and cache, and can
## decide what to read at runtime.
extends Resource
class_name HEGoFetchSurfacesConfig

## Whether to read the [code]N[/code] attribute into the surface's normals.
@export var normal : bool
## Whether to read the [code]Cd[/code] attribute into the surface's vertex colours.
@export var color : bool
## Whether to read the first UV set.
@export var uv : bool
## Whether to read the second UV set.
@export var uv2 : bool
## Whether to read tangents.
@export var tangents: bool
## Further attribute names to read from the cook, beyond the toggles above.
@export var read_attribs : PackedStringArray
## Attribute names to filter the primitives on, one per entry of [member filter_attrib_values].
@export var filter_attribs : PackedStringArray
## The value each attribute in [member filter_attribs] has to carry for a primitive to be kept.
@export var filter_attrib_values : Array[Variant]:
	set(value):
		# Ensure correct type
		for i in range(value.size()):
			if not typeof(value[i]) in [
				TYPE_INT, 
				TYPE_STRING, 
				TYPE_FLOAT, 
				TYPE_VECTOR2, 
				TYPE_VECTOR3, 
				TYPE_VECTOR4, 
				TYPE_VECTOR2I, 
				TYPE_VECTOR3I,
				TYPE_VECTOR4I,
				TYPE_NIL,
				]:
				push_error("[Houdini Engine]: Invalid type in array. Only int, float, their vector counterparts, and string is supported.")
				return
		filter_attrib_values = value
## Attribute names to group the kept primitives by, applied in order, one nesting level each.
@export var split_attribs : PackedStringArray



## Builds a config from its fields, so one can be made in code as well as saved.
func _init(
	p_read_attribs = PackedStringArray(), 
	p_filter_attribs = PackedStringArray(), 
	p_filter_attrib_values = Array(),
	p_split_attribs = PackedStringArray()
	):
		read_attribs = p_read_attribs
		filter_attribs = p_filter_attribs
		filter_attrib_values = p_filter_attrib_values
		split_attribs = p_split_attribs
