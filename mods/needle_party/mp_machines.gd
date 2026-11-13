extends Node

const FrameSlots = preload("mp_frame_slots.gd")
var _scan_slot := FrameSlots.new()
var _pose_slot := FrameSlots.new()

# Machines.
#
# A machine runs on the host only, so the same hay cannot become two bales.
# That used to leave it standing still on everyone else's screen. The host now
# sends three things for each one:
#
#   * where its moving parts are, whatever drives them (the piston rake scrubs
#     an AnimationPlayer, the robotic arm drives its joints from code)
#   * which of its parts are visible and which particles are running, so smoke,
#     flames and lamps show up
#   * the handful of numbers that other systems read: fuel and output for the
#     generator, and every setting a panel can change
#
# Only what changed is sent, and only for machines somebody is standing near.

const TICK := 0.1
const FIELD_TICK := 0.5
const SETTINGS_TICK := 0.1  # switches/recipes go out this fast (see _send_fields)
const EDIT_TICK := 0.05   # how often a guest looks for a setting it changed
var _settings_t := 0.0
# the scan runs half a period apart from the 2 s full pose refresh, so the two
# never land in the same frame
var _scan_offset_done := false
const FIELDS_FULL_TICK := 3.0  # every machine's fields go out in full this often
const EDIT_GUARD_MS := 1500    # see on_fields
const EDIT_RESEND_MS := 2000   # see _send_edits
var _edit_at := {}             # machine key -> when we last sent a new edit for it
var _edit_sent := {}           # machine key -> {field: [value, msec]} last sent
var _fields_full_t := 0.0
const FULL_TICK := 2.0    # how often every part goes out again, packets get lost
const RANGE := 32.0        # metres from a player before a machine is worth sending
const MOVE_EPS := 0.0015
const ANG_EPS := 0.004
# a machine model carries a lot of nodes and the smoke and firebox sit well
# down the list, so do not cut the walk short
# (1.2.19) was 120: the full game's big machines have far more (skyline crane ~690,
# paper machine ~250, smelter ~260), and everything past the first 120 never moved
# on a guest: the crane's trolley and cable stood still. The periodic full refresh
# now resends only parts that have moved (see _moved_ever), so a big machine whose
# parts mostly stand still costs little.
const MAX_PARTS := 1000
const SMOOTH := 22.0
const MAX_RAW := 4 << 20

# What each kind of machine keeps that is worth copying: the numbers other
# parts of the game read (power, stock) and everything a settings panel can
# change. Read from the machine, written back through its setter when it has
# one.
const FIELDS := {
	# not what they make: a guest works that out, see _feed_generators
	"generators": ["fuel", "switched_off", "fed_kw", "unplugged", "tank", "water", "_net_sat",
		"_burning", "arriving", "full_wait", "starved_for"],
	# the panel's stop/start and rate dial live in discharge_rate/resume_rate;
	# without them one player's stopped silo kept emptying on the host
	"silos": ["switched_off", "stored", "queued", "discharge_rate", "resume_rate",
		"pending_needles", "power", "power_blocked", "starved_for", "blocked_for", "_clock", "_left_at"],
	# 1.0.1: every panel setting the current game build has (checked against
	# its scripts); before, a split ratio, route, pick order, drone zone, head
	# aim or depot emptying set by one player never reached the other
	"splitters": ["forced_side", "priority_side", "next_side", "left_share",
		"split_route", "split_route_on", "split_route_alt", "filters", "smart", "manual", "closed_lane", "_holding", "_stuck"],
	"joiners": ["next_side", "out_lane", "manual"],
	"tube_launchers": ["switched_off", "aim", "power", "stored", "pending_needles"],
	# (1.2.19) the rake panel's last stroke (bite, gathered, thrown) and the reasons its
	# header and alert sign give (JAMMED, RAKING NOTHING, BELT FULL): they stayed at 0 / off
	"piston_rakes": ["switched_off", "throw_distance", "last_bite", "last_gathered", "last_thrown",
		"_jam_strokes", "_dry_strokes", "_holding"],
	"pelletizers": ["switched_off", "throw_distance", "stored", "head_yaw", "_jam", "pending_needles", "iron_points", "copper_points", "poured",
		"_grind", "_cycle", "_holding", "starved_for", "furnace_heat",
		# the smelter's working state, see _drive_smelter
		"_load_clock", "_heat_clock", "_pour_clock", "_casting_metal", "_gripped", "_released",
		"_held_out", "activity", "_load_rate", "_heat_rate", "_cast_rate", "_handoff_at", "_cast_length"],
	# _stall: the reason it shows, "nowhere to put it" and the like
	"robotic_arms": ["switched_off", "accept_mask", "tier_index", "pick_order", "completed_cycles", "delivered_needles", "_stall"],
	"scanners": ["switched_off", "tier_index", "banked", "stored", "thrown", "cannon_yaw",
		"cannon_throw", "_cycle_left", "_emit_left", "_loads", "_loads_total", "_outgoing", "behind", "starved_for"],
	"hay_lifts": ["down", "head_turn"],
	# renamed power lines, cables strung or cut by hand
	"power_poles": ["line_name", "links_at", "cuts_at"],
	"compressors": ["switched_off", "stored", "_jam", "pending_needles", "_cycle", "starved_for", "_press", "handover_frame"],
	"pulpers": ["switched_off", "stored", "_jam", "pending_needles", "water", "slabs_made", "_cycle", "starved_for", "_bed"],
	# _t/_running: a fabricator's work timer, or the guest's panel shows its own
	# _cycle_recipe: the part a fabricator's mould is making (latched from recipe when a cycle
	# starts; only fabricators have it). Its mould is redrawn by _sync_mould, see REDRAW.
	"papers": ["switched_off", "queued", "recipe", "queued_needles", "pending_needles", "pressed", "_t", "_running",
		"_stage", "_out_left", "_out_strands", "made", "cycles", "starved_for", "_cycle_recipe"],
	# full game: assemblers, bioplastic reactors and carbon kilns are briquette
	# presses underneath and live in this list; "recipe" is theirs (a plain
	# press has none, and a field a machine lacks is skipped)
	"briquette_presses": ["switched_off", "stored_strands", "stored_bricks", "recipe", "_jam", "pending_needles", "slots", "made",
		"_cycle", "starved_for"],
	# depots are wrappers underneath: emptying is theirs
	"wrappers": ["switched_off", "queued", "emptying", "emptying_kinds", "queued_needles", "pending_needles", "taken",
		"_wrap", "starved_for"],
	"boreholes": ["switched_off"],
	"dump_hatches": ["stored"],
	"needle_radars": ["cooldown", "last_found", "phase", "_marks"],
	"work_lamps": ["brightness", "_off", "tint", "sensor_auto", "sensor_on", "sensor_off", "sensor_dark", "paint"],
	# full game additions. Panel presses, fabricators and fibre machines are
	# paper machines underneath; depot drones are hay drones.
	# _stowed: what a depot drone's pod holds (made up; travels as stowed_records()). Its fill
	# lamps count it, and they stayed as they were when the guest joined.
	"hay_drones": ["switched_off", "mode", "zone_at", "zone_r", "drop_at", "drop_kind", "takes", "trips", "strands_put",
		"_stowed"],
	"hay_excavators": ["switched_off", "throw_distance", "dug", "thrown", "aimed", "aim_yaw", "aim_pitch", "aim_intake"],
	"skyline_cranes": ["switched_off", "zone_at", "zone_radius", "dug", "lots", "feed_rate"],
	"pipe_pumps": ["switched_off", "tier"],
}

# Machines from the full game's mixed lists (extras, fixtures, ...) go under
# "x:<script name>"; fittings there that keep running on a guest but have a
# switch go under "xs:<script name>". Both use these when nothing more
# specific is listed above.
const MIXED_FIELDS := ["switched_off", "recipe", "mode", "setting"]

# Machines that keep running on clients but whose settings still have to match.
const SETTINGS_ONLY := ["work_lamps", "power_poles"]

# The areas a machine watches for something to eat. Named rather than walked,
# because a machine's other areas are the scanner's beam and the stairs' climb
# zone, which have nothing to do with taking hay in.
const MOUTHS := ["_intake", "_hopper", "_mouth", "_mouth_area", "_wad_mouth",
	"_brick_mouth", "_catch"]
const MOUTH_TICK := 0.25

# What a panel lets a player change, as opposed to what a machine works out for
# itself. Only these travel back from a guest: fuel, stock, output and the rest
# are the host's to count, and taking a guest's word for them would let the
# same hay pay twice.
const SETTINGS := {
	"generators": ["switched_off"],
	"silos": ["switched_off", "discharge_rate", "resume_rate"],
	"splitters": ["forced_side", "priority_side", "left_share", "split_route",
		"split_route_on", "split_route_alt", "filters", "smart", "manual", "closed_lane"],
	"joiners": ["out_lane", "manual"],
	"tube_launchers": ["switched_off", "aim", "power"],
	# _drive: the panel's Back/Forward, made up, see _send_drives
	"piston_rakes": ["switched_off", "throw_distance", "_drive"],
	"pelletizers": ["switched_off", "throw_distance", "head_yaw", "_jam"],
	"robotic_arms": ["switched_off", "accept_mask", "tier_index", "pick_order"],
	"scanners": ["switched_off", "tier_index", "cannon_yaw", "cannon_throw"],
	"hay_lifts": ["down", "head_turn"],
	"power_poles": ["line_name", "links_at", "cuts_at"],
	"compressors": ["switched_off", "_jam"],
	"pulpers": ["switched_off", "_jam"],
	"papers": ["switched_off", "recipe"],
	"briquette_presses": ["switched_off", "recipe", "_jam"],
	"wrappers": ["switched_off", "emptying", "emptying_kinds"],
	"boreholes": ["switched_off"],
	"needle_radars": ["phase"],  # the button: the host's radar goes off, see _apply_field
	"work_lamps": ["brightness", "_off", "tint", "sensor_auto", "sensor_on", "sensor_off", "sensor_dark", "paint"],
	# full game additions (see FIELDS)
	"hay_drones": ["switched_off", "mode", "zone_at", "zone_r", "drop_at", "drop_kind", "takes"],
	"hay_excavators": ["switched_off", "throw_distance", "aimed", "aim_yaw", "aim_pitch", "aim_intake"],
	"skyline_cranes": ["switched_off", "zone_at", "zone_radius", "feed_rate"],
	"pipe_pumps": ["switched_off"],
}

# The full game's lists that mix machines with plain fittings.
const MIXED_GROUPS := ["extras", "belt_gates", "switch_boxes", "fixtures", "belt_poles"]


func _fields_of(group: String) -> Array:
	if FIELDS.has(group):
		return FIELDS[group]
	return _mixed_fields(group)


func _settings_of(group: String) -> Array:
	if SETTINGS.has(group):
		return SETTINGS[group]
	return _mixed_fields(group)


# "x:"/"xs:"/"d:" groups: the fitting's own list when it has one (a fan's aim,
# a sign's text...), else the common machine settings; paint either way.
var _mixed_cache := {}

func _mixed_fields(group: String) -> Array:
	if _mixed_cache.has(group):
		return _mixed_cache[group]
	var out: Array = []
	var colon := group.find(":")
	if colon > 0:
		var kind := group.substr(colon + 1)
		if KIND_FIELDS.has(kind):
			out = (KIND_FIELDS[kind] as Array).duplicate()
		elif not group.begins_with("d:"):
			out = MIXED_FIELDS.duplicate()
		else:
			out = ["_p"]  # fixtures; skipped for anything without apply_params
		if not out.has("paint"):
			out.append("paint")
	_mixed_cache[group] = out
	return out


func _settings_only(group: String) -> bool:
	return SETTINGS_ONLY.has(group) or group.begins_with("xs:") or group.begins_with("d:")

var mp: Node
var world: Node
var builds: Node

var _parts := {}    # key -> Array[Node3D] in walk order
var _ids := {}      # key -> PackedInt32Array, each part named by its path
var _slot := {}     # key -> {part id: index into _parts}
var _sent := {}     # key -> {part id: last transform broadcast}
var _full := false  # this machine (in _send_poses) / this packet gets a full refresh
const FULL_SLICES := 20  # FULL_TICK / TICK
var _full_phase := 0
var _refresh_t := 0.0
var _log := OS.get_environment("MP_DEBUG_PROPS") != ""
var _fx := {}       # key -> per part: its light and its shader values
var _fx_sent := {}  # key -> {part id << 16 | slot + 1: last value sent}
var _fx_seen := {}  # key -> {part id: its material's values when last looked at}
var _flags := {}    # key -> PackedByteArray last broadcast
var _vals := {}     # key -> Dictionary of fields last broadcast
var _goal := {}     # key -> {part index: Transform3D}
var _nodes := {}    # key -> machine node
var _group := {}    # key -> which build array it came from
var _scan_t := 0.0
var _t := 0.0
var _field_t := 0.0
var _edit_t := 0.0
var _mouth_t := 0.0
var _theirs := {}   # guest: key -> the settings as the host last stated them
var _alias := {}    # a key from the host -> our key for the same machine
var _rescan_at := -100000  # msec, last rescan forced by a key we did not know
# a key naming a machine we do not have (yet): skip it until then instead of
# walking every machine again for every packet that mentions it
const UNKNOWN_KEY_WAIT := 1000
const KEY_SLACK := 0.25   # metres: the same machine, placed on both sides
const BIG_PACKET := 1000  # compressed bytes; past this a packet goes reliable


