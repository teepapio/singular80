class_name ReportDialog
extends RefCounted
## In-App-Meldung für einen beanstandeten Vorschlag.
##
## Google Play verlangt für nutzergenerierte Inhalte einen Meldeweg *im Spiel*.
## Vorschläge sind zwar nur über das Hauptmenü sichtbar, aber genau dort steht
## der Meldeknopf — wer etwas beanstanden kann, meldet es ohne Umweg.
##
## Zwei Wege, weil `mailto:` auf Android nicht verlässlich öffnet: das Mail
## wird zusätzlich in die Zwischenablage gelegt, sodass niemand tippen muss.
## Aufbau wie `SuggestDialog`: statische Overlay-Funktion, `Ui`-Helfer, kein
## Handgerüst.

static var _layer: CanvasLayer = null


## Meldet den Vorschlag mit der angegebenen Nummer und Text.
static func open(parent: Control, id: int, text: String) -> void:
	if _layer != null and is_instance_valid(_layer):
		return
	_build(parent.get_tree(), id, text)


static func open_world(parent: Node3D, id: int, text: String) -> void:
	if _layer != null and is_instance_valid(_layer):
		return
	_build(parent.get_tree(), id, text)


static func is_open() -> bool:
	return _layer != null and is_instance_valid(_layer)


static func close() -> void:
	if _layer != null and is_instance_valid(_layer):
		_layer.queue_free()
	_layer = null


static func _build(tree: SceneTree, id: int, text: String) -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 128
	tree.root.add_child(_layer)

	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.theme = UiTheme.shared()
	_layer.add_child(root)

	root.add_child(Ui.backdrop(0.82))

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)

	var panel := Ui.panel()
	panel.custom_minimum_size = Vector2(680, 0)
	center.add_child(panel)

	var column := Ui.vbox(12)
	panel.add_child(column)

	column.add_child(Ui.title("Inhalt melden", 30, UiTheme.WARNING))

	var quoted := Ui.label("Vorschlag #%d" % id, 16, UiTheme.ACCENT, true)
	column.add_child(quoted)

	var excerpt := Ui.label(AppLegal.quote(text), 16, UiTheme.TEXT_DIM)
	excerpt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	excerpt.custom_minimum_size = Vector2(640, 0)
	column.add_child(excerpt)

	column.add_child(Ui.label("Grund", 17, UiTheme.TEXT_DIM, true))
	var reasons := OptionButton.new()
	for reason in AppLegal.REASONS:
		reasons.add_item(reason)
	column.add_child(reasons)

	var note := TextEdit.new()
	note.placeholder_text = "Was stört dich daran? (optional)"
	note.custom_minimum_size = Vector2(640, 90)
	note.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	column.add_child(note)

	var status := Ui.label("", 15, UiTheme.TEXT_DIM)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.custom_minimum_size = Vector2(640, 44)
	column.add_child(status)

	if not AppLegal.is_configured():
		# Ehrlich bleiben: ohne Adresse geht keine Meldung raus, und das ist
		# besser als eine Adresse, an die niemand zuhört.
		status.add_theme_color_override("font_color", UiTheme.WARNING)
		status.text = "Noch keine Meldeadresse hinterlegt (MODERATION_MAIL in app_legal.gd)."

	var actions := Ui.hbox(10)
	actions.alignment = BoxContainer.ALIGNMENT_END
	column.add_child(actions)

	var copy := Ui.button("Text kopieren", Vector2(200, 46), UiTheme.PANEL_LIGHT, func() -> void:
		DisplayServer.clipboard_set(AppLegal.report_message(
			id, text, _selected(reasons), note.text))
		Sfx.select()
		status.add_theme_color_override("font_color", UiTheme.SUCCESS)
		status.text = "In die Zwischenablage kopiert — in der Mail-App einfach einfügen."
	)
	var send := Ui.button("Melde-Mail öffnen", Vector2(230, 46), UiTheme.ACCENT, func() -> void:
		var url := AppLegal.report_mailto(id, text, _selected(reasons), note.text)
		if OS.shell_open(url) == OK:
			close()
			return
		Sfx.select()
		# Android öffnet mailto: nicht überall. Die Kopie bleibt der Weg.
		DisplayServer.clipboard_set(AppLegal.report_message(
			id, text, _selected(reasons), note.text))
		status.add_theme_color_override("font_color", UiTheme.WARNING)
		status.text = "Keine Mail-App geöffnet — der Text liegt jetzt in der Zwischenablage."
	)
	var cancel := Ui.button("Schließen", Vector2(140, 46), UiTheme.PANEL_LIGHT, func() -> void:
		Sfx.select()
		close()
	)
	actions.add_child(cancel)
	actions.add_child(copy)
	actions.add_child(send)

	root.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed:
			close()
	)


static func _selected(reasons: OptionButton) -> String:
	var index := reasons.selected
	if index < 0 or index >= AppLegal.REASONS.size():
		return AppLegal.REASONS[0]
	return AppLegal.REASONS[index]
