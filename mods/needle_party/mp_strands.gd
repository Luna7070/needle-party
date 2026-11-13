extends Node

# Loose straw.
#
# Every player's dig throws hundreds of straws around, and until now each
# player only saw their own: the floor was covered on one screen and clean on
# the other. The peer that made a straw sends where it is; everyone else keeps
# a copy of it.
#
# The copies are the game's own "visual only" straws: no collision, no physics
# body, drawn by the same multimesh as the real ones. They cannot be picked up
# or swept, so nobody can turn one straw into two loads of hay. Straws that
# have come to rest stop costing anything, since their pose never changes
# again, and nothing is sent about straws too far from anyone else to see.

const SCAN_TICK := 0.1
const MOVE_TICK := 0.1
const CENSUS_TICK := 5.0
const RANGE := 26.0        # what a remote player could see, Cfg.STRAND_DESPAWN_DIST
const MOVE_EPS := 0.004
const ADD_BUDGET := 80
const MOVE_BUDGET := 120
const MINE_CAP := 400      # never track more of our own than this
const MAX_RAW := 4 << 20

var mp: Node
var world: Node
var live: Node

var _mine := {}      # sid -> body we own
var _ghost := {}     # sid -> our copy of somebody else's straw
var _sent := {}      # sid -> last transform broadcast
var _owner := {}     # sid -> peer, for ghosts
var _goal := {}      # sid -> where a copy is heading, eased so it does not jump
var _next := 0
var _watched := {}   # instance id -> true, bodies whose tree_exiting we listen to
var _scan_t := 0.0
var _move_t := 0.0
var _census_t := 0.0


func start(mp_node: Node, world_node: Node) -> void:
	mp = mp_node
	world = world_node
	live = world.get("live")


func shutdown() -> void:
	for sid in _ghost:
		var b: Variant = _ghost[sid]
		if b != null and is_instance_valid(b) and live != null:
			_revive(b)
			live.consume(b)
	_ghost.clear()
	for pid in _hands:
		for b in _hands[pid]:
			if b != null and is_instance_valid(b) and live != null:
				_revive(b)
				live.consume(b)
	_hands.clear()
	_mine.clear()
	_sent.clear()
	_owner.clear()


func _me() -> int:
	return multiplayer.get_unique_id()


# The game keeps its straw bodies in a pool: a straw that is used up (a bucket
# scoops it, the vac takes it, it rides off on a belt) leaves the tree and the
# same body comes back later as some other straw. We held on to it and kept
# moving it, read its position out of the tree, and in the end handed it back
# to the pool again while something else was using it: a belt, a hand, a
# machine. That is the crash guests got while the host was building. So let go
# of a body the moment it leaves, whoever took it.
func _watch(b: Node) -> void:
	var id := b.get_instance_id()
	if _watched.has(id):
		return
	_watched[id] = true
	b.tree_exiting.connect(_on_body_left.bind(b))


func _on_body_left(b: Node) -> void:
	if not is_instance_valid(b):
		return
	var gid := int(b.get_meta("mp_gid", 0))
	if gid != 0 and _ghost.get(gid) == b:
		_ghost.erase(gid)
		_goal.erase(gid)
		_owner.erase(gid)
	var sid := int(b.get_meta("mp_sid", 0))
	if sid != 0 and _mine.get(sid) == b:
		_mine.erase(sid)
		_sent.erase(sid)
		if mp != null and mp.active() and multiplayer.multiplayer_peer != null:
			# (1.1.7, GitHub #17) a guest's straw that a belt took: our belt only
			# mirrors the host's, so the straw was simply gone. Hand it to the
			# host at that spot instead; the host's belt takes it from there.
			# Only when the belt really took it (its straw count goes up a frame
			# later): a straw a player scooped off a belt must stay gone, or the
			# host would make it again and the hay would exist twice.
			var belt: Object = _belt_under(b) if not mp.is_host and (b as Node3D).is_inside_tree() else null
			if belt != null and belt.has_method("strand_load"):
				_belt_check.append([sid, (b as Node3D).global_position, belt, int(belt.call("strand_load"))])
			else:
				mp._rx_straw_del.rpc(PackedInt64Array([sid]))
	for pid in _hands:
		(_hands[pid] as Array).erase(b)
	# the pool does not clear what we put on it, and the next straw made from
	# this body is nobody's copy
	for key in ["mp_ghost", "mp_gid", "mp_sid"]:
		if b.has_meta(key):
			b.remove_meta(key)