func start(mp_node: Node, world_node: Node) -> void:
	mp = mp_node
	world = world_node
	builds = world.get("builds")
	_rescan()


func shutdown() -> void:
	_parts.clear()
	_fx.clear()
	_ids.clear()
	_slot.clear()
	_sent.clear()
	_flags.clear()
	_vals.clear()
	_goal.clear()
	_nodes.clear()
	_walked.clear()
	_group.clear()


# ------------------------------------------------------------------ the parts

# Every machine worth sending, under a key both sides work out the same way:
# the array it lives in and where it stands.
func _rescan() -> void:
	if builds == null or not is_instance_valid(builds):
		return
	var ws: Node = mp.world_sync
	var groups: Array = ws.get_script().get_script_constant_map().get("CLIENT_FROZEN", [])
	_nodes.clear()
	_group.clear()
	# (The part lists used to be thrown away here every 2 s, so the next pose
	# tick walked every machine's whole model again and hashed a path for each
	# part: ~12,000 in one frame, an 80 ms freeze every 2 s on host and guest.
	# They are kept now; see _refresh_parts.)
	for group in groups + SETTINGS_ONLY:
		var arr: Variant = builds.get(group)
		if not (arr is Array):
			continue
		for n in arr:
			if n is Node3D and is_instance_valid(n):
				var key := _key(String(group), n)
				_nodes[key] = n
				_group[key] = String(group)
	_rescan_mixed(ws)
	_rescan_deco(ws, groups + SETTINGS_ONLY + MIXED_GROUPS)
	_refresh_parts()
	# forget machines that are gone (this used to run over _parts after it was
	# cleared, so it never did anything and every demolished machine's state
	# stayed behind for good)
	for d in [_sent, _flags, _vals, _goal, _fx_sent, _fx_seen, _theirs, _edit_sent, _edit_at, _far_sent, _moved_ever, _anim_sent, _anim_on, _pbuf,
			_claw_sent, _claw_due, _claw_on, _claw_t]:
		for key in (d as Dictionary).keys():
			if not _nodes.has(key):
				(d as Dictionary).erase(key)
	for key in _alias.keys():
		if not _nodes.has(_alias[key]):
			_alias.erase(key)


# Full game: the mixed lists. What the factory clock runs as a machine is
# "x:<script>" (frozen on a guest, poses and fields from the host); a fitting
# with a switch is "xs:<script>" (runs everywhere, only its settings travel).
# Both sides ask the same clock, so they file a node under the same group.
func _rescan_mixed(ws: Node) -> void:
	var clock: Node = ws.call("_factory_clock") if ws.has_method("_factory_clock") else null
	for group in MIXED_GROUPS:
		var arr: Variant = builds.get(group)
		if not (arr is Array):
			continue
		for n in arr:
			if not (n is Node3D) or not is_instance_valid(n):
				continue
			var s: Variant = (n as Node).get_script()
			var kind := "node"
			if s is Script:
				kind = (s as Script).resource_path.get_file().get_basename()
			var g := ""
			# a guest's frozen copy may no longer count as running, so the
			# freeze mark settles it there
			if (n as Node).has_meta("mp_stopped") or (clock != null and bool(clock.call("is_machine", n))):
				g = "x:" + kind
			elif "switched_off" in n:
				g = "xs:" + kind
			elif KIND_FIELDS.has(kind) or _paintable(n):
				g = "d:" + kind
			else:
				continue
			var key := _key(g, n)
			_nodes[key] = n
			_group[key] = g


# Our key for a machine the host named. Both sides place a machine from the
# same save data, but its position can come out a hair different, and the key
# is built from it; so an exact miss falls back to the nearest machine of the
# same kind. A key that matches nothing waits a second before the next rescan.
func _local_key(key: String) -> String:
	if _nodes.has(key):
		return key
	var known: String = _alias.get(key, "")
	if known != "" and _nodes.has(known):
		return known
	var now := Time.get_ticks_msec()
	if now - _rescan_at >= UNKNOWN_KEY_WAIT:
		_rescan_at = now
		_rescan()
		if _nodes.has(key):
			return key
	var bar := key.find("|")
	if bar < 0:
		return ""
	var group := key.substr(0, bar)
	var xyz := key.substr(bar + 1).get_slice("|", 0).split(",")
	if xyz.size() != 3:
		return ""
	var at := Vector3(float(xyz[0]), float(xyz[1]), float(xyz[2]))
	var best := ""
	var best_d := KEY_SLACK * KEY_SLACK
	for k in _nodes:
		if _group.get(k, "") != group:
			continue
		var n: Variant = _nodes[k]
		if n == null or not is_instance_valid(n) or not (n as Node3D).is_inside_tree():
			continue
		var d := _pos_of(n as Node3D).distance_squared_to(at)
		if d < best_d:
			best_d = d
			best = k
	if best != "":
		_alias[key] = best
	return best


func _key(group: String, n: Node3D) -> String:
	var p := _pos_of(n)
	var k := "%s|%.2f,%.2f,%.2f" % [group, p.x, p.y, p.z]
	# belts, rails, beams, pipes: placed by two ends, and several can share one
	var b: Variant = n.get("b") if "b" in n else null
	if "a" in n and b is Vector3:
		k += "|%.2f,%.2f,%.2f" % [b.x, b.y, b.z]
	return k


func _pos_of(n: Node3D) -> Vector3:
	var a: Variant = n.get("a") if "a" in n else null
	if a is Vector3:
		return a
	return n.global_position if n.is_inside_tree() else n.position


# ------------------------------------------------------------------ fittings and paint
# Checked against every building class in the game's files (their save data,
# to_dict). Machines are above; these are the fittings and decor a player can
# set or paint. Before, a fitting without an on/off switch was not looked at at
# all, and one with a switch only sent the switch: a sign's text, a fan's aim,
# a light's colour, a valve, a belt gate, or the paint on a belt, wall or
# platform changed for the player who did it only.
const KIND_FIELDS := {
	"yard_fan": ["switched_off", "turn", "tilt", "height", "strength", "paint"],
	"jump_pad": ["switched_off", "angle", "strength", "paint"],
	"yard_light": ["switched_off", "tint", "brightness", "tilt", "sensor_auto",
		"sensor_on", "sensor_off", "sensor_dark", "paint"],
	# fixtures (signs, markings, ladders, ramps, beams...) keep their settings in
	# one parameter block, "p" in their save data, applied with apply_params()
	"yard_sign": ["_p", "paint"],
	"marking": ["_p", "paint"],
	"pipe_valve": ["setting"],
	"belt_gate": ["shut"],
	"power_pole": ["line_name", "links_at", "cuts_at"],
	# generators that live in the mixed lists
	"gas_plant": ["switched_off", "fuel", "fed_kw", "unplugged", "tank", "water", "_net_sat", "_burning", "recipe", "mode", "setting"],
	"biogas_digester": ["switched_off", "fuel", "fed_kw", "unplugged", "tank", "water", "_net_sat", "_burning", "recipe", "mode", "setting"],
	"power_box": ["line_name", "links_at", "cuts_at"],
	"wall_outlet": ["line_name", "links_at", "cuts_at"],
}
# what to call after new values are in, so the fitting shows them
const KIND_REFRESH := {
	"yard_light": ["_apply", "apply_tilt"],
	"work_lamp": ["_apply_brightness", "_apply_tint"],
	"pipe_valve": ["_apply"],
	"belt_gate": ["_apply_wall"],
	"wall_outlet": ["_rewire"],
	"hay_excavator": ["_aim_moved", "_draw_tube"],
	"yard_fan": ["_write_dial", "_apply_lamp", "_aim_arc"],
	"jump_pad": ["_apply_lamp"],
}


func _kind_of(n: Node) -> String:
	var s: Variant = n.get_script()
	return (s as Script).resource_path.get_file().get_basename() if s is Script else "node"


func _paintable(n: Node) -> bool:
	return "paint" in n and n.has_method("set_paint")


# Everything in the yard's other lists that has settings or paint, filed as
# "d:<script>": runs on every PC, only its settings travel.
func _rescan_deco(ws: Node, taken: Array) -> void:
	var lists: Array = ws.get_script().get_script_constant_map().get("BUILD_ARRAYS", [])
	for group in lists:
		if taken.has(group):
			continue
		var arr: Variant = builds.get(group)
		if not (arr is Array):
			continue
		for n in arr:
			if not (n is Node3D) or not is_instance_valid(n):
				continue
			var kind := _kind_of(n)
			if not KIND_FIELDS.has(kind) and not _paintable(n):
				continue
			var g := "d:" + kind
			var key := _key(g, n)
			_nodes[key] = n
			_group[key] = g


# After a batch of fields landed on one node: repaint what needs it.
func _after_fields(n: Node) -> void:
	if n == null or not is_instance_valid(n):
		return
	for m in KIND_REFRESH.get(_kind_of(n), []):
		if m == "_rewire":
			# cables strung by hand: let the game restring and rebuild the grid
			if builds != null and is_instance_valid(builds) and builds.has_method("_rewire_now"):
				builds.call_deferred("_rewire_now")
		elif n.has_method(m):
			n.call(m)


# The model's own nodes, in tree order. Both sides build the machine from the
# same code, so the same walk gives the same list and an index is enough.
# Keep each machine's part list between scans. Drop it when the machine is
# gone or was rebuilt (another node under the same key), and walk a few
# machines again per scan in turn, so parts the game adds while it runs
# (smoke, lamps, markers) are still picked up: spread out instead of all
# machines in one frame.
const REWALK_PER_SCAN := 6
var _walked := {}      # key -> the node its part list was walked from

# (1.2.19) Animations. Most machines move their parts with AnimationPlayers. A guest's
# copy is frozen, so they stood still there and the parts only moved with the 10 Hz
# poses: a step every few frames, the wrapper and press looked choppy. Now the host
# sends what each player is playing (clip, time, speed) and the guest plays it itself
# at full frame rate; the poses leave the parts those clips move alone. The same for
# the VAT machines (pulper, borehole, digester...): their motion is a clock in a shader
# that no pose carries, so the host sends that clock's phase and speed.
const ANIM_RESEND_MS := 1000   # host: a playing clip is stated again this often
const ANIM_DRIFT_S := 0.12     # guest: seek only when further off than this
const VAT_DRIFT := 0.05
const CLOCK_VARS := ["_clock", "_vat_clock", "_gen_clock"]
const VAT_MESH_VARS := ["_vat_meshes", "_gen_vat"]
var _players := {}     # key -> Array[AnimationPlayer] in a fixed order
var _moved_ever := {}  # host: key -> {part id: true} parts seen moving at least once
var _anim_seen := {}   # host: "key#player" -> [clip, time, usec] when last read
var _anim_sent := {}   # host: key -> [msec, the last state sent, the last clock sent]
var _owned := {}       # guest: key -> {part id: true} parts a clip moves
var _anim_on := {}     # guest: key -> true once a clip state was applied
var _rewalk_at := 0    # round-robin position


func _refresh_parts() -> void:
	for key in _parts.keys():
		if not _nodes.has(key) or _nodes[key] != _walked.get(key):
			_forget_parts(key)
	# rotate over the machine list itself (same order every scan): _parts
	# reorders as lists are walked again, which made a fixed step skip some
	var keys: Array = _nodes.keys()
	if keys.is_empty():
		return
	for i in mini(REWALK_PER_SCAN, keys.size()):
		_forget_parts(keys[(_rewalk_at + i) % keys.size()])
	_rewalk_at = (_rewalk_at + REWALK_PER_SCAN) % maxi(1, keys.size())


func _forget_parts(key: Variant) -> void:
	_parts.erase(key)
	_ids.erase(key)
	_slot.erase(key)
	_fx.erase(key)
	_walked.erase(key)
	_players.erase(key)
	_owned.erase(key)
	_anim_on.erase(key)


func _parts_of(key: String) -> Array:
	if _parts.has(key):
		return _parts[key]
	_walked[key] = _nodes.get(key)
	var out: Array = []
	var ids := PackedInt32Array()
	var slot := {}
	var n: Variant = _nodes.get(key)
	if n != null and is_instance_valid(n):
		# from the machine itself, not from its model: the fire, the lamps and
		# the smoke column are made in code and hang off the machine, so a walk
		# that started at the model never saw them
		var base: Node = n as Node
		# (1.2.0) parts and their paths in one walk. Building each path
		# afterwards walked up to the machine again for every part and counted
		# siblings at every level: 5-10 ms for one big machine. Same names.
		var paths := PackedStringArray()
		_walk_named(base, "", out, paths, "_claw_straw" in base)
		# A part is named by where it hangs, not by its place in the list: the
		# game adds and removes nodes of its own (alert markers, dust, range
		# rings), and a machine with one more of those would otherwise hand
		# every pose to the wrong part and come out crooked.
		for i in out.size():
			# 31 bits: these ids travel in a signed 32-bit array, and a hash that
			# spills over the sign bit would arrive as a different number and
			# match nothing. It cost half the parts of every machine.
			var id := int(paths[i].hash()) & 0x7fffffff
			ids.append(id)
			slot[id] = i
	_parts[key] = out
	_ids[key] = ids
	_slot[key] = slot
	return out


func _ids_of(key: String) -> PackedInt32Array:
	_parts_of(key)
	return _ids.get(key, PackedInt32Array())


func _slot_of(key: String) -> Dictionary:
	_parts_of(key)
	return _slot.get(key, {})


func _walk(n: Node, out: Array) -> void:
	for child in n.get_children():
		if out.size() >= MAX_PARTS:
			return
		if child is Node3D:
			out.append(child)
			_walk(child, out)


