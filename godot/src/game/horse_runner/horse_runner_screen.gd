class_name HorseRunnerScreen
extends WorldScreen
## Horse Runner 3D — an endless ride with three lanes, jumping logs, rocks and
## fences. Port of `scenes/HorseRunnerScene.ts` plus `horseRunner.ts`.

const SPAWN_Z := -150.0
const DESPAWN_Z := 16.0
const TREES := 46
const ROCKS := 18
const OBSTACLES_PER_KIND := 10
const TREE_MIN_X := HorseRunner.PATH_HALF_WIDTH + 0.8
const TREE_MAX_X := 26.0
const START_Z := 6.0
const INVULN_TIME := 0.9

var distance := 0.0
var score := 0
var highscore := 0
var lane := 1
var lane_x := 0.0
var vel_y := 0.0
var on_ground := true
var invuln := 0.0
var running := true
var gallop := 0.0
var obstacles: Array[Dictionary] = []
var trees: Array[Dictionary] = []
var next_spawn_z := -40.0
var legs: Array[Dictionary] = []
var neck: Node3D = null
var head: Node3D = null
var tail: Node3D = null
var neck_rest := 0.0
var head_rest := 0.0
var tail_rest := 0.0
var horse: Node3D
var shadow: MeshInstance3D
var dirt: MeshInstance3D

var _stick: VirtualStick
var _score_label: Label
var _speed_label: Label
var _over_layer: Control
var _shake := 0.0


func _ready_world() -> void:
	highscore = Game.highscore(Game.HS_HORSE)
	_setup_theme()
	_build_ground()
	_build_horse()
	_build_scenery()
	_build_ui()
	lane_x = HorseRunner.lane_x(lane)
	horse.position = Vector3(lane_x, 0.0, START_Z)
	_score_label.text = "0 m"
	_speed_label.text = "0.0"
	hide_loading()


func _setup_theme() -> void:
	set_fog(Color("bfdbfe"), 0.012)
	set_ambient(Color("bfdbfe"), 0.9)
	sun.light_color = Color("fff3d6")
	sun.light_energy = 1.35
	fill.light_color = Color("93c5fd")
	fill.light_energy = 0.4
	camera.fov = 60.0
	camera.far = 400.0
	camera.position = Vector3(0, 5.2, START_Z + 11.0)


func _build_ground() -> void:
	var grass := MeshInstance3D.new()
	var grass_mesh := BoxMesh.new()
	grass_mesh.size = Vector3(120, 0.4, 420)
	grass.mesh = grass_mesh
	grass.material_override = WorldScreen.standard_material(Color("4a7c3f"))
	grass.position = Vector3(0, -0.25, -120)
	add_child(grass)

	# A darker earth band frames the dirt path against the grass.
	var verge := MeshInstance3D.new()
	var verge_mesh := BoxMesh.new()
	verge_mesh.size = Vector3(HorseRunner.PATH_HALF_WIDTH * 2.0 + 1.2, 0.12, 420)
	verge.mesh = verge_mesh
	verge.material_override = WorldScreen.standard_material(Color("6b4f2a"))
	verge.position = Vector3(0, -0.04, -120)
	add_child(verge)

	dirt = MeshInstance3D.new()
	var dirt_mesh := BoxMesh.new()
	dirt_mesh.size = Vector3(HorseRunner.PATH_HALF_WIDTH * 2.0, 0.1, 420)
	dirt.mesh = dirt_mesh
	dirt.material_override = WorldScreen.standard_material(Color("9a7248"))
	dirt.position = Vector3(0, 0.0, -120)
	add_child(dirt)

	# Lane guides.
	for i in HorseRunner.LANE_COUNT:
		var x: float = HorseRunner.LANE_X[i]
		if i == 0 or i == HorseRunner.LANE_COUNT - 1:
			continue
		var line := MeshInstance3D.new()
		var line_mesh := BoxMesh.new()
		line_mesh.size = Vector3(0.08, 0.02, 420)
		line.mesh = line_mesh
		line.material_override = WorldScreen.standard_material(Color("c9a978"))
		line.position = Vector3(x, 0.06, -120)
		add_child(line)

	shadow = MeshInstance3D.new()
	var shadow_mesh := CylinderMesh.new()
	shadow_mesh.top_radius = 1.0
	shadow_mesh.bottom_radius = 1.0
	shadow_mesh.height = 0.02
	shadow_mesh.radial_segments = 16
	shadow.mesh = shadow_mesh
	var shadow_material := StandardMaterial3D.new()
	shadow_material.albedo_color = Color(0, 0, 0, 0.28)
	shadow_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	shadow_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shadow.material_override = shadow_material
	shadow.position = Vector3(0, 0.08, START_Z)
	add_child(shadow)