func _new_sid() -> int:
	_next += 1
	# peer in the high bits: peer * 1e6 + n ran into the next range after a
	# million straws in a long session, and two straws shared an id
	return (_me() << 31) | (_next & 0x7FFFFFFF)


# ------------------------------------------------------------------ ticks

# stopwatch: anything over 4 ms in one frame goes into mp_trace.log by name
func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_process_inner(delta)
	if mp != null and is_instance_valid(mp):
		mp.perf("straw", Time.get_ticks_usec() - t0)


func _process_inner(delta: float) -> void:
	if live == null or not is_instance_valid(live):
		return
	# keeps following the fist even if the link hiccups
	_park_hands()
	_ease(delta)
	_watch_hand()
	if mp == null or not mp.active() or multiplayer.multiplayer_peer == null:
		return
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	_check_belt_takes()
	_scan_t += delta
	if _scan_t >= SCAN_TICK:
		_scan_t = 0.0
		_scan()
	_move_t += delta
	if _move_t >= MOVE_TICK:
		_move_t = 0.0
		_send_moves()
	_census_t += delta
	if _census_t >= CENSUS_TICK:
		_census_t = 0.0
		_census()


func _watchers() -> Array:
	var out: Array = []
	var ws: Node = mp.world_sync
	if ws == null or not is_instance_valid(ws):
		return out
	for id in ws.avatars:
		var a: Variant = ws.avatars[id]
		if a != null and is_instance_valid(a) and (a as Node3D).is_inside_tree():
			out.append((a as Node3D).global_position)
	return out


func _near(at: Vector3, watchers: Array) -> bool:
	for w in watchers:
		if at.distance_squared_to(w) < RANGE * RANGE:
			return true
	return false


# Pick up straws that are ours and close enough to somebody else to matter,
# and let go of the ones that are gone or out of everyone's sight.
# (1.1.4) This used to walk every loose straw ten times a second and, worse,
# stopped at the first straw once 400 were tracked (and at the add budget), so
# every tracked straw it had not reached counted as gone: all of them were
# deleted for the other player and sent again under new ids, over and over.
# Now the straws we track are checked directly, and new ones are looked for a
# slice of the pile at a time.
const SCAN_SLICE := 500
var _scan_at := 0

func _scan() -> void:
	var watchers := _watchers()
	var active: Variant = live.get("_active")
	if not (active is Array):
		return
	var adds: Array = []
	var drop := PackedInt64Array()
	# ours: keep what is still loose and in sight, let go of the rest
	for sid in _mine.keys():
		var b: Variant = _mine[sid]
		var keep: bool = not watchers.is_empty() and b != null and is_instance_valid(b) \
			and (b as Node3D).is_inside_tree() and not bool(b.get_meta("protected", false)) \
			and _near((b as Node3D).global_position, watchers)
		if keep:
			continue
		_mine.erase(sid)
		_sent.erase(sid)
		if b != null and is_instance_valid(b) and b.has_meta("mp_sid"):
			b.remove_meta("mp_sid")
		drop.append(sid)
	# new ones: one slice of the pile per tick, never past the cap
	var n: int = (active as Array).size()
	if not watchers.is_empty() and n > 0 and _mine.size() < MINE_CAP:
		var count := mini(n, SCAN_SLICE)
		var looked := count
		for i in count:
			if _mine.size() >= MINE_CAP or adds.size() >= ADD_BUDGET:
				looked = i  # the rest get their turn next tick
				break
			var b: Variant = active[(_scan_at + i) % n]
			if b == null or not is_instance_valid(b):
				continue
			if b.has_meta("mp_ghost") or b.has_meta("needle_index"):
				continue
			if b.has_meta("mp_sid") and _mine.get(int(b.get_meta("mp_sid"))) == b:
				continue  # tracked already
			# straw in a hand, a bucket or on a tool travels with whatever
			# holds it, so it is not ours to scatter on the floor
			if bool(b.get_meta("protected", false)):
				continue
			var body := b as Node3D
			if not body.is_inside_tree() or not _near(body.global_position, watchers):
				continue
			var sid := _new_sid()
			b.set_meta("mp_sid", sid)
			_mine[sid] = b
			_watch(b)
			_sent[sid] = body.global_transform
			adds.append([sid, body.global_transform,
				b.get_meta("tint", Color(1, 1, 1))])
		_scan_at = (_scan_at + looked) % n
	if not adds.is_empty():
		mp._rx_straw_add.rpc(adds)
	if drop.size() > 0:
		mp._rx_straw_del.rpc(drop)


