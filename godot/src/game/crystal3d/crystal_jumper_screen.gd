class_name CrystalJumperScreen
extends WorldScreen
## Crystal Jumper 3D — climb a spiral tower, collect crystals, reach the summit
## and merge them into higher tiers. Port of `scenes/CrystalJumperScene.ts`
## plus `crystalTower.ts`.
##
## Three editions share this screen: the classic crystals, the Christmas
## ornaments and the Halloween pumpkins. A theme only swaps names, tints, meshes
## and scenery, so gameplay stays identical.

const FLOOR_HEIGHT := 3.4
const PLATFORM_HALF := 2.4
const PLATFORM_THICKNESS := 0.6
const PLAYER_HALF_HEIGHT := 0.75
const PLAYER_RADIUS := 0.7
const GRAVITY := 42.0
const JUMP_SPEED := 18.5
const BASE_SPEED := 12.0
const BOUND := 18.0
const WORLD_CRYSTAL_SCALE := 0.62
const INVENTORY_SLOT := 0.85
const INVENTORY_COLS := 6
const INVENTORY_SCALE := 0.5
const INVENTORY_CAP := INVENTORY_COLS * 2
const MERGE_GATHER := 0.42
const MERGE_BURST := 0.24
const MERGE_SETTLE := 0.36
const PARTICLE_COUNT := 220
const PARTICLE_SPREAD := 46.0
const PARTICLE_MARGIN := 14.0
const LABEL_POOL_SIZE := 8

const PHASE_IDLE := 0
const PHASE_GATHER := 1
const PHASE_BURST := 2
const PHASE_SETTLE := 3

var theme: Dictionary = {}
var theme_id := "classic"
var config: Dictionary = {}
var platforms: Array[Dictionary] = []
var crystals: Array[Dictionary] = []

var pos := Vector3.ZERO
var vel_y := 0.0
var grounded := true
var air_jumps := 0
var jump_held := false
var checkpoint := 0
var running := true

var counts: Array = []
var collected := 0
var bonus: Dictionary = {}
var equipped_tier := 0
var move_speed := BASE_SPEED
var jump_speed := JUMP_SPEED
var pickup_radius := 2.0

## Flusskette: Länge, schon ausgezahlter Bonus und Zeitpunkt des letzten
## Fundes. `run_best_flow` ist die längste Kette dieses Laufs, `best_flow` der
## Rekord aus `Game`.
var flow_chain := 0
var flow_bonus := 0
var flow_last_ms := -1.0
var run_best_flow := 0
var best_flow := 0
var flow_record := false

var summit_reached := false
var summit_time := 0.0
var summit_merges := 0
var summit_within_target := false
var merge_phase := PHASE_IDLE
var merge_timer := 0.0
var merge_steps: Array = []
var merge_actors: Array = []
var merge_created: Node3D = null
var merge_created_tier := 0
var merge_point := Vector3(0, 2.7, 0)
var actor_start: Array[Vector3] = []
var actor_spin: Array[float] = []

var ship: Node3D
var altar: MeshInstance3D
var altar_light: OmniLight3D
var inventory_root: Node3D
var burst_ring: MeshInstance3D
var burst_light: OmniLight3D
var tier_templates: Array = []
var particles: MultiMeshInstance3D
var particle_data: PackedFloat32Array = PackedFloat32Array()
var particle_speeds: PackedFloat32Array = PackedFloat32Array()
var particle_height := 30.0
var particle_direction := -1.0

var _stick: VirtualStick
var _score_label: Label
var _points_label: Label
var _floor_label: Label
var _time_label: Label
var _chain_label: Label
var _chain_bar: ProgressBar
var _bag_label: Label
var _hint_label: Label
var _hud_layer: Control
var _label_pool: Array = []
var _floating: Array = []
## Last chain length written to the label, so colours are only touched on change.
var _flow_shown := -1
## Last point total written to the label.
var _score_shown := -1
var _record_announced := false


func _ready_world() -> void:
	theme_id = _theme_for_screen()
	theme = CrystalTower.theme_by_id(theme_id)
	var prefix := str(theme["keyPrefix"])
	equipped_tier = int(Game.get_number("%s_equipped" % prefix, 0.0))
	best_flow = maxi(0, int(Game.get_number("%s_best_flow" % prefix, 0.0)))
	bonus = CrystalTower.equip_bonus(equipped_tier) if equipped_tier > 0 else {
		"speedMult": 1.0, "jumpMult": 1.0, "pickupRadius": 2.0, "extraJumps": 0,
	}
	move_speed = BASE_SPEED * float(bonus["speedMult"])
	jump_speed = JUMP_SPEED * float(bonus["jumpMult"])
	pickup_radius = float(bonus["pickupRadius"])
	air_jumps = int(bonus["extraJumps"])

	var unlocked: int = clampi(int(Game.get_number("%s_unlocked" % prefix, 1.0)), 1, CrystalTower.MAX_LEVEL)
	var level: int = clampi(int(Game.get_number("%s_level" % prefix, 1.0)), 1, unlocked)
	config = CrystalTower.level_config(level)
	counts = []
	for i in CrystalTower.MAX_CRYSTAL_TIER:
		counts.append(0)

	_setup_theme()
	_build_tower()
	_build_particles()
	_build_player()
	_build_label_pool()
	_build_ui()
	hide_loading()
	_refresh_bag()


