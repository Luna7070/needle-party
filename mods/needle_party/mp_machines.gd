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
		"_burning", "arriving", "full_wait", "starved_for",
		# (2026-11-14) "FUEL RUNNING LOW · empty in N min": the minutes are worked out in the
		# generator's own tick, stopped on a guest, so the warning never showed there
		"low_fuel_minutes",
		# (2026-11-14) what else their alerts read that only the host works out: the gas plant's
		# "FUEL DISCS ONLY · take the X off the intake", a hay generator's oversize load
		"_wrong_fuel", "_wrong_name", "_oversize"],
	# the panel's stop/start and rate dial live in discharge_rate/resume_rate;
	# without them one player's stopped silo kept emptying on the host
	"silos": ["switched_off", "stored", "queued", "discharge_rate", "resume_rate",
		"pending_needles", "power", "power_blocked", "starved_for", "blocked_for", "_clock", "_left_at"],
	# 1.0.1: every panel setting the current game build has (checked against
	# its scripts); before, a split ratio, route, pick order, drone zone, head
	# aim or depot emptying set by one player never reached the other
	# (2026-11-14) manual, then entry FIRST: a T-splitter's way in, set by hand; set_entry() remaps
	# the sides below, so it has to land before them (see _apply_field). manual before it, as the
	# game does it (set_t_by_hand): a T still on "by belts" gets its way in worked out again from
	# the belts when the junctions are rebuilt, and the hand-set one was undone at once.
	"splitters": ["manual", "entry", "forced_side", "priority_side", "next_side", "left_share",
		"split_route", "split_route_on", "split_route_alt", "filters", "smart", "closed_lane", "_holding", "_stuck"],
	"joiners": ["manual", "next_side", "out_lane"],
	"tube_launchers": ["switched_off", "aim", "power", "stored", "pending_needles"],
	# (1.2.19) the rake panel's last stroke (bite, gathered, thrown) and the reasons its
	# header and alert sign give (JAMMED, RAKING NOTHING, BELT FULL): they stayed at 0 / off
	"piston_rakes": ["switched_off", "throw_distance", "last_bite", "last_gathered", "last_thrown",
		"_jam_strokes", "_dry_strokes", "_holding",
		# (2026-11-13, dev/machine_audit.md) the throw limit and its counter: the guest's
		# rake never showed its limit and the panel counter stayed at 0
		"throw_limit_hit", "_thrown_total", "_did_throw",
		# (2026-11-14) why the host would not drive it (the panel shows it next to Back/Forward)
		"drive_blocked"],
	"pelletizers": ["switched_off", "throw_distance", "stored", "head_yaw", "_jam", "pending_needles", "iron_points", "copper_points", "poured",
		"_grind", "_cycle", "_holding", "starved_for", "furnace_heat",
		# the smelter's working state, see _drive_smelter
		"_load_clock", "_heat_clock", "_pour_clock", "_casting_metal", "_gripped", "_released",
		"_held_out", "activity", "_load_rate", "_heat_rate", "_cast_rate", "_handoff_at", "_cast_length"],
	# _stall: the reason it shows, "nowhere to put it" and the like
	"robotic_arms": ["switched_off", "accept_mask", "tier_index", "pick_order", "completed_cycles", "delivered_needles", "_stall",
		# (2026-11-14) "NOWHERE TO PUT IT" and its kind come from these (alert_reason)
		"_drop_fault", "_hold_tries",
		# (2026-11-14) which belts it takes from and puts on (and "take when stuck"), made up,
		# travels as links_to_save(): set by hand in the arm's link mode, never synced before
		"_links"],
	"scanners": ["switched_off", "tier_index", "banked", "stored", "thrown", "cannon_yaw",
		"cannon_throw", "_cycle_left", "_emit_left", "_loads", "_loads_total", "_outgoing", "behind", "starved_for"],
	"hay_lifts": ["down", "head_turn"],
	# renamed power lines, cables strung or cut by hand
	"power_poles": ["line_name", "links_at", "cuts_at"],
	"compressors": ["switched_off", "stored", "_jam", "pending_needles", "_cycle", "starved_for", "_press", "handover_frame"],
	"pulpers": ["switched_off", "stored", "_jam", "pending_needles", "water", "slabs_made", "_cycle", "starved_for", "_bed",
		# (2026-11-14) is_running() for the production panel is _run >= 0 (see COARSE)
		"_run"],
	# _t/_running: a fabricator's work timer, or the guest's panel shows its own
	# _cycle_recipe: the part a fabricator's mould is making (latched from recipe when a cycle
	# starts; only fabricators have it). Its mould is redrawn by _sync_mould, see REDRAW.
	"papers": ["switched_off", "queued", "recipe", "queued_needles", "pending_needles", "pressed", "_t", "_running",
		"_stage", "_out_left", "_out_strands", "made", "cycles", "starved_for", "_cycle_recipe", "_run"],
	# full game: assemblers, bioplastic reactors and carbon kilns are briquette
	# presses underneath and live in this list; "recipe" is theirs (a plain
	# press has none, and a field a machine lacks is skipped)
	"briquette_presses": ["switched_off", "stored_strands", "stored_bricks", "recipe", "_jam", "pending_needles", "slots", "made",
		"_cycle", "starved_for",
		# (2026-11-14) an assembler's "output blocked" alert (alert_reason)
		"_push_failed", "_out_id",
		# (2026-11-14) running or not (production panel) and an assembler's cycle time
		"_run", "_cycle_duration"],
	# depots are wrappers underneath: emptying is theirs
	"wrappers": ["switched_off", "queued", "emptying", "emptying_kinds", "queued_needles", "pending_needles", "taken",
		"_wrap", "starved_for"],
	"boreholes": ["switched_off"],
	"dump_hatches": ["stored"],
	# (1.2.21) tier_index/paid_cost: since the game update of 13 Nov 2026 each radar has
	# its own tier and can be upgraded
	"needle_radars": ["cooldown", "last_found", "phase", "_marks", "tier_index", "paid_cost",
		# (2026-11-13, dev/machine_audit.md) a tier set by hand, and the tier of the last run
		"tier_override", "_fired_tier"],
	"work_lamps": ["brightness", "_off", "tint", "sensor_auto", "sensor_on", "sensor_off", "sensor_dark", "paint"],
	# full game additions. Panel presses, fabricators and fibre machines are
	# paper machines underneath; depot drones are hay drones.
	# _stowed: what a depot drone's pod holds (made up; travels as stowed_records()). Its fill
	# lamps count it, and they stayed as they were when the guest joined.
	"hay_drones": ["switched_off", "mode", "zone_at", "zone_r", "drop_at", "drop_kind", "takes", "trips", "strands_put",
		"_stowed", "fill_slots",
		# (2026-11-13) what its status line (plate_status) reads: on a guest the stopped copy
		# kept its own and showed the wrong state (CLAUDE.md known issue). Display only.
		# (not power/power_line: the guest's own power grid works those out the same way)
		"_load_too_long", "_route_why", "_route_dirty",
		"_route_block_name", "_route_leg", "_route_block", "_phase", "_stall", "_empty_why",
		"_wait_traffic", "_wait",
		# (2026-11-14) a depot drone's status line on top: which item it fetches for an order and
		# how many more, lorry bed or doorway (only depot drones have these; null elsewhere)
		"errand", "_fetch_short", "_bed_at", "_bed_refused",
		# (2026-11-14) made up: 1 while the claws hold something (its status line counts it on board)
		"_held_on"],
	"hay_excavators": ["switched_off", "throw_distance", "dug", "thrown", "aimed", "aim_yaw", "aim_pitch", "aim_intake",
		# (2026-11-14) its work state and load: a guest's stopped copy kept the state it was loaded
		# with and showed "NOTHING MORE IN REACH" (or "SET ME UP") while the host's dug away
		"state", "load_strands", "_holding"],
	"skyline_cranes": ["switched_off", "zone_at", "zone_radius", "dug", "lots", "feed_rate",
		# (2026-11-14) the panel's feed slider at its top end sets feed_full, not feed_rate: a
		# guest's "full" never reached the host. hopper: what its panel shows it holds
		"feed_full", "hopper"],
	"pipe_pumps": ["switched_off", "tier"],
	# (2026-11-13, dev/machine_audit.md) a needle cabinet's doors: a guest's cabinet is
	# stopped, so opening it there played nothing and the host never knew
	# (2026-11-14) the end button: presses left and whether the key is being forged (the host's;
	# a guest's press goes to the host as an edit of _end_left, see _apply_field)
	"cabinets": ["_open", "_end_left", "_unleashed"],
	# (2026-11-14, F54) the sell stand: its combo count, and its last sale (made up, see
	# _watch_sales). A sale runs on the host only; a guest saw no payout, sound or combo.
	"stand": ["_combo", "_sale"],
}

