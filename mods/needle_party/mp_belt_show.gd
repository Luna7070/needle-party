extends Node

# The guest's own drawing of the host's belt rows ("script replay" drawer, 2026-11-15, test).
#
# Without our native belt core the guest's own belt core keeps stepping its belts, so the rows the
# player sees come from the row table (mp_belt_replay.gd, filled by mp_belts from the host's step
# words). Here they are drawn:
#   - every belt of the table that is fed (a host word came) and whose shape is read, within R_IN of
#     the player (x/z), is taken out of the game's belt drawer (the batch class's unwatch, which
#     covers both of the game's drawers) and given back (watch) beyond R_OUT, when it is no longer
#     fed, on set_active(false) and when the mod exits. Every CHECK_MS the hidden runs are checked
#     again: a rebuild can give a run back to the game's drawer, it is taken out again.
#   - our own MultiMeshes, one per item kind, level of detail, shadow on/off and mesh part, with the
#     game's own meshes and materials asked from its drawer at runtime (nothing of the game's is
#     kept in the mod). Every row has a fixed slot (same slot in all parts of its group). Per frame
#     only the belts in the camera's view are worked on, a belt whose rows all stand and did not
#     change is skipped, a straight belt's row writes only its 3 origin numbers per part (the basis
#     is written when the row is seated), and each changed part is sent once (multimesh_set_buffer).
#   - level of detail and shadow per belt by its distance to the camera, as the game's drawer does.
#   - dev_mirror(): the same hide and draw path fed from this PC's own belt core (the rows as the
#     game's drawer places them), to compare our drawing with the game's on a solo host.
# Game classes are found by name at runtime and every method is checked first (the demo build
# lacks some): something missing sets `fault` (one short reason), everything is given back and
# nothing is drawn. Script errors in our frame (frames begun but not finished) do the same.
#
# The frame's data (2026-11-15, second pass, for the cost): every hidden belt has an index (bi) and
# every row of ours an id (ri); what the frame loop reads lives in flat arrays of this node indexed
# by them (the belt's flags, step clock, shape, row list; the row's spot numbers, last s, segment,
# group and slot), so the loop reads no fields of other objects and does no Dictionary lookups.
# A belt's rows are taken from the table only when the table changed it (its Rec.ver when there is
# one, else the old check of list, clock and spots); a belt whose rows stand costs one read a frame.
# The list of belts in view is made again only when the camera moved or turned more than VIS_PAD
# covers (it is made with that much more room). Headless (no game drawer at all): groups without
# meshes, so the rows are still worked out and drawn_rows() has every hidden belt's rows.

const R_IN := 40.0
const R_OUT := 45.0
const CHECK_MS := 500
const VIEW_SLACK := 6.0       # m: a belt this far outside the view still counts (the view turns)
const VIS_PAD := 2.0          # m: more room in the view list; it is kept while the camera moved less than this covers
const VIS_MOVE := 0.25        # m of camera move (the rest of VIS_PAD is for turning)
const COST_N := 600
const ERR_MAX := 3            # our frames that did not finish before it is a fault
const INITIAL := 64
const EPS := 0.000001
const BATCH_API := ["watch", "unwatch", "pool_wanted"]
const MIRROR_API := ["first", "count", "seq_of", "row_group", "rel_of", "s_of", "speed_of", "row_room",
	"draw_into", "lead_seconds", "record"]
# per belt flags (_bfl)
const F_STILL := 1            # rows stand and are written: nothing to do until the rec changes
const F_SEEN := 2             # in view in the last drawn frame
const F_STRAIGHT := 4
const F_DOWN := 8             # has a next belt (rows past the end go on its path)
const F_FAST := 16            # the rec's spot arrays matched its rows when taken (s worked out here)
const F_TAKE := 32            # take the rec's rows at the next frame it is in view
const F_FAR := 64             # FAR_M or more from the camera: worked on every other frame
const NEAR_M := 13.0          # m (x/z) from the player: belts this near are worked on every frame, in view or
                              # not (their shadows; the metrics' zone r_pos 10 m around a spot 3.5 m away)
const FAR_M := 30.0           # m from the camera: a row's step of two frames there is far below a pixel
const F_MID := 128            # MID_M or more from the camera
const MID_M := 16.0           # ... worked on every other frame only at MID_DT (180 fps and more), and its
                              # table changes may wait a frame or two in a burst (TAKE_BUDGET)
const MID_DT := 0.0056
const TAKE_BUDGET := 24       # takes a frame of belts MID_M+ away (nearer ones always at once)
const TAKE_URGENT_MS := 8.0   # ... unless their rows' carry ends this soon (a word extends it)
const F_CHG := 256            # the table changed its rec since our take (changed_take; stays set while the take waits)


# One item kind at one level of detail, shadow on or off: one MultiMesh per mesh part, a row has
# the same slot in each. The numbers live in our _buf (one region per part, `off`).
class Group:
	var gi := 0                  # index in _order (and in the flat group arrays)
	var key := 0
	var kind := 0
	var lvl := 0
	var sh := false
	var parts: Array = []        # [{mesh, local (part local, no rest/scale), shape: bool}]
	var np := 0
	var mms: Array[MultiMesh] = []
	var nodes: Array[MultiMeshInstance3D] = []
	var off := PackedInt32Array()
	var cap := 0
	var n := 0
	var shown := -1
	var owner := PackedInt32Array()   # slot -> row id


# A hidden belt: what the slow paths (check round, row list changes, mirror) need. The frame loop
# reads the flat arrays at `bi`.
class Belt:
	var bi := -1
	var pid := 0
	var path: Node = null
	var run: Object = null       # the run we took out of the game's drawer
	var rec: Object = null
	var was_watched := false     # the game drew it when we took it (we give it back only then)
	var lvls := {}               # kind -> level of detail
	var sh := false
	var d := 0.0                 # distance to the camera (the game's measure)
	var in_cell := false
	var cell := Vector2i.ZERO
	var geo: Variant = null      # rec.geo_at when its shape was copied here (null: copy)
	var kver := 0                # rec.ver when its kinds were last checked (kok)
	var kok := false
	var mid := Vector3.ZERO
	var rad := 0.0
	var line := PackedVector3Array()
	var ja := Vector3.ZERO       # the line's first point and first-to-last (level of detail distance)
	var jab := Vector3.ZERO
	var straight := true
	var basis0 := Basis()
	var seq_last := PackedInt32Array()
	var trs := PackedInt32Array()   # row ids in transit past the end (rec.tr)
	# the old change check (a table without Rec.ver): clock and a copy of the spots when taken
	var t0 := NAN
	var until := NAN
	var et := NAN
	var s0_snap := PackedFloat32Array()
	# mirror: the rows its fill put in the rec
	var direct := false
	var same := false
	var seq_now := PackedInt32Array()
	var s0a := PackedFloat32Array()
	var va := PackedFloat32Array()
	var rma := PackedFloat32Array()
	var e0a := PackedFloat32Array()


# The hidden belts in 16 m cells (x/z): the view test per cell first, per belt only on a cell's edge.
class Cell:
	var key := Vector2i.ZERO
	var mid := Vector3.ZERO
	var rad := 0.0
	var lo := Vector3.ZERO       # box of its belts with room for what is on them (our MultiMeshes' bounds)
	var hi := Vector3.ZERO
	var seen := true
	var dirty := true
	var bis := PackedInt32Array()


var mp: Node
var active := false
var fault := ""
var table: Node = null
var bs: Node = null
var mirror := false

var _batch: Variant = null       # game classes (scripts), found by name
var _pool: Variant = null
var _shadow: Variant = null
var _path_cls: Variant = null
var _cfg: Node = null
var _size_gain := 0.0
var _hold := 1.0
var _cargo_r := 0.45
var _far_cut := 0.6
var _ease_ms := 80.0
var _r_in := R_IN
var _r_out := R_OUT
var _headless := false

var _belts := {}                 # path instance id -> Belt (hidden)
var _groups := {}                # group key -> Group
var _order: Array[Group] = []
var _kd_why := {}                # kind -> why its picture is not there (its belts stay with the game's drawer)
var _kd_at := {}
var _active_at := 0
var _drawn_ok := false           # at least one kind could be drawn
var _kds := {}                   # kind -> [levels, cuts, base_scale, exact_cuts, rest, shadow_part, by_strands]
var _locs := {}                  # group key * 4096 + strands -> Array[Transform3D]
var _scales := {}
var _buf := PackedFloat32Array()
var _host: Object = null
var _check_at := -100000
const CHECK_BUDGET_US := 40       # our check round's time a frame at most (the rest the next frames)
var _scan: Array = []
var _scanv: Array = []
var _scan_i := -1
var _scan_recs: Dictionary = {}
var _p0 := Vector3.ZERO
var _round := 0
var _gate := 0.0                 # the shadow distance, read once a check round
var _wd_b: Variant = null        # the game drawers' run lists, read once a check round
var _wd_p: Variant = null
var _ver_known := false
var _has_ver := false            # the table's Rec has `ver` (bumped on any change of its rows)
var _has_geo := false            # ... and `geo_at` (when its shape was read)

# per belt, by bi
var _bcap := 0
var _bn := 0
var _bfree := PackedInt32Array()
var _nbfree := 0
var _bobj: Array[Belt] = []
var _brec: Array = []
var _bfl := PackedInt32Array()
var _bver := PackedInt64Array()
var _bmark := PackedInt32Array()
var _bmid := PackedVector3Array()
var _brad := PackedFloat64Array()
var _bt0 := PackedFloat64Array()
var _buntil := PackedFloat64Array()
var _bet := PackedFloat64Array()
var _blen := PackedFloat64Array()
var _bl0 := PackedVector3Array()
var _bbz := PackedVector3Array()
var _bb0: Array = []             # basis at the start (read only when a row's basis is written)
var _bline: Array = []           # bent belts: line, cum, segment bases
var _bcum: Array = []
var _bbases: Array = []
var _brids: Array = []           # PackedInt32Array of row ids, front first (as rec.seq)
var _bnr := PackedInt32Array()   # rows (list + transit)
var _btrn := PackedInt32Array()  # the rec's transit rows when taken
var _bntr := PackedInt32Array()  # our transit rows

# per row, by ri
var _rcap := 0
var _rn := 0
var _rfree := PackedInt32Array()
var _nrfree := 0
var _rseq := PackedInt32Array()
var _rkind := PackedInt32Array()
var _rstr := PackedInt32Array()
var _rside := PackedFloat32Array()
var _rlift := PackedFloat32Array()
var _rg := PackedInt32Array()    # group index or -1 (not seated)
var _rslot := PackedInt32Array()
var _rs := PackedFloat64Array()  # the s last written (NAN: write it)
var _rk := PackedInt32Array()    # segment of the basis written (straight: 0); -1 none, -2 full write
var _bs0: Array = []             # per belt: the rec's spot arrays as taken (shared, not copied: the table lets
var _bva: Array = []             # go of an array before it writes one in place, so ours keep the numbers taken)
var _brma: Array = []
var _be0a: Array = []
var _ro := PackedVector3Array()  # stride _mp: per part the origin part that does not change with s
var _rlocs: Array = []           # per part of its group: rest x scale x part local

# per group, by gi
var _mp := 4                     # stride of the per part arrays (most parts of any group)
var _gdirty := PackedByteArray()
var _gnp := PackedInt32Array()
var _goff := PackedInt32Array()  # stride _mp: buffer offset of each part

# view
var _cells: Array[Cell] = []
var _cellmap := {}               # Vector2i -> Cell
const CELL_M := 16.0
var _vis := PackedInt32Array()   # belts in view (bi), _nvis of them
var _nvis := 0
var _vis_ok := false
var _vis_cam := false
var _vis_xf := Transform3D()
var _vis_fov := -1.0
var _vis_size := Vector2.ZERO
var _vis_turn := 0.0             # basis change that VIS_PAD still covers (from the farthest belt)
var _planes: Array[Plane] = []
var _eye := Vector3.ZERO
var _range_m := 0.0
var _box := AABB()

