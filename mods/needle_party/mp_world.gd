# Per-world sync for the multiplayer mod. Created by MPMod once the yard is
# built, freed when the scene changes. All network traffic goes through MPMod's
# RPCs; this node only reads and applies game state.
extends Node

var mp: Node
var world: Node
var field: Node
var builds: Node
var player: Node

const POSE_HZ := 20.0
const POSE_KEEPALIVE_MS := 500  # an unchanged pose still goes out this often
const HAY_TICK := 0.12
const HAY_FULL_SCAN := 3.0
const HAY_EPS := 0.002
const HAY_BATCH := 6000
const BUILD_TICK := 0.4
const STATE_TICK := 0.25
# The host sends a checksum per 16x16-vertex block of the pile this often. A
# guest compares it with its own pile and asks for the blocks that drifted.
const HAY_SUM_TICK := 4.0
const HAY_BLOCK := 16
# metres of height summed over a block before it counts as drifted: well above
# the HAY_EPS rounding every vertex is allowed, well below any real dig
const HAY_SUM_TOL := 0.5

# Machines that dig, scan, route, lift or turn hay into something, and the
# cabinets and radars. They run on the host only: their motion, settings, belt
# contents and the items they make are sent out, so running them twice would
# count the same hay twice. Conveyors, decks, walls and lamps stay live
# everywhere.
const CLIENT_FROZEN := ["piston_rakes", "robotic_arms", "hay_drones", "scanners",
	"compressors", "pulpers", "papers", "briquette_presses", "wrappers", "silos",
	"pelletizers", "tube_launchers", "dump_hatches", "needle_radars",
	"generators", "boreholes", "splitters", "joiners", "hay_lifts", "hay_stairs",
	"cabinets",
	# full game: machines the demo does not have
	"hay_excavators", "skyline_cranes", "pipe_pumps"]

# Full game lists that hold a mix of machines and plain fittings (jump pads,
# lamps, signs, ladders). Only the entries the factory clock runs as machines
# are frozen on a guest; the rest have to keep working for the guest's player.
const CLIENT_FROZEN_IF_MACHINE := ["extras", "belt_gates", "switch_boxes",
	"fixtures", "belt_poles"]

const BUILD_ARRAYS := ["conveyors", "corners", "water_mains", "water_splitters",
	"robotic_arms", "platforms", "stairs", "railings", "walls", "roofs", "scanners",
	"compressors", "pulpers", "papers", "briquette_presses", "wrappers", "silos",
	"pelletizers", "generators", "boreholes", "tube_launchers", "dump_hatches",
	"hay_stairs", "hay_lifts", "splitters", "joiners", "cabinets", "needle_radars",
	"paint_boards", "work_lamps", "hay_drones", "piston_rakes", "power_poles",
	# full game: lists the demo does not have (or keeps empty). They must be
	# parked in _add_buildings too, or from_array()'s clear() wipes them.
	# Lists a build does not have are skipped.
	"belt_gates", "switch_boxes", "hay_excavators", "skyline_cranes",
	"belt_poles", "fixtures", "pipe_pumps", "extras"]
const BUILD_SHAPE_KEYS := ["span", "rise", "kind", "sections", "rows", "side"]

# Settings the game keeps in a save's meta and reads back when it loads one,
# as { the name on Cfg: the name in the meta }. The guest builds its yard out
# of our payload with the game's own loader, so anything missing here reaches
# it as a default: shed_long_bays decides how long the warehouse is and where
# the sell stand goes, and leaving it out put the two players' stands eleven
# metres apart. shed_grid also controls the warehouse layout; a default on
# the guest offsets the shop and the conveyors attached to it (upstream #22/#23).
# Sent only when the game has it, so older builds are untouched.
const CFG_META := {"shed_long_bays": "shed_bays", "shed_grid": "shed_grid"}
# save meta key -> SaveManager variable (a missing one, like cozy before 15.x, is skipped)
const SAVE_META := {"sandbox": "current_sandbox", "cozy": "current_cozy"}

const ADD_F := ["money", "debt", "hay_total", "hay_dug", "hay_returned", "hay_sold",
	"money_earned", "stacks_ordered", "needles_found", "pile_needles_found"]
const ADD_A := ["needles_by_type", "needle_stock"]
const OR_A := ["needle_taken", "discovered"]
# counters kept per item kind in a dictionary (the depot's stock): sent as
# changes like money, so a guest taking 3 out is "-3" on the host, never a
# stock the host then puts back (which would have let the items be taken twice)
const ADD_D := ["depot_stock", "gifts"]
const HOST_ABS := ["run_secs", "lot_tier", "hay_initial", "money_peak", "pile_cleared",
	"first_needle_secs", "first_clear_secs",
	# 1.1.2: the yard's story and records follow the host as well
	"has_hatch", "key_taken", "hatch_open", "completed", "case_goal", "endings"]
# records anyone can set: the best of everybody's, both ways. The sale and how many
# strands it was are one record.
const SHARED_BEST := ["best_sale", "best_sale_strands", "best_combo", "best_income"]
const HOST_MAX := ["mission_index", "contract_index"]

var avatars := {}
var _avatar_script: Script
var _me: Node  # our own body, seen when looking down
var props_sync: Node  # loose item replication
var belts_sync: Node  # what is riding on the belts
var machines_sync: Node  # how the machines move and what they are set to
var strands_sync: Node  # loose straw on the ground
var contracts_sync: Node  # the delivery truck and its contract
var boards_sync: Node  # what is drawn on the paint boards
var tables_sync: Node  # paint, power tags, routes, clocks, plugs, groups
var _pose_t := 0.0

var _hay_base := PackedFloat32Array()
var _hay_cand := {}
var _hay_t := 0.0
var _hay_scan_t := 0.0

var _bkeys := {}  # key -> building dict
var _builds_dirty := false
var _build_t := 0.0
var _applying_builds := false

var _st_base := {}
var _st_pending: Array = []  # [seq, delta]
var _seq := 0
var _peer_ack := {}
var _state_t := 0.0
var _tech_mute := false
var _needles := {}  # needle index -> "free" | "held" | "away"
var _holder := {}  # host: needle index -> peer holding it
var _last_at := {}  # peer -> where its last pose put it (outlives the avatar)
var _hay_sum_t := 0.0
var _hay_scan_at := 0
const FrameSlots = preload("mp_frame_slots.gd")
var _hay_sum_slot := FrameSlots.new()
var _pose_last: Array = []   # what our last pose packet said
var _pose_sent_at := 0  # where the rolling pile scan is
var _tech_queue := {}  # tech id -> rank changed this frame, sent at the end of it
var _tech_paid := {}   # tech id -> true if that change was bought, not granted
var tech_refunds := 0  # host: ranks bought twice and paid back (for the log and the test)
var _needle_t := 0.0
var _frozen := false  # stop sending (pile swap in progress, waiting for a reload)
var _pile_seed := 0


func _ready() -> void:
	field = world.get("field")
	builds = world.get("builds")
	player = world.get("player")
	_avatar_script = load(mp.base_dir + "/mp_avatar.gd")
	_me = _avatar_script.new()
	_me.setup_local(player, mp)
	world.add_child(_me)
	props_sync = (load(mp.base_dir + "/mp_props.gd") as Script).new()
	props_sync.name = "MPProps"
	add_child(props_sync)
	props_sync.start(mp, world)
	belts_sync = (load(mp.base_dir + "/mp_belts.gd") as Script).new()
	belts_sync.name = "MPBelts"
	add_child(belts_sync)
	belts_sync.start(mp, world)
	machines_sync = (load(mp.base_dir + "/mp_machines.gd") as Script).new()
	machines_sync.name = "MPMachines"
	add_child(machines_sync)
	machines_sync.start(mp, world)
	strands_sync = (load(mp.base_dir + "/mp_strands.gd") as Script).new()
	strands_sync.name = "MPStrands"
	add_child(strands_sync)
	strands_sync.start(mp, world)
	contracts_sync = (load(mp.base_dir + "/mp_contracts.gd") as Script).new()
	contracts_sync.name = "MPContracts"
	add_child(contracts_sync)
	contracts_sync.start(mp, world)
	boards_sync = (load(mp.base_dir + "/mp_boards.gd") as Script).new()
	boards_sync.name = "MPBoards"
	add_child(boards_sync)
	boards_sync.start(mp, world)
	tables_sync = (load(mp.base_dir + "/mp_tables.gd") as Script).new()
	tables_sync.name = "MPTables"
	add_child(tables_sync)
	tables_sync.start(mp, world)
	if field != null:
		field.cells_redrawn.connect(_on_cells_redrawn)
	if builds != null:
		builds.changed.connect(_on_builds_changed)
	Tech.tech_changed.connect(_on_tech_changed)
	GameState.pile_replaced.connect(_on_pile_replaced)
	GameState.needle_found.connect(_on_needle_found)
	GameState.needle_discovered.connect(_on_needle_discovered)
	GameState.purchased.connect(_on_purchased)
	rebaseline()
	if mp.active():
		apply_session_rules()


func shutdown() -> void:
	if Tech.tech_changed.is_connected(_on_tech_changed):
		Tech.tech_changed.disconnect(_on_tech_changed)
	if GameState.pile_replaced.is_connected(_on_pile_replaced):
		GameState.pile_replaced.disconnect(_on_pile_replaced)
	if GameState.needle_found.is_connected(_on_needle_found):
		GameState.needle_found.disconnect(_on_needle_found)
	if GameState.needle_discovered.is_connected(_on_needle_discovered):
		GameState.needle_discovered.disconnect(_on_needle_discovered)
	if GameState.purchased.is_connected(_on_purchased):
		GameState.purchased.disconnect(_on_purchased)
	if props_sync != null and is_instance_valid(props_sync):
		props_sync.shutdown()
	if belts_sync != null and is_instance_valid(belts_sync):
		belts_sync.shutdown()
	if machines_sync != null and is_instance_valid(machines_sync):
		machines_sync.shutdown()
	if strands_sync != null and is_instance_valid(strands_sync):
		strands_sync.shutdown()
	if contracts_sync != null and is_instance_valid(contracts_sync):
		contracts_sync.shutdown()
	if boards_sync != null and is_instance_valid(boards_sync):
		boards_sync.shutdown()
	clear_avatars()
	if is_instance_valid(_me):
		_me.queue_free()


# Take the current world as the agreed starting point (nothing to send yet).
func rebaseline() -> void:
	if field != null:
		_hay_base = field.heights.duplicate()
	_hay_cand.clear()
	_bkeys = _scan_builds()
	_builds_dirty = false
	_build_fixed.clear()
	_build_off = 0
	_st_base = _capture_state()
	_st_pending.clear()
	_pile_seed = GameState.run_seed
	_needles.clear()
	_holder.clear()
	for idx in _needle_bodies():
		_needles[idx] = "free"
	_frozen = false


