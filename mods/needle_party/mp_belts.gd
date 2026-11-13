extends Node

# Belt contents.
#
# The host decides what is riding on the belts. Four times a second it sends the
# rides of the belts near a player that changed; every two seconds, every belt.
# A guest puts each belt's rides back exactly as the host has them: the same id
# (seq), position, gap and speed, written straight into the belt's own rows, and
# the belt's step clock started anew, so the game draws them on from there without
# a jump. Between updates the guest's own belts keep turning; their ends are held,
# so a ride crosses to the next belt (or into a machine) only with the host's word.
#
# (1.2.19) This replaces several attempts of our own (restore_records with new ids,
# keeping rides by position, replaying hand-over events), which all looked fine on
# one PC and stuttered or jammed between two. Adopted from xRangerDE's
# "Multiplayer Enhanced" (mp_belts.gd / mp_belt_routes.gd, 0.19.6-xRangerDE.80), a
# fork of AleDev11's FindTheNeedle-Coop-Mod, MIT licence, see LICENSE. Their way is
# well tested; the matching of belts by their two ends and the rest is ours.
#
# Machines that eat from a belt are switched off on guests, or both sides would
# turn the same hay into two bales.

const TICK := 0.25           # near belts that changed go out this often
const FULL_TICK := 2.0       # every belt goes out this often, changed or not
const NEAR_M := 40.0         # "near": within this of any player
const MAX_RAW := 8 << 20
const APPLY_BUDGET_US := 2500  # guest: belt work per frame
const FrameSlots = preload("mp_frame_slots.gd")

var mp: Node
var world: Node
var _t := 0.0
var _since := 0.0
var _send_slot := FrameSlots.new()
var _apply_slot := FrameSlots.new()
var _sent := {}        # host: belt key -> its rows as bytes, last sent
var _keys := {}        # a -> b -> key: making these strings 300 times a tick added up
var _paths := {}       # guest: belt key -> the belt's node
var _paths_n := -1
var _queue := {}       # guest: belt key -> rows waiting to go on (newest wins)
var _order: Array = [] # guest: in which order they came
var _pending: Array = []  # guest: messages not unpacked yet
# test counters
var applied := 0
var full_seen := 0


func start(mp_node: Node, world_node: Node) -> void:
	mp = mp_node
	world = world_node
	# (log v2) every counter the test tools read, on the trace's tick line (as many as since
	# the last tick); they count always, only the tools used to look
	if mp.trace != null and mp.trace.has_method("add_counters"):
		mp.trace.add_counters(self, COUNTERS)


const COUNTERS := {"aliased": "aliased", "boarded": "boarded", "removed": "removed", "nudged": "nudged",
	"board_refused": "board_refused", "board_forced": "board_forced", "board_slid": "board_slid",
	"crossed": "crossed", "waited": "waited", "kept_seam": "kept_seam",
	"fork_picked": "fork_picked", "wrongmove": "fork_wrong_moved", "fork_steered": "fork_steered",
	"fork_fallback": "fork_fallback", "fork_rehold": "fork_rehold", "fork_stuck": "fork_stuck",
	"phase_clash": "phase_clash", "stride_miss": "stride_miss", "phased": "phased", "phase_set": "phase_set",
	"dup_rows": "dup_rows", "dup_caught": "dup_caught", "remove_short": "remove_short", "board_extra": "board_extra",
	"words": "applied", "full_words": "full_seen", "outlet_held": "outlet_held_set"}


# (log v2) a belt's short name in the logs: the same on every PC (from its key)
func belt_id(path: Node) -> String:
	return "b%06x" % (_key_of(path).hash() & 0xffffff)


# "beltw belt=b12 rows=118 seq0=881 seq1=998 phase=2 stride=4 lag_ms=212": one per belt
# word, into the trace's 30 s ring; into the trace itself when it says something is off
# (a lag spike, a stride the host's belt does not have here).
const BELTW_LAG_MS := 400
var _lag_base := INF   # guest: the quickest a word has come lately (local ms - host ms)

func _beltw(k: String, e: Dictionary, lag: int, path: Variant) -> void:
	if mp == null or mp.trace == null:
		return
	var rows: Array = e.get("r", [])
	var seq0 := int((rows[0] as Dictionary).get("seq", -1)) if not rows.is_empty() and rows[0] is Dictionary else -1
	var seq1 := int((rows.back() as Dictionary).get("seq", -1)) if not rows.is_empty() and rows.back() is Dictionary else -1
	var ph: Array = e.get("ph", [0, 0])
	var stride := int(ph[1]) if ph.size() > 1 else 0
	var bid := "b%06x" % (k.hash() & 0xffffff)
	var odd := lag >= BELTW_LAG_MS
	if path != null and is_instance_valid(path) and stride > 0 and int(path.run.stride_ticks) != stride:
		odd = true
	mp.trace.beltw(bid, "beltw belt=%s rows=%d seq0=%d seq1=%d phase=%d stride=%d lag_ms=%d" % [bid, rows.size(), seq0, seq1,
		int(ph[0]) if ph.size() > 0 else 0, stride, lag], odd)


# Hand the belt ends back, in case the world outlives the session.
func shutdown() -> void:
	for item in BeltPath._live:
		if not is_instance_valid(item) or not item.is_inside_tree():
			continue
		if item.has_signal("caught_record") and item.caught_record.is_connected(_on_caught):
			item.caught_record.disconnect(_on_caught)
		if item.get_meta("np_fork_held", false):
			item.remove_meta("np_fork_held")
			item.run.set_end_held(false)
		var ko := _key_of(item)
		if _outlets.has(ko) and item.has_method("set_outlet_held"):
			item.call("set_outlet_held", bool(_outlets[ko]))
		if not item.get_meta("np_held", false):
			continue
		item.remove_meta("np_held")
		item.run.set_end_held(false)
		# (1.2.19) not in every build (the demo: 31,536 errors in one log, from asking about
		# a function it does not have)
		if item.has_method("_on_run_fell_off") and item.run.has_signal("fell_off") \
		and not item.run.fell_off.is_connected(item._on_run_fell_off):
			item.run.fell_off.connect(item._on_run_fell_off)


# stopwatch: anything over 4 ms in one frame goes into mp_trace.log by name
func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_process_inner(delta)
	if mp != null and is_instance_valid(mp):
		mp.perf("belts", Time.get_ticks_usec() - t0)


func _process_inner(delta: float) -> void:
	if mp == null or not mp.active():
		return
	if not mp.is_host:
		if not _pending.is_empty() and _apply_slot.take():
			var p: Array = _pending.pop_front()
			_unpack(p[0], p[1])
		_drain()
		_watch_forks()
		return
	if multiplayer.multiplayer_peer == null or mp.players.size() < 2:
		return
	_t += delta
	_since += delta
	if _t < TICK or not _send_slot.take():
		return
	_t = 0.0
	send_all()


func _key(a: Variant, b: Variant) -> String:
	var row: Dictionary = _keys.get(a, {})
	var k: Variant = row.get(b)
	if k == null:
		k = "%s|%s" % [a, b]
		row[b] = k
		_keys[a] = row
	return k


