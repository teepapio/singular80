class_name ThemePicker
extends RefCounted
## The themed editions of one game, and the dialog that switches between them.
##
## "Crystal Jumper 3D", "Christmas Jumper" and "Halloween Jumper" are three
## tiles in the lobby for one screen script — the game differs only in names,
## colours and meshes. A lobby that shows all three sells one game three times,
## so the lobby carries one tile and the *screen* carries the choice. This file
## is that choice: it answers "does this game have other editions" and "which one
## is on screen" for the top bar of every screen, 2D and 3D alike.
##
## Where the editions come from, in this order:
##
## 1. `themes` on a registry entry. That is what a game declares once its lobby
##    tile is the only one it has, and it is the shape a merge step writes when
##    the tiles are folded into one.
## 2. Every other registry entry that opens the same screen script. That is
##    exactly what three Jumper tiles are *before* they are merged, and it is
##    read rather than written: a new edition shows up in the dialog the moment
##    it has a registry entry, with nothing kept in step by hand.
##
## Each theme keeps its own highscore key and its own progress (the screens
## store that per theme), so folding the tiles together costs a player no
## record — the dialog simply shows all of them side by side.
##
## Once the lobby carries one tile per game, the surviving entry declares the
## editions itself and the first source above takes over:
##
##     {"id": "crystal3d", ..., "screen": "crystal3d", "themes": [
##         {"screen": "crystal3d", "name": "Crystal Jumper 3D", "icon": "◆", ...},
##         {"screen": "crystal3d_christmas", "name": "Christmas Jumper", ...},
##         {"screen": "crystal3d_halloween", "name": "Halloween Jumper", ...},
##     ]}
##
## The dialog lives on the screen's own modal layer, so a screen change — which
## is what choosing an edition is — takes it along and leaves nothing behind.

## One edition row. Wide enough for the longest catalogue name in either
## language, tall enough to hit with a thumb.
const CARD_SIZE := Vector2(440.0, 78.0)
const CARD_GAP := 10
## Marks a card for the tests and for anyone walking the tree later.
const CARD_META := "edition_card"

## What the dialog spends on everything that is not a card: the head, the close
## button, the two gaps around the list and the panel's own margin. The suite
## measures the built dialog against the window, so a change to one of those
## four that is not mirrored here fails the run instead of quietly letting the
## dialog grow past the bottom of the screen.
const DIALOG_CHROME := 132.0
## Floor for the card list, so a window too small for the whole dialog still
## shows a usable one instead of cards of height zero.
const DIALOG_MIN_LIST := 240.0

## The one dialog that is open, if any. A screen carries its own modal layers, so
## this is the layer alone: closing the dialog must not take a pause overlay with
## it. Like the suggestion and settings dialogs it is a static, and like them it
## survives a screen change only as a dangling reference — `is_instance_valid()`
## is the check that matters.
static var _layer: Control = null


## The screen a top bar belongs to. Both base classes carry `screen_id`, and the
## router sets it before the screen enters the tree, so the bar is right on the
## first frame. Anything without the property answers `""` — and gets no button.
static func screen_id_of(node: Node) -> String:
	if node == null or not is_instance_valid(node):
		return ""
	var id: Variant = node.get("screen_id")
	return "" if id == null else str(id)


## Every registry entry that opens the same screen script as `screen_id`.
##
## The script is what makes two entries editions of one game; the screen id only
## says which of them is on screen. A menu or a dialog answers `[]`, because no
## registry entry opens it.
static func family_of(screen_id: String) -> Array[Dictionary]:
	var script_path := str(Router.SCREEN_SCRIPTS.get(screen_id, ""))
	if script_path.is_empty():
		return []
	var out: Array[Dictionary] = []
	for game in GameRegistry.GAMES:
		if str(Router.SCREEN_SCRIPTS.get(str(game.get("screen", "")), "")) == script_path:
			out.append(game)
	return out


