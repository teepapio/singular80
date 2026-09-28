class_name ArenaRuns
extends RefCounted
## Wave forecasting, boss telegraphs, kill chains and the dash for the Arena.
## Everything here is a pure function of elapsed time, the content pack and the
## kill feed, so the HUD can *anticipate* instead of only reacting. The single
## exception is `dash_press()`, the one place a finger turns into input.
## input.

const WAVE_DURATION := 30.0
const BOSS_INTERVAL := 120.0
const PREVIEW_COUNT := 3

## A kill extends the chain; a longer gap breaks it.
const CHAIN_WINDOW := 2.2

## Bonus XP per chain step. Step 1 pays nothing, step 2 pays 1, and so on.
const CHAIN_STEP := 1.0

## Chain steps at which the bonus stops growing.
const CHAIN_CAP := 12

## The rarity ladder, one list for colour and for draft weight. It used to be
## two dictionaries that both stopped at epic, while `DragonRpg.RARITIES` — the
## other half of the same ladder — has five rungs: a legendary card therefore
## got the common grey and weight 0.0, which made it undrawable. The ids here
## are the ids there, in the same order.
const RARITY_LADDER: Array[Dictionary] = [
	{"id": "common", "color": Color(0.392, 0.455, 0.545), "weight": 10.0},
	{"id": "uncommon", "color": Color(0.133, 0.773, 0.369), "weight": 6.0},
	{"id": "rare", "color": Color(0.231, 0.510, 0.965), "weight": 3.0},
	{"id": "epic", "color": Color(0.659, 0.333, 0.969), "weight": 1.5},
	{"id": "legendary", "color": Color(0.984, 0.749, 0.141), "weight": 0.6},
]

## Colour per rarity and draft weight per rarity, both read out of the ladder.
static var RARITY_COLORS: Dictionary = _rarity_field("color")
static var RARITY_WEIGHT: Dictionary = _rarity_field("weight")


static func _rarity_field(key: String) -> Dictionary:
	var out: Dictionary = {}
	for entry in RARITY_LADDER:
		out[str(entry["id"])] = entry[key]
	return out


## 1-based wave number for an elapsed time.
static func wave_at(elapsed: float) -> int:
	return 1 + int(floor(maxf(0.0, elapsed) / WAVE_DURATION))


## Seconds left until the next wave starts; 0.0 while the wave is fresh.
static func time_to_next_wave(elapsed: float) -> float:
	var position := fposmod(maxf(0.0, elapsed), WAVE_DURATION)
	return WAVE_DURATION - position


## The content entries a wave may spawn, i.e. everything unlocked and with a
## positive random weight — the same filter the spawner uses, so the preview
## never promises an enemy that cannot appear.
static func eligible(defs: Array, wave: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for def in defs:
		var entry: Dictionary = def
		if bool(entry.get("boss", false)):
			continue
		if float(entry.get("weight", 0.0)) <= 0.0:
			continue
		if int(entry.get("minWave", 1)) > wave:
			continue
		out.append(entry)
	return out


## The `count` most likely enemies of the next wave, ordered by weight.
##
## Shuffle-bag drafting is what the spawner effectively does, so previewing the
## heaviest entries communicates the wave's character without pretending to know
## the exact order.
static func wave_preview(defs: Array, wave: int, count: int = PREVIEW_COUNT) -> Array[Dictionary]:
	var pool := eligible(defs, wave)
	pool.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("weight", 0.0)) > float(b.get("weight", 0.0))
	)
	var out: Array[Dictionary] = []
	for entry in pool:
		if out.size() >= count:
			break
		out.append(entry)
	return out


## The boss that a wave would spawn, or an empty dictionary.
##
## When several are unlocked the most recently added one wins, because that is the
## fight the player is actually building up to.
static func boss_preview(defs: Array, wave: int) -> Dictionary:
	var best: Dictionary = {}
	var best_unlock := -1
	for def in defs:
		var entry: Dictionary = def
		if not bool(entry.get("boss", false)):
			continue
		var unlock := int(entry.get("minWave", 1))
		if unlock > wave:
			continue
		if unlock >= best_unlock:
			best_unlock = unlock
			best = entry
	return best


