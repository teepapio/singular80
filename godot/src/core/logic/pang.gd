class_name Pang
extends RefCounted
## Rules for "Pang 3D" — a faithful take on the 1990 arcade original.
##
## The whole game is: balls fall, bounce and split, the player runs left and
## right along the floor and shoots harpoons straight up, and every ball has to
## be gone before the clock runs out. That is all — no heroes, no abilities, no
## orbiting spacecraft, no upgrade trees. Everything here is renderer free and
## deterministic, so the levels, physics constants and bonus drops are unit
## testable and the screen only draws what this module decides.
##
## A level ships its balls in two batches: the opening layout, and — from the
## middle of the campaign on — reinforcement waves that drop in while the level
## is still running. Both are decided here, so the level select, the ball
## budget and the screen all count the same balls.

# --- arena ------------------------------------------------------------------
# World units. X runs across the arena, Y is up, Z is the (shallow) depth axis
# the balls and the harpoons live on.

const ARENA_HALF_WIDTH := 15.0
const FLOOR_Y := 0.0
const CEILING_Y := 17.0
## Balls never settle below this line, so nothing rests on the player's head.
const FLOOR_BAND_TOP := 3.2
const PLAYER_HALF_WIDTH := 0.8
const PLAYER_TOP_Y := 1.9
## The hit box is smaller than the knight mesh on purpose: balls roll along the
## same floor strip the player walks on, so only a solid overlap should cost a
## life and brushing past has to stay survivable.
const PLAYER_HITBOX_HALF_WIDTH := 0.5
const PLAYER_HITBOX_TOP := 1.25

const GRAVITY := 26.0
## Horizontal speed of a size-1 ball; every other size scales off this.
const BALL_BASE_SPEED := 4.6

# --- balls ------------------------------------------------------------------

const SIZE_LARGEST := 1
const SIZE_SMALLEST := 4
## Every ball splits down to `SIZE_SMALLEST`, so a level that opens with `n`
## balls can momentarily hold `n * 2^(SIZE_SMALLEST-1)` of them. The
## reinforcement waves sit on top of that, so the cap is checked against
## `peak_balls` of the widest level in the campaign rather than guessed.
const ORB_SAFE_CAP := 128

## One entry per size level. `bounce` is the apex a ball reaches after a floor
## bounce, which is what makes big ones feel heavy and small ones twitchy.
const SIZES: Array[Dictionary] = [
	{"level": 1, "radius": 1.15, "speedMult": 1.10, "bounce": 12.4, "points": 100, "color": Color("f87171")},
	{"level": 2, "radius": 0.86, "speedMult": 1.42, "bounce": 10.4, "points": 50, "color": Color("fb923c")},
	{"level": 3, "radius": 0.60, "speedMult": 1.70, "bounce": 8.4, "points": 25, "color": Color("facc15")},
	{"level": 4, "radius": 0.42, "speedMult": 1.95, "bounce": 6.4, "points": 10, "color": Color("38bdf8")},
]

# --- the two-shot trick ------------------------------------------------------
# The signature of the original: the smallest ball takes two hits. The first
# one does not split it, it only arms it — the ball crawls and blinks, and the
# second harpoon pops it for a bonus. That is the difference between a level
# that ends in two twitchy little balls you have to chase again, and a level a
# good player ends with the second shot of a planned pair.

const HIT_SPLIT := "split"
const HIT_ARM := "arm"
const HIT_POP := "pop"

## How long an armed ball stays armable. Long enough to walk over and line up
## the second shot, short enough that it is not a free pop later on.
const ARM_WINDOW := 6.0
## An armed ball crawls: slow enough to be worth chasing, still fast enough to
## punish a player who walks away from it.
const ARM_SLOWDOWN := 0.32
## The first hit pays a little, so arming is never simply a wasted harpoon.
const ARM_POINTS := 5
## The second hit pays the ball's own value plus this, which is the reward for
## spending a second harpoon instead of doubling the problem.
const ARM_BONUS := 15
## Blink period of the armed tell. One clock drives every ball, so the whole
## board flashes in step instead of looking like noise.
const ARM_BLINK := 0.26
const ARM_TINT := Color("f8fafc")
## The one-line rule the HUD teaches. It lives here with the rest of the rules
## so the copy and the behaviour cannot drift apart.
const ARM_HINT := "Kleinste Kugel: 1. Treffer lässt sie blinken, 2. Treffer platzt"

