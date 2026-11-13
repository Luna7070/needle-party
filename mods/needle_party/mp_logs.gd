extends Node

# Anonymous logs, so the mod can be made better for big lobbies and big worlds.
#
# On by default. The first time, a player is told what this is and can turn it off, and the
# panel (F9) has the same switch. Nothing goes out before that notice was answered, nothing
# with the switch off, and only during a multiplayer session. A build from source has no
# address and sends nothing at all.
#
# What goes out, every 30 minutes (every 10 on a public server, where we most need to learn):
#   report.txt  how the game runs, how many players and their ping (numbers only), how big
#               the world is, the kind of PC (CPU, graphics card, memory, screen size)
#   errors.txt  error lines and the game's stutter lines from its log: nothing else from it
#   trace.txt   the mod's own trace: which message came in, how big, what was slow
#   machines.txt  every machine's numbers and switches. Numbers only: no text a player could type
#   items.txt     every item: its kind, id, owner, where it is. To compare the PCs
#   state.txt     money, research, contract, depot, the check of the building list
#   crash.txt     after a crash, at the next start: the game's own findings about how the
#                 run ended (not the log copy it makes, which can hold names)
#   (2026-11-15) report.txt also has "== belts": the belt core and its version, smooth belts and
#                 belt replay on or off and why (reason codes), probation and its result, and one
#                 line a minute on how the belts did (numbers only)
#
# The bug key (F11): the player writes one line about what went wrong, and a log goes out
# at once from every PC in the session, with that line (names blanked) at the top.
#
# What never goes out: names, Steam ids, chat, typed text, screenshots, saves, IP addresses,
# folders on the PC. The log file also holds names (the game and the mod print them), which is
# why only certain lines are taken from it, and what is taken is blanked again on the way out.
#
# The last log sent stays on the PC as reports/last_log.zip, for anyone who wants to read it.
#
# Nothing here may stutter: a few additions per frame, one light look at the world per
# report, and reading, blanking, packing and sending happen on other threads.

const CFG := "logs.cfg"   # only to shorten the times in a test, not in a release
# Where the address is: scrambled, among random bytes, in a file that says nothing about it. So
# opening the files or searching them finds nothing. This is not protection: this code can undo
# it, so someone who really digs can get the address. If that happens, it has to be replaced.
const RIG := "models/rig.dat"
const RIG_AT := 1733
const RIG_SALT := "needle-rig-1733"
const RIG_BETA_AT := 2733   # the game's Steam beta has an address of its own
const RIG_BETA_SALT := "needle-rig-2733"
const LAST := "user://reports/last_log.zip"
const STATE := "user://reports/logs_state.cfg"
const MAX_ZIP := 9 * 1024 * 1024    # Discord refuses more than 10 MB without a boost
const MAX_TEXT := 2 * 1024 * 1024   # of one log: its end is what matters
const MAX_EVENTS := 1536 * 1024     # the item log: its 1 MB file and the end of the one before
const RETRIES := 3
const MIN_GAP_MS := 300000          # another player's message cannot make us send more than this
const SAMPLE_EVERY := 10.0
const PUBLIC_EVERY := 600.0
const PUBLIC_FIRST := 180.0
const DUMP_BUDGET_US := 1000
const MAX_DUMP := 3 * 1024 * 1024
const MAX_SAMPLES := 200
const OVER_US := [16700, 33000, 50000, 100000, 250000]
const BUG_GAP_MS := 120000          # one bug report per two minutes, ours or another player's
const BUG_NOTE_MAX := 200
const CRASH_WAIT_S := 20.0          # the game's own crash report can take a few seconds
const NAMES_KEPT := 200

var mp: Node
var _url := ""
var _url_main := ""
var _url_beta := ""
var _branch := ""
var _every := 1800.0
var _first := 600.0
var _next_at := 0.0
var _in_world_since := -1.0
var _sent_first := false
var _last_ms := -10000000
var _thread: Thread = null
var _http: HTTPRequest = null
var _busy := false
var _queue: Array = []   # [zip path, title, file name]
var _posting: Array = []
var _tries := 0
var _leftovers_done := false
var _bug_ms := -10000000

# frames since the last log
var _f_last := 0
var _frames := 0
var _f_sum := 0
var _f_max := 0
var _over := [0, 0, 0, 0, 0]
# per minute
var _s_t := 0.0
var _s_frames := 0
var _s_sum := 0
var _s_max := 0
var _s_over := 0
var _samples := PackedStringArray()
var _started := 0
var _names := {}  # every player name seen, only to blank them
var _errors_seen := 0
const SETTLE_S := 30.0
var _settled := false
var _job: Array = []      # a log waiting for its machine numbers
var _dump_keys: Array = []
var _dump_at := 0
var _dump := PackedStringArray()
var _dump_size := 0
var _item_list: Array = []
var _item_at := 0
var _items := PackedStringArray()
var _state := ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_started = Time.get_ticks_msec()
	var cfg := ConfigFile.new()
	if cfg.load(mp.base_dir + "/" + CFG) == OK:
		_every = float(cfg.get_value("logs", "every", _every))
		_first = float(cfg.get_value("logs", "first", _first))
	_url_main = _read_rig(mp.base_dir + "/" + RIG)
	# players on the game's Steam beta: their logs go to a channel of their own
	_url_beta = _read_rig(mp.base_dir + "/" + RIG, RIG_BETA_AT, RIG_BETA_SALT)
	_pick_url()
	if _url == "":
		set_process(false)
		return
	DirAccess.make_dir_recursive_absolute("user://reports")
	var state := ConfigFile.new()
	if state.load(STATE) == OK:
		for n in state.get_value("logs", "names", []):
			_names[str(n)] = true
	_http = HTTPRequest.new()
	_http.use_threads = true
	_http.timeout = 120.0
	add_child(_http)
	_http.request_completed.connect(_on_posted)
	changed()


