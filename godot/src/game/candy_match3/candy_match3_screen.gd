class_name CandyMatch3Screen
extends WorldScreen
## "Candy Crush 3D" — a match-3 with six themed worlds and 240 generated levels.
## Rules live in `candy_match3.gd`; this screen only draws them and feeds input.
## The board stands upright in the XY plane with the camera in front of it — that
## keeps the pieces readable on a phone and makes touch picking one ray/plane hit.

const CELL := 1.0
const PIECE_SCALE := 0.74
const SELECTED_SCALE := 1.24
const HINT_SCALE := 1.14
## How much a candy grows when it is part of the combination the player is
## holding together — the preview has to be loud enough to read as one shape.
const COMBO_SCALE := 1.18
const SWAP_TIME := 0.17
const STEP_TIME := 0.3
const DRAG_THRESHOLD := 26.0
const UNDO_BASE := 3
const GAME_ID := "candy3d"

const MODE_SELECT := 0
const MODE_BUSY := 1
const MODE_WON := 2
const MODE_LOST := 3

var state: Dictionary = {}
var mode: int = MODE_SELECT
var selected: int = -1
var hint_cells: PackedInt32Array = PackedInt32Array()
## The cells the combination with the selected candy would clear, as a set: the
## preview is asked for on a tap and read every frame, so a lookup beats a scan.
var combo_set: Dictionary = {}
## The name the board announces for that combination, e.g. "Dreifachblitz".
var combo_label: String = ""
var hint_until: float = 0.0
var swap_back: Dictionary = {}
var steps: Array = []
var step_timer: float = 0.0
## Own animation clock, advanced by the delta that `_update_world` is handed.
## The base class only ticks `elapsed` inside `_process`, so every timer read
## from it stands still as soon as the screen is stepped from anywhere else —
## and a cascade that never finishes locks the board.
var clock: float = 0.0
var undo_stack: Array = []
var undo_left: int = UNDO_BASE
var palette_mode: String = CandyMatch3.PALETTE_CLASSIC
var star_cache: Dictionary = {}
var daily_stars: int = 0
var streak: int = 0
var world_id: String = "candy"

## cell → piece view. Each view: {node, color, special, target, scale, dying}
var pieces: Dictionary = {}
var blockers: Dictionary = {}
var piece_pool: Dictionary = {}
var piece_materials: Dictionary = {}
var templates: Dictionary = {}
var blocker_nodes: Node3D
var piece_root: Node3D
var plate_root: Node3D
var fx_root: Node3D
var ring: MeshInstance3D
var particles: MultiMeshInstance3D
var particle_data: PackedFloat32Array
var particle_life: PackedFloat32Array
var particle_velocity: PackedFloat32Array
var particle_cursor: int = 0

var _score_label: Label
var _moves_label: Label
var _title_label: Label
var _world_label: Label
var _goals_box: VBoxContainer
var _undo_button: Button
var _hint_button: Button
var _palette_button: Button
var _select_root: Control
var _select_body: VBoxContainer
var _toast_label: Label
var _toast_until: float = 0.0
var _drag_from: int = -1
var _drag_start: Vector2 = Vector2.ZERO


# --- setup ------------------------------------------------------------------

func _ready_world() -> void:
	# A fresh install plays in the contrast palette: a match-3 is decided by
	# telling six colours apart at a glance, and the soft world palette is the
	# look the player opts into. A stored choice always wins.
	var stored_palette := Game.get_number("candy_palette", -1.0)
	palette_mode = CandyMatch3.PALETTE_CLASSIC if stored_palette >= 0.0 and stored_palette < 0.5 \
		else CandyMatch3.PALETTE_CONTRAST
	_load_star_cache()
	daily_stars = Game.stars(GAME_ID, "daily:%s" % Game.today())
	streak = CandyMatch3.daily_streak(_daily_days(), Game.today())

	plate_root = Node3D.new()
	add_child(plate_root)
	blocker_nodes = Node3D.new()
	add_child(blocker_nodes)
	piece_root = Node3D.new()
	add_child(piece_root)
	fx_root = Node3D.new()
	add_child(fx_root)

	_build_ring()
	_build_particles()
	_build_hud()

	var resume := _resume_level()
	_apply_level(CandyMatch3.level_for(str(resume["world"]), int(resume["index"])))
	_show_level_select()
	get_viewport().size_changed.connect(_fit_camera)
	_fit_camera()
	hide_loading()


## The highest finished campaign level, otherwise the very first one.
func _resume_level() -> Dictionary:
	for i in range(CandyMatch3.WORLDS.size() - 1, -1, -1):
		var def: Dictionary = CandyMatch3.WORLDS[i]
		var world := str(def["id"])
		for index in range(CandyMatch3.LEVELS_PER_WORLD, 0, -1):
			if Game.stars(GAME_ID, str(CandyMatch3.level_for(world, index)["number"])) > 0:
				return {"world": world, "index": index}
	return {"world": "candy", "index": 1}


func _build_ring() -> void:
	var mesh := TorusMesh.new()
	mesh.inner_radius = 0.4
	mesh.outer_radius = 0.5
	ring = MeshInstance3D.new()
	ring.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.WHITE
	material.emission_enabled = true
	material.emission = Color.WHITE
	material.emission_energy_multiplier = 1.6
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring.material_override = material
	ring.visible = false
	fx_root.add_child(ring)


func _build_particles() -> void:
	const COUNT := 260
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.16, 0.16, 0.16)
	particles = MultiMeshInstance3D.new()
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = mesh
	multimesh.instance_count = COUNT
	multimesh.visible_instance_count = COUNT
	particles.multimesh = multimesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	particles.material_override = material
	fx_root.add_child(particles)
	particle_data = PackedFloat32Array()
	particle_data.resize(COUNT * 3)
	particle_life = PackedFloat32Array()
	particle_life.resize(COUNT)
	particle_velocity = PackedFloat32Array()
	particle_velocity.resize(COUNT * 3)
	for i in COUNT:
		particle_data[i * 3] = 999.0
	_write_particles()


func _write_particles() -> void:
	if particles == null or particles.multimesh == null:
		return
	for i in particle_life.size():
		if particle_life[i] <= 0.0:
			continue
		particles.multimesh.set_instance_transform(i, Transform3D(Basis.IDENTITY, Vector3(
			particle_data[i * 3], particle_data[i * 3 + 1], particle_data[i * 3 + 2])))


