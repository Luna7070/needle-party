extends Node

# The full game keeps several yard-wide tables next to the buildings:
#   machine_paint  colours painted on machines
#   tags           power tags (names, colours, which machine is in which,
#                  start order)
#   routes         named splitter routes
#   clocks         machine clocks
#   plugs          which machine is pinned/unplugged from which pole
#   groups         blueprint groups
# None of them is in a building's own data, so the building sync never carried
# them: a guest joined to unpainted machines, no tags and no routes, and an
# edit on either side stayed on that side. Each table can write itself out
# (to_dict) and read itself back (from_dict + resolve), and it records
# machines by where they stand, so the same data works on every PC.
#
# Every TICK each player looks for a table that changed. A guest sends it to
# the host; the host applies it and passes it on to everyone, so the host is
# the referee when two players edit at the same moment. A guest that joins
# gets every table from the host.

const TABLES := ["machine_paint", "tags", "routes", "clocks", "plugs", "groups",
	# GameState settings either player can change: the depot's per-item limits
	# and the items it refuses
	"gs:depot_limits", "gs:depot_refused",
	# (1.2.21) game update 13 Nov 2026: the depot's per-item "no drones" switch
	"gs:depot_no_drones",
	# game 15.x: the same settings, but each depot keeps its own (Depot.limits,
	# Depot.refused). Only one of the two pairs exists in a given game build;
	# the other reads as null and is skipped.
	"depots",
	# the hay market (Buyers: prices that fall as hay is sold and recover over
	# time). It ran on every PC, so prices drifted apart. Host -> guests only.
	"market"]
const HOST_ONLY := ["market"]
const MARKET_PATH := "res://scripts/world/buyers.gd"
const MARKET_TICK := 4.0
const TICK := 0.5
var _market_t := 0.0
var _market: Script = null
var _market_tried := false

var mp: Node
var world: Node
var builds: Object
var _hash := {}      # table -> hash of what we last sent or applied
var _waiting := {}   # table -> [sender, data] that came while buildings were loading
var _market_seen := {}  # guest: the market's sold counts as we last looked
var _own_sent := {}  # guest: table -> [hash, msec]: sent, and the host has not said it back
var _held_back := {} # guest: table -> what the host said in the meantime
const OWN_MS := 2000
var _t := 0.0
var _applying := false
const FrameSlots = preload("mp_frame_slots.gd")
var _slot := FrameSlots.new()


func start(mp_node: Node, world_node: Node) -> void:
	mp = mp_node
	world = world_node
	builds = world.get("builds")
	_rebaseline()
	_note_market()


func _table(name: String) -> Object:
	if builds == null or not is_instance_valid(builds):
		return null
	var t: Variant = builds.get(name)
	if t is Object and (t as Object).has_method("to_dict") and (t as Object).has_method("from_dict"):
		return t
	return null


func _dict_of(name: String) -> Variant:
	if name.begins_with("gs:"):
		var v: Variant = GameState.get(name.substr(3))
		if v is Dictionary:
			return (v as Dictionary).duplicate(true)
		if v is Array:
			return {"list": (v as Array).duplicate(true)}
		return null
	if name == "market":
		var m := _market_script()
		if m == null:
			return null
		var md: Variant = m.call("to_dict")
		return md if md is Dictionary else null
	if name == "depots":
		return _depots_dict()
	var t := _table(name)
	if t == null:
		return null
	var d: Variant = t.call("to_dict")
	return d if d is Dictionary else null


# Buyers keeps its state in static variables: its static to_dict/from_dict
# are called on the script itself.
func _market_script() -> Script:
	if not _market_tried:
		_market_tried = true
		if ResourceLoader.exists(MARKET_PATH):
			var s: Script = load(MARKET_PATH)
			if s != null:
				var names := {}
				for m in s.get_script_method_list():
					names[m["name"]] = true
				if names.has("to_dict") and names.has("from_dict"):
					_market = s
	return _market