func _theme_for_screen() -> String:
	match screen_id:
		"crystal3d_christmas":
			return CrystalTower.THEME_CHRISTMAS
		"crystal3d_halloween":
			return CrystalTower.THEME_HALLOWEEN
		_:
			return CrystalTower.THEME_CLASSIC


func _setup_theme() -> void:
	var background: Color = theme["background"]
	set_fog(background, 0.012)
	set_ambient(theme["sky"], 0.75)
	sun.light_color = Color.WHITE
	sun.light_energy = 1.25
	fill.light_color = theme["sky"]
	fill.light_energy = 0.35
	camera.fov = 60.0
	camera.far = 400.0

	_build_ground(theme["ground"], theme["grid"])
	_load_tier_templates()


## Ground disc plus a light grid of crossing lines and rings so the climb height
## stays readable. Everything is built from primitives — no extra assets.
func _build_ground(ground_color: Color, grid_colors: Array) -> void:
	var ground := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = 30.0
	mesh.bottom_radius = 30.0
	mesh.height = 0.4
	mesh.radial_segments = 48
	ground.mesh = mesh
	ground.material_override = WorldScreen.standard_material(ground_color)
	ground.position.y = -0.2
	add_child(ground)

	var line_material := WorldScreen.standard_material(grid_colors[0])
	for i in 4:
		var bar := MeshInstance3D.new()
		var bar_mesh := BoxMesh.new()
		if i % 2 == 0:
			bar_mesh.size = Vector3(0.12, 0.02, 60.0)
		else:
			bar_mesh.size = Vector3(60.0, 0.02, 0.12)
		bar.mesh = bar_mesh
		bar.material_override = line_material
		bar.position.y = 0.02
		add_child(bar)

	for radius in [8.0, 16.0, 24.0]:
		var ring := MeshInstance3D.new()
		var torus := TorusMesh.new()
		torus.inner_radius = float(radius) - 0.06
		torus.outer_radius = float(radius)
		ring.mesh = torus
		ring.material_override = line_material
		ring.position.y = 0.02
		add_child(ring)


func _load_tier_templates() -> void:
	tier_templates = []
	for tier in range(1, CrystalTower.MAX_CRYSTAL_TIER + 1):
		var key := str((theme["tierAssets"] as Array)[tier - 1])
		var template := WorldScreen.mesh(key, CrystalTower.crystal_tier_color(theme, tier), 1.0, 0.35 if tier >= 3 else 0.0)
		if template != null:
			tier_templates.append(template)
		else:
			tier_templates.append(_crystal_fallback(CrystalTower.crystal_tier_color(theme, tier)))


## A simple faceted gem used when a mesh cannot be loaded.
func _crystal_fallback(color: Color) -> Node3D:
	var root := Node3D.new()
	var gem := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.42
	mesh.height = 1.3
	mesh.radial_segments = 8
	mesh.rings = 5
	gem.mesh = mesh
	gem.material_override = WorldScreen.standard_material(color, 0.6)
	root.add_child(gem)
	return root