func _burst(position: Vector3, color: Color, count: int) -> void:
	var total := particle_life.size()
	for i in count:
		var index := particle_cursor
		particle_cursor = (particle_cursor + 1) % total
		particle_data[index * 3] = position.x
		particle_data[index * 3 + 1] = position.y
		particle_data[index * 3 + 2] = 0.6
		particle_velocity[index * 3] = randf_range(-2.6, 2.6)
		particle_velocity[index * 3 + 1] = randf_range(-2.6, 3.0)
		particle_velocity[index * 3 + 2] = randf_range(0.8, 2.4)
		particle_life[index] = 0.5
		particles.multimesh.set_instance_color(index, color)


## Distance the camera keeps from the board — recomputed whenever the viewport
## changes, since `aspect = expand` makes it a different value per device.
var _camera_distance: float = 12.0


## Frames the whole board: the distance follows the viewport aspect, so a phone
## in portrait sees the same eight columns as a tablet in landscape.
func _fit_camera() -> void:
	var size := get_viewport().get_visible_rect().size
	var aspect: float = maxf(0.3, size.x / maxf(1.0, size.y))
	camera.fov = 52.0
	var half := tan(deg_to_rad(camera.fov) * 0.5)
	var by_height := (float(CandyMatch3.ROWS) * CELL * 0.5 + 0.7) / half
	var by_width := (float(CandyMatch3.COLS) * CELL * 0.5 + 0.5) / (half * aspect)
	_camera_distance = maxf(by_height, by_width)
	camera.position = Vector3(0, 0, _camera_distance)
	camera.look_at(Vector3.ZERO, Vector3.UP)
	camera.far = maxf(200.0, _camera_distance * 2.0)


# --- level lifecycle --------------------------------------------------------

func _apply_level(level: Dictionary) -> void:
	var def := CandyMatch3.world_by_id(str(level["worldId"]))
	world_id = str(def["id"])
	var bonus := CandyMatch3.world_bonus(_world_stars(world_id))
	state = CandyMatch3.start_level(level, bonus)
	selected = -1
	ring.visible = false
	hint_cells = PackedInt32Array()
	_clear_combo()
	swap_back = {}
	steps = []
	undo_stack = []
	undo_left = UNDO_BASE + int((bonus as Dictionary)["undos"])
	_set_world_look(def)
	_build_plates(level)
	_build_blockers()
	_rebuild_pieces()
	_title_label.text = str(level["title"])
	_world_label.text = "%s %s" % [str(def["icon"]), str(def["name"])]
	mode = MODE_SELECT
	_refresh()


## Paint, fog and camera for the world, so every level feels different.
func _set_world_look(def: Dictionary) -> void:
	var background := Color(str(def["background"]))
	set_fog(background, 0.02)
	set_ambient(CandyMatch3.palette_color(def, 1), 0.9)
	sun.light_color = Color.WHITE
	sun.light_energy = 1.35
	fill.light_color = CandyMatch3.palette_color(def, 0)
	fill.light_energy = 0.45
	_plate_colors = [Color(str((def["plate"] as Array)[0])), Color(str((def["plate"] as Array)[1]))]
	_icing_color = Color(str(def["icing"]))
	_stone_color = Color(str(def["stone"]))
	_apply_palette()


var _plate_colors: Array[Color] = [Color("3b0764"), Color("2e0a4f")]
var _icing_color: Color = Color("ddd6fe")
var _stone_color: Color = Color("94a3b8")


func _build_plates(level: Dictionary) -> void:
	for child in plate_root.get_children():
		child.queue_free()
	var plate := BoxMesh.new()
	plate.size = Vector3(CELL * 0.94, CELL * 0.94, 0.18)
	var layout: Array = level["layout"]
	for row in CandyMatch3.ROWS:
		for col in CandyMatch3.COLS:
			var line := str(layout[row]) if row < layout.size() else ""
			if line.length() <= col or line[col] != "#":
				continue
			var instance := MeshInstance3D.new()
			instance.mesh = plate
			instance.material_override = WorldScreen.standard_material(_plate_colors[(col + row) % 2])
			instance.position = _cell_position(CandyMatch3.cell_index(col, row)) - Vector3(0, 0, 0.12)
			plate_root.add_child(instance)
	var backing := MeshInstance3D.new()
	var back_mesh := BoxMesh.new()
	back_mesh.size = Vector3(
		float(CandyMatch3.COLS) * CELL + 0.5,
		float(CandyMatch3.ROWS) * CELL + 0.5,
		0.2)
	backing.mesh = back_mesh
	backing.material_override = WorldScreen.standard_material(_plate_colors[1].darkened(0.45))
	backing.position = Vector3(0, 0, -0.3)
	plate_root.add_child(backing)


func _build_blockers() -> void:
	for child in blocker_nodes.get_children():
		child.queue_free()
	blockers.clear()
	var board: Dictionary = state["board"]
	var kind: PackedInt32Array = board["kind"]
	for cell in CandyMatch3.CELL_COUNT:
		if kind[cell] == CandyMatch3.KIND_OPEN or kind[cell] == CandyMatch3.KIND_HOLE:
			continue
		var instance: MeshInstance3D
		if kind[cell] == CandyMatch3.KIND_STONE:
			var rock := SphereMesh.new()
			rock.radius = 0.46
			rock.height = 0.9
			rock.radial_segments = 8
			rock.rings = 4
			instance = MeshInstance3D.new()
			instance.mesh = rock
			instance.material_override = WorldScreen.standard_material(_stone_color, 0.1)
		else:
			var block := BoxMesh.new()
			block.size = Vector3(CELL * 0.86, CELL * 0.86, 0.5)
			instance = MeshInstance3D.new()
			instance.mesh = block
			var material := WorldScreen.standard_material(_icing_color, 0.25)
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			material.albedo_color.a = 0.55
			instance.material_override = material
		instance.position = _cell_position(cell) + Vector3(0, 0, 0.1)
		blocker_nodes.add_child(instance)
		blockers[cell] = instance


# --- pieces -----------------------------------------------------------------

func _template(color: int) -> Node3D:
	if templates.has(color):
		return templates[color]
	var def := CandyMatch3.world_by_id(world_id)
	var key := str((def["pieceAssets"] as Array)[clampi(color, 0, 5)])
	var node := WorldScreen.mesh(key, CandyMatch3.palette_color(def, color, palette_mode), PIECE_SCALE, 0.35)
	if node == null:
		node = _piece_fallback(CandyMatch3.palette_color(def, color, palette_mode))
	# The board stands upright, so the mesh (Y-up) is laid onto the screen plane.
	node.rotation_degrees = Vector3(-90, 0, 0)
	node.position = Vector3(0, 0, 0.35)
	templates[color] = node
	return node