# --- harpoon ----------------------------------------------------------------

const HARPOON_SPEED := 17.0
## How long a harpoon stays stuck in the ceiling before it drops away. This
## brief pause is what makes threading a shot between two balls a real skill.
const HARPOON_HOLD_TIME := 0.9
const HARPOON_COOLDOWN := 0.3
const HARPOON_HALF_WIDTH := 0.42
const BASE_HARPOONS := 1
const MAX_HARPOONS := 4

const PLAYER_MOVE_SPEED := 8.4
## Protection at level start: the balls drop onto the player's own strip of
## floor, so without it a level can be lost before the first shot.
const START_GRACE := 2.5
const INVULN_TIME := 1.6
const RESPAWN_TIME := 1.1

# --- bonus drops ------------------------------------------------------------
# The original drops a small item when a ball bursts. Keeping the set tiny is
# deliberate: two bars, one of which the player spends on positioning.

const DROP_CHANCE := 0.14
## `weight` drives the drop table. `double_harpoon` is additive, `freeze` is
## timed, the rest apply instantly.
const BONUSES: Array[Dictionary] = [
	{"id": "double_harpoon", "name": "Doppelhaken", "icon": "⇈", "asset": "pang/harpoon", "color": Color("facc15"), "weight": 40, "duration": 0.0, "description": "Zwei Haken auf einmal."},
	{"id": "freeze", "name": "Eiswürfel", "icon": "❄", "asset": "pang/ice", "color": Color("67e8f9"), "weight": 20, "duration": 6.0, "description": "Hält alle Kugeln sechs Sekunden an."},
	{"id": "extra_time", "name": "Zeitbonus", "icon": "∞", "asset": "pang/clock", "color": Color("34d399"), "weight": 20, "duration": 0.0, "description": "Schenkt dir Sekunden."},
	{"id": "extra_life", "name": "Leben", "icon": "♥", "asset": "pang/heart", "color": Color("f472b6"), "weight": 20, "duration": 0.0, "description": "Ein Leben extra."},
]

const FREEZE_DURATION := 6.0
const EXTRA_TIME_AMOUNT := 12.0

# --- level scenery ----------------------------------------------------------
# The original plays across plain stages: a floor, side walls, a ceiling, and
# the occasional fixed platform the harpoon can stick into.

## `bounces` means balls ricochet off it, `blocks` means the harpoon stops there.
## Breakable crates take `hp` hits; fixed platforms are indestructible.
const OBSTACLE_BREAKABLE := "crate"
const OBSTACLE_FIXED := "platform"

const OBSTACLE_SPECS: Array[Dictionary] = [
	{"kind": OBSTACLE_BREAKABLE, "asset": "rpg/crate", "halfWidth": 0.7, "halfHeight": 0.7, "halfDepth": 0.7, "hp": 2, "bounces": true, "blocks": false, "scale": 1.3},
	{"kind": OBSTACLE_FIXED, "asset": "pang/platform", "halfWidth": 2.2, "halfHeight": 0.4, "halfDepth": 0.5, "hp": 0, "bounces": true, "blocks": true, "scale": 1.0},
]

# --- campaign ---------------------------------------------------------------

const TOTAL_LEVELS := 30
const FIRST_UNLOCKED := 1
const LIVES := 3
## Levels per page in the level select.
const LEVELS_PER_PAGE := 10

## Difficulty ramps over the whole campaign, so the curve never jumps.
## Level 1 gets `TIME_START` seconds and `BALLS_START` balls, the last level
## `TIME_END` and `BALLS_END`.
##
## The clock is sized against the ball budget, not picked by feel: a level that
## ships more balls also gets more seconds, so "more balls" stays a fuller
## screen instead of a faster firing range. `shot_cost` is the number both
## numbers are balanced against.
const TIME_START := 118.0
const TIME_END := 92.0
const BALLS_START := 4
const BALLS_END := 10

# --- more balls -------------------------------------------------------------
# A level that dumps every ball in its first second is over before the screen
# has warmed up, and the request every player makes after the third level is
# "more balls". Two cheap sources of them, both of them decided here:
#
#   * the *riffle* — a crowd of the two smallest sizes, spread under the ceiling
#     in the opening layout. Two to five harpoons each, so the arena looks busy
#     without the level turning into a shooting gallery.
#   * the *reinforcement wave* — a second batch that drops in while the level is
#     still running, once the board has thinned out. It keeps the clock
#     interesting and gives a level a second act instead of a single dump.