func _build_tower() -> void:
	platforms = []
	platforms.append({"index": 0, "x": 0.0, "z": 0.0, "y": 0.0, "half": PLATFORM_HALF + 1.6, "summit": false})
	for i in range(1, int(config["floors"])):
		var angle := float(i) * 0.95
		var radius := 5.4 + sin(float(i) * 0.7) * 0.5
		var summit := i == int(config["floors"]) - 1
		platforms.append({
			"index": i,
			"x": cos(angle) * radius,
			"z": sin(angle) * radius,
			"y": float(i) * FLOOR_HEIGHT,
			"half": PLATFORM_HALF + 1.0 if summit else PLATFORM_HALF,
			"summit": summit,
		})

	for platform in platforms:
		var half: float = platform["half"]
		var box := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(half * 2.0, PLATFORM_THICKNESS, half * 2.0)
		box.mesh = mesh
		if bool(platform["summit"]):
			box.material_override = WorldScreen.standard_material(theme["summit"], 0.7)
		else:
			box.material_override = WorldScreen.standard_material(theme["platform"])
		box.position = Vector3(float(platform["x"]), float(platform["y"]) - PLATFORM_THICKNESS * 0.5, float(platform["z"]))
		add_child(box)

	var tower_top: float = float(platforms[platforms.size() - 1]["y"]) + 1.0
	var column := MeshInstance3D.new()
	var column_mesh := CylinderMesh.new()
	column_mesh.top_radius = 0.3
	column_mesh.bottom_radius = 0.55
	column_mesh.height = tower_top
	column_mesh.radial_segments = 10
	column.mesh = column_mesh
	column.material_override = WorldScreen.standard_material(theme["column"])
	column.position = Vector3(0, tower_top * 0.5, 0)
	add_child(column)

	var summit: Dictionary = platforms[platforms.size() - 1]
	altar = MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 2.88
	torus.outer_radius = 3.0
	altar.mesh = torus
	altar.material_override = WorldScreen.standard_material(theme["accent"], 1.5)
	altar.position = Vector3(float(summit["x"]), float(summit["y"]) + 0.35, float(summit["z"]))
	add_child(altar)

	altar_light = OmniLight3D.new()
	altar_light.light_color = theme["accent"]
	altar_light.light_energy = 18.0
	altar_light.omni_range = 16.0
	altar_light.position = altar.position + Vector3(0, 2.2, 0)
	add_child(altar_light)

	inventory_root = Node3D.new()
	inventory_root.position = altar.position + Vector3(0, 0.6, 0)
	inventory_root.visible = false
	add_child(inventory_root)

	burst_ring = MeshInstance3D.new()
	var burst_torus := TorusMesh.new()
	burst_torus.inner_radius = 0.94
	burst_torus.outer_radius = 1.0
	burst_ring.mesh = burst_torus
	burst_ring.material_override = WorldScreen.standard_material(Color.WHITE, 2.0)
	burst_ring.visible = false
	inventory_root.add_child(burst_ring)

	burst_light = OmniLight3D.new()
	burst_light.light_color = Color.WHITE
	burst_light.light_energy = 0.0
	burst_light.omni_range = 14.0
	inventory_root.add_child(burst_light)

	# Crystals on every floor; higher floors carry rarer tiers.
	for platform in platforms:
		var count: int = int(config["crystalsPerFloor"]) + (1 if bool(platform["summit"]) else 0)
		var tier := CrystalTower.tier_for_floor(int(platform["index"]), int(config["floors"]))
		for c in count:
			var node := _spawn_tier_node(tier)
			var spread: float = float(platform["half"]) * 0.62
			var x: float = float(platform["x"]) + randf_range(-spread, spread)
			var z: float = float(platform["z"]) + randf_range(-spread, spread)
			var base_y: float = float(platform["y"]) + 1.5
			node.position = Vector3(x, base_y, z)
			node.rotation.y = randf() * TAU
			add_child(node)
			crystals.append({"node": node, "x": x, "y": base_y, "z": z, "tier": tier, "phase": randf() * TAU})


func _spawn_tier_node(tier: int) -> Node3D:
	if tier_templates.is_empty():
		return _crystal_fallback(CrystalTower.crystal_tier_color(theme, tier))
	var template: Node3D = tier_templates[clampi(tier, 1, tier_templates.size()) - 1]
	var node := template.duplicate() as Node3D
	node.scale = Vector3.ONE * WORLD_CRYSTAL_SCALE
	return node


func _build_particles() -> void:
	particle_height = float(platforms[platforms.size() - 1]["y"]) + PARTICLE_MARGIN
	particle_direction = -1.0 if bool(theme["particleFall"]) else 1.0
	var mesh := SphereMesh.new()
	mesh.radius = 0.11
	mesh.height = 0.22
	mesh.radial_segments = 5
	mesh.rings = 3
	particles = MultiMeshInstance3D.new()
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = PARTICLE_COUNT
	multimesh.visible_instance_count = PARTICLE_COUNT
	particles.multimesh = multimesh
	particles.material_override = WorldScreen.standard_material(theme["particle"], 0.8)
	add_child(particles)

	particle_data = PackedFloat32Array()
	particle_data.resize(PARTICLE_COUNT * 3)
	particle_speeds = PackedFloat32Array()
	particle_speeds.resize(PARTICLE_COUNT)
	for i in PARTICLE_COUNT:
		particle_data[i * 3] = randf_range(-0.5, 0.5) * PARTICLE_SPREAD
		particle_data[i * 3 + 1] = randf() * particle_height
		particle_data[i * 3 + 2] = randf_range(-0.5, 0.5) * PARTICLE_SPREAD
		particle_speeds[i] = 1.2 + randf() * 2.4
	_write_particles()


func _write_particles() -> void:
	if particles == null or particles.multimesh == null:
		return
	for i in PARTICLE_COUNT:
		var basis := Basis.IDENTITY.scaled(Vector3.ONE * (0.7 + 0.5 * fmod(float(i), 3.0) / 3.0))
		particles.multimesh.set_instance_transform(i, Transform3D(basis, Vector3(
			particle_data[i * 3], particle_data[i * 3 + 1], particle_data[i * 3 + 2])))


func _build_player() -> void:
	ship = Node3D.new()
	var body := WorldScreen.mesh("ship", theme["ship"], 0.8, 0.5)
	if body != null:
		ship.add_child(body)
	else:
		var cone := MeshInstance3D.new()
		var mesh := CylinderMesh.new()
		mesh.top_radius = 0.0
		mesh.bottom_radius = 0.45
		mesh.height = 1.0
		mesh.radial_segments = 6
		cone.mesh = mesh
		cone.material_override = WorldScreen.standard_material(theme["ship"], 0.5)
		ship.add_child(cone)
	add_child(ship)
	pos = Vector3(0, PLAYER_HALF_HEIGHT, 3.0)
	ship.position = pos


