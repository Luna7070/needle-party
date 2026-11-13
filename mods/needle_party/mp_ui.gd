# UI for the multiplayer mod: lobby panel (F2 or the menu's MULTIPLAYER entry),
# notification feed, chat (Y) and the player list.
extends CanvasLayer

# NEEDLE PARTY look (made by Luna and Lolfa): a farm machine's control panel. Warm
# charcoal, one hay-amber accent, hairlines, square corners, spaced small
# caps for labels, a hazard stripe. No glow, no gradients.
const COL_TITLE := Color(0.96, 0.74, 0.28)      # hay amber: the one accent
const COL_ACCENT := Color(0.78, 0.52, 0.16)     # deeper amber, for pressed/edges
const COL_INK := Color(0.11, 0.095, 0.08)       # text on amber
const COL_TEXT := Color(0.95, 0.92, 0.86)       # warm off-white
const COL_DIM := Color(0.64, 0.6, 0.54)
const COL_LINE := Color(1.0, 0.95, 0.85, 0.09)  # hairlines
const COL_BG := Color(0.085, 0.08, 0.074, 0.97)
const COL_PLATE := Color(0.07, 0.066, 0.06, 0.9)  # chat and notification cards
const COL_CARD := Color(0.095, 0.09, 0.083, 0.98)  # the joining card
const COL_FIELD := Color(0.055, 0.052, 0.048, 0.92)  # text fields, chat
const COL_OFF := Color(0.46, 0.44, 0.41)          # steps still to come
const COL_DONE := Color(0.6, 0.82, 0.45)          # field green: done, good
const COL_BAR := Color(0.96, 0.74, 0.28)
const COL_BAR_BACK := Color(1.0, 0.95, 0.85, 0.07)


# Black and amber diagonal stripes, like the warning band on a machine.
class Hazard extends Control:
	var a := Color(0.96, 0.74, 0.28)
	var b := Color(0.11, 0.095, 0.08)
	var step := 10.0
	func _ready() -> void:
		clip_contents = true
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), b)
		var h := size.y
		# (2026-11-13) drawn before its first layout (height 0) every stripe was a flat
		# polygon: "Invalid polygon data, triangulation failed" in the logs
		if h < 1.0 or size.x < 1.0:
			return
		var x := -h
		while x < size.x:
			draw_colored_polygon(PackedVector2Array([Vector2(x, h), Vector2(x + h, 0),
				Vector2(x + h + step * 0.5, 0), Vector2(x + step * 0.5, h)]), a)
			x += step
const FEED_SECONDS := 7.0
const FEED_MAX := 6
const FEED_IN := 0.25  # the HUD cards fade 0.25 s, linear
const FEED_OUT := 1.0
const WAIT_W := 372.0  # same width as the lobby's slot card
const WAIT_TICK := 0.15  # the hand-off has no signals, so poll for its state
const WAIT_DONE := 5.0  # how long "you are in" stays up before it gets out of the way
const WAIT_BREATH := 2.8  # the current step's edge breathes like the mission card
const MARK_DONE := "✓"

# What a guest is waiting for, in the order it happens.
enum Step { CONNECT, SAVE, WORLD, LOADING, INSIDE }

var mp: Node

var _root: ColorRect
var _panel: PanelContainer
var _name_edit: LineEdit
var _status: Label
var _progress: ProgressBar
var _players_label: RichTextLabel
var _steam_host_btn: Button
var _invite_btn: Button
var _steam_label: Label
var _steps_label: RichTextLabel
var _help_label: Label
var _close_btn: Button
var _title_label: Label
var _subtitle_label: Label
var _leave_btn: Button
var _resync_btn: Button

var _feed: VBoxContainer
var _chat_box: PanelContainer
var _chat_edit: LineEdit
var _roster: RichTextLabel
var _roster_on := false
var _mouse_was_captured := false

# last notification, so the same message twice counts up instead of stacking
var _last_note: Control = null
var _last_note_text := ""
var _last_note_n := 1

# the guest's "what is happening" card
var _wait: PanelContainer
var _wait_title: Label
var _wait_sub: Label
var _wait_hint: Label
var _wait_bar: ProgressBar
var _wait_marks: Array[Label] = []
var _wait_names: Array[Label] = []
var _wait_rows: Array[StyleBoxFlat] = []
var _wait_sig := ""  # only rewrite the card when something actually changed
var _wait_now := -1
var _wait_clock := 0.0
var _wait_t := 0.0
var _wait_done_at := 0.0
var _progress_v := -1.0


func _ready() -> void:
	layer = 110
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_feed()
	_build_roster()
	_build_chat()
	_build_wait()
	_build_panel()
	_build_tab()
	refresh()


# ---------------------------------------------------------------- building

var _font_cache: Font = null
var _font_tried := false
var _ui_font_cls: Script = null
var _ui_font_tried := false


# the game's bold UI font, if its UiFont helper is there
func _font() -> Font:
	if not _font_tried:
		_font_tried = true
		var cls := _ui_font()
		if cls != null:
			_font_cache = cls.call("bold")
	return _font_cache


func _ui_font() -> Script:
	if not _ui_font_tried:
		_ui_font_tried = true
		_ui_font_cls = _global_class("UiFont")
	return _ui_font_cls


# a label the way the game does every one of its own: its font, regular or
# bold, and a thin black outline
func _style(l: Label, size: int, col: Color, outline := 4, heavy := false) -> void:
	var cls := _ui_font()
	if cls != null:
		cls.call("style", l, size, col, outline, heavy)
		return
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("outline_size", outline)


func _styled(text: String, size: int, col: Color, outline := 4, heavy := false) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_style(l, size, col, outline, heavy)
	return l


func _global_class(n: String) -> Script:
	for c in ProjectSettings.get_global_class_list():
		if str(c["class"]) == n:
			return load(str(c["path"]))
	return null


# wrap only for long text that sits in a box with a real width (a wrapping
# label inside an HBox collapses to zero width and stacks one letter per line)
func _label(text: String, size := 18, col := COL_TEXT, wrap := false) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = 560
	var f := _font()
	if f != null and size >= 20:
		l.add_theme_font_override("font", f)
	return l


# The game's HUD card: near-black, a little see-through, square, no shadow,
# with a coloured edge down the left so a card reads as "who" at a glance.
func _plate(accent: Color, mx := 12.0, my := 8.0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = COL_PLATE
	sb.border_color = accent
	sb.border_width_left = 3
	sb.content_margin_left = mx
	sb.content_margin_right = mx
	sb.content_margin_top = my
	sb.content_margin_bottom = my + 1.0
	return sb


# the lobby's save slot card: a gold hairline all round and a soft shadow
func _card() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = COL_CARD
	sb.set_border_width_all(1)
	sb.border_color = Color(COL_TITLE, 0.55)
	sb.shadow_color = Color(0, 0, 0, 0.55)
	sb.shadow_size = 14
	sb.content_margin_left = 22
	sb.content_margin_right = 22
	sb.content_margin_top = 18
	sb.content_margin_bottom = 18
	return sb


# thin gold on a faint track, like the game's own loading bar (square ends on
# the guest card, where it sits next to the lobby's square boxes)
func _style_bar(bar: ProgressBar, square := false) -> void:
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.show_percentage = false
	bar.min_value = 0.0
	bar.max_value = 100.0
	var r := 0 if square else 3
	var back := StyleBoxFlat.new()
	back.bg_color = COL_BAR_BACK
	back.set_corner_radius_all(r)
	var fill := StyleBoxFlat.new()
	fill.bg_color = COL_BAR
	fill.set_corner_radius_all(r)
	bar.add_theme_stylebox_override("background", back)
	bar.add_theme_stylebox_override("fill", fill)


func _button(text: String, cb: Callable, accent := false) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 44)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_font_size_override("font_size", 19)
	var f := _font()
	if f != null:
		b.add_theme_font_override("font", f)
	# primary: solid amber with dark lettering; secondary: a hairline outline
	# that picks up the amber under the mouse
	for st in ["normal", "hover", "pressed", "disabled", "focus"]:
		var sb := StyleBoxFlat.new()
		sb.set_corner_radius_all(2)
		sb.content_margin_left = 16
		sb.content_margin_right = 16
		if accent:
			sb.bg_color = {"normal": COL_TITLE, "hover": COL_TITLE.lightened(0.12),
				"pressed": COL_ACCENT, "focus": COL_TITLE,
				"disabled": Color(1, 0.95, 0.85, 0.06)}[st]
			if st == "disabled":
				sb.set_border_width_all(1)
				sb.border_color = COL_LINE
		else:
			sb.bg_color = {"normal": Color(1, 0.95, 0.85, 0.035), "hover": Color(1, 0.95, 0.85, 0.08),
				"pressed": Color(1, 0.95, 0.85, 0.12), "focus": Color(1, 0.95, 0.85, 0.035),
				"disabled": Color(0, 0, 0, 0)}[st]
			sb.set_border_width_all(1)
			sb.border_color = Color(COL_TITLE, 0.7) if st == "hover" else COL_LINE
		b.add_theme_stylebox_override(st, sb)
	b.add_theme_font_size_override("font_size", 17)
	b.add_theme_color_override("font_color", COL_INK if accent else COL_TEXT)
	b.add_theme_color_override("font_hover_color", COL_INK if accent else COL_TITLE)
	b.add_theme_color_override("font_pressed_color", COL_INK if accent else COL_TITLE)
	b.add_theme_color_override("font_focus_color", COL_INK if accent else COL_TEXT)
	b.add_theme_color_override("font_disabled_color", Color(COL_DIM, 0.5))
	var sf := _spaced(_font(), 1.0)
	if sf != null:
		b.add_theme_font_override("font", sf)
	b.pressed.connect(cb)
	return b


# The game's font with extra space between the letters, for small caps labels.
var _spaced_cache := {}

func _spaced(base: Font, gap: float) -> Font:
	if base == null:
		base = ThemeDB.fallback_font
	var k := "%s|%s" % [base.get_instance_id(), gap]
	if not _spaced_cache.has(k):
		var fv := FontVariation.new()
		fv.base_font = base
		fv.spacing_glyph = int(gap)
		_spaced_cache[k] = fv
	return _spaced_cache[k]


# A small spaced-out caps label: section heads, column heads, badges.
func _caps(text: String, size := 12, col := COL_DIM, gap := 2.0) -> Label:
	var l := Label.new()
	l.text = text.to_upper()
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.add_theme_font_override("font", _spaced(_font(), gap))
	return l


# A hairline with a short amber lead-in: separates the header from the body.
func _rule() -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 0)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var lead := ColorRect.new()
	lead.color = COL_TITLE
	lead.custom_minimum_size = Vector2(36, 2)
	lead.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(lead)
	var line := ColorRect.new()
	line.color = COL_LINE
	line.custom_minimum_size = Vector2(0, 1)
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.size_flags_vertical = Control.SIZE_SHRINK_END
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(line)
	return h


func _hazard(w: float, h: float) -> Control:
	var z := Hazard.new()
	z.custom_minimum_size = Vector2(w, h)
	z.a = COL_TITLE
	z.b = COL_INK
	return z


# ---------------------------------------------------------------- friends list
# Invite friends from inside the game. The Steam overlay's dialog is still
# there as a fallback, but it often never shows in this game.
var _join_invite_btn: Button
var _update_btn: Button
var _friends_box: VBoxContainer
var _friends_list: VBoxContainer


func _build_friends(v: VBoxContainer) -> void:
	_friends_box = VBoxContainer.new()
	_friends_box.add_theme_constant_override("separation", 6)
	_friends_box.visible = false
	v.add_child(_friends_box)
	var head := HBoxContainer.new()
	head.add_child(_label(mp.t_or("friends_title", "INVITE A FRIEND"), 15, COL_TITLE))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(spacer)
	var reload := _button(mp.t_or("friends_reload", "REFRESH"), _fill_friends)
	reload.size_flags_horizontal = Control.SIZE_SHRINK_END
	reload.custom_minimum_size = Vector2(120, 34)
	head.add_child(reload)
	_friends_box.add_child(head)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 150)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_friends_box.add_child(scroll)
	_friends_list = VBoxContainer.new()
	_friends_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_friends_list.add_theme_constant_override("separation", 4)
	scroll.add_child(_friends_list)
	var overlay := _button(mp.t_or("friends_overlay", "OPEN STEAM OVERLAY INSTEAD"), func() -> void: mp.invite_friends())
	overlay.custom_minimum_size = Vector2(0, 34)
	_friends_box.add_child(overlay)


