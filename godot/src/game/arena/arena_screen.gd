class_name ArenaScreen
extends Screen
## Arena survival — the core mode of Singular 80.
##
## Port of `scenes/GameScene.ts`: waves of enemies chase the player, killed
## enemies drop XP gems, levels offer three weighted upgrades and a boss shows
## up every two minutes. Movement, aiming and firing all work with the virtual
## stick, the keyboard, a gamepad or touch.

const ARENA_W := 1280.0
const ARENA_H := 720.0
const MAX_ENEMIES := 220
const MAX_BULLETS := 400
const MAX_GEMS := 160
const MAX_SPARKS := 160
const BOSS_INTERVAL := 120.0
const WAVE_DURATION := 30.0
const SPAWN_MARGIN := 60.0

const RARITY_WEIGHT := {"common": 10.0, "uncommon": 6.0, "rare": 3.0, "epic": 1.5}
const RARITY_COLOR := {
	"common": Color(0.392, 0.455, 0.545),
	"uncommon": Color(0.133, 0.773, 0.369),
	"rare": Color(0.231, 0.510, 0.965),
	"epic": Color(0.659, 0.333, 0.969),
}


class Enemy:
	extends RefCounted
	var def: Dictionary = {}
	var pos := Vector2.ZERO
	var hp := 1.0
	var max_hp := 1.0
	var speed := 50.0
	var touch_damage := 5.0
	var xp_value := 1
	var wobble := 0.0
	var is_boss := false
	var radius := 16.0
	var flash := 0.0


class Bullet:
	extends RefCounted
	var pos := Vector2.ZERO
	var velocity := Vector2.ZERO
	var damage := 1.0
	var pierce := 0
	var life := 0.0
	var is_crit := false
	var size := 6.0
	var color := Color.WHITE


class Gem:
	extends RefCounted
	var pos := Vector2.ZERO
	var xp := 1
	var active := false
	## Chain payouts drop in gold so the player sees what the streak is worth.
	var tint := Color(0.220, 0.741, 0.973)


class Spark:
	extends RefCounted
	var pos := Vector2.ZERO
	var velocity := Vector2.ZERO
	var life := 0.0
	var max_life := 0.28


## The dash button for players without a keyboard.
##
## `content/mechanics.json` promises a dash and the mechanics module implements
## it, but it listens to the `dash` input action — which a phone does not have.
## This button presses exactly that action and draws the cooldown the arena
## mirrors from the mechanic, so both input paths share one rule.
class DashPad:
	extends Control
	const RADIUS := 54.0
	## Bottom right, clear of the pause button above it and of the thumb stick.
	const CENTER := Vector2(1204.0, 512.0)

	var screen: ArenaScreen
	var held := false
	var _drawn_at := -1.0
	var _drawn_held := false

	## Redraws only when the ring actually moved — not every frame.
	func sync() -> void:
		if screen == null:
			return
		var step := snappedf(screen.dash_cooldown_left, 0.02)
		if step == _drawn_at and held == _drawn_held:
			return
		_drawn_at = step
		_drawn_held = held
		queue_redraw()

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventScreenTouch:
			var touch := event as InputEventScreenTouch
			_hold(touch.pressed)
			accept_event()
		elif event is InputEventMouseButton and not DisplayServer.is_touchscreen_available():
			var click := event as InputEventMouseButton
			if click.button_index == MOUSE_BUTTON_LEFT:
				_hold(click.pressed)
				accept_event()

	## Behaves like a key: held while the finger is down, released when it
	## lifts. Holding it cannot chain dashes — the mechanic's cooldown decides.
	func _hold(down: bool) -> void:
		if down == held:
			return
		held = down
		ArenaRuns.dash_press(down)

	func _draw() -> void:
		var center := size * 0.5
		var ratio := ArenaRuns.dash_cooldown_ratio(screen.dash_cooldown_left, screen.dash_cooldown)
		var ready := ratio <= 0.0
		var accent: Color = UiTheme.ACCENT if ready else UiTheme.TEXT_MUTED
		var alpha := 1.0 if ready else 0.6
		draw_circle(center, RADIUS, Color(0.031, 0.047, 0.086, 0.62))
		draw_arc(center, RADIUS, 0.0, TAU, 40, Color(accent.r, accent.g, accent.b, 0.8 * alpha), 3.0, true)
		# The sweep empties while the dash recharges, so the ring *is* the timer.
		if not ready:
			draw_arc(center, RADIUS - 7.0, -PI * 0.5, -PI * 0.5 + TAU * (1.0 - ratio), 40,
				Color(accent.r, accent.g, accent.b, 0.85), 5.0, true)
		_draw_chevrons(center, Color(accent.r, accent.g, accent.b, alpha))
		var text := ArenaRuns.dash_charge_text(screen.dash_cooldown_left)
		if text == "":
			return
		var font := Ui.font_bold()
		if font != null:
			var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14)
			draw_string(font, center + Vector2(-width.x * 0.5, RADIUS - 12.0), text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(accent.r, accent.g, accent.b, 0.75))

	## Two chevrons pointing the way a dash goes — a glyph DejaVu can draw
	## without an icon font.
	func _draw_chevrons(center: Vector2, tint: Color) -> void:
		for i in 2:
			var x := center.x - 8.0 + float(i) * 14.0
			var chevron := PackedVector2Array([
				Vector2(x, center.y - 13.0), Vector2(x + 10.0, center.y), Vector2(x, center.y + 13.0)
			])
			draw_polyline(chevron, tint, 4.0, true)


var stats: PlayerStats
var weapon: Dictionary = {}
var mode: Dictionary = {}
var elapsed := 0.0
var kills := 0
var score := 0

var enemies: Array[Enemy] = []
var bullets: Array[Bullet] = []
var gems: Array[Gem] = []
var sparks: Array[Spark] = []
var mechanics: Array[Mechanic] = []
var upgrade_stacks: Dictionary = {}
var pending_choices: Array[Dictionary] = []

