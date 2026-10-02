class_name DragonFlight
extends RefCounted
## Logic for "Drachenflug" — the 3D dragon-flight game with its hatchery.
##
## Everything that can be decided without a renderer lives here: the breeds, the
## heritable traits and their genetics, the enemies, the power-ups, the 30 levels
## with their unlock rules, the permanent upgrades and the save file. The three
## screens (hangar, flight, hatchery) only draw what this module decides, which
## is what the headless test suite exercises.
##
## Design goals:
##  - breeding is the progression: a dragon is a breed plus an allele set, and
##    cross breeding mixes alleles, so rare traits need two carriers
##  - every number a run depends on comes from `resolve_stats()`, so a gene, a
##    breed and an upgrade can never disagree about what a dragon does
##  - the profile is a plain Dictionary that round-trips through JSON

const DEFAULT_SAVE_PATH := "user://dragonflight.json"
## Where the profile lives. Tests point this at their own file so a headless run
## never overwrites the player's dragons.
static var save_path: String = DEFAULT_SAVE_PATH

## Flight corridor. The dragon flies over the landscape, so it never touches the
## ground: everything is measured in world units around a fixed player position.
const ARENA_HALF_WIDTH := 26.0
const CEILING := 21.0
const FLOOR := 3.2
const SPAWN_Z := -110.0
const DESPAWN_Z := 22.0
const PLAYER_Z := 0.0

const PLAYER_RADIUS := 1.15
const HIT_INVULN := 1.1
const MAX_ENEMIES := 90
const MAX_SHOTS := 70
const MAX_PICKUPS := 40

## A run is scored on distance, kills and the gold left in the air.
const GOLD_PER_KILL_BASE := 2

## Flight control. The dragon does not accelerate: a held direction sets the
## speed at once, a released one coasts out over `1 / GLIDE_DECAY` seconds.
const GLIDE_DECAY := 6.0
## Below this the stick counts as centred, so a thumb resting on the knob does
## not make the dragon drift.
const STICK_DEADZONE := 0.12


## Turns a merged stick/keyboard vector into a direction in world axes.
##
## Both inputs arrive in *screen* axes, and screen +Y points down: the stick
## reports +1 when the finger moves down, and `Input.get_axis(&"move_up",
## &"move_down")` is `strength(move_down) - strength(move_up)` (Godot 4.5
## `Input.get_axis`), so the keyboard and the gamepad agree with the finger.
## The camera follows from behind and looks down the corridor towards -Z, so
## world +Y is up on the screen. Handing that vector straight to the altitude
## flew the dragon upside down: stick up and W dived. Only the altitude flips
## — the roll axis already matches the screen, and the corridor is symmetric.
static func flight_direction(input_vector: Vector2) -> Vector2:
	return Vector2(input_vector.x, -input_vector.y)


## The flight velocity for this frame's input, given the current one.
##
## Both axes are read every frame instead of one after the other. The `elif`
## this replaces picked a single axis per frame, which had two consequences
## that made the vertical one feel arbitrary: a diagonal push moved the dragon
## sideways only, and a climb rate that had been built up stayed latched while
## the stick was held sideways, so the dragon kept rising with no input. An
## axis that is not held coasts back to level flight on its own, which is both
## the dragon's behaviour and what keeps the corridor readable.
static func flight_velocity(input_vector: Vector2, current: Vector2, dt: float) -> Vector2:
	var move := flight_direction(input_vector)
	var out := current
	var decay := clampf(dt * GLIDE_DECAY, 0.0, 1.0)
	if absf(move.x) > STICK_DEADZONE:
		out.x = move.x
	else:
		out.x = lerpf(out.x, 0.0, decay)
	if absf(move.y) > STICK_DEADZONE:
		out.y = move.y
	else:
		out.y = lerpf(out.y, 0.0, decay)
	return out


# --- biomes -----------------------------------------------------------------
## One entry per block of three levels. The screen reads the colours from here so
## a new biome only has to be described once.
const BIOMES: Array[Dictionary] = [
	{"id": "grasland", "name": "Grassland", "fog": "a7f3d0", "ambient": "bbf7d0", "ground": "4a7c3f", "accent": "22c55e"},
	{"id": "berge", "name": "Highland", "fog": "c7d2fe", "ambient": "e0e7ff", "ground": "6b7280", "accent": "818cf8"},
	{"id": "wueste", "name": "Desert", "fog": "fed7aa", "ambient": "fef3c7", "ground": "c2813f", "accent": "f59e0b"},
	{"id": "vulkan", "name": "Volcano", "fog": "fca5a5", "ambient": "fed7aa", "ground": "4b2b23", "accent": "ef4444"},
	{"id": "eis", "name": "Ice Field", "fog": "bae6fd", "ambient": "e0f2fe", "ground": "8fa8bf", "accent": "38bdf8"},
	{"id": "sturm", "name": "Whirlwind", "fog": "94a3b8", "ambient": "cbd5e1", "ground": "475569", "accent": "8b5cf6"},
	{"id": "nacht", "name": "Night Flight", "fog": "312e81", "ambient": "4c1d95", "ground": "1e1b4b", "accent": "a855f7"},
	{"id": "sumpf", "name": "Swamp", "fog": "bef264", "ambient": "d9f99d", "ground": "3f6212", "accent": "84cc16"},
	{"id": "schlucht", "name": "Dragon Gorge", "fog": "fdba74", "ambient": "fed7aa", "ground": "7c2d12", "accent": "fb923c"},
	{"id": "himmel", "name": "Sky Realm", "fog": "dbe4ff", "ambient": "f8fafc", "ground": "6b7fa8", "accent": "facc15"},
]


# --- breeds -----------------------------------------------------------------
## The dragons a player can own. `asset` is a mesh key: most breeds reuse the
## dragon meshes of the RPG pack, the four sky breeds come from the flight pack.
## Stats are the base values; traits and upgrades are applied on top.
const BREEDS: Array[Dictionary] = [
	{
		"id": "ember", "name": "Ember Dragon", "asset": "rpg/dragon_ember", "egg": "flight/egg",
		"tier": 1, "price": 0, "element": "fire", "size": 1.0, "wings": 1.0,
		"hp": 100.0, "speed": 20.0, "turn": 3.0, "fireRate": 0.36, "damage": 17.0,
		"shotSpeed": 46.0, "shotSize": 1.0, "armor": 0.0, "crit": 0.06, "goldMult": 1.0, "pickup": 2.6,
		"body": "b45309", "belly": "fbbf24", "accent": "fde047", "eggColor": "f97316",
		"desc": "A sturdy starter. Fires fast and forgives mistakes.",
	},
	{
		"id": "frost", "name": "Frost Dragon", "asset": "rpg/dragon_frost", "egg": "flight/egg",
		"tier": 1, "price": 450, "element": "ice", "size": 1.0, "wings": 1.0,
		"hp": 112.0, "speed": 19.0, "turn": 2.8, "fireRate": 0.42, "damage": 19.0,
		"shotSpeed": 50.0, "shotSize": 1.05, "armor": 0.06, "crit": 0.05, "goldMult": 1.0, "pickup": 2.6,
		"body": "1d4ed8", "belly": "bae6fd", "accent": "e0f2fe", "eggColor": "38bdf8",
		"desc": "Slower but tough — soaks up hits well.",
	},
	{
		"id": "storm", "name": "Storm Dragon", "asset": "rpg/dragon_storm", "egg": "flight/egg",
		"tier": 2, "price": 900, "element": "storm", "size": 1.05, "wings": 1.1,
		"hp": 104.0, "speed": 23.0, "turn": 3.6, "fireRate": 0.33, "damage": 16.0,
		"shotSpeed": 54.0, "shotSize": 0.95, "armor": 0.0, "crit": 0.1, "goldMult": 1.0, "pickup": 2.8,
		"body": "7c3aed", "belly": "c4b5fd", "accent": "67e8f9", "eggColor": "a855f7",
		"desc": "As agile as the wind — the best all-rounder.",
	},
	{
		"id": "venom", "name": "Venom Dragon", "asset": "rpg/dragon_venom", "egg": "flight/egg",
		"tier": 2, "price": 1100, "element": "poison", "size": 0.98, "wings": 0.95,
		"hp": 98.0, "speed": 21.0, "turn": 3.2, "fireRate": 0.3, "damage": 14.0,
		"shotSpeed": 44.0, "shotSize": 1.1, "armor": 0.0, "crit": 0.08, "goldMult": 1.15, "pickup": 3.0,
		"body": "4d7c0f", "belly": "bef264", "accent": "a855f7", "eggColor": "84cc16",
		"desc": "Hits poison the enemy over time.",
	},
	{
		"id": "stone", "name": "Stone Dragon", "asset": "rpg/dragon_stone", "egg": "flight/egg_large",
		"tier": 3, "price": 1600, "element": "earth", "size": 1.2, "wings": 0.85,
		"hp": 165.0, "speed": 16.5, "turn": 2.2, "fireRate": 0.48, "damage": 27.0,
		"shotSpeed": 40.0, "shotSize": 1.35, "armor": 0.18, "crit": 0.04, "goldMult": 0.95, "pickup": 2.4,
		"body": "57534e", "belly": "a8a29e", "accent": "d6a24a", "eggColor": "78716c",
		"desc": "A tank in the sky. Slow, but hits hard.",
	},
	{
		"id": "shadow", "name": "Shadow Dragon", "asset": "rpg/dragon_shadow", "egg": "flight/egg_crystal",
		"tier": 3, "price": 2100, "element": "void", "size": 1.1, "wings": 1.05,
		"hp": 120.0, "speed": 22.0, "turn": 3.4, "fireRate": 0.28, "damage": 21.0,
		"shotSpeed": 58.0, "shotSize": 0.9, "armor": 0.04, "crit": 0.18, "goldMult": 1.1, "pickup": 3.2,
		"body": "312e81", "belly": "4c1d95", "accent": "a855f7", "eggColor": "6d28d9",
		"desc": "Highest hit chance, almost invisible in twilight light.",
	},
	{
		"id": "crystal", "name": "Crystal Dragon", "asset": "rpg/dragon_crystal", "egg": "flight/egg_crystal",
		"tier": 4, "price": 3000, "element": "ice", "size": 1.15, "wings": 1.0,
		"hp": 135.0, "speed": 20.0, "turn": 3.0, "fireRate": 0.34, "damage": 24.0,
		"shotSpeed": 52.0, "shotSize": 1.15, "armor": 0.08, "crit": 0.1, "goldMult": 1.2, "pickup": 3.4,
		"body": "0891b2", "belly": "a5f3fc", "accent": "67e8f9", "eggColor": "22d3ee",
		"desc": "The projectile splits and hoovers up gold from the air.",
	},
	{
		"id": "gold", "name": "Gold Dragon", "asset": "rpg/dragon_gold", "egg": "flight/egg_large",
		"tier": 4, "price": 3800, "element": "light", "size": 1.22, "wings": 1.1,
		"hp": 145.0, "speed": 19.0, "turn": 2.8, "fireRate": 0.35, "damage": 22.0,
		"shotSpeed": 48.0, "shotSize": 1.2, "armor": 0.1, "crit": 0.08, "goldMult": 1.6, "pickup": 3.6,
		"body": "ca8a04", "belly": "fde68a", "accent": "fef08a", "eggColor": "facc15",
		"desc": "Every dive brings gold. The economy of flight.",
	},
	{
		"id": "cloud", "name": "Cloud Dragon", "asset": "flight/dragon_cloud", "egg": "flight/egg",
		"tier": 5, "price": 5200, "element": "air", "size": 1.3, "wings": 1.45,
		"hp": 155.0, "speed": 25.0, "turn": 4.0, "fireRate": 0.3, "damage": 23.0,
		"shotSpeed": 56.0, "shotSize": 1.0, "armor": 0.05, "crit": 0.12, "goldMult": 1.25, "pickup": 4.0,
		"body": "94a3b8", "belly": "e2e8f0", "accent": "7dd3fc", "eggColor": "cbd5e1",
		"desc": "Tears the clouds apart: the fastest agility in the game.",
	},
	{
		"id": "void", "name": "Void Dragon", "asset": "flight/dragon_void", "egg": "flight/egg_crystal",
		"tier": 5, "price": 7000, "element": "void", "size": 1.5, "wings": 1.6,
		"hp": 180.0, "speed": 23.0, "turn": 3.6, "fireRate": 0.26, "damage": 30.0,
		"shotSpeed": 62.0, "shotSize": 1.25, "armor": 0.12, "crit": 0.2, "goldMult": 1.3, "pickup": 3.8,
		"body": "1e1b4b", "belly": "4c1d95", "accent": "c084fc", "eggColor": "7e22ce",
		"desc": "The end of the breeding line. Huge, fast, hungry.",
	},
]