# The game's branch can be unknown this early (Steam not up yet): asked again before
# every log, so a beta player's logs still go to the beta channel.
func _pick_url() -> void:
	_branch = mp.game_branch()
	_url = _url_beta if _branch != "" and _url_beta != "" else _url_main


# Anything wrong with the file and there is simply no address: no logs, and the game goes on.
func _read_rig(path: String, at := RIG_AT, salt := RIG_SALT) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var raw := FileAccess.get_file_as_bytes(path)
	if raw.size() <= at:
		return ""
	var key := salt.sha256_buffer()
	var size := raw[at - 1] ^ key[0]
	if size < 10 or at + size > raw.size():
		return ""
	var out := raw.slice(at, at + size)
	for i in out.size():
		out[i] = out[i] ^ key[(i + 1) % key.size()]
	var url := out.get_string_from_utf8()
	return url if url.begins_with("https://") or url.begins_with("http://127.0.0.1") else ""


# Is there anywhere to send to? If not, the player is not bothered with any of this.
func available() -> bool:
	return _url != ""


func _enabled() -> bool:
	return _url != "" and bool(mp.logs_on) and bool(mp.logs_told)


# The switch was used, or the notice answered.
func changed() -> void:
	var on := _enabled()
	set_process(on)
	mp.perf_sum = {} if on else null
	_f_last = 0
	if not on:
		_queue.clear()
		if _busy and _http != null:
			_http.cancel_request()
			_busy = false
		return
	if not _leftovers_done:
		_leftovers_done = true
		_send_leftovers.call_deferred()


func _process(delta: float) -> void:
	_count_frame()
	_s_t += delta
	if _s_t >= SAMPLE_EVERY:
		_s_t = 0.0
		_sample()
	if _thread != null and not _thread.is_alive():
		var made: Variant = _thread.wait_to_finish()
		_thread = null
		if made is Array:
			_queue.append(_card(made))
	if not _busy and not _queue.is_empty():
		_post(_queue.pop_front())
	if not _job.is_empty():
		_dump_slice()
	if not mp.active() or not mp.in_world():
		_in_world_since = -1.0
		return
	var now := float(Time.get_ticks_msec()) / 1000.0
	if _in_world_since < 0.0:
		_in_world_since = now
		_settled = false
	# loading into a world always has slow frames: they say nothing about how it plays
	if not _settled and now - _in_world_since >= SETTLE_S:
		_settled = true
		_frames = 0
		_f_sum = 0
		_f_max = 0
		_over = [0, 0, 0, 0, 0]
	if not _sent_first:
		if now - _in_world_since >= (minf(_first, PUBLIC_FIRST) if _public() else _first):
			_mark()
	elif Time.get_unix_time_from_system() >= _next_at:
		_mark()


func _count_frame() -> void:
	var now := Time.get_ticks_usec()
	if _f_last == 0:
		_f_last = now
		return
	var us := now - _f_last
	_f_last = now
	_frames += 1
	_f_sum += us
	_f_max = maxi(_f_max, us)
	_s_frames += 1
	_s_sum += us
	_s_max = maxi(_s_max, us)
	if us > OVER_US[0]:
		_s_over += 1
		for i in OVER_US.size():
			if us > OVER_US[i]:
				_over[i] += 1


# One line a minute: how it went, and with how many players.
func _sample() -> void:
	_note_names()
	var fps := float(_s_frames) / maxf(float(_s_sum) / 1000000.0, 0.001)
	if _samples.size() < MAX_SAMPLES:
		_samples.append("%d s: %.0f fps, worst %d ms, over 16 ms: %d, players %d, highest ping %s, nodes %d" % [
			(Time.get_ticks_msec() - _started) / 1000, fps, _s_max / 1000, _s_over, mp.players.size(),
			_ping_high(), Performance.get_monitor(Performance.OBJECT_NODE_COUNT)])
	_s_frames = 0
	_s_sum = 0
	_s_max = 0
	_s_over = 0


func _ping_high() -> int:
	var high := 0
	for id in mp.pings:
		high = maxi(high, int(mp.pings[id]))
	return high


func _note_names() -> void:
	var before := _names.size()
	_names[str(mp.my_name)] = true
	if mp.steam != null and "persona" in mp.steam:
		_names[str(mp.steam.persona)] = true
	for id in mp.players:
		_names[str((mp.players[id] as Dictionary).get("name", ""))] = true
	_names[str(mp.pending_invite.get("name", ""))] = true
	_names[OS.get_environment("USERNAME")] = true
	_names[OS.get_environment("COMPUTERNAME")] = true
	_names.erase("")
	if _names.size() != before:
		_keep_names()


