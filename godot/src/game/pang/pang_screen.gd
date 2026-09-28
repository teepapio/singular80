class_name PangScreen
extends WorldScreen
## Pang 3D — the 1990 arcade original as a 3D diorama, faithful to the source:
## no heroes, no abilities, no orbiting spacecraft. Rules live in `Pang`
## (`core/logic/pang.gd`); this file builds the stage, draws it and feeds input.
## Balls and harpoons share one Z plane with scenery in front and behind, so the
## side-on readability of the original survives while every prop is a real mesh.
## Reinforcement waves use the same pooled spawn as the opening layout, so a wave
## costs no allocation and no new node.

## The ball pool is sized from the rules, not guessed: see `Pang.ORB_SAFE_CAP`.
const ORB_LIMIT := Pang.ORB_SAFE_CAP
const HARPOON_LIMIT := 6
const OBSTACLE_LIMIT := 12
const PICKUP_LIMIT := 4
const LABEL_LIMIT := 12
const PARTICLE_COUNT := 240

const CAMERA_TARGET := Vector3(0.0, 8.2, 0.0)
const CAMERA_BASE := 24.0
const CAMERA_FOLLOW := 0.2
const CAMERA_LERP := 5.0

const WALL_Z := -3.2
const FRONT_Z := 3.0
const ORB_Z := 0.0
const HARPOON_Z := 0.5
const PLAYER_Z := 0.9
const OBSTACLE_Z := -1.1

const STATE_PLAYING := "playing"
const STATE_CLEARED := "cleared"
const STATE_LOST := "lost"
const STATE_PAUSED := "paused"

## Colour of the wave warning. Pink, because nothing else on the floor is, and
## it is also the colour of the reinforcement chip in the corner.
const WAVE_ALERT := Color("f472b6")
## The knight's own colour, so the warning tint can be taken back off again.
const PLAYER_TINT := Color("dbe4f0")

## Backdrop moods, cycled per level by `Pang.level_data().background`.
const THEMES: Array[Dictionary] = [
	{"fog": "0b1a2f", "wall": "16324f", "floor": "1d3b52", "sun": "ffe9c4", "fill": "4f7dff", "ambient": "6f9ad6"},
	{"fog": "2a1206", "wall": "4a2412", "floor": "5c3116", "sun": "ffd9a0", "fill": "ff7a3c", "ambient": "c98a55"},
	{"fog": "101a2c", "wall": "1d2f52", "floor": "27405f", "sun": "d8ecff", "fill": "6ea8ff", "ambient": "86a6d8"},
]

## Decoration in three depth layers, so the stage reads as a place rather than
## a backdrop card. Meshes are reused from the shared collection.
const SCENERY: Array[Dictionary] = [
	{"key": "rpg/stone_pillar", "count": 4, "z": WALL_Z - 1.4, "min": 1.6, "max": 2.4, "tint": "3d5673"},
	{"key": "rpg/broken_pillar", "count": 4, "z": WALL_Z - 0.6, "min": 1.0, "max": 1.7, "tint": "3a4f6b"},
	{"key": "rpg/rock_large", "count": 5, "z": WALL_Z + 0.6, "min": 0.8, "max": 1.5, "tint": "44607d"},
	{"key": "rpg/crystal_cluster", "count": 5, "z": WALL_Z + 1.6, "min": 0.6, "max": 1.2, "tint": "2f6f8f"},
	{"key": "rpg/crate", "count": 3, "z": FRONT_Z - 0.5, "min": 0.7, "max": 1.1, "tint": "2b3a52"},
	{"key": "rpg/barrel", "count": 3, "z": FRONT_Z + 0.4, "min": 0.6, "max": 0.9, "tint": "243349"},
]

# --- run state --------------------------------------------------------------

var level := 1
var layout: Dictionary = {}
var theme_index := 0
var state := STATE_PLAYING

var score := 0
var lives := Pang.LIVES
var balls_left := 0
var time_left := 0.0
var run_time := 0.0
var balls_popped := 0
var best_time := 0.0
var new_record := false
var speed_mult := 1.0

# --- reinforcements ---------------------------------------------------------
# A level ships its balls in two batches: the opening layout and the waves that
# drop in while it runs. The rules decide both (`Pang.level_data`), the screen
# only counts down to the next one and puts it on the board.
#
# A wave is announced before it lands: `Pang.wave_stage` runs the timeline
# silent → announced → falling, and the screen draws the flank the batch will
# arrive over plus a countdown. The only piece of state it owns is `wave_warned`
# — how long the warning has been running, `-1.0` while the wave is silent.

var waves: Array = []
var waves_left := 0
var wave_index := 0
var waves_total := 0
var wave_clock := 0.0
## Warning clock of the wave in `wave_index`; `-1.0` means "not announced yet".
var wave_warned := -1.0
var layout_total := 0

var player_x := 0.0
var player_facing := 1.0
var walk_phase := 0.0
var invuln := 0.0
var respawn := 0.0
var shake := 0.0
var shoot_cd := 0.0
var separate_tick := 0

# --- bonus effects ----------------------------------------------------------

var harpoons_extra := 0
var active_harpoons := 0
var freeze := 0.0

# --- pools ------------------------------------------------------------------
# Every entry is a mutable Dictionary that is reused for the whole run, so the
# per-frame loop never allocates.

var orbs: Array[Dictionary] = []
var harpoons: Array[Dictionary] = []
var obstacles: Array[Dictionary] = []
var pickups: Array[Dictionary] = []
var labels: Array[Dictionary] = []
var orb_nodes: Array[Node3D] = []

var arena: Node3D
var player: Node3D
var player_mesh: Node3D
var particles: MultiMeshInstance3D
## Free-list of particle slots, used as a LIFO stack so a burst never allocates.
var particle_stack: Array[int] = []
var particle_life := PackedFloat32Array()
var particle_pos := PackedVector3Array()
var particle_vel := PackedVector3Array()

var _stick: VirtualStick
var _score_label: Label
var _time_bar: ProgressBar
var _level_label: Label
var _lives_label: Label
var _balls_label: Label
## Last values written to `_balls_label`. Comparing the integers instead of the
## formatted string keeps the label — and the frame loop — free of allocations
## while nothing changes.
var _balls_shown := -1
var _balls_shown_waves := -1
var _hook_label: Label
## The wave warning in the top-left column and the countdown over the arriving
## flank. Both are formatted only when this step moves on, so the frame loop
## writes no text while the wave creeps.
var _alert_label: Label
## Tenths of a second since the last rebuild of both warning texts; `-1` means
## "no wave is announced".
var _alert_step := -1
## The flank marker of the arriving wave: a painted strip on the floor, the
## countdown above it and the tint on the knight.
var _wave_band: MeshInstance3D
var _wave_band_material: StandardMaterial3D
var _wave_count: Label3D
var _player_alert := false
var _effect_box: VBoxContainer
var _overlay: Control
var _pause_held := false


func _ready_world() -> void:
	# `data` is the router payload the base class already filled in.
	level = maxi(1, int(data.get("level", 1)))
	_setup_theme()
	_build_arena()
	_build_scenery()
	_build_player()
	_build_pools()
	_build_wave_marker()
	_build_particles()
	_build_ui()
	_start_level()

	get_viewport().size_changed.connect(_fit_camera)
	_fit_camera.call_deferred()
	hide_loading()


## Reached when the router hands over a level; `_ready_world` already guessed,
## so only a real change restarts.
func _on_data(payload: Dictionary) -> void:
	var wanted := maxi(1, int(payload.get("level", 1)))
	if wanted != level:
		level = wanted
		_goto_level(wanted)


# --- stage ------------------------------------------------------------------

