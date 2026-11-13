# Dev only, never shipped. Two copies of the game on one PC over a local
# connection (no Steam session):
#   MP_SELFTEST=host  hosts save slot 1 (saving blocked) on port 7790
#   MP_SELFTEST=guest joins 127.0.0.1:7790
# Both dump, after the guest has been in the yard a while, every synced value
# (machine fields, yard tables, shared state, rules, day) to
# user://mp_selftest_<role>.txt, then quit. Compare the two files.
extends Node

var mp: Node
var role := ""
const PORT := 7790
const SETTLE := 25.0

func _ready() -> void:
	role = OS.get_environment("MP_SELFTEST")
	await get_tree().create_timer(5.0).timeout
	SaveManager.block_save = true
	if role == "host":
		mp.host(PORT)
		await get_tree().create_timer(1.0).timeout
		SaveManager.block_save = true
		SaveManager.begin_load(1)
		Loading.enter_scene("res://scenes/main.tscn")
		# wait for a guest to be in the yard
		var t := 0.0
		while t < 150.0:
			await get_tree().create_timer(1.0).timeout
			t += 1.0
			SaveManager.block_save = true
			var in_world := false
			for pid in mp.players:
				if int(pid) != 1 and str(mp.players[pid].get("state", "")) == "world":
					in_world = true
			if in_world:
				break
	else:
		await get_tree().create_timer(12.0).timeout  # let the host load first
		mp.join("127.0.0.1", PORT)
		var t := 0.0
		while t < 150.0:
			await get_tree().create_timer(1.0).timeout
			t += 1.0
			if mp.phase == mp.Phase.IN_WORLD and mp.in_world():
				break
	# can the player actually move once in? (players got stuck facing the pile)
	await get_tree().create_timer(3.0).timeout
	_check_move("after join")
	await get_tree().create_timer(SETTLE).timeout
	_dump()
	# phase 2: change things on both sides the way a player would, then compare.
	# The host waits first, so the guest has written its "before" file too.
	if role == "host":
		await get_tree().create_timer(8.0).timeout
	var b: Object = mp.world_sync.world.get("builds")
	var grid: Object = b.get("grid")
	var log := FileAccess.open("user://mp_selftest_%s_actions.txt" % role, FileAccess.WRITE)
	if role == "host":
		var poles: Array = b.get("power_poles")
		if not poles.is_empty() and grid != null:
			var was := bool(grid.call("pole_running", poles[0]))
			grid.call("switch_pole", poles[0], was)
			log.store_line("host: pole 0 running %s -> %s" % [was, grid.call("pole_running", poles[0])])
		var silos: Array = b.get("silos")
		if not silos.is_empty():
			silos[0].call("set_switched_off", not bool(silos[0].get("switched_off")))
			log.store_line("host: silo off -> %s" % silos[0].get("switched_off"))
		var spl: Array = b.get("splitters")
		if not spl.is_empty() and "left_share" in spl[0]:
			spl[0].call("set_left_share", 70)
			log.store_line("host: splitter left_share -> %s" % spl[0].get("left_share"))
		var conv: Array = b.get("conveyors")
		if conv.size() > 2 and b.has_method("reverse_conveyor"):
			var why: Variant = b.call("reverse_blocked_reason", conv[0]) if b.has_method("reverse_blocked_reason") else ""
			b.call("reverse_conveyor", conv[0])
			log.store_line("host: reversed belt 0 (blocked reason: '%s')" % str(why))
	else:
		await get_tree().create_timer(2.0).timeout
		var gconv: Array = b.get("conveyors")
		if gconv.size() > 2 and b.has_method("reverse_conveyor"):
			b.call("reverse_conveyor", gconv[gconv.size() - 1])
			log.store_line("guest: reversed last belt")
		var comps: Array = b.get("compressors")
		if not comps.is_empty():
			comps[0].call("set_switched_off", not bool(comps[0].get("switched_off")))
			log.store_line("guest: compressor 0 off -> %s" % comps[0].get("switched_off"))
		var poles: Array = b.get("power_poles")
		if poles.size() > 1 and grid != null:
			var was := bool(grid.call("pole_running", poles[poles.size() - 1]))
			grid.call("switch_pole", poles[poles.size() - 1], was)
			log.store_line("guest: last pole running %s -> %s" % [was, grid.call("pole_running", poles[poles.size() - 1])])
	log.close()
	await _scanner_test(b)
	if role == "guest":
		await _straw_test()
	await get_tree().create_timer(8.0).timeout
	role = role + "_after"
	_dump()
	role = role.trim_suffix("_after")
	# the host stays until the guest has written its files too
	await get_tree().create_timer(20.0 if role == "host" else 3.0).timeout
	print("[MPSelfTest] %s done" % role)
	get_tree().quit()