# Put the local player where a new game starts (the save carries the host's
# spot). Each client gets a small sideways offset so nobody spawns inside
# someone else.
#
# (1.1.6) This used to put every guest at the new-game spawn point facing the
# middle of the yard. In a played yard the hay pile has often grown over that
# spot, so guests landed in the hay, facing the pile, and felt stuck. The
# world the host sends already puts us beside the host (build_payload); keep
# that, step aside per guest so nobody stands inside anybody, and face the
# way the host faces. The old spawn point is only the fallback.
func place_at_spawn() -> void:
	if player == null or not is_instance_valid(player):
		return
	var slot: int = maxi(1, mp.players.keys().find(multiplayer.get_unique_id()))
	var from: Vector3 = player.global_position
	var yaw: float = player.rotation.y
	var near_host := from.length() > 0.5 and from.y > -20.0
	if not near_host:
		var consts: Dictionary = world.get_script().get_script_constant_map()
		from = consts.get("SPAWN_POS", Vector3(13.2, 0.4, 5.6))
	var side := Vector3(cos(yaw), 0.0, -sin(yaw))  # the host's right
	var sp := from + side * (0.9 * float(slot - 1))
	var at: Vector3 = world._seat(sp) if world.has_method("_seat") else sp
	# (1.1.7) "beside the host" can be on a belt (it carries you off: the
	# player who moved on their own), inside a machine or a wall (stuck). Look
	# for a free spot with real floor that is not a belt, in rings around it.
	if near_host:
		var safe: Variant = _safe_spot(sp, slot)
		if safe != null:
			at = safe
	player.global_position = at
	if not near_host:
		player.look_at_from_position(at, Vector3(0, 3.0, 0), Vector3.UP)
		yaw = player.rotation.y
	player.rotation = Vector3(0, yaw, 0)
	if player.has_method("set_look"):
		player.set_look(yaw, 0.0)
	player.velocity = Vector3.ZERO


const SPAWN_RINGS := [0.0, 1.5, 2.5, 3.5, 5.0]
const SPAWN_DIRS := 8

func _safe_spot(center: Vector3, slot: int) -> Variant:
	var space := (player as Node3D).get_world_3d().direct_space_state
	var radius := 0.34
	var height := 1.78
	var consts: Dictionary = player.get_script().get_script_constant_map()
	radius = float(consts.get("CAP_RADIUS", radius))
	height = float(consts.get("STAND_HEIGHT", height))
	var shape := CapsuleShape3D.new()
	shape.radius = radius
	shape.height = height
	var mask: int = int(player.get("collision_mask"))
	var me: RID = (player as CollisionObject3D).get_rid()
	for r in SPAWN_RINGS:
		for k in (1 if r == 0.0 else SPAWN_DIRS):
			# each guest starts its ring at another angle, so two never pick
			# the same spot
			var ang := TAU * (float(k) + 0.37 * float(slot)) / float(SPAWN_DIRS)
			var c: Vector3 = center + Vector3(cos(ang), 0.0, sin(ang)) * r
			var ray := PhysicsRayQueryParameters3D.create(c + Vector3.UP * 1.5, c + Vector3.DOWN * 3.0, mask, [me])
			var hit := space.intersect_ray(ray)
			if hit.is_empty() or (hit["normal"] as Vector3).y < 0.7:
				continue  # no floor, or a slope
			if _is_belt(hit.get("collider")):
				continue
			var feet: Vector3 = hit["position"]
			var q := PhysicsShapeQueryParameters3D.new()
			q.shape = shape
			q.transform = Transform3D(Basis(), feet + Vector3.UP * (height * 0.5 + 0.05))
			q.collision_mask = mask
			q.exclude = [me]
			if space.intersect_shape(q, 1).is_empty():
				return feet + Vector3.UP * 0.02
	return null


# A belt, splitter, joiner or anything else that carries things along.
func _is_belt(n: Variant) -> bool:
	var node: Variant = n
	for i in 5:
		if node == null or not (node is Node) or not is_instance_valid(node):
			return false
		if node is BeltPath:
			return true
		var s: Variant = (node as Node).get_script()
		if s is Script:
			var f := (s as Script).resource_path.get_file()
			if f.contains("conveyor") or f.contains("belt") or f.contains("splitter") or f.contains("joiner"):
				return true
		node = (node as Node).get_parent()
	return false


func apply_session_rules() -> void:
	mp._mp_guard_online_services()
	mp.hold_profile()
	if props_sync != null and is_instance_valid(props_sync):
		props_sync.session_started()
	if not mp.is_host:
		_leave_missions_to_host()
		SaveManager.block_save = true
		if "autosave_enabled" in world:
			world.autosave_enabled = false
		# needles that surface as the pile is dug are announced by the host;
		# letting both sides pop them out gives two bodies for one needle
		var live: Node = _live()
		if live != null and "expose_uncovered" in live:
			live.expose_uncovered = false
		_freeze_client_machines()


# Missions run on every player so the quest board keeps up, but only the host
# pays for them: a guest that finished one first paid it here, the payment
# reached the host as more money, and the host paid it again when it got
# there. Marking every step as paid and rewarded on the guest makes its
# director skip the money, the free building and the card; the host's payout
# arrives with the shared money like anything else.
func _leave_missions_to_host() -> void:
	for i in MissionBook.count():
		var id := String(MissionBook.id_at(i))
		GameState.missions_paid[id] = true
		GameState.gifts_given[id] = true


var _refreeze_t := 0.0

func _is_client() -> bool:
	return mp.active() and not mp.is_host


# stopwatch: anything over 4 ms in one frame goes into mp_trace.log by name
func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_process_inner(delta)
	if mp != null and is_instance_valid(mp):
		mp.perf("world", Time.get_ticks_usec() - t0)


func _process_inner(delta: float) -> void:
	if not mp.active() or multiplayer.multiplayer_peer == null:
		return
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	_pose_t += delta
	if _pose_t >= 1.0 / POSE_HZ:
		_pose_t = 0.0
		_send_pose()
	if _frozen:
		return
	if not _tech_queue.is_empty():
		_flush_tech()
	_hay_t += delta
	_hay_scan_t += delta
	if _hay_t >= HAY_TICK:
		_hay_t = 0.0
		_hay_tick(true)  # a slice of the safety-net scan every tick (see _hay_tick)
	_build_t += delta
	if _build_t >= BUILD_TICK:
		_build_t = 0.0
		_build_tick()
	if not mp.is_host:
		_refreeze_t += delta
		if _refreeze_t >= 1.0:
			_refreeze_t = 0.0
			_freeze_client_machines()
	_needle_t += delta
	if _needle_t >= 0.2:
		_needle_t = 0.0
		_needle_tick()
	_state_t += delta
	if _state_t >= STATE_TICK:
		_state_t = 0.0
		_state_tick()
	_day_tick(delta)
	_watch_tick(delta)
	if mp.is_host:
		_hay_sum_t += delta
		if _hay_sum_t >= HAY_SUM_TICK and _hay_sum_slot.take():
			_hay_sum_t = 0.0
			_send_hay_sums()


# ---------------------------------------------------------------- avatars

func _send_pose() -> void:
	if player == null or not is_instance_valid(player):
		return
	var pitch := 0.0
	var p: Variant = player.get("_pitch")
	if p != null:
		pitch = float(p)
	var crouch := 0.0
	if player.has_method("crouch_amount"):
		crouch = float(player.crouch_amount())
	var moving: float = (player.velocity * Vector3(1, 0, 1)).length() if "velocity" in player else 0.0
	# (1.1.4, idea from xRangerDE's Multiplayer Enhanced, MIT) a player standing
	# still sent the same pose 20 times a second; now unchanged poses are
	# skipped and a keep-alive goes out every POSE_KEEPALIVE_MS
	var now := Time.get_ticks_msec()
	var pose := [player.global_position, player.rotation.y, pitch,
		int(player.get("current_tool")), crouch, moving, _hands()]
	if _pose_last.size() == pose.size() and now - _pose_sent_at < POSE_KEEPALIVE_MS \
	and (pose[0] as Vector3).distance_squared_to(_pose_last[0]) < 0.000001 \
	and absf(float(pose[1]) - float(_pose_last[1])) < 0.001 \
	and absf(float(pose[2]) - float(_pose_last[2])) < 0.001 \
	and pose[3] == _pose_last[3] and absf(float(pose[4]) - float(_pose_last[4])) < 0.01 \
	and absf(float(pose[5]) - float(_pose_last[5])) < 0.01 and pose[6] == _pose_last[6]:
		_poll_emote()
		return
	_pose_last = pose
	_pose_sent_at = now
	mp._rx_pose.rpc(now, player.global_position, player.rotation.y, pitch,
		int(player.get("current_tool")), crouch, moving, _hands())
	_poll_emote()


# ---------------------------------------------------------------- sell stand
# Moving the sell stand changes Cfg.stand_spot, which is not a building, so a
# moved stand stayed where it was for everyone else. Whoever moves it sends
# the spot; the others put their stand up there with the game's own call, and
# the host passes it on.
# (Turning a belt round needs nothing extra: the game reports it as a building
# change and the building sync carries it, tested both ways. A separate belt
# message tried in 1.2.0 development made a second belt for a moment.)
const WATCH_TICK := 0.5
var _watch_t := 0.0
var _stand_seen: Variant = null
var _applying_watch := false


func _watch_tick(delta: float) -> void:
	_watch_t += delta
	if _watch_t < WATCH_TICK:
		return
	_watch_t = 0.0
	var stand: Variant = Cfg.get("stand_spot")
	if stand is Dictionary:
		if _stand_seen != null and stand != _stand_seen and not _applying_watch 		and not (stand as Dictionary).is_empty():
			if mp.is_host:
				mp._rx_stand.rpc(stand)
			else:
				mp._rx_stand.rpc_id(1, stand)
		_stand_seen = (stand as Dictionary).duplicate(true)


func on_stand(sender: int, spot: Dictionary) -> void:
	var cur: Variant = Cfg.get("stand_spot")
	if cur is Dictionary and cur == spot:
		return
	# the spot is a position and a direction; whatever the keys are called
	var at: Variant = null
	var yaw := 0.0
	for k in spot:
		if spot[k] is Vector3 and at == null:
			at = spot[k]
		elif typeof(spot[k]) == TYPE_FLOAT and String(k).to_lower().contains("yaw"):
			yaw = float(spot[k])
	_applying_watch = true
	Cfg.set("stand_spot", spot.duplicate(true))
	if at != null and world.has_method("_put_up_stand"):
		world.call("_put_up_stand", at, yaw)
	_stand_seen = spot.duplicate(true)
	_applying_watch = false
	if mp.is_host and sender != 1:
		mp._rx_stand.rpc(spot)


