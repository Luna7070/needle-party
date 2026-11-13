extends Node

# Smooth belt drawing on this PC (host, single player and guest).
#
# (2026-11-15, test feature, setting mp.belt_smooth) The game's drawer carries a belt's free group
# (and a moving jam) on from its last core step by speed x time, but never past the room the group
# had at that step. When what is in front of the group moves on during the step (the next belt's
# last row, a jam that clears), the group stops at that old room until the next step and then
# jumps on: measured on the busiest spot of test save 3, 533 of 584 of the game's own drawn row
# jumps (91 %) were exactly that.
#
# (2026-11-15, round 4: script only, no native library) We give the free group the room the thing
# in front of it gains in one step, by correcting the drawer's own output: the game's record pool
# draws every row on the GPU from one number per belt group (its offset along the belt, in a small
# state texture; the vertex shader places the rows along the belt). Right after the pool's frame
# (process_priority above its 100) we write our offset for the few belts whose free group the pool
# holds at its room, and send the state texture once (a few kB). No extra meshes, nothing drawn
# twice, no per-row work: per near belt a few numbers per core step, and per frame only for the
# belts that are held at their room. The rows the core keeps, steps and hands over are untouched
# (visual only). With the game's older batch drawer (TAA on, or a headless copy) the free group's
# node of a straight belt is moved the same way; bent belts keep the game's drawing there.
#
# (2026-11-15, round 4) SMOOTH BELTS is the one belt switch for players, on by default, with the
# same safety as belt replay:
#   - SMOOTH_BUILDS: the game builds it was tested on. Another build where everything this reads
#     is still there runs ON PROBATION: for the first PROBATION_MS of each world a health watch
#     compares our drawing with the game's own on a few belts near the player; on a fault smooth
#     drawing goes off until the game is started again (the drawer's own offsets back at once, no
#     restart), with one log line saying why. Script errors in this file do the same on any build.
#   - the state for the panel (panel_state) and the anonymous logs (report_lines, one "belt min"
#     line a minute, the belt events), so a log says for sure what ran and why.

const NEAR_M := 40.0          # belts this close to the player and in view are drawn smooth
const VIEW_SLACK := 6.0       # m: a belt this far outside the view still counts (the view turns)
const FIND_MS := 500          # how often the near / in-view list is made again (spread over frames)
const FIND_SLICE := 50        # belts looked at per frame while it is made
const IDLE_TICKS := 6         # a belt that did not step: its clock read again this many physics frames later
const STEP_BUDGET := 24       # belt steps worked out per frame at most (the rest the next frame, in turn)
const SMOOTH_BUILDS := ["26646592"]
const PROBATION_MS := 300000
const BUILD_WAIT_MS := 15000  # the build id not known after this long: taken as untested
const WATCH_BELTS := 8        # belts near the player the health watch follows (probation only)
const JUMP_M := 0.05          # a drawn row that moves 5 cm more (or back) than its speed in a frame
# health limits per 5 s (from good runs, with a margin: see the work log step 87)
const HM_ERRORS := 3          # script errors in this file, or frames of ours that did not finish (any build;
                              # a release build stops a function at an error without a word: counted here)
const HM_LAYOUT := 3          # answers that cannot be right (group counts, speeds, the drawer's state)
const HM_JUMPS_MIN := 30      # smooth jumps: at least this many, and more than
const HM_JUMP_RATIO := 1.0    # ... the game's own drawing would make x this + HM_JUMP_SLACK
const HM_JUMP_SLACK := 15
const HM_BACK_MIN := 6        # rows drawn back: at least this many, and more than
const HM_BACK_RATIO := 2.0    # ... the game's own drawing x this + HM_BACK_SLACK
const HM_BACK_SLACK := 4
# what smooth drawing calls on a belt run, with its number of arguments
const API := {"draw_into": 1, "lead_seconds": 2, "first": 0, "count": 0, "rel_of": 1, "seq_of": 1, "speed_of": 1}
const PROPS := ["end_held", "stepped_tick", "last_dt"]
const POOL_PROPS := ["_by_run", "_state", "_state_tex", "_state_rows", "_tex_count"]
const TEX_W := 256            # the pool's state texture width (BeltRecordPool.TEX_W, checked)
const MINUTE_MS := 60000
const MAX_EVENTS := 40
const MAX_MINUTES := 90
const COST_N := 600           # frames of our cost kept for p50 / p99

# One belt near the player: its core state at its last step, cached until the next step.
class Entry:
	var path: Node
	var pid := 0
	var run: Object
	var tick := -2            # the core step the cache is for (-2: none yet)
	var s0 := 0.0             # free group: offset, speed, room at that step
	var v := 0.0
	var room := 0.0
	var extra := 0.0          # the room the thing in front gains in one step (0: nothing to do)
	var o := -1               # pool: index of the group offsets in its state; -1 none
	var rd: Object = null     # the drawer's own record of this belt
	var over := false         # we drew this belt's free group differently this frame
	var hot := false          # this step its free group can reach its room (or the watch follows it)
	var next := 0             # the physics frame its next step is due (its clock is not read before)
	var flip := false         # test tools only: flips every step (fault "jitter")
	var seen := 0             # _find round it was last near
	# health watch: the free group's front row
	var q := -1
	var rel := 0.0
	var last_q := -1
	var last_o := NAN
	var last_s := NAN
	var last_us := 0