# The same walk as _walk, naming each part as it goes, exactly like
# _part_path/_part_name do: a node's own name, or "<class>#<n>" for a node the
# engine named ("@..."), n counting earlier siblings of the same class.
func _walk_named(n: Node, prefix: String, out: Array, paths: PackedStringArray, arm := false) -> void:
	var count := {}  # class -> siblings of that class seen so far
	for child in n.get_children():
		if out.size() >= MAX_PARTS:
			return
		var cls := child.get_class()
		var seen: int = count.get(cls, 0)
		count[cls] = seen + 1
		if not (child is Node3D):
			continue
		# a robot arm's hay in the claw ("ClawStraw", made when it first bites):
		# the guest builds its own from the count, see _claw_count
		if arm and child is MultiMeshInstance3D and (child as Node3D).top_level:
			continue
		var nm := String(child.name)
		if nm.begins_with("@"):
			nm = "%s#%d" % [cls, seen]
		var path := nm if prefix == "" else prefix + "/" + nm
		out.append(child)
		paths.append(path)
		_walk_named(child, path, out, paths)


# ------------------------------------------------------------------ ticks

# stopwatch: anything over 4 ms in one frame goes into mp_trace.log by name
func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_process_inner(delta)
	if mp != null and is_instance_valid(mp):
		mp.perf("machines", Time.get_ticks_usec() - t0)


func _process_inner(delta: float) -> void:
	var _tp_ease := Time.get_ticks_usec()
	_ease(delta)
	if mp != null:
		mp.perf("machines.ease", Time.get_ticks_usec() - _tp_ease)
	if mp == null or not mp.active() or multiplayer.multiplayer_peer == null:
		return
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	if not _scan_offset_done:
		_scan_offset_done = true
		_scan_t = -1.0
	if not mp.is_host:
		var _tp_guest := Time.get_ticks_usec()
		_drain_poses()
		mp.perf("machines.drain_poses", Time.get_ticks_usec() - _tp_guest)
		_tp_guest = Time.get_ticks_usec()
		_drain_fields()
		mp.perf("machines.drain_fields", Time.get_ticks_usec() - _tp_guest)
		_tp_guest = Time.get_ticks_usec()
		_present_smelters(delta)
		mp.perf("machines.smelters", Time.get_ticks_usec() - _tp_guest)
		_tp_guest = Time.get_ticks_usec()
		_tick_radar_marks(delta)
		mp.perf("machines.radar", Time.get_ticks_usec() - _tp_guest)
		_feed_generators(delta)
		# a guest works the panels on its own copy, which the machine itself
		# ignores, so watch for what the player changed and hand it to the host
		_scan_t += delta
		if _scan_t >= 2.0 and _scan_slot.take():
			_scan_t = 0.0
			var _tp_rescan := Time.get_ticks_usec()
			_rescan()
			mp.perf("machines.rescan", Time.get_ticks_usec() - _tp_rescan)
		_edit_t += delta
		if _edit_t >= EDIT_TICK:
			_edit_t = 0.0
			var _tp_edits := Time.get_ticks_usec()
			_send_drives()
			_send_edits()
			mp.perf("machines.edits", Time.get_ticks_usec() - _tp_edits)
		return
	if mp.players.size() < 2:
		return
	_scan_t += delta
	if _scan_t >= 2.0 and _scan_slot.take():
		_scan_t = 0.0
		var _tp_rescan := Time.get_ticks_usec()
		_rescan()
		mp.perf("machines.rescan", Time.get_ticks_usec() - _tp_rescan)
	_t += delta
	if _t >= TICK and _pose_slot.take():
		_t = 0.0
		# (1.1.4, idea from xRangerDE's Multiplayer Enhanced, MIT) the full
		# refresh used to send every part of every machine in one tick each
		# FULL_TICK; now each tick refreshes the machines whose turn it is, so
		# every machine still gets one every FULL_TICK, never all at once
		_full_phase = (_full_phase + 1) % FULL_SLICES
		var _tp_poses := Time.get_ticks_usec()
		_send_poses()
		mp.perf("machines.poses", Time.get_ticks_usec() - _tp_poses)
	# (1.1.4) Every SETTINGS_TICK: the switches and settings of every machine,
	# plus the full fields (stock, counters...) of the next fifth of them. The
	# full pass used to read every field of every machine in one frame every
	# FIELD_TICK (about 5 ms each time on a mid-size yard). Same coverage:
	# each machine still gets its full fields every FIELD_TICK.
	_settings_t += delta
	if _settings_t >= SETTINGS_TICK:
		_settings_t = 0.0
		var _tp_settings := Time.get_ticks_usec()
		_send_fields(true)
		mp.perf("machines.settings", Time.get_ticks_usec() - _tp_settings)
		var _tp_slice := Time.get_ticks_usec()
		if _field_at == 0:
			_field_keys = _nodes.keys()
			_field_round += 1
		var per := maxi(1, int(ceil(float(_field_keys.size()) * SETTINGS_TICK / FIELD_TICK)))
		var slice: Array = _field_keys.slice(_field_at, _field_at + per)
		# say everything again now and then: only sending changes meant a guest
		# that once got out of step (a lost update, a frozen copy that moved its
		# own counter) stayed wrong until F8
		if _field_round % int(FIELDS_FULL_TICK / FIELD_TICK) == 0:
			for k in slice:
				_vals.erase(k)
		_send_fields(false, slice)
		_field_at += per
		if _field_at >= _field_keys.size():
			_field_at = 0
		mp.perf("machines.fullslice", Time.get_ticks_usec() - _tp_slice)
	_mouth_t += delta
	if _mouth_t >= MOUTH_TICK:
		_mouth_t = 0.0
		var _tp_mouths := Time.get_ticks_usec()
		_feed_mouths()
		mp.perf("machines.mouths", Time.get_ticks_usec() - _tp_mouths)


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


const FAR_RANGE := 90.0     # metres: out to here every MID_POSE_EVERY-th pose tick
const MID_POSE_EVERY := 2   # 5 a second
const FAR_POSE_EVERY := 4   # the rest of the yard: 2.5 a second (FULL_SLICES is a multiple of both)
const NEAR_SHARE_US := 4000 # of POSE_BUDGET_US: the near ones first, the rest for the far ones
var _due_at := 0            # host: where the far ones carry on next tick

func _near_within(at: Vector3, watchers: Array, r: float) -> bool:
	for w in watchers:
		if at.distance_squared_to(w) < r * r:
			return true
	return false


func _send_poses() -> void:
	var watchers := _watchers()
	if watchers.is_empty():
		return
	var batch := {}
	var any_full := false
	_mat_vals.clear()
	# (1.2.0) a time budget per tick, carried on next tick from where it
	# stopped: near a busy factory this pass took 15 ms (up to 99 ms) at once
	var t0 := Time.get_ticks_usec()
	var walks := 0
	# (1.2.19) Every machine in the yard moves on a guest now, nearest first. Only RANGE used
	# to count (around each guest), and from where players start the robot arms on the upper
	# ring (~40 m) stood still on a guest while they worked on the host (measured: moving 90%
	# of frames on the host, 4% on the guest). Near ones every tick, out to FAR_RANGE every
	# MID_POSE_EVERY-th, the rest of the yard every FAR_POSE_EVERY-th, by turns; the near ones
	# go first, so the time budget never makes them slower.
	var near_k: Array = []
	var due_k: Array = []
	for key in _nodes:
		if _settings_only(String(_group.get(key, ""))):
			continue
		var nn: Variant = _nodes[key]
		if nn == null or not is_instance_valid(nn) or not (nn as Node3D).is_inside_tree():
			continue
		var at := (nn as Node3D).global_position
		if _near(at, watchers):
			near_k.append(key)
			continue
		var every := MID_POSE_EVERY if _near_within(at, watchers, FAR_RANGE) else FAR_POSE_EVERY
		# by the same turn as the full refresh below, so a far one still gets its full one
		if posmod(_full_phase - absi(String(key).hash()), every) == 0:
			due_k.append(key)
	# each list by turns (from where the budget stopped it last tick); the near ones get
	# NEAR_SHARE_US of the budget first, the far ones the rest (near first and the far ones
	# after, with no share of their own, starved them: the arms then moved 14% of the time)
	var first := _pose_at if _pose_at < near_k.size() else 0
	var dfirst := _due_at if _due_at < due_k.size() else 0
	var n_near := near_k.size()
	var keys: Array = near_k.slice(first) + near_k.slice(0, first) + due_k.slice(dfirst) + due_k.slice(0, dfirst)
	var total := keys.size()
	var step := 0
	var near_done := 0
	var due_done := 0
	while step < total:
		var spent := Time.get_ticks_usec() - t0
		if spent > POSE_BUDGET_US:
			break
		if step < n_near and spent > NEAR_SHARE_US:
			step = n_near   # the rest of the near ones go on next tick
			continue
		var key: String = keys[step]
		step += 1
		if step <= n_near:
			near_done = step
		else:
			due_done = step - n_near
		_full = absi(String(key).hash()) % FULL_SLICES == _full_phase
		var n: Variant = _nodes[key]
		if n == null or not is_instance_valid(n) or not (n as Node3D).is_inside_tree():
			continue
		if not _parts.has(key):
			if walks >= POSE_WALKS:
				continue
			walks += 1
		var parts := _parts_of(key)
		if parts.is_empty():
			continue
		# Every part now and then, not only the ones that just moved: poses go
		# out on an unreliable channel, and a part that moves once and stops
		# would stay wrong on the other screen for good if that packet was
		# lost. It also puts right anything that started out differently.
		var last: Dictionary = _sent.get(key, {})
		var ever: Dictionary = _moved_ever.get(key, {})
		if _full:
			# resend what has ever moved; a part that never did is still where the
			# first send (or the guest's own load) put it
			last = last.duplicate()
			for id in ever:
				last.erase(id)
		var part_ids := _ids_of(key)
		var flags := PackedByteArray()
		flags.resize(parts.size())
		var moved := PackedInt32Array()
		var rows := PackedFloat32Array()
		for i in parts.size():
			var part: Variant = parts[i]
			if part == null or not is_instance_valid(part):
				continue
			var node := part as Node3D
			flags[i] = _flags_of(node)
			var xf: Transform3D = node.transform
			var was: Variant = last.get(part_ids[i])
			if was != null and _same(was, xf):
				continue
			if was != null:
				ever[part_ids[i]] = true
			last[part_ids[i]] = xf
			moved.append(part_ids[i])
			# the whole basis, not a rotation and a scale: some parts are
			# skewed and rebuilding them from a quaternion left them crooked
			rows.append_array(PackedFloat32Array([
				xf.origin.x, xf.origin.y, xf.origin.z,
				xf.basis.x.x, xf.basis.x.y, xf.basis.x.z,
				xf.basis.y.x, xf.basis.y.y, xf.basis.y.z,
				xf.basis.z.x, xf.basis.z.y, xf.basis.z.z]))
		_sent[key] = last
		_moved_ever[key] = ever
		var entry := {}
		if moved.size() > 0:
			entry["i"] = moved
			entry["t"] = rows
		if _full or _flags.get(key, PackedByteArray()) != flags:
			_flags[key] = flags
			var fl := PackedInt32Array()
			for i in parts.size():
				fl.append(part_ids[i])
				fl.append(flags[i])
			entry["f"] = fl
		_read_anims(key, n as Node, entry)
		if "_claw_straw" in n:
			var c := _claw_count(n as Node)
			if _full or int(_claw_sent.get(key, -1)) != c:
				_claw_sent[key] = c
				entry["c"] = c
		var fx_ids := PackedInt32Array()
		var fx_vals := PackedFloat32Array()
		_read_fx(key, fx_ids, fx_vals)
		if fx_vals.size() > 0:
			entry["xi"] = fx_ids
			entry["xv"] = fx_vals
		if not entry.is_empty():
			batch[key] = entry
			any_full = any_full or _full
	# each list carries on next tick from where the budget stopped it
	_pose_at = (first + near_done) % maxi(1, n_near) if near_done < n_near else 0
	_due_at = (dfirst + due_done) % maxi(1, due_k.size()) if due_done < due_k.size() else 0
	# from here on _full means: this packet carries a full refresh (reliable)
	_full = any_full
	if batch.is_empty():
		return
	if _log and _full:
		for key in batch:
			var e: Dictionary = batch[key]
			print("[MPMACH] send %s moved=%d flags=%d fx=%d" % [key,
				(e.get("i", PackedInt32Array()) as PackedInt32Array).size(),
				(e.get("f", PackedInt32Array()) as PackedInt32Array).size() / 2,
				(e.get("xv", PackedFloat32Array()) as PackedFloat32Array).size()])
	if mp.over_steam:
		_send_small(batch)
		return
	batch["@t"] = _host_ms()
	var raw := var_to_bytes(batch)
	var packed := raw.compress(FileAccess.COMPRESSION_ZSTD)
	# One machine's full pose is already bigger than a packet. Sent unreliably,
	# losing any fragment lost the whole batch, so big batches and the
	# periodic full refresh go on the reliable channel instead.
	if _full or packed.size() > BIG_PACKET:
		mp._rx_machines_big.rpc(packed, raw.size())
	else:
		mp._rx_machines.rpc(packed, raw.size())


# Over Steam, in small pieces. Every guest crash over Steam came right after a
# big machine update arrived (up to 9 KB in one message), and over a direct
# connection it has never happened, so over Steam no message gets that big:
# each machine's parts, flags and effects are split into pieces a guest can
# apply one by one, and packed into messages of about a kilobyte.
const PIECE_PARTS := 10
const PIECE_PAIRS := 40
const SMALL_PACKET := 900

