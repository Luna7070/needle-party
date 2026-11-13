extends Node

# Guest belt replay without our native belt core: the ROW TABLE ("script replay", 2026-11-15,
# stage 1: data, sync, metrics; drawing it is mp_belt_show.gd's part).
#
# The game's belt core cannot be stopped from a script, so on a guest without our core the rows
# the player SEES come from here: per belt the host's rows as its step words say (mp_belts
# _sw_apply / _sw_belt put each word in when its time comes on the display clock _sw_disp()).
# Each row is carried on per frame as the host's drawer does it: s = s0 + min(v x dt, room), dt
# from the host's step (t0) up to `until` (the step's length plus slack; far belts: their keep),
# then it stands. A word that moves an already drawn row by less than EASE_MAX makes it glide
# there over EASE_MS (smoothstep), a bigger move snaps (the same rule our native core had).
# A row lives in one belt's list only: a word that puts it on belt B takes it off A in that frame;
# a word that takes it off A near A's end keeps it drawn (TRANSIT_MS) until B's word comes, along
# B's path past A's end, so a row over a joint is never on neither or on both belts.
# A row our player takes is gone here at once (taken()); our own catches (rows our core made from
# our throws) are put in as standing rows until the host's row comes (mp_belts _sw_local).
# The guest's own belt core keeps running underneath (pick-up, machines); mp_belts keeps its rows
# the host's by number and order and near the drawn spot.
#
# Created by mp_belts (guest only). Only plain calls on the belt's run object by name, every one
# checked first (mp_belts ST_API_SCRIPT): the demo build lacks some game functions.

const EASE_MAX := 0.20       # m: a correction this small glides (our native core's np_stream_ease)
const EASE_MIN := 0.002
const EASE_MS := 80.0
const TRANSIT_MS := 300.0    # a row taken off near a belt's end waits this long for the next belt's word
const TRANSIT_END_M := 0.8   # ... when it is drawn this close to the end (else it is gone at once)
const GEO_MS := 2000         # a belt's shape read again this often (building can change it)
const NEAR_MS := 200
const SWEEP_MS := 1000
const COST_N := 600
const LOCAL_SEQ := 1500000000   # mp_belts ST_LOCAL_SEQ: our own catches

var active := false          # the table is live (script replay on and words coming)
var bs: Node = null          # mp_belts
var fault := ""              # non-empty: the table got data it cannot use (mp_belts' health watch falls back)

class Rec:
	extends RefCounted
	var path: Node = null
	var pid := 0
	var run: Variant = null
	var key := ""
	var fed := false          # a word for it came
	var ver := 0              # +1 on any change of its rows, spots, clock, glide, transit list or shape (the
	                          # drawer skips a belt whose ver it has drawn; one Rec per belt for its whole life)
	var ok := false           # its shape is read
	var geo_at := -100000
	var line := PackedVector3Array()
	var cum := PackedFloat64Array()
	var bases: Array[Basis] = []
	var straight := true
	var basis0 := Basis()
	var length := 0.0
	var mid := Vector3.ZERO
	var rad := 0.0
	var down_id := 0          # the next belt (path instance id), 0 none
	var down_s0 := NAN        # where this belt's end is on the next belt (its s); NAN not known yet (_down_s0)
	# the rows of the last word, front first as the host has them; one step clock for all
	var seq := PackedInt32Array()
	var kind := PackedInt32Array()
	var strands := PackedInt32Array()
	var side := PackedFloat32Array()
	var lift := PackedFloat32Array()
	var s0 := PackedFloat32Array()
	var v := PackedFloat32Array()
	var room := PackedFloat32Array()
	var e0 := PackedFloat32Array()
	var t0 := 0.0             # display ms the rows were at s0
	var until := 0.0          # display ms they are carried on up to
	var et := 0.0             # display ms the glides started
	# rows a word took off near the end, until the next belt's word has them:
	# [seq, kind, strands, side, lift, s0, v, room, t0, until, e0, et, gone]
	var tr: Array = []

var _recs := {}              # path instance id -> Rec
var _where := {}             # row seq -> Rec it is on (in its rows or its transit list)
var _tr_recs := {}           # path instance id -> Rec with transit rows
var _near_list: Array = []
var _near_at := -100000
var _near_c := Vector3(INF, INF, INF)
var _near_r := -1.0
var _sweep_at := 0
var _cur_run: Variant = null  # put(): the belt's run (fields of a row not cached any more)
var _st := PackedFloat64Array()
# counters
var puts := 0
var fast_puts := 0           # words that kept the belt's row list as it was (only spots changed)
var eased := 0
var snapped := 0
var moved := 0               # rows that came over from another belt's list
var transit_kept := 0
var transit_done := 0        # ... that the next belt's word took over
var transit_lost := 0        # ... that timed out
var transit_late := 0        # ... and came back later (the next belt's word was later than TRANSIT_MS)
var _lost_at := {}           # row seq -> display ms its transit timed out (for transit_late)
var taken_n := 0
var same_skips := 0          # words for a belt whose rows all stand where the table has them (no change)
var same_skip := true        # test tools only: false = such a word changes the record all the same (ver)
                             # (A/B 2026-11-16, one session, 20 s LAN dense throws: drawer takes 7.05 -> 3.51 a frame,
                             # its ms p99 0.564 -> 0.574: not what drives its p99 on this PC; 19-28 % of the puts skipped)