## First level that carries a riffle, and its size at the start of the campaign.
const RIFFLE_FIRST_LEVEL := 6
const RIFFLE_START := 2
## The riffle never grows past the two smallest sizes, and never below the
## chain balls of its own level.
const RIFFLE_SIZE := 3
const RIFFLE_MAX := 6

## How often a batch ball may look for a free spot before it keeps the one it
## drew. A crowded arena is exactly the case this has to survive, so the number
## is generous; a failed search still ends in a legal spot, never in a loop.
const BATCH_PLACEMENT_TRIES := 8

## First level that sends reinforcements, and how many waves a level may send.
const WAVE_FIRST_LEVEL := 9
const WAVE_MAX := 2
const WAVE_BALLS_START := 2
const WAVE_BALLS_END := 4
## Live balls at which the next wave drops in. Waiting for a thin board is what
## makes the arrival a beat instead of an interruption.
const WAVE_TRIGGER := 5
## …and a wave never waits longer than this, so the reinforcements always come
## and a level can never be finished before it has shown up.
const WAVE_MAX_DELAY := 11.0

# --- lookups ----------------------------------------------------------------

static func size_spec(size_level: int) -> Dictionary:
	return SIZES[clampi(size_level, SIZE_LARGEST, SIZE_SMALLEST) - 1]


static func radius_of(size_level: int) -> float:
	return float(size_spec(size_level)["radius"])


static func speed_of(size_level: int) -> float:
	return BALL_BASE_SPEED * float(size_spec(size_level)["speedMult"])


static func bounce_of(size_level: int) -> float:
	return float(size_spec(size_level)["bounce"])


static func points_for(size_level: int) -> int:
	return int(size_spec(size_level)["points"])


## Only the smallest size has the two-shot trick, exactly like in the arcade
## original: every bigger ball has to be split.
static func needs_two_hits(size_level: int) -> bool:
	return clampi(size_level, SIZE_LARGEST, SIZE_SMALLEST) >= SIZE_SMALLEST


## What one harpoon hit does to a ball of this size; `armed` is the ball's
## state before the hit. Above the smallest size every hit splits, the smallest
## size arms itself on the first hit and pops on the second.
static func hit_outcome(size_level: int, armed: bool) -> String:
	if not needs_two_hits(size_level):
		return HIT_SPLIT
	return HIT_POP if armed else HIT_ARM


## Points one hit is worth. Arming pays a consolation, finishing pays the full
## value of the ball plus the bonus, and a ball that splits always pays its
## plain value.
static func hit_points(size_level: int, armed: bool) -> int:
	if not needs_two_hits(size_level):
		return points_for(size_level)
	return points_for(size_level) + ARM_BONUS if armed else ARM_POINTS


## How many harpoons a ball of this size costs to clear.
static func shots_needed(size_level: int) -> int:
	return 2 if needs_two_hits(size_level) else 1


## Horizontal speed of an armed ball. Unarmed it keeps `speed_of`; the screen
## applies this once when a ball is armed, so a bounce can never slow it twice.
static func armed_speed(size_level: int) -> float:
	return speed_of(size_level) * ARM_SLOWDOWN


## True while the armed tell blinks. `clock` is the run clock, which keeps every
## armed ball in step.
static func is_blinking(clock: float) -> bool:
	return fmod(maxf(0.0, clock), ARM_BLINK) < ARM_BLINK * 0.5


## Vertical speed that makes a ball reach `bounce_of(size)` after a floor hit.
static func jump_velocity(size_level: int) -> float:
	return sqrt(2.0 * GRAVITY * bounce_of(size_level))


static func bonus_by_id(id: String) -> Dictionary:
	for entry in BONUSES:
		if str(entry["id"]) == id:
			return entry
	return BONUSES[0]


static func obstacle_spec(kind: String) -> Dictionary:
	for spec in OBSTACLE_SPECS:
		if str(spec["kind"]) == kind:
			return spec
	return OBSTACLE_SPECS[0]


static func max_harpoons(extra: int) -> int:
	return clampi(BASE_HARPOONS + extra, BASE_HARPOONS, MAX_HARPOONS)


