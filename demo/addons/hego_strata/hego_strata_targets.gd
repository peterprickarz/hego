@tool
class_name HEGoStrataTargets
extends HEGoCookExtension
## Publishes the heightfields an HEGo node's HDA outputs into procedural terrain layers.
##
## Add it as a child of an [HEGoNode3D] and list the layers in [member targets]. A cook then
## becomes one transaction: every terrain input is snapshotted before upload, every target
## receives a complete validated result, and anything that changes or fails along the way
## leaves all previous results, terrain and Outputs alike, in place. Paths in
## [member targets] are relative to the HEGo node, the same as its input paths.

## Key this extension keeps its per-cook state under in the shared cook dictionary.
const COOK_KEY := "hego_strata"
## Name given to a binding created with [method ensure].
const DEFAULT_NAME := "StrataTargets"

## Complete procedural output bindings. Each entry has path, channels, and optional
## required_channels. Height is required by default when declared; use mask-only
## declarations for scalar-only stages. Targets must be explicitly procedural.
@export var targets: Array[Dictionary] = []
## Stable identity of this producer, recorded on the layers it publishes. Generated on
## first use when empty.
@export var producer_id := ""
@export_multiline var status := "No terrain cook yet"
@export var stale := true

var _generation := 0
var _context_revision := 0
var _last_state: Dictionary = {}
var _poll_elapsed := 0.0


## The binding under [param host], or null when it has none.
static func of(host: Node) -> HEGoStrataTargets:
	if host == null:
		return null
	for child in host.get_children():
		if child is HEGoStrataTargets and not child.is_queued_for_deletion():
			return child
	return null


## The binding under [param host], created when it has none. A new binding is owned by the
## host's owner, so it is saved with the scene; add the host to its scene first.
static func ensure(host: Node) -> HEGoStrataTargets:
	var existing := of(host)
	if existing != null:
		return existing
	var created := HEGoStrataTargets.new()
	created.name = DEFAULT_NAME
	host.add_child(created)
	var scene_owner := host.owner if host.owner != null else host
	if host.is_inside_tree() and host.get_tree().edited_scene_root == host:
		scene_owner = host
	created.owner = scene_owner
	return created


func get_producer() -> String:
	if producer_id.is_empty():
		producer_id = Crypto.new().generate_random_bytes(16).hex_encode()
	return producer_id


## Records that the host's inputs or parameters changed, so every bound layer and any
## runtime bake built from them is stale until the next explicit cook.
func mark_stale() -> void:
	_context_revision += 1
	stale = true
	status = "Inputs/parameters changed; explicit recook required"
	var host := get_parent()
	if host == null:
		return
	for binding in targets:
		var layer := HEGoInputNodes._resolve_input_node(host, binding.get("path", ""))
		if layer is StrataLayer:
			layer.procedural_stale = true
			layer.procedural_status = status
			# Explicit input/parameter intent, even when the cached target was already
			# stale. This also tells the terrain its runtime bake is out of date.
			layer.mark_producer_intent()


# ─────────────────────────────────────────────
# HEGoCookExtension
# ─────────────────────────────────────────────

func cook_prepare(host: Node, cook: Dictionary) -> Dictionary:
	_generation += 1
	var generation := _generation
	if not targets.is_empty():
		stale = true
		status = "Cooking; previous procedural cache retained"
	var guard_signature := _signature()
	var guard := func(): return _signature() == guard_signature
	var rows: Array = host.hego_get_input_stash() if host.has_method("hego_get_input_stash") else []
	var state := HEGoStrataOutput.prepare(host, rows, targets, get_producer(), guard)
	state["generation"] = generation
	cook[COOK_KEY] = state
	if not state.ok:
		_set_result(state, generation)
		return state
	# Bound targets publish all-or-nothing, so no input may be silently skipped.
	if state.get("active", false):
		cook.strict = true
	return {"ok": true}


func cook_before(host: Node, asset: HEGoAssetNode, cook: Dictionary) -> Dictionary:
	var state: Dictionary = cook.get(COOK_KEY, {})
	var captured := await HEGoStrataOutput.capture_preset(host, asset, state)
	if not captured.ok:
		_set_result(captured, state.get("generation", -1))
	return captured


func cook_commit(context: HEGoOutputContext) -> Dictionary:
	var state: Dictionary = context.cook_state.get(COOK_KEY, {})
	if not state.get("active", false):
		return {"ok": true}
	var result := await HEGoStrataOutput.handle(context, state)
	_set_result(result, state.generation)
	if not result.ok:
		return result
	if state.generation != _generation:
		return {"ok": false, "message": "A newer cook of this node superseded this one"}
	var published: Array = []
	for binding in state.prebound.values():
		var layer: StrataLayer = binding.ref.get_ref()
		published.append(StrataProcedural.revision_token(layer, "raw"))
	_last_state = {"inputs": state.inputs, "published": published, "signature": _signature()}
	return {"ok": true}


func cook_failed(_host: Node, cook: Dictionary, message: String) -> void:
	var state: Dictionary = cook.get(COOK_KEY, {})
	if state.is_empty():
		return
	_set_result(HEGoStrataOutput.fail(state, message), state.get("generation", -1))


## One terrain backend per cook: a host publishing into terrain layers does not also build
## Terrain3D output from the same heightfields.
func skips_output_handler(handler: Variant, cook: Dictionary) -> bool:
	if not cook.get(COOK_KEY, {}).get("active", false):
		return false
	return handler == HEGoTerrain3DOutput or handler == HEGoTerrain3DInstancer


func inputs_changed() -> void:
	mark_stale()


func requires_explicit_cook() -> bool:
	return not targets.is_empty()


# ─────────────────────────────────────────────
# Freshness
# ─────────────────────────────────────────────

func _ready() -> void:
	if not targets.is_empty():
		stale = true
		status = "Cached terrain state; explicit recook required after loading"


# Watches for anything that makes the last published result out of date: the host's own
# settings, its terrain inputs, or the published layers themselves.
func _process(delta: float) -> void:
	if stale or _last_state.is_empty(): return
	_poll_elapsed += delta
	if _poll_elapsed < 0.25: return
	_poll_elapsed = 0.0
	if _signature() != _last_state.signature:
		mark_stale()
		return
	for snapshot in _last_state.inputs:
		if not StrataProcedural.token_is_current(snapshot.token):
			mark_stale()
			return
	for token in _last_state.published:
		if not StrataProcedural.token_is_current(token):
			mark_stale()
			return


func _signature() -> Dictionary:
	var host := get_parent()
	var inputs: Array = host.hego_get_input_stash() if host != null and host.has_method("hego_get_input_stash") else []
	return {
		"generation": _generation,
		"context": _context_revision,
		"host": host.get_instance_id() if host != null else 0,
		"asset": host.get("asset_name") if host != null else null,
		"inputs": inputs.duplicate(true),
		"targets": targets.duplicate(true),
		"transform": host.global_transform if host is Node3D else Transform3D(),
	}


func _set_result(result: Dictionary, generation := -1) -> void:
	if generation >= 0 and generation != _generation: return
	stale = not result.get("ok", false)
	status = String(result.get("message", "Unknown terrain cook status"))
	if stale: HEGoLog.get_singleton().warning("terrain", status)


func _validate_property(property: Dictionary) -> void:
	if property.name in ["status", "stale"]: property.usage |= PROPERTY_USAGE_READ_ONLY


func _get_configuration_warnings() -> PackedStringArray:
	if not get_parent() is HEGoNode3D:
		return PackedStringArray(["HEGoStrataTargets only takes part in cooks as a direct child of an HEGoNode3D."])
	return PackedStringArray()