func _key_of(path: Node) -> String:
	var line: Variant = path.get("_line")
	if line == null or line.size() < 2:
		return ""
	return _key(line[0], line[line.size() - 1])


# ------------------------------------------------------------------ host

# Everyone (pid 0), or one guest that just came in (pid > 0: every belt).
func send_all(pid: int = 0) -> void:
	var full := pid > 0 or _since >= FULL_TICK
	var spots := [] if full else _player_spots()
	var rows_out: Array = []
	var live := {}
	for path in BeltPath._live:
		if not is_instance_valid(path) or not path.is_inside_tree():
			continue
		var k := _key_of(path)
		if k == "":
			continue
		live[k] = true
		var run: Variant = path.run
		if not full and not _near(path, spots):
			continue
		var rows: Array = []
		var lead := _step_lead(path)
		for i in range(int(run.first()), int(run.first()) + int(run.count())):
			var row: Dictionary = run.record(i)
			row["gap"] = float(run.gap_of(i))
			# where it is drawn now, not where the belt's last step (up to 66 ms ago) left it
			var v := float(row.get("speed", 0.0))
			if v > 0.0:
				row["s"] = float(row.get("s", 0.0)) + v * lead
			row.erase("xform")
			if not (row.get("state") is Dictionary):
				row["state"] = {}
			rows.append(row)
		var entry := {"k": k, "r": rows}
		# (dev/belt_phase.md) the step phase of the belt's line: [_stagger, stride,
		# _seen_tick, _owed]. Sent with the rows every time, a stale stagger is worse than none.
		var ln: Variant = path.get("line")
		if ln is Object and "_stagger" in ln:
			entry["ph"] = [int(ln.get("_stagger")), int(run.stride_ticks), int(ln.get("_seen_tick")), float(ln.get("_owed")), int(run.stepped_tick)]
		if pid == 0:
			var enc := var_to_bytes([rows, entry.get("ph", [0, 0])[0], entry.get("ph", [0, 0])[1]])
			var same: bool = _sent.get(k) == enc
			_sent[k] = enc
			if same and not full:
				continue
			if same and rows.is_empty():
				continue  # an empty belt stays empty: say nothing
		elif rows.is_empty():
			continue
		rows_out.append(entry)
	var data := {"b": rows_out, "full": full, "f": Engine.get_physics_frames(), "pk": _picks_now(),
		"ms": Time.get_ticks_msec()}
	for e in rows_out:
		_beltw(String(e["k"]), e, 0, null)
	if full and pid == 0:
		_since = 0.0
		for k in _sent.keys():
			if not live.has(k):
				_sent.erase(k)
	if rows_out.is_empty() and not full:
		return
	var raw := var_to_bytes(data)
	var packed := raw.compress(FileAccess.COMPRESSION_ZSTD)
	if pid > 0:
		mp._rx_belts.rpc_id(pid, packed, raw.size())
	else:
		mp._rx_belts.rpc(packed, raw.size())


# Host: [feeder key, head row's seq, route key] per splitter. A splitter points its feeder
# at the route it picked (feeder.downstream = route(side)) before the head gets there, and
# the core hands the head over that seam: so the route is known ahead, and the guest can
# point its own feeder there before its head row reaches the mouth (no wait there).
func _picks_now() -> Array:
	var out: Array = []
	var b: Variant = world.get("builds") if world != null and is_instance_valid(world) else null
	var sps: Variant = b.get("splitters") if b != null and is_instance_valid(b) else null
	if not (sps is Array):
		return out
	for sp in sps:
		if sp == null or not is_instance_valid(sp) or not sp.has_method("feeder") or not sp.has_method("routes"):
			continue
		var f: Variant = sp.call("feeder")
		if not (f is Node) or not is_instance_valid(f) or int(f.run.count()) == 0:
			continue
		var d: Variant = f.get("downstream")
		if d == null or not is_instance_valid(d) or not (sp.call("routes") as Array).has(d):
			continue
		var fk := _key_of(f)
		var dk := _key_of(d)
		if fk != "" and dk != "":
			out.append([fk, int(f.run.seq_of(int(f.run.first()))), dk])
	return out


func _player_spots() -> Array:
	var out: Array = []
	var ws: Node = mp.world_sync
	if ws != null and is_instance_valid(ws):
		for id in ws.avatars:
			var a: Variant = ws.avatars[id]
			if a != null and is_instance_valid(a) and (a as Node3D).is_inside_tree():
				out.append((a as Node3D).global_position)
	var me: Variant = world.get("player") if world != null and is_instance_valid(world) else null
	if me != null and is_instance_valid(me):
		out.append((me as Node3D).global_position)
	return out


func _near(path: Node, spots: Array) -> bool:
	if spots.is_empty():
		return true
	var line: Variant = path.get("_line")
	if line == null or line.size() < 2:
		return true
	var box := AABB(line[0], Vector3.ZERO)
	for p in line:
		box = box.expand(p)
	box = box.grow(NEAR_M)
	for at in spots:
		if box.has_point(at):
			return true
	return false


# ------------------------------------------------------------------ guest

func on_belts(packed: PackedByteArray, raw_size: int) -> void:
	_pending.append([packed, raw_size])


func _unpack(packed: PackedByteArray, raw_size: int) -> void:
	if raw_size <= 0 or raw_size > MAX_RAW:
		return
	var data: Variant = bytes_to_var(packed.decompress(raw_size, FileAccess.COMPRESSION_ZSTD))
	if not (data is Dictionary):
		return
	if (data as Dictionary).has("f"):
		_note_frames(int(data["f"]))
	var lag := 0
	if (data as Dictionary).has("ms"):
		var raw := float(Time.get_ticks_msec() - int(data["ms"]))
		if raw < _lag_base:
			_lag_base = raw
		else:
			_lag_base += (raw - _lag_base) * 0.002   # the way got slower: follow it slowly
		lag = roundi(raw - _lag_base)
	var t_pk := Time.get_ticks_msec()
	for pk in (data as Dictionary).get("pk", []):
		if pk is Array and (pk as Array).size() == 3:
			_picks[String(pk[0])] = [int(pk[1]), String(pk[2]), t_pk]
	if BeltPath._live.size() != _paths_n:
		_map_paths()
	_recheck_outlets()
	var listed := {}
	for e in (data as Dictionary).get("b", []):
		if not (e is Dictionary):
			continue
		var k := String(e.get("k", ""))
		listed[k] = true
		_beltw(k, e, lag, _paths.get(k))
		var hs := {}
		for r in e.get("r", []):
			if r is Dictionary:
				hs[int(r.get("seq", -1))] = float(r.get("s", 0.0))
		_word_seqs[k] = hs
		var t_now := Time.get_ticks_msec()
		if _word_at.has(k):
			_word_gap[k] = clampi(t_now - int(_word_at[k]), 100, 4000)
		_word_at[k] = t_now
		if not _queue.has(k):
			_order.append(k)
		_queue[k] = e
	# (1.2.19) all of one message in the same frame: spread over frames, a ride the host
	# had just passed from one belt to the next was briefly on both or on neither
	_drain(true)
	if bool((data as Dictionary).get("full", false)):
		full_seen += 1
		# a belt the host has nothing on has nothing here either
		for k in _paths:
			if listed.has(k):
				continue
			var path: Variant = _paths[k]
			if is_instance_valid(path) and int(path.run.count()) > 0:
				if not _queue.has(k):
					_order.append(k)
				_queue[k] = {"r": []}
				_word_seqs[k] = {}