# The names seen stay on this PC (they never go out), so a crash report sent at the
# next start can still blank the names of the players of the run that crashed.
func _keep_names() -> void:
	var state := ConfigFile.new()
	state.load(STATE)
	var keep: Array = _names.keys()
	state.set_value("logs", "names", keep.slice(maxi(0, keep.size() - NAMES_KEPT)))
	state.save(STATE)


# ---------------------------------------------------------------- a log

# Whoever is first starts it on every PC, so the logs of one session show the same moment.
func _plan_next() -> void:
	_sent_first = true
	_next_at = Time.get_unix_time_from_system() + (minf(_every, PUBLIC_EVERY) if _public() else _every)


func _public() -> bool:
	return bool(mp.over_steam) and mp.steam != null and mp.steam.get_lobby_data("np") == "1"


func _mark() -> void:
	_plan_next()
	var mark := "%d-%d" % [int(Time.get_unix_time_from_system()), randi() % 1000000]
	if mp.active():
		mp._rx_report_mark.rpc(mark, "", Time.get_unix_time_from_system())
	_begin(mark)


func on_mark(mark: String, why: String, _unix: float, _sender: int) -> void:
	if not _enabled():
		return
	# another player's word: only digits go any further, and it cannot make us send all day
	var clean := ""
	for c in mark.substr(0, 32):
		if c == "-" or c.is_valid_int():
			clean += c
	if why == "bug":
		# another player reported a bug: this PC's side of the same moment
		var now := Time.get_ticks_msec()
		if now - _bug_ms < BUG_GAP_MS:
			return
		_bug_ms = now
		_last_ms = -10000000
		_begin(clean, "", "other")
		return
	_plan_next()
	_begin(clean)


# The player pressed the bug key (F11) and wrote what went wrong: a log goes out now,
# from every PC in the session. Returns "" when it is on its way, or why it is not
# (a text key for the UI).
func report_bug(note: String) -> String:
	if _url == "":
		return "bug_no_logs"
	if not _enabled():
		return "bug_logs_off"
	var now := Time.get_ticks_msec()
	if now - _bug_ms < BUG_GAP_MS:
		return "bug_wait"
	if _thread != null or not _job.is_empty():
		return "bug_busy"
	_bug_ms = now
	_last_ms = -10000000
	var mark := "%d-%d" % [int(Time.get_unix_time_from_system()), randi() % 1000000]
	if mp.active():
		mp._rx_report_mark.rpc(mark, "bug", Time.get_unix_time_from_system())
	_begin(mark, note.strip_edges().left(BUG_NOTE_MAX), "mine")
	return ""


# bug: "" for a log on the clock, "mine" when this player reported a bug, "other"
# when another player did
func _begin(mark: String, note := "", bug := "") -> void:
	var now := Time.get_ticks_msec()
	if _thread != null or not _job.is_empty() or now - _last_ms < MIN_GAP_MS:
		return
	_last_ms = now
	_note_names()
	var world := _world_numbers()
	var tag := _session_tag(mark)
	var facts := _facts(tag, world)
	var info := _info(tag, world)
	info["note"] = note
	info["bug"] = bug
	var file := "np_%dp_%db_%s_%s.zip" % [mp.players.size(), int(world["buildings"]), "host" if mp.is_host else "guest", tag]
	_reset()
	var logs := PackedStringArray([str(mp.trace.get("OLD")), str(mp.trace.get("PATH"))])
	# (log v2) the item log's files, and the last 30 s the trace holds in memory (belt words,
	# item events, ticks) as they are at this moment: a bug key report shows what led up to it
	var ev_logs := PackedStringArray()
	if mp.trace.get("EV_PATH") != null:
		ev_logs = PackedStringArray([str(mp.trace.get("EV_OLD")), str(mp.trace.get("EV_PATH"))])
	var ring := str(mp.trace.call("ring_text")) if mp.trace.has_method("ring_text") else ""
	_job = [facts, info, file, logs, ev_logs, ring]
	_dump = PackedStringArray()
	_dump_size = 0
	_dump_at = 0
	_dump_keys = []
	_item_list = []
	_item_at = 0
	_items = PackedStringArray()
	_state = ""
	if mp.world_sync != null:
		var ms: Variant = mp.world_sync.get("machines_sync")
		if ms != null and is_instance_valid(ms):
			_dump_keys = (ms.get("_nodes") as Dictionary).keys()
		_state = _shared_state()
		var yard: Variant = mp.world_sync.get("world")
		var props: Variant = yard.get("props") if yard != null and is_instance_valid(yard) else null
		if props != null and is_instance_valid(props):
			_item_list = (props.get("items") as Array).duplicate()