func _build_horse() -> void:
	horse = Node3D.new()
	var body := WorldScreen.mesh("horse", Color.WHITE, 1.0)
	if body != null:
		horse.add_child(body)
		_find_limb(body, "HorseLegFL", -0.34, true)
		_find_limb(body, "HorseLegFR", 0.34, true)
		_find_limb(body, "HorseLegBL", -0.34, false)
		_find_limb(body, "HorseLegBR", 0.34, false)
		neck = _find_node(body, "HorseNeck")
		head = _find_node(body, "HorseHead")
		tail = _find_node(body, "HorseTail")
		neck_rest = neck.rotation.x if neck != null else 0.0
		head_rest = head.rotation.x if head != null else 0.0
		tail_rest = tail.rotation.x if tail != null else 0.0
	else:
		var box := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(1.0, 1.3, 2.1)
		box.mesh = mesh
		box.material_override = WorldScreen.standard_material(Color("8b5a2b"))
		box.position.y = 1.0
		horse.add_child(box)
	add_child(horse)


func _find_node(root: Node, node_name: String) -> Node3D:
	if root.name == node_name and root is Node3D:
		return root as Node3D
	for child in root.get_children():
		var found := _find_node(child, node_name)
		if found != null:
			return found
	return null


func _find_limb(root: Node3D, node_name: String, x: float, front: bool) -> void:
	var node := _find_node(root, node_name)
	if node == null:
		return
	legs.append({"node": node, "phase": 0.0 if front else PI, "front": front})


func _build_scenery() -> void:
	for i in TREES:
		var side: float = 1.0 if randf() < 0.5 else -1.0
		var x: float = side * randf_range(TREE_MIN_X, TREE_MAX_X)
		trees.append({"node": _tree_node(x, randf_range(SPAWN_Z, DESPAWN_Z - 10.0))})
	for i in ROCKS:
		var side2: float = 1.0 if randf() < 0.5 else -1.0
		var x2: float = side2 * randf_range(TREE_MIN_X, TREE_MAX_X)
		var rock := WorldScreen.mesh("rock", Color("8a8f98"), randf_range(0.6, 1.4))
		if rock == null:
			continue
		rock.position = Vector3(x2, 0.0, randf_range(SPAWN_Z, DESPAWN_Z - 10.0))
		rock.rotation.y = randf() * TAU
		add_child(rock)
		trees.append({"node": rock})
	for kind in HorseRunner.KINDS:
		for i in OBSTACLES_PER_KIND:
			obstacles.append({"node": _obstacle_node(str(kind)), "kind": str(kind), "active": false, "x": 0.0, "z": 0.0})


func _tree_node(x: float, z: float) -> Node3D:
	var node := WorldScreen.mesh("tree", Color("3f7a34"), randf_range(0.8, 1.6))
	if node == null:
		node = WorldScreen.mesh("rpg/pine_tree", Color("3f7a34"), randf_range(0.8, 1.6))
	if node == null:
		var cone := MeshInstance3D.new()
		var mesh := CylinderMesh.new()
		mesh.top_radius = 0.0
		mesh.bottom_radius = 1.2
		mesh.height = 3.0
		mesh.radial_segments = 6
		cone.mesh = mesh
		cone.material_override = WorldScreen.standard_material(Color("3f7a34"))
		node = cone
	node.position = Vector3(x, 0.0, z)
	node.rotation.y = randf() * TAU
	add_child(node)
	return node


