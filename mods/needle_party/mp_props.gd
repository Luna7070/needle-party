extends Node

# Loose item replication.
#
# Every prop in the yard gets an id. The peer that made it owns it and is the
# only one that sends its movement; everyone else keeps a frozen copy that
# follows along. Picking up an item somebody else owns takes it over, so the
# item keeps moving for everybody while you carry it.
#
# The host is the reference: a joining client throws its own props away and
# rebuilds the list the host sends.

const MOVE_TICK := 0.1
const STATE_TICK := 1.0
const CENSUS_TICK := 6.0
const MOVE_EPS := 0.005
const BASIS_EPS := 0.01
const MOVE_BUDGET := 60
const STATE_BUDGET := 20
const RESET_BATCH := 30
const SMOOTH := 16.0
# tool items and the avatar tool that draws them, see _hide_held_tools
const TOOL_ITEMS := {"spade": 1, "pitchfork": 2, "broom": 3, "sand_shovel": 4,
	"metal_detector": 5, "yard_vac": 6}
const HELD_TICK := 0.2
# pushed with both hands, the owner's farmer draws them, see _hand_barrows
const PUSHED_ITEMS := {"wheelbarrow": true}

var mp: Node
var world: Node
var props: Node

var _by_id := {}     # mp id -> Carryable
var _owner := {}     # mp id -> peer id
var _sent := {}      # mp id -> last transform we broadcast
var _hash := {}      # mp id -> hash of the last state we broadcast
var _goal := {}      # mp id -> transform a remote copy is easing towards
var _want := {}      # mp id -> peer we expect it from
var _next := 0
var _ready_map := false
var _busy := false   # we are the ones touching the prop list, do not echo it
var _move_t := 0.0
var _state_t := 0.0
var _census_t := 0.0
var _held_t := 0.0
var _hidden := {}   # mp id -> the layer a hidden copy had, while it is hidden
var _held := {}     # mp id -> true while its owner says they're carrying it
var _pushed := {}   # mp id -> avatar placing that copy in its hands
var _boarded := {}  # mp id -> where one of ours got on a belt, guest only
var _belt_t := 0.0
var _handed := {}   # mp id -> when we handed it to the host's belt, guest only
var _poured := {}   # mp id -> when we last poured towards this container
var _taken_at := {} # mp id -> when another player last took it over
var _log := OS.get_environment("MP_DEBUG_PROPS") != ""  # dev tracing


func start(mp_node: Node, world_node: Node) -> void:
	mp = mp_node
	world = world_node
	props = world.get("props")
	if props == null or not is_instance_valid(props):
		return
	props.item_added.connect(_on_added)
	props.item_removed.connect(_on_removed)
	var carry: Variant = _carry_tool()
	if carry != null:
		carry.carry_changed.connect(_on_carry_changed)
	session_started()


# The host can also open a session from inside a world, after this node is up.
func session_started() -> void:
	if mp.is_host and not _ready_map:
		_adopt_all()
		_ready_map = true


# (1.2.19) A guest's game keeps its own floor tidy too: over the item cap (120 by default,
# "Floor full at 120 pieces") it folds the oldest items away. On a guest the only items it
# may touch are the ones the guest owns, so it folded away exactly those: whatever a guest
# had just pulled with the Forcetron (or put down) vanished, for everybody. Only the host
# keeps the floor tidy now; the guest gets what it folds away like any other removal. The
# cap is lifted for as long as we are a guest and put back when we leave (it is not
# written to the settings file, checked).
var _cap_was: Variant = null

func _lift_floor_cap() -> void:
	if _cap_was != null:
		return
	var cfg := get_node_or_null("/root/Cfg")
	if cfg == null or cfg.get("prop_cap") == null:
		return
	_cap_was = cfg.get("prop_cap")
	cfg.set("prop_cap", 1000000)


# (1.2.19) Over the floor cap the host's game folds loose items away ("FLOOR FULL"), and
# leaves the ones near its player alone. It knows only the host's player, so whatever lay
# around a guest was first in line: a bale, a silo ball or a wad a guest dropped, threw or
# took off a belt was gone a few seconds later, for everybody (tested: thrown with the host
# far away, gone in 3 s; with the host next to it, kept). The host now puts the game's own
# "on hold" mark (what the clean-up skips) on items near every other player, renewed while
# they stay near, so a guest's floor is kept like the host's. The game's keep distance.
const KEEP_TICK := 0.5
const HOLD_META := "hold_until"   # LiveStrandManager.META_HOLD_UNTIL (not in every build)
const KEEP_M := 12.0       # Cfg.PROP_KEEP_DIST
const KEEP_HOLD_S := 1.5   # outlasts a few ticks; lapses on its own once nobody is near
var _keep_t := 0.0

func _keep_near_players() -> void:
	var ws: Variant = mp.world_sync if mp != null else null
	var avatars: Dictionary = ws.avatars if ws != null and is_instance_valid(ws) else {}
	var spots: Array[Vector3] = []
	for pid in avatars:
		var av: Variant = avatars[pid]
		if av != null and is_instance_valid(av) and (av as Node3D).is_inside_tree():
			spots.append((av as Node3D).global_position)
	if spots.is_empty():
		return
	var until := _yard_now() + KEEP_HOLD_S
	var r2 := KEEP_M * KEEP_M
	for id in _by_id:
		var it: Variant = _by_id[id]
		if it == null or not is_instance_valid(it) or not (it as Node3D).is_inside_tree():
			continue
		var at: Vector3 = (it as Node3D).global_position
		for p in spots:
			if at.distance_squared_to(p) <= r2:
				# never shorten a longer hold the game set itself
				if float(it.get_meta(HOLD_META, 0.0)) < until:
					it.set_meta(HOLD_META, until)
				break


# ---------------------------------------------------------------- game functions by name
# (1.2.19) Some game builds lack functions the mod calls (the demo has no
# BeltRun.kind_of_item(), and 1.2.18 failed to load this whole file there: no items synced
# for demo players, seen in their logs). Called by name instead, so a missing one switches
# off only what needs it.
static var _statics := {}   # "Class.method" -> the class (a Script) when it has it, else null

static func _static_of(cls: Variant, key: String, method: String) -> Variant:
	var k := key + "." + method
	if not _statics.has(k):
		var found: Variant = null
		if cls is Script:
			for f in (cls as Script).get_script_method_list():
				if String(f.get("name", "")) == method:
					found = cls
					break
		_statics[k] = found
	return _statics[k]


static var _yard_clock: Variant = false   # false = not looked up yet

static func _game_class(name: String) -> Variant:
	for c in ProjectSettings.get_global_class_list():
		if String(c.get("class", "")) == name:
			return load(String(c.get("path", "")))
	return null


# the game's own clock (YardClock.seconds()), or ours where a build has none
static func _yard_now() -> float:
	if typeof(_yard_clock) == TYPE_BOOL:
		_yard_clock = _game_class("YardClock")
	if _yard_clock != null and _static_of(_yard_clock, "YardClock", "seconds") != null:
		return float(_yard_clock.call("seconds"))
	return float(Time.get_ticks_msec()) / 1000.0


static func _kind_of_item(item_id: String, state: Dictionary) -> int:
	var c: Variant = _static_of(BeltRun, "BeltRun", "kind_of_item")
	return int(c.call("kind_of_item", item_id, state)) if c != null else -1


static func _record_where(seq: int) -> Dictionary:
	var c: Variant = _static_of(BeltPath, "BeltPath", "record_where")
	return c.call("record_where", seq) if c != null else {}


static func _record_in(at: Vector3, r: float) -> Dictionary:
	var c: Variant = _static_of(BeltPath, "BeltPath", "record_in")
	return c.call("record_in", at, r) if c != null else {}

static func _is_rider(rb: RigidBody3D) -> bool:
	var c: Variant = _static_of(BeltPath, "BeltPath", "is_rider")
	return bool(c.call("is_rider", rb)) if c != null else false


static func _release_rider(rb: RigidBody3D) -> void:
	var c: Variant = _static_of(BeltPath, "BeltPath", "release")
	if c != null:
		c.call("release", rb)


# Player.Tool.<name>, or -999 (no tool is that) where a build has no such tool
static var _tools: Variant = null

static func _tool(name: String) -> int:
	if _tools == null:
		var m: Dictionary = (Player as Script).get_script_constant_map() if Player is Script else {}
		_tools = m.get("Tool", {}) if m.get("Tool") is Dictionary else {}
	return int((_tools as Dictionary).get(name, -999))


# `o is <name>` for a game class a build may not have (by its script and the ones it extends)
static func _is_a(o: Variant, cname: String) -> bool:
	if o == null or not is_instance_valid(o):
		return false
	var sc: Variant = (o as Object).get_script()
	while sc is Script:
		if String((sc as Script).get_global_name()) == cname:
			return true
		sc = (sc as Script).get_base_script()
	return false


func _restore_floor_cap() -> void:
	if _cap_was == null:
		return
	var cfg := get_node_or_null("/root/Cfg")
	if cfg != null:
		cfg.set("prop_cap", _cap_was)
	_cap_was = null


func shutdown() -> void:
	_restore_floor_cap()
	if props == null or not is_instance_valid(props):
		return
	if props.item_added.is_connected(_on_added):
		props.item_added.disconnect(_on_added)
	if props.item_removed.is_connected(_on_removed):
		props.item_removed.disconnect(_on_removed)
	var carry: Variant = _carry_tool()
	if carry != null and carry.carry_changed.is_connected(_on_carry_changed):
		carry.carry_changed.disconnect(_on_carry_changed)
	for id in _by_id:
		var it: Variant = _by_id[id]
		if it != null and is_instance_valid(it):
			_release(it)
			if _hidden.has(id):
				it.collision_layer = int(_hidden[id])
				it.visible = true
	for id in _pushed:
		if is_instance_valid(_pushed[id]):
			_pushed[id].push_item(null)
	_pushed.clear()
	_carrying.clear()
	_flying.clear()
	for it in _sinking.keys():
		if is_instance_valid(it):
			_remove_copy(it)
	_sinking.clear()
	_boarded.clear()
	_rp_wait.clear()
	_rp_shown.clear()
	_held.clear()
	_hidden.clear()
	_by_id.clear()
	_owner.clear()
	_goal.clear()


