class_name PangMenuScreen
extends Screen
## Level selection for "Pang 3D".
##
## The original arcade game is a straight level ladder, so this is a plain grid
## of levels with their best time and a lock, in the app's menu style: a centred
## column of `Ui.*` containers that adapts from a phone to a desktop window.

const CARD := Vector2(190, 132)
const GAP := 12

var _page := 0
var _page_label: Label
var _detail: Label
var _panel: VBoxContainer
## The drifting background discs, so a window resize can put them back on screen.
var _discs: Array[Control] = []


func _ready_game() -> void:
	_draw_background()
	_build_chrome()
	_rebuild()


func _draw_background() -> void:
	var layer := Control.new()
	layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content_layer().add_child(layer)
	layer.add_child(Ui.rect(UiTheme.BG))
	# A few slow drifting discs, echoing the bouncing balls of the game.
	#
	# The field is the size of the window, not a fixed 1300x700: a 4:3 tablet runs
	# a 1280x1707 viewport, and a hard-coded extent leaves the lower two thirds
	# of the screen bare.
	var extent := _disc_extent()
	for i in 16:
		var dot := Ui.rect(Color(0.055, 0.647, 0.898, randf_range(0.05, 0.22)), 64)
		dot.size = Vector2.ONE * randf_range(60.0, 190.0)
		dot.position = Vector2(randf() * extent.x - 40.0, randf() * extent.y - 40.0)
		layer.add_child(dot)
		_discs.append(dot)
		var tween := dot.create_tween()
		tween.set_loops()
		tween.tween_property(dot, "position:y", dot.position.y + randf_range(120.0, 320.0), randf_range(7.0, 14.0)).set_trans(Tween.TRANS_SINE)
		tween.tween_property(dot, "position:y", dot.position.y - 120.0, randf_range(7.0, 14.0)).set_trans(Tween.TRANS_SINE)
	var viewport := get_viewport()
	if not viewport.size_changed.is_connected(_respawn_discs):
		viewport.size_changed.connect(_respawn_discs)


## The area the discs drift through: the window, plus the width of the largest one.
func _disc_extent() -> Vector2:
	var size := get_viewport_rect().size
	return Vector2(maxf(320.0, size.x) + 40.0, maxf(240.0, size.y) + 320.0)


## A window that changed shape leaves half the discs outside it.
func _respawn_discs() -> void:
	var extent := _disc_extent()
	for dot in _discs:
		if not is_instance_valid(dot):
			continue
		dot.position = Vector2(randf() * extent.x - 40.0, randf() * extent.y - 40.0)


func _build_chrome() -> void:
	var column := Ui.vbox(6)
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	column.offset_top = 58
	column.offset_bottom = -40
	column.offset_left = 16
	column.offset_right = -16
	content_layer().add_child(column)

	column.add_child(Ui.title("PANG 3D", 44, UiTheme.ACCENT))
	column.add_child(Ui.label("Skewer every ball before time runs out.", 17, UiTheme.TEXT_DIM))
	column.add_child(Ui.label(
		Loc.f("From level %d on, reinforcements announce themselves; the card names the side.", [Pang.WAVE_FIRST_LEVEL]), 15, Color("f472b6")
	))
	_page_label = Ui.label("", 16, UiTheme.TEXT_DIM)
	_page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_page_label)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)

	_panel = Ui.vbox(GAP)
	_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_panel)

	_detail = Ui.label("", 17, UiTheme.TEXT)
	_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_detail)

	var row := Ui.hbox(8)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_child(row)
	row.add_child(Ui.button("◀ Back", Vector2(130, 44), UiTheme.PANEL_LIGHT, func() -> void: _turn_page(-1)))
	row.add_child(Ui.button("Continue ▶", Vector2(130, 44), UiTheme.PANEL_LIGHT, func() -> void: _turn_page(1)))
	row.add_child(Ui.button("⏵ Play", Vector2(200, 44), UiTheme.ACCENT, func() -> void: _start()))