func _send_small(batch: Dictionary) -> void:
	var pieces: Array = []  # [key, sub entry]
	for key in batch:
		var e: Dictionary = batch[key]
		if e.has("a") or e.has("v") or e.has("c"):
			var av := {}
			for k in ["a", "v", "c"]:
				if e.has(k):
					av[k] = e[k]
			pieces.append([key, av])
		if e.has("f"):
			var f: PackedInt32Array = e["f"]
			for a in range(0, f.size(), PIECE_PAIRS * 2):
				pieces.append([key, {"f": f.slice(a, a + PIECE_PAIRS * 2)}])
		if e.has("xi") and e.has("xv"):
			var xi: PackedInt32Array = e["xi"]
			var xv: PackedFloat32Array = e["xv"]
			for a in range(0, xv.size(), PIECE_PAIRS):
				pieces.append([key, {"xi": xi.slice(a * 2, (a + PIECE_PAIRS) * 2),
					"xv": xv.slice(a, a + PIECE_PAIRS)}])
		if e.has("i") and e.has("t"):
			var ids: PackedInt32Array = e["i"]
			var rows: PackedFloat32Array = e["t"]
			for a in range(0, ids.size(), PIECE_PARTS):
				pieces.append([key, {"i": ids.slice(a, a + PIECE_PARTS),
					"t": rows.slice(a * 12, (a + PIECE_PARTS) * 12)}])
	var out := {}
	for p in pieces:
		var key: String = p[0]
		if out.has(key):
			_send_one(out)
			out = {}
		out[key] = p[1]
		if var_to_bytes(out).size() > SMALL_PACKET * 3:
			# ~3:1 compression on these; keep what is sent near a kilobyte
			_send_one(out)
			out = {}
	if not out.is_empty():
		_send_one(out)


func _send_one(batch: Dictionary) -> void:
	batch["@t"] = _host_ms()
	var raw := var_to_bytes(batch)
	var packed := raw.compress(FileAccess.COMPRESSION_ZSTD)
	# the periodic full refresh has to arrive; the moves in between may drop
	if _full:
		mp._rx_machines_big.rpc(packed, raw.size())
	else:
		mp._rx_machines.rpc(packed, raw.size())


# bit 0: the part is drawn. bit 1: its particles are running.
func _flags_of(n: Node3D) -> int:
	var f := 1 if n.visible else 0
	if n is GPUParticles3D:
		f |= 2 if (n as GPUParticles3D).emitting else 0
	elif n is CPUParticles3D:
		f |= 2 if (n as CPUParticles3D).emitting else 0
	return f


func _same(a: Transform3D, b: Transform3D) -> bool:
	if a.origin.distance_squared_to(b.origin) > MOVE_EPS * MOVE_EPS:
		return false
	return a.basis.x.distance_squared_to(b.basis.x) < ANG_EPS * ANG_EPS \
		and a.basis.y.distance_squared_to(b.basis.y) < ANG_EPS * ANG_EPS \
		and a.basis.z.distance_squared_to(b.basis.z) < ANG_EPS * ANG_EPS


# only_settings: the fast pass (switches, recipes, modes) that runs every
# SETTINGS_TICK so a machine or belt turned on or off shows for everybody at
# once; the full pass (stock, counters) keeps its slower FIELD_TICK.
var _field_keys: Array = []  # the machines the rolling full pass walks this round
var _field_at := 0
var _field_round := 0

const SETTINGS_REACH := 14.0  # metres: the fast settings pass only looks this far

var _slowest_us := 0      # diagnostics: the slowest single field this pass
var _slowest_what := ""

func _send_fields(only_settings := false, keys: Array = []) -> void:
	_slowest_us = 0
	_slowest_what = ""
	_send_fields_inner(only_settings, keys)
	if _slowest_us > 1500 and mp.trace != null:
		mp.trace.note("slow field %s %.1f ms" % [_slowest_what, _slowest_us / 1000.0])


func _send_fields_inner(only_settings := false, keys: Array = []) -> void:
	var batch := {}
	var watchers := _watchers()
	# (1.1.4) the fast settings pass (10 times a second) only needs the
	# machines the host's own farmer can reach: those are the panels a person
	# here can be working. Anything further away (power tags, pole switches)
	# is caught by the rolling full pass within FIELD_TICK.
	var here := Vector3.INF
	if only_settings and mp.world_sync != null:
		var pl: Variant = mp.world_sync.get("player")
		if pl != null and is_instance_valid(pl) and (pl as Node3D).is_inside_tree():
			here = (pl as Node3D).global_position
	for key in (keys if not keys.is_empty() else _nodes.keys()):
		if not _nodes.has(key):
			continue
		var n: Variant = _nodes[key]
		if n == null or not is_instance_valid(n):
			continue
		if only_settings and here != Vector3.INF and (n as Node3D).is_inside_tree() \
		and _pos_of(n as Node3D).distance_squared_to(here) > SETTINGS_REACH * SETTINGS_REACH:
			continue
		var group := String(_group.get(key, ""))
		var names: Array = _settings_of(group) if only_settings else _fields_of(group)
		if names.is_empty():
			continue
		var was: Dictionary = _vals.get(key, {})
		var diff := {}
		var near: bool = only_settings or _near(_pos_of(n as Node3D), watchers)
		# far away they still go out now and then: a stale timer reads as a warning
		if not near and Time.get_ticks_msec() - int(_far_sent.get(key, -FAR_EVERY_MS)) >= FAR_EVERY_MS:
			near = true
			_far_sent[key] = Time.get_ticks_msec()
		for f in names:
			if not near and NEAR_ONLY.has(f):
				continue
			var _tf := Time.get_ticks_usec()
			var v: Variant = _get_field(n as Node, f)
			# nothing that cannot cross the network
			if v == null or v is Object or v is RID or v is Callable:
				continue
			if not was.has(f) or was[f] != v:
				if only_settings and mp.is_host and was.has(f) and mp.trace != null \
				and Time.get_ticks_msec() - int(_guest_edit_at.get(key, -100000)) > 1500:
					mp.trace.act("ev=press m=%s f=%s" % [_mid(String(key)), f])
					mp.trace.bump("presses")
				diff[f] = v
				# a copy, not the machine's own list: a silo's contents change in
				# place, so a kept reference always "matched" and the new numbers
				# were never sent
				was[f] = v.duplicate(true) if (v is Array or v is Dictionary) else v
			var _df := Time.get_ticks_usec() - _tf
			if _df > _slowest_us:
				_slowest_us = _df
				_slowest_what = "%s.%s" % [key, f]
		_vals[key] = was
		if not diff.is_empty():
			batch[key] = diff
	if batch.is_empty():
		return
	mp._rx_machine_fields.rpc(batch)


# ------------------------------------------------------------------ from the net

func on_poses(packed: PackedByteArray, raw_size: int) -> void:
	if raw_size <= 0 or raw_size > MAX_RAW:
		return
	var batch: Variant = bytes_to_var(packed.decompress(raw_size, FileAccess.COMPRESSION_ZSTD))
	if not (batch is Dictionary):
		return
	# (1.2.0) applied a little at a time in _drain_poses, not here: one full
	# refresh near a busy factory took up to 230 ms in one frame on a guest
	var t := -1.0
	if batch.has("@t"):
		t = float(batch["@t"])
		var off := _host_ms() - t
		if off < _pose_off:
			_pose_off = off
		else:
			_pose_off += (off - _pose_off) * 0.002
	for host_key in batch:
		if String(host_key) == "@t":
			continue
		_pose_queue.append([host_key, batch[host_key], t])


const DRAIN_BUDGET_US := 3000  # guest: applying poses, per frame
const POSE_BUDGET_US := 6000  # machine animation work per pose tick (10 a second), host and guest; 3000 left busy yards with arms updated 2-3 times a second
const POSE_WALKS := 2          # new part lists built per frame at most
var _pose_queue: Array = []    # guest: [host key, entry] waiting to be applied
var _pose_at := 0              # host: where the budgeted pose pass carries on


func _drain_poses() -> void:
	if _pose_queue.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	var walks := 0
	var n := 0
	while n < _pose_queue.size():
		if Time.get_ticks_usec() - t0 > DRAIN_BUDGET_US:
			break
		var e: Array = _pose_queue[n]
		var key := _local_key(String(e[0]))
		if key != "" and not _parts.has(key):
			if walks >= POSE_WALKS:
				break
			walks += 1
		_apply_pose(e[0], e[1], float(e[2]) if e.size() > 2 else -1.0)
		n += 1
	if n > 0:
		_pose_queue = _pose_queue.slice(n)
	# never let a backlog grow: old animation frames are worth nothing
	if _pose_queue.size() > 400:
		_pose_queue = _pose_queue.slice(_pose_queue.size() - 400)


func _apply_pose(host_key: Variant, entry: Dictionary, t: float = -1.0) -> void:
	var key := _local_key(String(host_key))
	if key == "":
		if _log:
			print("[MPMACH] got %s but no machine of mine matches" % host_key)
		return
	var parts := _parts_of(key)
	if parts.is_empty():
		if _log:
			print("[MPMACH] got %s but walked no parts" % key)
		return
	var slot := _slot_of(key)
	if entry.has("f"):
		var flags: PackedInt32Array = entry["f"]
		var k := 0
		var hit := 0
		var lost := 0
		while k + 1 < flags.size():
			var at: int = int(slot.get(flags[k], -1))
			if at >= 0 and at < parts.size():
				var part: Variant = parts[at]
				if part != null and is_instance_valid(part):
					_set_flags(part as Node3D, flags[k + 1])
					hit += 1
			else:
				lost += 1
			k += 2
		if _log and lost > 0:
			print("[MPMACH] %s flags: %d placed, %d with no part here (I walked %d)" % [
				key, hit, lost, parts.size()])
	if entry.has("xi") and entry.has("xv"):
		on_fx(key, entry["xi"], entry["xv"])
	if entry.has("a"):
		_apply_anims(key, entry["a"])
	if entry.has("v"):
		_apply_vat(key, entry["v"])
	if entry.has("c"):
		_queue_claw(key, t, int(entry["c"]))
	if not entry.has("t") or not entry.has("i"):
		return
	var moved: PackedInt32Array = entry["i"]
	var rows: PackedFloat32Array = entry["t"]
	var want: Dictionary = _goal.get(key, {})
	var owned: Dictionary = _owned.get(key, {}) if _anim_on.has(key) else {}
	for j in moved.size():
		var r := j * 12
		if r + 11 >= rows.size():
			break
		if not slot.has(moved[j]) or owned.has(moved[j]):
			continue
		var to := Transform3D(Basis(
				Vector3(rows[r + 3], rows[r + 4], rows[r + 5]),
				Vector3(rows[r + 6], rows[r + 7], rows[r + 8]),
				Vector3(rows[r + 9], rows[r + 10], rows[r + 11])),
			Vector3(rows[r], rows[r + 1], rows[r + 2]))
		# walk from where the part is now to where it has got to, over the
		# gap between packets. Chasing the newest pose with a fixed pull
		# made every arm and grabber move in steps.
		var at: int = int(slot[moved[j]])
		var from: Transform3D = to
		if at < parts.size() and parts[at] != null and is_instance_valid(parts[at]):
			from = (parts[at] as Node3D).transform
		if t >= 0.0:
			_add_sample(key, moved[j], t, to, from)
			want.erase(moved[j])
			continue
		want[moved[j]] = [from, to, 0.0]
	_goal[key] = want


func _set_flags(n: Node3D, f: int) -> void:
	var on := (f & 1) != 0
	if n.visible != on:
		n.visible = on
	var running := (f & 2) != 0
	if n is GPUParticles3D and (n as GPUParticles3D).emitting != running:
		(n as GPUParticles3D).emitting = running
	elif n is CPUParticles3D and (n as CPUParticles3D).emitting != running:
		(n as CPUParticles3D).emitting = running


# One batch can name hundreds of machines and repainting a gauge takes time, which
# all landed in a single frame: a spike of 10 ms and more on a guest. Now they wait
# here and go in a little per frame, like the poses in _drain_poses.
const FIELD_BUDGET_US := 2000
var _field_queue: Array = []  # guest: [host key, values] not applied yet
var _redraw_due := {}         # guest: machine -> true: its gauges want repainting

func on_fields(batch: Dictionary) -> void:
	for host_key in batch:
		_field_queue.append([String(host_key), batch[host_key]])


func _drain_fields() -> void:
	if _field_queue.is_empty() and _redraw_due.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	var done := 0
	while done < _field_queue.size() and Time.get_ticks_usec() - t0 < FIELD_BUDGET_US:
		var e: Array = _field_queue[done]
		done += 1
		_apply_fields_of(e[0], e[1])
	if done >= _field_queue.size():
		_field_queue.clear()
	elif done > 0:
		_field_queue = _field_queue.slice(done)
	for m in _redraw_due.keys():
		if Time.get_ticks_usec() - t0 >= FIELD_BUDGET_US:
			break
		_redraw_due.erase(m)
		if is_instance_valid(m):
			_redraw(m)
	mp.perf("machines.fields", Time.get_ticks_usec() - t0)