var player_pos := Vector2(ARENA_W * 0.5, ARENA_H * 0.5)
var aim_dir := Vector2.RIGHT
var invuln_until := 0.0
var fire_accumulator := 0.0
var spawn_accumulator := 0.0
var next_boss_at := BOSS_INTERVAL
var paused := false
var choosing_upgrade := false
var pending_level_ups := 0
var game_ended := false
var shake_time := 0.0
var shake_power := 0.0

# --- anticipation: forecast, boss telegraph, kill chain ---
var chain_state: Dictionary = {"chain": 0, "last_kill": -999.0}
var chain_milestone := 0.0
var boss_banner_time := 0.0
var boss_banner_name := ""

# --- dash: the mechanic owns the rule, the arena owns the button and the look ---
var dash_cooldown := 1.5
var dash_cooldown_left := 0.0
var dash_glow := 0.0
var dash_dir := Vector2.RIGHT
## Where the player was during the burst; the board draws these as after-images.
var dash_trail: Array[Vector2] = []

var _board: ArenaBoard
var _hp_bar: ProgressBar
var _xp_bar: ProgressBar
var _hud_label: Label
var _hint_label: Label
var _preview_label: Label
var _chain_label: Label
var _boss_banner: Label
var _dash_pad: DashPad
var _stick: VirtualStick
var _pointer := Vector2(ARENA_W * 0.5 + 140.0, ARENA_H * 0.5)
var _board_base := Vector2.ZERO


func _ready_game() -> void:
	weapon = Content.weapon_by_id(str(data.get("weaponId", Game.arena_weapon)))
	mode = Content.mode_by_id(str(data.get("modeId", Game.arena_mode)))
	stats = PlayerStats.create(weapon)
	_reset_state()
	_build_playfield()
	_build_hud()
	_build_mechanics()
	for i in MAX_ENEMIES:
		enemies.append(Enemy.new())
	for i in MAX_BULLETS:
		bullets.append(Bullet.new())
	for i in MAX_GEMS:
		gems.append(Gem.new())
	for i in MAX_SPARKS:
		sparks.append(Spark.new())


func _reset_state() -> void:
	elapsed = 0.0
	kills = 0
	score = 0
	player_pos = Vector2(ARENA_W * 0.5, ARENA_H * 0.5)
	aim_dir = Vector2.RIGHT
	invuln_until = 0.0
	fire_accumulator = 0.0
	spawn_accumulator = 0.0
	next_boss_at = ArenaRuns.BOSS_INTERVAL
	chain_state = {"chain": 0, "last_kill": -999.0}
	chain_milestone = 0.0
	boss_banner_time = 0.0
	boss_banner_name = ""
	dash_cooldown_left = 0.0
	dash_glow = 0.0
	dash_dir = Vector2.RIGHT
	# Preallocated: the after-images are written every frame of a dash.
	dash_trail.resize(ArenaRuns.DASH_TRAIL_STEPS)
	paused = false
	choosing_upgrade = false
	pending_level_ups = 0
	game_ended = false
	upgrade_stacks.clear()
	pending_choices.clear()
	mechanics.clear()


# --- construction -----------------------------------------------------------

func _build_playfield() -> void:
	var field := Ui.rect(Color(0.031, 0.047, 0.086))
	field.size = Vector2(1280, 720)
	field.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stage().add_child(field)

	_board = ArenaBoard.new()
	_board.screen = self
	_board.size = Vector2(ARENA_W, ARENA_H)
	_board_base = Vector2.ZERO
	_board.position = _board_base
	_board.mouse_filter = Control.MOUSE_FILTER_STOP
	stage().add_child(_board)
	_board.gui_input.connect(_on_board_input)


func _build_hud() -> void:
	var layer := stage()

	_hp_bar = Ui.bar(UiTheme.SUCCESS, 18.0)
	_hp_bar.position = Vector2(16, 62)
	_hp_bar.size = Vector2(320, 18)
	layer.add_child(_hp_bar)

	_xp_bar = Ui.bar(Color(0.220, 0.741, 0.973), 18.0)
	_xp_bar.position = Vector2(944, 62)
	_xp_bar.size = Vector2(320, 18)
	layer.add_child(_xp_bar)

	_hud_label = Ui.label("", 15, Color(0.796, 0.835, 0.882))
	_hud_label.position = Vector2(16, 88)
	_hud_label.size = Vector2(780, 48)
	layer.add_child(_hud_label)

	_preview_label = Ui.label("", 14, Color(0.580, 0.667, 0.827))
	_preview_label.position = Vector2(16, 132)
	_preview_label.size = Vector2(560, 20)
	layer.add_child(_preview_label)

	_chain_label = Ui.label("", 22, Color("facc15"), true)
	_chain_label.position = Vector2(880, 130)
	_chain_label.size = Vector2(384, 30)
	_chain_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_chain_label.add_theme_constant_override("outline_size", 6)
	_chain_label.add_theme_color_override("font_outline_color", Color("020617"))
	layer.add_child(_chain_label)

	# The boss telegraph is the single most useful piece of information in a
	# survival run, so it gets the top of the screen to itself.
	_boss_banner = Ui.label("", 30, Color("f87171"), true)
	_boss_banner.position = Vector2(0, 246)
	_boss_banner.size = Vector2(1280, 44)
	_boss_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_boss_banner.add_theme_constant_override("outline_size", 8)
	_boss_banner.add_theme_color_override("font_outline_color", Color("020617"))
	_boss_banner.modulate.a = 0.0
	layer.add_child(_boss_banner)

	_hint_label = Ui.label("", 14, UiTheme.TEXT_MUTED)
	_hint_label.position = Vector2(0, 690)
	_hint_label.size = Vector2(1280, 22)
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(_hint_label)

	_stick = VirtualStick.new()
	_stick.size = VirtualStick.SIZE
	_stick.position = Vector2(18, 720.0 - VirtualStick.SIZE.y - 16.0)
	_stick.visible = Game.touch_controls
	layer.add_child(_stick)

	var pause := Ui.button("❚❚", Vector2(54, 46), UiTheme.PANEL_LIGHT, toggle_pause)
	pause.position = Vector2(1280.0 - 74.0, 720.0 - 64.0)
	layer.add_child(pause)
	refresh_hud()