func _carry_tool() -> Variant:
	var pl: Variant = world.get("player")
	if pl == null or not is_instance_valid(pl):
		return null
	var c: Variant = pl.get("carry")
	if c == null or not is_instance_valid(c) or not c.has_signal("carry_changed"):
		return null
	return c


# (2026-11-14) The carry tool keeps the item it aims at until its next look (a few frames). An
# item taken out of the world in between (a belt or machine took it, or the other player's word
# removed it here) is out of the tree but not freed yet, and the tool's rip check asked for its
# position every frame: "!is_inside_tree()" from carry_tool _building_before, hundreds of times
# in players' logs, each with a backtrace. It aims at nothing until it looks again.
func _carry_forgets(item: Node) -> void:
	if world == null or not is_instance_valid(world):
		return
	var c: Variant = _carry_tool()
	if c == null or not ("_target" in c) or not c.has_method("_set_target"):
		return
	if c.get("_target") == item:
		c.call("_set_target", null)


func _me() -> int:
	return multiplayer.get_unique_id()


func _new_id() -> int:
	_next += 1
	return (_me() << 31) | (_next & 0x7FFFFFFF)


# ------------------------------------------------------------------ bookkeeping

func _adopt_all() -> void:
	for item in props.items:
		if is_instance_valid(item) and not item.has_meta("mp_id"):
			_adopt(item, _new_id(), _me())


func _adopt(item: Node, id: int, owner: int) -> void:
	# Ids are peer * 1e6 + a counter that starts over with every world load.
	# After a resync the host still lists items we made before it, so carry on
	# counting from the highest of ours, or a new item takes an old one's id
	# and the others just move the old one to where the new one is.
	if id >> 31 == _me():
		_next = maxi(_next, id & 0x7FFFFFFF)
	item.set_meta("mp_id", id)
	_by_id[id] = item
	_owner[id] = owner
	_want.erase(id)
	if owner == _me():
		_release(item)
	else:
		_puppet(item)


func _forget(id: int) -> void:
	_carrying.erase(id)
	_hidden.erase(id)
	_held.erase(id)
	_by_id.erase(id)
	_owner.erase(id)
	_sent.erase(id)
	_hash.erase(id)
	_goal.erase(id)
	_poured.erase(id)


# A copy owned by somebody else: no physics of its own, and off limits to the
# yard cleaner and to the machines that go looking for loose hay.
func _puppet(item: Node) -> void:
	item.set_meta("mp_copy", true)
	item.set_meta(PropManager.META_CLAIM, get_instance_id())
	item.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	item.freeze = true
	item.set_physics_process(false)
	# a new hay tuft starts with no collision layer and gets it back in its own
	# physics tick once no straw is inside it; that tick is off on a copy, so the
	# copy stayed out of everyone's aim and only its maker could pick it up
	if item is HayTuft and float(item.get("_emerging")) > 0.0:
		item.set("_emerging", 0.0)
		item.collision_layer = int(item.get("_emerge_layer"))
		item.collision_mask = int(item.get("_emerge_mask"))


# Moving a frozen body by its transform alone leaves its collision shape
# behind, so a copy could be seen but not picked up or bumped into. Tell the
# physics server as well, the way the game does in Carryable.warp().
func _place(item: Node, xform: Transform3D) -> void:
	PhysicsServer3D.body_set_state(item.get_rid(),
		PhysicsServer3D.BODY_STATE_TRANSFORM, xform)
	item.global_transform = xform


func _release(item: Node) -> void:
	if not item.has_meta("mp_copy"):
		return
	item.remove_meta("mp_copy")
	if item.has_meta(PropManager.META_CLAIM) \
	and int(item.get_meta(PropManager.META_CLAIM)) == get_instance_id():
		item.remove_meta(PropManager.META_CLAIM)
	item.set_physics_process(true)
	# an item in a hand is carried as a kinematic body: forcing it static here
	# undid what the game had just set and left it sweeping through things
	if item.is_held():
		item.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	else:
		item.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
		item.freeze = false


func _mine(id: int) -> bool:
	return int(_owner.get(id, 0)) == _me()


# Host only. A guest's item is sitting in a machine's mouth. The machines run
# here, and they will not touch a frozen copy that belongs to somebody else, so
# take it over first: once it is ours and unfrozen the machine swallows it on
# its own tick, and the delete goes out like any other. This is how hay a guest
# loads finally counts, and it still only counts once, here.
func host_take(item: Variant) -> bool:
	if not mp.is_host or item == null or not is_instance_valid(item):
		return false
	var n := item as Node
	if n == null or not n.has_meta("mp_id"):
		return false
	var id := int(n.get_meta("mp_id"))
	# theirs to carry for as long as they are carrying it
	if _mine(id) or bool(_held.get(id, false)):
		return false
	_iev(id, "handover", n, " to=host via=mouth")
	_owner[id] = _me()
	_goal.erase(id)
	_held.erase(id)
	_hash.erase(id)
	_release(n)
	mp._rx_prop_claim.rpc(id)
	return true


# ------------------------------------------------------------------ local events

func _on_added(item: Node) -> void:
	if _busy or not _ready_map or item.has_meta("mp_id"):
		return
	var id := _new_id()
	_adopt(item, id, _me())
	_sent[id] = item.global_transform
	var st := _state_of(item)
	_hash[id] = st.hash()
	if _log:
		print("[MPPROPS] made %s id=%d at %v" % [item.item_id, id, item.global_position])
	mp._rx_prop_add.rpc(id, String(item.item_id), item.global_transform, st)
	# Belt contents are records, not items: taking one off a belt makes a new item
	# in our hand, and only our own belt lost the record. The host's still had it
	# and its next list put it back here, so items could be copied for ever.
	# (2026-11-14, F57) Only the record we aimed at: an item of its kind, made where it was (the
	# game spawns a picked record at the record's pose). Any other item made in those 150 ms (a
	# machine's brick landing here, a host item arriving) counted as "taken" too, and the host
	# took the aimed record off its belt: a player's hay wads vanished (4 of 6 reached the stand).
	var took := false
	if not mp.is_host and Time.get_ticks_msec() - _aim_at <= AIM_MS and item is Node3D:
		var k := _kind_of_item(String(item.item_id), item.to_state())
		var aim_at: Variant = _aim.get("at")
		took = k != NOT_A_RIDE and k == int(_aim.get("kind", NOT_A_RIDE)) and aim_at is Vector3 \
			and (item as Node3D).global_position.distance_to(aim_at) <= AIM_NEAR_M
	_iev(id, "spawn", item, (" from=belt seq=%d" % int(_aim.get("seq", -1))) if took else "")
	if took:
		mp.trace.act("ev=belt_take id=%d kind=%s seq=%d" % [_iid(id), item.item_id, int(_aim.get("seq", -1))])
		mp.trace.bump("belt_take")
		var hseq := _host_seq(_aim)
		mp._rx_belt_take.rpc_id(1, id, int(_aim["kind"]), _aim["at"], hseq)
		var bs: Variant = mp.world_sync.get("belts_sync") if mp.world_sync != null else null
		if bs != null and bs.has_method("note_taken"):
			bs.call("note_taken", hseq)
		_aim_at = -100000


# The host's number for the record we took (our belt may have it under its own, see
# mp_belts.host_seq_for); -1 when we do not know it.
func _host_seq(aim: Dictionary) -> int:
	var seq := int(aim.get("seq", -1))
	var path: Variant = aim.get("path")
	var bs: Variant = mp.world_sync.get("belts_sync") if mp.world_sync != null else null
	if seq < 0 or path == null or not is_instance_valid(path) or bs == null or not bs.has_method("host_seq_for"):
		return seq
	return int(bs.call("host_seq_for", path, seq))


const AIM_MS := 150     # in time, not frames: a fast PC has many frames in a click
const AIM_NEAR_M := 1.0 # a picked record appears where it was; in AIM_MS a belt moves it ~0.3 m
const NOT_A_RIDE := -1  # what the game answers for things that never ride as records
var _aim := {}          # guest: the record under our crosshair: {kind, at}
var _aim_at := -100000  # ...and when we last saw it

# Guest only, every frame. What the game itself would pick up right now. It is
# gone from our belt by the time the new item appears, so look before that.
func _watch_aim() -> void:
	var carry: Variant = _carry_tool()
	if carry == null or not carry.has_method("_record_under_crosshair"):
		return
	# Out of the world it asks for a world that is not there, and the engine falls over: this
	# was a guest's crash (three errors from here, then signal 11).
	if not is_instance_valid(carry) or not (carry as Node).is_inside_tree():
		return
	var under: Dictionary = carry.call("_record_under_crosshair")
	if under.is_empty():
		return
	var path: Variant = under.get("path")
	var rec: Dictionary = under.get("record", {})
	if path == null or not is_instance_valid(path) or rec.is_empty():
		return
	var where: Dictionary = path.record_where(int(rec.get("seq", -1)))
	if where.is_empty():
		return
	_aim = {"kind": int(rec.get("kind", NOT_A_RIDE)), "at": (where["pose"] as Transform3D).origin,
		"seq": int(rec.get("seq", -1)), "path": path}
	_aim_at = Time.get_ticks_msec()


# Host only. The same record on our belt: it has moved on a little since the
# guest saw it, so look around that spot, nearest first, for one of its kind.
# None left means a machine had it first, and the guest's item is one too many.
const TAKE_RINGS := [0.0, 0.2, 0.4, 0.7, 1.0, 1.4]
const TAKE_NEAR := 0.25

