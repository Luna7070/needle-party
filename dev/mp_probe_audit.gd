# Dev only: load slot 1 (saving blocked). For every building class the game
# has (res://scripts/build/*.gd with to_dict), report the keys its save data
# holds and its public vars. Uses a real placed building when the yard has one
# (exact data), otherwise a fresh instance (keys only). Also lists which build
# list each class lives in. Quits without saving.
extends Node

var mp: Node

func _ready() -> void:
	await get_tree().create_timer(4.0).timeout
	SaveManager.block_save = true
	SaveManager.begin_load(1)
	Loading.enter_scene("res://scenes/main.tscn")
	var t := 0.0
	while t < 60.0:
		await get_tree().create_timer(0.5).timeout
		t += 0.5
		var cs := get_tree().current_scene
		if cs != null and "_built" in cs and bool(cs.get("_built")):
			break
	await get_tree().create_timer(2.0).timeout
	SaveManager.block_save = true
	var out := FileAccess.open("user://mp_probe_audit.txt", FileAccess.WRITE)
	var builds: Object = get_tree().current_scene.get("builds")
	# which list each script lives in, from the yard
	var placed := {}   # script file -> [list name, node]
	for p in builds.get_property_list():
		var v: Variant = builds.get(p["name"])
		if v is Array:
			for n in v:
				if n is Node and is_instance_valid(n) and n.get_script() != null:
					var f: String = n.get_script().resource_path.get_file()
					if not placed.has(f):
						placed[f] = [p["name"], n]
	for c in ProjectSettings.get_global_class_list():
		var path: String = c["path"]
		if not path.begins_with("res://scripts/build/"):
			continue
		var s: Script = load(path)
		if s == null:
			continue
		var has_dict := false
		for m in s.get_script_method_list():
			if m["name"] == "to_dict":
				has_dict = true
				break
		if not has_dict:
			continue
		var f := path.get_file()
		var node: Object = null
		var where := "-"
		var real := false
		if placed.has(f):
			where = placed[f][0]
			node = placed[f][1]
			real = true
		elif s.can_instantiate():
			node = s.new()
		var keys := "?"
		if node != null:
			var d: Variant = node.call("to_dict")
			if d is Dictionary:
				var parts: Array = []
				for k in d:
					parts.append("%s=%s" % [k, str(d[k]).substr(0, 24)] if real else str(k))
				keys = ", ".join(parts)
		var vars: Array = []
		for p in s.get_script_property_list():
			if int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE and not String(p["name"]).begins_with("_"):
				vars.append(p["name"])
		out.store_line("### %s (%s) list=%s real=%s" % [c["class"], f, where, real])
		out.store_line("  save: " + keys)
		out.store_line("  vars: " + ", ".join(vars))
		if node != null and not real and node is Node:
			(node as Node).free()
	out.close()
	print("[MPProbe] audit done")
	get_tree().quit()