func _apply_special(name: String, data: Dictionary) -> bool:
	if name.begins_with("gs:"):
		var f := name.substr(3)
		var cur: Variant = GameState.get(f)
		if cur is Dictionary:
			(cur as Dictionary).clear()
			(cur as Dictionary).merge(data, true)
		elif cur is Array and data.get("list") is Array:
			(cur as Array).assign(data["list"])
		else:
			return true
		if GameState.has_signal("depot_changed"):
			GameState.depot_changed.emit()
		return true
	if name == "market":
		var m := _market_script()
		if m != null:
			m.call("from_dict", data)
			if GameState.has_signal("buyers_changed"):
				GameState.buyers_changed.emit()
			_note_market()
		return true
	if name == "depots":
		_apply_depots(data)
		return true
	return false


# ------------------------------------------------------------ depots (game 15.x)
# Each depot's item limits and refused items, by where the depot stands:
#   {"x,y,z": {"l": {item: n}, "r": [item, ...]}}
# Sorted, so the same settings give the same hash on every PC. A depot the
# others name but that is not built here yet waits in _depot_wait and is
# counted as it is, so this PC does not send the table back without it.
const DEPOT_LISTS := ["wrappers", "depots"]
var _depot_wait := {}

func _depot_nodes() -> Dictionary:
	var out := {}
	if builds == null or not is_instance_valid(builds):
		return out
	for list in DEPOT_LISTS:
		var arr: Variant = builds.get(list)
		if not (arr is Array):
			continue
		for n in arr:
			if n is Node and is_instance_valid(n) and n.is_inside_tree() and n.has_method("set_limit") \
			and n.has_method("set_refused") and n.get("limits") is Dictionary and n.get("refused") is Dictionary:
				# snapped, and +0.0 so -0.0 and 0.0 give the same key on every PC
				var p: Vector3 = (n as Node3D).global_position
				out["%.1f,%.1f,%.1f" % [snappedf(p.x, 0.1) + 0.0, snappedf(p.y, 0.1) + 0.0, snappedf(p.z, 0.1) + 0.0]] = n
	return out


func _depot_rules(n: Node) -> Dictionary:
	var lim: Dictionary = n.get("limits")
	var ref: Dictionary = n.get("refused")
	var l := {}
	var by_name := {}
	for id in lim:
		by_name[str(id)] = id
	var ids: Array = by_name.keys()
	ids.sort()  # as Strings: StringNames would sort differently on each PC
	for id in ids:
		l[id] = int(lim[by_name[id]])
	var r: Array = []
	for id in ref:
		if bool(ref[id]):
			r.append(str(id))
	r.sort()
	return {"l": l, "r": r}


func _depots_dict() -> Variant:
	var nodes := _depot_nodes()
	if nodes.is_empty() and _depot_wait.is_empty():
		# no depot here, or a game build whose depots have no limits of their own
		return null if not _depots_exist() else {}
	var all := {}
	for k in nodes:
		var rules := _depot_rules(nodes[k])
		if not (rules["l"] as Dictionary).is_empty() or not (rules["r"] as Array).is_empty():
			all[k] = rules
	for k in _depot_wait:
		if not nodes.has(k):
			all[k] = _depot_wait[k]
	var keys: Array = all.keys()
	keys.sort()
	var out := {}
	for k in keys:
		out[k] = all[k]
	return out


# Does this game build keep limits on the depots at all? (game 15.x)
var _depots_known: Variant = null

func _depots_exist() -> bool:
	if _depots_known == null:
		var s: Variant = load("res://scripts/build/depot.gd") if ResourceLoader.exists("res://scripts/build/depot.gd") else null
		var has := false
		if s is Script:
			for m in (s as Script).get_script_method_list():
				if m["name"] == "set_limit":
					has = true
					break
		_depots_known = has
	return bool(_depots_known)


