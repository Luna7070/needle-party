# Dev only: list every input action the game defines and its keys, plus the
# DayCycle API, then quit.
extends Node

var mp: Node

func _ready() -> void:
	await get_tree().create_timer(4.0).timeout
	var out := FileAccess.open("user://mp_probe_keys.txt", FileAccess.WRITE)
	for a in InputMap.get_actions():
		if String(a).begins_with("ui_"):
			continue
		var keys: Array = []
		for e in InputMap.action_get_events(a):
			if e is InputEventKey:
				var k: int = e.physical_keycode if e.physical_keycode != 0 else e.keycode
				keys.append(OS.get_keycode_string(k))
			elif e is InputEventMouseButton:
				keys.append("mouse%d" % e.button_index)
		out.store_line("%s: %s" % [a, ", ".join(keys)])
	out.close()
	print("[MPProbe] keys done")
	get_tree().quit()