var mp: Node
var _entries: Array[Entry] = []
var _by_id := {}             # path instance id -> Entry
var _by_run_id := {}         # run instance id -> Entry (test tools)
var _round := 0
var _at := -100000
var _st := PackedFloat64Array()
var _on := false
var _was_over := false
var _hot: Array[Entry] = []  # the belts that need work every frame this step (few)
var _hot_tick := -1          # the physics frame _hot was made in
var _poll_at := 0            # where the next physics frame's look at the step clocks starts (in turn)
var drawer := ""             # "pool" / "batch" / "" (none found yet)
var updates := 0             # test counter: core steps whose extra room we worked out
var overrides := 0           # test counter: belt frames we drew differently from the drawer
var _cost: PackedInt32Array = PackedInt32Array()
var _cost_i := 0

# ---- state (panel, logs)
var state := "wait"          # wait, active, probation, off_setting, off_update, off_problem
var why := ""                # the reason, for the logs ("" when active)
var core_version := ""       # our native belt core (dev builds only; the release has none)
var game_build := ""
var core_skip := ""          # the installer's reason code when it took a belt core of ours out
var probation := false
var fault := ""              # why smooth drawing went off this run of the game ("" = it did not)
var test_fault := ""         # test tools only: "jitter" (offsets that jump), "layout" (answers that cannot be), "error"
var _build_asked := -1
var _api := -1               # -1 not checked yet, 0 something missing (_off_state says what), 1 fine
var _off_state := ""
var _off_why := ""
var _probation_end := 0
var _probation_world := 0
var _passed := false
var events: Array = []       # "<s since start> s <text>"
var minutes: Array = []      # one "belt min ..." line a minute
var _minute_at := 0
var _minute_base := {}
var _started := 0

# ---- health watch (probation)
var _hm_at := 0
var _hm_ring: Array = []     # per second: [smooth jumps, game jumps, smooth back, game back, layout, -, errors]
var _hm_now := [0, 0, 0, 0, 0, 0, 0]
var hm_total := [0, 0, 0, 0, 0, 0, 0]
var _err_seen := 0
var _runs_started := 0       # frames of ours begun / finished (a frame stopped by an error does not finish)
var _runs_done := 0
var _missed_seen := 0
var _show: Node = null       # mp_belt_show.gd while it draws belts itself (their runs out of the game's drawer)


func _ready() -> void:
	_started = Time.get_ticks_msec()
	_minute_at = _started
	process_priority = 1000   # after the game's belt drawers (100): we correct their output
	_st.resize(10)
	_cost.resize(COST_N)


func _process(_d: float) -> void:
	var t0 := Time.get_ticks_usec()
	var now := Time.get_ticks_msec()
	_health(now)   # first: an error further down cannot stop the watch
	_process_inner(now)
	_minute(now)
	var us := Time.get_ticks_usec() - t0
	if _on:
		_cost[_cost_i % COST_N] = us
		_cost_i += 1
		if mp != null and is_instance_valid(mp) and mp.has_method("perf"):
			mp.perf("belt_draw", us)


func _process_inner(now: int) -> void:
	if mp == null or not is_instance_valid(mp):
		return
	if mp.get("belt_smooth") != true:
		if _on:
			_clear()
		_set_state("off_setting", "setting off")
		return
	if fault != "":
		if _on:
			_clear()
		_set_state("off_problem", "problem found: " + fault)
		return
	if _scan_i >= 0:
		_find()
	elif now - _at >= FIND_MS:
		_at = now
		_find()
	if not _check(now):
		if _on:
			_clear()
		return
	# a guest that replays the host's belts (a dev build with our native core): the host's words
	# carry the room, its runs never step here
	var bs: Variant = mp.world_sync.get("belts_sync") if mp.world_sync != null and is_instance_valid(mp.world_sync) else null
	if bs != null and is_instance_valid(bs) and bool(bs.get("replay_on")):
		if _on:
			_clear()
		_set_state("active", "")
		return
	_on = true
	var sh: Variant = mp.get("belt_show")
	_show = sh if sh != null and is_instance_valid(sh) and bool(sh.get("active")) else null
	_set_state("probation" if probation else "active", "")
	_runs_started += 1
	if test_fault == "error":
		return   # test tools only: a frame stopped by a script error (it never finishes)
	if drawer == "pool":
		_frame_pool()
	elif drawer == "batch":
		_frame_batch()
	_runs_done += 1


