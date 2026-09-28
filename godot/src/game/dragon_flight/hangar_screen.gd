class_name DragonFlightHangarScreen
extends Screen
## The Drachenflug hangar: pick a dragon, pick a level, buy upgrades.
##
## The lobby entry point of the game. It is the only place that writes to the
## save outside a finished run, and every number it shows comes from
## `DragonFlight`, so the flight screen can never disagree with it.

const COLUMNS := 3
const CARD := Vector2(152, 104)
const PANEL_WIDTH := 330
const DRAGONS_PER_PAGE := 3

var profile: Dictionary = {}
var selected_level := 1
var selected_dragon := 0

var _level_grid: GridContainer
var _dragon_row: HBoxContainer
var _upgrades: VBoxContainer
var _stats: VBoxContainer
var _gold_label: Label
var _title: Label
var _detail: Label
var _start: Button
var _dragon_page := 0


func _ready_game() -> void:
	profile = DragonFlight.load_profile()
	selected_level = DragonFlight.next_unlocked(1, profile)
	selected_dragon = int(profile.get("active", 0))
	_build_hangar()
	_refresh()


## Builds the hangar layout. Deliberately not called `_build()`: that name
## belongs to `Screen` and would replace the shared top bar.
##
## Everything is laid out with containers so the three columns can never overlap
## and the 30 level cards simply scroll.
func _build_hangar() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_top", 64)
	margin.add_theme_constant_override("margin_bottom", 12)
	content_layer().add_child(margin)

	var column := Ui.vbox(8)
	margin.add_child(column)

	var header := Ui.hbox(12)
	column.add_child(header)
	_title = Ui.label("DRAGON FLIGHT", 28, UiTheme.ACCENT, true)
	_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(_title)
	header.add_child(Ui.spacer())
	_gold_label = Ui.label("", 20, Color("fbbf24"), true)
	_gold_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(_gold_label)
	header.add_child(Ui.button("Breeding", Vector2(140, 42), UiTheme.PANEL_LIGHT, func() -> void:
		Sfx.select()
		Router.go_to("dragonflight_hatchery")
	))

	# --- middle: dragons | levels | upgrades ---------------------------------
	var middle := Ui.hbox(8)
	middle.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(middle)
	middle.add_child(_build_dragon_panel())
	middle.add_child(_build_level_scroll())
	middle.add_child(_build_upgrade_panel())

	# --- footer ---------------------------------------------------------------
	var footer := Ui.hbox(12)
	column.add_child(footer)
	_detail = Ui.label("", 16, UiTheme.TEXT_DIM)
	_detail.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(_detail)
	_start = Ui.button("Start", Vector2(300, 52), UiTheme.ACCENT, _on_start)
	footer.add_child(_start)


func _panel(title: String, width: float) -> Array:
	"""A titled panel plus its VBox, ready to be filled. The width is fixed and\n	the content wraps, so a long trait text can never widen the layout."""
	var panel := Ui.panel(UiTheme.PANEL, UiTheme.BORDER, 12)
	panel.custom_minimum_size = Vector2(width, 0)
	panel.size_flags_horizontal = Control.SIZE_FILL
	var box := Ui.vbox(6)
	panel.add_child(box)
	box.add_child(Ui.label(title, 19, UiTheme.TEXT, true))
	return [panel, box]


## Vertical scroller with a fixed width: its child is forced to that width, so
## wrapped labels shrink instead of widening the panel.
func _vscroll(inner: Control, width: float) -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(width, 0)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(inner)
	return scroll


## A label that wraps instead of stretching its container.
func _wrap(text: String, size: int, color: Color, bold: bool = false) -> Label:
	var node := Ui.label(text, size, color, bold)
	node.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	node.custom_minimum_size = Vector2(40, 0)
	return node


func _build_dragon_panel() -> Control:
	var parts := _panel("Deine Drachen", PANEL_WIDTH)
	var panel: PanelContainer = parts[0]
	var box: VBoxContainer = parts[1]
	_dragon_row = Ui.hbox(5)
	box.add_child(_dragon_row)
	_stats = Ui.vbox(3)
	box.add_child(_vscroll(_stats, PANEL_WIDTH - 30))
	return panel


func _build_upgrade_panel() -> Control:
	var parts := _panel("Dauerhafte Upgrades", PANEL_WIDTH)
	var panel: PanelContainer = parts[0]
	var box: VBoxContainer = parts[1]
	_upgrades = Ui.vbox(4)
	box.add_child(_vscroll(_upgrades, PANEL_WIDTH - 30))
	return panel


func _build_level_scroll() -> Control:
	_level_grid = GridContainer.new()
	_level_grid.columns = COLUMNS
	_level_grid.add_theme_constant_override("h_separation", 7)
	_level_grid.add_theme_constant_override("v_separation", 7)
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_level_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_level_grid)
	return scroll


# --- refresh ----------------------------------------------------------------

func _refresh() -> void:
	_gold_label.text = "◈ %s Gold   ·   %d Eier" % [Ui.format_number(int(profile.get("gold", 0))), int(profile.get("eggs", 0))]
	_rebuild_dragons()
	_rebuild_upgrades()
	_rebuild_levels()
	_refresh_stats()


