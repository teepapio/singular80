class_name DragonFlightScreen
extends WorldScreen
## Drachenflug — the 3D flight run. A dragon crosses a landscape from a chase
## camera behind and above it, shooting at everything that flies or stands in
## the way. All rules live in `DragonFlight`; this file only moves meshes.

const PICKUP_POOL := 46
const SHOT_POOL := DragonFlight.MAX_SHOTS
const ENEMY_POOL := DragonFlight.MAX_ENEMIES
const CLOUD_POOL := 12
const ISLAND_POOL := 12
const TRAIL_POOL := 24

var profile: Dictionary = {}
var level_n := 1
var level_def: Dictionary = {}
var dragon: Dictionary = {}
var stats: Dictionary = {}

var running := false
var finished := false
var hp := 100.0
var max_hp := 100.0
var distance := 0.0
var score := 0
var gold := 0
var eggs_found := 0
var kills := 0
var combo := 0
var combo_timer := 0.0

var pos := Vector3(0.0, 11.0, DragonFlight.PLAYER_Z)
var vel := Vector2.ZERO
var invuln := 0.0
var fire_cd := 0.0
var trail_cd := 0.0
var shake := 0.0
var boss_spawned := false
var next_spawn := 0.0

# Timed effects from power-ups, in seconds.
var buff_rapid := 0.0
var buff_shield := 0.0
var buff_magnet := 0.0

var enemies: Array[Dictionary] = []
var shots: Array[Dictionary] = []
var pickups: Array[Dictionary] = []
var clouds: Array[Dictionary] = []
var islands: Array[Dictionary] = []
var props: Array[Dictionary] = []
var trail: Array[Dictionary] = []

var dragon_node: Node3D
var dragon_scale := 1.0
var dragon_color := Color.WHITE
var wing_l: Node3D
var wing_r: Node3D
var tail_nodes: Array[Node3D] = []
var breath: MeshInstance3D
var flap := 0.0

var _stick: VirtualStick
var _hp_bar: ProgressBar
var _hud: VBoxContainer
var _label_score: Label
var _label_gold: Label
var _label_level: Label
var _label_trait: Label
var _label_buff: Label
var _over: Control
var _banner: Label
var _banner_timer := 0.0


func _ready_world() -> void:
	profile = DragonFlight.load_profile()
	level_n = clampi(int(data.get("level", 1)), 1, DragonFlight.level_count())
	level_def = DragonFlight.level(level_n)
	dragon = DragonFlight.active_dragon(profile)
	if dragon.is_empty():
		dragon = DragonFlight.random_dragon(1, ["ember"])
		profile["dragons"] = [dragon]
		profile["active"] = dragon["uid"]
	stats = DragonFlight.resolve_stats(dragon, profile.get("upgrades", {}))
	max_hp = float(stats["max_hp"])
	hp = max_hp

	_setup_theme()
	_build_landscape()
	_build_dragon()
	_build_pools()
	_build_ui()
	hide_loading()
	_begin()


func _setup_theme() -> void:
	var biome := DragonFlight.biome_by_id(str(level_def["biome"]))
	# Light fog only: the corridor has to stay readable up to the spawn distance.
	set_fog(Color(str(biome["fog"])), 0.0032)
	set_ambient(Color(str(biome["ambient"])), 0.75)
	sun.light_color = Color("fff6e0")
	sun.light_energy = 1.45
	fill.light_color = Color(str(biome["accent"]))
	fill.light_energy = 0.5
	camera.fov = 58.0
	camera.far = 460.0
	camera.position = Vector3(0.0, 15.0, 19.0)


## A wide ground band far below plus floating islands: the player never touches
## anything, so the landscape only has to read as motion.
func _build_landscape() -> void:
	var biome := DragonFlight.biome_by_id(str(level_def["biome"]))
	var ground := MeshInstance3D.new()
	var ground_mesh := BoxMesh.new()
	# Long enough that its far edge never shows as a hard line at the horizon.
	ground_mesh.size = Vector3(420.0, 1.0, 2600.0)
	ground.mesh = ground_mesh
	ground.material_override = WorldScreen.standard_material(Color(str(biome["ground"])))
	ground.position = Vector3(0.0, -14.0, -900.0)
	add_child(ground)

	for i in ISLAND_POOL:
		var key := "flight/island" if randf() < 0.7 else ("rpg/pine_tree" if randf() < 0.5 else "rpg/dead_tree")
		var node := WorldScreen.mesh(key, Color(str(biome["ground"])).lightened(0.12), randf_range(1.6, 4.2))
		if node == null:
			continue
		node.position = Vector3(randf_range(-90.0, 90.0), randf_range(-11.0, -4.0), randf_range(DragonFlight.SPAWN_Z, 0.0))
		node.rotation.y = randf() * TAU
		add_child(node)
		islands.append({"node": node, "z": node.position.z})

	for i in CLOUD_POOL:
		props.append({"node": _cloud_node(), "kind": "cloud", "z": 0.0, "x": 0.0})
	# Waypoint totems give the corridor a readable rhythm.
	for i in 7:
		var totem := WorldScreen.mesh("flight/totem", Color.WHITE, 1.0)
		if totem == null:
			continue
		var side: float = 1.0 if randf() < 0.5 else -1.0
		totem.position = Vector3(side * (DragonFlight.ARENA_HALF_WIDTH + 2.5), -2.0, -60.0 - float(i) * 90.0)
		add_child(totem)
		props.append({"node": totem, "kind": "totem", "z": totem.position.z, "x": totem.position.x})