func _build_ui() -> void:
	_stick = add_stick("bottom_left")
	add_action_button("▲", 66.0, "jump")

	_hud_layer = Control.new()
	_hud_layer.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_hud_layer.offset_left = -300
	_hud_layer.offset_right = -16
	_hud_layer.offset_top = 66
	_hud_layer.offset_bottom = 310
	_hud_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_root.add_child(_hud_layer)
	var panel := Ui.rect(Color(0.031, 0.047, 0.086, 0.62), 12, Color(1, 1, 1, 0.08), 1)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hud_layer.add_child(panel)

	_score_label = _stat("Kristalle", "0", Vector2(0, 0), 60.0)
	_points_label = _stat("Punkte", "0", Vector2(0, 46), 120.0)
	_floor_label = _stat("Etage", "1/%d" % int(config["floors"]), Vector2(0, 92), 60.0)
	_time_label = _stat("Zeit", "0:00", Vector2(0, 138), 120.0)

	# The chain gets its own row plus a bar that drains while it is alive: the
	# player has to see the window closing to know the next pickup is urgent.
	var chain_caption := Ui.label("Kette", 14, UiTheme.TEXT_DIM)
	chain_caption.position = Vector2(0, 184)
	chain_caption.size = Vector2(120, 22)
	_hud_layer.add_child(chain_caption)
	_chain_label = Ui.label("", 26, UiTheme.TEXT_DIM, true)
	_chain_label.position = Vector2(120, 176)
	_chain_label.size = Vector2(180, 40)
	_hud_layer.add_child(_chain_label)
	_chain_bar = Ui.bar(theme["accent"], 10.0)
	_chain_bar.position = Vector2(0, 222)
	_chain_bar.size = Vector2(300, 10)
	_hud_layer.add_child(_chain_bar)
	Ui.set_bar(_chain_bar, 0.0, theme["accent"])

	_bag_label = Ui.label("", 15, UiTheme.TEXT_DIM)
	_bag_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_bag_label.position = Vector2(20, -170)
	_bag_label.size = Vector2(320, 150)
	_bag_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_bag_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	hud_root.add_child(_bag_label)

	_hint_label = Ui.label("%s  ·  Flusskette: schnell aufeinanderfolgende Funde zahlen mehr" % str(theme["hint"]), 15, UiTheme.TEXT_DIM)
	_hint_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_hint_label.position = Vector2(0, -32)
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud_root.add_child(_hint_label)

	if equipped_tier > 0:
		_hint_label.text += "  ·  Ausgerüstet: %s" % CrystalTower.crystal_tier_name(theme, equipped_tier)


## One caption/value pair of the top-right status block.
func _stat(caption: String, value: String, pos: Vector2, width: float) -> Label:
	var label := Ui.label(caption, 14, UiTheme.TEXT_DIM)
	label.position = pos
	label.size = Vector2(120, 22)
	_hud_layer.add_child(label)
	var result := Ui.value_label(value)
	result.position = pos + Vector2(120.0, -6.0)
	result.size = Vector2(width, 40)
	_hud_layer.add_child(result)
	return result


## Pre-allocated floating texts. A pickup writes its bonus into the air, so the
## pool is built once instead of spawning a Label3D per crystal.
func _build_label_pool() -> void:
	for i in LABEL_POOL_SIZE:
		var label := Label3D.new()
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.fixed_size = true
		label.outline_render_priority = 1
		label.outline_size = 24
		label.outline_modulate = Color("020617")
		label.font_size = 96
		label.visible = false
		add_child(label)
		_label_pool.append(label)


## Shows `text` at `at` for `life` seconds, fading out. Reuses the oldest free
## label when the pool is exhausted.
func _push_label(at: Vector3, text: String, color: Color, life: float, size: float) -> void:
	var node: Label3D = null
	for candidate in _label_pool:
		if not candidate.visible:
			node = candidate
			break
	if node == null:
		node = _label_pool[0]
	node.text = text
	node.modulate = color
	node.font_size = int(size)
	node.position = at
	node.visible = true
	_floating.append({"node": node, "life": life, "max_life": life})


## Ages every floating label and hides the expired ones.
func _update_floating(dt: float) -> void:
	for i in range(_floating.size() - 1, -1, -1):
		var entry: Dictionary = _floating[i]
		entry["life"] = float(entry["life"]) - dt
		var node: Label3D = entry["node"]
		node.position += Vector3(0, dt * 1.6, 0)
		node.modulate.a = clampf(float(entry["life"]) / maxf(0.01, float(entry["max_life"])), 0.0, 1.0)
		if float(entry["life"]) <= 0.0:
			node.visible = false
			_floating.remove_at(i)


# --- loop -------------------------------------------------------------------