func _apply_fields_of(host_key: String, diff: Dictionary) -> void:
	var key := _local_key(host_key)
	var n: Variant = _nodes.get(key)
	if n == null or not is_instance_valid(n):
		return
	# remember what the host says, so a guest can tell a setting the player
	# just changed from one the host handed down
	var known: Dictionary = _theirs.get(key, {})
	var changed := false
	# we changed this machine a moment ago and the host may not have it
	# yet: a packet already on its way would flip our switch back. Keep
	# ours; the edit tick sees the difference and asks again.
	var fresh := Time.get_ticks_msec() - int(_edit_at.get(key, -100000)) < EDIT_GUARD_MS
	var ours: Dictionary = _edit_sent.get(key, {})
	for f in diff:
		known[String(f)] = diff[f]
		# only an edit of ours the host has not answered yet is protected. Once
		# it says our value back the edit is settled and its word counts again;
		# anything else would send our old value back over a newer change of theirs
		var mine: Variant = ours.get(String(f))
		if mine is Array and (mine as Array).size() == 2 and (mine as Array)[0] != diff[f] \
		and fresh and _settings_of(String(_group.get(key, ""))).has(String(f)):
			continue
		ours.erase(String(f))
		# the 3 s full refresh repeats values we already have: skip those,
		# so signs are not rebuilt and lamps not relit for nothing
		if _get_field(n as Node, String(f)) == diff[f]:
			continue
		_apply_field(n as Node, String(f), diff[f])
		# a timer ticking on is nothing to repaint a machine for
		if not NEAR_ONLY.has(String(f)):
			changed = true
	_theirs[key] = known
	if _is_smelter(n):
		_drive_smelter(n as Node)
	if changed:
		_redraw_due[n] = true
		_after_fields(n as Node)


# The smelter's arms are not parts that move: the shader plays them from a clock per group
# (where it started, from which position, how fast). The game sets those clocks in its work
# tick, which is off on a guest, so the arms stood still whatever the host's smelter did.
# Start the same clocks here. Between updates the shader carries on by itself, so this costs
# nothing per frame, and only a clock that drifted gets set again.
const VAT_LOAD := 0
const VAT_HEAT := 1
const VAT_CAST := 2
const VAT_SLACK := 0.35  # seconds: a little late is not worth a visible jump
const PRESENT_NEAR := 40.0

func _is_smelter(n: Variant) -> bool:
	return n != null and is_instance_valid(n) and (n as Node).has_method("cast_metal") and (n as Node).has_method("_set_clock")


func _drive_smelter(n: Node) -> void:
	_drive_clock(n, VAT_LOAD, float(n.get("_load_clock")), float(n.get("_load_rate")))
	_drive_clock(n, VAT_HEAT, float(n.get("_heat_clock")), float(n.get("_heat_rate")))
	# copper and iron share one long clip: iron's part starts further along
	var metal := str(n.get("_casting_metal"))
	var at := -1.0
	if metal != "":
		at = float(n.get("_pour_clock"))
		if metal == "iron":
			at += _iron_starts_at(n)
	_drive_clock(n, VAT_CAST, at, float(n.get("_cast_rate")))


var _iron_at := -1.0

func _iron_starts_at(n: Node) -> float:
	if _iron_at < 0.0:
		var s: Variant = n.get_script()
		var known: Dictionary = (s as Script).get_script_constant_map() if s is Script else {}
		_iron_at = float(known.get("TIMELINE_IRON_AT", 0.0))
	return _iron_at


func _drive_clock(n: Node, group: int, at: float, rate: float) -> void:
	var clocks: Variant = n.get("_clocks")
	if not (clocks is Array) or group >= (clocks as Array).size():
		return
	var ran := float(((clocks as Array)[group] as Vector3).z)
	if at < 0.0:
		if ran != 0.0:
			n.call("_set_clock", group, 0.0, 0.0)
		return
	if absf(ran - rate) > 0.01 or absf(float(n.call("clock_position", group)) - at) > VAT_SLACK:
		n.call("_set_clock", group, at, rate)


# What the machine's own tick would have moved on since the last word from the host, so the
# pour and the furnace do not go in steps, and the machine's own drawing code for what it
# shows: the pot, the stream, the ingot. Only near this player.
func _present_smelters(delta: float) -> void:
	var pl: Variant = mp.world_sync.get("player") if mp.world_sync != null else null
	if pl == null or not is_instance_valid(pl) or not (pl as Node3D).is_inside_tree():
		return
	var here: Vector3 = (pl as Node3D).global_position
	var list: Variant = builds.get("pelletizers") if builds != null and is_instance_valid(builds) else null
	if not (list is Array):
		return
	for n in list:
		if not _is_smelter(n) or not (n as Node3D).is_inside_tree():
			continue
		if here.distance_squared_to((n as Node3D).global_position) > PRESENT_NEAR * PRESENT_NEAR:
			continue
		var t0: float = float(n.get("_load_clock"))
		if t0 >= 0.0:
			n.set("_load_clock", t0 + delta * float(n.get("_load_rate")))
		var t1: float = float(n.get("_heat_clock"))
		if t1 >= 0.0:
			n.set("_heat_clock", t1 + delta * float(n.get("_heat_rate")))
		if str(n.get("_casting_metal")) != "":
			n.set("_pour_clock", float(n.get("_pour_clock")) + delta * float(n.get("_cast_rate")))
		n.call("present", delta, true)


# A guest's machine is frozen, so it never runs the code that repaints its
# gauges, readout, heap and lamps from what it holds: the silo showed its own
# old numbers while the host's tank held something else. Repaint after every
# update. Only drawing methods, and only the ones the machine has.
const REDRAW := ["_apply_dials", "_apply_heap", "_apply_readout", "_apply_lamps",
	"_apply_spin", "_draw_spin", "_apply_meter", "_apply_gauge", "_apply_lamp",
	"_refresh_screen", "_apply_cannon", "_sync_counts", "_sync_mould"]

func _redraw(n: Node) -> void:
	if mp.is_host or n == null or not is_instance_valid(n):
		return
	for m in REDRAW:
		if n.has_method(m) and n.get_method_argument_count(m) == 0:
			n.call(m)


# Guest: anything in SETTINGS that no longer matches what the host last told us
# is something the player just did on a panel. Send it and remember it as the
# new agreed value, so a switch does not go out again every tick while we wait
# for the host to echo it back.
func _send_edits() -> void:
	if _theirs.is_empty():
		return
	var batch := {}
	for key in _edit_turn():
		var names: Array = _settings_of(String(_group.get(key, "")))
		if names.is_empty():
			continue
		var n: Variant = _nodes.get(key)
		if n == null or not is_instance_valid(n):
			continue
		# nothing from the host yet: we have no idea what it thinks, so a
		# difference here would be our own ignorance, not the player's doing
		var known: Dictionary = _theirs.get(key, {})
		if known.is_empty():
			continue
		var diff := {}
		var now := Time.get_ticks_msec()
		var sent: Dictionary = _edit_sent.get(key, {})
		var fresh_value := false
		for f in names:
			if not known.has(f):
				continue
			# a work lamp keeps its switch in _off itself, the other lights do not
			var v: Variant = (n as Node).get("switched_off") if f == "_off" and "switched_off" in n else _get_field(n as Node, f)
			if v == null or v == known[f]:
				continue
			# a jam only ever goes this way when we cleared one by hand; any
			# other difference (meter, decay) is the host's to decide
			if f == "_jam" and not (v is Dictionary and known[f] is Dictionary \
			and bool((known[f] as Dictionary).get("jammed", false)) \
			and not bool((v as Dictionary).get("jammed", false))):
				continue
			# the same value went out a moment ago and the host has not taken
			# it: do not ask again 20 times a second (that loop flooded the
			# connection); after EDIT_RESEND_MS ask once more, and once the
			# guard runs out the host's value wins
			var last: Variant = sent.get(f)
			var repeat: bool = last is Array and (last as Array).size() == 2 and (last as Array)[0] == v
			if repeat and now - int((last as Array)[1]) < EDIT_RESEND_MS:
				continue
			if not repeat:
				fresh_value = true
			sent[f] = [v.duplicate(true) if (v is Array or v is Dictionary) else v, now]
			diff[f] = v
			known[f] = v.duplicate(true) if (v is Array or v is Dictionary) else v
		_edit_sent[key] = sent
		if not diff.is_empty():
			batch[key] = diff
			# only a new value restarts the guard: a repeat of one the host
			# refused must let the host's value win once the guard runs out
			if fresh_value:
				_edit_at[key] = now
	if batch.is_empty():
		return
	mp._rx_machine_edit.rpc_id(1, batch)
	_press_marks(batch, "")
	if _log:
		print("[MPMACH] guest sent %d machine edits" % batch.size())


# (1.2.19) Guest: the rake panel's Back/Forward call drive() on our stopped copy, which only
# sets _drive_left (the stepping runs in its _process, off here): the rake never moved and
# the buttons stayed locked. Hand each press to the host and clear ours, so the buttons free
# up; the host's rake drives, and the yard's change brings it here at its new spot.
func _send_drives() -> void:
	var batch := {}
	for key in _nodes:
		if String(_group.get(key, "")) != "piston_rakes":
			continue
		var n: Variant = _nodes[key]
		if n == null or not is_instance_valid(n) or not ("_drive_left" in n):
			continue
		var left := float(n.get("_drive_left"))
		if left == 0.0:
			continue
		n.set("_drive_left", 0.0)
		batch[key] = {"_drive": signf(left)}
	if not batch.is_empty():
		mp._rx_machine_edit.rpc_id(1, batch)
		_press_marks(batch, "")


# (log v2) "act ev=press m=splitters/1a2b3c f=forced_side": a machine button or switch a
# player used, a few a minute, to line a report up with the moment. by=guest on the host
# for one a guest pressed.
var _guest_edit_at := {}   # host: machine key -> msec a guest's edit was applied

func _mid(key: String) -> String:
	return "%s/%06x" % [String(_group.get(key, "?")), key.hash() & 0xffffff]


func _press_marks(batch: Dictionary, by: String) -> void:
	if mp == null or mp.trace == null:
		return
	for key in batch:
		var fs: Variant = batch[key]
		if not (fs is Dictionary):
			continue
		var k := _local_key(String(key)) if by != "" else String(key)
		for f in fs:
			mp.trace.act("ev=press m=%s f=%s%s" % [_mid(k if k != "" else String(key)), f, by])
			mp.trace.bump("presses")


# Every machine, 20 times a second, was over 2 ms a time on a guest. A player changes
# what is in reach, or whatever a panel shows: with the mouse free every machine is
# looked at, otherwise the ones around us each tick and the rest in turn.
const EDIT_NEAR := 14.0
const EDIT_NEAR_EVERY := 0.5
const EDIT_ALL_EVERY := 2.0
var _edit_near: Array = []
var _edit_near_t := 0.0
var _edit_all: Array = []
var _edit_i := 0

func _edit_turn() -> Array:
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return _nodes.keys()
	return _edit_turn_near()


func _edit_turn_near() -> Array:
	_edit_near_t += EDIT_TICK
	if _edit_near_t >= EDIT_NEAR_EVERY or _edit_all.size() != _nodes.size():
		_edit_near_t = 0.0
		_edit_all = _nodes.keys()
		_edit_near = []
		var ws: Node = mp.world_sync
		var pl: Variant = ws.player if ws != null and is_instance_valid(ws) else null
		if pl != null and is_instance_valid(pl) and (pl as Node3D).is_inside_tree():
			var here: Vector3 = (pl as Node3D).global_position
			for key in _edit_all:
				var n: Variant = _nodes[key]
				if n != null and is_instance_valid(n) and n is Node3D and (n as Node3D).is_inside_tree() \
				and here.distance_squared_to((n as Node3D).global_position) < EDIT_NEAR * EDIT_NEAR:
					_edit_near.append(key)
	var turn: Array = _edit_near.duplicate()
	var total := _edit_all.size()
	if total > 0:
		var step := mini(total, ceili(float(total) * EDIT_TICK / EDIT_ALL_EVERY))
		for i in step:
			turn.append(_edit_all[(_edit_i + i) % total])
		_edit_i = (_edit_i + step) % total
	return turn


# Host: hand the machines whatever a guest has put in their mouths. A copy
# somebody else owns is frozen, and a machine skips a frozen body that is not
# riding a belt, so a guest could load a generator all day and nothing burned.
# Taking the item over here lets the machine's own code do the rest.
func _feed_mouths() -> void:
	var props: Node = mp.world_sync.props_sync if mp.world_sync != null else null
	if props == null or not is_instance_valid(props):
		return
	# loose straw thrown in by a guest, not only their items
	var straws: Node = mp.world_sync.strands_sync
	var watchers := _watchers()
	if watchers.is_empty():
		return
	for key in _nodes:
		var n: Variant = _nodes[key]
		if n == null or not is_instance_valid(n) or not (n as Node3D).is_inside_tree():
			continue
		if not _near((n as Node3D).global_position, watchers):
			continue
		for mouth in MOUTHS:
			var a: Variant = (n as Node).get(mouth)
			if not (a is Area3D) or not (a as Area3D).is_inside_tree():
				continue
			for body in (a as Area3D).get_overlapping_bodies():
				if not props.host_take(body) and straws != null and is_instance_valid(straws):
					straws.host_take(body)