var _mtab: Node = null           # mirror: a private row table of this PC's own core rows
var _mst := PackedFloat64Array()
var _mrec := {}                  # mirror: path id -> {seq: [kind, strands, side, lift]}
var _cost := PackedInt32Array()
var _cost_i := 0
var _mcost := PackedInt32Array()
var _split: Array[Vector3i] = []   # per frame: us in the check round, in the frame loop, in the uploads (dev)
const PF_N := 7
var _pf := PackedInt32Array()      # per frame (dev): takes, belts worked on, rows written, full poses, us in takes, belts visited
var _c_take := 0
var _c_rows := 0
var _c_full := 0
var _c_tus := 0
var _c_vis := 0
var _runs_started := 0
var _runs_done := 0
var fast_s := true               # rows' s worked out here (false: the table's _row_s per row)
var rewatched := 0               # hidden runs the game took back (and we took out again)
var rows_drawn := 0
var rows_written := 0
var belts_drawn := 0
var takes := 0                   # belts whose rows were taken from the table again (count)
var frame_us := 0                # when this frame's rows were worked out (ticks us; the metrics stamp drawn rows with it)
var frame_now := 0.0             # ... and for which display ms (the table's clock)
var _fpar := 0                   # frame parity: which half of the far belts is worked on
var _dt := 1.0                   # this frame's delta (s)
var _par_last := -1              # the parity of far belts skipped in the last frame (-1 none)
var _tier_last := 0              # ... and which (F_FAR, F_MID)
var _c_defer := 0                # dev: table changes left for a later frame (budget) this frame
const FAR_DT := 0.0105           # far belts at half rate only while frames are shorter (about 95 fps and more)
var use_chg := true              # the frame loop from the table's changed_take() (false: ver read on every belt in view)
var _has_chg := false            # the table has changed_take()
var _chg_on := false             # changed_take() is what the frame loop works from (F_CHG flags are up to date)
var _act := PackedInt32Array()   # belts in view to visit this frame (moving, F_TAKE or F_CHG), _nact of them
var _nact := 0
var _bact := PackedByteArray()   # per belt: in _act
var _act_ok := false             # _act made from _vis since it last changed


func _ready() -> void:
	process_priority = 1001   # after the game's belt drawers (100) and mp_belt_draw.gd (1000)
	_cost.resize(COST_N)
	_mcost.resize(COST_N)
	_split.resize(COST_N)
	_pf.resize(COST_N * PF_N)
	_mst.resize(10)
	_headless = DisplayServer.get_name() == "headless"


func _exit_tree() -> void:
	_release_all()


# ------------------------------------------------------------------ interface

func set_active(on: bool, tab: Node) -> void:
	if not on:
		_release_all()
		return
	if fault != "":
		return
	if active and tab == table:
		return
	_release_all()
	var why := _resolve()
	if why != "":
		_set_fault(why)
		_release_all()
		return
	table = tab
	bs = tab.get("bs") if tab != null else null
	_has_chg = tab != null and tab.has_method("changed_take")
	_chg_on = false
	_act_ok = false
	var em: Variant = tab.get("EASE_MS") if tab != null else null
	_ease_ms = float(em) if em is float or em is int else 80.0
	mirror = false
	_r_in = R_IN
	_r_out = R_OUT
	active = tab != null
	_active_at = Time.get_ticks_msec()
	_runs_started = 0
	_runs_done = 0


func is_hidden(path: Node) -> bool:
	return active and path != null and _belts.has(path.get_instance_id())


# For the metrics: our rows as drawn this frame [[belt key, seq, kind, world spot, s], ...]. A belt out of
# the camera's view (not in our list; never one within NEAR_M of the player) is not worked on: its
# rows are the table's at this frame's display ms (frame_now), which is where they are drawn the
# frame it comes into view (taken and worked out before it is drawn); those entries end in "u".
func drawn_rows(center: Vector3, radius: float) -> Array:
	var out: Array = []
	var c2 := Vector2(center.x, center.z)
	for bi in _bn:
		var b: Belt = _bobj[bi]
		if b == null or b.rec == null:
			continue
		var r: Variant = b.rec
		var key := String(r.get("key"))
		if (_bfl[bi] & F_SEEN) == 0:
			if mirror or table == null or not is_instance_valid(table):
				continue
			var seq: PackedInt32Array = r.seq
			var kinds: PackedInt32Array = r.kind
			for i in seq.size():
				var su := float(table._row_s(r, i, frame_now))
				var au := _spot(r, su, 0.0, 0.0)
				if Vector2(au.x, au.z).distance_to(c2) <= radius:
					out.append([key, seq[i], kinds[i], au, su, "u"])
			for e in r.tr:
				var su2 := float(table._tr_s(e, frame_now))
				var au2 := _spot(r, su2, 0.0, 0.0)
				if Vector2(au2.x, au2.z).distance_to(c2) <= radius:
					out.append([key, int(e[0]), int(e[1]), au2, su2, "u"])
			continue
		for ri in _brids[bi]:
			if _rg[ri] < 0 or is_nan(_rs[ri]):
				continue
			var at := _spot(r, _rs[ri], 0.0, 0.0)
			if Vector2(at.x, at.z).distance_to(c2) <= radius:
				out.append([key, _rseq[ri], _rkind[ri], at, _rs[ri]])
		for ri in b.trs:
			if _rg[ri] < 0 or is_nan(_rs[ri]):
				continue
			var at2 := _spot(r, _rs[ri], 0.0, 0.0)
			if Vector2(at2.x, at2.z).distance_to(c2) <= radius:
				out.append([key, _rseq[ri], _rkind[ri], at2, _rs[ri]])
	return out


func stats() -> Dictionary:
	var c := _cost.slice(0, mini(_cost_i, COST_N))
	c.sort()
	var m := _mcost.slice(0, mini(_cost_i, COST_N))
	m.sort()
	var slots := 0
	for g in _order:
		slots += g.n
	var nd := 0
	var nf := 0
	for j in _nvis:
		nd += _bnr[_vis[j]]
		if (_bfl[_vis[j]] & F_FAR) != 0:
			nf += 1
	rows_drawn = nd
	belts_drawn = _nvis
	return {"active": active, "mirror": mirror, "fault": fault, "belts_hidden": _belts.size(),
		"belts_drawn": belts_drawn, "rows_drawn": rows_drawn, "rows_written": rows_written, "slots": slots,
		"groups": _order.size(), "rewatched": rewatched, "bad_kinds": _kd_why.duplicate(), "frames": _cost_i,
		"drawer": ("pool" if bool(_batch.call("pool_wanted")) else "batch") if _batch != null else "",
		"headless": _headless, "has_ver": _has_ver, "takes": takes, "belts_far": nf, "chg_on": _chg_on, "belts_act": _nact,
		"ms_p50": _pct(c, 0.5), "ms_p99": _pct(c, 0.99), "ms_max": _pct(c, 1.0),
		"mirror_src_ms_p50": _pct(m, 0.5), "mirror_src_ms_p99": _pct(m, 0.99)}


func _pct(c: PackedInt32Array, q: float) -> float:
	if c.is_empty():
		return 0.0
	return float(c[mini(c.size() - 1, int(c.size() * q))]) / 1000.0


# ------------------------------------------------------------------ the frame

func _process(_d: float) -> void:
	if fault != "" and (active or not _belts.is_empty()):
		_release_all()
		return
	if not active:
		return
	if not mirror and (table == null or not is_instance_valid(table)):
		_release_all()
		return
	if _runs_started - _runs_done >= ERR_MAX:
		_set_fault("frame errors")
		return
	var t0 := Time.get_ticks_usec()
	_runs_started += 1
	_dt = _d
	var now_ms := Time.get_ticks_msec()
	var msrc := _check(now_ms)
	if not active or fault != "":
		return
	var t1 := Time.get_ticks_usec()
	var sp := _frame_draw()
	_runs_done += 1
	var t2 := Time.get_ticks_usec()
	msrc += sp.x
	var us := t2 - t0 - msrc
	var k := _cost_i % COST_N
	_cost[k] = us
	_mcost[k] = msrc
	_split[k] = Vector3i(t1 - t0, t2 - t1 - sp.x - sp.y, sp.y)
	var kp := k * PF_N
	_pf[kp] = _c_take
	_pf[kp + 1] = _c_rows
	_pf[kp + 2] = rows_written
	_pf[kp + 3] = _c_full
	_pf[kp + 4] = _c_tus
	_pf[kp + 5] = _c_vis
	_pf[kp + 6] = _c_defer
	_cost_i += 1
	if mp != null and is_instance_valid(mp) and mp.has_method("perf"):
		mp.perf("belt_show", us)


# Which belts are ours (hide / give back), their level of detail and shadow; runs the game took back.
# One round every CHECK_MS, at most CHECK_BUDGET_US of it a frame (no hitch with hundreds of belts near).
# Returns the mirror source's time (us) spent here.
func _check(now_ms: int) -> int:
	var msrc := 0
	if _scan_i < 0:
		if now_ms - _check_at < CHECK_MS:
			return 0
		var me := _player()
		if me == null:
			return 0
		_check_at = now_ms
		_p0 = me.global_position
		if not _cam():
			_eye = _p0   # no camera (headless): distances (level of detail, F_FAR) from the player
		var rm := float(_cfg.call("machine_distance_metres")) if _cfg != null and _cfg.has_method("machine_distance_metres") else 0.0
		if rm != _range_m:
			_range_m = rm
			_vis_ok = false
		_round += 1
		_round_prep()
		var t0 := Time.get_ticks_usec()
		_scan_recs = _source_recs(_p0)
		if mirror:
			msrc += Time.get_ticks_usec() - t0
		_scan = _scan_recs.keys()
		_scanv = _scan_recs.values()
		_scan_i = 0
	var c2 := Vector2(_p0.x, _p0.z)
	var end := _scan.size()
	var tq := Time.get_ticks_usec()
	var done := 0
	while _scan_i < end:
		done += 1
		if done % 2 == 0 and Time.get_ticks_usec() - tq > CHECK_BUDGET_US:
			break
		var pid: Variant = _scan[_scan_i]
		var r: Variant = _scanv[_scan_i]
		_scan_i += 1
		if r == null:
			continue
		var b: Belt = _belts.get(pid)
		if b == null:
			# not ours: the distance first (most of the table is far)
			var mid0: Vector3 = r.mid
			if maxf(Vector2(mid0.x, mid0.z).distance_to(c2) - float(r.rad), 0.0) > _r_in:
				continue
			if not bool(r.fed) or not bool(r.ok):
				continue
			var path: Variant = r.path
			if path == null or not is_instance_valid(path):
				continue
			if not _can_draw(r):
				continue
			var run: Variant = (path as Node).get("run")
			if run == null or not is_instance_valid(run):
				continue
			b = _belt_new(pid, path, r)
			if _has_ver and not mirror:
				b.kver = int(r.ver)
				b.kok = true
			_hide(b, run)
			_bmark[b.bi] = _round
			continue
		if not bool(r.fed) or not bool(r.ok):
			continue
		var path2: Variant = r.path
		if path2 == null or not is_instance_valid(path2):
			continue
		if not is_same(r, b.rec):
			# another record for the same path: all from it again
			b.rec = r
			_brec[b.bi] = r
			b.geo = null
			b.kok = false
			_bfl[b.bi] |= F_TAKE
			_bfl[b.bi] &= ~F_STILL
			_wake(b.bi)
		_cull_data(b)
		if maxf(Vector2(b.mid.x, b.mid.z).distance_to(c2) - b.rad, 0.0) > _r_out:
			continue
		if _has_ver and not mirror:
			var v := int(r.ver)
			if not b.kok or v != b.kver:
				if not _can_draw(r):
					continue
				b.kver = v
				b.kok = true
		elif not _can_draw(r):
			continue
		var run2: Variant = b.path.get("run")
		if run2 != b.run:
			# the belt was built again: a new run (the old one is gone)
			_unseat_all(b)
			if run2 == null or not is_instance_valid(run2):
				continue
			_hide(b, run2)
		elif _watched_fast(run2):
			rewatched += 1
			_hide(b, run2)
		else:
			_judge(b)
		_bmark[b.bi] = _round
	if _scan_i < _scan.size():
		return msrc
	_scan_i = -1
	_scan = []
	_scanv = []
	_scan_recs = {}
	for bi in _bn:
		var b: Belt = _bobj[bi]
		if b != null and _bmark[bi] != _round:
			_show(b)
			_belts.erase(b.pid)
			_belt_free(b)
	_bounds()
	if not _drawn_ok and not _kd_why.is_empty() and Time.get_ticks_msec() - _active_at > 5000:
		var k0: Variant = _kd_why.keys()[0]
		_set_fault("no picture (kind %s: %s)" % [k0, _kd_why[k0]])
	return msrc


