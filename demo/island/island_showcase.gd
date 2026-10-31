@tool
extends Node3D
## Bracken Isle: a five-stage layered island. Opening it loads the saved layers from the
## scene and its storage directory and never cooks; every Houdini cook is a button.
##
## The terrain's data lives at fixed paths under its storage directory (see StrataStorage):
## one file per hand layer, one per cooked channel, plus the region bake (manifest and region files).
## A cook overwrites its layer's files; nothing here creates dated folders or manifests.

signal showcase_ready
const PAD := Vector2(-1008.0, 592.0)
const TINT_LAYER := "TerrainTint"
const TINT_CHANNELS := ["terrain_tint_r", "terrain_tint_g", "terrain_tint_b", "terrain_ao"]
## The layer each erosion stage publishes into, as the HDA's target_layer_path parameter
## names it: the only binding between a host and its layer.
const STAGE_LAYERS := ["CoarseErosion", "DetailErosion"]
## Rough base cache written by scripts/houdini/build_island_hda.py.
const BASE_HEIGHT := "res://island/cache/base_height"

@onready var terrain: StrataTerrain3D = $Terrain
@onready var camera: HEGoIslandCamera = $Camera
@onready var hosts: Array = [$HDA/CoarseCook, $HDA/DetailCook]
@onready var tint_host: HEGoNode3D = get_node_or_null("HDA/TintCook")
@onready var material_host: HEGoNode3D = get_node_or_null("HDA/MaterialCook")
var renderer: StrataRenderer
var player: HEGoIslandPlayer
var collision: StrataCollision
var navigation: StrataNavigation
var ready_for_capture := false
var selected := 4
var _compiled: Dictionary = {}
var _full_compiled: Dictionary = {}
## The manifest the renderer was configured from, and the regions it holds as private copies
## (stage views and brush dabs edit copies, never the baked regions).
var _bound_data: StrataRuntimeData
var _private_regions: Dictionary = {}
var _contract: Dictionary = {}
var _tint_contract: Dictionary = {}
var _material_contract: Dictionary = {}
var _materials: Array[StrataMaterial] = []
var _busy := false
var _owned_session := false
var _message := "Loading saved island…"
var _status: Label
var _header_status: Label
var _layer_choice: OptionButton
var _ownership: CheckButton
var _sculpt: CheckButton
var _operation: OptionButton
var _radius: SpinBox
var _strength: SpinBox
var _buttons: Array[Button] = []
var _undo: Array = []
var _redo: Array = []
var _stroke_layer: StrataLayer
var _stroke_records: Array = []
var _last_point := Vector2(INF, INF)
var _flatten := NAN
var _saved_hands: Dictionary = {}
var _revealed: Dictionary = {}
var _cursor: MeshInstance3D
var _frame := 0
var _capture := ""
var _capture_view := "overview"
var _capture_ownership := false
var _captured := false
var _quit_frames := 0
var _status_elapsed := 0.0


func _ready() -> void:
	_contract = _read_json("res://island/hda/contract.json")
	_tint_contract = _read_json("res://island/hda/tint_contract.json")
	_material_contract = _read_json(HEGoIslandMaterials.CONTRACT)
	if not _material_contract.is_empty():
		var attached := HEGoIslandMaterials.attach(self, _material_contract)
		if not attached.ok: push_error(attached.message); return
		material_host = attached.host
		if terrain.editor_material_channels.is_empty(): terrain.editor_material_channels = HEGoIslandMaterials.channels()
	_configure_hosts()
	if Engine.is_editor_hint():
		terrain.preview_spacing = 32.0
		return
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-view="): _capture_view = argument.trim_prefix("--capture-view=")
		if argument == "--show-ownership": _capture_ownership = true
		if argument.begins_with("--capture="): _capture = argument.trim_prefix("--capture=")
		if argument.begins_with("--quit-after-frames="): _quit_frames = int(argument.trim_prefix("--quit-after-frames="))
	# Tests set this meta so a bake they trigger is published in memory only (a stack that
	# differs from the saved bake would otherwise rewrite runtime_data.res and regions/).
	if Engine.has_meta("island_no_save") or OS.get_cmdline_user_args().has("--no-save"): terrain.storage_directory = ""
	if OS.get_cmdline_user_args().has("--prepare-island"):
		await _prepare_island()
		return
	if OS.get_cmdline_user_args().has("--five-stage-check"):
		await _five_stage_check()
		return
	if OS.get_cmdline_user_args().has("--cook-materials"):
		await _cook_materials_headless()
		return
	var started := Time.get_ticks_usec()
	if _layers()[0].data.get_channel_names().is_empty():
		push_error("The saved island has no rough base; run scripts/run_terrain_island.py --prepare first")
		get_tree().quit(2)
		return
	_full_compiled = StrataProcedural.compile_heightfield(terrain, null, terrain.region_spacing)
	if not _full_compiled.get("ok", false):
		push_error("Island height compilation failed: " + str(_full_compiled)); get_tree().quit(2); return
	_compiled = _full_compiled
	_message = "Saved island loaded · no Houdini session started"
	if OS.get_cmdline_user_args().has("--verify"):
		var valid: bool = _compiled.image.get_size() == Vector2i(4097, 4097) and not HEGoAPI.get_singleton().is_session_active()
		print("ISLAND_REOPEN_%s load_ms=%.1f" % ["PASS" if valid else "FAIL", (Time.get_ticks_usec() - started) / 1000.0])
		get_tree().quit(0 if valid else 1)
		return
	if DisplayServer.get_name() == "headless":
		push_error("Use a real Forward+ display for the island; --prepare-island, --cook-materials, --five-stage-check and --verify are the headless modes.")
		get_tree().quit(2)
		return
	_materials = HEGoIslandMaterials.pool()
	renderer = StrataRenderer.new(); renderer.name = "IslandRenderer"; terrain.add_child(renderer)
	renderer.max_patches = 512; renderer.min_patch_size = 8.0; renderer.split_ratio = 1.8
	# The runtime renderer is built from the baked manifest (configure_runtime): heights, holes,
	# macro tint and the material ids/weights all come from regions composed from the stack.
	if not _bake_runtime(): get_tree().quit(2); return
	renderer.set_camera(camera); camera.renderer = renderer
	camera.teleport_to(Vector3(-3000.0, 2000.0, 3300.0), Vector3(-700.0, 80.0, -250.0))
	_remember_hands()
	_make_landmarks()
	_build_ui()
	_create_cursor()
	if not await _install_physics(): get_tree().quit(2); return
	if _capture_view == "platform":
		var h := renderer.sample_render_height(PAD)
		camera.teleport_to(Vector3(PAD.x - 82.0, h + 75.0, PAD.y + 110.0), Vector3(PAD.x + 4.0, h + 1.0, PAD.y))
	if _capture_view == "ground":
		await set_player_enabled(true)
		for index in range(90): await get_tree().physics_frame
		print("ISLAND_GROUND_CAPTURE grounded=", player.is_on_floor())
	if _capture_ownership:
		_ownership.button_pressed = true
		renderer.set_ownership_overlay(_layers()[selected])
	ready_for_capture = true
	showcase_ready.emit()
	print("ISLAND_SHOWCASE_READY resolution=%s load_ms=%.1f" % [_compiled.image.get_size(), (Time.get_ticks_usec() - started) / 1000.0])


