extends Node
# Two copies, real connection, real game calls. Run as mods/needle_party/mp_selftest.gd
# MP_SELFTEST=host|guest, MP_SYNC=<folder>. Results: <folder>/out_<role>.txt,
# everything on every machine: <folder>/dump_<role>_<tag>.txt
var mp: Node
var role := ""
var o: FileAccess
var dir := ""
const PORT := 7792

func w(s) -> void:
	o.store_line(str(s)); o.flush()

func mark(x: String) -> void:
	FileAccess.open(dir + "/" + role + "_" + x, FileAccess.WRITE).store_string("1")

func put(x: String, v: Variant) -> void:
	FileAccess.open(dir + "/val_" + x, FileAccess.WRITE).store_var(v)
	mark("val_" + x)

func grab(x: String) -> Variant:
	await wait_for("val_" + x)
	return FileAccess.open(dir + "/val_" + x, FileAccess.READ).get_var()

func wait_for(x: String, limit := 90.0) -> void:
	var other := "guest" if role == "host" else "host"
	var t := 0.0
	while t < limit and not FileAccess.file_exists(dir + "/" + other + "_" + x):
		await get_tree().create_timer(0.1).timeout
		t += 0.1
	if t >= limit:
		w("TIMEOUT waiting " + x)

func both(x: String) -> void:
	mark(x)
	await wait_for(x)

func sleep(s: float) -> void:
	await get_tree().create_timer(s).timeout

func frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

var world: Node
var b: Object
var grid: Object
var clocks: Object
var paint: Object
var props: Node
var ps: Node
var pl: Node3D
var carry: Object
var cam: Camera3D
var ms: Node
var machine_power: Script
var made_here: Array = []

const PRIM := [TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_STRING_NAME, TYPE_VECTOR3, TYPE_COLOR, TYPE_VECTOR2]
var GETTER := RegEx.create_from_string("^(is_|has_|can_)|(_kw|_rate|_progress|_fraction|_seconds|_time|_capacity|_reason|_text|_line|_left|_id|_level|_shown)$")
var SKIP := RegEx.create_from_string("^_|set_|start|stop|take|drop|clear|add|remove|reset|make|build|spawn|preview|ghost|shot|^has_method|^is_inside|^can_process")

func val(v: Variant) -> Variant:
	var t := typeof(v)
	if t in PRIM:
		return str(v)
	if t == TYPE_ARRAY or t == TYPE_PACKED_INT32_ARRAY or t == TYPE_PACKED_FLOAT32_ARRAY or t == TYPE_PACKED_VECTOR3_ARRAY:
		return str(v) if v.size() <= 12 else "size=%d" % v.size()
	if t == TYPE_DICTIONARY:
		return str(v) if (v as Dictionary).size() <= 12 else "size=%d" % (v as Dictionary).size()
	return null

