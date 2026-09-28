class_name SiedlerScreen
extends WorldScreen
## Siedler 3D — a settlement builder after *Die Siedler* (Blue Byte, Amiga 1993).
## Rules live in `Siedler` (`core/logic/siedler.gd`); this file only draws them.
## The 1993 original hid *why* a building stalled — here every one says so.
## One `ArrayMesh` for the terrain, one `MultiMesh` for all carriers, no allocations
## in `_update_world`; buildings, flags and serfs come from pools.

const GROUND_Y := 0.0
const ROAD_Y := 0.09
const TILE := 1.0
## At most this many carriers are drawn.
const MAX_CARRIERS := 420
## This many serfs are drawn.
const MAX_SERFS := 48
## How far a building label floats above its building.
const LABEL_HEIGHT := 2.1

enum Tool { SELECT, ROAD, FLAG }

var siedler := Siedler.new()
var tool: int = Tool.SELECT
## The armed building from the build arc, "" if none.
var armed_kind: String = ""
## Start cell of a road planning, -1 if none is running.
var road_from: int = -1
var selected_building: int = -1
var hover_cell: int = -1
var speed_index: int = 1

# --- world nodes ------------------------------------------------------------
var _world_root: Node3D
var _terrain: MeshInstance3D
var _road_mesh: MeshInstance3D
var _territory: MultiMeshInstance3D
var _prop_root: Node3D
var _ghost: MeshInstance3D
var _preview: MeshInstance3D
var _carriers: MultiMeshInstance3D

var _prop_meshes: Dictionary = {}
var _territory_capacity := 0
var _building_nodes: Dictionary = {}
var _building_labels: Dictionary = {}
var _flag_nodes: Dictionary = {}
var _serf_nodes: Array[Node3D] = []

# --- hud --------------------------------------------------------------------
var _stats_label: Label
var _inspector: PanelContainer
var _inspector_body: VBoxContainer
var _tool_buttons: Dictionary = {}
var _modal_layer: Control
## The advisor card at the bottom centre: the one reason the settlement is stuck
## right now, plus the button that fixes it.
var _advisor: PanelContainer
var _advisor_body: VBoxContainer
## Key of the last built advisor, so the card is not rebuilt five times a second.
var _advisor_key := ""
## The advice currently shown on the card.
var _advisor_top: Dictionary = {}
## Cell the advisor currently points at, -1 if none.
var _advisor_cell := -1
## The "Trade routes" card: which road carries which good. A dialog and not a
## permanent panel, because it changes every second and nobody reads a list
## that keeps jumping.
var _routes_body: VBoxContainer = null
## What the last optimizer pass did, line by line.
var _routes_notes: Array[String] = []
## How many routes the card shows. More would push the list out of view, and the
## longest routes are on top anyway.
const ROUTE_ROWS := 6

# --- rebuild flags ----------------------------------------------------------
var _roads_dirty := true
var _terrain_dirty := true
var _slow_timer := 0.0
var _hud_timer := 0.0
## Screen runtime, so the advisor's square can pulse.
var _clock := 0.0
var _notice_shown := ""
var _end_shown := false
var _frame_delta := 0.0

# --- camera -----------------------------------------------------------------
var cam_focus := Vector3.ZERO
var cam_goal := Vector3.ZERO
var cam_distance := 56.0
var cam_goal_distance := 56.0
var cam_yaw := 0.72
const CAM_MIN_DISTANCE := 20.0
const CAM_MAX_DISTANCE := 100.0
const CAM_PITCH := 0.9
const CAM_YAW_STEP := 0.22
const CAM_LIMIT := 26.0
const TAP_SLOP := 22.0
const PAN_SPEED := 0.05

# --- touch ------------------------------------------------------------------
var _pointers: Dictionary = {}
var _pointer_start: Dictionary = {}
var _dragged := false
var _gesture := false
var _gesture_span := 1.0
var _gesture_angle := 0.0
var _gesture_mid := Vector2.ZERO

const SPEEDS: Array[float] = [0.0, 1.0, 3.0, 8.0]
const SPEED_NAMES: Array[String] = ["||", "1x", "3x", "8x"]


# --- setup ------------------------------------------------------------------

func _ready_world() -> void:
	siedler.setup(0, 46)
	_build_world()
	_build_panels()
	_set_tool(Tool.SELECT)
	_rebuild_props()
	hide_loading()


func _build_world() -> void:
	set_fog(Color("a8cbe8"), 0.0032)
	set_ambient(Color("c4dcf5"), 0.95)
	sun.light_energy = 1.2
	sun.rotation_degrees = Vector3(-58, 34, 0)
	camera.fov = 50.0

	_world_root = Node3D.new()
	_world_root.name = "SiedlerWorld"
	add_child(_world_root)

	_prop_root = Node3D.new()
	_prop_root.name = "Deposits"
	_world_root.add_child(_prop_root)

	_territory = _make_overlay("Territory", Color("38bdf8"), 0.3, 0.94)
	_territory_capacity = siedler.cells.size()
	_rebuild_territory()

	_terrain = MeshInstance3D.new()
	_terrain.name = "Terrain"
	_terrain.material_override = _terrain_material()
	_world_root.add_child(_terrain)
	_build_terrain()
	_terrain_dirty = false

	_road_mesh = MeshInstance3D.new()
	_road_mesh.name = "Roads"
	_road_mesh.material_override = _flat_material(Color("8a6a44"), 1.0)
	_world_root.add_child(_road_mesh)
	_build_roads()
	_roads_dirty = false

	_carriers = MultiMeshInstance3D.new()
	_carriers.name = "Carriers"
	var carriers := MultiMesh.new()
	carriers.transform_format = MultiMesh.TRANSFORM_3D
	carriers.use_colors = true
	carriers.mesh = _carrier_mesh()
	carriers.instance_count = MAX_CARRIERS
	carriers.visible_instance_count = 0
	_carriers.multimesh = carriers
	_world_root.add_child(_carriers)

	_ghost = MeshInstance3D.new()
	_ghost.name = "Ghost"
	_ghost.mesh = _box_mesh(Vector3(0.9, 0.06, 0.9))
	_ghost.material_override = _flat_material(Color("4ade80"), 0.45)
	_ghost.visible = false
	_world_root.add_child(_ghost)

	_preview = MeshInstance3D.new()
	_preview.name = "RoadPreview"
	_preview.mesh = _box_mesh(Vector3(1, 0.1, 0.1))
	_preview.material_override = _flat_material(Color("fbbf24"), 0.9)
	_preview.visible = false
	_world_root.add_child(_preview)

	_apply_camera()


# --- hud --------------------------------------------------------------------