## Seconds until the next boss spawn, or -1.0 when no boss is due at all.
static func boss_countdown(elapsed: float, next_boss_at: float) -> float:
	return next_boss_at - maxf(0.0, elapsed)


## Threat level of an incoming boss, used for the banner colour.
static func boss_threat(countdown: float) -> int:
	if countdown <= 8.0:
		return 2
	return 1 if countdown <= 20.0 else 0


## Feed a kill into the chain state.
##
## `state` is `{"chain": int, "last_kill": float}`. Returns the new state plus
## the awarded bonus XP and whether the chain just grew past a milestone (used for
## the HUD flash).
## for the HUD flash).
static func register_kill(state: Dictionary, now: float, base_xp: int) -> Dictionary:
	var chain: int = int(state.get("chain", 0))
	var last: float = float(state.get("last_kill", -999.0))
	chain = chain + 1 if now - last <= CHAIN_WINDOW else 1
	var capped: int = mini(chain, CHAIN_CAP)
	return {
		"chain": chain,
		"last_kill": now,
		"bonus": int(round(float(maxi(0, capped - 1)) * CHAIN_STEP)),
		"milestone": capped in [3, 5, 8, 12],
	}


## Drops the chain once the window has expired, so a dead streak disappears from
## the HUD instead of lingering.
static func decay(state: Dictionary, now: float) -> Dictionary:
	if int(state.get("chain", 0)) == 0:
		return state
	if now - float(state.get("last_kill", -999.0)) > CHAIN_WINDOW:
		return {"chain": 0, "last_kill": float(state.get("last_kill", 0.0))}
	return state


## HUD line for the chain, empty while there is none.
static func chain_text(state: Dictionary) -> String:
	var chain: int = int(state.get("chain", 0))
	if chain < 2:
		return ""
	var capped: int = mini(chain, CHAIN_CAP)
	var bonus: int = int(round(float(maxi(0, capped - 1)) * CHAIN_STEP))
	return Loc.f("CHAIN ×%d  ·  +%d XP", [capped, bonus])


## HUD line for the wave forecast: what is coming and how long there is left.
static func preview_text(defs: Array, wave: int, elapsed: float) -> String:
	var names: Array[String] = []
	for entry in wave_preview(defs, wave + 1):
		names.append(str(entry.get("name", "?")))
	if names.is_empty():
		return Loc.f("Wave %d", [wave])
	return Loc.f("Wave %d → %s", [wave, " · ".join(names)])


## Colour for a content entry, by its rarity.
static func color_of(def: Dictionary) -> Color:
	return RARITY_COLORS.get(str(def.get("rarity", "common")), RARITY_COLORS["common"])


# --- level offers -----------------------------------------------------------

## How many offers one level-up presents.
const DRAFT_SIZE := 3

## What each stat serves. The axis decides how much a relative gain counts: in a
## survival run damage ends it long before tempo runs out, so an offensive card is
## worth more than an equally large gain in comfort.
##
## The keys are the stat names of `PlayerStats`. The upgrade pack spells them
## `maxHp` and `xpMult`; `stat_key()` is what makes the two spellings one.
const STAT_AXIS := {
	"max_hp": "zaehigkeit",

	"hp": "zaehigkeit",
	"hp_regen": "zaehigkeit",
	"armor": "zaehigkeit",
	"damage_mult": "angriff",
	"fire_rate": "angriff",
	"crit_chance": "angriff",
	"crit_mult": "angriff",
	"pierce": "angriff",
	"projectile_count": "angriff",
	"projectile_speed": "angriff",
	"move_speed_mult": "ertrag",
	"pickup_radius": "ertrag",
	"xp_mult": "ertrag",
}

