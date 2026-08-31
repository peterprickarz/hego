@tool
class_name HEGoPropertyUtil
extends RefCounted

## Applies the [code]hego_custom_properties[/code] dictionary an HDA can attach to a
## spawned object onto the object itself.
##
## The dictionary is nested, and every level that carries a value stores it under
## [code]hego_val[/code], so a sub-resource and its own properties can be described
## in one structure:
## [codeblock]
## {
##     "mesh": {
##         "hego_val": "BoxMesh",     # instantiated, then filled in
##         "size": { "hego_val": Vector3(2, 2, 2) },
##     },
##     "visible": { "hego_val": true },
## }
## [/codeblock]

## Key holding the value of a property inside the nested dictionary.
const VALUE_KEY := "hego_val"


## Applies [param properties] to [param obj], recursing into nested dictionaries.
static func apply_custom_properties(obj: Object, properties: Dictionary) -> void:
	for key in properties.keys():
		var value: Variant = properties[key]

		if not value is Dictionary or not value.has(VALUE_KEY):
			push_warning(HEGoNodeUtil.LOG_PREFIX + "Invalid property format for %s, expected dictionary with %s" % [key, VALUE_KEY])
			continue

		var actual_value: Variant = value[VALUE_KEY]

		# Everything besides hego_val that is itself a dictionary describes properties
		# of the value we are about to assign.
		var nested_properties := {}
		for sub_key in value.keys():
			if sub_key != VALUE_KEY and value[sub_key] is Dictionary:
				nested_properties[sub_key] = value[sub_key]

		if nested_properties.is_empty():
			set_property(obj, key, actual_value)
			continue

		if actual_value is String and ClassDB.class_exists(actual_value):
			# The value names a class: instantiate it, then fill in its properties.
			var new_obj: Object = ClassDB.instantiate(actual_value)
			set_property(obj, key, new_obj)
			apply_custom_properties(new_obj, nested_properties)
		elif actual_value is String and ResourceLoader.exists(actual_value):
			# The value is a resource path: load it, then override properties on it.
			var resource: Resource = load(actual_value)
			set_property(obj, key, resource)
			if resource is Object:
				apply_custom_properties(resource, nested_properties)
		else:
			set_property(obj, key, actual_value)
			# Assigning may have converted the value, so re-read the property
			# before applying the nested ones to it.
			var target_obj: Variant = obj.get(key) if has_property(obj, key) else null
			if target_obj is Object:
				apply_custom_properties(target_obj, nested_properties)


## Sets one property, skipping it with a warning if it does not exist or the value
## cannot be converted to the property's type.
static func set_property(obj: Object, property: String, value: Variant) -> void:
	var prop_info := find_property_info(obj, property)
	if prop_info.is_empty():
		push_warning(HEGoNodeUtil.LOG_PREFIX + "Property %s does not exist on %s, skipping" % [property, obj.get_class()])
		return

	var expected_class: String = prop_info.get("class_name", "")
	if is_compatible_type(value, prop_info["type"], expected_class):
		obj.set(property, value)
		return

	var value_class: String = value.get_class() if value is Object else "none"
	push_warning(
		HEGoNodeUtil.LOG_PREFIX
		+ "Type mismatch for %s.%s (expected %s:%s, got %s:%s), skipping"
		% [obj.get_class(), property, prop_info["type"], expected_class if expected_class else "unknown", typeof(value), value_class]
	)


## Returns the [method Object.get_property_list] entry for [param property],
## or an empty dictionary if the object has no such property.
static func find_property_info(obj: Object, property: String) -> Dictionary:
	for property_info in obj.get_property_list():
		if property_info.get("name", "") == property:
			return property_info
	return {}


## Whether [param obj] exposes a property called [param property].
static func has_property(obj: Object, property: String) -> bool:
	return not find_property_info(obj, property).is_empty()


## Whether [param value] can be assigned to a property of [param expected_type]
## (a [enum Variant.Type]) and, for objects, of class [param expected_class].
static func is_compatible_type(value: Variant, expected_type: int, expected_class: String) -> bool:
	var actual_type := typeof(value)

	# For TYPE_OBJECT, check if the value's class is compatible with the expected class
	if expected_type == TYPE_OBJECT and value is Object:
		if expected_class.is_empty():
			return true
		var value_class: String = value.get_class()
		return ClassDB.class_exists(value_class) and ClassDB.is_parent_class(value_class, expected_class)

	if actual_type == expected_type:
		return true

	# Conversions Godot performs implicitly on assignment.
	if expected_type == TYPE_VECTOR3 and actual_type == TYPE_VECTOR2:
		return true
	if expected_type == TYPE_COLOR and actual_type == TYPE_VECTOR3:
		return true
	if expected_type == TYPE_FLOAT and actual_type == TYPE_INT:
		return true

	return false