func _rebuild_dragons() -> void:
	for child in _dragon_row.get_children():
		child.queue_free()
	var owned := DragonFlight.dragons_of(profile)
	if owned.is_empty():
		_dragon_row.add_child(Ui.label("No dragon yet", 16, UiTheme.TEXT_DIM))
		return
	var per_page := DRAGONS_PER_PAGE
	var pages: int = maxi(1, int(ceil(float(owned.size()) / float(per_page))))
	_dragon_page = clampi(_dragon_page, 0, pages - 1)
	for i in range(_dragon_page * per_page, mini(owned.size(), (_dragon_page + 1) * per_page)):
		var dragon: Dictionary = owned[i]
		var breed := DragonFlight.breed_by_id(str(dragon["breed"]))
		var uid := int(dragon["uid"])
		var is_active: bool = uid == selected_dragon
		var traits: Array[String] = DragonFlight.expressed_traits(dragon.get("alleles", {}))
		# "+2" is the hidden part of the dragon's value: two recessive genes
		# this one carries without showing them.
		var carried := DragonFlight.carried_traits(dragon.get("alleles", {}))
		var caption := "%s\nG%d · %d Merkmale" % [str(breed["name"]), int(dragon.get("gen", 1)), traits.size()]
		if not carried.is_empty():
			caption += " · +%d" % carried.size()
		var button := Ui.button(caption, Vector2(100, 78), Color(str(breed["accent"])) if is_active else UiTheme.PANEL_LIGHT, _on_pick_dragon.bind(uid))
		button.add_theme_font_size_override("font_size", 12)
		_dragon_row.add_child(button)
	if pages > 1:
		var nav := Ui.hbox(4)
		nav.add_child(Ui.button("◀", Vector2(34, 30), UiTheme.PANEL_LIGHT, func() -> void:
			_dragon_page = wrapi(_dragon_page - 1, 0, pages)
			_refresh()
		))
		nav.add_child(Ui.label(Loc.f("%d/%d", [_dragon_page + 1, pages]), 14, UiTheme.TEXT_MUTED))
		nav.add_child(Ui.button("▶", Vector2(34, 30), UiTheme.PANEL_LIGHT, func() -> void:
			_dragon_page = wrapi(_dragon_page + 1, 0, pages)
			_refresh()
		))
		_dragon_row.add_child(nav)


func _refresh_stats() -> void:
	for child in _stats.get_children():
		child.queue_free()
	var dragon := DragonFlight.dragon_by_uid(profile, selected_dragon)
	if dragon.is_empty():
		_stats.add_child(Ui.label("Choose a dragon.", 16, UiTheme.TEXT_DIM))
		return
	var breed := DragonFlight.breed_by_id(str(dragon["breed"]))
	var stats := DragonFlight.resolve_stats(dragon, profile.get("upgrades", {}))
	_title.text = "☄  DRACHENFLUG  ·  %s" % str(breed["name"])
	_stats.add_child(_wrap(str(breed["desc"]), 14, UiTheme.TEXT_MUTED))
	_stat_row("Lebensenergie", "%d" % roundi(float(stats["max_hp"])), Color("22c55e"))
	_stat_row("Tempo", "%.0f" % float(stats["speed"]), Color("38bdf8"))
	_stat_row("Wendigkeit", "%.1f" % float(stats["turn"]), Color("38bdf8"))
	_stat_row("Schaden", "%.0f" % float(stats["damage"]), Color("f97316"))
	_stat_row("Feuerrate", "%.2f s" % float(stats["fire_rate"]), Color("f59e0b"))
	_stat_row("Rüstung", "%d %%" % roundi(float(stats["armor"]) * 100.0), Color("94a3b8"))
	_stat_row("Größe", "×%.2f" % DragonFlight.visual_scale(dragon), Color("a855f7"))
	var traits: Array = stats.get("traits", [])
	if traits.is_empty():
		_stats.add_child(Ui.label("No inherited traits", 14, UiTheme.TEXT_MUTED))
	else:
		for id in traits:
			var gene := DragonFlight.trait_by_id(str(id))
			var row := Ui.vbox(0)
			_stats.add_child(row)
			var head := Ui.hbox(6)
			row.add_child(head)
			head.add_child(Ui.rect(Color(str(gene["hue"])), 10, Color(0, 0, 0, 0), 0))
			head.add_child(Ui.label(str(gene["name"]), 14, Color(str(gene["hue"])), true))
			row.add_child(_wrap(str(gene["desc"]), 12, UiTheme.TEXT_DIM))
	# A recessive gene that this dragon does not show is still worth knowing:
	# it is a carrier, and a carrier paired with a second one is the only way
	# to breed the trait at all.
	var carried: Array[String] = DragonFlight.carried_traits(dragon.get("alleles", {}))
	if not carried.is_empty():
		var names: Array[String] = []
		for id in carried:
			names.append(str(DragonFlight.trait_by_id(id)["name"]))
		_stats.add_child(_wrap("Verdeckte Träger: %s" % ", ".join(names), 13, Color("fbbf24")))