func dump_all(tag: String) -> void:
	var f := FileAccess.open("%s/dump_%s_%s.txt" % [dir, role, tag], FileAccess.WRITE)
	var gm := {}
	for m in grid.call("machines"):
		gm[m] = true
	for key in ms.get("_nodes"):
		var n: Variant = ms.get("_nodes")[key]
		if n == null or not is_instance_valid(n):
			continue
		var s: Script = n.get_script()
		if s == null:
			continue
		var row := {"key": str(key), "cls": str(s.get_global_name())}
		for p in s.get_script_property_list():
			if int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE:
				var name: String = p["name"]
				if name.begins_with("@"):
					continue
				var v: Variant = val(n.get(name))
				if v != null:
					row["v." + name] = v
		for m in s.get_script_method_list():
			var name: String = m["name"]
			if (m["args"] as Array).size() != int((m["default_args"] as Array).size()):
				continue
			if GETTER.search(name) == null or SKIP.search(name) != null:
				continue
			var v: Variant = val(n.call(name))
			if v != null:
				row["g." + name] = v
		if n is Node3D:
			var seen := 0
			for mi in (n as Node).find_children("*", "MeshInstance3D", true, false):
				if seen >= 40:
					break
				var rid: RID = (mi as MeshInstance3D).get_instance()
				if not rid.is_valid():
					continue
				for sp in RenderingServer.instance_geometry_get_shader_parameter_list(rid):
					var sv: Variant = RenderingServer.instance_geometry_get_shader_parameter(rid, sp["name"])
					row["s.%s.%s" % [mi.name, sp["name"]]] = str(sv)
					seen += 1
		if gm.has(n):
			row["p.share"] = str(machine_power.call("power_share", n, grid))
			row["p.line"] = str(machine_power.call("rating_line", n, grid))
			row["p.clock"] = str(clocks.call("clock_of", n))
			var rep: Dictionary = grid.call("report", n)
			for k in ["supply", "demand", "could", "satisfaction", "share", "machines", "poles", "connected"]:
				row["p.report." + k] = str(rep.get(k))
		f.store_line(JSON.stringify(row))
	# shared things
	var g := {"key": "GLOBAL", "cls": "GLOBAL"}
	for p in GameState.get_script().get_script_property_list():
		if int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE:
			var v: Variant = val(GameState.get(p["name"]))
			if v != null:
				g["gs." + str(p["name"])] = v
	g["depot"] = str(GameState.depot_stock)
	g["ranks"] = str(Tech.ranks)
	for t in ["clocks", "machine_paint", "tags", "routes", "plugs", "groups"]:
		g["table." + t] = str(b.get(t).call("to_dict")).substr(0, 500)
	g["market.sold"] = str(Buyers.to_dict().get("sold")).substr(0, 300)
	var counts := {}
	for it in props.items:
		if is_instance_valid(it):
			var id := String(it.item_id)
			counts[id] = int(counts.get(id, 0)) + 1
	var keys := counts.keys()
	keys.sort()
	for k in keys:
		g["items." + str(k)] = str(counts[k])
	var rows := 0
	for e in BeltPath.belts_to_array():
		rows += (e.get("records", []) as Array).size()
	g["belts.rows"] = str(rows)
	var tr: Node = world.get("truck")
	g["truck.shown"] = str(tr.call("load_shown"))
	g["truck.state"] = str(tr.get("state"))
	f.store_line(JSON.stringify(g))
	f.close()

func entry_key(e: Dictionary) -> String:
	return "%s|%s" % [str(e.get("a")), str(e.get("b"))]

func rows_of(k: String) -> int:
	for e in BeltPath.belts_to_array():
		if entry_key(e) == k:
			return (e.get("records", []) as Array).size()
	return -1

func loose(id: String) -> int:
	var n := 0
	for it in props.items:
		if is_instance_valid(it) and String(it.item_id) == id:
			n += 1
	return n

func aim_at(at: Vector3) -> bool:
	for az in 8:
		var dir2 := Vector3(cos(az * TAU / 8.0), 0, sin(az * TAU / 8.0))
		for r in [0.8, 1.2, 0.6]:
			pl.global_position = Vector3(at.x, at.y - 0.43, at.z) + dir2 * float(r)
			pl.set("velocity", Vector3.ZERO)
			await get_tree().physics_frame
			pl.global_position = Vector3(at.x, at.y - 0.43, at.z) + dir2 * float(r)
			cam.look_at(at)
			await get_tree().physics_frame
			await get_tree().process_frame
			if not (carry.call("_record_under_crosshair") as Dictionary).is_empty():
				return true
	return false

func add_everywhere(d: Dictionary) -> void:
	mp._rx_builds.rpc([d], [])
	await mp.world_sync.on_builds([d], [])

func one_of(list: String) -> Node:
	var arr: Variant = b.get(list)
	if arr is Array and not (arr as Array).is_empty():
		var last: Variant = (arr as Array).back()
		if is_instance_valid(last):
			return last
	return null