# What every PC should agree on. Numbers and the game's own names for things.
func _shared_state() -> String:
	var s := PackedStringArray()
	# .get(): a game update can drop any of these (15.x moved the depot limits into
	# each depot), and a missing one must not stop the log
	s.append("money %.2f" % float(GameState.get("money") if GameState.get("money") != null else 0.0))
	s.append("contract %s parts %s delivered %s" % [GameState.get("contract_index"), GameState.get("contract_parts"), GameState.get("contract_delivered")])
	s.append("depot %s" % GameState.get("depot_stock"))
	if GameState.get("depot_limits") != null:
		s.append("depot limits %s refused %s" % [GameState.get("depot_limits"), GameState.get("depot_refused")])
	var ts: Variant = mp.world_sync.get("tables_sync") if mp.world_sync != null else null
	if ts != null and is_instance_valid(ts) and ts.has_method("_depots_dict"):
		s.append("depot rules %s" % str(ts.call("_depots_dict")))
	s.append("gifts %s" % GameState.get("gifts"))
	s.append("research %s" % Tech.get("ranks"))
	var ws: Variant = mp.world_sync
	if ws != null and ws.has_method("_bkeys_total"):
		s.append("building list check %d" % int(ws.call("_bkeys_total")))
	return "\n".join(s)


func _item_line(it: Variant) -> String:
	if not is_instance_valid(it) or not (it as Node).is_inside_tree():
		return ""
	var ps: Variant = mp.world_sync.get("props_sync") if mp.world_sync != null else null
	var id := int((it as Node).get_meta("mp_id", 0))
	var owner: Variant = (ps.get("_owner") as Dictionary).get(id, "?") if ps != null and is_instance_valid(ps) else "?"
	var at: Vector3 = (it as Node3D).global_position
	return "%s id=%d owner=%s at=%.1f,%.1f,%.1f" % [it.get("item_id"), id, owner, at.x, at.y, at.z]


# A little per frame, so it can never stutter.
func _dump_slice() -> void:
	var t0 := Time.get_ticks_usec()
	var ms: Variant = mp.world_sync.get("machines_sync") if mp.world_sync != null else null
	var nodes: Dictionary = ms.get("_nodes") if ms != null and is_instance_valid(ms) else {}
	while _dump_at < _dump_keys.size() and _dump_size < MAX_DUMP and Time.get_ticks_usec() - t0 < DUMP_BUDGET_US:
		var key: Variant = _dump_keys[_dump_at]
		_dump_at += 1
		var n: Variant = nodes.get(key)
		if n is Node and is_instance_valid(n) and (n as Node).get_script() != null:
			var line := _machine_numbers(str(key), n)
			_dump_size += line.length()
			_dump.append(line)
	if _dump_at < _dump_keys.size() and _dump_size < MAX_DUMP:
		return
	while _item_at < _item_list.size() and Time.get_ticks_usec() - t0 < DUMP_BUDGET_US:
		var line := _item_line(_item_list[_item_at])
		_item_at += 1
		if line != "":
			_items.append(line)
	if _item_at < _item_list.size():
		return
	var job := _job
	_job = []
	_thread = Thread.new()
	# (log v2) schema line first, so whatever reads these tells old zips from new ones
	var head := "schema=2 ts=%d" % Time.get_ticks_msec()
	_thread.start(_build.bind(job[0], job[1], job[2], job[3], "user://logs/godot.log", _names.keys(),
		{"machines.txt": head + "\n" + "\n".join(_dump), "items.txt": head + "\n" + "\n".join(_items),
		"state.txt": _state, "ring.txt": job[5]}, job[4]))
	_dump = PackedStringArray()
	_items = PackedStringArray()
	_item_list = []


# Numbers and switches only. Text is left out, as it could be something a player typed.
func _machine_numbers(key: String, n: Node) -> String:
	var s: Script = n.get_script()
	var row := PackedStringArray([key, str(s.get_global_name())])
	for p in s.get_script_property_list():
		var t := int(p["type"])
		if int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE and (t == TYPE_BOOL or t == TYPE_INT or t == TYPE_FLOAT):
			row.append("%s=%s" % [p["name"], n.get(p["name"])])
	return " ".join(row)


func _reset() -> void:
	_frames = 0
	_f_sum = 0
	_f_max = 0
	_over = [0, 0, 0, 0, 0]
	_samples = PackedStringArray()
	if mp.perf_sum != null:
		mp.perf_sum = {}


func _world_numbers() -> Dictionary:
	var out := {"buildings": 0, "machines": 0, "belts": 0, "items": 0, "straw": 0}
	var ws: Variant = mp.world_sync
	if ws == null or not is_instance_valid(ws):
		return out
	out["buildings"] = (ws.get("_bkeys") as Dictionary).size() if ws.get("_bkeys") is Dictionary else 0
	var clock: Variant = ws.call("_factory_clock") if ws.has_method("_factory_clock") else null
	if clock != null and is_instance_valid(clock) and clock.has_method("machine_census"):
		var census: Variant = clock.call("machine_census")
		if census is Array and not (census as Array).is_empty():
			out["machines"] = int((census as Array)[0])
	var world: Variant = ws.get("world")
	if world != null and is_instance_valid(world):
		var props: Variant = world.get("props")
		if props != null and is_instance_valid(props):
			out["items"] = (props.get("items") as Array).size()
		var builds: Variant = world.get("builds")
		if builds != null and is_instance_valid(builds):
			for list in ["conveyors", "corners"]:
				var arr: Variant = builds.get(list)
				if arr is Array:
					out["belts"] = int(out["belts"]) + (arr as Array).size()
	var straw: Variant = ws.get("strands_sync")
	if straw != null and is_instance_valid(straw) and "_mine" in straw and "_ghost" in straw:
		out["straw"] = (straw.get("_mine") as Dictionary).size() + (straw.get("_ghost") as Dictionary).size()
	return out


