# At most one heavy sync job per frame. Each job that can be expensive (machine
# scan, belt snapshot, yard tables, hay checksums...) holds one of these and
# asks take() before running: if another heavy job already ran this frame, it
# waits for a later frame (at most MAX_WAIT frames, then it runs anyway).
#
# Adopted from xRangerDE's Multiplayer Enhanced (mp_frame_slots.gd), a fork of
# AleDev11's FindTheNeedle-Coop-Mod. MIT licence, see LICENSE.txt.
extends RefCounted

const MAX_WAIT := 3

static var _frame := -1
static var _taken := false

var _waited := 0


func take() -> bool:
	var frame := Engine.get_process_frames()
	if frame != _frame:
		_frame = frame
		_taken = false
	if _taken and _waited < MAX_WAIT:
		_waited += 1
		return false
	_taken = true
	_waited = 0
	return true
