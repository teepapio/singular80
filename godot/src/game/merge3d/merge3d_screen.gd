class_name Merge3DScreen
extends WorldScreen
## Merge 3D — a 6x6 board where three or five identical items upgrade into the
## next tier. Port of `scenes/Merge3DScene.ts` plus `merge3d.ts`.
##
## Two editions share the screen: Christmas ornaments and Halloween pumpkins.

const GRID := 6
const CELL := 2.0
const TILE_HEIGHT := 0.35
const ITEM_BASE_Y := 1.0
const ITEM_SCALE := 0.72
const ITEM_BOB := 0.12
const SELECTED_SCALE := 1.22
const INITIAL_ITEMS := 10
const PARTICLE_COUNT := 260
const PARTICLE_TOP := 22.0
const PARTICLE_AREA := 44.0
## How long a tip keeps pulsing, and how long the player must idle on a nearly
## full board before the screen offers the merge on its own.
const HINT_LIFETIME := 4.0
const HINT_IDLE := 6.0
const HINT_PULSE := 0.13

var theme: Dictionary = {}
var theme_id := "christmas"
var board := PackedInt32Array()
var items: Dictionary = {}
var selected: PackedInt32Array = PackedInt32Array()
## Cells the Tipp button marked, plus the time it stops pulsing.
var hint_cells: PackedInt32Array = PackedInt32Array()
var hint_until := 0.0
## Seconds since the last merge — the idle watch behind the automatic tip.
var since_merge := 0.0
var score := 0
var highscore := 0
var used := 0
var spawn_timer := 0.0
var elapsed_run := 0.0
var game_over := false
var tier_templates: Array = []
var tier_pool: Array = []
var particles: MultiMeshInstance3D
var particle_data := PackedFloat32Array()
var particle_speeds := PackedFloat32Array()
var particle_direction := -1.0
var required := Merge3D.MERGE_3

var _glow: OmniLight3D
var _score_label: Label
var _best_label: Label
var _used_label: Label
var _sel_label: Label
var _mode_label: Button
var _hint_button: Button
var _hint_label: Label
var _instruction_label: Label


func _ready_world() -> void:
	theme_id = "halloween" if screen_id.ends_with("halloween") else "christmas"
	theme = Merge3D.theme_by_id(theme_id)
	highscore = Game.highscore(str(theme["highscoreKey"]))

	_setup_theme()
	_build_board()
	_build_particles()
	_build_ui()
	board = Merge3D.create_board(GRID)
	for i in INITIAL_ITEMS:
		_spawn_item()
	_refresh()
	hide_loading()


func _setup_theme() -> void:
	set_fog(theme["background"], 0.012)
	set_ambient(theme["sky"], 0.8)
	sun.light_color = Color.WHITE
	sun.light_energy = 1.25
	fill.light_color = theme["sky"]
	fill.light_energy = 0.4
	camera.fov = 52.0
	camera.far = 300.0
	camera.position = Vector3(0, 13.5, 12.5)

	_glow = OmniLight3D.new()
	_glow.light_color = theme["accent"]
	_glow.light_energy = 24.0
	_glow.omni_range = 26.0
	_glow.position = Vector3(0, 8, 0)
	add_child(_glow)

	var ground := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(34, 0.4, 34)
	ground.mesh = mesh
	ground.material_override = WorldScreen.standard_material(theme["ground"])
	ground.position.y = -0.2
	add_child(ground)

	tier_templates = []
	tier_pool = []
	for tier in range(1, Merge3D.MAX_MERGE_TIER + 1):
		var key := str((theme["tierAssets"] as Array)[tier - 1])
		var template := WorldScreen.mesh(key, Merge3D.tier_color(theme, tier), 1.0, 0.3 if tier >= 4 else 0.0)
		if template == null:
			template = _item_fallback(Merge3D.tier_color(theme, tier))
		tier_templates.append(template)
		tier_pool.append([])


func _item_fallback(color: Color) -> Node3D:
	var root := Node3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.4
	mesh.height = 0.9
	mesh.radial_segments = 8
	mesh.rings = 5
	var body := MeshInstance3D.new()
	body.mesh = mesh
	body.material_override = WorldScreen.standard_material(color, 0.4)
	root.add_child(body)
	return root