# ---------------------------------------------------------------- day and night
# Each game ran its own day cycle from the moment it loaded, so after a while
# (and after one side sat in a paused menu) it was night for one player and
# day for the other. The host's clock is the real one: it sends the hour and
# moon phase every DAY_TICK, and a guest only steps its clock when it is off by
# more than DAY_SLACK hours (a full day is 30 real minutes, so 0.05 h is about
# 4 seconds), so the sky never visibly jumps for small differences.
const DAY_TICK := 5.0
const DAY_SLACK := 0.05
const DAY_SCRIPT := "day_cycle.gd"
var _day_t := 0.0
var _day: Node = null
var _day_look_t := 0.0


func _day_cycle() -> Node:
	if _day != null and is_instance_valid(_day):
		return _day
	_day = null
	if Time.get_ticks_msec() < _day_look_t:
		return null
	_day_look_t = Time.get_ticks_msec() + 10000  # look again at most every 10 s
	_day = _find_by_script(world, DAY_SCRIPT, 0)
	return _day


func _find_by_script(n: Node, file: String, depth: int) -> Node:
	if n == null or depth > 6:
		return null
	var s: Script = n.get_script()
	if s != null and s.resource_path.ends_with(file):
		return n
	for c in n.get_children():
		var hit := _find_by_script(c, file, depth + 1)
		if hit != null:
			return hit
	return null


func _day_tick(delta: float) -> void:
	if not mp.is_host or mp.players.size() < 2:
		return
	_day_t += delta
	if _day_t < DAY_TICK:
		return
	_day_t = 0.0
	var dc := _day_cycle()
	if dc == null or not dc.has_method("hour") or _sun_is_held():
		return
	var ph: float = float(dc.call("phase")) if dc.has_method("phase") else -1.0
	mp._rx_day.rpc(float(dc.call("hour")), ph)


# With "always day" on the sun stands still. Setting the hour then still lit the sky for that
# hour, and the game put it back: the screen flickered every 5 seconds.
func _sun_is_held() -> bool:
	var cfg := get_node_or_null("/root/Cfg")
	return cfg != null and "always_day" in cfg and bool(cfg.get("always_day"))


func on_day(hour: float, phase: float) -> void:
	if mp.is_host:
		return
	var dc := _day_cycle()
	if dc == null or not dc.has_method("set_hour") or _sun_is_held():
		return
	var mine := float(dc.call("hour"))
	var off := absf(fposmod(mine - hour + 12.0, 24.0) - 12.0)  # across midnight too
	if off > DAY_SLACK:
		dc.call("set_hour", hour)
	if phase >= 0.0 and dc.has_method("set_phase") and dc.has_method("phase") \
	and absf(float(dc.call("phase")) - phase) > 0.01:
		dc.call("set_phase", phase)


# ---------------------------------------------------------------- emotes
# The game plays emotes on the first-person arms (Player/Head/Camera/
# SprintHands, emote_id()/play_emote()). Those arms only exist for the local
# camera, so the others get the emote as a pop-up icon and name over our
# farmer's head. Sent once when it starts, reliable.
var _emote_hands: Node = null
var _emote_look_t := 0.0
var _emote_last := ""
var _emotes_script: Script = null
const EMOTES_PATH := "res://scripts/player/emotes.gd"


func _poll_emote() -> void:
	if _emote_hands == null or not is_instance_valid(_emote_hands):
		_emote_hands = null
		_emote_look_t -= 0.1
		if _emote_look_t > 0.0:
			return
		_emote_look_t = 2.0  # look again at most every 2 s
		_emote_hands = player.find_child("SprintHands", true, false)
		if _emote_hands == null or not _emote_hands.has_method("emote_id"):
			_emote_hands = null
			return
	var id := str(_emote_hands.call("emote_id"))
	if id == _emote_last:
		return
	_emote_last = id
	if id != "" and id != "<null>":
		mp._rx_emote.rpc(id)


var _emotes: Object = null  # an instance of the game's Emotes helper

func _emote_info(id: String) -> Dictionary:
	if _emotes == null and _emotes_script == null and ResourceLoader.exists(EMOTES_PATH):
		_emotes_script = load(EMOTES_PATH)
		if _emotes_script != null and _emotes_script.can_instantiate():
			_emotes = _emotes_script.new()
	var out := {"name": id.capitalize(), "icon": null, "secs": 3.0}
	if _emotes == null:
		return out
	var e: Variant = _emotes.call("get_emote", id) if _emotes.has_method("get_emote") else null
	if e is Dictionary:
		out["name"] = str((e as Dictionary).get("name", out["name"]))
		if _emotes.has_method("length_of"):
			var secs: Variant = _emotes.call("length_of", e)
			if typeof(secs) in [TYPE_FLOAT, TYPE_INT]:
				out["secs"] = clampf(float(secs), 2.0, 8.0)
	if _emotes.has_method("icon"):
		var tex: Variant = _emotes.call("icon", id)
		if tex is Texture2D:
			out["icon"] = tex
	return out


func on_emote(id: int, emote: String) -> void:
	var a: Node = avatars.get(id)
	if a == null or not is_instance_valid(a) or not (a is Node3D):
		return
	var old := a.get_node_or_null("MPEmote")
	if old != null:
		old.queue_free()
	var info := _emote_info(emote.substr(0, 40))
	var bubble := Node3D.new()
	bubble.name = "MPEmote"
	bubble.position = Vector3(0, 2.45, 0)
	a.add_child(bubble)
	if info["icon"] != null:
		var s := Sprite3D.new()
		s.texture = info["icon"]
		s.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		s.no_depth_test = true
		s.render_priority = 10
		s.pixel_size = 0.55 / maxf(1.0, float((info["icon"] as Texture2D).get_width()))
		s.modulate = Color(1, 1, 1, 1)
		bubble.add_child(s)
	var l := Label3D.new()
	l.text = str(info["name"])
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.render_priority = 11
	l.font_size = 40
	l.outline_size = 10
	l.modulate = Color(0.95, 0.92, 0.86)          # NEEDLE PARTY off-white
	l.outline_modulate = Color(0.11, 0.095, 0.08)
	l.pixel_size = 0.004
	l.position = Vector3(0, -0.42 if info["icon"] != null else 0.0, 0)
	bubble.add_child(l)
	# pop in, hold, float up and fade
	bubble.scale = Vector3.ONE * 0.2
	var tw := bubble.create_tween()
	tw.tween_property(bubble, "scale", Vector3.ONE * 1.15, 0.14).set_trans(Tween.TRANS_BACK)
	tw.tween_property(bubble, "scale", Vector3.ONE, 0.1)
	tw.tween_interval(float(info["secs"]))
	tw.tween_property(bubble, "position:y", 2.85, 0.5)
	tw.parallel().tween_property(l, "modulate:a", 0.0, 0.5)
	for c in bubble.get_children():
		if c is Sprite3D:
			tw.parallel().tween_property(c, "modulate:a", 0.0, 0.5)
	tw.tween_callback(bubble.queue_free)


# What is in our bare hands, in one number: how many straws in the low four
# bits, and the type of needle plus one above that (0 for none). The full game
# has 24 needle types, so the needle part is read back without a 4-bit mask.
func _hands() -> int:
	var hand: Variant = player.get("hand")
	if hand == null or not is_instance_valid(hand):
		return 0
	var straws: int = clampi(int(hand.count()), 0, 15)
	var needle := 0
	if hand.has_method("held_needle_index"):
		var idx: int = int(hand.held_needle_index())
		if idx >= 0:
			needle = int(GameState.type_of(idx)) + 1
	return straws | (needle << 4)


func on_pose(id: int, pos: Vector3, yaw: float, pitch: float, tool: int, crouch: float, moving: float, hands: int = 0, stamp: int = -1) -> void:
	_last_at[id] = pos
	var a: Node = avatars.get(id)
	if a == null or not is_instance_valid(a):
		a = _avatar_script.new()
		a.setup(mp.player_name(id), mp.player_color(id))
		world.add_child(a)
		a.global_position = pos
		avatars[id] = a
	a.set_target(pos, yaw, pitch, tool, crouch, moving)
	if stamp >= 0 and a.has_method("push_snapshot"):
		a.push_snapshot(stamp, pos, yaw, pitch)
	if a.has_method("set_hands"):
		a.set_hands(hands & 15, (hands >> 4) - 1)
	if strands_sync != null and is_instance_valid(strands_sync):
		# one straw is a straw; from two up the farmer holds a small ball of hay
		var straws: int = hands & 15
		strands_sync.set_hand(id, 0 if straws >= 2 else straws)


func remove_avatar(id: int) -> void:
	if strands_sync != null and is_instance_valid(strands_sync):
		strands_sync.drop_hand(id)
	var a: Node = avatars.get(id)
	if a != null and is_instance_valid(a):
		a.queue_free()
	avatars.erase(id)


func clear_avatars() -> void:
	for id in avatars.keys():
		remove_avatar(id)


func forget_peer(id: int) -> void:
	if mp.is_host:
		_drop_needles_of(id)
	_last_at.erase(id)
	if props_sync != null and is_instance_valid(props_sync):
		props_sync.peer_gone(id)
	if strands_sync != null and is_instance_valid(strands_sync):
		strands_sync.peer_gone(id)
	_peer_ack.erase(id)


func avatar_positions() -> Dictionary:
	var out := {}
	for id in avatars:
		if is_instance_valid(avatars[id]):
			out[id] = avatars[id].global_position
	return out


# ---------------------------------------------------------------- hay

func _on_cells_redrawn(cells: PackedInt32Array) -> void:
	var nc: int = field.get("_nc")
	var nv: int = field.get("_nv")
	for gc in cells:
		var v := (gc / nc) * nv + (gc % nc)
		_hay_cand[v] = true
		_hay_cand[v + 1] = true
		_hay_cand[v + nv] = true
		_hay_cand[v + nv + 1] = true


func _hay_tick(full: bool) -> void:
	if field == null:
		return
	var h: PackedFloat32Array = field.heights
	if h.size() != _hay_base.size():
		_hay_base = h.duplicate()
		_hay_cand.clear()
		return
	var idx := PackedInt32Array()
	var vals := PackedFloat32Array()
	if full:
		# (1.1.4) the safety-net pass over the whole pile used to run in one
		# frame every HAY_FULL_SCAN seconds; now each tick checks the next
		# slice, so the pile is still covered every HAY_FULL_SCAN seconds
		var n := h.size()
		var slice := maxi(1, int(ceil(float(n) * HAY_TICK / HAY_FULL_SCAN)))
		var a := _hay_scan_at
		var b := mini(n, a + slice)
		# compare the slice in one go first (native code); only a slice that
		# really changed gets the per-vertex loop (idea from xRangerDE's
		# Multiplayer Enhanced, MIT: 451 us -> 2 us for an unchanged field)
		if h.slice(a, b) != _hay_base.slice(a, b):
			for i in range(a, b):
				if absf(h[i] - _hay_base[i]) > HAY_EPS:
					idx.append(i)
					vals.append(h[i])
					_hay_base[i] = h[i]
		_hay_scan_at = 0 if b >= n else b
	if not _hay_cand.is_empty():
		var n := h.size()
		for i in _hay_cand:
			if i < n and absf(h[i] - _hay_base[i]) > HAY_EPS:
				idx.append(i)
				vals.append(h[i])
				_hay_base[i] = h[i]
	_hay_cand.clear()
	var at := 0
	while at < idx.size():
		var end := mini(at + HAY_BATCH, idx.size())
		# The host owns the pile. A guest hands its digs to the host, which
		# settles them into its pile and sends the result to everybody; two
		# players' digs and slides used to overwrite each other for good.
		if mp.is_host:
			mp._rx_hay.rpc(idx.slice(at, end), vals.slice(at, end))
		else:
			mp._rx_hay.rpc_id(1, idx.slice(at, end), vals.slice(at, end))
		at = end