# Host: a guest worked a panel. The machine is ours to run, so apply it here and
# the next field tick hands it to everyone, the guest who asked included.
func on_edit(from: int, batch: Dictionary) -> void:
	if not mp.is_host or not mp.players.has(from):
		return
	_press_marks(batch, " by=guest")
	for guest_key in batch:
		var key := _local_key(String(guest_key))
		var n: Variant = _nodes.get(key)
		if n == null or not is_instance_valid(n):
			continue
		var names: Array = _settings_of(String(_group.get(key, "")))
		var diff: Dictionary = batch[guest_key]
		var was: Dictionary = _vals.get(key, {})
		_guest_edit_at[key] = Time.get_ticks_msec()
		for f in diff:
			# only ever the settings: a guest does not get to set our stock
			if names.has(String(f)):
				_apply_field(n as Node, String(f), diff[f])
			# forget what we last sent for it either way, so the next field
			# tick states our value again: that is what puts a guest back in
			# line when we would not take the change
			was.erase(String(f))
		_vals[key] = was
		_after_fields(n as Node)
	# answer straight away instead of on the next tick: the guest who flipped
	# the switch, and everyone else, see it within one round trip
	_settings_t = SETTINGS_TICK


# ---------------------------------------------------------------- jams
# Machines that can choke on scrap keep it in a ScrapJam object (scrap_jam:
# meter, jammed, the stuck piece). It travels as the made-up field "_jam".
# The host's copy is the real one: guests get it and light the game's own jam
# glow; a guest who clears a jam by hand sends the cleared state back, so the
# host's machine is unjammed too.
const JAM_GLOW_PATH := "res://scripts/build/jam_glow.gd"
var _jam_glow: Object = null
var _jam_glow_tried := false


# Times that run all the time: a little rounding, or they would go out on every
# pass. The warnings that read them only care about seconds.
const COARSE := {"starved_for": 0.5, "blocked_for": 0.5, "arriving": 0.5, "full_wait": 0.5, "behind": 0.1}

# What only a panel or a lamp right in front of a player shows, and that changes
# all the time: not worth sending twice a second for a machine nobody is standing
# near. It goes out on the next pass after someone comes close.
const FAR_EVERY_MS := 3000
var _far_sent := {}  # machine key -> when it last went out in full while far away
const NEAR_ONLY := {"_t": true, "_press": true, "_grind": true, "_wrap": true, "_cycle": true,
	"_bed": true, "_stage": true, "_out_left": true,
	"_out_strands": true, "_cycle_left": true, "_emit_left": true, "_loads": true,
	"_loads_total": true, "_outgoing": true, "behind": true, "arriving": true, "full_wait": true,
	"starved_for": true, "blocked_for": true, "_clock": true, "_left_at": true,
	"furnace_heat": true, "_holding": true, "_stuck": true,
	"_load_clock": true, "_heat_clock": true, "_pour_clock": true, "_gripped": true, "_released": true,
	"_held_out": true, "activity": true, "_handoff_at": true, "_cast_length": true}


# A field's value as it goes over the wire: "_jam" is the ScrapJam as a dict.
# (1.1.4) A silo's "queued" holds every wad inside it, often thousands of
# identical entries. Comparing, copying and sending that list was the
# slowest field (1.5-2 ms each time) and the biggest message. It travels as
# runs instead: [[entry, how many], ...], unpacked again on arrival.
func _rle(q: Array) -> Array:
	var out: Array = []
	var prev: Variant = null
	var count := 0
	for e in q:
		if count > 0 and e == prev:
			count += 1
		else:
			if count > 0:
				out.append([prev, count])
			prev = e
			count = 1
	if count > 0:
		out.append([prev, count])
	return out


func _unrle(runs: Array) -> Array:
	var out: Array = []
	for r in runs:
		if r is Array and (r as Array).size() == 2:
			for i in clampi(int(r[1]), 0, 100000):
				out.append((r[0] as Dictionary).duplicate(true) if r[0] is Dictionary else r[0])
	return out


func _get_field(n: Node, f: String) -> Variant:
	if f == "_net_sat":
		if not mp.is_host:
			return n.get_meta("mp_net_sat") if n.has_meta("mp_net_sat") else null
		var grid: Variant = builds.get("grid") if builds != null else null
		if grid == null:
			return null
		return snappedf(float((grid.call("report", n) as Dictionary).get("satisfaction", 1.0)), 0.01)
	if COARSE.has(f):
		var v: Variant = n.get(f)
		return snappedf(float(v), float(COARSE[f])) if v != null else null
	if f == "_marks":
		if not n.has_method("marks"):
			return null
		var marked: Array = []
		for m in n.call("marks"):
			marked.append(int((m as Dictionary).get("index", -1)))
		marked.sort()
		return marked
	if f == "queued":
		var q: Variant = n.get("queued")
		if q is Array and (q as Array).size() > 16:
			return {"rle": _rle(q)}
		return q
	if f == "_p":
		if not n.has_method("apply_params") or not n.has_method("to_dict"):
			return null
		var d: Variant = n.call("to_dict")
		return (d as Dictionary).get("p") if d is Dictionary else null
	if f == "_stowed":
		return n.call("stowed_records") if n.has_method("stowed_records") else null
	if f == "_drive":
		return null   # an action, never a value to compare (see _send_drives)
	if f == "_jam":
		var sj: Variant = n.get("scrap_jam")
		if sj is Object and (sj as Object).has_method("to_dict"):
			return (sj as Object).call("to_dict")
		return null
	return n.get(f)


func _apply_wires(n: Node, f: String, v: Variant) -> void:
	if not (v is Array) or builds == null or not is_instance_valid(builds):
		return
	var cuts: bool = f == "cuts_at"
	var was: Array = (n.get(f) as Array).duplicate()
	for at in v:
		if not was.has(at):
			var other := _pole_at(at)
			if other != null:
				builds.call("cut_poles" if cuts else "join_poles", n, other)
	for at in was:
		if not (v as Array).has(at):
			var other := _pole_at(at)
			if other != null:
				builds.call("join_poles" if cuts else "cut_poles", n, other)
	# word for word the host's, or a guest would take the difference for an edit
	(n.get(f) as Array).assign(v)


func _pole_at(at: Variant) -> Node:
	var grid: Variant = builds.get("grid")
	var poles: Variant = grid.call("_poles") if grid != null and grid.has_method("_poles") else builds.get("power_poles")
	if not (poles is Array) or not (at is Vector3):
		return null
	var best: Node = null
	var best_d := 0.05
	for p in poles:
		if is_instance_valid(p):
			var d: float = (p as Node3D).global_position.distance_to(at)
			if d < best_d:
				best_d = d
				best = p
	return best


# The needles a radar marked, by index. The marks themselves are made and timed
# here, the way the radar does it, since a guest's radar is stopped.
func _apply_marks(n: Node, v: Variant) -> void:
	if not (v is Array) or not n.has_method("_add_mark"):
		return
	var have := {}
	for m in n.call("marks"):
		have[int((m as Dictionary).get("index", -1))] = true
	if (v as Array).is_empty():
		if not have.is_empty():
			n.call("clear_marks")
		return
	var data: Variant = n.call("tier_data")
	for index in v:
		if not have.has(int(index)):
			n.call("_add_mark", int(index), data, n.call("_body_of", int(index)))


# A guest's power grid runs on the guest. It divides what the generators make by
# what its machines draw, and what they made used to be the host's number. Any
# difference in the demand, a clock, a cable, a machine that had just switched,
# then read as a shortage: "too little power" with plenty of generators. Now they
# make what the guest's own line asks for, times how well the host's line is fed,
# so a guest is short exactly when the host is.
const POWER_TICK := 0.2
var _power_t := 0.0

func _feed_generators(delta: float) -> void:
	_power_t += delta
	if _power_t < POWER_TICK or builds == null or not is_instance_valid(builds):
		return
	_power_t = 0.0
	var grid: Variant = builds.get("grid")
	if grid == null:
		return
	for g in grid.call("machines"):
		if not is_instance_valid(g) or not g.has_method("deliverable_kw") or not ("made_kw" in g):
			continue
		var report: Dictionary = grid.call("report", g)
		var could := float(report.get("could", 0.0))
		var able := float(g.call("deliverable_kw"))
		if could <= 0.0 or able <= 0.0:
			g.set("made_kw", 0.0)
			continue
		var fed := float(report.get("demand", 0.0)) * float(g.get_meta("mp_net_sat", 1.0))
		g.set("made_kw", minf(able, fed * able / could))


func _tick_radar_marks(delta: float) -> void:
	if builds == null or not is_instance_valid(builds):
		return
	var radars: Variant = builds.get("needle_radars")
	if radars is Array:
		for n in radars:
			if is_instance_valid(n) and n.has_method("_tick_marks") and not (n.call("marks") as Array).is_empty():
				n.call("_tick_marks", delta)


func _apply_jam(n: Node, v: Variant) -> void:
	var sj: Variant = n.get("scrap_jam")
	if not (v is Dictionary) or not (sj is Object) or not (sj as Object).has_method("from_dict"):
		return
	if mp.is_host:
		# from a guest: only ever take a clear, never a new jam (that is the
		# host's machine to decide)
		if bool((v as Dictionary).get("jammed", false)) or not bool((sj as Object).get("jammed")):
			return
	(sj as Object).call("from_dict", v)
	if mp.is_host:
		return
	# the guest's machine is frozen, so it never lights its own glow
	if not _jam_glow_tried:
		_jam_glow_tried = true
		if ResourceLoader.exists(JAM_GLOW_PATH):
			var s: Script = load(JAM_GLOW_PATH)
			if s != null and s.can_instantiate():
				_jam_glow = s.new()
	if _jam_glow == null:
		return
	if bool((sj as Object).get("jammed")):
		var icon: Variant = (sj as Object).call("icon") if (sj as Object).has_method("icon") else null
		_jam_glow.call("light", n, icon)
	elif bool(_jam_glow.call("is_lit", n)):
		_jam_glow.call("put_out", n)


# Go through the machine's own setter when it has one: several of them repaint
# lamps or dials from there.
func _apply_field(n: Node, f: String, v: Variant) -> void:
	if f == "_jam":
		_apply_jam(n, v)
		return
	if f == "_stowed":
		# the list itself, not restore_stowed(): a depot drone's version hands what it held
		# back to the depot (GameState.depot_give) and empties the pod, which on a guest is
		# stock made twice once it reaches the host
		var cur_s: Variant = n.get("_stowed")
		if v is Array and cur_s is Array:
			(cur_s as Array).assign(v)
			n.set("_lamps_lit", -1)
			if n.has_method("_show_fill"):
				n.call("_show_fill")
		return
	if f == "_drive":
		# host: a guest pressed Back/Forward on its stopped copy. Drive ours, checked by our
		# own build tool like a press here; the yard's change then carries it to everyone.
		if mp.is_host and n.has_method("drive") and float(v) != 0.0:
			var check := Callable()
			var pl: Variant = world.get("player") if world != null and is_instance_valid(world) else null
			var bt: Variant = pl.get("build") if pl != null and is_instance_valid(pl) else null
			if bt != null and is_instance_valid(bt) and bt.has_method("rake_drive_reason"):
				check = Callable(bt, "rake_drive_reason")
			n.call("drive", signf(float(v)), check)
		return
	if f == "queued" and v is Dictionary and (v as Dictionary).has("rle"):
		v = _unrle((v as Dictionary)["rle"])
	if f == "_p":
		if v is Dictionary and n.has_method("apply_params"):
			n.call("apply_params", v)
			if n.has_method("rebuild"):
				n.call("rebuild")
		return
	# set_cannon_yaw(degrees, snap) turns the tube; the plain variable alone does not
	if f == "cannon_yaw" and n.has_method("set_cannon_yaw"):
		n.call("set_cannon_yaw", float(v))
		return
	# These change the model through a function of another name; the plain variable
	# alone leaves the old look. Only on a real change: set_tier rebuilds parts.
	if f == "tier_index" and n.has_method("set_tier"):
		if int(n.get(f)) != int(v):
			n.call("set_tier", int(v))
		return
	if f == "closed_lane" and n.has_method("set_closed"):
		if int(n.get(f)) != int(v):
			n.call("set_closed", int(v))
			# it can refuse a lane; the host's value still has to hold on both sides
			if int(n.get(f)) != int(v):
				n.set(f, v)
		return
	# the ring, route and arm follow these only through their setter (two values)
	if (f == "zone_at" or f == "zone_r" or f == "zone_radius") and n.has_method("set_zone") \
	and n.get_method_argument_count("set_zone") == 2:
		n.set(f, v)
		n.call("set_zone", n.get("zone_at"), n.get("zone_r") if "zone_r" in n else n.get("zone_radius"))
		return
	if (f == "drop_at" or f == "drop_kind") and n.has_method("set_drop") \
	and n.get_method_argument_count("set_drop") == 2:
		n.set(f, v)
		n.call("set_drop", n.get("drop_at"), n.get("drop_kind"))
		return
	if f == "_net_sat":
		n.set_meta("mp_net_sat", float(v))
		return
	# Cables strung or cut by hand. The lists alone do nothing: the game keeps the
	# real links elsewhere and works them out when it strings or cuts one.
	if (f == "links_at" or f == "cuts_at") and n is PowerPole:
		_apply_wires(n, f, v)
		return
	# its launch strength: set_power is what the power grid feeds it through
	if f == "power" and n is TubeLauncher:
		n.set(f, v)
		return
	# A guest pressed the radar's button on its stopped copy. Nothing runs there,
	# so it is the host's radar that goes off.
	if f == "phase" and n is NeedleRadar and mp.is_host:
		if int(v) != 0 and not bool(n.call("is_busy")):
			n.call("activate")
		return
	if f == "_marks" and n is NeedleRadar:
		_apply_marks(n, v)
		return
	var setter := "set_switched_off" if f == "_off" else "set_" + f
	# only a setter that takes just the value: set_shut(on, ...) or
	# set_sensor(auto, on, off, dark) want more, so those are set directly and
	# the fitting is repainted in _after_fields
	if n.has_method(setter) and n.get_method_argument_count(setter) == 1:
		n.call(setter, v)
		return
	var cur: Variant = n.get(f)
	if cur is Array and v is Array:
		# fill it in place: a typed array (Array[Dictionary] and the like)
		# refuses a plain one handed to set(), and the machine kept its old list
		(cur as Array).assign(v)
	elif cur is Dictionary and v is Dictionary:
		(cur as Dictionary).clear()
		(cur as Dictionary).merge(v)
	else:
		n.set(f, v)


