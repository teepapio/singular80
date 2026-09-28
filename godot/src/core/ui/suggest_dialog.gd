class_name SuggestDialog
extends RefCounted
## The in-game suggestion form.
##
## Posts to `POST /api/suggestions` through `Api`, falling back to a persistent
## local queue when the device is offline so a player never loses an idea.

const MAX_LENGTH := 2000
const QueueClass := preload("res://src/core/logic/suggestion_queue.gd")

static var _layer: CanvasLayer = null
## Released in `close()`; otherwise a later suggestion writes into a freed label.
static var _warning_hook: Callable = Callable()


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
	if _warning_hook.is_valid():
		if is_instance_valid(Api) and Api.suggestion_failed.is_connected(_warning_hook):
			Api.suggestion_failed.disconnect(_warning_hook)
		_warning_hook = Callable()
	if _layer != null and is_instance_valid(_layer):
		_layer.queue_free()
	_layer = null


## Writes the pending count into the line. Without a queue it disappears
## entirely rather than claiming "0 Vorschläge warten auf Netz".
static func _show_waiting(label: Label) -> void:
	var text := QueueClass.pending_hint(Api.pending_count())
	label.text = text
	label.visible = text != ""


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

	column.add_child(Ui.title(Loc.t("ui.suggest_title"), 32, UiTheme.ACCENT))

	# The origin is filled in from the active screen, so the player writes *what*
	# should change, never where.
	var source := context.strip_edges()
	if source == "":
		source = SuggestionContext.for_screen(Router.current_id)
	var origin := Ui.label(Loc.t("ui.suggest_origin", {"game": source}), 16, UiTheme.ACCENT, true)
	column.add_child(origin)

	var hint := Ui.label(
		Loc.t("ui.suggest_hint"),
		16, UiTheme.TEXT_DIM)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(640, 0)
	column.add_child(hint)

	# Sent ideas must not look lost, so the pending count is visible here.
	var waiting := Ui.label("", 16, UiTheme.ACCENT)
	waiting.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	waiting.custom_minimum_size = Vector2(640, 0)
	column.add_child(waiting)
	_show_waiting(waiting)

	column.add_child(Ui.label(Loc.t("ui.suggest_yours"), 17, UiTheme.TEXT_DIM, true))
	var text_area := TextEdit.new()
	text_area.placeholder_text = Loc.t("ui.suggest_placeholder")
	text_area.custom_minimum_size = Vector2(640, 150)
	text_area.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	column.add_child(text_area)

	column.add_child(Ui.label(Loc.t("ui.suggest_name"), 17, UiTheme.TEXT_DIM, true))
	var name_edit := LineEdit.new()
	name_edit.placeholder_text = Loc.t("ui.anonymous")
	name_edit.custom_minimum_size = Vector2(640, 46)
	column.add_child(name_edit)

	# Terms are a notice, not a condition: there is no consent checkbox.
	var terms := Ui.label(Loc.t("ui.suggest_terms", {"url": AppLegal.terms_url()}), 14, UiTheme.TEXT_MUTED)
	terms.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	terms.custom_minimum_size = Vector2(640, 0)
	column.add_child(terms)

	var status := Ui.label("", 16, UiTheme.TEXT_DIM)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.custom_minimum_size = Vector2(640, 48)
	column.add_child(status)
	# The queue names the reason here (stored offline, or the oldest suggestion
	# dropped by the cap). `last_warning` pins it for the sender, whose own status
	# text would otherwise overwrite it.
	var last_warning := {"text": ""}
	_warning_hook = func(reason: String) -> void:
		last_warning["text"] = reason
		if not is_instance_valid(status):
			return
		status.add_theme_color_override("font_color", UiTheme.WARNING)
		status.text = reason
	Api.suggestion_failed.connect(_warning_hook)

	var actions := Ui.hbox(10)
	actions.alignment = BoxContainer.ALIGNMENT_END
	column.add_child(actions)

	var send := Ui.button(Loc.t("ui.suggest_send"), Vector2(160, 48), UiTheme.ACCENT)
	var cancel := Ui.button(Loc.t("ui.close"), Vector2(140, 48), UiTheme.PANEL_LIGHT, func() -> void:
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
			status.text = Loc.t("ui.suggest_too_short")
			status.add_theme_color_override("font_color", UiTheme.DANGER)
			return
		send.disabled = true
		send.text = Loc.t("ui.suggest_sending")
		last_warning["text"] = ""
		var author := name_edit.text.strip_edges().substr(0, 60)
		# "Anonym" is a backend value, not screen text: it shows next to other
		# suggestions on the dashboard.
		var view := await Api.submit_suggestion(text, author if author != "" else "Anonym", source)
		if view.is_empty():
			status.add_theme_color_override("font_color", UiTheme.WARNING)
			# A concrete reason from the queue beats the generic "stored" sentence.
			var reason := str(last_warning.get("text", ""))
			status.text = reason if reason != "" else Loc.t("ui.suggest_queued")
			send.text = Loc.t("ui.suggest_stored")
			_show_waiting(waiting)
			Sfx.level_up()
			return
		Sfx.level_up()
		status.add_theme_color_override("font_color", UiTheme.SUCCESS)
		var cluster := int(view.get("clusterSize", 1))
		var extra := ""
		if cluster > 1:
			extra = Loc.t("ui.suggest_cluster", {"count": str(cluster)})
		status.text = Loc.t("ui.suggest_thanks", {"id": str(int(view.get("id", 0))), "extra": extra})
		send.text = Loc.t("ui.suggest_sent")
		_show_waiting(waiting)
	)

	backdrop.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed:
			close()
	)