func _obstacle_node(kind: String) -> Node3D:
	var spec := HorseRunner.obstacle_spec(kind)
	var node := WorldScreen.mesh(str(spec["asset"]), Color.WHITE, float(spec["scale"]))
	if node == null:
		var box := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(float(spec["halfWidth"]) * 2.0, float(spec["top"]), float(spec["halfDepth"]) * 2.0)
		box.mesh = mesh
		box.material_override = WorldScreen.standard_material(Color("6b4f2a"))
		box.position.y = float(spec["top"]) * 0.5
		node = box
	node.visible = false
	add_child(node)
	return node


func _build_ui() -> void:
	_stick = add_stick("bottom_left")
	add_action_button("▲", 68.0, "jump")
	var left := add_action_button("◀", 56.0, &"", func() -> void: _shift(-1))
	left.position = left.position + Vector2(-136, -76)
	var right := add_action_button("▶", 56.0, &"", func() -> void: _shift(1))
	right.position = right.position + Vector2(-68, -76)

	var column := VBoxContainer.new()
	column.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	column.position = Vector2(20, 74)
	column.custom_minimum_size = Vector2(280, 0)
	column.add_theme_constant_override("separation", 2)
	hud_root.add_child(column)
	var title := Ui.label("♞  PFERDE-PARCOURS 3D", 22, UiTheme.TEXT, true)
	column.add_child(title)
	_score_label = _value(column, "Strecke", "0 m", Color("facc15"))
	_speed_label = _value(column, "Tempo", "0.0", UiTheme.TEXT)

	var hint := Ui.label("Stick oder ◀ ▶ zum Spurwechsel · ▲ springen", 15, UiTheme.TEXT_DIM)
	hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	hint.position = Vector2(0, -130)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud_root.add_child(hint)


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


# --- loop -------------------------------------------------------------------

func _update_world(delta: float) -> void:
	var dt: float = minf(delta, 0.05)
	if not running:
		return

	var difficulty := HorseRunner.difficulty_at(distance)
	var speed: float = float(difficulty["speed"])

	var input_vector := VirtualStick.combined(_stick.value, &"move_left", &"move_right")
	if absf(input_vector.x) > 0.55:
		_shift(1 if input_vector.x > 0.0 else -1)

	if Input.is_action_just_pressed("jump") and on_ground:
		vel_y = HorseRunner.JUMP_SPEED
		on_ground = false
		Sfx.jump()

	invuln = maxf(0.0, invuln - dt)
	lane_x = lerpf(lane_x, HorseRunner.lane_x(lane), clampf(dt * 12.0, 0.0, 1.0))
	vel_y -= HorseRunner.GRAVITY * dt
	var feet: float = vel_y
	if feet <= 0.0:
		feet = 0.0
		vel_y = 0.0
		on_ground = true
	var height := maxf(feet, 0.0)

	distance += speed * dt
	score = int(distance * 10.0)
	gallop += dt * (6.0 + speed * 0.35)

	horse.position = Vector3(lane_x, height, START_Z)
	horse.rotation.y = lerp_angle(horse.rotation.y, (lane - 1) * -0.18, clampf(dt * 8.0, 0.0, 1.0))
	shadow.position = Vector3(lane_x, 0.08, START_Z)
	var shadow_scale: float = clampf(1.0 - height * 0.16, 0.4, 1.0)
	shadow.scale = Vector3(shadow_scale, 1.0, shadow_scale)
	shadow.material_override.albedo_color.a = 0.28 * shadow_scale

	_animate_horse(dt, on_ground, speed)
	_update_obstacles(dt, difficulty, speed, height)
	_update_scenery(dt, speed)
	_follow(dt)

	_score_label.text = "%d m" % int(distance)
	_speed_label.text = "%.1f" % speed


func _animate_horse(dt: float, grounded: bool, speed: float) -> void:
	for leg in legs:
		var node: Node3D = leg["node"]
		node.rotation.x = sin(gallop + float(leg["phase"])) * (0.55 if grounded else 0.2)
	if neck != null:
		neck.rotation.x = neck_rest + sin(gallop * 0.5) * 0.06 + (0.12 if not grounded else 0.0)
	if head != null:
		head.rotation.x = head_rest + sin(gallop * 0.5 + 0.6) * 0.05
	if tail != null:
		tail.rotation.x = tail_rest + sin(gallop * 0.7) * 0.25


