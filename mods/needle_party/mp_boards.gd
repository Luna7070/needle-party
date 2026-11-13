extends Node

# Paint boards.
#
# A board is placed and taken down like any building, but what is drawn on it
# lived only on the screen of whoever drew it. Now a finished stroke, an
# erase or a wipe goes to everyone, and their board shows the same picture.
#
# Only what is drawn live travels. A board can also cycle through the
# drawings a player has kept, and that sketchbook is each player's own, so a
# board showing one of those is left alone rather than having the two players'
# boards pull the picture back and forth.
#
# A drawing can be large, so it goes out in pieces of about a kilobyte.

const SCAN := 0.5
const SEND_DELAY := 0.3
const PIECE := 1000
const MAX_RAW := 4 << 20
const KEY_SLACK := 0.25

var mp: Node
var world: Node
var builds: Node
var _scan_t := 0.0
var _watched := {}   # board instance id -> true
var _due := {}       # board -> seconds until we send it
var _known := {}     # board instance id -> hash of the strokes last sent or received
var _applying := false
var _parts := {}     # "key|id" -> {n, raw, got: {i: bytes}}
var _next := 0
var _hold := {}      # board -> a picture that came while we were drawing on it


func start(mp_node: Node, world_node: Node) -> void:
	mp = mp_node
	world = world_node
	builds = world.get("builds")


func shutdown() -> void:
	_due.clear()
	_hold.clear()
	_parts.clear()


func _boards() -> Array:
	if builds == null or not is_instance_valid(builds):
		return []
	var arr: Variant = builds.get("paint_boards")
	return arr if arr is Array else []


func _key(b: Node3D) -> String:
	var p := b.global_position
	return "%.2f,%.2f,%.2f" % [p.x, p.y, p.z]


# stopwatch: anything over 4 ms in one frame goes into mp_trace.log by name
func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_process_inner(delta)
	if mp != null and is_instance_valid(mp):
		mp.perf("boards", Time.get_ticks_usec() - t0)


func _process_inner(delta: float) -> void:
	if mp == null or not mp.active() or multiplayer.multiplayer_peer == null:
		return
	_scan_t += delta
	if _scan_t >= SCAN:
		_scan_t = 0.0
		for b in _boards():
			if is_instance_valid(b) and b.has_signal("drawing_changed"):
				var id: int = b.get_instance_id()
				if not _watched.has(id):
					_watched[id] = true
					b.drawing_changed.connect(_on_changed.bind(b))
	for b in _due.keys():
		_due[b] = float(_due[b]) - delta
		if float(_due[b]) <= 0.0:
			_due.erase(b)
			if is_instance_valid(b):
				if _hold.has(b):
					_take_held(b)
				_send(b, 0)
	for b in _hold.keys():
		if not is_instance_valid(b):
			_hold.erase(b)
		elif not _due.has(b) and not _drawing(b):
			_take_held(b)
			_send(b, 0)


func _on_changed(b: Node) -> void:
	if _applying or not is_instance_valid(b):
		return
	# a kept drawing from this player's own sketchbook: not ours to push
	if int(b.get("showing")) >= 0 and not bool(b.get("drafting")):
		return
	# wait for the stroke to settle, a wipe and a redraw often come together
	_due[b] = SEND_DELAY


func _send(b: Node, pid: int) -> void:
	var strokes: Array = b.get("strokes")
	var h := hash(strokes)
	if pid == 0 and int(_known.get(b.get_instance_id(), 0)) == h:
		return
	_known[b.get_instance_id()] = h
	var raw := var_to_bytes(strokes)
	var packed := raw.compress(FileAccess.COMPRESSION_ZSTD)
	_next += 1
	var id := multiplayer.get_unique_id() * 100000 + _next
	var n := int(ceil(float(packed.size()) / PIECE))
	for i in maxi(n, 1):
		var piece := packed.slice(i * PIECE, mini((i + 1) * PIECE, packed.size()))
		if pid > 0:
			mp._rx_board.rpc_id(pid, _key(b as Node3D), id, i, maxi(n, 1), raw.size(), piece)
		else:
			mp._rx_board.rpc(_key(b as Node3D), id, i, maxi(n, 1), raw.size(), piece)


# Host: a player just came in, show them every board as it is.
func send_all(pid: int) -> void:
	for b in _boards():
		if is_instance_valid(b) and not (b.get("strokes") as Array).is_empty():
			_send(b, pid)


func on_piece(key: String, id: int, i: int, n: int, raw_size: int, piece: PackedByteArray) -> void:
	if n <= 0 or n > 4096 or raw_size <= 0 or raw_size > MAX_RAW:
		return
	var slot := "%s|%d" % [key, id]
	var e: Dictionary = _parts.get(slot, {"n": n, "raw": raw_size, "got": {}})
	(e["got"] as Dictionary)[i] = piece
	_parts[slot] = e
	if (e["got"] as Dictionary).size() < n:
		return
	_parts.erase(slot)
	var packed := PackedByteArray()
	for k in n:
		if not (e["got"] as Dictionary).has(k):
			return
		packed.append_array((e["got"] as Dictionary)[k])
	var strokes: Variant = bytes_to_var(packed.decompress(raw_size, FileAccess.COMPRESSION_ZSTD))
	if not (strokes is Array):
		return
	var b := _board_at(key)
	if b == null:
		return
	# A picture replaces the whole list: our stroke waiting to go out, or the one
	# under our pen, would be gone. Keep it until we are done and then join them.
	if _due.has(b) or _drawing(b):
		_hold[b] = strokes
		return
	_show(b, strokes)


func _show(b: Node, strokes: Array) -> void:
	_known[b.get_instance_id()] = hash(strokes)
	_applying = true
	b.set_picture(strokes)
	_applying = false


func _drawing(b: Node) -> bool:
	if bool(b.get("_was_painting")) or bool(b.get("_was_erasing")):
		return true
	var pen: Variant = b.get("_live")
	if pen is Array or pen is Dictionary:
		return not pen.is_empty()
	return pen != null


# What came meanwhile, plus what we drew that it does not have.
func _take_held(b: Node) -> void:
	var theirs: Array = _hold[b]
	_hold.erase(b)
	var seen := {}
	for stroke in theirs:
		seen[hash(stroke)] = true
	var both: Array = theirs.duplicate()
	for stroke in (b.get("strokes") as Array):
		if not seen.has(hash(stroke)):
			both.append(stroke)
	_show(b, both)
	if both.size() != theirs.size():
		_known.erase(b.get_instance_id())  # so _send tells them about ours


func _board_at(key: String) -> Node:
	var xyz := key.split(",")
	if xyz.size() != 3:
		return null
	var at := Vector3(float(xyz[0]), float(xyz[1]), float(xyz[2]))
	var best: Node = null
	var best_d := KEY_SLACK * KEY_SLACK
	for b in _boards():
		if not is_instance_valid(b) or not (b as Node3D).is_inside_tree():
			continue
		var d := (b as Node3D).global_position.distance_squared_to(at)
		if d < best_d:
			best_d = d
			best = b
	return best
