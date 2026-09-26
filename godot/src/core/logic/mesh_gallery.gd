class_name MeshGallery
extends RefCounted
## Layout and bookkeeping for the walk-in mesh gallery.
##
## The gallery is a room the player walks through: pedestals in a ring, one mesh
## each, and a wall of signs that can be opened at any time. Everything that
## decides *where* something stands and *what* the final suggestion says lives
## here so it can be unit tested without a viewport.

# --- room -------------------------------------------------------------------

## Radius of the pedestal ring, and how high a pedestal is.
const RING_RADIUS := 13.0
const PEDESTAL_HEIGHT := 0.55
const PEDESTAL_RADIUS := 0.85

## How many pedestals one arc of the ring holds.
const ARC_SIZE := 12

## The player's own position in the middle of the room.
const CENTER := Vector3(0.0, 0.0, 0.0)

## Distance at which a pedestal counts as "the one in front of you".
const NEAR_DISTANCE := 4.2

# --- review list ------------------------------------------------------------

## The context line that ends up in front of a submitted suggestion.
const CONTEXT := "Mesh-Galerie"

## The player's list of meshes to improve. It outlives the gallery screen,
## because it is the input of the suggestion the player writes afterwards.
static var marks: Dictionary = {}


## The key of the pedestal at `index`, or `""` past the end of the page.
static func key_at(keys: Array[String], index: int) -> String:
	if index < 0 or index >= keys.size():
		return ""
	return keys[index]


## World position of pedestal `index`. The ring is walked clockwise from the
## south, so the first pedestal is straight ahead when entering.
static func pedestal_position(index: int) -> Vector3:
	var angle := TAU * float(index) / float(ARC_SIZE)
	return Vector3(cos(angle) * RING_RADIUS, PEDESTAL_HEIGHT * 0.5, sin(angle) * RING_RADIUS)


## Which pedestal is nearest to `from`, or -1 when the player is too far from
## every one of them.
static func nearest_pedestal(keys: Array[String], from: Vector3) -> int:
	var best := -1
	var best_distance := NEAR_DISTANCE
	for i in keys.size():
		var distance := from.distance_to(pedestal_position(i))
		if distance < best_distance:
			best_distance = distance
			best = i
	return best


## How many keys one page holds.
static func page_size(count: int) -> int:
	return count if count <= ARC_SIZE else ARC_SIZE


## How many pages a list of keys needs.
static func pages_for(count: int) -> int:
	if count <= 0:
		return 1
	return int(ceil(float(count) / float(ARC_SIZE)))


## The keys of one page.
static func page(keys: Array[String], index: int) -> Array[String]:
	var out: Array[String] = []
	if keys.is_empty():
		return out
	var per_page := page_size(keys.size())
	for i in range(index * per_page, mini((index + 1) * per_page, keys.size())):
		out.append(keys[i])
	return out


# --- review list ------------------------------------------------------------

## A fresh, empty mark list.
static func new_marks() -> Dictionary:
	return {"entries": {}, "order": []}


## The shared list, created on first use.
static func shared_marks() -> Dictionary:
	if marks.is_empty() or not marks.has("order"):
		marks = new_marks()
	return marks


## Replaces the shared list.
static func set_marks(value: Dictionary) -> void:
	marks = value


## Number of marked meshes.
static func mark_count(marks: Dictionary) -> int:
	return (marks.get("order", []) as Array).size()


## True when the mesh is on the list.
static func is_marked(marks: Dictionary, key: String) -> bool:
	return (marks.get("entries", {}) as Dictionary).has(key)


## The note stored for a mesh, empty when there is none.
static func mark_note(marks: Dictionary, key: String) -> String:
	return str((marks.get("entries", {}) as Dictionary).get(key, {}).get("note", ""))