func _update_world(delta: float) -> void:
	var dt: float = minf(delta, 0.05)
	var prev_y := pos.y

	if running:
		elapsed += dt
		var move_vector := VirtualStick.combined(_stick.value, &"move_left", &"move_right")
		if move_vector.length() > 0.05:
			pos.x = clampf(pos.x + move_vector.x * move_speed * dt, -BOUND, BOUND)
			pos.z = clampf(pos.z + move_vector.y * move_speed * dt, -BOUND, BOUND)
			ship.rotation.y = atan2(move_vector.x, move_vector.y)

		var jump_now := Input.is_action_pressed("jump")
		if jump_now and not jump_held:
			if grounded:
				vel_y = jump_speed
				grounded = false
				air_jumps = int(bonus["extraJumps"])
			elif air_jumps > 0:
				vel_y = jump_speed * 0.85
				air_jumps -= 1
				Sfx.jump()
		jump_held = jump_now

		vel_y -= GRAVITY * dt
		pos.y += vel_y * dt

		grounded = false
		if vel_y <= 0.0:
			var prev_feet: float = prev_y - PLAYER_HALF_HEIGHT
			var feet: float = pos.y - PLAYER_HALF_HEIGHT
			for platform in platforms:
				var top: float = platform["y"]
				var within_x: bool = absf(pos.x - float(platform["x"])) <= float(platform["half"]) + PLAYER_RADIUS
				var within_z: bool = absf(pos.z - float(platform["z"])) <= float(platform["half"]) + PLAYER_RADIUS
				if prev_feet >= top - 0.05 and feet <= top and within_x and within_z:
					pos.y = top + PLAYER_HALF_HEIGHT
					vel_y = 0.0
					grounded = true
					air_jumps = int(bonus["extraJumps"])
					if int(platform["index"]) > checkpoint:
						checkpoint = int(platform["index"])
					if bool(platform["summit"]):
						_reach_summit()
					break

		if pos.y < -10.0:
			var respawn: Dictionary = platforms[checkpoint]
			pos = Vector3(float(respawn["x"]), float(respawn["y"]) + PLAYER_HALF_HEIGHT, float(respawn["z"]))
			vel_y = 0.0
			grounded = true
			# A fall tears the chain apart; only the paid-out bonus survives.
			flow_chain = 0
			flow_last_ms = -1.0

	ship.position = Vector3(pos.x, pos.y + sin(elapsed * 4.0) * 0.06, pos.z)

	_update_crystals(dt)
	_update_flow(dt)

	altar.rotation.y += dt * 0.5
	_update_particles(dt)
	_update_merge(dt)
	_update_inventory(dt)

	if summit_reached:
		var summit: Dictionary = platforms[platforms.size() - 1]
		_camera_goal = Vector3(float(summit["x"]), float(summit["y"]) + 7.0, float(summit["z"]) + 13.0)
		_camera_look = Vector3(float(summit["x"]), float(summit["y"]) + 1.0, float(summit["z"]))
	else:
		_camera_goal = Vector3(pos.x, pos.y + 8.0, pos.z + 14.0)
		_camera_look = Vector3(pos.x, pos.y + 2.4, pos.z)
	camera.position = camera.position.lerp(_camera_goal, clampf(5.0 * dt, 0.0, 1.0))
	camera.look_at(_camera_look, Vector3.UP)

	_score_label.text = str(collected)
	_floor_label.text = "%d/%d" % [checkpoint + 1, int(config["floors"])]
	_time_label.text = CrystalTower.format_time(elapsed * 1000.0) if running else CrystalTower.format_time(summit_time)


var _camera_goal := Vector3.ZERO
var _camera_look := Vector3.ZERO


func _update_crystals(dt: float) -> void:
	var pickup_sq: float = pickup_radius * pickup_radius
	for i in range(crystals.size() - 1, -1, -1):
		var crystal: Dictionary = crystals[i]
		var node: Node3D = crystal["node"]
		node.rotation.y += dt * 1.5
		var y: float = float(crystal["y"]) + sin(elapsed * 2.0 + float(crystal["phase"])) * 0.22
		node.position.y = y
		if not running:
			continue
		var dx: float = float(crystal["x"]) - pos.x
		var dy: float = y - pos.y
		var dz: float = float(crystal["z"]) - pos.z
		if dx * dx + dy * dy + dz * dz >= pickup_sq:
			continue
		node.queue_free()
		crystals.remove_at(i)
		var tier := int(crystal["tier"])
		counts[tier - 1] = int(counts[tier - 1]) + 1
		collected += 1
		_pickup_flow(Vector3(float(crystal["x"]), y, float(crystal["z"])), tier)
		_refresh_bag()


