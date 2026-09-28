extends Screen
## List lobby — a flat overview of every game, grouped by the same categories the
## 3D lobby uses. Reachable from the 3D lobby and the fallback when 3D is
## unavailable.
##
## Container based, so it stays centred and readable in phone landscape.

const COLUMNS := 5
const COLUMN_WIDTH := 232.0
const COLUMN_GAP := 16.0
const HEADER_Y := 150.0
const LIST_TOP := 214.0
const LIST_BOTTOM := 600.0
const BUTTON_GAP := 9.0

var _muted_button: Button
var _server_button: Button
var _pending_label: Label
## The drifting background motes, so a window resize can put them back on screen.
var _motes: Array[Control] = []


func _ready_game() -> void:
	_draw_background()
	_build_header()
	_build_columns()
	_build_footer()


## Drifting motes, matching the browser lobby's ambience.
##
## The field is the size of the window, not a fixed 1400x760. A 4:3 tablet runs
## a 1280x1707 viewport, and a hard-coded extent stops the motes at y~760 — the
## lower two thirds of the screen is then bare. Reading the window and respawning
## on a resize is the whole fix; the loop itself is unchanged.
func _draw_background() -> void:
	var layer := Control.new()
	layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var background := Ui.rect(UiTheme.BG)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(background)

	for i in 40:
		var dot := Ui.rect(Color(0.220, 0.741, 0.973, randf_range(0.08, 0.3)))
		dot.size = Vector2.ONE * float(randi_range(2, 5))
		layer.add_child(dot)
		dot.position = Vector2(randf() * _mote_extent().x - 60.0, randf() * _mote_extent().y)
		_motes.append(dot)
		var extent := _mote_extent()
		var tween := dot.create_tween()
		tween.set_loops()
		tween.tween_property(dot, "position:y", dot.position.y - randf_range(40.0, 120.0), randf_range(4.0, 9.0)).set_trans(Tween.TRANS_SINE)
		tween.tween_property(dot, "modulate:a", 0.0, randf_range(4.0, 9.0))
		tween.tween_callback(func() -> void:
			dot.position.y = randf() * extent.y
			dot.modulate.a = 1.0)
	content_layer().add_child(layer)
	var viewport := get_viewport()
	if not viewport.size_changed.is_connected(_respawn_motes):
		viewport.size_changed.connect(_respawn_motes)


## The area the motes drift through: the window, with a margin for the drift.
func _mote_extent() -> Vector2:
	return Vector2(maxf(320.0, get_viewport_rect().size.x) + 60.0, maxf(240.0, get_viewport_rect().size.y))


## A window that changed shape leaves half the motes outside it. One pass puts
## every one back inside.
func _respawn_motes() -> void:
	var extent := _mote_extent()
	for dot in _motes:
		if not is_instance_valid(dot):
			continue
		dot.position = Vector2(randf() * extent.x - 60.0, randf() * extent.y)


func _build_header() -> void:
	var column := Ui.vbox(4)
	column.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	column.offset_top = 56
	column.offset_bottom = 150
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	content_layer().add_child(column)

	var title := Ui.title("SINGULAR 80", 54)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(title)
	var subtitle := Ui.label("Lobby — all games by category", 20, Color(0.490, 0.827, 0.988))
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(subtitle)


func _build_columns() -> void:
	var row := Ui.hbox(int(COLUMN_GAP))
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_top = HEADER_Y
	row.offset_bottom = -(720.0 - LIST_BOTTOM)
	row.alignment = BoxContainer.ALIGNMENT_CENTER

	for index in GameRegistry.CATEGORIES.size():
		var category: Dictionary = GameRegistry.CATEGORIES[index]
		row.add_child(_category_column(category))
	content_layer().add_child(row)


func _category_column(category: Dictionary) -> Control:
	var accent: Color = category["accent"]
	var column := Ui.vbox(5)
	column.custom_minimum_size = Vector2(COLUMN_WIDTH, 0)
	column.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var header := Ui.rect(Color(accent.r, accent.g, accent.b, 0.16), 8, accent, 2)
	header.custom_minimum_size = Vector2(0, 46)
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(header)

	var labels := CenterContainer.new()
	labels.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	labels.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(labels)
	var text := Ui.vbox(0)
	labels.add_child(text)
	var head := Ui.label(Loc.f("%s  %s", [category["icon"], category["name"]]), 17, UiTheme.TEXT, true)
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	head.custom_minimum_size = Vector2(COLUMN_WIDTH - 10, 24)
	text.add_child(head)
	var tagline := Ui.label(str(category["tagline"]), 11, UiTheme.TEXT_DIM)
	tagline.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tagline.custom_minimum_size = Vector2(COLUMN_WIDTH - 10, 18)
	text.add_child(tagline)

	var games := GameRegistry.games_in_category(str(category["id"]))
	if games.is_empty():
		return column
	var available := LIST_BOTTOM - LIST_TOP
	var height: float = minf(66.0, (available - float(games.size() - 1) * BUTTON_GAP) / float(games.size()))
	var stack := Ui.vbox(int(BUTTON_GAP))
	stack.alignment = BoxContainer.ALIGNMENT_CENTER
	stack.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for game in games:
		stack.add_child(_game_card(game, height))
	column.add_child(stack)
	return column