## Clouds are scenery, not obstacles: they sit off to the sides and high up so
## they frame the corridor instead of hiding what flies through it.
func _cloud_node() -> Node3D:
	var stormy: bool = str(level_def["biome"]) in ["sturm", "nacht", "vulkan"]
	var node := WorldScreen.mesh("flight/cloud_storm" if stormy else "flight/cloud", Color.WHITE, randf_range(1.4, 2.8))
	if node == null:
		var box := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(9.0, 3.0, 5.0)
		box.mesh = mesh
		box.material_override = WorldScreen.standard_material(Color("e2e8f0"))
		node = box
	var side: float = 1.0 if randf() < 0.5 else -1.0
	node.position = Vector3(side * randf_range(34.0, 80.0), randf_range(14.0, 30.0), randf_range(DragonFlight.SPAWN_Z, 0.0))
	add_child(node)
	return node


## Builds the player's dragon from its breed mesh and caches the animated parts.
func _build_dragon() -> void:
	dragon_node = Node3D.new()
	var breed: Dictionary = stats["breed"]
	var body := WorldScreen.mesh(str(breed["asset"]), Color.WHITE, 1.0)
	if body != null:
		dragon_node.add_child(body)
		wing_l = _part(body, "DragonWingL")
		wing_r = _part(body, "DragonWingR")
		for name in ["DragonTailA", "DragonTailB", "DragonTailC"]:
			var node := _part(body, str(name))
			if node != null:
				tail_nodes.append(node)
		var accent := Color(str(breed["accent"]))
		_tint_parts(body, Color(str(breed["body"])), Color(str(breed["belly"])), accent)
	else:
		# Fallback primitive so a missing mesh never blocks a run.
		var box := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(1.4, 1.0, 2.6)
		box.mesh = mesh
		box.material_override = WorldScreen.standard_material(Color(str(breed["body"])))
		dragon_node.add_child(box)
	add_child(dragon_node)

	dragon_scale = DragonFlight.visual_scale(dragon)
	dragon_color = Color(str(breed["body"]))
	pos = Vector3(0.0, 11.0, DragonFlight.PLAYER_Z)
	dragon_node.position = pos

	breath = MeshInstance3D.new()
	var ball := SphereMesh.new()
	ball.radius = 0.3
	ball.height = 0.6
	ball.radial_segments = 8
	ball.rings = 4
	breath.mesh = ball
	breath.material_override = WorldScreen.standard_material(Color(str(breed["accent"])), 2.4)
	breath.scale = Vector3.ONE * float(stats["shot_size"])
	breath.visible = false
	dragon_node.add_child(breath)


## The Blender dragon is built from named parts; recolour them by role so one
## breed reads differently from the next even when the mesh is shared.
func _tint_parts(root: Node, body: Color, belly: Color, accent: Color) -> void:
	for child in root.get_children():
		if child is GeometryInstance3D:
			var geometry := child as GeometryInstance3D
			var part := str(child.name)
			var color := body
			if part.contains("Belly") or part.contains("Jaw") or part.contains("Snout"):
				color = belly
			elif part.contains("Eye") or part.contains("Horn") or part.contains("Spike") or part.contains("Crest") or part.contains("Fin") or part.contains("Strut"):
				color = accent
			geometry.material_override = WorldScreen.standard_material(color, 1.6 if part.contains("Eye") else 0.0)
		_tint_parts(child, body, belly, accent)


func _part(root: Node, node_name: String) -> Node3D:
	if str(root.name) == node_name and root is Node3D:
		return root as Node3D
	for child in root.get_children():
		var found := _part(child, node_name)
		if found != null:
			return found
	return null


