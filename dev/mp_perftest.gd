extends Node
# Frame times, host and guest, standing among the machines. Works on any version.
var mp: Node
var role := ""
var o: FileAccess
var dir := ""
const PORT := 7793
var measuring := false
var last := 0
var times: PackedInt32Array = PackedInt32Array()
var phys: PackedInt32Array = PackedInt32Array()
var last_p := 0

func w(s) -> void:
	o.store_line(str(s)); o.flush()

func mark(x: String) -> void:
	FileAccess.open(dir + "/" + role + "_" + x, FileAccess.WRITE).store_string("1")

func wait_for(x: String, limit := 120.0) -> void:
	var other := "guest" if role == "host" else "host"
	var t := 0.0
	while t < limit and not FileAccess.file_exists(dir + "/" + other + "_" + x):
		await get_tree().create_timer(0.1).timeout
		t += 0.1

func sleep(s: float) -> void:
	await get_tree().create_timer(s).timeout

func _process(_d: float) -> void:
	if not measuring:
		return
	var now := Time.get_ticks_usec()
	if last != 0:
		times.append(now - last)
	last = now

func report(tag: String) -> void:
	var a := times.duplicate()
	a.sort()
	var n := a.size()
	if n == 0:
		w("%s no frames" % tag)
		return
	var total := 0
	var over4 := 0
	var over8 := 0
	var over16 := 0
	var over33 := 0
	for v in a:
		total += v
		over4 += 1 if v > 4000 else 0
		over8 += 1 if v > 8000 else 0
		over16 += 1 if v > 16700 else 0
		over33 += 1 if v > 33000 else 0
	w("%s frames=%d avg=%.2fms p50=%.2f p95=%.2f p99=%.2f p999=%.2f max=%.1f | over 4ms=%d 8ms=%d 16ms=%d 33ms=%d" % [tag, n, float(total) / n / 1000.0, a[n / 2] / 1000.0, a[int(n * 0.95)] / 1000.0, a[int(n * 0.99)] / 1000.0, a[int(n * 0.999)] / 1000.0, a[n - 1] / 1000.0, over4, over8, over16, over33])

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
	else:
		await sleep(30.0)
		mp.join("127.0.0.1", PORT)
		var t := 0.0
		while t < 220.0:
			await sleep(1.0)
			t += 1.0
			if mp.phase == mp.Phase.IN_WORLD and mp.in_world():
				break
	await sleep(10.0)
	mark("ready")
	await wait_for("ready")
	var world: Node = mp.world_sync.world
	var pl: Node3D = world.get("player")
	var b: Object = world.get("builds")
	# stand in the middle of the factory: everything within range of everyone
	var sum := Vector3.ZERO
	var n := 0
	for m in b.get("grid").call("machines"):
		if is_instance_valid(m):
			sum += (m as Node3D).global_position
			n += 1
	var mid: Vector3 = sum / maxf(1.0, float(n))
	pl.global_position = Vector3(mid.x + (2.0 if role == "host" else -2.0), mid.y + 1.0, mid.z)
	pl.set("velocity", Vector3.ZERO)
	await sleep(8.0)
	# keep standing there: the player falls otherwise and the numbers wander
	w("version %s standing at %s fps setting=%s" % [mp.VERSION, pl.global_position, Engine.max_fps])
	await wait_for("ready")
	measuring = true
	await sleep(40.0)
	measuring = false
	report(role)
	var t0 := Time.get_ticks_usec()
	mark("end")
	await wait_for("end", 20.0)
	get_tree().quit()