## Values a pickup: continues the flow chain, pays the bonus and puts the amount
## into the air. A single pickup has nothing to celebrate, so the text and the
## second sound only start at a chain of two.
func _pickup_flow(at: Vector3, tier: int) -> void:
	flow_chain = CrystalTower.next_flow(elapsed * 1000.0, flow_last_ms, flow_chain)
	flow_last_ms = elapsed * 1000.0
	if flow_chain > run_best_flow:
		run_best_flow = flow_chain
	var bonus := CrystalTower.flow_step_bonus(flow_chain, tier)
	flow_bonus += bonus
	if not _record_announced and run_best_flow > best_flow and best_flow > 0:
		_record_announced = true
		notify("Neuer Kettenrekord: ×%d!" % run_best_flow)
	if bonus <= 0:
		Sfx.hit()
		return
	Sfx.coin()
	_push_label(at, "+%d  ×%d" % [bonus, CrystalTower.flow_multiplier(flow_chain)], _flow_color(), 1.2, 64.0)


## Lets the chain run out, drains the bar and writes score, chain and colour.
## Only the bar is touched every frame; text and colours follow the chain length.
func _update_flow(dt: float) -> void:
	_update_floating(dt)
	if flow_chain > 0 and CrystalTower.flow_left_ms(elapsed * 1000.0, flow_last_ms, flow_chain) <= 0.0:
		flow_chain = 0
	var score := CrystalTower.run_score(counts, flow_bonus)
	if score != _score_shown:
		_score_shown = score
		_points_label.text = str(score)
	if flow_chain >= 2:
		Ui.set_bar(_chain_bar, CrystalTower.flow_ratio(elapsed * 1000.0, flow_last_ms, flow_chain), _flow_color())
	elif _chain_bar.value > 0.0:
		Ui.set_bar(_chain_bar, 0.0, _flow_color())
	if flow_chain == _flow_shown:
		return
	_flow_shown = flow_chain
	_chain_label.text = CrystalTower.format_flow(flow_chain)
	_chain_label.add_theme_color_override("font_color", _flow_color())


## Dim while no chain runs, then theme accent, green and finally gold at the cap.
func _flow_color() -> Color:
	if flow_chain < 2:
		return UiTheme.TEXT_DIM
	if flow_chain < 5:
		return theme["accent"]
	if flow_chain < CrystalTower.MAX_FLOW:
		return UiTheme.SUCCESS
	return UiTheme.WARNING


func _update_particles(dt: float) -> void:
	for i in PARTICLE_COUNT:
		var y: float = particle_data[i * 3 + 1] + particle_direction * particle_speeds[i] * dt
		if particle_direction < 0.0 and y < 0.0:
			y = particle_height
		elif particle_direction > 0.0 and y > particle_height:
			y = 0.0
		particle_data[i * 3 + 1] = y
	_write_particles()


# --- summit, inventory and merging ------------------------------------------

func _reach_summit() -> void:
	if not running:
		return
	running = false
	summit_time = snappedf(elapsed * 1000.0, 1.0)
	summit_merges = 0
	summit_within_target = summit_time <= float(config["targetMs"])
	summit_reached = true

	var summit: Dictionary = platforms[platforms.size() - 1]
	pos = Vector3(float(summit["x"]), float(summit["y"]) + PLAYER_HALF_HEIGHT, float(summit["z"]) + 2.8)
	vel_y = 0.0
	grounded = true
	inventory_root.visible = true
	_sync_inventory()

	var prefix := str(theme["keyPrefix"])
	var value := CrystalTower.run_score(counts, flow_bonus)
	Game.submit_score("%s_highscore" % prefix, value)
	if run_best_flow > best_flow:
		best_flow = run_best_flow
		flow_record = true
		Game.set_number("%s_best_flow" % prefix, float(best_flow))
	if summit_within_target:
		var best_time := Game.get_number("%s_best_time" % prefix, 0.0)
		if best_time == 0.0 or summit_time < best_time:
			Game.set_number("%s_best_time" % prefix, summit_time)
		if int(config["level"]) < CrystalTower.MAX_LEVEL:
			Game.set_number("%s_unlocked" % prefix, maxf(Game.get_number("%s_unlocked" % prefix, 1.0), float(config["level"]) + 1.0))
	Sfx.level_up()
	_show_summit_panel()


func _refresh_bag() -> void:
	var parts: Array = []
	for i in counts.size():
		if int(counts[i]) > 0:
			parts.append("◆ %s ×%d" % [CrystalTower.crystal_tier_name(theme, i + 1), int(counts[i])])
	_bag_label.text = "\n".join(parts) if not parts.is_empty() else "Inventar leer"


## Lays the 3D inventory grid out in tier rows above the summit altar.
func _sync_inventory() -> void:
	for child in inventory_root.get_children():
		if child == burst_ring or child == burst_light:
			continue
		child.queue_free()
	for tier in range(1, CrystalTower.MAX_CRYSTAL_TIER + 1):
		var want: int = mini(int(counts[tier - 1]), INVENTORY_CAP)
		for i in want:
			var node := _spawn_inventory_node(tier)
			inventory_root.add_child(node)
			var slot := _slot_position(tier, i, want)
			node.position = slot
			node.scale = Vector3.ONE * INVENTORY_SCALE


func _spawn_inventory_node(tier: int) -> Node3D:
	if tier_templates.is_empty():
		return _crystal_fallback(CrystalTower.crystal_tier_color(theme, tier))
	var template: Node3D = tier_templates[clampi(tier, 1, tier_templates.size()) - 1]
	var node := template.duplicate() as Node3D
	node.scale = Vector3.ONE * INVENTORY_SCALE
	return node