func _build_pools() -> void:
	for i in ENEMY_POOL:
		enemies.append({"node": null, "active": false, "kind": "", "hp": 1.0, "max_hp": 1.0,
			"x": 0.0, "y": 0.0, "z": 0.0, "phase": 0.0, "poison": 0.0, "boss": false})
	for i in SHOT_POOL:
		shots.append({"node": null, "active": false, "x": 0.0, "y": 0.0, "z": 0.0, "vx": 0.0, "vy": 0.0,
			"damage": 1.0, "crit": false, "poison": false, "radius": 0.4, "life": 0.0})
	for i in PICKUP_POOL:
		pickups.append({"node": null, "active": false, "id": "", "x": 0.0, "y": 0.0, "z": 0.0, "phase": 0.0})
	for i in TRAIL_POOL:
		var puff := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.12
		sphere.height = 0.24
		sphere.radial_segments = 5
		sphere.rings = 3
		puff.mesh = sphere
		var material := WorldScreen.standard_material(Color(str(stats["breed"]["accent"])), 0.0)
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.albedo_color.a = 0.28
		puff.material_override = material
		puff.visible = false
		add_child(puff)
		trail.append({"node": puff, "active": false, "life": 0.0})


func _begin() -> void:
	running = true
	finished = false
	_banner_text("Level %d · %s" % [level_n, str(level_def["name"])], 2.0)


# --- HUD --------------------------------------------------------------------

func _build_ui() -> void:
	_stick = add_stick("bottom_left", "Flug")
	add_action_button("◈", 66.0, &"fire")

	_hud = VBoxContainer.new()
	_hud.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_hud.position = Vector2(20, 74)
	_hud.custom_minimum_size = Vector2(330, 0)
	_hud.add_theme_constant_override("separation", 3)
	hud_root.add_child(_hud)

	_label_level = Ui.label("Level %d · %s" % [level_n, str(level_def["name"])], 21, Color(str(DragonFlight.biome_by_id(str(level_def["biome"]))["accent"])), true)
	_hud.add_child(_label_level)

	_hp_bar = Ui.bar(Color("ef4444"), 16.0)
	_hud.add_child(_hp_bar)

	_label_score = _value(_hud, "Punkte", "0", Color("facc15"))
	_label_gold = _value(_hud, "Gold", "0", Color("fbbf24"))
	_label_trait = _value(_hud, "Merkmale", "—", Color("c084fc"))
	_label_buff = _value(_hud, "Effekt", "—", Color("38bdf8"))

	_banner = Ui.label("", 30, Color.WHITE, true)
	_banner.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_banner.offset_left = -420.0
	_banner.offset_right = 420.0
	# Below the status block, so the two never overlap.
	_banner.offset_top = 232.0
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_banner.add_theme_constant_override("outline_size", 6)
	_banner.modulate.a = 0.0
	hud_root.add_child(_banner)

	var hint := Ui.label("Stick lenkt · ◈ feuert", 15, UiTheme.TEXT_DIM)
	hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	hint.position = Vector2(0, -132)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud_root.add_child(hint)


func _value(parent: VBoxContainer, caption: String, value: String, color: Color) -> Label:
	var row := Ui.hbox(10)
	parent.add_child(row)
	row.add_child(Ui.label(caption, 15, UiTheme.TEXT_DIM))
	row.add_child(Ui.spacer())
	var result := Ui.label(value, 19, color, true)
	row.add_child(result)
	return result


func _banner_text(text: String, seconds: float) -> void:
	_banner.text = text
	_banner_timer = seconds
	_banner.modulate.a = 1.0


# --- loop -------------------------------------------------------------------

func _update_world(delta: float) -> void:
	var dt: float = minf(delta, 0.05)
	_tick_banner(dt)
	if not running:
		return

	var level_scroll: float = float(level_def["scroll"])
	var move: Vector2 = VirtualStick.combined(_stick.value, &"move_left", &"move_right")
	if absf(move.x) > 0.12:
		vel.x = move.x
	elif absf(move.y) > 0.12:
		vel.y = move.y
	else:
		vel = vel.lerp(Vector2.ZERO, clampf(dt * 6.0, 0.0, 1.0))

	_move_player(dt)
	_update_fire(dt)
	_update_shots(dt, level_scroll)
	_update_spawns(dt, level_scroll)
	_update_enemies(dt, level_scroll)
	_update_pickups(dt, level_scroll)
	_update_world_props(dt, level_scroll)
	_update_trail(dt)
	_update_camera(dt)
	_update_timers(dt)
	_update_hud()
	_check_end()


## The corridor clamps position instead of bouncing, so the dragon never sticks
## to a wall.
func _move_player(dt: float) -> void:
	var speed: float = float(stats["speed"])
	pos.x += vel.x * speed * dt
	pos.y += vel.y * speed * dt
	pos.x = clampf(pos.x, -DragonFlight.ARENA_HALF_WIDTH, DragonFlight.ARENA_HALF_WIDTH)
	pos.y = clampf(pos.y, DragonFlight.FLOOR, DragonFlight.CEILING)
	# Banking: the dragon leans into the turn, which reads as flight.
	var bank: float = clampf(-vel.x * 0.34, -0.55, 0.55)
	var pitch: float = clampf(vel.y * 0.22, -0.32, 0.32)
	dragon_node.position = pos
	dragon_node.rotation = dragon_node.rotation.lerp(Vector3(pitch, 0.0, bank), clampf(dt * 8.0, 0.0, 1.0))
	dragon_node.scale = Vector3.ONE * dragon_scale
	_animate_dragon(dt)