# Parts ease towards the last pose we heard about, so ten packets a second
# still read as movement rather than stepping.
func _ease(delta: float) -> void:
	_play_samples()
	_play_claws()
	if _goal.is_empty():
		return
	var step_t := delta / TICK
	for key in _goal:
		var parts := _parts_of(key)
		var slot := _slot_of(key)
		var want: Dictionary = _goal[key]
		var done: Array = []
		for part_id in want:
			var idx: int = int(slot.get(part_id, -1))
			if idx < 0 or idx >= parts.size():
				done.append(part_id)
				continue
			var part: Variant = parts[idx]
			if part == null or not is_instance_valid(part):
				done.append(part_id)
				continue
			var walk: Array = want[part_id]
			var from: Transform3D = walk[0]
			var to: Transform3D = walk[1]
			var t: float = minf(1.0, float(walk[2]) + step_t)
			walk[2] = t
			# axis by axis: interpolate_with would pull a skewed part through a
			# rotation it never had
			(part as Node3D).transform = Transform3D(Basis(
					from.basis.x.lerp(to.basis.x, t),
					from.basis.y.lerp(to.basis.y, t),
					from.basis.z.lerp(to.basis.z, t)),
				from.origin.lerp(to.origin, t))
			if t >= 1.0:
				done.append(part_id)
		for gone in done:
			want.erase(gone)


# A client just arrived: forget what we think it knows, so the next ticks
# send every pose, flag and setting again.
func send_all(_pid: int) -> void:
	_rescan()
	_sent.clear()
	_flags.clear()
	_vals.clear()


# ------------------------------------------------------------------ glow

# Smoke columns, fire glow and dials are driven by a shader value or a light's
# strength, not by a node moving, so a frozen machine looks cold without them.
# Work out once per part what it has, then send only what changed.
func _fx_of(key: String) -> Array:
	if _fx.has(key):
		return _fx[key]
	var out: Array = []
	for part in _parts_of(key):
		# the game frees some parts of its own (markers, rings) while it runs
		if part == null or not is_instance_valid(part):
			out.append(null)
			continue
		var node := part as Node3D
		var entry: Dictionary = {}
		if node is Light3D:
			entry["light"] = node
		var mat: Variant = _shader_of(node)
		if mat != null and (mat as ShaderMaterial).shader != null:
			var names := _float_uniforms((mat as ShaderMaterial).shader)
			if names.size() > 0:
				entry["mat"] = mat
				entry["names"] = names
		out.append(entry if not entry.is_empty() else null)
	_fx[key] = out
	return out


# A shader's float values, asked once per shader. Asking the engine
# (get_shader_uniform_list) costs a lot, and every machine of a kind shares its
# shaders: re-reading a machine's parts every few seconds asked it again for each
# part, up to 7 ms per machine on a fast PC and 20-39 ms frames on a laptop.
var _uniforms := {}  # Shader instance id -> PackedStringArray

func _float_uniforms(shader: Shader) -> PackedStringArray:
	var id := shader.get_instance_id()
	if _uniforms.has(id):
		return _uniforms[id]
	var names := PackedStringArray()
	for u in shader.get_shader_uniform_list():
		if int(u.get("type", -1)) == TYPE_FLOAT:
			names.append(String(u.get("name", "")))
	_uniforms[id] = names
	return names


func _shader_of(n: Node3D) -> Variant:
	if not (n is GeometryInstance3D):
		return null
	var g := n as GeometryInstance3D
	if g.material_override is ShaderMaterial:
		# the build hologram, while a machine is being put up: it belongs to
		# BuildFx, which hands the real material back when it is done
		if _is_build_glow(g.material_override):
			return null
		return g.material_override
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		if mi.get_surface_override_material_count() > 0 \
		and mi.get_surface_override_material(0) is ShaderMaterial:
			return mi.get_surface_override_material(0)
		if mi.mesh != null and mi.mesh.get_surface_count() > 0 \
		and mi.mesh.surface_get_material(0) is ShaderMaterial:
			return mi.mesh.surface_get_material(0)
	return null


# While a machine is being put up, BuildFx swaps every mesh's material for its
# green hologram and puts the real one back when it is done, but only on a
# mesh still wearing that hologram. We used to copy it as the part's "own"
# material, so the game never gave the real one back and the machine stayed a
# half-built hologram for good.
func _is_build_glow(mat: Variant) -> bool:
	return mat is ShaderMaterial and BuildFx._shader != null \
		and (mat as ShaderMaterial).shader == BuildFx._shader


# -1 as the slot means the light's strength, 0 and up are shader values.
# (1.2.18) This ran over every value of every part ten times a second and cost a
# host 3-4 ms each time with only 8-30 machines: most parts share a few
# materials, which were asked the same values again for each part, and each
# value was looked up under a freshly formatted string. Now each material is
# read once per pass, and a part whose material says exactly what it said the
# last time this part was looked at has nothing new to send and is skipped.
# Same values go out as before.
func _read_fx(key: String, ids: PackedInt32Array, vals: PackedFloat32Array) -> void:
	var fx := _fx_of(key)
	var part_ids := _ids_of(key)
	var was: Dictionary = _fx_sent.get(key, {})
	var seen: Dictionary = _fx_seen.get(key, {})
	if _full:
		was = {}
	for i in fx.size():
		var entry: Variant = fx[i]
		if entry == null:
			continue
		var d: Dictionary = entry
		var pid: int = part_ids[i]
		if d.has("light"):
			var light: Variant = d["light"]
			if is_instance_valid(light):
				_note_fx(pid, -1, (light as Light3D).light_energy, was, ids, vals)
		if not d.has("mat"):
			continue
		var mat: Variant = d["mat"]
		if not is_instance_valid(mat):
			continue
		var now := _mat_values(mat as ShaderMaterial, d["names"])
		var before: Variant = seen.get(pid)
		if not _full and before is PackedFloat32Array and before == now:
			continue
		seen[pid] = now
		for j in now.size():
			if not is_inf(now[j]):
				_note_fx(pid, j, now[j], was, ids, vals)
	_fx_sent[key] = was
	_fx_seen[key] = seen


# A material's float values, read once per pose pass (_send_poses empties this).
# INF stands for a value the material does not have.
var _mat_vals := {}  # material instance id -> PackedFloat32Array

func _mat_values(mat: ShaderMaterial, names: PackedStringArray) -> PackedFloat32Array:
	var id := mat.get_instance_id()
	var got: Variant = _mat_vals.get(id)
	# a part walked before its material's shader changed can hold another list
	if got != null and (got as PackedFloat32Array).size() == names.size():
		return got
	var out := PackedFloat32Array()
	out.resize(names.size())
	for j in names.size():
		var v: Variant = mat.get_shader_parameter(names[j])
		out[j] = INF if v == null else float(v)
	if got == null:
		_mat_vals[id] = out
	return out


func _note_fx(part_id: int, slot: int, v: float, was: Dictionary,
		ids: PackedInt32Array, vals: PackedFloat32Array) -> void:
	var at := (part_id << 16) | (slot + 1)
	var old: Variant = was.get(at)
	if old != null and absf(float(old) - v) < 0.004:
		return
	was[at] = v
	ids.append(part_id)
	ids.append(slot)
	vals.append(v)


func on_fx(key: String, ids: PackedInt32Array, vals: PackedFloat32Array) -> void:
	var fx := _fx_of(key)
	var slot := _slot_of(key)
	var k := 0
	while k + 1 < ids.size() and k / 2 < vals.size():
		var at: int = int(slot.get(ids[k], -1))
		var which: int = ids[k + 1]
		var v: float = vals[k / 2]
		k += 2
		if at < 0 or at >= fx.size() or fx[at] == null:
			continue
		var d: Dictionary = fx[at]
		if which < 0:
			if d.has("light") and is_instance_valid(d["light"]):
				(d["light"] as Light3D).light_energy = v
			continue
		if not d.has("mat") or not is_instance_valid(d["mat"]):
			continue
		var names: PackedStringArray = d["names"]
		if which < names.size():
			# The full refresh names every value of every part, and most are what the
			# shared material already says. Each of those got its own copy for nothing, and
			# as a player walked through the yard they piled up: 311 materials became
			# thousands, the graphics card ran out of room for them, draws were skipped (the
			# screen flickered) and after two hours the game fell over.
			var cur: Variant = (d["mat"] as ShaderMaterial).get_shader_parameter(names[which])
			if cur != null and absf(float(cur) - v) < FX_SAME:
				continue
			var own := _own_material(key, at, d)
			if own != null:
				own.set_shader_parameter(names[which], v)


# A machine's shader material is often the mesh's own, shared by every copy of
# that machine, so one machine's smoke or glow set here showed on all of them.
# Give the part its own copy the first time we write to it.
const FX_SAME := 0.004      # as in _note_fx: not worth a word
const OWN_MAX := 800        # copies at most: a glow not matching is better than no picture
var _own_count := 0

func _own_material(key: String, at: int, d: Dictionary) -> Variant:
	var mat: ShaderMaterial = d["mat"]
	if mat.has_meta("mp_own") or _is_build_glow(mat):
		return mat
	if _own_count >= OWN_MAX:
		return null
	var parts := _parts_of(key)
	if at < 0 or at >= parts.size() or parts[at] == null or not is_instance_valid(parts[at]) \
	or not (parts[at] is GeometryInstance3D):
		return mat
	var own := mat.duplicate() as ShaderMaterial
	own.set_meta("mp_own", true)
	var g := parts[at] as GeometryInstance3D
	if g.material_override == mat:
		g.material_override = own
	elif g is MeshInstance3D:
		(g as MeshInstance3D).set_surface_override_material(0, own)
	else:
		return mat
	d["mat"] = own
	_own_count += 1
	return own


# Where a part hangs, as a name both sides work out the same way. Nodes the
# game builds in code get a generated name (@GPUParticles3D@27) that counts up
# differently on each machine, so those are placed by what they are and where
# they sit among their siblings instead.
func _part_path(base: Node, n: Node) -> String:
	var bits := PackedStringArray()
	var cur: Node = n
	while cur != null and cur != base:
		bits.append(_part_name(cur))
		cur = cur.get_parent()
	bits.reverse()
	return "/".join(bits)


func _part_name(n: Node) -> String:
	var nm := String(n.name)
	if not nm.begins_with("@"):
		return nm
	var parent := n.get_parent()
	if parent == null:
		return n.get_class()
	var seen := 0
	for child in parent.get_children():
		if child == n:
			break
		if child.get_class() == n.get_class():
			seen += 1
	return "%s#%d" % [n.get_class(), seen]


# ------------------------------------------------------------------ animations

func _players_of(key: String) -> Array:
	if _players.has(key):
		return _players[key]
	var out: Array = []
	var n: Variant = _nodes.get(key)
	if n != null and is_instance_valid(n):
		for p in (n as Node).find_children("*", "AnimationPlayer", true, false):
			out.append(p)
	_players[key] = out
	return out


# [clock var, meshes] of a VAT machine, or [] (the smelter has clocks of its own)
func _clock_of(n: Node) -> Array:
	if _is_smelter(n):
		return []
	for c in CLOCK_VARS:
		if n.get(c) is Vector3:
			for m in VAT_MESH_VARS:
				var arr: Variant = n.get(m)
				if arr is Array and not (arr as Array).is_empty():
					return [c, arr]
	return []


func _vat_now() -> float:
	var rc := get_node_or_null("/root/RenderClock")
	return float(rc.call("now")) if rc != null and rc.has_method("now") else 0.0


