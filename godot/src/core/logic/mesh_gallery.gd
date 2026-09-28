class_name MeshGallery
extends RefCounted
## Layout and bookkeeping for the walk-in mesh gallery: pedestals in a ring, one
## mesh each, and a wall of signs that opens at any time.
## Everything deciding *where* something stands and *what* the final suggestion
## says lives here, so it can be unit tested without a viewport.

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
##
## A key, not a string: the line is handed to `Api.submit_suggestion` as the
## suggestion's origin and the player reads it back in the dashboard, so it has
## to be in their language. It was a hardcoded "Mesh-Galerie" — German in a
## source that is otherwise English, in no catalogue, and therefore the same
## German word for an English and a French player.
const CONTEXT_LOC_KEY := "gallery.context"

## The sentence the marked list is written into the draft under.
const DRAFT_LOC_KEY := "gallery.draft"

## Both keys above, in the array form the extractor recognises.
##
## The extractor reads a `…_LOC_KEYS` list, a `…_LOC_KEY` dictionary and a
## `Loc.t("…")` literal — and nothing else. A lone `const X_LOC_KEY := "ui.…"`
## matches none of the three, which is why `asset_registry.gd` and
## `suggestion_context.gd` each keep such a list next to the dictionary. A key
## that is never written down anywhere is a key nobody can find when it goes
## missing: `check` only reports the ones it can see in use.
const MESH_GALLERY_LOC_KEYS: Array[String] = [
	"gallery.context",
	"gallery.draft",
]

## The player's list of meshes to improve. It outlives the gallery screen,
## because it is the input to the suggestion written afterwards.
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


## Which pedestal is nearest `from`, or -1 when the player is too far from all.
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


## Remembers which detail level the player was looking at when marking it.
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

## The pre-filled suggestion body for the marked meshes. The player wrote the
## "what"; the gallery contributes the "which mesh, at which detail level, and
## why", so nobody has to spell out `rpg/dragon_lord` by hand.
static func draft(marks: Dictionary) -> String:
	var order: Array = marks.get("order", [])
	if order.is_empty():
		return ""
	var lines: Array[String] = []
	for key in order:
		var entry: Dictionary = (marks.get("entries", {}) as Dictionary).get(key, {})
		var tier := str(entry.get("tier", "low"))
	# The level the player was looking at is part of the complaint: a 10 000
	# triangle version of a bad shape is a different problem than a 400 triangle one.
		var head := Loc.f("%s — %s, level %s (%s triangles)", [
			AssetRegistry.display_name(key), key,
			AssetRegistry.tier_label(tier), AssetRegistry.tri_text(key, tier),
		])
		var note := str(entry.get("note", ""))
		lines.append("– %s" % head if note == "" else "– %s\n  %s" % [head, note])
	# The list is a whole sentence with the meshes in it, so it is one key with a
	# `{meshes}` placeholder rather than `Loc.f`: `Loc.f` looks the template up
	# in the `text` half of the catalogue, which is generated from the literals in
	# the code, and this one was a hardcoded German sentence that was in neither
	# half. `{name}` instead of `%s` because a translation may want the list
	# before the sentence.
	return Loc.t(DRAFT_LOC_KEY, {"meshes": "\n".join(lines)})


## The context the suggestion dialog shows for this screen, in the player's
## language.
static func context() -> String:
	return Loc.t(CONTEXT_LOC_KEY)


## How the gallery describes the detail levels, for the HUD.
static func tier_caption(tier: String) -> String:
	var label := AssetRegistry.tier_label(tier)
	var budget := int(AssetRegistry.TIER_BUDGET.get(tier, 0))
	if budget <= 0:
		return Loc.f("%s — the version the games use", [label])
	return Loc.f("%s — target: about %s triangles", [label, Ui.format_number(budget)])
