class_name SuggestDialog
extends RefCounted
## The in-game suggestion form.
##
## Posts to `POST /api/suggestions` through `Api`, exactly like the browser
## overlay did, and falls back to a local queue when the device is offline so a
## player never loses an idea.

const MAX_LENGTH := 2000

static var _layer: CanvasLayer = null


## `context` overrides the automatic label. Leave it empty to use the game the
## player is currently in; the mesh gallery passes its own, more precise one.
static func open(parent: Control, context: String = "") -> void:
	if _layer != null and is_instance_valid(_layer):
		return
	_build(parent.get_tree(), context)


static func open_world(parent: Node3D, context: String = "") -> void:
	if _layer != null and is_instance_valid(_layer):
		return
	_build(parent.get_tree(), context)


## True while the suggestion overlay is on screen.
static func is_open() -> bool:
	return _layer != null and is_instance_valid(_layer)


static func close() -> void:
	if _layer != null and is_instance_valid(_layer):
		_layer.queue_free()
	_layer = null


static func _build(tree: SceneTree, context: String = "") -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 128
	tree.root.add_child(_layer)

	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.theme = UiTheme.shared()
	_layer.add_child(root)

	var backdrop := Ui.backdrop(0.82)
	root.add_child(backdrop)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)

	var panel := Ui.panel()
	panel.custom_minimum_size = Vector2(680, 0)
	center.add_child(panel)

	var column := Ui.vbox(14)
	panel.add_child(column)

	column.add_child(Ui.title("Vorschlag einreichen", 32, UiTheme.ACCENT))

	# The origin is filled in from the active screen, so the player only has to
	# write *what* should change, never where.
	var source := context.strip_edges()
	if source == "":
		source = SuggestionContext.for_screen(Router.current_id)
	var origin := Ui.label("Aus: %s" % source, 16, UiTheme.ACCENT, true)
	column.add_child(origin)

	var hint := Ui.label(
		"Neue Inhalte, Mechaniken, Balance oder Bugs — alles landet gesammelt auf dem Dashboard und wird dort priorisiert. Umsetzungen erscheinen direkt im Spiel.",
		16, UiTheme.TEXT_DIM)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(640, 0)
	column.add_child(hint)

	column.add_child(Ui.label("Dein Vorschlag *", 17, UiTheme.TEXT_DIM, true))
	var text_area := TextEdit.new()
	text_area.placeholder_text = "z. B. Füge einen Gegner hinzu, der beim Sterben in zwei kleinere Slimes zerfällt …"
	text_area.custom_minimum_size = Vector2(640, 150)
	text_area.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	column.add_child(text_area)

	column.add_child(Ui.label("Name (optional)", 17, UiTheme.TEXT_DIM, true))
	var name_edit := LineEdit.new()
	name_edit.placeholder_text = "Anonym"
	name_edit.custom_minimum_size = Vector2(640, 46)
	column.add_child(name_edit)

	var status := Ui.label("", 16, UiTheme.TEXT_DIM)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.custom_minimum_size = Vector2(640, 48)
	column.add_child(status)

	var actions := Ui.hbox(10)
	actions.alignment = BoxContainer.ALIGNMENT_END
	column.add_child(actions)

	var send := Ui.button("Absenden", Vector2(160, 48), UiTheme.ACCENT)
	var cancel := Ui.button("Schließen", Vector2(140, 48), UiTheme.PANEL_LIGHT, func() -> void:
		Sfx.select()
		close()
	)
	actions.add_child(cancel)
	actions.add_child(send)

	send.pressed.connect(func() -> void:
		var text := text_area.text.strip_edges()
		if text.length() > MAX_LENGTH:
			text = text.substr(0, MAX_LENGTH)
			text_area.text = text
		if text.length() < 3:
			status.text = "Bitte schreibe mindestens ein paar Worte."
			status.add_theme_color_override("font_color", UiTheme.DANGER)
			return
		send.disabled = true
		send.text = "Sende …"
		var author := name_edit.text.strip_edges().substr(0, 60)
		var view := await Api.submit_suggestion(text, author if author != "" else "Anonym", source)
		if view.is_empty():
			status.add_theme_color_override("font_color", UiTheme.WARNING)
			status.text = "Gespeichert, aber noch nicht an den Server geschickt. Die Idee wird gesendet, sobald du wieder online bist."
			send.text = "Gespeichert ✓"
			Sfx.level_up()
			return
		Sfx.level_up()
		status.add_theme_color_override("font_color", UiTheme.SUCCESS)
		var cluster := int(view.get("clusterSize", 1))
		var extra := ""
		if cluster > 1:
			extra = " Ähnliche Vorschläge gibt es schon (Cluster mit %d Einträgen) — deine Stimme zählt dort mit." % cluster
		status.text = "Danke! Dein Vorschlag läuft als #%d.%s" % [int(view.get("id", 0)), extra]
		send.text = "Gesendet ✓"
	)

	backdrop.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed:
			close()
	)
