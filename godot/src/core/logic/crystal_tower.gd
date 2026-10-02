class_name CrystalTower
extends RefCounted
## Logic for the "Crystal Jumper 3D" tower climb and its themed editions.

const MAX_CRYSTAL_TIER := 5
const MAX_LEVEL := 6

## How long a "Flusskette" (flow chain) survives without a new pickup, in ms.
const FLOW_WINDOW_MS := 3000.0
## Upper bound of the chain: past it the count stops, the bonus keeps paying.
const MAX_FLOW := 10
## Names for the chain, so the counter becomes a goal instead of a number.
const FLOW_TITLES := [
	"", "Train", "Doppel", "Fluss", "Strom", "Kaskade", "Wirbel", "Sturm", "Furie", "Orkan", "Singular",
]

const THEME_CLASSIC := "classic"
const THEME_CHRISTMAS := "christmas"
const THEME_HALLOWEEN := "halloween"

const CRYSTAL_TIERS := [
	{"tier": 1, "name": "Shard", "color": Color("93c5fd"), "asset": "crystal1"},
	{"tier": 2, "name": "Crystal", "color": Color("22d3ee"), "asset": "crystal2"},
	{"tier": 3, "name": "Jewel", "color": Color("34d399"), "asset": "crystal3"},
	{"tier": 4, "name": "Prism", "color": Color("fbbf24"), "asset": "crystal4"},
	{"tier": 5, "name": "Starcore", "color": Color("f472b6"), "asset": "crystal5"},
]

const THEMES := {
	THEME_CLASSIC: {
		"id": THEME_CLASSIC,
		"title": "Crystal Jumper 3D",
		"icon": "◆",
		"tierNames": ["Splitter", "Kristall", "Juwel", "Prisma", "Sternenkern"],
		"tierColors": [Color("93c5fd"), Color("22d3ee"), Color("34d399"), Color("fbbf24"), Color("f472b6")],
		"tierAssets": ["crystal1", "crystal2", "crystal3", "crystal4", "crystal5"],
		"background": Color("05070d"),
		"ground": Color("0b1220"),
		"platform": Color("1e293b"),
		"summit": Color("6d28d9"),
		"summitGlow": Color("4c1d95"),
		"column": Color("111a2e"),
		"grid": [Color("1e293b"), Color("172033")],
		"sky": Color("8fc7ff"),
		"atmosphere": Color("0a1024"),
		"accent": Color("f472b6"),
		"ship": Color("facc15"),
		"particle": Color("8fc7ff"),
		"particleFall": false,
		"keyPrefix": "singular80_crystal3d",
		"hint": "Move the stick · jump button · reach the summit!",
	},
	THEME_CHRISTMAS: {
		"id": THEME_CHRISTMAS,
		"title": "Crystal Jumper — Christmas",
		"icon": "✧",
		"tierNames": ["Tannenzapfen", "Zuckerstange", "Glaskugel", "Lebkuchenstern", "Christstern"],
		"tierColors": [Color("b45309"), Color("ef4444"), Color("7dd3fc"), Color("d97706"), Color("facc15")],
		"tierAssets": ["xmas_pinecone", "xmas_candy_cane", "xmas_bauble", "xmas_gingerbread_star", "xmas_star"],
		"background": Color("0a1220"),
		"ground": Color("e2e8f0"),
		"platform": Color("334155"),
		"summit": Color("0ea5e9"),
		"summitGlow": Color("0369a1"),
		"column": Color("1e293b"),
		"grid": [Color("94a3b8"), Color("cbd5e1")],
		"sky": Color("bfdbfe"),
		"atmosphere": Color("1e293b"),
		"accent": Color("22c55e"),
		"ship": Color("ef4444"),
		"particle": Color("ffffff"),
		"particleFall": true,
		"keyPrefix": "singular80_crystal3d_christmas",
		"hint": "Happy climbing! Collect Christmas decorations and reach the summit.",
	},
	THEME_HALLOWEEN: {
		"id": THEME_HALLOWEEN,
		"title": "Crystal Jumper — Halloween",
		"icon": "☠",
		"tierNames": ["Pumpkin seed", "Candy", "Mini pumpkin", "Pumpkin", "Ghost pumpkin"],
		"tierColors": [Color("fef3c7"), Color("f472b6"), Color("fb923c"), Color("ea580c"), Color("a7f3d0")],
		"tierAssets": ["halloween_seed", "halloween_candy", "halloween_mini_pumpkin", "halloween_pumpkin", "halloween_ghost_pumpkin"],
		"background": Color("0b0616"),
		"ground": Color("1e1035"),
		"platform": Color("2e1065"),
		"summit": Color("f97316"),
		"summitGlow": Color("7c2d12"),
		"column": Color("24103f"),
		"grid": [Color("2e1065"), Color("3b0764")],
		"sky": Color("7c3aed"),
		"atmosphere": Color("160a2e"),
		"accent": Color("f97316"),
		"ship": Color("a855f7"),
		"particle": Color("fb923c"),
		"particleFall": false,
		"keyPrefix": "singular80_crystal3d_halloween",
		"hint": "Collect pumpkins at night and climb to the ghost summit.",
	},
}