func _on_join_invite() -> void:
	mp.accept_invite()
	refresh()


func _toggle_friends() -> void:
	_friends_box.visible = not _friends_box.visible
	if _friends_box.visible:
		_fill_friends()


func _fill_friends() -> void:
	for c in _friends_list.get_children():
		c.queue_free()
	var list: Array = mp.steam.friends() if mp.steam_ready() else []
	if list.is_empty():
		_friends_list.add_child(_label(mp.t_or("friends_none", "No friends online right now."), 15, COL_DIM))
		return
	for f in list:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var dot := _label("●", 16, COL_TITLE if f["playing"] else COL_DONE)
		row.add_child(dot)
		var name_l := _label(str(f["name"]).substr(0, 28), 17, COL_TEXT)
		name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_l.clip_text = true
		row.add_child(name_l)
		if f["playing"]:
			row.add_child(_label(mp.t_or("friends_playing", "in Find The Needle"), 13, COL_TITLE))
		var fid: int = int(f["id"])
		var fname: String = str(f["name"])
		var b := _button(mp.t_or("friends_invite", "INVITE"), func() -> void: mp.invite_friend(fid, fname), true)
		b.size_flags_horizontal = Control.SIZE_SHRINK_END
		b.custom_minimum_size = Vector2(110, 34)
		row.add_child(b)
		_friends_list.add_child(row)


func _edit(text: String, placeholder: String) -> LineEdit:
	var e := LineEdit.new()
	e.text = text
	e.placeholder_text = placeholder
	e.custom_minimum_size = Vector2(0, 42)
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	e.add_theme_font_size_override("font_size", 18)
	e.add_theme_color_override("font_color", COL_TEXT)
	e.add_theme_color_override("font_placeholder_color", Color(COL_DIM, 0.6))
	e.add_theme_color_override("caret_color", COL_TITLE)
	e.add_theme_color_override("selection_color", Color(COL_TITLE, 0.3))
	e.add_theme_color_override("font_uneditable_color", COL_DIM)
	# a sunken field with an underline that turns amber while you type
	for st in ["normal", "focus", "read_only"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = COL_FIELD
		sb.set_corner_radius_all(2)
		sb.border_width_bottom = 2
		sb.border_color = COL_TITLE if st == "focus" else COL_LINE
		sb.content_margin_left = 12
		sb.content_margin_right = 12
		e.add_theme_stylebox_override(st, sb)
	return e


func _field(parent: Control, caption: String, ctl: Control) -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(_caps(caption, 11, COL_DIM, 2.0))
	box.add_child(ctl)
	parent.add_child(box)


var _panel_scroll: ScrollContainer
var _panel_body: VBoxContainer


# The card is as tall as its content, up to the screen height minus a margin.
func _fit_panel() -> void:
	if _panel_scroll == null or _panel_body == null or not _root.visible:
		return
	var room: float = get_viewport().get_visible_rect().size.y - 110.0
	var h: float = minf(_panel_body.get_combined_minimum_size().y, maxf(200.0, room))
	if not is_equal_approx(_panel_scroll.custom_minimum_size.y, h):
		_panel_scroll.custom_minimum_size.y = h
		_panel.reset_size()


func _build_panel() -> void:
	# full-screen layer: dims the game and centres the panel
	_root = ColorRect.new()
	_root.color = Color(0.02, 0.018, 0.015, 0.6)
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.visible = false
	add_child(_root)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)

	_panel = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = COL_BG
	sb.set_border_width_all(1)
	sb.border_color = COL_LINE
	sb.set_corner_radius_all(3)
	sb.shadow_color = Color(0, 0, 0, 0.55)
	sb.shadow_size = 28
	sb.shadow_offset = Vector2(0, 10)
	sb.content_margin_left = 32
	sb.content_margin_right = 32
	sb.content_margin_top = 26
	sb.content_margin_bottom = 26
	_panel.add_theme_stylebox_override("panel", sb)
	_panel.custom_minimum_size = Vector2(640, 0)
	center.add_child(_panel)

	# everything scrolls inside the card, so it never grows past the screen
	_panel_scroll = ScrollContainer.new()
	_panel_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_panel.add_child(_panel_scroll)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_panel_scroll.add_child(v)
	_panel_body = v
	# header: hazard band and kicker on top, the name under it, status right
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 14)
	v.add_child(head)
	var titles := VBoxContainer.new()
	titles.add_theme_constant_override("separation", 2)
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(titles)
	var kicker := HBoxContainer.new()
	kicker.add_theme_constant_override("separation", 10)
	kicker.add_child(_caps("Co-op multiplayer", 12, COL_TITLE, 3.0))
	titles.add_child(kicker)
	_title_label = _label(mp.t("title"), 40, COL_TEXT)
	titles.add_child(_title_label)
	_state_pill = PanelContainer.new()
	_state_pill.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_state_sb = StyleBoxFlat.new()
	_state_sb.set_corner_radius_all(12)
	_state_sb.set_border_width_all(1)
	_state_sb.content_margin_left = 10
	_state_sb.content_margin_right = 12
	_state_sb.content_margin_top = 5
	_state_sb.content_margin_bottom = 5
	_state_pill.add_theme_stylebox_override("panel", _state_sb)
	var ph := HBoxContainer.new()
	ph.add_theme_constant_override("separation", 7)
	_state_pill.add_child(ph)
	_state_dot = _label("●", 12, COL_DONE)
	ph.add_child(_state_dot)
	_state_text = _caps("", 12, COL_TEXT, 2.0)
	ph.add_child(_state_text)
	head.add_child(_state_pill)
	# (#29, 2026-11-17) settings behind a small gear (SMOOTH BELTS, anonymous logs)
	_gear_btn = Button.new()
	_gear_btn.flat = true
	_gear_btn.focus_mode = Control.FOCUS_NONE
	_gear_btn.custom_minimum_size = Vector2(34, 34)
	_gear_btn.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_gear_btn.tooltip_text = mp.t_or("np_settings", "SETTINGS")
	_gear_btn.draw.connect(_draw_gear)
	_gear_btn.mouse_entered.connect(_gear_btn.queue_redraw)
	_gear_btn.mouse_exited.connect(_gear_btn.queue_redraw)
	_gear_btn.pressed.connect(func() -> void: show_settings(not _settings_page.visible))
	head.add_child(_gear_btn)
	_subtitle_label = _label(mp.t("subtitle") % mp.VERSION + "   ·   " + mp.CREDIT, 13, COL_DIM)
	v.add_child(_subtitle_label)
	# shown only when GitHub has a newer release (see mp.gd _check_for_update)
	_update_btn = _button("", func() -> void: mp.update_click(), true)
	_update_btn.visible = false
	v.add_child(_update_btn)
	_build_tabs(v)
	v.add_child(_rule())
	_main_box = VBoxContainer.new()
	_main_box.add_theme_constant_override("separation", 12)
	v.add_child(_main_box)
	var outer: VBoxContainer = _main_box
	_friends_page = VBoxContainer.new()
	_friends_page.add_theme_constant_override("separation", 12)
	outer.add_child(_friends_page)
	v = _friends_page

	# step-by-step guide; the current step is highlighted in refresh()
	_steps_label = RichTextLabel.new()
	_steps_label.bbcode_enabled = true
	_steps_label.fit_content = true
	_steps_label.scroll_active = false
	_steps_label.custom_minimum_size = Vector2(560, 0)
	_steps_label.add_theme_font_size_override("normal_font_size", 17)
	v.add_child(_steps_label)

	_name_edit = _edit(mp.my_name, mp.t("name_hint"))
	_name_edit.max_length = 24
	_name_edit.text_changed.connect(func(t: String) -> void: mp.set_player_name(t))
	_field(v, mp.t("your_name"), _name_edit)

	# --- Steam: the easy way, no ports and no IPs
	_steam_label = _label("", 15, COL_DIM, true)
	v.add_child(_steam_label)
	var srow := HBoxContainer.new()
	srow.add_theme_constant_override("separation", 10)
	_steam_host_btn = _button(mp.t("create_game"), func() -> void: mp.host_steam(), true)
	_invite_btn = _button(mp.t("invite_friends"), _toggle_friends, true)
	srow.add_child(_steam_host_btn)
	srow.add_child(_invite_btn)
	v.add_child(srow)
	# an invite somebody sent us, waiting for an answer
	_join_invite_btn = _button("", _on_join_invite, true)
	_join_invite_btn.visible = false
	v.add_child(_join_invite_btn)
	_build_friends(v)
	var row4 := HBoxContainer.new()
	row4.add_theme_constant_override("separation", 10)
	_leave_btn = _danger(_button(mp.t("disconnect"), func() -> void: mp.leave(mp.t("session_closed"))))
	_resync_btn = _button(mp.t("resync"), func() -> void: mp.request_resync())
	row4.add_child(_leave_btn)
	row4.add_child(_resync_btn)
	v.add_child(row4)

	v.add_child(HSeparator.new())
	_status = _label("", 17, COL_TEXT, true)
	v.add_child(_status)
	_progress = ProgressBar.new()
	_progress.custom_minimum_size = Vector2(0, 8)
	_progress.visible = false
	_style_bar(_progress)
	v.add_child(_progress)

	_players_label = RichTextLabel.new()
	_players_label.bbcode_enabled = true
	_players_label.fit_content = true
	_players_label.scroll_active = false
	_players_label.custom_minimum_size = Vector2(560, 0)
	_players_label.add_theme_font_size_override("normal_font_size", 17)
	v.add_child(_players_label)

	_help_label = _label(mp.t("panel_help"), 14, COL_DIM, true)
	v.add_child(_help_label)
	v = outer
	_build_servers(v)
	_build_manage(v)
	# (2026-11-14, test feature) belt replay as a guest (mp_belts.gd), quick A/B
	# (2026-11-15, round 4) no button of its own any more: part of SMOOTH BELTS (dev command belt_replay)
	# (2026-11-15, test feature) smooth belt drawing on this PC (mp_belt_draw.gd)
	# (round 4) the one belt switch for players, on by default, its live state under it
	_close_btn = _button(mp.t("close"), close_panel)
	v.add_child(_close_btn)
	# (#29, 2026-11-17) the settings page (gear in the header): SMOOTH BELTS and the logs switch
	_settings_page = VBoxContainer.new()
	_settings_page.add_theme_constant_override("separation", 12)
	_settings_page.visible = false
	_panel_body.add_child(_settings_page)
	_settings_page.add_child(_caps(mp.t_or("np_settings", "SETTINGS"), 12, COL_TITLE, 2.0))
	_smooth_btn = _button("", func() -> void:
		mp.set_belt_smooth(not mp.belt_smooth)
		refresh())
	_settings_page.add_child(_smooth_btn)
	_smooth_label = _label("", 13, COL_DIM, true)
	_settings_page.add_child(_smooth_label)
	_logs_btn = _button("", func() -> void: mp.set_logs(not mp.logs_on))
	_logs_btn.visible = false
	_settings_page.add_child(_logs_btn)
	_settings_page.add_child(_rule())
	_settings_page.add_child(_button(mp.t_or("np_back", "BACK"), func() -> void: show_settings(false)))
	_page_tabs[1].visible = false
	_page_tabs[2].visible = false


# ---------------------------------------------------------------- settings page (gear)
var _gear_btn: Button = null
var _main_box: VBoxContainer = null
var _settings_page: VBoxContainer = null


func show_settings(open: bool) -> void:
	if _settings_page == null or _main_box == null:
		return
	_settings_page.visible = open
	_main_box.visible = not open
	if _gear_btn != null:
		_gear_btn.queue_redraw()
	refresh()