## What each stat is called on the card. A caption rather than a sentence, but a
## caption that a language may want to word differently ("Yield" is not a
## one-word idea everywhere), so it is a key and not a bare string.
const AXIS_LOC_KEY := {
	"angriff": "arena.axis.angriff",
	"zaehigkeit": "arena.axis.zaehigkeit",
	"ertrag": "arena.axis.ertrag",
}

## Every key this module hands to `Loc.t`, so the extractor can find them: they
## are looked up in dictionaries, and a key that is only ever built at runtime is
## invisible to it.
const ARENA_LOC_KEYS: Array[String] = [
	"arena.axis.angriff",
	"arena.axis.zaehigkeit",
	"arena.axis.ertrag",
	"arena.repair.0",
	"arena.repair.1",
	"arena.repair.2",
	"arena.draft.badge",
]

const AXIS_WEIGHT := {"angriff": 1.0, "zaehigkeit": 0.7, "ertrag": 0.6}

## A flat armour reduction has no percentage to compare against, so the damage of
## an average body hit stands in for one.
const TOUCH_DAMAGE := 10.0

## Regeneration pays over time rather than per hit; a minute is the horizon a level
## decision is made in.
const AMOUNT_PERIOD := 60.0

## Not every bullet that pierces finds a second body behind the first, so a pierce
## step is damped instead of counting as a whole extra shot.
const PIERCE_SHARE := 0.3

## A relative gain of this much fills the effect bar on the card completely.
const EFFECT_FULL := 0.3

## The fallback cards, used when the pool of upgrades runs out. Each heals a growing
## share of what is missing, so even a fallback draft offers a choice instead of
## three identical buttons.
const REPAIR_SHARE := [0.3, 0.5, 0.75]
const REPAIR_LOC_KEY := ["arena.repair.0", "arena.repair.1", "arena.repair.2"]
const REPAIR_RARITY := ["common", "uncommon", "rare"]


## The stat name in the spelling `PlayerStats` uses.
##
## The upgrade pack writes `maxHp`, the stat block holds `max_hp`, and
## `PlayerStats.apply_upgrade` silently drops everything it does not recognise —
## which is most of the pack. Both spellings mean the same number, so the draft
## reads either and hands the stat block the name it knows.
static func stat_key(upgrade: Dictionary) -> String:
	return str(upgrade.get("stat", "")).to_snake_case()


## The same offer with its stat in the spelling `PlayerStats` applies.
static func applied_form(upgrade: Dictionary) -> Dictionary:
	var out: Dictionary = upgrade.duplicate()
	out["stat"] = stat_key(upgrade)
	return out


## The axis a stat serves; an unknown stat is treated as an offensive card, because
## that is the axis the draft must never under-rank.
static func axis_of(upgrade: Dictionary) -> String:
	return str(STAT_AXIS.get(stat_key(upgrade), "angriff"))


static func axis_label(upgrade: Dictionary) -> String:
	return Loc.t(str(AXIS_LOC_KEY.get(axis_of(upgrade), AXIS_LOC_KEY["angriff"])))


## One offer per stat, in the order the pool lists them.
##
## Two cards that raise the same number are not a decision, they are the same card
## twice — so the draft keeps a single representative per stat. Of two candidates
## for the same stat the one with fewer stacks wins, because that is the one the
## player has taken least often.
static func one_per_stat(pool: Array, stacks: Dictionary = {}) -> Array[Dictionary]:
	var chosen: Array[Dictionary] = []
	var at_of: Dictionary = {}
	for def in pool:
		var entry: Dictionary = def
		var stat := stat_key(entry)
		if not at_of.has(stat):
			at_of[stat] = chosen.size()
			chosen.append(entry)
			continue
		# Two cards for one stat: the one taken least often wins, because that is the
		# one the draft has the least reason to repeat.
		var at: int = int(at_of[stat])
		if _stacks_of(entry, stacks) < _stacks_of(chosen[at], stacks):
			chosen[at] = entry
	return chosen


static func _stacks_of(upgrade: Dictionary, stacks: Dictionary) -> int:
	return int(stacks.get(str(upgrade.get("id", "")), 0))


