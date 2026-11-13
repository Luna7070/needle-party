# Find The Needle - Co-op mod, Luna7070 edition (autoload "MPMod").
# Based on AleDev11's FindTheNeedle-Coop-Mod v0.19.5 and its contributors (MIT).
# Loaded from override.cfg. Owns the ENet session, the lobby flow, the world
# hand-off and every RPC. Per-world syncing lives in mp_world.gd.
extends Node

const VERSION := "1.2.20"  # full game (app 5160800); older versions are refused at the hello
# Raised whenever what travels between PCs changes, also between test builds of one
# version: two TEST zips of 1.2.19 both said "1.2.19", a guest on the newer one waited for
# belt messages the older host never sent, and every belt jammed. Host and guest must match.
const PROTOCOL := 11
const WIRE_VERSION := VERSION + "p11"  # keep in step with PROTOCOL
# Public servers (the PUBLIC SERVERS tab, mp_ui._build_servers): off for now. The code
# stays; set this to true to bring the tab and public lobbies back.
const PUBLIC_SERVERS := true
const CREDIT := "made by Luna7070"
const DEFAULT_PORT := 7777
const MAX_PEERS := 8  # players in a session, host included (Steam counts the same way)
const WORLD_CHUNK := 60000
const SESSION_DIR := "user://mp_session"
const SETTINGS_PATH := "user://mp_settings.cfg"
const GAME_SCENE := "res://scenes/main.tscn"
const MENU_SCENE := "res://scenes/main_menu.tscn"

const COLORS := [
	Color(0.95, 0.35, 0.3), Color(0.3, 0.65, 0.98), Color(0.4, 0.85, 0.4),
	Color(0.98, 0.78, 0.25), Color(0.75, 0.45, 0.95), Color(0.3, 0.9, 0.85),
	Color(0.98, 0.55, 0.8), Color(0.9, 0.9, 0.9),
]

enum Phase { OFFLINE, HOSTING, CONNECTING, LOBBY, LOADING, IN_WORLD }

var base_dir := ""
var ui: Node = null
var world_sync: Node = null
var phase: int = Phase.OFFLINE
var is_host := false
var players := {}  # peer id -> {name, color, state}
var my_name := "Player"  # replaced by the Steam name or the saved one

var i18n: RefCounted = null  # mp_i18n.gd: UI strings in the game's language
var steam: Node = null  # mp_steam.gd: Steam relay transport (no port forwarding)
var over_steam := false  # is the current session running through Steam?
var trace: Node = null  # mp_trace.gd: what came in last, for crash reports

var _last_scene: Node = null
var _world_rx := {}
var _pending_world: Variant = null
var _mp_world_load := false  # client is loading a world sent by the host
var _world_watch: Node = null
var _steam_hosting := false  # waiting for our own lobby to be created
var _steam_joining := false  # we asked to join someone else (Steam also
# reports lobby_joined to the creator, which is not a join we should act on)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	base_dir = get_script().resource_path.get_base_dir()
	trace = load(base_dir + "/mp_trace.gd").new()
	trace.name = "MPTrace"
	trace.mp = self
	add_child(trace)
	trace.start(VERSION)
	i18n = load(base_dir + "/mp_i18n.gd").new()
	_load_settings()
	_mp_guard_online_services()
	ui = load(base_dir + "/mp_ui.gd").new()
	ui.mp = self
	add_child(ui)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	steam = load(base_dir + "/mp_steam.gd").new()
	steam.name = "MPSteam"
	add_child(steam)
	steam.lobby_created.connect(_on_steam_lobby_created)
	steam.lobby_joined.connect(_on_steam_lobby_joined)
	steam.join_requested.connect(_on_steam_join_requested)
	steam.invite_received.connect(_on_invite_received)
	_start_steam.call_deferred()
	if OS.get_environment("MP_TEST_HOST") != "" or OS.get_environment("MP_TEST_JOIN") != "" or OS.get_environment("MP_TEST_STEAM") != "" or OS.get_environment("MP_TEST_AVATAR") != "":
		# the test harness is a dev-only file and is not shipped in releases
		var test_script: Script = load(base_dir + "/mp_test.gd") if FileAccess.file_exists(base_dir + "/mp_test.gd") else null
		if test_script != null:
			var test: Node = test_script.new()
			test.mp = self
			add_child(test)
	if OS.get_environment("MP_SELFTEST") != "" and FileAccess.file_exists(base_dir + "/mp_selftest.gd"):
		# dev only, not shipped: two local copies host and join, then compare
		var st: Node = load(base_dir + "/mp_selftest.gd").new()
		st.mp = self
		add_child(st)
	# test builds only, not shipped: a test tool can drive this game (dev/mp_control.gd)
	if FileAccess.file_exists(base_dir + "/mp_control.gd") and FileAccess.file_exists(base_dir + "/ctl.cfg"):
		var ctl: Node = load(base_dir + "/mp_control.gd").new()
		ctl.mp = self
		ctl.name = "MPControl"
		add_child(ctl)
	if FileAccess.file_exists(base_dir + "/mp_report.gd"):
		# test builds only, not shipped: sends logs to the webhook in report.cfg
		var report: Node = load(base_dir + "/mp_report.gd").new()
		report.mp = self
		reporter = report
		add_child(report)
	else:
		# anonymous logs: only in a release, and see the switch below
		var logs: Node = load(base_dir + "/mp_logs.gd").new()
		logs.mp = self
		reporter = logs
		add_child(logs)
	updater = load(base_dir + "/mp_update.gd").new()
	updater.mp = self
	add_child(updater)
	if OS.get_environment("MP_PROBE") != "" and FileAccess.file_exists(base_dir + "/mp_probe.gd"):
		# dev only, not shipped: dump the game's script API for a new game build
		var probe: Node = load(base_dir + "/mp_probe.gd").new()
		probe.mp = self
		add_child(probe)
	for f in ["mp_world.gd", "mp_avatar.gd", "mp_i18n.gd", "mp_props.gd",
			"mp_machines.gd", "mp_strands.gd", "mp_contracts.gd", "mp_trace.gd", "mp_boards.gd", "mp_tables.gd"]:
		var s: Script = load(base_dir + "/" + f)
		if s == null or not s.can_instantiate():
			push_error("[MPMod] %s failed to compile" % f)
	print("[MPMod] v%s (%s) loaded from %s" % [VERSION, CREDIT, base_dir])
	_warn_other_mods.call_deferred()
	_check_for_update.call_deferred()


# ---------------------------------------------------------------- update check
# Once per start: ask GitHub for the latest release. If it is newer than this
# copy, the panel shows a button that opens the download page. Nothing is
# downloaded or installed by the mod itself.
const RELEASES_API := "https://api.github.com/repos/Luna7070/needle-party/releases/latest"
const RELEASES_PAGE := "https://github.com/Luna7070/needle-party/releases/latest"
var latest_version := ""   # set when a newer release exists
var latest_zip := ""       # its download, for the UPDATE NOW button
var latest_digest := ""
var updater: Node = null


