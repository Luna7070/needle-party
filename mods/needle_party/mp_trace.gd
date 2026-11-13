extends Node

# What the mod was doing, written as it happens.
#
# Some guests crash over Steam and the game dies without a word: the crash log
# stops and says nothing about what came in last. This keeps a small file next
# to the game's crash logs with every message the mod receives and when the
# heavier jobs (adding buildings, belts, loading the world) start and end, so
# after a crash its last lines say what was being handled.
#
# It holds no chat or names, only which message arrived, from which peer and how
# big it was. It stays on the player's PC unless anonymous logs are on (mp_logs.gd). The ones that come in many times
# a second (moves, poses, belt and machine updates) are only counted, and the
# counts go on the once a second tick line: one line each filled 4 MB in about
# 18 minutes and the start of a session was gone by the time anyone looked. Each line is flushed as it is
# written, so it survives the game dying. On start the previous run's file is
# kept as mp_trace.prev.log, since after a crash the game gets opened again.

var PATH := "user://mp_trace_%s.log" % OS.get_environment("MP_SELFTEST") if OS.get_environment("MP_SELFTEST") != "" else "user://mp_trace.log"  # dev: one file per test copy
var PREV := PATH.get_basename() + ".prev.log"
var OLD := PATH.get_basename() + ".old.log"  # this run, before the size limit
const MAX_BYTES := 4 << 20
const TICK := 1.0
const COUNTED := ["straw_move", "straw_add", "straw_del", "straw_census",
	"prop_move", "prop_state", "prop_census", "machines", "machine_fields",
	"belts", "hay", "hay_sums", "state_delta", "machines_big", "state_snap", "market"]

var _f: FileAccess = null
var _t := 0.0
var _frames := 0
var _dirty := false  # something was written this frame
var _counts := {}    # message -> how many since the last tick


func start(version: String) -> void:
	var dir := DirAccess.open("user://")
	if dir != null and dir.file_exists(PATH.get_file()):
		dir.rename(PATH.get_file(), PREV.get_file())
	if dir != null and dir.file_exists(EV_PATH.get_file()):
		dir.rename(EV_PATH.get_file(), EV_PREV.get_file())
	_open()
	_ev_open()
	note("start mod %s, engine %s, %s" % [version, Engine.get_version_info().get("string", "?"),
		Time.get_datetime_string_from_system(true)])
	_hook_errors()


func _open() -> void:
	_f = FileAccess.open(PATH, FileAccess.WRITE)


func note(text: String) -> void:
	if _f == null:
		return
	_f.store_line("%d %s" % [Time.get_ticks_msec(), text])
	_f.flush()
	_dirty = true
	if _f.get_length() > MAX_BYTES:
		# start over rather than grow for ever, and keep the last stretch: the whole
		# start of a session was gone by the time anyone looked
		_f.close()
		var dir := DirAccess.open("user://")
		if dir != null:
			dir.rename(PATH.get_file(), OLD.get_file())
		_open()
		note("trace restarted (size limit)")


func rx(what: String, from: int, size: int) -> void:
	if COUNTED.has(what):
		_counts[what] = int(_counts.get(what, 0)) + 1
		return
	note("rx %s from %d%s" % [what, from, (" n=%d" % size) if size >= 0 else ""])


func _process(delta: float) -> void:
	if not _err_q.is_empty():
		_drain_errs()
	# a frame went by after something was written: whatever that was, it
	# finished. After a crash, a message with no "frame" after it is the suspect.
	if _dirty and _f != null:
		_f.store_line("%d frame" % Time.get_ticks_msec())
		_f.flush()
		_dirty = false
	_frames += 1
	_t += delta
	if _t < TICK:
		return
	var got := ""
	for what in _counts:
		got += " %s=%d" % [what, _counts[what]]
	_counts.clear()
	got += _counter_text()
	_flush_repeat()
	_flush_err_counts()
	var tick := "tick fps=%d frame_ms=%.1f nodes=%d%s" % [_frames, 1000.0 * _t / maxf(1.0, _frames),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)), got]
	note(tick)
	_ring_add(_ring_tick, _ring_tick_t, tick, 64)
	_t = 0.0
	_frames = 0
	_clock_tick()