## Draws `count` offers out of `candidates`, weighted by rarity, removing what it
## picked so no card can appear twice.
##
## The rolls are passed in rather than pulled from `randf()` here: a weighted pick
## is the one thing a test cannot predict otherwise, and a screen that wants
## randomness just fills the array with `randf()`.
static func weighted_draft(candidates: Array, count: int, rolls: PackedFloat32Array) -> Array[Dictionary]:
	var picks: Array[Dictionary] = []
	var available: Array = candidates.duplicate()
	var used := 0
	while picks.size() < count and not available.is_empty():
		var total := 0.0
		for def in available:
			total += _rarity_weight(def)
		if total <= 0.0:
			break
		var roll: float = randf() if used >= rolls.size() else rolls[used]
		used += 1
		roll = clampf(roll, 0.0, 0.999999) * total
		var index := available.size() - 1
		for i in available.size():
			roll -= _rarity_weight(available[i])
			if roll <= 0.0:
				index = i
				break
		picks.append(available[index])
		available.remove_at(index)
	return picks


## Draft weight of one card. A rarity the ladder does not know falls back to the
## common weight: weight 0.0 would drop the card from the draft without a word,
## which is what a legendary card used to do.
static func _rarity_weight(def: Variant) -> float:
	var rarity := str((def as Dictionary).get("rarity", "common"))
	return float(RARITY_WEIGHT.get(rarity, RARITY_WEIGHT["common"]))


## A heal card for slot `slot`, scaled to what the player is actually missing. Three
## different amounts, because "you may pick one of three identical buttons" is the
## one draft that is not a decision.
static func repair_offer(stats: PlayerStats, slot: int) -> Dictionary:
	var index: int = clampi(slot, 0, REPAIR_SHARE.size() - 1)
	var missing: float = maxf(0.0, stats.max_hp - stats.hp)
	# The floor grows with the slot so two repairs can never come out equal.
	var floor_amount: int = 15 * (index + 1)
	var amount: int = maxi(floor_amount, int(round(missing * float(REPAIR_SHARE[index]))))
	return {
		"id": "repair_%d" % index,
		"name": Loc.t(str(REPAIR_LOC_KEY[index])),
		"description": Loc.f("+%d health", [amount]),
		"stat": "hp",
		"amount": amount,
		"maxStacks": 99,
		"rarity": str(REPAIR_RARITY[index]),
		"minLevel": 1,
	}


## How much a number grew, in its own unit. A stat that sits at zero has no relative
## size, so it counts as one full step — the guard exists so a degenerate stat
## cannot divide a whole draft by zero.
static func _rel(after: float, before: float) -> float:
	if absf(before) < 0.0001:
		return 1.0
	return (after - before) / absf(before)


## Damage of an average body hit after `armor` points of armour.
static func hit_damage(armor: float) -> float:
	return maxf(1.0, TOUCH_DAMAGE - armor)


## The damage of an average shot with crits folded in — the one unit both crit stats
## speak in, so a chance and a multiplier can be compared.
static func _crit_power(crit_chance: float, crit_mult: float) -> float:
	return 1.0 + clampf(crit_chance, 0.0, PlayerStats.MAX_CRIT_CHANCE) * maxf(0.0, crit_mult - 1.0)