func _apply_depots(data: Dictionary) -> void:
	var nodes := _depot_nodes()
	_depot_wait.clear()
	for k in data:
		if not nodes.has(k) and data[k] is Dictionary:
			_depot_wait[k] = data[k]
	for k in nodes:
		var want: Dictionary = data.get(k, {}) if data.get(k) is Dictionary else {}
		_set_depot(nodes[k], want)
	if GameState.has_signal("depot_changed"):
		GameState.depot_changed.emit()


func _set_depot(n: Node, want: Dictionary) -> void:
	var have := _depot_rules(n)
	var wl: Dictionary = want.get("l", {}) if want.get("l") is Dictionary else {}
	var wr: Array = want.get("r", []) if want.get("r") is Array else []
	for id in (have["l"] as Dictionary):
		if not wl.has(id):
			n.call("set_limit", id, -1)  # -1: no limit (the game's own way to clear one)
	for id in wl:
		if int((have["l"] as Dictionary).get(id, -2)) != int(wl[id]):
			n.call("set_limit", id, int(wl[id]))
	for id in (have["r"] as Array):
		if not wr.has(id):
			n.call("set_refused", id, false)
	for id in wr:
		if not (have["r"] as Array).has(id):
			n.call("set_refused", id, true)


# A depot that was named before it was built here: give it its settings now.
func _resolve_depots() -> void:
	if _depot_wait.is_empty():
		return
	var nodes := _depot_nodes()
	var done := false
	for k in _depot_wait.keys():
		if nodes.has(k):
			_set_depot(nodes[k], _depot_wait[k])
			_depot_wait.erase(k)
			done = true
	if done and GameState.has_signal("depot_changed"):
		GameState.depot_changed.emit()


func _rebaseline() -> void:
	for name in TABLES:
		var d: Variant = _dict_of(name)
		if d != null:
			_hash[name] = (d as Dictionary).hash()
			if name == "clocks":
				_clock_agreed = _clock_rows(d)


# stopwatch: anything over 4 ms in one frame goes into mp_trace.log by name
func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_process_inner(delta)
	if mp != null and is_instance_valid(mp):
		mp.perf("tables", Time.get_ticks_usec() - t0)


func _process_inner(delta: float) -> void:
	if mp == null or not mp.active() or multiplayer.multiplayer_peer == null:
		return
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	_market_t += delta
	_t += delta
	if _t < TICK or not _slot.take():
		return
	_t = 0.0
	# clocks and paint are swapped for empty stand-ins while buildings load (see
	# mp_world._add_buildings) and the machines are parked: not now
	if _buildings_loading():
		return
	for name in _waiting.keys():
		var w: Array = _waiting[name]
		_waiting.erase(name)
		on_table(int(w[0]), String(name), w[1])
	_release_held_back()
	_resolve_depots()
	if not mp.is_host:
		_send_market_sales()
	for name in TABLES:
		if HOST_ONLY.has(name):
			# the market moves every few seconds on its own: only the host
			# sends it, and only every MARKET_TICK
			if not mp.is_host or _market_t < MARKET_TICK:
				continue
			_market_t = 0.0
		var d: Variant = _dict_of(name)
		if d == null:
			continue
		var h: int = (d as Dictionary).hash()
		if int(_hash.get(name, 0)) == h:
			continue
		_hash[name] = h
		if name == "clocks":
			_clock_agreed = _clock_rows(d)
		_note_table("changed here", name, d)
		if mp.is_host:
			mp._rx_table.rpc(name, d)
		else:
			_own_sent[name] = [h, Time.get_ticks_msec()]
			mp._rx_table.rpc_id(1, name, d)


# The small tables the players edit by hand: what went where, in the log.
func _note_table(what: String, name: String, data: Variant) -> void:
	if name.begins_with("gs:") or name == "depots":
		mp.trace.note("table %s %s: %s" % [name, what, str(data).substr(0, 160)])