func _exit_tree() -> void:
	if _logger != null and OS.has_method("remove_logger"):
		OS.call("remove_logger", _logger)
		_logger = null
	if _f != null:
		note("quit")
		_f.close()
		_f = null
	if _ev != null:
		_ev.close()
		_ev = null


# ---------------------------------------------------------------- log v2 (dev/logs_upgrade.md)
# What made this week's fixes possible, from real sessions: one timeline for host and guest
# (clock lines), what happened to each item (items_events), the belt counters on the tick
# line, the last 30 s of belt words / item events / ticks in memory for the bug key, and
# every error with what had just happened. Events only, never positions per frame; repeats
# collapse to one line and a count; one item cannot fill the file.

var mp: Node = null   # set by mp.gd

# --- one timeline: "clock role=guest peer=7 local_ms=.. host_ms=.. rtt_ms=.. session=.."
const CLOCK_EVERY := 30   # ticks
var session := ""          # host: made when it starts hosting; guest: the host's, with its pings
var _clock_n := 0
var _clock_pair := []      # guest: [local ms, host ms] of the host's last ping

func clock(role: String, peer: int, local_ms: int, host_ms: int, rtt_ms: int) -> void:
	note("clock role=%s peer=%d local_ms=%d host_ms=%d rtt_ms=%d session=%s" % [role, peer, local_ms, host_ms, rtt_ms,
		session if session != "" else "-"])


# Guest: the host's ping arrived (its own clock in it). The first one and then every
# CLOCK_EVERY s it goes in the log.
func host_ping(host_ms: int, host_session: String) -> void:
	var first := _clock_pair.is_empty() or (host_session != "" and host_session != session)
	if host_session != "":
		session = host_session
	_clock_pair = [Time.get_ticks_msec(), host_ms]
	if first:
		_clock_line()


func _clock_line() -> void:
	if mp == null or not is_instance_valid(mp) or not bool(mp.call("active")):
		return
	if bool(mp.get("is_host")):
		var now := Time.get_ticks_msec()
		clock("host", 1, now, now, 0)
	elif not _clock_pair.is_empty():
		var me := multiplayer.get_unique_id()
		clock("guest", me, int(_clock_pair[0]), int(_clock_pair[1]), int((mp.get("pings") as Dictionary).get(me, 0)))


func _clock_tick() -> void:
	_clock_n += 1
	if _clock_n >= CLOCK_EVERY:
		_clock_n = 0
		_clock_line()


# --- counters on the tick line. Sources hand over running totals (their own test
# counters, which count always); the tick line says how many since the last tick.
# bump(): counters kept here (deletes by reason, takes, throws...).
var _sources: Array = []   # [object, {name on the line: its variable}]
var _seen := {}            # "src#name" -> total at the last tick
var _bumps := {}           # name -> count since the last tick

func add_counters(src: Object, names: Dictionary) -> void:
	# a new session's sync nodes replace the last one's
	_sources = _sources.filter(func(s: Array) -> bool: return s[0] != null and is_instance_valid(s[0]))
	_sources.append([src, names])


func bump(what: String, n := 1) -> void:
	_bumps[what] = int(_bumps.get(what, 0)) + n


func _counter_text() -> String:
	var out := ""
	for s in _sources:
		var src: Variant = s[0]
		if src == null or not is_instance_valid(src):
			continue
		var names: Dictionary = s[1]
		for nm in names:
			var v: Variant = (src as Object).get(names[nm])
			if v == null:
				continue
			var key := "%d#%s" % [(src as Object).get_instance_id(), nm]
			var d := int(v) - int(_seen.get(key, 0))
			_seen[key] = int(v)
			if d != 0:
				out += " %s=%d" % [nm, d]
	for what in _bumps:
		out += " %s=%d" % [what, _bumps[what]]
	_bumps.clear()
	return out