func _build_panels() -> void:
	var stats_panel := Ui.rect(Color(0.031, 0.047, 0.086, 0.74), 10, Color(1, 1, 1, 0.1), 1)
	stats_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	stats_panel.offset_left = 12
	stats_panel.offset_top = 66
	stats_panel.offset_right = 274
	stats_panel.offset_bottom = 196
	hud_root.add_child(stats_panel)

	_stats_label = Ui.label("", 13, UiTheme.TEXT)
	_stats_label.position = Vector2(22, 74)
	_stats_label.custom_minimum_size = Vector2(246, 0)
	hud_root.add_child(_stats_label)

	var speed_row := Ui.hbox(4)
	speed_row.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	speed_row.position = Vector2(-200, 66)
	hud_root.add_child(speed_row)
	for i in SPEEDS.size():
		var index := i
		var button := Ui.button(SPEED_NAMES[i], Vector2(46, 34), UiTheme.PANEL_LIGHT, func() -> void:
			_set_speed(index)
		)
		speed_row.add_child(button)
		_tool_buttons["speed%d" % i] = button
	_set_speed(1)

	var tool_row := Ui.hbox(6)
	tool_row.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	tool_row.position = Vector2(14, -62)
	hud_root.add_child(tool_row)
	var entries := [
		[Tool.SELECT, "◎", "Select and inspect"],
		[Tool.ROAD, "⇢", "Build a road: tap the start tile, then the target"],
		[Tool.FLAG, "⚑", "Extra banner beside a road: more carriers, more throughput"],
	]
	for entry in entries:
		var mode: int = entry[0]
		var button := Ui.button(str(entry[1]), Vector2(52, 52), UiTheme.PANEL_LIGHT, func() -> void:
			_set_tool(mode)
		)
		button.tooltip_text = str(entry[2])
		tool_row.add_child(button)
		_tool_buttons[mode] = button
	tool_row.add_child(Ui.button("⌂ Build", Vector2(78, 52), UiTheme.ACCENT, func() -> void:
		_open_build_sheet()
	))

	_inspector = Ui.panel(Color(0.031, 0.047, 0.086, 0.92), UiTheme.BORDER, 12)
	_inspector.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_inspector.position = Vector2(-308, 112)
	_inspector.custom_minimum_size = Vector2(296, 0)
	_inspector.visible = false
	hud_root.add_child(_inspector)
	_inspector_body = Ui.vbox(4)
	_inspector_body.custom_minimum_size = Vector2(278, 0)
	_inspector.add_child(_inspector_body)

	var help_row := Ui.hbox(6)
	help_row.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	help_row.position = Vector2(-248, -58)
	hud_root.add_child(help_row)
	# The routes button belongs next to the help, not in the tool bar: three
	# tools and the build arc are already there, and a fifth button would eat
	# half the width on a phone.
	help_row.add_child(Ui.button("⇄ Routes", Vector2(96, 48), UiTheme.PANEL_LIGHT, func() -> void:
		_open_routes_sheet()
	))
	help_row.add_child(Ui.button("? Help", Vector2(78, 48), UiTheme.PANEL_LIGHT, func() -> void:
		_show_help()
	))
	help_row.add_child(Ui.button("✕", Vector2(48, 48), UiTheme.PANEL_LIGHT, func() -> void:
		selected_building = -1
	))

	# The advisor card sits bottom centre, where nothing else is, and names *one*
	# reason; the button opens the full list.
	# Fixed anchors instead of `set_anchors_and_offsets_preset`: the card has to
	# stay centred when the difficulty setting makes it grow.
	_advisor = Ui.panel(Color(0.031, 0.047, 0.086, 0.9), UiTheme.BORDER, 12)
	_advisor.anchor_left = 0.5
	_advisor.anchor_right = 0.5
	_advisor.anchor_top = 1.0
	_advisor.anchor_bottom = 1.0
	_advisor.offset_left = -286.0
	_advisor.offset_right = 286.0
	_advisor.offset_top = -150.0
	_advisor.offset_bottom = -14.0
	_advisor.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_advisor.visible = false
	hud_root.add_child(_advisor)
	_advisor_body = Ui.vbox(3)
	_advisor_body.custom_minimum_size = Vector2(544, 0)
	_advisor.add_child(_advisor_body)


# --- build sheet ------------------------------------------------------------

## The build sheet lists every production building grouped the way the economy
## teaches it: material, food, raw materials, crafts, administration.
func _open_build_sheet() -> void:
	var root := _modal_root()
	root.add_child(Ui.backdrop(0.86))
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var panel := Ui.panel(Color(0.043, 0.063, 0.11, 0.98), UiTheme.ACCENT, 14)
	panel.custom_minimum_size = Vector2(580, 600)
	center.add_child(panel)
	var column := Ui.vbox(8)
	panel.add_child(column)
	column.add_child(Ui.title("Build buildings", 26, UiTheme.ACCENT))

	var groups := [
		[Loc.t("siedler.group_material"), ["woodcutter", "forester", "sawmill", "quarry"]],
		[Loc.t("siedler.group_food"), ["farm", "pigFarm", "windmill", "butcher", "bakery", "fishery"]],
		[Loc.t("siedler.group_raw"), ["coalMine", "ironMine", "goldMine", "smelter"]],
		[Loc.t("siedler.group_craft"), ["toolsmith", "goldsmith", "blacksmith"]],
		[Loc.t("siedler.group_admin"), ["warehouse", "watchtower"]],
	]
	for group in groups:
		column.add_child(Ui.label(str(group[0]), 14, UiTheme.TEXT_DIM))
		var grid := GridContainer.new()
		grid.columns = 3
		grid.add_theme_constant_override("h_separation", 6)
		grid.add_theme_constant_override("v_separation", 6)
		column.add_child(grid)
		for kind in group[1]:
			grid.add_child(_palette_button(str(kind)))
	column.add_child(Ui.label(
		"Hint: toolshop first, then mines — without iron there are no tools.",
		13, UiTheme.WARNING
	))
	var close_row := CenterContainer.new()
	close_row.add_child(Ui.button("Close", Vector2(170, 46), UiTheme.PANEL_LIGHT, func() -> void:
		_close_modal()
	))
	column.add_child(close_row)


func _palette_button(kind: String) -> Button:
	var spec := Siedler.spec_of(kind)
	var cost: Dictionary = spec["cost"]
	var button := Ui.button(
		Loc.f("%s %s\nPlanks %d · Stone %d", [spec["icon"], spec["name"], int(cost["planks"]), int(cost["stone"])]),
		Vector2(182, 58), UiTheme.PANEL_LIGHT, func() -> void:
			armed_kind = kind
			_set_tool(Tool.SELECT)
			_close_modal()
			Sfx.select()
			notify(Loc.f("%s is being built — tap a tile", [str(spec["name"])]))
	)
	button.add_theme_font_size_override("font_size", 12)
	button.tooltip_text = str(spec["desc"])
	return button


# --- input ------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if _modal_layer != null and is_instance_valid(_modal_layer):
		return
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			_pointer_down(touch.index, touch.position)
		else:
			_pointer_up(touch.index)
		return
	if event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		_pointer_move(drag.index, drag.position)
		return
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_LEFT:
			if button.pressed:
				_pointer_down(0, button.position)
			else:
				_pointer_up(0)
			return
		if button.button_index == MOUSE_BUTTON_WHEEL_UP and button.pressed:
			_zoom(0.9)
			return
		if button.button_index == MOUSE_BUTTON_WHEEL_DOWN and button.pressed:
			_zoom(1.1)
			return
		return
	if event is InputEventMouseMotion:
		_hover_at((event as InputEventMouseMotion).position)
		if _pointers.has(0):
			_pointer_move(0, (event as InputEventMouseMotion).position)
		return
	if event is InputEventKey and event.is_pressed():
		_key(event as InputEventKey)


func _key(key: InputEventKey) -> void:
	match key.keycode:
		KEY_1:
			_set_tool(Tool.SELECT)
		KEY_2:
			_set_tool(Tool.ROAD)
		KEY_3:
			_set_tool(Tool.FLAG)
		KEY_SPACE:
			_set_speed((speed_index + 1) % SPEEDS.size())
		KEY_W:
			_open_routes_sheet()
		KEY_ESCAPE:
			if tool != Tool.SELECT or armed_kind != "":
				_set_tool(Tool.SELECT)
			else:
				selected_building = -1
		KEY_F:
			_zoom(0.8)
		KEY_Q:
			cam_yaw -= CAM_YAW_STEP
		KEY_E:
			cam_yaw += CAM_YAW_STEP


func _pointer_down(index: int, position: Vector2) -> void:
	_pointers[index] = position
	_pointer_start[index] = position
	if _pointers.size() >= 2:
		_begin_gesture()
	else:
		_gesture = false
		_dragged = false


func _pointer_move(index: int, position: Vector2) -> void:
	if not _pointers.has(index):
		return
	var previous: Vector2 = _pointers[index]
	_pointers[index] = position
	_pointer_start[index] = position
	if _pointer_start[index].distance_to(position) > TAP_SLOP:
		_dragged = true
	if _pointers.size() >= 2:
		_update_gesture()
	elif _dragged:
		_pan_by((previous - position) * PAN_SPEED * (cam_distance / CAM_MIN_DISTANCE))
	_hover_at(position)


func _pointer_up(index: int) -> void:
	# The position has to be read before the pointer is dropped, otherwise the
	# tap lands wherever the last drag happened to end.
	var was_tap: bool = _pointers.has(index) and not _dragged
	var tapped := _screen_to_cell(_pointers[index]) if was_tap else -1
	_pointers.erase(index)
	_pointer_start.erase(index)
	if _pointers.size() >= 2:
		_begin_gesture()
	else:
		_gesture = false
	if was_tap:
		_on_tap(tapped)