static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path): return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _layers() -> Array[StrataLayer]: return terrain.get_layers()


## The HDA hosts' inputs follow the layer stack, so a renamed or reordered layer cannot
## leave a host reading the wrong stage. Each host's target is its HDA's target_layer_path
## parameter, set on every cook.
func _configure_hosts() -> void:
	var tint := terrain.get_node_or_null(TINT_LAYER) as StrataLayer
	if tint_host != null and tint != null and not _tint_contract.is_empty():
		# Cumulative FINAL height through the last stage below the tint layer,
		# resampled at 4 m so the 0.25 m BuildingFlatten lattice is never sent.
		var below := _layers()[tint.get_index() - 1] if tint.get_index() > 0 else null
		tint_host.asset_name = _tint_contract.operator
		tint_host.input_stash = [{"inputs": ["../../Terrain/" + String(below.name)] if below != null else [], "settings": {"terrain_mode": "cumulative", "terrain_channels": "height", "terrain_spacing": StrataMacro.DEFAULT_SPACING}}]
	# The material pass reads the final stack below it at the terrain's region spacing (1 m,
	# 4097 samples per side), so its fields are the lattice the regions are composed from.
	if material_host != null and not _material_contract.is_empty():
		var material_layer := terrain.get_node_or_null(HEGoIslandMaterials.LAYER) as StrataLayer
		var material_below := HEGoIslandMaterials.layer_below(terrain, material_layer) if material_layer != null else null
		if material_below != null:
			material_host.input_stash = [{"inputs": ["../../Terrain/" + String(material_below.name)], "settings": HEGoIslandStageMaterials.input_settings(4.0, {}, true, terrain.region_spacing)}]
	if _contract.is_empty(): return
	for index in range(2):
		var host: HEGoNode3D = hosts[index]
		host.asset_name = _contract.operator
		var rows: Array = [{"inputs": ["../../Terrain/" + ("RoughBase" if index == 0 else "ManualFine")], "settings": HEGoIslandStageMaterials.input_settings(8.0 if index == 0 else 4.0)}]
		if index == 1 and not _layers()[4].data.get_owned_rect(&"height").has_area() and not _layers()[4].data.get_owned_rect(&"constraint").has_area():
			rows.append({"inputs": [], "settings": {}})
		elif index == 1:
			rows.append({"inputs": ["../../Terrain/BuildingFlatten"], "settings": {"terrain_mode": "raw", "terrain_channels": "height,constraint", "terrain_compact_empty": true}})
		host.input_stash = rows


func _ensure_houdini() -> bool:
	var api := HEGoAPI.get_singleton()
	if api.is_session_active(): return true
	_owned_session = api.start_session(HEGoAPI.SESSION_NAMED_PIPE, "hego_island_%d" % OS.get_process_id())
	return _owned_session


# ─────────────────────────────────────────────
# Explicit cooks
# ─────────────────────────────────────────────

## Cooks erosion stage [param index] (0 coarse, 1 detail). The HDA's saved parameters are
## kept; [param changes] override some of them. The result lands in the stage's layer and
## its storage files; a failed cook leaves the previous result in place.
func _cook(index: int, changes: Dictionary = {}) -> bool:
	_configure_hosts()
	if not _ensure_houdini(): _set_message("Houdini session could not start; saved layers retained"); return false
	var host: HEGoNode3D = hosts[index]
	var asset := host.agent.asset(host.asset_name)
	var initialize := host.parm_stash.is_empty()
	if not await host.agent.instantiate(asset, host.parm_stash, true): return false
	var preserved_parameters: Dictionary = {}
	if not initialize:
		var previous := await HEGoNodeUtil.checked_task(self, asset.get_parms_dict())
		if not previous.ok: _set_message("Could not verify the saved HDA parameters before recook"); return false
		_collect_parms(previous.value, preserved_parameters)
	var preset_name := "coarse" if index == 0 else "detail"
	var parms: Dictionary = _contract.caller_presets[preset_name].duplicate(true) if initialize else {}
	if initialize:
		for key in parms.keys():
			if not _contract.parameters.has(key): parms.erase(key)
		parms.seed = 7; parms.erosion_strength = 1.0; parms.constraint_channel = "constraint"; parms.sea_level = 0.0
	parms.target_layer_path = "../../Terrain/" + String(STAGE_LAYERS[index])
	parms.merge(changes, true)
	if not await _apply_parameters(asset, parms, _contract.parameters, preserved_parameters): return false
	host.hego_notify_cook_inputs_changed()
	var target := terrain.get_node(String(STAGE_LAYERS[index])) as StrataLayer
	var before := target.procedural_revision
	var started := Time.get_ticks_usec()
	_set_message("Cooking Houdini %s erosion… the saved terrain remains visible" % preset_name)
	await host.cook()
	var ok := target.procedural_revision > before and not target.procedural_stale
	_set_message("%s erosion committed in %.1f s" % [preset_name.capitalize(), (Time.get_ticks_usec() - started) / 1000000.0] if ok else target.procedural_status)
	return ok