func _build_board() -> void:
	var extent := float(GRID) * CELL
	var base := MeshInstance3D.new()
	var base_mesh := BoxMesh.new()
	base_mesh.size = Vector3(extent + 1.2, 0.6, extent + 1.2)
	base.mesh = base_mesh
	base.material_override = WorldScreen.standard_material(Color("111827"))
	base.position.y = -0.3
	add_child(base)

	var tile_mesh := BoxMesh.new()
	tile_mesh.size = Vector3(CELL * 0.9, TILE_HEIGHT, CELL * 0.9)
	var colors: Array = theme["tileColors"]
	var materials: Array = []
	for color in colors:
		materials.append(WorldScreen.standard_material(color))
	for row in GRID:
		for col in GRID:
			var tile := MeshInstance3D.new()
			tile.mesh = tile_mesh
			tile.material_override = materials[(col + row) % 2]
			tile.position = _cell_position(row * GRID + col)
			add_child(tile)


func _cell_position(cell: int) -> Vector3:
	var col: int = cell % GRID
	var row: int = int(floor(float(cell) / float(GRID)))
	return Vector3(
		float(col) - float(GRID - 1) * 0.5,
		TILE_HEIGHT * 0.5,
		float(row) - float(GRID - 1) * 0.5
	) * CELL


func _build_particles() -> void:
	particle_direction = -1.0 if bool(theme["particleFall"]) else 1.0
	var mesh := SphereMesh.new()
	mesh.radius = 0.1
	mesh.height = 0.2
	mesh.radial_segments = 5
	mesh.rings = 3
	particles = MultiMeshInstance3D.new()
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = PARTICLE_COUNT
	multimesh.visible_instance_count = PARTICLE_COUNT
	particles.multimesh = multimesh
	particles.material_override = WorldScreen.standard_material(theme["particle"], 0.7)
	add_child(particles)

	particle_data = PackedFloat32Array()
	particle_data.resize(PARTICLE_COUNT * 3)
	particle_speeds = PackedFloat32Array()
	particle_speeds.resize(PARTICLE_COUNT)
	for i in PARTICLE_COUNT:
		particle_data[i * 3] = randf_range(-0.5, 0.5) * PARTICLE_AREA
		particle_data[i * 3 + 1] = randf() * PARTICLE_TOP
		particle_data[i * 3 + 2] = randf_range(-0.5, 0.5) * PARTICLE_AREA
		particle_speeds[i] = 1.0 + randf() * 2.0


func _write_particles() -> void:
	if particles == null or particles.multimesh == null:
		return
	for i in PARTICLE_COUNT:
		particles.multimesh.set_instance_transform(i, Transform3D(Basis.IDENTITY, Vector3(
			particle_data[i * 3], particle_data[i * 3 + 1], particle_data[i * 3 + 2])))


func _build_ui() -> void:
	var column := VBoxContainer.new()
	column.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	column.position = Vector2(20, 74)
	column.custom_minimum_size = Vector2(300, 0)
	column.add_theme_constant_override("separation", 2)
	hud_root.add_child(column)
	var frame := Ui.rect(Color(0.031, 0.047, 0.086, 0.66), 12, Color(1, 1, 1, 0.1), 1)
	frame.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	frame.offset_left = 12
	frame.offset_right = 332
	frame.offset_top = 66
	frame.offset_bottom = 216
	hud_root.add_child(frame)
	column.position = Vector2(26, 76)

	var title := Ui.label(Loc.f("%s  %s", [theme["icon"], theme["title"]]), 22, UiTheme.TEXT, true)
	column.add_child(title)
	_score_label = _hud_value(column, "Punkte", "0", Color("facc15"))
	_best_label = _hud_value(column, "Bestwert", str(highscore), Color("facc15"))
	_used_label = _hud_value(column, "Felder belegt", "0", UiTheme.TEXT)
	_sel_label = _hud_value(column, "Auswahl", "—", UiTheme.TEXT_DIM)

	_mode_label = Ui.button("3er-Merge", Vector2(190, 52), UiTheme.ACCENT, _toggle_mode)
	_mode_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_mode_label.position = Vector2(24, -64)
	hud_root.add_child(_mode_label)

	var merge_button := Ui.button("Merge", Vector2(190, 52), UiTheme.SUCCESS, _try_merge)
	merge_button.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	merge_button.position = Vector2(228, -64)
	hud_root.add_child(merge_button)

	_hint_button = Ui.button("Hint", Vector2(190, 52), UiTheme.PANEL_LIGHT, _show_hint)
	_hint_button.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_hint_button.position = Vector2(432, -64)
	hud_root.add_child(_hint_button)

	var clear_button := Ui.button("Clear selection", Vector2(200, 52), UiTheme.PANEL_LIGHT, func() -> void:
		selected = PackedInt32Array()
		_clear_hint()
		_refresh()
	)
	clear_button.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	clear_button.position = Vector2(636, -64)
	hud_root.add_child(clear_button)

	# The tip line answers the question the button raises: what it points at,
	# and whether it is worth pressing.
	_hint_label = Ui.label("", 19, UiTheme.TEXT_DIM)
	_hint_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_hint_label.position = Vector2(0, -138)
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud_root.add_child(_hint_label)

	_instruction_label = Ui.label(_instruction_text(), 15, UiTheme.TEXT_DIM)
	_instruction_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_instruction_label.position = Vector2(0, -104)
	_instruction_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud_root.add_child(_instruction_label)


