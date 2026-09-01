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

	print("")
	print("failures: ", failures)
	quit(1 if failures > 0 else 0)