func _send_moves() -> void:
	if _mine.is_empty():
		return
	var ids := PackedInt64Array()
	var rows := PackedFloat32Array()
	for sid in _mine:
		var b: Variant = _mine[sid]
		if b == null or not is_instance_valid(b) or not (b as Node3D).is_inside_tree():
			continue
		var xf: Transform3D = (b as Node3D).global_transform
		var was: Variant = _sent.get(sid)
		if was != null and (was as Transform3D).origin.distance_squared_to(xf.origin) < MOVE_EPS * MOVE_EPS:
			continue
		_sent[sid] = xf
		_moving[sid] = true
		ids.append(sid)
		var q := xf.basis.get_rotation_quaternion()
		rows.append_array(PackedFloat32Array([xf.origin.x, xf.origin.y, xf.origin.z,
			q.x, q.y, q.z, q.w]))
		if ids.size() >= MOVE_BUDGET:
			break
	if ids.size() > 0:
		mp._rx_straw_move.rpc(ids, rows)


func _census() -> void:
	_send_rests()
	var ids := PackedInt64Array()
	for sid in _mine:
		if is_instance_valid(_mine[sid]):
			ids.append(sid)
	mp._rx_straw_census.rpc(ids)


# Moves can get lost and nothing would ever correct the last one: a straw that
# came to rest says where it lies once more, reliably.
var _moving := {}  # sid -> true: it moved since we last said where it rests

func _send_rests() -> void:
	var ids := PackedInt64Array()
	var rows := PackedFloat32Array()
	for sid in _moving.keys():
		var b: Variant = _mine.get(sid)
		var was: Variant = _sent.get(sid)
		if b == null or was == null or not is_instance_valid(b) or not (b as Node3D).is_inside_tree():
			_moving.erase(sid)
			continue
		var xf: Transform3D = (b as Node3D).global_transform
		if (was as Transform3D).origin.distance_squared_to(xf.origin) >= MOVE_EPS * MOVE_EPS:
			continue  # still on its way
		_moving.erase(sid)
		ids.append(sid)
		var q := xf.basis.get_rotation_quaternion()
		rows.append_array(PackedFloat32Array([xf.origin.x, xf.origin.y, xf.origin.z,
			q.x, q.y, q.z, q.w]))
		if ids.size() >= MOVE_BUDGET:
			break
	if ids.size() > 0:
		mp._rx_straw_rest.rpc(ids, rows)


# They lack these (came in late, or their pool was empty when we announced them).
func on_want(sender: int, ids: PackedInt64Array) -> void:
	var adds: Array = []
	for sid in ids:
		var b: Variant = _mine.get(sid)
		if b == null or not is_instance_valid(b) or not (b as Node3D).is_inside_tree():
			continue
		adds.append([sid, (b as Node3D).global_transform, b.get_meta("tint", Color(1, 1, 1))])
	if not adds.is_empty():
		mp._rx_straw_add.rpc_id(sender, adds)