# (dev/belt_joints.md) Belts that meet: the core hands a row over a joint itself (run.link)
# and keeps its seq, on both sides. So a row the host shows on a belt may be one our core
# already moved there, or is about to. Joints are found by the scene (path.downstream) and
# by where belts start and end, so the branches of a fork count both ways: the host and we
# pick a fork's branch each on our own.
var _up := {}      # belt key -> keys of belts that hand onto it
var _down := {}    # belt key -> keys of belts it hands onto (all branches)
var _sib := {}     # belt key -> other branches of the same fork

func _map_paths() -> void:
	_paths_n = BeltPath._live.size()
	_paths.clear()
	_line_cache.clear()
	_up.clear()
	_down.clear()
	_sib.clear()
	var by_start := {}
	var by_end := {}
	for item in BeltPath._live:
		if not is_instance_valid(item) or not item.is_inside_tree():
			continue
		var k := _key_of(item)
		if k == "":
			continue
		_paths[k] = item
		var line: Array = item.get("_line")
		var a := str(line[0])
		var b := str(line[line.size() - 1])
		if not by_start.has(a):
			by_start[a] = []
		by_start[a].append(k)
		if not by_end.has(b):
			by_end[b] = []
		by_end[b].append(k)
	for k in _paths:
		var item: Node = _paths[k]
		var line: Array = item.get("_line")
		var a := str(line[0])
		var b := str(line[line.size() - 1])
		var down: Array = (by_start.get(b, []) as Array).filter(func(x): return x != k)
		var d: Variant = item.get("downstream")
		if d != null and is_instance_valid(d):
			var dk := _key_of(d)
			if dk != "" and not down.has(dk):
				down.append(dk)
		_down[k] = down
		for dk in down:
			if not _up.has(dk):
				_up[dk] = []
			if not (_up[dk] as Array).has(k):
				_up[dk].append(k)
		_sib[k] = (by_start.get(a, []) as Array).filter(func(x): return x != k)
	_map_forks()
	for k in _paths:
		var item: Node = _paths[k]
		# An end that leads into a machine (no next belt) holds what reaches it: it goes in
		# with the host's next word, never on our own guess (our machines are frozen). A
		# joint to the next belt hands rides on as the game does: held there too, every
		# ride stopped at each joint until the next word and then jumped half a metre on.
		# (dev/belt_api.md) The core's own switch, not hold_records(Callable()) on the whole
		# conveyor: the run keeps its jam/free bookkeeping and only its end stays shut.
		# Only an end with no belt after it at all: a joint, a fork's branch included, is
		# _sync_run_links' (it sets end_held/outlet from the scene) and is not fought.
		var leads_on: Variant = item.get("downstream")
		var no_belt_after: bool = (leads_on == null or not is_instance_valid(leads_on)) 				and (_down.get(k, []) as Array).is_empty()
		if no_belt_after:
			if not item.get_meta("np_held", false):
				item.run.set_end_held(true)
				item.set_meta("np_held", true)
		elif item.get_meta("np_held", false):
			item.remove_meta("np_held")
			item.run.set_end_held(false)
		# a splitter's feeder: rows wait at the mouth until the host names their route
		if _fork_routes.has(k) and not item.get_meta("np_fork_held", false):
			item.run.set_end_held(true)
			item.set_meta("np_fork_held", true)
		# (dev/belt_joints.md) our core hands rows over seams itself and says so
		if item.has_signal("caught_record") and not item.caught_record.is_connected(_on_caught):
			item.caught_record.connect(_on_caught.bind(item))
		# A ride that goes over an open end falls and lands as an item. The host's did
		# that too, so it was there twice; what really falls reaches us as an item.
		if item.has_method("_on_run_fell_off") and item.run.has_signal("fell_off") \
		and item.run.fell_off.is_connected(item._on_run_fell_off):
			item.run.fell_off.disconnect(item._on_run_fell_off)
		_hold_outlet(item)


# (1.2.19) A belt that cannot pass its rows on as rows (no belt after it, or one that only
# takes bodies: a machine's mouth, the hay stairs) turns the row at its end into an item
# (_after_flush -> _materialize_head) for whatever is there to take. On the host that is the
# machine's way in. On a guest the machine is frozen and the host's item comes over anyway:
# ours was one more, made here and sent to the host as a new item, which the host's machine
# then took in as well (the hay stairs made ~3 a second, measured: hay out of nowhere). The
# belt's own outlet hold is what _after_flush leaves alone; our row waits at the end until
# the host's word takes it away.
var _outlets := {}   # belt key -> its own _outlet_held before we held it

func _hold_outlet(item: Node) -> void:
	var k := _key_of(item)
	if k == "" or not item.has_method("set_outlet_held"):
		return
	var passes := bool(item.call("_seam_carries_records")) if item.has_method("_seam_carries_records") else false
	if passes:
		if _outlets.has(k):
			item.call("set_outlet_held", bool(_outlets[k]))
			_outlets.erase(k)
		return
	if not _outlets.has(k):
		_outlets[k] = bool(item.get("_outlet_held"))
	if not bool(item.get("_outlet_held")):
		item.call("set_outlet_held", true)
		outlet_held_set += 1


var outlet_held_set := 0   # counter: outlets held (again) on this side
var _outlet_t := 0

# a machine can set its belt's hold again (its own setup, the yard's feeder bookkeeping)
func _recheck_outlets() -> void:
	var now := Time.get_ticks_msec()
	if now - _outlet_t < 2000:
		return
	_outlet_t = now
	for k in _outlets:
		var item: Variant = _paths.get(k)
		if item != null and is_instance_valid(item) and not bool(item.get("_outlet_held")):
			item.call("set_outlet_held", true)
			outlet_held_set += 1


func _drain(all := false) -> void:
	if _order.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	var n := 0
	while n < _order.size() and (all or Time.get_ticks_usec() - t0 < APPLY_BUDGET_US):
		var k: String = _order[n]
		n += 1
		var e: Variant = _queue.get(k)
		_queue.erase(k)
		if not (e is Dictionary):
			continue
		var path: Variant = _paths.get(k)
		if path == null or not is_instance_valid(path) or not path.is_inside_tree():
			if BeltPath._live.size() != _paths_n:
				_map_paths()
			path = _paths.get(k)
			if path == null or not is_instance_valid(path):
				continue
		var synced := _phase(path, e.get("ph"))
		_restore(path, e.get("r", []), synced)
		applied += 1
	_order = _order.slice(n)