# The core's state of a belt's free group at its last step, and how far the thing in front of the
# group moves on in one step: once per core step (every ~67 ms), not per frame.
func _step(e: Entry, t: int) -> void:
	e.tick = t
	e.flip = not e.flip
	var run: Variant = e.run
	run.draw_into(_st)
	var n := int(run.count())
	var nj := int(_st[7])
	var nf := int(_st[8])
	if test_fault == "layout":
		nj = n + 3   # test tools only: a belt library that answers something else
	if nj < 0 or nf < 0 or nj + nf > n or is_nan(_st[0]) or is_nan(_st[1]) or is_nan(_st[2]) \
			or _st[1] < -0.001 or _st[1] > 50.0:
		_hm_now[4] += 1
		e.extra = 0.0
		e.q = -1
		return
	e.s0 = _st[0]
	e.v = maxf(_st[1], 0.0)
	e.room = _st[2]
	e.extra = 0.0
	e.q = -1
	if nf > 0 and probation and _watch_set.has(e.pid):
		var i := int(_st[6]) + nj   # the free group's front row (after the head and the jam)
		e.q = int(run.seq_of(i))
		e.rel = float(run.rel_of(i))
	e.hot = e.q >= 0 or test_fault == "jitter"
	var step := float(run.last_dt)
	if nf == 0 or step <= 0.0 or e.v <= 0.0 or is_inf(e.room):
		return
	if e.v * step * 1.5 <= e.room:
		return   # this step the group cannot reach its room: the drawer's own drawing is right
	# the front of the run: what comes after its end (nothing moves on at a held end)
	var v_out := false
	if nj == 0 and not bool(run.end_held):
		var dn: Variant = run.get("downstream")
		if dn != null and is_instance_valid(dn) and not bool(dn.get("blocked")):
			# the next belt takes rows on unless its own end is held and it is full to the joint
			var m := int(dn.count())
			if m == 0 or not bool(dn.end_held) or float(dn.speed_of(int(dn.first()) + m - 1)) > 0.0:
				v_out = true
	# the free group runs into the jam if there is one (as fast as it clears), else into what is
	# after the end: a belt whose last row moves, or an empty one, lets it on at its own speed.
	# A jam that clears is left as it is (more room for it measured worse: rows stepped back).
	if nj > 0:
		e.extra = minf(e.v, maxf(_st[4], 0.0)) * step
	elif v_out:
		e.extra = e.v * step
	if e.extra > 0.0:
		e.hot = true
	updates += 1


# Once per physics frame (the cores step only then): every near belt's step clock; a belt that
# stepped gets its numbers again. The belts that need work every frame are listed in _hot.
func _poll(ptick: int) -> void:
	if ptick == _hot_tick:
		return
	_hot_tick = ptick
	_hot.clear()
	var budget := STEP_BUDGET
	var tps := float(Engine.physics_ticks_per_second)
	var n := _entries.size()
	if _poll_at >= n:
		_poll_at = 0
	var stop := -1
	for k in n:
		var e: Entry = _entries[(_poll_at + k) % n]
		if budget == 0 and stop < 0:
			stop = (_poll_at + k) % n   # the next frame starts here: every belt gets its turn
		if ptick >= e.next and (budget > 0 or e.hot):
			var run: Variant = e.run
			if run != null and is_instance_valid(e.path):
				var t := int(run.stepped_tick)
				if t != e.tick:
					_step(e, t)
					budget -= 1
					# the next step is one step length after this one: no need to look before
					e.next = t + maxi(1, roundi(float(run.last_dt) * tps)) if t > 0 else ptick + IDLE_TICKS
				else:
					e.next = ptick + (1 if e.hot else IDLE_TICKS)
		if e.hot or e.over:
			_hot.append(e)
	_poll_at = stop if stop >= 0 else 0


# Pool: our offset for each belt whose free group is held at its room this frame, then the state
# texture once. The pool's own array is left as it is: its next frame starts from its own numbers.
func _frame_pool() -> void:
	var pool: Variant = BeltRecordPool.instance
	if pool == null or not is_instance_valid(pool):
		return
	var frac: float = Engine.get_physics_interpolation_fraction() if BeltRunBatch.pinned_frac < 0.0 else BeltRunBatch.pinned_frac
	var ptick := Engine.get_physics_frames()
	var buf: PackedFloat32Array = pool._state
	var size := buf.size()
	var any := false
	var tw := Time.get_ticks_usec()
	var jitter := test_fault == "jitter"
	_poll(ptick)
	for e in _hot:
		var run: Variant = e.run
		if run == null or not is_instance_valid(e.path):
			continue
		if _show != null and _show.is_hidden(e.path):
			_forget(e)
			continue
		var t := e.tick
		var watched := e.q >= 0
		if e.extra <= 0.0 and not jitter and not watched:
			e.over = false
			continue
		var dt := float(run.lead_seconds(frac, ptick))
		var go := e.v * dt
		var own := e.s0 + minf(go, e.room)
		var mine := own
		if go > e.room:
			mine = e.s0 + minf(go, e.room + e.extra)
		if jitter:
			mine = own + (0.2 if e.flip else 0.0)   # test tools only: offsets that jump every step
		if watched:
			_watch_row(e, own, mine, tw)
		if mine == own:
			e.over = false
			continue
		if e.o < 0:
			if e.rd == null or not is_instance_valid(e.path):
				continue
			e.o = int(e.rd.get("tex")) * 4
		if e.o < 0 or e.o >= size:
			continue
		buf[e.o] = mine
		e.over = true
		any = true
		overrides += 1
	if any or _was_over:
		_upload(pool, buf)
	_was_over = any


