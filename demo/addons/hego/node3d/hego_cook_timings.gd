@tool
class_name HEGoCookTimings
extends RefCounted

## Collects the per-phase timings of a [method HEGoNode3D.cook] call.
##
## Usage: [method begin_phase] before a phase, [method end_phase] after it, and
## [method format_summary] once the cook is done. Phases are printed in the order
## they were recorded, so adding an output handler needs no change here.

var _cook_start_usec: int = Time.get_ticks_usec()
var _phase_start_usec: int = Time.get_ticks_usec()
var _phase_order: PackedStringArray = PackedStringArray()
var _phase_msec: Dictionary = {}


## Milliseconds elapsed since [param start_usec], as returned by [method Time.get_ticks_usec].
static func elapsed_msec(start_usec: int) -> float:
	return float(Time.get_ticks_usec() - start_usec) / 1000.0


## Marks the start of a phase.
func begin_phase() -> void:
	_phase_start_usec = Time.get_ticks_usec()


## Records the time since the last [method begin_phase] under [param phase_name].
func end_phase(phase_name: String) -> void:
	if not _phase_msec.has(phase_name):
		_phase_order.append(phase_name)
	_phase_msec[phase_name] = elapsed_msec(_phase_start_usec)


## Milliseconds since this object was created, i.e. since the cook started.
func total_msec() -> float:
	return elapsed_msec(_cook_start_usec)


## Human readable summary of every recorded phase plus the cook total.
func format_summary() -> String:
	var lines := PackedStringArray()
	lines.append(HEGoNodeUtil.LOG_PREFIX + "Cook timing summary")
	for phase_name in _phase_order:
		lines.append(HEGoNodeUtil.LOG_PREFIX + "  %s: %.3f ms" % [_label_for(phase_name), _phase_msec[phase_name]])
	lines.append(HEGoNodeUtil.LOG_PREFIX + "  Total cook(): %.3f ms" % total_msec())
	return "\n".join(lines)


## Turns a phase key such as [code]mesh_output[/code] into [code]Mesh Output[/code].
func _label_for(phase_name: String) -> String:
	return phase_name.capitalize()
