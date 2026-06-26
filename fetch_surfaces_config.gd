extends Resource
class_name HEGoFetchSurfacesConfig

@export var normal : bool
@export var color : bool
@export var uv : bool
@export var uv2 : bool
@export var tangents: bool
@export var read_attribs : PackedStringArray
@export var filter_attribs : PackedStringArray
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
@export var split_attribs : PackedStringArray



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