# what a check round reads once, not per belt
func _round_prep() -> void:
	var gv: Variant = _cfg.get("yard_shadow_distance") if _cfg != null else null
	_gate = float(gv) if gv is float or gv is int else 0.0
	_wd_b = null
	_wd_p = null
	var inst: Variant = _batch.get("instance") if _batch != null else null
	if inst != null and is_instance_valid(inst):
		var d: Variant = inst.get("_by_run")
		if d is Dictionary:
			_wd_b = d
	if _pool != null:
		var pi: Variant = _pool.get("instance")
		if pi != null and is_instance_valid(pi):
			var d2: Variant = pi.get("_by_run")
			if d2 is Dictionary:
				_wd_p = d2
	# the farthest point of a hidden belt from the player: how far the camera may turn before the
	# view list's VIS_PAD no longer covers it
	var far := _r_out + 30.0
	for c in _cells:
		if c.dirty:
			_cell_fix(c)
		far = maxf(far, Vector2(c.mid.x - _p0.x, c.mid.z - _p0.z).length() + c.rad + 10.0)
	_vis_turn = (VIS_PAD - VIS_MOVE) / far


# the rec's shape, copied here when it was read again (rec.geo_at; no geo_at: every round)
func _cull_data(b: Belt) -> void:
	var r: Variant = b.rec
	if _has_geo:
		var ga: Variant = r.geo_at
		if b.geo != null and ga == b.geo:
			return
		b.geo = ga
	var bi := b.bi
	var m: Vector3 = r.mid
	var rd := float(r.rad)
	var line: PackedVector3Array = r.line
	var straight := bool(r.straight)
	var b0: Basis = r.basis0
	var shape_new := line != b.line or straight != b.straight or b0 != b.basis0
	b.line = line
	b.straight = straight
	b.basis0 = b0
	b.ja = line[0] if line.size() > 0 else Vector3.ZERO
	b.jab = (line[line.size() - 1] - b.ja) if line.size() > 1 else Vector3.ZERO
	var fl := _bfl[bi]
	fl = (fl | F_STRAIGHT) if straight else (fl & ~F_STRAIGHT)
	fl = (fl | F_DOWN) if (int(r.down_id) != 0 and not mirror) else (fl & ~F_DOWN)
	_blen[bi] = float(r.length)
	_bl0[bi] = b.ja
	_bbz[bi] = b0.z
	_bb0[bi] = b0
	_bline[bi] = line
	_bcum[bi] = r.cum
	_bbases[bi] = r.bases
	if shape_new and _bnr[bi] > 0:
		# its rows' bases and spots again
		for ri in _brids[bi]:
			_rk[ri] = -1
			_rs[ri] = NAN
		fl &= ~F_STILL
	_bfl[bi] = fl
	_wake(bi)
	if m != b.mid or rd != b.rad or not b.in_cell:
		b.mid = m
		b.rad = rd
		_bmid[bi] = m
		_brad[bi] = rd
		_cell_move(b)


# every kind on the belt can be drawn by us (else the game's drawer keeps it)
func _can_draw(r: Variant) -> bool:
	var kinds: Variant = r.get("kind")
	if not (kinds is PackedInt32Array):
		return false
	var last := -1
	for k in kinds:
		if k == last or _kds.has(k):
			last = k
			continue
		if _kd(k).is_empty():
			return false
		last = k
	return true


# one box around every hidden belt (with room for what is on it) for our MultiMeshes
func _bounds() -> void:
	var first := true
	var lo := Vector3.ZERO
	var hi := Vector3.ZERO
	for c in _cells:
		if c.dirty:
			_cell_fix(c)
		if first:
			lo = c.lo
			hi = c.hi
			first = false
		else:
			lo = lo.min(c.lo)
			hi = hi.max(c.hi)
	if first:
		return
	var box := AABB(lo, hi - lo)
	if box.is_equal_approx(_box):
		return
	_box = box
	for g in _order:
		for mm in g.mms:
			mm.custom_aabb = box


func _hide(b: Belt, run: Object) -> void:
	b.was_watched = _watched(run) or b.was_watched
	b.run = run
	_batch.call("unwatch", run)
	_bfl[b.bi] &= ~F_STILL
	_wake(b.bi)
	if mp != null and mp.get("belt_draw") != null and mp.belt_draw.has_method("forget_path"):
		mp.belt_draw.forget_path(b.path)
	_judge(b)


func _show(b: Belt) -> void:
	_unseat_all(b)
	if b.run != null and is_instance_valid(b.run) and b.was_watched and is_instance_valid(b.path) \
			and b.path.is_inside_tree() and b.path.get("run") == b.run:
		_batch.call("watch", b.run)
	if mp != null and mp.get("belt_draw") != null and mp.belt_draw.has_method("forget_path") and is_instance_valid(b.path):
		mp.belt_draw.forget_path(b.path)


func _watched(run: Object) -> bool:
	var inst: Variant = _batch.get("instance")
	if inst != null and is_instance_valid(inst):
		var d: Variant = inst.get("_by_run")
		if d is Dictionary and (d as Dictionary).has(run):
			return true
	if _pool != null:
		var pi: Variant = _pool.get("instance")
		if pi != null and is_instance_valid(pi):
			var d2: Variant = pi.get("_by_run")
			if d2 is Dictionary and (d2 as Dictionary).has(run):
				return true
	return false


# the same with the run lists read at the round's start
func _watched_fast(run: Object) -> bool:
	if _wd_b != null and (_wd_b as Dictionary).has(run):
		return true
	return _wd_p != null and (_wd_p as Dictionary).has(run)


# level of detail per kind and shadow on/off by the distance from the camera to the belt's line
func _judge(b: Belt) -> void:
	if b.line.size() < 2:
		return
	var a := b.ja
	var ab := b.jab
	var l2 := ab.length_squared()
	var t := 0.0 if l2 < 1e-8 else clampf((_eye - a).dot(ab) / l2, 0.0, 1.0)
	b.d = _eye.distance_to(a + ab * t)
	var gate := _gate
	var reach := (gate + _cargo_r * _size_gain) * (_hold if b.sh else 1.0)
	var sh := gate > 0.0 and b.d <= reach
	var changed := sh != b.sh
	b.sh = sh
	for kind in b.lvls:
		var l := _lvl_for(int(kind), b.d)
		if l != int(b.lvls[kind]):
			b.lvls[kind] = l
			changed = true
	if changed:
		for ri in _brids[b.bi]:
			_seat(b, ri)
		for ri in b.trs:
			_seat(b, ri)
		_bfl[b.bi] &= ~F_STILL
		_bfl[b.bi] |= F_TAKE   # worked on the next frame even if far (the reseated rows are written then)
		_wake(b.bi)
	if b.d > FAR_M and not mirror:
		_bfl[b.bi] |= F_FAR
	else:
		_bfl[b.bi] &= ~F_FAR
	if b.d > MID_M and not mirror:
		_bfl[b.bi] |= F_MID
	else:
		_bfl[b.bi] &= ~F_MID


func _lvl_for(kind: int, d: float) -> int:
	var kd: Array = _kd(kind)
	if kd.is_empty():
		return 0
	var cuts: PackedFloat32Array = kd[1]
	var bsc: float = kd[2]
	var n := cuts.size()
	for i in n:
		var end := cuts[i] * bsc
		if i == n - 2 and end > 0.0 and not bool(kd[3]):
			end = maxf(end * _far_cut, cuts[i - 1] * bsc if i > 0 else 0.0)
		if end > 0.0 and d < end:
			return i
	return maxi(n - 1, 0)


# Returns Vector2i(the mirror source's time, the upload time) in us.
func _frame_draw() -> Vector2i:
	var cam_ok := _cam()
	var msrc := 0
	var now := 0.0
	var tab: Variant = _mtab if mirror else table
	if tab == null or not is_instance_valid(tab):
		return Vector2i.ZERO
	frame_us = Time.get_ticks_usec()
	if mirror:
		now = float(frame_us) / 1000.0
	elif bs != null and is_instance_valid(bs) and bs.has_method("_sw_disp"):
		now = float(bs.call("_sw_disp"))
	frame_now = now
	if not _vis_ok or cam_ok != _vis_cam:
		_vis_make(cam_ok)
	var nw := 0
	var has_ver := _has_ver and not mirror
	# far belts every other frame, only at a high frame rate (a two-frame step there stays below a pixel)
	# (and MID_M+ belts too at MID_DT)
	var par := _fpar if _dt < FAR_DT else -1
	var tier := F_FAR if _dt >= MID_DT else F_FAR | F_MID
	_par_last = par
	_tier_last = tier
	_fpar ^= 1
	var take0 := takes
	var budget := TAKE_BUDGET
	_c_rows = 0
	_c_full = 0
	_c_tus = 0
	_c_vis = _nvis
	_c_defer = 0
	var use := has_ver and use_chg and _has_chg
	if use != _chg_on:
		_chg_on = use
		_act_ok = false
		if use:
			_chg_intake(true)   # flags from every belt's ver once (changes while off were not listed)
	elif use:
		_chg_intake(false)
	if use:
		# only the belts in view that move, are to be taken or changed (still ones leave the list)
		if not _act_ok:
			_act_make()
		var wi := 0
		var j := 0
		while j < _nact:
			var bi := _act[j]
			j += 1
			var fl := _bfl[bi]
			var skip := (fl & F_TAKE) == 0 and (fl & tier) != 0 and (bi & 1) == par
			var draw := true
			if (fl & F_TAKE) != 0:
				fl = _take(bi, fl)
			elif (fl & F_CHG) != 0:
				# as the ver scan below: at once when near or its rows moved, else on budget / urgent
				if (fl & (F_MID | F_FAR)) == 0 or _rows_moved(bi):
					fl = _take(bi, fl)
				elif not skip and (budget > 0 or now + TAKE_URGENT_MS >= _buntil[bi]):
					budget -= 1
					fl = _take(bi, fl)
				else:
					_c_defer += 1
					draw = not skip and (fl & F_STILL) == 0
			else:
				draw = not skip and (fl & F_STILL) == 0
			if draw:
				nw += _rows(bi, fl, now, tab)
				_c_rows += 1
			if (_bfl[bi] & (F_STILL | F_TAKE | F_CHG)) == F_STILL:
				_bact[bi] = 0
			else:
				_act[wi] = bi
				wi += 1
		_c_vis = j
		_nact = wi
	else:
		for j in _nvis:
			var bi := _vis[j]
			var fl := _bfl[bi]
			# far (and at MID_DT mid) belts: their rows every other frame (half of them each frame)
			var skip := (fl & F_TAKE) == 0 and (fl & tier) != 0 and (bi & 1) == par
			if has_ver:
				if (fl & F_TAKE) != 0:
					fl = _take(bi, fl)
				elif int(_brec[bi].ver) != _bver[bi]:
					# the table changed it: at once when near or when its rows moved (a row is never on
					# two belts or on none), else when its rows' carry ends soon or within the frame's
					# budget, not on its skipped frames; else it waits (rows carried on as taken, a frame or two)
					if (fl & (F_MID | F_FAR)) == 0 or _rows_moved(bi):
						fl = _take(bi, fl)
					elif not skip and (budget > 0 or now + TAKE_URGENT_MS >= _buntil[bi]):
						budget -= 1
						fl = _take(bi, fl)
					else:
						_c_defer += 1
						if skip or (fl & F_STILL) != 0:
							continue
				elif skip or (fl & F_STILL) != 0:
					continue
			elif skip:
				continue
			elif mirror:
				var b: Belt = _bobj[bi]
				var ms0 := Time.get_ticks_usec()
				_mirror_fill(b, now)
				msrc += Time.get_ticks_usec() - ms0
				if b.same and (fl & F_TAKE) == 0:
					if (fl & F_STILL) != 0:
						continue   # mirror: rows as last frame and none can move
					_bt0[bi] = b.t0
					_buntil[bi] = b.until
					_bet[bi] = b.et
				else:
					fl = _take(bi, fl)
			elif (fl & F_TAKE) != 0:
				fl = _take(bi, fl)
			elif _changed_old(bi):
				fl = _take(bi, fl)
			elif (fl & F_STILL) != 0:
				continue
			nw += _rows(bi, fl, now, tab)
			_c_rows += 1
	_c_take = takes - take0
	var tu := Time.get_ticks_usec()
	for g in _order:
		if g.n != g.shown:
			for mm in g.mms:
				mm.visible_instance_count = g.n
			g.shown = g.n
		if _gdirty[g.gi] != 0:
			_gdirty[g.gi] = 0
			var span := g.cap * 12
			for p in g.np:
				RenderingServer.multimesh_set_buffer(g.mms[p].get_rid(), _buf.slice(g.off[p], g.off[p] + span))
	rows_written = nw
	return Vector2i(msrc, Time.get_ticks_usec() - tu)


