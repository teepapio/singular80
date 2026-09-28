class_name DragonRpgScreen
extends WorldScreen
## Drachen-RPG 3D — an action RPG arena: survive dragon waves, level up, loot
## gold and swap weapons. Port of `scenes/DragonRpgScene.ts` plus
## `dragonRpg.ts`.

const ARENA_RADIUS := 32.0
const PLAYER_RADIUS := 0.75
const PLAYER_HALF_HEIGHT := 1.35
const DRAGON_LIMIT := 40
const LABEL_POOL_SIZE := 24
const LOOT_LIMIT := 80
const PROJECTILE_LIMIT := 56
const SPAWN_RADIUS := ARENA_RADIUS - 2.5
const CAMERA_HEIGHT := 17.5
const CAMERA_DISTANCE := 17.0
const SWING_DURATION := 0.28
const INVULN_TIME := 0.6
const PARTICLE_COUNT := 260
const PARTICLE_TOP := 24.0
const PARTICLE_AREA := 70.0

const ENVIRONMENT := [
	{"key": "rpg/pine_tree", "count": 14, "minR": 20.0, "maxR": 30.0, "minS": 0.9, "maxS": 1.6},
	{"key": "rpg/dead_tree", "count": 8, "minR": 20.0, "maxR": 30.0, "minS": 0.9, "maxS": 1.5},
	{"key": "rpg/bush", "count": 12, "minR": 19.0, "maxR": 30.0, "minS": 0.8, "maxS": 1.4},
	{"key": "rpg/rock_small", "count": 12, "minR": 18.0, "maxR": 30.0, "minS": 0.7, "maxS": 1.5},
	{"key": "rpg/rock_large", "count": 6, "minR": 20.0, "maxR": 30.0, "minS": 0.9, "maxS": 1.7},
	{"key": "rpg/grass_tuft", "count": 18, "minR": 17.0, "maxR": 30.0, "minS": 0.9, "maxS": 1.6},
	{"key": "rpg/mushroom", "count": 8, "minR": 18.0, "maxR": 30.0, "minS": 0.9, "maxS": 1.4},
	{"key": "rpg/stalagmite", "count": 8, "minR": 20.0, "maxR": 30.0, "minS": 0.8, "maxS": 1.6},
	{"key": "rpg/crystal_cluster", "count": 8, "minR": 19.0, "maxR": 30.0, "minS": 0.8, "maxS": 1.5},
	{"key": "rpg/broken_pillar", "count": 6, "minR": 20.0, "maxR": 30.0, "minS": 0.9, "maxS": 1.5},
	{"key": "rpg/gravestone", "count": 5, "minR": 20.0, "maxR": 30.0, "minS": 0.9, "maxS": 1.4},
]

var player_pos := Vector3.ZERO
var player_facing := 0.0
var player: Node3D
var weapon_pivot: Node3D
var weapon_mesh: Node3D
var stats := DragonRpg.base_player_stats()
var weapon: Dictionary = DragonRpg.WEAPONS[0]
var level := 1
var xp := 0
var gold := 0
var kills := 0
var wave := 0
var wave_state := "idle"
var wave_timer := 0.0
var to_spawn := 0
var spawn_timer := 0.0
var boss: Dictionary = {}
var cooldown := 0.0
var swing := 0.0
var invuln := 0.0
var running := true
## The escape burst; the rules live in `DragonRpg.Dash`.
var dash := DragonRpg.Dash.new()
## Set while the dash action is held, so a tap never falls between two frames.
var dash_requested := false
var dragons: Array[Dictionary] = []
var loot: Array[Dictionary] = []
## The best drop of each kind so far, so a new pickup can be compared against it.
var best_loot: Dictionary = {}
## Everything currently drawn with a pooled Label3D.
var _floating: Array[Dictionary] = []
var projectiles: Array[Dictionary] = []
var heart_light: OmniLight3D
var particles: MultiMeshInstance3D
var particle_data := PackedFloat32Array()
var particle_speeds := PackedFloat32Array()