## Sets [param parms] on [param asset], then reads them back and refuses to cook when
## Houdini holds different values, or when a saved parameter not in [param parms] changed.
func _apply_parameters(asset: HEGoAssetNode, parms: Dictionary, parameters: Dictionary, preserved: Dictionary = {}) -> bool:
	# JSON numbers are floats. HAPI parameter setters are type-specific: sending
	# a toggle/int through the float setter can write the wrong parameter slot.
	for key in parms:
		if not parameters.has(key): _set_message("Unknown HDA parameter %s; cook refused" % key); return false
		var kind := String(parameters[key].get("type", ""))
		if kind in ["int", "toggle"]: parms[key] = int(parms[key])
		elif kind == "float": parms[key] = float(parms[key])
	var configured := await HEGoNodeUtil.checked_task(self, asset.set_parms_batch(parms))
	if not configured.ok: _set_message(configured.message); return false
	var values := await HEGoNodeUtil.checked_task(self, asset.get_parms_dict())
	if not values.ok: _set_message("Could not verify HDA parameter readback"); return false
	var actual: Dictionary = {}
	_collect_parms(values.value, actual, parameters)
	for key in parms:
		var matches: bool = actual.has(key) and (is_equal_approx(float(actual[key]), float(parms[key])) if parms[key] is float or parms[key] is int else actual[key] == parms[key])
		if not matches:
			_set_message("HDA parameter readback mismatch for %s: expected %s, got %s; cook refused" % [key, parms[key], actual.get(key)])
			return false
	for key in preserved:
		if parms.has(key): continue
		if not actual.has(key) or actual[key] != preserved[key]:
			_set_message("Saved HDA parameter %s changed unexpectedly; cook refused" % key)
			return false
	return true


func _collect_parms(value: Variant, result: Dictionary, parameters: Dictionary = {}) -> void:
	if parameters.is_empty(): parameters = _contract.parameters
	if value is Dictionary:
		if value.has("name") and value.has("values") and parameters.has(String(value.name)) and not value["values"].is_empty(): result[String(value.name)] = value["values"][0]
		for child in value.values(): _collect_parms(child, result, parameters)
	elif value is Array:
		for child in value: _collect_parms(child, result, parameters)


## Cooks only the mask-only tint stage; no height stage is cooked.
func _cook_tint(changes: Dictionary = {}) -> bool:
	var target := terrain.get_node_or_null(TINT_LAYER) as StrataLayer
	if tint_host == null or target == null or _tint_contract.is_empty(): _set_message("This level has no terrain tint producer"); return false
	_configure_hosts()
	if not _ensure_houdini(): _set_message("Houdini session could not start; saved layers retained"); return false
	var asset := tint_host.agent.asset(tint_host.asset_name)
	var initialize := tint_host.parm_stash.is_empty()
	if not await tint_host.agent.instantiate(asset, tint_host.parm_stash, true): return false
	var parameters: Dictionary = _tint_contract.parameters
	var parms := {}
	if initialize:
		for key in parameters:
			if parameters[key].has("default") and key != "target_layer_path": parms[key] = parameters[key].default
	parms.target_layer_path = "../../Terrain/" + TINT_LAYER
	parms.merge(changes, true)
	if not await _apply_parameters(asset, parms, parameters): return false
	tint_host.hego_notify_cook_inputs_changed()
	var before := target.procedural_revision
	var started := Time.get_ticks_usec()
	_set_message("Cooking terrain tint/AO in Houdini… height stages are not cooked")
	await tint_host.cook()
	var ok := target.procedural_revision > before and not target.procedural_stale
	_set_message("Terrain tint/AO committed in %.1f s" % ((Time.get_ticks_usec() - started) / 1000000.0) if ok else target.procedural_status)
	return ok


## Cooks only the material distribution at the terrain's region spacing. Nothing is packed:
## the editor preview and the bake compose the material maps from the committed fields (with
## any manual layers above them). A result that is not on the terrain lattice is marked stale.
func _cook_materials() -> bool:
	if _material_contract.is_empty() or material_host == null: _set_message("This level has no material producer"); return false
	if not _ensure_houdini(): _set_message("Houdini session could not start; saved materials retained"); return false
	var target := terrain.get_node_or_null(HEGoIslandMaterials.LAYER) as StrataLayer
	if target == null: _set_message("The scene has no MaterialDistribution layer"); return false
	_configure_hosts()
	var started := Time.get_ticks_usec()
	_set_message("Cooking material distribution in Houdini at %s m…" % String.num(terrain.region_spacing))
	var result := await HEGoIslandMaterials.cook_explicit(self, material_host, target, _material_contract)
	var ok: bool = result.get("ok", false) and not target.procedural_stale
	if ok:
		var checked := HEGoIslandMaterials.validate(target)
		if not checked.ok:
			target.mark_stale(String(checked.message))
			result = {"message": checked.message}
			ok = false
	_set_message("Materials committed in %.1f s" % ((Time.get_ticks_usec() - started) / 1000000.0) if ok else String(result.get("message", "Material cook failed")))
	return ok


# ─────────────────────────────────────────────
# Headless preparation
# ─────────────────────────────────────────────