func _build_mechanics() -> void:
	for def in Content.enabled_mechanics():
		var mechanic := MechanicsIndex.by_id(str(def.get("id", "")))
		if mechanic != null:
			mechanics.append(mechanic)
			mechanic.init_mechanic(self)
		# The dash rule stays in the mechanic; the button only needs to know how
		# long the recharge takes so it can draw it.
		var dash := mechanic as DashMechanic
		if dash != null:
			dash_cooldown = dash.COOLDOWN
			_build_dash_pad()
			# The mechanic's own hint talks about a key. On a phone the button
			# is the only dash there is, so name it.
			if Game.touch_controls:
				add_hint("Daumen bewegen   ·   Dash-Knopf = ausweichen")


## The on-screen dash. It presses the very action a key presses, so the
## mechanic stays the only place the dash rule exists and the button can never
## drift away from it.
func _build_dash_pad() -> void:
	_dash_pad = DashPad.new()
	_dash_pad.screen = self
	_dash_pad.mouse_filter = Control.MOUSE_FILTER_STOP
	_dash_pad.size = Vector2(DashPad.RADIUS * 2.0, DashPad.RADIUS * 2.0)
	_dash_pad.position = DashPad.CENTER - _dash_pad.size * 0.5
	_dash_pad.visible = Game.touch_controls
	stage().add_child(_dash_pad)


# --- mechanics host ---------------------------------------------------------

func add_hint(text: String) -> void:
	if _hint_label != null:
		_hint_label.text = text


func input_direction() -> Vector2:
	var dir := Vector2(
		Input.get_axis("move_left", "move_right"),
		Input.get_axis("move_up", "move_down")
	)
	if dir.length() < 0.2 and _stick != null and _stick.value.length() > 0.02:
		dir = _stick.value
	return dir.limit_length(1.0)


func aim_direction() -> Vector2:
	var target := _pointer - player_pos
	if target.length() < 1.0:
		return aim_dir
	aim_dir = target.normalized()
	return aim_dir


func is_invulnerable() -> bool:
	return elapsed < invuln_until


func grant_invulnerability(ms: float) -> void:
	invuln_until = maxf(invuln_until, elapsed + ms / 1000.0)


func shake_camera(ms: float, intensity: float) -> void:
	shake_time = maxf(shake_time, ms / 1000.0)
	shake_power = maxf(shake_power, intensity)


# --- loop -------------------------------------------------------------------

func _process(delta: float) -> void:
	super(delta)
	_update_telegraph(delta)
	if game_ended:
		return
	if Input.is_action_just_pressed("pause"):
		toggle_pause()
	if Input.is_action_just_pressed("confirm") and choosing_upgrade and not pending_choices.is_empty():
		_choose_upgrade(0)
	if paused or choosing_upgrade:
		return

	elapsed += delta
	for mechanic in mechanics:
		mechanic.update_mechanic(self, delta)

	var override: Variant = null
	for mechanic in mechanics:
		var result: Variant = mechanic.movement_override(self, delta)
		if result != null:
			override = result
	if override != null:
		player_pos += Vector2(float(override["x"]), float(override["y"])) * delta
		# The dash is the only movement override in the game, so this is where
		# the burst becomes visible and where its cooldown starts.
		_begin_dash(Vector2(float(override["x"]), float(override["y"])))
	else:
		player_pos += input_direction() * stats.effective_move_speed() * delta
	player_pos.x = clampf(player_pos.x, 22.0, ARENA_W - 22.0)
	player_pos.y = clampf(player_pos.y, 22.0, ARENA_H - 22.0)
	aim_direction()

	if Input.is_action_just_pressed("fire") or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		fire_accumulator = 999.0

	_update_combat(delta)
	_update_enemies(delta)
	_update_bullets(delta)
	_update_gems(delta)
	_update_sparks(delta)
	_update_spawning(delta)
	_update_shake(delta)
	refresh_hud()
	_board.queue_redraw()

	if stats.hp <= 0.0:
		_end_game()


## Fades the boss banner out and lets a stalled kill chain expire.
func _update_telegraph(delta: float) -> void:
	if chain_milestone > 0.0:
		chain_milestone = maxf(0.0, chain_milestone - delta * 1.6)
	if boss_banner_time > 0.0:
		boss_banner_time = maxf(0.0, boss_banner_time - delta)
		if _boss_banner != null:
			# Hold the last half second, then fade.
			_boss_banner.modulate.a = clampf(boss_banner_time * 2.0, 0.0, 1.0)
	chain_state = ArenaRuns.decay(chain_state, elapsed)
	dash_cooldown_left = maxf(0.0, dash_cooldown_left - delta)
	dash_glow = maxf(0.0, dash_glow - delta / ArenaRuns.DASH_TRAIL_TIME)
	if _dash_pad != null:
		_dash_pad.sync()


## Mirrors the burst the mechanic just started: the button gets its 1.5 s back
## and the board gets three ghosts to fade out behind the player.
func _begin_dash(velocity: Vector2) -> void:
	if velocity.length() > 0.01:
		dash_dir = velocity.normalized()
	dash_glow = 1.0
	dash_cooldown_left = dash_cooldown
	for i in range(dash_trail.size() - 1, 0, -1):
		dash_trail[i] = dash_trail[i - 1]
	dash_trail[0] = player_pos