# Machines from the full game's mixed lists (extras, fixtures, ...) go under
# "x:<script name>"; fittings there that keep running on a guest but have a
# switch go under "xs:<script name>". Both use these when nothing more
# specific is listed above.
const MIXED_FIELDS := ["switched_off", "recipe", "mode", "setting"]

# Machines that keep running on clients but whose settings still have to match.
const SETTINGS_ONLY := ["work_lamps", "power_poles"]

# (1.2.21) BuildManager's single buildings whose moving parts and clips follow the host
const SINGLES := ["stand", "shop"]

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
	"splitters": ["manual", "entry", "forced_side", "priority_side", "left_share", "split_route",
		"split_route_on", "split_route_alt", "filters", "smart", "closed_lane"],
	"joiners": ["manual", "out_lane"],
	"tube_launchers": ["switched_off", "aim", "power"],
	# _drive: the panel's Back/Forward, made up, see _send_drives
	# (2026-11-14) throw_limit_hit: the panel's reset (rake_panel sets it false) has to reach the host
	"piston_rakes": ["switched_off", "throw_distance", "_drive", "throw_limit_hit"],
	"pelletizers": ["switched_off", "throw_distance", "head_yaw", "_jam"],
	"robotic_arms": ["switched_off", "accept_mask", "tier_index", "pick_order", "_links"],
	"scanners": ["switched_off", "tier_index", "cannon_yaw", "cannon_throw"],
	"hay_lifts": ["down", "head_turn"],
	"power_poles": ["line_name", "links_at", "cuts_at"],
	"compressors": ["switched_off", "_jam"],
	"pulpers": ["switched_off", "_jam"],
	"papers": ["switched_off", "recipe"],
	"briquette_presses": ["switched_off", "recipe", "_jam"],
	"wrappers": ["switched_off", "emptying", "emptying_kinds"],
	"boreholes": ["switched_off"],
	# phase: the button, the host's radar goes off, see _apply_field. tier_index/paid_cost:
	# a guest's radar upgrade, like the arms' tier
	"needle_radars": ["phase", "tier_index", "paid_cost"],
	"work_lamps": ["brightness", "_off", "tint", "sensor_auto", "sensor_on", "sensor_off", "sensor_dark", "paint"],
	# full game additions (see FIELDS)
	"hay_drones": ["switched_off", "mode", "zone_at", "zone_r", "drop_at", "drop_kind", "takes"],
	"hay_excavators": ["switched_off", "throw_distance", "aimed", "aim_yaw", "aim_pitch", "aim_intake"],
	"skyline_cranes": ["switched_off", "zone_at", "zone_radius", "feed_rate", "feed_full"],
	"pipe_pumps": ["switched_off"],
	"cabinets": ["_open", "_end_left"],
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
	if _held_stand_in != null and is_instance_valid(_held_stand_in):
		var drones: Variant = builds.get("hay_drones") if builds != null and is_instance_valid(builds) else null
		for d in (drones if drones is Array else []):
			if is_instance_valid(d) and "_held" in d and d.get("_held") == _held_stand_in:
				d.set("_held", null)
		_held_stand_in.free()
	_held_stand_in = null
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
var _nodes_sig := 0
var _nodes_n := -1

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
	# (1.2.21) the sell stand and the supply shop: one of each, not in a list. A sale
	# runs on the host, so the stand's sale, till and sack clips never played on a
	# guest. Poses and clips only: neither is frozen and neither has a setting.
	for single in SINGLES:
		var s: Variant = builds.get(single)
		if s is Node3D and is_instance_valid(s):
			var skey := _key(String(single), s)
			_nodes[skey] = s
			_group[skey] = String(single)
			if single == "stand":
				if mp.is_host:
					_watch_sales(s as Node)
				else:
					_note_stand(s as Node)
	_rescan_mixed(ws)
	_rescan_deco(ws, groups + SETTINGS_ONLY + MIXED_GROUPS)
	_refresh_parts()
	# (2026-11-13) the same machines as last time (the usual case): nothing to forget, and
	# the 18 lists below need no walk
	var sig := hash(_nodes.keys())
	if sig == _nodes_sig and _nodes.size() == _nodes_n:
		return
	_nodes_sig = sig
	_nodes_n = _nodes.size()
	if _key_cache.size() > _nodes.size() * 2 + 256:
		_key_cache.clear()
	# forget machines that are gone (this used to run over _parts after it was
	# cleared, so it never did anything and every demolished machine's state
	# stayed behind for good)
	for d in [_sent, _flags, _vals, _goal, _fx_sent, _fx_seen, _theirs, _edit_sent, _edit_at, _far_sent, _moved_ever, _anim_sent, _anim_on, _pbuf,
			_claw_sent, _claw_due, _claw_on, _claw_t, _wrote, _local_parts, _gap_ms, _last_word]:
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