# --- rings: the last RING_MS of belt words, item events and ticks, for the bug key
const RING_MS := 30000
# plain Arrays: they are shared by reference, a packed array handed to _ring_add is a copy
var _ring_belt: Array = []
var _ring_belt_t: Array = []
var _ring_item: Array = []
var _ring_item_t: Array = []
var _ring_tick: Array = []
var _ring_tick_t: Array = []
var _last_items: Array = []   # the last 3 item events, for error lines
var _last_belts: Array = []   # the last 3 belt words

func _ring_add(lines: Array, times: Array, text: String, cap: int) -> void:
	var now := Time.get_ticks_msec()
	lines.append(text)
	times.append(now)
	# drop what is older than the window, or over the cap: from the front, a slice at a time
	var cut := 0
	while cut < times.size() and (now - int(times[cut]) > RING_MS or times.size() - cut > cap):
		cut += 1
	if cut > 64 or (cut > 0 and times.size() > cap):
		lines.assign(lines.slice(cut))
		times.assign(times.slice(cut))


# Everything the rings hold, one timeline: "<ms> <line>", oldest first.
func ring_text() -> String:
	var now := Time.get_ticks_msec()
	var rows: Array = []
	for pair in [[_ring_tick, _ring_tick_t], [_ring_item, _ring_item_t], [_ring_belt, _ring_belt_t]]:
		var lines: Array = pair[0]
		var times: Array = pair[1]
		for i in lines.size():
			if now - int(times[i]) <= RING_MS:
				rows.append([times[i], lines[i]])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) < int(b[0]))
	var out := PackedStringArray(["schema=2 ts=%d window_ms=%d" % [now, RING_MS]])
	for r in rows:
		out.append("%d %s" % [r[0], r[1]])
	return "\n".join(out)


# A belt word: "beltw belt=b1a2b3 rows=.. seq0=.. seq1=.. phase=.. stride=.. lag_ms=..".
# Into the ring always; into the trace only when it says something is off (notable),
# once per belt per BELTW_QUIET_MS.
const BELT_RING_CAP := 10000   # ~30 s of words in a busy yard (about 200 a second here)
const BELTW_QUIET_MS := 5000
var _beltw_at := {}

func beltw(belt: String, text: String, notable: bool) -> void:
	_ring_add(_ring_belt, _ring_belt_t, text, BELT_RING_CAP)
	_last_belts.append(text)
	if _last_belts.size() > 3:
		_last_belts.pop_front()
	if notable:
		var now := Time.get_ticks_msec()
		if now - int(_beltw_at.get(belt, -BELTW_QUIET_MS)) >= BELTW_QUIET_MS:
			_beltw_at[belt] = now
			note(text)


# --- item lifecycle: items_events log, its own file (1 MB, .prev/.old like the trace)
var EV_PATH := PATH.get_basename().replace("mp_trace", "mp_items_events") + ".log"
var EV_PREV := EV_PATH.get_basename() + ".prev.log"
var EV_OLD := EV_PATH.get_basename() + ".old.log"
const EV_MAX_BYTES := 1 << 20
const ITEM_RING_CAP := 3000
const PER_ITEM_MAX := 24   # lines per item; its delete always gets in
var _ev: FileAccess = null
var _per_item := {}

func _ev_open() -> void:
	_ev = FileAccess.open(EV_PATH, FileAccess.WRITE)
	if _ev != null:
		_ev.store_line("schema=2 ts=%d" % Time.get_ticks_msec())
		_ev.flush()