func _upload(pool: Variant, buf: PackedFloat32Array) -> void:
	var rows := maxi(1, ceili(float(int(pool._tex_count)) / TEX_W))
	if rows != int(pool._state_rows) or buf.size() < rows * TEX_W * 4:
		return   # the pool grows its texture this frame: its own upload stands
	var img := Image.create_from_data(TEX_W, rows, false, Image.FORMAT_RGBAF, buf.slice(0, rows * TEX_W * 4).to_byte_array())
	(pool._state_tex as ImageTexture).update(img)


# Batch drawer (TAA on, headless copies): a straight belt's free group is one node moved along the
# belt; bent belts write every row and keep the game's drawing.
func _frame_batch() -> void:
	var frac: float = Engine.get_physics_interpolation_fraction() if BeltRunBatch.pinned_frac < 0.0 else BeltRunBatch.pinned_frac
	var ptick := Engine.get_physics_frames()
	var tw := Time.get_ticks_usec()
	var jitter := test_fault == "jitter"
	_poll(ptick)
	for e in _hot:
		var run: Variant = e.run
		if run == null or not is_instance_valid(e.path):
			continue
		if _show != null and _show.is_hidden(e.path):
			_forget(e)
			continue
		var t := e.tick
		var watched := e.q >= 0
		if e.extra <= 0.0 and not jitter and not watched:
			if e.over:
				e.over = false
				_batch_put(e, e.s0 + minf(e.v * float(run.lead_seconds(frac, ptick)), e.room))
			continue
		var dt := float(run.lead_seconds(frac, ptick))
		var go := e.v * dt
		var own := e.s0 + minf(go, e.room)
		var mine := own
		if go > e.room:
			mine = e.s0 + minf(go, e.room + e.extra)
		if jitter:
			mine = own + (0.2 if e.flip else 0.0)
		if watched:
			_watch_row(e, own, mine, tw)
		if mine == own and not e.over:
			continue
		e.over = mine != own
		_batch_put(e, mine)
		if e.over:
			overrides += 1


# (2026-11-15) a belt mp_belt_show takes out of the game's drawer or gives back: its drawer record
# and its pool slot are not ours any more (the slot can go to another run); found again by _find
func forget_path(path: Node) -> void:
	if path == null:
		return
	var e: Entry = _by_id.get(path.get_instance_id())
	if e != null:
		_forget(e)


func _forget(e: Entry) -> void:
	e.rd = null
	e.o = -1
	e.over = false


func _batch_put(e: Entry, fo: float) -> bool:
	var rd: Variant = e.rd
	if rd == null or not bool(rd.get("straight")):
		return false
	var at: Vector3 = (rd.get("basis") as Basis).z * fo
	for b in rd.get("free_bins"):
		var nd: Variant = b.get("node")
		if nd != null:
			(nd as Node3D).position = at
	return true


# The near, in-view belts: made again every FIND_MS, FIND_SLICE belts a frame (no hitch with
# thousands of belts); the list in use stays until the new one is complete.
var _scan: Array = []        # BeltPath._live as it was when this round began
var _scan_i := -1            # -1: no round running
var _scan_out: Array[Entry] = []
var _scan_near: Array = []
var _scan_eye := Vector3.ZERO
var _scan_planes: Array[Plane] = []
var _scan_by_run: Dictionary = {}
var _scan_runs: Dictionary = {}   # run instance id -> Entry, made while scanning