func _check_for_update() -> void:
	var http := HTTPRequest.new()
	http.timeout = 10.0
	add_child(http)
	http.request_completed.connect(func(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
		http.queue_free()
		if result != HTTPRequest.RESULT_SUCCESS or code != 200:
			return
		var data: Variant = JSON.parse_string(body.get_string_from_utf8())
		if not (data is Dictionary):
			return
		var tag := str((data as Dictionary).get("tag_name", "")).trim_prefix("v")
		if _newer(tag, VERSION):
			latest_version = tag
			var assets: Variant = (data as Dictionary).get("assets")
			if assets is Array:
				for a in assets:
					if a is Dictionary and str(a.get("name", "")) == "NeedleParty-%s.zip" % tag:
						latest_zip = str(a.get("browser_download_url", ""))
						latest_digest = str(a.get("digest", ""))
			print("[MPMod] update available: %s (this is %s)" % [tag, VERSION])
			ui.notify(t_or("update_note", "NEEDLE PARTY %s is out - F9 to get it") % tag)
			ui.refresh())
	http.request(RELEASES_API, ["User-Agent: NeedleParty-mod", "Accept: application/vnd.github+json"])


# "1.10.0" is newer than "1.9.2"; anything not a plain number counts as 0
static func _newer(a: String, b: String) -> bool:
	var pa := a.split(".")
	var pb := b.split(".")
	for i in maxi(pa.size(), pb.size()):
		var x := int(pa[i]) if i < pa.size() and pa[i].is_valid_int() else 0
		var y := int(pb[i]) if i < pb.size() and pb[i].is_valid_int() else 0
		if x != y:
			return x > y
	return false


func open_update_page() -> void:
	OS.shell_open(RELEASES_PAGE)


# The update button, by what the update is doing.
func update_text() -> String:
	match int(updater.state):
		updater.State.DOWNLOADING:
			return t_or("update_busy", "DOWNLOADING THE UPDATE...")
		updater.State.DONE:
			return t_or("update_done", "UPDATED TO v%s  -  click to close the game, then start it again") % latest_version
		updater.State.FAILED:
			return t_or("update_failed", "UPDATE FAILED  -  click to open the download page")
	if active():
		return t_or("update_leave", "UPDATE v%s: leave the session first") % latest_version
	return t_or("update_now", "UPDATE NOW: v%s") % latest_version


func update_blocked() -> bool:
	return int(updater.state) == updater.State.DOWNLOADING or (int(updater.state) == updater.State.IDLE and active())


func update_click() -> void:
	match int(updater.state):
		updater.State.DONE:
			get_tree().quit()
		updater.State.FAILED:
			open_update_page()
		updater.State.IDLE:
			if latest_zip == "":
				open_update_page()
			else:
				updater.start(latest_zip, latest_version, latest_digest)


# Two multiplayer mods in one game fight over the same peer and the same RPC
# paths, which is the worst kind of desync. The installer removes old ones;
# this catches a copy someone added back to override.cfg by hand.
func _warn_other_mods() -> void:
	var others: Array = []
	for p in ProjectSettings.get_property_list():
		var key: String = p["name"]
		if not key.begins_with("autoload/"):
			continue
		var path := str(ProjectSettings.get_setting(key)).trim_prefix("*")
		var mp_like := key == "autoload/MPMod" or RegEx.create_from_string("(?i)(multi|co-?op|/mp)").search(path) != null
		if mp_like and (path.begins_with("res://mods/") or path.begins_with("mods/")):
			if not path.trim_prefix("res://").begins_with(base_dir.trim_prefix("res://")):
				others.append("%s (%s)" % [key.trim_prefix("autoload/"), path])
	if not others.is_empty():
		push_warning("[MPMod] other mods are loaded too: %s" % ", ".join(others))
		ui.notify("Other mods loaded: %s. Run install.bat again to remove old multiplayer mods." % ", ".join(others))


# One line in the trace for a message that just arrived: which one, from whom
# and, for the big ones, how many bytes or entries.
func _trace(what: String, size: int = -1) -> void:
	if trace == null:
		return
	var from := multiplayer.get_remote_sender_id() if multiplayer.multiplayer_peer != null else 0
	trace.rx(what, from, size)


# Stopwatch: each sync part times its own frame (see their _process) and calls
# this. Anything over PERF_SLOW_US is a visible stutter at this game's frame
# rates, so it goes into mp_trace.log by name, at most twice a second per part.
const PERF_SLOW_US := 4000
var _perf_last := {}
var perf_sum: Variant = null  # with logs on: every reading added up, per name
var reporter: Node = null     # mp_logs.gd, or in a test build mp_report.gd

func perf(what: String, usec: int) -> void:
	if perf_sum != null:
		perf_sum[what] = int(perf_sum.get(what, 0)) + usec
	if usec < PERF_SLOW_US or trace == null:
		return
	var now := Time.get_ticks_msec()
	if now - int(_perf_last.get(what, -10000)) < 500:
		return
	_perf_last[what] = now
	trace.note("slow %s %.1f ms" % [what, usec / 1000.0])


# UI string in whatever language the game is set to.
func t(key: String) -> String:
	return i18n.t(key)


func _process(_delta: float) -> void:
	var cs := get_tree().current_scene
	if cs != _last_scene:
		_last_scene = cs
		_on_scene_changed(cs)
	# the world left the tree before the game named a new scene: we run before our children
	if world_sync != null and (not is_instance_valid(world_sync.world) or not (world_sync.world as Node).is_inside_tree()):
		_stop_world_sync()
	if _world_watch != null and is_instance_valid(_world_watch) and world_sync == null:
		if bool(_world_watch.get("_built")):
			_start_world_sync(_world_watch)
	_keep_yard_running()
	_public_tick(_delta)
	_ping_tick(_delta)
	_rules_tick(_delta)


# Esc opens the game's pause menu, and with the game's "pause in menu" option
# on it stopped the whole yard. On the host that froze machines, belts and the
# pile for everybody, and on a guest its own game stood still. While a session
# runs, the menu opens over a running yard for every player, also if somebody
# turns the option on in the session. The player's own setting is put back when
# the session ends, and it is never written to settings.cfg by us.
var _pause_saved: Variant = null
var _pause_menu: Node = null
var _pause_look_at := 0

func _keep_yard_running() -> void:
	var cfg := get_node_or_null("/root/Cfg")
	var want := active() and in_world()
	if cfg != null and "pause_in_menu" in cfg:
		if want:
			if bool(cfg.get("pause_in_menu")):
				_pause_saved = true
				cfg.set("pause_in_menu", false)
				if cfg.has_signal("pause_in_menu_changed"):
					cfg.emit_signal("pause_in_menu_changed", false)
			elif _pause_saved == null:
				_pause_saved = false
		elif _pause_saved != null:
			if _pause_saved:
				cfg.set("pause_in_menu", true)
				if cfg.has_signal("pause_in_menu_changed"):
					cfg.emit_signal("pause_in_menu_changed", true)
			_pause_saved = null
	# safety net: the menu paused the tree anyway
	if want and get_tree().paused:
		var now := Time.get_ticks_msec()
		if (_pause_menu == null or not is_instance_valid(_pause_menu)) and now >= _pause_look_at:
			_pause_look_at = now + 1000
			_pause_menu = _find_pause_menu(get_tree().current_scene)
		if _pause_menu != null and _pause_menu.has_method("is_open") and bool(_pause_menu.call("is_open")):
			get_tree().paused = false


func _find_pause_menu(n: Node) -> Node:
	if n == null:
		return null
	var s: Script = n.get_script()
	if s != null and s.resource_path.ends_with("pause_menu.gd"):
		return n
	for c in n.get_children():
		var hit := _find_pause_menu(c)
		if hit != null:
			return hit
	return null


# ---------------------------------------------------------------- scenes

func is_world(n: Node) -> bool:
	# exported scripts may be remapped to .gdc, so recognise the world by its members
	return n != null and "_built" in n and "field" in n and "builds" in n


func is_menu(n: Node) -> bool:
	return n != null and (n.scene_file_path == MENU_SCENE or n.has_method("_on_multiplayer"))


var _bail_after_load := false

func _on_scene_changed(cs: Node) -> void:
	_stop_world_sync()
	_stay_last.call_deferred()
	_world_watch = null
	if _bail_after_load and is_world(cs):
		get_tree().change_scene_to_file.call_deferred(MENU_SCENE)
		return
	if is_menu(cs):
		if _bail_after_load:
			_bail_after_load = false
			SaveManager.block_save = false
		ui.hook_menu(cs)
		if active() and not is_host and phase == Phase.IN_WORLD:
			# client walked back to the title: that ends its session
			leave(t("left_game"))
		elif active() and is_host:
			# clients drop back to the lobby and get the world again when we return
			for pid in players.keys():
				if pid != 1:
					players[pid]["state"] = "lobby"
			_broadcast_host_in_world(false)
	elif is_world(cs):
		_world_watch = cs
		# a different world from a world (a load, a new pile): guests need it too
		if active() and is_host:
			for pid in players.keys():
				if pid != 1:
					players[pid]["state"] = "lobby"


func _start_world_sync(world: Node) -> void:
	trace.note("world sync starts (%s, %s)" % ["host" if is_host else "guest", "steam" if over_steam else "ip"])
	world_sync = load(base_dir + "/mp_world.gd").new()
	world_sync.name = "MPWorld"
	world_sync.mp = self
	world_sync.world = world
	add_child(world_sync)
	if not active():
		return
	if is_host:
		_public_t = PUBLIC_TICK  # the list says we are playing right away
		_broadcast_host_in_world(true)
		for pid in players.keys():
			if pid != 1 and str(players[pid].get("state", "")) != "world":
				send_world(pid)
	elif _mp_world_load:
		_mp_world_load = false
		phase = Phase.IN_WORLD
		world_sync.place_at_spawn()
		ui.notify(t("connected_yard"))
		_rx_client_ready.rpc_id(1)


# When the game quits, Godot takes the scene tree down from the last child of
# the root to the first, so a new scene (added after us) went first and the
# world was pulled down with our guest-side changes still in it: the straw
# copies we put back into the physics world by hand, the stopped machines, the
# frozen puppets. That crashed a guest on every quit. Staying the root's last
# child means we go first and undo all of it while the world is still whole.
func _stay_last() -> void:
	var root := get_tree().root
	if get_parent() == root and get_index() != root.get_child_count() - 1:
		root.move_child(self, root.get_child_count() - 1)


func _exit_tree() -> void:
	_stop_world_sync()
	restore_rules()
	# put the player's "pause in menu" choice back before the game saves settings
	var cfg := get_node_or_null("/root/Cfg")
	if cfg != null and _pause_saved != null and bool(_pause_saved):
		cfg.set("pause_in_menu", true)
		_pause_saved = null


func _stop_world_sync() -> void:
	if world_sync != null:
		world_sync.shutdown()
		# queue_free waits for the end of the frame, and its children would still run this
		# frame on a world that may already have left the tree
		world_sync.process_mode = Node.PROCESS_MODE_DISABLED
		world_sync.queue_free()
		world_sync = null


func in_world() -> bool:
	return world_sync != null


func active() -> bool:
	return phase != Phase.OFFLINE


# ---------------------------------------------------------------- Steam session
# Steam's relay does the NAT work: both players connect out to Steam, so
# nobody opens a port and friends join from the Steam friends list.

func _start_steam() -> void:
	var res: Dictionary = steam.setup(base_dir)
	print("[MPMod] steam: ", res["status"])
	if not res["ok"]:
		if _custom_name == "":
			my_name = default_name()
		ui.refresh()
		return
	if _custom_name == "":
		my_name = steam.persona.substr(0, 24)
	ui.refresh()
	# launched by accepting an invite while the game was closed
	var lobby: int = steam.lobby_from_command_line()
	if lobby != 0:
		join_steam(lobby)


func steam_ready() -> bool:
	return steam != null and steam.available


func host_steam() -> bool:
	if not steam_ready():
		ui.notify(t("steam_unavailable_long"))
		return false
	if active():
		leave()
	_steam_hosting = true
	_steam_joining = false
	steam.public_info = _next_public
	_next_public = {}
	ui.notify(t("steam_creating"))
	steam.host_lobby(MAX_PEERS)
	return true


# A public server: in the list for everyone on this mod. See mp_ui, the servers page.
var _next_public := {}
var _public_t := 0.0
const PUBLIC_TICK := 30.0

func host_public(server_name: String) -> bool:
	if not PUBLIC_SERVERS:
		_next_public = {}
		return host_steam()  # switched off: a normal friends-only game
	var shown := server_name.strip_edges().substr(0, 32)
	_next_public = {"np": "1", "np_ver": VERSION, "np_name": shown if shown != "" else t_or("server_default", "NEEDLE PARTY server")}
	return host_steam()


func _public_tick(delta: float) -> void:
	_public_t += delta
	if _public_t < PUBLIC_TICK:
		return
	_public_t = 0.0
	if not is_host or not over_steam or steam == null or steam.public_info.is_empty():
		return
	var built: Variant = world_sync.get("_bkeys") if world_sync != null else null
	steam.set_lobby_data("np_b", str((built as Dictionary).size()) if built is Dictionary else "0")
	steam.set_lobby_data("np_w", "1" if world_sync != null else "0")
	var machines := 0
	var clock: Variant = world_sync.call("_factory_clock") if world_sync != null else null
	if clock != null and is_instance_valid(clock) and clock.has_method("machine_census"):
		var census: Variant = clock.call("machine_census")
		if census is Array and not (census as Array).is_empty():
			machines = int((census as Array)[0])
	steam.set_lobby_data("np_m", str(machines))


func join_steam(lobby_id: int) -> bool:
	if not steam_ready():
		ui.notify(t("steam_unavailable"))
		return false
	if active():
		leave()
	ui.notify(t("steam_entering"))
	_steam_joining = true
	_steam_hosting = false
	phase = Phase.CONNECTING
	steam.join_lobby(lobby_id)
	ui.refresh()
	_join_try += 1
	_give_up_joining(_join_try)
	return true


# A join that never gets through (a server gone, Steam unable to connect) used to
# show "Joining the server..." for good. After JOIN_LIMIT_S it gives up and says so.
const JOIN_LIMIT_S := 20.0
var _join_try := 0


func _give_up_joining(attempt: int) -> void:
	await get_tree().create_timer(JOIN_LIMIT_S).timeout
	if attempt == _join_try and phase == Phase.CONNECTING:
		trace.note("join gave up after %d s" % int(JOIN_LIMIT_S))
		leave(t("join_timeout"))


func invite_friends() -> void:
	if steam_ready() and steam.lobby_id != 0:
		steam.invite_overlay()
	else:
		ui.notify(t("create_first"))


func _on_steam_lobby_created(ok: bool, id: int) -> void:
	if not _steam_hosting:
		return
	_steam_hosting = false
	if not ok:
		ui.notify(t("steam_create_failed"))
		return
	var peer: MultiplayerPeer = steam.make_peer()
	if peer == null:
		ui.notify(t("steam_peer_failed"))
		return
	peer.call("host_with_lobby", id)
	multiplayer.multiplayer_peer = peer
	over_steam = true
	# who hosts, for a guest that Steam will not let into the lobby (see _join_host_directly)
	steam.set_lobby_data("np_host", str(steam.steam_id))
	_become_host()
	ui.notify(t("game_created"))


func _on_steam_lobby_joined(ok: bool, id: int, reason: String) -> void:
	if not _steam_joining:
		return  # Steam tells the creator it "joined" its own lobby; ignore that
	_steam_joining = false
	if not ok:
		# (1.2.19) Steam sometimes answers "does not exist" (code 2) for a lobby that is there
		# and listed: seen between two friends' accounts, one way only. The lobby is only the
		# meeting point; the game itself goes over the Steam relay to the host, which takes
		# any connection. So: go straight to the host.
		if reason == "code 2" and await _join_host_directly(id):
			return
		# code 2: it does not exist any more, an old invite from before the host restarted
		leave(t("steam_join_gone") if reason == "code 2" else t("steam_join_failed") % reason)
		return
	var peer: MultiplayerPeer = steam.make_peer()
	if peer == null:
		leave(t("steam_peer_failed"))
		return
	peer.call("connect_to_lobby", id)
	multiplayer.multiplayer_peer = peer
	over_steam = true
	is_host = false
	phase = Phase.CONNECTING
	ui.refresh()


# The host's Steam id: from the lobby's data (it is readable without being in the lobby,
# after a lookup), else from the invite that brought us here.
func _join_host_directly(lobby: int) -> bool:
	var st: Object = steam.get("steam")
	var host := 0
	for attempt in 2:
		host = str(st.call("getLobbyData", lobby, "np_host")).to_int()
		if host != 0:
			break
		st.call("requestLobbyData", lobby)
		await get_tree().create_timer(2.0).timeout
	if host == 0 and int(pending_invite.get("lobby", 0)) == lobby:
		host = int(pending_invite.get("from", 0))
	if host == 0 or host == int(steam.steam_id):
		return false
	var peer: MultiplayerPeer = steam.make_peer()
	if peer == null or int(peer.call("create_client", host, 0)) != OK:
		return false
	trace.note("lobby refused us: straight to the host over the relay")
	multiplayer.multiplayer_peer = peer
	over_steam = true
	is_host = false
	phase = Phase.CONNECTING
	_join_try += 1
	_give_up_joining(_join_try)
	ui.refresh()
	return true


func _on_steam_join_requested(lobby_id: int) -> void:
	# invite accepted (overlay or friends list) while the game is running
	pending_invite = {}
	join_steam(lobby_id)


# ---------------------------------------------------------------- invites in game

var pending_invite := {}  # {lobby, from, name, at} while an invite waits for an answer
const INVITE_KEEP_MS := 120000

func _on_invite_received(inviter: int, lobby_id: int) -> void:
	var who: String = steam.name_of(inviter)
	pending_invite = {"lobby": lobby_id, "from": inviter, "name": who, "at": Time.get_ticks_msec()}
	ui.notify(t_or("invite_got", "%s invited you to NEEDLE PARTY!  Press F10 to join") % who)
	ui.refresh()


func has_invite() -> bool:
	if pending_invite.is_empty():
		return false
	if Time.get_ticks_msec() - int(pending_invite["at"]) > INVITE_KEEP_MS:
		pending_invite = {}
		return false
	return true


func accept_invite() -> void:
	if not has_invite():
		return
	var lobby := int(pending_invite["lobby"])
	pending_invite = {}
	join_steam(lobby)


# Invite one Steam friend from the in-game list.
func invite_friend(friend_id: int, friend_name: String) -> void:
	if not (steam_ready() and steam.lobby_id != 0):
		ui.notify(t("create_first"))
		return
	if steam.invite(friend_id):
		ui.notify(t_or("invite_sent", "Invite sent to %s") % friend_name)
	else:
		ui.notify(t_or("invite_failed", "Could not invite %s") % friend_name)


# A string from mp_i18n, or English when this key is new and not translated yet.
func t_or(key: String, fallback: String) -> String:
	var s := t(key)
	return fallback if s == "" or s == key else s


# ---------------------------------------------------------------- session

func _become_host() -> void:
	is_host = true
	phase = Phase.HOSTING
	# (log v2) one name for this session in every PC's log: it goes out with the pings
	trace.session = "%08x" % (str(Time.get_unix_time_from_system()).hash() & 0xffffffff)
	trace.call("_clock_line")
	players = {1: {"name": my_name, "color": COLORS[0], "state": "world" if in_world() else "menu"}}
	_mp_guard_online_services()
	if world_sync != null:
		world_sync.rebaseline()
		world_sync.apply_session_rules()
	if not in_world():
		ui.notify(t("now_load"))
	ui.refresh()


func host(port: int) -> bool:
	if active():
		leave()
	var peer := ENetMultiplayerPeer.new()
	# two test copies on one PC: inside this PC only, so Windows does not ask about its firewall
	if OS.get_environment("MP_SELFTEST") != "":
		peer.set_bind_ip("127.0.0.1")
	var err := peer.create_server(port, MAX_PEERS - 1)
	if err != OK:
		ui.notify(t("port_failed") % [port, err])
		return false
	multiplayer.multiplayer_peer = peer
	over_steam = false
	_save_settings()
	ui.notify(t("server_open") % port)
	_become_host()
	return true


func join(ip: String, port: int) -> bool:
	if active():
		leave()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	if err != OK:
		ui.notify(t("peer_failed") % err)
		return false
	multiplayer.multiplayer_peer = peer
	over_steam = false
	is_host = false
	phase = Phase.CONNECTING
	_save_settings()
	ui.notify(t("connecting"))  # no addresses on screen: people stream this
	ui.refresh()
	return true


func leave(reason: String = "") -> void:
	trace.note("leave session")
	var was_client := active() and not is_host
	var was_in_mp_world := was_client and in_world()
	# the host's world is still loading: it arrives after we have left, see
	# _on_scene_changed. Nothing may save until it is gone.
	var was_loading := was_client and _mp_world_load
	# the host plays on in this world: the guests' items must not stay frozen
	# copies, their straw must go and the needles they held come back
	if active() and is_host and world_sync != null:
		for pid in players.keys():
			if int(pid) != 1:
				world_sync.forget_peer(int(pid))
	if multiplayer.multiplayer_peer != null and not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer):
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	if steam_ready():
		steam.leave_lobby()
	over_steam = false
	_steam_hosting = false
	_steam_joining = false
	phase = Phase.OFFLINE
	is_host = false
	players.clear()
	pings.clear()
	restore_rules()
	_rules_hash = 0
	_world_rx.clear()
	_mp_world_load = false
	if world_sync != null:
		world_sync.clear_avatars()
	if was_client:
		SaveManager.block_save = was_loading
		_bail_after_load = was_loading
		SaveManager.use_player_saves()
	release_profile()
	if reason != "":
		ui.notify(reason)
	ui.refresh()
	if was_in_mp_world:
		# the client's world is a borrowed copy; never let it linger or save
		get_tree().change_scene_to_file(MENU_SCENE)


