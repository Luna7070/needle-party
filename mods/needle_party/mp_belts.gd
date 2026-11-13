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
	"words": "applied", "full_words": "full_seen", "outlet_held": "outlet_held_set", "fast_words": "fast_words",
	"sw_words": "sw_words", "sw_inserted": "sw_inserted", "sw_removed": "sw_removed", "sw_reput": "sw_reput",
	"sw_rebuilt": "sw_rebuilt", "sw_nostat": "sw_nostat", "sw_lost": "sw_lost", "sw_old": "sw_old",
	"sw_shown": "sw_shown", "sw_local": "sw_local"}


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
	var phv: Variant = e.get("ph")
	var ph: Array = phv if phv is Array else [0, 0]
	var stride := int(ph[1]) if ph.size() > 1 else 0
	var bid := "b%06x" % (k.hash() & 0xffffff)
	var odd := lag >= BELTW_LAG_MS
	if path != null and is_instance_valid(path) and stride > 0 and int(path.run.stride_ticks) != stride:
		odd = true
	mp.trace.beltw(bid, "beltw belt=%s rows=%d seq0=%d seq1=%d phase=%d stride=%d lag_ms=%d" % [bid, rows.size(), seq0, seq1,
		int(ph[0]) if ph.size() > 0 else 0, stride, lag], odd)


# Hand the belt ends back, in case the world outlives the session.
func shutdown() -> void:
	if replay_on:
		replay_on = false
		_sw_release_all()
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
		var us := Time.get_ticks_usec() - t0
		mp.perf("belts", us)
		if replay_on:
			if _us_ring.size() != 2048:
				_us_ring.resize(2048)
			_us_ring[_us_ring_i & 2047] = us
			_us_ring_i += 1


func _process_inner(delta: float) -> void:
	if mp == null or not mp.active():
		if replay_on:
			set_replay(false)   # left the session: our belts run on their own again at once
		return
	if not mp.is_host:
		# (belt replay, L2) the switch, read every frame (F9 panel, dev command)
		if _sw_quiet and not replay_on:
			_sw_quiet_tick()   # (F59) off after a silence of the host: on again by itself
		var want_rp := bool(mp.get("belt_replay")) if mp.get("belt_replay") != null else false
		if want_rp != replay_on and (not want_rp or _sw_core != 0):
			set_replay(want_rp)
		if replay_on:
			_sw_tick()
			return
		# (2026-11-13) each part timed on its own in the perf list (belts.unpack ...)
		var tg := Time.get_ticks_usec()
		if not _pending.is_empty() and _apply_slot.take():
			var p: Array = _pending.pop_front()
			_unpack(p[0], p[1])
			mp.perf("belts.unpack", Time.get_ticks_usec() - tg)
		tg = Time.get_ticks_usec()
		_drain()
		mp.perf("belts.drain", Time.get_ticks_usec() - tg)
		tg = Time.get_ticks_usec()
		_watch_forks()
		mp.perf("belts.forks", Time.get_ticks_usec() - tg)
		return
	if multiplayer.multiplayer_peer == null or mp.players.size() < 2:
		return
	# (belt replay, L2) the belt stream: the belts that stepped since the last word, right after
	# (in a frame, where the drawer's lead and the clock agree), at most every ST_SEND_MS
	if not _st_peers.is_empty() and Time.get_ticks_msec() - _st_sent_at >= st_send_ms:
		_st_sent_at = Time.get_ticks_msec()
		_st_send_all()
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
#
# (2026-11-13) This ran four times a second over every belt of the yard (840 in the test
# save) and cost the host 10-60 ms each time: a hitch the guest felt as lag too. Now:
# a belt's box for "near" is kept (it was rebuilt from all its line points every time),
# an empty belt costs one count() call, and the bytes compare (var_to_bytes of every belt)
# is only done for belts that stand still: rows that move never match the last word.
# The time of each part goes into the mod's perf list (belts.rows, belts.pack ...).
var _box := {}   # host: belt instance id -> [line point count, AABB grown by NEAR_M]
const _EMPTY := "-"
# host: the belts near a player, found again once a second (NEAR_M is 40 m, nobody walks
# that far in a second); the near words in between only walk these, not the whole yard
const NEAR_LIST_MS := 1000
var _near_list: Array = []
var _near_at := -100000

func send_all(pid: int = 0) -> void:
	# (belt replay, L2) guests that take the belt stream get no words of this kind; with none
	# of them this is exactly the way before
	var to: Array = []
	if pid == 0 and not _st_peers.is_empty():
		for id in mp.players:
			if int(id) != 1 and not _st_peers.has(int(id)):
				to.append(int(id))
		if to.is_empty():
			return
	var t0 := Time.get_ticks_usec()
	var full := pid > 0 or _since >= FULL_TICK
	var spots := [] if full else _player_spots()
	var rows_out: Array = []
	var live := {}
	var t_rows := 0
	var walk: Array = BeltPath._live
	if not full:
		var now_ms := Time.get_ticks_msec()
		if now_ms - _near_at >= NEAR_LIST_MS or _near_list.is_empty():
			_near_at = now_ms
			_near_list.clear()
			for p in BeltPath._live:
				if is_instance_valid(p) and p.is_inside_tree() and _near(p, spots):
					_near_list.append(p)
		walk = _near_list
	for path in walk:
		if not is_instance_valid(path) or not path.is_inside_tree():
			continue
		var k := _key_of(path)
		if k == "":
			continue
		if full:
			live[k] = true
		var run: Variant = path.run
		var n := int(run.count())
		if n == 0:
			# an empty belt: nothing to build; say so once when it empties, and in a full word
			if pid == 0:
				var was_empty: bool = _sent.get(k) is String
				_sent[k] = _EMPTY
				if was_empty:
					continue
			else:
				continue
			var ent := {"k": k, "r": []}
			# never a null "ph": _beltw and the guest read it into a typed Array, and in the
			# game's release build that null crashed the whole game (signal 11)
			var eph: Variant = _ph_of(path, run)
			if eph != null:
				ent["ph"] = eph
			rows_out.append(ent)
			continue
		var tr := Time.get_ticks_usec()
		var rows: Array = []
		var lead := _step_lead(path)
		var moving := false
		var f0 := int(run.first())
		for i in range(f0, f0 + n):
			var row: Dictionary = run.record(i)
			row["gap"] = float(run.gap_of(i))
			# where it is drawn now, not where the belt's last step (up to 66 ms ago) left it
			var v := float(row.get("speed", 0.0))
			if v > 0.0:
				moving = true
				row["s"] = float(row.get("s", 0.0)) + v * lead
			row.erase("xform")
			if not (row.get("state") is Dictionary):
				row["state"] = {}
			rows.append(row)
		t_rows += Time.get_ticks_usec() - tr
		var entry := {"k": k, "r": rows}
		# (dev/belt_phase.md) the step phase of the belt's line: [_stagger, stride,
		# _seen_tick, _owed]. Sent with the rows every time, a stale stagger is worse than none.
		var ph: Variant = _ph_of(path, run)
		if ph != null:
			entry["ph"] = ph
		if pid == 0:
			if moving:
				# moving rows are never the same as last time: no bytes to compare
				_sent[k] = null
			else:
				var enc := var_to_bytes([rows, ph[0] if ph != null else 0, ph[1] if ph != null else 0])
				var prev: Variant = _sent.get(k)
				var same: bool = prev is PackedByteArray and prev == enc
				_sent[k] = enc
				if same and not full:
					continue
		rows_out.append(entry)
	mp.perf("belts.rows", t_rows)
	var tp := Time.get_ticks_usec()
	var data := {"b": rows_out, "full": full, "f": Engine.get_physics_frames(), "pk": _picks_now(),
		"ms": Time.get_ticks_msec()}
	for e in rows_out:
		_beltw(String(e["k"]), e, 0, null)
	if full and pid == 0:
		_since = 0.0
		for k in _sent.keys():
			if not live.has(k):
				_sent.erase(k)
		if _box.size() > live.size() * 2 + 64:
			_box.clear()
	if rows_out.is_empty() and not full:
		mp.perf("belts.scan", tp - t0 - t_rows)
		return
	var raw := var_to_bytes(data)
	var packed := raw.compress(FileAccess.COMPRESSION_ZSTD)
	if pid > 0:
		mp._rx_belts.rpc_id(pid, packed, raw.size())
	elif not to.is_empty():
		for id in to:
			mp._rx_belts.rpc_id(id, packed, raw.size())
	else:
		mp._rx_belts.rpc(packed, raw.size())
	mp.perf("belts.scan", tp - t0 - t_rows)
	mp.perf("belts.pack", Time.get_ticks_usec() - tp)


func _ph_of(path: Node, run: Variant) -> Variant:
	var ln: Variant = path.get("line")
	if ln is Object and "_stagger" in ln:
		return [int(ln.get("_stagger")), int(run.stride_ticks), int(ln.get("_seen_tick")), float(ln.get("_owed")), int(run.stepped_tick)]
	return null


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


const APPLY_NOW_M := 25.0   # guest: belt words this close to a player are applied at once

func _near(path: Node, spots: Array, reach := NEAR_M) -> bool:
	if spots.is_empty():
		return true
	var line: Variant = path.get("_line")
	if line == null or line.size() < 2:
		return true
	var id := path.get_instance_id()
	var c: Variant = _box.get(id)
	var box: AABB
	if c is Array and int(c[0]) == line.size():
		box = c[1]
	else:
		box = AABB(line[0], Vector3.ZERO)
		for p in line:
			box = box.expand(p)
		box = box.grow(NEAR_M)
		_box[id] = [line.size(), box]
	if reach != NEAR_M:
		box = box.grow(reach - NEAR_M)
	for at in spots:
		if box.has_point(at):
			return true
	return false


# (script replay) _near(path, [at], ST_PICK_M) with the belt's box kept 2 s (a word asks it of every belt)
var _pick_box := {}   # path instance id -> [msec, box grown by ST_PICK_M] (null box: no line, always near)

func _near_pick(path: Node, at: Vector3) -> bool:
	var id := path.get_instance_id()
	var c: Variant = _pick_box.get(id)
	var now := Time.get_ticks_msec()
	if not (c is Array) or now - int(c[0]) > 2000:
		var line: Variant = path.get("_line")
		var box: Variant = null
		if line != null and line.size() >= 2:
			var bx := AABB(line[0], Vector3.ZERO)
			for p in line:
				bx = bx.expand(p)
			box = bx.grow(ST_PICK_M)
		c = [now, box]
		_pick_box[id] = c
		if _pick_box.size() > 20000:
			_pick_box.clear()
	return c[1] == null or (c[1] as AABB).has_point(at)


# ------------------------------------------------------------------ guest

func on_belts(packed: PackedByteArray, raw_size: int) -> void:
	_pending.append([packed, raw_size])
	if _sw_quiet:
		_sw_quiet_rx()


func _unpack(packed: PackedByteArray, raw_size: int) -> void:
	if raw_size <= 0 or raw_size > MAX_RAW:
		return
	var t_dec := Time.get_ticks_usec()
	var data: Variant = bytes_to_var(packed.decompress(raw_size, FileAccess.COMPRESSION_ZSTD))
	mp.perf("belts.decode", Time.get_ticks_usec() - t_dec)
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
	_guest_spots = _player_spots()
	var listed := {}
	var t_loop := Time.get_ticks_usec()
	var t_w := 0
	for e in (data as Dictionary).get("b", []):
		if not (e is Dictionary):
			continue
		var k := String(e.get("k", ""))
		listed[k] = true
		var tw := Time.get_ticks_usec()
		_beltw(k, e, lag, _paths.get(k))
		t_w += Time.get_ticks_usec() - tw
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
	mp.perf("belts.beltw", t_w)
	mp.perf("belts.words", Time.get_ticks_usec() - t_loop - t_w)
	# (1.2.19) all of one message in the same frame: spread over frames, a ride the host
	# had just passed from one belt to the next was briefly on both or on neither
	# (2026-11-14) ... but a word with many belts (the full one every 2 s: every belt of the
	# yard) made an 8-16 ms frame on the test yard. Belts within APPLY_NOW_M of a player go all
	# in this frame (that is where a ride between two belts can be seen); the others follow over
	# the next frames within APPLY_BUDGET_US (the regular _drain() in _process).
	var td := Time.get_ticks_usec()
	var later: Array = []
	if not _guest_spots.is_empty():
		var now_keys: Array = []
		for k in _order:
			var p: Variant = _paths.get(k)
			if p != null and is_instance_valid(p) and (p as Node).is_inside_tree() \
			and not _near(p, _guest_spots, APPLY_NOW_M):
				later.append(k)
			else:
				now_keys.append(k)
		_order = now_keys
	_drain(true)
	_order.append_array(later)
	mp.perf("belts.apply", Time.get_ticks_usec() - td)
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
	# (2026-11-14, F58) a door after the joint can refuse a kind (a full machine's door, a
	# filter): the game then turns that row into an item at this end. Here that item was one
	# more than the host's and went to it as new (an eco brick every 2 s in a real session; in
	# the door test 35 hay wads in 30 s). Held like an end into a machine: the row waits here
	# until the host's word takes it away.
	if passes and _door_after(item):
		passes = false
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


func _door_after(item: Node) -> bool:
	var down: Variant = item.get("downstream")
	if not (down is Node) or not is_instance_valid(down):
		return false
	var door: Variant = (down as Node).get("_door_kind")
	return door is Callable and (door as Callable).is_valid()


var outlet_held_set := 0   # counter: outlets held (again) on this side
var _outlet_t := 0
var _outlet_keys: Array = []   # the round's belt keys, OUTLET_STEP of them looked at per frame
var _outlet_i := 0
const OUTLET_STEP := 48        # (2026-11-15) all ~1100 belts in one frame were 2.3 ms every 2 s on a guest

# a machine can set its belt's hold again (its own setup, the yard's feeder bookkeeping)
func _recheck_outlets() -> void:
	if _outlet_i >= _outlet_keys.size():
		var now := Time.get_ticks_msec()
		if now - _outlet_t < 2000:
			return
		_outlet_t = now
		_outlet_keys = _paths.keys()
		_outlet_i = 0
	# (2026-11-14, F58) every belt, not only the ones held so far: a machine sets or clears the
	# door after its belt (a door that refuses a kind makes an end that has to be held)
	var end := mini(_outlet_i + OUTLET_STEP, _outlet_keys.size())
	for j in range(_outlet_i, end):
		var item: Variant = _paths.get(_outlet_keys[j])
		if item != null and is_instance_valid(item) and (item as Node).is_inside_tree():
			_hold_outlet(item as Node)
	_outlet_i = end


var _ts_joint := 0  # usec this frame inside _restore's long way, by part (perf list)
var _ts_keep := 0
var _ts_rename := 0
var _ts_change := 0
var _t_phase := 0   # usec this frame, for the perf list (belts.phase / .fast / .slow)
var _t_fast := 0
var _t_slow := 0

func _drain(all := false) -> void:
	if _order.is_empty():
		return
	_t_phase = 0
	_t_fast = 0
	_t_slow = 0
	_ts_joint = 0
	_ts_keep = 0
	_ts_rename = 0
	_ts_change = 0
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
		var tq := Time.get_ticks_usec()
		var synced := _phase(path, e.get("ph"))
		var tr := Time.get_ticks_usec()
		var fw := fast_words
		_restore(path, e.get("r", []), synced)
		var te := Time.get_ticks_usec()
		_t_phase += tr - tq
		if fast_words != fw:
			_t_fast += te - tr
		else:
			_t_slow += te - tr
		applied += 1
	_order = _order.slice(n)
	if mp != null:
		mp.perf("belts.phase", _t_phase)
		mp.perf("belts.fast", _t_fast)
		mp.perf("belts.slow", _t_slow)
		mp.perf("belts.s_joint", _ts_joint)
		mp.perf("belts.s_keep", _ts_keep)
		mp.perf("belts.s_rename", _ts_rename)
		mp.perf("belts.s_change", _ts_change)


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
# (2026-11-13) A belt further than NEAR_M from every player here: its rows are only checked
# by the host's full word every 2 s, and drift that far apart in between. Putting each back
# (off, then on again) was up to 200 rows per full word, 5-10 ms, on belts nobody can see.
# There a matched row is only moved when it is more than this far off; once a player comes
# within NEAR_M the near words (4 a second) put it right with the usual margins.
const IDLE_NUDGE_M := 2.5
var _guest_spots: Array = []   # guest: where the players are, taken once per message
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


var fast_words := 0     # test counter: belt words that matched as they were (see _restore)
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
	# (script replay) not drawn any more from this frame on
	if replay_on and _sw_script and table != null and is_instance_valid(table):
		table.call("taken", host_seq)


# Guest: the host's number for a row of ours (rows can be renamed, see _alias).
func host_seq_for(path: Node, seq: int) -> int:
	if replay_on:
		return seq   # (belt replay) every row of ours carries the host's number
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
	var idle := not _guest_spots.is_empty() and not _near(path, _guest_spots)
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
			var tol := FAR_M if synced and v > 0.0 else NUDGE_M
			if idle:
				tol = maxf(tol, IDLE_NUDGE_M)
			if absf(float(by_seq[ls][1]) - at) > tol:
				nudge_at.append(int(by_seq[ls][4]))
				boards.append([r, at])
			else:
				amap[hs] = ls
		else:
			rest.append([r, at])
	# (2026-11-13) The usual case: every host row matched one of ours by its seq (or alias),
	# in place, and we have no row the host lacks. Everything below would then find nothing
	# to do (no joint to wait for, no row to keep, rename, drop, nudge or board) and end with
	# the same alias map; it only cost time (4-8 ms per word on the test yard, a hitch every
	# word). Same result, straight away.
	if rest.is_empty() and nudge_at.is_empty() and dup_at.is_empty() and used.size() == mine.size():
		_pend_since[k] = {}
		_keep_since[k] = {}
		_alias[k] = amap
		fast_words += 1
		if word_tap.is_valid():
			word_tap.call(k, rows, amap, {}, int(run.count()))
		return
	var ts0 := Time.get_ticks_usec()
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
	var ts1 := Time.get_ticks_usec()
	_ts_joint += ts1 - ts0
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
	var ts2 := Time.get_ticks_usec()
	_ts_keep += ts2 - ts1
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
	var ts3 := Time.get_ticks_usec()
	_ts_rename += ts3 - ts2
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
	_ts_change += Time.get_ticks_usec() - ts3
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


