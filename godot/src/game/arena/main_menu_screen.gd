extends Screen
## Arena main menu: start weapon, difficulty mode, backend address, ticker for
## implemented suggestions. Port of `scenes/MainMenuScene.ts`.

const WEAPON_WIDTH := 176.0
const WEAPON_HEIGHT := 68.0
const WEAPON_GAP := 18.0
const MODE_WIDTH := 190.0
const MODE_HEIGHT := 42.0
const MODE_GAP := 20.0

var weapon_id: String = "pistol"
var mode_id: String = "classic"
var _weapon_buttons: Array[PanelContainer] = []
var _mode_buttons: Array[Button] = []
var _ticker: Label
var _ticker_items: Array = []
var _ticker_index: int = 0
var _ticker_timer: float = 0.0
var _stars: Array[Control] = []
var _server_button: Button


func _ready_game() -> void:
	weapon_id = Game.arena_weapon
	mode_id = Game.arena_mode
	if not Content.weapons.any(func(w: Dictionary) -> bool: return str(w["id"]) == weapon_id):
		weapon_id = str(Content.weapons[0]["id"]) if not Content.weapons.is_empty() else "pistol"
	if not Content.modes.any(func(m: Dictionary) -> bool: return str(m["id"]) == mode_id):
		mode_id = str(Content.modes[0]["id"]) if not Content.modes.is_empty() else "classic"

	_draw_background()
	_build_content()
	_load_implemented.call_deferred()


func _draw_background() -> void:
	var layer := Control.new()
	layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var background := Ui.rect(UiTheme.BG)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(background)
	for i in 54:
		var dot := Ui.rect(Color(0.220, 0.741, 0.973, randf_range(0.08, 0.35)))
		dot.size = Vector2.ONE * float(randi_range(2, 4))
		layer.add_child(dot)
		dot.position = Vector2(randf() * 1360.0 - 40.0, randf() * 700.0 + 20.0)
		_stars.append(dot)
		var tween := dot.create_tween()
		tween.set_loops()
		tween.tween_property(dot, "position:y", dot.position.y - randf_range(40.0, 120.0), randf_range(4.0, 9.0)).set_trans(Tween.TRANS_SINE)
		tween.tween_property(dot, "modulate:a", 0.0, randf_range(4.0, 9.0))
		tween.tween_callback(func() -> void:
			dot.position.y = randf() * 700.0 + 20.0
			dot.modulate.a = 1.0)
	content_layer().add_child(layer)