## Adds a mesh to the list, or updates its note. Returns the new state.
static func mark(marks: Dictionary, key: String, note: String = "") -> Dictionary:
	if key == "" or not AssetRegistry.exists(key):
		return marks
	var entries: Dictionary = (marks.get("entries", {}) as Dictionary).duplicate(true)
	var order: Array = (marks.get("order", []) as Array).duplicate()
	if not entries.has(key):
		order.append(key)
	entries[key] = {"note": note.strip_edges(), "tier": "low"}
	return {"entries": entries, "order": order}


## Takes a mesh off the list. Returns the new state.
static func unmark(marks: Dictionary, key: String) -> Dictionary:
	var entries: Dictionary = (marks.get("entries", {}) as Dictionary).duplicate(true)
	var order: Array = (marks.get("order", []) as Array).duplicate()
	entries.erase(key)
	order.erase(key)
	return {"entries": entries, "order": order}


## Flips the mark and returns `{"marks": …, "marked": bool}`.
static func toggle(marks: Dictionary, key: String, note: String = "") -> Dictionary:
	if is_marked(marks, key):
		return {"marks": unmark(marks, key), "marked": false}
	return {"marks": mark(marks, key, note), "marked": true}


## Stores the note of a marked mesh. Returns the new state.
static func set_note(marks: Dictionary, key: String, note: String) -> Dictionary:
	if not is_marked(marks, key):
		return marks
	var entries: Dictionary = (marks.get("entries", {}) as Dictionary).duplicate(true)
	var entry: Dictionary = entries[key]
	entry["note"] = note.strip_edges()
	entries[key] = entry
	return {"entries": entries, "order": (marks.get("order", []) as Array).duplicate()}


## Remembers which detail level the player was looking at when they marked it.
static func set_tier(marks: Dictionary, key: String, tier: String) -> Dictionary:
	if not is_marked(marks, key):
		return marks
	var entries: Dictionary = (marks.get("entries", {}) as Dictionary).duplicate(true)
	var entry: Dictionary = entries[key]
	entry["tier"] = tier if tier in AssetRegistry.TIERS else "low"
	entries[key] = entry
	return {"entries": entries, "order": (marks.get("order", []) as Array).duplicate()}


## Removes every mark.
static func clear_marks() -> Dictionary:
	return new_marks()


# --- the suggestion ---------------------------------------------------------

## The pre-filled suggestion body for the marked meshes.
##
## The player wrote the "what"; the gallery contributes the "which mesh, at which
## detail level, and why", so nobody has to spell out `rpg/dragon_lord` by hand.
static func draft(marks: Dictionary) -> String:
	var order: Array = marks.get("order", [])
	if order.is_empty():
		return ""
	var lines: Array[String] = []
	for key in order:
		var entry: Dictionary = (marks.get("entries", {}) as Dictionary).get(key, {})
		var tier := str(entry.get("tier", "low"))
		# The level the player was looking at is part of the complaint: a 10 000
		# triangle version of a bad shape is a different problem than a 400
		# triangle one.
		var head := "%s — %s, Stufe %s (%s Dreiecke)" % [
			AssetRegistry.display_name(key), key,
			str(AssetRegistry.TIER_LABELS.get(tier, tier)), AssetRegistry.tri_text(key, tier),
		]
		var note := str(entry.get("note", ""))
		lines.append("– %s" % head if note == "" else "– %s\n  %s" % [head, note])
	return "Diese Meshes soll ich verbessern:\n%s" % "\n".join(lines)


## The context the suggestion dialog shows for this screen.
static func context() -> String:
	return CONTEXT


## How the gallery describes the detail levels, for the HUD.
static func tier_caption(tier: String) -> String:
	var label := str(AssetRegistry.TIER_LABELS.get(tier, tier))
	var budget := int(AssetRegistry.TIER_BUDGET.get(tier, 0))
	if budget <= 0:
		return "%s — die Fassung, die die Spiele benutzen" % label
	return "%s — Ziel: ca. %s Dreiecke" % [label, Ui.format_number(budget)]