var _chg := {}               # path instance id -> Rec changed (ver) since the drawer last asked (changed_take)
var _cost := PackedInt32Array()
var _cost_i := 0
var _us_frame := 0


func _ready() -> void:
	_st.resize(10)
	_cost.resize(COST_N)


func clear() -> void:
	fault = ""
	# the records stay (the drawer may hold them): emptied, not fed until a word comes again
	for pid in _recs:
		var r: Rec = _recs[pid]
		r.fed = false
		r.seq = PackedInt32Array()
		r.kind = PackedInt32Array()
		r.strands = PackedInt32Array()
		r.side = PackedFloat32Array()
		r.lift = PackedFloat32Array()
		r.s0 = PackedFloat32Array()
		r.v = PackedFloat32Array()
		r.room = PackedFloat32Array()
		r.e0 = PackedFloat32Array()
		r.tr = []
		_bump(r)
	_where.clear()
	_tr_recs.clear()
	_near_list = []
	_near_at = -100000


# ------------------------------------------------------------------ geometry

func _rec_for(path: Node) -> Rec:
	var pid := path.get_instance_id()
	var r: Rec = _recs.get(pid)
	if r == null:
		r = Rec.new()
		r.path = path
		r.pid = pid
		if bs != null and bs.has_method("_key_of"):
			r.key = String(bs.call("_key_of", path))
		_recs[pid] = r
	var now := Time.get_ticks_msec()
	if not r.ok or now - r.geo_at >= GEO_MS:
		_geo(r, now)
	return r


func _geo(r: Rec, now: int) -> void:
	r.geo_at = now
	_geo_read(r)


func _geo_read(r: Rec) -> void:
	var run: Variant = r.path.get("run") if is_instance_valid(r.path) else null
	if run == null or not (run is Object) or not is_instance_valid(run):
		r.ok = false
		return
	r.run = run
	var lv: Variant = run.call("line")
	if not (lv is PackedVector3Array) or (lv as PackedVector3Array).size() < 2:
		r.ok = false
		return
	var line: PackedVector3Array = lv
	var len0 := float(run.call("length"))
	var dn0: Variant = r.path.get("downstream")
	var did := (dn0 as Node).get_instance_id() if dn0 != null and dn0 is Node and is_instance_valid(dn0) and dn0 != r.path else 0
	if r.ok and r.line == line and r.length == len0 and r.down_id == did:
		r.down_s0 = NAN   # found again when needed (the next belt's own shape may have changed)
		return   # the same shape as read last time
	var cv: Variant = run.call("cum")
	var bv: Variant = run.call("seg_bases")
	if not (bv is Array):
		r.ok = false
		return
	var cum := PackedFloat64Array()
	if cv is PackedFloat32Array or cv is PackedFloat64Array or cv is Array:
		for x in cv:
			cum.append(float(x))
	if cum.size() != line.size():
		r.ok = false
		return
	var bases: Array[Basis] = []
	for b in bv:
		if b is Basis:
			bases.append(b)
	if bases.size() < line.size() - 1:
		r.ok = false
		return
	_bump(r)
	r.line = line
	r.cum = cum
	r.bases = bases
	r.straight = bool(run.call("is_straight"))
	var b0: Variant = run.call("basis_at_start")
	r.basis0 = b0 if b0 is Basis else bases[0]
	r.length = float(run.call("length"))
	var mv: Variant = r.path.get("_mid")
	var m := Vector3.ZERO
	if mv is Vector3:
		m = mv
	else:
		for p in line:
			m += p
		m /= float(line.size())
	r.mid = m
	var rad := 0.0
	for p in line:
		rad = maxf(rad, p.distance_to(m))
	r.rad = rad
	r.down_id = 0
	r.down_s0 = NAN   # found when first needed (_down_s0), from the next belt's record: no recursion
	var dn: Variant = r.path.get("downstream")
	if dn != null and dn is Node and is_instance_valid(dn) and dn != r.path:
		r.down_id = (dn as Node).get_instance_id()
	r.ok = true


# where this belt's end is on the next belt (its s); NAN while the next belt has no record yet
func _down_s0(r: Rec) -> float:
	if not is_nan(r.down_s0) or r.down_id == 0:
		return r.down_s0
	var d: Rec = _recs.get(r.down_id)
	if d == null or not d.ok or r.line.is_empty():
		return NAN
	r.down_s0 = _closest_s(d, r.line[r.line.size() - 1])
	return r.down_s0


