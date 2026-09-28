class_name MeshGallery
extends RefCounted
## Layout of the walk-in mesh gallery: one long hall with a row of pedestals on
## the left and one on the right, every mesh of the registry standing in one of
## them. The player walks straight ahead and looks at what passes on either
## side — no collections, no pages, nothing to choose.
##
## Everything deciding *where* a pedestal stands and *what* the suggestion says
## lives here, so it is unit tested without a viewport.

# --- the hall ---------------------------------------------------------------

## How far a row stands from the middle line, and how much room one pedestal
## needs between two neighbours.
const ROW_OFFSET := 4.2
const SLOT_SPACING := 4.6
const PEDESTAL_HEIGHT := 0.55
const PEDESTAL_RADIUS := 0.85

## Where the first pedestal stands. The hall grows towards **negative** z,
## because the camera trails the player at `+z` and pushing the stick forward
## walks into the screen.
const FIRST_SLOT_Z := 5.0

## Distance at which a pedestal counts as "the one you stand in front of".
##
## Wider than `ROW_OFFSET`, so that walking down the middle of the lane is
## already standing in front of a row — a player who never leaves the middle
## would otherwise never look at a mesh at all. At the wall it is still narrow
## enough that the pair of the next depth is clearly the farther one.
const NEAR_DISTANCE := 5.2

## The gap the player keeps to a pedestal, so the knight does not walk into it.
const PEDESTAL_GAP := 0.6

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


## World position of pedestal `index`. Two pedestals share a depth, one per side,
## and the next pair stands one spacing further down the hall.
static func slot_position(index: int) -> Vector3:
	var pair := index / 2
	return Vector3(
		float(side_of(index)) * ROW_OFFSET,
		PEDESTAL_HEIGHT * 0.5,
		-(FIRST_SLOT_Z + float(pair) * SLOT_SPACING)
	)


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


## The middle lane the player is kept in, as `(min x, max x)`.
static func lane_bounds() -> Vector2:
	var edge := ROW_OFFSET - PEDESTAL_RADIUS - PEDESTAL_GAP
	return Vector2(-edge, edge)


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