func _setup_theme() -> void:
	var look := THEMES[theme_index]
	set_fog(Color(str(look["fog"])), 0.010)
	set_ambient(Color(str(look["ambient"])), 0.75)
	sun.light_color = Color(str(look["sun"]))
	sun.light_energy = 1.15
	fill.light_color = Color(str(look["fill"]))
	fill.light_energy = 0.42
	camera.fov = 52.0
	camera.far = 260.0


func _build_arena() -> void:
	if arena != null and is_instance_valid(arena):
		arena.queue_free()
	arena = Node3D.new()
	add_child(arena)

	var look := THEMES[theme_index]
	var width := Pang.ARENA_HALF_WIDTH * 2.0
	var height := Pang.CEILING_Y + 2.0

	# A darker apron behind the walkable strip seats the stage in its world.
	_arena_box("Apron", Vector3(width + 8.0, 0.4, 9.0), Vector3(0.0, -0.22, -0.4), Color(str(look["floor"])).darkened(0.35))
	_arena_box("Floor", Vector3(width, 0.24, 4.4), Vector3(0.0, -0.12, PLAYER_Z - 1.0), Color(str(look["floor"])))

	# The back wall is a row of offset panels rather than one quad, so it catches
	# the light unevenly and the stage has some relief.
	var panels := 9
	var step: float = width / float(panels)
	for i in panels:
		_arena_box(
			"Wall%d" % i,
			Vector3(step - 0.12, height, 0.5),
			Vector3(-Pang.ARENA_HALF_WIDTH + (float(i) + 0.5) * step, height * 0.5 - 0.5, WALL_Z),
			Color(str(look["wall"])).lightened(0.03 * float(i % 3))
		)

	for side in [-1.0, 1.0]:
		_arena_box(
			"Side%d" % int(side),
			Vector3(0.6, height, 7.0),
			Vector3(side * (Pang.ARENA_HALF_WIDTH + 0.3), height * 0.5 - 0.5, 0.0),
			Color(str(look["wall"])).darkened(0.25)
		)

	# The ceiling girder is what the harpoon bites into.
	_arena_box("Girder", Vector3(width, 0.5, 0.7), Vector3(0.0, Pang.CEILING_Y + 0.25, ORB_Z), Color(str(look["wall"])).darkened(0.15))
	# Foreground lip: a dark band along the bottom of the frame.
	_arena_box("Lip", Vector3(width + 6.0, 1.4, 1.0), Vector3(0.0, -0.8, FRONT_Z), Color(0.02, 0.03, 0.05))


func _arena_box(node_name: String, size: Vector3, position: Vector3, color: Color) -> void:
	var node := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	node.mesh = mesh
	node.material_override = WorldScreen.standard_material(color)
	node.position = position
	arena.add_child(node)


func _build_scenery() -> void:
	for entry in SCENERY:
		for i in int(entry["count"]):
			var node := WorldScreen.mesh(str(entry["key"]), Color(str(entry["tint"])), randf_range(float(entry["min"]), float(entry["max"])))
			if node == null:
				continue
			var spread := Pang.ARENA_HALF_WIDTH + 1.5
			node.position = Vector3(
				randf_range(-spread, spread),
				randf_range(-0.3, 0.7),
				float(entry["z"]) + randf_range(-0.3, 0.3)
			)
			node.rotation.y = randf() * TAU
			add_child(node)


func _build_player() -> void:
	player = Node3D.new()
	add_child(player)

	player_mesh = WorldScreen.mesh("rpg/knight", PLAYER_TINT, 0.95)
	if player_mesh == null:
		var box := MeshInstance3D.new()
		var box_mesh := BoxMesh.new()
		box_mesh.size = Vector3(0.7, 1.7, 0.7)
		box.mesh = box_mesh
		box.material_override = WorldScreen.standard_material(Color("cbd5e1"))
		box.position.y = 0.85
		player_mesh = box
	player.add_child(player_mesh)
	player.position = Vector3(0.0, 0.0, PLAYER_Z)


# --- pools ------------------------------------------------------------------

func _build_pools() -> void:
	for i in ORB_LIMIT:
		orbs.append({
			"node": null, "active": false, "x": 0.0, "y": 0.0, "vx": 0.0, "vy": 0.0,
			"size": 3, "flash": 0.0, "arm": 0.0, "blink": false,
		})
		orb_nodes.append(_orb_node())

	for i in HARPOON_LIMIT:
		harpoons.append({
			"node": _harpoon_node(), "rope": _rope_node(), "active": false,
			"x": 0.0, "y": 0.0, "extending": true, "hold": 0.0, "obstacle": "", "target": null,
		})
	for i in OBSTACLE_LIMIT:
		obstacles.append({"node": null, "active": false, "x": 0.0, "y": 0.0, "kind": "", "hp": 0, "flash": 0.0})
	for i in PICKUP_LIMIT:
		pickups.append({"node": null, "active": false, "x": 0.0, "y": 0.0, "vy": 0.0, "id": ""})
	for i in LABEL_LIMIT:
		labels.append({"node": _label_node(), "active": false, "life": 0.0, "y": 0.0})


func _orb_node() -> Node3D:
	var node := WorldScreen.mesh("pang/orb", Pang.size_spec(Pang.SIZE_LARGEST)["color"], 1.0)
	if node == null:
		var ball := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 1.0
		sphere.height = 2.0
		sphere.radial_segments = 14
		sphere.rings = 7
		ball.mesh = sphere
		ball.material_override = _bubble_material(Pang.size_spec(Pang.SIZE_LARGEST)["color"])
		node = ball
	node.visible = false
	node.position.z = ORB_Z
	add_child(node)
	return node


func _harpoon_node() -> Node3D:
	var node := WorldScreen.mesh("pang/harpoon", Color("e2e8f0"), 0.9)
	if node == null:
		node = Node3D.new()
		var shaft := MeshInstance3D.new()
		var shaft_mesh := CylinderMesh.new()
		shaft_mesh.top_radius = 0.04
		shaft_mesh.bottom_radius = 0.06
		shaft_mesh.height = 1.6
		shaft_mesh.radial_segments = 6
		shaft.mesh = shaft_mesh
		shaft.material_override = WorldScreen.standard_material(Color("e2e8f0"))
		shaft.position.y = 0.9
		node.add_child(shaft)
	node.visible = false
	node.position.z = HARPOON_Z
	add_child(node)
	return node


func _rope_node() -> MeshInstance3D:
	var rope := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.035
	mesh.bottom_radius = 0.035
	mesh.height = 1.0
	mesh.radial_segments = 5
	rope.mesh = mesh
	rope.material_override = WorldScreen.standard_material(Color("c8d3e0"))
	rope.visible = false
	rope.position.z = HARPOON_Z
	add_child(rope)
	return rope


## `fixed_size` keeps a score number the same size on screen no matter how far
## the camera is, so the size is chosen for the arena framing and not scaled up.
func _label_node() -> Label3D:
	var label := Label3D.new()
	label.font = Ui.font_bold()
	label.font_size = 34
	label.pixel_size = 0.005
	label.outline_size = 10
	label.outline_modulate = Color(0.02, 0.03, 0.06, 0.9)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.fixed_size = true
	label.outline_render_priority = 1
	label.visible = false
	add_child(label)
	return label


func _bubble_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.22
	material.metallic = 0.2
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 0.3
	return material


