class_name DragonRpg
extends RefCounted
## Logic for the 3D action-RPG "Drachen-RPG".
## Port of `src/game/dragonRpg.ts`.

const BOSS_EVERY := 5

const DRAGON_TYPES: Array[Dictionary] = [
	{"id": "dragon_hatchling", "name": "Schlüpfling", "asset": "rpg/dragon_hatchling", "tier": 1, "hp": 26.0, "speed": 4.4, "damage": 6.0, "radius": 0.85, "scale": 0.8, "xp": 5, "gold": 2, "boss": false, "flying": false, "color": Color("86efac")},
	{"id": "dragon_ember", "name": "Glutdrache", "asset": "rpg/dragon_ember", "tier": 2, "hp": 44.0, "speed": 4.9, "damage": 9.0, "radius": 1.0, "scale": 0.95, "xp": 9, "gold": 4, "boss": false, "flying": false, "color": Color("f97316")},
	{"id": "dragon_frost", "name": "Frostdrache", "asset": "rpg/dragon_frost", "tier": 2, "hp": 50.0, "speed": 4.5, "damage": 8.0, "radius": 1.0, "scale": 0.95, "xp": 9, "gold": 4, "boss": false, "flying": true, "color": Color("7dd3fc")},
	{"id": "dragon_venom", "name": "Giftdrache", "asset": "rpg/dragon_venom", "tier": 3, "hp": 70.0, "speed": 5.3, "damage": 11.0, "radius": 1.05, "scale": 0.95, "xp": 14, "gold": 6, "boss": false, "flying": false, "color": Color("a3e635")},
	{"id": "dragon_storm", "name": "Sturmdrache", "asset": "rpg/dragon_storm", "tier": 3, "hp": 64.0, "speed": 6.0, "damage": 10.0, "radius": 1.0, "scale": 0.95, "xp": 14, "gold": 6, "boss": false, "flying": true, "color": Color("c084fc")},
	{"id": "dragon_stone", "name": "Steindrache", "asset": "rpg/dragon_stone", "tier": 3, "hp": 96.0, "speed": 3.7, "damage": 14.0, "radius": 1.15, "scale": 1.0, "xp": 15, "gold": 7, "boss": false, "flying": false, "color": Color("a8a29e")},
	{"id": "dragon_shadow", "name": "Schattendrache", "asset": "rpg/dragon_shadow", "tier": 4, "hp": 120.0, "speed": 5.8, "damage": 15.0, "radius": 1.1, "scale": 1.0, "xp": 22, "gold": 10, "boss": false, "flying": true, "color": Color("8b5cf6")},
	{"id": "dragon_bone", "name": "Knochendrache", "asset": "rpg/dragon_bone", "tier": 4, "hp": 140.0, "speed": 4.2, "damage": 16.0, "radius": 1.15, "scale": 1.0, "xp": 23, "gold": 11, "boss": false, "flying": false, "color": Color("e7e5d8")},
	{"id": "dragon_crystal", "name": "Kristalldrache", "asset": "rpg/dragon_crystal", "tier": 4, "hp": 130.0, "speed": 5.0, "damage": 15.0, "radius": 1.15, "scale": 1.05, "xp": 24, "gold": 12, "boss": false, "flying": true, "color": Color("67e8f9")},
	{"id": "dragon_gold", "name": "Golddrache", "asset": "rpg/dragon_gold", "tier": 5, "hp": 190.0, "speed": 4.8, "damage": 18.0, "radius": 1.2, "scale": 1.1, "xp": 34, "gold": 22, "boss": false, "flying": true, "color": Color("fbbf24")},
	{"id": "dragon_elder", "name": "Urdrache", "asset": "rpg/dragon_elder", "tier": 5, "hp": 300.0, "speed": 4.0, "damage": 24.0, "radius": 1.5, "scale": 1.3, "xp": 60, "gold": 40, "boss": true, "flying": false, "color": Color("ef4444")},
	{"id": "dragon_lord", "name": "Drachenfürst", "asset": "rpg/dragon_lord", "tier": 5, "hp": 460.0, "speed": 4.6, "damage": 30.0, "radius": 1.75, "scale": 1.55, "xp": 110, "gold": 80, "boss": true, "flying": false, "color": Color("a855f7")},
]