# The belts in view (the frustum's side planes with VIEW_SLACK + VIS_PAD room), by cells; made
# again when the camera moved or turned more than VIS_PAD covers, or the hidden belts changed.
func _vis_make(cam_ok: bool) -> void:
	_vis_ok = true
	_act_ok = false
	_vis_cam = cam_ok
	var pa := Plane()
	var pb := Plane()
	var pc := Plane()
	var pd := Plane()
	if cam_ok:
		var vp := get_viewport()
		var cam := vp.get_camera_3d() if vp != null else null
		if cam == null:
			cam_ok = false
		else:
			_vis_xf = cam.global_transform
			_vis_fov = cam.fov
			_vis_size = vp.get_visible_rect().size
			var f := cam.get_frustum()
			_planes.clear()
			for i in range(2, f.size()):   # left, top, right, bottom (near and far add nothing here)
				_planes.append(f[i])
			cam_ok = _planes.size() == 4
	if cam_ok:
		pa = _planes[0]
		pb = _planes[1]
		pc = _planes[2]
		pd = _planes[3]
	var r_far := _range_m + RANGE_MARGIN_M if _range_m > 0.0 else INF
	var room := VIEW_SLACK + VIS_PAD
	# belts near the player are in the list in view or not (NEAR_M; the list is made again when the
	# camera, and with it the player, moved VIS_MOVE)
	var pn := Vector2(INF, INF)
	if cam_ok:
		var me := _player()
		if me != null:
			pn = Vector2(me.global_position.x, me.global_position.z)
	if _vis.size() < _bcap:
		_vis.resize(_bcap)
	_nvis = 0
	for c in _cells:
		if c.dirty:
			_cell_fix(c)
		var whole := true   # the whole cell in view: no test per belt
		if cam_ok:
			var cm := c.mid
			var cl := c.rad + room
			var da := pa.distance_to(cm)
			var db := pb.distance_to(cm)
			var dc := pc.distance_to(cm)
			var dd := pd.distance_to(cm)
			if da > cl or db > cl or dc > cl or dd > cl:
				# the whole cell out of view (and none of it near the player)
				if Vector2(cm.x, cm.z).distance_to(pn) - c.rad > NEAR_M:
					if c.seen:
						c.seen = false
						for bi in c.bis:
							_bfl[bi] &= ~F_SEEN
					continue
				whole = false
			else:
				whole = da < -c.rad and db < -c.rad and dc < -c.rad and dd < -c.rad
		c.seen = true
		for bi in c.bis:
			var mid := _bmid[bi]
			var rad := _brad[bi]
			var seen := true
			if not whole:
				var lim := rad + room
				if pa.distance_to(mid) > lim or pb.distance_to(mid) > lim or pc.distance_to(mid) > lim or pd.distance_to(mid) > lim:
					seen = Vector2(mid.x, mid.z).distance_to(pn) - rad <= NEAR_M
			if seen and r_far < INF and cam_ok and _eye.distance_to(mid) > r_far + 2.0 * rad:
				_out_of_range(bi)
				continue
			if not seen:
				_bfl[bi] &= ~F_SEEN
				continue
			if (_bfl[bi] & F_SEEN) == 0:
				_bfl[bi] |= F_SEEN | F_TAKE   # comes into view: worked on this frame (far or not)
			_vis[_nvis] = bi
			_nvis += 1


const RANGE_MARGIN_M := 4.0


# the game's drawer does not draw a belt beyond the machine distance (+ its size): it is in view, so
# its rows go out of our buffers (not only left as they were)
func _out_of_range(bi: int) -> void:
	if _bnr[bi] > 0:
		_unseat_all(_bobj[bi])
	_bfl[bi] &= ~F_SEEN


func _cell_move(b: Belt) -> void:
	if b.in_cell:
		_cell_rm(b)
	var k := Vector2i(floori(b.mid.x / CELL_M), floori(b.mid.z / CELL_M))
	var c: Cell = _cellmap.get(k)
	if c == null:
		c = Cell.new()
		c.key = k
		_cellmap[k] = c
		_cells.append(c)
	c.bis.append(b.bi)
	c.dirty = true
	b.cell = k
	b.in_cell = true
	_vis_ok = false


func _cell_rm(b: Belt) -> void:
	if not b.in_cell:
		return
	b.in_cell = false
	_vis_ok = false
	var c: Cell = _cellmap.get(b.cell)
	if c == null:
		return
	var i := c.bis.find(b.bi)
	if i >= 0:
		c.bis.remove_at(i)
	c.dirty = true
	if c.bis.is_empty():
		_cellmap.erase(b.cell)
		_cells.erase(c)


func _cell_fix(c: Cell) -> void:
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	var blo := lo
	var bhi := hi
	for bi in c.bis:
		var m := _bmid[bi]
		lo = lo.min(m)
		hi = hi.max(m)
		var rr := float(_brad[bi]) + 3.0
		var rv := Vector3(rr, rr, rr)
		blo = blo.min(m - rv)
		bhi = bhi.max(m + rv)
	c.mid = (lo + hi) * 0.5
	var r := 0.0
	for bi in c.bis:
		r = maxf(r, c.mid.distance_to(_bmid[bi]) + _brad[bi])
	c.rad = r
	c.lo = blo
	c.hi = bhi
	c.dirty = false


# a belt in view that may have work again (F_TAKE set or F_STILL cleared): into this frame's or the
# next frame's visit list (changed_take mode)
func _wake(bi: int) -> void:
	if not _chg_on or not _act_ok or (_bfl[bi] & F_SEEN) == 0 or bi >= _bact.size() or _bact[bi] != 0:
		return
	_bact[bi] = 1
	if _nact >= _act.size():
		_act.resize(maxi(64, _act.size() * 2))
	_act[_nact] = bi
	_nact += 1


# the visit list from the belts in view: the ones that move, are to be taken or changed
func _act_make() -> void:
	_act_ok = true
	if _bact.size() < _bcap:
		_bact.resize(_bcap)
	_bact.fill(0)
	if _act.size() < _nvis:
		_act.resize(maxi(_nvis, 64))
	_nact = 0
	for j in _nvis:
		var bi := _vis[j]
		if (_bfl[bi] & (F_STILL | F_TAKE | F_CHG)) != F_STILL:
			_bact[bi] = 1
			_act[_nact] = bi
			_nact += 1


# the table's changed records since the last frame: F_CHG on our belts with that rec (and a ver we did
# not take), into the visit list when in view. `all`: no list known yet, every belt's ver read once.
func _chg_intake(all: bool) -> void:
	var ch: Array = table.call("changed_take")
	if all:
		for bi in _bn:
			var r0: Variant = _brec[bi]
			if r0 != null and _bobj[bi] != null and int(r0.ver) != _bver[bi]:
				_bfl[bi] |= F_CHG
		return
	for r in ch:
		if r == null:
			continue
		var b: Belt = _belts.get(r.pid)
		if b == null or not is_same(b.rec, r):
			continue   # not ours, or another record for the path (the check round takes it all again)
		var bi := b.bi
		if (_bfl[bi] & F_CHG) != 0 or int(r.ver) == _bver[bi]:
			continue
		_bfl[bi] |= F_CHG
		_wake(bi)


# the rec's rows (its list or its transit list) are not the ones we have: such a change is never left
# for later (a row would be on two belts, or on none, for a frame)
func _rows_moved(bi: int) -> bool:
	var r: Variant = _brec[bi]
	var seq: PackedInt32Array = r.seq
	return seq != _bobj[bi].seq_last or (r.tr as Array).size() != _btrn[bi]


# a table without Rec.ver: its list, step clock, spots or transit rows changed since we took them
func _changed_old(bi: int) -> bool:
	var b: Belt = _bobj[bi]
	var r: Variant = _brec[bi]
	var trn := (r.tr as Array).size()
	if trn != _btrn[bi]:
		return true
	var seq: PackedInt32Array = r.seq
	if seq != b.seq_last:
		return true
	if float(r.t0) != b.t0:
		return true
	var s0r: PackedFloat32Array = r.s0
	return s0r != b.s0_snap


# The rec's rows into ours: the list (rows in the same order), the step clock, every row's spot numbers.
func _take(bi: int, fl: int) -> int:
	takes += 1
	var tk := Time.get_ticks_usec()
	var b: Belt = _bobj[bi]
	var r: Variant = _brec[bi]
	var seq: PackedInt32Array = r.seq
	if seq != b.seq_last:
		_sync_rows(b, r, seq)
	var t0: float = r.t0
	_bt0[bi] = t0
	_buntil[bi] = float(r.until)
	_bet[bi] = float(r.et)
	var s0a: PackedFloat32Array = r.s0
	var va: PackedFloat32Array = r.v
	var rma: PackedFloat32Array = r.room
	var e0a: PackedFloat32Array = r.e0
	var rids: PackedInt32Array = _brids[bi]
	var n := rids.size()
	fl &= ~(F_STILL | F_TAKE | F_FAST | F_CHG)
	if fast_s and s0a.size() == n and va.size() == n and rma.size() == n and e0a.size() == n:
		fl |= F_FAST
		_bs0[bi] = s0a
		_bva[bi] = va
		_brma[bi] = rma
		_be0a[bi] = e0a
	if mirror:
		_btrn[bi] = 0
	else:
		_btrn[bi] = (r.tr as Array).size()
		if _has_ver:
			_bver[bi] = int(r.ver)
		else:
			b.t0 = t0
			b.s0_snap = s0a.duplicate()   # a copy: the table can change its array in place
	_bfl[bi] = fl
	_c_tus += Time.get_ticks_usec() - tk
	return fl


# This belt's rows into our buffer (the rows' spots as taken, carried on to `now`); returns the rows written.
func _rows(bi: int, fl: int, now: float, tab: Variant) -> int:
	var rids: PackedInt32Array = _brids[bi]
	var n := rids.size()
	var t0 := _bt0[bi]
	var until := _buntil[bi]
	var et := _bet[bi]
	# the table's row spot (its _row_s / _drawn) worked out here per belt once, per row a few steps
	# (fast_s; dev_s_check compares it with the table's own answer)
	var lead := maxf((minf(now, until) - t0) * 0.001, 0.0)
	var ep := (now - et) / _ease_ms
	var ef := 0.0
	if ep < 1.0:
		ep = maxf(ep, 0.0)
		ef = 1.0 - ep * ep * (3.0 - 2.0 * ep)
	var fast := (fl & F_FAST) != 0
	var go_on := not fast   # the table's _row_s per row: not known which rows move, never still by rows
	# (always arrays: set when the belt is made and at every take; read only when fast)
	var s0a: PackedFloat32Array = _bs0[bi]
	var va: PackedFloat32Array = _bva[bi]
	var rma: PackedFloat32Array = _brma[bi]
	var e0a: PackedFloat32Array = _be0a[bi]
	var length := _blen[bi]
	var down := (fl & F_DOWN) != 0
	var w := 0
	if (fl & F_STRAIGHT) != 0:
		var bz := _bbz[bi]
		var l0 := _bl0[bi]
		for i in n:
			var ri := rids[i]
			var gi := _rg[ri]
			if gi < 0:
				continue
			var s: float
			if fast:
				s = s0a[i]
				var vi := va[i]
				if vi > 0.0:
					var go := vi * lead
					var rm := maxf(rma[i], 0.0)
					if go < rm:
						go_on = true   # this row still has room: it moves on next frame
						s += go
					else:
						s += rm
				if ef != 0.0:
					s += e0a[i] * ef
			else:
				s = tab._row_s(_brec[bi], i, now)
			if s == _rs[ri]:
				continue
			if s > length and down:
				_put_full(ri, tab._xf(_brec[bi], s, _rside[ri], _rlift[ri]))
				_rs[ri] = s
				_rk[ri] = -2
				w += 1
				continue
			if _rk[ri] != 0:
				_basis_straight(ri, _bb0[bi])
			_rs[ri] = s
			var base := l0 + bz * s
			var gb := gi * _mp
			var rb := ri * _mp
			var j := _rslot[ri] * 12
			for p in _gnp[gi]:
				var o := base + _ro[rb + p]
				var x := _goff[gb + p] + j
				_buf[x + 3] = o.x
				_buf[x + 7] = o.y
				_buf[x + 11] = o.z
			_gdirty[gi] = 1
			w += 1
	else:
		var line: PackedVector3Array = _bline[bi]
		var cum: PackedFloat64Array = _bcum[bi]
		var bases: Array = _bbases[bi]
		var last := line.size() - 2
		for i in n:
			var ri := rids[i]
			var gi := _rg[ri]
			if gi < 0:
				continue
			var s: float
			if fast:
				s = s0a[i]
				var vi := va[i]
				if vi > 0.0:
					var go := vi * lead
					var rm := maxf(rma[i], 0.0)
					if go < rm:
						go_on = true   # this row still has room: it moves on next frame
						s += go
					else:
						s += rm
				if ef != 0.0:
					s += e0a[i] * ef
			else:
				s = tab._row_s(_brec[bi], i, now)
			if s == _rs[ri]:
				continue
			if s > length and down:
				_put_full(ri, tab._xf(_brec[bi], s, _rside[ri], _rlift[ri]))
				_rs[ri] = s
				_rk[ri] = -2
				w += 1
				continue
			var k0 := _rk[ri]
			var k := k0 if k0 >= 0 else 0
			while k < last and s > cum[k + 1]:
				k += 1
			while k > 0 and s <= cum[k]:
				k -= 1
			if k != k0:
				_basis_straight(ri, bases[k])
				_rk[ri] = k
			_rs[ri] = s
			var span: float = cum[k + 1] - cum[k]
			var tt := 0.0 if span <= 1e-9 else (s - cum[k]) / span
			if k > 0:
				tt = maxf(tt, 0.0)
			if k < last:
				tt = minf(tt, 1.0)
			var base := line[k].lerp(line[k + 1], tt)
			var gb := gi * _mp
			var rb := ri * _mp
			var j := _rslot[ri] * 12
			for p in _gnp[gi]:
				var o := base + _ro[rb + p]
				var x := _goff[gb + p] + j
				_buf[x + 3] = o.x
				_buf[x + 7] = o.y
				_buf[x + 11] = o.z
			_gdirty[gi] = 1
			w += 1
	# rows in transit past the end (few): the table's pose (on the next belt's path)
	var trn := _btrn[bi]
	if trn > 0 or _bntr[bi] > 0:
		w += _transit_rows(_bobj[bi], tab, _brec[bi], now)
	# still: no row can move on (all at their room or not moving, no glide) or the step is over
	if trn == 0 and now >= et + _ease_ms and (now >= until or not go_on):
		_bfl[bi] |= F_STILL
	return w