## Flap rate follows the flight speed, so a fast dragon beats its wings visibly
## faster than a slow one.
func _animate_dragon(dt: float) -> void:
	var rate: float = 3.0 + float(stats["speed"]) * 0.22
	flap += dt * rate
	var beat: float = sin(flap)
	if wing_l != null:
		wing_l.rotation.z = -beat * 0.5
	if wing_r != null:
		wing_r.rotation.z = beat * 0.5
	for i in tail_nodes.size():
		var node: Node3D = tail_nodes[i]
		node.rotation.x = node.rotation.x + sin(flap * 0.7 - float(i) * 0.6) * dt * 1.6


func _update_fire(dt: float) -> void:
	fire_cd = maxf(0.0, fire_cd - dt)
	if Input.is_action_pressed("fire") and fire_cd <= 0.0:
		_shoot()


func _shoot() -> void:
	var rate: float = float(stats["fire_rate"])
	if buff_rapid > 0.0:
		rate *= 0.4
	fire_cd = rate
	var roll := DragonFlight.roll_shot(stats, 1.0)
	for shot in shots:
		if bool(shot["active"]):
			continue
		var node := _mesh_for(shot, "flight/fireball", dragon_color.lightened(0.4), float(stats["shot_size"]) * 2.2, 1.4)
		shot["active"] = true
		shot["x"] = pos.x
		shot["y"] = pos.y + 0.6
		shot["z"] = pos.z - 2.2
		shot["damage"] = float(roll["damage"])
		shot["crit"] = bool(roll["crit"])
		shot["poison"] = float(stats["poison"]) > 0.0
		shot["radius"] = 0.55 * float(stats["shot_size"])
		shot["life"] = 2.4
		shot["node"] = node
		break
	Sfx.shoot()


func _update_shots(dt: float, _scroll: float) -> void:
	var shot_speed: float = float(stats["shot_speed"])
	for shot in shots:
		if not bool(shot["active"]):
			continue
		shot["z"] = float(shot["z"]) - shot_speed * dt
		shot["life"] = float(shot["life"]) - dt
		var node: Node3D = shot["node"]
		node.position = Vector3(float(shot["x"]), float(shot["y"]), float(shot["z"]))
		if float(shot["life"]) <= 0.0 or float(shot["z"]) < DragonFlight.SPAWN_Z:
			_release(shot)
			continue
		for enemy in enemies:
			if not bool(enemy["active"]):
				continue
			if _hits(float(shot["x"]), float(shot["y"]), float(shot["z"]), float(shot["radius"]), enemy):
				_damage_enemy(enemy, float(shot["damage"]), bool(shot["poison"]))
				_release(shot)
				break


func _update_spawns(dt: float, scroll: float) -> void:
	next_spawn -= scroll * dt
	if next_spawn <= 0.0:
		next_spawn = DragonFlight.spawn_gap(level_def)
		_spawn_enemy()
	if not boss_spawned and distance >= float(level_def["length"]) * 0.82:
		_spawn_boss()


func _spawn_enemy() -> void:
	var kind := DragonFlight.pick_enemy(level_def)
	var alive := 0
	for enemy in enemies:
		if bool(enemy["active"]):
			alive += 1
	if alive >= DragonFlight.concurrent_for(level_n):
		return
	for enemy in enemies:
		if bool(enemy["active"]):
			continue
		_activate_enemy(enemy, kind)
		return


func _spawn_boss() -> void:
	var boss_id := str(level_def.get("boss", ""))
	if boss_id.is_empty():
		return
	boss_spawned = true
	_activate_enemy(_free_enemy(), DragonFlight.enemy_by_id(boss_id))
	_banner_text("BOSS", 1.6)
	Sfx.game_over()


func _free_enemy() -> Dictionary:
	for enemy in enemies:
		if not bool(enemy["active"]):
			return enemy
	return enemies[0]