func _update_shake(delta: float) -> void:
	if shake_time > 0.0:
		shake_time = maxf(0.0, shake_time - delta)
	_board.position = _board_base + Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * shake_power * ARENA_W * (shake_time * 6.0)
	if shake_time <= 0.0:
		_board.position = _board_base


func _update_combat(delta: float) -> void:
	fire_accumulator += delta * 1000.0
	var cooldown := stats.effective_cooldown(weapon)
	if fire_accumulator >= cooldown:
		fire_accumulator = 0.0
		_fire_weapon()
	if stats.hp_regen > 0.0:
		stats.hp = minf(stats.max_hp, stats.hp + stats.hp_regen * delta)


func _fire_weapon() -> void:
	var aim := aim_direction()
	var base_angle := aim.angle()
	var shot := {
		"damage": stats.effective_damage(),
		"speed": stats.projectile_speed,
		"count": maxi(1, int(round(stats.projectile_count))),
		"spread": stats.spread,
		"pierce": int(stats.pierce),
		"size": float(weapon.get("size", 6)),
		"color": UiTheme.from_hex(str(weapon.get("color", "#ffffff"))),
		"critChance": stats.crit_chance,
		"critMult": stats.crit_mult,
	}
	for mechanic in mechanics:
		shot = mechanic.on_fire(self, shot)

	var count: int = maxi(1, int(round(float(shot["count"]))))
	for i in count:
		var bullet := _free_bullet()
		if bullet == null:
			return
		var offset: float = 0.0 if count == 1 else (float(i) / float(count - 1) - 0.5) * float(shot["spread"])
		var angle := base_angle + offset + (randf() - 0.5) * float(shot["spread"]) * 0.25
		bullet.pos = player_pos
		bullet.velocity = Vector2(cos(angle), sin(angle)) * float(shot["speed"])
		bullet.damage = float(shot["damage"])
		bullet.is_crit = randf() < float(shot["critChance"])
		if bullet.is_crit:
			bullet.damage *= float(shot["critMult"])
		bullet.pierce = int(shot["pierce"])
		bullet.life = 1.4
		bullet.size = float(shot["size"])
		bullet.color = shot["color"]
	Sfx.shoot()


func _free_bullet() -> Bullet:
	for bullet in bullets:
		if bullet.life <= 0.0:
			return bullet
	return null


func _update_bullets(delta: float) -> void:
	for bullet in bullets:
		if bullet.life <= 0.0:
			continue
		bullet.life -= delta
		bullet.pos += bullet.velocity * delta
		if bullet.life <= 0.0 or bullet.pos.x < -30.0 or bullet.pos.x > ARENA_W + 30.0 or bullet.pos.y < -30.0 or bullet.pos.y > ARENA_H + 30.0:
			bullet.life = 0.0
			continue
		for enemy in enemies:
			if enemy.def.is_empty():
				continue
			if bullet.pos.distance_to(enemy.pos) > enemy.radius + bullet.size * 0.5:
				continue
			enemy.hp -= bullet.damage
			enemy.flash = 0.07
			_emit_sparks(bullet.pos, 3 if not bullet.is_crit else 7)
			Sfx.hit()
			if enemy.hp <= 0.0:
				_kill_enemy(enemy)
			bullet.pierce -= 1
			if bullet.pierce < 0:
				bullet.life = 0.0
			break


func _update_enemies(delta: float) -> void:
	for enemy in enemies:
		if enemy.def.is_empty():
			continue
		enemy.flash = maxf(0.0, enemy.flash - delta)
		var to_player := player_pos - enemy.pos
		var angle := to_player.angle()
		var behavior := str(enemy.def.get("behavior", "chase"))
		var velocity := Vector2(cos(angle), sin(angle)) * enemy.speed
		if behavior == "zigzag":
			enemy.wobble += delta * 6.0
			var perpendicular := angle + PI * 0.5
			var wobble := sin(enemy.wobble) * enemy.speed * 0.55
			velocity += Vector2(cos(perpendicular), sin(perpendicular)) * wobble
		elif behavior == "orbit":
			if to_player.length() < 170.0:
				velocity = -velocity * 0.8
			var perpendicular := angle + PI * 0.5
			velocity += Vector2(cos(perpendicular), sin(perpendicular)) * enemy.speed * 0.7
		enemy.pos += velocity * delta
		if enemy.pos.distance_to(player_pos) <= enemy.radius + 16.0:
			_on_enemy_touch(enemy)


func _on_enemy_touch(enemy: Enemy) -> void:
	if game_ended or is_invulnerable():
		return
	stats.hp -= maxf(1.0, enemy.touch_damage - stats.armor)
	grant_invulnerability(800.0)
	shake_camera(120.0, 0.004)
	_emit_sparks(player_pos, 12)
	Sfx.hurt()
	if stats.hp <= 0.0:
		_end_game()


func _kill_enemy(enemy: Enemy) -> void:
	if enemy.def.is_empty():
		return
	kills += 1
	var def := enemy.def
	var pos := enemy.pos
	_emit_sparks(pos, 40 if enemy.is_boss else 8)
	var chain := ArenaRuns.register_kill(chain_state, elapsed, enemy.xp_value)
	chain_state = {"chain": int(chain["chain"]), "last_kill": float(chain["last_kill"])}
	var extra_xp := int(chain["bonus"])
	if extra_xp > 0:
		# The chain pays out as extra gems, so the reward is visible in the world.
		_drop_gem(pos, extra_xp, Color("facc15"))
	if bool(chain["milestone"]):
		chain_milestone = 1.0
		show_toast("Kette ×%d!" % mini(int(chain["chain"]), ArenaRuns.CHAIN_CAP), 1.1)
	_drop_gem(pos, enemy.xp_value)
	for mechanic in mechanics:
		mechanic.on_enemy_killed(self, enemy)
	if enemy.is_boss:
		shake_camera(250.0, 0.006)
	Sfx.kill()
	enemy.def = {}
	_spawn_split(def, pos)