func _find() -> void:
	if _scan_i < 0:
		var w: Variant = mp.world_sync.get("world") if mp.world_sync != null and is_instance_valid(mp.world_sync) else get_tree().current_scene
		var me: Variant = w.get("player") if w != null and is_instance_valid(w) else null
		if me == null or not is_instance_valid(me) or not (me as Node3D).is_inside_tree():
			_entries.clear()
			return
		# a new world: probation again on an untested build
		var wid := (w as Object).get_instance_id()
		if probation and fault == "" and wid != _probation_world and _api == 1:
			_start_probation(wid)
		drawer = "pool" if BeltRunBatch.pool_wanted() else "batch"
		var reg: Variant = BeltRecordPool.instance if drawer == "pool" else BeltRunBatch.instance
		_scan_by_run = reg.get("_by_run") if reg != null and is_instance_valid(reg) and reg.get("_by_run") is Dictionary else {}
		_scan_eye = (me as Node3D).global_position
		_scan_planes.clear()
		var cam := get_viewport().get_camera_3d() if get_viewport() != null else null
		if cam != null and DisplayServer.get_name() != "headless":
			for pl in cam.get_frustum():
				_scan_planes.append(pl)
		_scan = BeltPath._live.duplicate()
		_scan_i = 0
		_scan_out = []
		_scan_near = []
		_scan_runs = {}
		_round += 1
	var end := mini(_scan_i + FIND_SLICE, _scan.size())
	while _scan_i < end:
		var p: Variant = _scan[_scan_i]
		_scan_i += 1
		if p == null or not is_instance_valid(p) or not (p as Node).is_inside_tree():
			continue
		var run: Variant = p.get("run")
		if run == null:
			continue
		var mid: Variant = p.get("_mid")
		var m3: Vector3 = mid if mid is Vector3 else (p as Node3D).global_position
		var d := m3.distance_to(_scan_eye)
		if d > NEAR_M:
			continue
		var half := float(run.length()) * 0.5 + VIEW_SLACK
		var seen := true
		for pl in _scan_planes:
			if pl.distance_to(m3) > half:
				seen = false
				break
		if not seen:
			continue
		var pid := (p as Object).get_instance_id()
		var e: Entry = _by_id.get(pid)
		if e == null:
			e = Entry.new()
			e.path = p
			e.pid = pid
			_by_id[pid] = e
		if e.run != run:
			e.run = run
			e.tick = -2
		var rd: Variant = _scan_by_run.get(run)
		if _show != null and _show.is_hidden(p):
			rd = null   # mp_belt_show draws it: nothing of the game's drawer is ours to write
		if rd != e.rd:
			e.rd = rd
			e.o = -1
		e.seen = _round
		_scan_out.append(e)
		_scan_runs[(run as Object).get_instance_id()] = e
		if probation and e.v > 0.0:
			_near_add(d, pid)   # the nearest belts whose free group moved at their last step
	if _scan_i < _scan.size():
		return
	_scan_i = -1
	_scan = []
	# belts that left: the drawer's own numbers again (the pool's are in its next upload)
	for pid in _by_id.keys():
		var e: Entry = _by_id[pid]
		if e.seen != _round:
			if e.over and drawer == "batch":
				_batch_put(e, e.s0)
			_by_id.erase(pid)
	_entries = _scan_out
	_scan_out = []
	_hot_tick = -1
	_by_run_id = _scan_runs
	_scan_runs = {}
	if probation:
		_watch_set = {}
		for x in _scan_near:
			_watch_set[int(x[1])] = true
		_scan_near = []


# the WATCH_BELTS nearest belts, kept while scanning (no sort of hundreds)
func _near_add(d: float, pid: int) -> void:
	if _scan_near.size() < WATCH_BELTS:
		_scan_near.append([d, pid])
		return
	var far_i := 0
	for i in range(1, _scan_near.size()):
		if float(_scan_near[i][0]) > float(_scan_near[far_i][0]):
			far_i = i
	if d < float(_scan_near[far_i][0]):
		_scan_near[far_i] = [d, pid]


# test tools: what the first n belts with extra room look like now
func debug_entries(n: int) -> Array:
	var out: Array = []
	for e in _entries:
		if out.size() >= n:
			break
		if e.extra > 0.0 or e.q >= 0:
			out.append({"tick": e.tick, "s0": e.s0, "v": e.v, "room": e.room, "extra": e.extra, "o": e.o,
				"rd": e.rd != null, "straight": bool(e.rd.get("straight")) if e.rd != null and "straight" in e.rd else null,
				"bins": (e.rd.get("free_bins") as Array).size() if e.rd != null and "free_bins" in e.rd else -1,
				"q": e.q, "over": e.over})
	return out


func _clear() -> void:
	_on = false
	if drawer == "pool":
		var pool: Variant = BeltRecordPool.instance
		if pool != null and is_instance_valid(pool) and _was_over:
			_upload(pool, pool._state)   # the drawer's own offsets on the screen again
	elif drawer == "batch":
		for e in _entries:
			if e.over:
				_batch_put(e, e.s0)
	for e in _entries:
		e.over = false
	_was_over = false


# for the test tools (belt_metrics): the free group's extra room of this run now (0: none)
func extra_for(run: Object) -> float:
	if not _on or run == null:
		return 0.0
	var e: Entry = _by_run_id.get(run.get_instance_id())
	if e == null:
		return 0.0
	var t := int(run.get("stepped_tick"))
	if e.tick != t:
		_step(e, t)   # the tools can look before our frame does: the same numbers our frame will use
	return e.extra


# ------------------------------------------------------------------ checks and state

