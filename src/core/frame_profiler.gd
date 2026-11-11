class_name FrameProfiler
## Where each frame's time goes, by system (F4 shows it: src/ui/profiler_overlay.gd).
## A system's per-frame function times itself:
##     var t := FrameProfiler.begin()
##     ...
##     FrameProfiler.add(&"mobs", t)
## Off (the overlay hidden), begin() returns 0 and add() does nothing.

static var on := false
static var _sums := {}  # system -> microseconds so far this frame


static func begin() -> int:
	return Time.get_ticks_usec() if on else 0


static func add(system: StringName, since: int) -> void:
	if since != 0:
		_sums[system] = int(_sums.get(system, 0)) + Time.get_ticks_usec() - since


## This frame's times (microseconds by system), starting the next frame.
static func take() -> Dictionary:
	var out := _sums
	_sums = {}
	return out