# --- traits -----------------------------------------------------------------
## Every gene is one gene with two alleles. A dragon carries two allele letters
## per gene; `expressed()` decides whether the gene shows. Dominant traits need
## one copy, recessive ones need two — which is what makes cross breeding the
## only way to a rare combination.
##
## `weight` is how often a randomly bred parent carries the dominant allele, and
## the recessive allele appears at 1/8 of that rate.
const TRAITS: Array[Dictionary] = [
	{
		"id": "feueratem", "name": "Fire Breath", "dom": "F", "weight": 0.34, "recessive": false,
		"desc": "+18 % damage, −5 % fire rate",
		"mods": {"damage": 0.18, "fire_rate": 0.05}, "scale": 1.0, "hue": "f97316",
	},
	{
		"id": "eisenhaut", "name": "Ironhide", "dom": "E", "weight": 0.26, "recessive": false,
		"desc": "+9 % armour, +8 % HP, −6 % speed",
		"mods": {"armor": 0.09, "max_hp": 0.08, "speed": -0.06}, "scale": 1.04, "hue": "94a3b8",
	},
	{
		"id": "sturmfluegel", "name": "Storm Wings", "dom": "W", "weight": 0.3, "recessive": false,
		"desc": "+22 % agility, +8 % speed",
		"mods": {"turn": 0.22, "speed": 0.08}, "scale": 1.0, "hue": "8b5cf6",
	},
	{
		"id": "riesenwuchs", "name": "Giant Growth", "dom": "R", "weight": 0.2, "recessive": true,
		"desc": "+30 % size, +25 % HP, −12 % speed",
		"mods": {"size": 0.3, "max_hp": 0.25, "speed": -0.12}, "scale": 1.22, "hue": "a16207",
	},
	{
		"id": "federleicht", "name": "Featherlight", "dom": "L", "weight": 0.28, "recessive": false,
		"desc": "+15 % speed, −8 % HP",
		"mods": {"speed": 0.15, "max_hp": -0.08}, "scale": 0.94, "hue": "e2e8f0",
	},
	{
		"id": "gifthauch", "name": "Venom Breath", "dom": "G", "weight": 0.22, "recessive": false,
		"desc": "Hits poison enemies over time",
		"mods": {"poison": 1.0}, "scale": 1.0, "hue": "84cc16",
	},
	{
		"id": "nachtfuchs", "name": "Night Fox", "dom": "N", "weight": 0.16, "recessive": true,
		"desc": "+9 % hit chance, +6 % damage",
		"mods": {"crit": 0.09, "damage": 0.06}, "scale": 1.0, "hue": "6d28d9",
	},
	{
		"id": "goldhort", "name": "Gold Hoard", "dom": "D", "weight": 0.24, "recessive": false,
		"desc": "+35 % gold",
		"mods": {"goldMult": 0.35}, "scale": 1.02, "hue": "facc15",
	},
	{
		"id": "hitzebluetig", "name": "Hot-Blooded", "dom": "H", "weight": 0.26, "recessive": false,
		"desc": "+18 % fire rate, −10 % HP",
		"mods": {"fire_rate": -0.18, "max_hp": -0.1}, "scale": 0.98, "hue": "fb923c",
	},
	{
		"id": "zaeherz", "name": "Tough Heart", "dom": "Z", "weight": 0.22, "recessive": true,
		"desc": "+22 % max health",
		"mods": {"max_hp": 0.22}, "scale": 1.06, "hue": "f87171",
	},
	{
		"id": "sturmatem", "name": "Charge Breath", "dom": "S", "weight": 0.18, "recessive": false,
		"desc": "+25 % projectile size, +10 % projectile speed",
		"mods": {"shotSize": 0.25, "shotSpeed": 0.1}, "scale": 1.0, "hue": "38bdf8",
	},
	{
		"id": "sammler", "name": "Collector", "dom": "M", "weight": 0.24, "recessive": false,
		"desc": "+30 % pickup radius, +10 % gold",
		"mods": {"pickup": 0.3, "goldMult": 0.1}, "scale": 1.0, "hue": "2dd4bf",
	},
]