func _build_content() -> void:
	var column := Ui.vbox(8)
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	column.offset_top = 62
	column.offset_bottom = -46
	content_layer().add_child(column)

	var title := Ui.title("SINGULAR 80", 64)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(title)
	var tagline := Ui.label("Ein Spiel, das von seinen Spielern gebaut wird.", 19, Color(0.490, 0.827, 0.988))
	tagline.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tagline.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(tagline)
	var record := Ui.label(Loc.f("Highscore: %s   ·   Content v%d", [[Ui.format_number(Game.highscore(Game.HS_ARENA)), Content.version]]), 14, UiTheme.TEXT_MUTED)
	record.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	record.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(record)

	column.add_child(_spacer(10))
	column.add_child(_caption("Startwaffe"))
	column.add_child(_weapon_row())
	column.add_child(_spacer(8))
	column.add_child(_caption("Modus"))
	column.add_child(_mode_row())
	column.add_child(_spacer(10))

	var start := Ui.button("▶  Spiel starten", Vector2(420, 66), UiTheme.ACCENT, func() -> void:
		Sfx.level_up()
		Router.go_to("arena", {"weaponId": weapon_id, "modeId": mode_id})
	)
	var start_row := Ui.hbox(0)
	start_row.alignment = BoxContainer.ALIGNMENT_CENTER
	start_row.add_child(start)
	column.add_child(start_row)

	column.add_child(_spacer(4))
	var actions := Ui.hbox(10)
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_child(Ui.button("Vorschlag einreichen", Vector2(250, 50), UiTheme.PANEL_LIGHT, func() -> void:
		SuggestDialog.open(self)
	))
	actions.add_child(Ui.button("Lobby", Vector2(170, 50), UiTheme.PANEL_LIGHT, func() -> void:
		Sfx.select()
		Router.go_to("lobby_list")
	))
	_server_button = Ui.button(_server_label(), Vector2(230, 50), UiTheme.PANEL_LIGHT, _toggle_server)
	actions.add_child(_server_button)
	# The language sits here instead of behind the gear in the header: this is the
	# first screen a new player sees, and a language they cannot find is one they
	# never change.
	actions.add_child(Ui.button(Loc.t("ui.language_button"), Vector2(190, 50), UiTheme.PANEL_LIGHT, func() -> void:
		Sfx.select()
		SettingsDialog.open(self)
	))
	column.add_child(actions)

	column.add_child(_spacer(6))
	var help := Ui.label("Stick / WASD bewegen  ·  Zielen mit Finger oder Maus  ·  Auto-Feuer  ·  Dash  ·  ESC Pause", 14, Color(0.278, 0.341, 0.412))
	help.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	help.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(help)

	# The ticker shows the implemented suggestion that Google Play requires a
	# reporting path for, and a suggestion is visible to the player only here, so
	# the report button has to be here too. It reads the ticker at click time, not
	# at build time: the ticker advances every 4.5 s.
	var ticker_row := Ui.hbox(8)
	ticker_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_ticker = Ui.label("", 13, Color(0.290, 0.871, 0.502))
	_ticker.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_ticker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ticker_row.add_child(_ticker)
	ticker_row.add_child(Ui.button("Inhalt melden", Vector2(150, 30), UiTheme.PANEL_LIGHT,
		func() -> void: _report_current()))
	column.add_child(ticker_row)


func _spacer(height: float) -> Control:
	return Ui.spacer(Vector2(0, height))


func _caption(text: String) -> Control:
	var label := Ui.label(text, 16, UiTheme.TEXT_DIM)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label


func _weapon_row() -> Control:
	var row := Ui.hbox(int(WEAPON_GAP))
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	var available: Array[Dictionary] = []
	for weapon in Content.weapons:
		if int(weapon.get("unlockWave", 0)) <= 0:
			available.append(weapon)
	for weapon in available:
		var entry: Dictionary = weapon
		var card := _weapon_card(entry)
		row.add_child(card)
		_weapon_buttons.append(card)
	_refresh_buttons()
	return row


## PanelContainer, so both labels stay sized correctly however long the text is.
func _weapon_card(weapon: Dictionary) -> Control:
	var id := str(weapon["id"])
	var card := PanelContainer.new()
	card.name = "Card"
	card.custom_minimum_size = Vector2(WEAPON_WIDTH, WEAPON_HEIGHT)
	card.add_theme_stylebox_override("panel", UiTheme.flat(UiTheme.PANEL_LIGHT, UiTheme.BORDER, 10, 2))
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	card.gui_input.connect(func(event: InputEvent) -> void:
		if (event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed) \
				or (event is InputEventMouseButton and (event as InputEventMouseButton).pressed):
			weapon_id = id
			Game.set_arena_weapon(id)
			Sfx.select()
			_refresh_buttons()
	)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 6)
	card.add_child(margin)

	var text := Ui.vbox(2)
	margin.add_child(text)

	var name_label := Ui.label(str(weapon["name"]), 16, UiTheme.TEXT, true)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	text.add_child(name_label)

	var description := Ui.label(str(weapon.get("description", "")), 11, UiTheme.TEXT_DIM)
	description.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	description.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description.size_flags_vertical = Control.SIZE_EXPAND_FILL
	text.add_child(description)
	return card


func _mode_row() -> Control:
	var row := Ui.hbox(int(MODE_GAP))
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	for mode in Content.modes:
		var entry: Dictionary = mode
		var button := Ui.button(str(mode["name"]), Vector2(MODE_WIDTH, MODE_HEIGHT), UiTheme.PANEL_LIGHT, func() -> void:
			mode_id = str(entry["id"])
			Game.set_arena_mode(mode_id)
			Sfx.select()
			_refresh_buttons()
		)
		row.add_child(button)
		_mode_buttons.append(button)
	return row