func _ready() -> void:
	role = OS.get_environment("MP_SELFTEST")
	dir = OS.get_environment("MP_SYNC")
	o = FileAccess.open(dir + "/out_" + role + ".txt", FileAccess.WRITE)
	await sleep(5.0)
	SaveManager.block_save = true
	if role == "host":
		mp.host(PORT)
		await sleep(1.0)
		SaveManager.block_save = true
		SaveManager.begin_load(1)
		Loading.enter_scene("res://scenes/main.tscn")
		var t := 0.0
		while t < 240.0:
			await sleep(1.0)
			t += 1.0
			SaveManager.block_save = true
			var ok := false
			for pid in mp.players:
				if int(pid) != 1 and str(mp.players[pid].get("state", "")) == "world":
					ok = true
			if ok:
				break
		w("guest in world after %s" % t)
	else:
		await sleep(30.0)
		mp.join("127.0.0.1", PORT)
		var t := 0.0
		while t < 220.0:
			await sleep(1.0)
			t += 1.0
			if mp.phase == mp.Phase.IN_WORLD and mp.in_world():
				break
		w("in world after %s phase=%s" % [t, mp.phase])
	await sleep(15.0)
	await both("ready")
	world = mp.world_sync.world
	b = world.get("builds")
	grid = b.get("grid")
	clocks = b.get("clocks")
	paint = b.get("machine_paint")
	props = world.get("props")
	ps = mp.world_sync.get("props_sync")
	pl = world.get("player")
	carry = pl.get("carry")
	cam = pl.get("camera")
	ms = mp.world_sync.get("machines_sync")
	machine_power = load("res://scripts/build/machine_power.gd")
	var home: Vector3 = pl.global_position
	w("VERSION %s" % mp.VERSION)
	if role == "guest":
		var stopped := 0
		var fc: Node = mp.world_sync.call("_factory_clock")
		for m in grid.call("machines"):
			if is_instance_valid(m) and fc.call("is_machine", m) and not fc.call("machine_on", m):
				stopped += 1
		w("T0 guest machines stopped on the clock=%d census=%s" % [stopped, fc.call("machine_census")])
		props.item_added.connect(func(it: Node) -> void:
			if not bool(ps.get("_busy")):
				made_here.append("%.1f %s at %s" % [float(Time.get_ticks_msec()) / 1000.0, it.item_id, (it as Node3D).global_position])
		)
	w("T0 income: per_min=%s log=%s yard=%s" % [GameState.call("income_per_minute"), str(GameState.get("_income_log")).substr(0, 90), YardClock.seconds()])

	# ---- machines as they stand, before anyone touches anything
	dump_all("settled")
	await both("d0")
	# the same standing among the machines, where the panels are read
	var sum := Vector3.ZERO
	var cnt := 0
	for m in grid.call("machines"):
		if is_instance_valid(m):
			sum += (m as Node3D).global_position
			cnt += 1
	pl.global_position = sum / maxf(1.0, float(cnt)) + Vector3(2.0 if role == "host" else -2.0, 1.0, 0.0)
	pl.set("velocity", Vector3.ZERO)
	await sleep(6.0)
	dump_all("near")
	await both("d1")
	pl.global_position = home
	pl.set("velocity", Vector3.ZERO)
	await sleep(1.0)

	# ---- T1 the Fabricator from the screenshots
	var fab: Node = null
	for m in grid.call("machines"):
		if is_instance_valid(m) and m.get_script() and String(m.get_script().get_global_name()) == "Fabricator":
			if fab == null or (m as Node3D).global_position.x < fab.global_position.x:
				fab = m
	if role == "host":
		clocks.call("set_clock", fab, 0.94)
		paint.call("set_swatch", fab, 1)
	await sleep(4.0)
	var rep: Dictionary = grid.call("report", fab)
	w("T1 clock=%s swatch=%s draw=%.2f power=%.2f supply=%.2f demand=%.2f could=%.0f sat=%.3f line=%s" % [clocks.call("clock_of", fab), paint.call("swatch_of", fab), fab.call("draw_kw"), fab.get("power"), rep.get("supply"), rep.get("demand"), rep.get("could"), rep.get("satisfaction"), machine_power.call("rating_line", fab, grid)])
	dump_all("clock")
	await both("t1")

	# ---- T1b the screenshots: generators nearly at their limit, clocks turned down to fit
	var gens: Array = b.get("generators")
	if role == "host":
		for i in gens.size():
			if i >= 5:
				gens[i].call("set_switched_off", true)
		var n := 0
		for m in grid.call("machines"):
			if n < 12 and clocks.call("clockable", m):
				clocks.call("set_clock", m, 0.9)
				n += 1
	await sleep(4.0)
	rep = grid.call("report", fab)
	w("T1b %s tight line: supply=%.2f demand=%.2f could=%.0f sat=%.3f fab power=%.3f line=%s" % [role, rep.get("supply"), rep.get("demand"), rep.get("could"), rep.get("satisfaction"), fab.get("power"), machine_power.call("rating_line", fab, grid)])
	await both("t1b_a")
	# the guest's demand differs for a while (as with the old wiped clocks): no false shortage
	if role == "guest":
		var ts: Node = mp.world_sync.get("tables_sync")
		ts.set_process(false)
		var n := 0
		for m in grid.call("machines"):
			if clocks.call("clockable", m) and float(clocks.call("clock_of", m)) != 1.0:
				clocks.call("set_clock", m, 1.0)
				n += 1
		await sleep(3.0)
		rep = grid.call("report", fab)
		w("T1b guest with %d clocks at 100%%: supply=%.2f demand=%.2f could=%.0f sat=%.3f line=%s" % [n, rep.get("supply"), rep.get("demand"), rep.get("could"), rep.get("satisfaction"), machine_power.call("rating_line", fab, grid)])
		clocks.call("from_dict", await grab("clock_rows"))
		clocks.call("resolve")
		ts.call("_rebaseline")
		ts.set_process(true)
	else:
		await sleep(1.0)
		put("clock_rows", clocks.call("to_dict"))
	await both("t1b_b")
	# a real shortage must still show on both
	if role == "host":
		for i in gens.size():
			gens[i].call("set_switched_off", i >= 3)
	await sleep(6.0)
	rep = grid.call("report", fab)
	w("T1b %s real shortage: supply=%.2f demand=%.2f could=%.0f sat=%.3f fab power=%.3f line=%s" % [role, rep.get("supply"), rep.get("demand"), rep.get("could"), rep.get("satisfaction"), fab.get("power"), machine_power.call("rating_line", fab, grid)])
	dump_all("short")
	await both("t1b_c")
	if role == "host":
		for g in gens:
			g.call("set_switched_off", false)
	await sleep(6.0)
	rep = grid.call("report", fab)
	w("T1b %s all generators back: supply=%.2f demand=%.2f sat=%.3f" % [role, rep.get("supply"), rep.get("demand"), rep.get("satisfaction")])
	await both("t1b")

	# ---- T2 the other player builds
	var conv: Dictionary = {}
	for d in b.to_array():
		if d is Dictionary and str(d.get("type")) == "conveyor":
			conv = (d as Dictionary).duplicate(true)
			break
	if role == "guest":
		for k in ["a", "b", "position"]:
			if conv.has(k) and conv[k] is Vector3:
				conv[k] += Vector3(150, 0, 150)
		mp._rx_builds.rpc_id(1, [conv], [])
	await sleep(3.0)
	w("T2 after a build: clock=%s swatch=%s clock rows=%s" % [clocks.call("clock_of", fab), paint.call("swatch_of", fab), str(clocks.call("to_dict")).length()])
	await both("t2")

	# ---- T3 five real pick-ups from a queue that stands still
	var wad0 := loose("hay_wad")
	if role == "host":
		var best := ""
		var spots: Array = []
		for e in BeltPath.belts_to_array():
			var rows: Array = e.get("records", [])
			if rows.size() < 8:
				continue
			var still := true
			for row in rows:
				if float(row.get("speed", 1.0)) != 0.0 or int(row.get("kind", -1)) != 0:
					still = false
					break
			if still:
				best = entry_key(e)
				for row in rows:
					spots.append((row["xform"] as Transform3D).origin)
				break
		w("T3 host queue=%s rows=%d" % [best.substr(0, 60), spots.size()])
		put("queue", [best, spots])
		var r0 := rows_of(best)
		await wait_for("t3_done", 120.0)
		await sleep(3.0)
		w("T3 HOST rows %d -> %d (want -5), loose hay_wad %d -> %d (want +5)" % [r0, rows_of(best), wad0, loose("hay_wad")])
		await both("t3")
	else:
		var q: Array = await grab("queue")
		var k: String = q[0]
		var spots: Array = q[1]
		var r0 := rows_of(k)
		var picks := 0
		for i in 5:
			var at: Vector3 = spots[spots.size() - 1 - i]
			if not await aim_at(at):
				w("T3 could not aim at %s" % at)
				continue
			await frames(2)
			var ok: Variant = carry.call("_pick_record", false)
			var it: Variant = carry.call("held")
			w("T3 pick %d -> %s item=%s held=%s" % [i, ok, it.item_id if it != null else "-", it.is_held() if it != null else "-"])
			if ok:
				picks += 1
			await frames(3)
			pl.global_position = home
			pl.set("velocity", Vector3.ZERO)
			await sleep(0.4)
			carry.call("drop")
			await sleep(0.6)
		mark("t3_done")
		await sleep(3.0)
		w("T3 GUEST picks=%d rows %d -> %d, loose hay_wad %d -> %d" % [picks, r0, rows_of(k), wad0, loose("hay_wad")])
		await both("t3")
	pl.global_position = home

	# ---- T4 a real pour, tipping with the mouse, into a bucket the host owns
	if role == "guest":
		var a: Node = props.call("spawn", "bucket", Transform3D(Basis(), home + Vector3(0, 1.0, 0.6)), {})
		await frames(3)
		carry.call("take", a)
		await frames(3)
		w("T4 guest holds A=%s owner_me=%s" % [a.is_held(), ps.call("_mine", int(a.get_meta("mp_id")))])
		Input.action_press("secondary")
		for fr in 90:
			var ev := InputEventMouseMotion.new()
			ev.relative = Vector2(0, 12)
			ev.screen_relative = Vector2(0, 12)
			get_viewport().push_input(ev)
			await get_tree().process_frame
		var pp: Vector3 = a.call("pour_point")
		w("T4 tipped: intent=%s up.y=%.2f pour point=%s" % [pl.call("pour_intent"), a.global_basis.y.y, pp])
		put("pour", pp)
		var id_b: int = await grab("bucket")
		await sleep(1.5)
		var bk: Node = ps.get("_by_id").get(id_b)
		w("T4 B on guest: stored=%s physics=%s owner=%s" % [bk.get("stored"), bk.is_physics_processing(), ps.get("_owner").get(id_b)])
		a.call("from_state", {"stored": 500})
		var seen := false
		var claimed := false
		for fr in 200:
			var ev := InputEventMouseMotion.new()
			ev.relative = Vector2(0, 2)
			ev.screen_relative = Vector2(0, 2)
			get_viewport().push_input(ev)
			await get_tree().process_frame
			seen = seen or bool(a.get("_pouring"))
			claimed = claimed or ps.call("_mine", id_b)
		Input.action_release("secondary")
		w("T4 poured: _pouring=%s A=%s B=%s B taken over=%s" % [seen, a.get("stored"), bk.get("stored"), claimed])
		mark("t4_poured")
		await sleep(6.0)
		w("T4 GUEST 6 s later: B=%s owner=%s physics=%s" % [bk.get("stored"), ps.get("_owner").get(id_b), bk.is_physics_processing()])
		carry.call("drop")
	else:
		var pp: Vector3 = await grab("pour")
		var bk: Node = props.call("spawn", "bucket", Transform3D(Basis(), Vector3(pp.x, pp.y - 0.9, pp.z)), {})
		await sleep(1.0)
		put("bucket", int(bk.get_meta("mp_id")))
		await wait_for("t4_poured")
		await sleep(1.5)
		w("T4 HOST right after the pour: B=%s owner=%s" % [bk.get("stored"), ps.get("_owner").get(int(bk.get_meta("mp_id")))])
		await sleep(5.0)
		w("T4 HOST 6 s later: B=%s owner=%s frozen=%s" % [bk.get("stored"), ps.get("_owner").get(int(bk.get_meta("mp_id"))), bk.get("freeze")])
	await both("t4")

	# ---- T5 truck
	var tr: Node = world.get("truck")
	await sleep(1.0)
	w("T5 start idx=%s parts=%s shown=%s state=%s" % [GameState.contract_index, GameState.contract_parts, tr.call("load_shown"), tr.get("state")])
	if role == "host":
		var want: Array = DeliveryBook.wanted_items(GameState.contract_index)
		for i in 5:
			GameState.contract_parts[str(want[0])] = int(GameState.contract_parts.get(str(want[0]), 0)) + 1
			GameState.contract_delivered += 1
			tr.call("stack_one", str(want[0]))
	await sleep(2.0)
	w("T5 +5 parts=%s shown=%s progress=%s" % [GameState.contract_parts, tr.call("load_shown"), world.get("deliveries").call("progress")])
	await both("t5a")
	if role == "host":
		var dd: Node = world.get("deliveries")
		GameState.contract_parts.clear()
		GameState.contract_delivered = 0
		GameState.contract_index += 1
		dd.call("_rig", GameState.contract_index)
		var want2: Array = DeliveryBook.wanted_items(GameState.contract_index)
		for i in 3:
			GameState.contract_parts[str(want2[0])] = int(GameState.contract_parts.get(str(want2[0]), 0)) + 1
			GameState.contract_delivered += 1
			tr.call("stack_one", str(want2[0]))
	await sleep(3.0)
	w("T5 next idx=%s parts=%s shown=%s spots=%s" % [GameState.contract_index, GameState.contract_parts, tr.call("load_shown"), (tr.get("_spots") as Dictionary).keys()])
	await both("t5")

	# ---- T6 refund of something expensive
	await sleep(1.0)
	var bales0 := loose("hay_bale")
	var rods0 := loose("hay_rod")
	var m0: float = GameState.money
	var st0: String = str(GameState.depot_stock)
	await both("t6a")
	await sleep(0.5)
	var refund := 0.0
	if role == "guest":
		var victim: Node = null
		var paid := 0.0
		for a in ["papers", "compressors", "briquette_presses", "pulpers", "wrappers"]:
			for n in b.get(a):
				if is_instance_valid(n) and n != fab and float(n.get("paid_cost") if "paid_cost" in n else 0.0) > paid:
					victim = n
					paid = float(n.get("paid_cost"))
		w("T6 guest demolishes %s paid=%s" % [victim, paid])
		var before: float = GameState.money
		w("T6 blocked=%s" % b.call("demolish_blocked_reason", victim))
		var ret: Variant = b.call("demolish", victim)
		refund = GameState.money - before
		w("T6 demolish returned %s, money here +%.2f, still there=%s" % [ret, refund, is_instance_valid(victim) and victim.is_inside_tree()])
		put("refund", refund)
	else:
		refund = await grab("refund")
	await sleep(6.0)
	w("T6 %s money change=%.2f money=%.2f depot same=%s bales %d -> %d rods %d -> %d" % [role, GameState.money - m0, GameState.money, st0 == str(GameState.depot_stock), bales0, loose("hay_bale"), rods0, loose("hay_rod")])
	await both("t6")
	# the same with the host taking one down
	var bales1 := loose("hay_bale")
	var all1: int = props.items.size()
	if role == "host":
		var victim2: Node = null
		var stuff := 0
		for a2 in ["compressors", "briquette_presses", "papers", "wrappers"]:
			for n2 in b.get(a2):
				if is_instance_valid(n2) and n2 != fab:
					victim2 = n2
					break
			if victim2 != null:
				break
		w("T6b host demolishes %s to_dict=%s" % [victim2, str(victim2.call("to_dict")).substr(0, 160)])
		b.call("demolish", victim2)
		await sleep(0.2)
		w("T6b host right after: items %d -> %d" % [all1, props.items.size()])
	await sleep(4.0)
	w("T6b %s items %d -> %d" % [role, all1, props.items.size()])
	await both("t6b")

	# ---- T7 market
	var sold0: float = float(Buyers.to_dict()["sold"].get("hay_bale", 0.0))
	if role == "guest":
		await sleep(1.0)
		Buyers.sell("hay_bale", 20, 2.0)
		w("T7 guest sold 20 hay_bale: sold here %.3f -> %.3f" % [sold0, float(Buyers.to_dict()["sold"].get("hay_bale", 0.0))])
	await sleep(7.0)
	w("T7 %s sold hay_bale %.3f -> %.3f" % [role, sold0, float(Buyers.to_dict()["sold"].get("hay_bale", 0.0))])
	await both("t7")

	# ---- T8 records
	if role == "guest":
		GameState.set("best_combo", 12345)
		GameState.set("best_sale", 7777.0)
		GameState.set("best_sale_strands", 99)
	else:
		GameState.set("best_income", 54321.0)
	await sleep(4.0)
	w("T8 best_combo=%s best_sale=%s/%s best_income=%s" % [GameState.best_combo, GameState.best_sale, GameState.best_sale_strands, GameState.best_income])
	await both("t8")

	# ---- T9 cables between poles that already stand
	var poles: Array = b.get("power_poles")
	var pa: Node = null
	var pb: Node = null
	var pairs := {}
	for p in poles:
		pairs[str((p as Node3D).global_position)] = p
	if role == "host":
		for i in poles.size():
			for j in range(i + 1, poles.size()):
				if grid.call("linked", poles[i], poles[j]):
					pa = poles[i]
					pb = poles[j]
					break
			if pa != null:
				break
		put("poles", [pa.global_position, pb.global_position])
		b.call("cut_poles", pa, pb)
	else:
		var q: Array = await grab("poles")
		var best_a := 9999.0
		var best_b := 9999.0
		for p in poles:
			var da: float = (p as Node3D).global_position.distance_to(q[0])
			var db: float = (p as Node3D).global_position.distance_to(q[1])
			if da < best_a:
				best_a = da
				pa = p
			if db < best_b:
				best_b = db
				pb = p
	await sleep(5.0)
	w("T9 host cut: linked=%s pa links=%s cuts=%s" % [grid.call("linked", pa, pb), pa.get("links_at"), pa.get("cuts_at")])
	await both("t9a")
	if role == "guest":
		b.call("join_poles", pa, pb)
	await sleep(5.0)
	w("T9 guest joined: linked=%s pa links=%s cuts=%s" % [grid.call("linked", pa, pb), pa.get("links_at"), pa.get("cuts_at")])
	await both("t9b")
	if role == "guest":
		b.call("cut_poles", pa, pb)
	await sleep(5.0)
	w("T9 guest cut again: linked=%s pa links=%s cuts=%s" % [grid.call("linked", pa, pb), pa.get("links_at"), pa.get("cuts_at")])
	await both("t9c")
	if role == "host":
		b.call("join_poles", pa, pb)
	await sleep(5.0)
	w("T9 host joined: linked=%s pa links=%s cuts=%s" % [grid.call("linked", pa, pb), pa.get("links_at"), pa.get("cuts_at")])
	await both("t9")

	# ---- T10 both grab one item in the same moment
	pl.global_position = home
	await sleep(0.5)
	var id_w := 0
	if role == "host":
		var h: Variant = carry.call("held")
		if h != null:
			carry.call("drop")
		var wad: Node = props.call("spawn", "hay_wad", Transform3D(Basis(), home + Vector3(0, 1.0, 1.0)), {"strands": 10})
		await sleep(1.0)
		id_w = int(wad.get_meta("mp_id"))
		put("wad", [id_w, Time.get_unix_time_from_system() + 2.0])
	var q2: Array = await grab("wad") if role == "guest" else [id_w, 0.0]
	if role == "host":
		q2 = FileAccess.open(dir + "/val_wad", FileAccess.READ).get_var()
	var item: Node = ps.get("_by_id").get(int(q2[0]))
	while Time.get_unix_time_from_system() < float(q2[1]):
		await get_tree().process_frame
	carry.call("take", item)
	w("T10 %s took: held=%s" % [role, item.is_held()])
	await sleep(1.5)
	var o1: Variant = ps.get("_owner").get(int(q2[0]))
	await sleep(1.5)
	w("T10 %s after 3 s: held=%s owner %s -> %s" % [role, item.is_held(), o1, ps.get("_owner").get(int(q2[0]))])
	await both("t10")
	if carry.call("held") != null:
		carry.call("drop")

	# ---- T11 radar, launcher, lamp, drone, crane, excavator: built here, used by the guest
	await sleep(1.0)
	var at0: Vector3 = Vector3(30, 0.0, 40)
	if role == "guest":
		await add_everywhere({"type": "needle_radar", "position": at0, "yaw": 0.0, "cool": 0.0})
		await add_everywhere({"type": "tube_launcher", "position": at0 + Vector3(5, 0, 0), "yaw": 0.0})
		await add_everywhere({"type": "work_lamp", "position": at0 + Vector3(10, 0, 0), "yaw": 0.0})
		await add_everywhere({"type": "hay_drone", "position": at0 + Vector3(15, 0, 0), "yaw": 0.0})
		await add_everywhere({"type": "skyline_crane", "position": at0 + Vector3(25, 0, 0), "yaw": 0.0})
		await add_everywhere({"type": "hay_excavator", "position": at0 + Vector3(35, 0, 0), "yaw": 0.0})
	await sleep(5.0)
	var radar := one_of("needle_radars")
	var launcher := one_of("tube_launchers")
	var lamp := one_of("work_lamps")
	var drone := one_of("hay_drones")
	var crane := one_of("skyline_cranes")
	var excav := one_of("hay_excavators")
	w("T11 built radar=%s launcher=%s lamp=%s drone=%s crane=%s excavator=%s" % [radar, launcher, lamp, drone, crane, excav])
	await both("t11a")
	if radar != null:
		radar.set("tier_override", 1)
		await sleep(1.0)
		if role == "guest":
			var r: Variant = radar.call("activate")
			w("T11 guest radar activate -> '%s' phase=%s" % [r, radar.get("phase")])
		await sleep(2.0)
		w("T11 %s radar 2 s: phase=%s busy=%s" % [role, radar.get("phase"), radar.call("is_busy")])
		var most := 0
		var last_left := -1.0
		for i in 60:
			await sleep(0.5)
			var mk: Array = radar.call("marks")
			most = maxi(most, mk.size())
			if not mk.is_empty():
				last_left = float(mk[0].get("left", -1.0))
		w("T11 %s radar after 32 s: phase=%s cool=%.0f last_found=%s most marks=%d last left=%.1f marks now=%d" % [role, radar.get("phase"), float(radar.get("cooldown")), radar.get("last_found"), most, last_left, (radar.call("marks") as Array).size()])
	await both("t11b")
	if launcher != null:
		if role == "guest":
			launcher.set("power", 0.7)
		await sleep(2.0)
		w("T12 %s launcher power=%s line_power=%s mains=%s" % [role, launcher.get("power"), launcher.get("line_power"), launcher.get("mains")])
	await both("t12")
	if lamp != null:
		if role == "guest":
			lamp.call("set_switched_off", true)
		await sleep(2.0)
		w("T13 %s lamp off=%s" % [role, lamp.get("_off")])
	await both("t13")
	if drone != null:
		var zb: Variant = drone.get("zone_at")
		if role == "guest":
			var zr: Variant = drone.call("set_zone", Vector3(home.x + 3.0, 0.0, home.z + 3.0), 5.0)
			w("T14 guest set_zone -> %s zone=%s mode=%s" % [zr, drone.get("zone_at"), drone.get("mode")])
			if drone.get("zone_at") == null or not is_finite(float((drone.get("zone_at") as Vector3).x)):
				drone.set("zone_at", Vector3(home.x + 3.0, 0.0, home.z + 3.0))
				drone.set("zone_r", 5.0)
				w("T14 guest wrote the zone directly")
		await sleep(2.0)
		w("T14 %s drone zone %s -> %s r=%s" % [role, zb, drone.get("zone_at"), drone.get("zone_r")])
	await both("t14")
	if crane != null:
		if role == "guest":
			crane.call("set_zone", at0 + Vector3(30, 0, 30), 8.0)
		await sleep(2.0)
		w("T15 %s crane zone=%s r=%s" % [role, crane.get("zone_at"), crane.get("zone_radius")])
	await both("t15")
	if excav != null:
		if role == "host":
			excav.set("aim_yaw", 1.1)
			excav.set("aim_pitch", 0.3)
			excav.set("aim_intake", 0.4)
			excav.set("aimed", true)
		await sleep(3.0)
		w("T16 %s excavator aimed=%s yaw=%s pitch=%s intake=%s dict=%s" % [role, excav.get("aimed"), excav.get("aim_yaw"), excav.get("aim_pitch"), excav.get("aim_intake"), str(excav.call("to_dict")).substr(0, 200)])
	await both("t16")

	# ---- everything again, after a long run of machines
	await sleep(10.0)
	dump_all("late")
	await both("d9")

	if role == "guest":
		w("T0b items the guest made itself during the whole run: %d" % made_here.size())
		for line in made_here.slice(0, 40):
			w("   " + str(line))
	w("T0c income per minute=%s" % GameState.call("income_per_minute"))
	# ---- T17 the host stops hosting and plays on
	if role == "host":
		var copies := 0
		for it in props.items:
			if is_instance_valid(it) and it.has_meta("mp_copy"):
				copies += 1
		w("T17 host before leave: frozen copies=%d" % copies)
		mp.leave("test")
		await sleep(3.0)
		copies = 0
		for it in props.items:
			if is_instance_valid(it) and it.has_meta("mp_copy"):
				copies += 1
		w("T17 host after leave: active=%s frozen copies=%d world still here=%s" % [mp.active(), copies, is_instance_valid(world) and world.is_inside_tree()])
	else:
		await sleep(5.0)
		w("T17 guest after host left: active=%s phase=%s block_save=%s scene=%s" % [mp.active(), mp.phase, SaveManager.block_save, get_tree().current_scene.scene_file_path if get_tree().current_scene else "?"])
	await sleep(3.0)
	mark("end")
	await wait_for("end", 20.0)
	w("DONE")
	get_tree().quit()
