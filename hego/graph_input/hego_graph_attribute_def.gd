@tool
class_name HEGoGraphAttributeDef
extends Resource

## One attribute a [HEGoGraph3D] can store on its points or connections.
##
## Lives in a [HEGoGraphAttributes] list on a child of the graph. The name, owner
## and value type decide what is sent to Houdini; the rest only shapes the editor UI.

enum Owner {
	POINT,
	CONNECTION,
}

enum ValueType {
	FLOAT,
	INT,
	STRING,
	## Three floats (a Houdini vector of tuple size 3), stored as a [PackedVector3Array].
	VECTOR3,
}

## Houdini attribute name. Must be unique per owner on one graph.
@export var attribute_name: String = "attr":
	set(value):
		if attribute_name == value:
			return
		attribute_name = value
		emit_changed()

## Whether this attribute is stored on points or on connections (Houdini prims).
@export var owner: Owner = Owner.POINT:
	set(value):
		if owner == value:
			return
		owner = value
		emit_changed()

## Storage type sent to Houdini.
@export var value_type: ValueType = ValueType.FLOAT:
	set(value):
		if value_type == value:
			return
		value_type = value
		emit_changed()

## Default for a newly created point or connection when [member value_type] is FLOAT.
@export var default_float: float = 0.0:
	set(value):
		if default_float == value:
			return
		default_float = value
		emit_changed()

## Default for a newly created point or connection when [member value_type] is INT.
@export var default_int: int = 0:
	set(value):
		if default_int == value:
			return
		default_int = value
		emit_changed()

## Default for a newly created point or connection when [member value_type] is STRING.
@export var default_string: String = "":
	set(value):
		if default_string == value:
			return
		default_string = value
		emit_changed()

## Default for a newly created point or connection when [member value_type] is VECTOR3.
@export var default_vector: Vector3 = Vector3.ZERO:
	set(value):
		if default_vector == value:
			return
		default_vector = value
		emit_changed()

## When [member value_type] is INT, the editor shows a checkbox and stores 0 or 1.
@export var int_as_toggle: bool = false:
	set(value):
		if int_as_toggle == value:
			return
		int_as_toggle = value
		emit_changed()

## When [member value_type] is STRING and this is not empty, the editor shows a dropdown.
@export var string_options: PackedStringArray = PackedStringArray():
	set(value):
		string_options = value
		emit_changed()


## The default that matches [member value_type].
func default_value() -> Variant:
	match value_type:
		ValueType.FLOAT:
			return default_float
		ValueType.INT:
			return default_int
		ValueType.STRING:
			return default_string
		ValueType.VECTOR3:
			return default_vector
	return null


## A packed array of [param size] filled with [method default_value].
func make_array(size: int) -> Variant:
	match value_type:
		ValueType.FLOAT:
			var floats := PackedFloat32Array()
			floats.resize(size)
			var fill := default_float
			for i in size:
				floats[i] = fill
			return floats
		ValueType.INT:
			var ints := PackedInt32Array()
			ints.resize(size)
			var fill_int := default_int
			for i in size:
				ints[i] = fill_int
			return ints
		ValueType.STRING:
			var strings := PackedStringArray()
			strings.resize(size)
			var fill_str := default_string
			for i in size:
				strings[i] = fill_str
			return strings
		ValueType.VECTOR3:
			var vectors := PackedVector3Array()
			vectors.resize(size)
			vectors.fill(default_vector)
			return vectors
	return null


## Whether [param array] is the packed type this definition stores.
func matches_array(array: Variant) -> bool:
	match value_type:
		ValueType.FLOAT:
			return array is PackedFloat32Array
		ValueType.INT:
			return array is PackedInt32Array
		ValueType.STRING:
			return array is PackedStringArray
		ValueType.VECTOR3:
			return array is PackedVector3Array
	return false


## The value type that stores [param array], or -1 when no type does. Used to declare the
## attributes a cook sends back.
static func value_type_of(array: Variant) -> int:
	if array is PackedFloat32Array or array is PackedFloat64Array:
		return ValueType.FLOAT
	if array is PackedInt32Array or array is PackedInt64Array:
		return ValueType.INT
	if array is PackedStringArray:
		return ValueType.STRING
	if array is PackedVector3Array:
		return ValueType.VECTOR3
	return -1