# the s on belt d closest to point p
func _closest_s(d: Rec, p: Vector3) -> float:
	var best := INF
	var bs_ := 0.0
	for k in d.line.size() - 1:
		var a := d.line[k]
		var ab := d.line[k + 1] - a
		var l2 := ab.length_squared()
		var t := 0.0 if l2 <= 1e-9 else clampf((p - a).dot(ab) / l2, 0.0, 1.0)
		var dd := (a + ab * t).distance_squared_to(p)
		if dd < best:
			best = dd
			bs_ = d.cum[k] + (d.cum[k + 1] - d.cum[k]) * t
	return bs_


# a row's pose at s on belt r (no rest, no scale): straight belts from the start, bent ones by
# segment; before the start and past the end along the first / last segment
func _xf_on(r: Rec, s: float, side: float, lift: float) -> Transform3D:
	if r.straight:
		var b := r.basis0
		return Transform3D(b, r.line[0] + b.x * side + b.y * lift + b.z * s)
	var last := r.line.size() - 2
	var k := 0
	while k < last and s > r.cum[k + 1]:
		k += 1
	var b2: Basis = r.bases[k]
	var span: float = r.cum[k + 1] - r.cum[k]
	var t := 0.0 if span <= 1e-9 else (s - r.cum[k]) / span
	if k > 0:
		t = maxf(t, 0.0)
	if k < last:
		t = minf(t, 1.0)
	return Transform3D(b2, r.line[k].lerp(r.line[k + 1], t) + b2.x * side + b2.y * lift)


# past the end: on the next belt's path (the seam stays where the next belt has it)
func _xf(r: Rec, s: float, side: float, lift: float) -> Transform3D:
	if s > r.length and r.down_id != 0:
		var d: Rec = _recs.get(r.down_id)
		var d0 := _down_s0(r)
		if d != null and d.ok and not is_nan(d0):
			return _xf_on(d, d0 + s - r.length, side, lift)
	return _xf_on(r, s, side, lift)


# ------------------------------------------------------------------ the rows

static func _drawn(s0: float, v: float, room: float, e0: float, t0: float, until: float, et: float, now: float) -> float:
	var x := s0
	if v > 0.0:
		var lead := maxf((minf(now, until) - t0) * 0.001, 0.0)
		x += minf(v * lead, maxf(room, 0.0))
	if e0 != 0.0:
		var p := (now - et) / EASE_MS
		if p < 1.0:
			p = maxf(p, 0.0)
			x += e0 * (1.0 - p * p * (3.0 - 2.0 * p))
	return x


func _row_s(r: Rec, i: int, now: float) -> float:
	return _drawn(r.s0[i], r.v[i], r.room[i], r.e0[i], r.t0, r.until, r.et, now)


static func _tr_s(e: Array, now: float) -> float:
	return _drawn(float(e[5]), float(e[6]), float(e[7]), float(e[10]), float(e[8]), float(e[9]), float(e[11]), now)


# Where row q is drawn now, in belt `to`'s s (its own belt, or the belt before it); NAN if unknown.
# Takes it off the list it is on.
func _take_prev(q: int, to: Rec, now: float) -> float:
	var r: Rec = _where.get(q)
	if r == null:
		return NAN
	_where.erase(q)
	var s := NAN
	var i := r.seq.find(q)
	if i >= 0:
		s = _row_s(r, i, now)
		_rm_row(r, i)
	else:
		for j in r.tr.size():
			if int(r.tr[j][0]) == q:
				s = _tr_s(r.tr[j], now)
				r.tr.remove_at(j)
				_bump(r)
				transit_done += 1
				if r.tr.is_empty():
					_tr_recs.erase(r.pid)
				break
	if is_nan(s) or r == to:
		return s
	moved += 1
	if r.down_id == to.pid:
		var d0 := _down_s0(r)
		return NAN if is_nan(d0) else d0 + s - r.length   # past r's end: on `to` from where r's end is on it
	return NAN


func _rm_row(r: Rec, i: int) -> void:
	_bump(r)
	r.seq.remove_at(i)
	r.kind.remove_at(i)
	r.strands.remove_at(i)
	r.side.remove_at(i)
	r.lift.remove_at(i)
	r.s0.remove_at(i)
	r.v.remove_at(i)
	r.room.remove_at(i)
	r.e0.remove_at(i)