## The two nodes the wave warning owns: a strip on the floor that covers the
## flank the batch is about to fall over, and the countdown floating above it.
## Both are built once and hidden between waves — the warning is a pulse, not a
## permanent piece of furniture.
func _build_wave_marker() -> void:
	_wave_band = MeshInstance3D.new()
	var strip := BoxMesh.new()
	strip.size = Vector3(1.0, 0.16, 2.6)
	_wave_band.mesh = strip
	_wave_band_material = StandardMaterial3D.new()
	_wave_band_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_wave_band_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_wave_band_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_wave_band_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_wave_band.material_override = _wave_band_material
	_wave_band.visible = false
	_wave_band.position.z = PLAYER_Z - 0.3
	add_child(_wave_band)

	_wave_count = Label3D.new()
	_wave_count.font = Ui.font_bold()
	_wave_count.font_size = 40
	_wave_count.pixel_size = 0.0055
	_wave_count.outline_size = 12
	_wave_count.outline_modulate = Color(0.02, 0.03, 0.06, 0.9)
	_wave_count.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_wave_count.no_depth_test = true
	_wave_count.fixed_size = true
	_wave_count.modulate = WAVE_ALERT
	_wave_count.position.z = ORB_Z + 0.8
	_wave_count.visible = false
	add_child(_wave_count)


func _spark_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.disable_receive_shadows = true
	return material


func _build_particles() -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(0.24, 0.24)
	particles = MultiMeshInstance3D.new()
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.use_colors = true
	multi.mesh = quad
	multi.instance_count = PARTICLE_COUNT
	multi.visible_instance_count = 0
	particles.multimesh = multi
	particles.material_override = _spark_material()
	add_child(particles)

	particle_stack.resize(PARTICLE_COUNT)
	particle_life.resize(PARTICLE_COUNT)
	particle_pos.resize(PARTICLE_COUNT)
	particle_vel.resize(PARTICLE_COUNT)
	# Reversed, so popping hands out 0, 1, 2 … and the visuals stay in order.
	for i in PARTICLE_COUNT:
		particle_stack[i] = PARTICLE_COUNT - 1 - i


# --- HUD --------------------------------------------------------------------

func _build_ui() -> void:
	_stick = add_stick("bottom_left", "")
	add_action_button("⇈", 72.0, "fire")

	var column := VBoxContainer.new()
	column.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	column.position = Vector2(20, 74)
	column.custom_minimum_size = Vector2(300, 0)
	column.add_theme_constant_override("separation", 2)
	hud_root.add_child(column)
	column.add_child(Ui.label("⇈  PANG 3D", 22, UiTheme.TEXT, true))
	_level_label = _value(column, "Level", "1", Color("38bdf8"))
	_score_label = _value(column, "Punkte", "0", Color("facc15"))
	_lives_label = _value(column, "Leben", "3", Color("f87171"))
	_balls_label = _value(column, "Kugeln", "0", Color("a3e635"))
	_hook_label = _value(column, "Haken", "0/1", Color("e2e8f0"))
	# The wave warning sits under the counters: it is the only line in the HUD
	# that changes on its own, and it changes only while a wave is announced.
	_alert_label = Ui.label("", 15, WAVE_ALERT, true)
	column.add_child(_alert_label)

	_time_bar = Ui.bar(Color("38bdf8"), 14.0)
	_time_bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_time_bar.offset_left = -300.0
	_time_bar.offset_right = -18.0
	_time_bar.offset_top = 74.0
	hud_root.add_child(_time_bar)

	var pause := Ui.button("‖ Pause", Vector2(104, 40), UiTheme.PANEL_LIGHT, func() -> void: _toggle_pause())
	pause.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	pause.offset_left = -122.0
	pause.offset_right = -18.0
	pause.offset_top = 96.0
	hud_root.add_child(pause)

	_effect_box = VBoxContainer.new()
	_effect_box.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_effect_box.position = Vector2(28, -238)
	_effect_box.custom_minimum_size = Vector2(250, 0)
	_effect_box.add_theme_constant_override("separation", 2)
	hud_root.add_child(_effect_box)

	var hint := Ui.label("Stick or ◀ ▶ to run · ⇈ hook · ‖ pause", 15, UiTheme.TEXT_DIM)
	hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	hint.position = Vector2(0, -172)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud_root.add_child(hint)

	# The two-shot trick is the one rule a newcomer cannot guess, so it is said
	# out loud on the floor of the screen.
	var trick := Ui.label(Pang.ARM_HINT, 14, Color("f8fafc"))
	trick.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	trick.position = Vector2(0, -146)
	trick.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud_root.add_child(trick)


func _value(parent: VBoxContainer, caption: String, value: String, color: Color) -> Label:
	var row := Ui.hbox(10)
	parent.add_child(row)
	row.add_child(Ui.label(caption, 15, UiTheme.TEXT_DIM))
	var spacer := Ui.spacer()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	var result := Ui.label(value, 19, color, true)
	row.add_child(result)
	return result


func _effect_chip(text: String, color: Color, seconds: float) -> void:
	var label := Ui.label(text, 16, color, true)
	_effect_box.add_child(label)
	var tween := label.create_tween()
	tween.tween_interval(seconds)
	tween.tween_property(label, "modulate:a", 0.0, 0.4)
	tween.tween_callback(label.queue_free)


# --- level lifecycle --------------------------------------------------------

func _start_level() -> void:
	_release_all()
	# The layout is regenerated here, so a retry and a fresh start always agree
	# and `Pang` stays the single source of truth for the level contents.
	layout = Pang.level_data(level)
	speed_mult = float(layout.get("speedMult", 1.0))
	time_left = float(layout["timeLimit"])
	best_time = Pang.level_best_time(level)
	# Both counts walk the whole layout, so they are read once here instead of
	# in the frame loop.
	waves = layout.get("waves", [])
	waves_total = waves.size()
	waves_left = waves_total
	wave_index = 0
	wave_clock = 0.0
	wave_warned = -1.0
	layout_total = Pang.total_balls(layout)
	score = 0
	balls_popped = 0
	run_time = 0.0
	player_x = 0.0
	player.position.x = 0.0
	invuln = Pang.START_GRACE
	respawn = 0.0
	shake = 0.0
	shoot_cd = 0.0
	lives = Pang.LIVES
	freeze = 0.0
	harpoons_extra = 0
	active_harpoons = 0
	state = STATE_PLAYING
	_close_overlay()

	for ball in layout["balls"]:
		_spawn_ball(float(ball["x"]), float(ball["y"]), int(ball["size"]))
	for entry in layout["obstacles"]:
		_spawn_obstacle(str(entry["kind"]), float(entry["x"]), float(entry["y"]))


## Returns every pooled node to its parked state and drops the ones that were
## built for a previous level.
func _release_all() -> void:
	for orb in orbs:
		orb["active"] = false
		orb["node"] = null
	for node in orb_nodes:
		node.visible = false
	for slot in harpoons:
		slot["active"] = false
		slot["target"] = null
		slot["node"].visible = false
		slot["rope"].visible = false
	for slot in obstacles:
		_drop_node(slot)
	for slot in pickups:
		_drop_node(slot)
	for slot in labels:
		slot["active"] = false
		slot["node"].visible = false
	balls_left = 0
	active_harpoons = 0
	_hide_wave_marker()
	for child in _effect_box.get_children():
		child.queue_free()


func _drop_node(slot: Dictionary) -> void:
	slot["active"] = false
	var node: Variant = slot["node"]
	if node != null and is_instance_valid(node):
		node.queue_free()
	slot["node"] = null


# --- spawning ---------------------------------------------------------------