# (dev/belt_phase.md) A belt line steps on the frames where (now + _stagger) % stride wraps,
# now being the physics frame. Host and guest count frames from their own start, so the
# host's stagger is moved by the frame offset between the two: the smallest (our frame -
# host frame) seen on arrival, less the one-way trip. With the same phase and stride both
# step at the same moment by the same dt, and moving rows need no nudge. stride can't be
# forced (run.stride_ticks is only a report; the line picks the slower of its strides), so
# a belt whose stride differs from the host's keeps the nudge.
var _frame_off := 0
var _frame_off_set := false
var _line_phase := {}   # line instance id -> the stagger set this message
var phased := 0         # test counters
var phase_set := 0
var stride_miss := 0
var phase_clash := 0
var phase_ok := 0       # the host's last step, moved into our frames, on our step grid
var phase_off := 0

func _note_frames(host_frame: int) -> void:
	var off := Engine.get_physics_frames() - host_frame
	if not _frame_off_set or off < _frame_off:
		_frame_off = off
		_frame_off_set = true
	elif off > _frame_off + 2:
		_frame_off += 1  # the way got slower: follow it slowly
	_line_phase.clear()


func _phase(path: Node, ph: Variant) -> bool:
	if not (ph is Array) or (ph as Array).size() < 4 or not _frame_off_set:
		return false
	var ln: Variant = path.get("line")
	if not (ln is Object) or not ("_stagger" in ln):
		return false
	var stride := int(ph[1])
	if stride <= 0 or int(path.run.stride_ticks) != stride:
		stride_miss += 1
		return false
	var trip := roundi(float(mp.pings.get(multiplayer.get_unique_id(), 0)) / 2.0 / (1000.0 / Engine.physics_ticks_per_second))
	var d := _frame_off - trip
	var want := posmod(int(ph[0]) - d, stride)
	var id: int = (ln as Object).get_instance_id()
	if _line_phase.has(id) and int(_line_phase[id]) != want:
		phase_clash += 1   # two host lines on one of ours: the first one this message wins
		return false
	_line_phase[id] = want
	if not (ln as Object).has_meta("np_phased"):
		# first word for this line: start the counters together (not _stepped_frame,
		# a frame guard on another counter: the host's value could stop ours stepping)
		(ln as Object).set_meta("np_phased", true)
		ln.set("_seen_tick", int(ph[2]) + d)
		ln.set("_owed", float(ph[3]))
	if int(ln.get("_stagger")) != want:
		ln.set("_stagger", want)
		phase_set += 1
	phased += 1
	if (ph as Array).size() >= 5:
		if posmod(int(ph[4]) + d - int(path.run.stepped_tick), stride) == 0:
			phase_ok += 1
		else:
			phase_off += 1
	return true


# Reconcile, don't rebuild (dev/belt_api.md). Our rows stay. Identity is an alias map per
# belt, host seq -> our seq: a host row we know is matched; a new host seq takes a row of
# ours of the same kind and speed within ALIAS_M of its place (a seq the host renewed at a
# joint or a rebase - before, that row was boarded a second time and the old one taken off
# later: the short-lived mid-belt ghosts); only when nothing matches is it boarded with
# board_record. A matched row more than NUDGE_M from the host's place is taken off and
# boarded again there (the nudge). All take-offs (gone rows, nudges) come before the
# boards, highest index first. Rows are indexed from run.first(), not 0 (as host capture does).
const NUDGE_M := 0.35
# Phase-synced moving rows: nudged only this far off. INF = no nudge at all for them: the
# guest then had 0.00 % jumps, but rows our ends or frozen machines held stayed metres off
# (p95 126 cm); 1.0 m: 0.11-0.20 % jumps, p50 1 cm, p95 14-21 cm (dev/belt_phase.md).
const FAR_M := 1.0
# A row the host renamed (a new seq, mostly at a joint) is found by kind and speed near its
# place. A moving row jumps a whole step at a time (stride 4: ~4.6 cm at plain speed, more
# boosted), so a fixed 5 cm missed most of them: we boarded a fresh row and dropped ours, one
# short-lived body per joint crossing. Moving rows: a window that grows with the step, at
# least ALIAS_RUN_M; parked rows don't move, so ALIAS_M.
const ALIAS_M := 0.05
const ALIAS_RUN_M := 0.6
const ALIAS_STEPS := 4.0
var _alias := {}   # belt key -> {host seq: our seq}
var aliased := 0   # test counters
var boarded := 0
var removed := 0
var nudged := 0

const SEAM_GRACE_MS := 600
var _word_seqs := {}    # belt key -> {host seq: true} in the host's latest word
var _pend_since := {}   # belt key -> {host seq: msec} waiting for our own hand-over
var _keep_since := {}   # belt key -> {our seq: msec} kept while the host has it next door
# ---------------------------------------------------------------- forks (splitters)
#
# A splitter picks a route per row and points its feeder at it (feeder.downstream =
# route(side)); the core then hands the row over that seam itself. On a guest the splitter
# is frozen, so the feeder stayed pointed at one route and every row went down it; the
# host's word then took it off there and put a second body on the other route. Now our
# feeder's end is held and its head row waits at the mouth until a route's word from the
# host carries its seq. That names the route: the feeder is pointed there and let go, and
# the core hands the row over as it would have, seq and all; when it is across
# (caught_record on the route) the end is held again. Not named within FORK_WORDS of the
# fork's words (a word lost, a far fork), the head goes down the route the feeder points
# at. A row already on the wrong route is moved across (our row, its seq kept).
const FORK_MOUTH_M := 0.35   # a row this close to the feeder's end waits at the mouth
const FORK_WORDS := 2.0      # not named within this many of the fork's words: fallback
const FORK_LET_GO_MS := 1000  # let go and nothing came over: hold again (a picked head is let go up to PICK_AHEAD_S early)
var _fork_routes := {}  # feeder key -> [route keys]
var _fork_of := {}      # route key -> feeder key
var _fork_head := {}    # feeder key -> [our seq at the mouth, msec it got there]
var _fork_open := {}    # feeder key -> [our seq let go, msec]
var _picks := {}        # feeder key -> [host seq of its head, route key, msec]: the host's pick
const PICK_AHEAD_S := 0.5   # a picked head this close (in time) to the mouth is let go now
const PICK_OLD_MS := 2500
var fork_picked := 0
const MOVE_AGAIN_MS := 1000
var _moved_at := {}     # our seq -> msec it was last moved across routes    # test counter: heads let go on the host's pick, no wait
var fork_steered := 0   # test counters
var fork_wrong_moved := 0
var fork_fallback := 0
var fork_rehold := 0
var fork_stuck := 0
var fork_cross_ok := 0
var both_routes := 0
var fork_cross_open := 0
var fork_cross_held := 0
var fork_wait_ms_near := 0  # time rows stood at the mouth: the cost of holding
var fork_wait_n_near := 0
var fork_wait_ms_far := 0
var fork_wait_n_far := 0