# Everything smooth drawing reads, asked once by name; the game build.
func _check(now: int) -> bool:
	if _api == 1:
		return true
	if _api == 0:
		_set_state(_off_state, _off_why)
		return false
	var run: Variant = _any_run()
	if run == null:
		return false
	var b := str(mp.call("game_build")) if mp.has_method("game_build") else ""
	if b == "":
		if _build_asked < 0:
			_build_asked = now
		if now - _build_asked < BUILD_WAIT_MS:
			_set_state("wait", "game build not known yet")
			return false
		b = "unknown"
	game_build = b
	if (run as Object).has_method("np_core_version"):
		core_version = str(run.call("np_core_version"))
	var miss := _api_missing(run)
	var drawer_ok := drawer != ""
	if drawer == "pool":
		var pool: Variant = BeltRecordPool.instance
		if pool == null or not is_instance_valid(pool):
			miss.append("BeltRecordPool.instance")
		else:
			for pr in POOL_PROPS:
				if not (pr in pool):
					miss.append("BeltRecordPool." + pr)
			if pool.get("_state_tex") != null and not (pool.get("_state_tex") is ImageTexture):
				miss.append("BeltRecordPool._state_tex type")
			if pool.get("TEX_W") != null and int(pool.get("TEX_W")) != TEX_W:
				miss.append("BeltRecordPool.TEX_W %s" % pool.get("TEX_W"))
	elif not drawer_ok:
		return false
	if not miss.is_empty():
		_set_state("off_update", "game update: belts differ (%s)" % ", ".join(miss))
		event("belt smooth off: game build %s, belts differ: %s (normal drawing)" % [b, ", ".join(miss)])
		_api_off()
		return false
	_api = 1
	probation = not SMOOTH_BUILDS.has(b)
	event("belt smooth on: script drawing (%s drawer), game build %s (%s)%s" % [drawer, b,
		"tested" if not probation else "not tested yet", (", native core " + core_version) if core_version != "" else ""])
	_note_old_core()
	if probation:
		var w: Variant = mp.world_sync.get("world") if mp.world_sync != null and is_instance_valid(mp.world_sync) else get_tree().current_scene
		_start_probation((w as Object).get_instance_id() if w != null and is_instance_valid(w) else 0)
	return true


func _api_off() -> void:
	_api = 0
	_off_state = state
	_off_why = why


func _start_probation(wid: int) -> void:
	_probation_world = wid
	_probation_end = Time.get_ticks_msec() + PROBATION_MS
	_passed = false
	_hm_ring.clear()
	_hm_now = [0, 0, 0, 0, 0, 0, 0]
	for e in _entries:
		e.last_o = NAN
	event("belt smooth probation start: game build %s not tested yet, watched for %d min" % [game_build, PROBATION_MS / 60000])


# the installer's note when it took an older belt core of ours out, or did not put it in (a code only)
func _note_old_core() -> void:
	var skip_path := OS.get_executable_path().get_base_dir() + "/np_beltcore_skip.json"
	core_skip = ""
	if not FileAccess.file_exists(skip_path):
		return
	var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(skip_path))
	if j is Dictionary:
		for c in str((j as Dictionary).get("reason", "")).left(24):
			if c == "_" or (c >= "a" and c <= "z"):
				core_skip += c
	if core_skip != "":
		event("belt core: installer note %s" % core_skip)


func _api_missing(obj: Object) -> Array:
	var have := {}
	for m in obj.get_method_list():
		if m is Dictionary and m.has("name"):
			var args: Variant = m.get("args")
			have[String(m["name"])] = (args as Array).size() if args is Array else -1
	var miss: Array = []
	for name in API:
		if not have.has(name):
			miss.append(String(name))
		elif int(have[name]) != int(API[name]) and int(have[name]) >= 0:
			miss.append("%s(%d args, want %d)" % [name, int(have[name]), int(API[name])])
	for pr in PROPS:
		if not (pr in obj):
			miss.append(pr)
	return miss


func _set_state(s: String, w: String) -> void:
	if s == state and w == why:
		return
	state = s
	why = w


# a belt event: the trace (timeline) and the list in the log's report (names are never looked for there)
func event(text: String) -> void:
	push_warning("[NP] " + text)
	var line := "%d s %s" % [(Time.get_ticks_msec() - _started) / 1000, text]
	events.append(line)
	if events.size() > MAX_EVENTS:
		events.pop_front()
	if mp != null and is_instance_valid(mp) and mp.trace != null and mp.trace.has_method("note"):
		mp.trace.note(text)


func _any_run() -> Variant:
	for item in BeltPath._live:
		if is_instance_valid(item) and item.get("run") != null:
			return item.get("run")
	return null


# ------------------------------------------------------------------ health watch

var _watch_set := {}         # path instance ids of the belts the watch follows