# One belt of a host word (mp_belts _sw_belt): `want` the host's rows we show (front first), each
# at word index want_k[j] in ss / vs / rs from offset b; t0 / until on the display clock; `locals`
# our own catches on it: [seq, s, kind, strands, side, lift, (speed, room)] (s at t0, like the
# host's). Replaces the belt's rows.
func put(path: Node, want: PackedInt32Array, want_k: PackedInt32Array, ss: PackedFloat32Array, vs: PackedFloat32Array,
		rs: PackedFloat32Array, b: int, t0: float, until: float, now: float, locals: Array) -> void:
	var tu := Time.get_ticks_usec()
	var n := want.size()
	if want_k.size() != n:
		fault = "word rows and indexes differ"
		return
	for j in n:
		var kk := b + want_k[j]
		if kk < 0 or kk >= ss.size() or kk >= vs.size() or kk >= rs.size():
			fault = "word index out of range"
			return
	for e in locals:
		if not (e is Array) or (e as Array).size() < 6:
			fault = "bad local row"
			return
	var r := _rec_for(path)
	r.fed = true
	puts += 1
	if locals.is_empty() and want == r.seq and r.s0.size() == n and r.v.size() == n and r.room.size() == n and r.e0.size() == n:
		_put_same(r, want_k, ss, vs, rs, b, t0, until, now)
		_us_frame += Time.get_ticks_usec() - tu
		return
	var nl := locals.size()
	var nseq := want
	if nl > 0:
		nseq = want.duplicate()
		for e in locals:
			nseq.append(int(e[0]))
	var same := nseq == r.seq
	var kind := PackedInt32Array()
	var strands := PackedInt32Array()
	var side := PackedFloat32Array()
	var lift := PackedFloat32Array()
	var s0 := PackedFloat32Array()
	var v := PackedFloat32Array()
	var room := PackedFloat32Array()
	var e0 := PackedFloat32Array()
	var m := n + nl
	s0.resize(m)
	v.resize(m)
	room.resize(m)
	e0.resize(m)
	var old_i := {}
	if same:
		fast_puts += 1
		kind = r.kind
		strands = r.strands
		side = r.side
		lift = r.lift
	else:
		kind.resize(m)
		strands.resize(m)
		side.resize(m)
		lift.resize(m)
		for i in r.seq.size():
			old_i[r.seq[i]] = i
	var stat := _bs_dict("_sw_stat")
	_cur_run = r.run
	# the old rows' clock and glide, and the new word's, once for all rows (as _drawn works it out)
	var lead_o := maxf((minf(now, r.until) - r.t0) * 0.001, 0.0)
	var ease_o := 0.0
	var po := (now - r.et) / EASE_MS
	if po < 1.0:
		po = maxf(po, 0.0)
		ease_o = 1.0 - po * po * (3.0 - 2.0 * po)
	var lead_n := maxf((minf(now, until) - t0) * 0.001, 0.0)
	var o_s0 := r.s0
	var o_v := r.v
	var o_room := r.room
	var o_e0 := r.e0
	for j in m:
		var q := nseq[j]
		var ns: float
		var nv: float
		var nr: float
		if j < n:
			var k := b + want_k[j]
			ns = ss[k]
			nv = vs[k]
			nr = rs[k]
		else:
			var le: Array = locals[j - n]
			ns = float(le[1])
			nv = float(le[6]) if le.size() >= 8 else 0.0
			nr = float(le[7]) if le.size() >= 8 else 0.0
		s0[j] = ns
		v[j] = nv
		room[j] = nr
		# where it is drawn now: this belt's last word, or the belt before it (the same frame)
		var prev := NAN
		if same:
			prev = o_s0[j] + o_e0[j] * ease_o
			var ov := o_v[j]
			if ov > 0.0:
				prev += minf(ov * lead_o, maxf(o_room[j], 0.0))
		else:
			var oi: Variant = old_i.get(q)
			if oi != null:
				var o := int(oi)
				prev = _row_s(r, o, now)
				kind[j] = r.kind[o]
				strands[j] = r.strands[o]
				side[j] = r.side[o]
				lift[j] = r.lift[o]
			else:
				if not _lost_at.is_empty() and _lost_at.has(q):
					_lost_at.erase(q)
					transit_late += 1
				if _where.has(q):
					var from: Rec = _where.get(q)
					var fi := from.seq.find(q) if from != null and from != r else -1
					if fi >= 0:
						kind[j] = from.kind[fi]
						strands[j] = from.strands[fi]
						side[j] = from.side[fi]
						lift[j] = from.lift[fi]
					prev = _take_prev(q, r, now)
					if from == r:
						fi = -1
					if fi < 0:
						_fields(j, q, stat, kind, strands, side, lift, locals, n)
				else:
					_fields(j, q, stat, kind, strands, side, lift, locals, n)
		if not is_nan(prev):
			var d := prev - ns - (minf(nv * lead_n, maxf(nr, 0.0)) if nv > 0.0 else 0.0)
			var a := absf(d)
			if a > EASE_MIN and a < EASE_MAX:
				e0[j] = d
				eased += 1
			elif a >= EASE_MAX:
				snapped += 1
	if not same:
		# rows this word took off: near the end (the next belt's word may come later) they wait
		var nset := {}
		for q in nseq:
			nset[q] = true
		var taken := _bs_dict("_taken")
		var tnow := Time.get_ticks_msec()
		for i in r.seq.size():
			var q := r.seq[i]
			if nset.has(q):
				continue
			if _where.get(q) == r:
				_where.erase(q)
			var gone_taken := taken.has(q) and tnow - int(taken[q]) < 1500
			if gone_taken or r.down_id == 0 or q >= LOCAL_SEQ:
				continue
			var sd := _row_s(r, i, now)
			if sd < r.length - TRANSIT_END_M:
				continue
			r.tr.append([q, r.kind[i], r.strands[i], r.side[i], r.lift[i], r.s0[i], r.v[i], r.room[i], r.t0, r.until,
				r.e0[i], r.et, now])
			_where[q] = r
			_tr_recs[r.pid] = r
			transit_kept += 1
		for q in nseq:
			_where[q] = r
	r.seq = nseq
	r.kind = kind
	r.strands = strands
	r.side = side
	r.lift = lift
	r.s0 = s0
	r.v = v
	r.room = room
	r.e0 = e0
	r.t0 = t0
	r.until = until
	r.et = now
	_bump(r)
	_us_frame += Time.get_ticks_usec() - tu


