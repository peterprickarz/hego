@tool
class_name CopiaSource3D
extends Node3D
## A place a [CopiaStore3D] streams around, in addition to (or instead of) the store's own target:
## its global position. Put it under a camera that draws the same world, such as a monitor or
## preview camera in a [SubViewport], or anywhere a neighbourhood must exist.
##
## Every enabled source in the scene tree is used by the stores it applies to (see [member store]).
## An object's section in a cell is loaded while any source is within the object's range (scaled
## by that source's [member range_scale]) plus the store's [code]load_margin[/code], and freed
## when none is within it plus [code]unload_margin[/code]. A group's quality is that of the most
## demanding source that needs it: the largest [member density] and [member range_scale] among
## them. The renderer does the rest per view: every camera culls the instances, applies their
## visibility ranges and picks mesh LODs from its own position.
##
## Sources register in the scene-tree group [constant GROUP]; a store reads that group when it
## updates, so it finds them without scanning the tree. Adding, removing or changing a source makes
## every store update in its next frame; a moving source is followed at the store's
## [code]update_interval[/code].

## The scene-tree group sources are in while inside the tree.
const GROUP := "copia_sources"

# Bumped by every source that enters or leaves the tree or changes a setting; a store that sees a
# new value updates in its next frame.
static var _revision := 0

## Off: no store streams around this source.
@export var enabled := true:
	set(value):
		if enabled == value: return
		enabled = value
		_touch()
## The [CopiaStore3D] this source applies to. Empty: every store in the scene tree.
@export var store: NodePath:
	set(value):
		if store == value: return
		store = value
		_touch()
## Scales every object's range for this source: the loading distances of draw and impostor
## sections and, when only sources with a smaller scale need a group, the group's visibility range
## end and its impostor swap distance. Colliders are not scaled.
@export_range(0.01, 4.0, 0.01, "or_greater") var range_scale := 1.0:
	set(value):
		value = maxf(value, 0.01)
		if is_equal_approx(range_scale, value): return
		range_scale = value
		_touch()
## Share of the instances this source wants, as the store's [code]density[/code]: a group needed
## only by this source draws the store's density times this.
@export_range(0.0, 1.0, 0.01) var density := 1.0:
	set(value):
		value = clampf(value, 0.0, 1.0)
		if is_equal_approx(density, value): return
		density = value
		_touch()
## Whether colliders are created around this source (within their usual distance).
@export var colliders := true:
	set(value):
		if colliders == value: return
		colliders = value
		_touch()
## Whether objects with a shadow range cast shadows while within it of this source.
@export var shadows := true:
	set(value):
		if shadows == value: return
		shadows = value
		_touch()
## Creation order weight: a store creates the work of a source with a larger priority earlier,
## for the same distance (the order value is distance ÷ priority).
@export_range(0.01, 100.0, 0.01, "or_greater") var priority := 1.0:
	set(value):
		value = maxf(value, 0.01)
		if is_equal_approx(priority, value): return
		priority = value
		_touch()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_ENTER_TREE:
			add_to_group(GROUP)
			_touch()
		NOTIFICATION_EXIT_TREE:
			remove_from_group(GROUP)
			_touch()


## True when this source applies to [param store_node]: enabled, inside the tree, and either no
## [member store] is set or it names that node.
func applies_to(store_node: Node) -> bool:
	if not enabled or not is_inside_tree():
		return false
	if store.is_empty():
		return true
	return get_node_or_null(store) == store_node


static func _touch() -> void:
	_revision += 1