func _refresh_buttons() -> void:
	var weapons: Array[Dictionary] = []
	for weapon in Content.weapons:
		if int(weapon.get("unlockWave", 0)) <= 0:
			weapons.append(weapon)
	for i in mini(_weapon_buttons.size(), weapons.size()):
		_style_weapon(_weapon_buttons[i], str(weapons[i]["id"]) == weapon_id)
	for i in mini(_mode_buttons.size(), Content.modes.size()):
		_style_mode(_mode_buttons[i], str(Content.modes[i]["id"]) == mode_id)


func _style_weapon(card: PanelContainer, selected: bool) -> void:
	var fill: Color = Color(UiTheme.ACCENT.r, UiTheme.ACCENT.g, UiTheme.ACCENT.b, 0.85) if selected else UiTheme.PANEL_LIGHT
	var border: Color = Color(0.490, 0.827, 0.988) if selected else UiTheme.BORDER
	card.add_theme_stylebox_override("panel", UiTheme.flat(fill, border, 10, 2))


func _style_mode(button: Button, selected: bool) -> void:
	var fill: Color = Color(UiTheme.SUCCESS.r, UiTheme.SUCCESS.g, UiTheme.SUCCESS.b, 0.8) if selected else UiTheme.PANEL_LIGHT
	var border: Color = Color(0.525, 0.937, 0.686) if selected else UiTheme.BORDER
	button.add_theme_stylebox_override("normal", UiTheme.flat(fill, border, 9, 2))
	button.add_theme_stylebox_override("hover", UiTheme.flat(fill.lightened(0.12), border, 9, 2))
	button.add_theme_stylebox_override("pressed", UiTheme.flat(fill.darkened(0.2), border, 9, 2))


func _server_label() -> String:
	return ServerDialog.label()


func _toggle_server() -> void:
	ServerDialog.open(self)
	# The dialog closes before the next frame, so the label is refreshed after it
	# instead of here, where it would still show the old address.
	_refresh_server_button.call_deferred()


func _refresh_server_button() -> void:
	if is_instance_valid(_server_button):
		_server_button.text = _server_label()


func _process(delta: float) -> void:
	super(delta)
	if _ticker_items.is_empty():
		return
	_ticker_timer += delta
	if _ticker_timer >= 4.5:
		_ticker_timer = 0.0
		_ticker_index += 1
		_show_ticker()


func _load_implemented() -> void:
	_ticker_items = await Api.implemented_suggestions(8)
	if _ticker_items.is_empty():
		_ticker.text = Loc.t("ui.ticker_empty")
		return
	_ticker_index = 0
	_show_ticker()


func _show_ticker() -> void:
	if _ticker_items.is_empty():
		return
	var item: Dictionary = _ticker_items[_ticker_index % _ticker_items.size()]
	var run: Variant = item.get("run", null)
	var detail := str(item.get("text", ""))
	if run is Dictionary:
		var summary := str((run as Dictionary).get("resultSummary", "")).strip_edges()
		if summary != "":
			detail = summary
	if detail.length() > 90:
		detail = detail.substr(0, 90) + "…"
	_ticker.text = Loc.t("ui.ticker_item", {"id": str(int(item.get("id", 0))), "detail": detail})


## Reports whatever the ticker shows right now. With no ticker there is nothing to
## report, and the button says so rather than opening an empty dialog.
func _report_current() -> void:
	Sfx.select()
	if _ticker_items.is_empty():
		_ticker.text = Loc.t("ui.ticker_nothing_to_report")
		return
	var item: Dictionary = _ticker_items[_ticker_index % _ticker_items.size()]
	var text := str(item.get("text", ""))
	var run: Variant = item.get("run", null)
	if run is Dictionary:
		var summary := str((run as Dictionary).get("resultSummary", "")).strip_edges()
		if summary != "":
			text = summary
	ReportDialog.open(self, int(item.get("id", 0)), text)