# per frame on probation: a watched belt's free group front row as the game's drawer draws it and
# as we do; jumps of each counted (a step that moves it on more than its speed, or back)
func _watch_row(e: Entry, own: float, mine: float, tw: int) -> void:
	var s_o := own + e.rel
	var s_s := mine + e.rel
	if e.q == e.last_q and not is_nan(e.last_o):
		var fdt := float(tw - e.last_us) / 1000000.0
		if fdt > 0.0 and fdt <= 0.1:
			var lim := e.v * fdt + JUMP_M
			var d_o := s_o - e.last_o
			var d_s := s_s - e.last_s
			if d_s > lim or d_s < -JUMP_M:
				_hm_now[0] += 1
			if d_o > lim or d_o < -JUMP_M:
				_hm_now[1] += 1
			if d_s < -JUMP_M:
				_hm_now[2] += 1
			if d_o < -JUMP_M:
				_hm_now[3] += 1
	e.last_q = e.q
	e.last_o = s_o
	e.last_s = s_s
	e.last_us = tw


# once a second: script errors in this file (any build), and on probation the 5 s totals
func _health(now: int) -> void:
	if now - _hm_at < 1000:
		return
	_hm_at = now
	var errs := 0
	if mp != null and is_instance_valid(mp) and mp.trace != null and mp.trace.has_method("errors_in"):
		var e := int(mp.trace.call("errors_in", "mp_belt_draw.gd"))
		errs = e - _err_seen
		_err_seen = e
	_hm_now[6] += errs
	var missed := (_runs_started - _runs_done) - _missed_seen
	_missed_seen += missed
	if missed > 0:
		_hm_now[6] += missed
	for i in 7:
		hm_total[i] += int(_hm_now[i])
	_hm_ring.append(_hm_now)
	_hm_now = [0, 0, 0, 0, 0, 0, 0]
	if _hm_ring.size() > 5:
		_hm_ring.pop_front()
	if fault != "" or not _on:
		return
	var t := [0, 0, 0, 0, 0, 0, 0]
	for e in _hm_ring:
		for i in 7:
			t[i] += int(e[i])
	var w := ""
	if t[6] >= HM_ERRORS:
		w = "%d script errors in the smooth drawing in 5 s (frames that did not finish)" % t[6]
	elif probation and now <= _probation_end:
		if t[4] >= HM_LAYOUT:
			w = "belt data looks different (%d checks in 5 s)" % t[4]
		elif t[0] >= HM_JUMPS_MIN and t[0] > t[1] * HM_JUMP_RATIO + HM_JUMP_SLACK:
			w = "smooth drawing jumps more than normal drawing (%d vs %d in 5 s)" % [t[0], t[1]]
		elif t[2] >= HM_BACK_MIN and t[2] > t[3] * HM_BACK_RATIO + HM_BACK_SLACK:
			w = "smooth drawing draws rows back (%d vs %d in 5 s)" % [t[2], t[3]]
	if w != "":
		_fault(w)
		return
	if probation and now > _probation_end and not _passed:
		_passed = true
		event("belt smooth probation passed: %d min without a problem (game build %s)" % [PROBATION_MS / 60000, game_build])


func _fault(w: String) -> void:
	fault = w
	_clear()
	_set_state("off_problem", "problem found: " + w)
	event("belt smooth off: problem found - %s, game build %s (normal drawing again)" % [w, game_build])


func health_stats() -> Dictionary:
	var t := [0, 0, 0, 0, 0, 0, 0]
	for e in _hm_ring:
		for i in 7:
			t[i] += int(e[i])
	return {"state": state, "why": why, "probation": probation, "left_s": maxi(0, (_probation_end - Time.get_ticks_msec()) / 1000) if probation else 0,
		"smooth_jumps_5s": t[0], "game_jumps_5s": t[1], "smooth_back_5s": t[2], "game_back_5s": t[3],
		"layout_5s": t[4], "errors_5s": t[6], "fault": fault, "watched": _watch_set.size(), "belts": _entries.size(),
		"drawer": drawer, "core": core_version, "build": game_build, "core_skip": core_skip, "updates": updates,
		"overrides": overrides, "total": hm_total, "cost_us": cost_stats()}


# our cost per frame while on (µs): p50, p99, max over the last COST_N frames
func cost_stats() -> Dictionary:
	var n := mini(_cost_i, COST_N)
	if n == 0:
		return {"n": 0}
	var a: Array = Array(_cost.slice(0, n))
	a.sort()
	return {"n": n, "p50": a[n / 2], "p99": a[mini(n - 1, int(n * 0.99))], "max": a[n - 1]}


# ------------------------------------------------------------------ panel and logs

# the state the panel shows: active, watch (probation), update, problem, nocore, off, wait
func panel_state() -> String:
	if mp == null or mp.get("belt_smooth") != true:
		return "off"
	var rs: Array = _replay_state()
	if state == "off_problem" or str(rs[0]) == "problem":
		return "problem"
	if state == "off_update":
		return "update"
	if state == "wait":
		return "wait"
	if probation or str(rs[0]) == "probation":
		return "watch"
	return "active"