func _activate_enemy(enemy: Dictionary, kind: Dictionary) -> void:
	var hp_mult: float = float(level_def["hpMult"])
	var node := _mesh_for(enemy, str(kind["asset"]), Color(str(kind["color"])), float(kind["size"]), 1.0)
	enemy["active"] = true
	enemy["kind"] = str(kind["id"])
	enemy["boss"] = bool(kind.get("boss", false))
	enemy["max_hp"] = float(kind["hp"]) * hp_mult
	enemy["hp"] = enemy["max_hp"]
	enemy["x"] = randf_range(-DragonFlight.ARENA_HALF_WIDTH, DragonFlight.ARENA_HALF_WIDTH)
	enemy["y"] = randf_range(6.0, 20.0) if bool(kind["flying"]) else randf_range(0.5, 3.0)
	enemy["z"] = DragonFlight.SPAWN_Z
	enemy["phase"] = randf() * TAU
	enemy["poison"] = 0.0
	enemy["node"] = node
	node.scale = Vector3.ONE * float(kind["size"]) * (1.35 if enemy["boss"] else 1.0)


## Movement per behaviour. Everything converges on the player, but from
## different angles, so a corridor full of enemies stays readable.
func _update_enemies(dt: float, scroll: float) -> void:
	var dmg_mult: float = float(level_def["damageMult"])
	var speed_mult: float = float(level_def["speedMult"])
	for enemy in enemies:
		if not bool(enemy["active"]):
			continue
		var kind := DragonFlight.enemy_by_id(str(enemy["kind"]))
		var behavior := str(kind["behavior"])
		var x := float(enemy["x"])
		var y := float(enemy["y"])
		var phase := float(enemy["phase"]) + dt * 2.2
		var base: float = float(kind["speed"]) * speed_mult
		var radius: float = float(kind["radius"])

		match behavior:
			"weave":
				x += cos(phase) * 9.0 * dt
				y += sin(phase * 1.7) * 3.0 * dt
			"dive":
				# Aim at the player, but only for a moment, then overshoot.
				var pull: float = clampf((float(enemy["z"]) + 40.0) / 60.0, 0.0, 1.0)
				x = lerpf(x, pos.x, pull * dt * 1.6)
				y = lerpf(y, pos.y, pull * dt * 1.1)
			"strafe":
				x += (1.0 if cos(phase) > 0.0 else -1.0) * 6.0 * dt
				y = lerpf(y, 9.0 + sin(phase * 0.8) * 5.0, dt * 0.8)
			"hover":
				y += sin(phase * 0.6) * 2.0 * dt
				x = lerpf(x, pos.x, dt * 0.25)
			"turret":
				# A ground turret never moves vertically; it only gets closer.
				y = 2.2
			"boss":
				x += cos(phase * 0.5) * 7.0 * dt
				y = lerpf(y, 8.0 + sin(phase * 0.4) * 6.0, dt * 0.6)
			_:
				pass

		enemy["x"] = clampf(x, -DragonFlight.ARENA_HALF_WIDTH - 4.0, DragonFlight.ARENA_HALF_WIDTH + 4.0)
		enemy["y"] = clampf(y, 0.0, DragonFlight.CEILING + 4.0)
		enemy["phase"] = phase
		var z := float(enemy["z"]) + scroll * dt
		enemy["z"] = z

		if float(enemy["poison"]) > 0.0:
			enemy["poison"] = float(enemy["poison"]) - dt
			_damage_enemy(enemy, 9.0 * dt, false, true)

		if z > DragonFlight.DESPAWN_Z:
			_release(enemy)
			continue

		var node: Node3D = enemy["node"]
		node.position = Vector3(float(enemy["x"]), float(enemy["y"]), z)
		var heading: float = atan2(pos.x - float(enemy["x"]), maxf(0.001, pos.z - z))
		node.rotation = node.rotation.lerp(Vector3(0.0, heading, 0.0), clampf(dt * 4.0, 0.0, 1.0))
		_flap_part(node, phase, 0.5)

		# Ramming the player costs hull, unless the shield buff is up.
		if invuln <= 0.0 and buff_shield <= 0.0 and _hits(pos.x, pos.y, pos.z, DragonFlight.PLAYER_RADIUS, enemy):
			_take_damage(DragonFlight.mitigate(float(kind["damage"]) * dmg_mult, float(stats["armor"])))
		# A ground turret that has been left behind is gone.
		if behavior == "turret" and z > 6.0:
			_release(enemy)


func _damage_enemy(enemy: Dictionary, amount: float, poison: bool, silent: bool = false) -> void:
	if not bool(enemy["active"]):
		return
	enemy["hp"] = float(enemy["hp"]) - amount
	if poison and not silent:
		enemy["poison"] = maxf(float(enemy["poison"]), 2.4)
	if not silent:
		Sfx.hit()
	if float(enemy["hp"]) <= 0.0:
		_kill_enemy(enemy)