func on_hay(sender: int, idx: PackedInt32Array, vals: PackedFloat32Array) -> void:
	if field == null or _frozen:
		return
	field.settle_join()
	var h: PackedFloat32Array = field.heights
	var n := h.size()
	if _hay_base.size() != n:
		_hay_base = h.duplicate()
	var nv: int = field.get("_nv")
	# our own digs not sent yet go first, or the numbers below overwrite them
	if not mp.is_host and h.size() == _hay_base.size():
		_hay_tick(false)
	# Host, digs from a guest: take them in as our own change, so our pile
	# settles around them and our next tick sends the result to everyone (the
	# guest included). Everyone else: the host's word is final, write it down
	# without settling it again.
	var from_guest: bool = mp.is_host and sender != 1 and sender != 0
	var touched := PackedInt32Array()
	for k in mini(idx.size(), vals.size()):
		var i := idx[k]
		if i < 0 or i >= n:
			continue
		h[i] = vals[k]
		if not from_guest:
			_hay_base[i] = vals[k]
		touched.append(i)
	field.heights = h
	for i in touched:
		if from_guest:
			field._touch_vertex(i % nv, i / nv)
		else:
			field._dirty_vertex_cells(i % nv, i / nv)


func _hay_blocks_per_side() -> int:
	var nv: int = field.get("_nv")
	return int(ceil(float(nv) / HAY_BLOCK))


func _hay_block_sums() -> PackedFloat32Array:
	var nv: int = field.get("_nv")
	var per := _hay_blocks_per_side()
	var sums := PackedFloat32Array()
	sums.resize(per * per)
	var h: PackedFloat32Array = field.heights
	for j in nv:
		var row := (j / HAY_BLOCK) * per
		var base := j * nv
		for i in nv:
			sums[row + i / HAY_BLOCK] += h[base + i]
	return sums


func _send_hay_sums() -> void:
	if field == null:
		return
	var sums := _hay_block_sums()
	for pid in mp.players.keys():
		if pid != 1 and str(mp.players[pid].get("state", "")) == "world":
			mp._rx_hay_sums.rpc_id(pid, sums)


# Guest: the host's checksums. Anything we dug since our last tick goes out
# first, on the same channel, so the host has it before it answers; then ask
# for every block that does not add up.
func on_hay_sums(sums: PackedFloat32Array) -> void:
	if field == null or _frozen or mp.is_host:
		return
	_hay_tick(false)
	var mine := _hay_block_sums()
	if mine.size() != sums.size():
		return
	var want := PackedInt32Array()
	for b in sums.size():
		if absf(mine[b] - sums[b]) > HAY_SUM_TOL:
			want.append(b)
	if not want.is_empty():
		mp._rx_hay_want.rpc_id(1, want)


# Host: send a guest the blocks it asked for, as they are here.
func on_hay_want(pid: int, blocks: PackedInt32Array) -> void:
	if field == null:
		return
	var nv: int = field.get("_nv")
	var per := _hay_blocks_per_side()
	var h: PackedFloat32Array = field.heights
	var idx := PackedInt32Array()
	var vals := PackedFloat32Array()
	for b in blocks:
		if b < 0 or b >= per * per:
			continue
		var j0 := (b / per) * HAY_BLOCK
		var i0 := (b % per) * HAY_BLOCK
		for j in range(j0, mini(j0 + HAY_BLOCK, nv)):
			for i in range(i0, mini(i0 + HAY_BLOCK, nv)):
				idx.append(j * nv + i)
				vals.append(h[j * nv + i])
	var at := 0
	while at < idx.size():
		var end := mini(at + HAY_BATCH, idx.size())
		mp._rx_hay.rpc_id(pid, idx.slice(at, end), vals.slice(at, end))
		at = end


# ---------------------------------------------------------------- buildings

func _on_builds_changed() -> void:
	if not _applying_builds:
		_builds_dirty = true
	# a machine placed here would run on its own until the next build tick
	if _is_client():
		_freeze_client_machines.call_deferred()


func _bkey(d: Dictionary) -> String:
	var parts := [str(d.get("type", ""))]
	for k in ["position", "a", "b"]:
		if d.has(k):
			parts.append(_qv(d[k]))
	if d.has("yaw"):
		parts.append(str(snappedf(float(d["yaw"]), 0.05)))
	for k in BUILD_SHAPE_KEYS:
		if d.has(k):
			parts.append("%s=%s" % [k, str(d[k])])
	# A row can keep its place elsewhere. A belt gate and a belt meter have a transform (a gate's
	# two ends are the belt's), a fixture has it in its parameter block. Without it, all belt
	# hangers, or all signs, were one key: the list saw one, and only the first of a kind ever
	# reached the other player.
	if d.get("xform") is Transform3D:
		parts.append(_qv((d["xform"] as Transform3D).origin))
	_add_places(d.get("p"), parts)
	# nothing else says where it stands: whatever positions it has
	if parts.size() == 1 or (parts.size() == 2 and d.has("kind")):
		_add_places(d, parts)
	return "|".join(parts)


func _add_places(block: Variant, parts: Array) -> void:
	if not (block is Dictionary):
		return
	var names: Array = (block as Dictionary).keys()
	names.sort()
	for k in names:
		if block[k] is Vector3:
			parts.append(_qv(block[k]))


func _qv(v: Variant) -> String:
	if v is Vector3:
		return "%.1f,%.1f,%.1f" % [snappedf(v.x, 0.1), snappedf(v.y, 0.1), snappedf(v.z, 0.1)]
	return str(v)


func _scan_builds() -> Dictionary:
	var out := {}
	if builds == null:
		return out
	for d in builds.to_array():
		# the clock and paint tables sit in the same list, but they are tables
		# (mp_tables sends them), not buildings
		if d is Dictionary and not TABLE_ROWS.has(str(d.get("type", ""))):
			out[_bkey(d)] = d
	return out


func _build_tick() -> void:
	if _applying_builds:
		return
	if _builds_dirty:
		_flush_builds()
		return
	if mp.is_host and mp.players.size() >= 2:
		_build_check_t += BUILD_TICK
		if _build_check_t >= BUILD_CHECK:
			_build_check_t = 0.0
			mp._rx_builds_check.rpc(_bkeys_total())


func flush_builds_now() -> void:
	if _builds_dirty and not _applying_builds:
		_flush_builds()


func _flush_builds() -> void:
	_builds_dirty = false
	var cur := _scan_builds()
	var adds: Array = []
	var removes: Array = []
	for k in cur:
		if not _bkeys.has(k):
			adds.append(cur[k])
	for k in _bkeys:
		if not cur.has(k):
			removes.append(_bkeys[k])
	_bkeys = cur
	if not adds.is_empty() or not removes.is_empty():
		_flushed_at = Time.get_ticks_msec()
		mp._rx_builds.rpc(adds, removes)
	if _is_client():
		_freeze_client_machines()


# Do both sides still have the same buildings? Nothing used to look, and a guest was
# found with two T-splitters standing inside two T-joiners, left over from something
# the host had already changed. They would have stayed until the next load. So the host
# says what its list adds up to, and a guest that stays different asks for the list and
# puts itself right. One try per building: if a list is written a little differently
# on the other PC, nothing goes up and down for ever.
const BUILD_CHECK := 10.0
const BUILD_FIX_MAX := 16      # more than this is not a few strays
const BUILD_BACK_OFF := -30    # nothing we may touch: ask again in about five minutes
const BUILD_QUIET_MS := 5000   # what we just built may still be on its way
var _build_check_t := 0.0
var _build_off := 0            # guest: checks in a row that did not match
var _build_fixed := {}         # guest: put right once, never touched again
var _flushed_at := -100000     # when our last builds went out


func _bkeys_total() -> int:
	var total := 0
	for k in _bkeys:
		total += (k as String).hash()
	return total


func on_builds_check(total: int) -> void:
	if builds == null or _frozen or _applying_builds or _builds_dirty:
		return
	if total == _bkeys_total():
		_build_off = 0
		return
	_build_off += 1
	if _build_off >= 2:
		_build_off = 0
		mp._rx_builds_list_ask.rpc_id(1)


# Host. What we built ourselves goes first, the two go down the same channel in order.
func on_builds_list_ask(pid: int) -> void:
	flush_builds_now()
	mp._rx_builds_list.rpc_id(pid, PackedStringArray(_bkeys.keys()))


func on_builds_list(keys: PackedStringArray) -> void:
	if builds == null or _frozen or _applying_builds or _builds_dirty:
		return
	if Time.get_ticks_msec() - _flushed_at < BUILD_QUIET_MS:
		_build_off = 1  # the next check asks again
		return
	var theirs := {}
	for k in keys:
		theirs[k] = true
	var extra: Array = []
	for k in _bkeys:
		if not theirs.has(k) and not _build_fixed.has(k):
			extra.append(k)
	var missing := PackedStringArray()
	for k in keys:
		if not _bkeys.has(k) and not _build_fixed.has(k):
			missing.append(k)
	mp.trace.note("builds differ from the host: %d extra here %s, %d missing here %s" % [extra.size(), str(extra.slice(0, 4)), missing.size(), str(missing.slice(0, 4))])
	if extra.is_empty() and missing.is_empty():
		_build_off = BUILD_BACK_OFF
		return
	if extra.size() + missing.size() > BUILD_FIX_MAX:
		_build_off = BUILD_BACK_OFF
		return
	var removes: Array = []
	for k in extra:
		_build_fixed[k] = true
		removes.append(_bkeys[k])
	for k in missing:
		_build_fixed[k] = true
	if not missing.is_empty():
		mp._rx_builds_want.rpc_id(1, missing)
	if not removes.is_empty():
		on_builds([], removes)