func _hover_at(screen_position: Vector2) -> void:
	hover_cell = _screen_to_cell(screen_position)
	if armed_kind != "":
		_update_ghost()
	elif road_from >= 0:
		_update_preview()
	else:
		_ghost.visible = false
		_preview.visible = false


## Projects the tap onto the ground plane and returns the cell under it.
func _screen_to_cell(screen_position: Vector2) -> int:
	var from := camera.project_ray_origin(screen_position)
	var direction := camera.project_ray_normal(screen_position)
	if absf(direction.y) < 0.0001:
		return -1
	var distance := (GROUND_Y - from.y) / direction.y
	if distance < 0.0:
		return -1
	return siedler.world_to_cell(from.x + direction.x * distance, from.z + direction.z * distance)


func _begin_gesture() -> void:
	var keys := _pointers.keys()
	if keys.size() < 2:
		return
	var a: Vector2 = _pointers[keys[0]]
	var b: Vector2 = _pointers[keys[1]]
	_gesture = true
	_gesture_span = maxf(a.distance_to(b), 1.0)
	_gesture_angle = atan2(b.y - a.y, b.x - a.x)
	_gesture_mid = (a + b) * 0.5
	_dragged = true


func _update_gesture() -> void:
	var keys := _pointers.keys()
	if keys.size() < 2 or not _gesture:
		return
	var a: Vector2 = _pointers[keys[0]]
	var b: Vector2 = _pointers[keys[1]]
	var span := maxf(a.distance_to(b), 1.0)
	var angle := atan2(b.y - a.y, b.x - a.x)
	_zoom(_gesture_span / span)
	cam_yaw -= angle - _gesture_angle
	_gesture_angle = angle
	var mid := (a + b) * 0.5
	_pan_by((_gesture_mid - mid) * PAN_SPEED * (cam_distance / CAM_MIN_DISTANCE))
	_gesture_mid = mid


## Moves the focus point on the ground plane along the screen axes.
func _pan_by(screen_delta: Vector2) -> void:
	var forward := Vector3(sin(cam_yaw), 0.0, cos(cam_yaw))
	var right := Vector3(forward.z, 0.0, -forward.x)
	var goal := cam_goal - forward * screen_delta.y + right * screen_delta.x
	goal.x = clampf(goal.x, -CAM_LIMIT, CAM_LIMIT)
	goal.z = clampf(goal.z, -CAM_LIMIT, CAM_LIMIT)
	cam_goal = goal


func _zoom(factor: float) -> void:
	cam_goal_distance = clampf(cam_goal_distance * factor, CAM_MIN_DISTANCE, CAM_MAX_DISTANCE)


func _on_tap(cell: int) -> void:
	if cell < 0:
		selected_building = -1
		return
	if tool == Tool.ROAD:
		_tap_road(cell)
		return
	if tool == Tool.FLAG:
		if siedler.add_flag(cell):
			notify("Banner placed — more carriers on this road")
			_roads_dirty = true
			Sfx.select()
		else:
			notify(siedler.notice)
		return
	if armed_kind != "":
		if siedler.place_building(armed_kind, cell):
			_roads_dirty = true
			_terrain_dirty = true
			_slow_timer = 1.0
			Sfx.select()
		else:
			notify(siedler.notice)
		return
	# No tool armed: select.
	selected_building = int(siedler.cells[cell]["building"])
	Sfx.select()


func _tap_road(cell: int) -> void:
	if road_from < 0:
		road_from = cell
		notify("Start tile chosen — now tap the target")
		return
	var result := siedler.build_road(road_from, cell, 4)
	if bool(result["ok"]):
		var flags := int(result["flags"])
		if flags > 0:
			notify(Loc.f("Road built · %d banners", [flags]))
		else:
			notify("Road built")
		_roads_dirty = true
		_slow_timer = 1.0
		Sfx.select()
	else:
		notify(str(result["reason"]))
	road_from = -1
	_preview.visible = false


func _set_tool(next: int) -> void:
	tool = next
	road_from = -1
	_preview.visible = false
	if next != Tool.SELECT:
		armed_kind = ""
		_ghost.visible = false
	for key in _tool_buttons:
		if key is int:
			var button := _tool_buttons[key] as Button
			button.modulate = UiTheme.ACCENT if int(key) == next else Color.WHITE


func _set_speed(index: int) -> void:
	speed_index = clampi(index, 0, SPEEDS.size() - 1)
	siedler.speed = SPEEDS[speed_index]
	for i in SPEEDS.size():
		var key := "speed%d" % i
		if _tool_buttons.has(key):
			(_tool_buttons[key] as Button).modulate = UiTheme.ACCENT if i == speed_index else Color.WHITE


func _update_ghost() -> void:
	# The advisor can point at a cell that cannot be built on (a stalled flag).
	# A pulsing square there shows the player where to tap.
	if armed_kind == "" and tool == Tool.FLAG and _advisor_cell >= 0:
		_ghost.position = siedler.cell_position(_advisor_cell, 0.06)
		_ghost.visible = true
		var pulse := 0.5 + 0.5 * sin(_clock * 6.0)
		(_ghost.material_override as StandardMaterial3D).albedo_color = Color("fbbf24").lerp(
			Color.WHITE, pulse * 0.6
		)
		return
	if armed_kind == "" or hover_cell < 0:
		_ghost.visible = false
		return
	var spec := Siedler.spec_of(armed_kind)
	var check := siedler.can_place(armed_kind, hover_cell)
	_ghost.position = siedler.cell_position(hover_cell, 0.06)
	_ghost.visible = true
	var material := _ghost.material_override as StandardMaterial3D
	if not bool(check["ok"]):
		material.albedo_color = Color("ef4444")
	elif int(siedler.store.get("planks", 0)) < int(spec["cost"]["planks"]) \
			or int(siedler.store.get("stone", 0)) < int(spec["cost"]["stone"]):
		material.albedo_color = Color("fbbf24")
	else:
		material.albedo_color = Color("4ade80")


func _update_preview() -> void:
	if road_from < 0 or hover_cell < 0:
		_preview.visible = false
		return
	var a := siedler.cell_position(road_from, 0.4)
	var b := siedler.cell_position(hover_cell, 0.4)
	_preview.visible = true
	_preview.position = (a + b) * 0.5
	_preview.scale = Vector3(maxf(a.distance_to(b), 0.2), 1.0, 1.0)
	# The bar lies along the connecting axis.
	_preview.rotation.y = atan2(b.x - a.x, b.z - a.z)


# --- per-frame --------------------------------------------------------------

func _update_world(delta: float) -> void:
	_frame_delta = delta
	cam_focus = cam_focus.lerp(cam_goal, clampf(6.0 * delta, 0.0, 1.0))
	cam_distance = lerpf(cam_distance, cam_goal_distance, clampf(6.0 * delta, 0.0, 1.0))
	_apply_camera()

	if _terrain_dirty:
		_build_terrain()
		_terrain_dirty = false
	if _roads_dirty:
		_build_roads()
		_roads_dirty = false

	_sync_buildings()
	_sync_flags()
	_sync_serfs()
	_sync_carriers()
	_animate_machines()

	# Warehouses and territory only every half second: they change rarely, and
	# this saves rewriting thousands of instance matrices.
	_slow_timer += delta
	if _slow_timer > 0.5:
		_slow_timer = 0.0
		_rebuild_props()
		_rebuild_territory()

	# The advisor's blinking square pulses even without pointer movement.
	if armed_kind == "" and tool == Tool.FLAG and _advisor_cell >= 0:
		_clock += delta
		_update_ghost()

	_hud_timer += delta
	if _hud_timer > 0.2:
		_hud_timer = 0.0
		_update_stats()
		_update_advisor()
		_update_inspector()
		_check_end()

	if siedler.notice != "" and siedler.notice != _notice_shown:
		_notice_shown = siedler.notice
		notify(siedler.notice)


func _apply_camera() -> void:
	var offset := Vector3(
		sin(cam_yaw) * cos(CAM_PITCH),
		sin(CAM_PITCH),
		cos(cam_yaw) * cos(CAM_PITCH)
	) * cam_distance
	camera.position = cam_focus + offset
	camera.look_at(cam_focus, Vector3.UP)


# --- terrain ----------------------------------------------------------------