## The rules line follows the merge mode: a 5er tip promising three items is
## worse than no tip.
func _instruction_text() -> String:
	if required == Merge3D.MERGE_5:
		return "Items antippen — 5 gleiche ergeben 2 Items der nächsten Stufe"
	return "Items antippen und auswählen — 3 gleiche ergeben ein Item der nächsten Stufe"


func _hud_value(parent: VBoxContainer, caption: String, value: String, color: Color) -> Label:
	var row := Ui.hbox(10)
	parent.add_child(row)
	row.add_child(Ui.label(caption, 15, UiTheme.TEXT_DIM))
	var spacer := Ui.spacer()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	var result := Ui.label(value, 19, color, true)
	row.add_child(result)
	return result


func _toggle_mode() -> void:
	required = Merge3D.MERGE_5 if required == Merge3D.MERGE_3 else Merge3D.MERGE_3
	_mode_label.text = "5er-Merge" if required == Merge3D.MERGE_3 else "3er-Merge"
	_instruction_label.text = _instruction_text()
	selected = PackedInt32Array()
	_clear_hint()
	Sfx.select()
	_refresh()


# --- Tipp --------------------------------------------------------------------

## Marks the most valuable merge on the board and selects it, so one more tap on
## "Verschmelzen" finishes the move. What the tip leaves to the player is *which*
## merge to take, and the tip line says what the one it picked is worth.
##
## `loud` is false for the automatic tip: a message and a sound every few
## seconds would be worse than the silence it is trying to break.
func _show_hint(loud: bool = true) -> void:
	var cells := _hint_cells()
	_clear_hint()
	if cells.is_empty():
		_hint_label.text = "Gerade nichts zu mergen — es kommen laufend neue Items."
		_hint_label.add_theme_color_override("font_color", UiTheme.TEXT_MUTED)
		if loud:
			notify("No merge possible — wait a moment")
			Sfx.select()
		return
	var tier: int = board[cells[0]]
	hint_cells = cells
	hint_until = elapsed + HINT_LIFETIME
	selected = cells
	_hint_label.text = "Tipp: %s" % Merge3D.hint_text(theme, board, cells)
	_hint_label.add_theme_color_override("font_color", Merge3D.tier_color(theme, tier).lightened(0.4))
	if loud:
		notify(Loc.f("Hint: %s", [Merge3D.tier_name(theme, tier)]))
		Sfx.select()
	_refresh()


func _clear_hint() -> void:
	hint_cells = PackedInt32Array()
	hint_until = 0.0


## The cells the tip would mark: a full group in the current mode, or — in
## 5er mode — the group of three that `_try_merge` falls back to anyway.
func _hint_cells() -> PackedInt32Array:
	var cells := Merge3D.find_hint(board, required)
	if cells.is_empty():
		cells = Merge3D.find_hint(board, Merge3D.MERGE_3)
	return cells


