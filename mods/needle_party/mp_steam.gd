# Steam side of the multiplayer mod.
#
# Older demos shipped without the Steam API, so the mod loads the GodotSteam
# GDExtension at runtime (GDExtensionManager.load_extension) and initialises
# Steam under the demo's app id. The full game and newer demos bring Steam
# themselves; then the mod reuses the session the game already started. That buys us Steam's relay network: players
# connect through Steam instead of a direct IP, so nobody has to open a port,
# and friends can be invited straight from the Steam overlay.
extends Node

const DEMO_APP_ID := 5165210  # Find The Needle Demo
const FULL_APP_ID := 5160800  # Find The Needle (full game)

# Worked out in setup(): the full game and newer demos start Steam themselves
# through their SteamLink autoload, so the mod uses whatever app id the game
# runs under instead of forcing the demo's.
var APP_ID := DEMO_APP_ID

var available := false      # extension loaded and Steam initialised
var load_status := ""
var steam: Object = null
var steam_id := 0
var persona := ""
var lobby_id := 0
var lobby_owner := 0

signal lobby_created(ok: bool, id: int)
signal lobbies_found(rows: Array)
signal lobby_joined(ok: bool, id: int, reason: String)
signal join_requested(id: int)
signal invite_received(inviter: int, id: int)
signal lobby_members_changed()


func setup(base_dir: String) -> Dictionary:
	if available:
		return {"ok": true, "status": load_status}
	APP_ID = _detect_app_id()
	_set_app_id()
	if not ClassDB.class_exists("SteamMultiplayerPeer") and not Engine.has_singleton("Steam"):
		var path := base_dir + "/steam/godotsteam.gdextension"
		if not FileAccess.file_exists(path):
			load_status = "no encuentro %s" % path
			return {"ok": false, "status": load_status}
		var st: int = GDExtensionManager.load_extension(path)
		if st != GDExtensionManager.LOAD_STATUS_OK and st != GDExtensionManager.LOAD_STATUS_ALREADY_LOADED:
			load_status = "la librerÃ­a de Steam no cargÃ³ (cÃ³digo %d)" % st
			return {"ok": false, "status": load_status}
	if not Engine.has_singleton("Steam"):
		load_status = "la librerÃ­a cargÃ³ pero no registrÃ³ Steam"
		return {"ok": false, "status": load_status}
	steam = Engine.get_singleton("Steam")
	if _game_started_steam():
		# the game's SteamLink already initialised Steam under its own app id;
		# initialising again under another id would point Steam at the wrong game
		print("[MPMod] steam: started by the game (app %d)" % APP_ID)
	else:
		# callbacks are run from _process below (it keeps going while the game is
		# paused); letting GodotSteam embed them as well ran every callback twice
		var res: Variant = steam.call("steamInitEx", APP_ID, false)
		var code := 0
		var verbal := ""
		if res is Dictionary:
			code = int(res.get("status", -1))
			verbal = str(res.get("verbal", ""))
		if code != 0:
			load_status = "Steam no arrancÃ³: %s" % verbal
			return {"ok": false, "status": load_status}
	steam_id = int(steam.call("getSteamID"))
	persona = str(steam.call("getPersonaName"))
	available = true
	load_status = "Steam listo (%s)" % persona
	_tune_networking()
	_connect_signals()
	set_process(true)
	return {"ok": true, "status": load_status}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)


func _process(_delta: float) -> void:
	if steam != null:
		steam.call("run_callbacks")


# Steam's networking defaults, set before any connection is made.
#
# ICE off: connections go through Steam's relays only, never straight between
# the two PCs. A player's crash dump put the crash some guests get a while
# after joining on an assert in Steam's own ICE code (m_pTransportICE, in
# steamnetworkingsockets_p2p_ice.cpp), and that takes the whole game down.
# Relays cost a few ms and also keep everyone's IP address private.
#
# A bigger send buffer: the world goes to a guest in one go and the default
# 512 KB is less than a big yard, so Steam refused the rest of it.
const SEND_BUFFER := 8 << 20

func _tune_networking() -> void:
	_set_global("NETWORKING_CONFIG_P2P_TRANSPORT_ICE_ENABLE", "NETWORKING_CONFIG_P2P_TRANSPORT_ICE_DISABLE")
	_set_global("NETWORKING_CONFIG_SEND_BUFFER_SIZE", "", SEND_BUFFER)


func _set_global(key: String, value_name: String, value: int = 0) -> void:
	if not ClassDB.class_has_integer_constant("Steam", key):
		print("[MPMod] steam: no %s in this GodotSteam" % key)
		return
	if value_name != "":
		if not ClassDB.class_has_integer_constant("Steam", value_name):
			print("[MPMod] steam: no %s in this GodotSteam" % value_name)
			return
		value = ClassDB.class_get_integer_constant("Steam", value_name)
	var ok: Variant = steam.call("setGlobalConfigValueInt32", ClassDB.class_get_integer_constant("Steam", key), value)
	print("[MPMod] steam: %s = %d (%s)" % [key, value, "ok" if ok else "refused"])