func _map_forks() -> void:
	_fork_routes.clear()
	_fork_of.clear()
	_moved_at.clear()
	var b: Variant = world.get("builds") if world != null and is_instance_valid(world) else null
	var sps: Variant = b.get("splitters") if b != null and is_instance_valid(b) else null
	if not (sps is Array):
		return
	for sp in sps:
		if sp == null or not is_instance_valid(sp) or not sp.has_method("routes") or not sp.has_method("feeder"):
			continue
		var f: Variant = sp.call("feeder")
		if not (f is Node) or not is_instance_valid(f):
			continue
		var fk := _key_of(f)
		if fk == "" or not _paths.has(fk):
			continue
		var rks: Array = []
		for r in sp.call("routes"):
			if r is Node and is_instance_valid(r):
				var rk := _key_of(r)
				if rk != "" and _paths.has(rk) and rk != fk:
					rks.append(rk)
		if rks.size() < 2:
			continue
		_fork_routes[fk] = rks
		for rk in rks:
			_fork_of[rk] = fk
			if not (_down[fk] as Array).has(rk):
				_down[fk].append(rk)
			if not _up.has(rk):
				_up[rk] = []
			if not (_up[rk] as Array).has(fk):
				_up[rk].append(fk)
			for rk2 in rks:
				if rk2 != rk and not (_sib[rk] as Array).has(rk2):
					_sib[rk].append(rk2)


func _fork_gap(fk: String) -> int:
	var g := int(_word_gap.get(fk, 0))
	for rk in _fork_routes.get(fk, []):
		g = maxi(g, int(_word_gap.get(rk, 0)))
	return maxi(g, int(TICK * 1000.0))


# Let the head go down route rk: point the feeder there and open its end.
func _fork_let_go(fk: String, rk: String, y: int) -> void:
	var f: Variant = _paths.get(fk)
	var r: Variant = _paths.get(rk)
	if f == null or r == null or not is_instance_valid(f) or not is_instance_valid(r):
		return
	if f.get("downstream") != r:
		f.downstream = r
	# what the splitter does for its open side (_apply_catching): only that route catches;
	# frozen, it left the last one catching and the core would not hand a row to the other
	for rk2 in _fork_routes.get(fk, []):
		var r2: Variant = _paths.get(rk2)
		if r2 != null and is_instance_valid(r2) and r2.has_method("set_catching"):
			r2.set_catching(rk2 == rk)
	f.run.set_end_held(false)
	f.run.wake()
	_fork_open[fk] = [y, Time.get_ticks_msec()]
	var fh: Variant = _fork_head.get(fk)
	if fh != null and int(fh[0]) == y:
		var waited_ms := Time.get_ticks_msec() - int(fh[1])
		if _fork_gap(fk) > SEAM_GRACE_MS:
			fork_wait_ms_far += waited_ms
			fork_wait_n_far += 1
		else:
			fork_wait_ms_near += waited_ms
			fork_wait_n_near += 1
	_fork_head.erase(fk)


func _watch_forks() -> void:
	if _fork_routes.is_empty():
		return
	var now := Time.get_ticks_msec()
	for fk in _fork_routes:
		var f: Variant = _paths.get(fk)
		if f == null or not is_instance_valid(f):
			continue
		var run: Variant = f.run
		var op: Variant = _fork_open.get(fk)
		if op != null:
			if now - int(op[1]) < FORK_LET_GO_MS:
				continue   # let go, waiting for it to come over
			_fork_open.erase(fk)
			fork_stuck += 1
			if stuck_tap.is_valid():
				var d0: Variant = f.get("downstream")
				var tr: Variant = d0.run if d0 != null and is_instance_valid(d0) else null
				stuck_tap.call("end_held=%s outlet_held=%s linked=%s route_catching=%s route_blocked=%s blocked=%s" % [
					run.end_held, run.outlet_held, run.downstream == tr and tr != null,
					tr.catching if tr != null else "-", tr.blocked if tr != null else "-", run.blocked])
		if not bool(run.end_held):
			run.set_end_held(true)
			fork_rehold += 1
		if int(run.count()) == 0:
			_fork_head.erase(fk)
			continue
		var h := int(run.first())   # rows are kept front first
		var y := int(run.seq_of(h))
		# the host's pick for this very row (by seq, through our alias): let it go now
		var pk: Variant = _picks.get(fk)
		if pk != null and now - int(pk[2]) < PICK_OLD_MS and (_fork_routes[fk] as Array).has(String(pk[1])):
			var hx := y
			var am: Dictionary = _alias.get(fk, {})
			for hk in am:
				if int(am[hk]) == y:
					hx = int(hk)
					break
			var lead := absf(float(run.speed_of(h))) * PICK_AHEAD_S
			if int(pk[0]) == hx and float(run.s_of(h)) >= _run_len(run) - maxf(FORK_MOUTH_M, lead):
				fork_picked += 1
				_fork_let_go(fk, String(pk[1]), y)
				continue
		if float(run.s_of(h)) < _run_len(run) - FORK_MOUTH_M:
			_fork_head.erase(fk)
			continue
		var fh: Variant = _fork_head.get(fk)
		if fh == null or int(fh[0]) != y:
			_fork_head[fk] = [y, now]
			continue
		var named := _fork_named(fk, y)
		if named != "":
			fork_steered += 1
			_fork_let_go(fk, named, y)
			continue
		if now - int(fh[1]) > int(FORK_WORDS * _fork_gap(fk)):
			# not named in time: the route the feeder points at
			var rk: String = (_fork_routes[fk] as Array)[0]
			var d: Variant = f.get("downstream")
			if d != null and is_instance_valid(d) and (_fork_routes[fk] as Array).has(_key_of(d)):
				rk = _key_of(d)
			fork_fallback += 1
			_fork_let_go(fk, rk, y)


# The route the host sent our head row down, if a word shows it there or on the belt
# after (a short route on a far fork is often passed before its next word).
func _fork_named(fk: String, y: int) -> String:
	var hx := y
	var am: Dictionary = _alias.get(fk, {})
	for h in am:
		if int(am[h]) == y:
			hx = int(h)
			break
	for rk in _fork_routes[fk]:
		var ws: Dictionary = _word_seqs.get(rk, {})
		if ws.has(hx):
			return rk
		for dk in _down.get(rk, []):
			if (_word_seqs.get(dk, {}) as Dictionary).has(hx):
				return rk
	return ""


