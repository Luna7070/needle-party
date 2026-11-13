# Dev only, never shipped. Dumps the game's script API (classes, methods,
# signals, properties, constants, autoloads) to user://mp_probe_dump.txt and
# quits, so the mod can be checked against a new game build.
extends Node

var mp: Node

func _ready() -> void:
	await get_tree().create_timer(4.0).timeout
	var out := FileAccess.open("user://mp_probe_dump.txt", FileAccess.WRITE)
	out.store_line("engine %s" % Engine.get_version_info().string)
	out.store_line("== autoloads")
	for n in get_tree().root.get_children():
		var s: Script = n.get_script()
		out.store_line("%s  %s" % [n.name, s.resource_path if s else n.get_class()])
	out.store_line("== classes")
	for c in ProjectSettings.get_global_class_list():
		var path: String = c["path"]
		out.store_line("\n### %s extends %s  (%s)" % [c["class"], c["base"], path])
		var s: Script = load(path)
		if s == null:
			out.store_line("  <failed to load>")
			continue
		_dump(out, s)
	for n in get_tree().root.get_children():
		var s: Script = n.get_script()
		if s != null and n != mp and n != self:
			out.store_line("\n### AUTOLOAD %s (%s)" % [n.name, s.resource_path])
			_dump(out, s)
	out.close()
	print("[MPProbe] wrote ", ProjectSettings.globalize_path("user://mp_probe_dump.txt"))
	get_tree().quit()


func _dump(out: FileAccess, s: Script) -> void:
	var sigs: Array = []
	for g in s.get_script_signal_list():
		var args: Array = []
		for a in g["args"]:
			args.append(a["name"])
		sigs.append("%s(%s)" % [g["name"], ",".join(args)])
	out.store_line("  signals: " + ", ".join(sigs))
	var props: Array = []
	for p in s.get_script_property_list():
		if int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE:
			props.append(p["name"])
	out.store_line("  vars: " + ", ".join(props))
	var consts: Dictionary = s.get_script_constant_map()
	var cn: Array = []
	for k in consts:
		var v: Variant = consts[k]
		cn.append("%s=%s" % [k, str(v).substr(0, 60)] if typeof(v) in [TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_STRING_NAME, TYPE_DICTIONARY] else str(k))
	out.store_line("  consts: " + ", ".join(cn))
	var ms: Array = []
	for m in s.get_script_method_list():
		var args: Array = []
		for a in m["args"]:
			args.append(a["name"])
		ms.append("%s(%s)" % [m["name"], ",".join(args)])
	out.store_line("  methods: " + ", ".join(ms))
