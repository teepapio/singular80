class_name Lobby
extends RefCounted
## Layout of the walkable 3D lobby: a circular plaza with the game categories on
## a ring, one pedestal per game inside each plaza, and an open crossing in the
## middle — no disc, no props, nothing to walk to. Geometry lives here rather
## than in the scene, so it stays testable and the render code carries no magic
## numbers.

const LOBBY_WALK_RADIUS := 40.0
const CATEGORY_RING_RADIUS := 24.0
const ZONE_RADIUS := 10.0
const PEDESTAL_ORBIT := 3.6
const PEDESTAL_TRIGGER := 2.5
const MINIMAP_WORLD_RADIUS := LOBBY_WALK_RADIUS + 6.0

## The plinth a game stands on: a cylinder 0.8 high whose top face carries the
## game's mesh and whose outer edge carries the accent rim.
const PEDESTAL_TOP := 1.1
const PEDESTAL_RIM_INNER := 1.05
const PEDESTAL_RIM_OUTER := 1.22
## Largest axis a pedestal mesh may reach. The rim is 2.44 wide, so an object
## that fits under 1.8 leaves it visible from every angle instead of hiding the
## game's colour under itself.
const PEDESTAL_MESH_SIZE := 1.8

## The mesh gallery sits on the axis the player enters through, between the
## crossing and the plaza ring, so it is the first thing they meet.
const GALLERY_DISTANCE := 13.0
const GALLERY_TRIGGER := 3.0

## Scenery ringing the lobby beyond the plazas: `count` objects of `key` placed
## at a random angle and a random radius in `[minR, maxR]`, scaled into
## `[minS, maxS]`.
##
## Every entry starts beyond the plazas, which reach `CATEGORY_RING_RADIUS +
## ZONE_RADIUS`. The band inside the plazas — the crossing, the open ground
## between the ring and the centre — used to hold rocks, bushes, grass and
## mushrooms as well: thirty-eight objects scattered across the way the player
## walks in, and the reason the middle read as an area instead of a way through
## one. Nothing goes there now.
const SCENERY: Array[Dictionary] = [
	{"key": "rpg/pine_tree", "count": 10, "minR": 36.0, "maxR": 45.0, "minS": 1.0, "maxS": 1.8},
	{"key": "rpg/dead_tree", "count": 6, "minR": 36.0, "maxR": 45.0, "minS": 1.0, "maxS": 1.7},
	{"key": "rpg/broken_pillar", "count": 5, "minR": 36.0, "maxR": 45.0, "minS": 1.0, "maxS": 1.6},
]

## What a game without a mesh of its own stands on.
const DEFAULT_TOTEM := "rpg/crystal_cluster"

## The mesh that stands on each game's pedestal, keyed by registry id.
##
## Every pedestal used to carry the same crystal, tinted in the game's accent
## colour, so the lobby showed eighteen coloured copies of one object and the
## only way to learn what a plinth held was to walk up to it and read the panel.
## Each entry is chosen for its silhouette: a horse is a horse course, a castle is
## a settlers' map, a bonbon is a candy crush, an orb is a Pang ball. A card
## game has no card mesh in the bundle — `rpg/scroll` and `rpg/key` are the two
## closest flat objects, and a real card would be worth building.
const TOTEMS: Dictionary = {
	"arena": "rpg/greatsword",
	"tetris": "rpg/crate",
	"poker": "rpg/scroll",
	"freecell": "rpg/key",
	"dame": "rpg/coin",
	"crystal3d": "crystal",
	"crystal3d-christmas": "xmas_bauble",
	"crystal3d-halloween": "pumpkin",
	"merge3d-christmas": "xmas_candy_cane",
	"merge3d-halloween": "halloween_pumpkin",
	"horserunner": "horse",
	"dragonrpg": "rpg/dragon_lord",
	"dragonflight": "flight/egg",
	"pang": "pang/orb",
	"metro3d": "metro/loco",
	"2048": "rpg/rune_stone",
	"candy3d": "candy/bonbon",
	"siedler": "siedler/castle",
}


## The mesh a game is represented by, and a usable one for an id the table does
## not know — a new registry entry shows up on its plinth before anyone remembers
## to give it a silhouette.
static func totem_of(game_id: String) -> String:
	return str(TOTEMS.get(game_id, DEFAULT_TOTEM))


## Registry games with no mesh of their own, `[]` once the table is complete.
## Keys the bundle does not ship are caught by the same test against
## `AssetRegistry.KEYS`.
static func missing_totems() -> Array[String]:
	var out: Array[String] = []
	for game in GameRegistry.GAMES:
		var id := str(game.get("id", ""))
		if not TOTEMS.has(id):
			out.append(id)
	return out


## Totem keys that are not bundled meshes, so a plinth falls back instead of
## showing nothing. The table maps game id to mesh, so it is the values that are
## checked — comparing the ids against `AssetRegistry.KEYS` reports every entry.
static func unknown_totems() -> Array[String]:
	var out: Array[String] = []
	for id in TOTEMS:
		var key := str(TOTEMS[id])
		if not (key in AssetRegistry.KEYS):
			out.append(key)
	out.sort()
	return out


## Scenery keys that reach into the crossing or onto a plaza, `[]` while the
## middle stays empty.
##
## The bound is the outer edge of the plaza ring: `minR` below it puts an object
## in the open ground the player walks across on the way in, which is what made
## the middle look like an area with things in it rather than a way through.
static func scenery_in_the_middle() -> Array[String]:
	var out: Array[String] = []
	var bound := CATEGORY_RING_RADIUS + ZONE_RADIUS
	for spec in SCENERY:
		if float(spec["minR"]) < bound:
			out.append(str(spec["key"]))
	out.sort()
	return out


## One plaza per category, evenly on a ring. The first plaza sits north of the
## crossing so the camera sees a plaza straight ahead.
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


## Clamps a position into the walkable circle around the crossing.
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