func _spawn_split(def: Dictionary, pos: Vector2) -> void:
	var child_id := str(def.get("splitInto", ""))
	if child_id == "":
		return
	var child_def := Content.enemy_by_id(child_id)
	if child_def.is_empty():
		return
	var count: int = maxi(1, int(round(float(def.get("splitCount", 2)))))
	var offset := float(def.get("radius", 16)) * 0.8
	for i in count:
		var child := _free_enemy()
		if child == null:
			return
		var angle := (TAU * float(i) / float(count)) + randf() * 0.5
		var at := Vector2(
			clampf(pos.x + cos(angle) * offset, 8.0, ARENA_W - 8.0),
			clampf(pos.y + sin(angle) * offset, 8.0, ARENA_H - 8.0)
		)
		_spawn_enemy(child, child_def, at, 1.0, 1.0, 1.0)
	_emit_sparks(pos, 12)


func _free_enemy() -> Enemy:
	for enemy in enemies:
		if enemy.def.is_empty():
			return enemy
	return null


func _spawn_enemy(enemy: Enemy, def: Dictionary, pos: Vector2, hp_mult: float, speed_mult: float, damage_mult: float) -> void:
	enemy.def = def
	enemy.max_hp = maxf(1.0, round(float(def.get("hp", 10)) * hp_mult))
	enemy.hp = enemy.max_hp
	enemy.speed = float(def.get("speed", 60.0)) * speed_mult
	enemy.touch_damage = float(def.get("damage", 5)) * damage_mult
	enemy.xp_value = int(def.get("xp", 1))
	enemy.is_boss = bool(def.get("boss", false))
	enemy.radius = maxf(8.0, float(def.get("radius", 16)))
	enemy.pos = pos
	enemy.wobble = randf() * TAU
	enemy.flash = 0.0


func _update_spawning(delta: float) -> void:
	var wave := ArenaRuns.wave_at(elapsed)
	if elapsed >= next_boss_at:
		next_boss_at += ArenaRuns.BOSS_INTERVAL
		_spawn_boss(wave)
	var interval: float = maxf(280.0, 1000.0 - float(wave) * 40.0) / maxf(0.1, float(mode.get("spawnRateMult", 1.0)))
	spawn_accumulator += delta * 1000.0
	var guard := 0
	while spawn_accumulator >= interval and guard < 64:
		spawn_accumulator -= interval
		_spawn_wave_enemy(wave)
		guard += 1


func _spawn_wave_enemy(wave: int) -> void:
	var enemy := _free_enemy()
	if enemy == null:
		return
	var def := _pick_enemy(wave)
	if def.is_empty():
		return
	var pos := Vector2.ZERO
	match randi() % 4:
		0:
			pos = Vector2(randf() * ARENA_W, -SPAWN_MARGIN)
		1:
			pos = Vector2(ARENA_W + SPAWN_MARGIN, randf() * ARENA_H)
		2:
			pos = Vector2(randf() * ARENA_W, ARENA_H + SPAWN_MARGIN)
		_:
			pos = Vector2(-SPAWN_MARGIN, randf() * ARENA_H)
	_spawn_enemy(
		enemy, def, pos,
		(1.0 + float(wave) * 0.22) * float(mode.get("enemyHpMult", 1.0)),
		(1.0 + minf(0.6, float(wave) * 0.015)) * float(mode.get("enemySpeedMult", 1.0)),
		1.0 + minf(1.5, float(wave) * 0.04)
	)


func _pick_enemy(wave: int) -> Dictionary:
	var pool: Array[Dictionary] = []
	var total := 0.0
	for def in Content.enemies:
		if bool(def.get("boss", false)) or float(def.get("weight", 0.0)) <= 0.0 or int(def.get("minWave", 1)) > wave:
			continue
		pool.append(def)
		total += float(def["weight"])
	if pool.is_empty():
		return {}
	var roll := randf() * total
	for def in pool:
		roll -= float(def["weight"])
		if roll <= 0.0:
			return def
	return pool[pool.size() - 1]


func _spawn_boss(wave: int) -> void:
	# The telegraph named this boss, so the same picker has to honour it.
	var def := ArenaRuns.boss_preview(Content.enemies, wave)
	if def.is_empty():
		return
	var enemy := _free_enemy()
	if enemy == null:
		return
	_spawn_enemy(
		enemy, def, Vector2(ARENA_W * 0.5 + (randf() - 0.5) * 200.0, -80.0),
		(1.0 + float(wave) * 0.55) * float(mode.get("enemyHpMult", 1.0)),
		float(mode.get("enemySpeedMult", 1.0)),
		1.0 + float(wave) * 0.05
	)
	boss_banner_name = str(def.get("name", ""))
	boss_banner_time = 3.4
	if _boss_banner != null:
		_boss_banner.text = "☠  %s erscheint  ☠" % boss_banner_name
		_boss_banner.add_theme_color_override("font_color", Color("f87171"))
		_boss_banner.modulate.a = 1.0
	show_toast("%s ist aufgetaucht" % boss_banner_name, 2.0)
	shake_camera(220.0, 0.005)


func _emit_sparks(pos: Vector2, amount: int) -> void:
	for i in amount:
		var spark := _free_spark()
		if spark == null:
			return
		spark.pos = pos
		spark.velocity = Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)).normalized() * randf_range(40.0, 180.0)
		spark.life = 0.28
		spark.max_life = 0.28


func _free_spark() -> Spark:
	for spark in sparks:
		if spark.life <= 0.0:
			return spark
	return null


func _update_sparks(delta: float) -> void:
	for spark in sparks:
		if spark.life <= 0.0:
			continue
		spark.life -= delta
		spark.pos += spark.velocity * delta


# --- gems & levelling -------------------------------------------------------