var _stick: VirtualStick
var _wave_label: Label
var _level_label: Label
var _gold_label: Label
var _weapon_label: Label
var _kills_label: Label
var _loot_label: Label
var _hp_bar: ProgressBar
var _hp_text: Label
var _xp_bar: ProgressBar
var _xp_text: Label
var _dash_bar: ProgressBar
var _dash_text: Label
var _dash_button: Button
var _boss_box: Control
var _boss_name: Label
var _boss_bar: ProgressBar
var _over_layer: Control
var _aim := Vector3.ZERO
## Pre-allocated pool of world-space labels; see `_push_label`.
var _label_pool: Array[Label3D] = []


func _ready_world() -> void:
	_setup_theme()
	_build_arena()
	_build_scenery()
	_build_player()
	_build_particles()
	_build_label_pool()
	_build_ui()
	_next_wave.call_deferred()
	hide_loading()


func _setup_theme() -> void:
	set_fog(Color("160a08"), 0.014)
	set_ambient(Color("ffc48a"), 0.7)
	sun.light_color = Color("ffe0b8")
	sun.light_energy = 1.25
	fill.light_color = Color("ff8a5c")
	fill.light_energy = 0.4
	camera.fov = 58.0
	camera.far = 320.0

	heart_light = OmniLight3D.new()
	heart_light.light_color = Color("ff6a3d")
	heart_light.light_energy = 26.0
	heart_light.omni_range = 34.0
	add_child(heart_light)


func _build_arena() -> void:
	var ground := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = ARENA_RADIUS
	mesh.bottom_radius = ARENA_RADIUS
	mesh.height = 0.4
	mesh.radial_segments = 64
	ground.mesh = mesh
	ground.material_override = WorldScreen.standard_material(Color("3a2a22"))
	ground.position.y = -0.2
	add_child(ground)

	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = ARENA_RADIUS - 0.6
	torus.outer_radius = ARENA_RADIUS - 0.2
	ring.mesh = torus
	ring.material_override = WorldScreen.standard_material(Color("ff6a3d"), 1.2)
	ring.position.y = 0.1
	add_child(ring)

	var altar := WorldScreen.mesh("rpg/portal_gate", Color("f97316"), 2.0, 0.6)
	if altar != null:
		altar.position = Vector3(0, 0, -ARENA_RADIUS + 3.0)
		add_child(altar)
	var brazier := WorldScreen.mesh("rpg/campfire", Color("ff9a4d"), 1.4, 0.8)
	if brazier != null:
		brazier.position = Vector3(0, 0, ARENA_RADIUS - 4.0)
		add_child(brazier)


func _build_scenery() -> void:
	for spec in ENVIRONMENT:
		for i in int(spec["count"]):
			var angle := randf() * TAU
			var radius: float = float(spec["minR"]) + randf() * (float(spec["maxR"]) - float(spec["minR"]))
			var node := WorldScreen.mesh(str(spec["key"]), Color.WHITE, randf() * 2.0)
			if node == null:
				continue
			node.position = Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
			node.rotation.y = randf() * TAU
			node.scale = Vector3.ONE * (float(spec["minS"]) + randf() * (float(spec["maxS"]) - float(spec["minS"])))
			add_child(node)


func _build_player() -> void:
	player = Node3D.new()
	var knight := WorldScreen.mesh("rpg/knight", Color("cbd5e1"), 1.0)
	if knight == null:
		var capsule := MeshInstance3D.new()
		var mesh := CapsuleMesh.new()
		mesh.radius = 0.5
		mesh.height = 1.8
		capsule.mesh = mesh
		capsule.material_override = WorldScreen.standard_material(Color("cbd5e1"))
		capsule.position.y = 0.9
		player.add_child(capsule)
	else:
		player.add_child(knight)
	weapon_pivot = Node3D.new()
	weapon_pivot.position = Vector3(0.55, 1.1, -0.35)
	player.add_child(weapon_pivot)
	_equip_weapon(weapon)
	add_child(player)

	heart_light.position = Vector3(0, 3.0, 0)


func _equip_weapon(next_weapon: Dictionary) -> void:
	weapon = next_weapon
	if weapon_mesh != null:
		weapon_mesh.queue_free()
	weapon_mesh = WorldScreen.mesh(str(weapon["asset"]), weapon["color"], float(weapon["scale"]))
	if weapon_mesh == null:
		var box := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(0.12, 0.12, 1.4)
		box.mesh = mesh
		box.material_override = WorldScreen.standard_material(weapon["color"])
		weapon_mesh = box
	weapon_pivot.add_child(weapon_mesh)