# --- items ------------------------------------------------------------------

func _spawn_item() -> void:
	var cell := Merge3D.pick_spawn_cell(board)
	if cell < 0:
		return
	var tier := Merge3D.spawn_tier(elapsed_run)
	board[cell] = tier
	_add_item_node(cell, tier, true)
	_refresh()


func _add_item_node(cell: int, tier: int, pop: bool) -> void:
	var node: Node3D
	var pool: Array = tier_pool[clampi(tier, 1, tier_pool.size()) - 1]
	if not pool.is_empty():
		node = pool.pop_back()
	else:
		node = (tier_templates[clampi(tier, 1, tier_templates.size()) - 1] as Node3D).duplicate() as Node3D
	node.visible = true
	node.scale = Vector3.ONE * (ITEM_SCALE * 0.05 if pop else ITEM_SCALE)
	node.position = _cell_position(cell) + Vector3(0, ITEM_BASE_Y, 0)
	add_child(node)
	items[cell] = {"node": node, "tier": tier, "phase": randf() * TAU, "target_scale": ITEM_SCALE}


func _remove_item_node(cell: int) -> void:
	if not items.has(cell):
		return
	var view: Dictionary = items[cell]
	var node: Node3D = view["node"]
	# Detach instead of freeing: the pool hands the node straight back to
	# `_add_item_node`, and a node queued for deletion but re-added in the same
	# frame is gone while it is still on the board.
	remove_child(node)
	tier_pool[clampi(int(view["tier"]), 1, tier_pool.size()) - 1].append(node)
	items.erase(cell)


# --- input ------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if game_over:
		return
	if event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed:
		_pick((event as InputEventScreenTouch).position)
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		_pick((event as InputEventMouseButton).position)
	elif event is InputEventKey and event.is_pressed():
		var key := event as InputEventKey
		if key.keycode == KEY_SPACE:
			_try_merge()
		elif key.keycode == KEY_T:
			_show_hint()


## Screen-space picking: the item whose projected centre is closest to the
## tap wins. Simple, allocation free and independent of physics bodies.
func _pick(screen_position: Vector2) -> void:
	var best_cell := -1
	var best_distance := 120.0
	for cell in items:
		var node: Node3D = (items[cell] as Dictionary)["node"]
		if camera.is_position_behind(node.global_position):
			continue
		var projected := camera.unproject_position(node.global_position)
		var distance := projected.distance_to(screen_position)
		if distance < best_distance:
			best_distance = distance
			best_cell = int(cell)
	if best_cell >= 0:
		_toggle_cell(best_cell)


func _toggle_cell(cell: int) -> void:
	if board[cell] == Merge3D.EMPTY_CELL:
		selected = PackedInt32Array()
		_clear_hint()
		_refresh()
		return
	var next := PackedInt32Array(selected)
	if next.has(cell):
		next.remove_at(next.find(cell))
	else:
		next.append(cell)
	selected = next
	# The player's own tap ends the tip — from here the selection is his.
	_clear_hint()
	Sfx.select()
	_refresh()


func _try_merge() -> void:
	if Merge3D.merge_is_valid(board, selected, required):
		var outcome := Merge3D.perform_merge(board, selected, required)
		for cell in selected:
			_remove_item_node(cell)
		board = outcome["board"]
		score += int(outcome["score"])
		since_merge = 0.0
		Sfx.merge()
		for created in outcome["created"]:
			_add_item_node(int(created["cell"]), int(created["tier"]), true)
		selected = PackedInt32Array()
		_clear_hint()
		_refresh()
		return
	# A 3-merge attempt on a 5-selection still works when enough items match.
	if Merge3D.merge_is_valid(board, selected, Merge3D.MERGE_3):
		required = Merge3D.MERGE_3
		_try_merge()
		required = Merge3D.MERGE_5 if _mode_label.text == "3er-Merge" else Merge3D.MERGE_3
		return
	selected = PackedInt32Array()
	_refresh()


# --- loop -------------------------------------------------------------------