func _mp_guard_online_services() -> void:
	# keep modded runs off the public leaderboard
	var lb := get_node_or_null("/root/Leaderboard")
	if lb != null and "enabled" in lb:
		lb.enabled = false


# Career stats. The shared GameState carries everyone's digging, selling and
# needles, and the game's Profile adds up whatever GameState gains, so a
# session would credit each player with the whole team's work. While a session
# runs the profile is held: pending stats are written first, then nothing is
# saved; when the session ends the profile is read back from disk, which drops
# the team's totals, and the yard is re-baselined so solo play counts again.
var _profile_held := false


func hold_profile() -> void:
	if _profile_held:
		return
	var pf := get_node_or_null("/root/Profile")
	if pf == null or not ("_inert" in pf):
		return
	if not bool(pf.get("_inert")) and pf.has_method("save_profile"):
		pf.save_profile()
	pf.set("_inert", true)
	_profile_held = true


func release_profile() -> void:
	if not _profile_held:
		return
	_profile_held = false
	var pf := get_node_or_null("/root/Profile")
	if pf == null:
		return
	pf.set("_inert", false)
	if pf.has_method("load_profile"):
		pf.load_profile()
	if in_world() and bool(pf.get("_in_yard")) and pf.has_method("enter_yard"):
		pf.enter_yard()