## Builds the whole island from the rough base: both erosion stages, the hand edits that sit
## between them, the tint and the materials, then saves every layer to storage. Also checks
## that recooking the coarse stage leaves the hand layers untouched.
## Recooks every stage of the saved island in order and overwrites its storage files: the
## rough base from the cache, then coarse and detail erosion with their saved parameters,
## the tint and the material distribution, and finally the runtime bake. The hand layers
## are used as saved and never changed here.
func _prepare_island() -> void:
	_set_message("Recooking the island's stages from the saved layers")
	# Every hand-painted layer (ManualFine, BuildingFlatten, the top StrataLayer and any other
	# non-procedural layer) is saved as loaded; refuse to save if a cook changed one.
	var hands_before := _all_hand_hashes()
	if not _load_rough_base(): _finish_headless(false); return
	for index in [0, 1]:
		if not await _cook(index): _finish_headless(false); return
	if tint_host != null and not await _cook_tint(): _finish_headless(false); return
	if not await _cook_materials(): _finish_headless(false); return
	_full_compiled = StrataProcedural.compile_heightfield(terrain, null, terrain.region_spacing)
	if not _full_compiled.get("ok", false): _finish_headless(false); return
	var hands_after := _all_hand_hashes()
	for name in hands_before:
		if name != String(_layers()[0].name) and hands_after.get(name) != hands_before[name]:
			push_error("Hand layer %s changed during the recook; nothing was saved" % name); _finish_headless(false); return
	if not await _install_runtime(): _finish_headless(false); return
	# Saves the stage channels, the hand layers as loaded, runtime_data.res and regions/.
	var saved := StrataStorage.save_all(terrain)
	if not saved.ok: push_error(saved.message)
	else: print("ISLAND_PREPARED ", saved.message)
	_finish_headless(saved.ok)


## ARTIFICIAL FIXTURE, never saved: scripted brush strokes stand in for hand edits so the
## five-stage preservation contract can be checked end to end in a headless run. Cooks
## coarse, applies the strokes, cooks detail, recooks coarse with other parameters and
## checks that both hand layers survive byte for byte while the detail stage goes stale.
## The saved island is left untouched; the process exits without writing storage.
func _five_stage_check() -> void:
	_set_message("Five-stage fixture check (nothing is saved)")
	# Commits write their channel files whenever the terrain has a storage directory, so
	# the fixture detaches storage first; the layers are already loaded in memory.
	terrain.storage_directory = ""
	if not _load_rough_base(): _finish_headless(false); return
	if not await _cook(0): _finish_headless(false); return
	_make_hand_edits()
	if not await _cook(1): _finish_headless(false); return
	var fine_hash := _hand_hash(_layers()[2]); var building_hash := _hand_hash(_layers()[4])
	if not await _cook(0, {"seed": 19, "erosion_strength": 1.18}): _finish_headless(false); return
	await get_tree().create_timer(0.35).timeout
	var downstream_stale := _layers()[3].procedural_stale
	if not await _cook(1): _finish_headless(false); return
	var preserved := fine_hash == _hand_hash(_layers()[2]) and building_hash == _hand_hash(_layers()[4])
	var ok := preserved and downstream_stale and not _layers()[3].procedural_stale
	if not ok: push_error("Five-stage preservation check failed: hands preserved=%s, detail went stale=%s" % [preserved, downstream_stale])
	print("ISLAND_FIVE_STAGE_%s" % ("PASS" if ok else "FAIL"))
	_finish_headless(ok)


## Cooks only the materials against the saved layers, then rebakes and saves the regions.
func _cook_materials_headless() -> void:
	if not await _cook_materials(): _finish_headless(false); return
	_full_compiled = StrataProcedural.compile_heightfield(terrain, null, terrain.region_spacing)
	if not _full_compiled.get("ok", false): _finish_headless(false); return
	if not await _install_runtime(): _finish_headless(false); return
	var saved := StrataStorage.save_all(terrain)
	if not saved.ok: push_error(saved.message)
	else: print("ISLAND_MATERIALS_COOKED ", saved.message)
	_finish_headless(saved.ok)


func _finish_headless(ok: bool) -> void:
	if _owned_session and HEGoAPI.get_singleton().is_session_active(): HEGoAPI.get_singleton().stop_session(); _owned_session = false
	get_tree().quit(0 if ok else 1)


func _load_rough_base() -> bool:
	var metadata := _read_json(BASE_HEIGHT + ".json")
	if metadata.is_empty(): push_error("No rough base cache at " + BASE_HEIGHT); return false
	var bytes := FileAccess.get_file_as_bytes(BASE_HEIGHT + ".rf32")
	if bytes.size() != int(metadata.width) * int(metadata.height) * 4: push_error("Rough base cache has the wrong size"); return false
	var image := Image.create_from_data(metadata.width, metadata.height, false, Image.FORMAT_RF, bytes)
	var layer := _layers()[0]
	layer.data.sample_spacing = float(metadata.sample_spacing)
	layer.data.grid_origin = Vector2(metadata.sample_origin[0], metadata.sample_origin[2])
	return layer.data.replace_dense(&"height", Vector2i.ZERO, image)


## Fixture strokes for [method _five_stage_check]; not an authoring tool and never saved.
func _make_hand_edits() -> void:
	var fine := _layers()[2]; fine.data.sample_spacing = 2.0; fine.set_composition(&"height", StrataLayer.Composition.ADD)
	StrataBrush.apply_brush(fine, PAD + Vector2(170.0, -70.0), 85.0, 18.0, "raise")
	StrataBrush.apply_brush(fine, PAD + Vector2(220.0, -30.0), 38.0, 8.0, "lower")
	fine.data.set_sample(&"height", Vector2i(roundi(PAD.x / 2.0) + 100, roundi(PAD.y / 2.0)), 0.0)
	var building := _layers()[4]; building.data.sample_spacing = 0.25
	var height := terrain.sample_height(PAD, fine) + 1.0
	StrataBrush.apply_brush(building, PAD, 30.0, 8.0, "flatten", &"height", height)
	var rect := building.data.get_owned_rect(&"height")
	var read := building.data.read_dense(&"height", rect.position, rect.size)
	var constraint := Image.create(rect.size.x, rect.size.y, false, Image.FORMAT_RF); constraint.fill(Color(1.0, 0.0, 0.0, 1.0))
	building.data.replace_dense(&"constraint", rect.position, constraint, read.ownership)
	var hole := Image.create(17, 17, false, Image.FORMAT_RF); hole.fill(Color(1.0, 0.0, 0.0, 1.0))
	var hole_position := Vector2i(roundi((PAD.x + 48.0) / 0.25), roundi((PAD.y + 8.0) / 0.25))
	building.data.replace_dense(&"hole", hole_position, hole)
	var exclusion := Image.create(113, 81, false, Image.FORMAT_RF); exclusion.fill(Color(1.0, 0.0, 0.0, 1.0))
	building.data.replace_dense(&"nav_exclusion", Vector2i(roundi((PAD.x - 14.0) / 0.25), roundi((PAD.y - 10.0) / 0.25)), exclusion)