## Floating damage numbers and loot verdicts share one pool, so a busy fight
## never allocates a node mid-frame.
func _build_label_pool() -> void:
	for i in LABEL_POOL_SIZE:
		var label := Label3D.new()
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.fixed_size = true
		label.outline_size = 12
		label.outline_modulate = Color("020617")
		label.visible = false
		label.font_size = 96
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
	node.outline_size = 24
	node.font_size = int(size)
	node.outline_render_priority = 1
	node.position = at
	node.visible = true
	_floating.append({"node": node, "life": life, "max_life": life})


## Ages every floating label and hides the expired ones. Called once per frame
## with the same delta the rest of the world uses.
func _update_floating(dt: float) -> void:
	for i in range(_floating.size() - 1, -1, -1):
		var entry: Dictionary = _floating[i]
		entry["life"] = float(entry["life"]) - dt
		var node: Label3D = entry["node"]
		node.position += Vector3(0, dt * 1.4, 0)
		node.modulate.a = clampf(float(entry["life"]) / maxf(0.01, float(entry["max_life"])), 0.0, 1.0)
		if float(entry["life"]) <= 0.0:
			node.visible = false
			_floating.remove_at(i)


func _build_particles() -> void:
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
	particles.material_override = WorldScreen.standard_material(Color("fb923c"), 0.75)
	add_child(particles)
	particle_data = PackedFloat32Array()
	particle_data.resize(PARTICLE_COUNT * 3)
	particle_speeds = PackedFloat32Array()
	particle_speeds.resize(PARTICLE_COUNT)
	for i in PARTICLE_COUNT:
		particle_data[i * 3] = randf_range(-0.5, 0.5) * PARTICLE_AREA
		particle_data[i * 3 + 1] = randf() * PARTICLE_TOP
		particle_data[i * 3 + 2] = randf_range(-0.5, 0.5) * PARTICLE_AREA
		particle_speeds[i] = 0.8 + randf() * 1.6


func _build_ui() -> void:
	_stick = add_stick("bottom_left")
	add_action_button("⚔", 74.0, "fire")
	_dash_button = add_action_button("»", 54.0, "dash")
	_dash_button.position = _dash_button.position + Vector2(-140, -70)

	var column := VBoxContainer.new()
	column.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	column.position = Vector2(20, 74)
	column.custom_minimum_size = Vector2(280, 0)
	column.add_theme_constant_override("separation", 2)
	hud_root.add_child(column)
	column.add_child(Ui.label("☄  DRACHEN-RPG 3D", 22, UiTheme.TEXT, true))
	_wave_label = _value(column, "Welle", "0")
	_level_label = _value(column, "Level", "1")
	_gold_label = _value(column, "Gold", "0", Color("fbbf24"))
	_weapon_label = _value(column, "Waffe", str(weapon["name"]))
	_kills_label = _value(column, "Kills", "0")
	_loot_label = _value(column, "Letzte Beute", "—")

	_hp_bar = Ui.bar(Color("ef4444"), 20.0)
	_hp_bar.position = Vector2(20, 264)
	_hp_bar.size = Vector2(320, 20)
	hud_root.add_child(_hp_bar)
	_hp_text = Ui.label("", 13, UiTheme.TEXT, true)
	_hp_text.position = Vector2(20, 266)
	_hp_text.size = Vector2(320, 18)
	_hp_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud_root.add_child(_hp_text)

	_xp_bar = Ui.bar(Color("38bdf8"), 12.0)
	_xp_bar.position = Vector2(20, 292)
	_xp_bar.size = Vector2(320, 12)
	hud_root.add_child(_xp_bar)
	_xp_text = Ui.label("", 12, UiTheme.TEXT_DIM)
	_xp_text.position = Vector2(20, 294)
	_xp_text.size = Vector2(320, 16)
	_xp_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud_root.add_child(_xp_text)

	_dash_bar = Ui.bar(Color("7dd3fc"), 8.0)
	_dash_bar.position = Vector2(20, 312)
	_dash_bar.size = Vector2(320, 8)
	hud_root.add_child(_dash_bar)
	_dash_text = Ui.label("", 12, UiTheme.TEXT_DIM)
	_dash_text.position = Vector2(20, 322)
	_dash_text.size = Vector2(320, 16)
	_dash_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud_root.add_child(_dash_text)

	_boss_box = Control.new()
	_boss_box.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_boss_box.offset_top = 62
	_boss_box.offset_bottom = 108
	_boss_box.visible = false
	_boss_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_root.add_child(_boss_box)
	_boss_name = Ui.label("", 19, Color("f87171"), true)
	_boss_name.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_boss_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_boss_box.add_child(_boss_name)
	_boss_bar = Ui.bar(Color("ef4444"), 14.0)
	_boss_bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_boss_bar.offset_left = 420
	_boss_bar.offset_right = -420
	_boss_bar.offset_top = 26
	_boss_box.add_child(_boss_bar)

	var hint := Ui.label("Stick bewegen · ⚔ Angriff (auch Auto-Ziel) · » Drachenflucht (kurze Unverwundbarkeit)", 15, UiTheme.TEXT_DIM)
	hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	hint.position = Vector2(0, -130)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud_root.add_child(hint)