func _on_peer_connected(id: int) -> void:
	trace.note("peer %d connected" % id)
	if is_host:
		print("[MPMod] peer %d connected" % id)


func _on_peer_disconnected(id: int) -> void:
	trace.note("peer %d disconnected" % id)
	if players.has(id):
		ui.notify(t("left") % players[id]["name"], players[id]["color"])
		players.erase(id)
	if world_sync != null:
		world_sync.remove_avatar(id)
		# everyone, not only the host: their straw copies would stay for good
		world_sync.forget_peer(id)
	if is_host:
		_rx_players.rpc(players)
	ui.refresh()


func _on_connected() -> void:
	phase = Phase.LOBBY
	ui.notify(t("connected_waiting"))
	_rx_hello.rpc_id(1, my_name, WIRE_VERSION)
	ui.refresh()


func _on_connection_failed() -> void:
	leave(t("connect_failed"))


func _on_server_disconnected() -> void:
	trace.note("lost the host")
	leave(t("host_closed"))


func _broadcast_host_in_world(on: bool) -> void:
	# a public server's card says "Playing" at once, not up to PUBLIC_TICK later
	_public_t = PUBLIC_TICK
	if players.has(1):
		players[1]["state"] = "world" if on else "menu"
	_rx_players.rpc(players)
	ui.refresh()


func player_name(id: int) -> String:
	if players.has(id):
		return str(players[id]["name"])
	return t("player_fallback") % id


func player_color(id: int) -> Color:
	if players.has(id):
		return players[id]["color"]
	return Color.WHITE


# ---------------------------------------------------------------- lobby RPCs

@rpc("any_peer", "call_remote", "reliable")
func _rx_hello(pname: String, ver: String) -> void:
	_trace("hello")
	if not is_host:
		return
	var id := multiplayer.get_remote_sender_id()
	if ver != WIRE_VERSION:
		_rx_kick.rpc_id(id, t("version_mismatch") % [WIRE_VERSION, ver])
		return
	if bans.has(_ban_key(id, pname)):
		trace.note("banned player %d turned away" % id)
		_rx_kick.rpc_id(id, t("you_banned"))
		_drop_later(id)
		return
	var used := {}
	for p in players.values():
		used[p["color"]] = true
	var col: Color = COLORS[players.size() % COLORS.size()]
	for c in COLORS:
		if not used.has(c):
			col = c
			break
	pname = pname.strip_edges().substr(0, 24)
	if pname == "":
		pname = t("player_fallback") % id
	players[id] = {"name": pname, "color": col, "state": "lobby"}
	ui.notify(t("joined") % pname, col)
	_rx_players.rpc(players)
	ui.refresh()
	if in_world():
		send_world(id)


@rpc("authority", "call_remote", "reliable")
func _rx_kick(reason: String) -> void:
	_trace("kick")
	leave(reason)


# ---------------------------------------------------------------- kick and ban
# The host sends a player away (kick) or keeps them out of games hosted on this PC
# for good (ban). Over Steam a ban sticks to the Steam account, so a new name does
# not get them back in; over a direct connection there is only the name. The list
# stays on this PC (mp_settings.cfg), nowhere else.
const KICK_DROP_S := 1.0  # asked to leave first, then cut off whatever they do

var bans := {}  # ban key -> the name they had


func _ban_key(id: int, pname := "") -> String:
	var mpp := multiplayer.multiplayer_peer
	if over_steam and mpp != null and mpp.has_method("get_steam_id_for_peer_id"):
		var sid := int(mpp.call("get_steam_id_for_peer_id", id))
		if sid != 0:
			return "s:%d" % sid
	var n := pname if pname != "" else str((players.get(id, {}) as Dictionary).get("name", ""))
	n = n.strip_edges().to_lower()
	return "n:" + n if n != "" else ""


func kick(id: int, ban := false) -> void:
	if not is_host or id == 1 or not players.has(id):
		return
	var who := player_name(id)
	if ban:
		var key := _ban_key(id)
		if key != "":
			bans[key] = who
			_save_settings()
	trace.note("%s player %d" % ["banned" if ban else "kicked", id])
	_rx_kick.rpc_id(id, t("you_banned") if ban else t("you_kicked"))
	ui.notify((t("banned_note") if ban else t("kicked_note")) % who)
	_drop_later(id)


func _drop_later(id: int) -> void:
	await get_tree().create_timer(KICK_DROP_S).timeout
	var mpp := multiplayer.multiplayer_peer
	if is_host and mpp != null and id in multiplayer.get_peers():
		mpp.disconnect_peer(id)


func clear_bans() -> void:
	bans.clear()
	_save_settings()
	ui.refresh()