func _all_hand_hashes() -> Dictionary:
	var hashes := {}
	for layer in _layers():
		if not layer.procedural: hashes[String(layer.name)] = _hand_hash(layer)
	return hashes


func _hand_hash(layer: StrataLayer) -> String:
	var context := HashingContext.new(); context.start(HashingContext.HASH_SHA256)
	context.update(var_to_bytes(layer.data.snapshot()))
	return context.finish().hex_encode()


func _remember_hands() -> void:
	for index in [2, 4]: _saved_hands[index] = _layers()[index].data.snapshot()


# ─────────────────────────────────────────────
# Runtime
# ─────────────────────────────────────────────

## Bakes the complete stack into region data (heights, holes, macro tint, material ids and
## weights composed from the stack at [member StrataTerrain3D.region_spacing]) and, when a
## renderer exists, builds it from that manifest with configure_runtime. A bake loaded from
## storage that is still current is reused rather than rebuilt.
func _bake_runtime() -> bool:
	var spacing := terrain.region_spacing
	if terrain.runtime_data == null or terrain.is_runtime_bake_stale():
		if not _full_compiled.has("token"):
			_full_compiled = StrataProcedural.compile_heightfield(terrain, null, spacing)
		var masks := StrataProcedural.compile_cell_masks(terrain, null, spacing)
		if not masks.get("ok", false): push_error("Island mask compilation failed: " + str(masks)); return false
		var baked := StrataBake.bake(terrain, {"compiled": _full_compiled, "spacing": spacing, "allow_stale_procedural": true, "cell_masks": masks})
		if not baked.get("ok", false): push_error("Island runtime bake failed: " + str(baked)); return false
	if renderer != null and not _bind_renderer(): return false
	return true


## Builds the renderer from the terrain's manifest, or restores it from a stage view.
func _bind_renderer() -> bool:
	if _bound_data == terrain.runtime_data and renderer.region_spec().size() > 0:
		for xy in _private_regions: renderer.update_region(xy, terrain.runtime_data.get_region(xy))
		_private_regions = {}
		return true
	if not renderer.configure_runtime(terrain, terrain.runtime_data, _materials):
		push_error("The renderer rejected the baked island regions")
		return false
	_bound_data = terrain.runtime_data
	_private_regions = {}
	return true


## Collision, navigation and the player, from the published manifest.
func _install_physics() -> bool:
	if collision == null:
		collision = StrataCollision.new(); collision.name = "IslandCollision"; terrain.add_child(collision)
	var replacement := collision.replace_data(terrain.runtime_data)
	if not replacement.get("ok", false): push_error("Collision rebake rejected; previous shapes retained: " + str(replacement)); return false
	var region := Rect2(PAD - Vector2(128.0, 128.0), Vector2(256.0, 256.0))
	var prepared := collision.prepare_region(region)
	if navigation == null:
		navigation = StrataNavigation.new(); navigation.name = "IslandNavigation"; terrain.add_child(navigation)
	navigation.data = terrain.runtime_data
	# A selected-area navigation bake is deliberate: never bake the whole 4 km
	# into Recast merely to open the level.
	var nav_result := navigation.bake_region(Rect2(PAD - Vector2(64.0, 64.0), Vector2(128.0, 128.0)))
	if nav_result.get("pending", false): nav_result = await navigation.bake_finished
	if not prepared.get("ok", false) or not nav_result.get("ok", false):
		push_error("Island runtime region preparation failed: collision %s, navigation %s" % [prepared, nav_result])
		return false
	if player == null and DisplayServer.get_name() != "headless":
		player = HEGoIslandPlayer.new(); player.name = "Player"; player.terrain = terrain; player.collision = collision; player.player_camera = camera; player.spawn_local_xz = PAD; add_child(player)
	await get_tree().process_frame
	return true


## Bakes, drives the renderer (if any) and installs collision and navigation.
func _install_runtime() -> bool:
	if not _bake_runtime(): return false
	return await _install_physics()


## A private copy of a renderer region, installed in place of the baked one, so a stage view
## or a brush dab never edits the manifest's regions.
func _private_region(xy: Vector2i) -> StrataRegionData:
	if _private_regions.has(xy): return renderer.get_region(xy)
	var copy: StrataRegionData = terrain.runtime_data.get_region(xy).duplicate()
	copy.maps = terrain.runtime_data.get_region(xy).maps.duplicate(true)
	if not renderer.update_region(xy, copy): return null
	_private_regions[xy] = true
	return copy


## Shows the cumulative terrain through [param through]: heights and holes composed through
## that layer replace the baked ones in private region copies (materials and tint stay those
## of the final stack, as before). A null layer restores the baked regions.
func _show_stage(through: StrataLayer) -> bool:
	if through == null: return _bind_renderer()
	var spec := renderer.region_spec()
	var grid := StrataRegions.grid_size(spec)
	var started := Time.get_ticks_msec()
	for y in range(grid.y):
		for x in range(grid.x):
			var xy := Vector2i(x, y)
			if _private_region(xy) == null: return false
			for map in [StrataRegions.MAP_HEIGHT, StrataRegions.MAP_HOLES]:
				if not spec.maps.has(map): continue
				var window := StrataRegions.map_window(spec, xy, spec.maps[map])
				var composed := StrataRegionCompose.compose_map(terrain, through, map, window, spec)
				if not composed.get("ok", false) or not renderer.update_region_window(xy, map, composed.image, Vector2i.ZERO):
					push_error("Stage view failed for region %s %s: %s" % [xy, map, composed.get("message", "renderer rejected the window")]); return false
		if Time.get_ticks_msec() - started > 8: await get_tree().process_frame; started = Time.get_ticks_msec()
	return true