static func theme_by_id(id: String) -> Dictionary:
	if id == THEME_CHRISTMAS:
		return THEMES[THEME_CHRISTMAS]
	if id == THEME_HALLOWEEN:
		return THEMES[THEME_HALLOWEEN]
	return THEMES[THEME_CLASSIC]


static func tier_asset(tier: int) -> String:
	return str((CRYSTAL_TIERS[clampi(tier, 1, MAX_CRYSTAL_TIER) - 1] as Dictionary)["asset"])


static func tier_info(tier: int) -> Dictionary:
	return CRYSTAL_TIERS[clampi(tier, 1, MAX_CRYSTAL_TIER) - 1]


static func crystal_tier_name(theme: Dictionary, tier: int) -> String:
	if tier <= 0:
		return "—"
	return str((theme["tierNames"] as Array)[clampi(tier, 1, MAX_CRYSTAL_TIER) - 1])


static func crystal_tier_color(theme: Dictionary, tier: int) -> Color:
	if tier <= 0:
		return Color("64748b")
	return (theme["tierColors"] as Array)[clampi(tier, 1, MAX_CRYSTAL_TIER) - 1]


## Score value of one crystal of the given tier. The ladder is `Merge3D`'s:
## three of a kind per tier, so both games price a tier the same way and only
## one of them has to be right.
static func tier_value(tier: int) -> int:
	if tier <= 0:
		return 0
	return Merge3D.TIER_VALUES[clampi(tier, 1, Merge3D.TIER_VALUES.size()) - 1]


## Tier a crystal found on the given floor (0 = base) gets. Higher = rarer.
static func tier_for_floor(floor: int, floors: int) -> int:
	if floors <= 1:
		return 1
	var ratio: float = clampf(float(floor) / float(floors - 1), 0.0, 1.0)
	return clampi(1 + int(round(ratio * float(MAX_CRYSTAL_TIER - 1))), 1, MAX_CRYSTAL_TIER)


## Plans the full merge cascade: three crystals of a tier become one of the next
## tier, repeatedly, from the lowest tier up. `steps` lists the individual merges
## so the scene can animate them one by one.
static func plan_merges(counts: Array) -> Dictionary:
	var result: Array = []
	for n in counts:
		result.append(maxi(0, int(n)))
	while result.size() < MAX_CRYSTAL_TIER:
		result.append(0)
	result.resize(MAX_CRYSTAL_TIER)
	var steps: Array = []
	for tier in MAX_CRYSTAL_TIER - 1:
		while int(result[tier]) >= 3:
			result[tier] = int(result[tier]) - 3
			result[tier + 1] = int(result[tier + 1]) + 1
			steps.append({"from": tier + 1, "to": tier + 2})
	return {"counts": result, "steps": steps, "merges": steps.size()}


static func merge_crystals(counts: Array) -> Dictionary:
	var plan := plan_merges(counts)
	return {"counts": plan["counts"], "merges": plan["merges"]}


## Total score value of an inventory (counts per tier, index 0 = tier 1).
static func inventory_value(counts: Array) -> int:
	var value := 0
	for i in mini(counts.size(), CRYSTAL_TIERS.size()):
		value += maxi(0, int(counts[i])) * tier_value(i + 1)
	return value