# ------------------------------------------------------------------ from the net

func on_add(sender: int, adds: Array) -> void:
	if live == null or not is_instance_valid(live):
		return
	for row in adds:
		if not (row is Array) or (row as Array).size() < 3:
			continue
		var sid: int = row[0]
		if _ghost.has(sid) or _mine.has(sid):
			continue
		var xf: Transform3D = row[1]
		var b: Variant = live.spawn(xf.origin, xf.basis, Vector3.ZERO, row[2], true)
		if b == null:
			continue
		b.set_meta("mp_ghost", true)
		b.set_meta("mp_gid", sid)
		_solid(b)
		_place(b, xf)
		_ghost[sid] = b
		_owner[sid] = sender
		_watch(b)


func on_move(ids: PackedInt64Array, rows: PackedFloat32Array) -> void:
	for i in ids.size():
		var b: Variant = _ghost.get(ids[i])
		if b == null or not is_instance_valid(b) or not (b as Node3D).is_inside_tree():
			continue
		var k := i * 7
		if k + 6 >= rows.size():
			return
		var to := Transform3D(
			Basis(Quaternion(rows[k + 3], rows[k + 4], rows[k + 5], rows[k + 6])),
			Vector3(rows[k], rows[k + 1], rows[k + 2]))
		_goal[ids[i]] = [(b as Node3D).global_transform, to, 0.0]


func on_del(ids: PackedInt64Array) -> void:
	for sid in ids:
		_drop_ghost(sid)


func on_census(sender: int, ids: PackedInt64Array) -> void:
	var theirs := {}
	for sid in ids:
		theirs[sid] = true
	var gone: Array = []
	for sid in _ghost:
		if int(_owner.get(sid, 0)) == sender and not theirs.has(sid):
			gone.append(sid)
	for sid in gone:
		_drop_ghost(sid)
	var missing := PackedInt64Array()
	for sid in ids:
		if not _ghost.has(sid) and not _mine.has(sid):
			missing.append(sid)
			if missing.size() >= ADD_BUDGET:
				break
	if missing.size() > 0:
		mp._rx_straw_want.rpc_id(sender, missing)


func _drop_ghost(sid: int) -> void:
	var b: Variant = _ghost.get(sid)
	_ghost.erase(sid)
	_goal.erase(sid)
	_owner.erase(sid)
	if b != null and is_instance_valid(b) and live != null:
		_revive(b)
		live.consume(b)


# A "visual only" straw is taken out of the physics world entirely. These
# bodies come from a pool the game reuses for real straws, so put it back
# before handing it over or the next straw drawn from the pool falls through
# the floor. Same steps the robotic arm uses for its sample bodies.
func _revive(b: Node) -> void:
	var body := b as Node3D
	if body == null or not body.is_inside_tree():
		return
	var space: RID = body.get_world_3d().space
	PhysicsServer3D.body_set_space(b.get_rid(), space)
	PhysicsServer3D.body_set_state(b.get_rid(),
		PhysicsServer3D.BODY_STATE_TRANSFORM, body.global_transform)
	body.force_update_transform()


func peer_gone(pid: int) -> void:
	var gone: Array = []
	for sid in _owner:
		if int(_owner[sid]) == pid:
			gone.append(sid)
	for sid in gone:
		_drop_ghost(sid)


# ------------------------------------------------------------------ in the hand

# Straw a remote player is holding. Their own game parks the real bodies in
# front of their camera; here we put copies in their farmer's hand so the
# others can see them carry it.

const HAND_FAN := 0.05
# the hand node hangs down the arm: a short step along -Z is the fist itself
const HAND_REACH := 0.13
const HAND_DROP := -0.03

var _hands := {}     # peer -> Array of straw bodies we keep for them


