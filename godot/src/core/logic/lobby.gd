class_name Lobby
extends RefCounted
## Layout of the walkable 3D lobby: a circular plaza with the game categories on
## a ring around a central campfire, one pedestal per game inside each plaza.
## Geometry lives here rather than in the scene, so it stays testable and the
## render code carries no magic numbers.

const LOBBY_WALK_RADIUS := 40.0
const CATEGORY_RING_RADIUS := 24.0
const ZONE_RADIUS := 10.0
const PEDESTAL_ORBIT := 3.6
const PEDESTAL_TRIGGER := 2.5
const MINIMAP_WORLD_RADIUS := LOBBY_WALK_RADIUS + 6.0

## The mesh gallery sits on the axis the player enters through, between hub and
## plaza ring, so it is the first thing they meet.
const GALLERY_DISTANCE := 13.0
const GALLERY_TRIGGER := 3.0


## One plaza per category, evenly on a ring. The first plaza sits north of the
## hub so the camera sees a plaza straight ahead.
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


## Pedestal offsets inside one plaza: a lone game stands at the centre, several
## form an even ring.
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


## Clamps a position into the walkable circle around the hub.
static func clamp_to_lobby(x: float, z: float, radius: float = LOBBY_WALK_RADIUS) -> Vector2:
	var length := sqrt(x * x + z * z)
	if length <= radius or length == 0.0:
		return Vector2(x, z)
	var scale := radius / length
	return Vector2(x * scale, z * scale)


## World position of the mesh gallery portal, a quarter turn from the first plaza.
static func gallery_position() -> Vector2:
	var layout := zone_layout()
	if layout.is_empty():
		return Vector2(0.0, -GALLERY_DISTANCE)
	var first: Dictionary = layout[0]
	var angle := atan2(float(first["z"]), float(first["x"]))
	# A quarter turn away from the first plaza: clearly separate, still central.
	return Vector2(cos(angle + PI * 0.5), sin(angle + PI * 0.5)) * GALLERY_DISTANCE


static func distance_sq(ax: float, az: float, bx: float, bz: float) -> float:
	var dx := ax - bx
	var dz := az - bz
	return dx * dx + dz * dz


## Projects a world position (x/z plane) onto minimap canvas pixels.
static func minimap_point(x: float, z: float, size: float, padding: float, world_radius: float) -> Vector2:
	var scale := (size * 0.5 - padding) / world_radius
	return Vector2(size * 0.5 + x * scale, size * 0.5 + z * scale)


# --- ground: grass, dirt paths, stone floors --------------------------------

## The lawn reaches this far. The player walks a circle of `LOBBY_WALK_RADIUS`
## and the camera looks a little past it, so the outer rings exist to keep the
## horizon from showing an edge — not to be walked on.
const GROUND_RADIUS := 130.0

## The lawn is a polar grid rather than a square one, and its rings are spaced
## with the square of their index: the fine rings land on the paths and the
## plazas, the coarse ones out at the horizon. A square grid fine enough at the
## middle to draw a path edge would carry forty times the triangles in order to
## describe ground the player never reaches.
const LAWN_RINGS := 40
const LAWN_SECTORS := 72

## How wide a dirt path is, and the disc they all meet in at the centre.
const PATH_WIDTH := 5.0
const PATH_CROSSING_RADIUS := 5.5
## A path stops where the thing it leads to begins, so that dirt meets the
## stone floor of a plaza instead of running underneath it.
const PATH_PLAZA_EDGE := CATEGORY_RING_RADIUS - ZONE_RADIUS

## The paths are decals laid on the lawn, and they cross each other by design:
## the ring runs under the spurs, the crossing disc under both. A hundredth of a
## unit of separation is well under a pixel from the lobby camera, and it
## removes the z-fighting that a single shared height would give.
const PATH_Y := 0.02
const SPOKE_Y := 0.04
const CROSSING_Y := 0.06

## The plaza platform's height, and the height its flagstones are laid at. The
## stones clear the top face for the same reason the paths clear the lawn.
const ZONE_PLATFORM_HEIGHT := 0.4
const FLAGSTONE_Y := ZONE_PLATFORM_HEIGHT + 0.02
const FLAGSTONE_CELL := 1.8
const FLAGSTONE_GAP := 0.12