# Which Steam app this copy of the game is. Asked in order: the game's own
# SteamLink autoload, Steam itself if it is already up, then the project name
# (the full game is "FindTheNeedle", the demo "Haystack Incremental").
func _detect_app_id() -> int:
	var link := _steam_link()
	if link != null and int(link.get("app_id")) > 0:
		return int(link.get("app_id"))
	if Engine.has_singleton("Steam"):
		var st: Object = Engine.get_singleton("Steam")
		if bool(st.call("isSteamRunning")):
			var id := int(st.call("getAppID"))
			if id > 0:
				return id
	if str(ProjectSettings.get_setting("application/config/name", "")) == "FindTheNeedle":
		return FULL_APP_ID
	return DEMO_APP_ID


func _steam_link() -> Node:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		return (loop as SceneTree).root.get_node_or_null("SteamLink")
	return null


func _game_started_steam() -> bool:
	var link := _steam_link()
	if link != null and bool(link.get("running")):
		return true
	return steam != null and bool(steam.call("isSteamRunning")) and int(steam.call("getSteamID")) != 0


# Lets Steam identify the game when it is launched outside the Steam client.
# Steam reads these the same way it reads a steam_appid.txt, and this way
# nothing is written into the game folder.
func _set_app_id() -> void:
	for key in ["SteamAppId", "SteamGameId"]:
		if OS.get_environment(key) == "":
			OS.set_environment(key, str(APP_ID))


func _connect_signals() -> void:
	_link("lobby_created", _on_lobby_created)
	_link("lobby_match_list", _on_lobby_match_list)
	_link("lobby_joined", _on_lobby_joined)
	_link("join_requested", _on_join_requested)
	_link("join_game_requested", _on_join_game_requested)
	_link("lobby_chat_update", _on_lobby_chat_update)
	_link("lobby_invite", _on_lobby_invite)


func _link(sig: String, cb: Callable) -> void:
	if steam.has_signal(sig) and not steam.is_connected(sig, cb):
		steam.connect(sig, cb)


# ---------------------------------------------------------------- lobbies

var public_info := {}  # what a public server shows in the list; empty = friends only

func host_lobby(max_players: int = 8) -> void:
	# 2 = LOBBY_TYPE_PUBLIC is searchable; FRIENDS_ONLY keeps it to invites
	steam.call("createLobby", 2 if not public_info.is_empty() else 1, max_players)


# The public servers of this mod, everywhere. The answer comes as lobbies_found.
func find_lobbies() -> void:
	steam.call("addRequestLobbyListStringFilter", "np", "1", 0)
	steam.call("addRequestLobbyListDistanceFilter", 3)
	steam.call("addRequestLobbyListResultCountFilter", 50)
	steam.call("requestLobbyList")


func _on_lobby_match_list(lobbies: Array) -> void:
	var rows: Array = []
	for l in lobbies:
		var id := int(l)
		rows.append({"id": id,
			"name": str(steam.call("getLobbyData", id, "np_name")).substr(0, 32),
			"ver": str(steam.call("getLobbyData", id, "np_ver")).substr(0, 16),
			"buildings": int(str(steam.call("getLobbyData", id, "np_b"))),
			"machines": int(str(steam.call("getLobbyData", id, "np_m"))),
			"world": str(steam.call("getLobbyData", id, "np_w")) == "1",
			"players": int(steam.call("getNumLobbyMembers", id)),
			"limit": int(steam.call("getLobbyMemberLimit", id))})
	lobbies_found.emit(rows)


func join_lobby(id: int) -> void:
	steam.call("joinLobby", id)


func leave_lobby() -> void:
	if lobby_id != 0:
		steam.call("leaveLobby", lobby_id)
		# or friends can still "join game" a lobby that is gone
		steam.call("clearRichPresence")
		lobby_id = 0
		lobby_owner = 0


func invite_overlay() -> void:
	if lobby_id != 0:
		steam.call("activateGameOverlayInviteDialog", lobby_id)


func lobby_members() -> Array:
	var out: Array = []
	if lobby_id == 0:
		return out
	var n := int(steam.call("getNumLobbyMembers", lobby_id))
	for i in n:
		out.append(int(steam.call("getLobbyMemberByIndex", lobby_id, i)))
	return out


func name_of(id: int) -> String:
	if steam == null:
		return "Jugador"
	return str(steam.call("getFriendPersonaName", id))


func set_lobby_data(key: String, value: String) -> void:
	if lobby_id != 0:
		steam.call("setLobbyData", lobby_id, key, value)


func get_lobby_data(key: String) -> String:
	if lobby_id == 0:
		return ""
	return str(steam.call("getLobbyData", lobby_id, key))