func _transit_rows(b: Belt, tab: Variant, r: Variant, now: float) -> int:
	var tr: Array = r.tr
	var keep := PackedInt32Array()
	var w := 0
	for e in tr:
		if not (e is Array) or (e as Array).size() < 12:
			continue
		var q := int(e[0])
		var ri := -1
		for x in b.trs:
			if _rseq[x] == q:
				ri = x
				break
		if ri < 0:
			ri = _row_new(q, int(e[1]), int(e[2]), float(e[3]), float(e[4]))
			_seat(b, ri)
		keep.append(ri)
		var s: float = tab._tr_s(e, now)
		if s != _rs[ri] and _rg[ri] >= 0:
			_put_full(ri, tab._xf(r, s, _rside[ri], _rlift[ri]))
			_rs[ri] = s
			_rk[ri] = -2
			w += 1
	for x in b.trs:
		if not keep.has(x):
			_row_free(x)
	b.trs = keep
	_bntr[b.bi] = keep.size()
	_bnr[b.bi] = (_brids[b.bi] as PackedInt32Array).size() + keep.size()
	return w


# The rows of the rec changed (a word with other rows): ours again in the same order.
func _sync_rows(b: Belt, r: Variant, seq: PackedInt32Array) -> void:
	var kinds: PackedInt32Array = r.kind
	var strands: PackedInt32Array = r.strands
	var sides: PackedFloat32Array = r.side
	var lifts: PackedFloat32Array = r.lift
	var nn := seq.size()
	# most changes: rows gone at the front (onto the next belt) and/or new rows at the back, the rows
	# kept with the same fields: no lookup table
	var old := b.seq_last
	var rids0: PackedInt32Array = _brids[b.bi]
	var no := old.size()
	if no > 0 and nn > 0 and no == rids0.size() and kinds.size() == nn and strands.size() == nn \
			and sides.size() == nn and lifts.size() == nn:
		var k := old.find(seq[0])
		if k >= 0 and no - k <= nn:
			var m := no - k
			var same := true
			for i in m:
				var ri0 := rids0[k + i]
				if old[k + i] != seq[i] or _rkind[ri0] != kinds[i] or _rstr[ri0] != strands[i] \
						or _rside[ri0] != sides[i] or _rlift[ri0] != lifts[i]:
					same = false
					break
			if same:
				for i in k:
					_row_free(rids0[i])
				var keep := rids0.slice(k)
				keep.resize(nn)
				for i in range(m, nn):
					var rn := _row_new(seq[i], kinds[i], strands[i], sides[i], lifts[i])
					_seat(b, rn)
					keep[i] = rn
				_brids[b.bi] = keep
				_bnr[b.bi] = nn + _bntr[b.bi]
				b.seq_last = seq.duplicate()   # a copy: the table can change its array in place (shared, not copied)
				return
	var by := {}
	for ri in _brids[b.bi]:
		by[_rseq[ri]] = ri
	var out := PackedInt32Array()
	out.resize(seq.size())
	for i in seq.size():
		var q := seq[i]
		var e: Variant = by.get(q)
		var ri := -1
		if e != null:
			ri = int(e)
			by.erase(q)
			if _rkind[ri] != kinds[i] or _rstr[ri] != strands[i]:
				_unseat(ri)
				_rkind[ri] = kinds[i]
				_rstr[ri] = strands[i]
				_rside[ri] = sides[i]
				_rlift[ri] = lifts[i]
				_seat(b, ri)
			elif _rside[ri] != sides[i] or _rlift[ri] != lifts[i]:
				_rside[ri] = sides[i]
				_rlift[ri] = lifts[i]
				_rk[ri] = -1
				_rs[ri] = NAN
		else:
			ri = _row_new(q, kinds[i], strands[i], sides[i], lifts[i])
			_seat(b, ri)
		out[i] = ri
	for q in by:
		_row_free(int(by[q]))
	_brids[b.bi] = out
	_bnr[b.bi] = out.size() + _bntr[b.bi]
	b.seq_last = seq.duplicate()   # a copy: the table can change its array in place (shared, not copied)


func _unseat_all(b: Belt) -> void:
	var bi := b.bi
	for ri in _brids[bi]:
		_row_free(ri)
	for ri in b.trs:
		_row_free(ri)
	_brids[bi] = PackedInt32Array()
	b.trs = PackedInt32Array()
	b.seq_last = PackedInt32Array()
	_bnr[bi] = 0
	_bntr[bi] = 0
	_bfl[bi] = (_bfl[bi] & ~F_STILL) | F_TAKE
	_wake(bi)


# ------------------------------------------------------------------ belts and rows (flat arrays)

func _belt_new(pid: int, path: Node, r: Variant) -> Belt:
	if not _ver_known:
		_ver_known = true
		_has_ver = "ver" in r
		_has_geo = "geo_at" in r
	var bi := -1
	if _nbfree > 0:
		_nbfree -= 1
		bi = _bfree[_nbfree]
	else:
		if _bn >= _bcap:
			_belt_grow()
		bi = _bn
		_bn += 1
	var b := Belt.new()
	b.bi = bi
	b.pid = pid
	b.path = path
	b.rec = r
	_bobj[bi] = b
	_brec[bi] = r
	_bfl[bi] = F_TAKE
	_bver[bi] = 0
	_bmark[bi] = _round
	_brids[bi] = PackedInt32Array()
	_bnr[bi] = 0
	_btrn[bi] = 0
	_bntr[bi] = 0
	_bs0[bi] = PackedFloat32Array()
	_bva[bi] = PackedFloat32Array()
	_brma[bi] = PackedFloat32Array()
	_be0a[bi] = PackedFloat32Array()
	_belts[pid] = b
	_cull_data(b)
	return b


func _belt_free(b: Belt) -> void:
	var bi := b.bi
	_cell_rm(b)
	_act_ok = false   # not in the visit list any more
	_bobj[bi] = null
	_brec[bi] = null
	_bb0[bi] = null
	_bline[bi] = null
	_bcum[bi] = null
	_bbases[bi] = null
	_brids[bi] = PackedInt32Array()
	_bs0[bi] = PackedFloat32Array()
	_bva[bi] = PackedFloat32Array()
	_brma[bi] = PackedFloat32Array()
	_be0a[bi] = PackedFloat32Array()
	_bfl[bi] = 0
	_bnr[bi] = 0
	if _nbfree >= _bfree.size():
		_bfree.resize(maxi(64, _bfree.size() * 2))
	_bfree[_nbfree] = bi
	_nbfree += 1
	b.bi = -1


func _belt_grow() -> void:
	var cap := maxi(256, _bcap * 2)
	_bobj.resize(cap)
	_brec.resize(cap)
	_bfl.resize(cap)
	_bver.resize(cap)
	_bmark.resize(cap)
	_bmid.resize(cap)
	_brad.resize(cap)
	_bt0.resize(cap)
	_buntil.resize(cap)
	_bet.resize(cap)
	_blen.resize(cap)
	_bl0.resize(cap)
	_bbz.resize(cap)
	_bb0.resize(cap)
	_bline.resize(cap)
	_bcum.resize(cap)
	_bbases.resize(cap)
	_brids.resize(cap)
	_bnr.resize(cap)
	_btrn.resize(cap)
	_bntr.resize(cap)
	_bs0.resize(cap)
	_bva.resize(cap)
	_brma.resize(cap)
	_be0a.resize(cap)
	_vis.resize(cap)
	_bcap = cap


func _row_new(q: int, kind: int, strands: int, side: float, lift: float) -> int:
	var ri := -1
	if _nrfree > 0:
		_nrfree -= 1
		ri = _rfree[_nrfree]
	else:
		if _rn >= _rcap:
			_row_grow()
		ri = _rn
		_rn += 1
	_rseq[ri] = q
	_rkind[ri] = kind
	_rstr[ri] = strands
	_rside[ri] = side
	_rlift[ri] = lift
	_rg[ri] = -1
	_rslot[ri] = -1
	_rs[ri] = NAN
	_rk[ri] = -1
	_rlocs[ri] = null
	return ri


func _row_free(ri: int) -> void:
	_unseat(ri)
	_rlocs[ri] = null
	if _nrfree >= _rfree.size():
		_rfree.resize(maxi(256, _rfree.size() * 2))
	_rfree[_nrfree] = ri
	_nrfree += 1


func _row_grow() -> void:
	var cap := maxi(1024, _rcap * 2)
	_rseq.resize(cap)
	_rkind.resize(cap)
	_rstr.resize(cap)
	_rside.resize(cap)
	_rlift.resize(cap)
	_rg.resize(cap)
	_rslot.resize(cap)
	_rs.resize(cap)
	_rk.resize(cap)
	_ro.resize(cap * _mp)
	_rlocs.resize(cap)
	_rcap = cap


# more room per row and group for parts (a group with more mesh parts than any before; rare)
func _set_mp(np: int) -> void:
	if np <= _mp:
		return
	var nm := np
	var ro := PackedVector3Array()
	ro.resize(_rcap * nm)
	for ri in _rn:
		for p in _mp:
			ro[ri * nm + p] = _ro[ri * _mp + p]
	_ro = ro
	var go := PackedInt32Array()
	go.resize(_gnp.size() * nm)
	for gi in _gnp.size():
		for p in _mp:
			go[gi * nm + p] = _goff[gi * _mp + p]
	_goff = go
	_mp = nm


# ------------------------------------------------------------------ slots and poses

# the row into the group its kind, the belt's level of detail and shadow say (no change: nothing)
func _seat(b: Belt, ri: int) -> void:
	var kind := _rkind[ri]
	if not b.lvls.has(kind):
		b.lvls[kind] = _lvl_for(kind, b.d)
	var g := _group(kind, int(b.lvls[kind]), b.sh)
	var gi := g.gi if g != null else -1
	if gi == _rg[ri]:
		return
	_unseat(ri)
	if g == null:
		return
	if g.n >= g.cap:
		_grow(g)
	var slot := g.n
	_rg[ri] = gi
	_rslot[ri] = slot
	g.owner[slot] = ri
	g.n += 1
	var strands := _rstr[ri]
	var lk := g.key * 4096 + (strands if strands >= 0 and strands < 4096 else 0)
	var locs: Variant = _locs.get(lk)
	if locs == null:
		locs = _locals_for(g, strands)
		_locs[lk] = locs
	_rlocs[ri] = locs
	var rb := ri * _mp
	var gb := gi * _mp
	for p in g.np:
		_ro[rb + p] = Vector3.ZERO
		# nothing drawn in the slot until the row is written (the slot can hold an old row's numbers)
		var x := _goff[gb + p] + slot * 12
		for c in 12:
			_buf[x + c] = 0.0
	_rk[ri] = -1
	_rs[ri] = NAN
	_gdirty[gi] = 1