## One vertex-coloured mesh for the whole island: a continuous heightmap rather
## than a mesh per cell, which would be thousands of draw calls on a phone.
func _build_terrain() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var size := siedler.map_size
	var half := float(size) * 0.5
	# Height per grid point: the mean of the up to four adjacent cells, so
	# neighbouring quads do not tear.
	var heights: PackedFloat32Array = PackedFloat32Array()
	heights.resize(size * size)
	for j in size:
		for i in size:
			var total := 0.0
			var count := 0
			for dy in range(-1, 1):
				for dx in range(-1, 1):
					var x := i + dx
					var y := j + dy
					if not siedler.in_bounds(x, y):
						continue
					var cell: Dictionary = siedler.cells[siedler.cell_index(x, y)]
					total += float(cell["height"])
					count += 1
			heights[j * size + i] = total / float(maxi(1, count))
	for j in size - 1:
		for i in size - 1:
			var p00 := Vector3(float(i) - half + 0.5, heights[j * size + i], float(j) - half + 0.5)
			var p10 := Vector3(float(i + 1) - half + 0.5, heights[j * size + i + 1], float(j) - half + 0.5)
			var p11 := Vector3(float(i + 1) - half + 0.5, heights[(j + 1) * size + i + 1], float(j + 1) - half + 0.5)
			var p01 := Vector3(float(i) - half + 0.5, heights[(j + 1) * size + i], float(j + 1) - half + 0.5)
			var c00 := _cell_color(siedler.cell_index(i, j))
			var c10 := _cell_color(siedler.cell_index(i + 1, j))
			var c11 := _cell_color(siedler.cell_index(i + 1, j + 1))
			var c01 := _cell_color(siedler.cell_index(i, j + 1))
			_quad(st, p00, p10, p11, p01, c00, c10, c11, c01)
	st.generate_normals()
	_terrain.mesh = st.commit()


func _cell_color(index: int) -> Color:
	var cell: Dictionary = siedler.cells[index]
	match str(cell["res"]):
		"grass": return Color("5c8f3a")
		"forest": return Color("3f6b2c")
		"stone": return Color("8b8d94")
		"coal": return Color("3a3a42")
		"iron": return Color("9c5a34")
		"gold": return Color("b99a2e")
		"water": return Color("2f6ea8")
	return Color("5c8f3a")


func _quad(
	st: SurfaceTool,
	p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3,
	c0: Color, c1: Color, c2: Color, c3: Color
) -> void:
	st.set_color(c0)
	st.add_vertex(p0)
	st.set_color(c1)
	st.add_vertex(p1)
	st.set_color(c2)
	st.add_vertex(p2)
	st.set_color(c0)
	st.add_vertex(p0)
	st.set_color(c2)
	st.add_vertex(p2)
	st.set_color(c3)
	st.add_vertex(p3)


# --- roads ------------------------------------------------------------------

## One `ArrayMesh` of road quads, rebuilt only when the network changes. A busy
## road is lighter — that is the throughput readout in the world itself.
func _build_roads() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for edge in siedler.edges:
		var a: Dictionary = siedler.nodes[int(edge["a"])]
		var b: Dictionary = siedler.nodes[int(edge["b"])]
		var p0 := Vector3(float(a["x"]), ROAD_Y, float(a["z"]))
		var p1 := Vector3(float(b["x"]), ROAD_Y, float(b["z"]))
		var delta := p1 - p0
		if delta.length() < 0.05:
			continue
		var is_link := str(edge["kind"]) == "link"
		var half_width := 0.24 if is_link else 0.34
		var side := Vector3(-delta.z, 0.0, delta.x).normalized() * half_width
		var color := Color("6b5335")
		if not is_link:
			var flow := clampf(siedler.edge_throughput(int(edge["id"])) / 12.0, 0.0, 1.0)
			color = Color(0.36, 0.24, 0.12).lerp(Color(0.72, 0.58, 0.28), flow)
		_road_quad(st, p0 - side, p0 + side, p1 + side, p1 - side, color)
	st.generate_normals()
	_road_mesh.mesh = st.commit()


func _road_quad(st: SurfaceTool, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, color: Color) -> void:
	for point: Vector3 in [p0, p1, p2, p0, p2, p3]:
		st.set_color(color)
		st.add_vertex(point)


# --- deposits and territory -------------------------------------------------

## One `MultiMesh` per resource kind. Instances whose deposit ran dry, or that
## now carry a building, collapse to zero scale.
func _rebuild_props() -> void:
	var counts: Dictionary = {}
	for res in ["forest", "stone", "coal", "iron", "gold", "water"]:
		counts[res] = 0
	for i in siedler.cells.size():
		var res := str(siedler.cells[i]["res"])
		if res == "grass" or not counts.has(res):
			continue
		counts[res] = int(counts[res]) + 1
	for res in counts:
		if not _prop_meshes.has(res):
			_prop_meshes[res] = _make_prop_multimesh(res, int(counts[res]))
		(_prop_meshes[res] as MultiMeshInstance3D).multimesh.visible_instance_count = int(counts[res])

	var used: Dictionary = {}
	for res in counts:
		used[res] = 0
	for i in siedler.cells.size():
		var cell: Dictionary = siedler.cells[i]
		var res := str(cell["res"])
		if res == "grass" or not _prop_meshes.has(res):
			continue
		var multimesh: MultiMesh = (_prop_meshes[res] as MultiMeshInstance3D).multimesh
		var slot: int = int(used[res])
		used[res] = slot + 1
		var transform := Transform3D.IDENTITY
		if int(cell["amount"]) > 0 and int(cell["building"]) < 0:
			var world := siedler.cell_to_world(i)
			var scale := 1.0 if res == "water" else 0.85 + float(i % 5) * 0.07
			transform = Transform3D(
				Basis(Vector3.UP, float(i % 7) * 0.9).scaled(Vector3.ONE * scale),
				Vector3(world.x, float(cell["height"]) + 0.05, world.y)
			)
		multimesh.set_instance_transform(slot, transform)


## A translucent quad over every plot the player owns, so "where am I allowed to
## build?" is answered at a glance.
func _rebuild_territory() -> void:
	var slot := 0
	for i in siedler.cells.size():
		if slot >= _territory_capacity:
			break
		var cell: Dictionary = siedler.cells[i]
		if not siedler.in_territory(i) or str(cell["res"]) == "water":
			continue
		var world := siedler.cell_to_world(i)
		_territory.multimesh.set_instance_transform(slot, Transform3D(
			Basis.IDENTITY.scaled(Vector3(0.92, 1.0, 0.92)),
			Vector3(world.x, float(cell["height"]) + 0.04, world.y)
		))
		slot += 1
	_territory.multimesh.visible_instance_count = slot


func _make_overlay(node_name: String, color: Color, alpha: float, size: float) -> MultiMeshInstance3D:
	var instance := MultiMeshInstance3D.new()
	instance.name = node_name
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	multimesh.mesh = quad
	multimesh.instance_count = siedler.cells.size()
	multimesh.visible_instance_count = 0
	instance.multimesh = multimesh
	instance.material_override = _flat_material(color, alpha)
	instance.rotation_degrees = Vector3(-90, 0, 0)
	_world_root.add_child(instance)
	return instance


func _make_prop_multimesh(res: String, count: int) -> MultiMeshInstance3D:
	var instance := MultiMeshInstance3D.new()
	instance.name = "Deposit_%s" % res
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = _mesh_resource(_node_mesh_key(res))
	multimesh.instance_count = maxi(1, count)
	multimesh.visible_instance_count = count
	instance.multimesh = multimesh
	_prop_root.add_child(instance)
	return instance


func _node_mesh_key(res: String) -> String:
	match res:
		"forest": return "siedler/oak"
		"stone": return "siedler/stone_node"
		"coal": return "siedler/coal_node"
		"iron": return "siedler/iron_node"
		"gold": return "siedler/gold_node"
		"water": return "siedler/fish_spot"
	return "siedler/stone_node"


# --- buildings --------------------------------------------------------------