# Host: only this guest lacks these.
func on_builds_want(pid: int, keys: PackedStringArray) -> void:
	var adds: Array = []
	for k in keys:
		if _bkeys.has(k):
			adds.append(_bkeys[k])
	if not adds.is_empty():
		mp._rx_builds.rpc_id(pid, adds, [])


func on_builds(adds: Array, removes: Array) -> void:
	if builds == null or _frozen:
		return
	while _applying_builds:
		await get_tree().process_frame
	# anything we built locally goes out first so the rescan below can't swallow it
	if _builds_dirty:
		_flush_builds()
	_applying_builds = true
	mp.trace.note("builds begin: %s added, %s removed" % [_types_of(adds), _types_of(removes)])
	for d in removes:
		if d is Dictionary:
			var n := _find_building(d)
			if n != null:
				_demolish(n)
	if not adds.is_empty():
		await _add_buildings(adds)
	_bkeys = _scan_builds()
	_builds_dirty = false
	_applying_builds = false
	mp.trace.note("builds end")
	if _is_client():
		_freeze_client_machines()


func _types_of(dicts: Array) -> String:
	var out := PackedStringArray()
	for d in dicts:
		if d is Dictionary:
			out.append(str(d.get("type", "?")))
	return "[" + ",".join(out) + "]"


# Only rounding, not a neighbour: if the building is really gone, take nothing down.
const FIND_SLACK := 0.15

func _find_building(d: Dictionary) -> Node3D:
	var want := str(d.get("type", ""))
	var key := _bkey(d)
	var best: Node3D = null
	var best_err := FIND_SLACK
	for n in builds.every_placed():
		if not is_instance_valid(n) or n.is_queued_for_deletion() or not n.has_method("to_dict"):
			continue
		var nd: Dictionary = n.to_dict()
		if str(nd.get("type", "")) != want:
			continue
		# the very building first: nearest-within-0.6 m could take a neighbour
		if _bkey(nd) == key:
			return n
		var err := 0.0
		var compared := false
		for k in ["position", "a", "b"]:
			if d.has(k) and nd.has(k) and d[k] is Vector3 and nd[k] is Vector3:
				err += (d[k] as Vector3).distance_to(nd[k])
				compared = true
		# nothing to measure by: it would take the first of its type
		if compared and err < best_err:
			best_err = err
			best = n
	return best


# Taking down the other player's demolition. Pulling down a free building (a
# pole, a rake or a cabinet a mission gave you) hands the gift back, and the
# game did that here as well as on their side, so every demolish made one more
# free building and a friend ended up with twenty poles. Whoever took it down
# gets it back; here it just goes.
func _demolish(n: Node3D) -> void:
	var gifts: Dictionary = GameState.gifts.duplicate()
	# What the building holds comes out where it is taken down. They have let it
	# out already and it reaches us as items, so ours would make it all twice.
	var ps: Node = props_sync if props_sync != null and is_instance_valid(props_sync) else null
	var had := {}
	if ps != null:
		for it in ps.props.items:
			had[it] = true
		ps._busy = true
	# a drone lets its pod out when taken down (spill_stowed): items, loose needles, and for a
	# depot drone stock back into the depot. The side that took it down has done that already
	# and it reaches us; the item clean-up below does not catch needles or depot stock, so the
	# pod is emptied first (the list itself: restore_stowed() of a depot drone gives stock back)
	var pod: Variant = n.get("_stowed") if "_stowed" in n else null
	if pod is Array:
		(pod as Array).clear()
	if builds.has_method("demolish_blocked_reason") and str(builds.demolish_blocked_reason(n)) == "":
		builds.demolish(n)
	if is_instance_valid(n) and not n.is_queued_for_deletion():
		builds._demolish_one(n)
	if ps != null:
		for it in (ps.props.items as Array).duplicate():
			if not had.has(it):
				ps.props.remove(it)
		ps._busy = false
	if GameState.gifts != gifts:
		GameState.gifts = gifts
		GameState.gifts_changed.emit()


# Add buildings through the game's own loader without wiping the yard:
# from_array() starts with clear(), so the existing buildings are parked
# outside the manager's lists while it runs, then merged back. clear() also
# empties the demo's withheld buildings (they would drop out of the host's
# save) and frees the enclosed-conveyor shells, so those are parked too.
const BUILD_EXTRAS := ["demo_withheld"]
# clear() also resets these two tables. Every building placed by the other
# player wiped the clocks and paint here, and the empty table then went round to
# everybody. An empty stand-in takes the reset while the loader runs (a real
# reset could also hand needles in a socket back out).
const CLEARED_TABLES := ["clocks", "machine_paint"]
const TABLE_ROWS := ["machine_clocks", "machine_paint"]


# A belt gate sits on a belt that is already standing. The game's loader looks for that belt
# among what it has just made, and here that is only the new rows, so the gate was skipped
# without a word: one player's gate never showed for the other, and the check of the two
# lists could not repair it either. Gates get their belt from us.
func _add_buildings(dicts: Array) -> void:
	var gates: Array = []
	var rows: Array = []
	for d in dicts:
		if d is Dictionary and str(d.get("type", "")) == "belt_gate":
			gates.append(d)
		else:
			rows.append(d)
	if not rows.is_empty():
		await _add_rows(rows)
	for d in gates:
		_add_gate(d)


func _add_gate(d: Dictionary) -> void:
	var a: Variant = d.get("a")
	var b: Variant = d.get("b")
	var at: Variant = d.get("xform")
	if not (a is Vector3) or not (b is Vector3) or not (at is Transform3D) or not builds.has_method("add_belt_gate"):
		return
	var belt := _belt_between(a, b)
	if belt == null:
		mp.trace.note("gate: no belt from %s to %s here" % [_qv(a), _qv(b)])
		return
	var gate: Variant = builds.add_belt_gate(belt, at)
	if bool(d.get("shut", false)) and gate is Object and is_instance_valid(gate) and (gate as Object).has_method("set_shut"):
		gate.set_shut(true, true)


const GATE_BELT_SLACK := 0.1  # metres: the same belt, placed on both sides

func _belt_between(a: Vector3, b: Vector3) -> Node:
	var best: Node = null
	var best_err := GATE_BELT_SLACK
	for list in ["conveyors", "corners"]:
		var arr: Variant = builds.get(list)
		if not (arr is Array):
			continue
		for c in arr:
			if not is_instance_valid(c) or not ("a" in c) or not ("b" in c) or not ((c as Node).get("a") is Vector3):
				continue
			var err: float = (c.a as Vector3).distance_to(a) + (c.b as Vector3).distance_to(b)
			if err < best_err:
				best_err = err
				best = c
	return best


func _add_rows(dicts: Array) -> void:
	var parked := {}
	for a in BUILD_ARRAYS + BUILD_EXTRAS:
		var arr: Variant = builds.get(a)
		if arr is Array:
			parked[a] = arr.duplicate()
			arr.clear()
	var shells: Variant = builds.get("_enclosed_visuals")
	var shells_sig: Variant = builds.get("_enclosed_built")
	var on_show: Variant = builds.get("_enclosed_on_show")
	var on_show_kept: Dictionary = (on_show as Dictionary).duplicate() if on_show is Dictionary else {}
	if shells != null:
		# clear() frees whatever this points at; keep the node alive
		builds.set("_enclosed_visuals", null)
	var tables_kept := {}
	for t in CLEARED_TABLES:
		var table: Variant = builds.get(t)
		if table is Object and (table as Object).get_script() != null:
			tables_kept[t] = table
			builds.set(t, ((table as Object).get_script() as Script).new(builds))
	var slice: int = builds.restore_slice_usec
	builds.restore_slice_usec = 0
	await builds.from_array(dicts)
	builds.restore_slice_usec = slice
	for t in tables_kept:
		builds.set(t, tables_kept[t])
	for a in parked:
		var arr: Array = builds.get(a)
		var fresh := arr.duplicate()
		arr.clear()
		arr.append_array(parked[a])
		arr.append_array(fresh)
	if shells != null and is_instance_valid(shells):
		var made: Variant = builds.get("_enclosed_visuals")
		if made != null and is_instance_valid(made) and made != shells:
			builds.remove_child(made)
			made.queue_free()
		builds.set("_enclosed_visuals", shells)
		if shells_sig != null:
			builds.set("_enclosed_built", shells_sig)
	if on_show is Dictionary:
		var now_show: Dictionary = builds.get("_enclosed_on_show")
		for k in on_show_kept:
			if not now_show.has(k):
				now_show[k] = on_show_kept[k]
	if builds.has_method("_rebuild_enclosed_visuals"):
		builds._rebuild_enclosed_visuals()
	builds.rebuild_junctions()
	builds.rebuild_water_joints()
	builds.fit_posts_to_decks()
	builds.share_joints()
	builds.changed.emit()


# Stopping a machine takes more than process_mode, and since the factory clock
# runs machines from its own list it takes more than the processing flags too:
# a "stopped" machine went on working on every guest. A fabricator kept making
# its products there, and they reached the host as new items. Only the clock's
# own switch takes a machine out of the loop; the host sends us how it moves
# instead. Asked again every second: the game can switch a machine back on.
func _freeze_client_machines() -> void:
	if builds == null:
		return
	var clock := _factory_clock()
	var clock_stops: bool = clock != null and clock.has_method("set_machine_on")
	for a in CLIENT_FROZEN + CLIENT_FROZEN_IF_MACHINE:
		var arr: Variant = builds.get(a)
		if not (arr is Array):
			continue
		var only_machines: bool = CLIENT_FROZEN_IF_MACHINE.has(a)
		if only_machines and clock == null:
			continue
		for n in arr:
			if not is_instance_valid(n):
				continue
			var runs: bool = clock != null and bool(clock.call("is_machine", n))
			if only_machines and not runs:
				continue
			if runs and clock_stops and bool(clock.call("machine_on", n)):
				clock.call("set_machine_on", n, false)
			if n.has_meta("mp_stopped"):
				continue
			n.set_meta("mp_stopped", true)
			n.set_process(false)
			n.set_physics_process(false)
			# Not process_mode: a disabled node takes its collision body out of
			# the world (CollisionObject3D.disable_mode) and its particles stop
			# emitting, so the machine turned into a hole you walk through with
			# no smoke and no fire.
			if n.process_mode == Node.PROCESS_MODE_DISABLED:
				n.process_mode = Node.PROCESS_MODE_INHERIT
			_still_animations(n)


# The world's FactoryClock node, which knows which nodes it runs as machines.
# Found once by its class name; null on a build without one.
var _clock: Node = null
var _clock_looked := false