func _spawn_ball(x: float, y: float, size: int) -> Dictionary:
	var slot := _free_slot(orbs)
	if slot.is_empty():
		return {}
	var node := _acquire_node()
	if node == null:
		return {}
	slot["node"] = node
	slot["active"] = true
	slot["x"] = x
	slot["y"] = y
	slot["size"] = size
	slot["flash"] = 0.0
	slot["arm"] = 0.0
	slot["blink"] = false
	slot["vx"] = (1.0 if randf() < 0.5 else -1.0) * Pang.speed_of(size) * speed_mult
	slot["vy"] = -Pang.jump_velocity(size) * 0.8
	# One mesh serves all four sizes, so the colour has to follow the level.
	WorldScreen.tint(node, Pang.size_spec(size)["color"])
	node.visible = true
	node.scale = Vector3.ONE * Pang.radius_of(size)
	balls_left += 1
	return slot


func _acquire_node() -> Node3D:
	for node in orb_nodes:
		if not node.visible:
			return node
	return null


func _spawn_obstacle(kind: String, x: float, y: float) -> void:
	var slot := _free_slot(obstacles)
	if slot.is_empty():
		return
	var spec := Pang.obstacle_spec(kind)
	var node := WorldScreen.mesh(str(spec["asset"]), Color("d6c39a"), float(spec["scale"]))
	if node == null:
		var box := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(float(spec["halfWidth"]) * 2.0, float(spec["halfHeight"]) * 2.0, float(spec["halfDepth"]) * 2.0)
		box.mesh = mesh
		box.material_override = WorldScreen.standard_material(Color("a3763f"))
		node = box
	# Obstacles sit behind the play plane so they never hide a ball.
	node.position = Vector3(x, y, OBSTACLE_Z)
	node.rotation.y = randf_range(-0.2, 0.2)
	node.visible = true
	add_child(node)
	slot["node"] = node
	slot["active"] = true
	slot["x"] = x
	slot["y"] = y
	slot["kind"] = kind
	slot["hp"] = int(spec["hp"])
	slot["flash"] = 0.0


func _spawn_pickup(id: String, x: float, y: float) -> void:
	var slot := _free_slot(pickups)
	if slot.is_empty():
		return
	var spec := Pang.bonus_by_id(id)
	var node := WorldScreen.mesh(str(spec["asset"]), spec["color"], 0.8, 0.3)
	if node == null:
		var box := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(0.55, 0.55, 0.55)
		box.mesh = mesh
		box.material_override = WorldScreen.standard_material(spec["color"], 0.3)
		node = box
	node.position = Vector3(x, y, PLAYER_Z - 0.4)
	node.visible = true
	add_child(node)
	slot["node"] = node
	slot["active"] = true
	slot["x"] = x
	slot["y"] = y
	slot["vy"] = 0.0
	slot["id"] = id


func _free_slot(pool: Array[Dictionary]) -> Dictionary:
	for entry in pool:
		if not bool(entry["active"]):
			return entry
	return {}


# --- loop -------------------------------------------------------------------

func _update_world(delta: float) -> void:
	if state == STATE_PAUSED:
		return
	var dt: float = minf(delta, 0.05)
	run_time += dt
	_tick_timers(dt)

	if state == STATE_PLAYING:
		_tick_countdown(dt)
		_tick_waves(dt)
		_tick_input()
		_tick_player(dt)
		_tick_balls(dt)
		_tick_harpoons(dt)
		_tick_pickups(dt)
		_check_player_hit()
		_check_cleared()
	else:
		# Let the balls keep drifting behind the overlay instead of freezing
		# mid-air, which looks like a crash rather than a pause.
		_tick_balls(dt * 0.3)
		# A pending wave no longer counts down while the level is over, and its
		# band must not glow through the overlay.
		_hide_wave_marker()

	_tick_particles(dt)
	_tick_labels(dt)
	_tick_camera(dt)
	_sync_hud()


func _tick_timers(dt: float) -> void:
	invuln = maxf(0.0, invuln - dt)
	shoot_cd = maxf(0.0, shoot_cd - dt)
	shake = maxf(0.0, shake - dt * 2.4)
	freeze = maxf(0.0, freeze - dt)
	respawn = maxf(0.0, respawn - dt)
	for slot in obstacles:
		if bool(slot["active"]):
			slot["flash"] = maxf(0.0, float(slot["flash"]) - dt)


func _tick_countdown(dt: float) -> void:
	# A frozen clock is part of the bonus, so the countdown waits it out.
	if freeze > 0.0:
		return
	time_left = maxf(0.0, time_left - dt)
	if time_left <= 0.0:
		_lose("Die Zeit ist um")


## The reinforcement, in three stages. `Pang.wave_stage` owns the whole
## timeline — a due wave is announced, the warning runs its course, and only
## then does the batch fall — so this function only keeps the one number the
## rules cannot keep themselves, `wave_warned`, and puts the batch on the board
## when the rules say it is due.
func _tick_waves(dt: float) -> void:
	if waves_left <= 0:
		_hide_wave_marker()
		return
	# A frozen level waits for the reinforcements too, otherwise they would drop
	# into a board that is standing still.
	if not Pang.is_frozen(freeze):
		wave_clock += dt
		if wave_warned >= 0.0:
			wave_warned += dt
	match Pang.wave_stage(waves[wave_index], balls_left, wave_clock, wave_warned):
		Pang.WAVE_PENDING:
			pass
		Pang.WAVE_WARNING:
			_announce_wave()
		Pang.WAVE_FALLING:
			_drop_wave()
			return
	_update_wave_marker()


## The frame the wave becomes visible. The arrival turns from an interruption
## into a decision here: the flank lights up, a countdown starts, the knight
## warns while it stands in the band — and the clock keeps running, so the
## player pays for looking for a safe side.
func _announce_wave() -> void:
	if wave_warned >= 0.0:
		return
	wave_warned = 0.0
	var wave: Dictionary = waves[wave_index]
	# A falling alarm tone. None of the named effects means "something is
	# about to arrive above you", and this one cannot be mistaken for a shot.
	Sfx.tone(760.0, 0.12, "square", -22.0, 240.0)
	notify(Loc.f("Reinforcements are coming — %s!", [Pang.wave_side_label(wave)]), 2.0)


## Puts the announced batch on the board and hands the arena back to the player.
func _drop_wave() -> void:
	var wave: Dictionary = waves[wave_index]
	var batch: Array = wave.get("balls", [])
	for ball in batch:
		_spawn_ball(float(ball["x"]), float(ball["y"]), int(ball["size"]))
	wave_index += 1
	waves_left -= 1
	wave_clock = 0.0
	wave_warned = -1.0
	_hide_wave_marker()
	# The arrival is the one moment the level interrupts itself, so it says so —
	# on screen, in the corner list and through the floor.
	notify(Loc.f("Reinforcements: %d balls from %s", [batch.size(), Pang.wave_side_label(wave)]), 2.0)
	_effect_chip("☄  Nachschub!  %s" % ("Noch " + Pang.wave_label(waves_left) if waves_left > 0 else "Letzte Welle"), WAVE_ALERT, 2.4)
	Sfx.tone(520.0, 0.18, "saw", -20.0, 160.0)
	shake = maxf(shake, 0.18)