func set_hand(pid: int, count: int) -> void:
	if live == null or not is_instance_valid(live):
		return
	var held: Array = _hands.get(pid, [])
	count = clampi(count, 0, 12)
	while held.size() > count:
		var b: Variant = held.pop_back()
		if b != null and is_instance_valid(b):
			_revive(b)
			live.consume(b)
	while held.size() < count:
		var b: Variant = live.spawn(Vector3.ZERO, Basis(), Vector3.ZERO,
			Color(0.86, 0.74, 0.4), true)
		if b == null:
			break
		b.set_meta("mp_ghost", true)
		held.append(b)
		_watch(b)
	if held.is_empty():
		_hands.erase(pid)
	else:
		_hands[pid] = held


# fanned out in front of the fist, the way the game holds them
func _park_hands() -> void:
	if _hands.is_empty():
		return
	var ws: Node = mp.world_sync
	if ws == null or not is_instance_valid(ws):
		return
	for pid in _hands.keys():
		var av: Variant = ws.avatars.get(pid)
		if av == null or not is_instance_valid(av) or not av.has_method("hand_xform"):
			set_hand(int(pid), 0)
			continue
		var base: Transform3D = av.hand_xform()
		var held: Array = _hands[pid]
		for i in held.size():
			var b: Variant = held[i]
			if b == null or not is_instance_valid(b) or not (b as Node3D).is_inside_tree():
				continue
			var side := (float(i) - float(held.size() - 1) * 0.5) * HAND_FAN
			var xf := base * Transform3D(Basis(Vector3.UP, side * 1.6),
				Vector3(side, HAND_DROP, -HAND_REACH))
			(b as Node3D).global_transform = xf


func drop_hand(pid: int) -> void:
	set_hand(pid, 0)


# ------------------------------------------------------------------ picking up

# A copy starts life outside the physics world, which is cheap but means the
# aim ray goes straight through it: you could see your friend's straw and not
# pick it up. Put it back in as a still, solid body. It collides with nothing
# itself, so it neither falls nor pushes anyone; the owner says where it is.
func _solid(b: Node) -> void:
	_revive(b)
	b.collision_layer = Cfg.L_STRAND
	b.collision_mask = 0
	b.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	b.freeze = true
	b.continuous_cd = false


func _place(b: Node, xf: Transform3D) -> void:
	PhysicsServer3D.body_set_state(b.get_rid(),
		PhysicsServer3D.BODY_STATE_TRANSFORM, xf)
	if (b as Node3D).is_inside_tree():
		(b as Node3D).global_transform = xf


# Picking somebody else's straw out of the yard takes it over: they drop
# theirs, we keep ours, and the straw stays one straw.
func _watch_hand() -> void:
	if _ghost.is_empty():
		return
	var pl: Variant = world.get("player")
	if pl == null or not is_instance_valid(pl):
		return
	var hand: Variant = pl.get("hand")
	if hand == null or not is_instance_valid(hand) or not hand.has_method("held_bodies"):
		return
	for b in hand.held_bodies():
		if b == null or not is_instance_valid(b) or not b.has_meta("mp_ghost"):
			continue
		var sid := int(b.get_meta("mp_gid", 0))
		if sid == 0 or not _ghost.has(sid):
			continue
		_ghost.erase(sid)
		_goal.erase(sid)
		_owner.erase(sid)
		b.remove_meta("mp_ghost")
		b.remove_meta("mp_gid")
		# a real straw again: it can fall, be carried and be put in a bucket
		b.collision_mask = LiveStrandManager.STRAND_MASK
		b.continuous_cd = true
		mp._rx_straw_claim.rpc(sid)


# Host only. A guest's straw landed in one of our machines' mouths. Our copy is
# frozen and a machine will not eat a frozen straw, so make it a real straw of
# ours, the way picking one up does, and the guest drops theirs. The machine
# takes it on its own tick and it burns once, here.
func host_take(b: Variant) -> bool:
	if not mp.is_host or b == null or not is_instance_valid(b):
		return false
	var sid := int((b as Node).get_meta("mp_gid", 0))
	if sid == 0 or _ghost.get(sid) != b:
		return false
	_ghost.erase(sid)
	_goal.erase(sid)
	_owner.erase(sid)
	b.remove_meta("mp_ghost")
	b.remove_meta("mp_gid")
	# a copy is made as a protected, visual only straw; this one is loose hay
	b.set_meta(LiveStrandManager.META_PROTECTED, false)
	b.collision_mask = LiveStrandManager.STRAND_MASK
	b.continuous_cd = true
	b.freeze = false
	b.sleeping = false
	mp._rx_straw_claim.rpc(sid)
	return true


