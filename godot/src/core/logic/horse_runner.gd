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