# a small gear: 8 teeth, a ring, a hole; amber under the mouse or while the page is open
func _draw_gear() -> void:
	if _gear_btn == null:
		return
	var c: Vector2 = _gear_btn.size / 2.0
	var lit: bool = _gear_btn.is_hovered() or (_settings_page != null and _settings_page.visible)
	var col: Color = COL_TITLE if lit else COL_DIM
	for i in 8:
		var a: float = TAU * float(i) / 8.0
		var d := Vector2(cos(a), sin(a))
		_gear_btn.draw_line(c + d * 6.0, c + d * 11.5, col, 4.0, true)
	_gear_btn.draw_circle(c, 8.0, col, true, -1.0, true)
	_gear_btn.draw_circle(c, 3.5, COL_BG, true, -1.0, true)


# ---------------------------------------------------------------- the two pages
var _replay_btn: Button = null
var _smooth_btn: Button = null
var _smooth_label: Label = null
var _friends_page: VBoxContainer = null
var _servers_page: VBoxContainer = null
var _page_tabs: Array = []   # [friends lit, friends plain, servers lit, servers plain]
var _servers_list: VBoxContainer = null
var _servers_name: LineEdit = null
var _servers_state: Label = null
var _servers_create: Button = null
var _servers_linked := false
var _servers_search: LineEdit = null
var _servers_you: VBoxContainer = null
var _servers_you_text: Label = null
var _servers_invite: Button = null
var _servers_host_box: VBoxContainer = null
var _servers_full_btn: Button = null
var _servers_other_btn: Button = null
var _servers_rows: Array = []
var _hide_full := false
var _hide_other := true
const BIG_LOBBY := 5

func _build_tabs(v: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	v.add_child(row)
	var friends: String = mp.t_or("tab_friends", "PLAY WITH FRIENDS")
	var servers: String = mp.t_or("tab_servers", "PUBLIC SERVERS")
	_page_tabs = [_page_tab(friends, func() -> void: show_page(false), true), _page_tab(friends, func() -> void: show_page(false), false),
		_page_tab(servers, func() -> void: show_page(true), true), _page_tab(servers, func() -> void: show_page(true), false)]
	for b in _page_tabs:
		row.add_child(b)
	# public servers switched off (mp.PUBLIC_SERVERS): no tabs, only the friends page
	row.visible = mp.PUBLIC_SERVERS


# A page tab: plain text on the card, the open one in amber with a line under it.
func _page_tab(text: String, cb: Callable, open: bool) -> Button:
	var b := _button(text, cb)
	for st in ["normal", "hover", "pressed", "focus", "disabled"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(COL_TITLE, 0.06) if open else (Color(1, 0.95, 0.85, 0.04) if st == "hover" else Color(0, 0, 0, 0))
		sb.border_width_bottom = 2
		sb.border_color = COL_TITLE if open else Color(1, 0.95, 0.85, 0.08)
		sb.content_margin_left = 16
		sb.content_margin_right = 16
		b.add_theme_stylebox_override(st, sb)
	var col := COL_TITLE if open else COL_DIM
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(c, COL_TEXT if (c == "font_hover_color" and not open) else col)
	return b


func show_page(servers: bool) -> void:
	if not mp.PUBLIC_SERVERS:
		servers = false
	_friends_page.visible = not servers
	_servers_page.visible = servers
	_page_tabs[0].visible = not servers
	_page_tabs[1].visible = servers
	_page_tabs[2].visible = servers
	_page_tabs[3].visible = not servers
	if servers:
		if _servers_name.text == "":
			_servers_name.text = (mp.t_or("servers_my", "%s's server") % mp.my_name).substr(0, 32)
		if mp.steam_ready():
			if not _servers_linked:
				_servers_linked = true
				mp.steam.lobbies_found.connect(_fill_servers)
			_ask_servers()
		else:
			_servers_state.text = mp.t("steam_unavailable")
	refresh()
	_panel_scroll.scroll_vertical = 0


func _build_servers(v: VBoxContainer) -> void:
	_servers_page = VBoxContainer.new()
	_servers_page.add_theme_constant_override("separation", 10)
	_servers_page.visible = false
	v.add_child(_servers_page)
	var experimental := _label(mp.t("servers_experimental"), 18, COL_BAD, true)
	experimental.custom_minimum_size = Vector2(576, 0)
	_servers_page.add_child(experimental)
	# when you are in a game: what it is and what to do next, on top
	_servers_you = VBoxContainer.new()
	_servers_you.add_theme_constant_override("separation", 8)
	_servers_you.visible = false
	_servers_page.add_child(_servers_you)
	_servers_you_text = _label("", 16, COL_TITLE, true)
	_servers_you_text.custom_minimum_size = Vector2(576, 0)
	_servers_you.add_child(_servers_you_text)
	var you_row := HBoxContainer.new()
	you_row.add_theme_constant_override("separation", 10)
	_servers_invite = _button(mp.t("invite_friends"), func() -> void: mp.steam.invite_overlay())
	you_row.add_child(_servers_invite)
	you_row.add_child(_danger(_button(mp.t("disconnect"), func() -> void: mp.leave(mp.t("session_closed")))))
	_servers_you.add_child(you_row)
	_servers_you.add_child(_rule())
	# looking for a game comes first: most players are here to join
	var find := HBoxContainer.new()
	find.add_theme_constant_override("separation", 8)
	_servers_search = _edit("", mp.t_or("servers_search", "Search servers"))
	_servers_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_servers_search.text_changed.connect(func(_t: String) -> void: _draw_servers())
	find.add_child(_servers_search)
	_servers_full_btn = _small_button("", func() -> void:
		_hide_full = not _hide_full
		_draw_servers())
	find.add_child(_servers_full_btn)
	_servers_other_btn = _small_button("", func() -> void:
		_hide_other = not _hide_other
		_draw_servers())
	find.add_child(_servers_other_btn)
	_servers_page.add_child(find)
	var head := HBoxContainer.new()
	_servers_state = _label("", 14, COL_DIM)
	_servers_state.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_servers_state)
	head.add_child(_small_button(mp.t_or("friends_reload", "REFRESH"), _ask_servers))
	_servers_page.add_child(head)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(576, 280)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_servers_page.add_child(scroll)
	_servers_list = VBoxContainer.new()
	_servers_list.add_theme_constant_override("separation", 6)
	_servers_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_servers_list)
	# then your own
	_servers_host_box = VBoxContainer.new()
	_servers_host_box.add_theme_constant_override("separation", 10)
	_servers_page.add_child(_servers_host_box)
	_servers_host_box.add_child(_rule())
	_servers_host_box.add_child(_caps(mp.t_or("servers_host", "Host your own"), 12, COL_TITLE, 2.0))
	var make := HBoxContainer.new()
	make.add_theme_constant_override("separation", 10)
	_servers_name = _edit("", mp.t_or("servers_name", "Server name"))
	_servers_name.max_length = 32
	_servers_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	make.add_child(_servers_name)
	_servers_create = _button(mp.t_or("servers_create", "CREATE SERVER"), _create_server, true)
	_servers_create.custom_minimum_size = Vector2(190, 44)
	_servers_create.size_flags_horizontal = Control.SIZE_SHRINK_END
	make.add_child(_servers_create)
	_servers_host_box.add_child(make)
	var warn := _label(mp.t_or("servers_warning", "Anyone can join and change or take down anything. Use a save you do not mind losing."), 13, COL_DIM, true)
	warn.custom_minimum_size = Vector2(576, 0)
	_servers_host_box.add_child(warn)
	var again := Timer.new()
	again.wait_time = SERVERS_REFRESH
	again.autostart = true
	again.timeout.connect(_refresh_servers)
	_servers_page.add_child(again)
	_update_filter_buttons()


# A secondary button for leaving or removing: red lettering, a faint red edge.
func _danger(b: Button) -> Button:
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(c, COL_BAD)
	for st in ["normal", "hover", "pressed", "focus"]:
		var sb := b.get_theme_stylebox(st).duplicate() as StyleBoxFlat
		if sb != null:
			sb.border_color = Color(COL_BAD, 0.55 if st == "hover" else 0.3)
			if st == "hover":
				sb.bg_color = Color(COL_BAD, 0.1)
			b.add_theme_stylebox_override(st, sb)
	return b


func _small_button(text: String, cb: Callable) -> Button:
	var b := _button(text, cb)
	b.size_flags_horizontal = Control.SIZE_SHRINK_END
	b.custom_minimum_size = Vector2(110, 40)
	b.add_theme_font_size_override("font_size", 14)
	return b


func _update_filter_buttons() -> void:
	_servers_full_btn.text = mp.t_or("servers_full_hidden", "FULL: HIDDEN") if _hide_full else mp.t_or("servers_full_shown", "FULL: SHOWN")
	_servers_other_btn.text = mp.t_or("servers_other_hidden", "OTHER VERSIONS: HIDDEN") if _hide_other else mp.t_or("servers_other_shown", "OTHER VERSIONS: SHOWN")


# On its own every little while, only while somebody is looking at the list.
const SERVERS_REFRESH := 20.0

func _refresh_servers() -> void:
	if _root.visible and _servers_page.visible and mp.steam_ready():
		mp.steam.find_lobbies()


func _ask_servers() -> void:
	_servers_state.text = mp.t_or("servers_looking", "Looking for servers...")
	mp.steam.find_lobbies()


func _fill_servers(rows: Array) -> void:
	_servers_rows = rows
	_draw_servers()


func _server_full(r: Dictionary) -> bool:
	return int(r["limit"]) > 0 and int(r["players"]) >= int(r["limit"])


func _draw_servers() -> void:
	if not is_instance_valid(_servers_list):
		return
	_update_filter_buttons()
	for c in _servers_list.get_children():
		_servers_list.remove_child(c)
		c.queue_free()
	var wanted := _servers_search.text.strip_edges().to_lower()
	var rows: Array = []
	# our own server is not in the list: it cannot be joined, and it made the count lie
	var mine: int = int(mp.steam.get("lobby_id")) if mp.steam != null else 0
	_servers_rows = _servers_rows.filter(func(r): return mine == 0 or int(r["id"]) != mine)
	for r in _servers_rows:
		if wanted != "" and not str(r["name"]).to_lower().contains(wanted):
			continue
		if _hide_other and r["ver"] != mp.VERSION:
			continue
		if _hide_full and _server_full(r):
			continue
		rows.append(r)
	# what can be joined first, the busiest on top; full ones after, other versions last
	var rank := func(r: Dictionary) -> int:
		if r["ver"] != mp.VERSION:
			return 2
		return 1 if _server_full(r) else 0
	rows.sort_custom(func(a, b):
		var ra: int = rank.call(a)
		var rb: int = rank.call(b)
		return ra < rb if ra != rb else int(a["players"]) > int(b["players"]))
	var open := 0
	for r in _servers_rows:
		if r["ver"] == mp.VERSION and not _server_full(r):
			open += 1
	_servers_state.text = (mp.t_or("servers_count_one", "1 server, %d you can join") % open) if _servers_rows.size() == 1 		else mp.t_or("servers_count", "%d servers, %d you can join") % [_servers_rows.size(), open]
	if rows.is_empty():
		var none: String = (mp.t_or("servers_none_in_game", "No other public servers right now.") if mp.active() else mp.t_or("servers_none", "No public servers right now. Create the first one below!")) if _servers_rows.is_empty() else mp.t_or("servers_none_shown", "No server matches. Change the search or the filters above.")
		var hint := _label(none, 16, COL_DIM, true)
		hint.custom_minimum_size = Vector2(560, 0)
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_servers_list.add_child(hint)
	for r in rows:
		_servers_list.add_child(_server_card(r))


