class_name ArenaRuns
extends RefCounted
## Wave forecasting, boss telegraphs, kill chains and the dash for the Arena.
##
## Everything here is a pure function of elapsed time, the content pack and the
## kill feed, so the HUD can *anticipate* instead of only reacting. The single
## exception is `dash_press()`, which is the one place a finger turns into
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

const RARITY_COLORS := {
	"common": Color(0.392, 0.455, 0.545),
	"uncommon": Color(0.133, 0.773, 0.369),
	"rare": Color(0.231, 0.510, 0.965),
	"epic": Color(0.659, 0.333, 0.969),
}


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
## heaviest entries communicates the wave's character without pretending to
## know the exact order.
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
## When several are unlocked the most recently added one wins, because that is
## the fight the player is actually building up to.
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
## the awarded bonus XP and whether the chain just grew past a milestone (used
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
		"milestone": capped in [3, 5, 8, 12, 20],
	}


## Drops the chain once the window has expired, so a dead streak disappears
## from the HUD instead of lingering.
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
	return "KETTE ×%d  ·  +%d EP" % [capped, bonus]


## HUD line for the wave forecast: what is coming and how long there is left.
static func preview_text(defs: Array, wave: int, elapsed: float) -> String:
	var names: Array[String] = []
	for entry in wave_preview(defs, wave + 1):
		names.append(str(entry.get("name", "?")))
	if names.is_empty():
		return "Welle %d" % wave
	return "Welle %d → %s" % [wave, " · ".join(names)]


## Colour for a content entry, by its rarity.
static func color_of(def: Dictionary) -> Color:
	return RARITY_COLORS.get(str(def.get("rarity", "common")), RARITY_COLORS["common"])


# --- dash --------------------------------------------------------------------

## The input action a finger and a key share. The dash rule itself lives in
## `mechanics/dash_mechanic.gd` and listens to exactly this action; the arena
## only supplies the button and the feedback, so the rule stays in one place.
const DASH_ACTION := "dash"

## How long the after-image of a dash lingers, in seconds.
const DASH_TRAIL_TIME := 0.36

## How many ghosts the after-image leaves, oldest last.
const DASH_TRAIL_STEPS := 3


## The one side effect in this module: a finger becomes the very same input a
## key produces. It lives here rather than in the button so the promise "a thumb
## dashes exactly like the space bar" is something a test can check.
static func dash_press(held: bool) -> void:
	if held:
		Input.action_press(DASH_ACTION)
	else:
		Input.action_release(DASH_ACTION)


## 0 means "ready", 1 means "just dashed": the sweep a cooldown ring draws.
## `cooldown` comes from the mechanic, so tuning the dash there moves the ring
## with it instead of leaving a second number behind to drift.
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