# (2026-11-13) a rescan (every 2 s) built this text for every machine, belt and lamp of
# the yard again (~700 on the test save, part of a 4-9 ms hitch): kept per node now and
# built again only when the node moved or its group changed.
var _key_cache := {}   # node instance id -> [group, position, b, key]

func _key(group: String, n: Node3D) -> String:
	var p := _pos_of(n)
	var b: Variant = n.get("b") if "a" in n and "b" in n else null
	var id := n.get_instance_id()
	var c: Variant = _key_cache.get(id)
	if c is Array and c[0] == group and c[1] == p and c[2] == b:
		return c[3]
	var k := "%s|%.2f,%.2f,%.2f" % [group, p.x, p.y, p.z]
	# belts, rails, beams, pipes: placed by two ends, and several can share one
	if b is Vector3:
		k += "|%.2f,%.2f,%.2f" % [b.x, b.y, b.z]
	_key_cache[id] = [group, p, b, k]
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
	"jump_pad": ["switched_off", "angle", "strength", "paint", "throws"],
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
	_redraw_players.erase(_walked.get(key))
	if _redraw_players.size() > 2048:
		_redraw_players.clear()  # nodes that are gone: walked again on their next redraw
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
		# (2026-11-14) the game's shadow stand-ins (world/shadow_fixes.gd): shadow-only copies
		# that a RemoteTransform3D or a BoneAttachment3D keeps on the part they stand for, on
		# every PC by itself. Sent as poses too, a guest's easing pulled them behind while the
		# follower put them back: the shadow jumped (rake: 22 jumps in 10 s, host 8).
		if _shadow_stand_in(child):
			continue
		var nm := String(child.name)
		if nm.begins_with("@"):
			nm = "%s#%d" % [cls, seen]
		var path := nm if prefix == "" else prefix + "/" + nm
		out.append(child)
		paths.append(path)
		_walk_named(child, path, out, paths)


func _shadow_stand_in(c: Node) -> bool:
	if c is GeometryInstance3D:
		return (c as GeometryInstance3D).cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY 			and c.has_meta("shadow_fix_off") and c.get_meta("shadow_fix_off") is bool
	if c is RemoteTransform3D:
		var to: Node = (c as RemoteTransform3D).get_node_or_null((c as RemoteTransform3D).remote_path)
		return String(c.name).begins_with("ShadowProxyFollow") or (to != null and _shadow_stand_in(to))
	if c is BoneAttachment3D and c.get_child_count() > 0:
		for k in c.get_children():
			if not _shadow_stand_in(k):
				return false
		return true
	return false


# (2026-11-14) The game holds a machine's clips, slows them, draws it only a few times a
# second or tells it it is unseen when the HOST's own eye is far or looks elsewhere
# (world/machine_lod.gd). The host's clips and parts are what guests get: a guest standing
# at a machine the host was not looking at saw it stand still (_test/lod_test.py: 100%
# moving, 0% as soon as the host turned away). Machines near a guest are kept as if they
# stood near the host's eye and in view; given back when no guest is near any more.
# The game's LOD class, looked up by name and read by name: the demo's older build lacks some of
# its members (_slow), and naming them in code kept this whole file from loading there (the
# machine sync was then off in the demo; caught by the demo boot check of _test/paket_bauen.py).
var _lod_cls: Variant = false  # false = not looked up yet

func _lod_static(member: String) -> Variant:
	if _lod_cls is bool:
		_lod_cls = null
		for c in ProjectSettings.get_global_class_list():
			if String(c.get("class", "")) == "MachineLod":
				_lod_cls = load(String(c.get("path", "")))
				break
	if _lod_cls == null or not is_instance_valid(_lod_cls):
		return null
	return (_lod_cls as Object).get(member)


const LOD_GUEST_M := 70.0
const LOD_EVERY := 0.5
var _lod_t := 0.0
var _lod_kept := {}  # machine root instance id -> [watch dict, gate, base, offok, reach]

func _lod_for_guests(delta: float) -> void:
	_lod_t += delta
	if _lod_t < LOD_EVERY:
		return
	_lod_t = 0.0
	var spots: Array = []
	var ws: Variant = mp.get("world_sync")
	if mp.is_host and mp.active() and ws != null and is_instance_valid(ws) and ws.has_method("avatar_positions"):
		spots = (ws.call("avatar_positions") as Dictionary).values()
	var keep := {}
	var watched: Variant = _lod_static("_watched")
	if not spots.is_empty() and watched is Array:
		for w: Dictionary in watched:
			var root: Variant = w.get("root")
			if root == null or not is_instance_valid(root) or not (root as Node3D).is_inside_tree():
				continue
			var at: Vector3 = (root as Node3D).global_position
			var near := false
			for spot in spots:
				if at.distance_to(spot) <= LOD_GUEST_M:
					near = true
					break
			if not near:
				continue
			var id := (root as Object).get_instance_id()
			keep[id] = true
			if not _lod_kept.has(id):
				_lod_kept[id] = [w, w.get("gate"), w.get("base"), w.get("offok"), w.get("reach")]
			w["gate"] = INF
			w["offok"] = false
			w["reach"] = Vector2(INF, INF)
	for id in _lod_kept.keys():
		if keep.has(id):
			continue
		var row: Array = _lod_kept[id]
		var w: Dictionary = row[0]
		_lod_kept.erase(id)
		if row[1] != null:
			# the game moves every gate by the same step when the view distance changes (regate)
			var moved := float(w.get("base", 0.0)) - float(row[2]) if row[2] != null else 0.0
			w["gate"] = float(row[1]) + moved
		if row[3] == null:
			w.erase("offok")
		else:
			w["offok"] = row[3]
		if row[4] == null:
			w.erase("reach")
		else:
			w["reach"] = row[4]


# (2026-11-14) Guest: the cabinet's last end press on a guest's own copy starts a KeyForge
# under it, and only the cabinet itself is frozen there: the forge ran, made a key of the
# guest's own (GameState.key_taken, a HatchKey in the guest's world) the host never knew of.
# The press goes to the host (_apply_field "_end_left"); a forge started here is taken away.
var _forge_t := 0.0

