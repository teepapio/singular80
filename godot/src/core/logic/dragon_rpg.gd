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

## Rarity drives both the drop weighting and the loot's look in the world.
## Order matters: later entries are strictly better, which is what
## `loot_score` ranks by.
const RARITIES: Array[Dictionary] = [
	{"id": "common", "name": "Gewöhnlich", "color": Color("94a3b8"), "weight": 62, "glow": 0.0},
	{"id": "uncommon", "name": "Ungewöhnlich", "color": Color("4ade80"), "weight": 26, "glow": 0.5},
	{"id": "rare", "name": "Selten", "color": Color("38bdf8"), "weight": 9, "glow": 1.0},
	{"id": "epic", "name": "Episch", "color": Color("c084fc"), "weight": 2.5, "glow": 1.5},
	{"id": "legendary", "name": "Legendär", "color": Color("fbbf24"), "weight": 0.5, "glow": 2.0},
]

const LOOT_TABLE: Array[Dictionary] = [
	{"id": "coin", "name": "Goldmünze", "asset": "rpg/coin", "kind": "gold", "value": 3, "weight": 46, "rarity": "common", "color": Color("fbbf24")},
	{"id": "gem", "name": "Edelstein", "asset": "rpg/gem", "kind": "treasure", "value": 12, "weight": 20, "rarity": "uncommon", "color": Color("22d3ee")},
	{"id": "potion_health", "name": "Heiltrank", "asset": "rpg/potion_health", "kind": "potion", "value": 30, "weight": 12, "rarity": "uncommon", "color": Color("ef4444")},
	{"id": "potion_mana", "name": "Manatrank", "asset": "rpg/potion_mana", "kind": "potion", "value": 18, "weight": 8, "rarity": "uncommon", "color": Color("3b82f6")},
	{"id": "scroll", "name": "Schriftrolle", "asset": "rpg/scroll", "kind": "treasure", "value": 8, "weight": 8, "rarity": "common", "color": Color("d6c6a0")},
	{"id": "key", "name": "Schlüssel", "asset": "rpg/key", "kind": "treasure", "value": 10, "weight": 5, "rarity": "uncommon", "color": Color("fcd34d")},
	{"id": "ring", "name": "Ring", "asset": "rpg/ring", "kind": "treasure", "value": 16, "weight": 4, "rarity": "rare", "color": Color("facc15")},
	{"id": "amulet", "name": "Amulett", "asset": "rpg/amulet", "kind": "treasure", "value": 20, "weight": 3, "rarity": "rare", "color": Color("a855f7")},
	{"id": "shield", "name": "Schild", "asset": "rpg/shield", "kind": "treasure", "value": 18, "weight": 3, "rarity": "rare", "color": Color("94a3b8")},
	{"id": "helmet", "name": "Helm", "asset": "rpg/helmet", "kind": "treasure", "value": 15, "weight": 3, "rarity": "rare", "color": Color("cbd5e1")},
	{"id": "armor", "name": "Rüstung", "asset": "rpg/armor", "kind": "treasure", "value": 22, "weight": 2, "rarity": "epic", "color": Color("94a3b8")},
	{"id": "boots", "name": "Stiefel", "asset": "rpg/boots", "kind": "treasure", "value": 12, "weight": 3, "rarity": "rare", "color": Color("64748b")},
	{"id": "crown", "name": "Krone", "asset": "rpg/crown", "kind": "treasure", "value": 40, "weight": 1, "rarity": "legendary", "color": Color("fde047")},
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


# --- Drachenflucht ----------------------------------------------------------

## Tuning of the escape burst. It has to be strong enough to outrun the fastest
## dragon of a late wave, otherwise the button is decoration: from wave 18 on a
## Sturmdrache is quicker than the player, so walking away is not an option.
const DASH_DURATION := 0.24
const DASH_COOLDOWN := 1.15
const DASH_SPEED_MULT := 2.6
## The invulnerability outlives the burst on purpose — the frames right after
## the last one are exactly the ones in which a dragon would catch up.
const DASH_IFRAMES := 0.38


## Ground distance a dash covers, which is `move_speed` × the burst time. The
## tests compare it against a dragon's speed to prove the escape works.
static func dash_distance(move_speed: float) -> float:
	return maxf(0.0, move_speed) * DASH_SPEED_MULT * DASH_DURATION


## Direction of a panic dash.
##
## `wanted` is the stick, `to_threat` points from the player to the nearest
## dragon. The stick wins; a player who does not touch it still flees straight
## away from the dragon, which is what makes the button usable while both thumbs
## are busy. `fallback` (the facing) closes the last gap so the result is never
## the zero vector.
static func dash_direction(wanted: Vector2, to_threat: Vector2, fallback: Vector3) -> Vector3:
	if wanted.length() > 0.05:
		return Vector3(wanted.x, 0.0, wanted.y).normalized()
	if to_threat.length() > 0.01:
		return Vector3(-to_threat.x, 0.0, -to_threat.y).normalized()
	var safe := fallback
	safe.y = 0.0
	if safe.length() < 0.01:
		return Vector3.FORWARD
	return safe.normalized()


class Dash:
	extends RefCounted
	## One escape slot: the burst itself plus the cooldown that follows. The
	## screen only asks `step()` where to go and `iframes()` whether a dragon may
	## still land a hit.

	var cooldown_left: float = 0.0
	var time_left: float = 0.0
	var iframe_left: float = 0.0
	var direction: Vector3 = Vector3.ZERO

	## True while the next press would be accepted.
	func ready() -> bool:
		return time_left <= 0.0 and cooldown_left <= 0.0

	## Starts the burst. Returns false when the cooldown is still running or when
	## there is no direction to flee to at all.
	func start(wanted: Vector3) -> bool:
		if not ready():
			return false
		var safe := wanted
		safe.y = 0.0
		if safe.length() < 0.01:
			return false
		direction = safe.normalized()
		time_left = DASH_DURATION
		cooldown_left = DASH_COOLDOWN
		iframe_left = DASH_IFRAMES
		return true

	## Ages all three timers; call once per frame.
	func tick(dt: float) -> void:
		cooldown_left = maxf(0.0, cooldown_left - dt)
		time_left = maxf(0.0, time_left - dt)
		iframe_left = maxf(0.0, iframe_left - dt)

	## Displacement for this frame — zero while the player walks normally, which
	## is what lets the screen fall back to its own movement. Never overshoots
	## the burst, however long the frame was.
	func step(dt: float, move_speed: float) -> Vector3:
		if time_left <= 0.0:
			return Vector3.ZERO
		return direction * maxf(0.0, move_speed) * DASH_SPEED_MULT * minf(dt, time_left)

	## Remaining invulnerability, for the player's hurt check.
	func iframes() -> float:
		return iframe_left

	## 1.0 = ready, 0.0 = just fled. The HUD fills its bar with it.
	func charge() -> float:
		if ready():
			return 1.0
		return clampf(1.0 - cooldown_left / DASH_COOLDOWN, 0.0, 1.0)


# --- weapons ----------------------------------------------------------------

static func weapon_by_id(id: String) -> Dictionary:
	for weapon in WEAPONS:
		if str(weapon["id"]) == id:
			return weapon
	return WEAPONS[0]


static func random_weapon() -> Dictionary:
	return WEAPONS[randi() % WEAPONS.size()]


# --- loot -------------------------------------------------------------------

## Rarity row by id, falling back to "common".
static func rarity_by_id(id: String) -> Dictionary:
	for rarity in RARITIES:
		if str(rarity["id"]) == id:
			return rarity
	return RARITIES[0]


## Index of a rarity in `RARITIES`; unknown ids become common.
static func rarity_index(id: String) -> int:
	for i in RARITIES.size():
		if str((RARITIES[i] as Dictionary)["id"]) == id:
			return i
	return 0


## The rarity a table entry belongs to.
static func rarity_of(entry: Dictionary) -> Dictionary:
	return rarity_by_id(str(entry.get("rarity", "common")))


## Loot table row by id, falling back to the most common drop.
static func loot_by_id(id: String) -> Dictionary:
	for entry in LOOT_TABLE:
		if str(entry["id"]) == id:
			return entry
	return LOOT_TABLE[0]


## Effective drop weight of one table row at a given luck level.
##
## Rarity 0 keeps its base weight; every step above multiplies it by
## `1 + luck * index²`, so luck never *reduces* a chance.
static func lottery_weight(entry: Dictionary, luck: float = 0.0) -> float:
	var index := rarity_index(str(entry.get("rarity", "common")))
	var factor: float = 1.0 + clampf(luck, 0.0, 1.0) * float(index) * float(index)
	return float(entry.get("weight", 0.0)) * factor


## Weighted random loot entry.
##
## `luck` (0.0–1.0) shifts weight towards the better rarities: a boss at 1.0
## drops almost exclusively epic or legendary, trash at 0.0 almost never does.
static func roll_loot(luck: float = 0.0) -> Dictionary:
	var weights: Array[float] = []
	var total := 0.0
	for entry in LOOT_TABLE:
		var weight := lottery_weight(entry, luck)
		weights.append(weight)
		total += weight
	var roll := randf() * total
	for i in LOOT_TABLE.size():
		roll -= weights[i]
		if roll <= 0.0:
			return LOOT_TABLE[i]
	return LOOT_TABLE[0]


## How good a drop is, for "you already have something better" comparisons.
## Value dominates, rarity breaks ties.
static func loot_score(entry: Dictionary) -> float:
	var rarity := rarity_of(entry)
	return float(entry.get("value", 0)) + float(rarity_index(str(rarity["id"]))) * 10.0


## Compare a fresh drop against the best item of the same kind already taken.
##
## Returns `"upgrade"`, `"downgrade"` or `"same"`; the HUD turns that into the
## green up-arrow / red down-arrow next to the pickup.
static func compare_drop(fresh: Dictionary, best_so_far: Dictionary) -> String:
	if best_so_far.is_empty():
		return "upgrade"
	var a := loot_score(fresh)
	var b := loot_score(best_so_far)
	if a > b:
		return "upgrade"
	if a < b:
		return "downgrade"
	return "same"


## How much luck a dragon grants: bosses always high, trash never above 0.3.
static func luck_for(dragon: Dictionary) -> float:
	if bool(dragon.get("boss", false)):
		return 1.0
	var tier: int = int(dragon.get("tier", 1))
	return clampf(0.1 + float(tier) * 0.06, 0.0, 0.4)


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