func on_belt_take(id: int, kind: int, at: Vector3, seq := -1) -> void:
	# (1.2.19) the very record, by its number, wherever it has got to: the guest's belt
	# can show it up to a belt or so from ours, and the search around the spot then took
	# a neighbour of the same kind (the guest's belt kept the wrong one) or nothing at all
	# (the guest's item was deleted while held: "nothing left")
	if seq >= 0:
		var w: Dictionary = _record_where(seq)
		var wp: Variant = w.get("path")
		if wp != null and is_instance_valid(wp) and int(wp.run.kind_of(int(w["row"]))) == kind:
			# take_record_at can refuse a row (returns {}), and the item would be twice:
			# in the guest's hands and still on our belt. Then the search below tries.
			if not (wp.take_record_at(int(w["row"])) as Dictionary).is_empty():
				mp.trace.note("belt take: kind %d seq %d (by number)" % [kind, seq])
				mp.trace.bump("take_by_number")
				return
			mp.trace.bump("take_refused")
	var belt: Node = null
	for b in BeltPath._live:
		if is_instance_valid(b) and b.is_inside_tree():
			belt = b  # record_in looks through every belt, whichever we ask
			break
	if belt != null:
		for r in TAKE_RINGS:
			for i in (1 if float(r) == 0.0 else 8):
				var spot := at + Vector3(cos(i * TAU / 8.0), 0.0, sin(i * TAU / 8.0)) * float(r)
				var hit: Dictionary = belt.record_in(spot, TAKE_NEAR)
				if hit.is_empty() or int((hit["record"] as Dictionary).get("kind", NOT_A_RIDE)) != kind:
					continue
				if (hit["path"].take_record_at(int(hit["row"])) as Dictionary).is_empty():
					mp.trace.bump("take_refused")
					continue
				mp.trace.note("belt take: kind %d seq %d" % [kind, int((hit["record"] as Dictionary).get("seq", -1))])
				mp.trace.bump("take_nearby")
				return
	mp.trace.note("belt take: nothing left of kind %d" % kind)
	mp.trace.bump("take_none")
	mp._rx_prop_gone.rpc(id)
	on_gone(id)


# The host says this item does not exist any more, in our hands or not.
func on_gone(id: int) -> void:
	var it: Variant = _by_id.get(id)
	_forget(id)
	if it != null and is_instance_valid(it):
		_remove_copy(it)


# Out of our hands first: the carry code goes on asking where the thing it holds is, and an
# item that has left the world gives it nothing to work with.
func _remove_copy(it: Node) -> void:
	if it.has_method("is_held") and it.is_held():
		_let_go(it)
	_forcetron_lets_go(it)
	_busy = true
	props.remove(it)
	_busy = false


# The Forcetron keeps hold of what it pulled and asks where each is every frame. A message from
# the host arrives before that in the same frame, so it asked about an item already out of the
# world and logged an error. It sorts itself out a frame later.
func _forcetron_lets_go(it: Node) -> void:
	var pl: Variant = world.get("player") if world != null else null
	if pl == null or not is_instance_valid(pl) or not ("forcetron" in pl):
		return
	var tool: Variant = pl.get("forcetron")
	if tool == null or not is_instance_valid(tool) or not tool.has_method("_lose"):
		return
	var pulled: Variant = tool.get("_targets")
	if pulled is Array:
		var at: int = (pulled as Array).find(it)
		if at >= 0:
			tool.call("_lose", at)


func _on_removed(item: Node) -> void:
	_carry_forgets(item)
	if not item.has_meta("mp_id"):
		return
	var id := int(item.get_meta("mp_id"))
	var mine := _mine(id)
	var belted := bool(_belted.get(id, false))
	_belted.erase(id)
	_forget(id)
	if _busy:
		return
	if _log:
		print("[MPPROPS] lost %s id=%d mine=%s" % [item.item_id, id, mine])
	if mine and _boarded.has(id):
		# our belt took it, but the host's belts are the real ones: hand it over
		# there, or the host's next belt snapshot wipes it and the hay is gone
		_flush_builds_first()
		mp._rx_prop_board.rpc_id(1, id, _boarded[id])
		_boarded.erase(id)
		_handed[id] = Time.get_ticks_msec()
		_iev(id, "handover", item, " to=host via=belt")
	elif mine and belted and mp.is_host:
		mp._rx_prop_boarded.rpc(PackedInt64Array([id]))
		_gone(id, item, "belt_eaten")
	elif mine:
		var why := _why_gone(item)
		_gone(id, item, why)
		if mp.is_host:
			mp._rx_prop_del_why.rpc(PackedInt64Array([id]), why)
		else:
			mp._rx_prop_del.rpc(PackedInt64Array([id]))
	elif mp.is_host or _taken_by_me(item) or _sold_by_me(item):
		_gone(id, item, _why_gone(item))
		# the host's world is the one that counts: something here used up a
		# guest's item (the delivery truck loads whatever lands in its bed), so
		# it is gone for everybody. Asking for it back put it in the truck again
		# and the same bale was counted over and over.
		#
		# On a guest, a copy that vanishes right in front of our own player was
		# taken by us: a tool going into the hotbar, an item sold at the stand.
		# Asking for it back (the old behaviour) made the host send it again,
		# so it lay on the floor once more and could be picked up and sold
		# over and over (GitHub #21, tool duplication). Claim it and delete it
		# for everyone instead. The shop takes a spare one from anywhere in the yard,
		# so that one need not be near us at all (see _sold_by_me).
		mp._rx_prop_claim.rpc(id)
		mp._rx_prop_del.rpc(PackedInt64Array([id]))
	else:
		# a local machine ate a copy far from us: ask for it back
		_want[id] = 0


# A belt laid or taken down here goes out on the next build tick, but what it does to
# the items goes out at once. The host then put them where it had no belt yet, or on one
# about to go, and they fell on its floor. The belt first.
func _flush_builds_first() -> void:
	var ws: Variant = mp.world_sync if mp != null else null
	if ws != null and is_instance_valid(ws):
		ws.flush_builds_now()


# Selling a spare bucket at the shop takes one from anywhere in the yard. Far from us it
# looked like a machine had eaten our copy, so we asked the host for it back, it came
# back, and the same bucket could be sold again and again for money.
func _sold_by_me(item: Node) -> bool:
	var menu: Variant = _open_shop()
	if menu == null:
		return false
	var rows: Variant = menu.get("_sell_buttons")
	return not (rows is Dictionary) or (rows as Dictionary).has(String(item.item_id))


func _open_shop() -> Variant:
	var pl: Variant = world.get("player") if world != null and is_instance_valid(world) else null
	var menu: Variant = pl.get("shop") if pl != null and is_instance_valid(pl) else null
	if menu == null or not is_instance_valid(menu) or not menu.has_method("is_open") or not menu.call("is_open"):
		return null
	return menu


# The shop can also bring your things to your feet from anywhere in the yard. A copy
# somebody else owns then moved on this PC only: it stood at our feet here and where it
# was on the other side. Something that jumps while our shop is open and nobody told us
# to move it is ours now, and the next move tick tells everybody where it is.
var _fetch_seen := {}

func _watch_fetch() -> void:
	if _open_shop() == null:
		_fetch_seen.clear()
		return
	for id in _by_id:
		if _mine(id) or bool(_held.get(id, false)) or _goal.has(id):
			continue
		var it: Variant = _by_id[id]
		if it == null or not is_instance_valid(it) or not it.is_inside_tree():
			continue
		var at: Vector3 = it.global_position
		var was: Variant = _fetch_seen.get(id)
		_fetch_seen[id] = at
		if was != null and (was as Vector3).distance_squared_to(at) > 1.0:
			_owner[id] = _me()
			_hash.erase(id)
			_sent.erase(id)
			_release(it)
			mp._rx_prop_claim.rpc(id)


const TAKE_REACH := 4.5  # metres from our eyes: hand reach plus a little slack

func _taken_by_me(item: Node) -> bool:
	var pl: Variant = world.get("player") if world != null and is_instance_valid(world) else null
	if pl == null or not is_instance_valid(pl) or not (pl as Node3D).is_inside_tree():
		return false
	var at: Vector3 = (item as Node3D).global_position if (item as Node3D).is_inside_tree() \
		else (item as Node3D).position
	var eye: Vector3 = pl.eye_position() if pl.has_method("eye_position") else (pl as Node3D).global_position
	return at.distance_to(eye) <= TAKE_REACH


# Taking an item somebody else owns makes it ours, so we are the one moving it.
func _on_carry_changed(item: Variant) -> void:
	# picked up or let go: tell the others now, not in a second
	_state_t = STATE_TICK
	if item == null or not is_instance_valid(item) or not item.has_meta("mp_id"):
		return
	var id := int(item.get_meta("mp_id"))
	if item.is_held():
		_iev(id, "picked", item)
	if _mine(id):
		return
	# (1.2.19) only a real pick-up: the game says "changed" a moment after a drop too, and
	# taken as a pick-up that claimed a wheelbarrow straight back from the dump hatch
	# with its old load (the hay was there twice)
	if not item.is_held() or _hatch_recent(id):
		return
	_note_fill(id, item)
	_owner[id] = _me()
	_goal.erase(id)
	_held.erase(id)
	_hash.erase(id)
	_release(item)
	mp._rx_prop_claim.rpc(id)


# Guest only. A belt says what it caught just before it takes the item out of
# the prop list, so note ours on the way past and _on_removed knows why it went.
func _watch_belts() -> void:
	for belt in BeltPath._live:
		if is_instance_valid(belt) and not belt.caught.is_connected(_on_belt_caught):
			belt.caught.connect(_on_belt_caught)
		# (log v2) an item's row crossing a seam: logged for rows that were items lately
		# (marked with our id: a new session's sync node connects again; the old connection
		# went with the old node)
		if is_instance_valid(belt) and int(belt.get_meta("np_rows_watch", 0)) != get_instance_id():
			belt.set_meta("np_rows_watch", get_instance_id())
			belt.caught_record.connect(_on_row_caught.bind(belt))
			# (belt replay) host: which row an item became, for the guests (mp_belts.note_boarded)
			if mp.is_host:
				belt.caught.connect(_on_caught_at.bind(belt))


func _on_belt_caught(rb: Node) -> void:
	if rb == null or not is_instance_valid(rb) or not rb.has_meta("mp_id"):
		return
	var id := int(rb.get_meta("mp_id"))
	_board_event(id, rb as Node3D)
	if mp.is_host:
		# the belt made it a row; the game takes the item out of the list right after, in the
		# same frame (a hay tuft stays an item riding the belt: the mark goes at frame end)
		_belted[id] = true
		_unbelt.call_deferred(id)
		return
	if _mine(id):
		_boarded[id] = (rb as Node3D).global_transform
		_hand_rider.call_deferred(rb)


func _unbelt(id: int) -> void:
	_belted.erase(id)


# Host: the belt's caught comes right after its core boarded the row (run.last_seq is it).
func _on_caught_at(rb: Node, belt: Node) -> void:
	if not mp.is_host or rb == null or not is_instance_valid(rb) or not rb.has_meta("mp_id"):
		return
	var bs: Variant = mp.world_sync.get("belts_sync") if mp.world_sync != null else null
	if bs != null and is_instance_valid(bs) and bs.has_method("note_boarded"):
		bs.call("note_boarded", int(rb.get_meta("mp_id")), belt)