func _sync_buildings() -> void:
	for building in siedler.buildings:
		var id := int(building["id"])
		var key := _building_key(building)
		var node: Node3D = _building_nodes.get(id)
		if node == null or str(node.get_meta("key", "")) != key:
			if node != null:
				node.queue_free()
				_building_labels.erase(id)
			node = _mesh_of(key)
			node.set_meta("key", key)
			_world_root.add_child(node)
			_building_nodes[id] = node
		node.position = siedler.cell_position(int(building["cell"]))
		# Only finished buildings get a sign; a construction site does not.
		var spec := Siedler.spec_of(str(building["kind"]))
		if str(building["state"]) == "done" and not _building_labels.has(id):
			var label := Label3D.new()
			label.text = Loc.f("%s %s", [spec["icon"], spec["name"]])
			label.font_size = 44
			label.pixel_size = 0.0055
			label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			label.outline_size = 14
			label.outline_modulate = Color(0, 0, 0, 0.85)
			label.modulate = Color("f87171") if str(building["owner"]) == "rival" else Color("bae6fd")
			label.position = Vector3(0, LABEL_HEIGHT, 0)
			node.add_child(label)
			_building_labels[id] = label


## Which mesh dresses a building.
func _building_key(building: Dictionary) -> String:
	if str(building["state"]) != "done":
		return "siedler/construction"
	return str(Siedler.MESH_BY_KIND.get(str(building["kind"]), "siedler/warehouse"))


func _sync_flags() -> void:
	for node_data in siedler.nodes:
		if not bool(node_data["flag"]):
			continue
		var id := int(node_data["id"])
		var node: Node3D = _flag_nodes.get(id)
		if node == null:
			node = _mesh_of("siedler/flag")
			_world_root.add_child(node)
			_flag_nodes[id] = node
		node.position = Vector3(float(node_data["x"]), 0.0, float(node_data["z"]))


# --- settlers ---------------------------------------------------------------

## The pool is indexed by settler slot, so a settler that leaves the castle
## simply stops being drawn.
func _sync_serfs() -> void:
	var used := 0
	for i in mini(MAX_SERFS, siedler.serfs.size()):
		var serf: Dictionary = siedler.serfs[i]
		if str(serf["owner"]) != "player":
			continue
		while _serf_nodes.size() <= i:
			var created := _mesh_of("siedler/settler")
			_world_root.add_child(created)
			_serf_nodes.append(created)
		var node := _serf_nodes[i]
		node.visible = true
		node.position = Vector3(float(serf["x"]), 0.0, float(serf["z"]))
		var swing := sin(float(serf["phase"])) * 0.55 if str(serf["state"]) == "walk" else 0.0
		_animate_limbs(node, swing)
		used = maxi(used, i + 1)
	for i in range(used, _serf_nodes.size()):
		_serf_nodes[i].visible = false


func _animate_limbs(node: Node3D, swing: float) -> void:
	var legs := _find_prefixed(node, "SettlerLeg")
	if legs.size() >= 2:
		(legs[0] as Node3D).rotation.x = swing
		(legs[1] as Node3D).rotation.x = -swing
	var arms := _find_prefixed(node, "SettlerArm")
	if arms.size() >= 2:
		(arms[0] as Node3D).rotation.x = -swing
		(arms[1] as Node3D).rotation.x = swing


## The windmill turns while it has grain, the forge glows while it works.
func _animate_machines() -> void:
	for building in siedler.buildings:
		var node: Node3D = _building_nodes.get(int(building["id"]))
		if node == null:
			continue
		var working := str(building["status"]) == "ok"
		var sails := _find_named(node, "WindmillSails")
		if sails != null:
			sails.rotate_object_local(Vector3.BACK, _frame_delta * (2.4 if working else 0.15))
		var glow := _find_named(node, "ForgeGlow")
		if glow == null:
			glow = _find_named(node, "SmelterGlow")
		if glow != null:
			var material := glow.get_active_material(0) as StandardMaterial3D
			if material != null:
				material.emission_energy_multiplier = 1.8 if working else 0.25


# --- carriers ---------------------------------------------------------------

## One `MultiMesh` holds every carrier, tinted by the good it carries. An empty
## carrier is grey, so the transshipment is readable at a glance.
func _sync_carriers() -> void:
	var multimesh := _carriers.multimesh
	var slot := 0
	for edge in siedler.edges:
		if slot >= MAX_CARRIERS:
			break
		for carrier in edge["carriers"]:
			if slot >= MAX_CARRIERS:
				break
			multimesh.set_instance_transform(slot, Transform3D(
				Basis(Vector3.UP, float(carrier["phase"])),
				Vector3(float(carrier["x"]), 0.0, float(carrier["z"]))
			))
			var good := str(carrier["load"])
			if good == "":
				multimesh.set_instance_color(slot, Color("64748b"))
			else:
				# `class_name` is a reserved word, hence `family` here.
				var family := str(Siedler.GOOD_CLASS.get(good, "wood"))
				multimesh.set_instance_color(slot, Siedler.CLASS_COLORS.get(family, Color.WHITE))
			slot += 1
	multimesh.visible_instance_count = slot


# --- hud --------------------------------------------------------------------

func _update_stats() -> void:
	var food := siedler.food_pieces()
	var store := siedler.store_report()
	var lines: Array[String] = [
		Loc.f("Planks %d · Logs %d", [int(siedler.store.get("planks", 0)), int(siedler.store.get("logs", 0))]),
		Loc.f("Stone %d · Coal %d · Iron %d", [
			int(siedler.store.get("stone", 0)),
			int(siedler.store.get("coal", 0)),
			int(siedler.store.get("iron", 0)),
		]),
		"Tools %d" % _tool_count(),
	]
	# The storage line sits above the food, because it answers the same question:
	# how much is there, and how much still fits? Without it the player only sees
	# a full castle once nothing fits any more. The refused-delivery count lives
	# here and not on the advisor card, because it keeps counting every second.
	if bool(store["full"]):
		lines.append(Loc.f("Storehouse full: %d of %d slots", [
			int(store["used"]), int(store["capacity"]),
		]) + "  ·  " + Loc.t("siedler.turned_away", {"count": int(store["refused_total"])}))
	else:
		lines.append(Loc.t("siedler.storehouse") + " " + Loc.f("%d of %d slots", [
			int(store["used"]), int(store["capacity"]),
		]))
	if food <= 0:
		lines.append("Food: 0 — the mines are starving!")
	else:
		lines.append("Food %d" % food)
	lines.append("Settlers %d/%d · Territory %d %%" % [
		siedler.current_serfs(), siedler.serf_quota(), int(siedler.territory_share() * 100.0),
	])
	var stuck := siedler.stuck_goods()
	if stuck > 0:
		lines.append(Loc.tn("siedler.goods_piled", stuck))
	var orphans := siedler.orphan_goods()
	if not orphans.is_empty():
		lines.append("no buyer: %s" % ", ".join(orphans.slice(0, 3)))
	lines.append("Score %s" % Ui.format_number(siedler.score()))
	_stats_label.text = "\n".join(lines)


## The advisor: the card that spares a new player the original's most expensive
## lesson. Not *some* building is idle, but *this* one, and it needs *this* good —
## with the button that does exactly that. The logic is in `Siedler.bottlenecks()`.
func _update_advisor() -> void:
	var list := siedler.bottlenecks()
	if list.is_empty():
		_advisor.visible = false
		_advisor_key = ""
		_advisor_cell = -1
		_advisor_top = {}
		return
	var top: Dictionary = list[0]
	_advisor_cell = int(top["cell"])
	_advisor_top = top
	# The card is rebuilt only when the advice itself changes; otherwise it
	# flickers five times a second, and nobody reads flickering text.
	var key := "%s:%s:%d" % [str(top["code"]), str(top["good"]), int(top["count"])]
	if key == _advisor_key and _advisor.visible:
		return
	_advisor_key = key
	_advisor.visible = true
	for child in _advisor_body.get_children():
		child.queue_free()

	var color := _severity_color(int(top["severity"]))
	_advisor_body.add_child(Ui.label(str(top["title"]), 17, color, true))
	var detail := Ui.label(str(top["detail"]), 13, UiTheme.TEXT_DIM)
	# The card grows with the text; without wrapping the sentence would run past
	# the edge.
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_advisor_body.add_child(detail)

	var row := Ui.hbox(8)
	_advisor_body.add_child(row)
	if list.size() > 1:
		row.add_child(Ui.button(Loc.f("▸ all (%d)", [list.size()]), Vector2(112, 40),
			UiTheme.PANEL_LIGHT, _show_all_advice))
	var fix := str(top.get("fix", ""))
	var target := int(top["building"])
	if fix != "":
		row.add_child(Ui.button(_fix_label(fix), Vector2(232, 40),
			UiTheme.ACCENT, _run_fix.bind(fix)))
	row.add_child(Ui.expander())
	if target >= 0 and target < siedler.buildings.size():
		row.add_child(Ui.button("⌖ show", Vector2(112, 40), UiTheme.PANEL_LIGHT,
			func() -> void:
				selected_building = target
				Sfx.select()
		))