## Paints the flank the batch will arrive over, the countdown above it and the
## warning on the knight. All three read the same `wave_progress`, so "how long
## have I got" has one answer on the screen as well as in the rules.
func _update_wave_marker() -> void:
	if wave_warned < 0.0:
		_hide_wave_marker()
		return
	var wave: Dictionary = waves[wave_index]
	var progress := Pang.wave_progress(wave, wave_warned)
	var band := Pang.wave_band(wave)
	# The strip widens as the wave gets closer, so the floor itself carries the
	# countdown and not just the number floating over it.
	var half: float = (band.y - band.x) * 0.5 + progress * Pang.WAVE_BAND_GROW
	var centre: float = (band.x + band.y) * 0.5
	_wave_band.visible = true
	_wave_band.position = Vector3(centre, Pang.FLOOR_Y + 0.08, PLAYER_Z - 0.3)
	_wave_band.scale = Vector3(maxf(0.1, half * 2.0), 1.0, 1.0)
	_wave_band_material.albedo_color = Color(WAVE_ALERT.r, WAVE_ALERT.g, WAVE_ALERT.b, 0.16 + 0.34 * progress)
	_wave_count.visible = true
	_wave_count.position = Vector3(centre, Pang.FLOOR_Y + 4.6, ORB_Z + 0.8)
	# Both texts are built in the rules, so the copy and the arrival cannot drift
	# apart — and they are only formatted when a tenth of a second has passed, so
	# the frame loop allocates nothing while the wave creeps.
	var step := int(progress * 20.0)
	if step != _alert_step:
		_alert_step = step
		_wave_count.text = "%.1f" % maxf(0.0, Pang.wave_eta(wave, balls_left, wave_clock, wave_warned))
		_wave_count.modulate.a = 0.55 + 0.45 * progress
		_alert_label.text = Pang.wave_alert(wave, wave_warned)
	# The knight warns while it stands in the band, which is the decision the
	# whole warning exists for: leave the flank, or clear fast and eat the drop.
	var inside := Pang.in_wave_band(wave, player_x)
	if inside != _player_alert:
		_player_alert = inside
		_tint_player(WAVE_ALERT if inside else PLAYER_TINT, 0.5 if inside else 0.0)


## `WorldScreen.tint` only walks the children, so a mesh that *is* the root — the
## procedural fallback knight, when the import is missing — has to be tinted by
## hand. Without this the warning would be invisible on exactly the devices that
## got no knight mesh.
func _tint_player(color: Color, emission: float) -> void:
	if player_mesh is GeometryInstance3D:
		(player_mesh as GeometryInstance3D).material_override = WorldScreen.standard_material(color, emission)
	WorldScreen.tint(player_mesh, color, emission)


func _hide_wave_marker() -> void:
	if _wave_band != null:
		_wave_band.visible = false
	if _wave_count != null:
		_wave_count.visible = false
	if _alert_step != -1:
		_alert_step = -1
		if _alert_label != null:
			_alert_label.text = ""
	if _player_alert:
		_player_alert = false
		_tint_player(PLAYER_TINT, 0.0)


func _tick_input() -> void:
	var axis := VirtualStick.combined(_stick.value, &"move_left", &"move_right").x
	if absf(axis) > 0.05:
		player_x = clampf(
			player_x + axis * Pang.PLAYER_MOVE_SPEED * 0.0166,
			-Pang.ARENA_HALF_WIDTH + Pang.PLAYER_HALF_WIDTH,
			Pang.ARENA_HALF_WIDTH - Pang.PLAYER_HALF_WIDTH
		)
		player_facing = signf(axis)
		walk_phase += 0.15

	if Input.is_action_just_pressed("fire"):
		_shoot()
	# Edge-detect the pause key so holding it does not toggle every frame.
	var held := Input.is_action_pressed("pause")
	if held and not _pause_held:
		_toggle_pause()
	_pause_held = held


func _tick_player(dt: float) -> void:
	player.position.x = player_x
	player.visible = respawn <= 0.0
	player_mesh.position.y = absf(sin(walk_phase)) * 0.09
	player_mesh.visible = not (invuln > 0.0 and respawn <= 0.0 and fmod(invuln, 0.18) <= 0.09)
	player.rotation.y = lerp_angle(player.rotation.y, -player_facing * 0.5, clampf(dt * 10.0, 0.0, 1.0))


func _tick_balls(dt: float) -> void:
	var frozen := Pang.is_frozen(freeze)
	for orb in orbs:
		if not bool(orb["active"]):
			continue
		var radius := Pang.radius_of(int(orb["size"]))
		if not frozen:
			# Horizontal speed is re-imposed every frame: a ricochet off an
			# obstacle or another ball must never slow a ball down.
			orb["vy"] = float(orb["vy"]) + Pang.GRAVITY * dt
			orb["vx"] = signf(float(orb["vx"])) * absf(float(orb["vx"]))
			orb["x"] = float(orb["x"]) + float(orb["vx"]) * dt
			orb["y"] = float(orb["y"]) + float(orb["vy"]) * dt

			if float(orb["x"]) - radius < -Pang.ARENA_HALF_WIDTH:
				orb["x"] = -Pang.ARENA_HALF_WIDTH + radius
				orb["vx"] = absf(float(orb["vx"]))
			elif float(orb["x"]) + radius > Pang.ARENA_HALF_WIDTH:
				orb["x"] = Pang.ARENA_HALF_WIDTH - radius
				orb["vx"] = -absf(float(orb["vx"]))

			var floor_y: float = Pang.FLOOR_Y + radius
			if float(orb["y"]) >= floor_y:
				orb["y"] = floor_y
				orb["vy"] = -Pang.jump_velocity(int(orb["size"]))
			elif float(orb["y"]) - radius <= Pang.CEILING_Y:
				orb["y"] = Pang.CEILING_Y + radius
				orb["vy"] = absf(float(orb["vy"]))

			_bounce_off_obstacles(orb, radius)

		# An armed ball recovers on its own once the window is over: the bonus
		# is a chance, not a promise.
		if float(orb["arm"]) > 0.0:
			orb["arm"] = float(orb["arm"]) - dt
			if float(orb["arm"]) <= 0.0:
				_disarm(orb)

		# Roll the ball in the direction it travels, so it reads as a bouncing
		# ball rather than a sliding circle.
		var spin := -float(orb["x"]) / maxf(radius, 0.05)
		var node: Node3D = orb["node"]
		node.position = Vector3(float(orb["x"]), float(orb["y"]), ORB_Z)
		node.rotation = Vector3(spin * 0.35, spin, 0.0)
		orb["flash"] = maxf(0.0, float(orb["flash"]) - dt)
		node.scale = Vector3.ONE * radius * (1.0 + float(orb["flash"]) * 0.4)
		_sync_orb_tint(orb, node)

	# The separation pass is O(n²); running it every third frame is visually
	# identical and keeps the frame budget for rendering.
	separate_tick += 1
	if separate_tick >= 3:
		separate_tick = 0
		_separate_balls()


## The armed tell: the ball flashes bright, and the second hit kills it. The
## material is only rebuilt when the blink actually flips, so the frame loop
## never allocates one.
func _sync_orb_tint(orb: Dictionary, node: Node3D) -> void:
	var blink := float(orb["arm"]) > 0.0 and Pang.is_blinking(run_time)
	if blink == bool(orb["blink"]):
		return
	orb["blink"] = blink
	WorldScreen.tint(node, Pang.ARM_TINT if blink else Color(Pang.size_spec(int(orb["size"]))["color"]))


## Restores a ball's normal pace. The speed is taken from the rules rather than
## multiplied back up, so a ball can never end up faster than a fresh one.
func _disarm(orb: Dictionary) -> void:
	orb["arm"] = 0.0
	orb["blink"] = false
	orb["vx"] = signf(float(orb["vx"])) * Pang.speed_of(int(orb["size"])) * speed_mult