# --- Flusskette (flow chain) -----------------------------------------------
##
## Pickups in quick succession build a chain, and every crystal of the chain is
## worth its own value again per step. Climb without hesitating and the score
## runs away; stand still and the chain is gone. The window is the only rule,
## which is what makes it readable while the tower scrolls past.

## Chain length after a pickup at `elapsed_ms`. A `last_ms` below zero means "no
## pickup yet"; an elapsed window starts a fresh chain at 1. `window_ms` is the
## level's chain window — the default keeps the plain three seconds, and a level
## that shortens it says so instead of silently ignoring the argument.
static func next_flow(elapsed_ms: float, last_ms: float, chain: int, window_ms: float = FLOW_WINDOW_MS) -> int:
	if chain > 0 and last_ms >= 0.0 and elapsed_ms - last_ms <= window_ms:
		return mini(chain + 1, MAX_FLOW)
	return 1


## Remaining lifetime of the chain in ms (0 = expired). A chain of one has no bar:
## a single pickup is not a flow yet, so the HUD stays quiet until the second one.
static func flow_left_ms(elapsed_ms: float, last_ms: float, chain: int, window_ms: float = FLOW_WINDOW_MS) -> float:
	if chain < 2:
		return 0.0
	return clampf(window_ms - (elapsed_ms - last_ms), 0.0, window_ms)


## Fill level of the chain bar, 0..1.
static func flow_ratio(elapsed_ms: float, last_ms: float, chain: int, window_ms: float = FLOW_WINDOW_MS) -> float:
	return flow_left_ms(elapsed_ms, last_ms, chain, window_ms) / window_ms


## Score multiplier the chain currently pays.
static func flow_multiplier(chain: int) -> int:
	return clampi(chain, 1, MAX_FLOW)


## Extra points a single pickup of `tier` is worth inside `chain`.
static func flow_step_bonus(chain: int, tier: int) -> int:
	return (flow_multiplier(chain) - 1) * tier_value(tier)


## Points of a finished run: inventory plus what the chains paid out.
static func run_score(counts: Array, flow_bonus: int) -> int:
	return inventory_value(counts) + maxi(0, flow_bonus)


## Name of the chain, empty below a chain of 2 — one pickup is not a flow.
static func flow_title(chain: int) -> String:
	if chain < 2:
		return ""
	return str(FLOW_TITLES[clampi(chain, 0, FLOW_TITLES.size() - 1)])


## HUD text of the chain, e.g. "×4 Wirbel". Empty while no chain runs.
static func format_flow(chain: int) -> String:
	if chain < 2:
		return ""
	return Loc.f("×%d %s", [flow_multiplier(chain), flow_title(chain)])


## Stat boost granted by equipping a crystal of the given tier.
static func equip_bonus(tier: int) -> Dictionary:
	var t: int = clampi(tier, 1, MAX_CRYSTAL_TIER)
	return {
		"speedMult": 1.0 + float(t) * 0.05,
		"jumpMult": 1.0 + float(t) * 0.04,
		"pickupRadius": 1.9 + float(t) * 0.3,
		"extraJumps": int(floor(float(t - 1) / 2.0)),
	}


# --- level select ------------------------------------------------------------
##
## The six towers as the entry screen shows them, and the names they are shown
## under. A level select has to answer two questions before the climb starts —
## what does this tower look like, and have I beaten it — and both answers are
## numbers this module already keeps. So the rows live here, next to the table
## they are built from, and the screen only draws them.
##
## Free choice, deliberately: every level of every theme can be started at any
## time. `unlocked` stays the progress marker (it is what the goal time moves),
## not a gate in front of the card — a player who asks for a level select and is
## then offered one card is served a locked door, not a choice.

## One row of the level select. `level_config` is the single source; this is the
## same table under the names the cards read, so a tower can never be drawn one
## way and built another.
static func level_card(level: int) -> Dictionary:
	var l: int = clampi(level, 1, MAX_LEVEL)
	var config := level_config(l)
	var rules: Array = level_rules(l)
	var labels: Array[String] = rule_names(l)
	return {
		"level": l,
		"shape": str(config["shape"]),
		"shapeName": shape_name(str(config["shape"])),
		"rules": rules,
		"ruleNames": labels,
		"caption": level_caption(l),
		"floors": int(config["floors"]),
		"crystals": crystals_in_level(l),
		"targetMs": float(config["targetMs"]),
	}