func _drop_gem(pos: Vector2, xp: int, tint: Color = Color(0.220, 0.741, 0.973)) -> void:
	for gem in gems:
		if gem.active:
			continue
		gem.pos = pos
		gem.xp = xp
		gem.tint = tint
		gem.active = true
		return


func _update_gems(_delta: float) -> void:
	var radius := stats.pickup_radius
	for gem in gems:
		if not gem.active:
			continue
		var to_player := player_pos - gem.pos
		var dist := to_player.length()
		if dist >= radius:
			continue
		var angle := to_player.angle()
		var speed := 260.0 + (radius - dist) * 6.0
		gem.pos += Vector2(cos(angle), sin(angle)) * speed * _delta
		if dist < 22.0:
			gem.active = false
			_gain_xp(float(gem.xp))


func _gain_xp(amount: float) -> void:
	stats.xp += amount * stats.xp_mult
	while stats.xp >= stats.xp_next:
		stats.xp -= stats.xp_next
		stats.level += 1
		stats.xp_next = PlayerStats.xp_for_level(stats.level)
		pending_level_ups += 1
		Sfx.level_up()
		for mechanic in mechanics:
			mechanic.on_level_up(self, stats.level)
	if pending_level_ups > 0 and not choosing_upgrade:
		_show_upgrade_choices()


func _pick_upgrade_choices() -> Array[Dictionary]:
	var pool: Array[Dictionary] = []
	for upgrade in Content.upgrades:
		if int(upgrade.get("minLevel", 1)) <= stats.level and int(upgrade_stacks.get(str(upgrade["id"]), 0)) < int(upgrade.get("maxStacks", 99)):
			pool.append(upgrade)
	var picks: Array[Dictionary] = []
	var available: Array = pool.duplicate()
	while picks.size() < 3 and not available.is_empty():
		var total := 0.0
		for upgrade in available:
			total += float(RARITY_WEIGHT.get(str((upgrade as Dictionary).get("rarity", "common")), 1.0))
		var roll := randf() * total
		var index := 0
		for i in available.size():
			roll -= float(RARITY_WEIGHT.get(str((available[i] as Dictionary).get("rarity", "common")), 1.0))
			if roll <= 0.0:
				index = i
				break
		picks.append(available[index])
		available.remove_at(index)
	while picks.size() < 3:
		picks.append({
			"id": "heal_%d" % picks.size(),
			"name": "Reparatur",
			"description": "+25 Leben",
			"stat": "hp",
			"amount": 25,
			"maxStacks": 99,
			"rarity": "common",
			"minLevel": 1,
		})
	return picks


func _show_upgrade_choices() -> void:
	choosing_upgrade = true
	pending_choices = _pick_upgrade_choices()
	var layer := modal()
	layer.add_child(Ui.backdrop(0.74))

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(center)

	var column := Ui.vbox(20)
	center.add_child(column)
	column.add_child(Ui.title("Level %d — Upgrade wählen" % stats.level, 32))

	var row := Ui.hbox(22)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_child(row)

	for index in pending_choices.size():
		var upgrade: Dictionary = pending_choices[index]
		var rarity := str(upgrade.get("rarity", "common"))
		var stacks := int(upgrade_stacks.get(str(upgrade["id"]), 0))
		var tint: Color = RARITY_COLOR.get(rarity, UiTheme.BORDER)
		var button := Ui.button("", Vector2(300, 244), UiTheme.PANEL, func() -> void: _choose_upgrade(index))
		button.add_theme_stylebox_override("normal", UiTheme.flat(Color(0.059, 0.090, 0.165, 0.97), tint, 14, 3))
		button.add_theme_stylebox_override("hover", UiTheme.flat(Color(0.090, 0.125, 0.212, 0.99), tint, 14, 3))
		button.add_theme_stylebox_override("pressed", UiTheme.flat(Color(0.039, 0.063, 0.114, 0.99), tint, 14, 3))
		row.add_child(button)

		var card := Ui.vbox(6)
		card.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		card.offset_left = 14
		card.offset_right = -14
		card.offset_top = 16
		card.offset_bottom = -16
		card.mouse_filter = Control.MOUSE_FILTER_IGNORE
		button.add_child(card)

		var name_label := Ui.label(str(upgrade.get("name", "")), 21, UiTheme.TEXT, true)
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		card.add_child(name_label)
		card.add_child(Ui.spacer(Vector2(0, 10)))

		var description := Ui.label(str(upgrade.get("description", "")), 16, UiTheme.TEXT_DIM)
		description.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		description.size_flags_vertical = Control.SIZE_EXPAND_FILL
		card.add_child(description)

		var meta := rarity.to_upper()
		if int(upgrade.get("maxStacks", 99)) < 90:
			meta += "  ·  %d/%d" % [stacks, int(upgrade["maxStacks"])]
		meta += "\n[%d]" % (index + 1)
		var meta_label := Ui.label(meta, 14, UiTheme.TEXT_MUTED)
		meta_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		card.add_child(meta_label)


func _choose_upgrade(index: int) -> void:
	if not choosing_upgrade or index < 0 or index >= pending_choices.size():
		return
	stats.apply_upgrade(pending_choices[index])
	var id := str(pending_choices[index]["id"])
	upgrade_stacks[id] = int(upgrade_stacks.get(id, 0)) + 1
	Sfx.merge()
	pending_level_ups -= 1
	close_modals()
	choosing_upgrade = false
	pending_choices.clear()
	if pending_level_ups > 0:
		_show_upgrade_choices.call_deferred()


# --- HUD --------------------------------------------------------------------