# --- enemies ----------------------------------------------------------------
## `behavior` drives the movement pattern in the screen: `weave` crosses the
## corridor, `dive` aims at the player, `strafe` flies alongside, `turret` sits on
## the ground and shoots up.
const ENEMIES: Array[Dictionary] = [
	{
		"id": "imp", "name": "Marsh", "asset": "flight/imp", "flying": true, "behavior": "weave",
		"hp": 16.0, "speed": 13.0, "damage": 7.0, "score": 40, "gold": 1, "radius": 0.85, "size": 1.35,
		"color": "f472b6", "drop": 0.14,
		"resist": {"fire": 0.0, "ice": 0.0, "poison": 0.2},
	},
	{
		"id": "wyvern", "name": "Wyvern", "asset": "flight/wyvern", "flying": true, "behavior": "dive",
		"hp": 34.0, "speed": 15.0, "damage": 11.0, "score": 90, "gold": 2, "radius": 0.95, "size": 1.0,
		"color": "a78bfa", "drop": 0.2,
		"resist": {"fire": 0.15, "ice": 0.0, "poison": 0.0},
	},
	{
		"id": "harpy", "name": "Harpy", "asset": "flight/harpy", "flying": true, "behavior": "strafe",
		"hp": 26.0, "speed": 18.0, "damage": 9.0, "score": 70, "gold": 1, "radius": 0.8, "size": 1.0,
		"color": "fcd34d", "drop": 0.16,
		"resist": {"fire": 0.0, "ice": 0.25, "poison": 0.0},
	},
	{
		"id": "ballista", "name": "Ballista", "asset": "flight/ballista", "flying": false, "behavior": "turret",
		"hp": 52.0, "speed": 0.0, "damage": 12.0, "score": 120, "gold": 3, "radius": 1.1, "size": 1.0,
		"color": "d6a24a", "drop": 0.3, "ground": true,
		"resist": {"fire": -0.35, "ice": 0.3, "poison": 0.1},
	},
	{
		"id": "golem", "name": "Stone Golem", "asset": "flight/golem", "flying": false, "behavior": "hover",
		"hp": 120.0, "speed": 6.0, "damage": 16.0, "score": 220, "gold": 5, "radius": 1.35, "size": 1.0,
		"color": "a8a29e", "drop": 0.42, "ground": true,
		"resist": {"fire": 0.4, "ice": 0.1, "poison": 0.35},
	},
	{
		"id": "storm_rider", "name": "Storm Rider", "asset": "rpg/dragon_storm", "flying": true, "behavior": "dive",
		"hp": 90.0, "speed": 17.0, "damage": 14.0, "score": 260, "gold": 6, "radius": 1.2, "size": 0.85,
		"color": "c084fc", "drop": 0.38,
		"resist": {"fire": -0.2, "ice": 0.2, "poison": 0.0},
	},
	{
		"id": "bone_warden", "name": "Bone Keeper", "asset": "rpg/dragon_bone", "flying": true, "behavior": "strafe",
		"hp": 150.0, "speed": 12.0, "damage": 18.0, "score": 320, "gold": 7, "radius": 1.25, "size": 0.9,
		"color": "e7e5d8", "drop": 0.44, "armor": 0.25,
		"resist": {"fire": 0.35, "ice": 0.35, "poison": -0.15},
	},
	{
		"id": "sky_tyrant", "name": "Sky Savages", "asset": "rpg/dragon_elder", "flying": true, "behavior": "boss",
		"hp": 900.0, "speed": 11.0, "damage": 22.0, "score": 2200, "gold": 40, "radius": 2.0, "size": 1.25,
		"color": "ef4444", "drop": 1.0, "boss": true, "armor": 0.2,
		"resist": {"fire": 0.3, "ice": 0.3, "poison": 0.2},
	},
	{
		"id": "storm_sovereign", "name": "Storm Ruler", "asset": "rpg/dragon_lord", "flying": true, "behavior": "boss",
		"hp": 1600.0, "speed": 12.5, "damage": 28.0, "score": 4200, "gold": 80, "radius": 2.4, "size": 1.45,
		"color": "a855f7", "drop": 1.0, "boss": true, "armor": 0.3,
		"resist": {"fire": -0.25, "ice": 0.25, "poison": 0.25},
	},
]


# --- power-ups --------------------------------------------------------------
const POWERUPS: Array[Dictionary] = [
	{"id": "heal", "name": "Healing", "asset": "rpg/potion_health", "color": "ef4444", "weight": 26, "duration": 0.0, "amount": 0.28},
	{"id": "shield", "name": "Dragon Shield", "asset": "rpg/shield", "color": "38bdf8", "weight": 16, "duration": 7.0, "amount": 0.0},
	{"id": "rapid", "name": "Fire Storm", "asset": "rpg/rune_stone", "color": "f59e0b", "weight": 18, "duration": 9.0, "amount": 0.6},
	{"id": "magnet", "name": "Lodestone", "asset": "rpg/gem", "color": "2dd4bf", "weight": 14, "duration": 11.0, "amount": 1.8},
	{"id": "gold", "name": "Gold Bag", "asset": "rpg/coin", "color": "facc15", "weight": 18, "duration": 0.0, "amount": 12.0},
	{"id": "egg", "name": "Dragon Egg", "asset": "flight/egg", "color": "fbbf24", "weight": 8, "duration": 0.0, "amount": 1.0},
]


# --- upgrades ---------------------------------------------------------------
## Permanent, bought with Drachengold in the hangar. `stat` is a multiplier per
## level, `cost` grows geometrically so the last levels stay expensive.
const UPGRADES: Array[Dictionary] = [
	{"id": "firepower", "name": "Firepower", "stat": "damage", "per": 0.07, "base": 140, "growth": 1.55, "max": 12,
		"desc": "+7 % damage per level"},
	{"id": "haste", "name": "Rapid Fire", "stat": "fire_rate", "per": -0.05, "base": 160, "growth": 1.58, "max": 10,
		"desc": "−5 % fire rate per level"},
	{"id": "vitality", "name": "Toughness", "stat": "max_hp", "per": 0.09, "base": 150, "growth": 1.56, "max": 12,
		"desc": "+9 % HP per level"},
	{"id": "agility", "name": "Agility", "stat": "speed", "per": 0.05, "base": 130, "growth": 1.54, "max": 10,
		"desc": "+5 % flight speed per level"},
	{"id": "armor", "name": "Horn Armour", "stat": "armor", "per": 0.03, "base": 180, "growth": 1.6, "max": 8,
		"desc": "+3 % armour per level"},
	{"id": "greed", "name": "Greed", "stat": "gold_mult", "per": 0.12, "base": 200, "growth": 1.62, "max": 8,
		"desc": "+12 % gold per level"},
]