func _severity_color(severity: int) -> Color:
	match severity:
		Siedler.SEV_CRITICAL: return UiTheme.DANGER
		Siedler.SEV_WARNING: return UiTheme.WARNING
	return UiTheme.SUCCESS


## The label of the button that fixes the top advice.
func _fix_label(fix: String) -> String:
	if fix.begins_with("build:"):
		var kind := fix.substr(6)
		return "⌂ %s" % str(Siedler.spec_of(kind)["name"])
	if fix == "queueTool":
		return Loc.t("siedler.fix_queue_tool")
	if fix.begins_with("road:"):
		return Loc.t("siedler.fix_road")
	if fix.begins_with("flag:"):
		return Loc.t("siedler.fix_flag")
	if fix.begins_with("select:"):
		return Loc.t("siedler.fix_show")
	if fix == "book:food":
		return "⌂ Build food"
	return ""


## Runs the move the advisor proposed. Every proposal is a one-button move, so
## the player does not have to search the build arc first.
func _run_fix(fix: String, target: int) -> void:
	Sfx.select()
	if fix.begins_with("build:"):
		var kind := fix.substr(6)
		armed_kind = kind
		_set_tool(Tool.SELECT)
		if not _can_pay(kind):
			notify("The castle is short of building material for that")
			return
		notify(Loc.f("%s is being built — tap a tile", [str(Siedler.spec_of(kind)["name"])]))
		return
	if fix == "queueTool":
		var tool_key := str(_advisor_top.get("good", ""))
		if tool_key != "" and siedler.request_tool(tool_key):
			notify(Loc.f("%s is scheduled", [Siedler.good_name(tool_key)]))
		else:
			notify(siedler.notice if tool_key != "" else "Unknown tool")
		return
	if fix.begins_with("road:"):
		_set_tool(Tool.ROAD)
		road_from = int(siedler.buildings[siedler.castle_id]["cell"])
		notify("Start tile: the castle — now tap the target")
		return
	if fix.begins_with("flag:"):
		_set_tool(Tool.FLAG)
		notify("Tap a banner where the square flashes")
		return
	if fix.begins_with("select:"):
		selected_building = fix.substr(7).to_int()
		return
	if fix == "book:food":
		_open_build_sheet()
		return
	if target >= 0:
		selected_building = target


## Can the castle still pay for this building? Otherwise the button would lead
## nowhere and the player would be surprised by a red card.
func _can_pay(kind: String) -> bool:
	var cost: Dictionary = Siedler.spec_of(kind)["cost"]
	return int(siedler.store.get("planks", 0)) >= int(cost["planks"]) \
		and int(siedler.store.get("stone", 0)) >= int(cost["stone"])


## The full list — the player should see that there is not *one* bottleneck but
## a ranking, and be allowed to decide for themselves.
func _show_all_advice() -> void:
	Sfx.select()
	var root := _modal_root()
	root.add_child(Ui.backdrop(0.86))
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var panel := Ui.panel(Color(0.043, 0.063, 0.11, 0.98), UiTheme.ACCENT, 14)
	panel.custom_minimum_size = Vector2(640, 0)
	center.add_child(panel)
	var column := Ui.vbox(8)
	panel.add_child(column)
	column.add_child(Ui.title("What is holding your settlement back?", 24, UiTheme.ACCENT))
	var list := siedler.bottlenecks()
	if list.is_empty():
		column.add_child(Ui.label("Nothing — every building is working.", 15, UiTheme.SUCCESS))
	for entry in list:
		var box := Ui.vbox(2)
		column.add_child(box)
		var head := Ui.hbox(8)
		box.add_child(head)
		head.add_child(Ui.label(
			Loc.f("■ %s", [str(entry["title"])]), 15, _severity_color(int(entry["severity"])), true
		))
		if int(entry["count"]) > 1:
			head.add_child(Ui.label(Loc.f("×%d", [int(entry["count"])]), 13, UiTheme.TEXT_MUTED))
		var text := Ui.label(str(entry["detail"]), 13, UiTheme.TEXT_DIM)
		text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		text.custom_minimum_size = Vector2(600, 0)
		box.add_child(text)
	var close_row := CenterContainer.new()
	close_row.add_child(Ui.button("Back to the settlement", Vector2(230, 46),
		UiTheme.PANEL_LIGHT, func() -> void:
			_close_modal()
	))
	column.add_child(close_row)


# --- trade routes ------------------------------------------------------------

## The "Trade routes" card answers the question the proposal poses: *which* road
## carries *which* good. The advisor says which building is hungry; this card
## says why the delivery is still too slow.
func _open_routes_sheet() -> void:
	Sfx.select()
	_routes_notes = []
	var root := _modal_root()
	root.add_child(Ui.backdrop(0.86))
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var panel := Ui.panel(Color(0.043, 0.063, 0.11, 0.98), UiTheme.ACCENT, 14)
	panel.custom_minimum_size = Vector2(700, 0)
	center.add_child(panel)
	var column := Ui.vbox(8)
	panel.add_child(column)
	column.add_child(Ui.title("Trade routes", 26, UiTheme.ACCENT))
	var lead := Ui.label(
		"Every trip since the last road is counted. The map measures, the optimiser decides.",
		12, UiTheme.TEXT_DIM
	)
	lead.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lead.custom_minimum_size = Vector2(660, 0)
	column.add_child(lead)
	_routes_body = Ui.vbox(6)
	column.add_child(_routes_body)
	_rebuild_routes_sheet()

	var actions := Ui.hbox(8)
	column.add_child(actions)
	actions.add_child(Ui.button("⇄ Optimise", Vector2(190, 46), UiTheme.ACCENT, func() -> void:
		_run_optimizer()
	))
	actions.add_child(Ui.button("↻ Measure again", Vector2(160, 46), UiTheme.PANEL_LIGHT, func() -> void:
		_rebuild_routes_sheet()
	))
	actions.add_child(Ui.expander())
	actions.add_child(Ui.button("Back", Vector2(150, 46), UiTheme.PANEL_LIGHT, func() -> void:
		_close_modal()
	))


## Rebuilds the card content. After an optimizer pass the number of routes
## changes, so the rows cannot be reused.
func _rebuild_routes_sheet() -> void:
	if _routes_body == null or not is_instance_valid(_routes_body):
		return
	for child in _routes_body.get_children():
		child.queue_free()
	for note in _routes_notes:
		_routes_body.add_child(_note_label("• " + note, UiTheme.SUCCESS))
	var routes := siedler.trade_report()
	if routes.is_empty():
		_routes_body.add_child(Ui.label(
			"No traffic measured yet. Build a road from the castle to a producer and let the carriers run.",
			14, UiTheme.TEXT_DIM
		))
	for entry in routes.slice(0, ROUTE_ROWS):
		_routes_body.add_child(_route_row(entry))
	if routes.size() > ROUTE_ROWS:
		_routes_body.add_child(Ui.label(
			Loc.f("… and %d more busy lines.", [(routes.size() - ROUTE_ROWS)]), 12, UiTheme.TEXT_MUTED
		))
	_routes_body.add_child(Ui.label(
		Loc.f("%d trips measured · %d busy lines", [siedler.measured_carriers(), routes.size(),]), 12, UiTheme.TEXT_MUTED
	))


func _note_label(text: String, color: Color) -> Label:
	var label := Ui.label(text, 12, color)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size = Vector2(660, 0)
	return label