## How many crystals a whole climb of this level can yield — every floor's share
## plus the one on the summit. The count is what the card promises, so it is
## computed from the same two numbers `_build_tower` uses and not estimated.
static func crystals_in_level(level: int) -> int:
	var config := level_config(level)
	var floors: int = int(config["floors"])
	return floors * int(config["crystalsPerFloor"]) + 1


## The caption naming a level's shape and its rules, e.g.
## "Level 3 · Zigzag · Sliding platforms".
##
## Written as one sentence per part rather than as one template, so that every
## part can be a catalogue key: a shape and a rule are words a translator
## reorders, and a template with the number already baked into it is one they
## cannot.
static func level_caption(level: int) -> String:
	var l: int = clampi(level, 1, MAX_LEVEL)
	var parts: Array[String] = [Loc.t("crystal.level", {"level": str(l)}), shape_name(level_shape(l))]
	for label in rule_names(l):
		parts.append(label)
	return " · ".join(parts)


## The name of a silhouette. Every key is a literal at its own call site because
## that is where the catalogue finds them: `"crystal.shape.%s"` is a key the
## extractor never sees, and a key with no call site reads as one the game no
## longer needs.
static func shape_name(shape_id: String) -> String:
	match shape_id:
		"spire":
			return Loc.t("crystal.shape.spire")
		"coil":
			return Loc.t("crystal.shape.coil")
		_:
			return Loc.t("crystal.shape.zigzag")


## The name of a rule, for the same reason as `shape_name`.
static func rule_name(rule: String) -> String:
	match rule:
		"drift":
			return Loc.t("crystal.rule.drift")
		"slide":
			return Loc.t("crystal.rule.slide")
		_:
			return Loc.t("crystal.rule.tight_flow")


## The rule names of a level, in the order `LEVELS` lists them.
static func rule_names(level: int) -> Array[String]:
	var out: Array[String] = []
	for rule in level_rules(level):
		out.append(rule_name(str(rule)))
	return out


# --- tower tuning ------------------------------------------------------------
## The numbers the ship obeys. They live in this module and not in the screen so
## that a level can be *proved* playable: `jump_reach` walks the same integration
## the screen walks, and every level below is written to stay under it.

## Gravity, and the jump it produces. `crystal_jumper_screen.gd` reads all three
## from here, so the numbers a test proves and the numbers a player feels cannot
## drift apart.
const GRAVITY := 42.0
const JUMP_SPEED := 18.5
const BASE_SPEED := 12.0
## How much of the ship's own footprint a landing still tolerates.
const PLAYER_RADIUS := 0.7
## Vertical distance between two floors.
##
## Constant on purpose. It is the one number of a tower the player cannot argue
## with: raise it with the level and the upper levels stop being harder, they
## stop being *finishable* — and nothing in a run says so, because the ship just
## never comes down on the next floor. The level ramp lives in the floors, in
## their width and in the rules below.
const FLOOR_HEIGHT := 3.4
## Half the width of a floor on level 1; every level takes a step off it.
const BASE_PLATFORM_HALF := 2.4
const PLATFORM_HALF_STEP := 0.1
const PLATFORM_THICKNESS := 0.6
## The screen clamps one frame to this, and `jump_reach` assumes no longer.
const MAX_STEP := 0.05

## Three silhouettes. A shape is what the player *sees*: a tower that winds
## slowly and close in does not feel like one that winds fast and wide, and
## `zigzag` — every other floor thrown out over the void — does not feel like
## either. A level names its shape so the difference is more than a number.
const SHAPES := {
	# A chimney. The tower barely turns, so the climb is almost straight up.
	"spire": {"step": 0.55, "radius": 4.9, "sway": 0.3},
	# A coil. Wide and fast: the player runs around the column between floors.
	"coil": {"step": 1.05, "radius": 6.4, "sway": 0.5},
	# A switchback. Half the floors stand far out, so the climb crosses a gap
	# again and again instead of circling the column once.
	"zigzag": {"step": 0.8, "radius": 5.4, "sway": 1.7},
}