# belt replay's state on this PC: [on / probation / host / off / problem / wait, why]
func _replay_state() -> Array:
	var bs: Variant = mp.world_sync.get("belts_sync") if mp != null and mp.world_sync != null and is_instance_valid(mp.world_sync) else null
	if bs != null and is_instance_valid(bs) and bs.has_method("replay_state"):
		var r: Variant = bs.call("replay_state")
		if r is Array and (r as Array).size() == 2:
			return r
	return ["off", "no session"]


func smooth_text() -> String:
	if state == "active" or state == "probation":
		if state == "probation":
			return "probation (%d s left)" % maxi(0, (_probation_end - Time.get_ticks_msec()) / 1000)
		return "active" + (" (probation passed)" if _passed else "")
	return "%s: %s" % [state, why]


# the "== belts" part of the log's report.txt (our own text: names are not looked for in it)
func report_lines() -> PackedStringArray:
	var s := PackedStringArray()
	s.append("smooth drawing: script, %s drawer, %d belts near" % [drawer if drawer != "" else "?", _entries.size()])
	s.append("native belt core: %s" % (core_version if core_version != "" else ("none" + ((" (installer: %s)" % core_skip) if core_skip != "" else ""))))
	s.append("game build: %s (smooth drawing tested on %s)" % [game_build if game_build != "" else "?", ", ".join(SMOOTH_BUILDS)])
	s.append("smooth: %s" % smooth_text())
	var rs: Array = _replay_state()
	s.append("replay: %s%s" % [rs[0], (": " + str(rs[1])) if str(rs[1]) != "" else ""])
	s.append("panel: %s" % panel_state())
	s.append("events:")
	for e in events:
		s.append("  " + str(e))
	s.append("per minute:")
	for m in minutes:
		s.append("  " + str(m))
	return s


# one line a minute while in a world: what the belts did
func _minute(now: int) -> void:
	if now - _minute_at < MINUTE_MS:
		return
	_minute_at = now
	if mp == null or not is_instance_valid(mp) or not mp.has_method("in_world") or not bool(mp.call("in_world")):
		return
	var line := minute_line()
	minutes.append("%d s %s" % [(now - _started) / 1000, line])
	if minutes.size() > MAX_MINUTES:
		minutes.pop_front()
	if mp.trace != null and mp.trace.has_method("note"):
		mp.trace.note(line)


func _delta(key: String, total: int) -> int:
	var d := total - int(_minute_base.get(key, 0))
	_minute_base[key] = total
	return d


func minute_line() -> String:
	var cs := cost_stats()
	var s := "belt min smooth=%s steps=%d drawn=%d cost_us=%d/%d" % [state, _delta("rooms", updates), _delta("over", overrides),
		int(cs.get("p50", 0)), int(cs.get("p99", 0))]
	if probation:
		s += " watch=%d/%d back=%d/%d" % [_delta("sj", int(hm_total[0])), _delta("gj", int(hm_total[1])),
			_delta("sb", int(hm_total[2])), _delta("gb", int(hm_total[3]))]
	var rs: Array = _replay_state()
	s += " replay=%s" % rs[0]
	var bs: Variant = mp.world_sync.get("belts_sync") if mp.world_sync != null and is_instance_valid(mp.world_sync) else null
	if bs == null or not is_instance_valid(bs) or not bs.has_method("replay_stats"):
		return s
	var st: Dictionary = bs.call("replay_stats")
	if mp.get("is_host") == true:
		s += " guests=%d stream_kbs=%.1f words=%d" % [int(st.get("peers", 0)),
			float(_delta("bytes", int(st.get("st_bytes", 0)))) / 1024.0 / (MINUTE_MS / 1000.0), _delta("st_words", int(st.get("st_words", 0)))]
	elif bool(st.get("on", false)):
		var hm: Variant = bs.get("hm_total")
		var lost := 0
		var miss := 0
		var want := 0
		var ins_fail := 0
		var nostat := 0
		if hm is Array and (hm as Array).size() >= 5:
			lost = _delta("lost", int(hm[0]))
			ins_fail = _delta("insfail", int(hm[1]))
			miss = _delta("miss", int(hm[2]))
			want = _delta("want", int(hm[3]))
			nostat = _delta("nostat", int(hm[4]))
		s += " buf=%d late95=%d eased=%d snapped=%d blinks=%d lost=%d missing=%d/%d insert_fail=%d nostat=%d words=%d" % [
			roundi(float(st.get("buffer_ms", 0.0))), roundi(float(st.get("late_p95_ms", 0.0))),
			_delta("eased", int(st.get("eased", 0))), _delta("snapped", int(st.get("snapped", 0))),
			_delta("blinks", int(bs.get("sw_blinks") if bs.get("sw_blinks") != null else 0)), lost, miss, want, ins_fail, nostat,
			_delta("words", int(st.get("words", 0)))]
	return s