## Writes a freshly compiled height patch (lattice at the region spacing) into the regions
## it touches, through private copies.
func _patch_regions(patch: Dictionary) -> bool:
	var spec := renderer.region_spec()
	var image: Image = patch.get("image")
	if image == null or not patch.get("ok", false): return false
	var bounds: Rect2 = patch.bounds
	var spacing: float = spec.spacing
	var first := Vector2i(((bounds.position - spec.bounds.position) / spacing).round())
	var description: Dictionary = spec.maps[StrataRegions.MAP_HEIGHT]
	for xy in StrataRegions.regions_touching(spec, bounds, description):
		if _private_region(xy) == null: return false
		# Region texel (u, v) is terrain sample (xy * cells + (u, v) - apron).
		var offset: Vector2i = xy * int(spec.cells) - Vector2i.ONE * int(description.apron)
		var size := StrataRegions.map_size(int(spec.cells), description)
		var low := Vector2i(maxi(first.x - offset.x, 0), maxi(first.y - offset.y, 0))
		var high := Vector2i(mini(first.x + image.get_width() - offset.x, size.x), mini(first.y + image.get_height() - offset.y, size.y))
		if high.x <= low.x or high.y <= low.y: continue
		var window := image.get_region(Rect2i(low + offset - first, high - low))
		if not renderer.update_region_window(xy, StrataRegions.MAP_HEIGHT, window, low): return false
	return true


# ─────────────────────────────────────────────
# Interface
# ─────────────────────────────────────────────

func _build_ui() -> void:
	var canvas := CanvasLayer.new(); canvas.name = "Interface"; add_child(canvas)
	var panel := PanelContainer.new(); panel.position = Vector2(22.0, 22.0); panel.size = Vector2(382.0, get_viewport().get_visible_rect().size.y - 44.0)
	get_viewport().size_changed.connect(func(): panel.size.y = maxf(220.0, get_viewport().get_visible_rect().size.y - 44.0))
	var style := StyleBoxFlat.new(); style.bg_color = Color(0.035, 0.065, 0.07, 0.95); style.set_corner_radius_all(12); style.set_content_margin_all(18)
	panel.add_theme_stylebox_override("panel", style); canvas.add_child(panel)
	var scroll := ScrollContainer.new(); scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED; panel.add_child(scroll)
	var box := VBoxContainer.new(); box.custom_minimum_size.x = 338.0; box.size_flags_horizontal = Control.SIZE_EXPAND_FILL; box.add_theme_constant_override("separation", 8); scroll.add_child(box)
	_label(box, "BRACKEN ISLE", 28)
	_label(box, "4 × 4 km · real Houdini erosion\n%d ambientCG materials" % _materials.size(), 14)
	_header_status = _label(box, "", 12); _header_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(HSeparator.new())
	_layer_choice = OptionButton.new()
	for name in ["1  Rough base · 8 m", "2  Coarse erosion · HDA", "3  Manual fine · 2 m Add", "4  Detailed erosion · HDA", "5  Building flatten · 0.25 m Replace"]: _layer_choice.add_item(name)
	_layer_choice.select(selected); _layer_choice.item_selected.connect(_select_layer); box.add_child(_layer_choice)
	_ownership = CheckButton.new(); _ownership.text = "Show selected ownership"; _ownership.toggled.connect(func(value: bool): renderer.set_ownership_overlay(_layers()[selected], &"height", value)); box.add_child(_ownership)
	_sculpt = CheckButton.new(); _sculpt.text = "Sculpt selected manual layer"; box.add_child(_sculpt)
	_operation = OptionButton.new()
	for name in ["Raise", "Lower", "Flatten", "Smooth", "Erase"]: _operation.add_item(name)
	box.add_child(_operation)
	_radius = _number(box, "Brush radius / m", 1.0, StrataBrush.MAX_RADIUS_METERS, 12.0)
	_radius.custom_minimum_size.x = 112.0
	_radius.tooltip_text = "Type up to 4096 m. The 65,536-sample dab budget still applies on the selected grid; an oversized dab reports its radius and spacing limits. Select a coarse manual layer for broad mountains, or add one in the editor with spacing chosen while empty. Populated layers lock their grid."
	_strength = _number(box, "Brush strength", 0.05, 20.0, 2.0)
	var row := HBoxContainer.new(); box.add_child(row); _button(row, "Undo", _undo_stroke); _button(row, "Redo", _redo_stroke)
	box.add_child(HSeparator.new())
	_button(box, "Cook coarse erosion", func(): _recook(0))
	_button(box, "Cook detail erosion", func(): _recook(1))
	if tint_host != null: _button(box, "Cook terrain tint / AO", _recook_tint)
	if material_host != null: _button(box, "Cook material distribution", _recook_materials)
	_button(box, "Reveal / restore building ownership", _reveal_building)
	_button(box, "Reset to saved hand edits", _reset_hands)
	_button(box, "Save layers to storage", _save_level)
	_button(box, "Walk the building platform", func(): set_player_enabled(player == null or not player.is_player_enabled()))
	_button(box, "Overview camera", _overview)
	_status = _label(box, "", 13); _status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(HSeparator.new())
	_label(box, "Right drag: look · WASD: move\nQ / E: descend / rise · Shift: fast\nWheel: speed · Tab: leave player\nEdits never trigger a Houdini cook.", 13)
	_update_status()


func _label(parent: Node, text: String, size: int) -> Label:
	var label := Label.new(); label.text = text; label.add_theme_font_size_override("font_size", size); parent.add_child(label); return label