func _piece_fallback(color: Color) -> Node3D:
	var root := Node3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.4
	mesh.height = 0.8
	mesh.radial_segments = 8
	mesh.rings = 5
	var body := MeshInstance3D.new()
	body.mesh = mesh
	body.material_override = WorldScreen.standard_material(color, 0.4)
	root.add_child(body)
	return root


## One shared material per colour, so the palette switch recolours the board in
## place and every piece stays a single draw call.
func _piece_material(color: int) -> StandardMaterial3D:
	if not piece_materials.has(color):
		var def := CandyMatch3.world_by_id(world_id)
		var tint := CandyMatch3.palette_color(def, color, palette_mode)
		var material := WorldScreen.standard_material(tint, 0.35)
		material.roughness = 0.3
		material.metallic = 0.25
		piece_materials[color] = material
	return piece_materials[color]


func _apply_palette() -> void:
	var def := CandyMatch3.world_by_id(world_id)
	for key in piece_materials:
		var color := int(key)
		var tint := CandyMatch3.palette_color(def, color, palette_mode)
		var material: StandardMaterial3D = piece_materials[key]
		material.albedo_color = tint
		material.emission = tint
		material.emission_energy_multiplier = 0.55 if palette_mode == CandyMatch3.PALETTE_CONTRAST else 0.35
	_palette_button.text = "◐ Weltpalette" if palette_mode == CandyMatch3.PALETTE_CONTRAST else "◑ Kontrast"


func _make_piece(cell: int, drop_from: float) -> void:
	var board: Dictionary = state["board"]
	var color: int = (board["colors"] as PackedInt32Array)[cell]
	if color == CandyMatch3.NO_CANDY:
		return
	var node := _take_node(color)
	var position := _cell_position(cell)
	node.visible = true
	node.scale = Vector3.ONE * PIECE_SCALE * (0.4 if drop_from > 0.0 else 1.0)
	node.position = Vector3(position.x, position.y + drop_from, 0.35)
	piece_root.add_child(node)
	_sync_badges(node, (board["specials"] as PackedInt32Array)[cell])
	pieces[cell] = {
		"node": node,
		"color": color,
		"special": (board["specials"] as PackedInt32Array)[cell],
		"target": Vector3(position.x, position.y, 0.35),
		"scale": PIECE_SCALE * (0.4 if drop_from > 0.0 else 1.0),
		"dying": 0.0,
		"spin": randf() * TAU,
	}


## Striped bar, wrapped cage or bomb core — the badge tells the specials apart.
func _sync_badges(node: Node3D, special: int) -> void:
	for child in node.get_children():
		if child is MeshInstance3D and str(child.get_meta("badge", "")) != "":
			node.remove_child(child)
			child.queue_free()
	if special == CandyMatch3.SPECIAL_NONE:
		return
	var badge := MeshInstance3D.new()
	badge.set_meta("badge", "1")
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color.a = 0.9
	match special:
		CandyMatch3.SPECIAL_ROW, CandyMatch3.SPECIAL_COL:
			var bar := BoxMesh.new()
			bar.size = Vector3(1.05 if special == CandyMatch3.SPECIAL_ROW else 0.22, 0.22, 0.12)
			badge.mesh = bar
			material.albedo_color = Color.WHITE
		CandyMatch3.SPECIAL_WRAPPED:
			var cage := BoxMesh.new()
			cage.size = Vector3(0.86, 0.86, 0.86)
			badge.mesh = cage
			material.albedo_color = Color("fde047")
			material.albedo_color.a = 0.55
		_:
			var core := SphereMesh.new()
			core.radius = 0.22
			core.height = 0.44
			core.radial_segments = 8
			core.rings = 4
			badge.mesh = core
			material.albedo_color = Color("22d3ee")
	badge.material_override = material
	badge.position = Vector3(0, 0, 0.55)
	node.add_child(badge)


func _take_node(color: int) -> Node3D:
	var key := "%s:%d" % [world_id, color]
	var pool: Array = piece_pool.get(key, [])
	if not pool.is_empty():
		return pool.pop_back() as Node3D
	var template := _template(color)
	var clone := template.duplicate() as Node3D
	_tint_shared(clone, _piece_material(color))
	return clone


func _tint_shared(node: Node3D, material: Material) -> void:
	for child in node.get_children():
		if child is GeometryInstance3D:
			(child as GeometryInstance3D).material_override = material
		_tint_shared(child, material)


func _release_node(node: Node3D, color: int) -> void:
	var key := "%s:%d" % [world_id, color]
	var pool: Array = piece_pool.get(key, [])
	if pool.size() < CandyMatch3.CELL_COUNT:
		node.visible = false
		pool.append(node)
	piece_pool[key] = pool


func _drop_piece(cell: int) -> void:
	if not pieces.has(cell):
		return
	var view: Dictionary = pieces[cell]
	var node: Node3D = view["node"]
	piece_root.remove_child(node)
	_release_node(node, int(view["color"]))
	pieces.erase(cell)


func _rebuild_pieces() -> void:
	for cell in pieces.keys():
		_drop_piece(cell)
	var board: Dictionary = state["board"]
	var kind: PackedInt32Array = board["kind"]
	for cell in CandyMatch3.CELL_COUNT:
		if kind[cell] == CandyMatch3.KIND_OPEN:
			_make_piece(cell, 0.0)


func _cell_position(cell: int) -> Vector3:
	return Vector3(
		CandyMatch3.cell_x(CandyMatch3.col_of(cell)) * CELL,
		CandyMatch3.cell_y(CandyMatch3.row_of(cell)) * CELL,
		0.35)


