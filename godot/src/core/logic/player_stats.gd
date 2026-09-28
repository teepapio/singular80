class_name PlayerStats
extends RefCounted
## Player stat block of the arena game plus the upgrade maths.
## Port of `src/game/stats.ts`.

var max_hp: float = 120.0
var hp: float = 120.0
var move_speed: float = 235.0
var move_speed_mult: float = 1.0
var damage: float = 0.0
var damage_mult: float = 1.0
var fire_rate: float = 0.0
var projectile_speed: float = 0.0
var projectile_count: float = 1.0
var spread: float = 0.0
var pierce: float = 0.0
var pickup_radius: float = 70.0
var hp_regen: float = 0.0
var crit_chance: float = 0.05
var crit_mult: float = 1.5
var armor: float = 0.0
var xp_mult: float = 1.0
var level: int = 1
var xp: float = 0.0
var xp_next: float = 0.0

const NUMERIC_FIELDS := [
	"max_hp", "hp", "move_speed", "move_speed_mult", "damage", "damage_mult",
	"fire_rate", "projectile_speed", "projectile_count", "spread", "pierce",
	"pickup_radius", "hp_regen", "crit_chance", "crit_mult", "armor", "xp_mult",
]


static func create(weapon: Dictionary) -> PlayerStats:
	var stats := PlayerStats.new()
	stats.damage = float(weapon.get("damage", 10))
	stats.projectile_speed = float(weapon.get("projectileSpeed", 400))
	stats.projectile_count = float(weapon.get("projectileCount", 1))
	stats.spread = float(weapon.get("spread", 0.0))
	stats.pierce = float(weapon.get("pierce", 0))
	stats.xp_next = xp_for_level(1)
	return stats


## The level curve of every game that levels a hero. Two entries, because the
## arena and the dragon RPG are two different games with two different
## progressions — but they are one table and one formula, so a third game cannot
## spell a third copy of "a level costs more than the last" and drift away from
## both.
##
## `per_level` counts from the *previous* level, so the RPG's `8 + 6l + 1.5l²`
## reads as `base 14 + 6 per level + 1.5 per level squared`.
const XP_CURVES := {
	"arena": {"base": 6.0, "per_level": 5.0, "exponent": 1.75},
	"rpg": {"base": 14.0, "per_level": 6.0, "quadratic": 1.5},
}


## The raw curve value for `level` under the named curve, unrounded: the two
## games round differently (the arena floors, the RPG rounds), and that rounding
## is part of what each one shows the player.
static func xp_with_curve(level: int, curve: String) -> float:
	var spec: Dictionary = XP_CURVES.get(curve, {})
	var l: int = maxi(1, level)
	var total := float(spec.get("base", 0.0)) + float(l - 1) * float(spec.get("per_level", 0.0))
	if spec.has("exponent"):
		total += pow(float(l), float(spec["exponent"]))
	total += float(l) * float(l) * float(spec.get("quadratic", 0.0))
	return total


static func xp_for_level(level: int) -> float:
	return floor(xp_with_curve(level, "arena"))


## The hard caps of the shooting rules. They used to be typed in twice — once
## here, once in `ArenaRuns`, which previews the same numbers for the level-up
## cards — so the card could promise a fire rate the stat block refused to keep.
const MAX_FIRE_RATE := 8.0
const MAX_CRIT_CHANCE := 0.9
## No weapon draws faster than this, whatever the fire rate says.
const MIN_COOLDOWN_MS := 70.0


## Applies one upgrade definition. Unknown stats are ignored, `max_hp` heals and
## the crit/fire-rate caps from the original rules are enforced.
func apply_upgrade(upgrade: Dictionary) -> void:
	var stat := str(upgrade.get("stat", ""))
	var amount := float(upgrade.get("amount", 0.0))
	if stat == "max_hp":
		max_hp += amount
		hp = minf(max_hp, hp + amount)
		return
	if stat == "hp":
		hp = minf(max_hp, hp + amount)
		return
	if stat in NUMERIC_FIELDS:
		set(stat, float(get(stat)) + amount)
	if stat == "projectile_count":
		spread = maxf(spread, 0.12)
	crit_chance = minf(crit_chance, MAX_CRIT_CHANCE)
	fire_rate = minf(fire_rate, MAX_FIRE_RATE)


func effective_move_speed() -> float:
	return move_speed * move_speed_mult


func effective_damage() -> float:
	return damage * damage_mult


func effective_cooldown(weapon: Dictionary) -> float:
	return maxf(MIN_COOLDOWN_MS, float(weapon.get("cooldown", 500)) / (1.0 + fire_rate))