## One route in the card: what it carries, how many carriers, and the one sentence
## about what to do. Plus the same two moves the optimizer takes, so the player
## can disagree with the proposal instead of having to accept it.
func _route_row(entry: Dictionary) -> Control:
	var box := Ui.vbox(2)
	var head := Ui.hbox(8)
	box.add_child(head)
	var good := str(entry["top"])
	var family := str(Siedler.GOOD_CLASS.get(good, "wood"))
	head.add_child(Ui.label(
		Loc.f("▬ “%s”", [Siedler.good_name(good)]), 15,
		Siedler.CLASS_COLORS.get(family, UiTheme.TEXT), true
	))
	if str(entry["kind"]) == "link":
		# The stub between house and flag carries half the delivery of a young
		# settlement. It is in the report, but it is not a trade route, and the
		# player should see that at once when reading the row.
		head.add_child(Ui.label("Neighbour", 12, UiTheme.TEXT_MUTED))
	head.add_child(Ui.label(
		Loc.f("%d of %d", [int(entry["top_count"]), int(entry["total"])]), 12, UiTheme.TEXT_MUTED
	))
	head.add_child(Ui.expander())
	head.add_child(Ui.label(Loc.f("%.0f tiles · %d carriers · %.1f/min · priority %d", [float(entry["length"]), int(entry["carriers"]),
		float(entry["throughput"]), int(entry["priority"]),]), 12, UiTheme.TEXT_DIM))

	var row := Ui.hbox(6)
	box.add_child(row)
	var edge_id := int(entry["edge"])
	var priority := int(entry["priority"])
	row.add_child(Ui.button("Prio −", Vector2(84, 36), UiTheme.PANEL_LIGHT, func() -> void:
		_road_priority(edge_id, priority - 1)
	))
	row.add_child(Ui.button("Prio +", Vector2(84, 36), UiTheme.PANEL_LIGHT, func() -> void:
		_road_priority(edge_id, priority + 1)
	))
	var cell := int(entry["cell"])
	if cell >= 0:
		row.add_child(Ui.button("⚑ Share line", Vector2(160, 36), UiTheme.ACCENT, func() -> void:
			_split_road(cell)
		))
	row.add_child(Ui.expander())
	var gain := int(entry["gain"])
	var waiting := int(entry["waiting"])
	var value := int(entry["value"])
	row.add_child(Ui.label(
		Loc.f("waiting %d · worth %d · sharing brings %d carriers", [waiting, value, maxi(0, gain)]),
		12, UiTheme.TEXT_MUTED
	))
	box.add_child(_note_label(siedler.route_advice(entry), UiTheme.WARNING))
	return box


func _road_priority(edge_id: int, priority: int) -> void:
	siedler.set_road_priority(edge_id, priority)
	_roads_dirty = true
	Sfx.select()
	_rebuild_routes_sheet()


func _split_road(cell: int) -> void:
	if siedler.add_flag(cell):
		notify("Banner placed — more carriers on this road")
		_roads_dirty = true
		Sfx.select()
	else:
		notify(siedler.notice)
	# A flag splits a road in two and the edge ids shift, so the card re-reads
	# after every move.
	_rebuild_routes_sheet()


## The single move from the proposal. It comes from the logic and reports
## itself via `notice`; the card additionally shows what it did.
func _run_optimizer() -> void:
	_routes_notes = siedler.optimize_trade_routes()
	_roads_dirty = true
	_slow_timer = 1.0
	Sfx.select()
	_rebuild_routes_sheet()


func _tool_count() -> int:
	var total := 0
	for tool_key in Siedler.TOOLS:
		total += int(siedler.store.get(tool_key, 0))
	return total


## The inspector answers the question that bothered the original most:
## why is this building idle?
func _update_inspector() -> void:
	if selected_building < 0 or selected_building >= siedler.buildings.size():
		_inspector.visible = false
		return
	var building: Dictionary = siedler.buildings[selected_building]
	var spec := Siedler.spec_of(str(building["kind"]))
	var rival := str(building["owner"]) == "rival"

	for child in _inspector_body.get_children():
		child.queue_free()
	_inspector.visible = true

	_inspector_body.add_child(Ui.label(Loc.f("%s %s", [spec["icon"], spec["name"]]), 20, UiTheme.ACCENT, true))
	_inspector_body.add_child(Ui.label(str(spec["desc"]), 12, UiTheme.TEXT_DIM))

	var status_text := Loc.t("siedler.rival") if rival else Siedler.status_text(str(building["status"]))
	var status_color := UiTheme.TEXT_DIM
	if not rival:
		status_color = UiTheme.SUCCESS if str(building["status"]) == "ok" else UiTheme.WARNING
	_inspector_body.add_child(_row(Loc.t("siedler.state"), status_text, status_color))
	# The castle *is* the warehouse: it shows the storage slots. A full store
	# refuses deliveries, which is otherwise only visible in the queue row.
	if not rival and str(building["kind"]) == "castle":
		var store := siedler.store_report()
		_inspector_body.add_child(_row(
			"Storehouse", Loc.f("%d of %d slots", [int(store["used"]), int(store["capacity"])]),
			UiTheme.DANGER if bool(store["full"]) else UiTheme.TEXT
		))
		if int(store["refused_total"]) > 0:
			_inspector_body.add_child(_row(
				"Before the gate", "%d deliveries turned away, %d waiting" % [
					int(store["refused_total"]), int(store["stuck"]),
				], UiTheme.WARNING
			))
	if int(spec["workers"]) > 0:
		_inspector_body.add_child(_row("Settlers", "%d/%d" % [int(building["workers"]), int(spec["workers"])], UiTheme.TEXT))
	if str(spec["tool"]) != "":
		var has_tool := str(building["tool"]) != ""
		_inspector_body.add_child(_row(
			"Tool", Siedler.good_name(str(spec["tool"])),
			UiTheme.SUCCESS if has_tool else UiTheme.WARNING
		))
	if bool(spec["hungry"]):
		var fed := siedler.food_pieces() > 0
		_inspector_body.add_child(_row(
			Loc.t("siedler.food"), Loc.t("siedler.supplied") if fed else Loc.t("siedler.hunger"),
			UiTheme.SUCCESS if fed else UiTheme.DANGER
		))
	if str(spec["harvest"]) != "":
		_inspector_body.add_child(_row(
			Loc.t("siedler.deposit"), Loc.number(int(siedler.cells[int(building["cell"])]["amount"])), UiTheme.TEXT
		))
	if int(spec["territory"]) > 0:
		_inspector_body.add_child(_row(
			Loc.t("siedler.garrison"), Loc.t("siedler.knights", {"count": int(building["garrison"])}), UiTheme.TEXT
		))
	var inputs: Dictionary = spec["inputs"]
	if not inputs.is_empty():
		_inspector_body.add_child(_row(Loc.t("siedler.needs"), _goods_text(inputs, building["input"]), UiTheme.TEXT))
	var outputs: Dictionary = spec["outputs"]
	if not outputs.is_empty():
		_inspector_body.add_child(_row(Loc.t("siedler.delivers"), _goods_text(outputs, building["output"]), UiTheme.SUCCESS))
	if str(building["kind"]) == "toolsmith" and not siedler.tool_queue.is_empty():
		_inspector_body.add_child(_row(Loc.t("siedler.queue"), " ".join(siedler.tool_queue), UiTheme.WARNING))
	if str(building["state"]) != "done" and not rival:
		var bar := Ui.bar(UiTheme.ACCENT, 12.0)
		Ui.set_bar(bar, float(building["progress"]), UiTheme.ACCENT)
		_inspector_body.add_child(bar)

	if rival:
		var morale := siedler.attack_morale()
		var suffix := ""
		if morale > 1.01:
			suffix = ", Moral +%d %%" % int((morale - 1.0) * 100.0)
		var target_id := selected_building
		_inspector_body.add_child(Ui.button(
			Loc.f("⚔ Attack (%d knight%s)", [siedler.knights, suffix]),
			Vector2(272, 46), UiTheme.DANGER, func() -> void:
				if siedler.send_knights(target_id, siedler.knights):
					notify("Knights have run out!")
					Sfx.select()
				else:
					notify(siedler.notice)
		))
	elif str(building["state"]) == "done":
		var toggle := Loc.t("siedler.keep_working") if bool(building["halted"]) else Loc.t("siedler.halt")
		_inspector_body.add_child(Ui.button(toggle, Vector2(272, 42), UiTheme.PANEL_LIGHT, func() -> void:
			building["halted"] = not bool(building["halted"])
		))

	if rival or str(building["kind"]) == "toolsmith":
		var tools_row := Ui.hbox(3)
		_inspector_body.add_child(tools_row)
		for tool_key in Siedler.TOOLS:
			var key := tool_key
			var button := Ui.button(Siedler.good_name(key).substr(0, 2), Vector2(29, 32), UiTheme.PANEL_LIGHT, func() -> void:
				if siedler.request_tool(key):
					notify(Loc.f("%s is scheduled", [Siedler.good_name(key)]))
				else:
					notify(siedler.notice)
			)
			button.add_theme_font_size_override("font_size", 11)
			tools_row.add_child(button)