# A route's word carries host seq hx we don't have on it. Ours with that seq, at the head
# of the feeder's mouth: the route is named, let it go there. Already on the other route:
# moved across. Only a row we hold; true when it was one of those.
func _fork_pick(k: String, fk: String, hx: int, at: float, moves: Array, amap: Dictionary) -> bool:
	var f: Variant = _paths.get(fk)
	if f != null and is_instance_valid(f):
		var y := int((_alias.get(fk, {}) as Dictionary).get(hx, hx))
		var run: Variant = f.run
		if int(run.count()) > 0:
			var h := int(run.first())
			if int(run.seq_of(h)) == y and float(run.s_of(h)) > _run_len(run) - FORK_MOUTH_M:
				var op: Variant = _fork_open.get(fk)
				if op == null or int(op[0]) != y:
					_fork_let_go(fk, k, y)
					fork_steered += 1
				amap[hx] = y   # on its way over: matched when the core has handed it
				return true
		if _seq_s(run, y) >= 0.0:
			amap[hx] = y       # still behind the head: it waits its turn
			return true
	for sk in _sib.get(k, []):
		var sp: Variant = _paths.get(sk)
		if sp == null or not is_instance_valid(sp):
			continue
		if (_word_seqs.get(sk, {}) as Dictionary).has(hx):
			both_routes += 1
			continue   # the host lists it on that route too (a shared deck): not wrong there
		# that route's own pairing only (the feeder's can still pair our row with an older
		# host seq, and two routes then pulled the same row back and forth); and a row moved
		# across is left where it is for a while
		var y2 := int((_alias.get(sk, {}) as Dictionary).get(hx, hx))
		if Time.get_ticks_msec() - int(_moved_at.get(y2, -100000)) < MOVE_AGAIN_MS:
			continue
		if _seq_s(sp.run, y2) >= 0.0:
			_moved_at[y2] = Time.get_ticks_msec()
			moves.append([sp.run, y2, at, hx])
			amap[hx] = y2
			fork_wrong_moved += 1
			if ev_tap.is_valid():
				ev_tap.call("wrongmove", k, y2, sk, "hx=%d same=%s from_word_has_hx=%s to_old_alias=%s" % [hx, hx == y2, (_word_seqs.get(sk, {}) as Dictionary).has(hx), str((_alias.get(k, {}) as Dictionary).get(hx, "-"))])
			return true
	return false


# Our row `seq` off `from_run`, onto belt `to_key` at `at`, keeping its seq.
func _move_row(from_run: Variant, seq: int, to_key: String, at: float) -> bool:
	var to: Variant = _paths.get(to_key)
	if to == null or not is_instance_valid(to):
		return false
	for i in range(int(from_run.first()), int(from_run.first()) + int(from_run.count())):
		if int(from_run.seq_of(i)) == seq:
			var rec: Dictionary = from_run.record(i)
			rec.erase("xform")
			from_run.remove_at(i)
			_board(to.run, rec, at, -1.0)
			from_run.wake()
			to.run.clock_live = true
			to.run.wake()
			return true
	return false


# Guest: our core handed a row over a seam onto `path`. If that belt already had a row with
# the same seq (we boarded the host's copy there when our hand-over came late), the one that
# just came over is the second body: it goes once the flush is done (not inside it).
var _dedup_due := {}
var dup_caught := 0     # test counter

func _on_caught(seq: int, _kind: Variant, _strand: Variant, path: Node) -> void:
	if mp == null or mp.is_host:
		return
	if not _fork_of.is_empty():
		var fk: String = _fork_of.get(_key_of(path), "")
		var op: Variant = _fork_open.get(fk) if fk != "" else null
		if op != null and int(op[0]) == seq:
			_fork_open.erase(fk)
			_rehold.call_deferred(fk)
			fork_cross_ok += 1
		elif fk != "":
			if op != null:
				fork_cross_open += 1   # another row went through while it was open
			else:
				fork_cross_held += 1   # a row went over a held end
	if _dedup_due.is_empty():
		_dedup_seams.call_deferred()
	_dedup_due[path.get_instance_id()] = path


func _rehold(fk: String) -> void:
	var f: Variant = _paths.get(fk)
	if f != null and is_instance_valid(f) and not _fork_open.has(fk):
		f.run.set_end_held(true)


func _dedup_seams() -> void:
	var due := _dedup_due
	_dedup_due = {}
	for id in due:
		var path: Variant = due[id]
		if path == null or not is_instance_valid(path):
			continue
		var run: Variant = path.run
		var seen := {}
		var twice: Array = []
		for i in range(int(run.first()), int(run.first()) + int(run.count())):
			var q := int(run.seq_of(i))
			if seen.has(q):
				twice.append(i)
			seen[q] = true
		twice.reverse()
		for i in twice:
			run.remove_at(i)
			dup_caught += 1


var dup_rows := 0       # test counter: a second row of ours with a seq already on the belt
var remove_short := 0   # test counters: rows remove_at left on, rows a board added beyond one
var board_extra := 0
var crossed := 0        # test counters
var waited := 0
var kept_seam := 0

const SEAM_M := 0.6
# A belt far from every player gets a word only with the full tick (~2 s), so a row handed
# over a seam there is always older than a flat grace when the next word comes, and has
# gone further than SEAM_M: it was dropped by arithmetic. The grace is the feeder belt's
# own word interval (a little over it), and off a far feeder the seam reaches further.
const SEAM_FAR_M := 1.5
# How far along the line a row of ours may be from the host's and still be the same row
# across belts: up to LINE_HOPS belts away (a short corner is passed within one word, and
# on ramps our rows ran a belt or two ahead of the host's), as far as a row goes in the
# time we allow (its speed x the grace), at least the seam.
const LINE_HOPS := 3
var _line_cache := {}   # belt key -> [[key, -1 before / +1 after, metres in between]]

func _line_near(k: String) -> Array:
	if _line_cache.has(k):
		return _line_cache[k]
	var out: Array = []
	for dir in [1, -1]:
		var seen := {k: true}
		var frontier: Array = [[k, 0.0]]
		for hop in LINE_HOPS:
			var nxt: Array = []
			for f in frontier:
				for d in (_down.get(f[0], []) if dir > 0 else _up.get(f[0], [])):
					if seen.has(d):
						continue
					seen[d] = true
					out.append([d, dir, f[1]])
					var dp: Variant = _paths.get(d)
					nxt.append([d, float(f[1]) + (_run_len(dp.run) if dp != null and is_instance_valid(dp) else 0.0)])
			frontier = nxt
	_line_cache[k] = out
	return out


func _reach_m(k: String, nk: String, v: float, grace_ms: int) -> float:
	return maxf(maxf(_seam_m(k), _seam_m(nk)), v * float(grace_ms) / 1000.0)

var _word_at := {}    # belt key -> msec of its last word
var _word_gap := {}   # belt key -> msec between its last two words

func _grace_ms(feeder: String) -> int:
	return maxi(SEAM_GRACE_MS, int(float(_word_gap.get(feeder, 0)) * 1.25))


func _seam_m(feeder: String) -> float:
	return SEAM_FAR_M if int(_word_gap.get(feeder, 0)) > SEAM_GRACE_MS else SEAM_M


# Guest: rows our player took off a belt, by the host's number -> msec (see mp_props)
const TAKEN_MS := 1500
var _taken := {}

func note_taken(host_seq: int) -> void:
	if host_seq < 0:
		return
	var now := Time.get_ticks_msec()
	if _taken.size() > 32:
		for s in _taken.keys():
			if now - int(_taken[s]) >= TAKEN_MS:
				_taken.erase(s)
	_taken[host_seq] = now


# Guest: the host's number for a row of ours (rows can be renamed, see _alias).
func host_seq_for(path: Node, seq: int) -> int:
	var am: Dictionary = _alias.get(_key_of(path), {})
	for hx in am:
		if int(am[hx]) == seq:
			return int(hx)
	return seq