# ------------------------------------------------------------------ belt replay (L2): the belt stream
#
# (2026-11-15, round 4: part of SMOOTH BELTS, on by default; mp.belt_replay is smooth belts on and the
# test switch belt_replay_off not set)
# (2026-11-15, test feature, switch mp.belt_replay, off by default) Needs the NEEDLE PARTY belt
# core (native/beltshim: our drop-in for the game's belt library, put in by the installer). On a
# guest with the switch on and that core there, our belts never step, link or hand rows on by
# themselves (np_stream_all): every row on them is one of the host's, put in with the host's
# number, in the host's order. The host sends a guest that asked for it (stream_ask) "step words":
# each belt within ST_NEAR_M of that guest right after the host's core stepped it (every ~67 ms;
# also when a row came or went in between), with its core's own state at that step: per row its
# number, its spot, its speed and how far it can still go (the numbers the host's drawer draws
# from), the time since that step, and the row's fixed fields (kind, size ...) in its first
# ST_STAT_WORDS words on a belt. Every other belt goes once in 2 s (ST_FAR_WORDS windows of 50 ms),
# then as where it is drawn and how far it really gets, carried on for ST_KEEP_FAR.
# The guest puts a word on when the host's clock, as we draw it, reaches the time of its latest
# step: the host's clock as the quickest word shows it, less an adaptive buffer (p95 of how late
# words come; ~25 ms on a LAN). Our core then answers for each row s + min(speed x time since its
# step, room), up to the step's length (np_stream_set), exactly what the host's drawer shows at
# that moment, so the game's own drawer draws the host's rows as the host draws them, the buffer
# later, with no stepping of our own. Only when the set of rows on a belt changes is our core's
# list changed (rows the host no longer has go, new ones are put in at the host's spot), so a row
# over a joint leaves one belt and appears on the next in the same frame, from the same word.
# Near the player our core's own spots are kept within ST_PICK_OFF of the drawn ones (aiming and
# picking a row up read them).
#
# Items: an item the host's belt took (word "bd": item id -> row number) goes in the frame its row
# is first shown (mp_props.rp_row_shown). Our own item that our belt catches stays as the row our
# core made, standing where it landed, until the host's row for it comes (then that one is shown);
# a row our player takes off a belt is gone here at once and not put back (note_taken).
# Without the core, or with a game build that lacks a function this needs: one line in the log,
# the switch has no effect (the belts run as before). Switch off: exactly the way before.
const ST_BUF_MIN := 6.0          # guest: we draw this many ms (at least) behind the host's clock ...
const ST_BUF_MAX := 250.0
const ST_BUF_MARGIN := 4.0       # ... p95 of how late the words come plus this
const ST_NEAR_M := 40.0          # host: "near" a stream guest
const ST_FAR_WORDS := 40         # host: every other belt once in this many words (2 s), spread over them
const ST_MOVING_MS := 80         # host: a belt with moving rows is looked at again at least this often
# Change-only near words (big yards): a belt goes again only when what the guest draws from its last
# word no longer matches the host (rows came or went, a speed changed, a row went further or less far
# than s + min(speed x t, room) says: something ahead moved or stopped), else at most every
# ST_KEEPALIVE_MS. Off by default for now (not measured enough yet; dev command stream_mode turns it
# on): every belt after every step of it, as measured in the work log step 85.
var st_change_only := false
const ST_KEEPALIVE_MS := 1000
const ST_MATCH_M := 0.002        # a row this close to where the last word says is "as sent"
# Upload budget per guest (belt stream only). Over it, belts away from the guest go less often first
# (by distance and behind the guest), the far belts' 2 s round becomes 4 / 8 s; the nearest stay exact.
var st_budget_kbs := 120.0
const ST_SEND_MS := 12           # host: stream words at most this often (a belt steps every ~67 ms)
var st_send_ms := ST_SEND_MS     # test tools only (F59: 2000 = the words of a yard with no belts)
const ST_STAT_WORDS := 2         # host: a row's fixed fields go with it in its first words on a belt
const ST_BD_MS := 400            # host: item -> row pairs go in every word this long (words can be lost)
const ST_SLACK := 0.04           # guest: a near belt's rows go on this long past the host's step length
                                 # (a word that came late, or one that waited for a later step in it)
const ST_KEEP_FAR := 2.6         # guest: rows of a far belt are carried on this long past its word (s)
const ST_PICK_M := 8.0           # guest: belts this close to the player keep our core's rows where they are drawn
const ST_PICK_OFF := 0.06        # ... put there again when further off than this (aim and pick-up read our core)
const ST_STALE_M := 2.0          # guest: other belts, further off than this
const ST_END_MARGIN := 0.05      # guest: our core never has a row this close to a belt's end
const ST_LOCAL_MS := 3000        # guest: our own catch waits this long for the host's row
const ST_LOCAL_SEQ := 1500000000 # guest: row numbers from here on are our own catches
# Game builds belt replay was tested on (Steam build ids). Another build (a game update) whose belt
# library still has every method this needs, with the same number of arguments (_sw_api_ok), runs
# replay ON PROBATION: for the first ST_PROBATION_MS of the session a health watch (_sw_health)
# compares what we show with what the host sent, and on a fault switches replay off for the
# session (np_stream_clear, the normal belts again, the next words put them right), with one log
# line saying why. A missing or changed method: the normal belts from the start.
const REPLAY_BUILDS := ["26646592"]
const ST_BUILD_WAIT_MS := 15000  # the build id not known after this long: taken as untested
const ST_PROBATION_MS := 300000
# what replay calls on a belt core (and on the script's BeltRun), with its number of arguments
const ST_API_GUEST := {"np_stream_all": 1, "np_stream_set": 3, "np_stream_keep": 1, "np_stream_clear": 0,
	"np_raw": 1, "np_core_version": 0, "_insert_row": 12, "_ev_board": 1, "remove_at": 1, "seqs": 0,
	"first": 0, "count": 0, "set_end_held": 1, "s_of": 1, "seq_of": 1, "length": 0}
const ST_API_HOST := {"seqs": 0, "positions": 0, "first": 0, "count": 0, "draw_into": 1, "lead_seconds": 2,
	"speed_of": 1, "row_room": 1, "has_head": 0, "kind_of": 1, "strands_of": 1, "needle_of": 1, "gap_of": 1,
	"reach_of": 1, "side_of": 1, "lift_of": 1, "state_of": 1}
# health limits (per 5 s, near belts; good runs: 0 of each except picks, see the work log step 85)
const HM_NO_WORD_MS := 3000      # no word put on for this long (host sends none, or none fit)
# (F59, 2026-11-16) No word for HM_NO_WORD_MS because none CAME (the host's game stood: a 12.6 s
# freeze while it compiled shaders after a build click, public 1.3.0 logs) is no fault of replay:
# off for now only. Once the host's normal belt words have come again with no gap longer than
# HM_BACK_GAP_MS for HM_BACK_MS, replay goes on again by itself (one log line). Each further time
# waits twice as long (at most HM_BACK_MAX_MS), so a bad link does not flip it on and off; once
# replay has run HM_CALM_MS since it last came on, the next pause waits HM_BACK_MS again. Words
# that kept coming and none fit, and every other fault, keep it off for the session.
const HM_GAP_MS := 1500          # no stream word came for this long: a silence (words come every 12-80 ms)
const HM_BACK_MS := 10000
const HM_BACK_MAX_MS := 120000
const HM_BACK_GAP_MS := 3500     # normal words: a full one every 2 s (FULL_TICK) at the least
const HM_CALM_MS := 600000       # replay ran this long since it last came on: the next pause waits HM_BACK_MS again
var sw_calm_ms := HM_CALM_MS     # test tools only
# (F59) A yard with few or no belts gets a stream word only every ~2 s (public 1.3.0 log, a yard with
# no buildings: 30 words a minute); a host hitch of 1.2 s then made "no word for 3 s" and replay was
# off for the session. The silence allowed grows by the longest of the last HM_GAPS_N gaps between
# words (at most HM_GAP_ALLOW_MS).
const HM_GAPS_N := 8
const HM_GAP_ALLOW_MS := 2500
var sw_gap_allow_ms := HM_GAP_ALLOW_MS   # test tools only (0 = the 3 s of 1.3.0)
const HM_LOST := 20              # rows our core lost not by our hand (a pick-up is one)
const HM_INSERT_FAIL := 5        # rows _insert_row did not add
const HM_MISSING_PCT := 2.0      # rows the host sent and our core does not hold after a word (%, at least 30)
const HM_NOSTAT := 60            # rows we could not put in (fixed fields never came)
const ST_CORE_RUN := ["np_stream_all", "np_stream_set", "np_stream_keep", "np_stream_clear", "np_raw",
	"np_core_version", "_insert_row", "_ev_board", "remove_at", "seqs", "positions", "first", "count",
	"set_end_held", "draw_into", "lead_seconds", "speed_of", "row_room", "seq_of", "s_of", "length"]
const ST_CORE_PROPS := ["end_held", "awake", "draw_queue", "draw_queued", "last_seq", "stepped_tick", "last_dt"]
# (2026-11-15, script replay) a guest without our core: the game's own belt core keeps stepping (a
# script cannot stop it), the host's rows go into the row table (mp_belt_replay.gd) that
# mp_belt_show.gd draws, and our core's rows are kept the host's (list sync, near the player near
# the drawn spot) for aim, pick-up and machines. What that calls on a run, with its argument count
# (the stock game has all of these, measured on build 26646592 with dev c_runapi):
const ST_API_SCRIPT := {"_insert_row": 12, "_ev_board": 1, "remove_at": 1, "seqs": 0, "first": 0, "count": 0,
	"set_end_held": 1, "s_of": 1, "seq_of": 1, "length": 0, "speed_of": 1, "row_room": 1, "row_group": 1,
	"rel_of": 1, "draw_into": 1, "lead_seconds": 2, "positions": 0, "kind_of": 1, "strands_of": 1, "needle_of": 1, "gap_of": 1,
	"reach_of": 1, "side_of": 1, "lift_of": 1, "state_of": 1, "line": 0, "cum": 0, "seg_bases": 0,
	"is_straight": 0, "basis_at_start": 0}
const ST_PROPS_SCRIPT := ["end_held", "awake", "draw_queue", "draw_queued", "last_seq"]
const ST_SEAM_M := 1.0           # script: a row this close to a joint may be on either belt in our core
var _sw_script := false          # guest: replay runs without our core (the row table draws)
var table: Node = null           # guest, script mode: the row table (mp_belt_replay.gd)
var _sw_local_next := ST_LOCAL_SEQ   # our own catches' numbers when the game has no set_next_seq
var sw_handed := 0               # test counters (script): rows our core handed over a joint by itself
var sw_seam_kept := 0            # ... kept on the next belt before the host's word said so
var sw_seam_skip := 0            # ... not put back on the belt before (our core is a step ahead there)
var sw_suspect := 0              # ... rows gone from our core near our player, not told as taken (yet)
var sw_moved := 0                # ... taken off another belt of ours to go in where the host has it
var _sw_core_at := {}            # (script) row seq -> path instance id our core had it on at our last word
var _sw_suspect := {}            # (script) row seq -> msec it went from our core near our player (taken?)
const ST_SUSPECT_MS := 300       # ... not put back for this long (our player's pick-up is told within it)

var replay_on := false       # guest: the stream replay runs now (the switch, and the core is there)
var _sw_core := -1           # guest: -1 not checked yet, 0 the core or a function is missing, 1 fine
var _sw_missing := ""
var core_version := ""
var game_build := ""         # the build id the check saw
var _sw_build_asked := -1
var probation := false       # guest: replay runs on an untested build, watched (_sw_health)
var _sw_probation_end := 0
var _sw_on_at := 0           # msec replay went on
var _sw_word_at := 0         # msec the last word was put on
var _hm_at := 0
var _hm_ring: Array = []     # per second: [lost, insert_fail, missing, wanted, nostat]
var _hm_now := [0, 0, 0, 0, 0]
var health := ""             # why replay went off this session ("" = it did not)
var _sw_heard_at := 0        # (F59) msec the last stream word came (put on or not)
var _sw_gap_end_at := -100000   # ... msec words came again after a silence of HM_GAP_MS
var _sw_ever_heard := false  # ... the host served us words this session (a host that never does: a fault)
var _sw_gaps := PackedInt32Array()   # ... the last HM_GAPS_N gaps between words that came (ms)
var _sw_quiet := false       # ... replay is off because the host was silent: it comes back by itself
var _sw_quiet_n := 0         # ... times this session
var _sw_quiet_need := HM_BACK_MS   # ... normal words with no gap for this long, then back on
var _sw_back_rx_at := 0      # ... msec the last normal belt word came while off
var _sw_back_from := 0       # ... msec they came again with no gap since (0: not yet)
var sw_backs := 0            # test counter: times replay came back on by itself
var sw_pauses := 0           # test counter: times replay went off because the host was silent
var hm_total := [0, 0, 0, 0, 0]   # the health counters since the start (the logs' minute line)
var _probation_noted := false
var sw_blinks := 0           # rows a word took off and a later word put back within 1 s (drawn gone for a while)
var _sw_gone := {}           # row seq -> [frame, msec] it was taken off
var sw_fault := ""           # test tools only: "drop" (words not put on) / "corrupt" (rows taken from our core)
var sw_fault_until := 0
var _st_api := -1            # host: -1 not checked, 0 the belt library lacks something, 1 fine

# ---- host
var _st_peers := {}          # guest peer id -> {"w": words, "near": [[path, kid]], "far": [[...] x ST_FAR_WORDS],
                             #   "at": msec the lists were made, "known": {kid: {seq: words}}, "n": {kid: rows sent},
                             #   "sig": {kid: [seqs, spots, deck shows stopped]} of standing belts}
var _st_bd: Array = []       # [item id, row seq, msec]
var _st_sent_at := -100000
var _st_kids := {}           # belt key -> its number in the words (hash; a clash gets the next free one)
var _st_kid_used := {}
var _st_buf := PackedFloat64Array()
var st_dup_keys := 0        # test counter (host): belts with the key of another belt (one stream id)
var st_bytes := 0            # test counters (host): bytes and words sent
var st_words := 0
var st_skipped := 0          # belts not sent: the guest's motion was still right (change-only)
var st_rate_kbs := 0.0       # last second to the last guest served
var st_level := 0            # budget level (0 = within)

# ---- guest
var _sw_pending: Array = []  # [packed, raw size, msec it came, true: it came while our frame stood (a stall)]
var _sw_queue: Array = []    # [host ms to put it on, word]
var _sw_at_last := -INF
var buffer_ms := 20.0
var _sw_q := -1
var _sw_stat := {}           # row seq -> [kind, strands, needle, gap, reach, side, lift, state]
var _sw_hp := {}             # belt number -> path
var _sw_held := {}           # path instance id -> [path, end held before]
var _sw_local := {}          # our row seq -> [item id, path, msec]: our own item our belt caught
var _sw_bd := {}             # item id -> [host row seq, msec]
var _sw_await := {}          # host row seq -> [item id, msec]: show the row, drop the item copy
var _sw_shown_now := {}      # row seqs put in or kept by a word this frame
var _sw_ask_at := -100000
var _off_ring: Array = []
var _off_min := INF
var _sw_late := PackedFloat32Array()   # how much later than the quickest the last words came (ms)
# (2026-11-15) a word that came while our own frame stood longer than this (and 3 x our usual frame)
# is no sample of the link: during our hitch nothing is drawn, after it the clock has moved on and
# the word goes on at once
const ST_STALL_US := 40000
var _sw_frame_avg := 0.0     # our usual frame (usec, slow average)
var st_buf_stall := true     # test tools only: false = every word is a sample (as in 51ccea6)
var sw_stood := 0            # test counter: words not taken as samples (our frame stood)
var sw_split := 0            # test counter: words whose belts went on over more than one frame
# test counters (guest)
var sw_words := 0
var sw_inserted := 0
var sw_removed := 0
var sw_reput := 0
var sw_rebuilt := 0
var sw_nostat := 0
var sw_lost := 0
var sw_old := 0
var sw_shown := 0
var sw_local := 0
var sw_eased := 0            # corrections our core glided (np_stream_counts) / put at once
var sw_snapped := 0
var _sw_counts_at := 0
var sw_tap := Callable()     # test tools only: (op, belt number, row seq, s)
var _sw_after := {}          # path id -> the row numbers our core had after our last word for it
# (script replay) usec this frame per part (perf list belts.sw.*) and a ring of whole frames (stats)
var _us_lost := 0
var _us_want := 0
var _us_put := 0
var _us_fix := 0
var _us_reput := 0
var _us_after := 0
var _us_deck := 0
var _us_tick := 0
var _us_misc := 0
var _us_words := 0
var _us_belts := 0
var _us_near := 0
var _us_rows := 0
# (dev) the guest's word work by kind since replay began, [count, usec] each: PC_NAMES
const PC_NAMES := ["table", "near", "core", "slow", "parse", "unpack", "deck", "outlets"]
var _pc := PackedInt64Array()
var _sw_core_last := false   # _sw_belt's last belt: its core was made the host's

var _pc_at := 0

# (dev) the cost block from now on (the frame ring, the slow frames, the word work by kind)
func cost_reset() -> void:
	_pc = PackedInt64Array()
	_pc_at = Time.get_ticks_msec()
	_us_ring_i = 0
	_us_slow.clear()

# (dev) the table's core gap around our player with up to k examples
func dev_gap(r: float, k: int) -> Dictionary:
	var me: Variant = world.get("player") if world != null and is_instance_valid(world) else null
	if me == null or not is_instance_valid(me) or table == null or not is_instance_valid(table):
		return {}
	return table.call("core_gap", (me as Node3D).global_position, r, k)

func _pc_add(i: int, us: int) -> void:
	if _pc.size() != 16:
		_pc.resize(16)
		_pc.fill(0)
	_pc[i * 2] += 1
	_pc[i * 2 + 1] += us

var _sw_stall_us := 0       # usec of our last frame after a hitch (words of the next frame are no samples either)
var _us_slow: Array = []     # (dev) the last slow frames (> 2 ms): [total, part usec ..., words, belts]
var _us_ring := PackedInt32Array()
var _us_ring_i := 0
var _sw_dg := PackedFloat32Array()   # (dev) per word: [late over the quickest, host ms - at, buffer]
var _sw_bh := PackedFloat32Array()   # (dev) per second: buffer, late max, words, pct, longest frame ms, offset
var _sw_late_max := 0.0
var _sw_late_n := 0
var _sw_pct_now := 0.0
var _sw_frame_max := 0.0
var _sw_tick_us := 0
var st_lean := true          # test tools only: false = the guest's word work as in 51ccea6 (A/B of the cost)


# what the test tools read
func replay_stats() -> Dictionary:
	var late := 0.0
	if not _sw_late.is_empty():
		var ls := _sw_late.duplicate()
		ls.sort()
		late = float(ls[int(ls.size() * 0.95) if ls.size() > 1 else 0])
	return {"on": replay_on, "core": core_version, "missing": _sw_missing, "build": game_build, "watch": health_stats(),
		"offset_ms": snappedf(_off_min, 0.1) if _off_min != INF else null, "late_p95_ms": snappedf(late, 0.1),
		"buffer_ms": snappedf(buffer_ms, 0.1), "queued": _sw_queue.size(), "words": sw_words, "lost": sw_lost, "belts": _sw_hp.size(), "stat_cache": _sw_stat.size(),
		"local": _sw_local.size(), "peers": _st_peers.size(), "st_bytes": st_bytes, "st_words": st_words, "st_skipped": st_skipped,
		"st_rate_kbs": snappedf(st_rate_kbs, 0.1), "st_level": st_level, "change_only": st_change_only,
		"eased": sw_eased, "snapped": sw_snapped, "ease": st_ease, "buf_pct": st_buf_pct, "blinks": sw_blinks,
		"state": replay_state(), "paused": _sw_quiet, "pauses": sw_pauses, "pause_n": _sw_quiet_n, "backs": sw_backs, "back_need_ms": _sw_quiet_need,
		"script": _sw_script, "handed": sw_handed, "seam_kept": sw_seam_kept,
		"seam_skip": sw_seam_skip, "end_kept": sw_end_kept, "reput": sw_reput, "rebuilds": sw_rebuilds, "hostlists": sw_hostlists, "hl_refused": sw_hl_refused, "hl_fix_refused": sw_hl_fix_refused, "dup_keys": st_dup_keys, "deferred": sw_deferred, "moved": sw_moved, "suspect": sw_suspect, "cost": _sw_cost(), "stood": sw_stood, "split": sw_split, "fast": sw_fast,
		"table": table.call("stats") if table != null and is_instance_valid(table) else {},
		"show": _sw_show_stats()}