## The rules a level runs under — what the player *feels*. A level that lists no
## rule here has the plain climb of level 1, which is why level 1 lists none.
const RULES := {
	# Crystals above the base circle their floor instead of standing on it.
	"drift": {"orbit": 1.2},
	# Every other floor of the middle of the tower slides sideways.
	"slide": {"travel": 1.8},
	# The river chain dies earlier, so the climb has to be without a pause.
	"tight_flow": {"windowMs": 1500.0},
}

## One line per level: a shape and the rules under it. Six levels, three
## shapes, and no two levels with the same pair — "the levels all feel the same"
## was a true complaint, and this table is the answer to it.
const LEVELS := [
	{"shape": "spire", "rules": []},
	{"shape": "coil", "rules": ["drift"]},
	{"shape": "zigzag", "rules": ["slide"]},
	{"shape": "spire", "rules": ["drift", "slide"]},
	{"shape": "coil", "rules": ["slide", "tight_flow"]},
	{"shape": "zigzag", "rules": ["drift", "slide", "tight_flow"]},
]


## The apex of one jump, in metres.
##
## Not `v² / 2g`: the ship subtracts gravity and moves within the same frame, so
## the apex it reaches is a *sampled* one and it depends on how long a frame is.
## The screen caps a frame at `MAX_STEP` and this walks exactly that cap — the
## number a player on a slow device really gets, and the one a floor height has
## to stay below.
static func jump_reach(step: float = MAX_STEP) -> float:
	var speed := JUMP_SPEED
	var height := 0.0
	var best := 0.0
	while speed > 0.0:
		speed -= GRAVITY * step
		height += speed * step
		if height > best:
			best = height
	return best


## Seconds one jump spends at or above `height`, counted the same way. Zero when
## the ship cannot reach that height in the first place.
static func air_window(height: float, step: float = MAX_STEP) -> float:
	var speed := JUMP_SPEED
	var y := 0.0
	var window := 0.0
	while speed > 0.0:
		speed -= GRAVITY * step
		y += speed * step
		if y >= height:
			window += step
	return window


## How far the ship travels sideways while it is above `height` — the widest gap
## one jump bridges.
##
## Framerate independent on purpose. This is the *design* bound a shape has to
## respect, while `jump_reach` is the *hardware* bound a floor has to respect;
## reading the shape against the sampled number would make every silhouette look
## too tight.
static func jump_gap(height: float) -> float:
	var apex: float = JUMP_SPEED * JUMP_SPEED / (2.0 * GRAVITY)
	if height >= apex:
		return 0.0
	var up := (JUMP_SPEED - sqrt(JUMP_SPEED * JUMP_SPEED - 2.0 * GRAVITY * height)) / GRAVITY
	return BASE_SPEED * 2.0 * up


## Which silhouette a level is built in.
static func level_shape(level: int) -> String:
	return str((LEVELS[clampi(level, 1, MAX_LEVEL) - 1] as Dictionary)["shape"])


## The rule ids a level runs under, in the order `LEVELS` lists them.
static func level_rules(level: int) -> Array:
	return (LEVELS[clampi(level, 1, MAX_LEVEL) - 1] as Dictionary)["rules"]


## Whether a level runs under `rule`. The screen asks this once per frame per
## system, which is why the answer is a lookup and not a scan of the table.
static func has_rule(level: int, rule: String) -> bool:
	return level_rules(level).has(rule)


## Half the width of one of this level's floors. Every level takes `STEP` off
## the one before, so the last tower asks for a precise landing and the first
## forgives a sloppy one.
static func platform_half(level: int) -> float:
	return BASE_PLATFORM_HALF - float(clampi(level, 1, MAX_LEVEL) - 1) * PLATFORM_HALF_STEP