## Applies one resolution step to the visuals. The board is already in its new
## state; the deltas in the step tell us what moved, fell and popped.
func _apply_step(step: Dictionary) -> void:
	var board: Dictionary = state["board"]
	var created_cells := {}
	for entry in (step["created"] as Array):
		created_cells[int((entry as Dictionary)["cell"])] = true

	for cell in (step["cleared"] as PackedInt32Array):
		if not pieces.has(cell):
			continue
		if created_cells.has(cell):
			_drop_piece(cell)
			_make_piece(cell, 0.0)
			if pieces.has(cell):
				(pieces[cell] as Dictionary)["scale"] = PIECE_SCALE * 1.35
			continue
		var view: Dictionary = pieces[cell]
		var color: int = int(view["color"])
		_burst(_cell_position(cell), CandyMatch3.palette_color(CandyMatch3.world_by_id(world_id), color, palette_mode), 6)
		view["dying"] = 1.0

	for cell in (step["blockersHit"] as PackedInt32Array):
		if blockers.has(cell):
			var node: Node3D = blockers[cell]
			node.scale = node.scale * 0.84
	for cell in (step["blockersBroken"] as PackedInt32Array):
		if blockers.has(cell):
			var node: Node3D = blockers[cell]
			blocker_nodes.remove_child(node)
			node.queue_free()
			blockers.erase(cell)

	for move in (step["fell"] as Array):
		var from_cell := int((move as Dictionary)["from"])
		var to_cell := int((move as Dictionary)["to"])
		if not pieces.has(from_cell):
			continue
		var view: Dictionary = pieces[from_cell]
		pieces.erase(from_cell)
		view["target"] = _cell_position(to_cell)
		pieces[to_cell] = view

	var stack := 0
	for cell in (step["spawned"] as PackedInt32Array):
		stack += 1
		_make_piece(cell, float(CandyMatch3.ROWS) + float(stack) * 0.2)
		if pieces.has(cell):
			(pieces[cell] as Dictionary)["target"] = _cell_position(cell)


# --- HUD --------------------------------------------------------------------

func _build_hud() -> void:
	var frame := Ui.rect(Color(0.031, 0.047, 0.086, 0.66), 12, Color(1, 1, 1, 0.1), 1)
	frame.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	frame.offset_left = 12
	frame.offset_top = 66
	frame.offset_right = 300
	frame.offset_bottom = 306
	hud_root.add_child(frame)

	var column := Ui.vbox(4)
	column.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	column.position = Vector2(24, 76)
	column.custom_minimum_size = Vector2(264, 0)
	hud_root.add_child(column)
	_title_label = Ui.label("—", 21, UiTheme.TEXT, true)
	column.add_child(_title_label)
	_world_label = Ui.label("—", 14, UiTheme.TEXT_DIM)
	column.add_child(_world_label)
	var score_row := Ui.hbox(10)
	column.add_child(score_row)
	score_row.add_child(Ui.label("Points", 15, UiTheme.TEXT_DIM))
	score_row.add_child(Ui.spacer(Vector2(0, 0)))
	_score_label = Ui.label("0", 19, Color("facc15"), true)
	score_row.add_child(_score_label)
	var moves_row := Ui.hbox(10)
	column.add_child(moves_row)
	moves_row.add_child(Ui.label("Moves", 15, UiTheme.TEXT_DIM))
	moves_row.add_child(Ui.spacer(Vector2(0, 0)))
	_moves_label = Ui.label("0", 19, UiTheme.TEXT, true)
	moves_row.add_child(_moves_label)
	_goals_box = Ui.vbox(4)
	column.add_child(_goals_box)

	_undo_button = _tool_button("↩ Undo", Vector2(150, 52), 24, _undo)
	_hint_button = _tool_button("💡 Hinweis", Vector2(160, 52), 206, _show_hint)
	_palette_button = _tool_button("◑ Kontrast", Vector2(170, 52), 374, _toggle_palette)
	_tool_button("☰ Level", Vector2(140, 52), 552, _show_level_select)
	_tool_button("🔁 Neustart", Vector2(170, 52), 700, _restart_level)

	_toast_label = Ui.label("", 16, UiTheme.TEXT, true)
	_toast_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_toast_label.offset_bottom = -92
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.visible = false
	hud_root.add_child(_toast_label)

	_build_level_select()


func _tool_button(text: String, size: Vector2, x: float, on_press: Callable) -> Button:
	var button := Ui.button(text, size, UiTheme.PANEL_LIGHT, on_press)
	button.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	button.position = Vector2(x, -64)
	hud_root.add_child(button)
	return button


func _toast(text: String, seconds: float = 1.9) -> void:
	_toast_label.text = text
	_toast_label.visible = true
	_toast_until = clock + seconds


func _refresh() -> void:
	if state.is_empty():
		return
	_score_label.text = Ui.format_number(int(state["score"]))
	_moves_label.text = str(int(state["movesLeft"]))
	_moves_label.add_theme_color_override("font_color", Color("f87171") if int(state["movesLeft"]) <= 5 else UiTheme.TEXT)
	_undo_button.text = "↩ Undo %d" % undo_left
	_undo_button.disabled = undo_left <= 0 or undo_stack.is_empty() or mode == MODE_BUSY
	for child in _goals_box.get_children():
		child.queue_free()
	for entry in CandyMatch3.goal_progress(state):
		var progress: Dictionary = entry
		var goal: Dictionary = progress["goal"]
		var row := Ui.hbox(6)
		_goals_box.add_child(row)
		var text := Ui.label(CandyMatch3.goal_text(goal), 13, Color("86efac") if bool(progress["done"]) else UiTheme.TEXT_DIM)
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(text)
		row.add_child(Ui.label(Loc.f("%d/%d", [int(progress["current"]), int(progress["target"])]), 13, UiTheme.TEXT))
		var bar := Ui.bar(CandyMatch3.palette_color(CandyMatch3.world_by_id(world_id), 0), 6.0)
		Ui.set_bar(bar, float(progress["current"]) / maxf(1.0, float(progress["target"])), Color("86efac") if bool(progress["done"]) else UiTheme.TEXT)
		_goals_box.add_child(bar)


# --- level select -----------------------------------------------------------

func _level_keys() -> Array:
	var keys: Array = []
	for world in CandyMatch3.WORLDS:
		for index in range(1, CandyMatch3.LEVELS_PER_WORLD + 1):
			keys.append(str(CandyMatch3.level_for(str((world as Dictionary)["id"]), index)["number"]))
	keys.append("daily:%s" % Game.today())
	return keys


func _load_star_cache() -> void:
	star_cache = Game.star_map(GAME_ID, _level_keys())


func _daily_days() -> Dictionary:
	var days := {}
	for key in star_cache:
		var text := str(key)
		if text.begins_with("daily:"):
			days[text.substr(6)] = int(star_cache[key])
	return days


