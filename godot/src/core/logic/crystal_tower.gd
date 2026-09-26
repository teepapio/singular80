class_name CrystalTower
extends RefCounted
## Logic for the "Crystal Jumper 3D" tower climb and its themed editions.
## Port of `src/game/crystalTower.ts`.

const MAX_CRYSTAL_TIER := 5
const MAX_LEVEL := 6

## How long a "Flusskette" (flow chain) survives without a new pickup, in ms.
const FLOW_WINDOW_MS := 3000.0
## Upper bound of the chain: past it the count stops, the bonus keeps paying.
const MAX_FLOW := 10
## Names for the chain, so the counter becomes a goal instead of a number.
const FLOW_TITLES := [
	"", "Zug", "Doppel", "Fluss", "Strom", "Kaskade", "Wirbel", "Sturm", "Furie", "Orkan", "Singular",
]

const THEME_CLASSIC := "classic"
const THEME_CHRISTMAS := "christmas"
const THEME_HALLOWEEN := "halloween"

const CRYSTAL_TIERS := [
	{"tier": 1, "name": "Splitter", "color": Color("93c5fd"), "value": 1, "asset": "crystal1"},
	{"tier": 2, "name": "Kristall", "color": Color("22d3ee"), "value": 3, "asset": "crystal2"},
	{"tier": 3, "name": "Juwel", "color": Color("34d399"), "value": 9, "asset": "crystal3"},
	{"tier": 4, "name": "Prisma", "color": Color("fbbf24"), "value": 27, "asset": "crystal4"},
	{"tier": 5, "name": "Sternenkern", "color": Color("f472b6"), "value": 81, "asset": "crystal5"},
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
		"hint": "Stick bewegen · Sprung-Taste · Gipfel erreichen!",
	},
	THEME_CHRISTMAS: {
		"id": THEME_CHRISTMAS,
		"title": "Crystal Jumper — Weihnachten",
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
		"hint": "Fröhliches Klettern! Sammle Weihnachtsschmuck und erreiche den Gipfel.",
	},
	THEME_HALLOWEEN: {
		"id": THEME_HALLOWEEN,
		"title": "Crystal Jumper — Halloween",
		"icon": "☠",
		"tierNames": ["Kürbiskern", "Süßigkeit", "Mini-Kürbis", "Kürbis", "Geisterkürbis"],
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
		"hint": "Sammle Kürbisse bei Nacht und klettere zum Geistergipfel.",
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


## Score value of one crystal of the given tier.
static func tier_value(tier: int) -> int:
	return int(tier_info(tier)["value"])


## Tier a crystal found on the given floor (0 = base) gets. Higher = rarer.
static func tier_for_floor(floor: int, floors: int) -> int:
	if floors <= 1:
		return 1
	var ratio: float = clampf(float(floor) / float(floors - 1), 0.0, 1.0)
	return clampi(1 + int(round(ratio * float(MAX_CRYSTAL_TIER - 1))), 1, MAX_CRYSTAL_TIER)


## Plans the full merge cascade: three crystals of a tier become one of the next
## tier, repeatedly, starting at the lowest tier. `steps` lists the individual
## merges so the scene can animate them one by one.
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


# --- Flusskette -------------------------------------------------------------
##
## Pickups in quick succession build a chain, and every crystal of the chain is
## worth its own value again per step. Climb without hesitating and the score
## runs away; stand still and the chain is gone. The window is the only rule,
## which is what makes it readable while the tower scrolls past.

## Chain length after a pickup at `elapsed_ms`. A `last_ms` below zero means "no
## pickup yet"; an elapsed window starts a fresh chain at 1.
static func next_flow(elapsed_ms: float, last_ms: float, chain: int) -> int:
	if chain > 0 and last_ms >= 0.0 and elapsed_ms - last_ms <= FLOW_WINDOW_MS:
		return mini(chain + 1, MAX_FLOW)
	return 1


## Remaining lifetime of the chain in ms (0 = expired). A chain of one has no
## bar: a single pickup is not a flow yet, so the HUD stays quiet until the
## second one.
static func flow_left_ms(elapsed_ms: float, last_ms: float, chain: int) -> float:
	if chain < 2:
		return 0.0
	return clampf(FLOW_WINDOW_MS - (elapsed_ms - last_ms), 0.0, FLOW_WINDOW_MS)


## Fill level of the chain bar, 0..1.
static func flow_ratio(elapsed_ms: float, last_ms: float, chain: int) -> float:
	return flow_left_ms(elapsed_ms, last_ms, chain) / FLOW_WINDOW_MS


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
	return "×%d %s" % [flow_multiplier(chain), flow_title(chain)]


## Stat boost granted by equipping a crystal of the given tier.
static func equip_bonus(tier: int) -> Dictionary:
	var t: int = clampi(tier, 1, MAX_CRYSTAL_TIER)
	return {
		"speedMult": 1.0 + float(t) * 0.05,
		"jumpMult": 1.0 + float(t) * 0.04,
		"pickupRadius": 1.9 + float(t) * 0.3,
		"extraJumps": int(floor(float(t - 1) / 2.0)),
	}


## Tower tuning for a level (1-based, clamped to `MAX_LEVEL`).
static func level_config(level: int) -> Dictionary:
	var l: int = clampi(level, 1, MAX_LEVEL)
	return {
		"level": l,
		"floors": 5 + l * 2,
		"targetMs": float(75 + l * 25) * 1000.0,
		"crystalsPerFloor": 2 + mini(2, int(floor(float(l) / 2.0))),
	}


static func format_time(ms: float) -> String:
	var total := int(maxf(0.0, ms) / 1000.0)
	return "%d:%02d" % [total / 60, total % 60]