func _value(parent: VBoxContainer, caption: String, value: String, color: Color = UiTheme.TEXT) -> Label:
	var row := Ui.hbox(10)
	parent.add_child(row)
	row.add_child(Ui.label(caption, 15, UiTheme.TEXT_DIM))
	var spacer := Ui.spacer()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	var result := Ui.label(value, 19, color, true)
	row.add_child(result)
	return result


# --- waves ------------------------------------------------------------------

func _next_wave() -> void:
	if not running:
		return
	wave += 1
	var config := DragonRpg.wave_config(wave)
	to_spawn = int(config["count"])
	wave_state = "spawning"
	spawn_timer = 0.2
	if bool(config["boss"]):
		_spawn_boss(config)
	Sfx.hurt()


func _spawn_boss(config: Dictionary) -> void:
	var type: Variant = config["bossType"]
	if type == null:
		return
	var dragon := _spawn_dragon(type as Dictionary, config, Vector3(0, 0, -SPAWN_RADIUS + 2.0))
	boss = {"dragon": dragon, "name": str((type as Dictionary)["name"]), "type": type}
	_boss_box.visible = true
	_boss_name.text = "☠  %s" % str((type as Dictionary)["name"])


func _spawn_dragon(type: Dictionary, config: Dictionary, at: Vector3) -> Dictionary:
	var scaled := DragonRpg.scaled_dragon(type, config)
	var node := WorldScreen.mesh(str(type["asset"]), type["color"], float(type["scale"]), 0.25)
	if node == null:
		var box := MeshInstance3D.new()
		var mesh := CapsuleMesh.new()
		mesh.radius = float(type["radius"]) * 0.7
		mesh.height = float(type["radius"]) * 2.4
		box.mesh = mesh
		box.material_override = WorldScreen.standard_material(type["color"])
		node = box
	node.position = at
	add_child(node)
	var dragon := {
		"type": type,
		"node": node,
		"hp": float(scaled["hp"]),
		"max_hp": float(scaled["hp"]),
		"speed": float(scaled["speed"]),
		"damage": float(scaled["damage"]),
		"radius": float(type["radius"]),
		"flying": bool(type["flying"]),
		"xp": int(type["xp"]),
		"gold": int(type["gold"]),
		"boss": bool(type["boss"]),
		"phase": randf() * TAU,
	}
	dragons.append(dragon)
	return dragon


func _random_spawn_point() -> Vector3:
	var angle := randf() * TAU
	return Vector3(cos(angle) * SPAWN_RADIUS, 0.0, sin(angle) * SPAWN_RADIUS)


# --- loop -------------------------------------------------------------------

func _update_world(delta: float) -> void:
	var dt: float = minf(delta, 0.05)
	if not running:
		return
	invuln = maxf(0.0, invuln - dt)
	# The dash owns a slice of that invulnerability, so it is merged into the
	# hurt timer here instead of competing with it.
	invuln = maxf(invuln, dash.iframes())
	cooldown = maxf(0.0, cooldown - dt)
	swing = maxf(0.0, swing - dt)
	dash.tick(dt)

	_update_waves(dt)
	_update_player(dt)
	_update_dragons(dt)
	_update_projectiles(dt)
	_update_loot(dt)
	_update_floating(dt)
	_update_particles(dt)
	_update_hud()

	camera.position = camera.position.lerp(Vector3(player_pos.x, CAMERA_HEIGHT, player_pos.z + CAMERA_DISTANCE), clampf(dt * 6.0, 0.0, 1.0))
	camera.look_at(player_pos + Vector3(0, 1.0, 0), Vector3.UP)
	heart_light.position = player_pos + Vector3(0, 2.5, 0)
	heart_light.light_energy = 22.0 + sin(elapsed * 3.0) * 4.0