## The worth of one offer in the one unit the draft compares in: how much bigger the
## number that matters becomes, damped by what the axis is worth.
static func effect_value(upgrade: Dictionary, stats: PlayerStats) -> float:
	var stat := stat_key(upgrade)
	var amount := float(upgrade.get("amount", 0.0))
	var gain := 0.0
	match stat:
		"max_hp":
			gain = _rel(stats.max_hp + amount, stats.max_hp)
		"hp":
			# A heal is worth what it repairs, and nothing where there is nothing left to
			# repair — which is exactly the judgement the player has to make at a level-up.
			gain = (minf(stats.max_hp, stats.hp + amount) - stats.hp) / maxf(1.0, stats.max_hp)
		"damage_mult":
			gain = _rel(stats.damage_mult + amount, stats.damage_mult)
		"move_speed_mult":
			gain = _rel(stats.move_speed_mult + amount, stats.move_speed_mult)
		"fire_rate":
			# More fire rate is a shorter cooldown, not a bigger number.
			gain = _rel(1.0 + stats.fire_rate + amount, 1.0 + stats.fire_rate)
		"pickup_radius":
			gain = _rel(stats.pickup_radius + amount, stats.pickup_radius)
		"projectile_speed":
			gain = _rel(stats.projectile_speed + amount, maxf(1.0, stats.projectile_speed))
		"hp_regen":
			# Regen is a per-second trickle and has no size of its own to be relative to,
			# so a minute of it is measured against the health pool — the only thing it
			# competes with.
			gain = amount * AMOUNT_PERIOD / maxf(1.0, stats.max_hp)
		"armor":
			gain = 1.0 - hit_damage(stats.armor + amount) / hit_damage(stats.armor)
		"crit_chance":
			gain = _rel(_crit_power(stats.crit_chance + amount, stats.crit_mult),
				_crit_power(stats.crit_chance, stats.crit_mult))
		"crit_mult":
			gain = _rel(_crit_power(stats.crit_chance, stats.crit_mult + amount),
				_crit_power(stats.crit_chance, stats.crit_mult))
		"pierce":
			gain = _rel(1.0 + (stats.pierce + amount) * PIERCE_SHARE, 1.0 + stats.pierce * PIERCE_SHARE)
		"projectile_count":
			gain = _rel(stats.projectile_count + amount, maxf(1.0, stats.projectile_count))
		"xp_mult":
			gain = _rel(stats.xp_mult + amount, stats.xp_mult)
		_:
			return 0.0
	return maxf(0.0, gain) * float(AXIS_WEIGHT.get(axis_of(upgrade), 1.0))


## 0..1, the width of the effect bar on the card.
static func effect_ratio(value: float) -> float:
	return clampf(value / EFFECT_FULL, 0.0, 1.0)


## Index of the strongest offer, or -1 for an empty draft. Ties keep the first card,
## so the marked card is always one the player can actually pick.
static func best_offer_index(offers: Array, stats: PlayerStats) -> int:
	var best := -1
	var best_value := -1.0
	for i in offers.size():
		var offer: Dictionary = offers[i]
		var value := effect_value(offer, stats)
		if value > best_value:
			best_value = value
			best = i
	return best


## The one line that says what the draft is worth: the card the game would take.
static func draft_headline(offers: Array, stats: PlayerStats) -> String:
	var index := best_offer_index(offers, stats)
	if index < 0:
		return ""
	var offer: Dictionary = offers[index]
	return Loc.f("Strongest: %s  ·  +%d %% %s", [
		str(offer.get("name", "")),
		int(round(effect_value(offer, stats) * 100.0)),
		axis_label(offer),
	])