# test tools only: the core rows of the belts that have rows (host and guest alike), `cnt` belts from
# the `from`-th on (the dev tools pass at most 200 entries): key -> [distance to our player (m), end held,
# length, [seq, kind, s, speed, room] per row, ms since our core was last made the host's (-1 never)].
# Compare a host's with a guest's by key / seq.
func fx_census(from := 0, cnt := 150) -> Dictionary:
	var me: Variant = world.get("player") if world != null and is_instance_valid(world) else null
	var at := (me as Node3D).global_position if me != null and is_instance_valid(me) else Vector3.ZERO
	var out := {}
	var j := -1
	var now := Time.get_ticks_msec()
	for item in BeltPath._live:
		if not is_instance_valid(item) or not item.is_inside_tree() or not ("run" in item) or int(item.run.count()) == 0:
			continue
		j += 1
		if j < from or j >= from + cnt:
			continue
		var k := _key_of(item)
		var line: Variant = item.get("_line")
		if k == "" or line == null:
			continue
		var d := INF
		for p in line:
			d = minf(d, (p as Vector3).distance_to(at))
		var run: Variant = item.run
		var rows: Array = []
		var f := int(run.first())
		for i in range(f, f + int(run.count())):
			rows.append([int(run.seq_of(i)), int(run.kind_of(i)), snappedf(float(run.s_of(i)), 0.01),
				snappedf(float(run.speed_of(i)), 0.01), snappedf(float(run.row_room(i)), 0.01)])
		var due: Variant = _sw_core_due.get(item.get_instance_id())
		out[k] = [snappedf(d, 0.1), bool(run.end_held), snappedf(float(run.length()), 0.01), rows,
			now - int(due) if due != null else -1]
	return out


# mp_belts' whole frame while replay runs, the last 2048 frames: mean / p50 / p99 / max ms
func _sw_cost() -> Dictionary:
	var n := mini(_us_ring_i, _us_ring.size())
	if n == 0:
		return {}
	var c := _us_ring.slice(0, n)
	c.sort()
	var tot := 0
	for x in c:
		tot += x
	var out := {"n": n, "mean_ms": snappedf(tot / 1000.0 / n, 0.001), "p50_ms": snappedf(c[n / 2] / 1000.0, 0.001),
		"p99_ms": snappedf(c[mini(n - 1, int(n * 0.99))] / 1000.0, 0.001), "max_ms": snappedf(c[n - 1] / 1000.0, 0.001)}
	# (dev) the last words: transit lateness and step age p50 / p95, buffer min / max
	var m := _sw_dg.size() / 3
	if m > 10:
		var tr := PackedFloat32Array()
		var ag := PackedFloat32Array()
		var bmin := INF
		var bmax := -INF
		for i in m:
			tr.append(_sw_dg[i * 3])
			ag.append(_sw_dg[i * 3 + 1])
			bmin = minf(bmin, _sw_dg[i * 3 + 2])
			bmax = maxf(bmax, _sw_dg[i * 3 + 2])
		tr.sort()
		ag.sort()
		out["words"] = m
		out["transit"] = [snappedf(tr[m / 2], 0.1), snappedf(tr[int(m * 0.95)], 0.1), snappedf(tr[m - 1], 0.1)]
		out["step_age"] = [snappedf(ag[m / 2], 0.1), snappedf(ag[int(m * 0.95)], 0.1), snappedf(ag[m - 1], 0.1)]
		out["buf"] = [snappedf(bmin, 0.1), snappedf(bmax, 0.1)]
	# (dev) the last 40 s, one entry a second: [buffer, late max, words, pct, longest frame, offset]
	var hist: Array = []
	var nb := _sw_bh.size() / 6
	for i in range(maxi(nb - 40, 0), nb):
		hist.append([snappedf(_sw_bh[i * 6], 0.1), snappedf(_sw_bh[i * 6 + 1], 0.1), int(_sw_bh[i * 6 + 2]),
			snappedf(_sw_bh[i * 6 + 3], 0.01), snappedf(_sw_bh[i * 6 + 4], 0.1), snappedf(_sw_bh[i * 6 + 5], 0.1)])
	out["hist"] = hist
	out["slow"] = _us_slow.duplicate()
	# (dev) word work by kind since cost_reset(): [count, ms, usec each]
	var pc := {}
	for i in mini(PC_NAMES.size(), _pc.size() / 2):
		var cn := int(_pc[i * 2])
		pc[PC_NAMES[i]] = [cn, snappedf(_pc[i * 2 + 1] / 1000.0, 0.1), snappedf(float(_pc[i * 2 + 1]) / maxi(cn, 1), 0.1)]
	out["paths"] = pc
	out["since_s"] = snappedf((Time.get_ticks_msec() - _pc_at) / 1000.0, 0.1)
	return out


func _sw_show_stats() -> Dictionary:
	var sh: Variant = mp.get("belt_show") if mp != null else null
	if sh == null or not is_instance_valid(sh) or not (sh as Object).has_method("stats"):
		return {}
	var d: Variant = sh.call("stats")
	return d if d is Dictionary else {}


# ------------------------------------------------------------------ host side

# mp._rx_belt_stream_ask: a guest wants the stream (or not any more)
func stream_ask(pid: int, on: bool) -> void:
	if not mp.is_host or pid <= 1:
		return
	if not on:
		_st_peers.erase(pid)
		return
	if _st_api < 0:
		var r: Variant = _any_run()
		if r == null:
			return   # the guest asks again in 5 s
		var miss := _sw_api_ok(r, ST_API_HOST)
		for m in ["end_held", "stepped_tick", "last_dt", "last_seq"]:
			if not (m in r):
				miss.append(m)
		_st_api = 1 if miss.is_empty() else 0
		if _st_api == 0:
			_sw_note("belt stream not served: this game's belt library differs (%s)" % ", ".join(miss))
	if _st_api != 1:
		return
	if not _st_peers.has(pid):
		_st_peers[pid] = {"w": 0, "near": [], "far": [], "at": -100000, "known": {}, "n": {}, "sig": {}, "tick": {}, "mv": {},
			"last": {}, "bw": [], "lvl": 0, "lvl_at": 0, "cyc": 0}
		if mp.trace != null and mp.trace.has_method("note"):
			mp.trace.note("belt stream on for a guest")


func _st_kid(k: String) -> int:
	var v: Variant = _st_kids.get(k)
	if v != null:
		return int(v)
	var h := k.hash() & 0x7fffffff
	while _st_kid_used.has(h):
		h = (h + 1) & 0x7fffffff
	_st_kid_used[h] = k
	_st_kids[k] = h
	return h


# Host (mp_props: a belt took one of our items): which row it became, for the stream guests.
func note_boarded(id: int, path: Node) -> void:
	if _st_peers.is_empty() or path == null or not is_instance_valid(path) or not ("run" in path):
		return
	var q: Variant = path.run.get("last_seq")
	if q == null:
		return
	_st_bd.append([id, int(q), Time.get_ticks_msec()])
	if _st_bd.size() > 64:
		_st_bd = _st_bd.slice(_st_bd.size() - 64)


func _st_send_all() -> void:
	var t0 := Time.get_ticks_usec()
	var now := Time.get_ticks_msec()
	var bd: Array = []
	var keep: Array = []
	for e in _st_bd:
		if now - int(e[2]) <= ST_BD_MS:
			keep.append(e)
			bd.append([int(e[0]), int(e[1])])
	_st_bd = keep
	for pid in _st_peers.keys():
		if not mp.players.has(pid):
			_st_peers.erase(pid)
			continue
		_st_send(int(pid), _st_peers[pid], bd, now)
	mp.perf("belts.stream", Time.get_ticks_usec() - t0)


# the near and the far belts of one guest, made again once a second
func _st_lists(pid: int, ps: Dictionary, now: int) -> void:
	ps["at"] = now
	var spot: Variant = null
	var fwd := Vector3.ZERO
	var ws: Node = mp.world_sync
	if ws != null and is_instance_valid(ws):
		var av: Variant = ws.avatars.get(pid)
		if av != null and is_instance_valid(av) and (av as Node3D).is_inside_tree():
			spot = (av as Node3D).global_position
			fwd = -(av as Node3D).global_transform.basis.z
	var near: Array = []
	var far: Array = []
	for i in ST_FAR_WORDS:
		far.append([])
	var seen := {}   # kid -> its list entry
	for p in BeltPath._live:
		if not is_instance_valid(p) or not p.is_inside_tree():
			continue
		var k := _key_of(p)
		if k == "":
			continue
		var kid := _st_kid(k)
		# (2026-11-16) two belts with one key would go out under one id (one with rows, one empty: the
		# guest's belt had the rows and none in turns): only the one with more rows
		var e0: Variant = seen.get(kid)
		if e0 is Array:
			st_dup_keys += 1
			if int(p.run.count()) > int(((e0 as Array)[0] as Node).get("run").count()):
				(e0 as Array)[0] = p   # the entry is in the near or far list: the path swapped in place
			continue
		if spot == null or _near(p, [spot], ST_NEAR_M):
			# distance class for the budget: 0 within 10 m, 1 within 20 m, 2 further; behind the guest +1
			var dc := 0
			if spot != null:
				var mid: Variant = p.get("_mid")
				var m3: Vector3 = mid if mid is Vector3 else (p as Node3D).global_position
				var dv: Vector3 = m3 - spot
				var dd := Vector2(dv.x, dv.z).length()
				dc = 0 if dd < 10.0 else (1 if dd < 20.0 else 2)
				if dd > 6.0 and fwd != Vector3.ZERO and Vector2(dv.x, dv.z).normalized().dot(Vector2(fwd.x, fwd.z).normalized()) < -0.3:
					dc = mini(dc + 1, 2)
			near.append([p, kid, dc])
			seen[kid] = near[near.size() - 1]
		else:
			(far[posmod(kid, ST_FAR_WORDS)] as Array).append([p, kid])
			seen[kid] = (far[posmod(kid, ST_FAR_WORDS)] as Array).back()
	ps["near"] = near
	ps["far"] = far


func _st_send(pid: int, ps: Dictionary, bd: Array, now: int) -> void:
	if now - int(ps["at"]) >= NEAR_LIST_MS:
		_st_lists(pid, ps, now)
	# far belts and the 2 s refresh of each near belt go by 50 ms windows
	var win := now / 50
	var new_win := win != int(ps.get("win", -1))
	ps["win"] = win
	var slot := posmod(win, ST_FAR_WORDS)
	var ints := PackedInt32Array()
	var ss := PackedFloat32Array()
	var vs := PackedFloat32Array()
	var rs := PackedFloat32Array()
	var gs := PackedFloat32Array()
	var ls := PackedFloat32Array()
	var states := {}
	var frac := Engine.get_physics_interpolation_fraction()
	var pf := Engine.get_physics_frames()
	var known: Dictionary = ps["known"]
	var sent_n: Dictionary = ps["n"]
	var sig: Dictionary = ps["sig"]
	var ticks: Dictionary = ps["tick"]
	var movers: Dictionary = ps["mv"]
	var at_step := -INF
	if _st_buf.size() != 10:
		_st_buf.resize(10)
	var fl: Array = ps["far"]
	var lvl := int(ps["lvl"])
	if new_win and slot == 0:
		ps["cyc"] = int(ps["cyc"]) + 1
	var cyc := int(ps["cyc"])
	var far_due := lvl == 0 or (lvl < 3 and cyc % 2 == 0) or cyc % 4 == 0
	var far_keep := ST_KEEP_FAR if lvl == 0 else (4.6 if lvl < 3 else 8.6)
	var last: Dictionary = ps["last"]
	var lists: Array = [ps["near"], fl[slot] if new_win and far_due and fl.size() > slot else []]
	for li in 2:
		var far := li == 1
		for e in lists[li]:
			var p: Variant = e[0]
			if p == null or not is_instance_valid(p) or not (p as Node).is_inside_tree():
				continue
			var kid := int(e[1])
			# a near belt gets its fixed fields again in its own window of the 2 s round
			var again := far or (new_win and posmod(kid, ST_FAR_WORDS) == slot)
			var run: Variant = p.run
			var n := int(run.count())
			if n == 0:
				if int(sent_n.get(kid, -1)) != 0 or again:
					ints.append_array(PackedInt32Array([kid, 0, 0, 0]))
					ls.append(0.0)
					ls.append(0.0)
					sent_n[kid] = 0
					known.erase(kid)
					sig.erase(kid)
					ticks.erase(kid)
				continue
			var dc := int(e[2]) if (e as Array).size() > 2 else 2
			var lw: Variant = last.get(kid)
			var since := now - int((lw as Array)[5]) if lw is Array else 100000
			# over the budget: belts away from the guest no more often than this (set changes too)
			var gap := 0
			if lvl >= 1 and dc == 2:
				gap = 250 if lvl == 1 else (500 if lvl == 2 else 1000)
			elif lvl >= 2 and dc == 1:
				gap = 250 if lvl == 2 else 500
			if not far and gap > 0 and since < gap:
				continue
			var keepalive := ST_KEEPALIVE_MS if lvl == 0 or dc == 0 else 3000
			var tick := int(run.stepped_tick)
			# a belt whose rows moved at its last word goes again after ST_MOVING_MS at the latest,
			# step seen or not (rows a run is carried on by without a new step clock)
			var stale: bool = movers.has(kid) and now - int(movers[kid]) >= ST_MOVING_MS
			if not again and not far and not stale and tick == int(ticks.get(kid, -1)) and n == int(sent_n.get(kid, -1)) \
			and not (st_change_only and since >= keepalive):
				continue   # no step and nothing came or went since its last word
			var seqs: PackedInt32Array = run.seqs()
			var pos: PackedFloat64Array = run.positions()
			if seqs.size() != n or pos.size() != n:
				continue
			run.draw_into(_st_buf)
			var nj := int(_st_buf[7])
			var nf := int(_st_buf[8])
			var standing := nj + nf >= n and (nf == 0 or _st_buf[1] <= 0.0) and (nj == 0 or _st_buf[4] <= 0.0)
			# 16: the belt's own surface shows stopped (jammed or held by a machine): the guest's deck too.
			# A belt that stands shows stopped only 0.35 s after its last move: that change goes out as well
			var deck_held: bool = p.has_method("deck_shows_held") and bool(p.call("deck_shows_held"))
			if standing and not again and int(sent_n.get(kid, -1)) == n:
				var was: Variant = sig.get(kid)
				if was is Array and (was as Array)[0] == seqs and (was as Array)[1] == pos and (was as Array)[2] == deck_held:
					ticks[kid] = tick
					movers.erase(kid)
					continue   # nothing moves and nothing changed: the guest has it
			if standing:
				sig[kid] = [seqs, pos, deck_held]
				movers.erase(kid)
			else:
				sig.erase(kid)
				movers[kid] = now
			ticks[kid] = tick
			var f := int(run.first())
			var lead := float(run.lead_seconds(frac, pf))
			var cap := maxf(float(run.last_dt), lead)
			var head := bool(run.has_head()) if run.has_method("has_head") else false
			var kn: Dictionary = known.get(kid, {})
			var kn2 := {}
			var stat_k := PackedInt32Array()
			# near: the core's own state at its last step and the time since (the guest's core draws
			# s + min(speed x time since the step, room) up to the step's length, as the host's drawer
			# does); far: where it is drawn now and how far it really gets (an end that passes rows
			# on, a row ahead that moves on), carried on until the next word 2 s later
			var extra := _st_pass_room(run) if far else 0.0
			var pg := -1
			var pv := 0.0
			var pre := 0.0
			var es := PackedFloat64Array()
			var ev := PackedFloat32Array()
			var er := PackedFloat32Array()
			for k in n:
				var v: float
				var room: float
				var g := 2
				if k < nj and not (head and k == 0):
					v = _st_buf[4]
					room = _st_buf[5]
					g = 0
				elif k < nj + nf and not (head and k == 0):
					v = _st_buf[1]
					room = _st_buf[2]
					g = 1
				else:
					v = float(run.speed_of(f + k))
					room = float(run.row_room(f + k))
				var s := pos[k]
				room = maxf(room, 0.0)
				if far:
					var re := room
					if k == 0:
						re = room + extra
					elif g == pg and g <= 1:
						re = pre
					elif pv > 0.0:
						re = room + pre
					pg = g
					pv = v
					pre = re
					if v > 0.0:
						var adv := minf(v * lead, re)
						s += adv
						re -= adv
					room = re
				es.append(s)
				ev.append(v)
				er.append(clampf(room, 0.0, 10000.0))
			var t_ref := float(now) - lead * 1000.0
			if st_change_only and not far and not again and since < keepalive and lw is Array and (lw as Array)[0] == seqs:
				# what the guest draws now from the last word, against the host's state now
				var ls0: PackedFloat64Array = lw[1]
				var lv0: PackedFloat32Array = lw[2]
				var lr0: PackedFloat32Array = lw[3]
				var dt := maxf((t_ref - float(lw[4])) / 1000.0, 0.0)
				var same := true
				for k in n:
					var adv := minf(float(lv0[k]) * dt, float(lr0[k])) if lv0[k] > 0.0 else 0.0
					if absf(ls0[k] + adv - es[k]) > ST_MATCH_M or absf(lv0[k] - ev[k]) > 0.001 \
					or absf(float(lr0[k]) - adv - er[k]) > ST_MATCH_M:
						same = false
						break
				if same:
					st_skipped += 1
					continue   # the guest's motion is still the host's: nothing to send
			last[kid] = [seqs, es, ev, er, t_ref, now]
			for k in n:
				ss.append(es[k])
				vs.append(ev[k])
				rs.append(er[k])
				var q := seqs[k]
				var c := int(kn.get(q, 0))
				if c < ST_STAT_WORDS or again:
					stat_k.append(k)
				kn2[q] = c + 1
			known[kid] = kn2
			sent_n[kid] = n
			if not far:
				# the word goes on at the guest when its latest step's time comes (a belt that
				# stepped longer ago is drawn from its own step's time all the same)
				at_step = maxf(at_step, float(now) - lead * 1000.0)
			ints.append(kid)
			ints.append(n)
			# flags: 1 end held, 2 far (drawn spot, carried on for the keep), 4 near (core state at
			# the step), 8 change-only (the guest carries it on for the keep, not the step's length)
			var co := st_change_only and not far
			ints.append((1 if bool(run.end_held) else 0) | (2 if far else 4) | (8 if co else 0) | (16 if deck_held else 0))
			ints.append(stat_k.size())
			ints.append_array(seqs)
			ls.append(lead)
			ls.append(far_keep if far else (keepalive / 1000.0 + 0.6 if co else cap))
			for k in stat_k:
				var i := f + k
				ints.append(k)
				ints.append(int(run.kind_of(i)))
				ints.append(int(run.strands_of(i)))
				ints.append(int(run.needle_of(i)))
				gs.append(float(run.gap_of(i)))
				gs.append(float(run.reach_of(i)))
				gs.append(float(run.side_of(i)))
				gs.append(float(run.lift_of(i)))
				var stv: Variant = run.state_of(i)
				if stv is Dictionary and not (stv as Dictionary).is_empty():
					states[seqs[k]] = stv
	var nz_due := new_win and slot == 0
	if ints.is_empty() and bd.is_empty() and not nz_due:
		return
	var w := int(ps["w"]) + 1
	ps["w"] = w
	var at := at_step if at_step > -INF else float(now)
	var data := {"q": w, "ms": now, "at": at, "i": ints, "s": ss, "v": vs, "r": rs, "g": gs, "l": ls}
	if not states.is_empty():
		data["st"] = states
	if not bd.is_empty():
		data["bd"] = bd
	if nz_due:
		# every belt that has rows (the guest empties any other it still shows)
		var nz := PackedInt32Array()
		for p in BeltPath._live:
			if is_instance_valid(p) and p.is_inside_tree() and int(p.run.count()) > 0:
				var k := _key_of(p)
				if k != "":
					nz.append(_st_kid(k))
		data["nz"] = nz
	var raw := var_to_bytes(data)
	var packed := raw.compress(FileAccess.COMPRESSION_ZSTD)
	st_bytes += packed.size()
	st_words += 1
	mp._rx_belt_stream.rpc_id(pid, packed, raw.size())
	_st_budget(ps, now, packed.size())