func _update_waves(dt: float) -> void:
	if wave_state == "spawning":
		spawn_timer -= dt
		while spawn_timer <= 0.0 and to_spawn > 0 and dragons.size() < DRAGON_LIMIT:
			spawn_timer += 0.35
			to_spawn -= 1
			var config := DragonRpg.wave_config(wave)
			var pool: Array = config["pool"]
			if pool.is_empty():
				break
			var type: Dictionary = pool[randi() % pool.size()]
			_spawn_dragon(type, config, _random_spawn_point())
		if to_spawn <= 0:
			wave_state = "fighting"
	elif wave_state == "fighting":
		if dragons.is_empty():
			wave_state = "cleared"
			wave_timer = 1.6
	elif wave_state == "cleared":
		wave_timer -= dt
		if wave_timer <= 0.0:
			_next_wave()


func _update_player(dt: float) -> void:
	var move_vector := VirtualStick.combined(_stick.value, &"move_left", &"move_right")
	# A tap on the round » button can be shorter than a frame, so the press is
	# latched instead of read as an edge — the attack is read as a level, too.
	if Input.is_action_pressed("dash"):
		dash_requested = true
	if dash_requested:
		dash_requested = false
		_dash(move_vector)
	var step := dash.step(dt, stats.move_speed)
	if step.length() > 0.0:
		# During the burst the stick is ignored — the player has committed.
		player_facing = atan2(dash.direction.x, dash.direction.z)
	elif move_vector.length() > 0.05:
		step = Vector3(move_vector.x, 0.0, move_vector.y) * stats.move_speed * dt
		player_facing = atan2(move_vector.x, move_vector.y)
	player_pos += step
	# Neither walking nor dashing leaves the arena.
	var length := player_pos.length()
	if length > ARENA_RADIUS - PLAYER_RADIUS:
		player_pos = player_pos.normalized() * (ARENA_RADIUS - PLAYER_RADIUS)

	# Auto-aim at the closest dragon; the player only chooses when to swing.
	var target := _closest_dragon()
	if target.is_empty():
		_aim = Vector3(sin(player_facing), 0.0, cos(player_facing))
	else:
		_aim = ((target["node"] as Node3D).global_position - player_pos).normalized()
		# The auto-aim must not turn the knight back around mid-dash.
		if move_vector.length() < 0.05 and dash.time_left <= 0.0:
			player_facing = atan2(_aim.x, _aim.z)
		if Input.is_action_pressed("fire"):
			_attack()
	player.position = player_pos
	player.rotation.y = player_facing
	weapon_pivot.rotation.y = sin(elapsed * 6.0) * (0.8 if swing > 0.0 else 0.0)
	if invuln > 0.0:
		player.visible = int(invuln * 14.0) % 2 == 0
	else:
		player.visible = true


## Starts the escape burst. Fleeing away from the closest dragon is the
## fallback, so the button still does the right thing when the stick is idle —
## which is exactly the moment a player reaches for it.
func _dash(move_vector: Vector2) -> void:
	var to_threat := Vector2.ZERO
	var threat := _closest_dragon()
	if not threat.is_empty():
		var offset: Vector3 = (threat["node"] as Node3D).global_position - player_pos
		to_threat = Vector2(offset.x, offset.z)
	var facing := Vector3(sin(player_facing), 0.0, cos(player_facing))
	if not dash.start(DragonRpg.dash_direction(move_vector, to_threat, facing)):
		return
	Sfx.dash()
	_push_label(player_pos + Vector3(0, 2.6, 0), "»", Color("7dd3fc"), 0.5, 110.0)


func _closest_dragon() -> Dictionary:
	var best: Dictionary = {}
	var best_distance := 1e9
	for dragon in dragons:
		var distance := player_pos.distance_squared_to((dragon["node"] as Node3D).global_position)
		if distance < best_distance:
			best_distance = distance
			best = dragon
	return best