## One game entry: accent frame, icon, name and highscore, tappable anywhere.
func _game_card(game: Dictionary, height: float) -> Control:
	var entry := game
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(0, height)
	card.add_theme_stylebox_override("panel", UiTheme.flat(UiTheme.PANEL, entry["accent"], 10, 2))
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	card.gui_input.connect(func(event: InputEvent) -> void:
		if (event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed) \
				or (event is InputEventMouseButton and (event as InputEventMouseButton).pressed):
			Sfx.level_up()
			Router.play(str(entry["id"]))
	)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 6)
	card.add_child(margin)

	var row := Ui.hbox(8)
	margin.add_child(row)

	var icon := Ui.label(str(game["icon"]), 26, entry["accent"], true)
	icon.custom_minimum_size = Vector2(30, 0)
	icon.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	row.add_child(icon)

	var text := Ui.vbox(0)
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(text)

	var name_label := Ui.label(str(game["name"]), 15, UiTheme.TEXT, true)
	# One line, trimmed with an ellipsis. `height` is only a *minimum* for a
	# container: an autowrapped name ("Weihnachts-Merge 3D") grew the card past
	# it, the column overflowed the row, and the last tile of a category ended up
	# underneath the footer — painted over and, since the footer is the later
	# sibling, unclickable.
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.custom_minimum_size = Vector2(0, 22)
	text.add_child(name_label)

	var score_text := Loc.t("ui.play")
	if game.has("highscore_key"):
		# `format_number` rather than `%d`: the card shows five-digit values, and
		# `1.234` is a decimal number in English and French.
		score_text = Loc.t("ui.highscore_of", {
			"score": Ui.format_number(Game.highscore(str(game["highscore_key"]))),
		})
	var score_label := Ui.label(score_text, 12, Color(0.980, 0.800, 0.086))
	text.add_child(score_label)
	return card


func _build_footer() -> void:
	var column := Ui.vbox(8)
	column.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	column.offset_top = -110
	column.offset_bottom = -8
	content_layer().add_child(column)

	var row := Ui.hbox(10)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_child(row)
	row.add_child(Ui.button("🧭  3D lobby", Vector2(200, 48), UiTheme.ACCENT, func() -> void:
		Sfx.select()
		Router.go_to("lobby")
	))
	row.add_child(Ui.button("Suggestion", Vector2(190, 48), UiTheme.PANEL_LIGHT, func() -> void:
		SuggestDialog.open(self)
	))
	row.add_child(Ui.button("Weapons & mode", Vector2(210, 48), UiTheme.PANEL_LIGHT, func() -> void:
		Sfx.select()
		Router.go_to("main_menu")
	))
	_muted_button = Ui.button(Ui.mute_label(), Vector2(140, 48), UiTheme.PANEL_LIGHT, func() -> void:
		Game.toggle_muted()
		_muted_button.text = Ui.mute_label()
	)
	row.add_child(_muted_button)

	# As in the main menu: the language spelled out. This screen is the fallback
	# used exactly when 3D is unavailable, so the setting must not live behind 3D.
	row.add_child(Ui.button(Loc.t("ui.language_button"), Vector2(190, 48), UiTheme.PANEL_LIGHT, func() -> void:
		Sfx.select()
		SettingsDialog.open(self)
	))

	# The server address belongs on a main screen, not in one game's menu:
	# without an address a suggestion vanishes into `user://` unnoticed.
	_server_button = Ui.button(ServerDialog.label(), Vector2(230, 48), UiTheme.PANEL_LIGHT, func() -> void:
		ServerDialog.open(self)
		_refresh_server_button.call_deferred()
	)
	row.add_child(_server_button)

	var footer := Ui.label(Loc.f("More games to come — send in your idea!  ·  Content v%d", [Content.version]), 14, UiTheme.TEXT_MUTED)
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	footer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(footer)

	# How many suggestions wait for delivery. Without this a stuck suggestion
	# looks exactly like one that arrived.
	_pending_label = Ui.label("", 14, UiTheme.TEXT_MUTED)
	_pending_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pending_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(_pending_label)
	Api.pending_changed.connect(_on_pending_changed)
	_on_pending_changed(Api.pending_count())


## Shows the waiting count plus the reason for it.
func _on_pending_changed(count: int) -> void:
	if not is_instance_valid(_pending_label):
		return
	if count <= 0:
		_pending_label.text = ""
		_pending_label.visible = false
		return
	_pending_label.visible = true
	# Without an address the cause is unambiguous, and hiding it would show the
	# player a data gap where only a setting needs changing.
	_pending_label.text = Loc.t("ui.pending_reason", {
		"pending": Api.pending_hint(),
		"reason": Loc.t("ui.pending_no_server") if not Game.has_server() else Loc.t("ui.pending_unreachable"),
	})
	_pending_label.add_theme_color_override("font_color", UiTheme.WARNING)


func _refresh_server_button() -> void:
	if is_instance_valid(_server_button):
		_server_button.text = ServerDialog.label()
