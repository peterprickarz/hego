## Regression test for the bottom panel's input list.
##
## An HDA input can be wired to several Godot nodes, so the panel shows one line per
## node. Rebuilding the list used to add a single line however many were needed,
## which left every input after the first one missing.
extends SceneTree

const INPUT_UI := preload("res://addons/hego/ui/input_ui.tscn")

var failures := 0


func check(condition: bool, what: String) -> void:
	if condition:
		print("  ok   ", what)
	else:
		print("  FAIL ", what)
		failures += 1


func make_input_ui() -> Control:
	var ui := INPUT_UI.instantiate()
	root.add_child(ui)
	return ui


func line_texts(ui: Control) -> PackedStringArray:
	var texts := PackedStringArray()
	for line in ui.input_container.get_children():
		texts.append(line.text)
	return texts


# Nodes added during _initialize() are in the tree but have not run _ready() yet,
# so their @onready members are still null. Wait for the first frame.
func _process(_delta: float) -> bool:
	run_tests()
	return true


func run_tests() -> void:
	# --- the case that was broken: more than one node on an input ----------
	var ui := make_input_ui()
	var three := PackedStringArray(["Node3D/A", "Node3D/B", "Node3D/C"])
	ui.setup("geo", three)
	check(ui.input_container.get_child_count() == 3,
		"3 inputs produce 3 lines, got %d" % ui.input_container.get_child_count())
	check(line_texts(ui) == three, "each line shows its own node path, got %s" % str(line_texts(ui)))
	check(ui.get_inputs() == three, "get_inputs() round trips every entry")
	check(int(ui.spin_box.value) == 3, "the spin box shows the count")
	check(not ui.include_children.button_pressed, "legacy inputs default to explicit nodes")
	ui.setup("geo", three, {"include_children": true, "curve_sample_length": .1})
	check(ui.include_children.button_pressed, "Include Children restores the saved setting")
	check(ui.get_inputs() == three, "recursive inputs retain the compact parent paths")
	var events := [0]
	ui.inputs_changed.connect(func(): events[0] += 1)
	ui.include_children.button_pressed = false
	check(events[0] == 1, "toggling child expansion notifies the panel exactly once")
	ui.setup("geo", three, {"include_children": true})
	check(events[0] == 1, "rebuilding the UI does not trigger a cook or overwrite the stash")
	var typed = ui.input_container.get_child(0)
	typed.focus_entered.emit()
	typed.text = "TypedParent"
	check(events[0] == 1, "typing does not start a cook for each keystroke")
	typed.text_submitted.emit("TypedParent")
	check(events[0] == 2, "typed paths notify the panel as well as dragged nodes")
	typed.focus_exited.emit()
	check(events[0] == 2, "focus loss after Enter does not trigger a duplicate cook")

	# --- growing and shrinking an existing list ----------------------------
	ui.setup("geo", PackedStringArray(["Node3D/X"]))
	check(ui.input_container.get_child_count() == 1, "shrinking to 1 leaves 1 line")
	check(line_texts(ui) == PackedStringArray(["Node3D/X"]), "the remaining line is updated")

	ui.setup("geo", PackedStringArray(["a", "b", "c", "d", "e"]))
	check(ui.input_container.get_child_count() == 5, "growing to 5 leaves 5 lines")
	check(ui.get_inputs() == PackedStringArray(["a", "b", "c", "d", "e"]), "all 5 round trip")

	ui.setup("geo", PackedStringArray())
	check(ui.input_container.get_child_count() == 0, "an input with no nodes shows no lines")

	# --- driving the spin box, the way a user does -------------------------
	var spun := make_input_ui()
	spun.setup("geo", PackedStringArray())
	spun.spin_box.value = 4
	check(spun.input_container.get_child_count() == 4,
		"raising the spin box to 4 adds 4 lines, got %d" % spun.input_container.get_child_count())
	spun.spin_box.value = 2
	check(spun.input_container.get_child_count() == 2, "lowering it to 2 removes the extras")

	# --- a fresh instance per input, as the panel builds them --------------
	var counts := [1, 2, 3]
	var ok := true
	for count in counts:
		var fresh := make_input_ui()
		var paths := PackedStringArray()
		for i in range(count):
			paths.append("n%d" % i)
		fresh.setup("input", paths)
		if fresh.input_container.get_child_count() != count:
			ok = false
	check(ok, "a freshly instantiated list is correct for 1, 2 and 3 inputs")

	# Visibility changes scene nodes, independently of cook settings and signals.
	var host := Node3D.new()
	root.add_child(host)
	var parent := Node3D.new()
	parent.name = "Sources"
	host.add_child(parent)
	var hidden_child := MeshInstance3D.new()
	hidden_child.visible = false
	parent.add_child(hidden_child)
	var other := Node3D.new()
	other.name = "Other"
	other.visible = false
	host.add_child(other)
	var undo := UndoRedo.new()
	var visibility_ui := make_input_ui()
	var visibility_cook_events := [0]
	visibility_ui.inputs_changed.connect(func(): visibility_cook_events[0] += 1)
	visibility_ui.setup("geometry", PackedStringArray(["Sources"]), {"include_children": true}, host, undo)
	check(visibility_ui.input_visible.button_pressed and not visibility_ui.input_visible.disabled, "visibility reflects the referenced parent")
	visibility_ui.input_visible.button_pressed = false
	check(not parent.visible and not hidden_child.visible, "hiding the parent preserves child flags")
	check(visibility_cook_events[0] == 0, "visibility does not change input settings or request a cook")
	undo.undo()
	visibility_ui.refresh_visibility()
	check(parent.visible and visibility_ui.input_visible.button_pressed, "undo restores source visibility and the toggle")
	undo.redo()
	visibility_ui.refresh_visibility()
	check(not parent.visible and not visibility_ui.input_visible.button_pressed, "redo hides the source again")
	visibility_ui.input_visible.button_pressed = true
	check(parent.visible and not hidden_child.visible, "showing the parent keeps intentionally hidden children hidden")
	visibility_ui.setup("geometry", PackedStringArray(["Sources", "Other", "Sources"]), {}, host, undo)
	check(visibility_ui.input_visible.text == "Mixed" and visibility_ui._visibility_targets().size() == 2, "mixed visibility and duplicate paths are handled")
	visibility_ui.input_visible.button_pressed = false
	check(not parent.visible and not other.visible, "mixed visibility click hides all references")
	undo.undo()
	visibility_ui.refresh_visibility()
	check(parent.visible and not other.visible and visibility_ui.input_visible.text == "Mixed", "undo restores each node's original visibility")
	parent.visible = false
	visibility_ui.refresh_visibility()
	check(not visibility_ui.input_visible.button_pressed, "scene-tree visibility changes update the toggle")
	var container := Node.new()
	container.name = "Container"
	host.add_child(container)
	var spatial := Node3D.new()
	container.add_child(spatial)
	visibility_ui.setup("geometry", PackedStringArray(["Container"]), {"include_children": true}, host, undo)
	visibility_ui.input_visible.button_pressed = false
	check(not spatial.visible, "plain Node containers can hide their 3D children when expansion is enabled")
	visibility_ui.setup("geometry", PackedStringArray(["Missing"]), {}, host, undo)
	check(visibility_ui.input_visible.disabled, "missing references disable visibility safely")
	visibility_ui.setup("geometry", PackedStringArray(), {}, host, undo)
	check(visibility_ui.input_visible.disabled, "empty inputs disable visibility")
	host.free()
	visibility_ui.refresh_visibility()
	check(visibility_ui.input_visible.disabled, "deleted input hosts are safe")

	print("")
	print("failures: ", failures)
	quit(1 if failures > 0 else 0)