func _unseat(ri: int) -> void:
	var gi := _rg[ri]
	if gi < 0:
		return
	var g: Group = _order[gi]
	var j := _rslot[ri]
	var last := g.n - 1
	if j != last:
		var mv := g.owner[last]
		for p in g.np:
			var a := g.off[p] + last * 12
			var z := g.off[p] + j * 12
			for c in 12:
				_buf[z + c] = _buf[a + c]
		g.owner[j] = mv
		_rslot[mv] = j
	g.owner[last] = -1
	g.n = last
	_gdirty[gi] = 1
	_rg[ri] = -1
	_rslot[ri] = -1
	_rs[ri] = NAN


func _basis_straight(ri: int, bb: Basis) -> void:
	var gi := _rg[ri]
	var lat := bb * Vector3(_rside[ri], _rlift[ri], 0.0)
	var j := _rslot[ri] * 12
	var rb := ri * _mp
	var gb := gi * _mp
	var locs: Array = _rlocs[ri]
	for p in _gnp[gi]:
		var loc: Transform3D = locs[p]
		_ro[rb + p] = lat + bb * loc.origin
		_put_basis(_goff[gb + p] + j, bb * loc.basis)
	_rk[ri] = 0


func _put_basis(x: int, m: Basis) -> void:
	_buf[x] = m.x.x
	_buf[x + 1] = m.y.x
	_buf[x + 2] = m.z.x
	_buf[x + 4] = m.x.y
	_buf[x + 5] = m.y.y
	_buf[x + 6] = m.z.y
	_buf[x + 8] = m.x.z
	_buf[x + 9] = m.y.z
	_buf[x + 10] = m.z.z


func _put_full(ri: int, xf: Transform3D) -> void:
	_c_full += 1
	var gi := _rg[ri]
	var j := _rslot[ri] * 12
	var gb := gi * _mp
	var locs: Array = _rlocs[ri]
	for p in _gnp[gi]:
		var t: Transform3D = xf * (locs[p] as Transform3D)
		var x := _goff[gb + p] + j
		_put_basis(x, t.basis)
		_buf[x + 3] = t.origin.x
		_buf[x + 7] = t.origin.y
		_buf[x + 11] = t.origin.z
	_gdirty[gi] = 1


# the row's spot on its own belt (side/lift applied, no rest/scale), as our fast path places it
func _spot(r: Variant, s: float, side: float, lift: float) -> Vector3:
	if not mirror and s > float(r.length) and int(r.down_id) != 0 and table != null:
		return (table._xf(r, s, side, lift) as Transform3D).origin
	var tab: Variant = _mtab if mirror else table
	return (tab._xf_on(r, s, side, lift) as Transform3D).origin


# ------------------------------------------------------------------ groups (game meshes)

# The game drawer's own picture of a kind (meshes with their materials, levels of detail, the
# shadow shape part), asked at runtime: [levels, cuts, base_scale, exact_cuts, rest, shadow_part, by_strands]
func _kd(kind: int) -> Array:
	var have: Variant = _kds.get(kind)
	if have != null:
		return have
	if _kd_why.has(kind) and Time.get_ticks_msec() - int(_kd_at.get(kind, 0)) < 2000:
		return []   # asked a moment ago without an answer: not every frame
	var out: Array = []
	var why := ""
	var host := _drawer_host()
	if host == null:
		why = "no drawer"
	elif not host.has_method("_kind_draw"):
		why = "no _kind_draw"
	else:
		var kd: Variant = host.call("_kind_draw", kind)
		var lv: Variant = kd.get("levels") if kd is Object else null
		var cuts := PackedFloat32Array()
		var cv: Variant = kd.get("cuts") if kd is Object else null
		if cv is PackedFloat32Array or cv is PackedFloat64Array or cv is Array:
			for x in cv:
				cuts.append(float(x))
		if not (kd is Object):
			why = "no kind draw"
		elif not (lv is Array) or (lv as Array).is_empty():
			why = "no levels"
		else:
			if cuts.is_empty():
				cuts.append(0.0)
			var rest: Variant = kd.get("rest")
			out = [lv, cuts, _num(kd.get("base_scale"), 1.0), _num(kd.get("exact_cuts"), 0.0) != 0.0,
				rest if rest is Basis else Basis.IDENTITY, int(_num(kd.get("shadow_part"), -1.0)),
				_num(kd.get("by_strands"), 0.0) != 0.0, kd]
	if out.is_empty():
		# only the plain picture (level 0) when the drawer's kind list is not there
		var parts: Variant = _batch.call("picture_of", kind, 50, true)
		if parts is Array and not (parts as Array).is_empty():
			var lvl0: Array = []
			var shape := -1
			for p in parts:
				if p is Dictionary:
					if bool(p.get("shadow", false)):
						shape = lvl0.size()
					lvl0.append({"mesh": p.get("mesh"), "local": p.get("local")})
			# picture_of's local has the rest and the scale for 50 strands in it already
			out = [[lvl0], PackedFloat32Array([0.0]), 1.0, true, Basis.IDENTITY, shape, false, null]
		elif _headless and host == null:
			# headless without any game drawer (nothing is drawn on this PC): a kind without meshes,
			# so the rows are still worked out (drawn_rows, the metrics) and nothing is left to a drawer
			out = [[[]], PackedFloat32Array([0.0]), 1.0, true, Basis.IDENTITY, -1, false, null]
		else:
			why += ", picture_of empty"
	if out.is_empty():
		_kd_why[kind] = why
		_kd_at[kind] = Time.get_ticks_msec()
		return out
	_kd_why.erase(kind)
	_kds[kind] = out
	return out


func _num(v: Variant, fallback: float) -> float:
	if v is float or v is int or v is bool:
		return float(v)
	return fallback


func _drawer_host() -> Object:
	if _host != null and is_instance_valid(_host):
		return _host
	var inst: Variant = _batch.get("instance")
	if inst != null and is_instance_valid(inst):
		_host = inst
	elif _pool != null:
		var pi: Variant = _pool.get("instance")
		if pi != null and is_instance_valid(pi):
			_host = pi
	return _host


func _group(kind: int, lvl: int, sh: bool) -> Group:
	var key := kind * 256 + lvl * 2 + (1 if sh else 0)
	var g: Group = _groups.get(key)
	if g != null:
		return g
	var kd := _kd(kind)
	if kd.is_empty():
		return null   # this kind cannot be drawn: belts carrying it go back to the game's drawer (_check)
	var levels: Array = kd[0]
	if lvl >= levels.size():
		lvl = levels.size() - 1
	var level: Array = levels[lvl] if lvl >= 0 else []
	var shape: int = kd[5]
	g = Group.new()
	g.key = key
	g.kind = kind
	g.lvl = lvl
	g.sh = sh
	for p in level.size():
		var part: Variant = level[p]
		if not (part is Dictionary) or not (part.get("mesh") is Mesh):
			continue
		if p == shape and not sh:
			continue   # no shadow for this belt: the shape part draws nothing
		g.parts.append({"mesh": part["mesh"], "local": part.get("local", Transform3D()), "shape": p == shape})
	g.np = g.parts.size()
	var holder := _holder()
	for p in g.np:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = g.parts[p]["mesh"]
		mm.custom_aabb = _box if _box.has_volume() else AABB(Vector3(-1e4, -1e3, -1e4), Vector3(2e4, 2e3, 2e4))
		var node := MultiMeshInstance3D.new()
		node.name = "K%dL%dS%dP%d" % [kind, lvl, 1 if sh else 0, p]
		node.multimesh = mm
		node.top_level = true
		node.lod_bias = float(kd[2])
		if shape >= 0:
			if bool(g.parts[p]["shape"]):
				node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
				if _shadow != null and _shadow.has_script_method("cast_bin"):
					_shadow.call("cast_bin", node, true, true)
			else:
				node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		else:
			node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if sh else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		holder.add_child(node)
		g.mms.append(mm)
		g.nodes.append(node)
	var offs := PackedInt32Array()
	offs.resize(g.np)
	g.off = offs
	_set_mp(g.np)
	g.gi = _order.size()
	_groups[key] = g
	_order.append(g)
	_gdirty.append(1)
	_gnp.append(g.np)
	_goff.resize(_order.size() * _mp)
	_grow(g)
	_drawn_ok = true
	return g


var _hold_node: Node3D = null
func _holder() -> Node3D:
	if _hold_node == null or not is_instance_valid(_hold_node):
		_hold_node = Node3D.new()
		_hold_node.name = "MPBeltShowMeshes"
		_hold_node.top_level = true
		add_child(_hold_node)
	return _hold_node


# more slots for a group: every region is laid out again in a new buffer (rare)
func _grow(g: Group) -> void:
	var want := maxi(INITIAL, g.cap * 2)
	var nb := PackedFloat32Array()
	for x in _order:
		var cap := want if x == g else x.cap
		var offs := PackedInt32Array()
		offs.resize(x.np)
		for p in x.np:
			var at := nb.size()
			if x.cap > 0 and x.n > 0:
				var a: int = x.off[p]
				nb.append_array(_buf.slice(a, a + x.n * 12))
			nb.resize(at + cap * 12)
			offs[p] = at
			_goff[x.gi * _mp + p] = at
		x.off = offs
	_buf = nb
	if g.cap != want:
		g.owner.resize(want)
		g.cap = want
		for mm in g.mms:
			mm.instance_count = want
		g.shown = -1
	for x in _order:
		_gdirty[x.gi] = 1


func _locals_for(g: Group, strands: int) -> Array:
	var kd := _kd(g.kind)
	var scale := 1.0
	if bool(kd[6]):
		var sv: Variant = _scales.get(strands)
		if sv == null:
			var host := _drawer_host()
			if host != null and host.has_method("_scale_for") and kd[7] != null:
				sv = float(host.call("_scale_for", kd[7], strands))
			else:
				sv = pow(maxf(float(strands), 1.0) / 50.0, 1.0 / 3.0) * 0.42
			_scales[strands] = sv
		scale = float(sv)
	var rest := Transform3D(kd[4] as Basis, Vector3.ZERO)
	var scaling := Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * scale), Vector3.ZERO)
	var out: Array = []
	for p in g.np:
		out.append(rest * scaling * (g.parts[p]["local"] as Transform3D))
	return out


func _free_groups() -> void:
	for g in _order:
		for node in g.nodes:
			if is_instance_valid(node):
				node.queue_free()
	_groups.clear()
	_order.clear()
	_locs.clear()
	_kds.clear()
	_scales.clear()
	_buf = PackedFloat32Array()
	_box = AABB()
	_drawn_ok = false
	_kd_why.clear()
	_kd_at.clear()
	_host = null
	_gdirty = PackedByteArray()
	_gnp = PackedInt32Array()
	_goff = PackedInt32Array()
	if _hold_node != null and is_instance_valid(_hold_node):
		_hold_node.queue_free()
	_hold_node = null


# every flat array empty (nothing hidden, nothing seated)
func _free_flat() -> void:
	_bcap = 0
	_bn = 0
	_nbfree = 0
	_bfree = PackedInt32Array()
	_bobj.clear()
	_brec.clear()
	_bfl = PackedInt32Array()
	_bver = PackedInt64Array()
	_bmark = PackedInt32Array()
	_bmid = PackedVector3Array()
	_brad = PackedFloat64Array()
	_bt0 = PackedFloat64Array()
	_buntil = PackedFloat64Array()
	_bet = PackedFloat64Array()
	_blen = PackedFloat64Array()
	_bl0 = PackedVector3Array()
	_bbz = PackedVector3Array()
	_bb0.clear()
	_bline.clear()
	_bcum.clear()
	_bbases.clear()
	_brids.clear()
	_bs0.clear()
	_bva.clear()
	_brma.clear()
	_be0a.clear()
	_bnr = PackedInt32Array()
	_btrn = PackedInt32Array()
	_bntr = PackedInt32Array()
	_rcap = 0
	_rn = 0
	_nrfree = 0
	_rfree = PackedInt32Array()
	_rseq = PackedInt32Array()
	_rkind = PackedInt32Array()
	_rstr = PackedInt32Array()
	_rside = PackedFloat32Array()
	_rlift = PackedFloat32Array()
	_rg = PackedInt32Array()
	_rslot = PackedInt32Array()
	_rs = PackedFloat64Array()
	_rk = PackedInt32Array()
	_ro = PackedVector3Array()
	_rlocs.clear()
	_mp = 4
	_cells.clear()
	_cellmap.clear()
	_vis = PackedInt32Array()
	_nvis = 0
	_vis_ok = false
	_act = PackedInt32Array()
	_nact = 0
	_bact = PackedByteArray()
	_act_ok = false
	_chg_on = false
	_ver_known = false
	_has_ver = false
	_has_geo = false