func _slot_position(tier: int, index: int, total: int) -> Vector3:
	var row_z: float = (2 - float(tier - 1)) * INVENTORY_SLOT
	var layer: int = int(floor(float(index) / float(INVENTORY_COLS)))
	var in_layer: int = index % INVENTORY_COLS
	var layer_count: int = mini(INVENTORY_COLS, maxi(1, total - layer * INVENTORY_COLS))
	var x: float = (float(in_layer) - float(layer_count - 1) * 0.5) * INVENTORY_SLOT
	return Vector3(x, 3.2 + float(layer) * INVENTORY_SLOT, row_z)


func _update_inventory(_dt: float) -> void:
	if not inventory_root.visible:
		return
	for child in inventory_root.get_children():
		if child is Node3D and child != burst_ring and child != burst_light:
			child.rotation.y += _dt * 0.6
			child.position.y += sin(elapsed * 2.0 + child.position.x) * _dt * 0.02


func start_merge() -> void:
	if merge_phase != PHASE_IDLE or not summit_reached:
		return
	merge_steps = CrystalTower.plan_merges(counts)["steps"]
	if merge_steps.is_empty():
		return
	_next_merge_step()


func _next_merge_step() -> void:
	if merge_steps.is_empty():
		merge_phase = PHASE_IDLE
		merge_actors.clear()
		merge_created = null
		_show_summit_panel()
		return
	var step: Dictionary = merge_steps.pop_front()
	var from_tier := int(step["from"])
	var to_tier := int(step["to"])
	counts[from_tier - 1] = maxi(0, int(counts[from_tier - 1]) - 3)
	counts[to_tier - 1] = int(counts[to_tier - 1]) + 1
	merge_created = _spawn_inventory_node(to_tier)
	merge_created.position = merge_point
	merge_created.scale = Vector3.ONE * 0.01
	merge_created_tier = to_tier
	inventory_root.add_child(merge_created)
	actor_start.clear()
	actor_spin.clear()
	for i in 3:
		actor_start.append(merge_point + Vector3(randf_range(-1.0, 1.0), randf_range(0.0, 0.6), randf_range(-1.0, 1.0)))
		actor_spin.append(randf_range(-4.0, 4.0))
	merge_phase = PHASE_GATHER
	merge_timer = 0.0
	Sfx.dash()
	_refresh_bag()
	_show_summit_panel()


func _update_merge(dt: float) -> void:
	if merge_phase == PHASE_IDLE:
		return
	merge_timer += dt
	if merge_phase == PHASE_GATHER:
		var t: float = minf(1.0, merge_timer / MERGE_GATHER)
		var eased: float = t * t
		if merge_created != null:
			merge_created.position = merge_created.position.lerp(merge_point, clampf(dt * 6.0, 0.0, 1.0))
			merge_created.scale = Vector3.ONE * INVENTORY_SCALE * (1.0 - 0.7 * eased)
			merge_created.rotation.y += dt * 5.0
		if t >= 1.0:
			merge_phase = PHASE_BURST
			merge_timer = 0.0
			burst_ring.visible = true
			burst_ring.material_override = WorldScreen.standard_material(CrystalTower.crystal_tier_color(theme, merge_created_tier), 2.0)
			burst_light.light_color = CrystalTower.crystal_tier_color(theme, merge_created_tier)
			burst_light.light_energy = 26.0
		return
	if merge_phase == PHASE_BURST:
		var t: float = minf(1.0, merge_timer / MERGE_BURST)
		burst_ring.scale = Vector3.ONE * (0.3 + t * 2.6)
		burst_light.light_energy = 26.0 * (1.0 - t)
		if merge_created != null:
			merge_created.scale = Vector3.ONE * INVENTORY_SCALE * (1.0 + 1.6 * (1.0 - pow(1.0 - t, 3.0)))
			merge_created.rotation.y += dt * 12.0
		if t >= 1.0:
			burst_ring.visible = false
			burst_light.light_energy = 0.0
			merge_phase = PHASE_SETTLE
			merge_timer = 0.0
			_sync_inventory()
			merge_created = null
			_show_summit_panel()
		return
	var t: float = minf(1.0, merge_timer / MERGE_SETTLE)
	if t >= 1.0:
		merge_phase = PHASE_IDLE
		summit_merges += 1
		Sfx.kill()
		_next_merge_step()


# --- summit panel -----------------------------------------------------------