## Ground colours, and the tones each surface is mottled in.
##
## Grass, stone and road carry the colours the settlers' island already uses for
## the same three surfaces, so the lobby and the map read as one world instead of
## as two palettes that happen to share a screen. Every surface is drawn in more
## than one tone and picked per vertex, because one flat colour over forty units
## of ground reads as paint rather than as grass.
const GRASS_TONES: Array[Color] = [Color("5c8f3a"), Color("527f33"), Color("679a44"), Color("486f2c")]
const DIRT_TONES: Array[Color] = [Color("6b5335"), Color("755b3c"), Color("614b2f")]
const STONE_TONES: Array[Color] = [Color("8b8d94"), Color("82848b"), Color("94969c"), Color("7a7c83")]
## What shows between the flagstones and covers the platform they are laid on:
## the joint, and the reason the stones are inset rather than butted together.
const STONE_JOINT := Color("4c4e54")


## The far end of every path, in the order the render code draws them: one per
## plaza, standing on that plaza's stone floor, and the mesh gallery in between.
static func path_targets() -> Array[Vector2]:
	var out: Array[Vector2] = []
	for zone in zone_layout():
		var centre := Vector2(float(zone["x"]), float(zone["z"]))
		if centre == Vector2.ZERO:
			continue
		out.append(centre.normalized() * PATH_PLAZA_EDGE)
	out.append(gallery_position())
	return out


## The radius within which `count` evenly spaced paths of `width` already cover
## the whole circle, and can therefore be swallowed by the crossing disc.
##
## A path is a rectangle rather than a wedge, so at radius `r` it covers an angle
## of `2·asin(width / 2r)`, and `count` of them close the circle once that is a
## full turn. This inverts that, and it is what keeps wedges of grass from
## showing between the spurs where they meet.
static func spoke_merge_radius(count: int, width: float) -> float:
	# Two is the smallest count that is still spread around the whole circle; one
	# path is a line, and a single line never covers anything but itself.
	if count < 2 or width <= 0.0:
		return 0.0
	return width / (2.0 * sin(PI / float(count)))


## Ring `index` of the lawn grid: index 0 is the centre, `rings` the rim.
static func lawn_ring_radius(index: int, rings: int = LAWN_RINGS, radius: float = GROUND_RADIUS) -> float:
	if rings <= 0:
		return 0.0
	return radius * pow(clampf(float(index) / float(rings), 0.0, 1.0), 2.0)


## A deterministic tone index in `[0, count)` from two grid coordinates.
##
## The lawn, the paths and the flagstones are mottled by picking a tone per
## vertex, and a test that compares two builds needs the same picks both times.
## `randi()` is seeded per run, so it would give a different lawn on every
## launch and a screenshot that never matches.
static func tone_pick(a: int, b: int, count: int) -> int:
	if count <= 1:
		return 0
	var n := (a * 374761393 + b * 668265263) & 0x7fffffff
	n = (n ^ (n >> 13)) * 1274126177
	return (n & 0x7fffffff) % count


static func grass_tone(a: int, b: int) -> Color:
	return GRASS_TONES[tone_pick(a, b, GRASS_TONES.size())]


static func dirt_tone(a: int, b: int) -> Color:
	return DIRT_TONES[tone_pick(a, b, DIRT_TONES.size())]


## The flagstones of one stone floor: a square grid clipped to the circle, each
## stone inset by `gap` so the joint shows between them.
##
## A cell is claimed by its whole extent, not by its centre: a cell whose centre
## sits on the rim has all four corners past it, and those corners would hang in
## the air beyond the platform. What is left over between the paving and the rim
## is bare joint, which reads as a border course — the other choice would be
## sixteen stones floating over the grass.
static func flagstone_cells(
	radius: float,
	cell: float = FLAGSTONE_CELL,
	gap: float = FLAGSTONE_GAP
) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if cell <= 0.0 or radius <= 0.0:
		return out
	var half := gap * 0.5
	var reach := cell * 0.5 * sqrt(2.0)
	var steps := ceili(radius / cell)
	for row in range(-steps, steps + 1):
		for column in range(-steps, steps + 1):
			var centre := Vector2(float(column) * cell, float(row) * cell)
			if centre.length() + reach > radius:
				continue
			out.append({
				"x0": centre.x - cell * 0.5 + half,
				"z0": centre.y - cell * 0.5 + half,
				"x1": centre.x + cell * 0.5 - half,
				"z1": centre.y + cell * 0.5 - half,
				"tone": tone_pick(column, row, STONE_TONES.size()),
			})
	return out