# ------------------------------------------------------------------ helpers

func _release_all() -> void:
	for pid in _belts:
		_show(_belts[pid])
	_belts.clear()
	rows_drawn = 0
	rows_written = 0
	belts_drawn = 0
	_scan_i = -1
	_scan = []
	_scanv = []
	_scan_recs = {}
	_free_groups()
	_free_flat()
	active = false
	table = null
	bs = null
	mirror = false
	if _mtab != null and is_instance_valid(_mtab):
		_mtab.free()
	_mtab = null
	_mrec.clear()


func _set_fault(why: String) -> void:
	if fault == "":
		fault = why
		push_warning("[NP] belt show off: " + why)
		if mp != null and is_instance_valid(mp) and mp.get("belt_draw") != null and mp.belt_draw.has_method("event"):
			mp.belt_draw.event("belt show off: " + why)
	# given back at the next frame's start (this can come in the middle of our belt loop)


# the game classes this needs, by name; "" or the reason
func _resolve() -> String:
	_batch = _cls("BeltRunBatch")
	if _batch == null:
		return "no BeltRunBatch"
	for m in BATCH_API:
		if not (_batch as Script).has_script_method(m):
			return "BeltRunBatch.%s missing" % m
	if not (_batch as Script).has_script_method("picture_of"):
		return "BeltRunBatch.picture_of missing"
	_pool = _cls("BeltRecordPool")
	_shadow = _cls("CargoShadow")
	_path_cls = _cls("BeltPath")
	_cfg = get_node_or_null("/root/Cfg")
	var sl: Variant = _cls("ShadowLod")
	var cm: Dictionary = (sl as Script).get_script_constant_map() if sl != null else {}
	_size_gain = float(cm.get("SIZE_GAIN", 0.0))
	_hold = float(cm.get("HOLD", 1.0))
	var bm: Dictionary = (_batch as Script).get_script_constant_map()
	_cargo_r = float(bm.get("CARGO_RADIUS", 0.45))
	_far_cut = float(bm.get("FAR_CUT", 0.6))
	return ""


func _cls(name: String) -> Variant:
	for c in ProjectSettings.get_global_class_list():
		if c is Dictionary and String(c.get("class", "")) == name:
			var s: Variant = load(String(c.get("path", "")))
			return s if s is Script else null
	return null


func _player() -> Node3D:
	var w: Variant = null
	if mp != null and is_instance_valid(mp) and mp.get("world_sync") != null and is_instance_valid(mp.world_sync):
		w = mp.world_sync.get("world")
	if w == null:
		w = get_tree().current_scene
	var me: Variant = w.get("player") if w != null and is_instance_valid(w) else null
	if me == null or not is_instance_valid(me) or not (me as Node3D).is_inside_tree():
		return null
	return me as Node3D


# the camera's eye; the view list is made again when the camera moved or turned more than VIS_PAD
# covers since it was made, or its fov or the window changed; false: no camera (all in view)
func _cam() -> bool:
	if _headless:
		return false
	var vp := get_viewport()
	var cam := vp.get_camera_3d() if vp != null else null
	if cam == null:
		return false
	var xf := cam.global_transform
	_eye = xf.origin
	if _vis_ok and _vis_cam:
		var vb := _vis_xf.basis
		if xf.origin.distance_squared_to(_vis_xf.origin) > VIS_MOVE * VIS_MOVE or cam.fov != _vis_fov \
				or (xf.basis.x - vb.x).length_squared() > _vis_turn * _vis_turn \
				or (xf.basis.y - vb.y).length_squared() > _vis_turn * _vis_turn \
				or (xf.basis.z - vb.z).length_squared() > _vis_turn * _vis_turn \
				or vp.get_visible_rect().size != _vis_size:
			_vis_ok = false
	return true


# ------------------------------------------------------------------ source (table or mirror)

func _source_recs(p0: Vector3) -> Dictionary:
	if not mirror:
		var d: Variant = table.get("_recs") if table != null and is_instance_valid(table) else null
		return d if d is Dictionary else {}
	# mirror: this PC's own belts near the player, their shape read by a private row table
	var live: Variant = _path_cls.get("_live") if _path_cls != null else null
	if not (live is Array):
		return {}
	for p in live:
		if p == null or not is_instance_valid(p) or not (p as Node).is_inside_tree():
			continue
		var mid: Variant = p.get("_mid")
		var m3: Vector3 = mid if mid is Vector3 else (p as Node3D).global_position
		if Vector2(m3.x - p0.x, m3.z - p0.z).length() > _r_out + 30.0:
			continue
		var run: Variant = p.get("run")
		if run == null or not is_instance_valid(run) or not _has_all(run, MIRROR_API):
			continue
		var r: Variant = _mtab.call("_rec_for", p)
		if r != null:
			r.fed = true
	return _mtab.get("_recs")


func _has_all(o: Object, names: Array) -> bool:
	for m in names:
		if not o.has_method(m):
			return false
	return true


# mirror: the belt's core rows as the game's drawer places them this frame, in the table's form
# (s0, v, room from one step clock), so the draw path is the same as for the host's rows
func _mirror_fill(b: Belt, now: float) -> void:
	var r: Variant = b.rec
	var run: Variant = b.run
	if run == null or not is_instance_valid(run):
		return
	var cnt := int(run.count())
	var f := int(run.first())
	var known: Dictionary = _mrec.get(b.pid, {})
	_mrec[b.pid] = known
	var seq := PackedInt32Array()
	var kind := PackedInt32Array()
	var strands := PackedInt32Array()
	var side := PackedFloat32Array()
	var lift := PackedFloat32Array()
	var s0 := PackedFloat32Array()
	var v := PackedFloat32Array()
	var room := PackedFloat32Array()
	var e0 := PackedFloat32Array()
	if cnt > 0:
		run.draw_into(_mst)
		var frac := Engine.get_physics_interpolation_fraction()
		var pinned: Variant = _batch.get("pinned_frac")
		if pinned is float and float(pinned) >= 0.0:
			frac = float(pinned)
		var dt := float(run.lead_seconds(frac, Engine.get_physics_frames()))
		r.t0 = now - dt * 1000.0
		r.until = now + 1000000.0
		r.et = 0.0
		for i in range(f, f + cnt):
			var q := int(run.seq_of(i))
			var info: Variant = known.get(q)
			if info == null:
				var rec: Variant = run.record(i)
				info = [int(rec.get("kind", 0)), int(rec.get("strands", 0)), float(rec.get("side", 0.0)), float(rec.get("lift", 0.0))] \
					if rec is Dictionary else [0, 0, 0.0, 0.0]
				known[q] = info
			var g := int(run.row_group(i))
			seq.append(q)
			kind.append(int(info[0]))
			strands.append(int(info[1]))
			side.append(float(info[2]))
			lift.append(float(info[3]))
			e0.append(0.0)
			if g == 0:
				s0.append(_mst[3] + float(run.rel_of(i)))
				v.append(_mst[4])
				room.append(_mst[5])
			elif g == 1:
				s0.append(_mst[0] + float(run.rel_of(i)))
				v.append(_mst[1])
				room.append(_mst[2])
			else:
				s0.append(float(run.s_of(i)))
				v.append(float(run.speed_of(i)))
				room.append(float(run.row_room(i)))
	if known.size() > cnt * 4 + 64:
		known.clear()
	r.seq = seq
	r.kind = kind
	r.strands = strands
	r.side = side
	r.lift = lift
	r.s0 = s0
	r.v = v
	r.room = room
	r.e0 = e0
	var same := b.direct and seq == b.seq_now and s0 == b.s0a and v == b.va and room == b.rma
	b.direct = true
	b.seq_now = seq
	b.s0a = s0
	b.va = v
	b.rma = room
	b.e0a = e0
	b.t0 = r.t0
	b.until = r.until
	b.et = r.et
	b.same = same
	if not same:
		_bfl[b.bi] &= ~F_STILL


# ------------------------------------------------------------------ dev tools (mirror test)

# dev: draw this PC's own core rows near the player (radius m) with our drawer instead of the game's
func dev_mirror(on: bool, radius: float = R_IN) -> Dictionary:
	_release_all()
	if not on:
		return stats()
	if fault != "":
		return stats()
	var why := _resolve()
	if why != "":
		_set_fault(why)
		_release_all()
		return stats()
	if _path_cls == null:
		_set_fault("no BeltPath")
		_release_all()
		return stats()
	_mtab = load(get_script().resource_path.get_base_dir() + "/mp_belt_replay.gd").new()
	_ease_ms = 80.0
	mirror = true
	_active_at = Time.get_ticks_msec()
	_r_in = radius
	_r_out = radius + (R_OUT - R_IN)
	active = true
	_runs_started = 0
	_runs_done = 0
	_cost_i = 0
	_check_at = -100000
	return stats()


# dev: the cost ring from now on (a measuring block)
func dev_cost_reset() -> void:
	_cost_i = 0
	takes = 0


# dev: our drawn spot of each row of the hidden belts in view against the game's own pose for it
# (run.pose_at), and our buffer against the pose we meant; max in mm, split straight / bent / seam
func dev_pose_check() -> Dictionary:
	var out := {"rows": 0, "straight_mm": 0.0, "bent_mm": 0.0, "seam_mm": 0.0, "seam_rows": 0, "bent_rows": 0,
		"basis_diff": 0.0, "basis_rest_diff": 0.0, "buf_mm": 0.0, "no_pose_at": 0}
	var tab: Variant = _mtab if mirror else table
	if tab == null:
		return out
	for bi in _bn:
		var b: Belt = _bobj[bi]
		if b == null or (_bfl[bi] & F_SEEN) == 0 or b.run == null or not is_instance_valid(b.run):
			continue
		var r: Variant = b.rec
		var straight := bool(r.straight)
		var length := float(r.length)
		for ri in _brids[bi]:
			var gi := _rg[ri]
			if gi < 0 or is_nan(_rs[ri]):
				continue
			var s := _rs[ri]
			var side := float(_rside[ri])
			var lift := float(_rlift[ri])
			var mine: Transform3D = tab._xf_on(r, s, side, lift) if _rk[ri] != -2 else tab._xf(r, s, side, lift)
			# our buffer, part 0, against the pose we meant
			if _gnp[gi] > 0:
				var x := _goff[gi * _mp] + _rslot[ri] * 12
				var bo := Vector3(_buf[x + 3], _buf[x + 7], _buf[x + 11])
				var want := mine * ((_rlocs[ri] as Array)[0] as Transform3D)
				out["buf_mm"] = maxf(float(out["buf_mm"]), bo.distance_to(want.origin) * 1000.0)
			if not b.run.has_method("pose_at"):
				out["no_pose_at"] = int(out["no_pose_at"]) + 1
				continue
			var gp: Variant = b.run.pose_at(s, side, lift)
			if not (gp is Transform3D):
				out["no_pose_at"] = int(out["no_pose_at"]) + 1
				continue
			var gt: Transform3D = gp
			var mm := gt.origin.distance_to(mine.origin) * 1000.0
			out["rows"] = int(out["rows"]) + 1
			var bd := 0.0
			var bdr := 0.0
			var kd := _kd(_rkind[ri])
			var rest: Basis = kd[4] if not kd.is_empty() else Basis.IDENTITY
			for c in 3:
				bd = maxf(bd, (gt.basis[c] - mine.basis[c]).length())
				bdr = maxf(bdr, ((gt.basis * rest)[c] - (mine.basis * rest)[c]).length())
			out["basis_diff"] = maxf(float(out["basis_diff"]), bd)
			out["basis_rest_diff"] = maxf(float(out["basis_rest_diff"]), bdr)
			if s < 0.0:
				# before the start (a row handed in with an overshoot back): carried back along the first segment
				var gs: Variant = b.run.pose_at(0.0, side, lift)
				out["before_rows"] = int(out.get("before_rows", 0)) + 1
				if gs is Transform3D:
					var gs3: Transform3D = gs
					var back := gs3.origin + gs3.basis.z.normalized() * s
					out["before_vs_carry_mm"] = maxf(float(out.get("before_vs_carry_mm", 0.0)), back.distance_to(mine.origin) * 1000.0)
			elif s > length:
				# past the end: the game's drawer carries the row on along its own belt; pose_at may stop at the end
				var ge: Variant = b.run.pose_at(length, side, lift)
				var clamped := ge is Transform3D and (ge as Transform3D).origin.distance_to(gt.origin) < 1e-5
				out["past_rows"] = int(out.get("past_rows", 0)) + 1
				out["past_mm"] = maxf(float(out.get("past_mm", 0.0)), mm)
				if clamped:
					out["past_pose_at_clamped"] = int(out.get("past_pose_at_clamped", 0)) + 1
				# our spot against the straight carry-on of the game's own end pose (its basis z)
				if ge is Transform3D:
					var ge3: Transform3D = ge
					var carry := ge3.origin + ge3.basis.z.normalized() * (s - length)
					out["past_vs_carry_mm"] = maxf(float(out.get("past_vs_carry_mm", 0.0)), carry.distance_to(mine.origin) * 1000.0)
			elif length - s < 0.6:
				out["seam_mm"] = maxf(float(out["seam_mm"]), mm)
				out["seam_rows"] = int(out["seam_rows"]) + 1
				if mm > 1.0 and (out.get("seam_bad", []) as Array).size() < 4:
					var cl: PackedFloat64Array = r.cum
					var g0: Variant = b.run.pose_at(s - 0.3, side, lift)
					var step := (gt.origin.distance_to((g0 as Transform3D).origin)) if g0 is Transform3D else -1.0
					var bad: Array = out.get("seam_bad", [])
					bad.append([snappedf(s, 0.001), snappedf(length, 0.001), snappedf(cl[cl.size() - 1], 0.001), straight,
						snappedf(mm, 0.1), snappedf(step, 0.001), _rk[ri], snappedf(side, 0.01), snappedf(lift, 0.01)])
					out["seam_bad"] = bad
				out["seam_over_1mm"] = int(out.get("seam_over_1mm", 0)) + (1 if mm > 1.0 else 0)
			elif straight:
				out["straight_mm"] = maxf(float(out["straight_mm"]), mm)
			else:
				out["bent_mm"] = maxf(float(out["bent_mm"]), mm)
				out["bent_rows"] = int(out["bent_rows"]) + 1
	return out


