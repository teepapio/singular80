class_name DashMechanic
extends Mechanic
## Dash: a short burst of speed with invulnerability.
## Port of `src/game/mechanics/dash.ts`.

const DASH_SPEED := 980.0
const DASH_TIME := 0.17
const COOLDOWN := 1.5

var _cooldown: float = 0.0
var _time: float = 0.0
var _dir := Vector2.RIGHT


func _init() -> void:
	id = "dash"
	mechanic_name = "Dash"
	description = Loc.f("Jump key: a short dash with invulnerability.", [])


func init_mechanic(host: Node) -> void:
	host.set_hint("Jump / dash key = dash")


func update_mechanic(host: Node, delta: float) -> void:
	_cooldown = maxf(0.0, _cooldown - delta)
	_time = maxf(0.0, _time - delta)
	if not Input.is_action_just_pressed("dash"):
		return
	if _cooldown > 0.0 or _time > 0.0:
		return
	var dir: Vector2 = host.input_direction()
	var aim: Vector2 = host.aim_direction()
	if dir == Vector2.ZERO:
		dir = aim
	if dir == Vector2.ZERO:
		dir = Vector2.RIGHT
	_dir = dir.normalized()
	_time = DASH_TIME
	_cooldown = COOLDOWN
	host.grant_invulnerability((DASH_TIME + 0.08) * 1000.0)
	Sfx.dash()
	host.shake_camera(60.0, 0.002)


func movement_override(_host: Node, delta: float) -> Variant:
	if _time <= 0.0:
		return null
	_time = maxf(0.0, _time - delta)
	return {"x": _dir.x * DASH_SPEED, "y": _dir.y * DASH_SPEED}


func hud(_host: Node) -> String:
	if _cooldown <= 0.0:
		return Loc.f("Dash ready", [])
	return Loc.f("Dash %.1fs", [_cooldown])


func reset() -> void:
	_cooldown = 0.0
	_time = 0.0