# "item ev=board id=1234 kind=hay_wad seq=881 belt=b12 s=4.02 role=guest"
func item(id: String, text: String, last := false) -> void:
	var n := int(_per_item.get(id, 0)) + 1
	if n > PER_ITEM_MAX and not last:
		return
	if last:
		_per_item.erase(id)
	else:
		_per_item[id] = n
		if _per_item.size() > 4096:
			_per_item.clear()
	_ring_add(_ring_item, _ring_item_t, text, ITEM_RING_CAP)
	_last_items.append(text)
	if _last_items.size() > 3:
		_last_items.pop_front()
	if _ev == null:
		return
	_ev.store_line("%d %s" % [Time.get_ticks_msec(), text])
	_ev.flush()
	if _ev.get_length() > EV_MAX_BYTES:
		_ev.close()
		var dir := DirAccess.open("user://")
		if dir != null:
			dir.rename(EV_PATH.get_file(), EV_OLD.get_file())
		_ev_open()


# --- one line, repeats folded: "act ...", "err ...", notable belt words
var _rep_last := ""
var _rep_n := 0

func note_once(text: String) -> void:
	if text == _rep_last:
		_rep_n += 1
		return
	_flush_repeat()
	_rep_last = text
	note(text)


func _flush_repeat() -> void:
	if _rep_n > 0:
		note("repeat n=%d of: %s" % [_rep_n, _rep_last.left(80)])
	_rep_n = 0


# Action markers: what a player did, a few a minute ("act ev=throw ...").
func act(text: String) -> void:
	note_once("act " + text)


# --- errors: the engine's own and ours, each with what had just happened
var _logger: Object = null
var _err_m := Mutex.new()
var _err_q := PackedStringArray()
const ERR_Q_CAP := 64

# Called by the logger, from any thread: only queue it.
func _queue_err(text: String) -> void:
	_err_m.lock()
	if _err_q.size() < ERR_Q_CAP:
		_err_q.append(text)
	_err_m.unlock()


func _drain_errs() -> void:
	if _err_q.is_empty():
		return
	_err_m.lock()
	var q := _err_q
	_err_q = PackedStringArray()
	_err_m.unlock()
	var now := Time.get_ticks_msec()
	for e in q:
		# one line per error, with what had just happened; the same error again within
		# ERR_QUIET_MS is only counted (the context differs every time, so it is keyed by
		# the error alone), and the count goes out with the next tick
		var seen: Variant = _err_seen.get(e)
		if seen != null and now - int(seen[0]) < ERR_QUIET_MS:
			seen[1] = int(seen[1]) + 1
			continue
		_err_seen[e] = [now, 0]
		if _err_seen.size() > 256:
			_err_seen.clear()
		note("err %s | items: %s | belts: %s" % [e, " ; ".join(_last_items), " ; ".join(_last_belts)])


const ERR_QUIET_MS := 5000
var _err_seen := {}   # error text -> [msec of its last line, how many since]

func _flush_err_counts() -> void:
	for e in _err_seen:
		var seen: Array = _err_seen[e]
		if int(seen[1]) > 0:
			note("repeat n=%d of: err %s" % [int(seen[1]), String(e).left(120)])
			seen[1] = 0


# A Logger (engine 4.5+) that hands each error to _queue_err. Made from source so a game on
# an engine without one still loads this file.
func _hook_errors() -> void:
	if not ClassDB.class_exists("Logger") or not OS.has_method("add_logger"):
		return
	var s := GDScript.new()
	s.source_code = "extends Logger\nvar sink: Object = null\n" \
		+ "func _log_error(function: String, file: String, line: int, code: String, rationale: String, editor_notify: bool, error_type: int, script_backtraces: Array[ScriptBacktrace]) -> void:\n" \
		+ "\tif sink != null:\n" \
		+ "\t\tsink._queue_err(\"%s @%s:%d\" % [(rationale if rationale != \"\" else code).left(200), file.get_file(), line])\n"
	if s.reload() != OK:
		return
	var lg: Object = s.new()
	lg.set("sink", self)
	OS.call("add_logger", lg)
	_logger = lg