func _number(parent: Node, text: String, minimum: float, maximum: float, value: float) -> SpinBox:
	var row := HBoxContainer.new(); parent.add_child(row); var label := _label(row, text, 13); label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var spin := SpinBox.new(); spin.min_value = minimum; spin.max_value = maximum; spin.step = 0.25; spin.value = value; row.add_child(spin); return spin


func _button(parent: Node, text: String, action: Callable) -> Button:
	var button := Button.new(); button.text = text; button.size_flags_horizontal = Control.SIZE_EXPAND_FILL; button.pressed.connect(action); parent.add_child(button); _buttons.append(button); return button


func _set_message(text: String) -> void:
	_message = text; print("ISLAND: ", text); _update_status()


func _update_status() -> void:
	if _header_status != null:
		_header_status.text = "Explicit cooks only\nCoarse: %s · Detail: %s" % ["stale" if _layers()[1].procedural_stale else "current", "stale" if _layers()[3].procedural_stale else "current"]
	if _status == null: return
	var stats := renderer.get_stats() if renderer != null else {}
	_status.text = "%s\n\nCoarse: %s\nDetail: %s\n\n%s patches · %s triangles\n1 m compiled field: 4097 × 4097" % [_message, _layers()[1].procedural_status, _layers()[3].procedural_status, stats.get("patches", 0), stats.get("triangles", 0)]


func _set_busy(value: bool) -> void:
	_busy = value
	for button in _buttons: button.disabled = value
	if _layer_choice != null: _layer_choice.disabled = value


func _select_layer(index: int) -> void:
	if _busy: return
	set_player_enabled(false)
	selected = index
	_set_busy(true); _set_message("Composing the selected cumulative stage…")
	await get_tree().process_frame
	# Stage 5 is the complete stack (what is baked); earlier stages are views through the layer.
	var ok := await _show_stage(null if selected >= 4 else _layers()[selected])
	if _ownership.button_pressed: renderer.set_ownership_overlay(_layers()[selected])
	_set_message("Viewing cumulative terrain through stage %d" % (selected + 1) if ok else "The stage view could not be composed"); _set_busy(false)


func _recook(index: int) -> void:
	if _busy: return
	_set_busy(true)
	if await _cook(index):
		await _refresh_full()
	_set_busy(false)


func _recook_tint() -> void:
	if _busy: return
	_set_busy(true)
	if await _cook_tint():
		await _refresh_full()
	_set_busy(false)


func _recook_materials() -> void:
	if _busy: return
	_set_busy(true)
	if await _cook_materials():
		await _refresh_full()
	_set_busy(false)


func _refresh_full() -> void:
	_set_message("Compiling 4097² runtime heightfield…")
	await get_tree().process_frame
	_full_compiled = StrataProcedural.compile_heightfield(terrain, null, terrain.region_spacing)
	_compiled = _full_compiled; selected = 4
	if _layer_choice != null: _layer_choice.select(4)
	await _install_runtime()
	if _ownership != null and _ownership.button_pressed: renderer.set_ownership_overlay(_layers()[selected])
	_set_message("Compiled terrain updated; hand ownership remains independent")


func _reveal_building() -> void:
	if _busy: return
	var layer := _layers()[4]
	if _revealed.is_empty():
		_revealed = layer.data.snapshot()
		var empty := layer.data.snapshot(); empty.channels = {}; layer.data.restore(empty)
		_set_message("Building ownership erased: the lower detail surface is revealed")
	else:
		layer.data.restore(_revealed); _revealed = {}
		_set_message("Building values and ownership restored exactly")
	_set_busy(true); await _refresh_full(); _set_busy(false)


func _reset_hands() -> void:
	if _busy: return
	for index in _saved_hands: _layers()[index].data.restore(_saved_hands[index])
	_revealed = {}; _undo.clear(); _redo.clear(); _set_busy(true); await _refresh_full(); _set_busy(false)


func _save_level() -> void:
	if _busy: return
	_set_busy(true); await _refresh_full()
	var saved := StrataStorage.save_all(terrain)
	if saved.ok: _remember_hands()
	_set_message(saved.message); _set_busy(false)


func _create_cursor() -> void:
	_cursor = MeshInstance3D.new(); var ring := TorusMesh.new(); ring.inner_radius = 0.96; ring.outer_radius = 1.0; ring.rings = 48; _cursor.mesh = ring
	var material := StandardMaterial3D.new(); material.albedo_color = Color("f4be65"); material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED; material.no_depth_test = true; _cursor.material_override = material
	_cursor.visible = false; add_child(_cursor)


func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint() or not ready_for_capture: return
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_TAB and player != null and player.is_player_enabled(): set_player_enabled(false)
		if event.ctrl_pressed and event.keycode == KEY_Z:
			if event.shift_pressed: _redo_stroke()
			else: _undo_stroke()
	if _busy or not _sculpt.button_pressed or _layers()[selected].procedural: return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if not event.pressed: _finish_stroke(); return
		var hit := renderer.raycast_heightfield(camera.project_ray_origin(event.position), camera.project_ray_normal(event.position))
		if not hit.is_empty():
			_stroke_layer = _layers()[selected]; _stroke_records = []; _last_point = Vector2(INF, INF)
			_flatten = terrain.sample_height(hit.local_position, _stroke_layer); _dab(hit.local_position)
	if event is InputEventMouseMotion:
		var hit := renderer.raycast_heightfield(camera.project_ray_origin(event.position), camera.project_ray_normal(event.position))
		_cursor.visible = not hit.is_empty()
		if not hit.is_empty():
			_cursor.position = hit.position + Vector3.UP * 0.25; _cursor.scale = Vector3(_radius.value, 1.0, _radius.value)
			if _stroke_layer != null and event.button_mask & MOUSE_BUTTON_MASK_LEFT: _dab(hit.local_position)


func _input(event: InputEvent) -> void:
	if not Engine.is_editor_hint() and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed: _finish_stroke()