func _rebuild() -> void:
	for child in _panel.get_children():
		child.queue_free()
	var span := _page_range()
	_page_label.text = Loc.f("Level %d–%d of %d  ·  Best time %s", [
		span.x, span.y, Pang.TOTAL_LEVELS, _page_best(span)])
	var grid := GridContainer.new()
	grid.columns = 5
	grid.add_theme_constant_override("h_separation", GAP)
	grid.add_theme_constant_override("v_separation", GAP)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_panel.add_child(grid)
	for level in range(span.x, span.y + 1):
		grid.add_child(_level_card(level))
	_detail.text = Loc.f("Unlocked up to level %d.", [Pang.unlocked_level()])


func _pages() -> int:
	return int(ceil(float(Pang.TOTAL_LEVELS) / float(Pang.LEVELS_PER_PAGE)))


func _turn_page(direction: int) -> void:
	_page = clampi(_page + direction, 0, _pages() - 1)
	Sfx.select()
	_rebuild()


func _page_range() -> Vector2i:
	var first := _page * Pang.LEVELS_PER_PAGE + 1
	return Vector2i(first, mini(first + Pang.LEVELS_PER_PAGE - 1, Pang.TOTAL_LEVELS))


func _page_best(span: Vector2i) -> String:
	var best := 0.0
	for level in range(span.x, span.y + 1):
		best = maxf(best, Pang.level_best_time(level))
	# The condition belongs outside the format, or `Loc.decimal` ends up with a
	# dash. `—` needs no translation.
	return Loc.t("common.seconds", {"seconds": Loc.decimal(best, 1)}) if best > 0.0 else "—"


func _level_card(level: int) -> Control:
	var unlocked := Pang.is_unlocked(level)
	var best := Pang.level_best_time(level)
	var box := Ui.panel(UiTheme.PANEL_LIGHT if unlocked else UiTheme.PANEL, UiTheme.BORDER if unlocked else Color(0.16, 0.20, 0.26), 12)
	box.custom_minimum_size = CARD
	var column := Ui.vbox(2)
	box.add_child(column)

	var headline := Ui.label(Loc.f("%d", [level]), 30, UiTheme.ACCENT if unlocked else UiTheme.TEXT_MUTED, true)
	headline.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(headline)

	var config := Pang.level_config(level)
	# The card counts every ball the level ships, reinforcements included, so it
	# never promises a nearly empty arena. Through the catalogue, because the
	# number is 1 on the tutorial level and a card that says "1 balls" is worse
	# than no card at all.
	var waves := int(config["waves"])
	var count_text := Loc.f("Balls: %d", [Pang.level_ball_total(level)])
	if waves > 0:
		count_text += "  ·  " + Pang.wave_label(waves)
	var count := Ui.label(count_text, 13, UiTheme.TEXT_DIM)
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(count)

	# Which flank a wave arrives over is half the battle in that level, so the
	# card says it up front instead of letting the player find out on the floor.
	if waves > 0:
		var flanks := Ui.label("Reinforcements: " + Pang.wave_flanks_label(level), 12, Color("f472b6"))
		flanks.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		column.add_child(flanks)

	var record := Ui.label(Loc.t("common.seconds", {"seconds": Loc.decimal(best, 1)}) if best > 0.0 else "—", 18, Color("facc15") if best > 0.0 else UiTheme.TEXT_MUTED, true)
	record.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(record)

	var button := Button.new()
	button.flat = true
	button.focus_mode = Control.FOCUS_NONE
	button.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	button.pressed.connect(func() -> void:
		if not Pang.is_unlocked(level):
			show_toast(Loc.f("Level %d is still locked.", [level]))
			Sfx.hurt()
			return
		Sfx.select()
		Router.go_to("pang", {"level": level}))
	box.add_child(button)
	return box


func _start() -> void:
	var target := _page_range().x
	while not Pang.is_unlocked(target) and target > 1:
		target -= 1
	Sfx.select()
	Router.go_to("pang", {"level": target})
