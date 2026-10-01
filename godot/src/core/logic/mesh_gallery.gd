class_name MeshGallery
extends RefCounted
## Layout of the walk-in mesh gallery: a hall with two rows of pedestals on
## either side, every mesh of the registry standing in one of them. The player
## walks the nave between them and can step into the aisle on either side, so
## the outer row is as reachable as the inner one — no collections, no pages,
## nothing to choose.
##
## Everything deciding *where* a pedestal stands and *what* the suggestion says
## lives here, so it is unit tested without a viewport.

# --- the hall ---------------------------------------------------------------

## How many rows stand on each side of the nave, and how many pedestals that
## makes per step down the hall. Two rows per side keep the hall half as long
## for the same number of meshes.
const ROWS_PER_SIDE := 2
const PER_STEP := 2 * ROWS_PER_SIDE

## How far the inner and the outer row stand from the middle line, and how much
## room one pedestal needs between two neighbours.
const INNER_ROW_OFFSET := 2.8
const OUTER_ROW_OFFSET := 7.0
const SLOT_SPACING := 4.6
const PEDESTAL_HEIGHT := 0.55
const PEDESTAL_RADIUS := 0.85

## Where the first pedestal stands. The hall grows towards **negative** z,
## because the camera trails the player at `+z` and pushing the stick forward
## walks into the screen.
const FIRST_SLOT_Z := 5.0

## Distance at which a pedestal counts as "the one you stand in front of".
##
## Wider than every gap the player can stand in — the nave to the inner row and
## the aisle to the outer one — so a mesh is never there, close enough to read,
## without being the one in front of them.
const NEAR_DISTANCE := 5.2

## The gap the player keeps to a pedestal, so the knight does not walk into it,
## and with it the width of the closed band around every pedestal.
const PEDESTAL_GAP := 0.6
const CLEAR := PEDESTAL_RADIUS + PEDESTAL_GAP

## The three bands of the walkable floor: the nave between the inner rows, the
## band the inner pedestals close off, and the aisle between the two rows.
const LANE_MID := INNER_ROW_OFFSET - CLEAR
const BAND_EDGE := INNER_ROW_OFFSET + CLEAR
const LANE_SIDE := OUTER_ROW_OFFSET - CLEAR

# --- the suggestion ---------------------------------------------------------

## The context line that ends up in front of a submitted suggestion.
##
## A key, not a string: the line is handed to `Api.submit_suggestion` as the
## suggestion's origin and the player reads it back in the dashboard, so it has
## to be in their language. It was a hardcoded "Mesh-Galerie" — German in a
## source that is otherwise English, in no catalogue, and therefore the same
## German word for an English and a French player.
const CONTEXT_LOC_KEY := "gallery.context"

## That key in the array form the extractor recognises.
##
## The extractor reads a `…_LOC_KEYS` list, a `…_LOC_KEY` dictionary and a
## `Loc.t("…")` literal — and nothing else. A lone `const X_LOC_KEY := "ui.…"`
## matches none of the three, which is why `asset_registry.gd` and
## `suggestion_context.gd` each keep such a list next to the dictionary. A key
## that is never written down anywhere is a key nobody can find when it goes
## missing: `check` only reports the ones it can see in use.
const MESH_GALLERY_LOC_KEYS: Array[String] = [
	"gallery.context",
]


## The key of pedestal `index`, or `""` past the end of the hall.
static func key_at(keys: Array[String], index: int) -> String:
	if index < 0 or index >= keys.size():
		return ""
	return keys[index]


## Which side of the hall a pedestal stands on: -1 is left, 1 is right.
##
## The rows alternate, so two neighbours are never both on the same side and a
## mesh on the left is answered by one on the right.
static func side_of(index: int) -> int:
	return 1 if index % 2 == 1 else -1


## World position of pedestal `index`. Four pedestals share a depth — two per
## side, inner and outer — and the next set of four stands one spacing further
## down the hall.
static func slot_position(index: int) -> Vector3:
	var step := index / PER_STEP
	var in_step := index % PER_STEP
	var side := float(side_of(index))
	var offset := INNER_ROW_OFFSET if in_step < 2 else OUTER_ROW_OFFSET
	return Vector3(
		side * offset,
		PEDESTAL_HEIGHT * 0.5,
		-(FIRST_SLOT_Z + float(step) * SLOT_SPACING)
	)


## How far `z` is from the depth of an inner row, in metres.
##
## Zero where the inner pedestals stand, half a step in the gap between two
## depths — that gap is the only place the player gets from the nave into the
## aisle. Infinite before the first row, where the floor is open.
static func depth_gap(z: float) -> float:
	var beyond := -z - FIRST_SLOT_Z
	if beyond < 0.0:
		return INF
	return absf(beyond - roundf(beyond / SLOT_SPACING) * SLOT_SPACING)


## The x the player ends up at, having wanted `x` at `z` and come from `was_x`.
##
## The hall is a nave with an aisle on either side, and the inner row closes off
## the ground between them. So the player crosses that band only where the inner
## pedestals leave a gap, and a player already in the aisle walks on — which is
## what makes the outer row reachable at all: from a fixed spot the nearer
## pedestal is the nearer one from everywhere, and no distance can make the far
## row the mesh in front of them while the near row stands between.
static func lane_x(want: float, z: float, was_x: float) -> float:
	var x := clampf(want, -LANE_SIDE, LANE_SIDE)
	if depth_gap(z) >= CLEAR or absf(x) >= BAND_EDGE:
		return x
	# Caught in the closed band. Push out towards the side the player came from,
	# so nobody standing in the nave is yanked across the hall.
	if absf(was_x) >= BAND_EDGE:
		return signf(was_x) * BAND_EDGE
	return signf(x) * LANE_MID


## Which pedestal is nearest `from`, or -1 when the player is too far from all.
static func nearest_slot(keys: Array[String], from: Vector3) -> int:
	var best := -1
	var best_distance := NEAR_DISTANCE
	for i in keys.size():
		var distance := from.distance_to(slot_position(i))
		if distance < best_distance:
			best_distance = distance
			best = i
	return best


## How deep the hall is for `count` meshes: the z of the last pedestal.
static func end_z(count: int) -> float:
	return slot_position(maxi(count - 1, 0)).z


## Where the player may walk, as `(min z, max z)`. The entrance end gets a
## little room behind the first pedestal, the far end stops one step short of
## the last one.
static func walk_bounds(count: int) -> Vector2:
	return Vector2(end_z(count) - SLOT_SPACING * 0.5, FIRST_SLOT_Z + 2.5)


# --- the suggestion ---------------------------------------------------------

## The context the suggestion dialog shows for this screen, in the player's
## language. With a mesh in front of the player the name rides along, so nobody
## has to spell out `rpg/dragon_lord` in the text itself.
static func context(key: String = "") -> String:
	var label := Loc.t(CONTEXT_LOC_KEY)
	if key == "":
		return label
	return "%s · %s" % [label, Loc.resolve(AssetRegistry.display_name(key))]


## How the gallery describes the detail levels, for the HUD.
static func tier_caption(tier: String) -> String:
	var label := AssetRegistry.tier_label(tier)
	var budget := int(AssetRegistry.TIER_BUDGET.get(tier, 0))
	if budget <= 0:
		return Loc.f("%s — the version the games use", [label])
	return Loc.f("%s — target: about %s triangles", [label, Ui.format_number(budget)])