func _world_stars(id: String) -> int:
	return CandyMatch3.world_stars(star_cache, id)


func _build_level_select() -> void:
	_select_root = Control.new()
	_select_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_select_root.mouse_filter = Control.MOUSE_FILTER_STOP
	hud_root.add_child(_select_root)
	_select_root.add_child(Ui.backdrop(0.82))

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_select_root.add_child(center)
	var panel := Ui.panel(UiTheme.PANEL, UiTheme.BORDER, 18)
	panel.custom_minimum_size = Vector2(920, 620)
	center.add_child(panel)
	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 18)
	panel.add_child(margin)
	_select_body = Ui.vbox(10)
	margin.add_child(_select_body)


func _show_level_select() -> void:
	if mode == MODE_BUSY:
		return
	mode = MODE_SELECT
	_select_root.visible = true
	_rebuild_level_select()


func _rebuild_level_select(active: String = "") -> void:
	if _select_body == null:
		return
	var world := active
	if world == "":
		# A daily run opens on the world of the day, otherwise on the current one.
		world = str(CandyMatch3.world_by_id(str(CandyMatch3.daily_level(Game.today())["worldId"]))["id"]) \
			if not state.is_empty() and str((state["level"] as Dictionary).get("dailyKey", "")) != "" \
			else (str((state["level"] as Dictionary)["worldId"]) if not state.is_empty() else "candy")
	for child in _select_body.get_children():
		child.queue_free()

	var header := Ui.hbox(10)
	_select_body.add_child(header)
	header.add_child(Ui.label("✦ 240 levels in 6 worlds", 26, UiTheme.TEXT, true))
	header.add_child(Ui.spacer())
	header.add_child(Ui.label(Loc.f("★ %d · best %s", [_total_stars(), Ui.format_number(Game.highscore(Game.HS_CANDY))]), 15, Color("facc15")))
	header.add_child(Ui.button("✕", Vector2(64, 44), UiTheme.PANEL_LIGHT, func() -> void: _select_root.visible = false))

	var daily := CandyMatch3.daily_level(Game.today())
	var daily_row := Ui.hbox(10)
	_select_body.add_child(daily_row)
	var daily_button := Ui.button(
		Loc.f("📅  Daily level %s   —   %s", ["★".repeat(daily_stars) + "☆".repeat(3 - daily_stars),
			"Serie: %d Tage" % streak,]),
		Vector2(0, 52), UiTheme.ACCENT, func() -> void: _start_level(daily))
	daily_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	daily_row.add_child(daily_button)

	var tabs := Ui.hbox(8)
	_select_body.add_child(tabs)
	for entry in CandyMatch3.WORLDS:
		var def: Dictionary = entry
		var id := str(def["id"])
		var stars_here := _world_stars(id)
		var color := UiTheme.ACCENT if id == world else UiTheme.PANEL_LIGHT
		var tab := Ui.button(Loc.f("%s %s  %d★", [str(def["icon"]), str(def["name"]), stars_here]), Vector2(0, 44), color,
			func() -> void: _rebuild_level_select(id))
		tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tabs.add_child(tab)

	var stars_here := _world_stars(world)
	var upcoming := CandyMatch3.next_milestone(stars_here)
	var bonus := CandyMatch3.world_bonus(stars_here)
	var bonus_text: Array = []
	if int((bonus as Dictionary)["moves"]) > 0:
		bonus_text.append("+%d Züge" % int((bonus as Dictionary)["moves"]))
	if int((bonus as Dictionary)["undos"]) > 0:
		bonus_text.append("+%d Undo" % int((bonus as Dictionary)["undos"]))
	if bool((bonus as Dictionary)["bomb"]):
		bonus_text.append("Start-Farbbombe")
	var milestone_text := "Alle Belohnungen freigeschaltet"
	if not upcoming.is_empty():
		milestone_text = "Noch %d bis: %s" % [int((upcoming as Dictionary)["stars"]) - stars_here, str((upcoming as Dictionary)["label"])]
	var track := Ui.hbox(4)
	for milestone in CandyMatch3.WORLD_MILESTONES:
		var reached: bool = stars_here >= int((milestone as Dictionary)["stars"])
		var pip := Ui.rect(Color("22c55e") if reached else Color(0.118, 0.161, 0.231), 4, UiTheme.BORDER, 1)
		pip.custom_minimum_size = Vector2(26, 8)
		track.add_child(pip)
	var milestone_row := Ui.hbox(10)
	milestone_row.add_child(Ui.label(Loc.f("★ %d  %s", [stars_here, milestone_text]), 14, UiTheme.TEXT_DIM))
	milestone_row.add_child(Ui.spacer())
	if not bonus_text.is_empty():
		milestone_row.add_child(Ui.label(Loc.f("Active: %s", [", ".join(PackedStringArray(bonus_text))]), 14, Color("86efac")))
	milestone_row.add_child(track)
	_select_body.add_child(milestone_row)

	var grid := GridContainer.new()
	grid.columns = 8
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.add_child(grid)
	_select_body.add_child(scroll)

	for index in range(1, CandyMatch3.LEVELS_PER_WORLD + 1):
		var level := CandyMatch3.level_for(world, index)
		var key := str(level["number"])
		var stars_level: int = int(star_cache.get(key, 0))
		var open: bool = index == 1 or int(star_cache.get(str(CandyMatch3.level_for(world, index - 1)["number"]), 0)) > 0
		var label := "%d\n%s" % [index, "★".repeat(stars_level) + "☆".repeat(3 - stars_level)]
		if not open:
			label = "%d\n🔒" % index
		var cell := Ui.button(label, Vector2(96, 62),
			UiTheme.PANEL_LIGHT if not open else (Color("14532d") if stars_level > 0 else UiTheme.PANEL),
			func() -> void: _start_level(level))
		cell.disabled = not open
		cell.add_theme_font_size_override("font_size", 13)
		grid.add_child(cell)


func _total_stars() -> int:
	var total := 0
	for value in star_cache.values():
		total += int(value)
	return total


func _start_level(level: Dictionary) -> void:
	_select_root.visible = false
	_apply_level(level)


func _restart_level() -> void:
	if state.is_empty() or mode == MODE_BUSY:
		return
	_apply_level(state["level"])


