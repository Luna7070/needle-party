# Dev only, never shipped: screenshots for the docs (panel, player list), then quit.
# Copy as mp_probe.gd into the mod folder and start with MP_PROBE=1.
# Writes user://shot_panel.png and user://shot_playerlist.png.
extends Node

var mp: Node

func _ready() -> void:
	await get_tree().create_timer(6.0).timeout
	# 1. the panel as anyone sees it on the title screen
	mp.ui.open_panel()
	# no personal names in public screenshots
	mp.ui._name_edit.text = "Luna7070"
	mp.ui._steam_label.text = mp.t("steam_ready") % "Luna7070"
	await get_tree().create_timer(1.2).timeout
	await RenderingServer.frame_post_draw
	_save("user://shot_panel.png")
	mp.ui.close_panel()
	# 2. the player list, with example players (display only, nothing is connected)
	mp.phase = 1
	mp.is_host = true
	mp.players = {
		1: {"name": "Luna7070", "color": Color(0.95, 0.35, 0.3), "state": "world"},
		22: {"name": "P1", "color": Color(0.3, 0.65, 0.98), "state": "world"},
		33: {"name": "HayKing", "color": Color(0.4, 0.85, 0.4), "state": "loading"},
	}
	mp.pings = {1: 0, 22: 38, 33: 112}
	if mp.ui._wait != null:
		mp.ui._wait.visible = false
	mp.ui._fill_tab()
	mp.ui._tab.visible = true
	mp.ui._tab.modulate.a = 1.0
	await get_tree().create_timer(0.8).timeout
	await RenderingServer.frame_post_draw
	_save("user://shot_playerlist.png")
	print("[MPProbe] shots saved")
	mp.players = {}
	mp.pings = {}
	mp.phase = 0
	mp.is_host = false
	get_tree().quit()


# 1600 px wide is plenty for a README and keeps the repository small
func _save(path: String) -> void:
	var img := get_viewport().get_texture().get_image()
	var w := 1600
	img.resize(w, int(float(img.get_height()) * w / img.get_width()), Image.INTERPOLATE_LANCZOS)
	img.save_png(path)