# bytes of the last second to this guest; the level of the budget moves at most every 500 ms
func _st_budget(ps: Dictionary, now: int, nbytes: int) -> void:
	var bw: Array = ps["bw"]
	bw.append([now, nbytes])
	var total := 0
	var keep: Array = []
	for x in bw:
		if now - int(x[0]) < 1000:
			keep.append(x)
			total += int(x[1])
	ps["bw"] = keep
	st_rate_kbs = total / 1024.0
	if now - int(ps["lvl_at"]) < 500:
		return
	ps["lvl_at"] = now
	var lvl := int(ps["lvl"])
	if st_rate_kbs > st_budget_kbs and lvl < 3:
		ps["lvl"] = lvl + 1
		if lvl == 0:
			_sw_note("belt stream over budget for a guest (%.0f kB/s > %.0f): belts away from it go less often" % [st_rate_kbs, st_budget_kbs])
	elif st_rate_kbs < st_budget_kbs * 0.6 and lvl > 0:
		ps["lvl"] = lvl - 1
	st_level = int(ps["lvl"])

# How far past its end a belt's front row really gets: none when the end is held (a machine, a
# door) or nothing comes after; else the room at the next belt's start (all of ST_PASS_M when its
# last row moves on too).
const ST_PASS_M := 1.0

func _st_pass_room(run: Variant) -> float:
	if bool(run.end_held):
		return 0.0
	var dn: Variant = run.get("downstream")
	if dn == null or not is_instance_valid(dn) or bool(dn.get("blocked")):
		return 0.0
	var m := int(dn.count())
	if m == 0:
		return minf(float(dn.length()), ST_PASS_M)
	var bi := int(dn.first()) + m - 1
	if float(dn.speed_of(bi)) > 0.0:
		return ST_PASS_M
	return clampf(float(dn.s_of(bi)) - float(dn.gap_of(bi)), 0.0, ST_PASS_M)


# ------------------------------------------------------------------ guest side

# Everything the stream needs from the game and our core, asked once by name.
func _sw_check() -> bool:
	if _sw_core >= 0:
		return _sw_core == 1
	var run: Variant = _any_run()
	if run == null:
		return false   # no belt to ask yet: ask again later
	var b := str(mp.call("game_build")) if mp.has_method("game_build") else ""
	if b == "":
		if _sw_build_asked < 0:
			_sw_build_asked = Time.get_ticks_msec()
		if Time.get_ticks_msec() - _sw_build_asked < ST_BUILD_WAIT_MS:
			return false   # not known yet (Steam not up): ask again later
		b = "unknown"
	game_build = b
	var miss := _sw_api_ok(run, ST_API_GUEST)
	for m in ST_CORE_PROPS:
		if not (m in run):
			miss.append(m)
	_sw_script = false
	if not miss.is_empty():
		# (script replay) no core of ours, or one this build does not fit: the row table, if the
		# game's own belt library has what that needs
		var miss2 := _sw_api_ok(run, ST_API_SCRIPT)
		for m in ST_PROPS_SCRIPT:
			if not (m in run):
				miss2.append(m)
		if miss2.is_empty():
			_sw_script = true
			miss = []
		else:
			miss = miss2
	_sw_core = 1 if miss.is_empty() else 0
	_sw_missing = ", ".join(miss)
	if _sw_core == 1:
		core_version = "script" if _sw_script else str(run.call("np_core_version"))
		probation = not REPLAY_BUILDS.has(b)
		if probation:
			_sw_note("belt replay on probation: game build %s not tested yet (watched for %d min)" % [b, ST_PROBATION_MS / 60000])
	else:
		if (run as Object).has_method("np_stream_clear"):
			run.call("np_stream_clear")
		var why := "the NEEDLE PARTY belt core is not installed" if miss.has("np_stream_all") else "game build %s, belt library differs: %s" % [b, _sw_missing]
		_sw_note("belt replay off: %s (belts run as before)" % why)
	return _sw_core == 1


# every method in `want` on this object (its native class and its script), with that many arguments;
# the ones missing or changed, by name
func _sw_api_ok(obj: Object, want: Dictionary) -> Array:
	var have := {}
	for m in obj.get_method_list():
		if m is Dictionary and m.has("name"):
			var args: Variant = m.get("args")
			have[String(m["name"])] = (args as Array).size() if args is Array else -1
	var miss: Array = []
	for name in want:
		if not have.has(name):
			miss.append(String(name))
		elif int(have[name]) != int(want[name]):
			miss.append("%s(%d args, want %d)" % [name, int(have[name]), int(want[name])])
	return miss


func _sw_note(text: String) -> void:
	var bd: Variant = mp.get("belt_draw") if mp != null else null
	if bd != null and is_instance_valid(bd) and bd.has_method("event"):
		bd.call("event", text)   # the trace, the warning and the log's report
		return
	push_warning("[NP] " + text)
	if mp != null and mp.trace != null and mp.trace.has_method("note"):
		mp.trace.note(text)


# The health watch, once a second (probation: the first ST_PROBATION_MS of an untested build; no
# word for HM_NO_WORD_MS: always). Off for the session on a fault.
func _sw_health(now: int) -> void:
	if now - _hm_at < 1000:
		return
	_hm_at = now
	if now % 5000 < 1000:
		_sw_depth.clear()   # belts built or turned meanwhile: the lines read again (about every 5 s)
	# (dev) one line a second: buffer, latest lateness max, words, percentile used, longest frame
	if _sw_bh.size() >= 600:
		_sw_bh = _sw_bh.slice(300)
	_sw_bh.append_array(PackedFloat32Array([buffer_ms, _sw_late_max, _sw_late_n, _sw_pct_now, _sw_frame_max, _off_min if _off_min != INF else 0.0]))
	_sw_late_max = 0.0
	_sw_late_n = 0
	_sw_frame_max = 0.0
	for i in 5:
		hm_total[i] += int(_hm_now[i])
	_hm_ring.append(_hm_now)
	_hm_now = [0, 0, 0, 0, 0]
	if _hm_ring.size() > 5:
		_hm_ring.pop_front()
	if not _sw_gone.is_empty():
		for q in _sw_gone.keys():
			if now - int(_sw_gone[q][1]) > 1000:
				_sw_gone.erase(q)
	if not _sw_suspect.is_empty():
		for q in _sw_suspect.keys():
			if now - int(_sw_suspect[q]) > 2000:
				_sw_suspect.erase(q)
	var since := maxi(_sw_word_at, _sw_on_at + 5000)   # 5 s to get the first words
	var gap_max := 0
	for g in _sw_gaps:
		gap_max = maxi(gap_max, g)
	if now - since > HM_NO_WORD_MS + mini(gap_max, sw_gap_allow_ms):
		# (F59) none came (still silent, or they came again just now after a silence: the host's
		# game stood, or ours): off for now only. A host that never served us: a fault as before
		var quiet := _sw_ever_heard and (now - _sw_heard_at > HM_GAP_MS or now - _sw_gap_end_at < HM_NO_WORD_MS)
		_sw_bench("no belt word from the host for %d s" % ((now - maxi(_sw_word_at, _sw_on_at)) / 1000), quiet)
		return
	if _sw_script and _sw_health_script():
		return
	if probation and now > _sw_probation_end and not _probation_noted:
		_probation_noted = true
		_sw_note("belt replay probation passed: %d min without a problem (game build %s)" % [ST_PROBATION_MS / 60000, game_build])
	if not probation or now > _sw_probation_end:
		return
	var t := [0, 0, 0, 0, 0]
	for e in _hm_ring:
		for i in 5:
			t[i] += int(e[i])
	var why := ""
	if t[0] > HM_LOST:
		why = "%d rows lost from our belts in 5 s" % t[0]
	elif t[1] > HM_INSERT_FAIL:
		why = "%d rows could not be put on in 5 s" % t[1]
	elif t[2] >= 30 and t[3] > 0 and 100.0 * t[2] / t[3] > HM_MISSING_PCT:
		why = "%d of %d host rows not shown in 5 s" % [t[2], t[3]]
	elif t[4] > HM_NOSTAT:
		why = "%d rows without their fields in 5 s" % t[4]
	if why != "":
		_sw_bench(why)


# (script replay) always watched, any build: our drawer broke, the table broke, host rows not
# shown (fixed fields never came, or our core cannot hold them). True = replay went off.
func _sw_health_script() -> bool:
	var why := ""
	var sh: Variant = mp.get("belt_show") if mp != null else null
	if st_show and sh != null and is_instance_valid(sh):
		var f: Variant = sh.get("fault")
		if f != null and str(f) != "":
			why = "belt drawer: " + str(f)
	if why == "" and (table == null or not is_instance_valid(table)):
		why = "row table missing"
	if why == "":
		var tf: Variant = table.get("fault")
		if tf != null and str(tf) != "":
			why = "row table: " + str(tf)
	if why == "":
		var t := [0, 0, 0, 0, 0]
		for e in _hm_ring:
			for i in 5:
				t[i] += int(e[i])
		if t[2] >= 30 and t[3] > 0 and 100.0 * t[2] / t[3] > HM_MISSING_PCT:
			why = "%d of %d host rows not held in 5 s" % [t[2], t[3]]
		elif t[4] > HM_NOSTAT:
			why = "%d rows without their fields in 5 s" % t[4]
	if why == "":
		return false
	_sw_bench(why)
	return true


# Replay off for this session, now: the normal belts take over (the host's next words put them right).
# (F59) quiet: the host was silent, off for now only (_sw_quiet_tick turns it on again).
func _sw_bench(why: String, quiet := false) -> void:
	health = why
	var back := ""
	if quiet:
		if Time.get_ticks_msec() - _sw_on_at > sw_calm_ms:
			_sw_quiet_n = 0   # a long calm since it last came on: a freeze now and then waits the short time
		_sw_quiet_n += 1
		sw_pauses += 1
		_sw_quiet_need = mini(HM_BACK_MS << mini(_sw_quiet_n - 1, 4), HM_BACK_MAX_MS)
		back = "; back on after %d s of its words" % (_sw_quiet_need / 1000)
	_sw_note("belt replay off: %s, game build %s (back to the normal belts%s)" % [why, game_build, back])
	set_replay(false)
	_sw_core = 0
	_sw_missing = "health: " + why
	_sw_quiet = quiet
	_sw_back_rx_at = 0
	_sw_back_from = 0


# (F59) replay is off because the host was silent: on again once its normal belt words have come
# with no gap longer than HM_BACK_GAP_MS for _sw_quiet_need ms (the switch decides as before).
func _sw_quiet_tick() -> void:
	var now := Time.get_ticks_msec()
	if _sw_back_from == 0 or now - _sw_back_rx_at > HM_BACK_GAP_MS or now - _sw_back_from < _sw_quiet_need:
		return
	var waited := (now - _sw_back_from) / 1000
	_sw_quiet = false
	health = ""
	_sw_missing = ""
	_sw_core = 1   # it ran before the silence: the check passed this session
	sw_backs += 1
	var want: Variant = mp.get("belt_replay") if mp != null else null
	if want == true:
		_sw_note("belt replay back on: the host's belt words came again for %d s (%d. time this session)" % [waited, _sw_quiet_n])


# (F59) a normal belt word came (replay off): counts while replay waits to come back
func _sw_quiet_rx() -> void:
	var now := Time.get_ticks_msec()
	if _sw_back_rx_at == 0 or now - _sw_back_rx_at > HM_BACK_GAP_MS:
		_sw_back_from = now   # the first, or the first after a gap: count from here
	_sw_back_rx_at = now


# belt replay's state on this PC for the panel and the logs: [state, why]
# state: serving (a host), on, probation, off, problem, wait
func replay_state() -> Array:
	if mp == null or not mp.active():
		return ["off", "no session"]
	if mp.is_host:
		return ["serving", "serves %d guest(s)" % _st_peers.size()]   # not "host": a player called Host would blank it in trace.txt
	if _sw_quiet and not replay_on:
		return ["paused", "the host was silent (%s): back on after %d s of its belt words" % [health, _sw_quiet_need / 1000]]
	if health != "":
		return ["problem", "problem found: " + health]
	if mp.get("belt_smooth") != true:
		return ["off", "smooth belts setting off"]
	if mp.get("belt_replay_off") == true:
		return ["off", "test switch off"]
	if _sw_core == 0:
		if _sw_missing.begins_with("np_stream_all") or _sw_missing.contains("np_stream_all"):
			return ["off", "no belt core"]
		return ["off", "game update: belt library differs (%s)" % _sw_missing]
	if _sw_core < 0:
		return ["wait", "checking the belt core"]
	if replay_on and probation and Time.get_ticks_msec() <= _sw_probation_end:
		return ["probation", "game build %s not tested yet, %d s left" % [game_build, maxi(0, (_sw_probation_end - Time.get_ticks_msec()) / 1000)]]
	if replay_on:
		return ["on", "tested game build" if not probation else "probation passed"]
	return ["off", "not on yet"]


func health_stats() -> Dictionary:
	var t := [0, 0, 0, 0, 0]
	for e in _hm_ring:
		for i in 5:
			t[i] += int(e[i])
	return {"probation": probation, "left_s": maxi(0, (_sw_probation_end - Time.get_ticks_msec()) / 1000) if probation else 0,
		"lost_5s": t[0], "insert_fail_5s": t[1], "missing_5s": t[2], "wanted_5s": t[3], "nostat_5s": t[4], "health": health}


func _any_run() -> Variant:
	for item in BeltPath._live:
		if is_instance_valid(item) and item.get("run") != null:
			return item.get("run")
	return null


# The switch (mp.belt_replay; F9 panel; dev command belt_replay).
func set_replay(on: bool) -> void:
	if on and (mp == null or mp.is_host or not mp.active() or not _sw_check()):
		on = false
	if on == replay_on:
		return
	replay_on = on
	if on:
		var run: Variant = _any_run()
		if _sw_script:
			_sw_table_on()
		if run != null:
			if not _sw_script:
				run.call("np_stream_all", true)
			if (run as Object).has_method("np_stream_ease") and not _sw_script:
				run.call("np_stream_ease", ST_EASE_MAX, ST_EASE_S if st_ease else 0.0)
			# rows our own belts make (our catches) get numbers far above the host's, so one of
			# ours is never taken for one of the host's
			if (run as Object).has_method("get_next_seq") and (run as Object).has_method("set_next_seq"):
				if int(run.call("get_next_seq")) < ST_LOCAL_SEQ:
					run.call("set_next_seq", ST_LOCAL_SEQ)
		_alias.clear()
		_pend_since.clear()
		_keep_since.clear()
		_queue.clear()
		_order.clear()
		_pending.clear()
		_fork_open.clear()
		_fork_head.clear()
		_paths_n = -1
		_sw_q = -1
		_sw_ask_at = -100000
		_sw_on_at = Time.get_ticks_msec()
		_sw_word_at = 0
		_sw_probation_end = _sw_on_at + ST_PROBATION_MS
		_hm_ring.clear()
		_hm_now = [0, 0, 0, 0, 0]
		_sw_quiet = false
	else:
		_sw_release_all()
		if mp != null and mp.active() and not mp.is_host and multiplayer.multiplayer_peer != null:
			mp._rx_belt_stream_ask.rpc_id(1, false)
	if on:
		_sw_note("belt replay on: %s, game build %s%s" % [core_version, game_build, " (on probation)" if probation else ""])
		_probation_noted = false
	elif health == "":
		_sw_note("belt replay off: %s" % str(replay_state()[1]))   # (a health fault: _sw_bench said why)


# (script replay) the row table on, and the drawer that shows it (mp_belt_show.gd; until that is
# there the game draws our core's rows, which are kept the host's)
func _sw_table_on() -> void:
	if table == null or not is_instance_valid(table):
		var sc: Variant = load((get_script() as Script).resource_path.get_base_dir() + "/mp_belt_replay.gd")
		if not (sc is Script):
			return
		table = (sc as Script).new()
		table.name = "MPBeltTable"
		table.set("bs", self)
		add_child(table)
	table.call("clear")
	table.set("active", true)
	_sw_show(true)


var st_show := true   # test tools only: false = the row table without our drawer (the game draws our core)

func _sw_show(on: bool) -> void:
	var sh: Variant = mp.get("belt_show") if mp != null else null
	if sh == null or not is_instance_valid(sh) or not (sh as Object).has_method("set_active"):
		return
	if on and st_show:
		if table != null and is_instance_valid(table):
			sh.call("set_active", true, table)
	elif bool(sh.get("active")):
		sh.call("set_active", false, null)


# the game's rows of this belt are hidden by our drawer now (its run is unwatched: no draw queue,
# no event sink; nothing of the game's drawer may be called for it)
func _sw_hidden(path: Node) -> bool:
	var sh: Variant = mp.get("belt_show") if mp != null else null
	return sh != null and is_instance_valid(sh) and (sh as Object).has_method("is_hidden") and bool(sh.call("is_hidden", path))


func _sw_release_all() -> void:
	# (script replay) our drawer off first: every run it hid is watched by the game's drawer again
	_sw_show(false)
	if table != null and is_instance_valid(table):
		table.set("active", false)
		table.call("clear")
	var run: Variant = _any_run()
	if run != null and (run as Object).has_method("np_stream_clear"):
		run.call("np_stream_clear")   # every run steps on its own again, all host tables gone
	for id in _sw_held:
		var e: Array = _sw_held[id]
		var path: Variant = e[0]
		if path != null and is_instance_valid(path):
			path.run.set_end_held(bool(e[1]))
			if path.has_method("wake"):
				path.call("wake")
	_sw_held.clear()
	_sw_hp.clear()
	_sw_pending.clear()
	_sw_queue.clear()
	_sw_at_last = -INF
	_sw_buf_n = 0
	_sw_late = PackedFloat32Array()   # a new start takes its own samples (not the ones of a join's hitches)
	_sw_local.clear()
	_sw_after.clear()
	_sw_bd.clear()
	_sw_await.clear()
	_sw_suspect.clear()
	_sw_core_at.clear()
	_sw_core_due.clear()
	_sw_rest = []
	_deck_ok.clear()
	_sw_q = -1
	_paths_n = -1   # _map_paths again with the next word: end holds, forks, outlets as before