# put() when the word has the same rows in the same order (most words): the spots and the clock
# change, glides as put() works them out, the arrays written in place
func _put_same(r: Rec, want_k: PackedInt32Array, ss: PackedFloat32Array, vs: PackedFloat32Array, rs: PackedFloat32Array,
		b: int, t0: float, until: float, now: float) -> void:
	fast_puts += 1
	var lead_o := maxf((minf(now, r.until) - r.t0) * 0.001, 0.0)
	var ease_o := 0.0
	var po := (now - r.et) / EASE_MS
	if po < 1.0:
		po = maxf(po, 0.0)
		ease_o = 1.0 - po * po * (3.0 - 2.0 * po)
	# (2026-11-16) every row stands, and stands where the table has it (the 2 s word of a standing belt):
	# nothing changes, the drawer need not take the belt again (bursts of such words made its slow frames)
	if same_skip and _all_stand(r, want_k, ss, vs, rs, b, lead_o, ease_o):
		same_skips += 1
		return
	var lead_n := maxf((minf(now, until) - t0) * 0.001, 0.0)
	var s0 := r.s0
	var v := r.v
	var room := r.room
	var e0 := r.e0
	# the record lets go of them first: written here without a copy (one who holds them keeps his)
	r.s0 = PackedFloat32Array()
	r.v = PackedFloat32Array()
	r.room = PackedFloat32Array()
	r.e0 = PackedFloat32Array()
	for j in want_k.size():
		var k := b + want_k[j]
		var ns := ss[k]
		var nv := vs[k]
		var nr := rs[k]
		var prev := s0[j] + e0[j] * ease_o
		var ov := v[j]
		if ov > 0.0:
			prev += minf(ov * lead_o, maxf(room[j], 0.0))
		var d := prev - ns - (minf(nv * lead_n, maxf(nr, 0.0)) if nv > 0.0 else 0.0)
		var a := absf(d)
		var ne := 0.0
		if a > EASE_MIN and a < EASE_MAX:
			ne = d
			eased += 1
		elif a >= EASE_MAX:
			snapped += 1
		s0[j] = ns
		v[j] = nv
		room[j] = nr
		e0[j] = ne
	r.s0 = s0
	r.v = v
	r.room = room
	r.e0 = e0
	r.t0 = t0
	r.until = until
	r.et = now
	_bump(r)


func _all_stand(r: Rec, want_k: PackedInt32Array, ss: PackedFloat32Array, vs: PackedFloat32Array, rs: PackedFloat32Array,
		b: int, lead_o: float, ease_o: float) -> bool:
	for j in want_k.size():
		var k := b + want_k[j]
		if vs[k] > 0.0 and rs[k] > 0.0:
			return false   # the word's row moves
		var ov := r.v[j]
		var orm := maxf(r.room[j], 0.0)
		if ov > 0.0 and orm > 0.0 and ov * lead_o < orm:
			return false   # ours still moves (or stopped at `until`, short of its room)
		if r.e0[j] != 0.0 and ease_o > 0.0:
			return false   # gliding
		var prev := r.s0[j] + (minf(ov * lead_o, orm) if ov > 0.0 else 0.0)
		if absf(prev - ss[k]) > EASE_MIN:
			return false
	return true


func _bump(r: Rec) -> void:
	r.ver += 1
	_chg[r.pid] = r


# For the drawer: the records (Rec) whose ver changed since the last call (rows, spots, clock, glide,
# transit list or shape), each once; the list is cleared. A Rec of a belt that is gone may be in it
# (check r.path). One caller only (the drawer): a second one would take the first one's changes.
func changed_take() -> Array:
	if _chg.is_empty():
		return []
	var out := _chg.values()
	_chg.clear()
	return out


# mp_belts' Dictionary `nm` (the same object for its whole life: asked once)
var _bs_d := {}
func _bs_dict(nm: String) -> Dictionary:
	var d: Variant = _bs_d.get(nm)
	if d is Dictionary:
		return d
	var v: Variant = bs.get(nm) if bs != null else null
	if v is Dictionary:
		_bs_d[nm] = v
		return v
	return {}