func _no_local_key(delta: float) -> void:
	_forge_t += delta
	if _forge_t < 0.2 or builds == null or not is_instance_valid(builds):
		return
	_forge_t = 0.0
	var cabs: Variant = builds.get("cabinets")
	if not (cabs is Array):
		return
	for c in cabs:
		if not is_instance_valid(c) or not ("_forge" in c):
			continue
		var forge: Variant = c.get("_forge")
		if forge != null and is_instance_valid(forge):
			(forge as Node).queue_free()
			c.set("_forge", null)
			if mp != null and mp.trace != null:
				mp.trace.note("cabinet: a key forge started on this guest was taken away (the host forges it)")


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
	if mp != null and (mp.is_host or not _lod_kept.is_empty()):
		_lod_for_guests(delta)
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
		_no_local_key(delta)
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
	# (2026-11-13) a pose tick is done in two halves, TICK/2 apart, each with half the time
	# budget: the same work, but a 3-4 ms piece every 50 ms instead of a 6-7.5 ms one every
	# 100 ms (an uneven frame ten times a second on the host). The turns (full refresh,
	# far machines) still count whole ticks: they move on in the first half only.
	if _t >= TICK * 0.5 and _pose_slot.take():
		_t = 0.0
		_pose_second = not _pose_second
		# (1.1.4, idea from xRangerDE's Multiplayer Enhanced, MIT) the full
		# refresh used to send every part of every machine in one tick each
		# FULL_TICK; now each tick refreshes the machines whose turn it is, so
		# every machine still gets one every FULL_TICK, never all at once
		if not _pose_second:
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
		if _pose_second:
			continue   # far ones: once per whole tick, in its first half
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
		if spent > POSE_BUDGET_US / 2:
			break
		if step < n_near and spent > NEAR_SHARE_US / 2:
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
	if not _pose_second:   # the second half has no far ones: keep their turn where it is
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
				if only_settings and mp.is_host and was.has(f) and mp.trace != null and f != "_jam" \
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
var _pose_second := false   # host: this pose pass is the second half of its tick
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
	var settings: Array = _settings_of(String(_group.get(key, "")))
	for f in diff:
		var had: bool = known.has(String(f))
		var before: Variant = known.get(String(f))
		known[String(f)] = diff[f]
		# (2026-11-13) the host only repeats what it said before (its regular full pass),
		# but the player has changed this setting here and the edit tick has not sent it yet
		# (it looks every 50-200 ms): applying the repeat threw the click away (switch test:
		# 3 of 40 guest clicks never reached the host). Keep ours; it goes out on the next
		# edit tick. Settings only (nothing else changes on a stopped copy by itself); not
		# the jam meter, which runs down here on its own.
		if had and settings.has(String(f)) and String(f) != "_jam" and not ours.has(String(f)) \
		and before == diff[f] and _get_field(n as Node, String(f)) != diff[f]:
			continue
		# only an edit of ours the host has not answered yet is protected. Once
		# it says our value back the edit is settled and its word counts again;
		# anything else would send our old value back over a newer change of theirs
		var mine: Variant = ours.get(String(f))
		if mine is Array and (mine as Array).size() == 2 and (mine as Array)[0] != diff[f] \
		and fresh and _settings_of(String(_group.get(key, ""))).has(String(f)):
			continue
		# (2026-11-13) the host says back the edit we sent, but the player has switched again
		# here since (off, then on at once): applying the echo threw the newer click away and
		# the host never heard of it (3 of 40 quick off/on clicks in the switch test). The
		# edit is settled; ours stays and the next edit tick sends it.
		if mine is Array and (mine as Array).size() == 2 and (mine as Array)[0] == diff[f] \
		and fresh and _settings_of(String(_group.get(key, ""))).has(String(f)) \
		and _get_field(n as Node, String(f)) != diff[f]:
			ours.erase(String(f))
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
var _redraw_players := {}  # machine node -> its AnimationPlayers (guest, _redraw)
var _held_stand_in: Node3D = null  # guest: what a drone "holds" while the host's holds something
const REDRAW := ["_apply_dials", "_apply_heap", "_apply_readout", "_apply_lamps",
	"_apply_spin", "_draw_spin", "_apply_meter", "_apply_gauge", "_apply_lamp",
	"_refresh_screen", "_apply_cannon", "_sync_counts", "_sync_mould"]

func _redraw(n: Node) -> void:
	if mp.is_host or n == null or not is_instance_valid(n):
		return
	# (2026-11-14) drawing must not touch how its clips play: those follow the host
	# (_apply_anims). The briquette press's _apply_spin sets its grind and mill clips'
	# speed from the stopped copy's own numbers (0.12 where the host ran 0.74): the clips
	# fell behind, were pulled forward again and its sleeve jumped up to 35 cm.
	var ps: Array = _redraw_players.get(n, [])
	if not _redraw_players.has(n):
		ps = (n as Node).find_children("*", "AnimationPlayer", true, false)
		_redraw_players[n] = ps
	var speeds := PackedFloat32Array()
	for p in ps:
		speeds.append((p as AnimationPlayer).speed_scale if is_instance_valid(p) else 0.0)
	for m in REDRAW:
		if n.has_method(m) and n.get_method_argument_count(m) == 0:
			n.call(m)
	for i in ps.size():
		if is_instance_valid(ps[i]) and (ps[i] as AnimationPlayer).speed_scale != speeds[i]:
			(ps[i] as AnimationPlayer).speed_scale = speeds[i]


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

# (2026-11-13) With the mouse free (a panel, the menu, chat) every building was read 20 times
# a second: ~700 on the test yard, 4-5 ms each time, as long as a panel stayed open. The ones
# in reach (where the open panel is) still go every tick; all of them every EDIT_FREE_ALL-th.
const EDIT_FREE_ALL := 4
var _edit_free_n := 0

func _edit_turn() -> Array:
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		_edit_free_n += 1
		if _edit_free_n >= EDIT_FREE_ALL:
			_edit_free_n = 0
			return _nodes.keys()
		_edit_turn_near()   # keeps the near list fresh (and turns the rolling pass)
		return _edit_near.duplicate()
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
# (2026-11-14) An excavator's dig zone set by a guest (its zone mode calls set_tube on the
# guest's stopped copy): only the angles reached the host, and the host's excavator stayed
# "NOTHING MORE IN REACH" and never moved there. What set_tube() does after the angles is done
# here too: new target for the arm, state MOVING, tube redrawn, woken up.
const AIM_FIELDS := ["aimed", "aim_yaw", "aim_pitch", "aim_intake"]

func _retube(n: Node) -> void:
	if not n.has_method("aim_controls") or not ("_want" in n) or not bool(n.get("aimed")):
		return
	var states: Variant = (n.get_script() as Script).get_script_constant_map().get("State") if n.get_script() != null else null
	if not (states is Dictionary) or not (states as Dictionary).has("MOVING"):
		return
	n.set("_want", n.call("aim_controls", 0.0))
	if "_extending" in n:
		n.set("_extending", false)
	if "_acc" in n:
		n.set("_acc", 0.0)
	n.set("state", int((states as Dictionary)["MOVING"]))
	if "_tube_key" in n:
		n.set("_tube_key", "")
	if n.has_method("_draw_tube"):
		n.call("_draw_tube")
	if n.has_method("_wake"):
		n.call("_wake")