# mp._rx_belt_stream
func on_belt_stream(packed: PackedByteArray, raw_size: int) -> void:
	# (F59) when words come, put on or not: a silence of the host is told from words that do not fit
	var now := Time.get_ticks_msec()
	if _sw_heard_at > 0:
		if now - _sw_heard_at > HM_GAP_MS:
			_sw_gap_end_at = now
		_sw_gaps.append(now - _sw_heard_at)
		if _sw_gaps.size() > HM_GAPS_N:
			_sw_gaps.remove_at(0)
	_sw_heard_at = now
	_sw_ever_heard = true
	if replay_on:
		var tu := Time.get_ticks_usec()
		# our own frame stood this long (a hitch here): when in it the word came is not known
		var stood := _sw_tick_us > 0 and tu - _sw_tick_us > maxf(ST_STALL_US, 3.0 * _sw_frame_avg)
		# a hitch inside the network poll itself (a message that builds things): the words that came
		# during it are handed over in the frame after
		stood = stood or (_sw_stall_us > 0 and tu - _sw_stall_us < ST_STALL_US)
		# (2026-11-15) our own frame was long (not a hitch): the word may have come early in it. Its
		# lateness for the buffer counts from a usual frame on (a late word is put on in the next frame
		# anyway; rows go on ST_SLACK past their step): our slow frames are not the link's lateness
		var extra := 0.0
		if _sw_tick_us > 0 and _sw_frame_avg > 0.0:
			extra = maxf(float(tu - _sw_tick_us) - 1.5 * _sw_frame_avg, 0.0) / 1000.0
		_sw_pending.append([packed, raw_size, float(tu) / 1000.0, stood, extra])


func _sw_tick() -> void:
	var t0 := Time.get_ticks_usec()
	if _sw_tick_us > 0:
		var fr := float(t0 - _sw_tick_us)
		_sw_frame_max = maxf(_sw_frame_max, fr / 1000.0)
		if fr > maxf(ST_STALL_US, 3.0 * _sw_frame_avg):
			_sw_stall_us = t0
		# a hitch counts as at most 2 usual frames (loading after the join must not make every frame "usual")
		_sw_frame_avg = minf(fr, 33000.0) if _sw_frame_avg <= 0.0 else _sw_frame_avg + (minf(fr, 2.0 * _sw_frame_avg + 1000.0) - _sw_frame_avg) * 0.02
	_sw_tick_us = t0
	var now := Time.get_ticks_msec()
	if now - _sw_ask_at >= 5000:
		_sw_ask_at = now
		mp._rx_belt_stream_ask.rpc_id(1, true)
	if BeltPath._live.size() != _paths_n:
		_map_paths()
		_sw_map()
	_sw_shown_now.clear()
	_pending.clear()   # words of the other kind, until the host has our ask
	while not _sw_pending.is_empty():
		var pr: Array = _sw_pending.pop_front()
		var tu := Time.get_ticks_usec()
		_sw_unpack(pr[0], int(pr[1]), float(pr[2]), pr.size() > 3 and bool(pr[3]), float(pr[4]) if pr.size() > 4 else 0.0)
		_pc_add(5, Time.get_ticks_usec() - tu)
	if not _sw_queue.is_empty() or not _sw_rest.is_empty():
		var ta := Time.get_ticks_usec()
		_sw_apply_t0 = ta
		var disp := _sw_disp()
		# (lean) one budget for all word work of the frame (the rest of a word and new words); a word
		# goes on over as many frames as it needs. Further behind than ST_LAG_OK: a bigger budget
		var split := _sw_script and st_lean and st_apply_us > 0
		_sw_core_us = 0
		if split:
			var due := float(_sw_rest[9]) if _sw_rest.size() > 9 else (float(_sw_queue[0][0]) if not _sw_queue.is_empty() else disp)
			var lag := disp - due
			_sw_budget = st_apply_us if lag <= ST_LAG_OK else int(st_apply_us * minf(lag / ST_LAG_OK, 4.0))
		if not _sw_rest.is_empty():
			_sw_behind = not split and not _sw_queue.is_empty() and float(_sw_queue[0][0]) <= disp
			_sw_apply_rest(_sw_rest)
		while _sw_rest.is_empty() and not _sw_queue.is_empty() and float(_sw_queue[0][0]) <= disp:
			if split and Time.get_ticks_usec() - ta > _sw_budget:
				break   # the next frame
			var w: Array = _sw_queue.pop_front()
			# (not lean) the next word is due already: we are behind, this one is not spread over frames
			_sw_behind = not split and not _sw_queue.is_empty() and float(_sw_queue[0][0]) <= disp
			_sw_apply(w[1], disp, float(w[0]))
		if _sw_queue.size() > 400:
			_sw_queue = _sw_queue.slice(_sw_queue.size() - 400)
		mp.perf("belts.sw.apply", Time.get_ticks_usec() - ta)
	if not _sw_defer.is_empty():
		_sw_defer_tick()
	if not _sw_local.is_empty() or not _sw_bd.is_empty():
		_sw_locals_tick(now)
	if not _sw_await.is_empty():
		_sw_check_shown(now)
	if _sw_script and table != null and is_instance_valid(table):
		var tt := Time.get_ticks_usec()
		table.call("tick", _sw_disp())
		_us_tick += Time.get_ticks_usec() - tt
	var to := Time.get_ticks_usec()
	_recheck_outlets()
	_pc_add(7, Time.get_ticks_usec() - to)
	_sw_health(now)
	_us_misc += Time.get_ticks_usec() - to
	if _sw_script:
		var tot := Time.get_ticks_usec() - t0
		if tot > 2000:
			if _us_slow.size() >= 40:
				_us_slow.pop_front()
			_us_slow.append([tot, _us_put, _us_want, _us_reput, _us_lost, _us_fix, _us_after, _us_deck, _us_tick, _us_misc,
				_us_words, _us_belts, _us_near, _us_rows])
		mp.perf("belts.sw.misc", _us_misc)
		_us_misc = 0
		_us_words = 0
		_us_belts = 0
		_us_near = 0
		_us_rows = 0
		mp.perf("belts.sw.lost", _us_lost)
		mp.perf("belts.sw.want", _us_want)
		mp.perf("belts.sw.put", _us_put)
		mp.perf("belts.sw.fix", _us_fix)
		mp.perf("belts.sw.reput", _us_reput)
		mp.perf("belts.sw.after", _us_after)
		mp.perf("belts.sw.deck", _us_deck)
		mp.perf("belts.sw.tick", _us_tick)
		_us_lost = 0
		_us_want = 0
		_us_put = 0
		_us_fix = 0
		_us_reput = 0
		_us_after = 0
		_us_deck = 0
		_us_tick = 0
	if not replay_on:
		return   # the health watch just turned it off
	if now - _sw_counts_at >= 1000:
		_sw_counts_at = now
		var r0: Variant = _any_run()
		if _sw_script and table != null and is_instance_valid(table):
			sw_eased = int(table.get("eased"))
			sw_snapped = int(table.get("snapped"))
		elif r0 != null and (r0 as Object).has_method("np_stream_counts"):
			var parts := str(r0.call("np_stream_counts")).split(" ")
			if parts.size() == 2:
				sw_eased = int(parts[0])
				sw_snapped = int(parts[1])
	mp.perf("belts.stream", Time.get_ticks_usec() - t0)


func _sw_map() -> void:
	_sw_hp.clear()
	_sw_depth.clear()
	for k in _paths:
		var p: Variant = _paths[k]
		if p == null or not is_instance_valid(p):
			continue
		_sw_hp[_st_kid(k)] = p
		# our own items our belts catch (the guest's throws)
		if p.has_signal("caught") and int((p as Node).get_meta("np_sw_watch", 0)) != get_instance_id():
			(p as Node).set_meta("np_sw_watch", get_instance_id())
			p.caught.connect(_sw_on_caught.bind(p))


# our belt caught an item of ours (only ours fly here: the host's are puppets): the row our
# core made stays, standing, until the host's row for that item comes (word "bd")
func _sw_on_caught(rb: Node, path: Node) -> void:
	if not replay_on or rb == null or not is_instance_valid(rb) or not rb.has_meta("mp_id") or not is_instance_valid(path):
		return
	var q: Variant = path.run.get("last_seq")
	if q == null:
		return
	if int(q) < ST_LOCAL_SEQ:
		# (script replay) a game without set_next_seq numbered it among the host's rows: our own number
		q = _sw_renumber(path, int(q))
		if int(q) < 0:
			return
	_sw_local[int(q)] = [int(rb.get_meta("mp_id")), path, Time.get_ticks_msec()]
	sw_local += 1
	if sw_tap.is_valid():
		sw_tap.call("local", path, int(q), float(rb.get_meta("mp_id")))
	if not _sw_hidden(path):
		_sw_wake(path.run, true, bool(path.run.awake))
	if _sw_script and table != null and is_instance_valid(table):
		# drawn from this frame on (the item is gone from the screen now)
		var run: Variant = path.run
		var f := int(run.first())
		for i in range(f + int(run.count()) - 1, f - 1, -1):
			if int(run.seq_of(i)) == int(q):
				table.call("add_local", path, int(q), float(run.s_of(i)), int(run.kind_of(i)), int(run.strands_of(i)),
					float(run.side_of(i)), float(run.lift_of(i)), maxf(float(run.speed_of(i)), 0.0),
					maxf(float(run.row_room(i)), 0.0), _sw_disp())
				break


# Our core's row `q` (newest first) put in again with our own number from ST_LOCAL_SEQ on, same
# spot and fields; the new number, -1 if it is not there.
func _sw_renumber(path: Node, q: int) -> int:
	var run: Variant = path.run
	var f := int(run.first())
	for i in range(f + int(run.count()) - 1, f - 1, -1):
		if int(run.seq_of(i)) != q:
			continue
		var stv: Variant = run.state_of(i)
		var st := [int(run.kind_of(i)), int(run.strands_of(i)), int(run.needle_of(i)), float(run.gap_of(i)),
			float(run.reach_of(i)), float(run.side_of(i)), float(run.lift_of(i)), stv if stv is Dictionary else {}]
		var s := float(run.s_of(i))
		var v := float(run.speed_of(i))
		_sw_local_next += 1
		run.remove_at(i)
		_sw_put(run, i, s, v, _sw_local_next, st, not _sw_hidden(path))
		return _sw_local_next
	return -1


func _sw_locals_tick(now: int) -> void:
	for q in _sw_local.keys():
		var e: Array = _sw_local[q]
		var gone: bool = now - int(e[2]) > ST_LOCAL_MS or e[1] == null or not is_instance_valid(e[1])
		if not gone and _sw_bd.has(int(e[0])) and _sw_shown_now.has(int(_sw_bd[int(e[0])][0])):
			gone = true   # the host's row for it is shown now (this frame)
		if gone:
			_sw_local.erase(q)
			if _sw_script and table != null and is_instance_valid(table):
				table.call("taken", int(q))
			if sw_tap.is_valid():
				sw_tap.call("local_gone", e[1] if e[1] != null and is_instance_valid(e[1]) else null, int(q), float(now - int(e[2])))
			var p: Variant = e[1]
			if p != null and is_instance_valid(p):
				var run: Variant = p.run
				var f := int(run.first())
				for i in range(f + int(run.count()) - 1, f - 1, -1):
					if int(run.seq_of(i)) == int(q):
						run.remove_at(i)
						break
	for id in _sw_bd.keys():
		if now - int(_sw_bd[id][1]) > ST_LOCAL_MS:
			_sw_bd.erase(id)


func _sw_check_shown(now: int) -> void:
	var ps: Variant = mp.world_sync.get("props_sync") if mp.world_sync != null else null
	for q in _sw_await.keys():
		var w: Array = _sw_await[q]
		if _sw_shown_now.has(int(q)):
			_sw_await.erase(q)
			sw_shown += 1
			if ps != null and is_instance_valid(ps) and ps.has_method("rp_row_shown"):
				ps.call("rp_row_shown", int(w[0]))
		elif now - int(w[1]) > 3000:
			_sw_await.erase(q)


func _sw_clock(off: float) -> void:
	_off_ring.append(off)
	if _off_ring.size() > 120:
		_off_ring.pop_front()
	var was := _off_min
	_off_min = INF
	for o in _off_ring:
		_off_min = minf(_off_min, float(o))
	if was != INF and _off_min > was:
		_off_min = minf(_off_min, was + 1.0)   # the way got slower: follow it slowly, no jump back
		_off_ring[_off_ring.size() - 1] = maxf(off, _off_min)


# How far behind the host's clock we draw: words go on when their step's time comes, and that must
# be after they came (p95 of how late they come, plus a little). The first ST_BUF_WARM words set
# it; after that it moves by at most ST_BUF_UP / ST_BUF_DOWN ms per word: a jump up would turn our
# clock back (rows going backwards), a quick way down runs it fast (rows hurrying). Measured at
# 100 +- 25 ms: one burst of late words took it to 250 ms with quick moves, and the long way down
# made every row hurry for seconds (error p95 43 cm); at 1 ms per word it still rose to 200 ms in
# a burst. A word later than this is put on when it comes (its rows go on 40 ms past their step,
# ST_SLACK); the clock itself stays even.
var st_buf_pct := -1.0   # lateness percentile the buffer covers; -1 adaptive (p95 / p99 by jitter)
const ST_JITTER_MS := 30.0
var st_ease := true      # our core glides small corrections (np_stream_ease)
const ST_EASE_MAX := 0.20
const ST_EASE_S := 0.08
const ST_BUF_WARM := 60
const ST_BUF_UP := 0.05
const ST_BUF_DOWN := 0.05
const ST_BUF_FAR := 15.0     # ms over what is needed: the way down goes 3x as quick
var st_buf_down := ST_BUF_DOWN   # test tools only (A/B of the way down)
var _sw_buf_n := 0

func _sw_buffer(late: float) -> void:
	_sw_late.append(late)
	if _sw_late.size() > 600:
		_sw_late = _sw_late.slice(_sw_late.size() - 600)
	var ls := _sw_late.duplicate()
	ls.sort()
	# st_buf_pct < 0: adaptive: p99 on a jittery link (p99 - p50 over ST_JITTER_MS), else p95.
	# Measured 3 x 20 s each: at 100 +- 25 ms p99 had 1323 jumps against p95's 3688 for ~+12 ms of
	# delay; on a LAN both 130 jumps, p99 up to +18 ms of delay
	var pct := st_buf_pct
	if pct < 0.0:
		var p50 := float(ls[int(ls.size() * 0.5)])
		var p99 := float(ls[mini(ls.size() - 1, int(ls.size() * 0.99))])
		pct = 0.99 if p99 - p50 > ST_JITTER_MS else 0.95
	_sw_pct_now = pct
	_sw_late_max = maxf(_sw_late_max, late)
	_sw_late_n += 1
	var want := clampf(float(ls[mini(ls.size() - 1, int(ls.size() * pct))]) + ST_BUF_MARGIN, ST_BUF_MIN, ST_BUF_MAX)
	_sw_buf_n += 1
	if _sw_buf_n <= ST_BUF_WARM:
		buffer_ms = want
	else:
		# (2026-11-15) far above what is needed (a burst of late words, our own hitch): down 3x as quick
		# (0.15 ms a word, ~9 ms a second: the clock runs ~1 % fast, a row ~2 mm ahead of its word);
		# from 83 ms back to 26 ms it took 17 s at 0.05
		var down := st_buf_down * (3.0 if buffer_ms - want > ST_BUF_FAR else 1.0)
		buffer_ms += clampf(want - buffer_ms, -down, ST_BUF_UP)


# A word that came: decoded at once (when it came is the clock), put on when its time comes.
func _sw_unpack(packed: PackedByteArray, raw_size: int, arrived: float, stood := false, extra := 0.0) -> void:
	if raw_size <= 0 or raw_size > MAX_RAW:
		return
	var t_dec := Time.get_ticks_usec()
	var data: Variant = bytes_to_var(packed.decompress(raw_size, FileAccess.COMPRESSION_ZSTD))
	mp.perf("belts.decode", Time.get_ticks_usec() - t_dec)
	if not (data is Dictionary):
		return
	var d: Dictionary = data
	var q := int(d.get("q", -1)) if d.get("q") is int else -1
	var host_ms := float(d.get("ms", -1)) if d.get("ms") is int else -1.0
	if q < 0 or host_ms < 0.0:
		return
	if _sw_q >= 0 and q <= _sw_q:
		if q < _sw_q - 100000:
			_sw_q = -1   # the host started counting again (a new session on its side)
		else:
			sw_old += 1
			return       # older than one already here (words can come out of order)
	if _sw_q >= 0 and q > _sw_q + 1:
		sw_lost += q - _sw_q - 1
	_sw_q = q
	_sw_clock(arrived - host_ms)
	var at := float(d.get("at", host_ms)) if (d.get("at") is float or d.get("at") is int) else host_ms
	at = clampf(at, host_ms - 1000.0, host_ms)
	at = maxf(at, _sw_at_last)   # never before a word already queued
	_sw_at_last = at
	if not (stood and st_buf_stall):
		_sw_buffer(arrived - at - _off_min - extra)
	else:
		sw_stood += 1
	# (dev) per word: how late it came over the quickest, how old its step was, the buffer
	if _sw_dg.size() >= 1800:
		_sw_dg = _sw_dg.slice(900)
	_sw_dg.append(arrived - host_ms - _off_min)
	_sw_dg.append(host_ms - at)
	_sw_dg.append(buffer_ms)
	# what an item became: at once (the copy waits for its row, whenever that is shown)
	var tnow := Time.get_ticks_msec()
	var bdv: Variant = d.get("bd")
	if bdv is Array:
		for pair in bdv:
			if pair is Array and (pair as Array).size() == 2 and pair[0] is int and pair[1] is int:
				if not _sw_bd.has(int(pair[0])):
					_sw_bd[int(pair[0])] = [int(pair[1]), tnow]
					_sw_await[int(pair[1])] = [int(pair[0]), tnow]
	_sw_queue.append([at, d])


# the host's clock as we draw it (host ms)
func _sw_disp() -> float:
	return float(Time.get_ticks_usec()) / 1000.0 - _off_min - buffer_ms


