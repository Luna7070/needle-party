extends Node

# Delivery contracts.
#
# The game's DeliveryDirector calls the truck, counts what lands in its bed and
# pays when the order is full. Left running on every player it did all of that
# once per player: each had their own truck on their own timer, and a finished
# contract paid on the guest too, which reached the host as more money, so the
# bonus came twice.
#
# Only the host's director runs now. A guest's is stopped, and the host sends
# the contract as it stands; the guest's truck, stack and board follow it.

const TICK := 0.5
const FULL_TICK := 3.0   # everything again now and then, for a guest that just came in

var mp: Node
var world: Node
var _t := 0.0
var _full_t := 0.0
var _last := {}
var _stopped := false
var _rigged := -1      # guest: the contract our truck is set up for
var _load_checked: Variant = null  # guest: what we last put the truck's load right for


func start(mp_node: Node, world_node: Node) -> void:
	mp = mp_node
	world = world_node


func shutdown() -> void:
	var dd := _director()
	if _stopped and dd != null:
		dd.set_process(true)
	_stopped = false


func _director() -> Node:
	var dd: Variant = world.get("deliveries") if world != null and is_instance_valid(world) else null
	return dd if dd != null and is_instance_valid(dd) else null


func _truck() -> Node:
	var tr: Variant = world.get("truck") if world != null and is_instance_valid(world) else null
	return tr if tr != null and is_instance_valid(tr) else null


# stopwatch: anything over 4 ms in one frame goes into mp_trace.log by name
func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_process_inner(delta)
	if mp != null and is_instance_valid(mp):
		mp.perf("contracts", Time.get_ticks_usec() - t0)


func _process_inner(delta: float) -> void:
	if mp == null or not mp.active() or multiplayer.multiplayer_peer == null:
		return
	if not mp.is_host:
		var dd := _director()
		if dd != null and dd.is_processing():
			dd.set_process(false)
			_stopped = true
		return
	if mp.players.size() < 2:
		return
	_t += delta
	_full_t += delta
	if _t < TICK:
		return
	_t = 0.0
	var now := _state()
	if now == _last and _full_t < FULL_TICK:
		return
	_full_t = 0.0
	_last = now
	mp._rx_contract.rpc(now)


func _state() -> Dictionary:
	var tr := _truck()
	return {
		"index": GameState.contract_index,
		"delivered": GameState.contract_delivered,
		# a contract that wants several things counts each one here (the board's 94/356)
		"parts": GameState.contract_parts.duplicate(),
		"here": GameState.contract_truck_here,
		"done": GameState.contracts_done.keys(),
		"truck": int(tr.get("state")) if tr != null else -1,
	}


func on_state(s: Dictionary) -> void:
	if mp.is_host:
		return
	var index := int(s.get("index", GameState.contract_index))
	var delivered := int(s.get("delivered", 0))
	var was_index: int = GameState.contract_index
	var was_delivered: int = GameState.contract_delivered
	var parts: Dictionary = s.get("parts", {})
	var was_parts: Dictionary = GameState.contract_parts.duplicate()
	var tr := _truck()
	# a contract closed on the host: tick it off here too
	if index > was_index:
		var dd := _director()
		if dd != null and dd.get("panel") != null:
			dd.panel.mark_complete(DeliveryBook.title_of(was_index))
		Audio.play("sell_register", -2.0)
		Audio.play_delayed("coins", 0.18, -3.0)
		was_delivered = 0
		was_parts.clear()
	GameState.contract_index = index
	GameState.contract_delivered = delivered
	GameState.contract_parts.clear()
	GameState.contract_parts.merge(parts)
	GameState.contract_truck_here = bool(s.get("here", GameState.contract_truck_here))
	var done := {}
	for id in s.get("done", []):
		done[str(id)] = true
	# which contracts, not how many: one finished on each side kept the count
	# equal and the list wrong
	# signed here and not yet on the host: ask for it and keep it meanwhile, or the
	# host's older list would take the signature back
	for id in GameState.contracts_done:
		var sid := str(id)
		if not done.has(sid) and DeliveryBook.index_of(sid) >= 0:
			done[sid] = true
			mp._rx_contract_sign.rpc_id(1, sid)
	var theirs: Array = done.keys()
	theirs.sort()
	var ours: Array = []
	for id in GameState.contracts_done:
		ours.append(str(id))
	ours.sort()
	if theirs != ours:
		GameState.contracts_done = done
		GameState.contracts_changed.emit()
	if tr != null:
		_rig_truck(index)
		_follow_truck(tr, int(s.get("truck", -1)))
		# what went into the host's truck, stacked in ours
		if index == was_index:
			_stack_new(tr, index, delivered - was_delivered, parts, was_parts)
		_check_load(tr, parts, delivered, index)
	var dd2 := _director()
	if dd2 != null:
		dd2._restate()