func _on_pick_dragon(uid: int) -> void:
	Sfx.select()
	selected_dragon = uid
	profile["active"] = uid
	DragonFlight.save_profile(profile)
	_refresh()


func _stat_row(caption: String, value: String, color: Color) -> void:
	var row := Ui.hbox(8)
	_stats.add_child(row)
	row.add_child(Ui.label(caption, 15, UiTheme.TEXT_DIM))
	row.add_child(Ui.spacer())
	row.add_child(Ui.label(value, 16, color, true))


func _rebuild_upgrades() -> void:
	for child in _upgrades.get_children():
		child.queue_free()
	for upgrade in DragonFlight.UPGRADES:
		var id := str(upgrade["id"])
		var level := DragonFlight.upgrade_level(id, profile)
		var cost := DragonFlight.upgrade_cost(id, profile)
		var maxed: bool = cost < 0
		var row := Ui.hbox(8)
		_upgrades.add_child(row)
		var text := Ui.vbox(0)
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(text)
		text.add_child(Ui.label(Loc.f("%s  (tier %d/%d)", [str(upgrade["name"]), level, int(upgrade["max"])]), 15, UiTheme.TEXT, true))
		text.add_child(_wrap(str(upgrade["desc"]), 12, UiTheme.TEXT_MUTED))
		if maxed:
			row.add_child(Ui.label("MAX", 16, Color("fbbf24"), true))
		else:
			var affordable: bool = int(profile.get("gold", 0)) >= cost
			row.add_child(Ui.button(Loc.f("%d ◈", [cost]), Vector2(96, 40),
				UiTheme.PANEL_LIGHT if affordable else UiTheme.PANEL, _on_buy.bind(id)))


## Buys one upgrade step and reports a failure as a toast.
func _on_buy(id: String) -> void:
	if DragonFlight.buy_upgrade(id, profile) < 0:
		show_toast("Not enough gold")
		return
	DragonFlight.save_profile(profile)
	Sfx.coin()
	_refresh()


func _rebuild_levels() -> void:
	for child in _level_grid.get_children():
		child.queue_free()
	for n in range(1, DragonFlight.level_count() + 1):
		_level_grid.add_child(_level_card(n))
	_refresh_detail()


func _level_card(n: int) -> Control:
	var level_def := DragonFlight.level(n)
	var unlocked: bool = DragonFlight.is_unlocked(n, profile)
	var stars: int = DragonFlight.stars_of(n, profile)
	var biome := DragonFlight.biome_by_id(str(level_def["biome"]))
	var panel := Ui.panel(UiTheme.PANEL_LIGHT if n == selected_level else UiTheme.PANEL,
		Color(str(biome["accent"])) if unlocked else UiTheme.BORDER, 10)
	var box := Ui.vbox(1)
	panel.add_child(box)
	box.add_child(Ui.label(Loc.f("%d", [n]), 24, Color(str(biome["accent"])) if unlocked else UiTheme.TEXT_MUTED, true))
	# The name wraps, so a long one can never widen the whole grid.
	box.add_child(_wrap(str(level_def["name"]), 14, UiTheme.TEXT if unlocked else UiTheme.TEXT_MUTED))
	box.add_child(Ui.label(str(biome["name"]), 11, UiTheme.TEXT_MUTED))
	box.add_child(Ui.label("★".repeat(stars) + "☆".repeat(3 - stars), 14, Color("facc15")))
	if not unlocked:
		var need := DragonFlight.star_requirement(n)
		# The condition stays outside the format: `"…%d…" % n if n > 0 else "…"`
		# means "format n, or show the other text", and folding the `%` into the
		# argument made a `%d` receive a string. Both branches are translated, so
		# neither is a German leftover.
		var need_text := Loc.f("· needs %d stars", [need]) if need > 0 else Loc.f("· Level %d first", [n - 1])
		box.add_child(Ui.label(need_text, 12, UiTheme.TEXT_MUTED))
		return panel
	panel.custom_minimum_size = CARD
	var button := Button.new()
	button.flat = true
	button.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(_on_pick_level.bind(n))
	panel.add_child(button)
	return panel


func _on_pick_level(n: int) -> void:
	Sfx.select()
	selected_level = n
	_refresh()


func _refresh_detail() -> void:
	var level_def := DragonFlight.level(selected_level)
	var biome := DragonFlight.biome_by_id(str(level_def["biome"]))
	var boss := str(level_def.get("boss", ""))
	var boss_name := "Boss: %s" % str(DragonFlight.enemy_by_id(boss)["name"]) if not boss.is_empty() else "ohne Boss"
	_detail.text = "Level %d · %s · %s m · %d Gegner gleichzeitig · %s" % [
		selected_level,
		str(biome["name"]),
		Ui.format_number(int(level_def["length"])) + " m",
		DragonFlight.concurrent_for(selected_level),
		boss_name,
	]
	_start.disabled = not DragonFlight.is_unlocked(selected_level, profile)


func _on_start() -> void:
	Sfx.select()
	Router.go_to("dragonflight_run", {"level": selected_level})