@rpc("authority", "call_remote", "reliable")
func _rx_players(list: Dictionary) -> void:
	_trace("players", list.size())
	var before := players.keys()
	players = list
	if world_sync != null:
		for id in before:
			if not players.has(id):
				world_sync.remove_avatar(id)
	if not is_host and players.has(1) and phase == Phase.IN_WORLD and in_world() 	and str(players[1].get("state", "")) == "menu":
		phase = Phase.LOBBY
		SaveManager.block_save = false
		SaveManager.use_player_saves()
		ui.notify(t("host_back_menu"))
		get_tree().change_scene_to_file(MENU_SCENE)
	elif not is_host and players.has(1) and phase == Phase.LOBBY:
		if str(players[1].get("state", "")) != "world":
			ui.set_status(t("host_in_menu"))
	ui.refresh()


@rpc("any_peer", "call_remote", "reliable")
func _rx_client_ready() -> void:
	_trace("client_ready")
	if not is_host:
		return
	var id := multiplayer.get_remote_sender_id()
	if players.has(id):
		players[id]["state"] = "world" if in_world() else "lobby"
		_rx_players.rpc(players)
	if world_sync != null:
		world_sync.send_full_sync(id)
	ui.refresh()


@rpc("any_peer", "call_remote", "reliable")
func _rx_chat(text: String) -> void:
	_trace("chat")
	var id := multiplayer.get_remote_sender_id()
	ui.chat_line(player_name(id), player_color(id), text.substr(0, 200))


func send_chat(text: String) -> void:
	text = text.strip_edges()
	if text == "" or not active():
		return
	_rx_chat.rpc(text)
	ui.chat_line(my_name, player_color(multiplayer.get_unique_id()), text)


# ---------------------------------------------------------------- world hand-off

func send_world(id: int) -> void:
	if world_sync == null:
		return
	var payload: Dictionary = world_sync.build_payload(id)
	var raw := var_to_bytes(payload)
	var packed := raw.compress(FileAccess.COMPRESSION_ZSTD)
	var n := int(ceil(float(packed.size()) / WORLD_CHUNK))
	if players.has(id):
		players[id]["state"] = "loading"
	# no more poses come while it loads: no farmer standing frozen meanwhile
	world_sync.remove_avatar(id)
	print("[MPMod] sending world to %d: %d KB (%d KB raw), %d chunks" % [id, packed.size() / 1024, raw.size() / 1024, n])
	_rx_world_begin.rpc_id(id, raw.size(), packed.size(), n)
	for i in n:
		_rx_world_chunk.rpc_id(id, i, packed.slice(i * WORLD_CHUNK, mini((i + 1) * WORLD_CHUNK, packed.size())))
	_rx_world_end.rpc_id(id)


@rpc("authority", "call_remote", "reliable", 1)
func _rx_world_begin(raw_size: int, packed_size: int, chunks: int) -> void:
	_trace("world_begin")
	_world_rx = {"raw": raw_size, "size": packed_size, "n": chunks, "parts": {}}
	phase = Phase.LOADING
	ui.set_status(t("receiving_world"))
	ui.set_progress(0.0)


@rpc("authority", "call_remote", "reliable", 1)
func _rx_world_chunk(i: int, data: PackedByteArray) -> void:
	_trace("world_chunk", data.size())
	if _world_rx.is_empty():
		return
	_world_rx["parts"][i] = data
	ui.set_progress(float(_world_rx["parts"].size()) / maxf(1.0, float(_world_rx["n"])))


@rpc("authority", "call_remote", "reliable", 1)
func _rx_world_end() -> void:
	_trace("world_end")
	if _world_rx.is_empty():
		return
	var packed := PackedByteArray()
	for i in int(_world_rx["n"]):
		if not _world_rx["parts"].has(i):
			leave(t("world_incomplete"))
			return
		packed.append_array(_world_rx["parts"][i])
	var raw := packed.decompress(int(_world_rx["raw"]), FileAccess.COMPRESSION_ZSTD)
	_world_rx.clear()
	var payload: Variant = bytes_to_var(raw)
	if typeof(payload) != TYPE_DICTIONARY:
		leave(t("world_unreadable"))
		return
	ui.set_progress(-1.0)
	_enter_mp_world(payload)


func _enter_mp_world(payload: Dictionary) -> void:
	_stop_world_sync()
	# Coming from a world (RESYNC, a new pile): the old one stays up for some seconds while the
	# new one loads. It must not be taken for the new one: the sync started on it, told the host
	# "ready", the items and tables went into the old world, and the new one never got them.
	_world_watch = null
	# before the yard loads, so splitters are built the host's way
	apply_rules(payload.get("mp_rules"))
	SaveManager.use_scratch_dir(SESSION_DIR)
	var path := SaveManager.slot_path(0)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		leave(t("world_write_failed") % FileAccess.get_open_error())
		return
	f.store_var(payload, true)
	f.close()
	SaveManager.block_save = false
	SaveManager.begin_load(0)
	_mp_world_load = true
	phase = Phase.LOADING
	ui.set_status(t("loading_world"))
	ui.close_panel()
	Loading.show_screen("FIND THE NEEDLE", t("entering_yard") % player_name(1).to_upper())
	Loading.enter_scene(GAME_SCENE)


# Host: re-send the whole world to every client (after a new pile, or on demand).
func resync_all() -> void:
	if not is_host or world_sync == null:
		return
	for pid in players.keys():
		if pid != 1:
			send_world(pid)


@rpc("any_peer", "call_remote", "reliable")
func _rx_request_world() -> void:
	_trace("request_world")
	if is_host and world_sync != null:
		send_world(multiplayer.get_remote_sender_id())


func request_resync() -> void:
	if not active():
		return
	if is_host:
		resync_all()
		ui.notify(t("resyncing_all"))
	else:
		_rx_request_world.rpc_id(1)
		ui.notify(t("asking_world"))


# ---------------------------------------------------------------- in-world RPCs (forwarded to mp_world)

# Plain unreliable: GodotSteam sends "unreliable_ordered" as RELIABLE, so a
# lost pose held up every pose after it. A pose is replaced 10x a second, so a
# lost or late one does not matter.
@rpc("any_peer", "call_remote", "unreliable", 2)
func _rx_pose(stamp: int, pos: Vector3, yaw: float, pitch: float, tool: int, crouch: float, moving: float, hands: int) -> void:
	if world_sync != null:
		world_sync.on_pose(multiplayer.get_remote_sender_id(), pos, yaw, pitch, tool, crouch, moving, hands, stamp)


# ---------------------------------------------------------------- yard rules
# Settings from the game's [yard] options that change how the shared world
# behaves. Each player's own values used to apply: a guest whose game cleans up
# loose items deleted things the host keeps, a different belt cap or decay made
# belts disagree, "always day" on one side fought the day sync, and a different
# T-splitter size built different splitters. In a session the host's values
# apply to everyone. They are set in memory only (never written to the guest's
# settings file) and the guest's own come back when the session ends.
const RULE_KEYS := ["prop_decay", "prop_cap", "belt_cap", "belt_decay", "auto_clean",
	"auto_clean_seconds", "always_day", "t_splitter_port_r"]
var _rules_saved := {}
var _rules_hash := 0
var _rules_t := 0.0


func host_rules() -> Dictionary:
	var out := {}
	var cfg := get_node_or_null("/root/Cfg")
	if cfg == null:
		return out
	for k in RULE_KEYS:
		if k in cfg:
			out[k] = cfg.get(k)
	return out


func apply_rules(d: Variant) -> void:
	if is_host or not (d is Dictionary):
		return
	var cfg := get_node_or_null("/root/Cfg")
	if cfg == null:
		return
	for k in d:
		if not RULE_KEYS.has(k) or not (k in cfg):
			continue
		if not _rules_saved.has(k):
			_rules_saved[k] = cfg.get(k)
		if cfg.get(k) == d[k]:
			continue
		cfg.set(k, d[k])
		_rule_changed(cfg, k)


func restore_rules() -> void:
	var cfg := get_node_or_null("/root/Cfg")
	if cfg != null:
		for k in _rules_saved:
			if cfg.get(k) != _rules_saved[k]:
				cfg.set(k, _rules_saved[k])
				_rule_changed(cfg, k)
	_rules_saved.clear()


func _rule_changed(cfg: Node, k: String) -> void:
	if k == "always_day" and cfg.has_signal("always_day_changed"):
		cfg.emit_signal("always_day_changed", cfg.get(k))
	elif k == "t_splitter_port_r" and cfg.has_signal("t_splitter_size_changed"):
		cfg.emit_signal("t_splitter_size_changed", cfg.get(k))


func _rules_tick(delta: float) -> void:
	if not is_host or players.size() < 2:
		return
	_rules_t += delta
	if _rules_t < 2.0:
		return
	_rules_t = 0.0
	var r := host_rules()
	var h := r.hash()
	if h != _rules_hash:
		_rules_hash = h
		_rx_rules.rpc(r)