func _attack() -> void:
	if cooldown > 0.0:
		return
	cooldown = float(weapon["cooldown"]) * stats.cooldown_mult
	swing = SWING_DURATION
	var roll := DragonRpg.roll_damage(float(weapon["damage"]), stats)
	if bool(weapon["ranged"]):
		_spawn_projectile(roll["damage"])
		return
	for dragon in dragons.duplicate():
		var node: Node3D = dragon["node"]
		var to_target: Vector3 = node.global_position - player_pos
		if not DragonRpg.in_melee_arc(player_pos.x, player_pos.z, player_facing, to_target.x, to_target.z, float(weapon["range"]), float(weapon["arc"])):
			continue
		_hit_dragon(dragon, int(roll["damage"]), bool(roll["crit"]))
		_push(dragon, 2.2)
	Sfx.hit()


func _spawn_projectile(damage: int) -> void:
	if projectiles.size() >= PROJECTILE_LIMIT:
		projectiles.pop_front()
	var node := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.22
	mesh.height = 0.44
	mesh.radial_segments = 8
	mesh.rings = 5
	node.mesh = mesh
	node.material_override = WorldScreen.standard_material(weapon["color"], 1.2)
	node.position = player_pos + Vector3(0, 1.1, 0) + _aim * 1.0
	add_child(node)
	projectiles.append({"node": node, "velocity": _aim * float(weapon["projectileSpeed"]), "damage": damage, "life": 2.0})


func _update_projectiles(dt: float) -> void:
	for i in range(projectiles.size() - 1, -1, -1):
		var shot: Dictionary = projectiles[i]
		var node: Node3D = shot["node"]
		shot["life"] = float(shot["life"]) - dt
		node.position += Vector3(shot["velocity"]) * dt
		var dead: bool = float(shot["life"]) <= 0.0
		if not dead:
			for dragon in dragons.duplicate():
				var dragon_node: Node3D = dragon["node"]
				if node.global_position.distance_to(dragon_node.global_position) > float(dragon["radius"]) + 0.4:
					continue
				_hit_dragon(dragon, int(shot["damage"]), false)
				_push(dragon, 1.2)
				dead = true
				break
		if dead:
			node.queue_free()
			projectiles.remove_at(i)


func _push(dragon: Dictionary, amount: float) -> void:
	var node: Node3D = dragon["node"]
	var direction: Vector3 = node.global_position - player_pos
	direction.y = 0.0
	if direction.length() < 0.01:
		direction = Vector3.FORWARD
	node.position += direction.normalized() * amount


func _update_dragons(dt: float) -> void:
	for i in range(dragons.size() - 1, -1, -1):
		var dragon: Dictionary = dragons[i]
		var node: Node3D = dragon["node"]
		dragon["phase"] = float(dragon["phase"]) + dt * 2.0
		var to_player: Vector3 = player_pos - node.global_position
		to_player.y = 0.0
		var direction: Vector3 = to_player.normalized()
		node.position += direction * float(dragon["speed"]) * dt
		if bool(dragon["flying"]):
			node.position.y = 1.4 + sin(float(dragon["phase"])) * 0.35
		else:
			node.position.y = 0.0
		if direction.length() > 0.01:
			node.rotation.y = atan2(direction.x, direction.z)
		if to_player.length() < float(dragon["radius"]) + PLAYER_RADIUS + 0.3:
			_touch(dragon)


func _touch(dragon: Dictionary) -> void:
	if invuln > 0.0 or not running:
		return
	var incoming := DragonRpg.mitigate_damage(float(dragon["damage"]), stats.armor)
	stats.hp -= incoming
	invuln = INVULN_TIME
	Sfx.hurt()
	_push(dragon, -2.4)
	if stats.hp <= 0.0:
		_end_run()


func _hit_dragon(dragon: Dictionary, damage: int, crit: bool) -> void:
	dragon["hp"] = float(dragon["hp"]) - float(damage)
	_spawn_damage_label(dragon, damage, crit)
	if float(dragon["hp"]) > 0.0:
		return
	kills += 1
	xp += int(dragon["xp"])
	gold += int(dragon["gold"])
	_drop_loot(dragon)
	while xp >= DragonRpg.xp_to_next(level):
		xp -= DragonRpg.xp_to_next(level)
		level += 1
		stats = stats.leveled_up()
		Sfx.level_up()
	var node: Node3D = dragon["node"]
	node.queue_free()
	dragons.erase(dragon)
	if not boss.is_empty() and boss.get("dragon") == dragon:
		boss = {}
		_boss_box.visible = false
	Sfx.kill()