func _show_summit_panel() -> void:
	close_modals()
	if not summit_reached:
		return
	var layer := modal()
	layer.add_child(Ui.backdrop(0.55))

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(center)

	var panel := Ui.panel(Color(0.031, 0.047, 0.086, 0.94), theme["accent"], 16)
	center.add_child(panel)
	var column := Ui.vbox(10)
	panel.add_child(column)

	column.add_child(Ui.title("%s Gipfel erreicht!" % theme["icon"], 32, theme["accent"]))
	column.add_child(Ui.label("%s · Level %d · Zeit: %s · Ziel: %s" % [
		theme["title"], int(config["level"]), CrystalTower.format_time(summit_time), CrystalTower.format_time(float(config["targetMs"])),
	], 16, UiTheme.TEXT_DIM))
	if summit_within_target:
		column.add_child(Ui.label("Ziel geschafft! %s" % ("Level %d ist freigeschaltet." % (int(config["level"]) + 1) if int(config["level"]) < CrystalTower.MAX_LEVEL else "Du bist auf der höchsten Stufe!"), 16, Color("facc15")))
	else:
		column.add_child(Ui.label("Ziel verpasst (%s). Versuch es noch einmal!" % CrystalTower.format_time(float(config["targetMs"])), 16, UiTheme.WARNING))

	# Was der Lauf wirklich gekostet hat: Inventar plus Flussbonus, und wie weit
	# die längste Kette kam — der Teil, den der Spieler beim nächsten Versuch
	# überbieten will.
	column.add_child(Ui.label("Punkte: %d  =  Inventar %d  +  Flussbonus %d" % [
		CrystalTower.run_score(counts, flow_bonus), CrystalTower.inventory_value(counts), flow_bonus,
	], 18, UiTheme.TEXT, true))
	column.add_child(Ui.label("Beste Kette: ×%d %s  ·  Rekord: ×%d" % [
		run_best_flow, CrystalTower.flow_title(run_best_flow), best_flow,
	], 16, UiTheme.TEXT_DIM))
	if flow_record:
		column.add_child(Ui.label("Neuer Kettenrekord!", 16, UiTheme.WARNING))

	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 6)
	column.add_child(grid)
	for tier in range(1, CrystalTower.MAX_CRYSTAL_TIER + 1):
		var color: Color = CrystalTower.crystal_tier_color(theme, tier)
		var cell := Ui.hbox(6)
		grid.add_child(cell)
		cell.add_child(Ui.label("◆ %d× %s" % [int(counts[tier - 1]), CrystalTower.crystal_tier_name(theme, tier)], 16, color, true))
		if int(counts[tier - 1]) > 0:
			var equip := Ui.button("Ausrüsten", Vector2(120, 34), UiTheme.PANEL_LIGHT, func() -> void: _equip(tier))
			cell.add_child(equip)

	var merge_count: int = (CrystalTower.plan_merges(counts)["steps"] as Array).size()
	column.add_child(Ui.button("Verschmelzen (%d×)" % merge_count, Vector2(320, 46), UiTheme.ACCENT, start_merge).with_disabled(merge_phase != PHASE_IDLE or merge_count == 0))
	column.add_child(Ui.label("Bisher verschmolzen: %d×  ·  Aktive Boni: +%d%% Tempo · +%d%% Sprung · %d Extrasprünge" % [
		summit_merges,
		int(round((float(bonus["speedMult"]) - 1.0) * 100.0)),
		int(round((float(bonus["jumpMult"]) - 1.0) * 100.0)),
		int(bonus["extraJumps"]),
	], 14, UiTheme.TEXT_MUTED))

	var actions := Ui.hbox(10)
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_child(actions)
	if summit_within_target and int(config["level"]) < CrystalTower.MAX_LEVEL:
		actions.add_child(Ui.button("Level %d" % (int(config["level"]) + 1), Vector2(200, 50), UiTheme.SUCCESS, func() -> void: _next_level()))
	actions.add_child(Ui.button("Nochmal", Vector2(200, 50), UiTheme.PANEL_LIGHT, func() -> void: Router.go_to(screen_id)))
	actions.add_child(Ui.button("Lobby", Vector2(200, 50), UiTheme.PANEL_LIGHT, func() -> void: Router.to_lobby()))


func _equip(tier: int) -> void:
	if merge_phase != PHASE_IDLE or int(counts[tier - 1]) <= 0:
		return
	counts[tier - 1] = int(counts[tier - 1]) - 1
	Game.set_number("%s_equipped" % str(theme["keyPrefix"]), float(tier))
	equipped_tier = tier
	bonus = CrystalTower.equip_bonus(tier)
	move_speed = BASE_SPEED * float(bonus["speedMult"])
	jump_speed = JUMP_SPEED * float(bonus["jumpMult"])
	pickup_radius = float(bonus["pickupRadius"])
	_sync_inventory()
	_refresh_bag()
	_show_summit_panel()


func _next_level() -> void:
	var prefix := str(theme["keyPrefix"])
	Game.set_number("%s_unlocked" % prefix, maxf(Game.get_number("%s_unlocked" % prefix, 1.0), float(config["level"]) + 1.0))
	Game.set_number("%s_level" % prefix, float(config["level"]) + 1.0)
	Router.go_to(screen_id)


func close_modals() -> void:
	for child in hud_root.get_children():
		if child.has_meta("summit_panel"):
			child.queue_free()


func modal() -> Control:
	var layer := Control.new()
	layer.set_meta("summit_panel", true)
	layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_root.add_child(layer)
	return layer