func refresh_hud() -> void:
	var ratio: float = clampf(stats.hp / maxf(1.0, stats.max_hp), 0.0, 1.0)
	var hp_color: Color = UiTheme.SUCCESS if ratio > 0.5 else (UiTheme.WARNING if ratio > 0.25 else UiTheme.DANGER)
	Ui.set_bar(_hp_bar, ratio, hp_color)
	Ui.set_bar(_xp_bar, clampf(stats.xp / maxf(1.0, stats.xp_next), 0.0, 1.0), Color(0.220, 0.741, 0.973))

	var seconds := int(elapsed)
	var wave := ArenaRuns.wave_at(elapsed)
	score = kills * 10 + seconds * 2 + stats.level * 100

	# What is coming, and how long there is until it arrives.
	var countdown := ArenaRuns.boss_countdown(elapsed, next_boss_at)
	var upcoming := ArenaRuns.boss_preview(Content.enemies, wave + 1)
	var forecast := ArenaRuns.preview_text(Content.enemies, wave, elapsed)
	var to_wave := int(ceil(ArenaRuns.time_to_next_wave(elapsed)))
	if _preview_label != null:
		_preview_label.text = "%s  ·  nächste Welle in %ds" % [forecast, maxi(0, to_wave)]
	# While the boss itself is on screen its name owns the banner; only a
	# standing countdown may overwrite it.
	if _boss_banner != null and boss_banner_time <= 0.0:
		if countdown <= 20.0 and countdown > 0.0:
			_boss_banner.text = "⚠  %s in %ds  ⚠" % [
				str(upcoming.get("name", "Boss")), maxi(0, int(ceil(countdown))),
			]
			_boss_banner.add_theme_color_override("font_color",
				Color("fbbf24") if ArenaRuns.boss_threat(countdown) == 2 else Color("f87171"))
			_boss_banner.modulate.a = 1.0
		else:
			_boss_banner.text = ""
	if _chain_label != null:
		_chain_label.text = ArenaRuns.chain_text(chain_state)
		_chain_label.modulate.a = 1.0 if chain_milestone > 0.0 else 0.92

	var status: Array = []
	for mechanic in mechanics:
		var text := mechanic.hud(self)
		if text != "":
			status.append(text)
	var extra := "   ".join(status)
	_hud_label.text = "Level %d   Welle %d   Zeit %s   Kills %d   Score %s\n%s%s" % [
		stats.level, wave, Ui.format_time(elapsed * 1000.0), kills, Ui.format_number(score),
		str(weapon.get("name", "")), ("   " + extra) if extra != "" else "",
	]


# --- pause / end ------------------------------------------------------------

func toggle_pause() -> void:
	if game_ended or choosing_upgrade:
		return
	paused = not paused
	if paused:
		_show_pause_menu()
	else:
		close_modals()


func _show_pause_menu() -> void:
	var layer := modal()
	layer.add_child(Ui.backdrop(0.75))

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(center)

	var column := Ui.vbox(16)
	center.add_child(column)
	column.add_child(Ui.title("Pause", 44))

	column.add_child(Ui.button("Fortsetzen", Vector2(420, 58), UiTheme.ACCENT, toggle_pause))
	column.add_child(Ui.button("Vorschlag einreichen", Vector2(420, 54), UiTheme.PANEL_LIGHT, func() -> void:
		SuggestDialog.open(self)
	))
	column.add_child(Ui.button("Waffenauswahl", Vector2(420, 54), UiTheme.PANEL_LIGHT, func() -> void:
		Router.go_to("main_menu")
	))
	column.add_child(Ui.button("Lobby", Vector2(420, 54), UiTheme.PANEL_LIGHT, func() -> void:
		Router.to_lobby()
	))


func _end_game() -> void:
	if game_ended:
		return
	game_ended = true
	Sfx.game_over()
	shake_camera(400.0, 0.008)
	Game.submit_score(Game.HS_ARENA, score)
	await get_tree().create_timer(0.6).timeout
	if is_inside_tree():
		Router.go_to("game_over", {
			"score": score,
			"kills": kills,
			"timeMs": elapsed * 1000.0,
			"level": stats.level,
			"modeId": str(mode.get("id", "classic")),
			"weaponId": str(weapon.get("id", "pistol")),
		})


# --- input ------------------------------------------------------------------

func _on_board_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed:
		_pointer = _board.get_local_mouse_position()
	elif event is InputEventScreenDrag:
		_pointer = _board.get_local_mouse_position()
	elif event is InputEventMouseMotion:
		_pointer = _board.get_local_mouse_position()
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		_pointer = _board.get_local_mouse_position()


# --- rendering --------------------------------------------------------------

