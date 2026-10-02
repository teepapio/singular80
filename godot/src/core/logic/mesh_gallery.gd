class_name MeshGallery
extends RefCounted
## Layout of the walk-in mesh gallery: a hall with rows of pedestals on either
## side, every mesh of the registry standing in one of them. The player walks
## the nave between them and can step into an aisle in front of every row, so
## the outermost row is as reachable as the innermost one — no collections, no
## pages, nothing to choose.
##
## Everything deciding *where* a pedestal stands and *what* the suggestion says
## lives here, so it is unit tested without a viewport.

# --- the hall ---------------------------------------------------------------

## How many rows stand on each side of the nave, and how many pedestals that
## makes per step down the hall.
##
## Five per side are ten rows in all, which is what a player asked for after
## walking past four. Ten per depth makes the hall 2.5 times as full at every
## step and a quarter shorter (188 m → 165 m measured), so it is the faster walk
## that keeps the tour short, not a smaller collection.
const ROWS_PER_SIDE := 5
const PER_STEP := 2 * ROWS_PER_SIDE

## How far each row stands from the middle line, and how much room one pedestal
## needs between two neighbours.
##
## The rows keep the lateral distance they had. It is the tightest gap in the
## hall and the one that has to hold a mesh ninety per cent bigger, so it is the
## one distance that cannot grow: at 2.2 times this the hall would be 88 m wide,
## the outermost rows would stand 40 m to the side where the camera and the fog
## cannot reach them, and the streaming window would have to hold three times the
## triangles. The extra distance a player asked for therefore went into
## `SLOT_SPACING`, which is the distance they actually walk.
const ROW_SPACING := 4.2
const INNER_ROW_OFFSET := 2.8
const OUTER_ROW_OFFSET := 19.6
const SLOT_SPACING := 10.12
const PEDESTAL_HEIGHT := 0.55
const PEDESTAL_RADIUS := 0.85

## The row offsets as a list, because the aisles are derived from them. A `const`
## array costs nothing to read — it is walked, never rebuilt — which matters for
## `lane_x`, that runs every frame the stick is moved.
const ROW_OFFSETS: Array[float] = [2.8, 7.0, 11.2, 15.4, 19.6]

## How much floor the walls keep behind the outermost row.
const WALL_MARGIN := 3.2

## Where the first pedestal stands. The hall grows towards **negative** z,
## because the camera trails the player at `+z` and pushing the stick forward
## walks into the screen.
const FIRST_SLOT_Z := 5.0

## The gap the player keeps to a pedestal, so the knight does not walk into it,
## and with it the width of the closed band around every pedestal.
const PEDESTAL_GAP := 0.6
const CLEAR := PEDESTAL_RADIUS + PEDESTAL_GAP

## Distance at which a pedestal counts as "the one you stand in front of".
##
## Every row has one aisle a `CLEAR` short of it — the nave is the aisle in
## front of the inner row — so a player standing in an aisle is `CLEAR` from the
## row it belongs to and `ROW_SPACING - CLEAR` from the next one, and
## `nearest_slot` picks the closer of the two. The number that has to be covered
## is the depth, though: the player crosses half a `SLOT_SPACING` between two
## depths, and from the middle of the nave the nearest pedestal is then
## `sqrt(INNER_ROW_OFFSET² + (SLOT_SPACING/2)²)` = 5.78 m away. The old 5.2 m
## left a dead zone every ten metres where nothing was selected and the info card
## flickered. 5.8 m closes it and costs nothing in precision, because the row a
## player means is always the nearest one.
const NEAR_DISTANCE := 5.8

## The walkable floor: the nave in front of the inner row, then one aisle in
## front of every row behind it. The outer row is read from its own aisle, which
## is a `CLEAR` short of it and therefore closer to it than to anything else.
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


## Which row of its side a pedestal stands in: 0 is the one nearest the nave.
##
## The two pedestals of a row stand next to each other across the hall, so a
## row takes the even slots on the left and the odd ones on the right.
static func row_of(index: int) -> int:
	return (index % PER_STEP) / 2


## World position of pedestal `index`. `PER_STEP` pedestals share a depth — one
## per row and side — and the next set stands one spacing further down the hall.
static func slot_position(index: int) -> Vector3:
	var step := index / PER_STEP
	var side := float(side_of(index))
	return Vector3(
		side * ROW_OFFSETS[row_of(index)],
		PEDESTAL_HEIGHT * 0.5,
		-(FIRST_SLOT_Z + float(step) * SLOT_SPACING)
	)


## How far `z` is from the depth of a row, in metres.
##
## Zero where the pedestals stand, half a step in the gap between two depths —
## and that gap is the only place the player gets from one aisle into the next.
## Infinite before the first row, where the floor is open. It is also wide
## enough to cross comfortably now: `SLOT_SPACING` doubled the gap between two
## depths from 1.7 m of open floor to 7.2 m, so the crossing is no longer the
## squeeze in the hall.
static func depth_gap(z: float) -> float:
	var beyond := -z - FIRST_SLOT_Z
	if beyond < 0.0:
		return INF
	return absf(beyond - roundf(beyond / SLOT_SPACING) * SLOT_SPACING)


## The x row `row` is read from: one `CLEAR` short of it, so the row an aisle
## belongs to is always nearer than the one behind it.
static func lane_of(row: int) -> float:
	return ROW_OFFSETS[row] - CLEAR


## The x the player ends up at, having wanted `x` at `z` and come from `was_x`.
##
## The hall is a nave with an aisle in front of every row, and every row closes
## off the ground in front of it. So the player crosses that band only where the
## pedestals leave a gap, and a player already in an aisle walks on — which is
## what makes the outer rows reachable at all: from a fixed spot the nearer row
## is the nearer one from everywhere, and no distance can make a far row the
## mesh in front of them while the near row stands between.
static func lane_x(want: float, z: float, was_x: float) -> float:
	var x := clampf(want, -LANE_SIDE, LANE_SIDE)
	if depth_gap(z) >= CLEAR:
		return x
	# The bands are the gaps *between* two aisles, and they are measured with
	# `lane_of()` rather than with `ROW_OFFSETS[row] ± CLEAR`: those are two
	# different subtractions, and they land a rounding error apart, so a player
	# standing exactly on an aisle fell inside the band and was pushed one row
	# further in. An aisle is an endpoint of the two bands around it and belongs
	# to neither.
	var reach := absf(x)
	for band in ROWS_PER_SIDE - 1:
		var near: float = lane_of(band)
		var far: float = lane_of(band + 1)
		if reach <= near or reach >= far:
			continue
		# Caught in a closed band. Push out into the neighbouring aisle, on the
		# side the player came from, so nobody standing in the nave is yanked
		# across the hall.
		var was := absf(was_x)
		var target := near
		if was >= far or (was > near and absf(was - far) < absf(was - near)):
			target = far
		return signf(x) * target
	return x


## How wide the hall is: the outermost row plus the floor the walls stand on.
static func hall_half_width() -> float:
	return ROW_OFFSETS[ROWS_PER_SIDE - 1] + WALL_MARGIN


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