## Where the platform of `floor` stands, tower centre at the origin.
##
## The base sits on the ground and every floor above it is one `FLOOR_HEIGHT`
## higher, so this is the one place the tower's geometry exists. `zigzag` throws
## every other floor out over the void; the other two shapes breathe with a sine
## instead, which keeps two neighbouring floors from standing exactly above one
## another without opening a gap.
static func floor_position(level: int, floor: int) -> Vector3:
	var shape_id := level_shape(level)
	var shape: Dictionary = SHAPES[shape_id]
	var sway: float = float(shape["sway"])
	var radius: float = float(shape["radius"])
	if shape_id == "zigzag":
		radius += sway if floor % 2 == 1 else 0.0
	else:
		radius += sin(float(floor) * 0.7) * sway
	var angle := float(floor) * float(shape["step"])
	return Vector3(cos(angle) * radius, float(floor) * FLOOR_HEIGHT, sin(angle) * radius)


## How far the platform of `floor` slides, in metres. Zero means it stands
## still.
##
## Only the middle of the tower moves. The base is where the run starts and the
## summit is where it ends, and a target that walks away from under the player
## is a different game than a climb — with a fall, a respawn and a torn chain on
## top of it.
static func floor_slide(level: int, floor: int, floors: int) -> float:
	if not has_rule(level, "slide"):
		return 0.0
	if floor < 2 or floor > floors - 3 or floor % 2 == 1:
		return 0.0
	return float((RULES["slide"] as Dictionary)["travel"])


## Where a sliding floor stands at `elapsed`, relative to where it was built.
## `floor_slide` says how far it travels; this says where it is, and the screen
## moves the mesh by exactly the number the landing check reads.
static func slide_offset(elapsed: float, phase: float, travel: float) -> Vector2:
	if travel <= 0.0:
		return Vector2.ZERO
	var angle: float = elapsed * 0.9 + phase
	return Vector2(cos(angle) * travel, sin(angle) * travel)


## How far a crystal above the base circles its floor, in metres. Zero means the
## crystals stand still, which is the whole of level 1.
static func drift_orbit(level: int) -> float:
	if not has_rule(level, "drift"):
		return 0.0
	return float((RULES["drift"] as Dictionary)["orbit"])


## Tower tuning for a level (1-based, clamped to `MAX_LEVEL`): the silhouette,
## the rules under it and every number the screen needs to build it.
static func level_config(level: int) -> Dictionary:
	var l: int = clampi(level, 1, MAX_LEVEL)
	var window := FLOW_WINDOW_MS
	for rule in level_rules(l):
		if str(rule) == "tight_flow":
			window = float((RULES["tight_flow"] as Dictionary)["windowMs"])
	return {
		"level": l,
		"floors": 5 + l * 2,
		"targetMs": float(75 + l * 25) * 1000.0,
		"crystalsPerFloor": 2 + mini(2, int(floor(float(l) / 2.0))),
		"shape": level_shape(l),
		"platformHalf": platform_half(l),
		"driftOrbit": drift_orbit(l),
		"flowWindowMs": window,
		"rules": level_rules(l),
	}


## The widest horizontal gap between two neighbouring floors of a level, in
## metres, and the floor it happens on.
##
## This is the number a silhouette has to answer for. A shape is free to wind
## fast, lean out or throw half its floors over the void — and every one of those
## is only a shape while the ship can still cross what the shape opened up. The
## landing box is subtracted, because the ship has to *touch* a floor, not reach
## its middle.
static func widest_gap(level: int) -> Dictionary:
	var floors: int = 5 + clampi(level, 1, MAX_LEVEL) * 2
	var reach: float = platform_half(level) + PLAYER_RADIUS
	var best := 0.0
	var best_floor := 1
	for f in range(1, floors):
		var below := floor_position(level, f - 1)
		var above := floor_position(level, f)
		var gap := Vector2(below.x - above.x, below.z - above.z).length() - 2.0 * reach
		if gap > best:
			best = gap
			best_floor = f
	return {"gap": best, "floor": best_floor}