## The other editions of this screen's game, `[]` for a game that has none —
## which is every game that is not a family of editions.
static func editions_for(screen_id: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for edition in _catalog(family_of(screen_id)):
		if str(edition.get("screen", "")) != screen_id:
			out.append(edition)
	return out


## Whether the top bar of this screen gets a theme button at all.
static func has_editions(screen_id: String) -> bool:
	return not editions_for(screen_id).is_empty()


## The edition this screen shows: the declared one whose screen it is, else the
## registry entry with this screen, else the first of the family. `{}` when the
## screen belongs to no game — the lobby, a dialog.
static func current_edition(screen_id: String) -> Dictionary:
	var family := family_of(screen_id)
	for game in family:
		for edition in game.get("themes", []):
			if str((edition as Dictionary).get("screen", "")) == screen_id:
				return edition
	for game in family:
		if str(game.get("screen", "")) == screen_id:
			return game
	if family.is_empty():
		return {}
	return family[0]


## Whether a dialog is on screen right now.
static func is_open() -> bool:
	return _layer != null and is_instance_valid(_layer)


## Builds the dialog over `host` and returns the layer it lives on, or `null`
## when there is nothing to choose between. The return value is what the tests
## walk; a player only ever sees the layer.
static func open(host: Node) -> Control:
	if is_open():
		return _layer
	if host == null or not is_instance_valid(host) or not host.has_method("modal"):
		return null
	var screen_id := screen_id_of(host)
	var editions := editions_for(screen_id)
	if editions.is_empty():
		return null
	var layer := host.call("modal") as Control
	if layer == null:
		return null
	_layer = layer

	# `Ui.backdrop()` stops the mouse, so the press lands on it and never reaches
	# the cards below — which is what makes "tap outside to dismiss" work here.
	var backdrop := Ui.backdrop(0.8)
	backdrop.gui_input.connect(func(event: InputEvent) -> void:
		if (event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed) \
				or (event is InputEventMouseButton and (event as InputEventMouseButton).pressed):
			Sfx.select()
			close()
	)
	layer.add_child(backdrop)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(center)

	var panel := Ui.panel()
	panel.custom_minimum_size = Vector2(CARD_SIZE.x + 48.0, 0)
	center.add_child(panel)

	var column := Ui.vbox(CARD_GAP)
	panel.add_child(column)

	# The game the player is in, in the name it has in the lobby — the dialog is
	# reached from inside that game and says so rather than showing a bare list.
	var head := current_edition(screen_id)
	column.add_child(Ui.title(str(head.get("name", "")), 28, UiTheme.TEXT))

	# The cards go into a list that scrolls. They used to be a bare
	# `VBoxContainer` inside a `CenterContainer`, and nothing clips either: a
	# family with one edition more than the window holds pushed the head off the
	# top and the close button off the bottom, and neither could be reached.
	var list := Ui.scroll_list(CARD_GAP)
	column.add_child(list)
	var rows := Ui.list_box(list)
	for edition in editions:
		rows.add_child(_card(edition))
	column.add_child(Ui.button(Loc.t("ui.close"), Vector2(200, 48), UiTheme.PANEL_LIGHT, func() -> void:
		Sfx.select()
		close()))

	# The list may not ask for more room than the window has: what the cards need
	# when they fit, and the whole budget when they do not — in which case they
	# scroll inside the dialog instead of the dialog leaving the screen.
	var room := maxf(DIALOG_MIN_LIST, host.get_viewport().get_visible_rect().size.y - DIALOG_CHROME)
	var count := editions.size()
	var row := Ui.list_row(room, count, float(CARD_GAP), CARD_SIZE.y)
	list.custom_minimum_size.y = minf(room, Ui.list_height(count, row, float(CARD_GAP)))
	return layer


## Takes the dialog down. Only the layer this class built — a game that stacks a
## pause overlay underneath keeps it.
static func close() -> void:
	if is_open():
		_layer.queue_free()
	_layer = null


## One edition: icon, name, record, and the whole card is the target — the same
## shape as a lobby card, so the two read as the same list at two sizes.
static func _card(edition: Dictionary) -> Control:
	var accent: Color = edition.get("accent", UiTheme.ACCENT)
	var target := str(edition.get("screen", ""))
	var card := PanelContainer.new()
	card.custom_minimum_size = CARD_SIZE
	card.add_theme_stylebox_override("panel", UiTheme.flat(UiTheme.PANEL, accent, 12, 2))
	card.set_meta(CARD_META, true)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	card.gui_input.connect(func(event: InputEvent) -> void:
		var pressed := (event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed) \
				or (event is InputEventMouseButton and (event as InputEventMouseButton).pressed)
		if pressed and not target.is_empty():
			Sfx.select()
			Router.go_to(target)
	)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	card.add_child(margin)

	var row := Ui.hbox(12)
	margin.add_child(row)

	var icon := Ui.label(str(edition.get("icon", "")), 30, accent, true)
	icon.custom_minimum_size = Vector2(46, 0)
	icon.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	row.add_child(icon)

	var text := Ui.vbox(0)
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(text)

	var name_label := Ui.label(str(edition.get("name", "")), 19, UiTheme.TEXT, true)
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.custom_minimum_size = Vector2(0, 26)
	text.add_child(name_label)

	# The record is why the three tiles are worth merging: one card used to hold
	# one number, and two of the three numbers were invisible from the lobby.
	var score_text := Loc.t("ui.play")
	if edition.has("highscore_key"):
		score_text = Loc.t("ui.highscore_of", {
			"score": Ui.format_number(Game.highscore(str(edition["highscore_key"]))),
		})
	text.add_child(Ui.label(score_text, 13, Color(0.980, 0.800, 0.086)))
	return card


## The editions of a family: what a member declares in `themes`, or — while the
## lobby still carries a tile per edition — the members themselves.
static func _catalog(family: Array[Dictionary]) -> Array[Dictionary]:
	for game in family:
		var declared: Array[Dictionary] = []
		for edition in game.get("themes", []):
			declared.append(edition as Dictionary)
		if not declared.is_empty():
			return declared
	return family