# Guest. Dragging a slider sends a few values in a row, and the host says each of them
# back. An older one coming back overwrote what the player had just set, and the slider
# jumped under their hand. Wait for our last word to come back; if something else comes
# instead, somebody else changed it too, and after a moment the host's word counts.
func _release_held_back() -> void:
	for name in _own_sent.keys():
		if Time.get_ticks_msec() - int(_own_sent[name][1]) < OWN_MS:
			continue
		_own_sent.erase(name)
		var w: Variant = _held_back.get(name)
		if w != null:
			_held_back.erase(name)
			on_table(int(w[0]), String(name), w[1])


# Host: everything, to a guest that just came in.
func send_all(pid: int) -> void:
	for name in TABLES:
		var d: Variant = _dict_of(name)
		if d != null:
			mp._rx_table.rpc_id(pid, name, d)


func _buildings_loading() -> bool:
	var ws: Variant = mp.world_sync if mp != null else null
	return ws != null and is_instance_valid(ws) and bool(ws.get("_applying_builds"))


# Guest: the market moves on the host, so a sale here only lowered our own prices
# until the next update put them back, and everybody could keep selling at the
# old price. What we sold since we last looked goes to the host. Sold counts only
# ever fall by themselves, so a rise is a sale.
const MARKET_EPS := 0.000001

func _send_market_sales() -> void:
	var m := _market_script()
	if m == null:
		return
	var d: Variant = m.call("to_dict")
	if not (d is Dictionary) or not ((d as Dictionary).get("sold") is Dictionary):
		return
	var sold: Dictionary = d["sold"]
	var more := {}
	for id in sold:
		var up: float = float(sold[id]) - float(_market_seen.get(id, 0.0))
		if up > MARKET_EPS:
			more[id] = up
	_market_seen = sold.duplicate()
	if not more.is_empty():
		mp._rx_market_sale.rpc_id(1, more, (d as Dictionary).get("ever", []), (d as Dictionary).get("flat_ever", []))


func _note_market() -> void:
	var m := _market_script()
	if m == null:
		return
	var d: Variant = m.call("to_dict")
	if d is Dictionary and (d as Dictionary).get("sold") is Dictionary:
		_market_seen = ((d as Dictionary)["sold"] as Dictionary).duplicate()


# Host: a guest's sale counts on the real market; everyone hears on the next update.
func on_market_sale(sold: Dictionary, ever: Array, flat_ever: Array) -> void:
	var m := _market_script()
	if m == null:
		return
	var d: Variant = m.call("to_dict")
	if not (d is Dictionary) or not ((d as Dictionary).get("sold") is Dictionary):
		return
	var ours: Dictionary = d["sold"]
	for id in sold:
		ours[id] = float(ours.get(id, 0.0)) + maxf(0.0, float(sold[id]))
	for pair in [["ever", ever], ["flat_ever", flat_ever]]:
		var list: Variant = (d as Dictionary).get(pair[0])
		if list is Array:
			for id in pair[1]:
				if not (list as Array).has(id):
					(list as Array).append(id)
	m.call("from_dict", d)
	if GameState.has_signal("buyers_changed"):
		GameState.buyers_changed.emit()
	_market_t = MARKET_TICK