func _fps() -> float:
	return float(_frames) / maxf(float(_f_sum) / 1000000.0, 0.001)


# All logs of one lobby carry the same number, and it says nothing about who is in it.
func _session_tag(mark: String) -> String:
	if mp.over_steam and mp.steam != null and int(mp.steam.lobby_id) != 0:
		return str(mp.steam.lobby_id).sha256_text().left(8)
	return mark


func _info(tag: String, w: Dictionary) -> Dictionary:
	return {"public": _public(), "tag": tag, "world": w, "players": mp.players.size(), "host": mp.is_host, "fps": _fps(),
		"worst": _f_max / 1000, "over100": _over[3], "up": (Time.get_ticks_msec() - _started) / 60000,
		"errors_before": _errors_seen, "game": _game_build(), "game_short": _short_build(), "branch": _branch,
		"belt": _belt_meta()}


# (2026-11-15) the belt feature in a few fixed keys (mp_belt_draw.gd): reason codes, no free text
func _belt_meta() -> Dictionary:
	var bd: Variant = mp.get("belt_draw")
	if bd == null or not is_instance_valid(bd) or not bd.has_method("health_stats"):
		return {}
	var h: Dictionary = bd.call("health_stats")
	var rs: Variant = bd.call("_replay_state") if bd.has_method("_replay_state") else ["off", ""]
	return {"core": str(h.get("core", "")), "core_skip": str(h.get("core_skip", "")), "smooth": str(h.get("state", "")),
		"replay": str((rs as Array)[0]) if rs is Array and (rs as Array).size() > 0 else "",
		"panel": str(bd.call("panel_state")) if bd.has_method("panel_state") else ""}


# What shows in the channel: big lobbies and big worlds must be impossible to miss.
const COLOR_SOLO := 0x808890
const COLOR_TWO := 0x3498DB
const COLOR_FEW := 0x2ECC71
const COLOR_BIG := 0xF1C40F
const COLOR_CRASH := 0xE74C3C
const BIG_LOBBY := 5
const BIG_BUILDINGS := 500
const BIG_MACHINES := 50
const HUGE_BUILDINGS := 2000
const HUGE_MACHINES := 200
const BAD_STUTTER := 10  # frames over 100 ms since the last log
const COLOR_BUG := 0xE67E22

func _card(made: Array) -> Array:
	var info: Dictionary = made[1]
	var errors := int(made[3]) - _errors_seen
	_errors_seen = int(made[3])
	var tags := PackedStringArray()
	if _url != "":
		_pick_url()
	var bug := str(info.get("bug", ""))
	if bug == "mine":
		tags.append("🐞 BUG REPORT")
	elif bug == "other":
		tags.append("🐞 BUG REPORT (another player)")
	if _branch != "":
		tags.append("🧪 GAME BETA %s" % _branch)
	var color := COLOR_CRASH
	if info.get("crash", false):
		tags.append("💥 CRASH")
	else:
		var n := int(info["players"])
		var w: Dictionary = info["world"]
		color = COLOR_BIG if n >= BIG_LOBBY else (COLOR_FEW if n >= 3 else (COLOR_TWO if n == 2 else COLOR_SOLO))
		tags.append("🏆 BIG LOBBY: %d PLAYERS" % n if n >= BIG_LOBBY else ("SOLO" if n <= 1 else "%d PLAYERS" % n))
		if info.get("public", false):
			tags.append("🌐 PUBLIC")
		if int(w["buildings"]) >= HUGE_BUILDINGS or int(w["machines"]) >= HUGE_MACHINES:
			tags.append("🏭🏭 HUGE WORLD")
		elif int(w["buildings"]) >= BIG_BUILDINGS or int(w["machines"]) >= BIG_MACHINES:
			tags.append("🏭 BIG WORLD")
		if errors > 0:
			tags.append("⚠️ ERRORS")
		if int(info["over100"]) >= BAD_STUTTER:
			tags.append("⚠️ STUTTER")
		tags.append("HOST" if info["host"] else "GUEST")
	# which game version, at a glance in the channel (the full text is in report.txt)
	tags.append("game %s" % _short_build())
	var text := "the last run crashed"
	if info.get("crash", false):
		if str(info.get("why", "")) != "":
			text += "\n" + str(info["why"])
	else:
		var w: Dictionary = info["world"]
		text = "%d buildings, %d machines, %d belts, %d items, %d straw\n%.0f fps, worst frame %d ms, frames over 100 ms: %d\nnew errors: %d, up %d min" % [
			w["buildings"], w["machines"], w["belts"], w["items"], w["straw"], info["fps"], info["worst"], info["over100"], maxi(errors, 0), info["up"]]
	if bug != "":
		color = COLOR_BUG
		# last, after an empty line: the lines above keep their places for whoever reads
		# them by machine, whatever the player wrote
		if str(info.get("note_clean", "")) != "":
			text = "%s\n\n\"%s\"" % [text, info["note_clean"]]
	var card := {"title": " | ".join(tags), "description": text, "color": color,
		"footer": {"text": "NP %s | session %s" % [mp.VERSION, info.get("tag", "-")]}}
	return [made[0], card, made[2]]


