class_name SettingsDialog
extends RefCounted
## Settings: language, sound, touch controls and the server address.
##
## Every setting is operable from here, including `touch_controls`, which was
## read in several places and written in none.
## `Loc.set_code` applies to new captions only; `Router` rebuilds the screen
## behind the dialog only when `rebuild_safe()` allows it, and the dialog says so.

static var _layer: CanvasLayer = null
static var _tree: SceneTree = null
## Rebuilt only after the dialog is gone; one vanishing mid-fade is worse.
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
	if not _rebuild or tree == null:
		return
	if Router.transitioning:
		# `go_to` returns immediately while another screen change is fading, so
		# the rebuild would be dropped silently — the dialog has just told the
		# player the new language is on screen. Keep the flag: the next close
		# performs the rebuild.
		return
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

	# On the backdrop, not on `root`: `Ui.backdrop()` is MOUSE_FILTER_STOP, so
	# it eats the press and `root.gui_input` never sees it. The backdrop itself
	# is what the player taps to dismiss.
	var backdrop := Ui.backdrop(0.84)
	root.add_child(backdrop)

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
	# Buttons rather than a dropdown: on a phone a button is as big as a finger
	# and every language is visible at once.
	var languages := Loc.available()
	for entry in languages:
		var code := str(entry["code"])
		column.add_child(_language_button(code, code == Loc.code()))
	# No readable catalogue means nothing to pick; an empty list looks like a fault.
	if languages.is_empty():
		column.add_child(Ui.label(Loc.t("ui.no_languages"), 15, UiTheme.WARNING))

	var note := Ui.label(Loc.t("ui.language_timing", {
		"mode": Loc.t("ui.language_now") if Router.rebuild_safe() else Loc.t("ui.language_next"),
	}), 14, UiTheme.TEXT_MUTED)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size = Vector2(620, 0)
	column.add_child(note)

	# --- sound -----------------------------------------------------------
	# The handler assigns to `sound`, so it is connected after the button exists:
	# a GDScript lambda captures locals by value, and inside the `Ui.button`
	# argument the local would still be null.
	var sound := Ui.button("", Vector2(0, 46), UiTheme.PANEL_LIGHT)
	sound.text = _sound_label()
	sound.pressed.connect(func() -> void:
		Sfx.select()
		Game.toggle_muted()
		sound.text = _sound_label()
	)
	column.add_child(sound)

	# --- touch controls --------------------------------------------------
	# Read by many screens, written nowhere before this switch.
	var touch := Ui.button("", Vector2(0, 46), UiTheme.PANEL_LIGHT)
	touch.text = _touch_label()
	touch.pressed.connect(func() -> void:
		Sfx.select()
		Game.set_touch_controls(not Game.touch_controls)
		touch.text = _touch_label()
	)
	column.add_child(touch)

	# --- server ----------------------------------------------------------
	var server := Ui.button("", Vector2(0, 46), UiTheme.PANEL_LIGHT, func() -> void:
		ServerDialog.open(_layer)
	)
	server.text = ServerDialog.label()
	column.add_child(server)

	# --- waiting suggestions ---------------------------------------------
	# The same count the lobby shows: has my idea arrived, or is it still waiting?
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

	backdrop.gui_input.connect(func(event: InputEvent) -> void:
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
	# Rebuild right away, or the buttons read "Deutsch" next to "✓ English".
	var tree := _tree
	_release()
	_build(tree)


static func _sound_label() -> String:
	return Loc.t("ui.sound_on") if not Game.muted else Loc.t("ui.sound_off")


static func _touch_label() -> String:
	return Loc.t("ui.touch_controls", {
		"state": Loc.t("ui.on") if Game.touch_controls else Loc.t("ui.off"),
	})