func _seq_s(run: Variant, seq: int) -> float:
	for i in range(int(run.first()), int(run.first()) + int(run.count())):
		if int(run.seq_of(i)) == seq:
			return float(run.s_of(i))
	return -1.0


func _run_len(run: Variant) -> float:
	var l: Variant = run.get("_length")
	return float(l) if l != null else 0.0


var word_tap := Callable()
var ev_tap := Callable()
var stuck_tap := Callable()  # test tools only: why a let-go row did not come over     # test tools only: ("walias"|"forced", key, seq, ...)
var _cur_k := ""   # test tools only (mp_control "caught"): (key, host rows, alias map)

func _restore(path: Node, rows: Array, synced := false) -> void:
	var run: Variant = path.run
	var k := _key_of(path)
	_cur_k = k
	# the host's word is half a ping old by now: moving rides went on that far
	var late := clampf(float(mp.pings.get(multiplayer.get_unique_id(), 0)) / 2000.0, 0.0, 0.3)
	if synced:
		# the host sent where a row is drawn; our rows sit where our last step left them
		late -= _step_lead(path)
	var mine: Array = []       # [seq, s, kind, speed, index]
	var by_seq := {}
	var dup_at: Array = []     # a second row of ours with a seq already on this belt
	for i in range(int(run.first()), int(run.first()) + int(run.count())):
		var row := [int(run.seq_of(i)), float(run.s_of(i)), int(run.kind_of(i)), float(run.speed_of(i)), i]
		if by_seq.has(row[0]):
			# two bodies of one row: our core handed it over a seam onto a belt where we
			# had boarded the host's copy. Matching by seq can't tell them apart, so the
			# second never went: the guest's extra rows. It goes now.
			dup_rows += 1
			dup_at.append(i)
			continue
		mine.append(row)
		by_seq[row[0]] = row
	var old: Dictionary = _alias.get(k, {})
	var amap := {}
	var used := {}
	var boards: Array = []     # [host row, s]
	var nudge_at: Array = []   # our indexes to take off before boarding again
	var step_s := float(maxi(int(run.stride_ticks), 1)) / float(Engine.physics_ticks_per_second)
	var rest: Array = []       # [host row, at] the host renamed or we lack
	# first every row we know by its seq (or its alias), so a rename can't take one of those
	var now_t := Time.get_ticks_msec()
	for h in rows:
		if not (h is Dictionary):
			continue
		var r: Dictionary = h
		var hs := int(r.get("seq", -1))
		# one our player just took off: the host's words still name it until it has taken
		# its own (one round trip), and boarding it again made it pop back for a moment
		if _taken.has(hs):
			if now_t - int(_taken[hs]) < TAKEN_MS:
				continue
			_taken.erase(hs)
		var v := float(r.get("speed", 0.0))
		var at := float(r.get("s", 0.0)) + (v * late if v > 0.0 else 0.0)
		var ls := int(old.get(hs, hs))
		if by_seq.has(ls) and not used.has(ls):
			used[ls] = true
			# on a phase-synced belt a moving row keeps in step by itself; only one our ends
			# or frozen machines held back (or let go) is put right, from FAR_M off
			if absf(float(by_seq[ls][1]) - at) > (FAR_M if synced and v > 0.0 else NUDGE_M):
				nudge_at.append(int(by_seq[ls][4]))
				boards.append([r, at])
			else:
				amap[hs] = ls
		else:
			rest.append([r, at])
	# rows at a joint (dev/belt_joints.md): the host's seq, through the alias of the belts
	# around, may name a row our core already handed onto this belt (alias it), or one it
	# still has on the belt before or already on the belt after (our step is a little
	# behind or ahead of the host's: wait for our own hand-over, don't board a second body).
	# A row on another branch of a fork is not waited for: it went the other way here.
	var near: Array = (_up.get(k, []) as Array) + (_down.get(k, []) as Array)
	var now := Time.get_ticks_msec()
	var pend_old: Dictionary = _pend_since.get(k, {})
	var pend := {}
	var rest2: Array = []
	var moves: Array = []      # [from run, our seq, at, host seq]: rows moved here, seq kept
	var fk_here: String = _fork_of.get(k, "")
	for e in rest:
		var hx := int((e[0] as Dictionary).get("seq", -1))
		var found := false
		if fk_here != "" and _fork_pick(k, fk_here, hx, float(e[1]), moves, amap):
			continue
		for nk in near + (_sib.get(k, []) as Array):
			var y := int((_alias.get(nk, {}) as Dictionary).get(hx, hx))
			if by_seq.has(y) and not used.has(y):
				amap[hx] = y
				used[y] = true
				crossed += 1
				found = true
				break
		if not found:
			var hv := absf(float((e[0] as Dictionary).get("speed", 0.0)))
			for ln in _line_near(k):
				var nk: String = ln[0]
				var np: Variant = _paths.get(nk)
				if np == null or not is_instance_valid(np):
					continue
				var y := int((_alias.get(nk, {}) as Dictionary).get(hx, hx))
				var ys := _seq_s(np.run, y)
				if ys < 0.0:
					continue
				# metres along the line between our row and the host's spot here
				var dist: float = (_run_len(np.run) - ys) + float(ln[2]) + float(e[1]) if int(ln[1]) < 0 \
						else ys + float(ln[2]) + (_run_len(run) - float(e[1]))
				var grace := maxi(_grace_ms(k), _grace_ms(nk))
				if dist <= _reach_m(k, nk, hv, grace):
					var since := int(pend_old.get(hx, now))
					if now - since < grace:
						pend[hx] = since
						amap[hx] = y
						waited += 1
						found = true
				break
		if not found:
			rest2.append(e)
	_pend_since[k] = pend
	rest = rest2
	# and ours the host no longer has here but does on the belt before or after: the same
	# row a step off the host's at the joint. Kept for a short while, not dropped.
	var keep_old: Dictionary = _keep_since.get(k, {})
	var keep := {}
	var rev := {}
	for hx in old:
		rev[int(old[hx])] = int(hx)
	var my_len := _run_len(run)
	for row in mine:
		var y: int = row[0]
		if used.has(y):
			continue
		var hx := int(rev.get(y, y))
		var ys := float(row[1])
		# taken off by our player: a belt's last word can be older than the take, so it
		# would keep our copy for a moment (the item showed in the hand and on the belt)
		if _taken.has(hx) or _taken.has(y):
			continue
		# on a route: a row the host has on the other route stays (it is moved across)
		for nk in ((_sib.get(k, []) as Array) if fk_here != "" else []):
			if true:
				var ws_s: Dictionary = _word_seqs.get(nk, {})
				if ws_s.has(hx) or ws_s.has(y):
					var since_s := int(keep_old.get(y, now))
					if now - since_s < _grace_ms(nk):
						keep[y] = since_s
						used[y] = true
						amap[hx] = y
						kept_seam += 1
					break
				continue
		if used.has(y):
			continue
		for ln in _line_near(k):
			var nk: String = ln[0]
			var ws: Dictionary = _word_seqs.get(nk, {})
			var hq := hx if ws.has(hx) else (y if ws.has(y) else -1)
			if hq < 0:
				continue
			var np: Variant = _paths.get(nk)
			if np == null or not is_instance_valid(np):
				break
			var hs_s := float(ws[hq])
			# metres along the line between our row here and the host's there
			var dist: float = ys + float(ln[2]) + (_run_len(np.run) - hs_s) if int(ln[1]) < 0 \
					else (my_len - ys) + float(ln[2]) + hs_s
			var grace := maxi(_grace_ms(k), _grace_ms(nk))
			if _fork_routes.has(k):
				grace = maxi(grace, int((FORK_WORDS + 0.5) * _fork_gap(k)))
			if dist <= _reach_m(k, nk, absf(float(row[3])), grace):
				var since := int(keep_old.get(y, now))
				if now - since < grace:
					keep[y] = since
					used[y] = true
					amap[hx] = y
					kept_seam += 1
			break
	_keep_since[k] = keep
	# then the renamed ones, front to back, each on the nearest free row of ours of the same
	# kind and speed; a rename only re-points the alias, the row itself stays as it is
	rest.sort_custom(func(x, y): return float(x[1]) < float(y[1]))
	for e in rest:
		var r: Dictionary = e[0]
		var at: float = e[1]
		var v := float(r.get("speed", 0.0))
		var win := ALIAS_M
		if v > 0.0:
			win = maxf(ALIAS_RUN_M, v * (ALIAS_STEPS * step_s + absf(late)))
		var best: Variant = null
		var best_d := win
		for row in mine:
			if used.has(row[0]) or int(row[2]) != int(r.get("kind", -1)):
				continue
			if absf(float(row[3]) - v) > 0.0005 and v > 0.0 and float(row[3]) > 0.0:
				continue  # both moving, at other speeds: not the same row
			var d := absf(float(row[1]) - at)
			if d <= best_d:
				best_d = d
				best = row
		if best != null:
			amap[int(r.get("seq", -1))] = best[0]
			used[best[0]] = true
			aliased += 1
			if ev_tap.is_valid():
				ev_tap.call("walias", k, int(best[0]), float(best[3]), v, best_d)
		else:
			boards.append([r, at])
	var touched := false
	# off first: what the host no longer has and the nudged rows (the same seq goes
	# straight back on), highest index first - a board into a place a stale row still
	# holds is moved or refused by the core's boarding rules
	var drop: Array = []
	for i in range(int(run.first()), int(run.first()) + int(run.count())):
		if not used.has(int(run.seq_of(i))):
			drop.append(i)
	var gone_seqs := {}
	if word_tap.is_valid():
		for i in drop:
			gone_seqs[int(run.seq_of(i))] = float(run.s_of(i))
	drop.append_array(nudge_at)
	drop.append_array(dup_at)
	drop.sort()
	drop.reverse()
	var n_before := int(run.count())
	for i in drop:
		run.remove_at(i)
		touched = true
	remove_short += drop.size() - (n_before - int(run.count()))
	removed += drop.size() - nudge_at.size()
	nudged += nudge_at.size()
	var n_mid := int(run.count())
	for m in moves:
		if _move_row(m[0], int(m[1]), k, float(m[2])):
			amap[int(m[3])] = int(m[1])
			touched = true
		else:
			# gone from the other route after all: the host's row, as before
			for e in rest:
				if int((e[0] as Dictionary).get("seq", -1)) == int(m[3]):
					boards.append(e)
	for b in boards:
		var r: Dictionary = (b[0] as Dictionary).duplicate()
		r.erase("xform")
		_board(run, r, float(b[1]), float(path.length) if "length" in path else -1.0)
		var hs := int(r.get("seq", -1))
		amap[hs] = hs
		boarded += 1
		touched = true
	board_extra += (int(run.count()) - n_mid) - boards.size()
	_alias[k] = amap
	if word_tap.is_valid():
		word_tap.call(k, rows, amap, gone_seqs, int(run.count()))
	if touched:
		run.clock_live = true
		run.wake()
		if path.has_method("wake"):
			path.wake()


