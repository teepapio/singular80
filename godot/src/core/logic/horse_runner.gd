class_name HorseRunner
extends RefCounted
## Logic for the 3D endless run "Pferde-Parcours 3D".
## Port of `src/game/horseRunner.ts`.

const LANE_COUNT := 3
const LANE_WIDTH := 2.6
const LANE_X := [-LANE_WIDTH, 0.0, LANE_WIDTH]
const PATH_HALF_WIDTH := LANE_WIDTH * 1.5 + 1.4

const HORSE_RADIUS := 0.62
const HORSE_HALF_LENGTH := 1.05

const GRAVITY := 30.0
const JUMP_SPEED := 10.6

const OBSTACLE_LOG := "log"
const OBSTACLE_ROCK := "rock"
const OBSTACLE_FENCE := "fence"

const OBSTACLE_SPECS: Array[Dictionary] = [
	{"kind": OBSTACLE_LOG, "asset": "log", "halfWidth": 1.05, "halfDepth": 0.42, "top": 0.74, "scale": 1.0},
	{"kind": OBSTACLE_ROCK, "asset": "rock", "halfWidth": 0.64, "halfDepth": 0.52, "top": 0.72, "scale": 1.0},
	{"kind": OBSTACLE_FENCE, "asset": "fence", "halfWidth": 1.15, "halfDepth": 0.22, "top": 1.02, "scale": 1.0},
]

const KINDS := [OBSTACLE_LOG, OBSTACLE_ROCK, OBSTACLE_FENCE]

# --- near misses ------------------------------------------------------------
## How close the two boxes may come (in world units) and still count as a graze.
## 0.5 is about a hoof: tight enough to feel risky, wide enough to reach with a
## normal lane change or a jump that is a heartbeat too late.
const GRAZE_MARGIN := 0.5

## Points the first graze of a chain pays; every further link pays again.
const GRAZE_POINTS := 25

## Metres a chain survives without a graze before it loses a link.
const CHAIN_HOLD := 70.0

## Verdicts of `pass_of`.
const PASS_CLEAR := "clear"
const PASS_HIT := "hit"
const PASS_NEAR := "near"


static func clamp_lane(lane: int) -> int:
	return clampi(lane, 0, LANE_COUNT - 1)


static func lane_x(lane: int) -> float:
	return float(LANE_X[clamp_lane(lane)])


## Difficulty ramps up over the first ~2200 m and then plateaus.
static func difficulty_at(distance: float) -> Dictionary:
	var t: float = clampf(distance / 2200.0, 0.0, 1.0)
	return {
		"speed": 15.0 + t * 19.0,
		"reaction": 1.35 - t * 0.62,
		"doubleChance": 0.12 + t * 0.5,
	}


static func obstacle_spec(kind: String) -> Dictionary:
	for spec in OBSTACLE_SPECS:
		if str(spec["kind"]) == kind:
			return spec
	return OBSTACLE_SPECS[0]


## World-unit gap before the next obstacle row; scales with speed so the player
## always gets roughly the same reaction time, plus a little jitter.
static func spawn_gap(difficulty: Dictionary) -> float:
	var jitter: float = 0.9 + randf() * 0.7
	return float(difficulty["speed"]) * float(difficulty["reaction"]) * jitter


## True when the horse box overlaps an obstacle box and its hooves are not high
## enough to clear it.
static func collides(horse_x: float, horse_feet_y: float, horse_z: float, obstacle_x: float, obstacle_z: float, spec: Dictionary) -> bool:
	if absf(horse_x - obstacle_x) >= float(spec["halfWidth"]) + HORSE_RADIUS:
		return false
	if absf(horse_z - obstacle_z) >= float(spec["halfDepth"]) + HORSE_HALF_LENGTH:
		return false
	return horse_feet_y < float(spec["top"]) - 0.04


## Highest hoof clearance of a jump with the given initial speed.
static func jump_apex(jump_speed: float = JUMP_SPEED, gravity: float = GRAVITY) -> float:
	return (jump_speed * jump_speed) / (2.0 * gravity)


## Hoof height `time` seconds into a jump. Below zero is before the take-off,
## so the answer is 0.0 — the way to ask "how high were the hooves when the
## obstacle arrived?" from a jump that was pressed `time` seconds earlier.
static func jump_height(time: float, jump_speed: float = JUMP_SPEED, gravity: float = GRAVITY) -> float:
	if time <= 0.0:
		return 0.0
	return jump_speed * time - gravity * time * time * 0.5


# --- near-miss rules --------------------------------------------------------

## Free world units between the horse box and an obstacle box, side by side.
## 0.0 means they just touch, negative means they overlap.
static func lateral_gap(horse_x: float, obstacle_x: float, spec: Dictionary) -> float:
	return absf(horse_x - obstacle_x) - (float(spec["halfWidth"]) + HORSE_RADIUS)


## How an obstacle went past the horse.
##
## `PASS_HIT` when it caught the horse, `PASS_NEAR` when the boxes came within
## `GRAZE_MARGIN` of each other and `PASS_CLEAR` for an uneventful pass. A graze
## counts in both directions: side by side on the same level, and over the top
## with only a whisker of clearance — the leading and the trailing edge of the
## window in which a jump clears the block at all. Flying over the middle of it
## is a clear pass and pays nothing, and so is riding along in the empty lane
## next to a block, which is a metre of daylight.
##
## The z-distance is deliberately not a parameter: the screen asks at the frame
## the obstacle crosses the horse, which is by definition the frame of the
## smallest z-distance and therefore the fairest moment to judge the pass.
static func pass_of(horse_x: float, horse_feet_y: float, obstacle_x: float, spec: Dictionary) -> String:
	var top: float = float(spec["top"])
	if collides(horse_x, horse_feet_y, 0.0, obstacle_x, 0.0, spec):
		return PASS_HIT
	# A negative gap means the boxes still overlap sideways — the horse is
	# straight above or below the block, so the height decides, not the side.
	# And a horse whose hooves are already over the top of the block flies
	# around it rather than past it, however narrow the lane felt.
	var gap: float = lateral_gap(horse_x, obstacle_x, spec)
	if gap >= 0.0 and gap <= GRAZE_MARGIN and horse_feet_y < top:
		return PASS_NEAR
	var clearance: float = horse_feet_y - top
	if clearance >= 0.0 and clearance <= GRAZE_MARGIN:
		return PASS_NEAR
	return PASS_CLEAR


## Points a graze pays when it brings the chain to `chain`. A chain therefore
## pays GRAZE_POINTS, then twice that, and so on.
static func chain_bonus(chain: int) -> int:
	return GRAZE_POINTS * maxi(1, chain)


## How many links a chain loses after `metres` without a graze. Losing one link
## per `CHAIN_HOLD` metres keeps the bonus something the player has to keep
## earning instead of a one-off gift.
static func chain_after(metres: float) -> int:
	return int(maxf(0.0, metres) / CHAIN_HOLD)