func on_edit(from: int, batch: Dictionary) -> void:
	if not mp.is_host or not mp.players.has(from):
		return
	_press_marks(batch, " by=guest")
	var echo := {}
	for guest_key in batch:
		var key := _local_key(String(guest_key))
		var n: Variant = _nodes.get(key)
		if n == null or not is_instance_valid(n):
			continue
		var names: Array = _settings_of(String(_group.get(key, "")))
		var diff: Dictionary = batch[guest_key]
		var was: Dictionary = _vals.get(key, {})
		_guest_edit_at[key] = Time.get_ticks_msec()
		var aimed_now := false
		for f in diff:
			# only ever the settings: a guest does not get to set our stock
			if names.has(String(f)):
				_apply_field(n as Node, String(f), diff[f])
				if AIM_FIELDS.has(String(f)):
					aimed_now = true
			# forget what we last sent for it either way, so the next field
			# tick states our value again: that is what puts a guest back in
			# line when we would not take the change
			was.erase(String(f))
		_vals[key] = was
		_after_fields(n as Node)
		if aimed_now:
			_retube(n as Node)
		# (F60, 2026-11-16) say our value back now, not on the next field pass: the fast pass
		# only covers machines within SETTINGS_REACH of our own player, so for a machine the
		# guest works far from us the echo came with the rolling full pass, up to 0.5 s later.
		# A change of ours in that window went out instead of the echo; the guest kept its own
		# edit against it (EDIT_GUARD_MS) and sent its old value again: our change was undone
		# (cabinet_radar_test: "host opens the cabinet" 2 of 3 times closed again by itself).
		var back := {}
		for f in diff:
			if not names.has(String(f)):
				continue
			var v: Variant = _get_field(n as Node, String(f))
			if v == null or v is Object or v is RID or v is Callable:
				continue
			back[String(f)] = v
			was[String(f)] = v.duplicate(true) if (v is Array or v is Dictionary) else v
		if not back.is_empty():
			echo[key] = back
	if not echo.is_empty():
		mp._rx_machine_fields.rpc(echo)
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
const COARSE := {"starved_for": 0.5, "blocked_for": 0.5, "arriving": 0.5, "full_wait": 0.5, "behind": 0.1,
	# (2026-11-14) a run timer, -1 when stopped: only "running or not" matters on a guest
	"_run": 1.0}

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
	"_held_out": true, "activity": true, "_handoff_at": true, "_cast_length": true,
	"_phase": true, "_wait": true, "_wait_traffic": true, "_wrong_fuel": true, "_run": true,
	"_held_on": true}


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
	if f == "_sale":
		return n.get_meta("mp_sale") if n.has_meta("mp_sale") else null
	if f == "_held_on":
		return (1 if n.get("_held") != null else 0) if "_held" in n else null
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
	if f == "_links":
		return n.call("links_to_save") if n.has_method("links_to_save") and n.has_method("load_links") else null
	if f == "_jam":
		var sj: Variant = n.get("scrap_jam")
		if sj is Object and (sj as Object).has_method("to_dict"):
			# (2026-11-13) "decay" is a running timer: unrounded it changed on every pass,
			# so every machine with a jam meter went out 10 times a second and was logged
			# as a button press (2,800 of them in one half-hour log). Whole seconds are
			# enough: the meter itself only steps once per DECAY_SECONDS.
			var d: Dictionary = (sj as Object).call("to_dict")
			if d.has("decay"):
				d["decay"] = snappedf(float(d["decay"]), 1.0)
			return d
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
	if f == "_combo" or f == "_sale":
		_apply_stand(n, f, v)
		return
	# (2026-11-14) a drone's claws hold something on the host: its status line on a guest counts
	# "_held != null" on board. The guest's drone is stopped and nothing else reads it there, so
	# one shared stand-in node (never in the tree) does; nothing held: null again.
	if f == "_held_on":
		if "_held" in n:
			if int(v) != 0 and n.get("_held") == null:
				if _held_stand_in == null:
					_held_stand_in = Node3D.new()
				n.set("_held", _held_stand_in)
			elif int(v) == 0 and n.get("_held") == _held_stand_in:
				n.set("_held", null)
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
	# (2026-11-14) a T-junction's arms set by hand: a T-splitter's way in (entry) and a T-joiner's
	# way out (out_lane). Only set_entry/set_out lay its belt paths anew, and the game then
	# refits the runs at its mouths and works the joints out again (set_t_by_hand). entry was
	# never synced at all (not in the building's key either), out_lane was only stored.
	if (f == "entry" and n.has_method("set_entry")) or (f == "out_lane" and n.has_method("set_out")):
		if int(n.get(f)) != int(v):
			n.call("set_entry" if f == "entry" else "set_out", int(v))
			if builds != null and is_instance_valid(builds):
				if n.has_method("ports") and builds.has_method("refit_runs_at"):
					builds.call("refit_runs_at", n.call("ports"))
				if builds.has_method("rebuild_junctions"):
					builds.call("rebuild_junctions")
		return
	# (2026-11-14) a compact splitter's door filters: set_filter() also drops the door it already
	# picked for the waiting item, so a host fed a guest's new filter does not send that item
	# out a door the filter now shuts. A guest's copy is stopped: only its door tags get redrawn
	# (set_filter would hold its feeder belt).
	if f == "filters" and n.has_method("set_filter") and (v is PackedInt32Array or v is Array):
		var cur_f: Variant = n.get("filters")
		var want_f: Array = Array(v)
		if mp.is_host and (cur_f is PackedInt32Array or cur_f is Array) and Array(cur_f).size() == want_f.size():
			var old_f: Array = Array(cur_f)
			for side in want_f.size():
				if int(old_f[side]) != int(want_f[side]):
					n.call("set_filter", side, int(want_f[side]))
			return
		n.set("filters", PackedInt32Array(want_f))
		if n.has_method("refresh_door_tags"):
			n.call("refresh_door_tags")
		return
	# (2026-11-14) an arm's belt links, through the game's own loader (as from a save)
	if f == "_links":
		if v is Array and n.has_method("load_links"):
			n.call("load_links", v)
		return
	# (2026-11-14) the cabinet's end button. A guest's press runs on its own copy (hand.gd calls
	# press_ending there) and never reached the host; its presses left go to the host as this
	# edit, and the host presses its own button that many times (the game's checks included:
	# armed, the pile dug out). The host's count comes back to the guest as a field.
	if f == "_end_left" and n.has_method("press_ending"):
		if mp.is_host:
			var guard := 0
			while int(n.get("_end_left")) > int(v) and guard < 6:
				guard += 1
				var before := int(n.get("_end_left"))
				if not (n.has_method("ending_armed") and bool(n.call("ending_armed"))):
					break
				n.call("press_ending")
				if int(n.get("_end_left")) >= before:
					break  # refused (the pile is not dug out yet): the game said why on the host
		else:
			n.set("_end_left", int(v))
			if n.has_method("_show_end_count"):
				n.call("_show_end_count")
		return
	if f == "_unleashed" and n.has_method("press_ending"):
		n.set("_unleashed", bool(v))
		if bool(v):
			n.set("_end_armed", false)  # the key is on its way: the button is done
		return
	# (2026-11-13) cabinet doors: the host opens or shuts its own (the door clip then
	# reaches guests with the other animations); a guest only takes the state, its
	# stopped copy plays the host's clip
	if f == "_open" and n.has_method("open_doors") and n.has_method("close_doors"):
		if mp.is_host:
			n.call("open_doors" if bool(v) else "close_doors")
		else:
			n.set("_open", bool(v))
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
	if mp.is_host:
		_after_filter(n, f)