func _kill_enemy(enemy: Dictionary) -> void:
	var kind := DragonFlight.enemy_by_id(str(enemy["kind"]))
	kills += 1
	combo += 1
	combo_timer = 3.0
	var gold_mult: float = float(stats["gold_mult"])
	gold += maxi(1, roundi(float(kind["gold"]) * gold_mult))
	score += int(kind["score"])
	Sfx.kill()
	_spawn_smoke(Vector3(float(enemy["x"]), float(enemy["y"]), float(enemy["z"])), Color(str(kind["color"])))
	if randf() < float(kind.get("drop", 0.0)):
		_spawn_pickup(float(enemy["x"]), float(enemy["y"]), float(enemy["z"]))
	_release(enemy)


func _update_pickups(dt: float, scroll: float) -> void:
	var radius: float = float(stats["pickup"]) * (1.0 + (1.8 * clampf(buff_magnet / 4.0, 0.0, 1.0)))
	for pickup in pickups:
		if not bool(pickup["active"]):
			continue
		var z := float(pickup["z"]) + scroll * dt
		pickup["z"] = z
		pickup["phase"] = float(pickup["phase"]) + dt * 3.0
		var node: Node3D = pickup["node"]
		node.position = Vector3(float(pickup["x"]), float(pickup["y"]) + sin(float(pickup["phase"])) * 0.35, z)
		node.rotation.y += dt * 2.0
		if z > DragonFlight.DESPAWN_Z:
			_release(pickup)
			continue
		var dx := float(pickup["x"]) - pos.x
		var dy := float(pickup["y"]) - pos.y
		var dz := z - pos.z
		# Magnet: inside the radius the pickup is pulled in, so it always lands.
		if dx * dx + dy * dy + dz * dz < radius * radius:
			var pull := (pos - Vector3(float(pickup["x"]), float(pickup["y"]), z)).normalized()
			pickup["x"] = float(pickup["x"]) + pull.x * 26.0 * dt
			pickup["y"] = float(pickup["y"]) + pull.y * 26.0 * dt
		if dx * dx + dy * dy + dz * dz < 2.6 * 2.6:
			_collect(pickup)


func _spawn_pickup(x: float, y: float, z: float) -> void:
	var entry := DragonFlight.roll_powerup()
	for pickup in pickups:
		if bool(pickup["active"]):
			continue
		pickup["active"] = true
		pickup["id"] = str(entry["id"])
		pickup["x"] = clampf(x, -DragonFlight.ARENA_HALF_WIDTH, DragonFlight.ARENA_HALF_WIDTH)
		pickup["y"] = clampf(y, 2.0, DragonFlight.CEILING)
		pickup["z"] = z
		pickup["phase"] = randf() * TAU
		pickup["node"] = _mesh_for(pickup, str(entry["asset"]), Color(str(entry["color"])), 1.0, 0.8)
		return


func _collect(pickup: Dictionary) -> void:
	var entry := DragonFlight.powerup_by_id(str(pickup["id"]))
	var amount := float(entry.get("amount", 0.0))
	match str(entry["id"]):
		"heal":
			hp = minf(max_hp, hp + max_hp * amount)
			_banner_text("+ Heilung", 0.9)
		"shield":
			buff_shield = float(entry["duration"])
			_banner_text("Drachenschild", 0.9)
		"rapid":
			buff_rapid = float(entry["duration"])
			_banner_text("Feuersturm", 0.9)
		"magnet":
			buff_magnet = float(entry["duration"])
			_banner_text("Magnetstein", 0.9)
		"gold":
			gold += maxi(1, roundi(amount * float(stats["gold_mult"])))
			_banner_text("+%d Gold" % maxi(1, roundi(amount)), 0.9)
		"egg":
			eggs_found += 1
			_banner_text("Drachenei gefunden!", 1.2)
		_:
			pass
	Sfx.coin()
	_release(pickup)


## Clouds, islands and totems scroll past to give the flight a sense of speed.
func _update_world_props(dt: float, scroll: float) -> void:
	for prop in props:
		var z := float(prop["z"]) + scroll * dt
		if z > DragonFlight.DESPAWN_Z:
			if str(prop["kind"]) == "cloud":
				var node: Node3D = prop["node"]
				var side: float = 1.0 if randf() < 0.5 else -1.0
				prop["x"] = side * randf_range(34.0, 80.0)
				prop["z"] = DragonFlight.SPAWN_Z
				node.position = Vector3(float(prop["x"]), randf_range(14.0, 30.0), DragonFlight.SPAWN_Z)
			continue
		prop["z"] = z
		var node2: Node3D = prop["node"]
		node2.position.z = z
	for island in islands:
		var iz := float(island["z"]) + scroll * dt * 0.6
		if iz > 40.0:
			iz = DragonFlight.SPAWN_Z
			var node3: Node3D = island["node"]
			node3.position = Vector3(randf_range(-90.0, 90.0), randf_range(-11.0, -4.0), DragonFlight.SPAWN_Z)
		island["z"] = iz
		(island["node"] as Node3D).position.z = iz


