extends SceneTree
## HEGo's extension points with the HEGo Strata bridge installed. Never starts Houdini.
## Needs a project with addons/hego, addons/strata and addons/hego_strata;
## demo/tests/addon_split_runner.py stages one.

var checks := 0
var failures := 0


class RefusingExtension extends HEGoCookExtension:
	func cook_prepare(_host: Node, _cook: Dictionary) -> Dictionary:
		return {"ok": false, "message": "refused for test"}


## Stands in for an output handler that builds terrain from heightfields; this project has
## no Terrain3D bridge.
class HeightfieldOutput extends HEGoOutputHandler:
	func handles_heightfields() -> bool:
		return true


class RecordingExtension extends HEGoCookExtension:
	var prepared := 0
	var failed: Array = []
	func cook_prepare(_host: Node, _cook: Dictionary) -> Dictionary:
		prepared += 1
		return {"ok": true}
	func cook_failed(_host: Node, _cook: Dictionary, message: String) -> void:
		failed.append(message)


func _initialize() -> void:
	run.call_deferred()


func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("EXTENSION_POINTS_TEST: " + message)


func run() -> void:
	# The demo project also has the Terrain3D bridge's input handler; the staged project
	# has only this bridge's.
	var handlers := HEGoInputNodes.extension_handlers().filter(func(handler): return handler is HEGoStrataInput)
	check(handlers.size() == 1, "HEGo discovers the bridge's terrain input handler from the class list")
	check(HEGoInputNodes.extension_handlers().has(handlers[0]) if handlers.size() == 1 else false, "handler instances are reused while the class list is unchanged")

	var scene := Node3D.new(); root.add_child(scene)
	var terrain := StrataTerrain3D.new(); terrain.name = "Terrain"; terrain.base_bounds = Rect2(0, 0, 4, 4); terrain.set_preview_enabled(false)
	scene.add_child(terrain)
	var layer := StrataLayer.new(); layer.name = "Generated"; layer.procedural = true; terrain.add_child(layer)
	var orphan := StrataLayer.new(); orphan.name = "Orphan"; scene.add_child(orphan)
	check(HEGoInputNodes.is_compatible_source(layer) and HEGoInputNodes.handler_for(layer) is HEGoStrataInput, "a terrain layer is an input HEGo can send")
	check(not HEGoInputNodes.is_compatible_source(orphan), "a layer outside a terrain is not")

	var host := HEGoNode3D.new(); host.name = "Producer"; host.asset_name = "Sop/test"; scene.add_child(host)
	check(host.cook_extensions().is_empty() and not host.hego_requires_explicit_cook(), "a plain HEGo node has no extensions and recooks automatically")
	var binding := HEGoStrataTargets.ensure(host)
	var extensions := host.cook_extensions()
	check(HEGoStrataTargets.of(host) == binding and HEGoStrataTargets.ensure(host) == binding and extensions.size() == 1 and extensions[0] == binding, "ensure() adds one binding, which the host lists as a cook extension")
	check(not host.hego_requires_explicit_cook(), "a binding without targets does not force explicit cooks")
	binding.targets = [{"path": "../Terrain/Generated"}]
	check(host.hego_requires_explicit_cook(), "bound targets make the host cook only on request")
	layer.procedural_stale = false
	binding.stale = false
	var intent := layer.producer_intent_revision
	host.hego_notify_cook_inputs_changed()
	check(binding.stale and layer.procedural_stale and layer.producer_intent_revision == intent + 1, "an input change reaches the binding and marks its target layer stale")
	var active := {HEGoStrataTargets.COOK_KEY: {"active": true}}
	var heightfields := HeightfieldOutput.new()
	check(binding.skips_output_handler(heightfields, active) and not binding.skips_output_handler(heightfields, {}) and not binding.skips_output_handler(HEGoOutputHandler.new(), active) and not binding.skips_output_handler(HEGoMeshOutput, active), "a terrain cook skips only output handlers that turn heightfields into terrain")

	# Hooks run in child order. The extension that stops a cook records its own reason;
	# the others are told through cook_failed, and nothing reaches Houdini.
	var plain := HEGoNode3D.new(); plain.name = "Plain"; plain.asset_name = "Sop/test"; scene.add_child(plain)
	var recorder := RecordingExtension.new(); plain.add_child(recorder)
	var refuser := RefusingExtension.new(); plain.add_child(refuser)
	await plain.cook()
	check(recorder.prepared == 1 and recorder.failed == ["refused for test"] and not plain.hego_did_last_cook_succeed(), "a refusing extension stops the cook and the others hear why")
	check(not HEGoAPI.get_singleton().is_session_active(), "no Houdini session was started")

	# The panel's input row shows the bridge's terrain options for a layer input.
	var row: Variant = load("res://addons/hego/ui/input_ui.tscn").instantiate()
	scene.add_child(row)
	row.setup("Input", PackedStringArray(["../Terrain/Generated"]), {}, host)
	var editors: Array = row.get_extension_editors()
	check(editors.size() == 1 and editors[0] is HEGoStrataInputSettings and editors[0].visible, "a terrain input row gets the bridge's settings editor")
	var settings: Dictionary = row.get_extension_settings()
	check(bool(settings.get(HEGoStrataInput.SETTINGS_MARKER, false)) and settings.get("terrain_mode") == "cumulative" and row.requires_explicit_cook(), "the row stores terrain settings and cooks only on request")

	scene.free()
	print("HEGO_EXTENSION_POINTS_TEST: %s (%d checks, %d failures)" % ["PASS" if failures == 0 else "FAIL", checks, failures])
	quit(0 if failures == 0 else 1)