func _sw_apply(d: Dictionary, disp: float, due := -1.0) -> void:
	if sw_fault == "drop" and Time.get_ticks_msec() < sw_fault_until:
		return   # test tools only: as if the host's words never came
	sw_words += 1
	applied += 1
	_sw_word_at = Time.get_ticks_msec()
	var tparse := Time.get_ticks_usec()
	var host_ms := float(d.get("ms", 0))
	var stv: Variant = d.get("st")
	var states: Dictionary = stv if stv is Dictionary else {}
	var iv: Variant = d.get("i")
	var sv: Variant = d.get("s")
	var vv: Variant = d.get("v")
	var rv: Variant = d.get("r")
	var gv: Variant = d.get("g")
	var lv: Variant = d.get("l")
	if not (iv is PackedInt32Array and sv is PackedFloat32Array and vv is PackedFloat32Array \
	and rv is PackedFloat32Array and gv is PackedFloat32Array and lv is PackedFloat32Array):
		return
	var ints: PackedInt32Array = iv
	var ss: PackedFloat32Array = sv
	var vs: PackedFloat32Array = vv
	var rs: PackedFloat32Array = rv
	var gs: PackedFloat32Array = gv
	var ls: PackedFloat32Array = lv
	var me: Variant = world.get("player") if world != null and is_instance_valid(world) else null
	var me_at: Variant = (me as Node3D).global_position if me != null and is_instance_valid(me) else null
	_us_words += 1
	var a := 0     # in ints
	var b := 0     # in s / v / r
	var c := 0     # in g
	var e := 0     # in l
	var todo: Array = []   # [path, seqs, offset in s / v / r, ago, keep]
	while a + 4 <= ints.size():
		var kid := ints[a]
		var n := ints[a + 1]
		var flags := ints[a + 2]
		var nst := ints[a + 3]
		a += 4
		if n < 0 or nst < 0 or a + n + nst * 4 > ints.size() or b + n > ss.size() or b + n > vs.size() \
		or b + n > rs.size() or c + nst * 4 > gs.size() or e + 2 > ls.size():
			return   # a broken word: nothing more of it
		var seqs := ints.slice(a, a + n)
		a += n
		for j in nst:
			var k := ints[a]
			if k >= 0 and k < n:
				var sq := seqs[k]
				_sw_stat[sq] = [ints[a + 1], ints[a + 2], ints[a + 3], gs[c], gs[c + 1], gs[c + 2], gs[c + 3],
					states.get(sq, {}) if states.get(sq) is Dictionary else {}]
			a += 4
			c += 4
		var lead := ls[e]
		var cap := ls[e + 1]
		e += 2
		var p: Variant = _sw_hp.get(kid)
		if p != null and is_instance_valid(p) and (p as Node).is_inside_tree():
			var ago: float
			var keep: float
			if (flags & 4) != 0:
				# the core's state at the host's last step of this belt: drawn from that moment on,
				# at most the step's length (as the host's drawer), or with change-only words until
				# the host's next word must have come (it sends when the motion no longer fits)
				ago = maxf((disp - (host_ms - lead * 1000.0)) / 1000.0, 0.0)
				keep = (cap - ago) if (flags & 8) != 0 else (cap + ST_SLACK - ago)
			else:
				ago = maxf((disp - host_ms) / 1000.0, 0.0)
				keep = cap if cap > 0.5 else ST_KEEP_FAR
			todo.append([p, seqs, b, ago, keep, flags])
			_us_rows += n
			if (flags & 4) != 0:
				_us_near += 1
		b += n
	# rows our player took off any of these belts first: a row picked at a belt's end can be on
	# the next belt in this word (the host moved it before it heard of the pick-up)
	var lean := _sw_script and st_lean
	if lean and st_down_first and st_apply_us > 0 and todo.size() > 1:
		todo = _sw_down_first(todo)
	var tl := Time.get_ticks_usec()
	_pc_add(4, tl - tparse)
	_us_belts += todo.size()
	for t in todo:
		if lean:
			var nm := me_at != null and _near_pick(t[0], me_at)
			t.append(nm)
			if not nm:
				# (script) only our player takes rows, and only near it: no list kept for the others
				_sw_after.erase((t[0] as Node).get_instance_id())
				continue
		_sw_lost_rows(t[0])
	_us_lost += Time.get_ticks_usec() - tl
	_sw_apply_rest([todo, 0, ss, vs, rs, disp, me_at, d, 0, due if due >= 0.0 else disp])


# The belts of a word, from todo[w[1]] on: (script, lean) at most ST_APPLY_US of this frame's word
# work, the rest the next frame (a word of 150 belts took 5-6 ms in one frame; one or two such a
# second were the p99). True: the word is done.
# w: [todo, next index, ss, vs, rs, display clock the word was begun at, me_at, the word, frames carried over,
#     display clock the word was due at]
const ST_APPLY_US := 800       # (2026-11-15) was 1500 with at most 3 frames a word (the 3rd did the rest: p99 3-4 ms)
const ST_LAG_OK := 30.0        # ms behind the display clock that the budget stays as it is
var st_core_frame_us := 250    # (lean) test tools only: usec a frame for cores of belts away from our player
var _sw_core_us := 0           # usec of this frame's word work on cores of belts away from our player
var _sw_budget := ST_APPLY_US  # usec of word work this frame
var _no_locals: Array = []     # (read only)
var sw_fast := 0             # test counter: belts of words that went only into the table
var _idents: Array = []       # n -> PackedInt32Array 0 .. n-1 (read only)

# (2026-11-15) a word's belts the last belt of each line first (by belts to the line's end): a row
# the host moved from A onto the next belt B goes from A's list to B's when B's part comes (drawn on
# from where A drew it). With A first and B a frame or two later (the word spread over frames) the
# row waited at A's end in between and then jumped on (measured: table jumps 212 -> 643 per 20 s
# with the spread, seam jumps 34 -> 120)
var st_down_first := true     # test tools only
var _sw_depth := {}           # path instance id -> belts after it to its line's end (cleared with the map)
const ST_DEPTH_MAX := 63

func _sw_depth_of(p: Node) -> int:
	var id := p.get_instance_id()
	var dv: Variant = _sw_depth.get(id)
	if dv != null:
		return int(dv)
	# walk down, then fill the walked belts (a loop of belts ends at ST_DEPTH_MAX)
	var walk: Array = [p]
	var cur: Node = p
	var base := 0
	while walk.size() <= ST_DEPTH_MAX:
		var dn: Variant = cur.get("downstream")
		if dn == null or not is_instance_valid(dn) or dn == cur or not ("run" in dn):
			break
		var known: Variant = _sw_depth.get((dn as Node).get_instance_id())
		if known != null:
			base = int(known) + 1
			break
		if walk.has(dn):
			break   # a loop
		walk.append(dn)
		cur = dn
	for j in walk.size():
		_sw_depth[(walk[j] as Node).get_instance_id()] = mini(base + walk.size() - 1 - j, ST_DEPTH_MAX)
	return int(_sw_depth[id])

func _sw_down_first(todo: Array) -> Array:
	var buckets: Array = []
	buckets.resize(ST_DEPTH_MAX + 1)
	var top := 0
	for t in todo:
		var p: Variant = t[0]
		var dpt := _sw_depth_of(p) if p != null and is_instance_valid(p) else 0
		if buckets[dpt] == null:
			buckets[dpt] = []
		(buckets[dpt] as Array).append(t)
		top = maxi(top, dpt)
	var out: Array = []
	for k in top + 1:
		if buckets[k] != null:
			out.append_array(buckets[k])
	return out

func _sw_ident(n: int) -> PackedInt32Array:
	while _idents.size() <= n:
		var a := PackedInt32Array()
		a.resize(_idents.size())
		for k in a.size():
			a[k] = k
		_idents.append(a)
	return _idents[n]

var st_apply_us := ST_APPLY_US   # test tools only (0: a word's belts all in one frame)
var _sw_rest: Array = []      # a word not done yet (w), its belts go on before any later word
var _sw_apply_t0 := 0         # usec this frame's word work began
var _sw_behind := false       # a later word is due already (then a word is done in one go)

func _sw_apply_rest(w: Array) -> bool:
	var todo: Array = w[0]
	var ss: PackedFloat32Array = w[2]
	var vs: PackedFloat32Array = w[3]
	var rs: PackedFloat32Array = w[4]
	var me_at: Variant = w[6]
	var d: Dictionary = w[7]
	var i0 := int(w[1])
	# begun in an earlier frame: the same moments on the display clock (t0 / until stay)
	var dd := maxf((_sw_disp() - float(w[5])) / 1000.0, 0.0) if i0 > 0 else 0.0
	var lean := _sw_script and st_lean
	var split := lean and st_apply_us > 0
	var tb_ok := lean and table != null and is_instance_valid(table)
	var tbv: Variant = table   # untyped: a direct call (no name lookup from a String each belt)
	var disp := _sw_disp()
	var now := Time.get_ticks_msec()
	var i := i0
	while i < todo.size():
		var t: Array = todo[i]
		i += 1
		var p: Variant = t[0]
		if p == null or not is_instance_valid(p) or not (p as Node).is_inside_tree():
			continue
		var seqs: PackedInt32Array = t[1]
		var n := seqs.size()
		# (lean) a belt away from our player whose core is not due: only the table, when every row
		# of the word is plain (fields known, not taken, no catch of ours anywhere)
		# (2026-11-15) a due core goes too when this frame's core work is used up (it is due next word)
		var fast := tb_ok and n > 0 and t.size() > 6 and not bool(t[6]) and _sw_local.is_empty()
		if fast:
			# (2026-11-16) not due, or the budget used up and its core made the host's lately (st_core_force_ms)
			var age := now - int(_sw_core_due.get((p as Node).get_instance_id(), -100000))
			fast = age < st_core_ms or (_sw_core_us >= st_core_frame_us and (st_core_force_ms <= 0 or age < st_core_force_ms))
		if fast:
			var tk := not _taken.is_empty()
			var su := not _sw_suspect.is_empty()
			for q in seqs:
				if not _sw_stat.has(q) or (tk and _taken.has(q)) or (su and _sw_suspect.has(q)):
					fast = false
					break
		if fast:
			var tf := Time.get_ticks_usec()
			var ago := float(t[3]) + dd
			var keep := float(t[4]) - dd
			tbv.put(p, seqs, _sw_ident(n), ss, vs, rs, int(t[2]), disp - ago * 1000.0, disp + keep * 1000.0, disp, _no_locals)
			for q in seqs:
				_sw_shown_now[q] = true
			_us_put += Time.get_ticks_usec() - tf
			_pc_add(0, Time.get_ticks_usec() - tf)
			sw_fast += 1
			if st_far_hold and st_hold == 3:
				_sw_far_hold(p, int(t[5]), ss, vs, rs, int(t[2]), n)
		else:
			var tb := Time.get_ticks_usec()
			_sw_wflags = int(t[5])
			_sw_belt(p, seqs, ss, vs, rs, int(t[2]), float(t[3]) + dd, float(t[4]) - dd, me_at, (int(t[5]) & 4) != 0,
				(1 if bool(t[6]) else 0) if t.size() > 6 else -1)
			var nb := t.size() > 6 and bool(t[6])
			var us := Time.get_ticks_usec() - tb
			if _sw_core_last and not nb:
				_sw_core_us += us
			_pc_add(1 if nb else (2 if _sw_core_last else 3), us)
		var tl := Time.get_ticks_usec()
		_sw_deck(p, int(t[5]))
		_us_deck += Time.get_ticks_usec() - tl
		_pc_add(6, Time.get_ticks_usec() - tl)
		# (lean) the frame's budget used up: the rest of the word next frame (as many frames as it
		# takes; _sw_tick raises the budget when the words fall behind)
		if split and not _sw_behind and i < todo.size() and tl - _sw_apply_t0 > _sw_budget:
			w[1] = i
			w[8] = int(w[8]) + 1
			_sw_rest = w
			sw_split += 1
			return false
	_sw_rest = []
	if sw_fault == "corrupt" and Time.get_ticks_msec() < sw_fault_until:
		# test tools only: a belt library that loses rows (the front row of every belt of this word)
		for t in todo:
			var fr: Variant = (t[0] as Node).get("run")
			if fr != null and int(fr.count()) > 0:
				fr.remove_at(int(fr.first()))
	var nzv: Variant = d.get("nz")
	if nzv is PackedInt32Array:
		_sw_empty_others(nzv)
	if _sw_stat.size() > 40000:
		_sw_stat.clear()   # the next words bring what is needed again
	return true

# a belt the host has nothing on has nothing here either (once in ST_FAR_WORDS words)
func _sw_empty_others(nz: PackedInt32Array) -> void:
	var has := {}
	for kid in nz:
		has[kid] = true
	var empty := PackedInt32Array()
	var none := PackedFloat32Array()
	for kid in _sw_hp:
		if has.has(kid):
			continue
		var p: Variant = _sw_hp[kid]
		if p != null and is_instance_valid(p) and int(p.run.count()) > 0:
			_sw_wflags = 0
			_sw_belt(p, empty, none, none, none, 0, 0.0, ST_KEEP_FAR, null)


# One belt of a word: our core's rows made the host's (by number, in the host's order), and the
# host's motion of each handed to our core.
func _sw_belt(path: Node, seqs: PackedInt32Array, ss: PackedFloat32Array, vs: PackedFloat32Array,
		rs: PackedFloat32Array, b: int, ago: float, keep: float, me_at: Variant, nearw := false, near_in := -1,
		core_only := false) -> void:
	var run: Variant = path.run
	var id := path.get_instance_id()
	if not core_only and not _sw_defer.is_empty():
		_sw_defer.erase(id)   # a newer word for this belt
	var script := _sw_script
	var tp := Time.get_ticks_usec()
	if not script:
		if not _sw_held.has(id):
			_sw_held[id] = [path, bool(run.end_held)]
		if not bool(run.end_held):
			run.set_end_held(true)   # nothing goes over an end by itself here
	var n := seqs.size()
	var now := Time.get_ticks_msec()
	# the host's rows we put in: not one our player has just taken off, not one we know nothing of
	var want := PackedInt32Array()
	var want_k := PackedInt32Array()
	var lean := script and st_lean
	var near_me: bool
	if lean and near_in >= 0:
		near_me = near_in == 1
	elif lean:
		near_me = me_at != null and _near_pick(path, me_at)
	else:
		near_me = me_at != null and _near(path, [me_at], ST_PICK_M)
	# (script, lean) our core's rows of a belt away from our player are made the host's at most every
	# st_core_ms (nobody aims at them; the table draws them from every word); near it every word
	var core_now := true
	if lean and not near_me and st_core_ms > 0 and n > 0:
		var age := now - int(_sw_core_due.get(id, -100000))
		core_now = age >= st_core_ms and (_sw_core_us < st_core_frame_us or (st_core_force_ms > 0 and age >= st_core_force_ms))
		if core_now:
			_sw_core_due[id] = now
	_sw_core_last = core_now
	# (lean) our core's list only when it is used
	var got := not lean or core_now or not _sw_local.is_empty()
	var cnt := int(run.count()) if got else 0
	var ours: PackedInt32Array = run.seqs() if cnt > 0 else PackedInt32Array()
	var have := {}
	if not lean:
		for q in ours:
			have[q] = true
		_sw_lost_rows(path, have)
	# (script, lean) _sw_apply looked for lost rows of this belt a moment ago and nothing of ours
	# moved its rows since (our core steps between frames): `have` only when a row lacks its fields
	for k in n:
		var q := seqs[k]
		if not _taken.is_empty() and _taken.has(q) and now - int(_taken[q]) < TAKEN_MS:
			continue
		if script and not _sw_suspect.is_empty() and _sw_suspect.has(q):
			if now - int(_sw_suspect[q]) < ST_SUSPECT_MS:
				continue
			_sw_suspect.erase(q)
		if not _sw_stat.has(q) and lean and have.is_empty():
			if not got:
				got = true
				cnt = int(run.count())
				ours = run.seqs() if cnt > 0 else PackedInt32Array()
			for q2 in ours:
				have[q2] = true
		if not have.has(q) and not _sw_stat.has(q):
			sw_nostat += 1
			_hm_now[4] += 1
			if sw_tap.is_valid():
				sw_tap.call("nostat", path, q, ss[b + k])
			continue
		want.append(q)
		want_k.append(k)
	var locals := PackedInt32Array()
	if not _sw_local.is_empty():
		for q in ours:
			if _sw_local.has(q):
				var e: Array = _sw_local[q]
				var hb: Variant = _sw_bd.get(int(e[0]))
				# it goes in the frame the host's row for it is shown, not before
				var done: bool = hb is Array and (seqs.has(int(hb[0])) or _sw_shown_now.has(int(hb[0])))
				if e[1] == path and not done:
					locals.append(q)
	var length := float(run.length()) if core_now else 0.0
	var hi := maxf(length - ST_END_MARGIN, 0.0)
	var changed := false
	if script and st_hold > 0:
		var hon: bool
		if st_hold == 3:
			# (2026-11-16) near our player: held while the host's end is held (word flag 1) or its front row
			# stands at the end (no room). Else our core passed a row the host keeps there on (into a machine
			# of ours): _sw_lost_rows took it for our player's pick-up and the table dropped it until the
			# belt's next word (a standing belt: 2 s, every other 2 s)
			# (2026-11-16, st_far_hold) belts away from our player too: else our core drains a jam the host has
			var hlen := length if core_now or not (lean and st_far_hold) else float(run.length())
			hon = (near_me or (lean and st_far_hold)) and ((_sw_wflags & 1) != 0 or (want.size() > 0 and hlen > 0.0 \
				and (rs[b + want_k[0]] <= 0.005 or vs[b + want_k[0]] <= 0.0) and ss[b + want_k[0]] >= hlen - 0.5))
		else:
			hon = near_me if st_hold == 1 else nearw
		_sw_hold(path, run, hon)
		if st_hold == 3 and hon:
			hi = maxf(length - 0.005, 0.0)   # held: our core passes nothing on, the front row at the host's spot
	# (script, lean) our core's s_of is its spot at its last step, `dt0` ago (the game's drawer and
	# the pick-up carry it on from there): rows go in, and are compared, at the host's spot at that
	# moment, else every row we put in is drawn up to a step's way ahead (measured: most of the
	# re-placed rows were "ahead by < 20 cm")
	var dt0 := -1.0
	if lean and core_now and st_exact and cnt + want.size() > 0:
		dt0 = maxf(float(run.lead_seconds(Engine.get_physics_interpolation_fraction(), Engine.get_physics_frames())), 0.0)
		if dt0 > ST_STEP_MAX:
			dt0 = 0.0   # not stepping now (asleep): it stands where it is put
	# (2026-11-16, st_defer) near our player our core's rows are re-placed right after our core stepped:
	# a row put in moves at the next step only from when it went in, so a row put in `dt0` after the
	# step is a step's way off one way or the other until put in again (21 cm at 3.22 m/s).
	# A/B 2026-11-16 (fresh session, 20 s each, one run): off 3.69 / 13.7 cm (gap near mean / p95),
	# 1 (all of the core part waits) 3.26 / 11.6 cm but 5 % of the drawn rows missing in our core and
	# word cost p99 1.46 ms, 2 (rows our core lacks at once, re-placing waits) 4.33 / 14.1, p99 1.70 ms
	var deferred := false
	if st_defer > 0 and not core_only and near_me and dt0 > ST_DEFER_DT:
		_sw_defer[id] = [path, seqs, ss, vs, rs, b, ago, keep, me_at, nearw, near_in, _sw_disp(), _sw_wflags]
		deferred = true
	# where each wanted row is drawn now on the host's motion (no glide), its speed
	var tgt := PackedFloat32Array()
	var tv := PackedFloat32Array()
	# (st_ins_now) where a row goes IN: the host's spot now. A row put in moves at our core's next step
	# only from the moment it went in (measured: rows put in at the spot of our core's last step stood
	# there through the next step, one step behind the host after it: 21 cm at 3.22 m/s); compared
	# (tgt) still at our core's last step, as s_of is
	var tin := tgt
	var ins_now := st_ins_now and dt0 > 0.0
	if core_now:
		tgt.resize(want.size())
		tv.resize(want.size())
		if ins_now:
			tin = PackedFloat32Array()
			tin.resize(want.size())
	for wj in (want.size() if core_now else 0):
		var k := want_k[wj]
		var v := vs[b + k]
		var s_host := ss[b + k]
		if v > 0.0:
			if dt0 >= 0.0:
				var room := rs[b + k]
				if room > 0.0:
					var lead0 := minf(ago, ago + keep) - dt0
					s_host += v * lead0 if lead0 < 0.0 else minf(v * lead0, room)
			else:
				s_host += minf(v * minf(ago, ago + keep), maxf(rs[b + k], 0.0))
		tgt[wj] = s_host
		tv[wj] = v
		if ins_now:
			tin[wj] = ss[b + k] + (minf(v * maxf(minf(ago, ago + keep), 0.0), maxf(rs[b + k], 0.0)) if v > 0.0 else 0.0)
	if not ins_now:
		tin = tgt
	var tq := Time.get_ticks_usec()
	_us_want += tq - tp
	if script and not core_only and table != null and is_instance_valid(table):
		# (script replay) the table first: what is drawn; an item waiting for its row goes this frame
		var disp := _sw_disp()
		var la: Array = []
		if not locals.is_empty():
			# our own catches move on our core: drawn from where it draws them now, at its speed
			var dt1 := float(run.lead_seconds(Engine.get_physics_interpolation_fraction(), Engine.get_physics_frames()))
			var f1 := int(run.first())
			for i in range(f1, f1 + int(run.count())):
				var q := int(run.seq_of(i))
				if locals.has(q):
					var lv := maxf(float(run.speed_of(i)), 0.0)
					var lroom := maxf(float(run.row_room(i)), 0.0)
					var lmove := minf(lv * maxf(dt1, 0.0), lroom)
					la.append([q, float(run.s_of(i)) + lmove - lv * ago, int(run.kind_of(i)), int(run.strands_of(i)),
						float(run.side_of(i)), float(run.lift_of(i)), lv, lroom - lmove + lv * ago])
		var tbv: Variant = table
		tbv.put(path, want, want_k, ss, vs, rs, b, disp - ago * 1000.0, disp + keep * 1000.0, disp, la)
	tp = Time.get_ticks_usec()
	_us_put += tp - tq
	if not core_now or (deferred and st_defer == 1):
		for wj in want.size():
			_sw_shown_now[want[wj]] = true
		return
	if not script:
		run.np_raw(true)   # our core's own spots below (not the host's motion)
	var seam := {}
	# (2026-11-16) near our player: the host's list whole (_sw_host_list), else as before
	var hl := -1
	if lean and near_me and st_hostlist == 1:
		hl = _sw_host_list(path, run, want, tgt, tv, locals, hi, st_pick_off, seam, not (script and _sw_hidden(path)))
		if hl == 1:
			changed = true
	var refused := false
	if hl < 0 and not (locals.is_empty() and ours == want):
		changed = true
		if script:
			var rf0 := int(_hm_now[1])
			_sw_fix(path, run, want, want_k, ss, b, locals, hi, tin, tv, seam, lean and not near_me)
			refused = int(_hm_now[1]) != rf0
		else:
			_sw_fix(path, run, want, want_k, ss, b, locals, hi)
	tq = Time.get_ticks_usec()
	_us_fix += tq - tp
	var held := int(run.count()) - int(seam.get("kept", 0))
	var wanted := want.size() + locals.size() - int(seam.get("skip", 0))
	_hm_now[3] += want.size()
	if held < wanted:
		_hm_now[2] += wanted - held
	# rows our core has well behind where they are drawn: put there again (near the player
	# the aim and the pick-up read our core's spot). (script) our core steps on its own: near the
	# player its spot as the game draws it now against the table's.
	var lim := (st_pick_off if lean else ST_PICK_OFF) if near_me else ST_STALE_M
	var exact := script and near_me
	var dt := 0.0
	if exact and dt0 < 0.0 and int(run.count()) > 0:
		dt = float(run.lead_seconds(Engine.get_physics_interpolation_fraction(), Engine.get_physics_frames()))
	var ev := not (script and _sw_hidden(path))
	if lean and hl < 0 and not deferred:
		var rp0 := sw_reput
		_sw_reput_lean(path, run, ours if not changed else PackedInt32Array([-1]), want, want_k, tgt, tv, ss, rs, b,
			ago, keep, dt, hi, lim, exact and dt0 < 0.0, near_me, ev, tin)
		if sw_reput != rp0:
			changed = true
		# (st_hostlist 2) a host row our core refused one by one (an overlap with ours, in jams): the
		# host's list whole
		if refused and near_me and st_hostlist == 2:
			sw_hl_fix_refused += 1
			if _sw_host_list(path, run, want, tgt, tv, locals, hi, lim, {}, ev) == 1:
				changed = true
	# every row of ours the host has, by number (a host row our core lacks must not stop the ones
	# after it from being looked at)
	var wmap := {}
	if not lean:
		for wj in want.size():
			wmap[want[wj]] = wj
	var r := 0
	while not lean and r < int(run.count()):
		# by place in the list: taking the front row off moves first() on
		var i := int(run.first()) + r
		r += 1
		var q := int(run.seq_of(i))
		var wv: Variant = wmap.get(q)
		if wv == null:
			continue
		var wi := int(wv)
		var s_host := tgt[wi]
		var v := tv[wi]
		var k := want_k[wi]
		if script and s_host >= hi:
			continue   # at the joint: our core hands it over by itself
		if exact and dt > 0.0 and v > 0.0 and rs[b + k] > 0.0:
			# (script) our core's s_of is its spot at its last step, `dt` ago (the game's drawer carries
			# it on from there): the host's spot at that moment
			var lead := minf(ago, ago + keep) - dt
			s_host = ss[b + k] + (v * lead if lead < 0.0 else minf(v * lead, rs[b + k]))
		s_host = clampf(s_host, 0.0, hi)
		if absf(float(run.s_of(i)) - s_host) > lim:
			var st: Variant = _sw_stat.get(q)
			if st is Array:
				if sw_tap.is_valid():
					sw_tap.call("reput" if near_me else "reput_far", path, q, float(run.s_of(i)) - s_host)
				run.remove_at(i)
				_sw_put(run, int(run.first()) + r - 1, s_host, v, q, st, ev)
				sw_reput += 1
				if script:
					changed = true
	tp = Time.get_ticks_usec()
	_us_reput += tp - tq
	for wj in want.size():
		_sw_shown_now[want[wj]] = true
	if script:
		var aft: PackedInt32Array = ours if lean and not changed else (run.seqs() if int(run.count()) > 0 else PackedInt32Array())
		if not lean or near_me:
			_sw_after[id] = aft   # (lean) kept only near our player (_sw_apply)
		if _sw_core_at.size() > 60000:
			_sw_core_at.clear()
		for q in aft:
			_sw_core_at[q] = id
		var moving := false
		for wj in want.size():
			if tv[wj] > 0.0 and rs[b + want_k[wj]] > 0.0:
				moving = true
				break
		# the game's drawer of this belt (never for one our drawer hides); our core keeps its own
		# awake state, only woken for rows we put in that move
		if changed and ev:
			_sw_wake(run, true, moving or bool(run.awake))
		_us_after += Time.get_ticks_usec() - tp
		return
	# the host's motion of every row, from the moment the host had it
	var tab := PackedFloat64Array()
	tab.resize((want.size() + locals.size()) * 5)
	var o := 0
	var moving := false
	for wj in want.size():
		var k := want_k[wj]
		var v := vs[b + k]
		var room := rs[b + k]
		tab[o] = want[wj]
		tab[o + 1] = ss[b + k]
		tab[o + 2] = v
		tab[o + 3] = room
		tab[o + 4] = ago
		o += 5
		if v > 0.0 and room > 0.0:
			moving = true
	if not locals.is_empty():
		var f2 := int(run.first())
		for i in range(f2, f2 + int(run.count())):
			var q := int(run.seq_of(i))
			if locals.has(q):
				tab[o] = q
				tab[o + 1] = float(run.s_of(i))
				tab[o + 2] = 0.0
				tab[o + 3] = 0.0
				tab[o + 4] = 0.0
				o += 5
	_sw_after[id] = run.seqs() if int(run.count()) > 0 else PackedInt32Array()
	run.np_raw(false)
	tab.resize(o)
	run.np_stream_set(tab, keep, true)
	_sw_wake(run, changed, moving)