# board_record refused 37 % of the guest's boards (measured): mostly a spot a row of ours
# held (ours sit a few cm off the host's), and whole belts the guest's core thought had no
# room or weren't catching, even empty ones. A refused row was tried again with every
# message and, once it got on, popped up mid-belt. So: the nearest free spot within
# BOARD_SLIDE_M first, and if the core still says no, the row goes in by hand.
const BOARD_SLIDE_M := 0.2
const BOARD_SLIDE_STEP := 0.02
var board_slid := 0     # test counters
var board_refused := 0
var board_forced := 0

func _board(run: Variant, r: Dictionary, at: float, length: float) -> bool:
	if length > 0.0:
		at = clampf(at, 0.0, length)
	var v := float(r.get("speed", 0.0))
	if bool(run.board_record(r, at, v, 0)):
		return true
	var reach := float(r.get("reach", 0.0))
	var gap := float(r.get("gap", 0.0))
	var kind := int(r.get("kind", 0))
	var d := BOARD_SLIDE_STEP
	while d <= BOARD_SLIDE_M + 0.0001:
		for x in [at - d, at + d]:
			if x < 0.0 or (length > 0.0 and x > length):
				continue
			if bool(run.accepts(x, reach, gap, kind)) and bool(run.board_record(r, x, v, 0)):
				board_slid += 1
				return true
		d += BOARD_SLIDE_STEP
	# the guest's core still says no (it does on belts it thinks have no room or don't catch,
	# even empty ones; the host's word is what counts here): put the row in by hand, at its
	# place in the list (front first, highest s first), and tell the core it boarded
	if run.has_method("_insert_row"):
		var f := int(run.first())
		var n := int(run.count())
		var idx := f + n
		for i in range(f, f + n):
			if at > float(run.s_of(i)):
				idx = i
				break
		run._insert_row(idx, at, reach, gap, float(r.get("side", 0.0)), float(r.get("lift", 0.0)), v,
			kind, int(r.get("strands", 0)), int(r.get("needle", -1)), int(r.get("seq", 0)),
			r.get("state", {}) if r.get("state") is Dictionary else {})
		run._ev_board(idx)
		board_forced += 1
		if ev_tap.is_valid():
			var nd := 99.0
			for i in range(int(run.first()), int(run.first()) + int(run.count())):
				if i != idx:
					nd = minf(nd, absf(float(run.s_of(i)) - at))
			ev_tap.call("forced", _cur_k, int(r.get("seq", 0)), nd, at)
		return true
	board_refused += 1
	return false


# Kept for the test tools (mp_control beltlog): how long since a belt's last step.
func _step_lead(path: Variant) -> float:
	var run: Variant = path.get("run")
	if run == null or not is_instance_valid(run) or not run.has_method("lead_seconds"):
		return 0.0
	return clampf(float(run.call("lead_seconds", Engine.get_physics_interpolation_fraction(),
		Engine.get_physics_frames())), 0.0, 0.25)