## The two numbers the player compares, and the word that says what they measure.
## Without it "+15 % Schaden" alone does not say whether that is 1.5 or 15 damage.
static func effect_text(upgrade: Dictionary, stats: PlayerStats, weapon: Dictionary = {}) -> String:
	var stat := stat_key(upgrade)
	var amount := float(upgrade.get("amount", 0.0))
	match stat:
		"max_hp":
			return Loc.f("Health  %d → %d", [_i(stats.max_hp), _i(stats.max_hp + amount)])
		"hp":
			return Loc.f("+%d health", [_i(minf(stats.max_hp, stats.hp + amount) - stats.hp)])
		"damage_mult":
			return Loc.f("Damage  %s → %s", [_n(stats.effective_damage()), _n(stats.damage * (stats.damage_mult + amount))])
		"move_speed_mult":
			return Loc.f("Speed  %d → %d", [_i(stats.effective_move_speed()), _i(stats.move_speed * (stats.move_speed_mult + amount))])
		"fire_rate":
			if weapon.is_empty():
				return Loc.f("Fire rate  ×%s → ×%s", [_x(1.0 + stats.fire_rate), _x(1.0 + stats.fire_rate + amount)])
			var base := float(weapon.get("cooldown", 500.0))
			var faster := maxf(PlayerStats.MIN_COOLDOWN_MS, base / (1.0 + stats.fire_rate + amount))
			return Loc.f("Draw  %d → %d ms", [_i(stats.effective_cooldown(weapon)), _i(faster)])
		"pickup_radius":
			return Loc.f("Pickup  %d → %d", [_i(stats.pickup_radius), _i(stats.pickup_radius + amount)])
		"projectile_speed":
			return Loc.f("Charge  %d → %d", [_i(stats.projectile_speed), _i(stats.projectile_speed + amount)])
		"hp_regen":
			return Loc.f("Regeneration  %s/s → %s/s", [_n(stats.hp_regen), _n(stats.hp_regen + amount)])
		"armor":
			return Loc.f("Damage per hit  %s → %s", [_n(hit_damage(stats.armor)), _n(hit_damage(stats.armor + amount))])
		"crit_chance":
			return Loc.f("Crit  %d %% → %d %%", [_i(stats.crit_chance * 100.0), _i((stats.crit_chance + amount) * 100.0)])
		"crit_mult":
			return Loc.f("Crit damage  %d %% → %d %%", [_i(stats.crit_mult * 100.0), _i((stats.crit_mult + amount) * 100.0)])
		"pierce":
			return Loc.f("Pierce  %d → %d", [_i(stats.pierce), _i(stats.pierce + amount)])
		"projectile_count":
			return Loc.f("Projectiles  %d → %d", [_i(stats.projectile_count), _i(stats.projectile_count + amount)])
		"xp_mult":
			return Loc.f("Experience  %d %% → %d %%", [_i(stats.xp_mult * 100.0), _i((stats.xp_mult + amount) * 100.0)])
		_:
			return ""


static func _n(value: float) -> String:
	return "%.1f" % value


static func _x(value: float) -> String:
	return "%.2f" % value


static func _i(value: float) -> int:
	return int(round(value))


# --- dash --------------------------------------------------------------------

## The input action a finger and a key share. The dash rule itself lives in
## `mechanics/dash_mechanic.gd` and listens to exactly this action; the arena only
## supplies the button and the feedback, so the rule stays in one place.
const DASH_ACTION := "dash"

## How long the after-image of a dash lingers, in seconds.
const DASH_TRAIL_TIME := 0.36

## How many ghosts the after-image leaves, oldest last.
const DASH_TRAIL_STEPS := 3


## The one side effect in this module: a finger becomes the very same input a key
## produces. It lives here rather than in the button so the promise "a thumb
## dashes exactly like the space bar" is something a test can check.
static func dash_press(held: bool) -> void:
	if held:
		Input.action_press(DASH_ACTION)
	else:
		Input.action_release(DASH_ACTION)


## 0 means "ready", 1 means "just dashed": the sweep a cooldown ring draws.
## `cooldown` comes from the mechanic, so tuning the dash there moves the ring with
## it instead of leaving a second number behind to drift.
static func dash_cooldown_ratio(remaining: float, cooldown: float) -> float:
	return clampf(remaining / maxf(0.01, cooldown), 0.0, 1.0)


static func dash_ready(remaining: float) -> bool:
	return remaining <= 0.0


## Countdown on the button, empty while the dash is available.
static func dash_charge_text(remaining: float) -> String:
	if dash_ready(remaining):
		return ""
	return "%.1f" % maxf(0.0, remaining)


## After-images fade out quadratically: the burst pops, the tail lingers.
static func dash_trail_alpha(glow: float) -> float:
	var fade: float = clampf(glow, 0.0, 1.0)
	return fade * fade


## Alpha of the i-th after-image — the oldest ghost is the faintest.
static func dash_step_alpha(glow: float, index: int) -> float:
	return dash_trail_alpha(glow) * clampf(1.0 - float(index) / float(DASH_TRAIL_STEPS), 0.0, 1.0)