func _facts(mark: String, w: Dictionary) -> String:
	var s := PackedStringArray()
	s.append("NEEDLE PARTY anonymous log, version %s, session %s" % [mp.VERSION, mark])
	s.append("sent %s UTC, up %d s" % [Time.get_datetime_string_from_system(true), (Time.get_ticks_msec() - _started) / 1000])
	s.append("")
	s.append("== session")
	s.append("role %s, players %d, over steam %s" % ["host" if mp.is_host else "guest", mp.players.size(), mp.over_steam])
	var pings: Array = []
	for id in mp.pings:
		pings.append(int(mp.pings[id]))
	pings.sort()
	s.append("pings %s" % str(pings))
	s.append("")
	s.append("== world")
	s.append(str(w))
	s.append("")
	var bd: Variant = mp.get("belt_draw")
	if bd != null and is_instance_valid(bd) and bd.has_method("report_lines"):
		s.append("== belts")
		s.append_array(bd.call("report_lines"))
		s.append("")
	s.append("== frames since the last log")
	s.append("frames %d  fps %.0f  average %.2f ms  worst %.1f ms" % [_frames, _fps(), float(_f_sum) / maxf(float(_frames), 1.0) / 1000.0, _f_max / 1000.0])
	s.append("over 16 ms: %d  33 ms: %d  50 ms: %d  100 ms: %d  250 ms: %d" % _over)
	if mp.perf_sum is Dictionary:
		s.append("")
		s.append("== the mod's own work, ms per frame")
		var names: Array = mp.perf_sum.keys()
		names.sort_custom(func(a, b): return int(mp.perf_sum[a]) > int(mp.perf_sum[b]))
		for k in names:
			s.append("  %-24s %.3f" % [k, float(mp.perf_sum[k]) / 1000.0 / maxf(float(_frames), 1.0)])
	s.append("")
	s.append("== per minute")
	s.append_array(_samples)
	s.append("")
	s.append(_pc())
	return "\n".join(s)


func _pc() -> String:
	var s := PackedStringArray()
	s.append("== engine")
	s.append("nodes %d  objects %d  video memory %.0f MB  draw calls %d" % [
		Performance.get_monitor(Performance.OBJECT_NODE_COUNT), Performance.get_monitor(Performance.OBJECT_COUNT),
		Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)])
	s.append("max fps %d  vsync %s  window mode %s  size %s" % [Engine.max_fps, DisplayServer.window_get_vsync_mode(), DisplayServer.window_get_mode(), DisplayServer.window_get_size()])
	s.append("")
	s.append("game %s" % _game_build())
	s.append("game branch %s" % (_branch if _branch != "" else "normal"))
	s.append("")
	s.append("== the kind of PC")
	s.append("%s %s" % [OS.get_name(), OS.get_version()])
	s.append("CPU %s, %d threads" % [OS.get_processor_name(), OS.get_processor_count()])
	s.append("GPU %s (%s)" % [RenderingServer.get_video_adapter_name(), RenderingServer.get_video_adapter_api_version()])
	s.append("RAM %.0f GB" % (float(OS.get_memory_info().get("physical", 0)) / 1073741824.0))
	s.append("screen %s" % DisplayServer.screen_get_size())
	return "\n".join(s)


# The game's own version text, e.g. "V66 Early Access V15.4 full".
func _game_build() -> String:
	var cfg := get_node_or_null("/root/Cfg")
	if cfg != null and cfg.has_method("build_string"):
		return str(cfg.call("build_string"))
	return "unknown"


# "V66 Early Access V15.4 full" -> "V15.4", for the card
func _short_build() -> String:
	var full := _game_build()
	var found := RegEx.create_from_string("V\\d+\\.\\d+(?:\\.\\d+)?").search_all(full)
	return (found[-1] as RegExMatch).get_string() if not found.is_empty() else full


# The last run crashed: what it left behind goes out at the next start. Only crashes
# after this feature was on: the first run has nothing to compare with.
func _send_leftovers() -> void:
	var state := ConfigFile.new()
	state.load(STATE)
	var crashes := DirAccess.get_files_at("user://crashes") if DirAccess.dir_exists_absolute("user://crashes") else PackedStringArray()
	var newest := ""
	for f in crashes:
		if str(f) > newest:
			newest = str(f)
	var seen := str(state.get_value("logs", "last_crash", "-"))
	state.set_value("logs", "last_crash", newest)
	state.save(STATE)
	if newest == "" or newest == seen or seen == "-" or _thread != null:
		return
	var game := await _game_crash_report()
	# a log on the clock may have started while the game wrote its report
	var waited := 0
	while (_thread != null or not _job.is_empty()) and waited < 120:
		await get_tree().create_timer(1.0).timeout
		waited += 1
	if _thread != null or not _job.is_empty() or not _enabled():
		return
	_note_names()
	var info := {"crash": true, "tag": "-", "why": game[0], "host": mp.is_host, "errors_before": 0,
		"game": _game_build(), "game_short": _short_build(), "branch": _branch}
	var logs := PackedStringArray([str(mp.trace.get("PREV"))])
	_thread = Thread.new()
	_thread.start(_build.bind("NEEDLE PARTY anonymous log, version %s: the last run crashed\n\n%s" % [mp.VERSION, _pc()], info, "np_crash.zip", logs, "user://crashes/" + newest, _names.keys(),
		{"crash.txt": game[1]}))