func _update_obstacles(dt: float, difficulty: Dictionary, speed: float, height: float) -> void:
	for obstacle in obstacles:
		var node: Node3D = obstacle["node"]
		if bool(obstacle["active"]):
			node.position.z += speed * dt
			if node.position.z > DESPAWN_Z:
				obstacle["active"] = false
				node.visible = false
				continue
			var spec := HorseRunner.obstacle_spec(str(obstacle["kind"]))
			if invuln <= 0.0 and HorseRunner.collides(lane_x, height, START_Z, float(obstacle["x"]), node.position.z, spec):
				_hit()
				continue
	# Spawn a new row when the gap demands it.
	next_spawn_z += speed * dt
	if next_spawn_z > SPAWN_Z + HorseRunner.spawn_gap(difficulty):
		next_spawn_z = SPAWN_Z
		_spawn_row(difficulty)


func _spawn_row(difficulty: Dictionary) -> void:
	var blocked: Array[int] = []
	var rows: int = 2 if randf() < float(difficulty["doubleChance"]) else 1
	for i in rows:
		var lane_index := randi() % HorseRunner.LANE_COUNT
		if lane_index in blocked:
			continue
		blocked.append(lane_index)
		for obstacle in obstacles:
			if bool(obstacle["active"]):
				continue
			var node: Node3D = obstacle["node"]
			node.visible = true
			node.position = Vector3(HorseRunner.lane_x(lane_index), 0.0, SPAWN_Z)
			node.rotation.y = randf() * 0.6 - 0.3
			obstacle["active"] = true
			obstacle["x"] = HorseRunner.lane_x(lane_index)
			obstacle["z"] = SPAWN_Z
			break


func _update_scenery(dt: float, speed: float) -> void:
	var shift: float = speed * dt
	for tree in trees:
		var node: Node3D = tree["node"]
		node.position.z += shift
		if node.position.z > DESPAWN_Z:
			var side: float = 1.0 if randf() < 0.5 else -1.0
			node.position.x = side * randf_range(TREE_MIN_X, TREE_MAX_X)
			node.position.z = randf_range(SPAWN_Z, DESPAWN_Z - 10.0)
			node.rotation.y = randf() * TAU


func _follow(dt: float) -> void:
	_shake = maxf(0.0, _shake - dt)
	var jitter := Vector3.ZERO
	if _shake > 0.0:
		jitter = Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), 0.0) * _shake * 0.5
	var goal := Vector3(lane_x * 0.4, 5.2 + maxf(vel_y, 0.0) * 0.25, START_Z + 11.0) + jitter
	camera.position = camera.position.lerp(goal, clampf(dt * 6.0, 0.0, 1.0))
	camera.look_at(Vector3(lane_x * 0.3, 1.6, START_Z - 8.0), Vector3.UP)


func _shift(direction: int) -> void:
	var next := HorseRunner.clamp_lane(lane + direction)
	if next == lane:
		return
	lane = next
	Sfx.select()


func _hit() -> void:
	invuln = INVULN_TIME
	Sfx.hurt()
	_shake = 0.32
	_end_run()


func _end_run() -> void:
	if not running:
		return
	running = false
	Game.submit_score(Game.HS_HORSE, score)
	Sfx.game_over()
	_over_layer = Control.new()
	_over_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_over_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_root.add_child(_over_layer)
	_over_layer.add_child(Ui.backdrop(0.78))
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_over_layer.add_child(center)
	var column := Ui.vbox(12)
	center.add_child(column)
	column.add_child(Ui.title("Sturz", 48, Color("f87171")))
	column.add_child(Ui.label("Strecke: %d m   ·   Punkte: %s   ·   Bestwert: %d m" % [int(distance), Ui.format_number(score), maxi(highscore, int(distance))], 20, UiTheme.TEXT))
	column.add_child(Ui.button("Nochmal", Vector2(340, 56), UiTheme.ACCENT, func() -> void: Router.go_to(screen_id)))
	column.add_child(Ui.button("Lobby", Vector2(340, 56), UiTheme.PANEL_LIGHT, func() -> void: Router.to_lobby()))