func _server_card(r: Dictionary) -> Control:
	var big := int(r["players"]) >= BIG_LOBBY
	var card := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 0.95, 0.85, 0.04)
	sb.border_width_left = 3
	sb.border_color = COL_TITLE if big else COL_LINE
	sb.set_corner_radius_all(2)
	sb.content_margin_left = 12
	sb.content_margin_right = 8
	sb.content_margin_top = 7
	sb.content_margin_bottom = 7
	card.add_theme_stylebox_override("panel", sb)
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 10)
	card.add_child(line)
	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_theme_constant_override("separation", 1)
	line.add_child(text)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	text.add_child(top)
	var shown: String = str(r["name"]) if str(r["name"]) != "" else mp.t_or("server_default", "NEEDLE PARTY server")
	var title := _label(shown, 17, COL_TEXT)
	title.clip_text = true
	title.custom_minimum_size = Vector2(120, 0)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(title)
	var state: String = mp.t_or("servers_playing", "Playing") if r["world"] else mp.t_or("servers_waiting", "Host in the menu")
	var same: bool = r["ver"] == mp.VERSION
	var bits := PackedStringArray([mp.t_or("servers_players", "%d/%d players") % [r["players"], r["limit"]], state])
	if r["world"]:
		bits.append(mp.t_or("servers_size", "%d buildings, %d machines") % [r["buildings"], r["machines"]])
	if not same:
		bits.append("v%s" % r["ver"])
	text.add_child(_label("  ·  ".join(bits), 13, COL_DIM))
	var full := _server_full(r)
	var label: String = mp.t_or("servers_join", "JOIN")
	if not same:
		label = mp.t_or("servers_other", "OTHER VERSION")
	elif full:
		label = mp.t_or("servers_is_full", "FULL")
	var id := int(r["id"])
	var join := _button(label, func() -> void: _join_server(id), same and not full)
	join.size_flags_horizontal = Control.SIZE_SHRINK_END
	join.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	join.custom_minimum_size = Vector2(150, 40)
	join.add_theme_font_size_override("font_size", 15)
	join.disabled = not same or full or mp.active()
	line.add_child(join)
	return card


func _create_server() -> void:
	# the first time on this PC: what public servers are and what can happen
	if not mp.public_told:
		show_public_notice(func() -> void:
			mp.host_public(_servers_name.text)
			refresh())
		return
	mp.host_public(_servers_name.text)
	refresh()


func _join_server(id: int) -> void:
	mp.join_steam(id)
	refresh()


# In a game: say what it is and what comes next, instead of the form to make another.
func _update_servers_you(on: bool) -> void:
	_servers_you.visible = on
	_servers_host_box.visible = not on
	_servers_invite.disabled = not (on and mp.over_steam)
	if not on:
		return
	if mp.is_host:
		_servers_you_text.text = mp.t_or("servers_you_playing", "Your server is online. Players can join now.") if mp.in_world() \
			else mp.t_or("servers_you_load", "Your server is online. Next: close this and click NEW GAME or LOAD GAME. Players can join once your world is up.")
	else:
		_servers_you_text.text = mp.t_or("servers_you_joined", "You are in a game.") if mp.in_world() else mp.t_or("servers_you_joining", "Joining the server...")
	# the JOIN buttons follow
	_draw_servers()


# ---------------------------------------------------------------- anonymous logs
var _logs_btn: Button = null
var _logs_card: Control = null

# Once: what the logs are and how to turn them off, before any goes out (see mp_logs.gd).
func show_logs_notice() -> void:
	if is_instance_valid(_logs_card) or not mp.logs_need_notice():
		return
	var root := ColorRect.new()
	root.color = Color(0.02, 0.018, 0.015, 0.75)
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	_logs_card = root
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var card := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = COL_BG
	sb.set_border_width_all(1)
	sb.border_color = COL_LINE
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 32
	sb.content_margin_right = 32
	sb.content_margin_top = 26
	sb.content_margin_bottom = 26
	card.add_theme_stylebox_override("panel", sb)
	card.custom_minimum_size = Vector2(640, 0)
	center.add_child(card)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	card.add_child(v)
	v.add_child(_label(mp.t("logs_title"), 28, COL_TEXT))
	var body := _label(mp.t("logs_text"), 17, COL_TEXT, true)
	body.custom_minimum_size = Vector2(576, 0)
	v.add_child(body)
	# (#29, 2026-11-17) one big OK; turning off stays one click, as a small dim link under it
	v.add_child(_button(mp.t("logs_ok"), func() -> void: _logs_answer(true), true))
	v.add_child(_small_link(mp.t("logs_turn_off"), func() -> void: _logs_answer(false)))


# A small, dim, flat text button (no frame), centred: for rarely used switches.
func _small_link(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.flat = true
	b.focus_mode = Control.FOCUS_NONE
	b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	b.add_theme_font_size_override("font_size", 13)
	b.add_theme_color_override("font_color", COL_DIM)
	b.add_theme_color_override("font_hover_color", COL_TEXT)
	b.add_theme_color_override("font_pressed_color", COL_TEXT)
	b.add_theme_color_override("font_focus_color", COL_DIM)
	var f := _font()
	if f != null:
		b.add_theme_font_override("font", f)
	b.pressed.connect(cb)
	return b


func _logs_answer(on: bool) -> void:
	mp.set_logs(on)
	if is_instance_valid(_logs_card):
		_logs_card.queue_free()
	_logs_card = null


func _build_feed() -> void:
	_feed = VBoxContainer.new()
	_feed.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_feed.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_feed.alignment = BoxContainer.ALIGNMENT_END
	_feed.add_theme_constant_override("separation", 6)
	_feed.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_feed)
	# bottom centre, above the hotbar: clear of the menu column and the HUD cards
	_feed.anchor_left = 0.5
	_feed.anchor_right = 0.5
	_feed.anchor_top = 1.0
	_feed.anchor_bottom = 1.0
	_feed.offset_top = -432
	_feed.offset_bottom = -212
	_feed.offset_left = -280
	_feed.offset_right = 280


func _build_roster() -> void:
	_roster = RichTextLabel.new()
	_roster.bbcode_enabled = true
	_roster.fit_content = true
	_roster.scroll_active = false
	_roster.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_roster.add_theme_font_size_override("normal_font_size", 16)
	_roster.add_theme_constant_override("outline_size", 5)
	_roster.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_roster.anchor_left = 1.0
	_roster.anchor_right = 1.0
	_roster.offset_left = -300
	_roster.offset_right = -16
	_roster.offset_top = 150
	_roster.offset_bottom = 400
	add_child(_roster)


# Looks like the lobby's rename field: dark, square, a gold hairline, with the
# game's own Enter key art in front. Sits just above the hotbar.
func _build_chat() -> void:
	_chat_box = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = COL_FIELD
	sb.set_border_width_all(1)
	sb.border_color = COL_TITLE
	sb.content_margin_left = 14
	sb.content_margin_right = 18
	sb.content_margin_top = 6
	sb.content_margin_bottom = 7
	_chat_box.add_theme_stylebox_override("panel", sb)
	_chat_box.anchor_left = 0.5
	_chat_box.anchor_right = 0.5
	_chat_box.anchor_top = 1.0
	_chat_box.anchor_bottom = 1.0
	_chat_box.offset_left = -360
	_chat_box.offset_right = 360
	_chat_box.offset_top = -206
	_chat_box.offset_bottom = -162
	_chat_box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_chat_box.visible = false
	add_child(_chat_box)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	_chat_box.add_child(row)
	row.add_child(_key_cap("enter", "ENTER"))

	_chat_edit = LineEdit.new()
	_chat_edit.placeholder_text = mp.t("chat_hint")
	_chat_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_edit.max_length = 200
	_chat_edit.context_menu_enabled = false
	# the box above is the frame, the field itself draws nothing
	for st in ["normal", "focus", "read_only"]:
		_chat_edit.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	var cls := _ui_font()
	if cls != null:
		_chat_edit.add_theme_font_override("font", cls.call("regular"))
	_chat_edit.add_theme_font_size_override("font_size", 20)
	_chat_edit.add_theme_color_override("font_color", COL_TEXT)
	_chat_edit.add_theme_color_override("font_placeholder_color", Color(COL_DIM, 0.7))
	_chat_edit.add_theme_color_override("caret_color", COL_TITLE)
	_chat_edit.text_submitted.connect(_on_chat_submit)
	row.add_child(_chat_edit)


# A key the way the game's hints draw it: its own keycap art when there is
# one, a small dark chip with the key name otherwise.
func _key_cap(key: String, fallback: String) -> Control:
	var icons := _global_class("InputIcons")
	var tex: Variant = icons.call("named", key) if icons != null else null
	if tex is Texture2D:
		var r := TextureRect.new()
		r.texture = tex
		r.custom_minimum_size = Vector2(34, 30)
		r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		r.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		r.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		return r
	var chip := PanelContainer.new()
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.55)
	sb.set_border_width_all(1)
	sb.border_color = Color(1, 1, 1, 0.2)
	sb.content_margin_left = 7
	sb.content_margin_right = 7
	sb.content_margin_top = 3
	sb.content_margin_bottom = 3
	chip.add_theme_stylebox_override("panel", sb)
	chip.add_child(_styled(fallback, 17, Color(0.94, 0.96, 1.0), 0, true))
	return chip


# A guest who accepts an invite has nothing to press and nothing to look at
# while the host picks a save, so spell out every step of the hand-off. Right
# hand side, vertically centred: clear of the menu column and of the hotbar.
# It shows over the title screen, so it reads like the lobby's slot card.
func _build_wait() -> void:
	_wait = PanelContainer.new()
	_wait.visible = false
	_wait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wait.add_theme_stylebox_override("panel", _card())
	_wait.anchor_left = 1.0
	_wait.anchor_right = 1.0
	_wait.anchor_top = 0.5
	_wait.anchor_bottom = 0.5
	_wait.offset_left = -(WAIT_W + 44.0)
	_wait.offset_right = -44.0
	_wait.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(_wait)

	var v := VBoxContainer.new()
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_theme_constant_override("separation", 10)
	_wait.add_child(v)

	_wait_title = _styled(mp.t("wait_title"), 21, COL_TITLE, 5, true)
	v.add_child(_wait_title)
	_wait_sub = _styled("", 16, COL_DIM)
	v.add_child(_wait_sub)

	var rows := VBoxContainer.new()
	rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rows.add_theme_constant_override("separation", 2)
	v.add_child(rows)
	for i in Step.size():
		# every row has the edge, only the current one shows it
		var box := PanelContainer.new()
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0, 0, 0, 0)
		sb.border_color = Color(COL_TITLE, 0)
		sb.border_width_left = 3
		sb.content_margin_left = 10
		sb.content_margin_right = 8
		sb.content_margin_top = 3
		sb.content_margin_bottom = 3
		box.add_theme_stylebox_override("panel", sb)
		var row := HBoxContainer.new()
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_theme_constant_override("separation", 8)
		box.add_child(row)
		var mark := _styled("", 16, COL_DONE)
		mark.custom_minimum_size.x = 14
		mark.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		# the row has a real width here, so wrapping behaves
		var name_l := _styled("", 16, COL_OFF)
		name_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(mark)
		row.add_child(name_l)
		rows.add_child(box)
		_wait_marks.append(mark)
		_wait_names.append(name_l)
		_wait_rows.append(sb)

	_wait_bar = ProgressBar.new()
	_wait_bar.custom_minimum_size = Vector2(0, 6)
	_wait_bar.visible = false
	_style_bar(_wait_bar, true)
	v.add_child(_wait_bar)

	_wait_hint = _styled("", 16, COL_DIM)
	_wait_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_wait_hint)