## Pushes overlapping balls apart and swaps their horizontal direction, which is
## what makes a fresh cluster fan out instead of stacking into a column.
func _separate_balls() -> void:
	for i in orbs.size():
		var a: Dictionary = orbs[i]
		if not bool(a["active"]):
			continue
		var ra := Pang.radius_of(int(a["size"]))
		for j in range(i + 1, orbs.size()):
			var b: Dictionary = orbs[j]
			if not bool(b["active"]):
				continue
			var reach: float = ra + Pang.radius_of(int(b["size"]))
			var dx: float = float(b["x"]) - float(a["x"])
			if absf(dx) >= reach:
				continue
			var dy: float = float(b["y"]) - float(a["y"])
			var distance_sq: float = dx * dx + dy * dy
			if distance_sq >= reach * reach or distance_sq < 0.0001:
				continue
			var distance := sqrt(distance_sq)
			var push: float = (reach - distance) * 0.5
			var nx := dx / distance
			var ny := dy / distance
			a["x"] = float(a["x"]) - nx * push
			a["y"] = float(a["y"]) - ny * push
			b["x"] = float(b["x"]) + nx * push
			b["y"] = float(b["y"]) + ny * push
			# The heavier ball keeps its heading, the lighter one takes the bounce.
			if ra >= float(b["size"]):
				a["vx"] = -float(a["vx"])
			else:
				b["vx"] = -float(b["vx"])


func _bounce_off_obstacles(orb: Dictionary, radius: float) -> void:
	for slot in obstacles:
		if not bool(slot["active"]):
			continue
		var spec := Pang.obstacle_spec(str(slot["kind"]))
		if not bool(spec["bounces"]):
			continue
		var hw: float = float(spec["halfWidth"])
		var hh: float = float(spec["halfHeight"])
		var cx: float = clampf(float(orb["x"]), float(slot["x"]) - hw, float(slot["x"]) + hw)
		var cy: float = clampf(float(orb["y"]), float(slot["y"]) - hh, float(slot["y"]) + hh)
		var dx: float = float(orb["x"]) - cx
		var dy: float = float(orb["y"]) - cy
		var distance_sq: float = dx * dx + dy * dy
		if distance_sq >= radius * radius:
			continue
		var distance := sqrt(maxf(distance_sq, 0.0001))
		var nx := dx / distance
		var ny := dy / distance
		if distance_sq < 0.0001:
			# Dead centre of a slab: straight up is the safest way out.
			nx = 0.0
			ny = 1.0
		orb["x"] = cx + nx * radius
		orb["y"] = cy + ny * radius
		var along: float = float(orb["vx"]) * nx + float(orb["vy"]) * ny
		if along < 0.0:
			orb["vx"] = float(orb["vx"]) - 2.0 * along * nx
			orb["vy"] = float(orb["vy"]) - 2.0 * along * ny
		slot["flash"] = 0.18


# --- shooting ---------------------------------------------------------------

func _shoot() -> void:
	if shoot_cd > 0.0 or state != STATE_PLAYING:
		return
	if active_harpoons >= Pang.max_harpoons(harpoons_extra):
		return
	var free := HARPOON_LIMIT - active_harpoons
	for i in maxi(1, mini(Pang.max_harpoons(harpoons_extra), free)):
		_fire_harpoon(float(i) * 0.9 - (float(maxi(1, free)) - 1.0) * 0.45)
	shoot_cd = Pang.HARPOON_COOLDOWN
	Sfx.shoot()


func _fire_harpoon(offset_x: float) -> void:
	var slot := _free_slot(harpoons)
	if slot.is_empty():
		return
	var x: float = clampf(player_x + offset_x, -Pang.ARENA_HALF_WIDTH + 0.2, Pang.ARENA_HALF_WIDTH - 0.2)
	slot["active"] = true
	slot["x"] = x
	slot["y"] = Pang.PLAYER_TOP_Y
	slot["extending"] = true
	slot["hold"] = 0.0
	slot["obstacle"] = ""
	slot["target"] = null
	var node: Node3D = slot["node"]
	node.visible = true
	node.position = Vector3(x, float(slot["y"]), HARPOON_Z)
	active_harpoons += 1


func _tick_harpoons(dt: float) -> void:
	for slot in harpoons:
		if not bool(slot["active"]):
			continue
		var node: Node3D = slot["node"]
		var rope: MeshInstance3D = slot["rope"]
		if bool(slot["extending"]):
			slot["y"] = float(slot["y"]) + Pang.HARPOON_SPEED * dt
			if _harpoon_hits_ball(slot):
				_pop_ball(slot)
				_retire_harpoon(slot)
				continue
			if _harpoon_hits_obstacle(slot):
				var spec := Pang.obstacle_spec(str(slot["obstacle"]))
				if bool(spec["blocks"]):
					# A fixed platform swallows the harpoon instead of breaking.
					slot["extending"] = false
					slot["hold"] = Pang.HARPOON_HOLD_TIME
				else:
					_damage_obstacle(slot)
					_retire_harpoon(slot)
					continue
			var stop: float = _harpoon_stop(float(slot["y"]))
			if float(slot["y"]) >= stop:
				slot["y"] = stop
				slot["extending"] = false
				slot["hold"] = Pang.HARPOON_HOLD_TIME
		else:
			slot["hold"] = float(slot["hold"]) - dt
			if float(slot["hold"]) <= 0.0:
				_retire_harpoon(slot)
				continue
		node.position = Vector3(float(slot["x"]), float(slot["y"]), HARPOON_Z)
		rope.visible = true
		rope.position = Vector3(float(slot["x"]), (Pang.PLAYER_TOP_Y + float(slot["y"])) * 0.5, HARPOON_Z)
		rope.scale = Vector3(1.0, maxf(0.01, float(slot["y"]) - Pang.PLAYER_TOP_Y), 1.0)


## The lowest blocking surface still above the harpoon: the ceiling girder or the
## underside of a platform, whichever comes first.
func _harpoon_stop(y: float) -> float:
	var stop: float = Pang.CEILING_Y
	for slot in obstacles:
		if not bool(slot["active"]):
			continue
		var spec := Pang.obstacle_spec(str(slot["kind"]))
		if not bool(spec["blocks"]):
			continue
		var top: float = float(slot["y"]) + float(spec["halfHeight"])
		if top >= y and top < stop:
			stop = top
	return stop


func _harpoon_hits_ball(slot: Dictionary) -> bool:
	for orb in orbs:
		if not bool(orb["active"]):
			continue
		var radius := Pang.radius_of(int(orb["size"]))
		if absf(float(orb["x"]) - float(slot["x"])) > radius + Pang.HARPOON_HALF_WIDTH:
			continue
		# The ball has to straddle the tip, not merely be somewhere above it.
		if absf(float(orb["y"]) - float(slot["y"])) <= radius + 0.25:
			slot["target"] = orb
			return true
	return false


func _harpoon_hits_obstacle(slot: Dictionary) -> bool:
	for obstacle in obstacles:
		if not bool(obstacle["active"]):
			continue
		var spec := Pang.obstacle_spec(str(obstacle["kind"]))
		if absf(float(obstacle["x"]) - float(slot["x"])) > float(spec["halfWidth"]):
			continue
		if absf(float(obstacle["y"]) - float(slot["y"])) <= float(spec["halfHeight"]):
			slot["obstacle"] = str(obstacle["kind"])
			slot["target"] = obstacle
			return true
	return false


func _damage_obstacle(slot: Dictionary) -> void:
	var target: Dictionary = slot["target"]
	if target.is_empty() or not bool(target.get("active", false)):
		return
	target["hp"] = int(target["hp"]) - 1
	target["flash"] = 0.25
	Sfx.hit()
	_burst(Vector3(float(target["x"]), float(target["y"]), OBSTACLE_Z), Color("fcd34d"), 8, 3.0)
	if int(target["hp"]) > 0:
		return
	_drop_node(target)
	score += 25
	_burst(Vector3(float(target["x"]), float(target["y"]), OBSTACLE_Z), Color("a3763f"), 22, 5.0)
	_add_label(Vector3(float(target["x"]), float(target["y"]), OBSTACLE_Z + 0.6), "+25", Color("fcd34d"))
	Sfx.kill()