# ---------------------------------------------------------------- the item log (log v2)
# "item ev=board id=1234 kind=hay_wad seq=881 belt=b12 s=4.02 role=guest", into
# mp_trace's items_events log. Numbers and the game's item names only. The id is ours made
# short (the full one is too long for the log's blanking, which takes any 15+ digit number
# for a Steam id): the host's own items keep their number, a guest's get its peer's slot
# (1-8) in front of it, so host and guest logs name an item the same way.
func _iid(id: int) -> int:
	var maker := id >> 31
	return (id & 0x7FFFFFFF) + (0 if maker == 1 else 1000000000 * (1 + maker % 8))


func _iev(id: int, ev: String, it: Variant, extra := "", last := false) -> void:
	if mp == null or mp.trace == null:
		return
	var kind := String(it.get("item_id")) if it != null and is_instance_valid(it) and it.get("item_id") != null else "?"
	mp.trace.item(str(_iid(id)), "item ev=%s id=%d kind=%s%s role=%s" % [ev, _iid(id), kind, extra,
		"host" if mp.is_host else "guest"], last)


# An item left: the log line (its last), and the tick line's tally (del_belt, del_machine...).
const DEL_TALLY := {"belt_eaten": "del_belt"}

func _gone(id: int, it: Variant, why: String) -> void:
	_iev(id, "delete", it, " why=%s" % why, true)
	mp.trace.bump(str(DEL_TALLY.get(why, "del_" + why)))
	_rows_of.erase(id)


# Why the game took one of our items out: sold at our stand, taken into our own player's
# hands or hotbar, folded away (the floor clean-up and the heaps: PropFold, made just before
# the remove), next to a machine, or none of those.
func _why_gone(item: Node) -> String:
	if _sold_by_me(item):
		return "sold"
	if _taken_by_me(item):
		return "picked"
	if _folded(item):
		return "despawn"
	if item is Node3D and _near_machine(_where(item as Node3D)):
		return "machine"
	return "other"


# (1.2.21) Since the game update of 13 Nov 2026 an item can already be out of the scene
# when its removal is reported. Its global_position then raised an engine error with a full
# backtrace (36 in two minutes on a big yard, a hitch each). Items hang straight off the
# prop manager, so its transform and the item's own position still say where it stood.
func _where(item: Node3D) -> Vector3:
	if item.is_inside_tree():
		return item.global_position
	if props != null and is_instance_valid(props) and props is Node3D and (props as Node3D).is_inside_tree():
		return (props as Node3D).global_transform * item.position
	return item.position


func _folded(item: Node) -> bool:
	if props == null or not is_instance_valid(props) or not (item is Node3D):
		return false
	var n: int = props.get_child_count()
	if n == 0:
		return false
	var c: Node = props.get_child(n - 1)
	return c is Node3D and String(c.name).begins_with("Fold") and (c as Node3D).is_inside_tree() \
		and (c as Node3D).global_position.distance_to(_where(item as Node3D)) < 0.05


const MACHINE_NEAR := 4.0

func _near_machine(at: Vector3) -> bool:
	var ms: Variant = mp.world_sync.get("machines_sync") if mp.world_sync != null else null
	if ms == null or not is_instance_valid(ms):
		return false
	var nodes: Dictionary = ms.get("_nodes")
	for k in nodes:
		var m: Variant = nodes[k]
		if m is Node3D and is_instance_valid(m) and (m as Node3D).is_inside_tree() \
		and (m as Node3D).global_position.distance_to(at) <= MACHINE_NEAR:
			return true
	return false


# A belt took an item: which belt, which row (both sides; on the host the row is ours to
# name, on a guest it is our own copy's until the host's word renames it).
var _rows_of := {}   # mp id -> seq of its row
var _items_of := {}  # seq -> [mp id, kind, msec]: rows that were items, for the seam lines
const ROW_WATCH_MS := 120000

func _board_event(id: int, rb: Node3D) -> void:
	if rb == null or not is_instance_valid(rb):
		return
	var hit: Dictionary = _record_in(rb.global_position, 0.8)
	var seq := -1
	var extra := ""
	if not hit.is_empty() and is_instance_valid(hit["path"]):
		var path: Node = hit["path"]
		seq = int((hit["record"] as Dictionary).get("seq", -1))
		extra = " seq=%d belt=%s s=%.2f" % [seq, _belt_id(path), float(path.run.s_of(int(hit["row"])))]
	_iev(id, "board", rb, extra)
	if seq >= 0:
		_rows_of[id] = seq
		if _items_of.size() > 512:
			var now := Time.get_ticks_msec()
			for q in _items_of.keys():
				if now - int(_items_of[q][2]) > ROW_WATCH_MS:
					_items_of.erase(q)
		_items_of[seq] = [id, String(rb.get("item_id")) if rb.get("item_id") != null else "?", Time.get_ticks_msec()]


func _on_row_caught(seq: int, _kind: int, _strands: int, belt: Node) -> void:
	var w: Variant = _items_of.get(seq)
	if w == null:
		return
	if Time.get_ticks_msec() - int(w[2]) > ROW_WATCH_MS:
		_items_of.erase(seq)
		return
	if mp == null or mp.trace == null:
		return
	var id := int(w[0])
	mp.trace.item(str(_iid(id)), "item ev=caught id=%d kind=%s seq=%d belt=%s role=%s" % [_iid(id), w[1], seq,
		_belt_id(belt), "host" if mp.is_host else "guest"])


func _belt_id(path: Node) -> String:
	var bs: Variant = mp.world_sync.get("belts_sync") if mp.world_sync != null else null
	if bs != null and is_instance_valid(bs) and bs.has_method("belt_id"):
		return str(bs.call("belt_id", path))
	return "b?"


# Guest only. Most items leave the prop list when a belt takes them, and
# _on_removed hands them to the host. A hay tuft stays an item riding the belt,
# so it never left: it rode our belt only, which just mirrors the host's, and
# at a splitter it went off the path and back to the start over and over. Hand
# it over now, where it got on, and drop it from our belt: the host's belt
# carries it from there like the host's own.
func _hand_rider(rb: Node) -> void:
	if rb == null or not is_instance_valid(rb) or not rb.is_inside_tree():
		return
	var id := int(rb.get_meta("mp_id", 0))
	if not _mine(id) or not _is_rider(rb as RigidBody3D):
		return
	var xf: Transform3D = _boarded.get(id, (rb as Node3D).global_transform)
	_boarded.erase(id)
	_release_rider(rb as RigidBody3D)
	_owner[id] = 1
	_goal.erase(id)
	_hash.erase(id)
	_puppet(rb)
	_place(rb, xf)
	_flush_builds_first()
	mp._rx_prop_board.rpc_id(1, id, xf)


# Host only. The guest's belt took one of the guest's items at xf. Take our copy
# over, put it there and let it go: our belt catches it on its next tick and it
# reaches everyone in the belt snapshot, the way the host's own hay does.
func on_board(sender: int, id: int, xf: Transform3D) -> void:
	var it: Variant = _by_id.get(id)
	if it == null or not is_instance_valid(it) or int(_owner.get(id, 0)) != sender:
		return
	# it just left their hands, whatever the last state said
	_held.erase(id)
	if not host_take(it):
		return
	_place(it, xf)
	_sent[id] = xf  # the guest has just forgotten it: a move would make it ask again
	(it as RigidBody3D).linear_velocity = Vector3.ZERO
	(it as RigidBody3D).sleeping = false


# Hay the other player dropped: the little piles a spade leaves (HayTuft) and
# wads. Our copy of one is frozen and claimed, and the spade passes over a
# frozen or claimed wad, so only the player who made a pile could scoop it up
# again. When we dig with a spade and such a copy lies in reach in front of us,
# take it over first, the way picking up an item does: then it is ours, loose,
# and the spade takes it like any other. Picking one up by hand already claims
# it.
const CLAIM_REACH := 2.4   # the spade's gather reach

func _claim_in_reach() -> void:
	var pl: Variant = world.get("player")
	if pl == null or not is_instance_valid(pl):
		return
	var tool := int(pl.get("current_tool"))
	if tool != _tool("SHOVEL") and tool != _tool("PITCHFORK") and tool != _tool("BROOM"):
		return
	if not Input.is_action_pressed("primary"):
		return
	var eye: Vector3 = pl.eye_position()
	var look: Vector3 = pl.look_direction()
	for id in _by_id.keys():
		if _mine(id) or bool(_held.get(id, false)):
			continue
		var it: Variant = _by_id[id]
		if it == null or not is_instance_valid(it) or not _is_a(it, "HayWad") or not (it as Node3D).is_inside_tree():
			continue
		# riding somebody's belt is not lying on the floor: taking it froze it
		# on the host's belt
		if _is_rider(it as RigidBody3D):
			continue
		var to: Vector3 = (it as Node3D).global_position - eye
		if to.length() > CLAIM_REACH or to.normalized().dot(look) < 0.6:
			continue
		_owner[id] = _me()
		_goal.erase(id)
		_hash.erase(id)
		_release(it)
		mp._rx_prop_claim.rpc(id)


# A container changes hands with its fill as we last heard it, which can be up to
# a second old. The old owner sends what it really holds; put the difference right.
var _fill_at := {}  # mp id -> what a container held as we took it

func _note_fill(id: int, it: Node) -> void:
	if _is_a(it, "HayContainer"):
		_fill_at[id] = int(it.get("stored"))


func on_fill(id: int, stored: int) -> void:
	var it: Variant = _by_id.get(id)
	if it == null or not is_instance_valid(it) or not _mine(id) or not _fill_at.has(id):
		return
	var missed: int = stored - int(_fill_at[id])
	_fill_at.erase(id)
	if missed != 0:
		it.from_state({"stored": maxi(0, int(it.get("stored")) + missed)})


# A bucket catches straw in its own physics tick, and that tick is off on a copy
# somebody else owns. Straw is real only on the side that pours it, so a bucket on
# the floor caught nothing unless the pourer happened to own it. Take over the
# bucket we are pouring into; a guest hands it back to the host afterwards.
const CATCH_REACH := 3.0
const CATCH_GIVE_BACK_MS := 3000
const CATCH_RETAKE_MS := 1000