# --- levels -----------------------------------------------------------------
## 30 levels in ten biomes, three per biome. Difficulty comes from the four
## multipliers, the enemy pool and the length — `scroll` is the world speed, so a
## late level is not just tougher but also faster to read.
const LEVELS: Array[Dictionary] = [
	# --- Grasland -----------------------------------------------------------
	{"n": 1, "name": "Awakening", "biome": "grasland", "length": 900.0, "scroll": 22.0,
		"pool": [["imp", 10]], "spawn": 1.5, "hpMult": 1.0, "speedMult": 1.0, "damageMult": 1.0, "gold": 60, "boss": ""},
	{"n": 2, "name": "Gust", "biome": "grasland", "length": 1100.0, "scroll": 24.0,
		"pool": [["imp", 10], ["wyvern", 4]], "spawn": 1.35, "hpMult": 1.1, "speedMult": 1.05, "damageMult": 1.05, "gold": 80, "boss": ""},
	{"n": 3, "name": "Steep Edge", "biome": "grasland", "length": 1300.0, "scroll": 26.0,
		"pool": [["imp", 8], ["wyvern", 6], ["ballista", 3]], "spawn": 1.25, "hpMult": 1.2, "speedMult": 1.1, "damageMult": 1.1, "gold": 110, "boss": ""},
	# --- Bergland -----------------------------------------------------------
	{"n": 4, "name": "Eagle’s Pass", "biome": "berge", "length": 1400.0, "scroll": 27.0,
		"pool": [["wyvern", 8], ["imp", 6], ["ballista", 4]], "spawn": 1.2, "hpMult": 1.35, "speedMult": 1.12, "damageMult": 1.2, "gold": 140, "boss": ""},
	{"n": 5, "name": "Rock Spur", "biome": "berge", "length": 1500.0, "scroll": 28.0,
		"pool": [["wyvern", 7], ["harpy", 7], ["ballista", 4]], "spawn": 1.15, "hpMult": 1.5, "speedMult": 1.15, "damageMult": 1.25, "gold": 170, "boss": ""},
	{"n": 6, "name": "Sea of Clouds", "biome": "berge", "length": 1600.0, "scroll": 29.0,
		"pool": [["wyvern", 6], ["harpy", 6], ["golem", 3], ["ballista", 3]], "spawn": 1.1, "hpMult": 1.6, "speedMult": 1.18, "damageMult": 1.3, "gold": 210, "boss": "sky_tyrant"},
	# --- Wüste --------------------------------------------------------------
	{"n": 7, "name": "Dune Ridge", "biome": "wueste", "length": 1700.0, "scroll": 30.0,
		"pool": [["harpy", 8], ["wyvern", 6], ["golem", 3]], "spawn": 1.05, "hpMult": 1.8, "speedMult": 1.2, "damageMult": 1.4, "gold": 250, "boss": ""},
	{"n": 8, "name": "Oasis Call", "biome": "wueste", "length": 1800.0, "scroll": 31.0,
		"pool": [["harpy", 7], ["storm_rider", 4], ["golem", 4], ["ballista", 3]], "spawn": 1.0, "hpMult": 2.0, "speedMult": 1.24, "damageMult": 1.5, "gold": 300, "boss": ""},
	{"n": 9, "name": "Sandstorm", "biome": "wueste", "length": 1900.0, "scroll": 32.0,
		"pool": [["harpy", 6], ["storm_rider", 5], ["wyvern", 6], ["golem", 3]], "spawn": 0.95, "hpMult": 2.2, "speedMult": 1.28, "damageMult": 1.6, "gold": 360, "boss": "sky_tyrant"},
	# --- Vulkan -------------------------------------------------------------
	{"n": 10, "name": "Ash Valley", "biome": "vulkan", "length": 2000.0, "scroll": 33.0,
		"pool": [["storm_rider", 6], ["wyvern", 6], ["golem", 4]], "spawn": 0.92, "hpMult": 2.5, "speedMult": 1.3, "damageMult": 1.7, "gold": 420, "boss": ""},
	{"n": 11, "name": "Lava Plain", "biome": "vulkan", "length": 2100.0, "scroll": 34.0,
		"pool": [["storm_rider", 6], ["bone_warden", 4], ["golem", 5], ["ballista", 3]], "spawn": 0.9, "hpMult": 2.8, "speedMult": 1.34, "damageMult": 1.8, "gold": 490, "boss": ""},
	{"n": 12, "name": "Ember Herd", "biome": "vulkan", "length": 2200.0, "scroll": 35.0,
		"pool": [["storm_rider", 5], ["bone_warden", 5], ["wyvern", 6], ["golem", 4]], "spawn": 0.86, "hpMult": 3.1, "speedMult": 1.38, "damageMult": 1.9, "gold": 580, "boss": "storm_sovereign"},
	# --- Eisfeld ------------------------------------------------------------
	{"n": 13, "name": "Frost Stream", "biome": "eis", "length": 2300.0, "scroll": 36.0,
		"pool": [["harpy", 7], ["bone_warden", 5], ["ballista", 5]], "spawn": 0.84, "hpMult": 3.4, "speedMult": 1.4, "damageMult": 2.0, "gold": 660, "boss": ""},
	{"n": 14, "name": "Fang", "biome": "eis", "length": 2400.0, "scroll": 37.0,
		"pool": [["bone_warden", 6], ["storm_rider", 6], ["harpy", 6], ["golem", 4]], "spawn": 0.82, "hpMult": 3.7, "speedMult": 1.44, "damageMult": 2.1, "gold": 750, "boss": ""},
	{"n": 15, "name": "Polar Storm", "biome": "eis", "length": 2500.0, "scroll": 38.0,
		"pool": [["bone_warden", 6], ["storm_rider", 6], ["wyvern", 6], ["golem", 5]], "spawn": 0.8, "hpMult": 4.0, "speedMult": 1.48, "damageMult": 2.2, "gold": 860, "boss": "sky_tyrant"},
	# --- Wirbelsturm --------------------------------------------------------
	{"n": 16, "name": "Vortex A", "biome": "sturm", "length": 2600.0, "scroll": 39.0,
		"pool": [["harpy", 8], ["storm_rider", 6], ["ballista", 5]], "spawn": 0.78, "hpMult": 4.4, "speedMult": 1.5, "damageMult": 2.3, "gold": 960, "boss": ""},
	{"n": 17, "name": "Vortex B", "biome": "sturm", "length": 2700.0, "scroll": 40.0,
		"pool": [["storm_rider", 7], ["bone_warden", 6], ["wyvern", 7], ["golem", 4]], "spawn": 0.76, "hpMult": 4.8, "speedMult": 1.54, "damageMult": 2.4, "gold": 1080, "boss": ""},
	{"n": 18, "name": "Storm Heart", "biome": "sturm", "length": 2800.0, "scroll": 41.0,
		"pool": [["bone_warden", 7], ["storm_rider", 7], ["harpy", 7], ["golem", 5]], "spawn": 0.74, "hpMult": 5.2, "speedMult": 1.58, "damageMult": 2.5, "gold": 1220, "boss": "storm_sovereign"},
	# --- Nachtflug ----------------------------------------------------------
	{"n": 19, "name": "Moonlight", "biome": "nacht", "length": 2900.0, "scroll": 42.0,
		"pool": [["wyvern", 8], ["bone_warden", 6], ["ballista", 6]], "spawn": 0.72, "hpMult": 5.6, "speedMult": 1.6, "damageMult": 2.6, "gold": 1360, "boss": ""},
	{"n": 20, "name": "Night Ride", "biome": "nacht", "length": 3000.0, "scroll": 43.0,
		"pool": [["wyvern", 7], ["bone_warden", 7], ["storm_rider", 7], ["golem", 5]], "spawn": 0.7, "hpMult": 6.0, "speedMult": 1.64, "damageMult": 2.7, "gold": 1520, "boss": ""},
	{"n": 21, "name": "Shadow Dragons", "biome": "nacht", "length": 3100.0, "scroll": 44.0,
		"pool": [["bone_warden", 8], ["storm_rider", 8], ["harpy", 6], ["golem", 6]], "spawn": 0.68, "hpMult": 6.5, "speedMult": 1.68, "damageMult": 2.8, "gold": 1700, "boss": "sky_tyrant"},
	# --- Sumpf --------------------------------------------------------------
	{"n": 22, "name": "Marsh Path", "biome": "sumpf", "length": 3200.0, "scroll": 45.0,
		"pool": [["imp", 8], ["harpy", 8], ["golem", 6], ["ballista", 5]], "spawn": 0.66, "hpMult": 7.0, "speedMult": 1.7, "damageMult": 2.9, "gold": 1900, "boss": ""},
	{"n": 23, "name": "Venom Mist", "biome": "sumpf", "length": 3300.0, "scroll": 46.0,
		"pool": [["wyvern", 7], ["bone_warden", 8], ["storm_rider", 7], ["golem", 6]], "spawn": 0.64, "hpMult": 7.6, "speedMult": 1.74, "damageMult": 3.0, "gold": 2120, "boss": ""},
	{"n": 24, "name": "Marsh Heart", "biome": "sumpf", "length": 3400.0, "scroll": 47.0,
		"pool": [["bone_warden", 8], ["storm_rider", 8], ["wyvern", 8], ["golem", 7]], "spawn": 0.62, "hpMult": 8.2, "speedMult": 1.78, "damageMult": 3.1, "gold": 2360, "boss": "storm_sovereign"},
	# --- Drachenschlucht -----------------------------------------------------
	{"n": 25, "name": "Gorge I", "biome": "schlucht", "length": 3500.0, "scroll": 48.0,
		"pool": [["wyvern", 8], ["bone_warden", 8], ["ballista", 7], ["golem", 6]], "spawn": 0.6, "hpMult": 8.8, "speedMult": 1.8, "damageMult": 3.2, "gold": 2600, "boss": ""},
	{"n": 26, "name": "Gorge II", "biome": "schlucht", "length": 3600.0, "scroll": 49.0,
		"pool": [["storm_rider", 9], ["bone_warden", 9], ["harpy", 8], ["golem", 7]], "spawn": 0.58, "hpMult": 9.4, "speedMult": 1.84, "damageMult": 3.3, "gold": 2880, "boss": "sky_tyrant"},
	{"n": 27, "name": "Crown Flight", "biome": "schlucht", "length": 3700.0, "scroll": 50.0,
		"pool": [["bone_warden", 10], ["storm_rider", 9], ["wyvern", 9], ["golem", 8]], "spawn": 0.56, "hpMult": 10.0, "speedMult": 1.88, "damageMult": 3.4, "gold": 3200, "boss": "storm_sovereign"},
	# --- Himmelsreich --------------------------------------------------------
	{"n": 28, "name": "Cloud Rim", "biome": "himmel", "length": 3800.0, "scroll": 51.0,
		"pool": [["storm_rider", 10], ["bone_warden", 10], ["harpy", 9], ["golem", 8]], "spawn": 0.54, "hpMult": 11.0, "speedMult": 1.9, "damageMult": 3.5, "gold": 3600, "boss": ""},
	{"n": 29, "name": "Starwind", "biome": "himmel", "length": 3900.0, "scroll": 52.0,
		"pool": [["bone_warden", 11], ["storm_rider", 10], ["wyvern", 10], ["golem", 9]], "spawn": 0.52, "hpMult": 12.0, "speedMult": 1.94, "damageMult": 3.6, "gold": 4000, "boss": "sky_tyrant"},
	{"n": 30, "name": "Primal Fire", "biome": "himmel", "length": 4200.0, "scroll": 54.0,
		"pool": [["bone_warden", 12], ["storm_rider", 11], ["wyvern", 11], ["golem", 9]], "spawn": 0.5, "hpMult": 13.0, "speedMult": 2.0, "damageMult": 3.8, "gold": 5000, "boss": "storm_sovereign"},
]


# --- lookups ----------------------------------------------------------------

static func breed_by_id(id: String) -> Dictionary:
	for breed in BREEDS:
		if str(breed["id"]) == id:
			return breed
	return BREEDS[0]


static func breed_index(id: String) -> int:
	for i in BREEDS.size():
		if str(BREEDS[i]["id"]) == id:
			return i
	return 0


static func trait_by_id(id: String) -> Dictionary:
	for gene in TRAITS:
		if str(gene["id"]) == id:
			return gene
	return {}


static func enemy_by_id(id: String) -> Dictionary:
	for enemy in ENEMIES:
		if str(enemy["id"]) == id:
			return enemy
	return ENEMIES[0]


static func powerup_by_id(id: String) -> Dictionary:
	for entry in POWERUPS:
		if str(entry["id"]) == id:
			return entry
	return {}


static func upgrade_by_id(id: String) -> Dictionary:
	for upgrade in UPGRADES:
		if str(upgrade["id"]) == id:
			return upgrade
	return {}


static func biome_by_id(id: String) -> Dictionary:
	for biome in BIOMES:
		if str(biome["id"]) == id:
			return biome
	return BIOMES[0]


## Level by its 1-based number. Out-of-range numbers clamp to the first/last
## level so a stale save can never crash the hangar.
static func level(n: int) -> Dictionary:
	var index: int = clampi(n - 1, 0, LEVELS.size() - 1)
	return LEVELS[index]


static func level_count() -> int:
	return LEVELS.size()


# --- genetics ---------------------------------------------------------------

## Fresh, random allele pair for one gene.
static func roll_alleles(gene: Dictionary) -> String:
	var dominant: bool = randf() < float(gene.get("weight", 0.2))
	if dominant:
		return str(gene["dom"]) + (str(gene["dom"]) if randf() < 0.5 else _recessive_letter(str(gene["dom"])))
	return _recessive_letter(str(gene["dom"])) + _recessive_letter(str(gene["dom"]))