# (2026-11-14) Filters the game sets with two-value setters (set_emptying_kind(id, on),
# set_accepting(bit, on)), so a guest's change lands raw above. Those setters also refresh
# what the machine works from; the host does that part too: a depot re-tells its belt which
# items to park (else the belt kept parking by the old list), a drone forgets the spots it
# had marked as done (else up to 10 s of skipping them), an arm looks again at once.
func _after_filter(n: Node, f: String) -> void:
	if f == "emptying_kinds" and n.has_method("_sync_parks"):
		n.call("_sync_parks")
	elif f == "takes" and "_covered" in n:
		var cov: Variant = n.get("_covered")
		if cov is Dictionary:
			(cov as Dictionary).clear()
	elif f == "accept_mask" and "_scan_left" in n and "_stall" in n and "_clear" in n:
		n.set("_stall", "")
		n.set("_clear", false)
		n.set("_scan_left", minf(float(n.get("_scan_left")), 0.15))


# Parts ease towards the last pose we heard about, so ten packets a second
# still read as movement rather than stepping.
func _ease(delta: float) -> void:
	_play_samples()
	_play_claws()
	_hold_pins()
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
			_moved_here(key, int(part_id), part as Node3D)
			# axis by axis: interpolate_with would pull a skewed part through a
			# rotation it never had
			(part as Node3D).transform = Transform3D(Basis(
					from.basis.x.lerp(to.basis.x, t),
					from.basis.y.lerp(to.basis.y, t),
					from.basis.z.lerp(to.basis.z, t)),
				from.origin.lerp(to.origin, t))
			_wrote_pose(key, int(part_id), part as Node3D)
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
		# Speed: the player's own while the clip really runs, the measured one only where
		# a machine holds a "playing" clip still or scrubs it by hand (the wrapper sits on
		# 0.0 while idle), or the stated speed would set a guest's copy running.
		# (1.2.21) Cycle clips that play once and start again from 0 (the compressor's
		# press, a digester's feed) were measured going backwards at every restart and
		# sent as -3x: the guest ran the clip back to 0 and stood there. A new clip was
		# sent at speed 0 (nothing measured yet) and a clip running into its end as half
		# speed. A step back, a first look and the end now keep the player's own speed.
		var pos := a.current_animation_position
		var mk := "%s#%d" % [key, i]
		var last: Variant = _anim_seen.get(mk)
		var stated := a.get_playing_speed() if a.is_playing() else 0.0
		var speed := stated
		var jumped := false
		var t_now := Time.get_ticks_usec()
		var anim_res: Animation = a.get_animation(clip) if a.has_animation(clip) else null
		var length := anim_res.length if anim_res != null else 0.0
		var looped := anim_res != null and anim_res.loop_mode != Animation.LOOP_NONE
		if last != null and last[0] == clip:
			var dt := float(t_now - int(last[2])) / 1000000.0
			var dp := pos - float(last[1])
			if dp < 0.0 and looped and length > 0.0:
				dp += length
			var kept := float(last[3]) if (last as Array).size() > 3 else stated
			var was_jump: bool = (last as Array).size() > 4 and bool(last[4])
			if dt > 0.02:
				if dp < 0.0:
					speed = stated            # started again from the top, or a seek back
				elif dp < 0.0005:
					speed = 0.0               # held: "playing" but not moving
				elif not looped and length > 0.0 and pos >= length - 0.02:
					speed = kept              # ran into its end between two looks
				else:
					var measured := snappedf(clampf(dp / dt, 0.0, 8.0), 0.05)
					var near := 0.15 * maxf(absf(stated), 0.2)
					if stated > 0.0 and dp > 0.15 and measured > 2.5 * stated and not was_jump and (absf(kept - stated) < near or absf(kept) < 0.05):
						# (2026-11-14) a jump on, not a faster run: the game seeked its clip ahead
						# (a rake's throw frame, a pulper's door) and mostly holds it there. Sent
						# as up to 8x, the guest ran past it and was pulled back on the next
						# word (rake head: 16-22 jumps of up to 3 m in 10 s, host 7). Hold where
						# it is; a clip that runs on is measured at its speed again next look
						# (only one look in a row counts as a jump: a clip scrubbed on fast by
						# hand gets its measured speed from the second look on).
						speed = 0.0
						jumped = true
					else:
						# a stated speed it really runs at: take that, it does not jitter
						speed = stated if absf(measured - stated) < near else measured
			else:
				speed = kept
		_anim_seen[mk] = [clip, pos, t_now, speed, jumped]
		state.append_array([i, clip, pos, speed])
	var vat := PackedFloat32Array()
	var ck := _clock_of(n)
	if not ck.is_empty():
		var c: Vector3 = n.get(ck[0])
		vat = PackedFloat32Array([c.y + (_vat_now() - c.x) * c.z, c.z])
	var now := Time.get_ticks_msec()
	var was: Array = _anim_sent.get(key, [-ANIM_RESEND_MS, [], PackedFloat32Array()])
	var had_clips := not (was[1] as Array).is_empty()
	if state.is_empty() and vat.is_empty():
		# (1.2.21) every clip has stopped: say so once. This used to return without a
		# word, so a guest's copy ran on (a looping clip for good).
		if had_clips:
			_anim_sent[key] = [now, [], PackedFloat32Array()]
			entry["a"] = []
		return
	var changed: bool = _full or now - int(was[0]) >= ANIM_RESEND_MS
	if not changed:
		# a new clip, a new speed, a stop or a start; the time runs on by itself.
		# (1.2.21) and where the guest's copy will be by now: a restart, a hold or a
		# seek keeps the clip and the speed but moves the host's clip somewhere else,
		# and the guest only heard of it up to a second later
		var old: Array = was[1]
		var since := float(now - int(was[0])) / 1000.0
		if old.size() != state.size():
			changed = true
		else:
			for j in range(0, state.size(), 4):
				if old[j] != state[j] or old[j + 1] != state[j + 1] \
						or absf(float(old[j + 3]) - float(state[j + 3])) > 0.1 * maxf(absf(float(old[j + 3])), 0.5):
					changed = true
					break
				var expect := float(old[j + 2]) + float(old[j + 3]) * since
				if _anim_off(ps[int(state[j])], String(state[j + 1]), expect, float(state[j + 2])) > ANIM_DRIFT_S:
					changed = true
					break
		var ov: PackedFloat32Array = was[2]
		if not changed and vat.size() == 2 and (ov.size() != 2 or absf(ov[1] - vat[1]) > 0.0001):
			changed = true
	if not changed:
		return
	_anim_sent[key] = [now, state, vat]
	if not state.is_empty() or had_clips:
		entry["a"] = state
	if not vat.is_empty():
		entry["v"] = vat