func _catch_tick() -> void:
	var pl: Variant = world.get("player")
	if pl == null or not is_instance_valid(pl):
		return
	var now := Time.get_ticks_msec()
	var carry: Variant = _carry_tool()
	var held: Variant = carry.call("held") if carry != null else null
	if not is_instance_valid(held):
		held = null
	# Only what can really pour: anything in the hands and a mouse button took a
	# bucket straight back from the host the moment it was put down.
	var tool := int(pl.get("current_tool"))
	var hand: Variant = pl.get("hand")
	var in_hand: bool = hand != null and is_instance_valid(hand) and hand.has_method("is_holding") \
		and bool(hand.call("is_holding"))
	var blade: bool = tool == _tool("SHOVEL") or tool == _tool("PITCHFORK")
	var has_hay: bool = _is_a(held, "HayContainer") or in_hand or blade
	# the right button tips a held bucket, and a spade empties its blade with it
	var pouring: bool = has_hay and pl.has_method("pour_intent") and bool(pl.call("pour_intent"))
	var working: bool = (blade or in_hand) and Input.is_action_pressed("primary")
	if pouring or working:
		var eye: Vector3 = pl.eye_position()
		var look: Vector3 = pl.look_direction()
		var cone := 0.0 if pouring else 0.5
		for id in _by_id.keys():
			var it: Variant = _by_id[id]
			if it == null or not is_instance_valid(it) or not _is_a(it, "HayContainer") or it == held:
				continue
			if bool(_held.get(id, false)) or it.is_held() or it.get("docked_in") != null \
			or not (it as Node3D).is_inside_tree() or _is_rider(it as RigidBody3D):
				continue
			var to: Vector3 = (it as Node3D).global_position - eye
			if to.length() > CATCH_REACH or to.normalized().dot(look) < cone:
				continue
			_poured[id] = now
			if not _mine(id) and now - int(_taken_at.get(id, -100000)) >= CATCH_RETAKE_MS:
				_take_container(id, it)
	for id in _poured.keys():
		if now - int(_poured[id]) < CATCH_GIVE_BACK_MS:
			continue
		_poured.erase(id)
		var it: Variant = _by_id.get(id)
		if not mp.is_host and _mine(id) and it != null and is_instance_valid(it) \
		and not it.is_held() and (it as Node3D).is_inside_tree():
			_give_to_host(id, it as RigidBody3D)


func _take_container(id: int, it: Node) -> void:
	_note_fill(id, it)
	_owner[id] = _me()
	_goal.erase(id)
	_hash.erase(id)
	_release(it)
	mp._rx_prop_claim.rpc(id)


func _state_of(item: Node) -> Dictionary:
	var st: Dictionary = item.to_state()
	if item.holds_needle():
		st["needle"] = item.needle_index
	# the game's from_state only reads its own keys, so older versions skip this
	if item.is_held():
		st["held"] = true
	return st


# ------------------------------------------------------------------ ticks

# stopwatch: anything over 4 ms in one frame goes into mp_trace.log by name
func _process(delta: float) -> void:
	if world == null or not is_instance_valid(world) or not (world as Node).is_inside_tree():
		return
	var t0 := Time.get_ticks_usec()
	_process_inner(delta)
	if mp != null and is_instance_valid(mp):
		mp.perf("props", Time.get_ticks_usec() - t0)


func _process_inner(delta: float) -> void:
	_smooth(delta)
	_settle_sinking(delta)
	_rp_wait_tick()
	_held_t += delta
	if _held_t >= HELD_TICK:
		_held_t = 0.0
		_hide_held_tools()
		_hand_barrows()
	if mp == null or not mp.active() or multiplayer.multiplayer_peer == null:
		return
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	if not _ready_map:
		return
	if mp.is_host:
		_keep_t += delta
		if _keep_t >= KEEP_TICK:
			_keep_t = 0.0
			_keep_near_players()
	_belt_t += delta
	if _belt_t >= 0.5:
		_belt_t = 0.0
		_watch_belts()
	if not mp.is_host:
		_lift_floor_cap()
		_watch_aim()
	_move_t += delta
	if _move_t >= MOVE_TICK:
		_move_t = 0.0
		_move_tick()
		_claim_in_reach()
		_catch_tick()
	_state_t += delta
	if _state_t >= STATE_TICK:
		_state_t = 0.0
		_state_tick()
	_census_t += delta
	if _census_t >= CENSUS_TICK:
		_census_t = 0.0
		_census_tick()


# A tool somebody else is carrying floats in front of their first-person view,
# but their farmer already draws it in its hand, so hide that copy while it's
# up there. Tools lying around, and every other item, stay visible.
func _hide_held_tools() -> void:
	var ws: Variant = mp.world_sync if mp != null else null
	var avatars: Dictionary = ws.avatars if ws != null and is_instance_valid(ws) else {}
	for id in _by_id:
		var it: Variant = _by_id[id]
		if it == null or not is_instance_valid(it):
			continue
		var tool: int = TOOL_ITEMS.get(String(it.item_id), 0)
		if tool == 0:
			continue
		var hide := false
		if not _mine(id):
			var av: Variant = avatars.get(int(_owner.get(id, 0)))
			if av != null and is_instance_valid(av) and int(av.get("_tool")) == tool \
			and it.is_inside_tree() and (av as Node3D).is_inside_tree():
				var off: Vector3 = it.global_position - av.global_position
				hide = off.y > 0.5 and Vector2(off.x, off.z).length() < 2.0
		if hide and not _hidden.has(id):
			# out of sight and out of everyone's aim: an invisible tool that is
			# still solid catches the ray meant for whatever is behind it, and
			# then nobody can pick anything up
			_hidden[id] = it.collision_layer
			it.collision_layer = 0
			it.visible = false
		elif not hide and _hidden.has(id):
			it.collision_layer = int(_hidden[id])
			_hidden.erase(id)
			it.visible = true


# A wheelbarrow somebody is pushing is drawn by their farmer, between its
# hands, instead of where their first-person view has it. When they let go it
# eases back to where the owner says it is.
func _hand_barrows() -> void:
	var ws: Variant = mp.world_sync if mp != null else null
	var avatars: Dictionary = ws.avatars if ws != null and is_instance_valid(ws) else {}
	var want := {}  # mp id -> avatar
	for pid in avatars:
		var av: Variant = avatars[pid]
		if av == null or not is_instance_valid(av) or not av.has_method("push_item"):
			continue
		for it in held_by(int(pid)):
			if PUSHED_ITEMS.has(String(it.item_id)):
				want[int(it.get_meta("mp_id"))] = av
	for id in _pushed.keys():
		var av: Variant = _pushed[id]
		if is_instance_valid(av) and want.get(id) == av:
			continue
		_pushed.erase(id)
		# unless it's taking another one below
		if is_instance_valid(av) and not want.values().has(av):
			av.push_item(null)
	for id in want:
		if _pushed.has(id):
			continue
		var it: Node = _by_id[id]
		# keep where it really is, for when they let go
		if not _goal.has(id) and it.is_inside_tree():
			_goal[id] = it.global_transform
		_pushed[id] = want[id]
		want[id].push_item(it)


# Items a peer owns and says they're carrying (see _state_of).
func held_by(pid: int) -> Array:
	var out: Array = []
	for id in _held:
		var it: Variant = _by_id.get(id)
		if int(_owner.get(id, 0)) == pid and it != null and is_instance_valid(it):
			out.append(it)
	return out


# Remote copies ease towards the last position we heard about instead of
# jumping ten times a second.
func _smooth(delta: float) -> void:
	if _goal.is_empty():
		return
	var f := minf(1.0, delta * SMOOTH)
	var done: Array = []
	for id in _goal:
		var it: Variant = _by_id.get(id)
		if it == null or not is_instance_valid(it):
			done.append(id)
			continue
		if _pushed.has(id):
			# a farmer is holding it, the goal waits for them to let go
			continue
		if not it.is_inside_tree():
			continue  # mid-reparent: it would read as the origin
		var want: Transform3D = _goal[id]
		var step: Transform3D = it.global_transform.interpolate_with(want, f)
		_place(it, step)
		if step.origin.distance_to(want.origin) < 0.002:
			_place(it, want)
			done.append(id)
	for id in done:
		_goal.erase(id)


# Our player is holding a copy somebody else owns, but the game picked it up
# some way that never fired carry_changed (hay and paper in the hands, for
# one). Then nothing claimed it: we moved it on our screen only and nobody
# else saw it, so the hay never reached a machine or a contract (GitHub #21).
# Claim anything our own player holds, whichever way it got into the hands.
func _claim_held_copies() -> void:
	for id in _by_id:
		if _mine(id) or bool(_held.get(id, false)) or _hatch_recent(id):
			continue  # ours already, or its owner says they are carrying it
		var it: Variant = _by_id[id]
		if it == null or not is_instance_valid(it) or not it.is_held():
			continue
		_owner[id] = _me()
		_goal.erase(id)
		_hash.erase(id)
		_release(it)
		_carrying[id] = true
		mp._rx_prop_claim.rpc(id)
		_state_t = STATE_TICK


# Guest only. Remember what we carry; once it leaves our hands (dropped or
# thrown) hand it to the host with its speed, so it lands in the host's world
# where machines, belts and the truck actually run. Before, a guest's dropped
# hay stayed a frozen copy on the host that nothing would take.
var _carrying := {}  # mp id -> true while our player holds it

func _hand_drops() -> void:
	for id in _by_id:
		var it: Variant = _by_id[id]
		if it == null or not is_instance_valid(it) or not _mine(id):
			continue
		if it.is_held():
			_carrying[id] = true
	for id in _carrying.keys():
		var it: Variant = _by_id.get(id)
		if it == null or not is_instance_valid(it) or not _mine(id):
			_carrying.erase(id)
			continue
		if it.is_held() or _in_forcetron(it):
			continue
		_carrying.erase(id)
		var thrown: bool = (it as RigidBody3D).linear_velocity.length() > 2.5
		mp.trace.act("ev=%s id=%d kind=%s" % ["throw" if thrown else "drop", _iid(id), it.item_id])
		mp.trace.bump("throws" if thrown else "drops")
		if mp.is_host or not (it as Node3D).is_inside_tree() or _boarded.has(id) \
		or _is_rider(it as RigidBody3D):
			continue
		if _container_near(it as Node3D):
			_give_to_host(id, it as RigidBody3D)
		else:
			_flying[id] = [Time.get_ticks_msec(), -1]
	_land_flights()