func _row(label_text: String, value_text: String, color: Color) -> Control:
	var row := Ui.hbox(8)
	row.add_child(Ui.label(label_text, 13, UiTheme.TEXT_DIM))
	row.add_child(Ui.spacer())
	var value := Ui.label(value_text, 13, color, true)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(value)
	return row


func _goods_text(amounts: Dictionary, stock: Dictionary) -> String:
	var parts: Array[String] = []
	for good in amounts:
		var amount := int(amounts[good])
		if amount <= 0:
			continue
		parts.append("%s %d/%d" % [Siedler.good_name(good), int(stock.get(good, 0)), amount])
	return "  ".join(parts)


func _check_end() -> void:
	if _end_shown or (not siedler.won and not siedler.lost):
		return
	_end_shown = true
	var value := siedler.score()
	Game.submit_score(Game.HS_SIEDLER, value)
	var root := _modal_root()
	root.add_child(Ui.backdrop(0.9))
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var column := Ui.vbox(8)
	center.add_child(column)
	column.add_child(Ui.title(
		"The settlement stands!" if siedler.won else "The castle has fallen",
		38, UiTheme.SUCCESS if siedler.won else UiTheme.DANGER
	))
	var sub := Ui.label(
		"All rival castles belong to you." if siedler.won else "Your rivals have taken your castle.",
		17, UiTheme.TEXT_DIM
	)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(sub)
	var points := Ui.label(Loc.f("Points: %s", [Ui.format_number(value)]), 30, UiTheme.ACCENT, true)
	points.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(points)
	var best := Ui.label(Loc.f("Best: %s", [Ui.format_number(Game.highscore(Game.HS_SIEDLER))]), 15, UiTheme.TEXT_DIM)
	best.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(best)
	var done := 0
	for building in siedler.buildings:
		if str(building["owner"]) == "player" and str(building["state"]) == "done":
			done += 1
	var detail := Ui.label(Loc.f("Buildings %d · Settlers %d · Territory %d %%", [done, siedler.current_serfs(), int(siedler.territory_share() * 100.0),]), 15, UiTheme.TEXT_DIM)
	detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(detail)
	var row := Ui.hbox(10)
	var center_row := CenterContainer.new()
	center_row.add_child(row)
	column.add_child(center_row)
	row.add_child(Ui.button("New village", Vector2(180, 48), UiTheme.ACCENT, func() -> void:
		Router.go_to("siedler")
	))
	row.add_child(Ui.button("◀ Lobby", Vector2(150, 48), UiTheme.PANEL_LIGHT, func() -> void:
		Router.to_lobby()
	))


func _show_help() -> void:
	var root := _modal_root()
	root.add_child(Ui.backdrop(0.9))
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var panel := Ui.panel(Color(0.043, 0.063, 0.11, 0.98), UiTheme.ACCENT, 14)
	panel.custom_minimum_size = Vector2(620, 600)
	center.add_child(panel)
	var column := Ui.vbox(8)
	panel.add_child(column)
	column.add_child(Ui.title("Settlers 3D", 28, UiTheme.ACCENT))
	var texts := [
		["The banners", "Every turquoise banner is a junction. Exactly one carrier takes two banners: it drags a load and hands it over at the next banner. Many banners on the same road = many carriers = more throughput. Too few banners = the goods pile up."],
		["Trade routes", "“⇄ Routes” works out which goods travel over which road and names the next move for each route. “⇄ Optimise” does it automatically: routes that are too long are split in the middle, and the priority is raised for the goods a finished building is waiting on. It takes nothing away from you — priorities only ever rise, and a second pass changes nothing more."],
		["Tools are the key", "A building only works when a settler with the right tool stands at it. The toolshop forges tools from 1 iron + 1 wood. When a bakery stands idle, it is almost always a shovel that is missing — or the bread."],
		["The chains", "Tree → woodcutter (axe) → logs → carpenter (saw) → planks.\nGrain → mill → flour → bakery → bread. Mines starve without bread.\nIron ore + coal → smelter → iron → toolshop → tools."],
		["Territory & military", "New buildings need land that belongs to your territory. A watchtower expands it, but only while at least one knight stands there. Knights equip the smithy (sword + shield). Goal: capture every rival castle."],
		[Loc.t("siedler.help_controls"), "Tap to place and select · Drag to move the map · Two fingers zoom and rotate · 1/2/3 tool · Space speed · Q/E rotate · W trade routes · Esc cancel"],
	]
	for entry in texts:
		column.add_child(Ui.label(str(entry[0]), 17, UiTheme.WARNING, true))
		column.add_child(Ui.label(str(entry[1]), 13, UiTheme.TEXT))
	var close_row := CenterContainer.new()
	close_row.add_child(Ui.button("Got it", Vector2(170, 46), UiTheme.ACCENT, func() -> void:
		_close_modal()
	))
	column.add_child(close_row)


# --- modals -----------------------------------------------------------------

func _modal_root() -> Control:
	if _modal_layer != null and is_instance_valid(_modal_layer):
		return _modal_layer
	_modal_layer = Control.new()
	_modal_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_modal_layer.mouse_filter = Control.MOUSE_FILTER_STOP
	hud_root.add_child(_modal_layer)
	return _modal_layer


func _close_modal() -> void:
	if _modal_layer != null and is_instance_valid(_modal_layer):
		_modal_layer.queue_free()
	_modal_layer = null


# --- mesh helpers -----------------------------------------------------------

## Loads a bundled mesh, or falls back to a primitive, so a 3D game never starts
## with an empty scene.
func _mesh_of(key: String) -> Node3D:
	var node := WorldScreen.mesh(key, Color.WHITE, 1.0)
	if node != null:
		return node
	var fallback := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.8, 0.8, 0.8)
	fallback.mesh = box
	fallback.position = Vector3(0, 0.4, 0)
	return fallback


## The raw `Mesh` of a bundled glTF, for `MultiMesh`. Falls back to a box so a
## deposit still shows up when the import is missing.
func _mesh_resource(key: String) -> Mesh:
	var path := AssetRegistry.path_of(key)
	if ResourceLoader.exists(path):
		var packed: PackedScene = load(path)
		if packed != null:
			var instance := packed.instantiate()
			var found: Mesh = null
			_walk(instance, func(node: Node) -> void:
				if found == null and node is MeshInstance3D:
					found = (node as MeshInstance3D).mesh
			)
			instance.queue_free()
			if found != null:
				return found
	var box := BoxMesh.new()
	box.size = Vector3(0.6, 0.8, 0.6)
	return box


func _find_named(root: Node, node_name: String) -> Node3D:
	var found: Node3D = null
	_walk(root, func(node: Node) -> void:
		if found == null and node is Node3D and str(node.name) == node_name:
			found = node as Node3D
	)
	return found


func _find_prefixed(root: Node, prefix: String) -> Array[Node]:
	var out: Array[Node] = []
	_walk(root, func(node: Node) -> void:
		if str(node.name).begins_with(prefix):
			out.append(node)
	)
	return out


func _walk(node: Node, visit: Callable) -> void:
	visit.call(node)
	for child in node.get_children():
		_walk(child, visit)


func _flat_material(color: Color, alpha: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(color.r, color.g, color.b, alpha)
	if alpha < 1.0:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.roughness = 0.9
	material.metallic = 0.0
	return material


func _terrain_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.95
	material.metallic = 0.0
	return material


func _box_mesh(size: Vector3) -> BoxMesh:
	var box := BoxMesh.new()
	box.size = size
	return box


## The little box a carrier carries, lifted so it hovers at chest height.
func _carrier_mesh() -> BoxMesh:
	var box := BoxMesh.new()
	box.size = Vector3(0.3, 0.3, 0.3)
	return box