func _drop_loot(dragon: Dictionary) -> void:
	if loot.size() >= LOOT_LIMIT:
		return
	# A boss rolls with full luck, so killing one genuinely pays off.
	var entry := DragonRpg.roll_loot(DragonRpg.luck_for(dragon))
	var rarity := DragonRpg.rarity_of(entry)
	var color: Color = rarity["color"]
	var node := WorldScreen.mesh(str(entry["asset"]), color, 0.6, 0.5)
	if node == null:
		var box := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(0.4, 0.4, 0.4)
		box.mesh = mesh
		box.material_override = WorldScreen.standard_material(color, 0.4)
		node = box
	var at: Vector3 = (dragon["node"] as Node3D).global_position
	at.y = 0.6
	node.position = at
	add_child(node)

	# Better-than-common drops get a light column and a pulsing ring, so a rare
	# find is visible across the arena instead of hiding among the coins.
	var glow := float(rarity["glow"])
	if glow > 0.0:
		var halo := _build_loot_glow(color, glow)
		halo.position = at
		add_child(halo)
		loot.append({
			"node": halo, "kind": str(entry["kind"]), "value": int(entry["value"]),
			"id": str(entry["id"]), "name": str(entry["name"]), "rarity": str(rarity["id"]),
			"color": color, "glow": glow, "phase": randf() * TAU,
		})
		return
	loot.append({
		"node": node, "kind": str(entry["kind"]), "value": int(entry["value"]),
		"id": str(entry["id"]), "name": str(entry["name"]), "rarity": str(rarity["id"]),
		"color": color, "glow": 0.0, "phase": 0.0,
	})


## A translucent cylinder plus a ground ring that marks a rare drop.
func _build_loot_glow(color: Color, strength: float) -> Node3D:
	var root := Node3D.new()
	var column := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 0.42
	cylinder.bottom_radius = 0.42
	cylinder.height = 1.6
	column.mesh = cylinder
	column.position = Vector3(0, 0.8, 0)
	var material := WorldScreen.standard_material(color, 0.85)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 0.5 + strength * 0.9
	material.albedo_color = Color(color.r, color.g, color.b, 0.16 + strength * 0.05)
	column.material_override = material
	root.add_child(column)

	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.5
	torus.outer_radius = 0.66
	torus.rings = 20
	ring.mesh = torus
	ring.position = Vector3(0, 0.05, 0)
	ring.material_override = WorldScreen.standard_material(color, 0.6)
	root.add_child(ring)
	return root


func _update_loot(dt: float) -> void:
	for i in range(loot.size() - 1, -1, -1):
		var item: Dictionary = loot[i]
		var node: Node3D = item["node"]
		node.rotation.y += dt * 2.0
		node.position.y = 0.6 + sin(elapsed * 3.0 + node.position.x) * 0.15
		if float(item["glow"]) > 0.0:
			# The halo breathes so it reads as "alive" next to static loot.
			var pulse := 1.0 + sin(elapsed * 3.4 + float(item["phase"])) * 0.12
			node.scale = Vector3.ONE * pulse
		if node.global_position.distance_to(player_pos) > stats.pickup_radius:
			continue
		_collect(item)
		node.queue_free()
		loot.remove_at(i)


func _collect(item: Dictionary) -> void:
	var id := str(item.get("id", ""))
	var verdict := ""
	if id != "":
		var previous: Dictionary = best_loot.get(id, {})
		verdict = DragonRpg.compare_drop(item, previous)
		if verdict == "upgrade" or previous.is_empty():
			best_loot[id] = {"value": int(item["value"]), "rarity": str(item["rarity"])}
	match str(item["kind"]):
		"gold", "treasure":
			gold += int(item["value"])
			Sfx.coin()
		"potion":
			stats.hp = minf(stats.max_hp, stats.hp + float(item["value"]))
			Sfx.level_up()
		_:
			Sfx.coin()
	_announce_loot(item, verdict)