# Host: what this machine's players play, as [index, clip, time, speed, ...], and its
# VAT clock as [phase, speed]. Sent when it changes, and now and then anyway.
func _read_anims(key: String, n: Node, entry: Dictionary) -> void:
	var state: Array = []
	var ps := _players_of(key)
	for i in ps.size():
		var ap: Variant = ps[i]
		if not is_instance_valid(ap) or not (ap as AnimationPlayer).active:
			continue
		var a := ap as AnimationPlayer
		var clip := String(a.current_animation)
		if clip == "":
			continue
		# The speed as measured, not as the player states it: some machines hold a
		# "playing" clip and scrub it by hand every frame (the wrapper sits on 0.0
		# while idle), so the stated speed would set a guest's copy running.
		var pos := a.current_animation_position
		var mk := "%s#%d" % [key, i]
		var last: Variant = _anim_seen.get(mk)
		var speed := 0.0
		var t_now := Time.get_ticks_usec()
		if last != null and last[0] == clip:
			var dt := float(t_now - int(last[2])) / 1000000.0
			var dp := pos - float(last[1])
			var length := a.get_animation(clip).length if a.has_animation(clip) else 0.0
			if dp < 0.0 and length > 0.0 and a.get_animation(clip).loop_mode != Animation.LOOP_NONE:
				dp += length
			if dt > 0.02:
				speed = snappedf(clampf(dp / dt, -8.0, 8.0), 0.05)
				# a stated speed it really runs at: take that, it does not jitter
				var stated := a.get_playing_speed() if a.is_playing() else 0.0
				if absf(speed - stated) < 0.15 * maxf(absf(stated), 0.2):
					speed = stated
		_anim_seen[mk] = [clip, pos, t_now]
		state.append_array([i, clip, pos, speed])
	var vat := PackedFloat32Array()
	var ck := _clock_of(n)
	if not ck.is_empty():
		var c: Vector3 = n.get(ck[0])
		vat = PackedFloat32Array([c.y + (_vat_now() - c.x) * c.z, c.z])
	if state.is_empty() and vat.is_empty():
		return
	var now := Time.get_ticks_msec()
	var was: Array = _anim_sent.get(key, [-ANIM_RESEND_MS, [], PackedFloat32Array()])
	var changed: bool = _full or now - int(was[0]) >= ANIM_RESEND_MS
	if not changed:
		# a new clip, a new speed, a stop or a start; the time runs on by itself
		var old: Array = was[1]
		if old.size() != state.size():
			changed = true
		else:
			for j in range(0, state.size(), 4):
				if old[j] != state[j] or old[j + 1] != state[j + 1] \
						or absf(float(old[j + 3]) - float(state[j + 3])) > 0.1 * maxf(absf(float(old[j + 3])), 0.5):
					changed = true
					break
		var ov: PackedFloat32Array = was[2]
		if not changed and vat.size() == 2 and (ov.size() != 2 or absf(ov[1] - vat[1]) > 0.0001):
			changed = true
	if not changed:
		return
	_anim_sent[key] = [now, state, vat]
	if not state.is_empty():
		entry["a"] = state
	if not vat.is_empty():
		entry["v"] = vat


func _one_way() -> float:
	return clampf(float(mp.pings.get(multiplayer.get_unique_id(), 0)) / 2000.0, 0.0, 0.3)


# Guest: play what the host plays, from where it is now; seek only when off.
func _apply_anims(key: String, state: Array) -> void:
	var ps := _players_of(key)
	if ps.is_empty():
		return
	if not _anim_on.has(key):
		_anim_on[key] = true
		_owned[key] = _owned_parts(key, ps)
	var lead := _one_way()
	var told := {}
	for j in range(0, state.size() - 3, 4):
		var i := int(state[j])
		if i < 0 or i >= ps.size() or not is_instance_valid(ps[i]):
			continue
		var a := ps[i] as AnimationPlayer
		var clip := String(state[j + 1])
		if not a.has_animation(clip):
			continue
		told[i] = true
		var speed := float(state[j + 3])
		var at := float(state[j + 2])
		var anim := a.get_animation(clip)
		var length := anim.length
		var looped := anim.loop_mode != Animation.LOOP_NONE
		var want := at + speed * lead
		if looped and length > 0.0:
			want = fposmod(want, length)
		elif length > 0.0:
			want = clampf(want, 0.0, length)
		if not a.active:
			a.active = true
		# the freeze switched it off (mp_world _still_animations); it runs now
		if a.process_mode == Node.PROCESS_MODE_DISABLED:
			a.process_mode = Node.PROCESS_MODE_INHERIT
		if speed == 0.0:
			if a.current_animation != clip:
				a.play(clip)
			a.speed_scale = 1.0
			a.pause()
			if absf(a.current_animation_position - want) > 0.001:
				a.seek(want, true)
			continue
		if a.current_animation != clip or not a.is_playing():
			a.play(clip)
			a.seek(want, true)
		a.speed_scale = speed
		var off := absf(a.current_animation_position - want)
		if looped and length > 0.0:
			off = minf(off, length - off)
		if off > ANIM_DRIFT_S:
			a.seek(want, true)
	# a player the host no longer names has stopped there
	for i in ps.size():
		if not told.has(i) and is_instance_valid(ps[i]) and (ps[i] as AnimationPlayer).is_playing():
			(ps[i] as AnimationPlayer).pause()


# The parts any clip of these players moves: the poses leave them to the clips.
func _owned_parts(key: String, ps: Array) -> Dictionary:
	var by_node := {}
	var parts := _parts_of(key)
	var ids := _ids_of(key)
	for i in mini(parts.size(), ids.size()):
		if is_instance_valid(parts[i]):
			by_node[(parts[i] as Node).get_instance_id()] = ids[i]
	var out := {}
	for p in ps:
		if not is_instance_valid(p):
			continue
		var a := p as AnimationPlayer
		var root: Node = a.get_node_or_null(a.root_node)
		if root == null:
			continue
		for clip in a.get_animation_list():
			var anim: Animation = a.get_animation(clip)
			for t in anim.get_track_count():
				var tt := anim.track_get_type(t)
				if tt != Animation.TYPE_POSITION_3D and tt != Animation.TYPE_ROTATION_3D \
						and tt != Animation.TYPE_SCALE_3D and tt != Animation.TYPE_VALUE:
					continue
				var path := anim.track_get_path(t)
				if tt == Animation.TYPE_VALUE:
					var prop := String(path.get_concatenated_subnames())
					if not (prop.begins_with("position") or prop.begins_with("rotation")
							or prop.begins_with("transform") or prop.begins_with("quaternion")
							or prop.begins_with("scale") or prop.begins_with("basis")):
						continue
				var target := root.get_node_or_null(NodePath(String(path.get_concatenated_names())))
				if target != null and by_node.has(target.get_instance_id()):
					out[by_node[target.get_instance_id()]] = true
	return out


# Guest: the VAT clock where the host's is now, only when it is off.
func _apply_vat(key: String, v: PackedFloat32Array) -> void:
	if v.size() < 2:
		return
	var n: Variant = _nodes.get(key)
	if n == null or not is_instance_valid(n):
		return
	var ck := _clock_of(n as Node)
	if ck.is_empty():
		return
	var now := _vat_now()
	var speed: float = v[1]
	var phase: float = v[0] + speed * _one_way()
	var c: Vector3 = (n as Node).get(ck[0])
	var mine := c.y + (now - c.x) * c.z
	if absf(c.z - speed) < 0.0001 and absf(mine - phase) < VAT_DRIFT:
		return
	var to := Vector3(now, phase, speed)
	(n as Node).set(ck[0], to)
	for m in ck[1]:
		var meshes: Array = m if m is Array else [m]
		for g in meshes:
			if g is GeometryInstance3D and is_instance_valid(g):
				(g as GeometryInstance3D).set_instance_shader_parameter("vat_clock", to)


# ------------------------------------------------------------------ smooth parts (1.2.19)
#
# A guest used to move each part towards the newest pose the moment it came, over one
# tick. Poses come every 0.1 s at best, and late or bunched up as often as not, so parts
# stood still, then hurried: the drones, arms and cranes looked choppy. Now every message
# carries the host's clock, and a guest shows parts SHOW_BEHIND_MS in the past, sliding
# between the two poses around that moment, the way online games show other players.
# The delay is the belts' (mp_belts EV_DELAY_MS), so machines and belts stay together.
# ------------------------------------------------------------------ hay in a robot arm's claw
# The arm draws what it carries as one MultiMesh ("ClawStraw", top level) that it
# makes when it bites and moves to its socket every frame. A guest's arm is frozen,
# so it never bit and its claw stayed empty; the hay only showed up once it lay on
# the belt. The host sends how many straws its claw shows, with the poses (so on the
# pose clock: it shows and goes with the claw, not 200 ms ahead of it), and the
# guest's arm draws the same number with its own code (_show_decoy) and keeps it at
# its socket, which the poses move.
const CLAW_STALE_MS := 5000   # shown and no word for this long (out of range): hide
var _claw_sent := {}   # host: key -> count last sent
var _claw_due := {}    # guest: key -> [[host ms, count], ...] oldest first
var _claw_t := {}      # guest: key -> host ms of the count last shown
var _claw_on := {}     # guest: key -> msec of the last word while shown


func _claw_count(n: Node) -> int:
	var pv: Variant = n.get("_payload_visual")
	if not (pv is MultiMeshInstance3D) or not is_instance_valid(pv) or not (pv as Node3D).visible:
		return 0
	var mm: MultiMesh = (pv as MultiMeshInstance3D).multimesh
	return mm.instance_count if mm != null else 0


func _queue_claw(key: String, t: float, c: int) -> void:
	if _claw_on.has(key):
		_claw_on[key] = Time.get_ticks_msec()
	if t >= 0.0 and t <= float(_claw_t.get(key, -1.0)):
		return  # old news
	var list: Array = _claw_due.get(key, [])
	var at := list.size()
	while at > 0 and t >= 0.0 and float(list[at - 1][0]) > t:
		at -= 1
	list.insert(at, [t, c])
	_claw_due[key] = list


func _play_claws() -> void:
	if _claw_due.is_empty() and _claw_on.is_empty():
		return
	var rt := _host_ms() - _pose_off - SHOW_BEHIND_MS if _pose_off != INF else INF
	for key in _claw_due.keys():
		var list: Array = _claw_due[key]
		var c := -1
		while not list.is_empty() and (float(list[0][0]) < 0.0 or float(list[0][0]) <= rt):
			var e: Array = list.pop_front()
			c = int(e[1])
			if float(e[0]) >= 0.0:
				_claw_t[key] = float(e[0])
		if list.is_empty():
			_claw_due.erase(key)
		if c >= 0:
			_set_claw(key, c)
	var now := Time.get_ticks_msec()
	for key in _claw_on.keys():
		var n: Variant = _nodes.get(key)
		if n == null or not is_instance_valid(n) or now - int(_claw_on[key]) > CLAW_STALE_MS:
			_set_claw(key, 0)
			continue
		var cs: Variant = n.get("_claw_straw")
		var sock: Variant = n.get("_socket")
		if cs is Node3D and is_instance_valid(cs) and sock is Node3D and is_instance_valid(sock) 		and (sock as Node3D).is_inside_tree():
			var sb := (sock as Node3D).global_basis.orthonormalized()
			(cs as Node3D).global_transform = Transform3D(sb, (sock as Node3D).global_position)


func _set_claw(key: String, c: int) -> void:
	var n: Variant = _nodes.get(key)
	if n == null or not is_instance_valid(n):
		_claw_on.erase(key)
		return
	if c > 0 and (n as Node).has_method("_show_decoy"):
		(n as Node).call("_show_decoy", c)
		_claw_on[key] = Time.get_ticks_msec()
	else:
		var cs: Variant = n.get("_claw_straw")
		if cs is Node3D and is_instance_valid(cs):
			(cs as Node3D).visible = false
		if "_payload_visual" in n and n.get("_payload_visual") == cs:
			n.set("_payload_visual", null)
		_claw_on.erase(key)


const SHOW_BEHIND_MS := 200.0
const SAMPLES := 4
const HOLD_GAP_MS := 700.0
var _pose_off := INF        # guest: local ms - host ms of the quickest message lately
var _pbuf := {}             # guest: key -> {part id: [[host ms, Transform3D], ...]}


func _host_ms() -> float:
	return float(Time.get_ticks_usec()) / 1000.0


func _add_sample(key: String, id: int, t: float, to: Transform3D, now_xf: Transform3D) -> void:
	var parts: Dictionary = _pbuf.get(key, {})
	var list: Array = parts.get(id, [])
	if list.is_empty():
		# where it is now, a tick before: it starts from there instead of jumping
		list.append([t - TICK * 1000.0, now_xf])
	else:
		var last: Array = list.back()
		if t <= float(last[0]):
			return  # old news (messages can overtake each other)
		if t - float(last[0]) > HOLD_GAP_MS:
			# it stood still in between: hold it until just before this pose. Not sooner: with
			# many machines near, one machine's poses can come 0.3-0.5 s apart while it moves,
			# and holding it then made it stop and go (robot arms, measured)
			list.append([t - TICK * 1000.0, last[1]])
	list.append([t, to])
	while list.size() > SAMPLES:
		list.pop_front()
	parts[id] = list
	_pbuf[key] = parts


func _play_samples() -> void:
	if _pbuf.is_empty() or _pose_off == INF:
		return
	var rt := _host_ms() - _pose_off - SHOW_BEHIND_MS
	for key in _pbuf.keys():
		var parts := _parts_of(key)
		var slot := _slot_of(key)
		var ids: Dictionary = _pbuf[key]
		for id in ids.keys():
			var idx: int = int(slot.get(id, -1))
			if idx < 0 or idx >= parts.size() or parts[idx] == null or not is_instance_valid(parts[idx]):
				ids.erase(id)
				continue
			var list: Array = ids[id]
			var xf: Transform3D
			if rt <= float(list[0][0]):
				xf = list[0][1]
			elif rt >= float(list.back()[0]):
				xf = list.back()[1]
				if rt - float(list.back()[0]) > 1000.0:
					ids.erase(id)  # settled: nothing to slide any more
			else:
				var k := 1
				while k < list.size() and float(list[k][0]) < rt:
					k += 1
				var a: Array = list[k - 1]
				var b: Array = list[k]
				var f := clampf((rt - float(a[0])) / maxf(float(b[0]) - float(a[0]), 0.001), 0.0, 1.0)
				var x0: Transform3D = a[1]
				var x1: Transform3D = b[1]
				# axis by axis, like _ease: some parts are skewed
				xf = Transform3D(Basis(x0.basis.x.lerp(x1.basis.x, f), x0.basis.y.lerp(x1.basis.y, f),
					x0.basis.z.lerp(x1.basis.z, f)), x0.origin.lerp(x1.origin, f))
			(parts[idx] as Node3D).transform = xf
		if ids.is_empty():
			_pbuf.erase(key)