@rpc("authority", "call_remote", "reliable", 0)
func _rx_rules(rules: Dictionary) -> void:
	_trace("rules", rules.size())
	apply_rules(rules)


# ---------------------------------------------------------------- ping
# The host pings every guest once a second on its own unreliable channel (so
# it never waits behind world traffic), keeps a smoothed round trip per guest
# and shares the table every 2 s. Shown on the Tab list.
var pings := {}       # peer id -> ms to the host (host: 0)
var _ping_t := 0.0
var _pings_out_t := 0.0
const PING_CHANNEL := 4

func _ping_tick(delta: float) -> void:
	if not is_host or not active() or multiplayer.multiplayer_peer == null:
		return
	_ping_t += delta
	_pings_out_t += delta
	if _ping_t >= 1.0:
		_ping_t = 0.0
		for pid in players.keys():
			if int(pid) != 1:
				_rx_ping.rpc_id(int(pid), Time.get_ticks_usec(), str(trace.session))
	if _pings_out_t >= 2.0:
		_pings_out_t = 0.0
		pings[1] = 0
		for pid in pings.keys():
			if not players.has(pid):
				pings.erase(pid)
		if players.size() > 1:
			_rx_pings.rpc(pings)


@rpc("authority", "call_remote", "unreliable", 4)
func _rx_ping(stamp: int, session: String) -> void:
	_rx_pong.rpc_id(1, stamp)
	# (log v2) the host's clock and session, for the clock lines that put both logs on one axis
	trace.host_ping(stamp / 1000, session)


@rpc("any_peer", "call_remote", "unreliable", 4)
func _rx_pong(stamp: int) -> void:
	if not is_host:
		return
	var id := multiplayer.get_remote_sender_id()
	var ms := float(Time.get_ticks_usec() - stamp) / 1000.0
	if ms < 0.0 or ms > 10000.0:
		return
	# smoothed, so one slow packet does not make the number jump
	pings[id] = roundi(lerpf(float(pings.get(id, ms)), ms, 0.35))


@rpc("authority", "call_remote", "reliable", 0)
func _rx_pings(table: Dictionary) -> void:
	pings = table


# A guest sold something: the host's market is the real one (see mp_tables).
@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_market_sale(sold: Dictionary, ever: Array, flat_ever: Array) -> void:
	_trace("market_sale")
	if is_host and world_sync != null and world_sync.tables_sync != null:
		world_sync.tables_sync.on_market_sale(sold, ever, flat_ever)


# One of the yard's side tables (paint, power tags, routes, clocks, plugs,
# blueprint groups) changed; see mp_tables.gd.
@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_table(table: String, data: Dictionary) -> void:
	var _t0_perf := Time.get_ticks_usec()
	_trace("market" if table == "market" else "table " + table, data.size())
	if world_sync != null and world_sync.tables_sync != null:
		world_sync.tables_sync.on_table(multiplayer.get_remote_sender_id(), table, data)
	perf("rx_table", Time.get_ticks_usec() - _t0_perf)


# The sell stand was moved (see mp_world).
@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_stand(spot: Dictionary) -> void:
	_trace("stand")
	if world_sync != null:
		world_sync.on_stand(multiplayer.get_remote_sender_id(), spot)


# Host -> guests: the time of day and moon phase (see mp_world on_day).
@rpc("authority", "call_remote", "reliable", 0)
func _rx_day(hour: float, phase: float) -> void:
	if world_sync != null:
		world_sync.on_day(hour, phase)


# A player started an emote; shown over their farmer's head.
@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_emote(emote: String) -> void:
	_trace("emote")
	if world_sync != null:
		world_sync.on_emote(multiplayer.get_remote_sender_id(), emote)


@rpc("any_peer", "call_remote", "reliable", 3)
func _rx_hay(idx: PackedInt32Array, vals: PackedFloat32Array) -> void:
	var _t0_perf := Time.get_ticks_usec()
	_trace("hay", idx.size())
	if world_sync != null:
		world_sync.on_hay(multiplayer.get_remote_sender_id(), idx, vals)
	perf("rx_hay", Time.get_ticks_usec() - _t0_perf)


# Host -> guest: a checksum per block of the pile, so a guest can find where it
# drifted from the host and ask for just those blocks.
@rpc("authority", "call_remote", "reliable", 3)
func _rx_hay_sums(sums: PackedFloat32Array) -> void:
	var _t0_perf := Time.get_ticks_usec()
	_trace("hay_sums", sums.size())
	if world_sync != null:
		world_sync.on_hay_sums(sums)
	perf("rx_hay_sums", Time.get_ticks_usec() - _t0_perf)


@rpc("any_peer", "call_remote", "reliable", 3)
func _rx_hay_want(blocks: PackedInt32Array) -> void:
	_trace("hay_want", blocks.size())
	if is_host and world_sync != null:
		world_sync.on_hay_want(multiplayer.get_remote_sender_id(), blocks)


# Do we still have the same buildings? See mp_world.on_builds_check.
@rpc("authority", "call_remote", "reliable", 0)
func _rx_builds_check(total: int) -> void:
	if world_sync != null:
		world_sync.on_builds_check(total)


@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_builds_list_ask() -> void:
	_trace("builds_list_ask")
	if world_sync != null and is_host:
		world_sync.on_builds_list_ask(multiplayer.get_remote_sender_id())


@rpc("authority", "call_remote", "reliable", 0)
func _rx_builds_list(keys: PackedStringArray) -> void:
	_trace("builds_list", keys.size())
	if world_sync != null:
		world_sync.on_builds_list(keys)


@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_builds_want(keys: PackedStringArray) -> void:
	_trace("builds_want", keys.size())
	if world_sync != null and is_host:
		world_sync.on_builds_want(multiplayer.get_remote_sender_id(), keys)


@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_builds(adds: Array, removes: Array) -> void:
	var _t0_perf := Time.get_ticks_usec()
	_trace("builds", adds.size())
	if world_sync != null:
		world_sync.on_builds(adds, removes)
	perf("rx_builds", Time.get_ticks_usec() - _t0_perf)


@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_state_delta(seq: int, delta: Dictionary) -> void:
	var _t0_perf := Time.get_ticks_usec()
	_trace("state_delta", delta.size())
	if is_host and world_sync != null:
		world_sync.on_state_delta(multiplayer.get_remote_sender_id(), seq, delta)
	perf("rx_state_delta", Time.get_ticks_usec() - _t0_perf)


@rpc("authority", "call_remote", "reliable", 0)
func _rx_state_snap(ack: int, snap: Dictionary) -> void:
	var _t0_perf := Time.get_ticks_usec()
	_trace("state_snap", snap.size())
	if world_sync != null:
		world_sync.on_state_snap(ack, snap)
	perf("rx_state_snap", Time.get_ticks_usec() - _t0_perf)


@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_tech(id: String, rank: int, paid: bool) -> void:
	_trace("tech")
	if world_sync != null:
		world_sync.on_tech(multiplayer.get_remote_sender_id(), id, rank, paid)


@rpc("authority", "call_remote", "reliable", 0)
func _rx_full_sync(heights: PackedFloat32Array, builds: Array, tech: Dictionary, needles: Array) -> void:
	var _t0_perf := Time.get_ticks_usec()
	_trace("full_sync", heights.size())
	if world_sync != null:
		world_sync.on_full_sync(heights, builds, tech, needles)
	perf("rx_full_sync", Time.get_ticks_usec() - _t0_perf)


@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_new_pile_request(on_credit: bool) -> void:
	_trace("new_pile_request")
	if is_host and world_sync != null:
		world_sync.host_new_pile_for_client(multiplayer.get_remote_sender_id(), on_credit)


# Host -> everyone: what happened to a loose needle. The host decides who holds
# it, so two players grabbing the same needle cannot both hand it in.
@rpc("authority", "call_remote", "reliable", 3)
func _rx_needle(kind: String, idx: int, pos: Vector3, holder: int) -> void:
	_trace("needle")
	if world_sync != null:
		world_sync.on_needle(kind, idx, pos, holder)


# Guest -> host: a guest picked a needle up, put it down or used it up.
@rpc("any_peer", "call_remote", "reliable", 3)
func _rx_needle_req(kind: String, idx: int, pos: Vector3) -> void:
	_trace("needle_req")
	if is_host and world_sync != null:
		world_sync.on_needle_req(multiplayer.get_remote_sender_id(), kind, idx, pos)


@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_event(kind: String, data: Dictionary) -> void:
	_trace("event", data.size())
	if world_sync != null:
		world_sync.on_event(multiplayer.get_remote_sender_id(), kind, data)


# ---------------------------------------------------------------- loose items

func _props() -> Node:
	if world_sync == null:
		return null
	return world_sync.props_sync


@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_prop_add(id: int, item_id: String, xf: Transform3D, state: Dictionary) -> void:
	_trace("prop_add", state.size())
	var p := _props()
	if p != null:
		p.on_add(multiplayer.get_remote_sender_id(), id, item_id, xf, state)


