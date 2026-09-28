class_name ReportDialog
extends RefCounted
## In-app report for a flagged suggestion.
##
## Google Play requires a reporting path *in the game* for user-generated content.
## `mailto:` does not reliably open on Android, so the mail is also copied to the
## clipboard. Static overlay, `Ui` helpers, like `SuggestDialog`.

static var _layer: CanvasLayer = null


## Reports the suggestion with the given number and text.
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

	# On the backdrop, not on `root`: `Ui.backdrop()` is MOUSE_FILTER_STOP and
	# eats the press, so `root.gui_input` never fired.
	var backdrop := Ui.backdrop(0.82)
	root.add_child(backdrop)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)

	var panel := Ui.panel()
	panel.custom_minimum_size = Vector2(680, 0)
	center.add_child(panel)

	var column := Ui.vbox(12)
	panel.add_child(column)

	column.add_child(Ui.title(Loc.t("ui.report_title"), 30, UiTheme.WARNING))

	var quoted := Ui.label(Loc.t("ui.report_quoted", {"id": str(id)}), 16, UiTheme.ACCENT, true)
	column.add_child(quoted)

	var excerpt := Ui.label(AppLegal.quote(text), 16, UiTheme.TEXT_DIM)
	excerpt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	excerpt.custom_minimum_size = Vector2(640, 0)
	column.add_child(excerpt)

	column.add_child(Ui.label(Loc.t("ui.report_reason"), 17, UiTheme.TEXT_DIM, true))
	var reasons := OptionButton.new()
	# The one control in the game that can take keyboard focus, so it needs the
	# focus stylebox itself — the theme's Button entry is dead, every other
	# button sets `FOCUS_NONE`.
	reasons.add_theme_stylebox_override("focus", UiTheme.flat(Color(0, 0, 0, 0), UiTheme.ACCENT, 10))
	# Displayed is the translation, reported is the German text from `REASONS`.
	for index in AppLegal.REASONS.size():
		reasons.add_item(AppLegal.reason_label(index))
	column.add_child(reasons)

	var note := TextEdit.new()
	note.placeholder_text = Loc.t("ui.report_note")
	note.custom_minimum_size = Vector2(640, 90)
	note.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	column.add_child(note)

	var status := Ui.label("", 15, UiTheme.TEXT_DIM)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.custom_minimum_size = Vector2(640, 44)
	column.add_child(status)

	if not AppLegal.is_configured():
		# No address means no report goes out, which beats one nobody reads.
		status.add_theme_color_override("font_color", UiTheme.WARNING)
		status.text = Loc.t("ui.report_unconfigured")

	var actions := Ui.hbox(10)
	actions.alignment = BoxContainer.ALIGNMENT_END
	column.add_child(actions)

	var copy := Ui.button(Loc.t("ui.report_copy"), Vector2(200, 46), UiTheme.PANEL_LIGHT, func() -> void:
		DisplayServer.clipboard_set(AppLegal.report_message(
			id, text, _selected(reasons), note.text))
		Sfx.select()
		status.add_theme_color_override("font_color", UiTheme.SUCCESS)
		status.text = Loc.t("ui.report_copied")
	)
	var send := Ui.button(Loc.t("ui.report_send"), Vector2(230, 46), UiTheme.ACCENT, func() -> void:
		var url := AppLegal.report_mailto(id, text, _selected(reasons), note.text)
		if OS.shell_open(url) == OK:
			close()
			return
		Sfx.select()
		# Android does not open mailto: everywhere. The copy is the fallback.
		DisplayServer.clipboard_set(AppLegal.report_message(
			id, text, _selected(reasons), note.text))
		status.add_theme_color_override("font_color", UiTheme.WARNING)
		status.text = Loc.t("ui.report_no_mail_app")
	)
	var cancel := Ui.button(Loc.t("ui.close"), Vector2(140, 46), UiTheme.PANEL_LIGHT, func() -> void:
		Sfx.select()
		close()
	)
	actions.add_child(cancel)
	actions.add_child(copy)
	actions.add_child(send)

	backdrop.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed:
			close()
	)


static func _selected(reasons: OptionButton) -> String:
	var index := reasons.selected
	if index < 0 or index >= AppLegal.REASONS.size():
		return AppLegal.REASONS[0]
	return AppLegal.REASONS[index]