func _retire_harpoon(slot: Dictionary) -> void:
	slot["active"] = false
	slot["extending"] = true
	slot["target"] = null
	slot["obstacle"] = ""
	var node: Node3D = slot["node"]
	node.visible = false
	var rope: MeshInstance3D = slot["rope"]
	rope.visible = false
	active_harpoons = maxi(0, active_harpoons - 1)


# --- popping ----------------------------------------------------------------

func _pop_ball(slot: Dictionary) -> void:
	var target: Dictionary = slot["target"]
	if target.is_empty() or not bool(target.get("active", false)):
		return
	_strike_ball(target)


## One harpoon hit on one ball. Everything above the smallest size splits, the
## smallest size is the two-shot trick: the first hit only arms it, the second
## pops it. `Pang.hit_outcome` decides which, so the rule is testable and this
## file only draws the result.
func _strike_ball(orb: Dictionary) -> void:
	var size := int(orb["size"])
	var armed := float(orb["arm"]) > 0.0
	var outcome := Pang.hit_outcome(size, armed)
	var x := float(orb["x"])
	var y := float(orb["y"])
	var points := Pang.hit_points(size, armed)
	score += points

	if outcome == Pang.HIT_ARM:
		# The two-shot trick: the first harpoon only arms the ball. Nothing is
		# removed and nothing is born, which is the whole point of the move.
		_arm_ball(orb, x, y, points)
		return

	# Both other outcomes take the ball off the board and differ only in what
	# they leave behind. The finish of a pair burns in the tell's colour.
	var color: Color = Pang.ARM_TINT if armed else Pang.size_spec(size)["color"]
	_retire_orb(orb)
	_pop_ball_fx(x, y, color, points)
	balls_popped += 1
	if outcome == Pang.HIT_SPLIT:
		_split_ball(x, y, size)


## Slows a ball down and makes it blink. The pace is applied once, so a bounce
## off a wall or a crate can never compound it.
func _arm_ball(orb: Dictionary, x: float, y: float, points: int) -> void:
	orb["arm"] = Pang.ARM_WINDOW
	orb["vx"] = float(orb["vx"]) * Pang.ARM_SLOWDOWN
	orb["flash"] = 0.25
	_burst(Vector3(x, y, ORB_Z), Pang.ARM_TINT, 10, 3.2)
	_add_label(Vector3(x, y, ORB_Z + 0.6), "1/2 +%d" % points, Pang.ARM_TINT)
	Sfx.hit()
	shake = maxf(shake, 0.06)


## The common part of a kill: burst, label, sound, screen shake and maybe a
## drop. Splitting and the two-shot finish share it so both feel the same.
func _pop_ball_fx(x: float, y: float, color: Color, points: int) -> void:
	_burst(Vector3(x, y, ORB_Z), color, 14, 4.5)
	_add_label(Vector3(x, y, ORB_Z + 0.6), "+%d" % points, color)
	Sfx.kill()
	shake = maxf(shake, 0.12)
	_maybe_drop(x, y)


## The smallest size is the end of the chain; anything bigger becomes two balls
## one size down. This is the whole game in three lines.
func _split_ball(x: float, y: float, size: int) -> void:
	for dir in [-1.0, 1.0]:
		var child := _spawn_ball(x + dir * Pang.radius_of(size) * 0.5, y, size + 1)
		if child.is_empty():
			break
		# A fresh pair starts apart, so it can never re-collide at the seam.
		child["x"] = clampf(float(child["x"]), -Pang.ARENA_HALF_WIDTH + 0.6, Pang.ARENA_HALF_WIDTH - 0.6)


func _retire_orb(orb: Dictionary) -> void:
	var node: Node3D = orb["node"]
	orb["active"] = false
	orb["node"] = null
	if node != null:
		node.visible = false
	balls_left = maxi(0, balls_left - 1)


func _maybe_drop(x: float, y: float) -> void:
	if randf() >= Pang.DROP_CHANCE:
		return
	_spawn_pickup(str(Pang.roll_bonus(randf())["id"]), x, y)


# --- pickups ----------------------------------------------------------------

func _tick_pickups(dt: float) -> void:
	for slot in pickups:
		if not bool(slot["active"]):
			continue
		var node: Node3D = slot["node"]
		# Bonuses sink to the floor and wait there to be walked over, exactly
		# like the original — that is the risk in the last hit of a chain.
		slot["vy"] = minf(float(slot["vy"]) + 14.0 * dt, 9.0)
		slot["y"] = minf(float(slot["y"]) + float(slot["vy"]) * dt, 0.85)
		node.position = Vector3(float(slot["x"]), float(slot["y"]), PLAYER_Z - 0.4)
		node.rotation.y += dt * 2.2
		if absf(float(slot["x"]) - player_x) < Pang.PLAYER_HALF_WIDTH + 0.4 and float(slot["y"]) < 1.5:
			_collect(str(slot["id"]))
			_drop_node(slot)


func _collect(id: String) -> void:
	var spec := Pang.bonus_by_id(id)
	var duration := float(spec["duration"])
	Sfx.coin()
	_effect_chip("%s  %s" % [str(spec["icon"]), str(spec["name"])], spec["color"], maxf(duration, 3.0))
	match id:
		"double_harpoon":
			harpoons_extra = mini(harpoons_extra + 1, Pang.MAX_HARPOONS - 1)
		"freeze":
			freeze = Pang.FREEZE_DURATION
		"extra_time":
			time_left += Pang.EXTRA_TIME_AMOUNT
		"extra_life":
			lives += 1


# --- damage -----------------------------------------------------------------

## True when a ball really overlaps the player. The hit box is deliberately
## narrower than the knight mesh and only covers the lower body, so brushing
## past a rolling ball is survivable and only a solid hit costs a life.
func _ball_hits_player(orb: Dictionary) -> bool:
	var radius := Pang.radius_of(int(orb["size"]))
	if absf(float(orb["x"]) - player_x) >= radius + Pang.PLAYER_HITBOX_HALF_WIDTH:
		return false
	return float(orb["y"]) - radius < Pang.PLAYER_HITBOX_TOP


func _check_player_hit() -> void:
	if respawn > 0.0 or invuln > 0.0:
		return
	for orb in orbs:
		if not bool(orb["active"]):
			continue
		if _ball_hits_player(orb):
			_take_hit()
			return


func _take_hit() -> void:
	invuln = Pang.INVULN_TIME
	lives -= 1
	respawn = Pang.RESPAWN_TIME
	shake = 0.5
	Sfx.hurt()
	_burst(player.position + Vector3(0.0, 1.0, 0.0), Color("f87171"), 24, 5.0)
	if lives <= 0:
		_lose("Keine Leben mehr")


# --- end states -------------------------------------------------------------

func _check_cleared() -> void:
	# A level with reinforcements still on the way is not done: the wave owns
	# the rest of the ball budget, so the screen has to wait for it.
	if balls_left > 0 or waves_left > 0 or state != STATE_PLAYING:
		return
	state = STATE_CLEARED
	new_record = Pang.record_level_time(level, run_time)
	score += Pang.clear_bonus(level, time_left)
	Game.submit_score(Game.HS_PANG, score)
	Sfx.level_up()
	var lines: Array[String] = [
		"%s  ·  %.1f s" % [Pang.level_title(level), run_time],
		"Bestzeit: %s" % ("neuer Rekord!" if new_record else ("%.1f s" % best_time if best_time > 0.0 else "—")),
		"Zeitbonus: +%d" % Pang.clear_bonus(level, time_left),
		"Kugeln: %d" % layout_total,
	]
	if waves_total > 0:
		var arrived := waves_total - waves_left
		lines.append("Nachschub: %s" % ("alle Wellen gekommen" if arrived == waves_total else "%d von %d Wellen gekommen" % [arrived, waves_total]))
	lines.append("Punkte: %s" % Ui.format_number(score))
	_show_overlay("Level geschafft!", Color("4ade80"), lines)