func _fields(j: int, q: int, stat: Dictionary, kind: PackedInt32Array, strands: PackedInt32Array, side: PackedFloat32Array,
		lift: PackedFloat32Array, locals: Array, n: int) -> void:
	if j >= n:
		var le: Array = locals[j - n]
		kind[j] = int(le[2])
		strands[j] = int(le[3])
		side[j] = float(le[4])
		lift[j] = float(le[5])
		return
	var st: Variant = stat.get(q)
	if st is Array and (st as Array).size() >= 7:
		kind[j] = int(st[0])
		strands[j] = int(st[1])
		side[j] = float(st[5])
		lift[j] = float(st[6])
		return
	# fixed fields no longer cached (mp_belts clears them now and then): our core's row with that number
	var run: Variant = _cur_run
	if run == null or not is_instance_valid(run):
		return
	var f := int(run.call("first"))
	for i in range(f, f + int(run.call("count"))):
		if int(run.call("seq_of", i)) == q:
			kind[j] = int(run.call("kind_of", i))
			strands[j] = int(run.call("strands_of", i))
			side[j] = float(run.call("side_of", i))
			lift[j] = float(run.call("lift_of", i))
			return


# Our own catch (mp_belts _sw_on_caught): drawn from this frame on, at `s` now, moving at v up to
# `room` more, until the belt's next word has it among its locals. Only on a belt the host's words
# feed (on another one the game draws our core's rows, this one too).
func add_local(path: Node, q: int, s: float, kind: int, strands: int, side: float, lift: float, v: float, room: float,
		now: float) -> void:
	if path == null or not is_instance_valid(path):
		return
	var r: Rec = _recs.get(path.get_instance_id())
	if r == null or not r.fed or r.seq.has(q):
		return
	var lead := maxf((minf(now, r.until) - r.t0) * 0.001, 0.0)
	var mv := v * lead if v > 0.0 else 0.0
	r.seq.append(q)
	r.kind.append(kind)
	r.strands.append(strands)
	r.side.append(side)
	r.lift.append(lift)
	r.s0.append(s - mv)
	r.v.append(v)
	r.room.append(maxf(room, 0.0) + mv)
	r.e0.append(0.0)
	_bump(r)
	_where[q] = r


# our player took row q (or our own catch went): gone from the table now
func taken(q: int) -> void:
	var r: Rec = _where.get(q)
	if r == null:
		return
	taken_n += 1
	_take_prev(q, r, 0.0)


# once a frame (mp_belts _sw_tick): rows waiting for the next belt's word time out; belts gone
func tick(now: float) -> void:
	if _us_frame > 0 or active:
		_cost[_cost_i % COST_N] = _us_frame
		_cost_i += 1
	_us_frame = 0
	if not _tr_recs.is_empty():
		# a late word (lag, jitter) is late for both belts: wait longer the further behind we draw
		var bv: Variant = bs.get("buffer_ms") if bs != null else null
		var wait := maxf(TRANSIT_MS, float(bv) * 2.0 + 150.0) if (bv is float or bv is int) else TRANSIT_MS
		for pid in _tr_recs.keys():
			var r: Rec = _tr_recs[pid]
			var j := r.tr.size() - 1
			while j >= 0:
				if now - float(r.tr[j][12]) > wait:
					var q := int(r.tr[j][0])
					if _lost_at.size() > 2000:
						_lost_at.clear()
					_lost_at[q] = now
					if _where.get(q) == r and r.seq.find(q) < 0:
						_where.erase(q)
					r.tr.remove_at(j)
					_bump(r)
					transit_lost += 1
				j -= 1
			if r.tr.is_empty():
				_tr_recs.erase(pid)
	var t := Time.get_ticks_msec()
	if t - _sweep_at >= SWEEP_MS:
		_sweep_at = t
		for pid in _recs.keys():
			var r: Rec = _recs[pid]
			if r.path == null or not is_instance_valid(r.path) or not r.path.is_inside_tree():
				for q in r.seq:
					if _where.get(q) == r:
						_where.erase(q)
				for e in r.tr:
					if _where.get(int(e[0])) == r:
						_where.erase(int(e[0]))
				_recs.erase(pid)
				_tr_recs.erase(pid)
				_chg.erase(pid)


# ------------------------------------------------------------------ for the drawer and the tools

# Paths (Node) with table records near `center` (their shape within `radius`). Cached for NEAR_MS;
# the array is handed out as it is: do not change it.
func belts_near(center: Vector3, radius: float) -> Array:
	var now := Time.get_ticks_msec()
	if now - _near_at < NEAR_MS and center.distance_to(_near_c) < 1.0 and absf(radius - _near_r) < 0.5:
		return _near_list
	_near_at = now
	_near_c = center
	_near_r = radius
	var out: Array = []
	for pid in _recs:
		var r: Rec = _recs[pid]
		if not r.fed or not r.ok or not is_instance_valid(r.path):
			continue
		if r.mid.distance_to(center) <= radius + r.rad:
			out.append(r.path)
	_near_list = out
	return out