# ---------------------------------------------------------------- behaviour

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_note_click()
		_click_to_front()
	elif _mouse_freed and event is InputEventMouseMotion:
		# the mouse passing over a window in the background is not looking around
		get_viewport().set_input_as_handled()
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var k: int = event.keycode
	# our own windows take the keys while they are up (typing goes to their field)
	if is_instance_valid(_bug_card) or is_instance_valid(_public_card):
		if k == KEY_ESCAPE:
			if is_instance_valid(_bug_card):
				_close_bug()
			else:
				_close_public()
			get_viewport().set_input_as_handled()
		return
	if _chat_box.visible:
		if k == KEY_ESCAPE:
			_close_chat()
			get_viewport().set_input_as_handled()
		return
	if k == KEY_F9:
		if _root.visible:
			close_panel()
		else:
			open_panel()
		get_viewport().set_input_as_handled()
	elif k == KEY_ESCAPE and _root.visible:
		close_panel()
		get_viewport().set_input_as_handled()
	elif (k == KEY_ENTER or k == KEY_KP_ENTER) and mp.active() and mp.in_world() and not _root.visible \
	and not (get_viewport().gui_get_focus_owner() is LineEdit or get_viewport().gui_get_focus_owner() is TextEdit):
		_open_chat()
		get_viewport().set_input_as_handled()
	elif k == KEY_F6 and mp.in_world():
		_toggle_debug_menu()
		get_viewport().set_input_as_handled()
	elif k == KEY_F10 and mp.has_invite():
		mp.accept_invite()
		refresh()
		get_viewport().set_input_as_handled()
	elif k == KEY_F8 and mp.active():
		mp.request_resync()
		get_viewport().set_input_as_handled()
	elif k == KEY_F11 and not _root.visible and mp.reporter != null and mp.reporter.has_method("report_bug"):
		# the game's own bug key is F7; this one sends our log, from every PC in the
		# session (a test build's reporter has F11 of its own and gets it instead)
		_open_bug()
		get_viewport().set_input_as_handled()


# The game ships a debug menu (money, items, unlocks, tech, needles) that it
# only builds once it has been unlocked in game. Build it ourselves and put it
# on F6, so a session can be set up without grinding for hay first.
func _toggle_debug_menu() -> void:
	var w: Node = mp.world_sync.world
	var dm: Variant = w.get("debug_menu")
	if dm == null or not is_instance_valid(dm):
		var cls := _global_class("DebugMenu")
		if cls == null:
			notify(mp.t("no_debug_menu"))
			return
		# the 29 Sep game build dropped the menu's own key from the input map, and
		# the menu asks for it on every key press: thousands of errors in the log
		if not InputMap.has_action("debug_menu"):
			InputMap.add_action("debug_menu")
		dm = cls.new()
		dm.name = "DebugMenu"
		dm.player = w.get("player")
		dm.world = w
		dm.props = w.get("props")
		dm.hud = w.get("hud")
		dm.live = w.get("live")
		dm.builds = w.get("builds")
		add_child(dm)
		w.set("debug_menu", dm)
		_add_take_money(dm)
	dm.toggle()
	if dm.is_open():
		_release_mouse()
	else:
		_restore_mouse()


# The menu only hands out money. Put the other direction next to it, on the
# same row, so a session can be set back to being poor as well.
func _add_take_money(dm: Node) -> void:
	var row := _find_money_row(dm)
	if row == null:
		return
	for amount in [100.0, 1000.0, 10000.0]:
		var label := "-$%s" % _money_text(amount)
		row.add_child(dm._button(label, dm._on_grant.bind(-amount)))


func _find_money_row(n: Node) -> Node:
	for child in n.get_children():
		if child is HBoxContainer:
			for b in child.get_children():
				if b is Button and (b as Button).text.begins_with("+$"):
					return child
		var found := _find_money_row(child)
		if found != null:
			return found
	return null


func _money_text(amount: float) -> String:
	var n := int(amount)
	var out := ""
	while n >= 1000:
		out = ",%03d%s" % [n % 1000, out]
		n /= 1000
	return "%d%s" % [n, out]


func _world_player() -> Node:
	if mp.world_sync != null and is_instance_valid(mp.world_sync.player):
		return mp.world_sync.player
	return null


func _release_mouse() -> void:
	var p := _world_player()
	# a second panel opening over the first must not forget it was captured
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_mouse_was_captured = true
	if p != null and p.has_method("capture_mouse"):
		p.capture_mouse(false)
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _debug_menu_open() -> bool:
	var w: Variant = mp.world_sync.world if mp.world_sync != null else null
	var dm: Variant = w.get("debug_menu") if w != null and is_instance_valid(w) else null
	return dm != null and is_instance_valid(dm) and dm.has_method("is_open") and bool(dm.call("is_open"))


func _restore_mouse() -> void:
	if not _mouse_was_captured:
		return
	# another of our panels is still up: the last one to close gives it back
	if _root.visible or _chat_box.visible or is_instance_valid(_bug_card) or _debug_menu_open():
		return
	_mouse_was_captured = false
	var p := _world_player()
	if p != null and p.has_method("capture_mouse"):
		p.capture_mouse(true)


func open_panel() -> void:
	if _root.visible:
		return
	_name_edit.text = mp.my_name
	show_settings(false)
	_root.visible = true
	# fade the backdrop in and let the card settle from slightly smaller
	_root.modulate.a = 0.0
	_panel.pivot_offset = _panel.size / 2.0
	_panel.scale = Vector2(0.96, 0.96)
	_panel.scale = Vector2(0.985, 0.985)
	var tw := _root.create_tween().set_parallel(true)
	tw.tween_property(_root, "modulate:a", 1.0, 0.12)
	tw.tween_property(_panel, "scale", Vector2.ONE, 0.16).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	_release_mouse()
	refresh()


func close_panel() -> void:
	if not _root.visible:
		return
	_root.visible = false
	_restore_mouse()
	_update_wait()  # the card stands in for the panel once it is closed


func _open_chat() -> void:
	_chat_box.visible = true
	_chat_edit.text = ""
	_release_mouse()
	_chat_edit.grab_focus.call_deferred()


func _close_chat() -> void:
	_chat_edit.release_focus()
	_chat_box.visible = false
	_restore_mouse()


func _on_chat_submit(text: String) -> void:
	mp.send_chat(text)
	_close_chat()


# ---------------------------------------------------------------- our own windows
# A card in the middle of the dimmed screen, the panel's look: the hazard band and a
# small caps line on top, then the title. [the full-screen layer, the card's column]
func _modal(kicker: String, title: String, width := 600.0) -> Array:
	var root := ColorRect.new()
	root.color = Color(0.02, 0.018, 0.015, 0.72)
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(root)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var card := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = COL_BG
	sb.set_border_width_all(1)
	sb.border_color = COL_LINE
	sb.set_corner_radius_all(3)
	sb.shadow_color = Color(0, 0, 0, 0.55)
	sb.shadow_size = 28
	sb.shadow_offset = Vector2(0, 10)
	sb.content_margin_left = 32
	sb.content_margin_right = 32
	sb.content_margin_top = 26
	sb.content_margin_bottom = 26
	card.add_theme_stylebox_override("panel", sb)
	card.custom_minimum_size = Vector2(width, 0)
	center.add_child(card)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	card.add_child(v)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)
	top.add_child(_caps(kicker, 12, COL_TITLE, 3.0))
	v.add_child(top)
	v.add_child(_label(title, 32, COL_TEXT))
	return [root, v]


# ---------------------------------------------------------------- bug report (F11)
# One line about what went wrong, and what kind of problem it is, then a log goes
# out from every PC in the session (mp_logs.report_bug). Only with the logs on:
# that is where it goes.
const BUG_KINDS := ["lag", "sync", "broken", "other"]
var _bug_card: Control = null
var _bug_edit: LineEdit = null
var _bug_count: Label = null
var _bug_kind := ""
var _bug_kinds := {}  # kind -> [lit button, plain button]


func _open_bug() -> void:
	if not mp.logs_available():
		notify(mp.t("bug_no_logs"))
		return
	if not mp.logs_on or not mp.logs_told:
		notify(mp.t("bug_logs_off"))
		return
	if is_instance_valid(_bug_card):
		return
	if _chat_box.visible:
		_close_chat()
	var m := _modal(mp.t("bug_kicker"), mp.t("bug_title"), 600.0)
	_bug_card = m[0]
	var v: VBoxContainer = m[1]
	var ask := _label(mp.t("bug_question"), 17, COL_DIM, true)
	ask.custom_minimum_size = Vector2(536, 0)
	v.add_child(ask)
	# what kind of problem: one click, and it can be left out
	var kinds := HBoxContainer.new()
	kinds.add_theme_constant_override("separation", 8)
	_bug_kind = ""
	_bug_kinds = {}
	for kind in BUG_KINDS:
		var lit := _button(mp.t("bug_" + kind), func() -> void: _pick_bug_kind(kind), true)
		var plain := _button(mp.t("bug_" + kind), func() -> void: _pick_bug_kind(kind))
		for b in [lit, plain]:
			(b as Button).custom_minimum_size = Vector2(0, 38)
			(b as Button).add_theme_font_size_override("font_size", 14)
			kinds.add_child(b)
		lit.visible = false
		_bug_kinds[kind] = [lit, plain]
	v.add_child(kinds)
	_bug_edit = _edit("", mp.t("bug_hint"))
	_bug_edit.max_length = 200
	_bug_edit.text_submitted.connect(func(_t: String) -> void: _send_bug())
	_bug_edit.text_changed.connect(func(t: String) -> void:
		_bug_count.text = "%d / 200" % t.length()
		_bug_count.add_theme_color_override("font_color", COL_BAD if t.length() >= 200 else (COL_TITLE if t.length() >= 180 else COL_DIM)))
	v.add_child(_bug_edit)
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 12)
	var info := _label(mp.t("bug_info"), 13, COL_DIM, true)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(info)
	_bug_count = _label("0 / 200", 13, COL_DIM)
	foot.add_child(_bug_count)
	v.add_child(foot)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.add_child(_button(mp.t("bug_send"), _send_bug, true))
	row.add_child(_button(mp.t("bug_cancel"), _close_bug))
	v.add_child(row)
	_release_mouse()
	if _bug_draft != "" or _bug_draft_kind != "":
		_bug_edit.text = _bug_draft
		_bug_count.text = "%d / 200" % _bug_draft.length()
		if _bug_draft_kind != "":
			_pick_bug_kind(_bug_draft_kind)
	_bug_edit.grab_focus.call_deferred()


# (1.2.19) A click into the world (or the game's free-mouse key) took the mouse back while
# the F11 box was open, and the player played on with it open: every key went into the
# note (a 1.2.18 report read "dwwaasdwwwww...": walking). Back in the game means done with
# the box for now: it closes, and what was typed is there again on the next F11.
var _bug_draft := ""
var _bug_draft_kind := ""

func _watch_bug_box() -> void:
	if not is_instance_valid(_bug_card) or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	_bug_draft = _bug_edit.text if is_instance_valid(_bug_edit) else ""
	_bug_draft_kind = _bug_kind
	mp.trace.note("bug box closed: the player went back to the game")
	if is_instance_valid(_bug_card):
		_bug_card.queue_free()
	_bug_card = null
	_mouse_was_captured = false   # the game has it already


func _pick_bug_kind(kind: String) -> void:
	_bug_kind = "" if _bug_kind == kind else kind
	for k in _bug_kinds:
		(_bug_kinds[k][0] as Button).visible = k == _bug_kind
		(_bug_kinds[k][1] as Button).visible = k != _bug_kind


func _send_bug() -> void:
	if not is_instance_valid(_bug_card):
		return
	var text := _bug_edit.text.strip_edges()
	if _bug_kind != "":
		text = ("[%s] %s" % [_bug_kind, text]).strip_edges()
	var why := str(mp.reporter.call("report_bug", text)) if mp.reporter != null and mp.reporter.has_method("report_bug") else "bug_no_logs"
	_bug_draft = ""
	_bug_draft_kind = ""
	_close_bug()
	notify(mp.t(why if why != "" else "bug_sent"), COL_DONE if why == "" else COL_TITLE)


func _close_bug() -> void:
	# sent or cancelled: no draft to bring back
	_bug_draft = ""
	_bug_draft_kind = ""
	if is_instance_valid(_bug_card):
		_bug_card.queue_free()
	_bug_card = null
	_restore_mouse()


# ---------------------------------------------------------------- public servers note
# Before the first public server on this PC: what it is and what can happen.
var _public_card: Control = null