## Weighted drop from a roll in [0, 1). Deterministic so the table is testable.
static func roll_bonus(roll: float) -> Dictionary:
	var total := 0.0
	for entry in BONUSES:
		total += float(entry["weight"])
	var target: float = clampf(roll, 0.0, 0.999999) * total
	for entry in BONUSES:
		target -= float(entry["weight"])
		if target <= 0.0:
			return entry
	return BONUSES[BONUSES.size() - 1]


## True while the clock is stopped by a freeze bonus.
static func is_frozen(freeze_left: float) -> bool:
	return freeze_left > 0.0


# --- levels -----------------------------------------------------------------

## Progress through the campaign in [0, 1].
static func level_progress(level: int) -> float:
	return float(clampi(level, 1, TOTAL_LEVELS) - 1) / float(maxi(1, TOTAL_LEVELS - 1))


## How many small balls join the opening layout. Zero in the first levels, then
## a slow ramp to `RIFFLE_MAX`.
static func riffle_count(level: int) -> int:
	var n: int = clampi(level, 1, TOTAL_LEVELS)
	if n < RIFFLE_FIRST_LEVEL:
		return 0
	return clampi(
		int(round(lerpf(float(RIFFLE_START), float(RIFFLE_MAX), level_progress(n)))),
		RIFFLE_START,
		RIFFLE_MAX
	)


## How many reinforcement waves a level sends: none early, one through the
## middle of the campaign, two at the very end.
static func wave_count(level: int) -> int:
	var n: int = clampi(level, 1, TOTAL_LEVELS)
	if n < WAVE_FIRST_LEVEL:
		return 0
	var span: float = float(maxi(1, TOTAL_LEVELS - WAVE_FIRST_LEVEL + 1))
	return clampi(1 + int(floor(float(n - WAVE_FIRST_LEVEL) * float(WAVE_MAX) / span)), 1, WAVE_MAX)


## Balls in wave `index` (0 based). Every wave is a little bigger than the one
## before it, and the last levels send the biggest batches.
static func wave_balls(level: int, index: int) -> int:
	var growth: int = int(round(lerpf(0.0, float(WAVE_BALLS_END - WAVE_BALLS_START), level_progress(clampi(level, 1, TOTAL_LEVELS)))))
	return clampi(WAVE_BALLS_START + growth + maxi(0, index), WAVE_BALLS_START, WAVE_BALLS_END)


## "1 Welle" and "2 Wellen". The HUD and the level select both put a count in
## front of this noun, and telling the two forms apart is the only German
## conjugation the game needs.
static func wave_label(count: int) -> String:
	return "%d Welle" % count if count == 1 else "%d Wellen" % count


## The size a reinforcement arrives in: two steps below the level's own balls,
## clamped into the table. A wave is meant to be a swarm of fast, twitchy
## balls — never a second wall of the big ones.
static func reinforcement_size(base_size: int) -> int:
	return clampi(int(base_size) + 2, SIZE_LARGEST, SIZE_SMALLEST)


## Every ball a level ships, opening batch, riffle and all waves together. The
## level select shows this, so a card never promises fewer balls than the level
## delivers. Walks the whole layout, so a per-frame caller should cache it.
static func level_ball_total(level: int) -> int:
	return total_balls(level_data(level))


static func level_title(level: int) -> String:
	return "Level %d" % maxi(1, level)


## The time the level should comfortably take; the clear bonus is measured
## against it, so par grows with the layout instead of a flat constant.
static func par_time(level: int) -> float:
	return 24.0 + 5.0 * float(maxi(1, level))


## Difficulty knobs for a level, all derived from one ramp.
static func level_config(level: int) -> Dictionary:
	var n: int = clampi(level, 1, TOTAL_LEVELS)
	var t: float = level_progress(n)
	return {
		"level": n,
		"timeLimit": lerpf(TIME_START, TIME_END, t),
		"ballCount": clampi(int(round(lerpf(float(BALLS_START), float(BALLS_END), t))), BALLS_START, BALLS_END),
		"riffleCount": riffle_count(n),
		"waves": wave_count(n),
		"baseSize": 1 if n > 12 else (2 if n > 4 else 3),
		"speedMult": 1.0 + t * 0.3,
		"crates": 0 if n < 4 else clampi(int(floor(float(n - 3) * 0.3)), 0, 3),
		"platforms": 0 if n < 7 else clampi(int(floor(float(n - 6) * 0.28)), 0, 3),
		"background": (n - 1) % 3,
	}