const WEAPONS: Array[Dictionary] = [
	{"id": "sword", "name": "Schwert", "asset": "rpg/sword", "damage": 12.0, "cooldown": 0.42, "range": 3.4, "arc": 1.05, "scale": 1.0, "ranged": false, "projectileSpeed": 0.0, "color": Color("cbd5e1")},
	{"id": "dagger", "name": "Dolch", "asset": "rpg/dagger", "damage": 7.0, "cooldown": 0.24, "range": 2.7, "arc": 0.85, "scale": 1.0, "ranged": false, "projectileSpeed": 0.0, "color": Color("e2e8f0")},
	{"id": "greatsword", "name": "Großschwert", "asset": "rpg/greatsword", "damage": 26.0, "cooldown": 0.82, "range": 4.0, "arc": 1.5, "scale": 1.0, "ranged": false, "projectileSpeed": 0.0, "color": Color("93c5fd")},
	{"id": "axe", "name": "Axt", "asset": "rpg/axe", "damage": 18.0, "cooldown": 0.6, "range": 3.5, "arc": 1.25, "scale": 1.0, "ranged": false, "projectileSpeed": 0.0, "color": Color("fca5a5")},
	{"id": "staff", "name": "Zauberstab", "asset": "rpg/staff", "damage": 14.0, "cooldown": 0.62, "range": 26.0, "arc": 0.12, "scale": 1.0, "ranged": true, "projectileSpeed": 24.0, "color": Color("c084fc")},
	{"id": "bow", "name": "Bogen", "asset": "rpg/bow", "damage": 9.0, "cooldown": 0.38, "range": 30.0, "arc": 0.1, "scale": 1.0, "ranged": true, "projectileSpeed": 36.0, "color": Color("fbbf24")},
]

const LOOT_TABLE: Array[Dictionary] = [
	{"id": "coin", "name": "Goldmünze", "asset": "rpg/coin", "kind": "gold", "value": 3, "weight": 46, "color": Color("fbbf24")},
	{"id": "gem", "name": "Edelstein", "asset": "rpg/gem", "kind": "treasure", "value": 12, "weight": 20, "color": Color("22d3ee")},
	{"id": "potion_health", "name": "Heiltrank", "asset": "rpg/potion_health", "kind": "potion", "value": 30, "weight": 12, "color": Color("ef4444")},
	{"id": "potion_mana", "name": "Manatrank", "asset": "rpg/potion_mana", "kind": "potion", "value": 18, "weight": 8, "color": Color("3b82f6")},
	{"id": "scroll", "name": "Schriftrolle", "asset": "rpg/scroll", "kind": "treasure", "value": 8, "weight": 8, "color": Color("d6c6a0")},
	{"id": "key", "name": "Schlüssel", "asset": "rpg/key", "kind": "treasure", "value": 10, "weight": 5, "color": Color("fcd34d")},
	{"id": "ring", "name": "Ring", "asset": "rpg/ring", "kind": "treasure", "value": 16, "weight": 4, "color": Color("facc15")},
	{"id": "amulet", "name": "Amulett", "asset": "rpg/amulet", "kind": "treasure", "value": 20, "weight": 3, "color": Color("a855f7")},
	{"id": "shield", "name": "Schild", "asset": "rpg/shield", "kind": "treasure", "value": 18, "weight": 3, "color": Color("94a3b8")},
	{"id": "helmet", "name": "Helm", "asset": "rpg/helmet", "kind": "treasure", "value": 15, "weight": 3, "color": Color("cbd5e1")},
	{"id": "armor", "name": "Rüstung", "asset": "rpg/armor", "kind": "treasure", "value": 22, "weight": 2, "color": Color("94a3b8")},
	{"id": "boots", "name": "Stiefel", "asset": "rpg/boots", "kind": "treasure", "value": 12, "weight": 3, "color": Color("64748b")},
	{"id": "crown", "name": "Krone", "asset": "rpg/crown", "kind": "treasure", "value": 40, "weight": 1, "color": Color("fde047")},
]


static func dragon_by_id(id: String) -> Dictionary:
	for dragon in DRAGON_TYPES:
		if str(dragon["id"]) == id:
			return dragon
	return DRAGON_TYPES[0]


## Wave tuning: more/faster/tougher dragons, a boss every `BOSS_EVERY` waves.
static func wave_config(wave: int) -> Dictionary:
	var w: int = maxi(1, wave)
	var max_tier: int = mini(5, 1 + int(floor(float(w - 1) / 2.0)))
	var pool: Array[Dictionary] = []
	for dragon in DRAGON_TYPES:
		if not bool(dragon["boss"]) and int(dragon["tier"]) <= max_tier:
			pool.append(dragon)
	var boss: bool = w % BOSS_EVERY == 0
	return {
		"wave": w,
		"count": mini(36, 3 + w * 2),
		"pool": pool,
		"hpMult": 1.0 + float(w - 1) * 0.24,
		"speedMult": minf(1.9, 1.0 + float(w - 1) * 0.05),
		"damageMult": 1.0 + float(w - 1) * 0.12,
		"boss": boss,
		"bossType": dragon_by_id("dragon_lord" if w % 10 == 0 else "dragon_elder") if boss else null,
	}