# dev: our draw path's s of each row (run again now) against the table's own _row_s at the same now
func dev_s_check() -> Dictionary:
	var tab: Variant = _mtab if mirror else table
	if tab == null:
		return {}
	var now := float(Time.get_ticks_usec()) / 1000.0 if mirror else float(bs.call("_sw_disp"))
	var worst := 0.0
	var n := 0
	for bi in _bn:
		var b: Belt = _bobj[bi]
		if b == null or (_bfl[bi] & F_SEEN) == 0:
			continue
		var fl := _take(bi, _bfl[bi])
		var rids: PackedInt32Array = _brids[bi]
		for ri in rids:
			_rs[ri] = NAN
		_rows(bi, fl, now, tab)
		for i in mini(rids.size(), (b.rec.seq as PackedInt32Array).size()):
			var ri := rids[i]
			if _rg[ri] < 0 or is_nan(_rs[ri]):
				continue
			worst = maxf(worst, absf(float(tab._row_s(b.rec, i, now)) - _rs[ri]))
			n += 1
	return {"rows": n, "max_m": worst}


# dev (metrics, called after our _process in the same frame): the s we drew this frame against the
# table's own answer at the same display ms (frame_now), for the belts in view within radius (x/z);
# nothing taken or written here. bad = rows more than 1 mm off.
func dev_now_check(center: Vector3, radius: float) -> Dictionary:
	if mirror or table == null or not is_instance_valid(table):
		return {}
	var c2 := Vector2(center.x, center.z)
	var now := frame_now
	var n := 0
	var bad := 0
	var worst := 0.0
	var ex: Array = []
	for bi in _bn:
		var b: Belt = _bobj[bi]
		if b == null or (_bfl[bi] & F_SEEN) == 0 or b.rec == null:
			continue
		if _par_last >= 0 and (_bfl[bi] & _tier_last) != 0 and (bi & 1) == _par_last:
			continue   # a far belt not worked on this frame (its rows are last frame's)
		if _has_ver and int(b.rec.ver) != _bver[bi]:
			continue   # a MID_M+ belt whose table change waits for a later frame (budget)
		var r: Variant = b.rec
		if Vector2(_bmid[bi].x, _bmid[bi].z).distance_to(c2) > radius + _brad[bi]:
			continue
		var seq: PackedInt32Array = r.seq
		var rids: PackedInt32Array = _brids[bi]
		for i in mini(rids.size(), seq.size()):
			var ri := rids[i]
			if _rg[ri] < 0 or is_nan(_rs[ri]):
				continue
			var d := absf(float(table._row_s(r, i, now)) - _rs[ri])
			if _rseq[ri] != seq[i]:
				d = INF
			n += 1
			if d > 0.001:
				bad += 1
				if ex.size() < 1:
					ex.append([String(r.key).left(20), _rseq[ri], snappedf(minf(d, 99.0), 0.0001), (_bfl[bi] & F_STILL) != 0,
						int(r.ver) != _bver[bi], snappedf(now - float(r.until), 0.1)])
			worst = maxf(worst, minf(d, 99.0))
		var tr: Array = r.tr
		for ri in b.trs:
			if _rg[ri] < 0 or is_nan(_rs[ri]):
				continue
			for e in tr:
				if int(e[0]) == _rseq[ri]:
					var d2 := absf(float(table._tr_s(e, now)) - _rs[ri])
					n += 1
					if d2 > 0.001:
						bad += 1
						if ex.size() < 1:
							ex.append([String(r.key).left(20), _rseq[ri], snappedf(minf(d2, 99.0), 0.0001), "tr"])
					worst = maxf(worst, minf(d2, 99.0))
					break
	return {"rows": n, "bad": bad, "max_mm": snappedf(worst * 1000.0, 0.01), "ex": ex}


# dev: where our frame's time goes (median over the ring): check round, frame loop, uploads (us);
# "slow"/"mid": the frames' counters (_pf) averaged over the slowest 2% and the middle 10% by total cost
func dev_split() -> Dictionary:
	var a := PackedInt32Array()
	var b := PackedInt32Array()
	var c := PackedInt32Array()
	var nf := mini(_cost_i, COST_N)
	var order: Array = []
	for i in nf:
		a.append(_split[i].x)
		b.append(_split[i].y)
		c.append(_split[i].z)
		order.append([_cost[i], i])
	order.sort()
	var avg := func(lo: int, hi: int) -> Array:
		var s := []
		s.resize(PF_N + 3)
		s.fill(0.0)
		var m := maxi(hi - lo, 1)
		for x in range(lo, hi):
			var i: int = order[x][1]
			for f in PF_N:
				s[f] += float(_pf[i * PF_N + f]) / m
			s[PF_N] += float(_split[i].x) / m
			s[PF_N + 1] += float(_split[i].y) / m
			s[PF_N + 2] += float(_split[i].z) / m
		for f in s.size():
			s[f] = snappedf(s[f], 0.1)
		return s
	var pf_keys := ["takes", "belts_worked", "rows_written", "full_poses", "take_us", "belts_visited", "deferred", "check_us", "loop_us", "upload_us"]
	var slow: Array = avg.call(int(nf * 0.98), nf) if nf > 0 else []
	var mid: Array = avg.call(int(nf * 0.45), int(nf * 0.55)) if nf > 0 else []
	a.sort()
	b.sort()
	c.sort()
	return {"check_p50": _pct(a, 0.5), "loop_p50": _pct(b, 0.5), "upload_p50": _pct(c, 0.5),
		"check_p99": _pct(a, 0.99), "loop_p99": _pct(b, 0.99), "upload_p99": _pct(c, 0.99),
		"check_max": _pct(a, 1.0), "loop_max": _pct(b, 1.0), "nvis": _nvis, "cells": _cells.size(),
		"keys": pf_keys, "slow": slow, "mid": mid}


# dev: per hidden belt in view, our rows against the core's row count and whether the game still has the run
func dev_count_check() -> Dictionary:
	var belts := 0
	var core := 0
	var ours := 0
	var game_has := 0
	for bi in _bn:
		var b: Belt = _bobj[bi]
		if b == null or b.run == null or not is_instance_valid(b.run):
			continue
		if _watched(b.run):
			game_has += 1
		if (_bfl[bi] & F_SEEN) == 0:
			continue
		belts += 1
		core += int(b.run.count()) if b.run.has_method("count") else 0
		for ri in _brids[bi]:
			if _rg[ri] >= 0:
				ours += 1
	return {"belts_seen": belts, "core_rows": core, "our_rows": ours, "game_still_has": game_has}


# dev: every fed + shaped belt of the source within radius (x/z) of the player: hidden by us, and
# its rows (rec) against our seated rows; for the headless coverage check
func dev_cover(radius: float) -> Dictionary:
	var me := _player()
	if me == null:
		return {}
	var c2 := Vector2(me.global_position.x, me.global_position.z)
	var recs := _source_recs(me.global_position) if active else {}
	var fed := 0
	var hidden := 0
	var not_hidden: Array = []
	var rec_rows := 0
	var our_rows := 0
	var seen := 0
	for pid in recs:
		var r: Variant = recs[pid]
		if r == null or not bool(r.fed) or not bool(r.ok):
			continue
		var mid: Vector3 = r.mid
		if maxf(Vector2(mid.x, mid.z).distance_to(c2) - float(r.rad), 0.0) > radius:
			continue
		fed += 1
		var b: Belt = _belts.get(pid)
		if b == null:
			if not_hidden.size() < 6:
				not_hidden.append([String(r.key).left(24), Array(r.kind).slice(0, 4)])
			continue
		hidden += 1
		if (_bfl[b.bi] & F_SEEN) != 0:
			seen += 1
		rec_rows += (r.seq as PackedInt32Array).size()
		for ri in _brids[b.bi]:
			if _rg[ri] >= 0 and not is_nan(_rs[ri]):
				our_rows += 1
	return {"fed": fed, "hidden": hidden, "seen": seen, "rec_rows": rec_rows, "our_rows": our_rows,
		"drawn_rows": drawn_rows(me.global_position, radius).size(), "not_hidden": not_hidden, "bad_kinds": _kd_why.duplicate(), "headless": _headless}


# dev: seqs that come twice in drawn_rows() and in the table's sample() around the player (radius m)
func dev_dupes(radius: float) -> Dictionary:
	var me := _player()
	if me == null:
		return {}
	var c := me.global_position
	var out := {}
	var srcs := {"drawn": drawn_rows(c, radius)}
	if table != null and is_instance_valid(table) and table.has_method("sample"):
		srcs["table"] = table.call("sample", c, radius)
	for name in srcs:
		var seen := {}
		var dup := 0
		var ex: Array = []
		for e in srcs[name]:
			var q := int(e[1])
			if seen.has(q):
				dup += 1
				if ex.size() < 3:
					ex.append([q, seen[q], String(e[0]), snappedf(float(e[4]), 0.01)])
			else:
				seen[q] = [String(e[0]), snappedf(float(e[4]), 0.01)]
		out[name] = {"rows": (srcs[name] as Array).size(), "dup": dup, "ex": ex}
	return out


# dev: hidden belts in view whose rows here are not the rec's rows now
func dev_stale() -> Dictionary:
	var n := 0
	var ex: Array = []
	var recs: Variant = table.get("_recs") if table != null else null
	for bi in _bn:
		var b: Belt = _bobj[bi]
		if b == null or (_bfl[bi] & F_SEEN) == 0:
			continue
		var seq: PackedInt32Array = b.rec.seq
		var mine := PackedInt32Array()
		for ri in _brids[bi]:
			mine.append(_rseq[ri])
		var same_rec: bool = recs is Dictionary and (recs as Dictionary).get(b.pid) == b.rec
		if mine != seq or not same_rec:
			n += 1
			if ex.size() < 4:
				ex.append([String(b.rec.key).left(24), Array(mine), Array(seq), same_rec, (_bfl[bi] & F_STILL) != 0,
					b.direct, b.seq_last == seq])
	return {"stale": n, "ex": ex}