# --- input ------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if _select_root.visible:
		return
	if event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed:
		_pointer_down((event as InputEventScreenTouch).position)
		return
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_pointer_down((event as InputEventMouseButton).position)
		return
	if event is InputEventScreenDrag:
		_pointer_move((event as InputEventScreenDrag).position)
		return
	if event is InputEventMouseMotion and _drag_from >= 0:
		_pointer_move((event as InputEventMouseMotion).position)
		return
	if event is InputEventKey and event.is_pressed():
		_key(event as InputEventKey)


func _key(key: InputEventKey) -> void:
	if key.is_action_pressed("undo"):
		_undo()
		return
	if key.is_action_pressed("restart"):
		_restart_level()
		return
	if key.is_action_pressed("cancel"):
		_show_level_select()
		return
	if selected < 0:
		return
	var col := CandyMatch3.col_of(selected)
	var row := CandyMatch3.row_of(selected)
	var step := Vector2i.ZERO
	if key.is_action_pressed("move_left"):
		step = Vector2i(-1, 0)
	elif key.is_action_pressed("move_right"):
		step = Vector2i(1, 0)
	elif key.is_action_pressed("move_up"):
		step = Vector2i(0, 1)
	elif key.is_action_pressed("move_down"):
		step = Vector2i(0, -1)
	if step == Vector2i.ZERO:
		return
	var target := CandyMatch3.cell_index(col + step.x, row + step.y)
	if target < 0 or target >= CandyMatch3.CELL_COUNT:
		return
	var from := selected
	selected = -1
	ring.visible = false
	_try_swap(from, target)


## Screen-space picking: one ray against the board plane, then a rounding to the
## nearest cell. No physics bodies, no allocations per tap.
func _cell_at(screen_position: Vector2) -> int:
	var from := camera.project_ray_origin(screen_position)
	var dir := camera.project_ray_normal(screen_position)
	var hit = Plane(Vector3(0, 0, 1), 0.0).intersects_ray(from, dir)
	if hit == null:
		return -1
	var point: Vector3 = hit
	var col := int(roundf(point.x / CELL + float(CandyMatch3.COLS - 1) * 0.5))
	var row := int(roundf(-point.y / CELL + float(CandyMatch3.ROWS - 1) * 0.5))
	if col < 0 or col >= CandyMatch3.COLS or row < 0 or row >= CandyMatch3.ROWS:
		return -1
	var cell := CandyMatch3.cell_index(col, row)
	if (state["board"] as Dictionary)["kind"][cell] != CandyMatch3.KIND_OPEN:
		return -1
	return cell


func _pointer_down(screen_position: Vector2) -> void:
	if mode != MODE_SELECT or state.is_empty():
		return
	var cell := _cell_at(screen_position)
	_drag_from = cell
	_drag_start = screen_position
	if cell < 0:
		selected = -1
		ring.visible = false
		_clear_combo()
		return
	Sfx.select()
	if selected >= 0 and selected != cell:
		if CandyMatch3.are_neighbours(selected, cell):
			var from := selected
			selected = -1
			ring.visible = false
			_clear_combo()
			_try_swap(from, cell)
			_drag_from = -1
			return
	selected = cell
	ring.position = _cell_position(cell)
	ring.visible = true
	_show_combo_partners(cell)


## Marks what the selected candy would blow up if it met a special neighbour, so
## the combination table can be read off the board instead of guessed. Only a
## tap builds this; the frame loop just asks the set. A candy with more than one
## partner announces the biggest of them.
func _show_combo_partners(cell: int) -> void:
	_clear_combo()
	var board: Dictionary = state["board"]
	var specials: Array = board["specials"]
	if specials[cell] == CandyMatch3.SPECIAL_NONE:
		return
	var col := CandyMatch3.col_of(cell)
	var row := CandyMatch3.row_of(cell)
	var biggest := 0
	for step: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var c: int = col + step.x
		var r: int = row + step.y
		if c < 0 or c >= CandyMatch3.COLS or r < 0 or r >= CandyMatch3.ROWS:
			continue
		var other := CandyMatch3.cell_index(c, r)
		if not CandyMatch3.has_candy(board, other) or specials[other] == CandyMatch3.SPECIAL_NONE:
			continue
		var blast := CandyMatch3.combo_blast(board, cell, other)
		if blast.is_empty():
			continue
		for target in blast:
			combo_set[target] = true
		if blast.size() > biggest:
			biggest = blast.size()
			combo_label = CandyMatch3.combo_name(CandyMatch3.combo_kind(specials[cell], specials[other]))
	if biggest == 0:
		return
	_toast("Kombination möglich: %s" % combo_label)


func _clear_combo() -> void:
	combo_set.clear()
	combo_label = ""


func _pointer_move(screen_position: Vector2) -> void:
	if _drag_from < 0 or mode != MODE_SELECT:
		return
	var delta := screen_position - _drag_start
	if absf(delta.x) < DRAG_THRESHOLD and absf(delta.y) < DRAG_THRESHOLD:
		return
	var col := CandyMatch3.col_of(_drag_from)
	var row := CandyMatch3.row_of(_drag_from)
	if absf(delta.x) > absf(delta.y):
		_try_swap(_drag_from, CandyMatch3.cell_index(col + (1 if delta.x > 0.0 else -1), row))
	else:
		_try_swap(_drag_from, CandyMatch3.cell_index(col, row + (-1 if delta.y > 0.0 else 1)))
	_drag_from = -1


# --- moves ------------------------------------------------------------------

func _try_swap(a: int, b: int) -> void:
	if state.is_empty() or mode != MODE_SELECT or not swap_back.is_empty() or a == b:
		return
	if not pieces.has(a) or not pieces.has(b):
		return
	var board: Dictionary = state["board"]
	var level: Dictionary = state["level"]
	var outcome := CandyMatch3.try_swap(board, a, b, state["rng"], int(level["colors"]))
	var view_a: Dictionary = pieces[a]
	var view_b: Dictionary = pieces[b]
	var position_a := _cell_position(a)
	var position_b := _cell_position(b)
	selected = -1
	ring.visible = false
	hint_cells = PackedInt32Array()
	_clear_combo()

	if outcome.is_empty():
		# Illegal swap: the pieces bounce and come back.
		view_a["target"] = Vector3(position_b.x, position_b.y, 0.35)
		view_b["target"] = Vector3(position_a.x, position_a.y, 0.35)
		Sfx.hurt()
		swap_back = {"a": a, "b": b}
		step_timer = clock + SWAP_TIME
		return

	undo_stack.append(CandyMatch3.snapshot_state(state))
	if undo_stack.size() > UNDO_BASE + int((state["bonus"] as Dictionary)["undos"]):
		undo_stack.pop_front()

	pieces.erase(a)
	pieces.erase(b)
	view_a["target"] = Vector3(position_b.x, position_b.y, 0.35)
	view_b["target"] = Vector3(position_a.x, position_a.y, 0.35)
	pieces[b] = view_a
	pieces[a] = view_b
	Sfx.hit()
	state["movesLeft"] = int(state["movesLeft"]) - 1
	var combo := int(outcome["combo"])
	steps = CandyMatch3.continue_cascades(state, outcome["step"], combo)
	if combo != CandyMatch3.COMBO_NONE:
		_toast("%s!" % CandyMatch3.combo_name(combo), 2.4)
	step_timer = clock + SWAP_TIME
	mode = MODE_BUSY