# The game writes a crash report of its own at the next start: how the run ended (a
# crash handler, a hang and where, or no shutdown at all), how long it ran, what it was
# doing, what Windows recorded (a program fault, a graphics driver reset). Our crash
# logs used to carry only the game's kept log, which a killed or crashed game has not
# written out yet: a few lines, nothing about the end. [reason, report]
var _quoted := RegEx.create_from_string("\"[^\"\\n]*\"|(?<![A-Za-z])'[^'\\n]*'")

func _game_crash_report() -> Array:
	var cr := get_node_or_null("/root/CrashReport")
	if cr == null:
		return ["", ""]
	var text := ""
	for _i in int(CRASH_WAIT_S * 2.0):
		var p: Variant = cr.get("pending")
		var busy := cr.has_method("busy") and bool(cr.call("busy"))
		if p is String and p != "" and not busy:
			text = p
			break
		await get_tree().create_timer(0.5).timeout
	if text == "" and cr.get("pending") is String:
		text = cr.get("pending")
	var reason: Variant = cr.get("pending_reason")
	var summary: Variant = cr.get("pending_summary")
	# only the game's own findings: after them it copies its log, which can hold names
	# and things players typed. Its error lines go out as errors.txt, like in every log.
	var cut := text.find("==== log")
	if cut >= 0:
		text = text.left(cut)
	var out := PackedStringArray()
	if reason is String and reason != "":
		out.append("reason: %s" % reason)
	if summary is String and summary != "":
		out.append("summary: %s" % summary)
	out.append(text)
	# quoted text could be a world's name or something else a player typed
	return [str(reason) if reason is String else "", _quoted.sub("\n".join(out), "\"…\"", true).left(MAX_TEXT)]


# ---------------------------------------------------------------- on a thread

# extra: more files for the zip, name -> text (empty ones are left out)
func _build(facts: String, info: Dictionary, file: String, logs: PackedStringArray, godot_log: String, names: Array, extra: Dictionary,
		ev_logs := PackedStringArray()) -> Variant:
	var clean := Blanker.new(names)
	var zip := ZIPPacker.new()
	if zip.open(LAST) != OK:
		return null
	# The report is all ours: numbers and the names of hardware, nothing a player chose,
	# so the player names are not looked for in it. They used to be, and a player called
	# "PC" turned the heading "the kind of PC" into "the kind of <name>".
	var report := clean.apply(facts, false)
	var bug := str(info.get("bug", ""))
	if bug != "":
		# the player's own words: names blanked like everywhere else
		var said := clean.apply(str(info.get("note", "")))
		info["note_clean"] = said
		var head := "another player reported a bug at this moment" if bug == "other" else (said if said != "" else "(no words)")
		var nl := report.find("\n")
		report = report.left(nl) + "\n\n== bug report\n" + head + "\n" + report.substr(nl)
	_add(zip, "report.txt", report)
	var trace := ""
	for f in logs:
		if FileAccess.file_exists(f):
			trace += FileAccess.get_file_as_string(f)
	_add(zip, "trace.txt", clean.apply(trace.right(MAX_TEXT)))
	var events := ""
	for f in ev_logs:
		if FileAccess.file_exists(f):
			events += FileAccess.get_file_as_string(f)
	if events != "":
		_add(zip, "items_events.txt", clean.apply(events.right(MAX_EVENTS)))
	for fname in extra:
		if str(extra[fname]) != "":
			_add(zip, str(fname), clean.apply(str(extra[fname])))
	var errors := 0
	if FileAccess.file_exists(godot_log):
		var kept := Blanker.only_errors(FileAccess.get_file_as_string(godot_log))
		errors = kept.count("\nERROR:") + kept.count("\nSCRIPT ERROR:") + kept.count("\nUSER ERROR:")
		_add(zip, "errors.txt", clean.apply(kept.right(MAX_TEXT)))
	_add(zip, "meta.json", _meta(info, errors))
	zip.close()
	return [LAST, info, file, errors]


# The card's facts once more, for a program to read: fixed keys, so whatever reads the
# channel does not have to pick numbers out of sentences. Add keys, never rename them.
func _meta(info: Dictionary, errors: int) -> String:
	var bug := str(info.get("bug", ""))
	var kind := "crash" if info.get("crash", false) else ("bug" if bug == "mine" else ("bug_other" if bug == "other" else "log"))
	var w: Dictionary = info.get("world", {})
	var m := {"format": 1, "kind": kind, "mod": str(mp.VERSION), "game": str(info.get("game_short", "")),
		"game_build": str(info.get("game", "")), "game_beta": str(info.get("branch", "")),
		"session": str(info.get("tag", "-")), "role": "host" if info.get("host", false) else "guest",
		"players": int(info.get("players", 0)), "public": bool(info.get("public", false)),
		"buildings": int(w.get("buildings", 0)), "machines": int(w.get("machines", 0)), "belts": int(w.get("belts", 0)),
		"items": int(w.get("items", 0)), "straw": int(w.get("straw", 0)),
		"fps": roundi(float(info.get("fps", 0.0))), "worst_ms": int(info.get("worst", 0)),
		"frames_over_100ms": int(info.get("over100", 0)), "errors_new": maxi(errors - int(info.get("errors_before", 0)), 0),
		"errors_in_log": errors, "up_min": int(info.get("up", 0))}
	var bm: Variant = info.get("belt", {})
	if bm is Dictionary and not (bm as Dictionary).is_empty():
		m["belt_core"] = str(bm.get("core", ""))
		m["belt_core_skip"] = str(bm.get("core_skip", ""))
		m["belt_smooth"] = str(bm.get("smooth", ""))
		m["belt_replay"] = str(bm.get("replay", ""))
		m["belt_panel"] = str(bm.get("panel", ""))
	if kind == "crash":
		m["crash_reason"] = str(info.get("why", ""))
	if bug == "mine":
		m["note"] = str(info.get("note_clean", ""))
	return JSON.stringify(m, "  ")