func show_public_notice(go: Callable) -> void:
	if is_instance_valid(_public_card):
		return
	var m := _modal(mp.t("public_kicker"), mp.t("public_title"), 620.0)
	_public_card = m[0]
	var v: VBoxContainer = m[1]
	var body := _label(mp.t("public_text"), 17, COL_TEXT, true)
	body.custom_minimum_size = Vector2(556, 0)
	v.add_child(body)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.add_child(_button(mp.t("public_ok"), func() -> void:
		mp.set_public_told()
		_close_public()
		go.call(), true))
	row.add_child(_button(mp.t("public_back"), _close_public))
	v.add_child(row)


func _close_public() -> void:
	if is_instance_valid(_public_card):
		_public_card.queue_free()
	_public_card = null


# ---------------------------------------------------------------- kick and ban (host)
# Everyone else in the game with KICK and BAN. BAN asks once more, so a slip of the
# mouse never bans a friend. CLEAR BANS undoes every ban made on this PC.
const BAN_ARM_MS := 4000
var _manage: VBoxContainer = null
var _manage_rows: VBoxContainer = null
var _manage_clear: Button = null
var _manage_said := ""
var _ban_armed := -1
var _ban_armed_at := 0


func _build_manage(v: VBoxContainer) -> void:
	_manage = VBoxContainer.new()
	_manage.add_theme_constant_override("separation", 6)
	_manage.visible = false
	v.add_child(_manage)
	_manage.add_child(_rule())
	_manage.add_child(_caps(mp.t("players_head"), 12, COL_TITLE, 2.0))
	_manage_rows = VBoxContainer.new()
	_manage_rows.add_theme_constant_override("separation", 4)
	_manage.add_child(_manage_rows)
	_manage_clear = _small_button("", func() -> void: mp.clear_bans())
	_manage_clear.custom_minimum_size = Vector2(220, 36)
	_manage.add_child(_manage_clear)


func _update_manage() -> void:
	if _manage == null:
		return
	var host_on: bool = mp.active() and mp.is_host
	var others: Array = []
	if host_on:
		for id in mp.players:
			if int(id) != 1:
				others.append(int(id))
	_manage_clear.text = mp.t("bans_clear") % mp.bans.size()
	_manage_clear.visible = not mp.bans.is_empty() and (host_on or not mp.active())
	_manage.visible = not others.is_empty() or _manage_clear.visible
	if _ban_armed != -1 and Time.get_ticks_msec() - _ban_armed_at > BAN_ARM_MS:
		_ban_armed = -1
	var sig := "%d|%d|" % [_ban_armed, mp.bans.size()]
	for id in others:
		sig += "%d:%s;" % [id, mp.player_name(id)]
	if sig == _manage_said:
		return
	_manage_said = sig
	for c in _manage_rows.get_children():
		_manage_rows.remove_child(c)
		c.queue_free()
	for id in others:
		var pid: int = id
		var p: Dictionary = mp.players[pid]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.add_child(_label("●", 14, p["color"]))
		var who := _label(str(p["name"]), 17, COL_TEXT)
		who.clip_text = true
		who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(who)
		row.add_child(_small_button(mp.t("kick"), func() -> void: mp.kick(pid)))
		var armed := _ban_armed == pid
		var ban := _danger(_small_button(mp.t("ban_sure") if armed else mp.t("ban"), func() -> void: _on_ban(pid)))
		if armed:
			ban.add_theme_color_override("font_color", COL_TEXT)
			var hot := ban.get_theme_stylebox("normal").duplicate() as StyleBoxFlat
			hot.bg_color = Color(COL_BAD, 0.35)
			ban.add_theme_stylebox_override("normal", hot)
		row.add_child(ban)
		_manage_rows.add_child(row)


func _on_ban(pid: int) -> void:
	if _ban_armed == pid and Time.get_ticks_msec() - _ban_armed_at <= BAN_ARM_MS:
		_ban_armed = -1
		mp.kick(pid, true)
	else:
		_ban_armed = pid
		_ban_armed_at = Time.get_ticks_msec()
		get_tree().create_timer(BAN_ARM_MS / 1000.0 + 0.1).timeout.connect(_update_manage)
	_update_manage()


func set_status(text: String) -> void:
	_status.text = text


func set_progress(v: float) -> void:
	_progress_v = v
	_progress.visible = v >= 0.0
	if v >= 0.0:
		_progress.value = v * 100.0
	_update_wait()


func notify(text: String, accent := COL_TITLE) -> void:
	print("[MPMod] ", text)
	set_status(text)
	# the same line twice in a row counts up on the card it already has
	if text == _last_note_text and is_instance_valid(_last_note) and _last_note.get_parent() == _feed:
		_last_note_n += 1
		var badge: Variant = _last_note.get_meta("badge", null)
		if badge is Label:
			(badge as Label).text = mp.t("note_repeat") % _last_note_n
			(badge as Label).visible = true
		_feed.move_child(_last_note, _feed.get_child_count() - 1)
		_feed_life(_last_note, false)
		return
	_last_note_text = text
	_last_note_n = 1
	_last_note = _feed_card(accent, "", text)
	_push_feed(_last_note)


func chat_line(who: String, col: Color, text: String) -> void:
	_forget_note()
	_push_feed(_feed_card(col, mp.t("chat_name") % who, text))


# One notification: the game's HUD card, the player's colour down the edge, the
# name in bold and the message in the regular face. Cards stack upwards and
# age out on their own.
func _feed_card(accent: Color, who: String, text: String) -> PanelContainer:
	var card := PanelContainer.new()
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_theme_stylebox_override("panel", _plate(accent))
	card.modulate.a = 0.0
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 8)
	card.add_child(row)
	if who != "":
		var n := _styled(who, 17, accent, 4, true)
		n.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		row.add_child(n)
	var msg := _styled(text, 17, COL_TEXT)
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	msg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(msg)
	var badge := _styled("", 13, COL_DIM, 3, true)
	badge.visible = false
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(badge)
	card.set_meta("badge", badge)
	return card


func _esc(s: String) -> String:
	return s.replace("[", "[lb]")


func _push_feed(c: Control) -> void:
	_feed.add_child(c)
	while _feed.get_child_count() > FEED_MAX:
		var old := _feed.get_child(0) as Control
		_feed.remove_child(old)
		_drop_feed(old)
	_feed_life(c, true)


# fade in, hold, fade out: nothing is ever overwritten in place
func _feed_life(c: Control, fade_in: bool) -> void:
	_kill_life(c)
	var t := create_tween()
	c.set_meta("tw", t)
	if fade_in:
		t.tween_property(c, "modulate:a", 1.0, FEED_IN)
	else:
		c.modulate.a = 1.0
	t.tween_interval(FEED_SECONDS)
	t.tween_property(c, "modulate:a", 0.0, FEED_OUT)
	t.tween_callback(_drop_feed.bind(c))


func _kill_life(c: Control) -> void:
	# get_meta(key, null) still logs an error when the key is missing
	if not c.has_meta("tw"):
		return
	var tw: Variant = c.get_meta("tw")
	if tw is Tween and (tw as Tween).is_valid():
		(tw as Tween).kill()


func _drop_feed(c: Control) -> void:
	if not is_instance_valid(c):
		return
	_kill_life(c)
	if _last_note == c:
		_forget_note()
	c.queue_free()


func _forget_note() -> void:
	_last_note = null
	_last_note_text = ""
	_last_note_n = 1


# ---------------------------------------------------------------- guest card

# The hand-off is driven by RPCs with no signals to hang off, so poll the
# session state instead: it is a handful of reads and it also catches the host
# dropping back to the menu.
# ---------------------------------------------------------------- player list (Alt)
# Hold Alt in a session (the game also pages the hotbar with Alt;
# we only read the key, so that keeps working): everyone in it, their role, where they are and their
# ping to the host, with signal bars. The key is only read, never eaten, so
# whatever the game itself does with Tab keeps working.
var _tab: PanelContainer
var _tab_rows: VBoxContainer
var _tab_count: Label
var _tab_t := 0.0
var _tab_on := false
const TAB_W := 600.0
const COL_GOOD := Color(0.6, 0.82, 0.45)   # field green
const COL_OK := Color(0.96, 0.74, 0.28)     # amber
const COL_BAD := Color(0.9, 0.4, 0.32)      # brick red


func _build_tab() -> void:
	_tab = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(COL_BG, 0.95)
	sb.set_border_width_all(1)
	sb.border_color = COL_LINE
	sb.set_corner_radius_all(3)
	sb.shadow_color = Color(0, 0, 0, 0.5)
	sb.shadow_size = 22
	sb.shadow_offset = Vector2(0, 8)
	sb.content_margin_left = 22
	sb.content_margin_right = 22
	sb.content_margin_top = 18
	sb.content_margin_bottom = 18
	_tab.add_theme_stylebox_override("panel", sb)
	_tab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab.anchor_left = 0.5
	_tab.anchor_right = 0.5
	_tab.offset_left = -TAB_W / 2.0
	_tab.offset_right = TAB_W / 2.0
	_tab.offset_top = 90
	_tab.visible = false
	_tab.modulate.a = 0.0
	add_child(_tab)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	_tab.add_child(v)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	head.add_child(_caps(mp.t("title"), 14, COL_TEXT, 3.0))
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(gap)
	_tab_count = _caps("", 12, COL_DIM, 2.0)
	_tab_count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	head.add_child(_tab_count)
	v.add_child(head)
	v.add_child(_rule())
	# column heads
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 12)
	cols.add_child(_col_head("PLAYER", 0, true))
	cols.add_child(_col_head("ROLE", 74))
	cols.add_child(_col_head("WHERE", 120))
	cols.add_child(_col_head("PING", 116, false, HORIZONTAL_ALIGNMENT_RIGHT))
	v.add_child(cols)
	_tab_rows = VBoxContainer.new()
	_tab_rows.add_theme_constant_override("separation", 4)
	v.add_child(_tab_rows)