# How far apart two times in a clip are: round the loop for a looping clip, and
# a clip that plays once stands at its end after it.
func _anim_off(p: Variant, clip: String, expected: float, actual: float) -> float:
	var a: AnimationPlayer = null
	if is_instance_valid(p):
		a = p as AnimationPlayer
	if a == null or not a.has_animation(clip):
		return absf(expected - actual)
	var anim := a.get_animation(clip)
	var length := anim.length
	if length <= 0.0:
		return absf(expected - actual)
	if anim.loop_mode != Animation.LOOP_NONE:
		var d := absf(fposmod(expected, length) - fposmod(actual, length))
		return minf(d, length - d)
	return absf(clampf(expected, 0.0, length) - actual)


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
		# the freeze switched it off (mp_world _still_animations); it runs now. Not one the
		# game's LOD steps by hand (see _lod_steps)
		if a.process_mode == Node.PROCESS_MODE_DISABLED and not _lod_steps(a):
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


# (2026-11-14) The game's LOD runs the clips of a machine at mid distance from this PC's eye
# by hand (MachineLod._slow: player switched off, advance() a few times a second). Switching
# such a player back on ran it twice, on its own and by the LOD's steps: a guest's rake ran
# its clip at 2x, 0.7 s ahead of the host's, and was pulled back every stroke.
var _slow_frame := -1
var _slow_set := {}

func _lod_steps(a: AnimationMixer) -> bool:
	var f := Engine.get_process_frames()
	if f != _slow_frame:
		_slow_frame = f
		_slow_set.clear()
		var slow: Variant = _lod_static("_slow")
		for e in (slow if slow is Array else []):
			if e is Array and (e as Array).size() > 0 and is_instance_valid(e[0]):
				_slow_set[(e[0] as Object).get_instance_id()] = true
	return _slow_set.has(a.get_instance_id())


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
const SHOW_BEHIND_MAX_MS := 900.0
var _gap_ms := {}     # guest: key -> how far apart its pose words come (host ms, smoothed)
var _last_word := {}  # guest: key -> host ms of its last pose word
const SAMPLES_MIN := 2
const SAMPLES_MAX := 16
const KEEP_BACK_MS := SHOW_BEHIND_MAX_MS + 250.0  # history kept per part, host ms
const HOLD_GAP_MS := 700.0
var _pose_off := INF        # guest: local ms - host ms of the quickest message lately
var _pbuf := {}             # guest: key -> {part id: [[host ms, Transform3D], ...]}


func _host_ms() -> float:
	return float(Time.get_ticks_usec()) / 1000.0


func _add_sample(key: String, id: int, t: float, to: Transform3D, now_xf: Transform3D) -> void:
	# how far apart this machine's pose words come (moving ones; a stop in between is no gap)
	var last_t := float(_last_word.get(key, -1.0))
	if t > last_t:
		if last_t > 0.0 and t - last_t < HOLD_GAP_MS:
			var g := float(_gap_ms.get(key, t - last_t))
			_gap_ms[key] = g + (t - last_t - g) * 0.2
		_last_word[key] = t
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
	# (2026-11-14) keep what covers the time being shown (SHOW_BEHIND_MS back) and a bit more,
	# not a fixed count: with poses every ~55 ms, 4 samples reached back 165 ms only. The
	# oldest one then still lay ahead of the time shown, the part waited on it and slid on
	# when the list moved (depot drone: still in 31% of the frames where the host's flew,
	# rotors jumping 24 cm).
	while list.size() > SAMPLES_MIN and float(list[1][0]) < t - KEEP_BACK_MS:
		list.pop_front()
	while list.size() > SAMPLES_MAX:
		list.pop_front()
	parts[id] = list
	_pbuf[key] = parts


# (2026-11-14, F54) A sale at the stand runs on the host only: its payout text, register
# sound, best-sale and best-combo text and the combo count never showed on a guest (the
# guest's stand had no popup at all after the host's sold for an hour). The host notes each
# sale (number, amount and which kind of celebration it got) as the made-up field _sale;
# a guest near the stand plays the game's own celebration for it (text in its own language).
# Not its till drawer and work clip: those already follow the host's clips. No coins either
# (they are items of their own). The combo count travels as _combo; a milestone flies here.
var _sales_watched := {}  # host: stand instance id -> true (sold connected)
var _sale_seen := {}      # host: stand instance id -> [number, best_sale, combo told, popup tween ids]
var _stand_first := {}    # guest: stand instance id -> ms its first field came
var _sale_last := {}      # guest: stand instance id -> number of the last sale seen
const SALE_SHOW_M := 60.0 # guest: beyond this the celebration is not worth playing
const SALE_JOIN_MS := 3000
const SALE_FRESH_MS := 4000  # a sale older than this is not celebrated any more

func _watch_sales(s: Node) -> void:
	var id := s.get_instance_id()
	if _sales_watched.has(id) or not s.has_signal("sold"):
		return
	_sales_watched[id] = true
	_sale_seen[id] = [0, float(GameState.get("best_sale")), bool(s.get("_combo_told")) if "_combo_told" in s else false,
		_tween_ids(s)]
	s.connect("sold", _on_stand_sold.bind(s))


func _tween_ids(s: Node) -> Array:
	var out: Array = []
	var tw: Variant = s.get("_popup_tweens")
	if tw is Array:
		for t in tw:
			out.append((t as Object).get_instance_id() if t is Object and is_instance_valid(t) else 0)
	return out


# Called right after the game's celebration of the sale (sold is emitted after it).
func _on_stand_sold(_strands: Variant, amount: Variant, s: Node) -> void:
	if not is_instance_valid(s):
		return
	var id := s.get_instance_id()
	var seen: Array = _sale_seen.get(id, [0, 0.0, false, []])
	var best_now := float(GameState.get("best_sale"))
	var best := best_now > float(seen[1])
	var told := bool(s.get("_combo_told")) if "_combo_told" in s else false
	var combo_best := told and not bool(seen[2]) and not best
	# "selling too fast" shows in its own colour: the popup this sale just started tells
	var cheap := false
	var ids := _tween_ids(s)
	var pops: Variant = s.get("_popups")
	var cheap_col: Variant = (s.get_script() as Script).get_script_constant_map().get("COL_CHEAP") \
		if s.get_script() is Script else null
	if not best and not combo_best and pops is Array and cheap_col is Color:
		var old: Array = seen[3]
		for i in ids.size():
			if int(ids[i]) != 0 and (i >= old.size() or int(old[i]) != int(ids[i])) \
			and i < (pops as Array).size() and pops[i] is Label3D:
				cheap = ((pops[i] as Label3D).modulate as Color).is_equal_approx(cheap_col)
	var n_sale := int(seen[0]) + 1
	_sale_seen[id] = [n_sale, best_now, told, ids]
	# the amount exactly as the host has it: the till and popup round it the same way then
	s.set_meta("mp_sale", [n_sale, float(amount), best, combo_best, cheap, Time.get_ticks_msec()])