func _on_lobby_created(connect_code: int, id: int) -> void:
	if connect_code == 1:
		lobby_id = id
		lobby_owner = steam_id
		set_lobby_data("game", "find_the_needle_mp")
		set_lobby_data("host", persona)
		for k in public_info:
			set_lobby_data(str(k), str(public_info[k]))
		# lets friends use "Join game" from the Steam friends list
		steam.call("setRichPresence", "connect", "+connect_lobby %d" % id)
		steam.call("setRichPresence", "steam_display", "#Status_Playing")
		lobby_created.emit(true, id)
	else:
		lobby_created.emit(false, 0)


# A friend clicked "Join game" in the Steam friends list.
func _on_join_game_requested(_user: int, connect_string: String) -> void:
	var id := lobby_from_connect(connect_string)
	if id != 0:
		join_requested.emit(id)


# Steam passes "+connect_lobby <id>" either on the command line (game was
# closed) or through the join_game_requested signal (game already open).
static func lobby_from_connect(text: String) -> int:
	var parts := text.split(" ", false)
	for i in parts.size():
		if parts[i] == "+connect_lobby" and i + 1 < parts.size():
			return int(parts[i + 1])
	return 0


func lobby_from_command_line() -> int:
	var args := OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	return lobby_from_connect(" ".join(args))


func _on_lobby_joined(id: int, _perms: int, _locked: bool, response: int) -> void:
	if response == 1:
		lobby_id = id
		lobby_owner = int(steam.call("getLobbyOwner", id))
		lobby_joined.emit(true, id, "")
	else:
		lobby_joined.emit(false, id, "code %d" % response)


func _on_join_requested(id: int, _friend_id: int) -> void:
	join_requested.emit(id)


# Somebody sent us an invite. Before, this joined at once, which pulled a
# player straight out of the game they were in; now it is offered and the
# player chooses (F10 or JOIN in the panel).
func _on_lobby_invite(inviter: int, id: int, _game: int) -> void:
	if id != 0 and id != lobby_id:
		invite_received.emit(inviter, id)


# ---------------------------------------------------------------- friends
# An in-game friends list: the Steam overlay often never hooks this game
# (Steam starts after the D3D12 device), so its invite dialog did nothing.

const FRIEND_FLAG_IMMEDIATE := 4

# Online friends, the ones in Find The Needle first, then by name.
# Each: {id, name, playing (bool), state (0 offline .. 6)}
func friends() -> Array:
	var out: Array = []
	if not available:
		return out
	var n := int(steam.call("getFriendCount", FRIEND_FLAG_IMMEDIATE))
	var mine := int(steam.call("getAppID")) if steam.has_method("getAppID") else APP_ID
	for i in mini(n, 500):
		var fid := int(steam.call("getFriendByIndex", i, FRIEND_FLAG_IMMEDIATE))
		if fid == 0:
			continue
		var state := int(steam.call("getFriendPersonaState", fid))
		if state == 0:
			continue  # offline
		var playing := false
		var g: Variant = steam.call("getFriendGamePlayed", fid)
		if g is Dictionary:
			playing = int((g as Dictionary).get("id", 0)) in [mine, APP_ID, FULL_APP_ID]
		out.append({"id": fid, "name": str(steam.call("getFriendPersonaName", fid)),
			"playing": playing, "state": state})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["playing"] != b["playing"]:
			return a["playing"]
		return str(a["name"]).to_lower() < str(b["name"]).to_lower())
	return out


func invite(friend_id: int) -> bool:
	if not available or lobby_id == 0:
		return false
	return bool(steam.call("inviteUserToLobby", lobby_id, friend_id))


func _on_lobby_chat_update(_id: int, _changed: int, _making: int, _state: int) -> void:
	lobby_members_changed.emit()


# ---------------------------------------------------------------- peers

# A MultiplayerPeer that talks over Steam's relay instead of a UDP socket.
#
# GodotSteam's peer only opens steam/multiplayer_peer/max_channels channels
# (4 by default), counted after its own reserved ones, while the mod sends on
# RPC channels 0-3. Everything past the limit was pushed onto channel 0 with a
# warning per packet (thousands per session in players' logs), so poses, hay
# and machine updates queued up behind the reliable traffic: lag and desync.
# The installer also writes this into override.cfg, which covers builds that
# read it once at startup; setting it here covers the ones that read it when
# the peer is made. Every player runs the same version, so both ends agree.
const MAX_CHANNELS := 16

func make_peer() -> MultiplayerPeer:
	if not ClassDB.class_exists("SteamMultiplayerPeer"):
		return null
	ProjectSettings.set_setting("steam/multiplayer_peer/max_channels", MAX_CHANNELS)
	var peer: Object = ClassDB.instantiate("SteamMultiplayerPeer")
	# send right away instead of waiting a few ms to merge: the mod already
	# batches its own messages, so Nagle only added latency to every pickup
	if "no_nagle" in peer:
		peer.set("no_nagle", true)
	return peer as MultiplayerPeer