func on_table(sender: int, name: String, data: Dictionary) -> void:
	if not TABLES.has(name):
		return
	if not mp.is_host and sender != 1:
		return  # guests only take tables from the host
	if mp.is_host and HOST_ONLY.has(name):
		return  # the host's market is the real one
	if _buildings_loading():
		_waiting[name] = [sender, data]
		return
	if not mp.is_host and _own_sent.has(name):
		if (data as Dictionary).hash() == int(_own_sent[name][0]):
			_own_sent.erase(name)
			_held_back.erase(name)
		else:
			_held_back[name] = [sender, data]
			return
	if (data as Dictionary).hash() == int(_hash.get(name, 0)):
		return
	_note_table("from %d" % sender, name, data)
	if _apply_special(name, data):
		var after: Variant = _dict_of(name)
		_hash[name] = (after as Dictionary).hash() if after is Dictionary else data.hash()
		if mp.is_host and sender != 1:
			mp._rx_table.rpc(name, after if after is Dictionary else data)
		return
	var t := _table(name)
	if t == null:
		return
	_applying = true
	# start from empty so removed entries go too; never for clocks, whose
	# reset can hand inserted needles back out (that would duplicate them)
	if name != "clocks" and t.has_method("reset"):
		t.call("reset")
	var gone: Array = _clock_gone(data) if name == "clocks" else []
	t.call("from_dict", data)
	if t.has_method("resolve"):
		t.call("resolve")
	if name == "clocks":
		_match_clocks(t, gone)
	# paint has to be put back on every machine it now names (and taken off
	# the ones it no longer does)
	if name == "machine_paint" and t.has_method("reapply"):
		for m in _machines():
			t.call("reapply", m)
	if t.has_signal("changed"):
		t.emit_signal("changed")
	_applying = false
	# what the table holds now, after the game's own tidying, is the agreed
	# state: remember it so it is not sent straight back
	var now: Variant = _dict_of(name)
	_hash[name] = (now as Dictionary).hash() if now is Dictionary else data.hash()
	if name == "clocks" and now is Dictionary:
		_clock_agreed = _clock_rows(now)
	if mp.is_host and sender != 1:
		# pass a guest's edit on to everybody, the guest included (harmless:
		# same hash) so nobody keeps an old copy
		mp._rx_table.rpc(name, now if now is Dictionary else data)


# Clocks are read in without a reset (see on_table). A machine set back to 100% somewhere
# else has no row any more, and from_dict only touches the machines it has rows for, so
# here it kept its old clock: a pulper ran at 1% on the host and at 100% on the guest.
# Rows are [where the machine stands, clock, needles, ...]. Only a row that both sides
# had (the last table sent or taken here) and that is now gone counts as "set back to
# 100%": a machine this PC set on its own, or one the other side never heard of, is
# left alone. Never touches needles: a machine without a row has none.
const CLOCK_EPS := 0.0001
const CLOCK_AT := 0.01  # metres: same machine
var _clock_agreed: Array = []  # where the rows of the last agreed clocks table stand

func _clock_rows(d: Variant) -> Array:
	var out: Array = []
	if d is Dictionary and (d as Dictionary).get("rows") is Array:
		for row in d["rows"]:
			if row is Array and not (row as Array).is_empty() and row[0] is Vector3:
				out.append(row[0])
	return out


# The agreed rows that the incoming table no longer has.
func _clock_gone(data: Dictionary) -> Array:
	var rows: Variant = data.get("rows")
	if not (rows is Array):
		return []
	var named := _clock_rows(data)
	if named.size() != (rows as Array).size():
		return []  # rows of a shape we do not know: take nothing away
	var gone: Array = []
	for at in _clock_agreed:
		var still := false
		for p in named:
			if (p as Vector3).distance_to(at) < CLOCK_AT:
				still = true
				break
		if not still:
			gone.append(at)
	return gone


func _match_clocks(t: Object, gone: Array) -> void:
	if gone.is_empty() or not t.has_method("clockable") or not t.has_method("clock_of") or not t.has_method("set_clock"):
		return
	for m in _machines():
		if not (m is Node3D) or not m.is_inside_tree():
			continue
		var p: Vector3 = (m as Node3D).global_position
		var hit := false
		for at in gone:
			if (at as Vector3).distance_to(p) < CLOCK_AT:
				hit = true
				break
		if not hit or not bool(t.call("clockable", m)):
			continue
		if absf(float(t.call("clock_of", m)) - 1.0) > CLOCK_EPS:
			mp.trace.note("clock back to 100%% on %s (set back on the other side)" % m.name)
			t.call("set_clock", m, 1.0)


func _machines() -> Array:
	var out: Array = []
	var ws: Node = mp.world_sync
	if ws == null:
		return out
	var groups: Array = ws.get_script().get_script_constant_map().get("BUILD_ARRAYS", [])
	for group in groups:
		var arr: Variant = builds.get(group)
		if arr is Array:
			for n in arr:
				if n is Node and is_instance_valid(n):
					out.append(n)
	return out