func _update_world(delta: float) -> void:
	var dt: float = minf(delta, 0.05)
	if not game_over:
		elapsed_run += dt
		since_merge += dt
		spawn_timer -= dt
		if spawn_timer <= 0.0:
			spawn_timer = Merge3D.spawn_interval_seconds(elapsed_run)
			_spawn_item()
			if Merge3D.is_game_over(board):
				_end_run()
		elif _should_auto_hint():
			# A nearly closed board and a long time without a merge: hand the
			# player the merge before the next spawn ends the run.
			since_merge = 0.0
			_show_hint(false)

	var hinting: bool = hint_until > elapsed
	for cell in items:
		var view: Dictionary = items[cell]
		var node: Node3D = view["node"]
		var is_selected: bool = selected.has(cell)
		var is_hint: bool = hinting and hint_cells.has(int(cell))
		node.rotation.y += dt * (1.4 if not is_selected and not is_hint else 3.0)
		node.position.y = _cell_position(int(cell)).y + ITEM_BASE_Y + sin(elapsed_run * 2.0 + float(view["phase"])) * ITEM_BOB
		var target: float = SELECTED_SCALE if is_selected else ITEM_SCALE
		if is_hint:
			target += HINT_PULSE * (0.5 + 0.5 * sin(elapsed * 6.0))
		var current: float = node.scale.x
		node.scale = Vector3.ONE * lerpf(current, target, clampf(dt * 10.0, 0.0, 1.0))
	if hinting == false and not hint_cells.is_empty():
		_clear_hint()

	for i in PARTICLE_COUNT:
		var y: float = particle_data[i * 3 + 1] + particle_direction * particle_speeds[i] * dt
		if particle_direction < 0.0 and y < 0.0:
			y = PARTICLE_TOP
		elif particle_direction > 0.0 and y > PARTICLE_TOP:
			y = 0.0
		particle_data[i * 3 + 1] = y
	_write_particles()

	camera.position.y = 13.5 + sin(elapsed * 0.6) * 0.5
	camera.look_at(Vector3(0, 0.6, 0), Vector3.UP)
	_glow.light_energy = 22.0 + sin(elapsed * 2.4) * 5.0


func _refresh() -> void:
	for cell in _stale_cells():
		_remove_item_node(cell)
	used = Merge3D.used_cells(board)
	_score_label.text = Ui.format_number(score)
	_best_label.text = Ui.format_number(maxi(highscore, score))
	_used_label.text = "%d/%d" % [used, board.size()]
	# Red while the board closes: a number nobody notices is no tension.
	_used_label.add_theme_color_override("font_color",
		UiTheme.DANGER if Merge3D.is_pressing(board) else UiTheme.TEXT)
	if selected.is_empty():
		_sel_label.text = "—"
	else:
		_sel_label.text = "%d× %s" % [selected.size(), Merge3D.tier_name(theme, board[selected[0]])]


## The automatic tip only fires when it helps: an almost full board, no merge
## for a while, and the player not in the middle of choosing something.
func _should_auto_hint() -> bool:
	return selected.is_empty() \
		and hint_cells.is_empty() \
		and since_merge >= HINT_IDLE \
		and Merge3D.is_pressing(board) \
		and not _hint_cells().is_empty()


## Item nodes whose board cell was consumed by a merge.
func _stale_cells() -> PackedInt32Array:
	var stale := PackedInt32Array()
	for cell in items:
		if board[int(cell)] == Merge3D.EMPTY_CELL:
			stale.append(int(cell))
	return stale


func _end_run() -> void:
	game_over = true
	Game.submit_score(str(theme["highscoreKey"]), score)
	Sfx.game_over()
	var layer := Control.new()
	layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.set_meta("merge_over", true)
	hud_root.add_child(layer)
	layer.add_child(Ui.backdrop(0.8))
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(center)
	var column := Ui.vbox(14)
	center.add_child(column)
	column.add_child(Ui.title("No space left", 44, Color("f87171")))
	column.add_child(Ui.label(Loc.f("Points: %s", [Ui.format_number(score)]), 24, UiTheme.TEXT))
	column.add_child(Ui.button("New game", Vector2(340, 56), UiTheme.ACCENT, func() -> void: Router.go_to(screen_id)))
	column.add_child(Ui.button("Lobby", Vector2(340, 56), UiTheme.PANEL_LIGHT, func() -> void: Router.to_lobby()))