var _sw_wflags := 0           # the flags of the word _sw_belt works on now (1 end held, 4 near, ...)
var st_defer := 0             # test tools only: 0 = near our player our core's rows made the host's at once, 1 = all of it after our core's next step, 2 = re-placing only
const ST_DEFER_DT := 0.010    # s: later than this after our core's step, the core part waits for its next step
const ST_DEFER_MAX := 120.0   # ms: done anyway after this long
var _sw_defer := {}           # path instance id -> the belt's word part [path, seqs, ss, vs, rs, b, ago, keep, me_at, nearw, near_in, disp]
var sw_deferred := 0          # test counter

func _sw_defer_tick() -> void:
	var disp := _sw_disp()
	var frac := Engine.get_physics_interpolation_fraction()
	var pf := Engine.get_physics_frames()
	for id in _sw_defer.keys():
		var e: Array = _sw_defer[id]
		var p: Variant = e[0]
		if p == null or not is_instance_valid(p) or not (p as Node).is_inside_tree():
			_sw_defer.erase(id)
			continue
		var dd := disp - float(e[11])
		var d := float((p as Node).get("run").lead_seconds(frac, pf))
		if d > ST_DEFER_DT and d <= ST_STEP_MAX and dd < ST_DEFER_MAX:
			continue   # not stepped yet
		_sw_defer.erase(id)
		sw_deferred += 1
		var tb := Time.get_ticks_usec()
		_sw_wflags = int(e[12])
		_sw_belt(p, e[1], e[2], e[3], e[4], int(e[5]), float(e[6]) + dd * 0.001, float(e[7]) - dd * 0.001, e[8], bool(e[9]),
			int(e[10]), true)
		_pc_add(1, Time.get_ticks_usec() - tb)


# (script replay) our core hands nothing over this belt's end by itself while `on` (the host's words
# move rows to the next belt): a step-early hand-over put our core's rows ahead of the host's at
# joints. Off again: the game's own end state (its link).
var st_hold := 3             # test tools only: 0 no holds, 1 belts near our player, 2 every belt with near words, 3 near our player while the host's front row stands at the end
var st_core_ms := 250        # (script, lean) our core's rows of belts away from our player: made the host's this often (ms)
# (2026-11-16) a belt away from our player whose core was made the host's this long ago gets it with
# its word even when this frame's far-core budget (st_core_frame_us) is used up. A standing belt's word
# comes every 2 s and the belts late in a word's order found the budget used up word after word: their
# core never got the host's rows (gate: guest 635 hay wads on belts against the host's 763)
var st_core_force_ms := 1000 # test tools only (0: as before, the budget alone)
# (2026-11-16) (st_hold 3) belts away from our player held too while the host's end is held or its
# front row stands at the end: else our core drains a jam the host has (rows standing at a full
# machine) into our machine between two words of the belt (2 s): the rows were gone from our core
var st_far_hold := true      # test tools only
# (2026-11-16) a belt away from our player: a row of ours near its end, moving, that the host's word
# has no more on this belt stays (our core hands it on by itself). The host handed it on a moment
# before our core did and has it on a belt after this one, whose word comes up to 2 s later: taken
# off here, it was gone from our core until then (gate: guest ~5 % short of the host's rows on
# moving belts away from its player, most of them taken off at a belt's end)
var st_end_keep := true      # test tools only
const ST_END_KEEP_M := 0.3   # m before the end (and past it) that such a row stays
var sw_end_kept := 0         # test counter
var _sw_core_due := {}       # path instance id -> msec its core rows were last made the host's
var st_pick_off := ST_PICK_OFF   # (lean) test tools only: near our player, re-placed when further off than this
var st_joint := false        # (lean) test tools only: a near row the host has at the joint, ours well behind: re-placed
var st_exact := true         # test tools only: false = rows go in at the host's spot now (as in 51ccea6)
var st_ins_now := false      # (exact) test tools only: rows go IN at the host's spot now, compared at our core's last step (A/B: no gain)
const ST_STEP_MAX := 0.1     # s: a run whose last step is longer ago than this does not step now

# (st_far_hold) a belt away from our player: held while the host's end is held (word flag 1) or the
# host's front row (the word's first) stands at the end
func _sw_far_hold(path: Node, flags: int, ss: PackedFloat32Array, vs: PackedFloat32Array, rs: PackedFloat32Array,
		b: int, n: int) -> void:
	var run: Variant = path.run
	var on := (flags & 1) != 0
	if not on and n > 0:
		var ln := float(run.length())
		on = ln > 0.0 and (rs[b] <= 0.005 or vs[b] <= 0.0) and ss[b] >= ln - 0.5
	_sw_hold(path, run, on)


func _sw_hold(path: Node, run: Variant, on: bool) -> void:
	var id := path.get_instance_id()
	if on:
		if not _sw_held.has(id):
			_sw_held[id] = [path, bool(run.end_held)]
		if not bool(run.end_held):
			run.set_end_held(true)
	elif _sw_held.has(id):
		var e: Array = _sw_held[id]
		_sw_held.erase(id)
		if path.has_method("_sync_run_links"):
			path.call("_sync_run_links")   # the game's own state (it may have changed meanwhile)
		elif bool(run.end_held) != bool(e[1]):
			run.set_end_held(bool(e[1]))


# (lean) _sw_belt's re-placing on the core's list as two arrays (seqs, positions): a row of ours
# whose spot is further than `lim` from the host's goes there again (remove + insert at its place).
# cur: the core's list when nothing changed it since it was read ([-1]: read it again).
func _sw_reput_lean(path: Node, run: Variant, cur: PackedInt32Array, want: PackedInt32Array, want_k: PackedInt32Array,
		tgt: PackedFloat32Array, tv: PackedFloat32Array, ss: PackedFloat32Array, rs: PackedFloat32Array, b: int,
		ago: float, keep: float, dt: float, hi: float, lim: float, exact: bool, near_me: bool, ev: bool,
		tin := PackedFloat32Array()) -> void:
	var n := int(run.count())
	if n == 0 or want.is_empty():
		return
	if cur.size() == 1 and cur[0] == -1:
		cur = run.seqs()
	var pos: PackedFloat64Array = run.positions()
	if cur.size() != n or pos.size() != n:
		return
	var same := cur == want
	var now_in := tin.size() == tgt.size() and tin != tgt   # (st_ins_now) rows go in at the host's spot now
	var wmap := {}
	if not same:
		for wj in want.size():
			wmap[want[wj]] = wj
	var script := _sw_script
	for r in n:
		var q := cur[r]
		var wi := r
		if not same:
			var wv: Variant = wmap.get(q)
			if wv == null:
				continue
			wi = int(wv)
		var s_host := tgt[wi]
		var v := tv[wi]
		var k := want_k[wi]
		if script and s_host >= hi:
			# at the joint: our core hands it over by itself; (st_joint) unless it is well behind there
			if not (st_joint and near_me and pos[r] < hi - lim):
				continue
		if exact and dt > 0.0 and v > 0.0 and rs[b + k] > 0.0:
			# (script) our core's s_of is its spot at its last step, `dt` ago (the game's drawer carries
			# it on from there): the host's spot at that moment
			var lead := minf(ago, ago + keep) - dt
			s_host = ss[b + k] + (v * lead if lead < 0.0 else minf(v * lead, rs[b + k]))
		s_host = clampf(s_host, 0.0, hi)
		if absf(pos[r] - s_host) <= lim:
			continue
		var st: Variant = _sw_stat.get(q)
		if not (st is Array):
			continue
		if sw_tap.is_valid():
			sw_tap.call("reput" if near_me else "reput_far", path, q, pos[r] - s_host)
		if near_me and st_rebuild and _sw_rebuild(path, run, cur, pos, same, wmap, want_k, tgt, tv, ss, rs, b, ago, keep, dt,
				hi, exact, ev, tin):
			sw_reput += 1
			return
		var n0 := int(run.count())
		run.remove_at(int(run.first()) + r)
		_sw_put(run, int(run.first()) + r, clampf(tin[wi], 0.0, hi) if now_in else s_host, v, q, st, ev)
		sw_reput += 1
		if int(run.count()) != n0:
			return   # it did not go back in: the places after it moved


# (2026-11-15, script, near our player) a row put back INTO a moving group of our core's list came out
# where the group's offset plus the spot we gave says (measured: a row at s 4.27 on a 3.3 m belt, its
# neighbour at -1.0; most of "our core ahead near the belt's end"). So near our player the whole list
# goes in again, front first, each row at the host's spot (a list put in from empty keeps each spot).
# Rows the host does not have (our catches, seam rows) stay where they are. False: not done (a row's
# fields not known).
var st_rebuild := true        # test tools only: false = near our player one row at a time (as before)
var st_spacing := true        # test tools only: false = rows put in again may be closer than the host has them
# (A/B/A 2026-11-16, one long session, 20 s each: st_spacing + st_hold 3 + st_hostlist 2 on / all off / on:
# core gap near p95 15.7 / 23.3 / 6.4 cm; off brings back "same end g0 behind" (rows of a jam behind), 1375 rows)
var sw_rebuilds := 0          # test counter

func _sw_rebuild(path: Node, run: Variant, cur: PackedInt32Array, pos: PackedFloat64Array, same: bool, wmap: Dictionary,
		want_k: PackedInt32Array, tgt: PackedFloat32Array, tv: PackedFloat32Array, ss: PackedFloat32Array,
		rs: PackedFloat32Array, b: int, ago: float, keep: float, dt: float, hi: float, exact: bool, ev: bool,
		tin: PackedFloat32Array) -> bool:
	var n := cur.size()
	var f := int(run.first())
	var now_in := tin.size() == tgt.size() and tin != tgt
	# (st_ins_now) a row kept where our core has it goes in where our core draws it now
	var dtn := 0.0
	if now_in:
		dtn = clampf(float(run.lead_seconds(Engine.get_physics_interpolation_fraction(), Engine.get_physics_frames())), 0.0, ST_STEP_MAX)
	var to_s := PackedFloat32Array()
	var to_v := PackedFloat32Array()
	var sts: Array = []
	to_s.resize(n)
	to_v.resize(n)
	var prev := INF
	var prev_t := INF   # the host's spot of the row ahead (a host row), for the host's spacing
	for r in n:
		var q := cur[r]
		var st: Variant = _sw_stat.get(q)
		if not (st is Array):
			return false
		sts.append(st)
		var wi := r
		if not same:
			var wv: Variant = wmap.get(q)
			wi = int(wv) if wv != null else -1
		var s: float
		var v: float
		if wi < 0 or tgt[wi] >= hi:
			# not the host's (yet), or at the joint (our core hands it over by itself, as _sw_reput_lean
			# leaves it): where our core has it
			s = pos[r]
			v = maxf(float(run.speed_of(f + r)), 0.0) if wi < 0 else tv[wi]
			if now_in and dtn > 0.0:
				var cv := maxf(float(run.speed_of(f + r)), 0.0)
				if cv > 0.0:
					s = minf(s + minf(cv * dtn, maxf(float(run.row_room(f + r)), 0.0)), maxf(hi, pos[r]))
		else:
			s = tin[wi] if now_in else tgt[wi]
			v = tv[wi]
			var k := want_k[wi]
			if exact and dt > 0.0 and v > 0.0 and rs[b + k] > 0.0:
				var lead := minf(ago, ago + keep) - dt
				s = ss[b + k] + (v * lead if lead < 0.0 else minf(v * lead, rs[b + k]))
			s = clampf(s, 0.0, hi)
		if st_spacing and wi >= 0:
			# (2026-11-16) never closer to the row ahead than the host has them (a row kept where our
			# core has it at the joint, behind the host's spot, and the next one at the host's spot
			# overlapped: measured rows 4 cm apart in a jam the host had 29 cm apart; our core then
			# moved the rows behind as a group past the host's standing ones)
			var th := tgt[wi]
			if prev_t != INF and prev_t >= th:
				s = minf(s, prev - (prev_t - th))
			prev_t = th
		else:
			prev_t = INF
		s = minf(s, prev)   # front first: never past the row ahead
		prev = s
		to_s[r] = s
		to_v[r] = v
	for i in range(f + n - 1, f - 1, -1):
		run.remove_at(i)
	for r in n:
		_sw_put(run, int(run.first()) + r, to_s[r], to_v[r], cur[r], sts[r], ev)
	sw_rebuilds += 1
	return true