# The tube of a scanner drawer must really turn on the other side, not only change its number.
func _scanner_test(b: Object) -> void:
	var list: Array = b.get("scanners")
	if list.is_empty():
		return
	var s: Node = list[0]
	var out := FileAccess.open("user://mp_selftest_%s_scanner.txt" % role, FileAccess.WRITE)
	if role == "guest":
		s.call("set_cannon_yaw", -45.0)
		out.store_line("guest turned tube to -45")
		await get_tree().create_timer(20.0).timeout
	else:
		out.store_line("host sees guest's turn: yaw=%s shown=%s" % [s.get("cannon_yaw"), s.call("cannon_shown_yaw")])
		s.call("set_cannon_yaw", 30.0)
		out.store_line("host turned tube to 30")
		await get_tree().create_timer(10.0).timeout
	out.store_line("%s end: yaw=%s shown=%s" % [role, s.get("cannon_yaw"), s.call("cannon_shown_yaw")])
	out.close()


# GitHub #17: drop straws of ours onto the belt nearest the host's farmer
# (straw is only shared near another player); the host's belts must gain them.
func _straw_test() -> void:
	var out := FileAccess.open("user://mp_selftest_straw.txt", FileAccess.WRITE)
	var ws: Node = mp.world_sync
	var host_av: Variant = ws.avatars.get(1)
	var b: Object = ws.world.get("builds")
	var live: Object = ws.world.get("live")
	if host_av == null or b == null or live == null:
		out.store_line("no host avatar / builds / live")
		out.close()
		return
	var hp: Vector3 = (host_av as Node3D).global_position
	var best: Variant = null
	var best_d := 1e9
	for c in b.get("conveyors"):
		if c is Node3D and is_instance_valid(c) and "a" in c and "b" in c:
			var mid: Vector3 = ((c.get("a") as Vector3) + (c.get("b") as Vector3)) * 0.5
			var d := mid.distance_to(hp)
			if d < best_d:
				best_d = d
				best = c
	if best == null:
		out.store_line("no conveyor")
		out.close()
		return
	var mid: Vector3 = ((best.get("a") as Vector3) + (best.get("b") as Vector3)) * 0.5
	out.store_line("belt %.1f m from host, at %v" % [best_d, mid])
	for i in 15:
		live.call("spawn", mid + Vector3(randf_range(-0.2, 0.2), 0.6, randf_range(-0.2, 0.2)),
			Basis(), Vector3.ZERO, Color(0.86, 0.74, 0.4), false)
		await get_tree().create_timer(0.15).timeout
	await get_tree().create_timer(4.0).timeout
	out.store_line("guest: straws tracked %d, waiting belt checks %d" % [ws.strands_sync._mine.size(), ws.strands_sync._belt_check.size()])
	out.close()


func _check_move(when: String) -> void:
	var out := FileAccess.open("user://mp_selftest_%s_move.txt" % role, FileAccess.WRITE)
	var ws: Node = mp.world_sync
	var pl: Node3D = ws.player if ws != null else null
	out.store_line("%s: paused=%s mouse_mode=%d chat=%s panel=%s" % [when, get_tree().paused,
		Input.mouse_mode, mp.ui._chat_box.visible, mp.ui._root.visible])
	if pl == null:
		out.store_line("no player")
		out.close()
		return
	for m in ["_accepts_input", "_accepts_move", "menu_is_up", "is_mouse_captured", "escape_is_taken"]:
		if pl.has_method(m):
			out.store_line("  %s() = %s" % [m, pl.call(m)])
	out.store_line("  process_mode=%d physics=%s can_process=%s pos=%v" % [pl.process_mode,
		pl.is_physics_processing(), pl.can_process(), pl.global_position])
	var cs := get_tree().current_scene
	for n in ["pause_menu", "hud", "intro"]:
		var v: Variant = cs.get(n) if cs != null else null
		if v is Node:
			out.store_line("  world.%s visible=%s" % [n, (v as Node).get("visible")])
	var p0 := pl.global_position
	Input.action_press("move_forward")
	await get_tree().create_timer(1.5).timeout
	Input.action_release("move_forward")
	out.store_line("  walked %.2f m in 1.5 s" % p0.distance_to(pl.global_position))
	out.close()


