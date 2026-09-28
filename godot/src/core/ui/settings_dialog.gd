class_name SettingsDialog
extends RefCounted
## Settings: language, sound, touch controls and the server address.
##
## There was no settings screen before. `muted` was flipped by a button in the
## header of every screen, `server_url` through a dialog in *one* game's menu,
## and `touch_controls` — read in several places and written in none — not at all.
## For a setting that can only be reached by a detour, that is the worst shape a
## setting can have.
##
## ## The language now, the screen later
##
## `Loc.set_code` takes effect at once: every caption created from now on is in
## the new language, and the number separators change with it. What does *not*
## take effect at once is the screen behind the dialog — its captions were built
## long ago. Rebuilding a running game would mean losing the round, so `Router`
## only rebuilds when `rebuild_safe()` allows it (lobby, menus, galleries), and
## the dialog says up front that the new language otherwise appears on the next
## screen change.
##
## Built like `SuggestDialog` and `ServerDialog`: a static overlay, `Ui` helpers,
## no hand-rolled tree.

static var _layer: CanvasLayer = null
static var _tree: SceneTree = null
## After a language change the screen should be rebuilt — but only once the dialog
## is gone. A dialog that vanishes in the middle of the fade is worse than one
## that waits a second.
static var _rebuild := false


static func is_open() -> bool:
	return _layer != null and is_instance_valid(_layer)


static func open(parent: Node) -> void:
	if is_open():
		return
	_build(parent.get_tree())


static func close() -> void:
	var tree := _tree
	_release()
	if _rebuild and tree != null:
		_rebuild = false
		# `go_to` is asynchronous and fades; the dialog is gone by then.
		Router.go_to(Router.current_id)


static func _release() -> void:
	if _layer != null and is_instance_valid(_layer):
		_layer.queue_free()
	_layer = null
	_tree = null


static func _build(tree: SceneTree) -> void:
	if tree == null:
		return
	_tree = tree
	_layer = CanvasLayer.new()
	_layer.layer = 128
	tree.root.add_child(_layer)

	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.theme = UiTheme.shared()
	_layer.add_child(root)

	root.add_child(Ui.backdrop(0.84))

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)

	var panel := Ui.panel()
	panel.custom_minimum_size = Vector2(660, 0)
	center.add_child(panel)

	var column := Ui.vbox(10)
	panel.add_child(column)

	column.add_child(Ui.title(Loc.t("ui.settings"), 30, UiTheme.ACCENT))

	# --- language --------------------------------------------------------
	column.add_child(Ui.label(Loc.t("ui.language"), 17, UiTheme.TEXT_DIM, true))
	# Buttons rather than a dropdown: on a phone a button is as big as a finger,
	# and every language is visible at once. With three catalogues that is a
	# shorter route than a popup menu.
	var languages := Loc.available()
	for entry in languages:
		var code := str(entry["code"])
		column.add_child(_language_button(code, code == Loc.code()))
	# With no readable catalogue there is nothing to pick, and an empty list looks
	# like a fault. In that case `Loc` has not translated anything either.
	if languages.is_empty():
		column.add_child(Ui.label(Loc.t("ui.no_languages"), 15, UiTheme.WARNING))

	var note := Ui.label(Loc.t("ui.language_timing", {
		"mode": Loc.t("ui.language_now") if Router.rebuild_safe() else Loc.t("ui.language_next"),
	}), 14, UiTheme.TEXT_MUTED)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size = Vector2(620, 0)
	column.add_child(note)

	# --- sound -----------------------------------------------------------
	var sound := Ui.button("", Vector2(0, 46), UiTheme.PANEL_LIGHT, func() -> void:
		Sfx.select()
		Game.toggle_muted()
		sound.text = _sound_label()
	)
	sound.text = _sound_label()
	column.add_child(sound)

	# --- touch controls --------------------------------------------------
	# Read by several screens and written nowhere: the setting existed but was
	# unreachable. This switch makes it operable.
	var touch := Ui.button("", Vector2(0, 46), UiTheme.PANEL_LIGHT, func() -> void:
		Sfx.select()
		Game.set_touch_controls(not Game.touch_controls)
		touch.text = _touch_label()
	)
	touch.text = _touch_label()
	column.add_child(touch)

	# --- server ----------------------------------------------------------
	var server := Ui.button("", Vector2(0, 46), UiTheme.PANEL_LIGHT, func() -> void:
		ServerDialog.open(_layer)
	)
	server.text = ServerDialog.label()
	column.add_child(server)

	# --- waiting suggestions ---------------------------------------------
	# The same number the lobby shows. One line here answers the question a player
	# would otherwise look up in the source: has my idea arrived, or is it still
	# sitting somewhere?
	var pending := Api.pending_count()
	if pending > 0:
		column.add_child(Ui.label(Loc.t("ui.pending_reason", {
			"pending": Api.pending_hint(),
			"reason": Loc.t("ui.pending_no_server") if not Game.has_server() else Loc.t("ui.pending_unreachable"),
		}), 14, UiTheme.WARNING))

	var actions := Ui.hbox(10)
	actions.alignment = BoxContainer.ALIGNMENT_END
	column.add_child(actions)
	actions.add_child(Ui.button(Loc.t("ui.close"), Vector2(150, 48), UiTheme.PANEL_LIGHT, func() -> void:
		close()
	))

	root.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed:
			close()
	)


## A language by its own name, in the language it names: "Deutsch", "English",
## "Français". "fr" on a French interface helps nobody.
static func _language_button(code: String, chosen: bool) -> Button:
	var label := Loc.native_name(code)
	if chosen:
		label = "✓  " + label
	return Ui.button(label, Vector2(0, 44), UiTheme.ACCENT if chosen else UiTheme.PANEL_LIGHT,
		func() -> void: _choose(code))


static func _choose(code: String) -> void:
	Sfx.select()
	if not Loc.set_code(code):
		return
	_rebuild = true
	# Rebuild the dialog right away so the language buttons are in the new
	# language. Without this it would read "Deutsch" next to "✓ English".
	var tree := _tree
	_release()
	_build(tree)


static func _sound_label() -> String:
	return Loc.t("ui.sound_on") if not Game.muted else Loc.t("ui.sound_off")


static func _touch_label() -> String:
	return Loc.t("ui.touch_controls", {
		"state": Loc.t("ui.on") if Game.touch_controls else Loc.t("ui.off"),
	})