# (2026-11-16, script, lean, near our player) our core's list made the HOST's in one go: the host's
# rows in its order at its spots (tgt), the ones our core lacks put in, the ones the host does not
# have dropped (our catches and rows our core handed over the joint a step early stay where they
# are). Only when the list differs (rows / order) or a row is further off than `lim`; then the whole
# list goes out and in again front first (one by one a front row put in among ours was refused as
# an overlap in jams, and a row put into a moving group comes out at the group's offset).
# -1: not done (a row's fields not known: the old path), 0: as the host's already, 1: rebuilt.
const ST_START_S := 0.215     # the stock core does not hold a row further back than this at a belt's start (measured)
# st_hostlist (test tools only): 0 = _sw_fix + _sw_reput_lean near our player (as before); 1 = the host's
# list whole on every word (A/B 2026-11-16, one session: core gap near p95 20.5 vs 14.1 cm: every list
# put in again costs each row up to a step, 4.6x the rebuilds); 2 = only after _sw_fix had a row refused
var st_hostlist := 2
var sw_hl_fix_refused := 0   # test counter: words where _sw_fix had a row refused near our player
var sw_hostlists := 0        # test counter: lists made the host's whole
var sw_hl_refused := 0       # test counter: rows the core did not take back in

func _sw_host_list(path: Node, run: Variant, want: PackedInt32Array, tgt: PackedFloat32Array, tv: PackedFloat32Array,
		locals: PackedInt32Array, hi: float, lim: float, seam: Dictionary, ev: bool) -> int:
	var n := int(run.count())
	var cur: PackedInt32Array = run.seqs() if n > 0 else PackedInt32Array()
	var pos: PackedFloat64Array = run.positions() if n > 0 else PackedFloat64Array()
	if cur.size() != n or pos.size() != n:
		return -1
	var f := int(run.first())
	var idx := {}   # seq -> place in our list
	for r in n:
		idx[cur[r]] = r
	var wset := {}
	for q in want:
		wset[q] = true
	# rows of ours that are not the host's and stay where they are, front first
	var stay := PackedInt32Array()
	var kept := 0
	for r in n:
		var q := cur[r]
		if wset.has(q):
			continue
		if locals.has(q):
			stay.append(r)
		elif pos[r] < ST_SEAM_M and _sw_on_up(path, q):
			stay.append(r)
			kept += 1
	var out_q := PackedInt32Array()
	var out_s := PackedFloat32Array()
	var out_v := PackedFloat32Array()
	var need := false
	var p := 0
	var prev := INF
	var prev_t := INF
	var skip := 0
	for wi in want.size():
		var q := want[wi]
		var s := tgt[wi]
		var rv: Variant = idx.get(q)
		var r := int(rv) if rv != null else -1
		if s >= hi:
			# at the joint: where our core has it (it hands it over by itself), unless well behind
			if r < 0:
				if _sw_on_down(path, q):
					skip += 1   # our core has it on the next belt already: it stays there
					continue
				s = hi
			else:
				s = pos[r] if pos[r] >= hi - lim else hi
		else:
			s = maxf(s, 0.0)
		while p < stay.size() and pos[stay[p]] > s:
			out_q.append(cur[stay[p]])
			out_s.append(minf(pos[stay[p]], prev))
			out_v.append(maxf(float(run.speed_of(f + stay[p])), 0.0))
			prev = out_s[out_s.size() - 1]
			prev_t = INF
			p += 1
		if st_spacing:
			if prev_t != INF and prev_t >= tgt[wi]:
				s = minf(s, prev - (prev_t - tgt[wi]))   # never closer than the host has them (_sw_rebuild)
			prev_t = tgt[wi]
		s = minf(s, prev)   # front first: never past the row ahead
		prev = s
		if r < 0 or (absf(pos[r] - s) > lim and not (s < ST_START_S and pos[r] >= s and pos[r] <= ST_START_S + 0.01)):
			need = true   # (a row at a belt's start: our core holds it at ST_START_S, put in again or not)
		out_q.append(q)
		out_s.append(s)
		out_v.append(tv[wi])
	while p < stay.size():
		out_q.append(cur[stay[p]])
		out_s.append(minf(pos[stay[p]], prev))
		out_v.append(maxf(float(run.speed_of(f + stay[p])), 0.0))
		prev = out_s[out_s.size() - 1]
		p += 1
	seam["kept"] = kept
	seam["skip"] = skip
	if not need and out_q == cur:
		return 0
	var sts: Array = []
	for q in out_q:
		var st: Variant = _sw_stat.get(q)
		if not (st is Array):
			return -1
		sts.append(st)
	var oset := {}
	for q in out_q:
		oset[q] = true
	for r in n:
		var q := cur[r]
		if not oset.has(q):
			if sw_tap.is_valid():
				sw_tap.call("rm", path, q, pos[r])
			sw_removed += 1
			_sw_forget(q, path)
			_sw_gone[q] = [Engine.get_process_frames(), Time.get_ticks_msec()]
	for i in range(f + n - 1, f - 1, -1):
		run.remove_at(i)
	for j in out_q.size():
		var q := out_q[j]
		if not idx.has(q):
			_sw_take_elsewhere(path, q)
			sw_inserted += 1
			var gone: Variant = _sw_gone.get(q)
			if gone is Array:
				if int(gone[0]) != Engine.get_process_frames() and Time.get_ticks_msec() - int(gone[1]) <= 1000:
					sw_blinks += 1
				_sw_gone.erase(q)
		var c0 := int(run.count())
		_sw_put(run, int(run.first()) + c0, out_s[j], out_v[j], q, sts[j], ev)   # at the back: front first
		if int(run.count()) == c0:
			sw_hl_refused += 1
	sw_hostlists += 1
	return 1


# The belt's own surface (it scrolls at the belt speed, or shows stopped while the belt is jammed
# or held by a machine): as the host's. Our runs never step, so the game's own stall check sees no
# row move and stopped every busy belt after 0.35 s (measured, see the work log step 86); the
# host's state goes with each word (flag 16), and the stall clock is set so the check agrees with
# it until the next word (far belts: 2 s later).
var st_deck := true

var _deck_ok := {}            # path instance id -> -1 no deck fields, 0 held at the last word, else msec of the last write
const ST_DECK_MS := 500       # (lean) a belt that is not held: its deck written at most this often

func _sw_deck(path: Node, flags: int) -> void:
	if not st_deck:
		return
	var id := path.get_instance_id()
	var okv: Variant = _deck_ok.get(id)
	if okv == null:
		okv = 0 if ("_deck_stalled" in path) and path.has_method("_refresh_deck") else -1
		_deck_ok[id] = okv
	if int(okv) < 0:
		return
	var held := (flags & 16) != 0
	var now := Time.get_ticks_msec()
	if _sw_script and st_lean and not held and int(okv) > 0 and now - int(okv) < ST_DECK_MS:
		return   # (lean) not held, written a moment ago: the stall clock we set holds 5 s
	_deck_ok[id] = 0 if held else now
	path.set("_stall_time", 1.0 if held else -5.0)
	if bool(path.get("_deck_held_by_machine")):
		path.set("_deck_held_by_machine", false)
	if bool(path.get("_deck_stalled")) != held:
		path.set("_deck_stalled", held)
	path.call("_refresh_deck")


# Rows our core lost since our last word for this belt, not by our hand: our player took them (the
# carry tool takes the row, its item is noticed a moment later): not put back for TAKEN_MS.
func _sw_lost_rows(path: Node, have: Dictionary = {}) -> void:
	var was: Variant = _sw_after.get(path.get_instance_id())
	if not (was is PackedInt32Array) or (was as PackedInt32Array).is_empty():
		return
	# lean: the core's list as it is (no Dictionary), and nothing to do when it is the same as after
	# our last word, or (script) when the belt is not near our player
	var lean := st_lean and have.is_empty()
	var cur := PackedInt32Array()
	var hv := have
	if hv.is_empty():
		var run: Variant = path.run
		if int(run.count()) > 0:
			cur = run.seqs()
		if lean:
			if cur == was:
				return   # the same rows as after our last word: none lost
		else:
			hv = {}
			for q in cur:
				hv[q] = true
	var tnow := Time.get_ticks_msec()
	if _taken.size() > 64:
		for t0 in _taken.keys():
			if tnow - int(_taken[t0]) >= TAKEN_MS:
				_taken.erase(t0)
	var dn_seqs: Variant = null   # (script replay) our core hands rows over joints itself
	var near := true
	if _sw_script:
		# our core moves rows on by itself; only our player takes rows, and only near it
		var me: Variant = world.get("player") if world != null and is_instance_valid(world) else null
		near = me != null and is_instance_valid(me) and _near(path, [(me as Node3D).global_position], ST_PICK_M)
		if lean and not near:
			_sw_after[path.get_instance_id()] = cur
			return
	for q0 in was:
		if not (cur.has(q0) if lean else hv.has(q0)) and q0 < ST_LOCAL_SEQ:
			if _sw_script:
				if not near:
					continue
				if _sw_gone.has(q0):
					continue   # our own list sync took it off (on another belt it had gone on to)
				var at0: Variant = _sw_core_at.get(q0)
				if at0 != null and int(at0) != path.get_instance_id():
					continue   # a later word saw it on another belt of ours
				if dn_seqs == null:
					dn_seqs = _sw_down_seqs(path)
				if (dn_seqs as PackedInt32Array).has(q0):
					sw_handed += 1
					continue
				# maybe our player took it (mp_props tells note_taken a moment later): not drawn, not
				# put back for ST_SUSPECT_MS
				_sw_suspect[q0] = tnow
				sw_suspect += 1
				if table != null and is_instance_valid(table):
					table.call("taken", q0)
				if sw_tap.is_valid():
					sw_tap.call("vanish", path, q0, 0.0)
				continue
			_hm_now[0] += 1
			if not _taken.has(q0):
				_taken[q0] = tnow
				if _sw_script and table != null and is_instance_valid(table):
					table.call("taken", q0)
			if sw_tap.is_valid():
				sw_tap.call("vanish", path, q0, 0.0)
	_sw_after[path.get_instance_id()] = cur if lean else PackedInt32Array(hv.keys())


# (script replay) we took row q off our core's belt `path`: the belt our last word saw it on (it
# went over a joint since) must not count it as lost
func _sw_forget(q: int, path: Node) -> void:
	var v: Variant = _sw_core_at.get(q)
	if v == null or int(v) == path.get_instance_id():
		return
	_sw_core_at.erase(q)
	var aft: Variant = _sw_after.get(int(v))
	if aft is PackedInt32Array:
		var pa: PackedInt32Array = aft
		var j := pa.find(q)
		if j >= 0:
			pa.remove_at(j)
			_sw_after[int(v)] = pa


# (script replay) our core has row q on another belt (where our last word saw it, or a belt or two
# on from there): taken off there, it goes in here (a row is on one belt only)
func _sw_take_elsewhere(path: Node, q: int) -> void:
	var v: Variant = _sw_core_at.get(q)
	if v == null or int(v) == path.get_instance_id():
		return
	var p0: Variant = instance_from_id(int(v))
	if p0 == null or not is_instance_valid(p0) or not (p0 is Node) or not ("run" in p0):
		return
	var cand: Array = [p0]
	for p in _sw_next_paths(p0):
		cand.append(p)
		for p2 in _sw_next_paths(p):
			if not cand.has(p2):
				cand.append(p2)
	for p in cand:
		if p == path:
			continue
		var r: Variant = p.run
		var f := int(r.first())
		for i in range(f + int(r.count()) - 1, f - 1, -1):
			if int(r.seq_of(i)) != q:
				continue
			r.remove_at(i)
			sw_moved += 1
			var pid := (p as Node).get_instance_id()
			var aft: Variant = _sw_after.get(pid)
			if aft is PackedInt32Array:
				var pa: PackedInt32Array = aft
				var j := pa.find(q)
				if j >= 0:
					pa.remove_at(j)
					_sw_after[pid] = pa
			return


# (script replay) the row numbers our core has on the belts after this one (two belts on)
func _sw_down_seqs(path: Node) -> PackedInt32Array:
	var out := PackedInt32Array()
	var next := _sw_next_paths(path)
	var all: Array = next.duplicate()
	for p in next:
		for p2 in _sw_next_paths(p):
			if not all.has(p2):
				all.append(p2)
	for p in all:
		if p == path:
			continue
		var r: Variant = p.run
		if r != null and int(r.count()) > 0:
			out.append_array(r.seqs())
	return out


# the belts a row of this one goes on to: the game's link, and every belt starting at its end
func _sw_next_paths(path: Node) -> Array:
	var out: Array = []
	var dn: Variant = path.get("downstream")
	if dn != null and is_instance_valid(dn) and dn != path and ("run" in dn):
		out.append(dn)
	for k in (_down.get(_key_of(path), []) as Array):
		var p: Variant = _paths.get(k)
		if p != null and is_instance_valid(p) and p != path and not out.has(p):
			out.append(p)
	return out


# (script replay) our core has row q on the belt after this one, near its start (handed on by
# itself a step before the host did)
func _sw_on_down(path: Node, q: int) -> bool:
	var dn: Variant = path.get("downstream")
	if dn == null or not is_instance_valid(dn) or dn == path or not ("run" in dn):
		return false
	var r: Variant = dn.run
	var n := int(r.count()) if r != null else 0
	if n == 0:
		return false
	var f := int(r.first())
	for i in range(f + n - 1, maxi(f, f + n - 8) - 1, -1):   # the back rows are the ones near the start
		if int(r.seq_of(i)) == q:
			return float(r.s_of(i)) < ST_SEAM_M
	return false


# (script replay) the host still has row q on the belt before this one (the table's last word for
# it, or a row it keeps drawn over the joint): our core handed it on a step early
func _sw_on_up(path: Node, q: int) -> bool:
	if table == null or not is_instance_valid(table):
		return false
	var wh: Variant = table.get("_where")
	if not (wh is Dictionary):
		return false
	var r: Variant = (wh as Dictionary).get(q)
	if r == null or not (r is Object):
		return false
	return int(r.get("down_id")) == path.get_instance_id() and r.get("path") != path


# our core's list made the host's: rows it does not have go, missing ones are put in at the
# host's spot, in the host's order (our own catches stay where they are)
func _sw_fix(path: Node, run: Variant, want: PackedInt32Array, want_k: PackedInt32Array, ss: PackedFloat32Array, b: int,
		locals: PackedInt32Array, hi: float, tgt := PackedFloat32Array(), tv := PackedFloat32Array(), seam := {},
		far := false) -> void:
	# (script replay) tgt / tv: where each wanted row is now and its speed (our core keeps stepping);
	# seam gets "kept" / "skip": rows at a joint our core has on the other belt than the host
	# far: a belt away from our player (st_end_keep)
	var script := tgt.size() == want.size() and tv.size() == want.size() and _sw_script
	var ev := not (script and _sw_hidden(path))
	var wset := {}
	for q in want:
		wset[q] = true
	# rows that stay where our core has them: our own catches, and (script) rows our core handed
	# over the joint into this belt a step before the host did
	var keep := {}
	for q in locals:
		keep[q] = true
	var f := int(run.first())
	var cnt := int(run.count())
	var seen := {}
	for i in range(f + cnt - 1, f - 1, -1):
		var q := int(run.seq_of(i))
		if (wset.has(q) and not seen.has(q)) or keep.has(q):
			seen[q] = true
			continue
		if script and not wset.has(q) and float(run.s_of(i)) < ST_SEAM_M and _sw_on_up(path, q):
			keep[q] = true
			sw_seam_kept += 1
			seam["kept"] = int(seam.get("kept", 0)) + 1
			continue
		if far and script and st_end_keep and not wset.has(q) and not bool(run.end_held) and float(run.speed_of(i)) > 0.0 \
				and absf(float(run.s_of(i)) - hi) <= ST_END_KEEP_M and not _sw_next_paths(path).is_empty():
			keep[q] = true
			sw_end_kept += 1
			continue
		if sw_tap.is_valid():
			sw_tap.call("rm", path, q, float(run.s_of(i)))
		run.remove_at(i)   # not the host's (any more), or twice
		sw_removed += 1
		if script:
			_sw_forget(q, path)
		_sw_gone[q] = [Engine.get_process_frames(), Time.get_ticks_msec()]
	# what is left must be in the host's order, else it all goes and comes again
	var left := PackedInt32Array()
	f = int(run.first())
	cnt = int(run.count())
	for i in range(f, f + cnt):
		var q := int(run.seq_of(i))
		if not keep.has(q):
			left.append(q)
	var order := PackedInt32Array()
	for q in want:
		if seen.has(q) and not keep.has(q):
			order.append(q)
	if left != order:
		sw_rebuilt += 1
		if sw_tap.is_valid():
			sw_tap.call("rebuild", path, left.size(), 0.0)
		for i in range(f + cnt - 1, f - 1, -1):
			if not keep.has(int(run.seq_of(i))):
				run.remove_at(i)
				sw_removed += 1
		seen.clear()
	# put the missing ones in, front first: each right after the host row before it
	var at := int(run.first())
	for wi in want.size():
		var q := want[wi]
		var k := want_k[wi]
		var s := clampf(tgt[wi] if script else ss[b + k], 0.0, hi)
		if seen.has(q):
			while at < int(run.first()) + int(run.count()) and int(run.seq_of(at)) != q:
				at += 1
			at += 1
			continue
		if script and s >= hi - ST_SEAM_M and _sw_on_down(path, q):
			sw_seam_skip += 1
			seam["skip"] = int(seam.get("skip", 0)) + 1
			continue   # our core has it on the next belt already: it stays there
		# our own catches stay where they are: a new row goes behind the ones further on
		while at < int(run.first()) + int(run.count()) and keep.has(int(run.seq_of(at))) and float(run.s_of(at)) > s:
			at += 1
		var st: Variant = _sw_stat.get(q)
		if not (st is Array):
			continue
		if script:
			_sw_take_elsewhere(path, q)
		_sw_put(run, at, s, tv[wi] if script else 0.0, q, st, ev)
		sw_inserted += 1
		var gone: Variant = _sw_gone.get(q)
		if gone is Array:
			# taken off by an earlier word (another frame), back now: drawn gone in between
			if int(gone[0]) != Engine.get_process_frames() and Time.get_ticks_msec() - int(gone[1]) <= 1000:
				sw_blinks += 1
			_sw_gone.erase(q)
		if sw_tap.is_valid():
			sw_tap.call("ins", path, q, s)
		at += 1


# ev: tell the game's drawer (not for a belt our drawer hides: its run has no event sink then; the
# drawer seats every row from the run again when it gets the run back)
func _sw_put(run: Variant, idx: int, s: float, v: float, q: int, st: Array, ev := true) -> void:
	var n0 := int(run.count())
	run._insert_row(idx, s, float(st[4]), float(st[3]), float(st[5]), float(st[6]), v, int(st[0]), int(st[1]),
		int(st[2]), q, st[7] if st[7] is Dictionary else {})
	if int(run.count()) != n0 + 1:
		_hm_now[1] += 1
		return
	if ev:
		run._ev_board(idx)


# the game's drawer: a run with rows that move is drawn every frame (awake), one that changed once
func _sw_wake(run: Variant, draw: bool, moving: bool) -> void:
	if bool(run.awake) != moving:
		run.awake = moving
	if draw or moving:
		var dq: Variant = run.draw_queue
		if dq is Array and not bool(run.draw_queued):
			(dq as Array).append(run)
			run.draw_queued = true