# This belt's rows as drawn at `now_disp` (the display clock, mp_belts _sw_disp()): appends kind,
# strands and the world pose (no rest, no scale; the row's lane side / lift applied) of each;
# rows past the end are on the next belt's path. Returns how many.
func rows_into(path: Node, now_disp: float, out_kinds: PackedInt32Array, out_strands: PackedInt32Array, out_xf: Array) -> int:
	if path == null:
		return 0
	var r: Rec = _recs.get(path.get_instance_id())
	if r == null or not r.ok:
		return 0
	var n := r.seq.size()
	for i in n:
		var s := _row_s(r, i, now_disp)
		out_kinds.append(r.kind[i])
		out_strands.append(r.strands[i])
		out_xf.append(_xf(r, s, r.side[i], r.lift[i]))
	for e in r.tr:
		out_kinds.append(int(e[1]))
		out_strands.append(int(e[2]))
		out_xf.append(_xf(r, _tr_s(e, now_disp), float(e[3]), float(e[4])))
	return n + r.tr.size()


func _disp() -> float:
	if bs != null and bs.has_method("_sw_disp"):
		return float(bs.call("_sw_disp"))
	return 0.0


func _in_zone(r: Rec, c2: Vector2, radius: float) -> bool:
	return r.ok and is_instance_valid(r.path) and Vector2(r.mid.x, r.mid.z).distance_to(c2) <= radius


# For the metrics: the table as drawn now, belts whose middle is within `radius` of `center` (x/z):
# [[belt key, seq, kind, world spot (centre line), s, speed now], ...]. A row past its belt's end
# keeps its belt and an s past the length (as the host's drawer draws it on that belt).
func sample(center: Vector3, radius: float) -> Array:
	var now := _disp()
	var c2 := Vector2(center.x, center.z)
	var out: Array = []
	for pid in _recs:
		var r: Rec = _recs[pid]
		if not _in_zone(r, c2, radius):
			continue
		for i in r.seq.size():
			var s := _row_s(r, i, now)
			out.append([r.key, r.seq[i], r.kind[i], _xf(r, s, 0.0, 0.0).origin, s, _v_now(r.s0[i], r.v[i], r.room[i], r.t0, r.until, now)])
		for e in r.tr:
			var s2 := _tr_s(e, now)
			out.append([r.key, int(e[0]), int(e[1]), _xf(r, s2, 0.0, 0.0).origin, s2,
				_v_now(float(e[5]), float(e[6]), float(e[7]), float(e[8]), float(e[9]), now)])
	return out


static func _v_now(s0: float, v: float, room: float, t0: float, until: float, now: float) -> float:
	if v <= 0.0 or now >= until:
		return 0.0
	var lead := maxf((now - t0) * 0.001, 0.0)
	return v if v * lead < room else 0.0


# For the metrics: per table row (zone as sample()) the distance in m to the guest core's row with
# the same seq as the game's drawer draws it now; missing = table rows our core lacks, extra =
# core rows in those belts the table lacks. Also "d": every distance.
# detail > 0 (dev): up to that many rows further off than 6 cm with the table's and our core's fields
func core_gap(center: Vector3, radius: float, detail := 0) -> Dictionary:
	var now := _disp()
	var c2 := Vector2(center.x, center.z)
	var table := {}   # seq -> world spot
	var core := {}
	var tkey := {}    # seq -> belt key (table), for the worst example
	var ckey := {}
	var frac := Engine.get_physics_interpolation_fraction()
	var ptick := Engine.get_physics_frames()
	for pid in _recs:
		var r: Rec = _recs[pid]
		if not _in_zone(r, c2, radius) or not r.fed:
			continue
		for i in r.seq.size():
			table[r.seq[i]] = _xf(r, _row_s(r, i, now), 0.0, 0.0).origin
			tkey[r.seq[i]] = [r.key, _row_s(r, i, now), r.length, 0, r, i]
		for e in r.tr:
			table[int(e[0])] = _xf(r, _tr_s(e, now), 0.0, 0.0).origin
			tkey[int(e[0])] = [r.key, _tr_s(e, now), r.length, 1]
		var run: Variant = r.run
		if run == null or not is_instance_valid(run):
			continue
		var cnt := int(run.call("count"))
		if cnt == 0:
			continue
		run.call("draw_into", _st)
		var dt := float(run.call("lead_seconds", frac, ptick))
		var fo := _st[0] + minf(_st[1] * dt, _st[2])
		var jo := _st[3] + minf(_st[4] * dt, _st[5])
		var f := int(run.call("first"))
		for i in range(f, f + cnt):
			var q := int(run.call("seq_of", i))
			var g := int(run.call("row_group", i))
			var s: float
			if g == 0:
				s = jo + float(run.call("rel_of", i))
			elif g == 1:
				s = fo + float(run.call("rel_of", i))
			else:
				s = float(run.call("s_of", i))
				var v := float(run.call("speed_of", i))
				if v > 0.0:
					s += minf(v * dt, float(run.call("row_room", i)))
			core[q] = _xf_on(r, s, 0.0, 0.0).origin
			ckey[q] = [r.key, s, g, run, i, fo, jo]
	var d := PackedFloat32Array()
	var missing := 0
	var worst: Array = []
	var cats := {}   # rows further off than 6 cm, by kind of place
	var ex: Array = []
	for q in table:
		var cp: Variant = core.get(q)
		if cp == null:
			missing += 1
			continue
		var dd := (table[q] as Vector3).distance_to(cp)
		d.append(dd)
		if dd > 0.06:
			var tk0: Array = tkey.get(q, ["", 0.0, 0.0, 0])
			var ck0: Array = ckey.get(q, ["", 0.0, 0])
			var ts := float(tk0[1])
			var tl := float(tk0[2])
			var zone := "tr" if int(tk0[3]) == 1 else ("past" if ts > tl else ("end" if ts > tl - 1.0 else ("start" if ts < 1.0 else "mid")))
			var ck := "%s %s g%d %s" % ["same" if tk0[0] == ck0[0] else "other", zone, int(ck0[2]),
				"ahead" if (tk0[0] == ck0[0] and float(ck0[1]) > ts) or (tk0[0] != ck0[0] and float(ck0[1]) < 1.0) else "behind"]
			cats[ck] = int(cats.get(ck, 0)) + 1
			if detail > 0 and ex.size() < detail:
				ex.append(_gap_ex(q, dd, ck, tk0, ck0, now))
		if worst.is_empty() or dd > float(worst[1]):
			var tk: Array = tkey.get(q, ["", 0.0, 0.0, 0])
			var ck: Array = ckey.get(q, ["", 0.0, 0])
			worst = [q, dd, String(tk[0]).hash() & 0xffff, String(ck[0]).hash() & 0xffff, snappedf(float(tk[1]), 0.01),
				snappedf(float(ck[1]), 0.01), snappedf(float(tk[2]), 0.01), int(tk[3]), int(ck[2])]
	var extra := 0
	for q in core:
		if not table.has(q):
			extra += 1
	var srt := d.duplicate()
	srt.sort()
	var tot := 0.0
	for x in d:
		tot += x
	return {"n": d.size(), "mean": tot / d.size() if d.size() > 0 else 0.0,
		"p95": srt[mini(srt.size() - 1, int(srt.size() * 0.95))] if srt.size() > 0 else 0.0,
		"max": srt[srt.size() - 1] if srt.size() > 0 else 0.0, "missing": missing, "extra": extra, "d": d, "worst": worst,
		"cats": cats, "ex": ex}