## Exhaust puffs behind the dragon: a cheap, pooled wing trail. They drift
## backwards past the camera, so they stay small and fade out fast.
func _update_trail(dt: float) -> void:
	for entry in trail:
		if not bool(entry["active"]):
			continue
		entry["life"] = float(entry["life"]) - dt
		var node: Node3D = entry["node"]
		var life := float(entry["life"])
		node.position.z += 11.0 * dt
		node.scale = Vector3.ONE * (1.0 + (0.45 - life) * 0.9)
		# Fade through the material, because a Node3D has no `modulate`.
		var material := node.material_override as StandardMaterial3D
		if material != null:
			material.albedo_color.a = clampf(life / 0.45, 0.0, 1.0) * 0.28
		if life <= 0.0:
			entry["active"] = false
			node.visible = false
	trail_cd = maxf(0.0, trail_cd - dt)
	if trail_cd <= 0.0 and running:
		_emit_trail()


func _emit_trail() -> void:
	for entry in trail:
		if bool(entry["active"]):
			continue
		var node: Node3D = entry["node"]
		entry["active"] = true
		entry["life"] = 0.45
		node.visible = true
		node.position = pos + Vector3(randf_range(-0.3, 0.3), randf_range(-0.15, 0.15), 1.2)
		trail_cd = 0.05
		return


func _spawn_smoke(at: Vector3, color: Color) -> void:
	for entry in trail:
		if bool(entry["active"]):
			continue
		var node: Node3D = entry["node"]
		entry["active"] = true
		entry["life"] = 0.5
		node.visible = true
		node.position = at
		node.scale = Vector3.ONE * 2.6
		var material := node.material_override as StandardMaterial3D
		if material != null:
			material.albedo_color = color
			material.albedo_color.a = 0.6
		return


func _update_camera(dt: float) -> void:
	shake = maxf(0.0, shake - dt * 2.2)
	var jitter := Vector3.ZERO
	if shake > 0.0:
		jitter = Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), 0.0) * shake
	# Chase camera: close behind and above, so the dragon fills a good part of
	# the frame and everything it flies into is visible ahead of it.
	var goal := Vector3(pos.x * 0.5, pos.y + 5.2, pos.z + 14.5) + jitter
	camera.position = camera.position.lerp(goal, clampf(dt * 5.0, 0.0, 1.0))
	var look := Vector3(pos.x * 0.85, pos.y + 0.5, pos.z - 26.0)
	camera.look_at(look, Vector3.UP)


func _update_timers(dt: float) -> void:
	invuln = maxf(0.0, invuln - dt)
	buff_rapid = maxf(0.0, buff_rapid - dt)
	buff_shield = maxf(0.0, buff_shield - dt)
	buff_magnet = maxf(0.0, buff_magnet - dt)
	combo_timer = maxf(0.0, combo_timer - dt)
	if combo_timer <= 0.0:
		combo = 0
	# The dragon breathes a short puff after every shot.
	breath.visible = maxf(0.0, fire_cd * 3.0) > 0.18


func _update_hud() -> void:
	Ui.set_bar(_hp_bar, hp / maxf(1.0, max_hp), Color("ef4444") if hp / max_hp < 0.35 else Color("22c55e"))
	_label_score.text = Ui.format_number(score)
	_label_gold.text = "%d" % gold
	var traits: Array = stats.get("traits", [])
	_label_trait.text = ", ".join(_short(traits)) if not traits.is_empty() else "—"
	var effects: Array[String] = []
	if buff_shield > 0.0:
		effects.append("Schild %.0fs" % buff_shield)
	if buff_rapid > 0.0:
		effects.append("Feuersturm %.0fs" % buff_rapid)
	if buff_magnet > 0.0:
		effects.append("Magnet %.0fs" % buff_magnet)
	if combo > 1:
		effects.append("Combo x%d" % combo)
	_label_buff.text = " · ".join(effects) if not effects.is_empty() else "—"


func _short(traits: Array) -> Array[String]:
	var out: Array[String] = []
	for id in traits:
		var gene := DragonFlight.trait_by_id(str(id))
		out.append(str(gene.get("name", id)))
	return out


func _tick_banner(dt: float) -> void:
	if _banner_timer <= 0.0:
		return
	_banner_timer -= dt
	_banner.modulate.a = clampf(_banner_timer, 0.0, 1.0)


# --- collision & feedback ---------------------------------------------------

## Circle overlap between a moving sphere and an enemy.
func _hits(x: float, y: float, z: float, radius: float, enemy: Dictionary) -> bool:
	var kind := DragonFlight.enemy_by_id(str(enemy["kind"]))
	var reach: float = float(kind["radius"]) + radius + (2.0 if bool(enemy["boss"]) else 0.0)
	var dx := x - float(enemy["x"])
	var dy := y - float(enemy["y"])
	var dz := z - float(enemy["z"])
	return dx * dx + dy * dy + dz * dz <= reach * reach