# (1.2.19) A thrown or dropped item used to go to the host the moment it left our hands,
# so its whole flight on our screen was the host's moves played back a round trip late:
# it hung, then caught up ("throwing feels laggy"). Now our own physics flies it, as in a
# game alone, and the host's copy follows our moves; it goes to the host once it has
# landed (or after FLY_MAX_MS). Whatever takes it on the way still works: our belt hands
# it over (_on_belt_caught), the host takes it in a machine's mouth (host_take), and near
# a bucket or barrow it goes to the host at once as before, so a lob into one counts there.
const FLY_MAX_MS := 4000
const LANDED_V := 0.25     # m/s
const LANDED_MS := 250     # this long that slow: landed
const CONTAINER_NEAR := 3.0
var _flying := {}          # mp id -> [msec let go, msec it first looked landed or -1]

func _land_flights() -> void:
	var now := Time.get_ticks_msec()
	for id in _flying.keys():
		var it: Variant = _by_id.get(id)
		if it == null or not is_instance_valid(it) or not _mine(id) or it.is_held() \
		or not (it as Node3D).is_inside_tree() or _boarded.has(id) or _is_rider(it as RigidBody3D):
			_flying.erase(id)
			continue
		var rb := it as RigidBody3D
		var f: Array = _flying[id]
		var still: bool = rb.sleeping or rb.freeze or (rb.linear_velocity.length() < LANDED_V \
			and rb.angular_velocity.length() < 1.0)
		if not still:
			f[1] = -1
		elif int(f[1]) < 0:
			f[1] = now
		if (still and now - int(f[1]) >= LANDED_MS) or now - int(f[0]) >= FLY_MAX_MS \
		or _container_near(it as Node3D):
			_flying.erase(id)
			_give_to_host(id, rb)


func _container_near(n: Node3D) -> bool:
	var at := n.global_position
	for cid in _by_id:
		var c: Variant = _by_id[cid]
		if c != n and is_instance_valid(c) and _is_a(c, "HayContainer") and (c as Node3D).is_inside_tree() \
		and (c as Node3D).global_position.distance_to(at) <= CONTAINER_NEAR:
			return true
	return false


func _give_to_host(id: int, rb: RigidBody3D) -> void:
	# just let go of: not to be taken straight back
	_taken_at[id] = Time.get_ticks_msec()
	_poured.erase(id)
	# its state as it left us: the host would keep the last one it heard, up to a
	# second old (a bucket poured out and put straight down)
	mp._rx_prop_state.rpc(PackedInt64Array([id]), [_state_of(rb)])
	var xf: Transform3D = rb.global_transform
	var vel := rb.linear_velocity
	var spin := rb.angular_velocity
	_owner[id] = 1
	_hash.erase(id)
	_sent.erase(id)
	_puppet(rb)
	_iev(id, "handover", rb, " to=host")
	# keep it moving the way it was thrown until the host's moves arrive
	_goal[id] = Transform3D(xf.basis, xf.origin + vel * 0.1)
	mp._rx_prop_drop.rpc_id(1, id, xf, vel, spin)


# Host only. A guest let go of its item: take our copy over at that spot and
# give it the guest's speed, so our physics, machines and belts carry on.
func on_drop(sender: int, id: int, xf: Transform3D, vel: Vector3, spin: Vector3) -> void:
	var it: Variant = _by_id.get(id)
	if it == null or not is_instance_valid(it) or int(_owner.get(id, 0)) != sender:
		return
	_held.erase(id)
	if not host_take(it):
		return
	_place(it, xf)
	var rb := it as RigidBody3D
	rb.linear_velocity = vel
	rb.angular_velocity = spin
	rb.sleeping = false


var _move_at := 0   # where the next move tick starts its walk over the items

func _move_tick() -> void:
	_claim_held_copies()
	_claim_for_forcetron()
	_watch_hatches()
	_hand_drops()
	_watch_fetch()
	var ids := PackedInt64Array()
	var xfs: Array = []
	# (2026-11-13) by turns: with more than MOVE_BUDGET items on the move, the walk always
	# started at the same items and the rest got no update until those had landed (they
	# stood, then jumped). It now carries on where the last tick stopped.
	var keys: Array = _by_id.keys()
	var total := keys.size()
	var start := _move_at % maxi(total, 1)
	var walked := 0
	while walked < total:
		var id: int = keys[(start + walked) % total]
		walked += 1
		var it: Variant = _by_id[id]
		# out of the tree (mid-reparent) it reads as the origin and would
		# teleport the copy on the other side
		if it == null or not is_instance_valid(it) or not _mine(id) or not it.is_inside_tree():
			continue
		var xf: Transform3D = it.global_transform
		var last: Variant = _sent.get(id)
		if last != null and _same(last, xf):
			continue
		_sent[id] = xf
		_moving[id] = true
		ids.append(id)
		xfs.append(xf)
		if ids.size() >= MOVE_BUDGET:
			break
	_move_at = (start + walked) % maxi(total, 1)
	if ids.size() > 0:
		mp._rx_prop_move.rpc(ids, xfs)
	if not _want.is_empty():
		var asking := PackedInt64Array()
		for id in _want:
			asking.append(id)
		_want.clear()
		mp._rx_prop_want.rpc(asking)


func _same(a: Transform3D, b: Transform3D) -> bool:
	if a.origin.distance_squared_to(b.origin) > MOVE_EPS * MOVE_EPS:
		return false
	return a.basis.x.distance_squared_to(b.basis.x) < BASIS_EPS * BASIS_EPS \
		and a.basis.y.distance_squared_to(b.basis.y) < BASIS_EPS * BASIS_EPS


# Moves can get lost and nothing would ever correct the last one: an item that
# came to rest sends where it lies once more, reliably, on the state tick.
var _moving := {}  # mp id -> true: it moved since we last said where it rests

func _send_rests() -> void:
	var ids := PackedInt64Array()
	var xfs: Array = []
	for id in _moving.keys():
		var it: Variant = _by_id.get(id)
		if it == null or not is_instance_valid(it) or not _mine(id) or not it.is_inside_tree():
			_moving.erase(id)
			continue
		var last: Variant = _sent.get(id)
		if last == null or not _same(last, it.global_transform):
			continue  # still on its way
		_moving.erase(id)
		ids.append(id)
		xfs.append(last)
		if ids.size() >= MOVE_BUDGET:
			break
	if ids.size() > 0:
		mp._rx_prop_rest.rpc(ids, xfs)


func _state_tick() -> void:
	_send_rests()
	var ids := PackedInt64Array()
	var states: Array = []
	for id in _by_id:
		var it: Variant = _by_id[id]
		if it == null or not is_instance_valid(it) or not _mine(id):
			continue
		var st := _state_of(it)
		var h := st.hash()
		if int(_hash.get(id, 0)) == h:
			continue
		_hash[id] = h
		ids.append(id)
		states.append(st)
		if ids.size() >= STATE_BUDGET:
			break
	if ids.size() > 0:
		mp._rx_prop_state.rpc(ids, states)


func _census_tick() -> void:
	var ids := PackedInt64Array()
	var have := PackedInt64Array()
	for id in _by_id:
		if is_instance_valid(_by_id[id]):
			have.append(id)
			if _mine(id):
				ids.append(id)
	mp._rx_prop_census.rpc(ids, have)


# ------------------------------------------------------------------ from the net

func on_add(sender: int, id: int, item_id: String, xf: Transform3D, state: Dictionary) -> void:
	var have: Variant = _by_id.get(id)
	if have != null and is_instance_valid(have):
		_goal[id] = xf
		return
	if not ItemDb.has_item(item_id):
		return
	_busy = true
	var it: Variant = props.spawn(item_id, xf, state)
	_busy = false
	if it != null:
		_adopt(it, id, sender)
		_note_held(id, state)


func on_del(ids: PackedInt64Array, why := "guest") -> void:
	for id in ids:
		if _mine(id):
			continue
		var it: Variant = _by_id.get(id)
		_gone(id, it, why)
		_forget(id)
		if it != null and is_instance_valid(it):
			_remove_copy(it)


# Guest: the host's belt took these and they are rows now (see below).
func on_boarded(ids: PackedInt64Array) -> void:
	var rp := _belt_replay()
	for id in ids:
		if _mine(id):
			continue
		var it: Variant = _by_id.get(id)
		_gone(id, it, "belt_eaten")
		_forget(id)
		if it == null or not is_instance_valid(it):
			continue
		if rp:
			# (belt replay) the copy stays where it is until its row is on our belt (mp_belts plays
			# the host's words back a little later): the one goes in the frame the other comes.
			# Far from our player (belts there get a word every 2 s) it goes at once, as before.
			if _rp_shown.has(id) or _far_from_me(it as Node3D):
				_rp_shown.erase(id)
				_remove_copy(it)
			else:
				_rp_wait[it] = [id, Time.get_ticks_msec()]
		elif not _sink_onto_belt(it as Node3D):
			_remove_copy(it)


# (belt replay) items the host's belt took, waiting for their rows here; rows that came first
const RP_WAIT_MS := 700   # (belt replay L2: a near belt's row shows within ~0.3 s even at 100 ms lag)
const RP_NEAR_M := 40.0
var _rp_wait := {}   # copy -> [mp id, msec]
var _rp_shown := {}  # mp id -> msec

func _belt_replay() -> bool:
	var bs: Variant = mp.world_sync.get("belts_sync") if mp != null and mp.world_sync != null else null
	return bs != null and is_instance_valid(bs) and bool(bs.get("replay_on"))


# mp_belts: the row of item `id` is on our belt now (this frame).
func rp_row_shown(id: int) -> void:
	for it in _rp_wait.keys():
		if int(_rp_wait[it][0]) == id:
			_rp_wait.erase(it)
			if is_instance_valid(it):
				_remove_copy(it)
			return
	_rp_shown[id] = Time.get_ticks_msec()


func _far_from_me(n: Node3D) -> bool:
	var me: Variant = world.get("player") if world != null and is_instance_valid(world) else null
	if me == null or not is_instance_valid(me) or not n.is_inside_tree():
		return false
	return (me as Node3D).global_position.distance_to(n.global_position) > RP_NEAR_M