# guest: when the stand was first seen here (see _rescan); what comes within SALE_JOIN_MS of
# that is the state the host had before we came, not news
func _note_stand(s: Node) -> void:
	if not _stand_first.has(s.get_instance_id()):
		_stand_first[s.get_instance_id()] = Time.get_ticks_msec()


# guest: how long ago the host made a sale stamped with its clock (the host's pings carry
# that clock; mp_trace keeps the last one). -1: not known yet.
func _host_age_ms(host_ms: int) -> int:
	var tracer: Variant = mp.get("trace")
	var pair: Variant = tracer.get("_clock_pair") if tracer != null and is_instance_valid(tracer) else null
	if not (pair is Array) or (pair as Array).size() < 2:
		return -1
	return int(pair[1]) + (Time.get_ticks_msec() - int(pair[0])) - host_ms


func _apply_stand(n: Node, f: String, v: Variant) -> void:
	var id := n.get_instance_id()
	var now := Time.get_ticks_msec()
	_note_stand(n)
	var settled := now - int(_stand_first[id]) >= SALE_JOIN_MS
	if f == "_combo":
		if not ("_combo" in n):
			return
		var was := int(n.get("_combo"))
		n.set("_combo", int(v))
		if settled and int(v) > was and _sale_near(n) and n.has_method("combo_milestone") \
		and n.has_method("_fly_combo") and bool(n.call("combo_milestone", int(v))):
			n.call("_fly_combo", int(v))
		return
	if not (v is Array) or (v as Array).size() < 6:
		return
	n.set_meta("mp_sale", v)  # so the host's repeat of it reads as known
	var last: Variant = _sale_last.get(id)
	var number := int(v[0])
	_sale_last[id] = number
	if last != null and int(last) == number:
		return
	# the host's last sale (maybe an hour old) comes along when we join or walk near: old news
	var age := _host_age_ms(int(v[5]))
	if (age >= 0 and age > SALE_FRESH_MS) or (age < 0 and not settled):
		return
	if not _sale_near(n) or not n.has_method("_celebrate"):
		return
	var amount := float(v[1])
	if bool(v[2]):
		GameState.set("best_sale", maxf(float(GameState.get("best_sale")), amount))
	var keep := {}
	for p in ["_till_anim", "_anim"]:
		if p in n:
			keep[p] = n.get(p)
			n.set(p, null)
	n.call("_celebrate", amount, 0, bool(v[2]), bool(v[3]), bool(v[4]))
	for p in keep:
		n.set(p, keep[p])


func _sale_near(n: Node) -> bool:
	var pl: Variant = mp.world_sync.get("player") if mp.world_sync != null else null
	if not (pl is Node3D) or not is_instance_valid(pl) or not (pl as Node3D).is_inside_tree() \
	or not (n is Node3D) or not (n as Node3D).is_inside_tree():
		return false
	return (pl as Node3D).global_position.distance_to((n as Node3D).global_position) < SALE_SHOW_M


# (2026-11-14) The sell stand and the shop are not frozen on a guest (SINGLES): their own
# code moves some parts there too (the stand weighs what lies on it: scale plate, needle,
# money sack). Host poses on the same parts made them fight: the guest's sack, star and
# plate jumped in 200 frames of 10 s, the host's in none. A part that moved since we last
# put it somewhere is moved by the game here; from then on the host's pose is put back on it
# every frame (_hold_pins, after the game's physics step), so it shows the host's weighing
# and not the guest's own (which read 0.70 where the host's plate stood empty).
var _wrote := {}        # key -> {part id: transform we last gave it}
var _local_parts := {}  # key -> {part id: true} driven by the guest's own game

func _moved_here(key: String, id: int, part: Node3D) -> bool:
	if not SINGLES.has(String(_group.get(key, ""))):
		return false
	var mine: Dictionary = _local_parts.get(key, {})
	if mine.has(id):
		return true
	# a part a clip moves (here and on the host) is the clip's: not held
	if (_owned.get(key, {}) as Dictionary).has(id):
		return false
	var was: Dictionary = _wrote.get(key, {})
	if was.has(id) and not part.transform.is_equal_approx(was[id]):
		mine[id] = true
		_local_parts[key] = mine
		if _log:
			print("[MPMACH] %s part %d is moved by the game here: the host's pose is held on it" % [key, id])
		return true
	return false


func _hold_pins() -> void:
	for key in _local_parts:
		var mine: Dictionary = _local_parts[key]
		var was: Dictionary = _wrote.get(key, {})
		if mine.is_empty() or was.is_empty():
			continue
		var parts := _parts_of(key)
		var slot := _slot_of(key)
		var owned: Dictionary = _owned.get(key, {})
		for id in mine:
			if not was.has(id) or owned.has(id):
				continue  # a clip's part (it may have been posed before the clips were synced)
			var idx: int = int(slot.get(id, -1))
			if idx < 0 or idx >= parts.size() or parts[idx] == null or not is_instance_valid(parts[idx]):
				continue
			var part := parts[idx] as Node3D
			if not part.transform.is_equal_approx(was[id]):
				part.transform = was[id]


func _wrote_pose(key: String, id: int, part: Node3D) -> void:
	if not SINGLES.has(String(_group.get(key, ""))):
		return
	var was: Dictionary = _wrote.get(key, {})
	was[id] = part.transform
	_wrote[key] = was


func _play_samples() -> void:
	if _pbuf.is_empty() or _pose_off == INF:
		return
	var rt0 := _host_ms() - _pose_off
	for key in _pbuf.keys():
		# (2026-11-14) shown far enough back for how often this machine's poses come: the ones
		# out of RANGE get theirs 5 or 2.5 times a second, and 200 ms back the newest sample
		# had often not come yet: the arm stood until it did (robot arms 36 m off: no sample
		# ahead in 45% of the frames they moved in, 82% moving against the host's 91%)
		var rt := rt0 - clampf(float(_gap_ms.get(key, 0.0)) * 1.6, SHOW_BEHIND_MS, SHOW_BEHIND_MAX_MS)
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
			_moved_here(key, int(id), parts[idx] as Node3D)
			(parts[idx] as Node3D).transform = xf
			_wrote_pose(key, int(id), parts[idx] as Node3D)
		if ids.is_empty():
			_pbuf.erase(key)