## Records the pickup in the HUD and floats a short verdict above the player.
func _announce_loot(item: Dictionary, verdict: String) -> void:
	var rarity := DragonRpg.rarity_by_id(str(item.get("rarity", "common")))
	var name_text := str(item.get("name", "?"))
	if _loot_label != null:
		_loot_label.text = "%s  ·  %s" % [name_text, str(rarity["name"])]
		_loot_label.add_theme_color_override("font_color", rarity["color"])
	if verdict == "":
		return
	var arrow := "▲ " if verdict == "upgrade" else ("▼ " if verdict == "downgrade" else "= ")
	_push_label(player_pos + Vector3(0, 2.4, 0), arrow + name_text, rarity["color"], 1.2, 90.0)


func _spawn_damage_label(dragon: Dictionary, damage: int, crit: bool) -> void:
	var node: Node3D = dragon["node"]
	var color := Color("fde047") if crit else Color("f8fafc")
	_push_label(node.global_position + Vector3(0, 2.0, 0), str(damage), color, 0.7, 150.0 if crit else 110.0)


func _update_particles(dt: float) -> void:
	for i in PARTICLE_COUNT:
		var y: float = particle_data[i * 3 + 1] - particle_speeds[i] * dt
		if y < 0.0:
			y = PARTICLE_TOP
		particle_data[i * 3 + 1] = y
	if particles == null or particles.multimesh == null:
		return
	for i in PARTICLE_COUNT:
		particles.multimesh.set_instance_transform(i, Transform3D(Basis.IDENTITY, Vector3(
			particle_data[i * 3], particle_data[i * 3 + 1], particle_data[i * 3 + 2])))


func _update_hud() -> void:
	_wave_label.text = str(wave)
	_level_label.text = str(level)
	_gold_label.text = Ui.format_number(gold)
	_weapon_label.text = str(weapon["name"])
	_kills_label.text = str(kills)
	Ui.set_bar(_hp_bar, clampf(stats.hp / maxf(1.0, stats.max_hp), 0.0, 1.0), Color("ef4444"))
	_hp_text.text = "%d / %d" % [int(ceil(stats.hp)), int(stats.max_hp)]
	var need := DragonRpg.xp_to_next(level)
	Ui.set_bar(_xp_bar, clampf(float(xp) / float(need), 0.0, 1.0), Color("38bdf8"))
	_xp_text.text = "XP %d / %d" % [xp, need]

	# The escape is the one button the player must be able to find without a
	# manual, so it gets its own bar next to HP and XP.
	var charge := dash.charge()
	Ui.set_bar(_dash_bar, charge, Color("7dd3fc") if charge >= 1.0 else Color("334155"))
	_dash_text.text = "» Drachenflucht bereit" if charge >= 1.0 else "» Drachenflucht %.1fs" % dash.cooldown_left
	_dash_button.modulate.a = 1.0 if charge >= 1.0 else 0.45
	if not boss.is_empty():
		var dragon: Dictionary = boss["dragon"]
		_boss_bar.value = clampf(float(dragon["hp"]) / maxf(1.0, float(dragon["max_hp"])), 0.0, 1.0)


func _end_run() -> void:
	if not running:
		return
	running = false
	var score := DragonRpg.score_for(wave, level, gold)
	Game.submit_score(Game.HS_DRAGON, score)
	Sfx.game_over()
	_over_layer = Control.new()
	_over_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_over_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_root.add_child(_over_layer)
	_over_layer.add_child(Ui.backdrop(0.8))
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_over_layer.add_child(center)
	var column := Ui.vbox(12)
	center.add_child(column)
	column.add_child(Ui.title("Gefallen", 46, Color("f87171")))
	column.add_child(Ui.label(Loc.f("Welle %d · Level %d · Gold %s\nKills %d · Score %s", [[
		wave, level, Ui.format_number(gold), kills, Ui.format_number(score)]]), 20, UiTheme.TEXT))
	column.add_child(Ui.button("Nochmal", Vector2(340, 56), UiTheme.ACCENT, func() -> void: Router.go_to(screen_id)))
	column.add_child(Ui.button("Lobby", Vector2(340, 56), UiTheme.PANEL_LIGHT, func() -> void: Router.to_lobby()))