func _rp_wait_tick() -> void:
	if _rp_wait.is_empty() and _rp_shown.is_empty():
		return
	var now := Time.get_ticks_msec()
	for it in _rp_wait.keys():
		if not is_instance_valid(it):
			_rp_wait.erase(it)
		elif now - int(_rp_wait[it][1]) > RP_WAIT_MS:
			_rp_wait.erase(it)
			_remove_copy(it)
	for id in _rp_shown.keys():
		if now - int(_rp_shown[id]) > RP_WAIT_MS:
			_rp_shown.erase(id)


# (1.2.19) An item that lands on a belt stops being an item and becomes one of the belt's
# rows. The host's "it is gone" comes at once; the row comes with the belt's next word, a
# little later. In between the guest showed nothing: a thrown ball blinked out for 0.1-0.3 s
# before it rode on (measured; nothing was lost, it reached the belt's end on both sides).
# So a copy the host's belt took (it says so: _rx_prop_boarded) stays, settling onto the deck,
# until a new row shows up where it is, at most SINK_MS. Anything else the host deletes (a
# machine ate it, it was sold) goes at once, as before.
const SINK_MS := 600
const SINK_ROW_R := 1.0
var _sinking := {}   # copy -> [msec, deck spot, the row there before (seq or -1)]
var _belted := {}    # host: mp id -> true, its belt took it this frame (see _on_belt_caught)

func _sink_onto_belt(it: Node3D) -> bool:
	if not it.is_inside_tree() or (it.has_method("is_held") and it.is_held()):
		return false
	var at := it.global_position
	var deck: Variant = _deck_under(at)
	if deck == null:
		deck = at   # our copy is a little off the belt (it trails the host's): stay put
	var near: Dictionary = _record_in(at, SINK_ROW_R)
	var was := int((near.get("record", {}) as Dictionary).get("seq", -1)) if not near.is_empty() else -1
	_sinking[it] = [Time.get_ticks_msec(), deck, was]
	return true


# The deck point under `at` when it lies over a belt (within its width, a little above it).
func _deck_under(at: Vector3) -> Variant:
	for p in BeltPath._live:
		if not is_instance_valid(p) or not (p as Node).is_inside_tree() or not p.has_method("_nearest"):
			continue
		var mid: Variant = p.get("_mid")
		var half: Variant = p.get("_half_len")
		if mid is Vector3 and half != null and (mid as Vector3).distance_to(at) > float(half) + 1.5:
			continue
		var n: Dictionary = p.call("_nearest", at)
		var s := float(n.get("s", -1.0))
		if s < 0.0 or s > float(p.call("path_length")) + 0.1:
			continue
		var lift := float(n.get("lift", 9.0))
		if absf(float(n.get("side", 9.0))) <= 0.75 and lift > -0.25 and lift < 1.6:
			return at - Vector3.UP * maxf(lift - 0.25, 0.0)
	return null


func _settle_sinking(delta: float) -> void:
	if _sinking.is_empty():
		return
	var now := Time.get_ticks_msec()
	for it in _sinking.keys():
		if not is_instance_valid(it):
			_sinking.erase(it)
			continue
		var e: Array = _sinking[it]
		var n := it as Node3D
		n.global_position = n.global_position.lerp(e[1], clampf(delta * 14.0, 0.0, 1.0))
		var near: Dictionary = _record_in(n.global_position, SINK_ROW_R)
		var row := int((near.get("record", {}) as Dictionary).get("seq", -1)) if not near.is_empty() else -1
		if (row >= 0 and row != int(e[2])) or now - int(e[0]) >= SINK_MS:
			_sinking.erase(it)
			_remove_copy(n)


func on_move(sender: int, ids: PackedInt64Array, xfs: Array) -> void:
	for i in ids.size():
		var id: int = ids[i]
		if _mine(id):
			continue
		var it: Variant = _by_id.get(id)
		if it == null or not is_instance_valid(it):
			if not _just_handed(id):
				_want[id] = sender
			continue
		if int(_owner.get(id, 0)) != sender:
			_owner[id] = sender
			_puppet(it)
		if it.is_held():
			continue
		_goal[id] = xfs[i]


func on_state(sender: int, ids: PackedInt64Array, states: Array) -> void:
	for i in ids.size():
		var id: int = ids[i]
		if _mine(id):
			continue
		var it: Variant = _by_id.get(id)
		if it == null or not is_instance_valid(it):
			if not _just_handed(id):
				_want[id] = sender
			continue
		var st: Dictionary = states[i]
		it.from_state(st)
		it.needle_index = int(st.get("needle", -1))
		_note_held(id, st)


# older versions never send "held", so their items just look loose
func _note_held(id: int, st: Dictionary) -> void:
	if st.get("held", false):
		_held[id] = true
	else:
		_held.erase(id)


# We gave this one to the host's belt a moment ago. A move or state already on
# its way must not make us ask for it back: that put a second, loose copy here.
const HANDED_MS := 3000

func _just_handed(id: int) -> bool:
	if not _handed.has(id):
		return false
	if Time.get_ticks_msec() - int(_handed[id]) < HANDED_MS:
		return true
	_handed.erase(id)
	return false


func on_claim(sender: int, id: int) -> void:
	var it: Variant = _by_id.get(id)
	var alive: bool = it != null and is_instance_valid(it)
	# The host has already used this one up, in the time it took them to grab it.
	# Leaving it in their hands would make it exist twice.
	if not alive and mp.is_host and sender != _me():
		mp._rx_prop_gone.rpc(id)
		_forget(id)
		return
	var was_mine := _mine(id)
	# Two players took it in the same moment and each kept claiming it from the
	# other for as long as they held it. The lower id keeps it, the other lets go.
	if alive and was_mine and sender != _me() and it.is_held():
		if _me() < sender:
			mp._rx_prop_claim.rpc(id)
			return
		_owner[id] = sender
		_let_go(it)
	_owner[id] = sender
	_held.erase(id)
	_sent.erase(id)
	_goal.erase(id)
	if sender != _me():
		_taken_at[id] = Time.get_ticks_msec()
	if not alive:
		return
	if was_mine and sender != _me() and _is_a(it, "HayContainer"):
		mp._rx_prop_fill.rpc_id(sender, id, int(it.get("stored")))
	# Two claims can cross on the way: each side takes the other's as the last word
	# and each thinks the other owns it, so nobody moves it. The host saw them in
	# one order, and that order is what counts for everybody.
	if mp.is_host and sender != _me():
		mp._rx_prop_owner.rpc(id, sender)
	# they took it off our belt: without this our belt keeps carrying the copy
	if mp.is_host and sender != _me() and _is_rider(it as RigidBody3D):
		_release_rider(it as RigidBody3D)
	if sender == _me():
		_release(it)
	else:
		_puppet(it)


# The host's word on who owns an item.
func on_owner(id: int, owner: int) -> void:
	var it: Variant = _by_id.get(id)
	if it == null or not is_instance_valid(it) or int(_owner.get(id, 0)) == owner:
		return
	_owner[id] = owner
	_goal.erase(id)
	_held.erase(id)
	_sent.erase(id)
	_hash.erase(id)
	if owner == _me():
		_release(it)
		return
	if it.is_held():
		_let_go(it)
	_puppet(it)


# Host: somebody is not sure about these.
func on_ask(sender: int, ids: PackedInt64Array) -> void:
	for id in ids:
		var it: Variant = _by_id.get(id)
		if it == null or not is_instance_valid(it):
			mp._rx_prop_gone.rpc_id(sender, id)
		else:
			mp._rx_prop_owner.rpc_id(sender, id, int(_owner.get(id, _me())))


func _let_go(it: Node) -> void:
	var carry: Variant = _carry_tool()
	if carry == null or not carry.is_carrying():
		return
	if carry.held() == it:
		carry.drop()
	else:
		carry.drop_all()


func on_want(sender: int, ids: PackedInt64Array) -> void:
	for id in ids:
		if not _mine(id):
			continue
		var it: Variant = _by_id.get(id)
		if it == null or not is_instance_valid(it) or not it.is_inside_tree():
			continue
		mp._rx_prop_add.rpc_id(sender, id, String(it.item_id),
			it.global_transform, _state_of(it))


# The owner lists what it still has. Anything of theirs we are holding on to
# that is not on the list is gone; anything on the list we lack, we ask for.
# (have: everything they have, theirs or not.) If they do have it and just take it
# for somebody else's, it is not gone: we only disagree about the owner. Deleting
# it then made it vanish for everyone. The host's word settles it instead.
func on_census(sender: int, ids: PackedInt64Array, have: PackedInt64Array) -> void:
	var theirs := {}
	for id in ids:
		theirs[id] = true
	var still := {}
	for id in have:
		still[id] = true
	var drop: Array = []
	var unsure := PackedInt64Array()
	for id in _by_id:
		if int(_owner.get(id, 0)) != sender or theirs.has(id):
			continue
		if still.has(id):
			unsure.append(id)
		else:
			drop.append(id)
	if mp.is_host:
		for id in unsure:
			_owner[id] = _me()
			_goal.erase(id)
			_held.erase(id)
			_hash.erase(id)
			var mine: Variant = _by_id.get(id)
			if mine != null and is_instance_valid(mine):
				_release(mine)
			mp._rx_prop_claim.rpc(id)
	elif unsure.size() > 0:
		mp._rx_prop_ask.rpc_id(1, unsure)
	for id in drop:
		var it: Variant = _by_id.get(id)
		_forget(id)
		if it != null and is_instance_valid(it):
			_remove_copy(it)
	var missing := PackedInt64Array()
	for id in ids:
		var it2: Variant = _by_id.get(id)
		if it2 == null or not is_instance_valid(it2):
			missing.append(id)
	if missing.size() > 0:
		mp._rx_prop_want.rpc_id(sender, missing)


# ------------------------------------------------------------------ joining