static func _recessive_letter(dominant: String) -> String:
	return dominant.to_lower()


## A complete, random genome.
static func random_genome() -> Dictionary:
	var out: Dictionary = {}
	for gene in TRAITS:
		out[str(gene["id"])] = roll_alleles(gene)
	return out


## True when the two alleles actually show the gene.
static func expressed(alleles: Dictionary, trait_id: String) -> bool:
	var gene := trait_by_id(trait_id)
	if gene.is_empty():
		return false
	var pair := str(alleles.get(trait_id, ""))
	if pair.length() < 2:
		return false
	var dominant := str(gene["dom"])
	var recessive := _recessive_letter(dominant)
	if bool(gene.get("recessive", false)):
		return pair[0] == recessive and pair[1] == recessive
	return pair[0] == dominant or pair[1] == dominant


## Every gene the dragon actually shows, in registry order.
static func expressed_traits(alleles: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for gene in TRAITS:
		if expressed(alleles, str(gene["id"])):
			out.append(str(gene["id"]))
	return out


## How likely a parent passes each of its two alleles on. This is what makes a
## pedigree useful: the player can see *why* a pairing is worth the gold.
## Returns `{"passes_dominant": p, "passes_recessive": p}` (they add up to 1).
static func allele_pass_probabilities(alleles: Dictionary, trait_id: String) -> Dictionary:
	var gene := trait_by_id(trait_id)
	if gene.is_empty():
		return {"passes_dominant": 0.5, "passes_recessive": 0.5}
	var dominant := str(gene["dom"])
	var recessive := _recessive_letter(dominant)
	var pair := str(alleles.get(trait_id, ""))
	if pair.length() < 2:
		return {"passes_dominant": 0.5, "passes_recessive": 0.5}
	var dominant_count := 0
	for i in 2:
		if pair[i] == dominant:
			dominant_count += 1
	# Exactly one of the two alleles is drawn at random.
	return {
		"passes_dominant": float(dominant_count) * 0.5,
		"passes_recessive": float(2 - dominant_count) * 0.5,
	}


## Probability that a child of these two parents shows the trait, ignoring
## mutation. A dominant trait needs one dominant allele, a recessive one two
## recessive alleles — so the same two numbers mean opposite things.
static func trait_probability(parent_a: Dictionary, parent_b: Dictionary, trait_id: String) -> float:
	var gene := trait_by_id(trait_id)
	if gene.is_empty():
		return 0.0
	var from_a := allele_pass_probabilities(parent_a.get("alleles", {}), trait_id)
	var from_b := allele_pass_probabilities(parent_b.get("alleles", {}), trait_id)
	var recessive_chance: float = float(from_a["passes_recessive"]) * float(from_b["passes_recessive"])
	if bool(gene.get("recessive", false)):
		return recessive_chance
	return 1.0 - recessive_chance


## Every trait with its chance, most likely first — the "which pair do I want"
## list the hatchery shows instead of a blind roll.
static func breeding_forecast(parent_a: Dictionary, parent_b: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for gene in TRAITS:
		var id := str(gene["id"])
		out.append({
			"id": id,
			"name": str(gene["name"]),
			"hue": str(gene["hue"]),
			"chance": trait_probability(parent_a, parent_b, id),
			"a": expressed(parent_a.get("alleles", {}), id),
			"b": expressed(parent_b.get("alleles", {}), id),
		})
	out.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
		return float(x["chance"]) > float(y["chance"])
	)
	return out


## Uids of a dragon's parents, in breeding order.
static func parent_uids(dragon: Dictionary) -> Array:
	var out: Array = []
	for uid in dragon.get("parents", []):
		out.append(int(uid))
	return out


## Ancestors of `uid`, breadth first and without repeats. Roots have no parents,
## so a pedigree can never walk off the end.
static func ancestors(profile: Dictionary, uid: int, depth: int = 3) -> Array:
	var out: Array = []
	var seen := {uid: true}
	var queue: Array = parent_uids(dragon_by_uid(profile, uid))
	var levels: int = maxi(0, depth)
	while not queue.is_empty() and levels > 0:
		var next: Array = []
		for entry in queue:
			var parent_uid := int(entry)
			if seen.has(parent_uid):
				continue
			seen[parent_uid] = true
			var dragon := dragon_by_uid(profile, parent_uid)
			if dragon.is_empty():
				continue
			out.append(dragon)
			next.append_array(parent_uids(dragon))
		queue = next
		levels -= 1
	return out


## One allele from each parent, plus a small mutation chance. This is the whole
## breeding rule: a child can only show a recessive gene if both parents carry
## it, which is what makes pairing two carriers worth the gold.
static func cross_alleles(parent_a: Dictionary, parent_b: Dictionary, mutation_chance: float = 0.04) -> Dictionary:
	var out: Dictionary = {}
	for gene in TRAITS:
		var id := str(gene["id"])
		var dominant := str(gene["dom"])
		var recessive := _recessive_letter(dominant)
		var a := str(parent_a.get(id, ""))
		var b := str(parent_b.get(id, ""))
		var first: String = a[randi() % 2] if a.length() >= 2 else (dominant if randf() < 0.5 else recessive)
		var second: String = b[randi() % 2] if b.length() >= 2 else (dominant if randf() < 0.5 else recessive)
		if randf() < mutation_chance:
			first = _mutate(first, dominant, recessive)
		if randf() < mutation_chance:
			second = _mutate(second, dominant, recessive)
		out[id] = first + second
	return out


static func _mutate(allele: String, dominant: String, recessive: String) -> String:
	return recessive if allele == dominant else dominant


## Inbreeding penalty: a child of two blood relatives is smaller and weaker, so
## crossing distant lines stays the better play.
static func inbreeding_penalty(parent_a: Dictionary, parent_b: Dictionary) -> float:
	var shared := 0
	for gene in TRAITS:
		var id := str(gene["id"])
		if _shares_lineage(parent_a, parent_b, id):
			shared += 1
	return clampf(1.0 - float(shared) * 0.02, 0.7, 1.0)


## Two dragons are related when they carry the very same allele pair at a gene.
## Shared alleles are what `inbreeding_penalty` charges for and what `pairing_cost`
## prices, so a clone pays the full penalty while a cross of two unrelated
## bloodlines pays none.
static func _shares_lineage(a: Dictionary, b: Dictionary, trait_id: String) -> bool:
	# The pairs live in the dragon's "alleles" map; a bare genome is accepted
	# too, because that is what a genome comparison has at hand. Asking the
	# dragon for the gene itself found nothing on either side, so every pair of
	# dragons counted as unrelated and the penalty never fired at all.
	var left := allele_pair(a["alleles"] if a.has("alleles") else a, trait_id)
	var right := allele_pair(b["alleles"] if b.has("alleles") else b, trait_id)
	if left.length() < 2 or right.length() < 2:
		return false
	return left == right


# --- bloodline readout ------------------------------------------------------

## The three states one gene can be in for one dragon. `carrier` only ever
## happens for a recessive gene: the dragon hides the trait but can pass it on.
## That hidden letter is the whole point of the readout — a recessive trait
## needs two carriers, and before this the roster could not show whether a
## dragon was one.
const GENE_SHOWS := "shows"
const GENE_CARRIER := "carrier"
const GENE_CLEAR := "clear"

## A gene at or below this `weight` counts as rare: a random dragon is unlikely
## to carry it, so keeping the line alive is worth waiting for.
const RARE_TRAIT_WEIGHT := 0.2


## The two allele letters of one gene, dominant letter first. A missing or short
## pair reads as "not carried" instead of crashing an old save.
static func allele_pair(alleles: Dictionary, trait_id: String) -> String:
	var gene := trait_by_id(trait_id)
	if gene.is_empty():
		return ""
	var dominant := str(gene["dom"])
	var recessive := _recessive_letter(dominant)
	var pair := str(alleles.get(trait_id, ""))
	if pair.length() < 2:
		return ""
	# "rR" and "Rr" are the same dragon; the readout always sorts the letters.
	if pair[0] == recessive and pair[1] == dominant:
		return dominant + recessive
	return pair.substr(0, 2)


## How many of a gene's recessive letters a dragon carries: 0, 1 or 2. Two
## means the trait shows, one means the dragon is only a carrier.
static func recessive_allele_count(alleles: Dictionary, trait_id: String) -> int:
	var gene := trait_by_id(trait_id)
	if gene.is_empty():
		return 0
	var recessive := _recessive_letter(str(gene["dom"]))
	var count := 0
	for letter in allele_pair(alleles, trait_id):
		if letter == recessive:
			count += 1
	return count


## `shows`, `carrier` or `clear` — the state every screen draws a gene in.
static func gene_state(alleles: Dictionary, trait_id: String) -> String:
	var gene := trait_by_id(trait_id)
	if gene.is_empty():
		return GENE_CLEAR
	if expressed(alleles, trait_id):
		return GENE_SHOWS
	# A dominant gene is already visible with a single letter, so only a
	# recessive one has something to hide.
	if bool(gene.get("recessive", false)) and recessive_allele_count(alleles, trait_id) > 0:
		return GENE_CARRIER
	return GENE_CLEAR


## True when the dragon hides a recessive trait but can still pass it on.
static func is_carrier(alleles: Dictionary, trait_id: String) -> bool:
	return gene_state(alleles, trait_id) == GENE_CARRIER


## The whole genome as drawable rows, in registry order.
static func genotype(alleles: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for gene in TRAITS:
		var id := str(gene["id"])
		out.append({
			"id": id,
			"name": str(gene["name"]),
			"hue": str(gene["hue"]),
			"desc": str(gene["desc"]),
			"recessive": bool(gene.get("recessive", false)),
			"pair": allele_pair(alleles, id),
			"state": gene_state(alleles, id),
		})
	return out


## The recessive genes a dragon hides but still carries, rarest first. This is
## the "which line do I keep" list a hatchling never shows on its own.
static func carried_traits(alleles: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for row in genotype(alleles):
		if str(row["state"]) == GENE_CARRIER:
			out.append(str(row["id"]))
	out.sort_custom(func(a: String, b: String) -> bool:
		return float(trait_by_id(a).get("weight", 1.0)) < float(trait_by_id(b).get("weight", 1.0))
	)
	return out


## How many of the allele a breeding goal needs a dragon carries. A recessive
## goal needs the small letter, a dominant one the big one — so this single
## number ranks the whole roster for both kinds of goal.
static func goal_allele_count(alleles: Dictionary, trait_id: String) -> int:
	var gene := trait_by_id(trait_id)
	if gene.is_empty():
		return 0
	var dominant := str(gene["dom"])
	var wanted: String = _recessive_letter(dominant) if bool(gene.get("recessive", false)) else dominant
	var count := 0
	for letter in allele_pair(alleles, trait_id):
		if letter == wanted:
			count += 1
	return count


## Every dragon of the roster that could help with a breeding goal, best first:
## those that show the trait, then the carriers, then the rest. Dragons that
## carry nothing of the goal drop out as soon as somebody in the stable does —
## a list of clean dragons is not an answer, but when nobody carries it, the
## player gets to see exactly why the goal is out of reach.
static func target_candidates(profile: Dictionary, trait_id: String, limit: int = 6) -> Array[Dictionary]:
	var rows := _ranked(profile, trait_id)
	var best_score := 0
	for row in rows:
		best_score = maxi(best_score, int(row["score"]))
	if best_score > 0:
		var useful: Array[Dictionary] = []
		for row in rows:
			if int(row["score"]) > 0:
				useful.append(row)
		rows = useful
	if limit > 0 and rows.size() > limit:
		rows = rows.slice(0, limit)
	return rows


## The whole roster ranked by goal usefulness, without the filter above — this
## is what `best_pair()` searches, so a goal nobody carries still reports its
## honest 0 % instead of "no pair at all".
static func _ranked(profile: Dictionary, trait_id: String) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for entry in dragons_of(profile):
		var dragon: Dictionary = entry
		rows.append({
			"dragon": dragon,
			"uid": int(dragon.get("uid", 0)),
			"score": goal_allele_count(dragon.get("alleles", {}), trait_id),
		})
	rows.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
		if int(x["score"]) != int(y["score"]):
			return int(x["score"]) > int(y["score"])
		var gen_x := int((x["dragon"] as Dictionary).get("gen", 1))
		var gen_y := int((y["dragon"] as Dictionary).get("gen", 1))
		if gen_x != gen_y:
			return gen_x > gen_y
		return int(x["uid"]) < int(y["uid"])
	)
	return rows


## How many dragons of the roster carry a goal at all — showing it or hiding
## it. One is not enough for a recessive trait, so this is also the answer to
## "can I breed this at all yet".
static func goal_carriers(profile: Dictionary, trait_id: String) -> int:
	var count := 0
	for entry in dragons_of(profile):
		var state := gene_state((entry as Dictionary).get("alleles", {}), trait_id)
		if state == GENE_SHOWS or state == GENE_CARRIER:
			count += 1
	return count


## The best pairing the roster can manage for a goal. Every candidate is tried
## against every other — cheap for a stable of a few dozen dragons — so the
## player gets a concrete answer instead of a probability to guess at. Returns
## `{"a": dragon, "b": dragon, "chance": p}`, or `{}` below two dragons.
static func best_pair(profile: Dictionary, trait_id: String) -> Dictionary:
	var candidates := _ranked(profile, trait_id)
	var best := {"a": {}, "b": {}, "chance": -1.0}
	for i in candidates.size():
		for j in range(i + 1, candidates.size()):
			var a: Dictionary = (candidates[i]["dragon"] as Dictionary).duplicate(true)
			var b: Dictionary = (candidates[j]["dragon"] as Dictionary).duplicate(true)
			var chance := trait_probability(a, b, trait_id)
			if chance > float(best["chance"]):
				best = {"a": a, "b": b, "chance": chance}
	if (best["a"] as Dictionary).is_empty() or (best["b"] as Dictionary).is_empty():
		return {}
	return best


## What an egg is worth before it opens: the traits it will show, the recessive
## genes it only carries, and the rarest of both. The genome is already rolled
## when the egg is laid, so the incubator can tell the truth — which is what
## turns a hatched-by-surprise dragon into a line the player chose.
static func egg_readout(dragon: Dictionary) -> Dictionary:
	var alleles: Dictionary = dragon.get("alleles", {})
	var traits := expressed_traits(alleles)
	var carriers := carried_traits(alleles)
	var rarest := ""
	var rarest_weight := 2.0
	for id in traits + carriers:
		var weight := float(trait_by_id(id).get("weight", 1.0))
		if weight < rarest_weight:
			rarest_weight = weight
			rarest = id
	return {
		"traits": traits,
		"carriers": carriers,
		"rarest": rarest,
		"rare": not rarest.is_empty() and rarest_weight <= RARE_TRAIT_WEIGHT,
	}


## Breed two dragons. The child inherits a breed from one parent, a mixed genome
## and a generation counter. Returns a plain dragon Dictionary.
static func breed_parents(parent_a: Dictionary, parent_b: Dictionary, uid: int) -> Dictionary:
	var bloodline: float = inbreeding_penalty(parent_a, parent_b)
	var child_breed: String = str(parent_a["breed"]) if randf() < 0.5 else str(parent_b["breed"])
	var genome := cross_alleles(parent_a.get("alleles", {}), parent_b.get("alleles", {}))
	var generation: int = maxi(int(parent_a.get("gen", 1)), int(parent_b.get("gen", 1))) + 1
	return {
		"uid": uid,
		"breed": child_breed,
		"name": "",
		"alleles": genome,
		"gen": generation,
		"wins": 0,
		"runs": 0,
		"vitality": bloodline,
		"parents": [int(parent_a.get("uid", 0)), int(parent_b.get("uid", 0))],
		"egg": null,
		"hatched_at": 0,
	}


## A random dragon of a breed, for eggs picked up while flying.
static func random_dragon(uid: int, breed_ids: Array = []) -> Dictionary:
	var pool: Array[String] = []
	for id in breed_ids:
		pool.append(str(id))
	if pool.is_empty():
		for breed in BREEDS:
			pool.append(str(breed["id"]))
	return {
		"uid": uid,
		"breed": pool[randi() % pool.size()],
		"name": "",
		"alleles": random_genome(),
		"gen": 1,
		"wins": 0,
		"runs": 0,
		"vitality": 1.0,
		"parents": [],
		"egg": null,
		"hatched_at": 0,
	}


## Seconds an egg of this breed needs in the nest.
static func incubation_seconds(breed_id: String) -> float:
	var breed := breed_by_id(breed_id)
	return 45.0 + float(int(breed.get("tier", 1))) * 35.0


## Gold to buy a new dragon of this breed outright.
static func breed_price(breed_id: String) -> int:
	return int(breed_by_id(breed_id).get("price", 0))


## Gold to pair two dragons in the hatchery.
static func pairing_cost(parent_a: Dictionary, parent_b: Dictionary) -> int:
	var tier: int = maxi(int(breed_by_id(str(parent_a.get("breed", ""))).get("tier", 1)), int(breed_by_id(str(parent_b.get("breed", ""))).get("tier", 1)))
	var shared := 0
	for gene in TRAITS:
		if _shares_lineage(parent_a, parent_b, str(gene["id"])):
			shared += 1
	return int(180.0 + float(tier) * 120.0 + float(shared) * 25.0)


# --- stats ------------------------------------------------------------------

## The resolved numbers of one dragon: breed base, then traits, then upgrades,
## then the inbreeding vitality factor. This is the single source of truth — the
## flight screen never computes a stat itself.
static func resolve_stats(dragon: Dictionary, upgrades: Dictionary = {}) -> Dictionary:
	var breed := breed_by_id(str(dragon.get("breed", "ember")))
	var alleles: Dictionary = dragon.get("alleles", {})
	var traits := expressed_traits(alleles)

	var out := {
		"max_hp": float(breed["hp"]),
		"speed": float(breed["speed"]),
		"turn": float(breed["turn"]),
		"fire_rate": float(breed["fireRate"]),
		"damage": float(breed["damage"]),
		"shot_speed": float(breed["shotSpeed"]),
		"shot_size": float(breed["shotSize"]),
		"armor": float(breed["armor"]),
		"crit": float(breed["crit"]),
		"gold_mult": float(breed["goldMult"]),
		"pickup": float(breed["pickup"]),
		"size": float(breed["size"]),
		"wings": float(breed["wings"]),
		"poison": 0.0,
		"chain": 0.0,
		"element": str(breed.get("element", "fire")),
	}
	var vitality: float = clampf(float(dragon.get("vitality", 1.0)), 0.7, 1.0)

	for trait_id in traits:
		var gene := trait_by_id(trait_id)
		for key in gene.get("mods", {}):
			var value := float(gene["mods"][key])
			# Modifiers name the resolved stat directly. A positive `fire_rate`
			# modifier means "slower", because the value is a duration.
			match key:
				"poison", "chain":
					out[key] = float(out.get(key, 0.0)) + value
				_:
					out[key] = float(out.get(key, 0.0)) * (1.0 + value)

	for upgrade in UPGRADES:
		var level := int(upgrades.get(str(upgrade["id"]), 0))
		if level <= 0:
			continue
		var stat := str(upgrade["stat"])
		out[stat] = float(out.get(stat, 0.0)) * (1.0 + float(upgrade["per"]) * float(level))

	out["max_hp"] = float(out["max_hp"]) * vitality
	out["max_hp"] = maxf(1.0, out["max_hp"])
	out["fire_rate"] = maxf(0.08, float(out["fire_rate"]))
	out["speed"] = maxf(6.0, float(out["speed"]))
	out["turn"] = maxf(0.6, float(out["turn"]))
	out["armor"] = clampf(float(out["armor"]), 0.0, 0.72)
	out["crit"] = clampf(float(out["crit"]), 0.0, 0.85)
	out["pickup"] = maxf(1.0, float(out["pickup"]))
	out["size"] = maxf(0.5, float(out["size"]))
	out["traits"] = traits
	out["breed"] = breed
	return out


## Sum of a stat's additive modifiers — used by the hangar to show what a gene
## actually does without duplicating the modifier rules.
static func stat_delta(base: float, key: String, modifier: float) -> float:
	if key == "fire_rate":
		return maxf(0.08, base * (1.0 + modifier))
	return base * (1.0 + modifier)


## The mesh scale a dragon is drawn at: breed size, gene growth and generation.
static func visual_scale(dragon: Dictionary) -> float:
	var stats := resolve_stats(dragon)
	var gen_bonus: float = 1.0 + float(maxi(0, int(dragon.get("gen", 1)) - 1)) * 0.03
	return clampf(float(stats["size"]) * gen_bonus, 0.55, 2.4)


## Damage a shot deals, including crits and the level's damage multiplier.
static func roll_shot(stats: Dictionary, damage_mult: float) -> Dictionary:
	var crit: bool = randf() < float(stats["crit"])
	var raw: float = float(stats["damage"]) * (1.9 if crit else 1.0) * damage_mult
	return {"damage": maxf(1.0, raw), "crit": crit}


## Damage multiplier of a dragon's element against a target's resistances.
## Positive resistance soaks the element, negative resistance doubles it — this
## is what makes Feueratem against a Steindrache a bad idea.
static func element_multiplier(element: String, resist: Dictionary) -> float:
	var value := float(resist.get(element, 0.0))
	return clampf(1.0 - value, 0.25, 2.0)


## The elements a level's enemies are weak or strong against, for the briefing.
static func level_resist_summary(level_def: Dictionary) -> String:
	var totals: Dictionary = {}
	for entry in level_def.get("pool", []):
		var kind := enemy_by_id(str((entry as Array)[0]))
		for element in kind.get("resist", {}):
			var key := str(element)
			totals[key] = float(totals.get(key, 0.0)) + float(kind["resist"][element]) * float((entry as Array)[1])
	if totals.is_empty():
		return ""
	var parts: Array[String] = []
	for element in ["fire", "ice", "poison"]:
		if not totals.has(element):
			continue
		var value := float(totals[element])
		parts.append("%s %+.0f %%" % [element_name(str(element)), value * 100.0])
	return ", ".join(parts)


static func element_name(element: String) -> String:
	match element:
		"fire":
			return "Fire"
		"ice":
			return "Frost"
		"poison":
			return "Poison"
		"storm":
			return "Storm"
		"earth":
			return "Earth"
		"void":
			return "Void"
		"air":
			return "Air"
		"light":
			return "Light"
		_:
			return element.capitalize()


## Incoming damage after armor, never below one.
static func mitigate(raw: float, armor: float) -> float:
	var safe: float = clampf(armor, 0.0, 0.85)
	return maxf(1.0, raw * (1.0 - safe))


# --- level flow -------------------------------------------------------------

## True when the level may be started: level 1 always, every other level needs
## its predecessor cleared, and the last five also need the star gate.
static func is_unlocked(n: int, profile: Dictionary) -> bool:
	if n <= 1:
		return true
	if n > level_count():
		return false
	if stars_of(n - 1, profile) <= 0:
		return false
	return total_stars(profile) >= star_requirement(n)


## Stars the player must have collected in total to open level `n`.
static func star_requirement(n: int) -> int:
	if n <= 5:
		return 0
	if n <= 12:
		return 6
	if n <= 20:
		return 16
	if n <= 27:
		return 30
	return 46


static func stars_of(n: int, profile: Dictionary) -> int:
	var entry: Dictionary = profile.get("levels", {}).get(str(n), {})
	return int(entry.get("stars", 0))


static func best_of(n: int, profile: Dictionary) -> int:
	var entry: Dictionary = profile.get("levels", {}).get(str(n), {})
	return int(entry.get("best", 0))


static func total_stars(profile: Dictionary) -> int:
	var levels: Dictionary = profile.get("levels", {})
	var total := 0
	for key in levels:
		total += int((levels[key] as Dictionary).get("stars", 0))
	return total


static func cleared_count(profile: Dictionary) -> int:
	var levels: Dictionary = profile.get("levels", {})
	var count := 0
	for key in levels:
		if int((levels[key] as Dictionary).get("stars", 0)) > 0:
			count += 1
	return count


## 1 star for finishing, 2 for half the hull, 3 for nearly untouched.
static func stars_for_run(finished: bool, hp_ratio: float) -> int:
	if not finished:
		return 0
	if hp_ratio >= 0.8:
		return 3
	if hp_ratio >= 0.45:
		return 2
	return 1


static func score_for(distance: float, kills: int, gold: int, combo: int) -> int:
	return roundi(distance * 1.4 + float(kills) * 55.0 + float(gold) * 4.0 + float(combo) * 25.0)


## How many enemies a level keeps alive at once.
static func concurrent_for(n: int) -> int:
	return clampi(4 + n / 2, 4, 22)


## World-unit gap between spawns; the level's own interval times its scroll speed.
static func spawn_gap(level_def: Dictionary) -> float:
	return maxf(9.0, float(level_def["scroll"]) * float(level_def["spawn"]) * 0.42)


## Weighted pick from a level's `[["id", weight], …]` pool.
static func pick_enemy(level_def: Dictionary) -> Dictionary:
	var pool: Array = level_def.get("pool", [])
	if pool.is_empty():
		return ENEMIES[0]
	var total := 0.0
	for entry in pool:
		total += float((entry as Array)[1])
	var roll := randf() * total
	for entry in pool:
		roll -= float((entry as Array)[1])
		if roll <= 0.0:
			return enemy_by_id(str((entry as Array)[0]))
	return enemy_by_id(str((pool[0] as Array)[0]))


## Weighted random power-up drop.
static func roll_powerup() -> Dictionary:
	var total := 0.0
	for entry in POWERUPS:
		total += float(entry["weight"])
	var roll := randf() * total
	for entry in POWERUPS:
		roll -= float(entry["weight"])
		if roll <= 0.0:
			return entry
	return POWERUPS[0]


# --- upgrades ---------------------------------------------------------------

static func upgrade_level(id: String, profile: Dictionary) -> int:
	return int(profile.get("upgrades", {}).get(id, 0))


## Gold needed for the next level of an upgrade, or -1 when it is maxed.
static func upgrade_cost(id: String, profile: Dictionary) -> int:
	var upgrade := upgrade_by_id(id)
	if upgrade.is_empty():
		return -1
	var level := upgrade_level(id, profile)
	if level >= int(upgrade["max"]):
		return -1
	return roundi(float(upgrade["base"]) * pow(float(upgrade["growth"]), float(level)))


## Buys one upgrade step. Returns the new level, or -1 when it cannot be paid.
static func buy_upgrade(id: String, profile: Dictionary) -> int:
	var cost := upgrade_cost(id, profile)
	if cost < 0 or int(profile.get("gold", 0)) < cost:
		return -1
	profile["gold"] = int(profile["gold"]) - cost
	var upgrades: Dictionary = profile.get("upgrades", {})
	upgrades[id] = upgrade_level(id, profile) + 1
	profile["upgrades"] = upgrades
	return int(upgrades[id])


# --- profile ----------------------------------------------------------------

static func default_profile() -> Dictionary:
	return {
		"gold": 0,
		"eggs": 2,
		"next_uid": 1,
		"dragons": [],
		"nests": [],
		"active": 0,
		"upgrades": {},
		"levels": {},
		# Derived from the owned dragons by `unlocked_breeds()`; a fresh profile
		# owns none, so the starter dragon can still be bought for free.
		"breeds": [],
		"hatched": 0,
		"eggs_found": 0,
		"last_collect": 0,
	}


## A fresh profile that already owns a breeding pair, so the hatchery is usable
## from the first minute: breeding needs a pair, and the whole game hangs on it.
static func starter_profile() -> Dictionary:
	var profile := default_profile()
	var starter := random_dragon(1, ["ember"])
	var second := random_dragon(2, ["frost"])
	profile["dragons"] = [starter, second]
	profile["next_uid"] = 3
	profile["active"] = starter["uid"]
	profile["breeds"] = unlocked_breeds(profile)
	return profile


static func dragons_of(profile: Dictionary) -> Array:
	var out: Array = []
	for entry in profile.get("dragons", []):
		if not (entry as Dictionary).get("egg", null):
			out.append(entry)
	return out


static func eggs_of(profile: Dictionary) -> Array:
	var out: Array = []
	for entry in profile.get("dragons", []):
		if (entry as Dictionary).get("egg", null) != null:
			out.append(entry)
	return out


static func dragon_by_uid(profile: Dictionary, uid: int) -> Dictionary:
	for entry in profile.get("dragons", []):
		if int((entry as Dictionary).get("uid", 0)) == uid:
			return entry
	return {}


static func active_dragon(profile: Dictionary) -> Dictionary:
	var found := dragon_by_uid(profile, int(profile.get("active", 0)))
	if not found.is_empty():
		return found
	var owned := dragons_of(profile)
	return owned[0] if not owned.is_empty() else {}


## Gold a breed costs right now, or -1 when it is already owned.
static func breed_price_for(profile: Dictionary, breed_id: String) -> int:
	if has_breed(profile, breed_id):
		return -1
	return breed_price(breed_id)


## Eggs a laid egg costs. The first one is free, so a new player can start
## breeding without flying first.
static func egg_cost(profile: Dictionary) -> int:
	var laid := 0
	for entry in profile.get("dragons", []):
		if (entry as Dictionary).get("egg", null) != null:
			laid += 1
	return 1 + laid


## Buys a breed outright. Returns the new dragon, or an empty Dictionary when the
## player cannot afford it or already owns it.
static func buy_breed(profile: Dictionary, breed_id: String) -> Dictionary:
	if has_breed(profile, breed_id):
		return {}
	var price := breed_price(breed_id)
	if int(profile.get("gold", 0)) < price:
		return {}
	profile["gold"] = int(profile["gold"]) - price
	var dragon := random_dragon(next_uid(profile), [breed_id])
	var dragons: Array = profile.get("dragons", [])
	dragons.append(dragon)
	profile["dragons"] = dragons
	profile["breeds"] = unlocked_breeds(profile)
	return dragon


## True when the player owns at least one dragon of this breed. Derived from the
## roster, so a stale cache in the save can never offer an owned breed again.
static func has_breed(profile: Dictionary, breed_id: String) -> bool:
	for entry in profile.get("dragons", []):
		if str((entry as Dictionary).get("breed", "")) == breed_id:
			return true
	return false


## Every breed the player owns at least one dragon of.
static func unlocked_breeds(profile: Dictionary) -> Array:
	var out: Array = []
	for entry in profile.get("dragons", []):
		var breed := str((entry as Dictionary).get("breed", ""))
		if not breed.is_empty() and not (breed in out):
			out.append(breed)
	if out.is_empty():
		out.append("ember")
	return out


static func next_uid(profile: Dictionary) -> int:
	var uid := int(profile.get("next_uid", 1))
	profile["next_uid"] = uid + 1
	return uid


## Puts an egg into a nest. `breed_id` empty means a random owned breed, and
## `seconds` <= 0 uses the breed's own incubation time.
static func lay_egg(profile: Dictionary, breed_id: String, seconds: float = 0.0) -> Dictionary:
	var uid := next_uid(profile)
	var dragon: Dictionary
	if breed_id.is_empty():
		dragon = random_dragon(uid, unlocked_breeds(profile))
	else:
		dragon = random_dragon(uid, [breed_id])
	var total: float = seconds if seconds > 0.0 else incubation_seconds(str(dragon["breed"]))
	total = maxf(5.0, total)
	dragon["egg"] = {"ready_at": Time.get_unix_time_from_system() + total, "total": total}
	var dragons: Array = profile.get("dragons", [])
	dragons.append(dragon)
	profile["dragons"] = dragons
	return dragon


## Seconds left on an egg, 0 when it is ready.
static func egg_remaining(dragon: Dictionary, now: float = -1.0) -> float:
	var egg: Dictionary = dragon.get("egg", {})
	if egg.is_empty():
		return 0.0
	var stamp: float = float(now if now >= 0.0 else Time.get_unix_time_from_system())
	return maxf(0.0, float(egg.get("ready_at", 0.0)) - stamp)


## 0..1 incubation progress.
static func egg_progress(dragon: Dictionary, now: float = -1.0) -> float:
	var egg: Dictionary = dragon.get("egg", {})
	if egg.is_empty():
		return 1.0
	var total: float = maxf(1.0, float(egg.get("total", 1.0)))
	return clampf(1.0 - egg_remaining(dragon, now) / total, 0.0, 1.0)


## Gold to skip the remaining incubation.
static func hatch_cost(dragon: Dictionary) -> int:
	return maxi(1, roundi(egg_remaining(dragon) * 3.0))


## Turns a ready egg into a dragon. Returns the hatched dragon or an empty one.
static func hatch(dragon: Dictionary, force: bool = false) -> Dictionary:
	if dragon.is_empty() or dragon.get("egg", null) == null:
		return {}
	if not force and egg_remaining(dragon) > 0.0:
		return {}
	var hatched := dragon.duplicate(true)
	hatched["egg"] = null
	hatched["hatched_at"] = int(Time.get_unix_time_from_system())
	return hatched


## Removes hatched dragons from the profile and returns them.
static func collect_hatched(profile: Dictionary) -> Array:
	var kept: Array = []
	var fresh: Array = []
	for entry in profile.get("dragons", []):
		var dragon: Dictionary = entry
		if dragon.get("egg", null) != null:
			kept.append(dragon)
			continue
		if int(dragon.get("hatched_at", 0)) > 0 and int(profile.get("last_collect", 0)) < int(dragon["hatched_at"]):
			fresh.append(dragon)
			continue
		kept.append(dragon)
	profile["dragons"] = kept
	profile["hatched"] = int(profile.get("hatched", 0)) + fresh.size()
	if not fresh.is_empty():
		profile["last_collect"] = int(Time.get_unix_time_from_system())
	return fresh


## Applies the result of a finished run: score, stars, gold and any egg drops.
static func apply_run(profile: Dictionary, level_n: int, result: Dictionary) -> Dictionary:
	var entry: Dictionary = profile.get("levels", {}).get(str(level_n), {})
	var stars: int = maxi(int(entry.get("stars", 0)), int(result.get("stars", 0)))
	var best: int = maxi(int(entry.get("best", 0)), int(result.get("score", 0)))
	var levels: Dictionary = profile.get("levels", {})
	levels[str(level_n)] = {"stars": stars, "best": best}
	profile["levels"] = levels

	var gold: int = int(profile.get("gold", 0)) + int(result.get("gold", 0))
	profile["gold"] = gold
	var eggs: int = int(profile.get("eggs", 0)) + int(result.get("eggs", 0))
	profile["eggs"] = eggs
	profile["eggs_found"] = int(profile.get("eggs_found", 0)) + int(result.get("eggs", 0))

	if int(result.get("new_best", 0)) > 0:
		var uid := int(profile.get("active", 0))
		var dragon := dragon_by_uid(profile, uid)
		if not dragon.is_empty():
			dragon["wins"] = int(dragon.get("wins", 0)) + 1
	profile["breeds"] = unlocked_breeds(profile)
	return {"stars": stars, "best": best, "gold": gold, "unlocked": next_unlocked(level_n, profile)}


## The highest level number the player may enter now.
static func next_unlocked(from_n: int, profile: Dictionary) -> int:
	for n in range(maxi(1, from_n), level_count() + 1):
		if is_unlocked(n, profile):
			return n
	return from_n


static func load_profile() -> Dictionary:
	if not FileAccess.file_exists(save_path):
		var fresh := starter_profile()
		save_profile(fresh)
		return fresh
	var text := FileAccess.get_file_as_string(save_path)
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		# A corrupt save must not leave the hatchery empty on every launch: fall
		# back to a playable profile and write it over the broken file, so the
		# player recovers instead of re-reading the same garbage each time.
		var recovered := starter_profile()
		save_profile(recovered)
		return recovered
	return _merge_defaults(parsed as Dictionary)


## Fills in keys an older or partial save does not have, so a new field never
## breaks an existing profile. Keys the save has but the defaults do not are
## carried over untouched — a field that only lives in the save (like
## `last_collect`, written by `collect_hatched`) would otherwise be dropped on
## every load and make the hatchery re-report every dragon as newly hatched.
static func _merge_defaults(saved: Dictionary) -> Dictionary:
	var profile := default_profile()
	for key in profile:
		if saved.has(key):
			profile[key] = saved[key]
	for key in saved:
		if not profile.has(key):
			profile[key] = saved[key]
	return profile


static func save_profile(profile: Dictionary) -> bool:
	var file := FileAccess.open(save_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(profile, "  "))
	file.close()
	return true


static func reset_profile() -> void:
	if FileAccess.file_exists(save_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path))