## Whether every level of the game can be climbed, and why not if one cannot.
##
## A tower a player cannot finish is the worst thing a difficulty ramp can do, and
## it is invisible: the run just never reaches the top and no screen says why. The
## proof therefore lives in the repository and not in a player's hands. Two
## conditions have to hold, and they are the two ways a tower turns impossible:
##
## 1. A floor at or above `jump_reach` — the ship never comes down on it.
## 2. A gap wider than `jump_gap` — the ship comes down beside it, not on it.
##
## `""` when every level holds, otherwise the level and the reason in one line.
static func unreachable_level() -> String:
	var carry := jump_gap(FLOOR_HEIGHT)
	for level in range(1, MAX_LEVEL + 1):
		if FLOOR_HEIGHT >= jump_reach():
			return "Floor height %.2f m is at or above the jump reach %.2f m" % [FLOOR_HEIGHT, jump_reach()]
		var gap := widest_gap(level)
		if float(gap["gap"]) > carry:
			return "Level %d: the gap on floor %d is %.2f m, the jump carries %.2f m" % [
				level, int(gap["floor"]), float(gap["gap"]), carry,
			]
	return ""


static func format_time(ms: float) -> String:
	var total := int(maxf(0.0, ms) / 1000.0)
	return "%d:%02d" % [total / 60, total % 60]


# --- save data ---------------------------------------------------------------
##
## Progression lives in `Game`'s generic number store, so it needs no new autoload
## and survives next to the other games' highscores — the same place Pang keeps
## its ladder.
##
## The store is reached through the scene tree rather than the `Game` autoload
## identifier: the headless rule-test runner boots without autoloads, and a plain
## `Game.…` reference would not even parse there (same trick as `Pang`).
##
## Three editions, one set of keys: every key carries the theme's prefix, so a
## christmas record is not read back as a halloween one.

## The number store, or `null` while the headless runner has no scene tree.
static func _store() -> Node:
	var loop := Engine.get_main_loop()
	if not (loop is SceneTree):
		return null
	return (loop as SceneTree).root.get_node_or_null("/root/Game")


static func _read(key: String, fallback: float) -> float:
	var store := _store()
	return store.get_number(key, fallback) if store != null else fallback


static func _write(key: String, value: float) -> void:
	var store := _store()
	if store != null:
		store.set_number(key, value)


## The player-file prefix of a theme, e.g. `singular80_crystal3d`. An unknown id
## falls back to the classic theme rather than throwing: the router hands a
## screen its id, and an id from an older build may name a theme that is gone.
static func theme_prefix(theme_id: String) -> String:
	return str(theme_by_id(theme_id)["keyPrefix"])


## Player-file key of the level a theme's next climb should build.
static func level_key(theme_id: String) -> String:
	return "%s_level" % theme_prefix(theme_id)


## Player-file key of one level's record time, in ms. 0 means "never climbed".
static func level_best_key(theme_id: String, level: int) -> String:
	return "%s_best_time_l%d" % [theme_prefix(theme_id), clampi(level, 1, MAX_LEVEL)]


## The level this theme continues at, clamped to the levels that exist.
##
## Clamped to `MAX_LEVEL` and *not* to the unlocked counter: the entry screen
## lets a player start any tower, so a stored level above the progress marker is
## a level the player chose, not a broken save.
static func stored_level(theme_id: String) -> int:
	return clampi(int(_read(level_key(theme_id), 1.0)), 1, MAX_LEVEL)


## Stores the level to build next and returns the level now stored.
static func store_level(theme_id: String, level: int) -> int:
	var target: int = clampi(level, 1, MAX_LEVEL)
	_write(level_key(theme_id), float(target))
	return target


## How far this theme's progress marker has come — the highest level reached,
## one until a goal time is beaten. A marker, not a gate: see `level_card`.
static func unlocked_level(theme_id: String) -> int:
	return clampi(int(_read("%s_unlocked" % theme_prefix(theme_id), 1.0)), 1, MAX_LEVEL)


## The fastest climb of one level in ms, 0 when the summit has never been reached.
static func level_best_ms(theme_id: String, level: int) -> float:
	return _read(level_best_key(theme_id, level), 0.0)


## Stores a climb time for one level when it beats the record there. Reports a
## new record, so the caller can say so.
static func record_level_ms(theme_id: String, level: int, ms: float) -> bool:
	if ms <= 0.0:
		return false
	var best := level_best_ms(theme_id, level)
	if best > 0.0 and ms >= best:
		return false
	_write(level_best_key(theme_id, level), ms)
	return true
