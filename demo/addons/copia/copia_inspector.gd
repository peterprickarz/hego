@tool
extends EditorInspectorPlugin
## Adds a small panel above the properties of a CopiaStore3D: totals, the sets with a Remove
## button each, and the buttons that build. It reads the sets index through the store's own calls
## ([method CopiaStore3D.set_summary]) and never opens a per-cell file; the stale cells are
## computed only when a button asks for them. "Build stale cells" and "Rebuild all" run on the
## store's background build thread ([method CopiaStore3D.build_async]), so the editor keeps
## working: the buttons are disabled and the status line shows the elapsed time while a build
## runs (one an object change started too), and the build's counts when it is done. Removing a
## set and Refresh run on the main thread.

const StoreScript := preload("res://addons/copia/copia_store_3d.gd")


func _can_handle(object: Object) -> bool:
	return is_instance_of(object, StoreScript)


func _parse_begin(object: Object) -> void:
	add_custom_control(make_panel(object))


## The panel for [param store]. Public so a script can create it without the editor.
static func make_panel(store: Node) -> Control:
	var panel := _Panel.new()
	panel.store = store
	return panel


class _Panel:
	extends VBoxContainer

	var store: Node
	var _totals: Label
	var _sets: VBoxContainer
	var _build_stale: Button
	var _rebuild: Button
	var _refresh: Button
	var _status: Label
	var _confirm: ConfirmationDialog
	var _pending_set := ""
	var _busy := false
	var _stale_text := "stale cells: press Refresh"
	var _build_label := ""  # what the running background build does
	var _build_started_usec := 0

	func _init() -> void:
		_totals = Label.new()
		add_child(_totals)
		_sets = VBoxContainer.new()
		add_child(_sets)
		var buttons := HBoxContainer.new()
		add_child(buttons)
		_build_stale = _button("Build stale cells", "Builds the cells whose built files differ from their inputs, in the background.", buttons)
		_rebuild = _button("Rebuild all", "Builds every cell again, whether or not its inputs changed, in the background.", buttons)
		_refresh = _button("Refresh", "Reads the counts again and finds the stale cells.", buttons)
		_build_stale.pressed.connect(_on_build_stale)
		_rebuild.pressed.connect(_on_rebuild)
		_refresh.pressed.connect(_on_refresh)
		_status = Label.new()
		_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		add_child(_status)
		_confirm = ConfirmationDialog.new()
		_confirm.confirmed.connect(_on_remove_confirmed)
		add_child(_confirm)
		add_child(HSeparator.new())

	func _ready() -> void:
		if is_instance_valid(store):
			store.build_started.connect(_on_build_started)
			store.build_finished.connect(_on_build_finished)
			if store.is_building():
				_on_build_started()
		_update_counts()

	func _exit_tree() -> void:
		if is_instance_valid(store):
			if store.build_started.is_connected(_on_build_started):
				store.build_started.disconnect(_on_build_started)
			if store.build_finished.is_connected(_on_build_finished):
				store.build_finished.disconnect(_on_build_finished)

	func _process(_delta: float) -> void:
		if _build_started_usec != 0:
			_status.text = "%s... %.1f s" % [_build_label, (Time.get_ticks_usec() - _build_started_usec) / 1e6]

	func _button(text: String, tooltip: String, parent: Control) -> Button:
		var button := Button.new()
		button.text = text
		button.tooltip_text = tooltip
		parent.add_child(button)
		return button

	func _valid() -> bool:
		return is_instance_valid(store) and not String(store.data_directory).is_empty()

	func _building() -> bool:
		return is_instance_valid(store) and store.is_building()

	# Totals and the set list from the sets index (no per-cell file is opened).
	func _update_counts() -> void:
		for child in _sets.get_children():
			_sets.remove_child(child)
			child.queue_free()
		if not _valid():
			_totals.text = "No data directory is set."
			_set_buttons(true)
			return
		var summary: Array = store.set_summary()
		var files := 0
		var instances := 0
		for entry in summary:
			files += int(entry.cells)
			instances += int(entry.instances)
			_add_set_row(entry.set, entry.cells, entry.instances)
		_totals.text = "%d sets, %d set files, %s instances, %s" % [summary.size(), files, _group(instances), _stale_text]
		_set_buttons(true)

	func _add_set_row(set_name: String, cell_count: int, instance_count: int) -> void:
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = "%s: %d cells, %s instances" % [set_name, cell_count, _group(instance_count)]
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		var remove := Button.new()
		remove.text = "Remove"
		remove.tooltip_text = "Deletes the set's files and rebuilds the cells it had content in."
		remove.pressed.connect(_ask_remove.bind(set_name))
		row.add_child(remove)
		_sets.add_child(row)

	static func _group(value: int) -> String:
		var text := str(value)
		var out := ""
		for i in text.length():
			if i > 0 and (text.length() - i) % 3 == 0:
				out += ","
			out += text[i]
		return out

	# Buttons are usable when asked, the store has a data directory and no build runs.
	func _set_buttons(enabled: bool) -> void:
		var can := enabled and _valid() and not _building() and not _busy
		_build_stale.disabled = not can
		_rebuild.disabled = not can
		_refresh.disabled = not can
		for row in _sets.get_children():
			row.get_child(1).disabled = not can

	func _ask_remove(set_name: String) -> void:
		if _busy or _building():
			return
		_pending_set = set_name
		_confirm.title = "Remove set"
		_confirm.dialog_text = "Delete set \"%s\" and rebuild the cells it had content in? This cannot be undone." % set_name
		_confirm.popup_centered()

	func _on_remove_confirmed() -> void:
		var set_name := _pending_set
		_pending_set = ""
		await _run("Removing set %s and rebuilding its cells" % set_name, func() -> String:
			var result: Dictionary = store.remove_set(set_name)
			return "removed set %s (%d cells). %s" % [set_name, result.cells.size(), build_text(result.build)])

	func _on_build_stale() -> void:
		_start_build("Building stale cells", [], false)

	func _on_rebuild() -> void:
		_start_build("Rebuilding every cell", store.rebuild_all_cells() if _valid() else [], true)

	func _start_build(what: String, cells: Array, force: bool) -> void:
		if _busy or _building() or not _valid():
			return
		_stale_text = "stale cells: press Refresh"  # a build changes them; Refresh sets it again
		_build_label = what
		if not store.build_async(cells, force):
			_build_label = ""
			_status.text = "%s: not started (a build is running, or there is no data directory)" % what
			_set_buttons(true)

	func _on_build_started() -> void:
		if _build_label.is_empty():
			_build_label = "Rebuilding what an object change made stale"
		_build_started_usec = Time.get_ticks_usec()
		_set_buttons(false)
		_process(0.0)

	func _on_build_finished(report: Dictionary) -> void:
		var seconds: float = (Time.get_ticks_usec() - _build_started_usec) / 1e6 if _build_started_usec != 0 else float(report.get("usec", 0)) / 1e6
		_build_started_usec = 0
		var what := _build_label
		_build_label = ""
		_update_counts()
		_status.text = "%s: %s in %.2f s" % [what, build_text(report), seconds]

	func _on_refresh() -> void:
		await _run("Finding stale cells", func() -> String:
			var stale: Array = store.stale_cells()
			var errors := 0
			for entry in stale:
				if entry.get("kind") == "error":
					errors += 1
			_stale_text = "stale cells: %d" % (stale.size() - errors)
			if errors > 0:
				return "invalid object descriptors: %s" % stale[0].get("error", "")
			return "%d stale cells" % stale.size())

	## The counts of a build report, as the status line shows them.
	static func build_text(result: Dictionary) -> String:
		if not result.get("ok", false):
			return "build failed: %s" % result.get("error", "")
		return "built %d cells, %d unchanged, %d deleted" % [result.get("written", []).size(), result.get("unchanged", []).size(), result.get("deleted", []).size()]

	# Disables the buttons, shows [param what], lets the editor draw, runs [param work] (which
	# returns the text to report) on the main thread, then refreshes the counts.
	func _run(what: String, work: Callable) -> void:
		if _busy or _building() or not _valid():
			return
		_busy = true
		_set_buttons(false)
		_status.text = what + "..."
		if is_inside_tree():
			await get_tree().process_frame
			await get_tree().process_frame
		_stale_text = "stale cells: press Refresh"  # a build changes them; Refresh sets it again
		var started := Time.get_ticks_usec()
		var message: String = work.call()
		var seconds := (Time.get_ticks_usec() - started) / 1e6
		_busy = false
		_update_counts()
		_status.text = "%s in %.2f s" % [message, seconds]