func _undo() -> void:
	if state.is_empty() or mode == MODE_BUSY or not swap_back.is_empty() or undo_left <= 0:
		return
	if undo_stack.is_empty():
		return
	var snapshot: Dictionary = undo_stack.pop_back()
	undo_left -= 1
	CandyMatch3.restore_state(state, snapshot)
	_build_blockers()
	_rebuild_pieces()
	selected = -1
	ring.visible = false
	hint_cells = PackedInt32Array()
	_clear_combo()
	mode = MODE_SELECT
	Sfx.select()
	_toast("Zug zurückgenommen")
	_refresh()


func _show_hint() -> void:
	if state.is_empty() or mode != MODE_SELECT:
		return
	var swaps := CandyMatch3.find_valid_swaps(state["board"], 1)
	if swaps.is_empty():
		_toast("Kein Zug möglich — das Brett wird gemischt.")
		return
	_clear_combo()
	var swap: Dictionary = swaps[0]
	hint_cells = PackedInt32Array([int((swap as Dictionary)["a"]), int((swap as Dictionary)["b"])])
	hint_until = clock + 2.6
	_toast("Tipp: die leuchtenden Bonbons tauschen")


func _toggle_palette() -> void:
	palette_mode = CandyMatch3.PALETTE_CLASSIC if palette_mode == CandyMatch3.PALETTE_CONTRAST else CandyMatch3.PALETTE_CONTRAST
	Game.set_number("candy_palette", 1.0 if palette_mode == CandyMatch3.PALETTE_CONTRAST else 0.0)
	_apply_palette()
	_toast("Kontrastpalette aktiv" if palette_mode == CandyMatch3.PALETTE_CONTRAST else "Weltpalette aktiv")


## The end of the run, won or lost: the result screen names the peaks of the
## level and what is still missing for the next star.
func _win() -> void:
	mode = MODE_WON
	_show_result(true)


func _lose() -> void:
	mode = MODE_LOST
	_show_result(false)


func _finish_move() -> void:
	_clear_combo()
	_refresh()
	if CandyMatch3.is_won(state):
		_win()
		return
	if int(state["movesLeft"]) <= 0:
		_lose()
		return
	if not CandyMatch3.has_valid_swap(state["board"]):
		if CandyMatch3.shuffle_board(state["board"], state["rng"], int((state["level"] as Dictionary)["colors"])):
			_rebuild_pieces()
			_toast("Kein Zug mehr — das Brett wird gemischt.")
	mode = MODE_SELECT


## Stores the result, updates the star cache and returns the stars plus any
## milestone that this result just unlocked.
func _record_result() -> Dictionary:
	var level: Dictionary = state["level"]
	var stars := CandyMatch3.stars_for(state)
	var daily_key := str(level.get("dailyKey", ""))
	var key := "daily:%s" % daily_key if daily_key != "" else str(level["number"])
	var world := str((state["world"] as Dictionary)["id"])
	var before := _world_stars(world)
	if Game.submit_stars(GAME_ID, key, stars):
		star_cache[key] = maxi(int(star_cache.get(key, 0)), stars)
	Game.submit_score(Game.HS_CANDY, int(state["score"]))
	var after := _world_stars(world)
	var unlocked: Array = []
	for milestone in CandyMatch3.WORLD_MILESTONES:
		if after >= int((milestone as Dictionary)["stars"]) and before < int((milestone as Dictionary)["stars"]):
			unlocked.append(str((milestone as Dictionary)["label"]))
	if daily_key != "":
		daily_stars = maxi(daily_stars, stars)
		streak = CandyMatch3.daily_streak(_daily_days(), Game.today())
	return {"stars": stars, "unlocked": unlocked}


func _show_result(won: bool) -> void:
	var level: Dictionary = state["level"]
	var recorded := _record_result()
	var stars := int((recorded as Dictionary)["stars"])
	var unlocked: Array = (recorded as Dictionary)["unlocked"]
	if won:
		Sfx.level_up()
		if not unlocked.is_empty():
			_toast("Belohnung freigeschaltet: %s" % ", ".join(PackedStringArray(unlocked)), 3.4)
	else:
		Sfx.game_over()
	var layer := Control.new()
	layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.mouse_filter = Control.MOUSE_FILTER_STOP
	hud_root.add_child(layer)
	layer.add_child(Ui.backdrop(0.8))
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(center)
	var column := Ui.vbox(10)
	center.add_child(column)
	var daily_key := str(level.get("dailyKey", ""))
	column.add_child(Ui.title("Daily level done!" if daily_key != "" and won else ("Level geschafft!" if won else "Keine Züge mehr"), 40,
		Color("facc15") if won else Color("f87171")))
	if won:
		column.add_child(Ui.label("★".repeat(stars) + "☆".repeat(3 - stars), 32, Color("facc15")))
	column.add_child(Ui.label(str(level["title"]), 20, UiTheme.TEXT))
	column.add_child(Ui.label(Loc.f("Points: %s", [Ui.format_number(int(state["score"]))]), 20, UiTheme.TEXT))
	column.add_child(Ui.label(Loc.f("Moves: %d", [(int(level["moves"]) - int(state["movesLeft"]))]), 16, UiTheme.TEXT_DIM))
	# What the level actually felt like: the peaks of the run and what is still
	# missing for the next star. Two stars without a reason is a dead end.
	_build_moments(column)
	if not unlocked.is_empty():
		column.add_child(Ui.label(Loc.f("Reward: %s", [", ".join(PackedStringArray(unlocked))]), 16, Color("86efac")))
	var next_level := CandyMatch3.level_for(str(level["worldId"]), int(level["index"]) + 1)
	var has_next: bool = daily_key == "" and int(level["index"]) < CandyMatch3.LEVELS_PER_WORLD
	if has_next:
		column.add_child(Ui.button("▶ Next level", Vector2(340, 56), UiTheme.ACCENT,
			func() -> void: _dismiss(layer, func() -> void: _start_level(next_level))))
	column.add_child(Ui.button("🔁 Again", Vector2(340, 56), UiTheme.PANEL_LIGHT,
		func() -> void: _dismiss(layer, func() -> void: _start_level(level))))
	column.add_child(Ui.button("☰ Level select", Vector2(340, 56), UiTheme.PANEL_LIGHT,
		func() -> void: _dismiss(layer, _show_level_select)))