## Draws the arena floor, the entities and the effects. Keeping all of it in a
## single canvas item avoids hundreds of nodes while staying allocation-free.
class ArenaBoard:
	extends Control
	var screen: ArenaScreen

	func _draw() -> void:
		if screen == null:
			return
		draw_rect(Rect2(0, 0, ARENA_W, ARENA_H), Color(0.043, 0.071, 0.125))
		var x := 0.0
		while x <= ARENA_W:
			draw_line(Vector2(x, 0), Vector2(x, ARENA_H), Color(0.118, 0.161, 0.231, 0.9), 1.0)
			x += 64.0
		var y := 0.0
		while y <= ARENA_H:
			draw_line(Vector2(0, y), Vector2(ARENA_W, y), Color(0.118, 0.161, 0.231, 0.9), 1.0)
			y += 64.0
		draw_rect(Rect2(1.5, 1.5, ARENA_W - 3.0, ARENA_H - 3.0), Color(0.200, 0.259, 0.333), false, 3.0)

		for spark in screen.sparks:
			if spark.life <= 0.0:
				continue
			var fade: float = clampf(spark.life / spark.max_life, 0.0, 1.0)
			draw_circle(spark.pos, 3.0 * fade, Color(0.85, 0.95, 1.0, fade * 0.9))

		for gem in screen.gems:
			if not gem.active:
				continue
			_draw_gem(gem.pos, gem.tint)

		for bullet in screen.bullets:
			if bullet.life <= 0.0:
				continue
			if bullet.is_crit:
				draw_circle(bullet.pos, maxf(7.0, bullet.size), Color(1.0, 0.9, 0.3, 0.35))
			draw_circle(bullet.pos, maxf(3.0, bullet.size * 0.5), bullet.color)

		for enemy in screen.enemies:
			if enemy.def.is_empty():
				continue
			_draw_enemy(enemy)

		_draw_dash(screen)
		# A dash is a gift, not a hit: it keeps its solid body and lets the
		# after-images carry the motion, instead of blinking like damage does.
		_draw_player(screen.player_pos, screen.is_invulnerable() and screen.dash_glow <= 0.0, screen.aim_dir, screen.elapsed)

	## After-images of the last dash. Without them the burst is a teleport the
	## player cannot aim — this is what makes the invulnerable frames readable.
	func _draw_dash(view: ArenaScreen) -> void:
		if view.dash_glow <= 0.0:
			return
		_draw_wake(view)
		for i in view.dash_trail.size():
			var alpha := ArenaRuns.dash_step_alpha(view.dash_glow, i)
			if alpha <= 0.02:
				continue
			var radius: float = 17.0 - float(i) * 4.0
			draw_circle(view.dash_trail[i], radius, Color(0.290, 0.647, 0.898, alpha * 0.5))
			draw_arc(view.dash_trail[i], radius, 0.0, TAU, 24, Color(0.490, 0.827, 0.988, alpha), 2.0, true)

	## A wake in the dash direction. The ghosts alone are dots; the wake says
	## which way the burst went and how far it carries the player.
	func _draw_wake(view: ArenaScreen) -> void:
		if view.dash_trail.is_empty():
			return
		var fade := ArenaRuns.dash_trail_alpha(view.dash_glow)
		var from := view.dash_trail[view.dash_trail.size() - 1] - view.dash_dir * 14.0
		draw_line(from, view.player_pos, Color(0.490, 0.827, 0.988, fade * 0.5), 9.0, true)

	## Enemy shapes mirror the content definition, exactly like the browser
	## build's procedurally generated textures.
	func _draw_enemy(enemy: Enemy) -> void:
		var base: Color = UiTheme.from_hex(str(enemy.def.get("color", "#94a3b8")), Color(0.58, 0.64, 0.72))
		if enemy.flash > 0.0:
			base = Color(1, 1, 1)
		var r := enemy.radius
		var border := Color(0.059, 0.090, 0.165, 0.55)
		match str(enemy.def.get("shape", "circle")):
			"square":
				var box := Rect2(enemy.pos - Vector2(r, r), Vector2(r * 2.0, r * 2.0))
				draw_rect(box, base)
				draw_rect(box, border, false, 3.0)
			"triangle":
				var tri := PackedVector2Array([enemy.pos + Vector2(0, -r), enemy.pos + Vector2(r, r), enemy.pos + Vector2(-r, r)])
				draw_colored_polygon(tri, base)
				draw_polyline(PackedVector2Array([tri[0], tri[1], tri[2], tri[0]]), border, 3.0, true)
			"diamond":
				var dia := PackedVector2Array([enemy.pos + Vector2(0, -r), enemy.pos + Vector2(r, 0), enemy.pos + Vector2(0, r), enemy.pos + Vector2(-r, 0)])
				draw_colored_polygon(dia, base)
				draw_polyline(PackedVector2Array([dia[0], dia[1], dia[2], dia[3], dia[0]]), border, 3.0, true)
			"hexagon":
				var hex := PackedVector2Array()
				for i in 6:
					var angle := PI / 3.0 * float(i) - PI * 0.5
					hex.append(enemy.pos + Vector2(cos(angle), sin(angle)) * r)
				draw_colored_polygon(hex, base)
				draw_polyline(PackedVector2Array([hex[0], hex[1], hex[2], hex[3], hex[4], hex[5], hex[0]]), border, 3.0, true)
			_:
				draw_circle(enemy.pos, r, base)
				draw_arc(enemy.pos, r, 0.0, TAU, 24, border, 3.0, true)

		if enemy.hp < enemy.max_hp and not enemy.is_boss:
			var width := r * 2.0
			var top := enemy.pos - Vector2(r, r + 8.0)
			draw_rect(Rect2(top, Vector2(width, 4.0)), Color(0.059, 0.090, 0.165, 0.85))
			draw_rect(Rect2(top, Vector2(width * clampf(enemy.hp / maxf(1.0, enemy.max_hp), 0.0, 1.0), 4.0)), Color(0.937, 0.267, 0.267))
		if enemy.is_boss:
			draw_arc(enemy.pos, r + 5.0, 0.0, TAU, 32, Color(0.937, 0.267, 0.267, 0.8), 2.0, true)

	## A chain payout arrives in gold and is drawn a little larger, so the bonus
	## is readable at a glance while dodging.
	func _draw_gem(pos: Vector2, tint: Color) -> void:
		var chain := not tint.is_equal_approx(Color(0.220, 0.741, 0.973))
		var size := 9.0 if chain else 7.0
		var diamond := PackedVector2Array([
			pos + Vector2(0, -size), pos + Vector2(size, 0), pos + Vector2(0, size), pos + Vector2(-size, 0)
		])
		if chain:
			draw_circle(pos, size + 4.0, Color(tint.r, tint.g, tint.b, 0.22))
		draw_colored_polygon(diamond, tint)
		draw_circle(pos, size * 0.45, tint.lightened(0.55))

	func _draw_player(pos: Vector2, invulnerable: bool, aim: Vector2, time: float) -> void:
		if invulnerable and int(time * 11.0) % 2 == 0:
			return
		draw_line(pos + aim * 12.0, pos + aim * 28.0, Color(0.490, 0.827, 0.988), 3.0, true)
		draw_circle(pos, 18.0, Color(0.055, 0.647, 0.898))
		draw_circle(pos, 11.0, Color(0.878, 0.949, 0.996))
		draw_circle(pos + aim * 4.0, 5.0, Color(0.059, 0.090, 0.165))