func _col_head(text: String, w: float, expand := false, align := HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := _caps(text, 11, Color(COL_DIM, 0.75), 2.0)
	l.horizontal_alignment = align
	if expand:
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	else:
		l.custom_minimum_size = Vector2(w, 0)
	return l


# the pink-to-purple line used under titles
func _strip(h: int) -> TextureRect:
	var strip := TextureRect.new()
	var grad := Gradient.new()
	grad.set_color(0, COL_TITLE)
	grad.set_color(1, Color(COL_ACCENT, 0.0))
	var gt := GradientTexture2D.new()
	gt.gradient = grad
	gt.width = 256
	gt.height = 1
	strip.texture = gt
	strip.stretch_mode = TextureRect.STRETCH_SCALE
	strip.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	strip.custom_minimum_size = Vector2(0, h)
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return strip


func _ping_colour(ms: int) -> Color:
	if ms <= 70:
		return COL_GOOD
	if ms <= 140:
		return COL_OK
	return COL_BAD


func _ping_bars(ms: int, known: bool) -> HBoxContainer:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	box.alignment = BoxContainer.ALIGNMENT_END
	var lit := 0
	if known:
		lit = 4 if ms <= 50 else (3 if ms <= 90 else (2 if ms <= 150 else 1))
	var col := _ping_colour(ms) if known else COL_OFF
	for i in 4:
		var bar := ColorRect.new()
		bar.custom_minimum_size = Vector2(4, 5 + i * 3)
		bar.size_flags_vertical = Control.SIZE_SHRINK_END
		bar.color = col if i < lit else Color(COL_OFF, 0.35)
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(bar)
	return box


func _fill_tab() -> void:
	for c in _tab_rows.get_children():
		c.queue_free()
	var me := multiplayer.get_unique_id() if multiplayer.multiplayer_peer != null else 1
	var ids: Array = mp.players.keys()
	ids.sort_custom(func(a, b) -> bool:
		if int(a) == 1 or int(b) == 1:
			return int(a) == 1
		return str(mp.players[a]["name"]).to_lower() < str(mp.players[b]["name"]).to_lower())
	_tab_count.text = "%d / %d" % [ids.size(), mp.MAX_PEERS]
	var i := 0
	for id in ids:
		var p: Dictionary = mp.players[id]
		var row := PanelContainer.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(1, 0.95, 0.85, 0.035 if i % 2 == 0 else 0.0)
		if int(id) == me:
			sb.bg_color = Color(COL_TITLE, 0.07)
		sb.border_width_left = 3
		sb.border_color = p.get("color", Color.WHITE)
		sb.set_corner_radius_all(0)
		sb.content_margin_left = 12
		sb.content_margin_right = 10
		sb.content_margin_top = 6
		sb.content_margin_bottom = 6
		row.add_theme_stylebox_override("panel", sb)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 12)
		row.add_child(h)
		var name_l := _label(str(p.get("name", "?")).substr(0, 24), 18, COL_TEXT)
		name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_l.clip_text = true
		h.add_child(name_l)
		if int(id) == me:
			h.add_child(_label("(you)", 13, COL_DIM))
		# role pill
		var host := int(id) == 1
		var pill := PanelContainer.new()
		var ps := StyleBoxFlat.new()
		ps.bg_color = COL_TITLE if host else Color(0, 0, 0, 0)
		ps.set_border_width_all(0 if host else 1)
		ps.border_color = COL_LINE
		ps.set_corner_radius_all(2)
		ps.content_margin_left = 8
		ps.content_margin_right = 8
		ps.content_margin_top = 2
		ps.content_margin_bottom = 3
		pill.add_theme_stylebox_override("panel", ps)
		pill.custom_minimum_size = Vector2(74, 0)
		pill.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var pl := _caps("HOST" if host else "GUEST", 11, COL_INK if host else COL_DIM, 2.0)
		pl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		pill.add_child(pl)
		h.add_child(pill)
		var where: String = str({"world": "in the yard", "loading": "loading…", "lobby": "in the lobby",
			"menu": "in the menu"}.get(str(p.get("state", "")), ""))
		var wl := _label(where, 14, COL_DONE if p.get("state", "") == "world" else COL_DIM)
		wl.custom_minimum_size = Vector2(120, 0)
		h.add_child(wl)
		# ping: number and bars
		var known: bool = host or mp.pings.has(id) or mp.pings.has(int(id))
		var ms := 0 if host else int(mp.pings.get(id, mp.pings.get(int(id), 0)))
		var pbox := HBoxContainer.new()
		pbox.add_theme_constant_override("separation", 8)
		pbox.custom_minimum_size = Vector2(116, 0)
		pbox.alignment = BoxContainer.ALIGNMENT_END
		var txt := "host" if host else ("%d ms" % ms if known else "…")
		pbox.add_child(_label(txt, 15, (COL_TITLE if host else _ping_colour(ms)) if known else COL_DIM))
		pbox.add_child(_ping_bars(ms, known))
		h.add_child(pbox)
		_tab_rows.add_child(row)
		i += 1


var _tab_tween: Tween = null

func _tab_tick(delta: float) -> void:
	if _tab == null:
		return
	var want: bool = mp.active() and Input.is_key_pressed(KEY_ALT) \
		and not _chat_box.visible and not _root.visible
	if want != _tab_on:
		_tab_on = want
		# the old fade would finish and hide the list we are showing again
		if _tab_tween != null:
			_tab_tween.kill()
		var tw := _tab.create_tween()
		_tab_tween = tw
		if want:
			_fill_tab()
			_tab_t = 0.0
			_tab.visible = true
			_tab.pivot_offset = Vector2(TAB_W / 2.0, 0)
			_tab.scale = Vector2(0.97, 0.97)
			tw.set_parallel(true)
			tw.tween_property(_tab, "modulate:a", 1.0, 0.12)
			tw.tween_property(_tab, "scale", Vector2.ONE, 0.16).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		else:
			tw.tween_property(_tab, "modulate:a", 0.0, 0.1)
			tw.tween_callback(func() -> void: _tab.visible = false)
	if _tab_on:
		_tab_t += delta
		if _tab_t >= 0.5:
			_tab_t = 0.0
			_fill_tab()


# The badge next to the title: where we stand, with a breathing dot.
var _state_pill: PanelContainer
var _state_sb: StyleBoxFlat
var _state_dot: Label
var _state_text: Label
var _state_clock := 0.0


func _update_state_pill(delta: float) -> void:
	if _state_pill == null or not _root.visible:
		return
	var col := COL_OFF
	var text := "OFFLINE"
	if mp.active():
		if mp.is_host:
			col = COL_DONE
			text = "HOSTING  ·  %d" % mp.players.size()
		elif mp.in_world():
			col = COL_DONE
			text = "IN PARTY"
		else:
			col = COL_OK
			text = "JOINING"
	_state_text.text = text
	_state_sb.bg_color = Color(col, 0.12)
	_state_sb.border_color = Color(col, 0.55)
	_state_clock += delta
	var breathe := 0.55 + 0.45 * (0.5 + 0.5 * sin(_state_clock * 3.0)) if mp.active() else 1.0
	_state_dot.add_theme_color_override("font_color", Color(col, breathe))


# stopwatch: anything over 4 ms in one frame goes into mp_trace.log by name
func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_process_inner(delta)
	if mp != null and is_instance_valid(mp):
		mp.perf("ui", Time.get_ticks_usec() - t0)


# ---------------------------------------------------------------- the window in the background
# A load takes half a minute, so players look at something else meanwhile. When it
# ends the game grabs the mouse even if its window is not in front, and from then on
# a click on the window does not bring it to the front: the keys and looking around
# are dead until alt-tab. So a mouse grabbed in the background is let go at once, and
# grabbed again as soon as the window is in front. Alt-tabbing away while playing
# never comes here: then the engine lets go of the mouse by itself.
const GRAB_TRIES := 3  # if the game keeps grabbing it, do not fight over it
var _grabbed_was := false
var _mouse_freed := false
var _grab_tries := 0

func _watch_focus() -> void:
	var p := _world_player()
	if p == null:
		_grabbed_was = false
		_mouse_freed = false
		return
	var grabbed := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if DisplayServer.window_is_focused():
		_grab_tries = 0
		if _mouse_freed:
			_mouse_freed = false
			# unless something in between (a menu) really wants the mouse free
			if not grabbed and p.get("_mouse_captured") != false:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
				grabbed = true
			mp.trace.note("window in front again: mouse grabbed=%s" % grabbed)
	elif grabbed and not _grabbed_was and _grab_tries < GRAB_TRIES:
		_grab_tries += 1
		_mouse_freed = true
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		grabbed = false
		DisplayServer.window_request_attention()  # the taskbar: the world is ready
		mp.trace.note("mouse grabbed while the window is in the background: let go")
	_grabbed_was = grabbed


# A click on the window means: this window, please. Windows does that by itself,
# except in the case above. This is the way back if it ever happens some other way.
func _click_to_front() -> void:
	if _world_player() != null and not DisplayServer.window_is_focused():
		DisplayServer.window_move_to_foreground()
		mp.trace.note("click while the window is in the background: asked for the front")


func _notification(what: int) -> void:
	if what != NOTIFICATION_APPLICATION_FOCUS_IN and what != NOTIFICATION_APPLICATION_FOCUS_OUT:
		return
	if mp != null and is_instance_valid(mp) and mp.trace != null:
		mp.trace.note("window %s" % ("in front" if what == NOTIFICATION_APPLICATION_FOCUS_IN else "in the background"))


# ---------------------------------------------------------------- input, for the log
# When a player cannot move or click there is nothing to go on afterwards, so the
# log says what the game thought at that moment. Only when it changes, and clicks.
const INPUT_WATCH := 0.25
var _input_t := 0.0
var _input_said := ""

func _input_state() -> String:
	var p := _world_player()
	if p == null:
		return ""
	var carry: Variant = p.get("carry")
	var hand: Variant = p.get("hand")
	var held: Variant = carry.call("held") if carry != null and carry.has_method("held") else null
	var focus := get_viewport().gui_get_focus_owner()
	return "accepts=%s move=%s captured=%s menu=%s focused=%s mouse=%s paused=%s tool=%s held=%s hand=%s arms=%s ui=%s" % [
		p.call("_accepts_input") if p.has_method("_accepts_input") else "?",
		p.call("_accepts_move") if p.has_method("_accepts_move") else "?",
		p.call("is_mouse_captured") if p.has_method("is_mouse_captured") else "?",
		p.call("menu_is_up") if p.has_method("menu_is_up") else "?",
		DisplayServer.window_is_focused(),
		Input.mouse_mode,
		get_tree().paused,
		p.get("current_tool"),
		held.item_id if is_instance_valid(held) else "-",
		hand.call("is_holding") if hand != null and is_instance_valid(hand) and hand.has_method("is_holding") else "?",
		carry.get("arms_full") if carry != null else "?",
		focus.name if focus != null else "-",
	]


func _input_tick(delta: float) -> void:
	_input_t += delta
	if _input_t < INPUT_WATCH:
		return
	_input_t = 0.0
	if not mp.active() or not mp.in_world():
		return
	var now := _input_state()
	if now != _input_said:
		_input_said = now
		mp.trace.note("input: " + now)


func _note_click() -> void:
	if not mp.active() or not mp.in_world():
		return
	var p := _world_player()
	if p == null:
		return
	var carry: Variant = p.get("carry")
	if carry == null or not carry.has_method("_record_under_crosshair"):
		return
	var under: Dictionary = carry.call("_record_under_crosshair")
	var rec: Dictionary = under.get("record", {})
	var target: Variant = carry.call("target") if carry.has_method("target") else null
	mp.trace.note("click: on a ride=%s kind=%s speed=%s target=%s primary=%s | %s" % [not under.is_empty(), rec.get("kind", "-"), rec.get("speed", "-"), target.item_id if is_instance_valid(target) else "-", Input.is_action_pressed("primary"), _input_state()])
	await get_tree().process_frame
	await get_tree().process_frame
	var held: Variant = carry.call("held") if is_instance_valid(carry) and carry.has_method("held") else null
	mp.trace.note("click result: held=%s" % (held.item_id if is_instance_valid(held) else "-"))


func _process_inner(delta: float) -> void:
	_tab_tick(delta)
	if _smooth_label != null and Engine.get_process_frames() % 30 == 0 and _smooth_label.is_visible_in_tree():
		var st := _smooth_state_text()
		if st != _smooth_label.text:
			_smooth_label.text = st
	_watch_bug_box()
	_input_tick(delta)
	_watch_focus()
	# an invite that ran out: its button does nothing any more
	if _join_invite_btn != null and _join_invite_btn.visible and not mp.has_invite():
		refresh()
	_update_state_pill(delta)
	_fit_panel()
	if _wait == null:
		return
	_wait_clock += delta
	if _wait_clock >= WAIT_TICK:
		_wait_clock = 0.0
		_update_wait()
	_pulse_wait(delta)


# Which step a guest is on, or -1 when the card has no business being up.
func _wait_step() -> int:
	if not mp.active() or mp.is_host:
		return -1
	if mp.phase == mp.Phase.IN_WORLD and mp.in_world():
		return Step.INSIDE
	if mp.phase == mp.Phase.LOADING:
		# the world arrives in chunks first, then the game loads it
		return Step.WORLD if _progress_v >= 0.0 else Step.LOADING
	if mp.phase == mp.Phase.LOBBY:
		var host: Dictionary = mp.players.get(1, {})
		# the host is in a world already: ours is being packed up and sent
		return Step.WORLD if str(host.get("state", "")) == "world" else Step.SAVE
	return Step.CONNECT


func _update_wait() -> void:
	if _wait == null:
		return
	var step := _wait_step()
	var up := step >= 0 and not (_root != null and _root.visible)
	if step < 0:
		_wait_done_at = 0.0
	elif step == Step.INSIDE:
		if _wait_done_at <= 0.0:
			_wait_done_at = _clock() + WAIT_DONE
		elif _clock() >= _wait_done_at:
			up = false
	else:
		_wait_done_at = 0.0
	if up:
		var pct: int = int(round(_progress_v * 100.0)) if _progress_v >= 0.0 else -1
		var host := ""
		if mp.players.has(1):
			var hp: Dictionary = mp.players[1]
			host = str(hp.get("name", ""))
		var sig := "%d|%d|%s|%s" % [step, pct, host, mp.i18n.locale()]
		if sig != _wait_sig:
			_wait_sig = sig
			_write_wait(step, pct, host)
	_wait.visible = up
	if _roster != null:
		# one place at a time: the card already says who we are waiting for
		_roster.visible = _roster_on and not up


