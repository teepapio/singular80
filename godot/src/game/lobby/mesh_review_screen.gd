class_name MeshReviewScreen
extends Screen
## The page between the gallery and the dashboard: which meshes are marked,
## what is wrong with them, and the finished suggestion text. The player only
## edits it where they want to sharpen it.

const MAX_NOTE := 400

var _rows: VBoxContainer
var _draft: TextEdit
var _summary: Label
var _submit_button: Button
var _selected := 0


## The list always comes from `MeshGallery`, never from a copy: the gallery can
## add to it while this screen is open, and a stale copy would drop that work.
func _marks() -> Dictionary:
	return MeshGallery.shared_marks()


func _ready_game() -> void:
	var background := Ui.rect(Color("080c16"))
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stage().add_child(background)

	var root := Ui.vbox(10)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 28
	root.offset_right = -28
	root.offset_top = BAR_HEIGHT + 12
	root.offset_bottom = -20
	stage().add_child(root)

	var header := Ui.hbox(12)
	root.add_child(header)
	header.add_child(Ui.label("✎  Mesh improvements", 30, UiTheme.ACCENT, true))
	var spacer := Ui.spacer()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	header.add_child(Ui.button("◈ To the gallery", Vector2(190, 44), UiTheme.PANEL_LIGHT, func() -> void:
		Sfx.select()
		Router.go_to("mesh_gallery")
	))

	var intro := Ui.label(
		"Every shortlisted mesh goes into a single suggestion. The text below is already filled in — change only what you want differently.",
		15, UiTheme.TEXT_DIM)
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(intro)

	# Left: the marks with a note field each. Right: the finished suggestion.
	var columns := Ui.hbox(16)
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(columns)

	var list_panel := Ui.panel()
	list_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_child(list_panel)
	var list_column := Ui.vbox(8)
	list_panel.add_child(list_column)
	list_column.add_child(Ui.label("Shortlisted meshes", 19, UiTheme.TEXT, true))
	_summary = Ui.label("", 15, UiTheme.TEXT_DIM)
	list_column.add_child(_summary)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	list_column.add_child(scroll)
	_rows = Ui.vbox(8)
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_rows)

	var draft_panel := Ui.panel()
	draft_panel.custom_minimum_size = Vector2(430, 0)
	columns.add_child(draft_panel)
	var draft_column := Ui.vbox(8)
	draft_panel.add_child(draft_column)
	draft_column.add_child(Ui.label("Finished suggestion", 19, UiTheme.TEXT, true))
	draft_column.add_child(Ui.label("This is what goes to the dashboard:", 13, UiTheme.TEXT_MUTED))
	_draft = TextEdit.new()
	_draft.custom_minimum_size = Vector2(410, 300)
	_draft.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_draft.size_flags_vertical = Control.SIZE_EXPAND_FILL
	draft_column.add_child(_draft)

	var draft_actions := Ui.hbox(8)
	draft_actions.alignment = BoxContainer.ALIGNMENT_END
	draft_column.add_child(draft_actions)
	draft_actions.add_child(Ui.button("Clear list", Vector2(170, 46), UiTheme.PANEL_LIGHT, func() -> void:
		MeshGallery.set_marks(MeshGallery.clear_marks())
		Sfx.select()
		_rebuild()
	))
	draft_actions.add_child(Ui.button("Apply", Vector2(180, 46), UiTheme.PANEL_LIGHT, func() -> void:
		_draft.text = MeshGallery.draft(_marks())
		Sfx.select()
	))
	_submit_button = Ui.button("Submit a suggestion", Vector2(250, 46), UiTheme.ACCENT, _submit)
	draft_actions.add_child(_submit_button)

	_rebuild()


# --- rows -------------------------------------------------------------------

func _rebuild() -> void:
	for child in _rows.get_children():
		child.queue_free()
	var marks := _marks()
	var order: Array = marks.get("order", [])
	_summary.text = "%d Meshes auf der Liste" % order.size()
	_submit_button.disabled = order.is_empty()
	if order.is_empty():
		_draft.text = ""
		_draft.placeholder_text = "Sobald du in der Galerie ein Mesh vormerkst, steht der Vorschlag hier."
		return
	_selected = clampi(_selected, 0, order.size() - 1)
	for i in order.size():
		_rows.add_child(_row(i, str(order[i])))
	_draft.text = MeshGallery.draft(marks)


func _row(index: int, key: String) -> Control:
	var entry: Dictionary = (_marks().get("entries", {}) as Dictionary).get(key, {})
	var panel := Ui.panel(Color(0.063, 0.082, 0.137, 0.9), Color("fbbf24") if index == _selected else UiTheme.BORDER, 10)
	var column := Ui.vbox(4)
	panel.add_child(column)

	var head := Ui.hbox(8)
	column.add_child(head)
	var title := Ui.label(AssetRegistry.display_name(key), 18, AssetRegistry.color_of(key), true)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	head.add_child(Ui.label(str(AssetRegistry.TIER_LABELS.get(str(entry.get("tier", "low")), "low")), 13, UiTheme.TEXT_DIM))
	head.add_child(Ui.button("✕", Vector2(36, 30), UiTheme.PANEL_LIGHT, func() -> void:
		MeshGallery.set_marks(MeshGallery.unmark(_marks(), key))
		Sfx.select()
		_rebuild()
	))

	var meta := Ui.label(Loc.f("%s   ·   %s triangles", [key, AssetRegistry.tri_text(key, str(entry.get("tier", "low")))]), 12, UiTheme.TEXT_MUTED)
	column.add_child(meta)

	var note := TextEdit.new()
	note.placeholder_text = "Was soll an diesem Mesh besser werden?  z. B. zu wenig Details an den Flügeln"
	note.custom_minimum_size = Vector2(0, 58)
	note.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	note.text = str(entry.get("note", "")).substr(0, MAX_NOTE)
	note.text_changed.connect(func() -> void:
		# Godot 4 has no length limit on TextEdit, so cap it here.
		if note.text.length() > MAX_NOTE:
			note.text = note.text.substr(0, MAX_NOTE)
			return
		MeshGallery.set_marks(MeshGallery.set_note(_marks(), key, note.text))
		# Keep the preview in sync, but never while the player is editing it.
		if not _draft.has_focus():
			_draft.text = MeshGallery.draft(_marks())
	)
	column.add_child(note)
	return panel


# --- submit -----------------------------------------------------------------

func _submit() -> void:
	var text := _draft.text.strip_edges()
	if text.length() < 3:
		show_toast("The suggestion is still empty.")
		return
	_submit_button.disabled = true
	_submit_button.text = "Sende …"
	# The dialog adds "Mesh-Galerie: " itself, so the origin is never lost.
	var result: Dictionary = await Api.submit_suggestion(text, "Anonym", MeshGallery.context())
	if result.is_empty():
		# Only queued, not delivered: the list stays so the player can still copy
		# the text, and `Liste leeren` clears it if they are done.
		_submit_button.text = "Gespeichert ✓"
		_submit_button.disabled = false
		show_toast("Saved offline — the suggestion goes out as soon as you are online again.", 3.5)
		return
	_submit_button.text = "Gesendet ✓"
	show_toast(Loc.f("Thank you! Suggestion #%d is on the dashboard.", [int(result.get("id", 0))]), 3.0)
	Sfx.level_up()
	# Delivered: the work is done, so the list starts empty again.
	MeshGallery.set_marks(MeshGallery.clear_marks())
	await get_tree().create_timer(1.4).timeout
	Router.to_lobby()
