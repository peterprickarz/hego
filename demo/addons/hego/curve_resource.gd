extends Resource
class_name HEGoCurveDataResource

@export var positions: PackedVector3Array
@export var order: int
@export var knots: PackedFloat32Array
@export var primitive_attribs: Array
@export var point_attribs: Array

func _init(_positions: PackedVector3Array = PackedVector3Array(), _order: int = 3, _knots: PackedFloat32Array = PackedFloat32Array(), _primitive_attribs: Array = [], _point_attribs: Array = []):
    positions = _positions
    order = _order
    knots = _knots
    primitive_attribs = _primitive_attribs
    point_attribs = _point_attribs