func _dab(point: Vector2) -> void:
	if _last_point.is_finite() and _last_point.distance_to(point) < _radius.value * 0.18: return
	_last_point = point
	var limit_message := StrataBrush.sample_limit_message(_stroke_layer, point, _radius.value)
	if not limit_message.is_empty():
		_set_message(limit_message)
		return
	var grid := StrataBrush.candidate_grid(_stroke_layer, point, _radius.value)
	if grid.is_empty(): return
	var record := StrataBrush.begin_record(_stroke_layer.data, &"height", grid)
	var operation: String = ["raise", "lower", "flatten", "smooth", "erase"][_operation.selected]
	var touched := StrataBrush.apply_brush(_stroke_layer, point, _radius.value, _strength.value, operation, &"height", _flatten)
	if touched == 0:
		_set_message("Brush changed no samples; check layer, strength and owned footprint")
		return
	if StrataBrush.finish_record(_stroke_layer.data, record): _stroke_records.append(record)
	var margin := _radius.value + maxf(3.0, _stroke_layer.data.sample_spacing * 2.0)
	var minimum := (point - Vector2.ONE * margin).floor().max(terrain.base_bounds.position)
	var maximum := (point + Vector2.ONE * margin).ceil().min(terrain.base_bounds.end)
	var patch := StrataProcedural.compile_heightfield(terrain, _stroke_layer, terrain.region_spacing, {"bounds": Rect2(minimum, maximum - minimum)})
	_patch_regions(patch)
	if _ownership.button_pressed: renderer.set_ownership_overlay(_stroke_layer)


func _finish_stroke() -> void:
	if _stroke_layer == null: return
	if not _stroke_records.is_empty(): _undo.append({"layer": _stroke_layer, "records": _stroke_records}); _redo.clear()
	var changed := not _stroke_records.is_empty()
	_stroke_layer = null; _stroke_records = []
	if changed: _set_message("Stroke committed, including every touched sample's ownership")


func _undo_stroke() -> void:
	_finish_stroke()
	if _undo.is_empty() or _busy: return
	var action: Dictionary = _undo.pop_back(); StrataBrush.restore_records(action.layer.data, action.records, "before"); _redo.append(action)
	_set_busy(true); await _refresh_full(); _set_busy(false)


func _redo_stroke() -> void:
	if _redo.is_empty() or _busy: return
	var action: Dictionary = _redo.pop_back(); StrataBrush.restore_records(action.layer.data, action.records, "after"); _undo.append(action)
	_set_busy(true); await _refresh_full(); _set_busy(false)


func _overview() -> void:
	set_player_enabled(false); camera.teleport_to(Vector3(-3000.0, 2000.0, 3300.0), Vector3(-700.0, 80.0, -250.0))


func set_player_enabled(value: bool) -> void:
	if value and selected != 4:
		_set_message("Select stage 5 before walking: collision uses the complete compiled stack")
		return
	if value and terrain.is_runtime_bake_stale():
		_set_busy(true); _set_message("Updating compiled collision before walking…")
		await _refresh_full()
		_set_busy(false)
		if terrain.is_runtime_bake_stale(): _set_message("Walking unavailable until a valid full runtime bake is ready"); return
	if player != null: player.set_player_enabled(value)
	elif value:
		camera.ground_mode = true; camera.speed = 8.0; var h := renderer.sample_render_height(PAD)
		camera.teleport_to(Vector3(PAD.x, h + 2.0, PAD.y + 23.0), Vector3(PAD.x, h + 2.0, PAD.y))
	else: camera.ground_mode = false


func set_benchmark_time(seconds: float) -> void:
	if camera == null or renderer == null: return
	camera.input_enabled = false
	var angle := seconds * 0.025 + 2.7
	var point := PAD + Vector2(cos(angle), sin(angle)) * 110.0
	var height := renderer.sample_render_height(point) + 12.0
	camera.teleport_to(terrain.to_global(Vector3(point.x, height, point.y)), terrain.to_global(Vector3(PAD.x, renderer.sample_render_height(PAD) + 4.0, PAD.y)))


## The authoring scene the showcase inherits already carries the landmarks; this builds
## them only for a scene that has none.
func _make_landmarks() -> void:
	if has_node("BuildingLandmarks"): return
	var root := Node3D.new(); root.name = "BuildingLandmarks"; add_child(root)
	var height := terrain.sample_height(PAD)
	for offset in [-8.0, 8.0]:
		var cabin := MeshInstance3D.new(); var mesh := BoxMesh.new(); mesh.size = Vector3(11.0, 6.0, 8.0); cabin.mesh = mesh
		var wood := StandardMaterial3D.new(); wood.albedo_color = Color("574a36"); wood.roughness = 0.9; cabin.material_override = wood
		cabin.position = Vector3(PAD.x + offset, height + 3.0, PAD.y); root.add_child(cabin)
		var roof := MeshInstance3D.new(); var roof_mesh := PrismMesh.new(); roof_mesh.size = Vector3(13.0, 4.0, 10.0); roof.mesh = roof_mesh
		var slate := StandardMaterial3D.new(); slate.albedo_color = Color("263a3d"); slate.roughness = 0.8; roof.material_override = slate
		roof.position = cabin.position + Vector3.UP * 5.0; root.add_child(roof)


func _process(delta: float) -> void:
	if Engine.is_editor_hint(): return
	_status_elapsed += delta
	if _status_elapsed > 0.4: _status_elapsed = 0.0; _update_status()
	if not ready_for_capture: return
	_frame += 1
	if not _captured and not _capture.is_empty() and _frame >= (_quit_frames if _quit_frames > 0 else 60):
		_captured = true
		await RenderingServer.frame_post_draw
		var error := get_viewport().get_texture().get_image().save_png(_capture)
		if error != OK: push_error("Island capture failed: " + error_string(error))
	if _quit_frames > 0 and _frame >= _quit_frames: get_tree().quit()


func _exit_tree() -> void:
	if not Engine.is_editor_hint() and _owned_session and HEGoAPI.get_singleton().is_session_active(): HEGoAPI.get_singleton().stop_session()