func _factory_clock() -> Node:
	if _clock != null and is_instance_valid(_clock):
		return _clock
	if _clock_looked or world == null:
		return null
	_clock_looked = true
	for n in world.find_children("*", "Node", true, false):
		var s: Variant = n.get_script()
		if s is Script and String((s as Script).get_global_name()) == "FactoryClock" and n.has_method("is_machine"):
			_clock = n
			break
	if _clock == null:
		var root := world.get_tree().root
		for n in root.find_children("*", "Node", true, false):
			var s: Variant = n.get_script()
			if s is Script and String((s as Script).get_global_name()) == "FactoryClock" and n.has_method("is_machine"):
				_clock = n
				break
	if mp != null and mp.trace != null:
		mp.trace.note("factory clock %s" % ("found" if _clock != null else "not found"))
	return _clock


# Their clips would otherwise hold whatever frame they stopped on, or keep
# looping, and fight the poses coming from the host.
func _still_animations(n: Node) -> void:
	for child in n.get_children():
		if child is AnimationPlayer:
			(child as AnimationPlayer).pause()
			child.process_mode = Node.PROCESS_MODE_DISABLED
		_still_animations(child)


# ---------------------------------------------------------------- shared game state

func _capture_state() -> Dictionary:
	var s := {}
	for f in ADD_F:
		s[f] = GameState.get(f)
	for a in ADD_A + OR_A:
		var v: Variant = GameState.get(a)
		s[a] = v.duplicate() if v != null else null
	for a in ADD_D:
		var v: Variant = GameState.get(a)
		s[a] = (v as Dictionary).duplicate(true) if v is Dictionary else null
	for f in ["case_goal", "best_combo"]:
		s["_" + f] = GameState.get(f)
	return s


# ADD_D helpers: per-key differences of two {kind: count} dictionaries.
func _dict_delta(c: Variant, b: Variant) -> Dictionary:
	var out := {}
	if not (c is Dictionary) or not (b is Dictionary):
		return out
	for k in (c as Dictionary).keys() + (b as Dictionary).keys():
		if out.has(k):
			continue
		var cv: Variant = (c as Dictionary).get(k, 0)
		var bv: Variant = (b as Dictionary).get(k, 0)
		if not (typeof(cv) in [TYPE_INT, TYPE_FLOAT]) or not (typeof(bv) in [TYPE_INT, TYPE_FLOAT]):
			continue
		var d := int(cv) - int(bv)
		if d != 0:
			out[k] = d
	return out


# sums deltas without clamping (pending changes may be negative)
func _dict_add_signed(target: Dictionary, delta: Dictionary) -> void:
	for k in delta:
		target[k] = int(target.get(k, 0)) + int(delta[k])


func _dict_add(target: Dictionary, delta: Dictionary) -> void:
	for k in delta:
		var cur: Variant = target.get(k, 0)
		if typeof(cur) in [TYPE_INT, TYPE_FLOAT]:
			var n := maxi(0, int(cur) + int(delta[k]))
			if n == 0 and not target.has(k):
				continue
			target[k] = n


func _state_tick() -> void:
	if mp.is_host:
		var snap := _capture_state()
		for f in HOST_ABS + HOST_MAX + SHARED_BEST:
			snap[f] = GameState.get(f)
		# it only moves when something sells and is read as a total over a minute
		if Time.get_ticks_msec() - _income_sent_at >= 2000:
			_income_sent_at = Time.get_ticks_msec()
			snap["income_log"] = _income_ages()
		for pid in mp.players.keys():
			if pid != 1 and str(mp.players[pid].get("state", "")) == "world":
				mp._rx_state_snap.rpc_id(pid, int(_peer_ack.get(pid, 0)), snap)
		return
	var cur := _capture_state()
	var delta := {}
	for f in ADD_F:
		var d: float = float(cur[f]) - float(_st_base[f])
		if absf(d) > 1e-6:
			delta[f] = d
	for a in ADD_A:
		var c: Variant = cur[a]
		var b: Variant = _st_base[a]
		if c == null or b == null or c.size() != b.size():
			continue
		var diff := PackedInt32Array()
		diff.resize(c.size())
		var any := false
		for i in c.size():
			diff[i] = c[i] - b[i]
			any = any or diff[i] != 0
		if any:
			delta[a] = diff
	for a in OR_A:
		var c: Variant = cur[a]
		var b: Variant = _st_base[a]
		if c == null or b == null or c.size() != b.size():
			continue
		var bits := PackedInt32Array()
		for i in c.size():
			if c[i] != 0 and b[i] == 0:
				bits.append(i)
		if not bits.is_empty():
			delta[a] = bits
	for a in ADD_D:
		var dd := _dict_delta(cur.get(a), _st_base.get(a))
		if not dd.is_empty():
			delta[a] = dd
	var best := {}
	for f in SHARED_BEST:
		var v: Variant = GameState.get(f)
		if v != null and float(v) > float(_best_sent.get(f, -1.0)):
			best[f] = v
			_best_sent[f] = v
	if best.has("best_sale") or best.has("best_sale_strands"):
		best["best_sale"] = GameState.get("best_sale")
		best["best_sale_strands"] = GameState.get("best_sale_strands")
	if not best.is_empty():
		delta["best"] = best
	_st_base = cur
	if delta.is_empty():
		return
	_seq += 1
	_st_pending.append([_seq, delta])
	mp._rx_state_delta.rpc_id(1, _seq, delta)


# The money per minute on the HUD adds up what add_money saw, and on a guest that
# is nothing: money reaches it as a number. The list goes over as how long ago,
# since the two PCs' clocks started at different times.
var _income_sent_at := 0

func _income_now() -> float:
	return float(GameState.get("_income_clock"))


func _income_ages() -> Array:
	var out: Array = []
	var log: Variant = GameState.get("_income_log")
	if log is Array:
		var now := _income_now()
		for e in log:
			out.append(Vector2(now - float(e.x), float(e.y)))
	return out


func _income_from_ages(ages: Array) -> void:
	var log: Variant = GameState.get("_income_log")
	if not (log is Array):
		return
	var now := _income_now()
	var rebuilt: Array = []
	for e in ages:
		rebuilt.append(Vector2(now - float(e.x), float(e.y)))
	(log as Array).assign(rebuilt)


var _best_sent := {}  # guest: the records we last told the host about

func _merge_best(theirs: Dictionary) -> void:
	if float(theirs.get("best_sale", -1.0)) > float(GameState.get("best_sale")):
		GameState.set("best_sale", theirs["best_sale"])
		if theirs.has("best_sale_strands"):
			GameState.set("best_sale_strands", theirs["best_sale_strands"])
	for f in ["best_combo", "best_income"]:
		if float(theirs.get(f, -1.0)) > float(GameState.get(f)):
			GameState.set(f, theirs[f])


func on_state_delta(pid: int, seq: int, delta: Dictionary) -> void:
	var before := _capture_state()
	if delta.get("best") is Dictionary:
		_merge_best(delta["best"])
	for f in ADD_F:
		if delta.has(f):
			_set_typed(f, float(GameState.get(f)) + float(delta[f]))
	for a in ADD_A:
		if delta.has(a):
			var arr: Variant = GameState.get(a)
			var d: PackedInt32Array = delta[a]
			if arr != null and arr.size() == d.size():
				for i in d.size():
					arr[i] = maxi(0, arr[i] + d[i])
				GameState.set(a, arr)
	for a in OR_A:
		if delta.has(a):
			var arr: Variant = GameState.get(a)
			if arr != null:
				for i in delta[a]:
					if i >= 0 and i < arr.size():
						arr[i] = 1
				GameState.set(a, arr)
	for a in ADD_D:
		if delta.has(a) and delta[a] is Dictionary:
			var dict: Variant = GameState.get(a)
			if dict is Dictionary:
				_dict_add(dict, delta[a])
				_drop_used_gifts(a, dict)
	_peer_ack[pid] = seq
	_emit_state_signals(before)


func on_state_snap(ack: int, snap: Dictionary) -> void:
	if mp.is_host:
		return
	while not _st_pending.is_empty() and int(_st_pending[0][0]) <= ack:
		_st_pending.pop_front()
	var pend := {}
	for entry in _st_pending:
		var d: Dictionary = entry[1]
		for f in d:
			if f in ADD_F:
				pend[f] = float(pend.get(f, 0.0)) + float(d[f])
			elif f in ADD_A:
				if not pend.has(f):
					pend[f] = d[f].duplicate()
				elif pend[f].size() == d[f].size():
					for i in d[f].size():
						pend[f][i] += d[f][i]
			elif f in OR_A:
				if not pend.has(f):
					pend[f] = PackedInt32Array()
				pend[f].append_array(d[f])
			elif f in ADD_D and d[f] is Dictionary:
				if not pend.has(f):
					pend[f] = {}
				_dict_add_signed(pend[f], d[f])
	var before := _capture_state()
	var cur := before
	for f in ADD_F:
		if not snap.has(f):
			continue
		var unsent: float = float(cur[f]) - float(_st_base[f])
		var nb: float = float(snap[f]) + float(pend.get(f, 0.0))
		_st_base[f] = nb
		_set_typed(f, nb + unsent)
	for a in ADD_A:
		if not snap.has(a) or snap[a] == null:
			continue
		var s: PackedInt32Array = snap[a]
		var c: Variant = cur[a]
		var b: Variant = _st_base[a]
		if c == null or b == null or c.size() != s.size() or b.size() != s.size():
			GameState.set(a, s.duplicate())
			_st_base[a] = s.duplicate()
			continue
		var p: Variant = pend.get(a)
		var nb := s.duplicate()
		var nv := s.duplicate()
		for i in s.size():
			var pi: int = p[i] if p != null and p.size() == s.size() else 0
			nb[i] = s[i] + pi
			nv[i] = nb[i] + (c[i] - b[i])
		_st_base[a] = nb
		GameState.set(a, nv)
	for a in OR_A:
		if not snap.has(a) or snap[a] == null:
			continue
		var s: PackedByteArray = snap[a]
		var c: Variant = cur[a]
		if c == null or c.size() != s.size():
			GameState.set(a, s.duplicate())
			_st_base[a] = s.duplicate()
			continue
		var nb := s.duplicate()
		for i in pend.get(a, PackedInt32Array()):
			if i >= 0 and i < nb.size():
				nb[i] = 1
		var nv := nb.duplicate()
		for i in s.size():
			if c[i] != 0:
				nv[i] = 1
		_st_base[a] = nb
		GameState.set(a, nv)
	# depot stock: the host's, plus what we sent and it has not counted yet,
	# plus what changed here since our last delta
	for a in ADD_D:
		if not (snap.get(a) is Dictionary):
			continue
		var nb: Dictionary = (snap[a] as Dictionary).duplicate(true)
		if pend.get(a) is Dictionary:
			_dict_add(nb, pend[a])
		var nv: Dictionary = nb.duplicate(true)
		_dict_add(nv, _dict_delta(cur.get(a), _st_base.get(a)))
		_st_base[a] = nb
		var live: Variant = GameState.get(a)
		if live is Dictionary:
			(live as Dictionary).clear()
			(live as Dictionary).merge(nv)
			_drop_used_gifts(a, live)
	for f in HOST_ABS:
		if snap.has(f) and snap[f] != null:
			GameState.set(f, snap[f])
	for f in HOST_MAX:
		if snap.has(f):
			GameState.set(f, maxi(int(GameState.get(f)), int(snap[f])))
	_merge_best(snap)
	for f in SHARED_BEST:
		if snap.has(f):
			_best_sent[f] = snap[f]  # what the host has, not what we have
	if snap.get("income_log") is Array:
		_income_from_ages(snap["income_log"])
	_emit_state_signals(before)