func _dismiss(layer: Control, then: Callable) -> void:
	if is_instance_valid(layer):
		layer.queue_free()
	if then.is_valid():
		then.call()


## The run summary below the score: one row per peak and the gap to the next
## star. Only built once per result, so the allocations do not touch the loop.
func _build_moments(column: VBoxContainer) -> void:
	var moments := CandyMatch3.run_moments(state)
	var gap := CandyMatch3.star_gap(state)
	if moments.is_empty() and gap.is_empty():
		return
	var box := Ui.vbox(4)
	column.add_child(box)
	for entry in moments:
		var moment: Dictionary = entry
		var row := Ui.hbox(8)
		box.add_child(row)
		row.add_child(Ui.label(str(moment["icon"]), 15, Color("facc15")))
		var name_label := Ui.label(str(moment["label"]), 15, UiTheme.TEXT_DIM)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_label)
		var value := "%s %s" % [Ui.format_number(int(moment["value"])), str(moment["unit"])]
		if int(moment.get("move", 0)) > 0:
			value += "  ·  Zug %d" % int(moment["move"])
		row.add_child(Ui.label(value, 15, UiTheme.TEXT))
	if gap.is_empty():
		box.add_child(Ui.label("★ All three stars", 16, Color("86efac")))
	else:
		box.add_child(Ui.label(Loc.f("%s points to %s", [Ui.format_number(int((gap as Dictionary)["missing"])),
			CandyMatch3.star_ordinal(int((gap as Dictionary)["stars"]))]), 16, Color("facc15")))


# --- loop -------------------------------------------------------------------

func _update_world(delta: float) -> void:
	clock += delta
	var dt: float = minf(delta, 0.05)
	var now := clock

	if not swap_back.is_empty() and now >= step_timer:
		var a: int = int((swap_back as Dictionary)["a"])
		var b: int = int((swap_back as Dictionary)["b"])
		if pieces.has(a):
			(pieces[a] as Dictionary)["target"] = _cell_position(a)
		if pieces.has(b):
			(pieces[b] as Dictionary)["target"] = _cell_position(b)
		swap_back = {}

	if mode == MODE_BUSY and not steps.is_empty() and now >= step_timer:
		var step: Dictionary = steps.pop_front()
		_apply_step(step)
		var cleared: PackedInt32Array = step["cleared"]
		if not cleared.is_empty():
			Sfx.kill() if cleared.size() > 4 else Sfx.coin()
		if not (step["created"] as Array).is_empty():
			Sfx.merge()
		step_timer = now + STEP_TIME + minf(0.16, float(cleared.size()) * 0.012)
		if steps.is_empty():
			_finish_move()

	var hinting: bool = hint_until > now
	var base := Basis(Vector3.RIGHT, -PI * 0.5)
	for cell in pieces.keys():
		var view: Dictionary = pieces[cell]
		var node: Node3D = view["node"]
		var target: Vector3 = view["target"]
		var position: Vector3 = node.position
		var ease: float = minf(1.0, dt * 14.0)
		position = position.lerp(target, ease)
		var is_selected: bool = int(cell) == selected
		var is_hint: bool = hinting and hint_cells.has(int(cell))
		var is_combo: bool = combo_set.has(cell)
		var wanted: float = PIECE_SCALE * (SELECTED_SCALE if is_selected else
			(HINT_SCALE if is_hint else (COMBO_SCALE if is_combo else 1.0)))
		var current: float = lerpf(float(view["scale"]), wanted, minf(1.0, dt * 12.0))
		var dying: float = float(view["dying"])
		if dying > 0.0:
			dying -= dt * 5.5
			view["dying"] = dying
			current = maxf(0.0, current - dt * 2.6)
			position.y += dt * 1.6
			if dying <= 0.0:
				_drop_piece(int(cell))
				continue
		view["scale"] = current
		view["spin"] = float(view["spin"]) + dt * (1.6 if (is_selected or is_hint) else 0.3)
		# Basis: lay the Y-up mesh onto the board plane, then spin in that plane.
		var basis := Basis(Vector3(0, 0, 1), float(view["spin"])) * base
		node.transform = Transform3D(basis.scaled(Vector3.ONE * maxf(0.001, current)), position)

	for cell in blockers:
		var node: MeshInstance3D = blockers[cell]
		node.rotation.z += dt * 0.4
		var layers: int = (state["board"] as Dictionary)["layers"][cell]
		var wanted: float = 1.0 if layers >= 2 else 0.84
		var scale_value: float = lerpf(node.scale.x, wanted, minf(1.0, dt * 8.0))
		node.scale = Vector3.ONE * scale_value
		var position := _cell_position(cell)
		node.position = Vector3(position.x, position.y + (scale_value - 1.0) * 0.3, 0.1)

	if hinting == false and not hint_cells.is_empty():
		hint_cells = PackedInt32Array()
	if _toast_until > 0.0 and now > _toast_until:
		_toast_until = 0.0
		_toast_label.visible = false
	if ring.visible:
		ring.scale = Vector3.ONE * (1.0 + sin(now * 6.0) * 0.08)
		ring.rotation.z += dt * 1.2

	for i in particle_life.size():
		if particle_life[i] <= 0.0:
			continue
		particle_life[i] -= dt
		if particle_life[i] <= 0.0:
			particle_data[i * 3 + 1] = 999.0
			continue
		particle_velocity[i * 3 + 1] -= dt * 7.0
		particle_data[i * 3] += particle_velocity[i * 3] * dt
		particle_data[i * 3 + 1] += particle_velocity[i * 3 + 1] * dt
		particle_data[i * 3 + 2] += particle_velocity[i * 3 + 2] * dt
	_write_particles()