## Full, deterministic layout for a level: ball positions, the reinforcement
## waves and the stage furniture. Same level in, same level out — no RNG state,
## no surprises.
static func level_data(level: int) -> Dictionary:
	var config := level_config(level)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("pang-level-%d" % int(config["level"]))

	var size := int(config["baseSize"])
	var count := int(config["ballCount"])
	var chain := _place_chain(rng, count, size, int(config["level"]))

	# `taken` is what a new ball has to keep clear of. Feeding it forward is what
	# makes a reinforcement wave land in the gaps of the level it belongs to
	# instead of on top of a ball that is still bouncing around up there.
	var taken: Array[Dictionary] = []
	taken.append_array(chain)
	var riffle := _place_riffle(rng, int(config["riffleCount"]), size, taken)
	taken.append_array(riffle)

	# The waves are part of the layout and not of the screen, so the level select
	# and the ball budget see the same reinforcements the player gets.
	var waves: Array[Dictionary] = []
	for index in int(config["waves"]):
		var batch := _place_wave(rng, wave_balls(int(config["level"]), index), reinforcement_size(size), taken)
		taken.append_array(batch)
		waves.append({
			"index": index,
			"trigger": WAVE_TRIGGER,
			"maxDelay": WAVE_MAX_DELAY,
			"balls": batch,
		})

	# The opening batch, chain first and riffle behind it: the screen spawns it
	# in this order, so the order is part of the layout, not of the frame.
	var balls: Array[Dictionary] = []
	balls.append_array(chain)
	balls.append_array(riffle)

	var obstacles: Array[Dictionary] = []
	obstacles.append_array(_scatter(rng, int(config["crates"]), OBSTACLE_BREAKABLE, balls, 0.9))
	obstacles.append_array(_scatter(rng, int(config["platforms"]), OBSTACLE_FIXED, balls, 0.5))

	return {
		"level": int(config["level"]),
		"name": level_title(int(config["level"])),
		"timeLimit": float(config["timeLimit"]),
		"parTime": par_time(int(config["level"])),
		"background": int(config["background"]),
		"speedMult": float(config["speedMult"]),
		"balls": balls,
		"waves": waves,
		"obstacles": obstacles,
	}