# The stopped director never sets the truck up for a new contract, so it kept the
# old contract's spots and could not show the new goods.
# (1.2.19) DeliveryBook.wanted_items() is not in every build (the demo: 1.2.18 failed to load
# this whole file there, so no contracts synced, seen in the demo players' logs). Called by
# name; without it, the contract's one "want".
var _wanted_fn: Variant = false   # false = not looked up yet

func _wanted_items(index: int) -> Array:
	if typeof(_wanted_fn) == TYPE_BOOL:
		_wanted_fn = null
		var db: Variant = DeliveryBook
		if db is Script:
			for f in (db as Script).get_script_method_list():
				if String(f.get("name", "")) == "wanted_items":
					_wanted_fn = db
					break
	if _wanted_fn != null:
		var v: Variant = _wanted_fn.call("wanted_items", index)
		return v if v is Array else []
	var want := str(DeliveryBook.contract(index).get("want", ""))
	return [want] if want != "" else []


func _rig_truck(index: int) -> void:
	if index == _rigged or DeliveryBook.contract(index).is_empty():
		return
	var dd := _director()
	if dd != null:
		dd._rig(index)
		_rigged = index
		_load_checked = null


# A guest that joins with a load already aboard, or misses a step: lay the host's
# load out again. Once per change, so a truck that shows fewer cannot loop on it.
func _check_load(tr: Node, counted: Dictionary, delivered: int, index: int) -> void:
	var parts := counted
	# a contract for one thing may only count in the total
	if parts.is_empty() and delivered > 0 and _wanted_items(index).size() == 1:
		parts = {str(_wanted_items(index)[0]): delivered}
	if parts.is_empty() or int(tr.get("state")) == DeliveryTruck.State.AWAY:
		return
	var total := 0
	for id in parts:
		if parts[id] is int or parts[id] is float:
			total += int(parts[id])
	if int(tr.load_shown()) == total:
		return
	var key := [parts.duplicate(), int(tr.get("state"))]
	if key == _load_checked:
		return
	_load_checked = key
	tr.restore_load(parts)


func _stack_new(tr: Node, index: int, more: int, parts: Dictionary, was_parts: Dictionary) -> void:
	if parts.is_empty():
		var want := str(DeliveryBook.contract(index).get("want", ""))
		for i in maxi(0, more):
			tr.stack_one(want)
		return
	var wanted: Array = _wanted_items(index)
	for id in parts:
		if str(id) in wanted and (parts[id] is int or parts[id] is float):
			for i in maxi(0, int(parts[id]) - int(was_parts.get(id, 0))):
				tr.stack_one(str(id))


# Host: a guest signed a contract on the board.
func on_sign(id: String) -> void:
	if mp.is_host and DeliveryBook.index_of(id) >= 0 and not GameState.contract_signed(id):
		GameState.sign_contract(id)


# The truck drives itself once told to come or go, so only the moves are sent.
func _follow_truck(tr: Node, want: int) -> void:
	var st := int(tr.get("state"))
	if want < 0 or want == st:
		return
	match want:
		DeliveryTruck.State.ARRIVING:
			tr.arrive()
		DeliveryTruck.State.PARKED:
			if st == DeliveryTruck.State.AWAY:
				tr.snap_parked()
		DeliveryTruck.State.LEAVING, DeliveryTruck.State.AWAY:
			if st == DeliveryTruck.State.ARRIVING:
				tr.snap_parked()
			tr.depart()