# (dev) one row of core_gap's detail: the table's row [s0, v, room, ms since t0, ms to until, e0, index,
# rows] and our core's [s_of, speed, room, rel, index, rows, end_held, free / jam offset, draw_into]
func _gap_ex(q: int, dd: float, ck: String, tk: Array, cr: Array, now: float) -> Dictionary:
	var out := {"q": q, "cm": snappedf(dd * 100.0, 0.1), "cat": ck, "len": snappedf(float(tk[2]), 0.01),
		"ts": snappedf(float(tk[1]), 0.01), "cs": snappedf(float(cr[1]), 0.01) if cr.size() > 1 else null}
	if tk.size() > 5 and tk[4] is Rec:
		var r: Rec = tk[4]
		var i := int(tk[5])
		if i < r.seq.size():
			out["t"] = [snappedf(r.s0[i], 0.001), snappedf(r.v[i], 0.001), snappedf(r.room[i], 0.001),
				snappedf(now - r.t0, 0.1), snappedf(r.until - now, 0.1), snappedf(r.e0[i], 0.001), i, r.seq.size()]
	if cr.size() > 6:
		var run: Variant = cr[3]
		var i := int(cr[4])
		if run != null:
			var f := int(run.call("first"))
			run.call("draw_into", _st)
			var sv: Array = []
			for x in _st:
				sv.append(snappedf(x, 0.001))
			out["c"] = [snappedf(float(run.call("s_of", i)), 0.001), snappedf(float(run.call("speed_of", i)), 0.001),
				snappedf(float(run.call("row_room", i)), 0.001), snappedf(float(run.call("rel_of", i)), 0.001),
				i - f, int(run.call("count")), bool(run.get("end_held")), snappedf(float(cr[5]), 0.001),
				snappedf(float(cr[6]), 0.001), sv]
	return out


func stats() -> Dictionary:
	var rows := 0
	var belts := 0
	var trn := 0
	for pid in _recs:
		var r: Rec = _recs[pid]
		if r.seq.size() > 0:
			belts += 1
		rows += r.seq.size()
		trn += r.tr.size()
	var c := _cost.slice(0, mini(_cost_i, COST_N))
	c.sort()
	return {"active": active, "records": _recs.size(), "belts": belts, "rows": rows, "transit": trn, "where": _where.size(),
		"puts": puts, "fast_puts": fast_puts, "eased": eased, "snapped": snapped, "moved": moved,
		"transit_kept": transit_kept, "transit_done": transit_done, "transit_lost": transit_lost, "transit_late": transit_late, "taken": taken_n, "same_skips": same_skips, "changed_n": _chg.size(),
		"put_us_p50": c[int(c.size() * 0.5)] if c.size() > 0 else 0, "put_us_p99": c[mini(c.size() - 1, int(c.size() * 0.99))] if c.size() > 0 else 0}