func _write_wait(step: int, pct: int, host: String) -> void:
	_wait_title.text = mp.t("wait_title")
	_wait_sub.text = mp.t("wait_sub") % host
	_wait_sub.visible = host != ""
	var names := PackedStringArray(["wait_connect", "wait_save", "wait_world", "wait_load", "wait_in"])
	for i in _wait_names.size():
		var mark := _wait_marks[i]
		var row := _wait_names[i]
		if i == step and i == Step.WORLD and pct >= 0:
			row.text = mp.t("wait_world_pct") % pct  # the only step with a number
		else:
			row.text = mp.t(names[i])
		var sb := _wait_rows[i]
		# done: dim with a green tick. now: bold, with the lobby's gold edge.
		# still to come: the menu's "not yet" grey
		mark.text = MARK_DONE if i < step else ""
		if i == step:
			_style(row, 16, COL_TEXT, 4, true)
			sb.bg_color = Color(0.02, 0.03, 0.05, 0.3)
			sb.border_color = COL_TITLE
		else:
			_style(row, 16, COL_DIM if i < step else COL_OFF)
			sb.bg_color = Color(0, 0, 0, 0)
			sb.border_color = Color(COL_TITLE, 0)
	var hints := PackedStringArray(["wait_hint_connect", "wait_hint_save", "wait_hint_world", "wait_hint_load", "wait_hint_in"])
	_wait_hint.text = mp.t(hints[step])
	_wait_bar.visible = step == Step.WORLD and pct >= 0
	_wait_bar.value = float(maxi(pct, 0))
	_wait_now = step


# the step we are on breathes like the game's mission card edge, so a slow
# transfer still looks alive
func _pulse_wait(delta: float) -> void:
	if not _wait.visible or _wait_now < 0 or _wait_now >= _wait_rows.size() or _wait_now == Step.INSIDE:
		return
	_wait_t += delta
	var a := 0.675 + 0.275 * sin(TAU * _wait_t / WAIT_BREATH)
	_wait_rows[_wait_now].border_color = Color(COL_TITLE, a)


func _clock() -> float:
	return float(Time.get_ticks_msec()) / 1000.0


# Three numbered steps with the current one highlighted, so nobody has to
# guess what to press next.
func _steps_text() -> String:
	var steps := [mp.t("create_game"), mp.t("invite_friends"), mp.t("step_play")]
	var at := 0
	if mp.active() and mp.is_host:
		at = 1 if not mp.in_world() else 2
		if mp.players.size() > 1:
			at = 2
	elif mp.active():
		steps = [mp.t("step_connecting"), mp.t("step_entering"), mp.t("step_dig")]
		at = 1 if mp.phase == mp.Phase.LOADING else (2 if mp.in_world() else 0)
	var out := PackedStringArray()
	for i in steps.size():
		var col := COL_TITLE.to_html(false) if i == at else "8a8f99"
		var mark := "▶" if i == at else "%d ·" % (i + 1)
		out.append("[color=#%s]%s %s[/color]" % [col, mark, steps[i]])
	return "   ".join(out)


# Button and label text is set when the panel is built; re-apply it so a
# language change in the game's options shows up without a restart.
func _apply_texts() -> void:
	_title_label.text = mp.t("title")
	_subtitle_label.text = mp.t("subtitle") % mp.VERSION + "   ·   " + mp.CREDIT
	_steam_host_btn.text = mp.t("create_game")
	_invite_btn.text = mp.t("invite_friends")
	_leave_btn.text = mp.t("disconnect")
	_resync_btn.text = mp.t("resync")
	_close_btn.text = mp.t("close")
	_help_label.text = mp.t("panel_help")
	_name_edit.placeholder_text = mp.t("name_hint")
	_chat_edit.placeholder_text = mp.t("chat_hint")


# SMOOTH BELTS: one short line on what it does, and what it does now on this PC
func _smooth_state_text() -> String:
	var key := "off"
	var bd: Variant = mp.get("belt_draw")
	if bd != null and is_instance_valid(bd) and bd.has_method("panel_state"):
		key = str(bd.call("panel_state"))
	var now: String = {
		"active": mp.t_or("belt_state_active", "Now: active"),
		"watch": mp.t_or("belt_state_watch", "Now: active (new game version, being checked)"),
		"update": mp.t_or("belt_state_update", "Now: off (game update - normal belts)"),
		"problem": mp.t_or("belt_state_problem", "Now: off (problem found - normal belts)"),
		"nocore": mp.t_or("belt_state_nocore", "Now: off (belt part not installed - normal belts)"),
		"wait": mp.t_or("belt_state_wait", "Now: starting..."),
	}.get(key, mp.t_or("belt_state_off", "Now: off (normal belts)"))
	return mp.t_or("belt_smooth_help", "Smoother conveyor belts. Turns itself off if a game update breaks it.") + "\n" + now


func refresh() -> void:
	if _panel == null:
		return
	_apply_texts()
	var on: bool = mp.active()
	var steam_ok: bool = mp.steam_ready()
	_steam_host_btn.disabled = on or not steam_ok
	if _update_btn != null:
		_update_btn.visible = mp.latest_version != ""
		_update_btn.text = mp.update_text()
		_update_btn.disabled = mp.update_blocked()
	# guests may invite too: any member of a Steam lobby can bring a friend
	_invite_btn.disabled = not (on and mp.over_steam)
	if _invite_btn.disabled and _friends_box != null:
		_friends_box.visible = false
	if _join_invite_btn != null:
		_join_invite_btn.visible = mp.has_invite()
		if _join_invite_btn.visible:
			_join_invite_btn.text = mp.t_or("invite_join", "JOIN %s'S GAME  (F10)") % str(mp.pending_invite.get("name", "")).to_upper()
	if steam_ok:
		_steam_label.text = mp.t("steam_ready") % mp.steam.persona
	else:
		_steam_label.text = mp.t("steam_missing") % mp.steam.load_status
	_leave_btn.disabled = not on
	_resync_btn.disabled = not (on and mp.in_world())
	_servers_create.disabled = on or not steam_ok
	_update_servers_you(on)
	_logs_btn.visible = mp.logs_available()
	_logs_btn.text = mp.t("logs_on") if mp.logs_on else mp.t("logs_off")
	if _smooth_btn != null:
		_smooth_btn.text = mp.t_or("belt_smooth_on", "SMOOTH BELTS: ON") if mp.belt_smooth \
			else mp.t_or("belt_smooth_off", "SMOOTH BELTS: OFF")
	if _smooth_label != null:
		_smooth_label.text = _smooth_state_text()
	_name_edit.editable = not on
	var lines := PackedStringArray()
	if on:
		lines.append("[color=#%s]%s[/color]" % [COL_TITLE.to_html(false), mp.t("role_host") if mp.is_host else mp.t("role_client")])
		for id in mp.players:
			var p: Dictionary = mp.players[id]
			var st := {"world": mp.t("state_world"), "loading": mp.t("state_loading"), "lobby": mp.t("state_lobby"), "menu": mp.t("state_menu")}.get(str(p.get("state", "")), "")
			lines.append("[color=#%s]●[/color] %s%s  [color=#8a8f99]%s[/color]" % [
				(p["color"] as Color).to_html(false), _esc(str(p["name"])),
				mp.t("host_suffix") if id == 1 else "", st])
	else:
		lines.append("[color=#8a8f99]%s[/color]" % mp.t("offline"))
	_players_label.text = "\n".join(lines)
	_steps_label.text = _steps_text()
	# roster in the corner while playing together
	_roster_on = on and mp.players.size() > 0
	if _roster_on:
		var rl := PackedStringArray()
		for id in mp.players:
			var p: Dictionary = mp.players[id]
			rl.append("[right][color=#%s]●[/color] %s[/right]" % [(p["color"] as Color).to_html(false), _esc(str(p["name"]))])
		_roster.text = "\n".join(rl)
	_update_manage()
	_update_wait()  # sets both its own visibility and the roster's


# ---------------------------------------------------------------- main menu

func hook_menu(menu: Node) -> void:
	for i in 120:
		var b := _find_mp_button(menu)
		if b != null:
			for c in b.pressed.get_connections():
				b.pressed.disconnect(c["callable"])
			b.pressed.connect(func() -> void:
				Audio.play("ui_open")
				open_panel())
			b.visible = true
			# our name and our pink on the menu entry
			b.text = mp.t("title")
			b.add_theme_color_override("font_color", COL_TITLE)
			b.add_theme_color_override("font_hover_color", COL_TITLE.lightened(0.25))
			b.add_theme_color_override("font_focus_color", COL_TITLE.lightened(0.25))
			show_logs_notice()
			return
		await get_tree().process_frame
		if not is_instance_valid(menu):
			return
	# Full-game builds no longer ship the demo's MULTIPLAYER button: add our own,
	# cloned from one of the menu's buttons so it matches the game's style.
	# On a first start the language picker covers the menu: keep looking until it is gone.
	_log_menu_buttons(menu)
	while is_instance_valid(menu):
		var own := _add_mp_button(menu)
		if own != null:
			print("[MPMod] menu: added our own MULTIPLAYER button next to '%s'" % _mp_btn_anchor)
			show_logs_notice()
			return
		await get_tree().create_timer(0.25).timeout


var _mp_btn_anchor := ""


func _menu_buttons(n: Node) -> Array[Button]:
	var out: Array[Button] = []
	var stack: Array[Node] = [n]
	while not stack.is_empty():
		var c: Node = stack.pop_back()
		if c is Button and (c as Button).is_visible_in_tree() and (c as Button).text.strip_edges() != "":
			out.append(c)
		stack.append_array(c.get_children())
	return out


func _log_menu_buttons(menu: Node) -> void:
	for b in _menu_buttons(menu):
		print("[MPMod] menu button: '%s' at %s (parent %s)" % [b.text, menu.get_path_to(b), b.get_parent().get_class()])


func _add_mp_button(menu: Node) -> Button:
	# pick the container holding the most visible text buttons: that is the main list
	var groups := {}
	for b in _menu_buttons(menu):
		var p := b.get_parent()
		if p is Container:
			if not groups.has(p):
				groups[p] = []
			(groups[p] as Array).append(b)
	var best: Node = null
	for p in groups:
		if best == null or (groups[p] as Array).size() > (groups[best] as Array).size():
			best = p
	if best == null or (groups[best] as Array).size() < 2:
		return null
	var siblings: Array = groups[best]
	# insert after the first button (usually PLAY / CONTINUE), cloned from it
	var src: Button = siblings[0]
	for b: Button in siblings:
		if b.get_index() < src.get_index():
			src = b
	var nb := src.duplicate(0) as Button  # no signals, groups or scripts carried over
	nb.set_script(null)
	nb.name = "MPModMultiplayer"
	nb.text = mp.t("title")
	nb.add_theme_color_override("font_color", COL_TITLE)
	nb.add_theme_color_override("font_hover_color", COL_TITLE.lightened(0.25))
	nb.disabled = false
	nb.visible = true
	best.add_child(nb)
	best.move_child(nb, src.get_index() + 1)
	nb.pressed.connect(func() -> void:
		Audio.play("ui_open")
		open_panel())
	_mp_btn_anchor = src.text
	return nb


func _find_mp_button(n: Node) -> Button:
	var want := [n.tr("MULTIPLAYER"), "MULTIPLAYER", mp.t("title")]
	var stack: Array[Node] = [n]
	while not stack.is_empty():
		var c: Node = stack.pop_back()
		if c is Button and (c as Button).text in want:
			return c
		stack.append_array(c.get_children())
	return null
