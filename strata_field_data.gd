@tool
class_name StrataFieldData
extends Resource
## One scalar channel with its exact physical sampling lattice. Native storage
## uses logical pixel indices, so channels can have different steps/origins.

@export var channel: StringName = &"height"
@export var data: StrataLayerData = StrataLayerData.new()
@export var sample_origin := Vector3.ZERO
@export var sample_step_x := Vector3.RIGHT
@export var sample_step_y := Vector3.BACK
@export var resolution := Vector2i.ZERO
@export var attrs: Dictionary = {}

func _init() -> void:
	resource_local_to_scene = true

func _validate_property(property: Dictionary) -> void:
	if property.name in ["channel", "data", "sample_origin", "sample_step_x", "sample_step_y", "resolution", "attrs"]:
		property.usage |= PROPERTY_USAGE_READ_ONLY

func physical_position(index: Vector2) -> Vector3:
	return sample_origin + sample_step_x * index.x + sample_step_y * index.y

func logical_position(position: Vector2) -> Vector2:
	var basis := Transform2D(Vector2(sample_step_x.x, sample_step_x.z), Vector2(sample_step_y.x, sample_step_y.z), Vector2(sample_origin.x, sample_origin.z))
	return basis.affine_inverse() * position

func sample(position: Vector2) -> Dictionary:
	return data.sample_channel(channel, logical_position(position))

func signature() -> Dictionary:
	return {"resource": get_instance_id(), "data": data.get_instance_id(), "revision": data.get_revision(), "channel": channel, "origin": sample_origin, "step_x": sample_step_x, "step_y": sample_step_y, "resolution": resolution, "attrs": attrs.duplicate(true)}

## The caller validates an entire cook before publishing any of these resources.
static func from_field(field: Dictionary) -> StrataFieldData:
	var result := StrataFieldData.new()
	result.channel = StringName(field.name)
	result.sample_origin = field.sample_origin
	result.sample_step_x = field.sample_step_x
	result.sample_step_y = field.sample_step_y
	result.resolution = field.image.get_size()
	result.attrs = field.get("attrs", {}).duplicate(true)
	if not result.data.replace_dense(result.channel, Vector2i.ZERO, field.image, field.get("ownership")):
		return null
	return result

func copy_from(other: StrataFieldData) -> void:
	channel = other.channel
	sample_origin = other.sample_origin
	sample_step_x = other.sample_step_x
	sample_step_y = other.sample_step_y
	resolution = other.resolution
	attrs = other.attrs.duplicate(true)
	data.restore(other.data.snapshot())