func _take_damage(raw: float) -> void:
	if invuln > 0.0 or buff_shield > 0.0:
		return
	hp -= raw
	invuln = DragonFlight.HIT_INVULN
	combo = 0
	shake = 0.7
	Sfx.hurt()


func _flap_part(node: Node3D, phase: float, amount: float) -> void:
	for child in node.get_children():
		if child is Node3D and str(child.name).contains("Wing"):
			(child as Node3D).rotation.z = sin(phase * 3.0) * amount * (1.0 if str(child.name).ends_with("R") else -1.0)
		_flap_part(child, phase, amount)


## Creates (once) and returns the mesh for a pooled entry.
func _mesh_for(entry: Dictionary, key: String, color: Color, scale: float, emission: float) -> Node3D:
	if entry.get("node", null) == null:
		var node := WorldScreen.mesh(key, color, scale, emission)
		if node == null:
			var box := MeshInstance3D.new()
			var mesh := BoxMesh.new()
			mesh.size = Vector3(1.0, 1.0, 1.0) * scale
			box.mesh = mesh
			box.material_override = WorldScreen.standard_material(color, emission)
			node = box
		node.visible = false
		add_child(node)
		entry["node"] = node
	var existing: Node3D = entry["node"]
	existing.visible = true
	existing.scale = Vector3.ONE * scale
	return existing


func _release(entry: Dictionary) -> void:
	entry["active"] = false
	var node: Node3D = entry.get("node", null)
	if node != null and is_instance_valid(node):
		node.visible = false


# --- end of run -------------------------------------------------------------

func _check_end() -> void:
	if hp <= 0.0:
		hp = 0.0
		_finish(false)
		return
	if distance >= float(level_def["length"]):
		_finish(true)


func _finish(survived: bool) -> void:
	if finished:
		return
	finished = true
	running = false
	var hp_ratio: float = hp / maxf(1.0, max_hp)
	var stars: int = DragonFlight.stars_for_run(survived, hp_ratio)
	score = DragonFlight.score_for(distance, kills, gold, combo)
	Game.submit_score(Game.HS_DRAGONFLIGHT, score)

	var result := {
		"score": score,
		"stars": stars,
		"gold": gold,
		"eggs": eggs_found,
		"new_best": 1 if survived else 0,
	}
	var gold_before := int(profile.get("gold", 0))
	var summary := DragonFlight.apply_run(profile, level_n, result)
	DragonFlight.save_profile(profile)
	if survived:
		Sfx.level_up()
	else:
		Sfx.game_over()
	_show_result(survived, stars, summary, int(profile.get("gold", 0)) - gold_before)


func _show_result(survived: bool, stars: int, summary: Dictionary, gold_delta: int) -> void:
	_over = Control.new()
	_over.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_over.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_root.add_child(_over)
	_over.add_child(Ui.backdrop(0.8))
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_over.add_child(center)
	var column := Ui.vbox(10)
	center.add_child(column)
	column.add_child(Ui.title("Geschafft" if survived else "Abgestürzt", 46, Color("22c55e") if survived else Color("f87171")))
	column.add_child(Ui.label("%d / 3 Sternen" % stars, 30, Color("facc15")))
	column.add_child(Ui.label("Strecke %d m · Abschüsse %d · Punkte %s" % [int(distance), kills, Ui.format_number(score)], 19, UiTheme.TEXT))
	column.add_child(Ui.label("Beute: %d Gold · %d Gold gesamt" % [gold, int(profile.get("gold", 0))], 19, UiTheme.TEXT_DIM))
	if gold_delta > 0:
		column.add_child(Ui.label("Dazu %d Gold aus dem Level" % gold_delta, 18, Color("fbbf24")))
	if int(summary.get("unlocked", level_n)) > level_n:
		column.add_child(Ui.label("Level %d freigeschaltet!" % int(summary["unlocked"]), 21, Color("38bdf8")))
	if eggs_found > 0:
		column.add_child(Ui.label("%d Ei(er) wartet in der Zucht" % eggs_found, 18, Color("fbbf24")))
	column.add_child(Ui.spacer(Vector2(0, 10)))
	column.add_child(Ui.button("Nochmal", Vector2(340, 54), UiTheme.ACCENT, func() -> void:
		Router.go_to("dragonflight_run", {"level": level_n})
	))
	column.add_child(Ui.button("Zur Zucht", Vector2(340, 50), UiTheme.PANEL_LIGHT, func() -> void:
		Router.go_to("dragonflight_hatchery")
	))
	column.add_child(Ui.button("Hangar", Vector2(340, 50), UiTheme.PANEL_LIGHT, func() -> void:
		Router.go_to("dragonflight")
	))