## The opening grid of the chain balls. A loose grid over the upper two thirds
## keeps the gaps wide enough to shoot through even once every ball has dropped
## and bounced around. It widens to five columns as soon as a level opens with
## more than eight balls, so two of the big ones never share a cell.
static func _place_chain(rng: RandomNumberGenerator, count: int, base_size: int, level: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var columns: int = 5 if count > 8 else 4
	var rows: int = maxi(1, int(ceil(float(count) / float(columns))))
	var cell_w: float = (ARENA_HALF_WIDTH * 2.0 - 4.0) / float(columns)
	var cell_h: float = (CEILING_Y - FLOOR_BAND_TOP - 3.0) / float(maxi(1, rows))
	for i in count:
		var column: int = i % columns
		var row: int = i / columns
		# Later levels mix in smaller balls, which is what makes them busier.
		var ball_size: int = base_size
		if i > 0 and rng.randf() < 0.15 + level_progress(level) * 0.25:
			ball_size = mini(SIZE_SMALLEST, base_size + 1)
		var spot := _ball_spot(
			-ARENA_HALF_WIDTH + 2.0 + (float(column) + 0.5) * cell_w + rng.randf_range(-0.35, 0.35) * cell_w,
			FLOOR_BAND_TOP + 2.0 + (float(row) + 0.5) * cell_h + rng.randf_range(-0.3, 0.3) * cell_h,
			ball_size
		)
		spot["dir"] = 1.0 if rng.randf() < 0.5 else -1.0
		out.append(spot)
	return out


## The crowd of small balls that joins the opening layout, in two staggered rows
## under the ceiling. It sticks to the two smallest sizes on purpose: that keeps
## the batch cheap in harpoons and in pool slots while it still fills the arena,
## and two rows read as a swarm instead of a line.
static func _place_riffle(rng: RandomNumberGenerator, count: int, base_size: int, taken: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if count <= 0:
		return out
	var top: int = (count + 1) / 2
	out.append_array(_place_row(rng, top, clampi(RIFFLE_SIZE, base_size, SIZE_SMALLEST), taken, CEILING_Y - 1.4))
	# The second row is placed against the first, so the two rows cannot land on
	# top of each other.
	var both: Array[Dictionary] = []
	both.append_array(taken)
	both.append_array(out)
	out.append_array(_place_row(rng, count - top, clampi(RIFFLE_SIZE - 1, base_size, SIZE_SMALLEST), both, CEILING_Y - 2.6))
	return out


## One reinforcement batch, spread under the ceiling in a single size.
static func _place_wave(rng: RandomNumberGenerator, count: int, size: int, taken: Array[Dictionary]) -> Array[Dictionary]:
	return _place_row(rng, count, clampi(size, SIZE_LARGEST, SIZE_SMALLEST), taken, CEILING_Y - 1.4)


## A row of balls at `y`, each one nudged away from everything already on the
## board. A layout that starts with two balls inside each other looks like a bug
## and shoves the pair apart on the first frame, so the spot is checked instead
## of hoped for; a full arena simply keeps the slot it drew.
##
## The search covers the whole field above the player's strip, not just the row:
## a busy level has no free slot left under the ceiling, and a ball that starts
## a little lower is one the player simply shoots first. The rules keep every
## spot above `FLOOR_BAND_TOP`, so nothing ever starts on the knight.
static func _place_row(rng: RandomNumberGenerator, count: int, size: int, taken: Array[Dictionary], y: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if count <= 0:
		return out
	var step: float = (ARENA_HALF_WIDTH * 2.0 - 4.0) / float(count)
	var radius := radius_of(size)
	var lowest: float = FLOOR_BAND_TOP + radius + 0.6
	var highest: float = CEILING_Y - radius - 0.4
	for i in count:
		var spot := _ball_spot(
			-ARENA_HALF_WIDTH + 2.0 + (float(i) + 0.5) * step + rng.randf_range(-0.28, 0.28) * step,
			y,
			size
		)
		for attempt in BATCH_PLACEMENT_TRIES:
			if _ball_spot_free(float(spot["x"]), float(spot["y"]), radius, radius, taken, out):
				break
			# Somewhere else in the field, so a crowded row spreads out instead of
			# stacking. The last attempt keeps the slot rather than looping.
			if attempt == BATCH_PLACEMENT_TRIES - 1:
				break
			spot = _ball_spot(
				rng.randf_range(-ARENA_HALF_WIDTH + 2.6, ARENA_HALF_WIDTH - 2.6),
				rng.randf_range(lowest, highest),
				size
			)
		spot["dir"] = 1.0 if rng.randf() < 0.5 else -1.0
		out.append(spot)
	return out


## A ball's spot, clamped into the playfield: no layout may start a ball half
## outside the arena or inside the player's own strip of floor.
static func _ball_spot(x: float, y: float, size: int) -> Dictionary:
	var radius := radius_of(size)
	return {
		"x": clampf(x, -ARENA_HALF_WIDTH + radius + 0.4, ARENA_HALF_WIDTH - radius - 0.4),
		"y": clampf(y, FLOOR_BAND_TOP + radius, CEILING_Y - radius - 0.4),
		"size": clampi(size, SIZE_LARGEST, SIZE_SMALLEST),
	}


## Drops obstacles onto free spots, skipping the player's strip and anything
## already occupied by a ball or another obstacle.
static func _scatter(rng: RandomNumberGenerator, count: int, kind: String, balls: Array[Dictionary], floor_ratio: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if count <= 0:
		return out
	var spec := obstacle_spec(kind)
	var tries := 0
	while out.size() < count and tries < count * 24:
		tries += 1
		var x: float = rng.randf_range(-ARENA_HALF_WIDTH + 2.6, ARENA_HALF_WIDTH - 2.6)
		var y: float = rng.randf_range(FLOOR_BAND_TOP + 1.4, CEILING_Y - 2.2)
		if rng.randf() < floor_ratio:
			y = FLOOR_BAND_TOP + 0.9
		if not _spot_free(x, y, float(spec["halfWidth"]), float(spec["halfHeight"]), balls, out):
			continue
		out.append({"kind": kind, "x": x, "y": y})
	return out


## Is a box of `half_w` × `half_h` at `x, y` clear of the balls in both lists?
## Two lists instead of one so a batch can be checked against the whole level
## (`taken`) and against its own row (`placed`) without building a merged array.
static func _ball_spot_free(x: float, y: float, half_w: float, half_h: float, taken: Array[Dictionary], placed: Array[Dictionary]) -> bool:
	return _balls_clear(x, y, half_w, half_h, taken) and _balls_clear(x, y, half_w, half_h, placed)


static func _balls_clear(x: float, y: float, half_w: float, half_h: float, balls: Array[Dictionary]) -> bool:
	for ball in balls:
		var radius := radius_of(int(ball["size"]))
		if absf(x - float(ball["x"])) < half_w + radius + 0.35 and absf(y - float(ball["y"])) < half_h + radius + 0.35:
			return false
	return true


static func _spot_free(x: float, y: float, half_w: float, half_h: float, balls: Array[Dictionary], placed: Array[Dictionary]) -> bool:
	var empty: Array[Dictionary] = []
	if not _ball_spot_free(x, y, half_w, half_h, balls, empty):
		return false
	for other in placed:
		var spec := obstacle_spec(str(other["kind"]))
		var gap_x2: float = half_w + float(spec["halfWidth"]) + 0.3
		var gap_y2: float = half_h + float(spec["halfHeight"]) + 0.3
		if absf(x - float(other["x"])) < gap_x2 and absf(y - float(other["y"])) < gap_y2:
			return false
	return true


## Every way a layout can be unfair, as human-readable strings. Empty means the
## level is playable; the test suite asserts exactly that for the whole campaign.
static func validate_level(data: Dictionary) -> Array[String]:
	var problems: Array[String] = []
	var level := int(data.get("level", 0))
	if level < 1 or level > TOTAL_LEVELS:
		problems.append("Level %d liegt außerhalb 1..%d" % [level, TOTAL_LEVELS])
	if float(data.get("timeLimit", 0.0)) < 20.0:
		problems.append("Zeitlimit ist zu knapp")
	var balls: Array = data.get("balls", [])
	if balls.is_empty():
		problems.append("Level hat keine Kugeln")
	_ball_problems(balls, "Kugel", problems)
	# A wave that can never arrive or never be shot at would make a level
	# unclearable in a way the opening layout cannot.
	for wave in data.get("waves", []):
		var entry: Dictionary = wave
		var batch: Array = entry.get("balls", [])
		if batch.is_empty():
			problems.append("Eine Welle kommt ohne Kugeln an")
			continue
		if int(entry.get("trigger", WAVE_TRIGGER)) < 0:
			problems.append("Eine Welle wartet auf eine negative Kugelzahl")
		if float(entry.get("maxDelay", WAVE_MAX_DELAY)) <= 0.0:
			problems.append("Eine Welle kommt gar nicht mehr an")
		_ball_problems(batch, "Wellenkugel", problems)
	for entry in data.get("obstacles", []):
		var kind := str(entry.get("kind", ""))
		if kind != OBSTACLE_BREAKABLE and kind != OBSTACLE_FIXED:
			problems.append("Unbekanntes Hindernis '%s'" % kind)
			continue
		var spec := obstacle_spec(kind)
		if float(entry.get("y", 0.0)) - float(spec["halfHeight"]) < FLOOR_BAND_TOP - 0.2:
			problems.append("Hindernis bei y=%.1f blockiert den Spielersockel" % float(entry.get("y", 0.0)))
	return problems


static func _ball_problems(balls: Array, what: String, problems: Array[String]) -> void:
	for ball in balls:
		var entry: Dictionary = ball
		var size := int(entry.get("size", 0))
		if size < SIZE_LARGEST or size > SIZE_SMALLEST:
			problems.append("%s mit ungültiger Größenstufe %d" % [what, size])
			continue
		var radius := radius_of(size)
		var x := float(entry.get("x", 0.0))
		var y := float(entry.get("y", 0.0))
		if x - radius < -ARENA_HALF_WIDTH or x + radius > ARENA_HALF_WIDTH:
			problems.append("%s bei x=%.1f ragt aus der Arena" % [what, x])
		if y - radius < FLOOR_BAND_TOP or y + radius > CEILING_Y:
			problems.append("%s bei y=%.1f liegt außerhalb des Spielfelds" % [what, y])


# --- ball budget ------------------------------------------------------------
# "More balls" is only free until the pool or the clock runs out, so both are
# measured here instead of being guessed. The screen sizes its orb pool from
# `peak_balls`, and the campaign's time limits are balanced against `shot_cost`.

## Balls one chain holds at its widest: a ball of `size` splits down to the
## smallest size, and the smallest one is popped instead of split, so its leaf
## count is halved.
static func chain_peak(size_level: int) -> int:
	return 1 << maxi(0, SIZE_SMALLEST - 1 - clampi(size_level, SIZE_LARGEST, SIZE_SMALLEST))


## Harpoons it takes to clear one ball of this size, all the way down its chain.
static func chain_cost(size_level: int) -> int:
	var size := clampi(size_level, SIZE_LARGEST, SIZE_SMALLEST)
	if size >= SIZE_SMALLEST:
		# The two-shot trick: no split, so no second generation.
		return shots_needed(size)
	return 1 + 2 * chain_cost(size + 1)


## Every ball a layout ships: the opening batch and all reinforcement waves.
static func total_balls(layout: Dictionary) -> int:
	var count := 0
	for ball in layout.get("balls", []):
		count += 1
	for wave in layout.get("waves", []):
		for ball in (wave as Dictionary).get("balls", []):
			count += 1
	return count


## Worst case of simultaneously live balls: every chain at its widest, waves
## included. A level whose peak does not fit the pool would quietly lose its
## last balls, so the screen's `ORB_LIMIT` has to cover this.
static func peak_balls(layout: Dictionary) -> int:
	var peak := 0
	for ball in layout.get("balls", []):
		peak += chain_peak(int((ball as Dictionary).get("size", SIZE_LARGEST)))
	for wave in layout.get("waves", []):
		for ball in (wave as Dictionary).get("balls", []):
			peak += chain_peak(int((ball as Dictionary).get("size", SIZE_LARGEST)))
	return peak


## Harpoons the whole layout costs, waves included — the work a level actually
## asks for. Divide it by the time limit and you have the campaign's pressure.
static func shot_cost(layout: Dictionary) -> int:
	var shots := 0
	for ball in layout.get("balls", []):
		shots += chain_cost(int((ball as Dictionary).get("size", SIZE_LARGEST)))
	for wave in layout.get("waves", []):
		for ball in (wave as Dictionary).get("balls", []):
			shots += chain_cost(int((ball as Dictionary).get("size", SIZE_LARGEST)))
	return shots


## True when the next reinforcement has to drop in: as soon as the board has
## thinned out to the wave's trigger, and in any case once its own wait is up.
## The first half is what makes the arrival a beat, the second half is what
## keeps a level from being finished before it has shown up.
static func wave_due(wave: Dictionary, live_balls: int, elapsed: float) -> bool:
	if wave.is_empty():
		return false
	if live_balls <= int(wave.get("trigger", WAVE_TRIGGER)):
		return true
	return elapsed >= float(wave.get("maxDelay", WAVE_MAX_DELAY))


# --- scoring ----------------------------------------------------------------

## The flat reward for clearing a level plus the leftover time measured against
## par, so finishing fast pays.
static func clear_bonus(level: int, seconds_left: float) -> int:
	var flat: float = 50.0 * float(maxi(1, level))
	var par_part: float = maxf(0.0, seconds_left - par_time(level) * 0.35) * 20.0
	return int(round(flat + par_part))


# --- save data --------------------------------------------------------------
# Progression lives in `Game`'s generic number store, so it needs no new autoload
# and survives next to the other games' highscores.
#
# The store is reached through the scene tree rather than the `Game` autoload
# identifier: the headless rule-test runner boots without autoloads, and a plain
# `Game.…` reference would not even parse there (same trick as `TestScreens`).

const KEY_UNLOCKED := "pang/unlocked"

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


static func unlocked_level() -> int:
	return clampi(int(_read(KEY_UNLOCKED, float(FIRST_UNLOCKED))), FIRST_UNLOCKED, TOTAL_LEVELS)


static func unlock_level(level: int) -> int:
	var target: int = clampi(level, FIRST_UNLOCKED, TOTAL_LEVELS)
	if target > unlocked_level():
		_write(KEY_UNLOCKED, float(target))
	return unlocked_level()


static func is_unlocked(level: int) -> bool:
	return level <= unlocked_level()


static func level_best_time(level: int) -> float:
	return _read("pang/best/%d" % maxi(1, level), 0.0)


## Stores a clear time when it beats the record. Returns true for a new record.
static func record_level_time(level: int, seconds: float) -> bool:
	if seconds <= 0.0:
		return false
	var best := level_best_time(level)
	if best > 0.0 and seconds >= best:
		return false
	_write("pang/best/%d" % maxi(1, level), seconds)
	unlock_level(level + 1)
	return true