# The belt under this straw right now, if any. Asked as it leaves the tree.
func _belt_under(b: Node) -> Object:
	if live == null or not is_instance_valid(live) or not live.has_method("_stand_belt_under"):
		return null
	var belt: Variant = live.call("_stand_belt_under", b)
	return belt if belt is Object and is_instance_valid(belt) else null


# Guest: straws of ours that left the tree on top of a belt, checked a frame
# later: [sid, where, belt, the belt's straw count before]
var _belt_check: Array = []

func _check_belt_takes() -> void:
	if _belt_check.is_empty():
		return
	var pending := _belt_check
	_belt_check = []
	var gone := PackedInt64Array()
	for e in pending:
		var belt: Variant = e[2]
		var took: bool = belt != null and is_instance_valid(belt) \
			and int((belt as Object).call("strand_load")) > int(e[3])
		if took:
			mp._rx_straw_board.rpc_id(1, int(e[0]), e[1])
		else:
			gone.append(int(e[0]))
	if gone.size() > 0:
		mp._rx_straw_del.rpc(gone)


# Host only (GitHub #17). A guest's belt took one of the guest's straws at
# `at`. Make our copy of it a real straw there (or a new one if we never had
# a copy) and let our own belt catch it; everyone sees it on our belt.
func on_board(sender: int, sid: int, at: Vector3) -> void:
	if not mp.is_host or live == null or not is_instance_valid(live):
		return
	var b: Variant = _ghost.get(sid)
	if b != null and is_instance_valid(b) and (b as Node3D).is_inside_tree() and int(_owner.get(sid, sender)) == sender and host_take(b):
		var xf := Transform3D((b as Node3D).global_transform.basis, at + Vector3.UP * 0.05)
		PhysicsServer3D.body_set_state((b as RigidBody3D).get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, xf)
		(b as Node3D).global_transform = xf
		(b as RigidBody3D).linear_velocity = Vector3.ZERO
		return
	# no copy here (it never came near us): a fresh straw of ours at that spot
	if live.has_method("spawn"):
		live.call("spawn", at + Vector3.UP * 0.05, Basis(), Vector3.ZERO, Color(0.86, 0.74, 0.4), false)


func on_claim(sender: int, sid: int) -> void:
	if sender == _me():
		return
	var mine: Variant = _mine.get(sid)
	if mine != null:
		_mine.erase(sid)
		_sent.erase(sid)
		if is_instance_valid(mine) and live != null:
			if mine.has_meta("mp_sid"):
				mine.remove_meta("mp_sid")
			live.consume(mine)
		return
	_drop_ghost(sid)


# A thrown straw moves fast and we only hear about it ten times a second, so
# slide the copy towards where it was last seen instead of teleporting it.
func _ease(delta: float) -> void:
	if _goal.is_empty():
		return
	var step_t := delta / MOVE_TICK
	var done: Array = []
	for sid in _goal:
		var b: Variant = _ghost.get(sid)
		if b == null or not is_instance_valid(b) or not (b as Node3D).is_inside_tree():
			done.append(sid)
			continue
		var walk: Array = _goal[sid]
		var from: Transform3D = walk[0]
		var to: Transform3D = walk[1]
		var t: float = minf(1.0, float(walk[2]) + step_t)
		walk[2] = t
		_place(b, Transform3D(
			Basis(from.basis.get_rotation_quaternion().slerp(
				to.basis.get_rotation_quaternion(), t)),
			from.origin.lerp(to.origin, t)))
		if t >= 1.0:
			done.append(sid)
	for sid in done:
		_goal.erase(sid)