@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_prop_del(ids: PackedInt64Array) -> void:
	_trace("prop_del", ids.size())
	var p := _props()
	if p != null:
		p.on_del(ids)


# The host: these items are gone, and why (belt_eaten, machine, sold, despawn, picked, other).
# Like _rx_prop_del (which a guest uses for its own), with the reason for the item log.
@rpc("authority", "call_remote", "reliable", 0)
func _rx_prop_del_why(ids: PackedInt64Array, why: String) -> void:
	_trace("prop_del", ids.size())
	var p := _props()
	if p != null:
		p.on_del(ids, why)


# The host: these items went onto one of its belts and are rows now. Like _rx_prop_del, but
# a guest keeps showing each until the row arrives (mp_props.on_boarded).
@rpc("authority", "call_remote", "reliable", 0)
func _rx_prop_boarded(ids: PackedInt64Array) -> void:
	_trace("prop_boarded", ids.size())
	var p := _props()
	if p != null:
		p.on_boarded(ids)


@rpc("any_peer", "call_remote", "unreliable_ordered", 0)
func _rx_prop_move(ids: PackedInt64Array, xfs: Array) -> void:
	var _t0_perf := Time.get_ticks_usec()
	_trace("prop_move", ids.size())
	var p := _props()
	if p != null:
		p.on_move(multiplayer.get_remote_sender_id(), ids, xfs)
	perf("rx_prop_move", Time.get_ticks_usec() - _t0_perf)


@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_prop_state(ids: PackedInt64Array, states: Array) -> void:
	_trace("prop_state", ids.size())
	var p := _props()
	if p != null:
		p.on_state(multiplayer.get_remote_sender_id(), ids, states)


@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_prop_claim(id: int) -> void:
	_trace("prop_claim")
	var p := _props()
	if p != null:
		p.on_claim(multiplayer.get_remote_sender_id(), id)


# A log starts on every PC at once, so they show the same moment.
@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_report_mark(mark: String, why: String, unix: float) -> void:
	if reporter != null:
		reporter.call("on_mark", mark, why, unix, multiplayer.get_remote_sender_id())


# A guest took something off a belt (see mp_props._watch_aim).
@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_belt_take(id: int, kind: int, at: Vector3, seq: int) -> void:
	_trace("belt_take")
	var p := _props()
	if p != null and is_host:
		p.on_belt_take(id, kind, at, seq)


# The host: this item does not exist any more.
@rpc("authority", "call_remote", "reliable", 0)
func _rx_prop_gone(id: int) -> void:
	_trace("prop_gone")
	var p := _props()
	if p != null:
		p.on_gone(id)


# A bucket's old owner: what it really held as it changed hands.
@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_prop_fill(id: int, stored: int) -> void:
	_trace("prop_fill")
	var p := _props()
	if p != null:
		p.on_fill(id, stored)


# Where an item came to rest, once more and reliably (moves can get lost).
@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_prop_rest(ids: PackedInt64Array, xfs: Array) -> void:
	_trace("prop_rest", ids.size())
	var p := _props()
	if p != null:
		p.on_move(multiplayer.get_remote_sender_id(), ids, xfs)


# A guest's belt took one of its items. Only the host's belts count, so the
# host puts its own copy down there instead.
@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_prop_board(id: int, xf: Transform3D) -> void:
	_trace("prop_board")
	var p := _props()
	if p != null and is_host:
		p.on_board(multiplayer.get_remote_sender_id(), id, xf)


# A guest let go of one of its items (dropped or thrown). The host's world is
# the one where machines, belts, hoppers and the contract truck run, so the
# host takes it over there with the same speed and spin; from then on it is a
# real item on the host and everyone sees the host's copy.
# A guest's wheelbarrow wants into the dump hatch at `at` (mp_props on_hatch_load).
# Same channel as _rx_prop_drop, which hands it over just before.
@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_hatch_load(id: int, at: Vector3) -> void:
	_trace("hatch_load")
	var p := _props()
	if p != null and is_host:
		p.on_hatch_load(multiplayer.get_remote_sender_id(), id, at)


@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_prop_drop(id: int, xf: Transform3D, vel: Vector3, spin: Vector3) -> void:
	_trace("prop_drop")
	var p := _props()
	if p != null and is_host:
		p.on_drop(multiplayer.get_remote_sender_id(), id, xf, vel, spin)


@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_prop_want(ids: PackedInt64Array) -> void:
	_trace("prop_want", ids.size())
	var p := _props()
	if p != null:
		p.on_want(multiplayer.get_remote_sender_id(), ids)


@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_prop_census(ids: PackedInt64Array, have: PackedInt64Array) -> void:
	_trace("prop_census", ids.size())
	var p := _props()
	if p != null:
		p.on_census(multiplayer.get_remote_sender_id(), ids, have)


# The host: who owns this item, when two claims crossed or somebody asked.
@rpc("authority", "call_remote", "reliable", 0)
func _rx_prop_owner(id: int, owner: int) -> void:
	_trace("prop_owner")
	var p := _props()
	if p != null:
		p.on_owner(id, owner)


# Somebody is not sure who owns these items: the host says.
@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_prop_ask(ids: PackedInt64Array) -> void:
	_trace("prop_ask", ids.size())
	var p := _props()
	if p != null and is_host:
		p.on_ask(multiplayer.get_remote_sender_id(), ids)


@rpc("authority", "call_remote", "reliable", 0)
func _rx_prop_reset(first: bool, ids: PackedInt64Array, owners: PackedInt32Array, entries: Array) -> void:
	var _t0_perf := Time.get_ticks_usec()
	_trace("prop_reset", ids.size())
	var p := _props()
	if p != null:
		p.on_reset(first, ids, owners, entries)
	perf("rx_prop_reset", Time.get_ticks_usec() - _t0_perf)


@rpc("authority", "call_remote", "reliable", 0)
func _rx_prop_reset_end() -> void:
	_trace("prop_reset_end")
	var p := _props()
	if p != null:
		p.on_reset_end()


@rpc("authority", "call_remote", "reliable", 0)
func _rx_belts(packed: PackedByteArray, raw_size: int) -> void:
	var _t0_perf := Time.get_ticks_usec()
	_trace("belts", packed.size())
	if world_sync == null or world_sync.belts_sync == null:
		return
	world_sync.belts_sync.on_belts(packed, raw_size)
	perf("rx_belts", Time.get_ticks_usec() - _t0_perf)


# ---------------------------------------------------------------- machines

# unreliable for the same reason as poses; the 2 s full refresh on the
# reliable channel puts right anything a lost packet missed
@rpc("authority", "call_remote", "unreliable", 0)
func _rx_machines(packed: PackedByteArray, raw_size: int) -> void:
	var _t0_perf := Time.get_ticks_usec()
	_trace("machines", packed.size())
	if world_sync == null or world_sync.machines_sync == null:
		return
	world_sync.machines_sync.on_poses(packed, raw_size)
	perf("rx_machines", Time.get_ticks_usec() - _t0_perf)


# The same, for batches too big for one packet (a lost fragment would drop the
# whole batch on the unreliable channel) and the periodic full refresh. Channel
# 1 only carries the world at join time, so this never holds up anything else.
@rpc("authority", "call_remote", "reliable", 1)
func _rx_machines_big(packed: PackedByteArray, raw_size: int) -> void:
	var _t0_perf := Time.get_ticks_usec()
	_trace("machines_big", packed.size())
	if world_sync == null or world_sync.machines_sync == null:
		return
	world_sync.machines_sync.on_poses(packed, raw_size)
	perf("rx_machines_big", Time.get_ticks_usec() - _t0_perf)


@rpc("authority", "call_remote", "reliable", 0)
func _rx_machine_fields(batch: Dictionary) -> void:
	var _t0_perf := Time.get_ticks_usec()
	_trace("machine_fields", batch.size())
	if world_sync == null or world_sync.machines_sync == null:
		return
	world_sync.machines_sync.on_fields(batch)
	perf("rx_machine_fields", Time.get_ticks_usec() - _t0_perf)


# A guest worked a machine's panel. The machine runs on the host, so the host
# is the only one that acts on this; everyone else hears about it in the next
# field tick like any other change.
@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_machine_edit(batch: Dictionary) -> void:
	_trace("machine_edit", batch.size())
	if not is_host or world_sync == null or world_sync.machines_sync == null:
		return
	world_sync.machines_sync.on_edit(multiplayer.get_remote_sender_id(), batch)


# A piece of a paint board's drawing; boards_sync puts the pieces together.
@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_board(key: String, id: int, i: int, n: int, raw_size: int, piece: PackedByteArray) -> void:
	_trace("board", piece.size())
	if world_sync == null or world_sync.boards_sync == null:
		return
	world_sync.boards_sync.on_piece(key, id, i, n, raw_size, piece)