static func scaled_dragon(type: Dictionary, cfg: Dictionary) -> Dictionary:
	return {
		"hp": roundi(float(type["hp"]) * float(cfg["hpMult"])),
		"speed": float(type["speed"]) * float(cfg["speedMult"]),
		"damage": roundi(float(type["damage"]) * float(cfg["damageMult"])),
	}


# --- player -----------------------------------------------------------------

class Stats:
	extends RefCounted
	var max_hp: float = 100.0
	var hp: float = 100.0
	var damage_mult: float = 1.0
	var cooldown_mult: float = 1.0
	var move_speed: float = 9.0
	var pickup_radius: float = 2.4
	var armor: float = 0.0
	var crit_chance: float = 0.08
	var crit_mult: float = 2.0

	func clone() -> Stats:
		var copy := Stats.new()
		copy.max_hp = max_hp
		copy.hp = hp
		copy.damage_mult = damage_mult
		copy.cooldown_mult = cooldown_mult
		copy.move_speed = move_speed
		copy.pickup_radius = pickup_radius
		copy.armor = armor
		copy.crit_chance = crit_chance
		copy.crit_mult = crit_mult
		return copy

	## Returns a new stats object with the permanent level-up bonuses applied.
	func leveled_up() -> Stats:
		var next := clone()
		next.max_hp = max_hp + 14.0
		next.hp = next.max_hp
		next.damage_mult = damage_mult * 1.09
		next.cooldown_mult = maxf(0.55, cooldown_mult * 0.97)
		next.move_speed = move_speed * 1.01
		next.armor = armor + 0.6
		next.crit_chance = minf(0.6, crit_chance + 0.01)
		return next


static func base_player_stats() -> Stats:
	return Stats.new()


## XP required to advance from `level` to the next level.
static func xp_to_next(level: int) -> int:
	var l: int = maxi(1, level)
	return roundi(8.0 + float(l) * 6.0 + float(l) * float(l) * 1.5)


# --- weapons ----------------------------------------------------------------

static func weapon_by_id(id: String) -> Dictionary:
	for weapon in WEAPONS:
		if str(weapon["id"]) == id:
			return weapon
	return WEAPONS[0]


static func random_weapon() -> Dictionary:
	return WEAPONS[randi() % WEAPONS.size()]


# --- loot -------------------------------------------------------------------

## Weighted random loot entry.
static func roll_loot() -> Dictionary:
	var total := 0
	for entry in LOOT_TABLE:
		total += int(entry["weight"])
	var roll := randf() * float(total)
	for entry in LOOT_TABLE:
		roll -= float(entry["weight"])
		if roll <= 0.0:
			return entry
	return LOOT_TABLE[0]


# --- combat -----------------------------------------------------------------

## True when two circles overlap.
static func circles_overlap(ax: float, az: float, ar: float, bx: float, bz: float, br: float) -> bool:
	var dx := ax - bx
	var dz := az - bz
	var radius := ar + br
	return dx * dx + dz * dz <= radius * radius


## True when a target lies within `range` of an attacker and inside the swing
## arc centred on `facing` (radians, 0 = facing -Z).
static func in_melee_arc(ax: float, az: float, facing: float, tx: float, tz: float, range: float, half_arc: float) -> bool:
	var dx := tx - ax
	var dz := tz - az
	var dist_sq := dx * dx + dz * dz
	if dist_sq > range * range:
		return false
	if dist_sq < 0.000001:
		return true
	var dist := sqrt(dist_sq)
	var fx := -sin(facing)
	var fz := -cos(facing)
	var dot := (dx * fx + dz * fz) / dist
	return dot >= cos(half_arc)


## Player damage against a dragon, including crits.
static func roll_damage(base: float, stats: Stats) -> Dictionary:
	var crit: bool = randf() < stats.crit_chance
	var raw := base * stats.damage_mult * (stats.crit_mult if crit else 1.0)
	return {"damage": maxi(1, roundi(raw)), "crit": crit}


## Incoming damage after armor mitigation (always at least 1).
static func mitigate_damage(raw: float, armor: float) -> float:
	var safe_armor: float = maxf(0.0, armor)
	return float(maxi(1, roundi(raw * (1.0 - safe_armor / (safe_armor + 40.0)))))


## End-of-run score: gold plus wave and level bonuses.
static func score_for(wave: int, level: int, gold: int) -> int:
	return roundi(float(gold) + float(maxi(1, wave)) * 120.0 + float(maxi(1, level)) * 60.0)