func _add(zip: ZIPPacker, name: String, text: String) -> void:
	zip.start_file(name)
	zip.write_file(text.to_utf8_buffer())
	zip.close_file()


# Takes out what must not leave the PC.
class Blanker:
	var _names: Array = []
	var _short: Array = []
	var _ids := RegEx.create_from_string("\\d{15,}")
	var _ips := RegEx.create_from_string("\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b")
	# one letter and a colon: a drive, not the "s:" of res://
	var _paths := RegEx.create_from_string("(?<![A-Za-z])[A-Za-z]:[\\\\/][^\\s\"'|,;)]*")

	func _init(names: Array) -> void:
		for n in names:
			var name := str(n)
			if name.length() >= 4:
				_names.append(name)
			elif name.length() >= 2:
				var re := RegEx.create_from_string("(?i)\\b" + _escaped(name) + "\\b")
				if re != null and re.is_valid():
					_short.append(re)

	func _escaped(text: String) -> String:
		var out := ""
		for c in text:
			out += ("\\" + c) if not (c.is_valid_identifier() or c.is_valid_int()) else c
		return out

	# names: also look for the player names (every text but our own report)
	func apply(text: String, names := true) -> String:
		if names:
			for n in _names:
				text = text.replacen(n, "<name>")
			for re in _short:
				text = (re as RegEx).sub(text, "<name>", true)
		text = _paths.sub(text, "<path>", true)
		text = _ids.sub(text, "<id>", true)
		return _ips.sub(text, "<ip>", true)

	# From the game's log, only these lines. The rest can hold names: who invited whom, whose yard.
	static func only_errors(text: String) -> String:
		var frame := RegEx.create_from_string("^\\[\\d+\\] ")
		var out := PackedStringArray()
		var details := false
		for line in text.split("\n"):
			var problem := line.begins_with("ERROR:") or line.begins_with("WARNING:") or line.begins_with("SCRIPT ERROR:") \
				or line.begins_with("USER ERROR:") or line.begins_with("USER WARNING:")
			if problem:
				out.append(line)
				details = true
			elif details and line.begins_with("   "):
				out.append(line)
			else:
				details = false
				if line.begins_with("[hitch]") or line.begins_with("CrashHandlerException") or line.begins_with("Engine version:") \
				or line.begins_with("Load address:") or line.begins_with("-- END OF") or frame.search(line) != null \
				or line.begins_with("GDScript backtrace") or line.begins_with("    ["):
					out.append(line)
		return "\n".join(out)


# ---------------------------------------------------------------- sending

func _post(item: Array) -> void:
	_posting = item
	_tries = 0
	_send(item)


func _send(item: Array) -> void:
	if _url != "":
		_pick_url()
	if not _enabled():
		return
	var zip := FileAccess.get_file_as_bytes(str(item[0]))
	if zip.is_empty() or zip.size() > MAX_ZIP:
		mp.trace.note("logs: not sent, %d bytes" % zip.size())
		return
	var boundary := "----needleparty%d" % Time.get_ticks_usec()
	var payload := JSON.stringify({"embeds": [item[1]], "allowed_mentions": {"parse": []}})
	var head := "--%s\r\nContent-Disposition: form-data; name=\"payload_json\"\r\nContent-Type: application/json\r\n\r\n%s\r\n--%s\r\nContent-Disposition: form-data; name=\"files[0]\"; filename=\"%s\"\r\nContent-Type: application/zip\r\n\r\n" % [boundary, payload, boundary, str(item[2])]
	var body := PackedByteArray()
	body.append_array(head.to_utf8_buffer())
	body.append_array(zip)
	body.append_array(("\r\n--%s--\r\n" % boundary).to_utf8_buffer())
	_busy = true
	if _http.request_raw(_url, PackedStringArray(["Content-Type: multipart/form-data; boundary=" + boundary]), HTTPClient.METHOD_POST, body) != OK:
		_busy = false


func _on_posted(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	_busy = false
	if result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300:
		mp.trace.note("logs: sent")
		return
	mp.trace.note("logs: not sent, result %d, http %d" % [result, code])
	# the address is gone: no point in trying again until the next start
	if code == 401 or code == 403 or code == 404:
		_url = ""
		_url_main = ""
		_url_beta = ""
		set_process(false)
		return
	_tries += 1
	if _tries < RETRIES:
		get_tree().create_timer(30.0 * _tries).timeout.connect(func() -> void:
			if not _busy and _enabled():
				_send(_posting)
		)


func _exit_tree() -> void:
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