@rpc("authority", "call_remote", "reliable", 0)
func _rx_contract(state: Dictionary) -> void:
	_trace("contract", state.size())
	if world_sync == null or world_sync.contracts_sync == null:
		return
	world_sync.contracts_sync.on_state(state)


@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_contract_sign(id: String) -> void:
	if world_sync == null or world_sync.contracts_sync == null:
		return
	world_sync.contracts_sync.on_sign(id)


# ---------------------------------------------------------------- loose straw

func _straws() -> Node:
	if world_sync == null:
		return null
	return world_sync.strands_sync


@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_straw_add(adds: Array) -> void:
	var _t0_perf := Time.get_ticks_usec()
	_trace("straw_add", adds.size())
	var s := _straws()
	if s != null:
		s.on_add(multiplayer.get_remote_sender_id(), adds)
	perf("rx_straw_add", Time.get_ticks_usec() - _t0_perf)


@rpc("any_peer", "call_remote", "unreliable_ordered", 0)
func _rx_straw_move(ids: PackedInt64Array, rows: PackedFloat32Array) -> void:
	var _t0_perf := Time.get_ticks_usec()
	_trace("straw_move", ids.size())
	var s := _straws()
	if s != null:
		s.on_move(ids, rows)
	perf("rx_straw_move", Time.get_ticks_usec() - _t0_perf)


@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_straw_del(ids: PackedInt64Array) -> void:
	_trace("straw_del", ids.size())
	var s := _straws()
	if s != null:
		s.on_del(ids)


# Somebody lacks these straws of ours (joined late, or could not make them).
@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_straw_want(ids: PackedInt64Array) -> void:
	_trace("straw_want", ids.size())
	var s := _straws()
	if s != null:
		s.on_want(multiplayer.get_remote_sender_id(), ids)


# Where a straw came to rest, once more and reliably (moves can get lost).
@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_straw_rest(ids: PackedInt64Array, rows: PackedFloat32Array) -> void:
	_trace("straw_rest", ids.size())
	var s := _straws()
	if s != null:
		s.on_move(ids, rows)


@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_straw_census(ids: PackedInt64Array) -> void:
	_trace("straw_census", ids.size())
	var s := _straws()
	if s != null:
		s.on_census(multiplayer.get_remote_sender_id(), ids)


# Guest -> host: one of the guest's straws went onto a belt at `at` (#17).
@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_straw_board(sid: int, at: Vector3) -> void:
	_trace("straw_board")
	var s := _straws()
	if s != null and is_host:
		s.on_board(multiplayer.get_remote_sender_id(), sid, at)


@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_straw_claim(sid: int) -> void:
	_trace("straw_claim")
	var s := _straws()
	if s != null:
		s.on_claim(multiplayer.get_remote_sender_id(), sid)


# ---------------------------------------------------------------- settings

var _custom_name := ""  # a name typed in the panel; empty = use the Steam name


func _load_settings() -> void:
	var c := ConfigFile.new()
	if c.load(SETTINGS_PATH) == OK:
		_custom_name = str(c.get_value("mp", "custom_name", ""))
		logs_on = bool(c.get_value("logs", "on", true))
		logs_told = bool(c.get_value("logs", "told", false))
		public_told = bool(c.get_value("mp", "public_told", false))
		var b: Variant = c.get_value("bans", "list", {})
		bans = b if b is Dictionary else {}
	# the Steam persona replaces this once Steam is up (see _start_steam); the
	# slower lookup in default_name() only runs when Steam is not available
	var user := OS.get_environment("USERNAME").substr(0, 24)
	my_name = _custom_name if _custom_name != "" else (user if user != "" else t("default_name"))


func _save_settings() -> void:
	var c := ConfigFile.new()
	c.set_value("mp", "custom_name", _custom_name)
	c.set_value("logs", "on", logs_on)
	c.set_value("logs", "told", logs_told)
	c.set_value("mp", "public_told", public_told)
	c.set_value("bans", "list", bans)
	c.save(SETTINGS_PATH)


var public_told := false  # the note about public servers was read (mp_ui show_public_notice)


func set_public_told() -> void:
	public_told = true
	_save_settings()


# Anonymous logs (mp_logs.gd): on unless the player turned them off, and nothing goes out
# until they have seen what this is.
var logs_on := true
var logs_told := false


func logs_available() -> bool:
	return reporter != null and reporter.has_method("available") and bool(reporter.call("available"))


func logs_need_notice() -> bool:
	return logs_available() and not logs_told


func set_logs(on: bool) -> void:
	logs_on = on
	logs_told = true
	_save_settings()
	if reporter != null and reporter.has_method("changed"):
		reporter.call("changed")
	if ui != null:
		ui.refresh()


# Called by the panel when the player edits the name field.
func set_player_name(n: String) -> void:
	n = n.strip_edges().substr(0, 24)
	if n == "":
		return
	my_name = n
	_custom_name = "" if n == default_name() else n
	_save_settings()


func default_name() -> String:
	var steam := steam_name()
	if steam != "":
		return steam.substr(0, 24)
	var user := OS.get_environment("USERNAME")
	return user.substr(0, 24) if user != "" else t("default_name")


var _steam_name_cache: Variant = null


# The game's Steam branch: "" on the normal one, else its name (like "v15-1-beta"). Asked of
# Steam, and if Steam cannot say, read from the game's appmanifest next to steamapps/common.
var _branch_cache: Variant = null

func game_branch() -> String:
	if _branch_cache != null:
		return _branch_cache
	var name := ""
	var found := false
	# Steam's own file first: asking Steam before it is up writes an error to the log
	var acf := OS.get_executable_path().get_base_dir().get_base_dir().get_base_dir() + "/appmanifest_5160800.acf"
	if FileAccess.file_exists(acf):
		found = true
		# MountedConfig is what is installed now; UserConfig is what was picked, which
		# differs while a branch switch is still downloading
		var text := FileAccess.get_file_as_string(acf)
		var at := text.find("\"MountedConfig\"")
		var key := RegEx.create_from_string("\"BetaKey\"\\s+\"([^\"]*)\"")
		var hit := key.search(text, at) if at >= 0 else key.search(text)
		if hit != null:
			name = hit.get_string(1)
	if not found and steam != null and int(steam.get("steam_id")) != 0 and Engine.has_singleton("Steam"):
		var st: Object = Engine.get_singleton("Steam")
		if st.has_method("getCurrentBetaName"):
			var r: Variant = st.call("getCurrentBetaName")
			if r is Dictionary:
				if bool((r as Dictionary).get("ret", (r as Dictionary).get("result", true))):
					name = str((r as Dictionary).get("name", ""))
			elif r is String:
				name = r
		found = true
	if not found:
		return ""  # not known yet: ask again later
	name = name.strip_edges()
	if name.to_lower() == "public" or name.to_lower() == "default":
		name = ""
	_branch_cache = name
	return name


# The demo has no Steam API, so read the persona name Steam keeps on disk
# (config/loginusers.vdf): the MostRecent account, else the newest login.
func steam_name() -> String:
	if _steam_name_cache != null:
		return _steam_name_cache
	_steam_name_cache = ""
	var roots: Array[String] = []
	var out: Array = []
	if OS.execute("reg", ["query", "HKCU\\Software\\Valve\\Steam", "/v", "SteamPath"], out) == 0 and not out.is_empty():
		var rx := RegEx.create_from_string("SteamPath\\s+REG_SZ\\s+(.+)")
		var hit := rx.search(str(out[0]))
		if hit != null:
			roots.append(hit.get_string(1).strip_edges())
	var pf := OS.get_environment("ProgramFiles(x86)")
	if pf != "":
		roots.append(pf.replace("\\", "/") + "/Steam")
	for root in roots:
		var f := FileAccess.open(root + "/config/loginusers.vdf", FileAccess.READ)
		if f == null:
			continue
		var text := f.get_as_text()
		f.close()
		var best := ""
		var best_stamp := -1
		var block_rx := RegEx.create_from_string("\"\\d+\"\\s*\\{([^}]*)\\}")
		var name_rx := RegEx.create_from_string("\"PersonaName\"\\s*\"([^\"]*)\"")
		var stamp_rx := RegEx.create_from_string("\"Timestamp\"\\s*\"(\\d+)\"")
		var recent_rx := RegEx.create_from_string("\"MostRecent\"\\s*\"1\"")
		for b in block_rx.search_all(text):
			var body := b.get_string(1)
			var n := name_rx.search(body)
			if n == null:
				continue
			var stamp := 0
			var s := stamp_rx.search(body)
			if s != null:
				stamp = int(s.get_string(1))
			if recent_rx.search(body) != null:
				stamp = 1 << 62
			if stamp > best_stamp:
				best_stamp = stamp
				best = n.get_string(1)
		if best != "":
			_steam_name_cache = best
			break
	return _steam_name_cache
