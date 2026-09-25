class_name Lobby
extends RefCounted
## Layout of the walkable 3D lobby.
## Port of `src/game/lobby.ts`.
##
## The lobby is a circular plaza: game categories sit on a ring around a central
## campfire, and each category plaza holds one pedestal per game. Keeping the
## geometry here (instead of in the scene) keeps it testable and free of magic
## numbers in the render code.

const LOBBY_WALK_RADIUS := 40.0
const CATEGORY_RING_RADIUS := 24.0
const ZONE_RADIUS := 10.0
const PEDESTAL_ORBIT := 3.6
const PEDESTAL_TRIGGER := 2.5
const MINIMAP_WORLD_RADIUS := LOBBY_WALK_RADIUS + 6.0


## One plaza per category, evenly distributed on a ring. The first plaza sits
## at the "north" side of the hub so the camera sees a plaza straight ahead.
static func zone_layout() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var count := GameRegistry.CATEGORIES.size()
	for index in count:
		var category: Dictionary = GameRegistry.CATEGORIES[index]
		var angle := (float(index) / float(count)) * TAU - PI * 0.5
		out.append({
			"category": category,
			"x": cos(angle) * CATEGORY_RING_RADIUS,
			"z": sin(angle) * CATEGORY_RING_RADIUS,
			"games": GameRegistry.games_in_category(str(category["id"])),
		})
	return out


## Offsets of the pedestals inside one plaza: a single game stands at the
## centre, several games form an even ring.
static func pedestal_offsets(count: int, orbit: float = PEDESTAL_ORBIT) -> Array[Vector2]:
	var offsets: Array[Vector2] = []
	if count <= 0:
		return offsets
	if count == 1:
		offsets.append(Vector2.ZERO)
		return offsets
	for i in count:
		var angle := (float(i) / float(count)) * TAU
		offsets.append(Vector2(cos(angle) * orbit, sin(angle) * orbit))
	return offsets


## Clamps a position to the walkable circle around the hub.
static func clamp_to_lobby(x: float, z: float, radius: float = LOBBY_WALK_RADIUS) -> Vector2:
	var length := sqrt(x * x + z * z)
	if length <= radius or length == 0.0:
		return Vector2(x, z)
	var scale := radius / length
	return Vector2(x * scale, z * scale)


static func distance_sq(ax: float, az: float, bx: float, bz: float) -> float:
	var dx := ax - bx
	var dz := az - bz
	return dx * dx + dz * dz


## Projects a world position (x/z plane) onto minimap canvas pixels.
static func minimap_point(x: float, z: float, size: float, padding: float, world_radius: float) -> Vector2:
	var scale := (size * 0.5 - padding) / world_radius
	return Vector2(size * 0.5 + x * scale, size * 0.5 + z * scale)