func _lose(reason: String) -> void:
	if state != STATE_PLAYING:
		return
	state = STATE_LOST
	Game.submit_score(Game.HS_PANG, score)
	Sfx.game_over()
	var lines: Array[String] = [
		reason,
		"Level %d  ·  Kugeln: %d" % [level, balls_popped],
	]
	if waves_left > 0:
		lines.append("Nachschub: %s kamen nicht mehr" % Pang.wave_label(waves_left))
	lines.append("Punkte: %s" % Ui.format_number(score))
	lines.append("Bestwert: %s" % Ui.format_number(maxi(Game.highscore(Game.HS_PANG), score)))
	_show_overlay("Game Over", Color("f87171"), lines)


func _toggle_pause() -> void:
	if state == STATE_PAUSED:
		state = STATE_PLAYING
		_close_overlay()
		return
	if state != STATE_PLAYING:
		return
	state = STATE_PAUSED
	_show_overlay("Pause", UiTheme.ACCENT, ["Der Timer wartet auf dich."], false)


func _show_overlay(title: String, color: Color, lines: Array[String], offer_next: bool = true) -> void:
	_close_overlay()
	_overlay = Control.new()
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_root.add_child(_overlay)
	_overlay.add_child(Ui.backdrop(0.8))
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.add_child(center)
	var column := Ui.vbox(10)
	center.add_child(column)
	column.add_child(Ui.title(title, 46, color))
	for line in lines:
		column.add_child(Ui.label(line, 19, UiTheme.TEXT))
	var buttons := Ui.vbox(8)
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_child(buttons)
	if state == STATE_CLEARED and offer_next and level < Pang.TOTAL_LEVELS:
		var next_level := level + 1
		buttons.add_child(Ui.button(Loc.f("Next: level %d", [next_level]), Vector2(320, 54), UiTheme.ACCENT, func() -> void:
			_goto_level(next_level)))
	buttons.add_child(Ui.button("Again", Vector2(320, 54), UiTheme.PANEL_LIGHT, func() -> void:
		_goto_level(level)))
	buttons.add_child(Ui.button("Level select", Vector2(320, 50), UiTheme.PANEL_LIGHT, func() -> void:
		Router.go_to("pang_menu")))
	buttons.add_child(Ui.button("Lobby", Vector2(320, 50), UiTheme.PANEL_LIGHT, func() -> void:
		Router.to_lobby()))


func _close_overlay() -> void:
	if _overlay != null and is_instance_valid(_overlay):
		_overlay.queue_free()
	_overlay = null


func _goto_level(target: int) -> void:
	_close_overlay()
	level = clampi(target, 1, Pang.TOTAL_LEVELS)
	# A different level may belong to a different chapter, so the stage is
	# rebuilt rather than patched.
	theme_index = clampi(int(Pang.level_data(level).get("background", 0)), 0, THEMES.size() - 1)
	_setup_theme()
	_build_arena()
	_start_level()


# --- feedback ---------------------------------------------------------------

func _burst(where: Vector3, color: Color, count: int, force: float) -> void:
	var multi := particles.multimesh
	for i in count:
		if particle_stack.is_empty():
			break
		var slot: int = particle_stack.pop_back()
		particle_pos[slot] = where
		particle_vel[slot] = Vector3(randf_range(-1.0, 1.0), randf_range(-0.2, 1.0), randf_range(-0.6, 0.6)).normalized() * force * randf_range(0.5, 1.2)
		particle_life[slot] = randf_range(0.35, 0.8)
		multi.set_instance_color(slot, color)
		multi.set_instance_transform(slot, Transform3D(Basis(), particle_pos[slot]))
	multi.visible_instance_count = PARTICLE_COUNT


func _tick_particles(dt: float) -> void:
	if particle_stack.size() == PARTICLE_COUNT:
		return
	var multi := particles.multimesh
	for i in PARTICLE_COUNT:
		if particle_life[i] <= 0.0:
			continue
		particle_life[i] = maxf(0.0, particle_life[i] - dt)
		particle_vel[i].y -= 16.0 * dt
		particle_pos[i] = particle_pos[i] + particle_vel[i] * dt
		if particle_life[i] <= 0.0:
			particle_stack.append(i)
			continue
		multi.set_instance_transform(i, Transform3D(Basis(), particle_pos[i]))


func _add_label(where: Vector3, text: String, color: Color) -> void:
	for slot in labels:
		if bool(slot["active"]):
			continue
		var node: Label3D = slot["node"]
		slot["active"] = true
		slot["life"] = 0.9
		slot["y"] = where.y
		node.text = text
		node.modulate = color
		node.position = where
		node.visible = true
		return


func _tick_labels(dt: float) -> void:
	for slot in labels:
		if not bool(slot["active"]):
			continue
		slot["life"] = float(slot["life"]) - dt
		slot["y"] = float(slot["y"]) + dt * 2.2
		var node: Label3D = slot["node"]
		node.position.y = float(slot["y"])
		node.modulate.a = clampf(float(slot["life"]) / 0.9, 0.0, 1.0)
		if float(slot["life"]) <= 0.0:
			slot["active"] = false
			node.visible = false


# --- camera and HUD ---------------------------------------------------------

func _tick_camera(dt: float) -> void:
	var jitter := Vector3.ZERO
	if shake > 0.0:
		jitter = Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), 0.0) * shake * 0.35
	var goal := Vector3(player_x * CAMERA_FOLLOW, CAMERA_TARGET.y, camera.position.z) + jitter
	camera.position = camera.position.lerp(goal, clampf(dt * CAMERA_LERP, 0.0, 1.0))
	camera.look_at(CAMERA_TARGET + Vector3(player_x * CAMERA_FOLLOW * 0.4, 0.0, 0.0), Vector3.UP)


## Pulls the camera back until the whole arena fits, whatever aspect ratio the
## device has — a phone in portrait would otherwise crop the playfield.
func _fit_camera() -> void:
	var size := get_viewport().get_visible_rect().size
	if size.y <= 0.0:
		return
	var aspect: float = maxf(size.x / size.y, 0.5)
	var half_fov := deg_to_rad(camera.fov * 0.5)
	var for_height: float = (Pang.CEILING_Y + 1.2) * 0.5 / tan(half_fov)
	var for_width: float = (Pang.ARENA_HALF_WIDTH + 1.0) / (tan(half_fov) * aspect)
	camera.position.z = maxf(CAMERA_BASE, maxf(for_height, for_width))
	_tick_camera(1.0)


func _sync_hud() -> void:
	_level_label.text = "%d/%d" % [level, Pang.TOTAL_LEVELS]
	_score_label.text = Ui.format_number(score)
	_lives_label.text = "♥%d" % lives
	# Balls still in the air, plus the ones a pending wave is going to add, so
	# the number never promises an empty board while reinforcements wait.
	if balls_left != _balls_shown or waves_left != _balls_shown_waves:
		_balls_shown = balls_left
		_balls_shown_waves = waves_left
		_balls_label.text = ("%d +%d" % [balls_left, waves_left]) if waves_left > 0 else str(balls_left)
	_hook_label.text = "%d/%d" % [active_harpoons, Pang.max_harpoons(harpoons_extra)]
	var ratio: float = clampf(time_left / maxf(1.0, float(layout.get("timeLimit", 1.0))), 0.0, 1.0)
	Ui.set_bar(_time_bar, ratio, Color("f87171") if ratio < 0.2 else Color("38bdf8"))