# A free building nobody has left has no row at all in the game's own list.
func _drop_used_gifts(a: String, dict: Dictionary) -> void:
	if a != "gifts":
		return
	for k in dict.keys():
		if int(dict[k]) <= 0:
			dict.erase(k)


func _set_typed(f: String, v: float) -> void:
	var cur: Variant = GameState.get(f)
	if typeof(cur) == TYPE_INT:
		GameState.set(f, int(round(v)))
	else:
		GameState.set(f, v)


func _emit_state_signals(before: Dictionary) -> void:
	if not is_equal_approx(float(before["money"]), float(GameState.money)):
		GameState.money_changed.emit(GameState.money)
	if not is_equal_approx(float(before["debt"]), float(GameState.debt)):
		GameState.debt_changed.emit(GameState.debt)
	if not is_equal_approx(float(before["hay_total"]), float(GameState.hay_total)) \
	or not is_equal_approx(float(before["hay_dug"]), float(GameState.hay_dug)):
		GameState.set("_hay_dirty", true)
		GameState.hay_changed.emit(GameState.hay_total, GameState.hay_dug)
	if not is_equal_approx(float(before["hay_sold"]), float(GameState.hay_sold)):
		GameState.hay_sold_changed.emit(GameState.hay_sold)
	var bs: Variant = before["needle_stock"]
	var ns: PackedInt32Array = GameState.needle_stock
	if bs != null and bs.size() == ns.size():
		for t in ns.size():
			if bs[t] != ns[t]:
				GameState.needle_stock_changed.emit(t, ns[t])
	if before.get("depot_stock") is Dictionary and GameState.get("depot_stock") is Dictionary \
	and before["depot_stock"] != GameState.get("depot_stock") and GameState.has_signal("depot_changed"):
		GameState.depot_changed.emit()
	if before.get("gifts") is Dictionary and GameState.get("gifts") is Dictionary \
	and before["gifts"] != GameState.get("gifts") and GameState.has_signal("gifts_changed"):
		GameState.gifts_changed.emit()
	if before.get("_case_goal") != GameState.get("case_goal") and GameState.has_signal("case_goal_changed"):
		GameState.case_goal_changed.emit(GameState.get("case_goal"))
	if before.get("_best_combo") != GameState.get("best_combo") and GameState.has_signal("best_combo_changed"):
		GameState.best_combo_changed.emit(GameState.get("best_combo"))
	var bd: Variant = before["discovered"]
	var nd: PackedByteArray = GameState.discovered
	if bd != null and bd.size() == nd.size():
		var at: Vector3 = player.global_position if player != null and is_instance_valid(player) else Vector3.ZERO
		for t in nd.size():
			if bd[t] == 0 and nd[t] != 0:
				GameState.needle_discovered.emit(t, at)


# ---------------------------------------------------------------- tech tree

# Tech.buy() changes the rank first and records the purchase right after, and
# a grant (bundled cards, rewards) never records one. So collect this frame's
# changes and send them at the end of it, marked bought or granted.
func _on_tech_changed(id: String, rank: int) -> void:
	if _tech_mute or not mp.active() or _frozen:
		return
	_tech_queue[id] = rank


func _on_purchased(kind: String, id: String) -> void:
	if kind == "card":
		_tech_paid[id] = true


func _flush_tech() -> void:
	for id in _tech_queue:
		mp._rx_tech.rpc(String(id), int(_tech_queue[id]), bool(_tech_paid.get(id, false)))
	_tech_queue.clear()
	_tech_paid.clear()


func on_tech(sender: int, id: String, rank: int, paid: bool = false) -> void:
	var have := int(Tech.ranks.get(id, 0))
	if rank > 0 and rank <= have:
		# Two players bought the same rank at once and both paid for it. The
		# host puts the second payment back into the shared money.
		if mp.is_host and paid and sender != 1:
			var cost := float(TechTree.cost_at(id, rank - 1))
			if cost > 0.0:
				tech_refunds += 1
				GameState.money += cost
				GameState.money_changed.emit(GameState.money)
			# the parts it took from the depot too
			var parts: Variant = Tech.parts_at(id, rank - 1)
			if parts is Dictionary and not (parts as Dictionary).is_empty():
				GameState.depot_refund(parts)
				print("[MPMod] %s rank %d was bought twice, refunded %.0f" % [id, rank, cost])
		return
	_tech_mute = true
	if rank <= 0:
		Tech.ranks.erase(id)
	else:
		Tech.ranks[id] = rank
	Tech.tech_changed.emit(id, rank)
	_tech_mute = false


# ---------------------------------------------------------------- full sync / pile swaps

# The host's world in the same shape SaveManager writes to disk, so a client
# can drop it into a scratch slot and load it with the game's own loader.
func build_payload(_pid: int) -> Dictionary:
	var xf: Transform3D = player.global_transform
	xf.origin += xf.basis.x * 1.2 + Vector3.UP * 0.2
	var props_arr: Array = []
	var props: Variant = world.get("props")
	if props != null and props.has_method("to_array"):
		props_arr = props.to_array()
	var belts: Dictionary = {}
	if world.has_method("_belts_to_dict"):
		belts = world._belts_to_dict()
	var out := {
		"version": SaveManager.FORMAT_VERSION,
		"pile_shape_version": SaveManager.current_pile_shape_version,
		"state": GameState.to_dict(),
		"heights": field.heights,
		"player": xf,
		"buildings": builds.to_array(),
		"props": props_arr,
		"belts": belts,
		"tech": Tech.to_dict(),
		"mp_rules": mp.host_rules(),  # the host's yard options, see mp.gd
		"cell": Cfg.CELL,
		"extent": Cfg.FIELD_EXTENT,
		"meta": {
			"name": "Multijugador",
			"locked": false,
			"map": SaveManager.current_map,
			"pile_size": SaveManager.current_pile_size,
			"saved_at": int(Time.get_unix_time_from_system()),
			"hay_dug": GameState.hay_dug,
			"hay_initial": GameState.hay_initial,
			"hay_total": GameState.hay_total,
			"needles_found": GameState.needles_found,
			"money": GameState.money,
			"money_earned": GameState.money_earned,
		},
	}
	# the pile's starting shape: without it the guest re-shapes the dome from
	# the seed, which is slow and not what the host's pile was dug from
	var dome: Variant = field.get("dome")
	if dome is PackedFloat32Array and (dome as PackedFloat32Array).size() == field.heights.size():
		out["dome"] = dome
		out["dome_seed"] = int(field.get("dome_seed"))
	var meta: Dictionary = out["meta"]
	for key in CFG_META:
		# null when this build of the game does not have the setting
		var v: Variant = Cfg.get(key)
		if v != null:
			meta[CFG_META[key]] = v
	_fill_from_game_save(out)
	# The run's mode: sandbox, cozy (game 15.x) and the rules version. The game's own
	# save builder (above) normally gives them; only if it did not, they come from
	# SaveManager here, so a guest never loads the host's world as a plain career run.
	meta = out["meta"]
	for key in SAVE_META:
		var sv: Variant = SaveManager.get(SAVE_META[key])
		if sv != null and not meta.has(key):
			meta[key] = sv
	var sm_script: Script = SaveManager.get_script()
	var rules: Variant = sm_script.get_script_constant_map().get("RULES_STAGES") if sm_script != null else null
	if rules is String and not meta.has("rules"):
		meta["rules"] = rules
	return out


# (1.2.0) The world above is put together by hand in the shape of a save, and
# anything the game keeps that it did not list was simply missing on the
# guest: the barn settings once, the sell stand's spot, whatever a game update
# adds next. Ask the game's own save builder as well and copy over every value
# (and meta value) ours does not have. Ours wins where both have one: those are
# the ones the sync relies on.
func _fill_from_game_save(out: Dictionary) -> void:
	if not SaveManager.has_method("build_payload"):
		return
	# Called by name, so a game build with other parameters cannot stop this
	# script from loading. The 5th value is the amount of loose straw on the
	# ground (a number); loose straw and needles travel on their own anyway.
	var game: Variant = SaveManager.call("build_payload", field.heights, out["player"], out["buildings"],
		out["props"], 0.0, out["belts"], out.get("dome", PackedFloat32Array()),
		int(out.get("dome_seed", 0)))
	if not (game is Dictionary):
		return
	var added: Array = []
	for k in game:
		if not out.has(k):
			out[k] = game[k]
			added.append(k)
		elif k == "meta" and game[k] is Dictionary:
			for mk in game[k]:
				if not (out["meta"] as Dictionary).has(mk):
					out["meta"][mk] = game[k][mk]
					added.append("meta." + str(mk))
	if not added.is_empty():
		mp.trace.note("world from the game's save adds: %s" % ", ".join(added))


func send_full_sync(pid: int) -> void:
	# loose needles the late joiner missed: [index, position, who holds it]
	var needles: Array = []
	var bodies := _needle_bodies()
	for idx in bodies:
		needles.append([idx, _npos(bodies[idx]), _holder_of(idx)])
	for idx in _holder:
		if not bodies.has(idx):
			needles.append([idx, Vector3.ZERO, int(_holder[idx])])
	mp._rx_full_sync.rpc_id(pid, field.heights, builds.to_array(), Tech.to_dict(), needles)
	if props_sync != null and is_instance_valid(props_sync):
		props_sync.send_all(pid)
	if belts_sync != null and is_instance_valid(belts_sync):
		belts_sync.send_all(pid)
	if boards_sync != null and is_instance_valid(boards_sync):
		boards_sync.send_all(pid)
	if tables_sync != null and is_instance_valid(tables_sync):
		tables_sync.send_all(pid)
	if machines_sync != null and is_instance_valid(machines_sync):
		machines_sync.send_all(pid)