func _dump() -> void:
	var out := FileAccess.open("user://mp_selftest_%s.txt" % role, FileAccess.WRITE)
	out.store_line("role %s phase %d players %d" % [role, mp.phase, mp.players.size()])
	var ws: Node = mp.world_sync
	if ws == null:
		out.store_line("NO WORLD SYNC")
		out.close()
		return
	var ms: Node = ws.machines_sync
	if ms != null:
		ms._rescan()
		var keys: Array = ms._nodes.keys()
		keys.sort()
		out.store_line("machines %d" % keys.size())
		for key in keys:
			var n: Node = ms._nodes[key]
			if n == null or not is_instance_valid(n):
				continue
			var parts: Array = []
			for f in ms._fields_of(String(ms._group.get(key, ""))):
				var v: Variant = ms._get_field(n, f)
				if v != null:
					parts.append("%s=%s" % [f, _fmt(v)])
			out.store_line("M %s :: %s" % [key, " ; ".join(parts)])
	var tb: Node = ws.tables_sync
	if tb != null:
		for name in tb.TABLES:
			var d: Variant = tb._dict_of(name)
			out.store_line("T %s :: %s" % [name, str(d.hash()) if d is Dictionary else "none"])
	for f in ws.ADD_F + ws.HOST_ABS + ws.HOST_MAX + ws.ADD_D:
		out.store_line("S %s :: %s" % [f, _fmt(GameState.get(f))])
	out.store_line("R :: %s" % str(mp.host_rules()))
	var dc: Node = ws._day_cycle()
	if dc != null:
		out.store_line("D hour %.2f" % float(dc.call("hour")))
	var b: Object = ws.world.get("builds")
	out.store_line("B buildings %d" % (b.to_array().size() if b != null else -1))
	# every building's own data, per type, without values that run on their own
	if b != null:
		var by_type := {}
		var skip := ["stored", "fuel", "queued", "jam", "charge", "next_side", "needles",
			"pending_needles", "queued_needles", "running_needle", "parts", "pose", "load",
			"dug", "trips", "takes", "takes_v", "banked", "loads", "cannon_queue", "iron",
			"copper", "taps", "run", "out_left", "out_strands", "out_worth", "cycle_needles",
			"cycle_duration", "cycle_makes", "port_last", "tank", "paid", "empty_kinds", "rate"]
		for d in b.to_array():
			if not (d is Dictionary):
				continue
			var parts: Array = []
			var keys: Array = (d as Dictionary).keys()
			keys.sort()
			for k in keys:
				if not skip.has(k):
					parts.append("%s=%s" % [k, _fmt(d[k])])
			var ty := str(d.get("type", "?"))
			if not by_type.has(ty):
				by_type[ty] = []
			(by_type[ty] as Array).append(";".join(parts))
		var types: Array = by_type.keys()
		types.sort()
		var rows_file := FileAccess.open("user://mp_selftest_%s_rows.txt" % role, FileAccess.WRITE)
		for ty in types:
			var rows: Array = by_type[ty]
			rows.sort()
			out.store_line("BD %s n=%d hash=%d" % [ty, rows.size(), "|".join(rows).hash()])
			for r in rows:
				rows_file.store_line("%s :: %s" % [ty, r])
		rows_file.close()
	for k in ["pile_size_id", "shed_long_bays", "shed_grid", "stand_spot", "FIELD_EXTENT",
			"PILE_RADIUS", "PILE_HEIGHT", "PILE_FOOTPRINT"]:
		out.store_line("CFG %s = %s" % [k, str(Cfg.get(k))])
	var pm: Variant = ws.world.get("props")
	out.store_line("PROPS %d" % ((pm.get("items") as Array).size() if pm != null else -1))
	var strands := 0
	for belt in BeltPath._live:
		if is_instance_valid(belt) and belt.has_method("strand_load"):
			strands += int(belt.call("strand_load"))
	out.store_line("BELT straws on belts %d" % strands)
	out.close()


func _fmt(v: Variant) -> String:
	if typeof(v) == TYPE_FLOAT:
		return "%.2f" % v
	return str(v).substr(0, 160)