# Host side: hand a client the whole yard, in batches so no single packet gets
# out of hand. Sent right after the client reports it is in the world.
func send_all(pid: int) -> void:
	var ids := PackedInt64Array()
	var owners := PackedInt32Array()
	var entries: Array = []
	var first := true
	for id in _by_id:
		var it: Variant = _by_id[id]
		if it == null or not is_instance_valid(it) or not it.is_inside_tree():
			continue
		ids.append(id)
		owners.append(int(_owner.get(id, 1)))
		var st := _state_of(it)
		# someone else carrying it right now
		if _held.has(id):
			st["held"] = true
		entries.append({
			"id": String(it.item_id),
			"xform": it.global_transform,
			"state": st,
		})
		if entries.size() >= RESET_BATCH:
			mp._rx_prop_reset.rpc_id(pid, first, ids, owners, entries)
			first = false
			ids = PackedInt64Array()
			owners = PackedInt32Array()
			entries = []
	mp._rx_prop_reset.rpc_id(pid, first, ids, owners, entries)
	mp._rx_prop_reset_end.rpc_id(pid)


func on_reset(first: bool, ids: PackedInt64Array, owners: PackedInt32Array, entries: Array) -> void:
	if first:
		_busy = true
		props.clear()
		_busy = false
		_by_id.clear()
		_owner.clear()
		_sent.clear()
		_hash.clear()
		_goal.clear()
		_want.clear()
		_held.clear()
		_carrying.clear()
		_flying.clear()
		for it in _sinking.keys():
			if is_instance_valid(it):
				_remove_copy(it)
		_sinking.clear()
	for i in ids.size():
		var e: Dictionary = entries[i]
		var item_id: String = e.get("id", "")
		if not ItemDb.has_item(item_id):
			continue
		_busy = true
		var it: Variant = props.spawn(item_id, e.get("xform", Transform3D.IDENTITY), e.get("state", {}))
		_busy = false
		if it != null:
			_adopt(it, ids[i], owners[i])
			_note_held(ids[i], e.get("state", {}))


func on_reset_end() -> void:
	_ready_map = true


# A peer left: the host keeps their things and takes over sending them.
func peer_gone(pid: int) -> void:
	for id in _owner:
		if int(_owner[id]) != pid:
			continue
		_owner[id] = 1
		_held.erase(id)
		var it: Variant = _by_id.get(id)
		if it == null or not is_instance_valid(it):
			continue
		if _me() == 1:
			_release(it)
			_sent.erase(id)


# ------------------------------------------------------------------ Forcetron (1.2.19)
#
# Bug reports: "the client cannot use the Forcetron". Everything somebody else owns is a
# frozen copy here, and the Forcetron cannot pull a frozen body, so for a guest it pulled
# nothing at all. Now what it aims at while pulling becomes ours first, the way picking it
# up by hand does, and once it lets go it goes back to the host like anything dropped.
const FORCE_REACH := 9.0    # metres along the beam
const FORCE_CONE := 0.8     # how close to the middle of the view

func _forcetron() -> Variant:
	var pl: Variant = world.get("player") if world != null else null
	if pl == null or not is_instance_valid(pl) or not ("forcetron" in pl):
		return null
	var tool: Variant = pl.get("forcetron")
	return tool if tool != null and is_instance_valid(tool) else null


func _in_forcetron(it: Node) -> bool:
	var tool: Variant = _forcetron()
	if tool == null:
		return false
	var pulled: Variant = tool.get("_targets")
	return pulled is Array and (pulled as Array).has(it)


var _force_claimed := {}  # mp id -> msec we took it for the Forcetron

func _claim_for_forcetron() -> void:
	var tool: Variant = _forcetron()
	var now := Time.get_ticks_msec()
	# taken for the Forcetron: once it holds them they count as carried (and go back to
	# the host when it lets go); what it did not take within a moment goes back now
	for id in _force_claimed.keys():
		var it: Variant = _by_id.get(id)
		if it == null or not is_instance_valid(it) or not _mine(id):
			_force_claimed.erase(id)
		elif _in_forcetron(it):
			_carrying[id] = true
			_force_claimed.erase(id)
		elif now - int(_force_claimed[id]) > 1500:
			_force_claimed.erase(id)
			if not mp.is_host and not it.is_held():
				_give_to_host(id, it as RigidBody3D)
	if tool == null or not tool.has_method("is_active") or not bool(tool.call("is_active")):
		return
	var pulled: Variant = tool.get("_targets")
	if pulled is Array:
		for it in pulled:
			if is_instance_valid(it) and (it as Node).has_meta("mp_id") and _mine(int((it as Node).get_meta("mp_id"))):
				_carrying[int((it as Node).get_meta("mp_id"))] = true
	if not tool.has_method("is_pulling") or not bool(tool.call("is_pulling")):
		return
	var pl: Variant = world.get("player")
	var eye: Vector3 = pl.eye_position()
	var look: Vector3 = pl.look_direction()
	for id in _by_id.keys():
		if _mine(id) or bool(_held.get(id, false)):
			continue
		var it: Variant = _by_id[id]
		if it == null or not is_instance_valid(it) or not (it as Node3D).is_inside_tree() or it.is_held():
			continue
		if _is_rider(it as RigidBody3D) or it.get("docked_in") != null:
			continue
		var to: Vector3 = (it as Node3D).global_position - eye
		if to.length() > FORCE_REACH or to.normalized().dot(look) < FORCE_CONE:
			continue
		_owner[id] = _me()
		_goal.erase(id)
		_hash.erase(id)
		_release(it)
		_force_claimed[id] = now
		mp._rx_prop_claim.rpc(id)


# ------------------------------------------------------------------ dump hatch (1.2.19)
#
# Bug reports (two groups): "secondary player cannot load wheelbarrow onto loader" / "der
# Client kann die Schubkarre nicht abkippen an der Kippstation". The hatch is a machine
# and runs on the host only; a guest's hatch is frozen, so the guest's wheelbarrow either
# never docked or docked into a copy that never tipped. Now a guest's wheelbarrow that
# docks here, or is pushed onto a hatch that wants it, goes to the host with its load,
# and the host's hatch takes it (DumpHatch.take: tested, it clamps, tips and throws the
# hay on as in single player). Everybody sees that through the usual sync.
const HATCH_PUSH_MS := 300    # pushed onto a hatch that wants it this long: load it
const HATCH_AGAIN_MS := 2000
var _hatch_near := {}   # mp id -> msec it was first pushed onto a hatch that wanted it
var _hatch_sent := {}   # mp id -> msec we last asked the host

func _hatch_recent(id: int) -> bool:
	return Time.get_ticks_msec() - int(_hatch_sent.get(id, -100000)) < HATCH_AGAIN_MS


func _watch_hatches() -> void:
	if mp.is_host:
		return
	var builds: Variant = world.get("builds") if world != null else null
	if builds == null or not is_instance_valid(builds) or not builds.has_method("hatch_wanting"):
		return
	var pl: Variant = world.get("player")
	if pl == null or not is_instance_valid(pl):
		return
	var carry: Variant = _carry_tool()
	var held: Variant = carry.call("held") if carry != null and is_instance_valid(carry) else null
	var now := Time.get_ticks_msec()
	# Our hatches are frozen copies; the game can still start a docking in one (it took
	# a barrow just handed to the host), and then it stayed "busy" for good and turned
	# every later barrow away. Anything not ours that it holds is let go of.
	var hatches: Variant = builds.get("dump_hatches")
	if hatches is Array:
		for h in hatches:
			if h == null or not is_instance_valid(h) or int(h.get("_state")) == 0:
				continue
			var ld: Variant = h.get("_load")
			var ours: bool = ld != null and is_instance_valid(ld) and (ld as Node).has_meta("mp_id") 				and _mine(int((ld as Node).get_meta("mp_id")))
			if not ours:
				if ld != null and is_instance_valid(ld) and ld.get("docked_in") == h:
					ld.set("docked_in", null)
				h.set("_load", null)
				h.set("_state", 0)
	for id in _by_id.keys():
		var it: Variant = _by_id[id]
		if it == null or not is_instance_valid(it) or not _is_a(it, "HayContainer") or not _mine(id):
			continue
		var hatch: Variant = it.get("docked_in")
		var docked: bool = hatch != null and is_instance_valid(hatch)
		if not docked:
			hatch = null
			if held != null and is_instance_valid(held) and it == held:
				var w: Variant = builds.call("hatch_wanting", it, (pl as Node3D).global_position)
				if w != null and is_instance_valid(w):
					var first: int = int(_hatch_near.get(id, now))
					_hatch_near[id] = first
					if now - first >= HATCH_PUSH_MS:
						hatch = w
				else:
					_hatch_near.erase(id)
			else:
				_hatch_near.erase(id)
		if hatch == null or now - int(_hatch_sent.get(id, -100000)) < HATCH_AGAIN_MS:
			continue
		_hatch_sent[id] = now
		_hatch_near.erase(id)
		if docked:
			# our copy of the hatch is frozen: undo its half-done docking, the host's does it
			hatch.set("_load", null)
			hatch.set("_state", 0)
			it.set("docked_in", null)
		if it == held and carry.has_method("drop"):
			carry.call("drop")
		_carrying.erase(id)
		_give_to_host(id, it as RigidBody3D)
		mp._rx_hatch_load.rpc_id(1, id, (hatch as Node3D).global_position)


# Host: a guest's wheelbarrow wants into the dump hatch at `at`. It came with
# _give_to_host just before (same channel, in order), so it is ours by now.
func on_hatch_load(sender: int, id: int, at: Vector3) -> void:
	if not mp.is_host:
		return
	var it: Variant = _by_id.get(id)
	if it == null or not is_instance_valid(it) or not _is_a(it, "HayContainer"):
		return
	if int(_owner.get(id, 0)) == sender:
		_held.erase(id)
		host_take(it)
	if not _mine(id):
		return
	var builds: Variant = world.get("builds") if world != null else null
	var hatches: Variant = builds.get("dump_hatches") if builds != null and is_instance_valid(builds) else null
	if not (hatches is Array):
		return
	var best: Variant = null
	var best_d := 2.5
	for h in hatches:
		if h == null or not is_instance_valid(h):
			continue
		var d: float = (h as Node3D).global_position.distance_to(at)
		if d < best_d:
			best_d = d
			best = h
	if best == null or bool(best.call("is_busy")) or not bool(best.call("will_take", it)):
		if mp.trace != null:
			mp.trace.note("hatch load %d refused (hatch %s)" % [id, best])
		return
	best.call("take", it)
	if mp.trace != null:
		mp.trace.note("hatch load %d from %d: taken" % [id, sender])