func on_full_sync(heights: PackedFloat32Array, host_builds: Array, tech: Dictionary, needles: Array = []) -> void:
	# what we spent or earned since the last state tick goes out now: the
	# rebaseline at the end of this used to drop it on the floor
	if _is_client():
		_state_tick()
	for n in needles:
		var holder := int(n[2])
		on_needle("claim" if holder != 0 else "spawn", int(n[0]), n[1], holder)
	if field != null and heights.size() == field.heights.size():
		var idx := PackedInt32Array()
		var vals := PackedFloat32Array()
		var h: PackedFloat32Array = field.heights
		for i in heights.size():
			if absf(heights[i] - h[i]) > HAY_EPS:
				idx.append(i)
				vals.append(heights[i])
		if not idx.is_empty():
			on_hay(1, idx, vals)
		_hay_base = field.heights.duplicate()
	if builds != null:
		var want := {}
		for d in host_builds:
			if d is Dictionary and not TABLE_ROWS.has(str(d.get("type", ""))):
				want[_bkey(d)] = d
		var have := _scan_builds()
		var adds: Array = []
		var removes: Array = []
		for k in want:
			if not have.has(k):
				adds.append(want[k])
		for k in have:
			if not want.has(k):
				removes.append(have[k])
		if not adds.is_empty() or not removes.is_empty():
			_builds_dirty = false
			await on_builds(adds, removes)
		_bkeys = _scan_builds()
	_tech_mute = true
	Tech.from_dict(tech)
	_tech_mute = false
	_st_base = _capture_state()


func _on_pile_replaced() -> void:
	if not mp.active():
		_pile_seed = GameState.run_seed
		return
	if mp.is_host:
		_frozen = true
		mp.ui.notify(mp.t("new_pile_host"))
		await get_tree().create_timer(1.5).timeout
		if not is_inside_tree():
			return
		rebaseline()
		mp.resync_all()
	else:
		# We just paid for the load. Get that out before freezing stops the
		# state tick, or the host undoes its own charge expecting ours and the
		# pile ends up free for everyone. Say how we paid, so the host can put
		# it back if it cannot take a new load after all.
		var on_credit: bool = float(GameState.debt) > float(_st_base.get("debt", 0.0)) + 0.5
		_state_tick()
		_frozen = true
		# the host owns the pile; ask it to swap its pile, it will send us the result
		mp.ui.notify(mp.t("new_pile_client"))
		mp._rx_new_pile_request.rpc_id(1, on_credit)


func host_new_pile_for_client(pid: int, on_credit: bool = false) -> void:
	# The client already paid on its side (that arrives as a state delta),
	# so undo the host-side charge of the delivery.
	var money: float = GameState.money
	var debt: float = GameState.debt
	var stacks: int = GameState.stacks_ordered
	var seed_before := GameState.run_seed
	if world.has_method("_deliver_new_pile"):
		world._deliver_new_pile(false)
	GameState.money = money
	GameState.debt = debt
	GameState.stacks_ordered = stacks
	GameState.money_changed.emit(money)
	GameState.debt_changed.emit(debt)
	if GameState.run_seed == seed_before:
		# The host could not take a new load right now (the landing spot is
		# blocked, or no load may be ordered). The guest's payment already came
		# in with its state delta: give it back, then put the guest back.
		if GameState.stacks_ordered > 0:
			GameState.stacks_ordered -= 1
			if on_credit:
				GameState.debt = maxf(0.0, GameState.debt - GameState.credit_stack_fee())
				GameState.debt_changed.emit(GameState.debt)
			else:
				GameState.money += GameState.next_stack_fee()
				GameState.money_changed.emit(GameState.money)
		mp.send_world(pid)


# ---------------------------------------------------------------- loose needles
# Uncovered needles are physics bodies in LiveStrandManager.needles, tagged
# with meta "needle_index". Everyone sees a needle once someone uncovers it;
# picking it up claims it (it vanishes for the others) so it can only be
# handed in once. States per index: "free" (lying here), "held" (in our hand),
# "away" (someone else is holding it).

func _live() -> Node:
	return world.get("live")


# A needle in a hand or tucked into a building can be out of the tree for a
# moment; reading its global position then logs `!is_inside_tree()` errors
# (seen in players' logs) and returns the origin. Use its local spot instead.
func _npos(b: Variant) -> Vector3:
	var n := b as Node3D
	if n == null:
		return Vector3.ZERO
	return n.global_position if n.is_inside_tree() else n.position


func _needle_bodies() -> Dictionary:
	var out := {}
	var live := _live()
	if live == null:
		return out
	for b in live.get("needles"):
		if is_instance_valid(b) and not b.is_queued_for_deletion():
			var idx := int(b.get_meta("needle_index", -1))
			if idx >= 0:
				out[idx] = b
	return out


func _held_needle() -> int:
	var hand: Variant = player.get("hand") if player != null and is_instance_valid(player) else null
	if hand != null and is_instance_valid(hand) and hand.has_method("held_needle_index"):
		return int(hand.held_needle_index())
	return -1


func _needle_tick() -> void:
	var cur := _needle_bodies()
	var held := _held_needle()
	for idx in cur:
		var st: String = _needles.get(idx, "")
		if st == "away":
			continue
		if st == "":
			# a new needle here: the host's own pile uncovered it, or one of our
			# tools lifted it out (the shovel does); either way everyone sees it
			_needles[idx] = "free"
			st = "free"
			if mp.is_host:
				_needle_out("spawn", idx, _npos(cur[idx]), 0)
			else:
				mp._rx_needle_req.rpc_id(1, "spawn", idx, _npos(cur[idx]))
		if idx == held and st == "free":
			_needles[idx] = "held"
			_needle_claim(idx)
		elif idx != held and st == "held":
			_needles[idx] = "free"
			if mp.is_host:
				_holder.erase(idx)
				_needle_out("spawn", idx, _npos(cur[idx]), 0)
			else:
				mp._rx_needle_req.rpc_id(1, "drop", idx, _npos(cur[idx]))
	for idx in _needles.keys():
		if _needles[idx] == "away" or cur.has(idx):
			continue
		var was: String = _needles[idx]
		_needles.erase(idx)
		if mp.is_host:
			# the host's copy is the one that counts
			_holder.erase(idx)
			_needle_out("gone", idx, Vector3.ZERO, 0)
		elif was == "held":
			# ours, and we used it up (handed it in)
			mp._rx_needle_req.rpc_id(1, "gone", idx, Vector3.ZERO)
		else:
			# a loose needle vanished here only (our physics lost it): that is
			# no reason to take it off everybody, ask the host where it is
			mp._rx_needle_req.rpc_id(1, "want", idx, Vector3.ZERO)


func _holder_of(idx: int) -> int:
	if _holder.has(idx):
		return int(_holder[idx])
	return 1 if mp.is_host and idx == _held_needle() else 0


func _needle_out(kind: String, idx: int, pos: Vector3, holder: int) -> void:
	mp._rx_needle.rpc(kind, idx, pos, holder)


# We picked a needle up. The host decides: first come, first served.
func _needle_claim(idx: int) -> void:
	if not mp.is_host:
		mp._rx_needle_req.rpc_id(1, "claim", idx, Vector3.ZERO)
		return
	var h := int(_holder.get(idx, 0))
	if h != 0 and h != 1:
		# a guest's claim got here first: it is theirs
		_apply_needle("claim", idx, Vector3.ZERO, h)
		return
	_holder[idx] = 1
	_needle_out("claim", idx, Vector3.ZERO, 1)


# Host: what a guest says happened to a needle.
func on_needle_req(sender: int, kind: String, idx: int, pos: Vector3) -> void:
	if _frozen or idx < 0:
		return
	var h := _holder_of(idx)
	match kind:
		"claim":
			if h != 0 and h != sender:
				# somebody else has it: tell the guest who, so it lets go
				mp._rx_needle.rpc_id(sender, "claim", idx, Vector3.ZERO, h)
				return
			_holder[idx] = sender
			_apply_needle("claim", idx, Vector3.ZERO, sender)
			_needle_out("claim", idx, Vector3.ZERO, sender)
		"drop":
			if h != sender:
				return
			_holder.erase(idx)
			_apply_needle("spawn", idx, pos, 0)
			_needle_out("spawn", idx, pos, 0)
		"gone":
			if h != sender and h != 0:
				return
			_holder.erase(idx)
			_apply_needle("gone", idx, Vector3.ZERO, 0)
			_needle_out("gone", idx, Vector3.ZERO, 0)
		"spawn":
			if h != 0 or _needle_bodies().has(idx):
				return
			_apply_needle("spawn", idx, pos, 0)
			_needle_out("spawn", idx, pos, 0)
		"want":
			var body: Variant = _needle_bodies().get(idx)
			if h != 0:
				mp._rx_needle.rpc_id(sender, "claim", idx, Vector3.ZERO, h)
			elif body != null:
				mp._rx_needle.rpc_id(sender, "spawn", idx, _npos(body), 0)
			else:
				mp._rx_needle.rpc_id(sender, "gone", idx, Vector3.ZERO, 0)


func on_needle(kind: String, idx: int, pos: Vector3, holder: int = 0) -> void:
	if _frozen:
		return
	_apply_needle(kind, idx, pos, holder)


func _apply_needle(kind: String, idx: int, pos: Vector3, holder: int) -> void:
	var live := _live()
	if live == null:
		return
	var me := multiplayer.get_unique_id()
	var body: RigidBody3D = _needle_bodies().get(idx)
	match kind:
		"spawn":
			if idx == _held_needle():
				return  # our claim is on its way; the host will settle it
			if body != null:
				body.global_position = pos
				body.linear_velocity = Vector3.ZERO
			else:
				live.reveal_needle(idx, pos)
			_needles[idx] = "free"
		"claim":
			if holder == me:
				_needles[idx] = "held"
				return
			# someone else holds it. If we grabbed it too, we were second: it
			# leaves our hand as well, so it can only be handed in once
			if body != null:
				live.consume_needle(body)
			_needles[idx] = "away"
		"gone":
			if body != null:
				live.consume_needle(body)
			_needles.erase(idx)


# A guest left while holding a needle: put it down where they were standing, so
# it is not lost to everybody.
func _drop_needles_of(pid: int) -> void:
	for idx in _holder.keys():
		if int(_holder[idx]) != pid:
			continue
		_holder.erase(idx)
		# the avatar is already gone by now, so use the last pose we had
		var at: Vector3 = GameState.needle_positions[idx] if idx < GameState.needle_positions.size() else Vector3.ZERO
		if _last_at.has(pid):
			at = (_last_at[pid] as Vector3) + Vector3.UP * 0.4
		_apply_needle("spawn", idx, at, 0)
		_needle_out("spawn", idx, at, 0)


# ---------------------------------------------------------------- events / toasts

func _on_needle_found(_index: int, _pos: Vector3) -> void:
	if mp.active() and not _frozen:
		mp._rx_event.rpc("needle", {})


func _on_needle_discovered(type: int, _pos: Vector3) -> void:
	pass


func on_event(id: int, kind: String, _data: Dictionary) -> void:
	match kind:
		"needle":
			toast(mp.t("needle_found") % mp.player_name(id))


func toast(text: String, seconds: float = 3.5) -> void:
	var hud: Variant = world.get("hud")
	if hud != null and is_instance_valid(hud) and hud.has_method("show_toast"):
		hud.show_toast(text, seconds)
	else:
		mp.ui.notify(text)
