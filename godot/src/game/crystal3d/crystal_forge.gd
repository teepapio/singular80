class_name CrystalForge
extends RefCounted
## The Crystal Jumper's bag: the crystals a climb hands over, kept per theme and
## merged here — three of a tier become one of the next — instead of only on the
## summit panel at the end of a run.
##
## Why this exists at all: `crystal_jumper_screen.gd` starts every climb with an
## empty `counts` array and throws it away when the run ends, so merging was a
## button on a panel a player meets once per finished tower. The bag is per
## theme, survives between runs and is what `crystal_forge_screen.gd` shows.
##
## Storage is `Game.set_number`, the same place the jumper keeps the equipped
## tier and the best chain: one number per tier, no save format of its own. A
## finished climb hands its crystals over with `deposit()`, which is the one call
## it needs.
##
## Renderer-free, like every other logic class: the screen owns the forge
## geometry and the merge animation, this owns the numbers.

## How many crystals of a tier make one of the next.
const MERGE_RULE := 3

## Screen the forge returns to, per theme. The router's payload may name another
## one; this is the fallback for a screen opened without a payload.
const CLIMB_SCREEN := {
	"classic": "crystal3d",
	"christmas": "crystal3d_christmas",
	"halloween": "crystal3d_halloween",
}

## Whether writes reach the player file. Off under `--script`, for the reason
## `Loc.persist` gives: a headless suite that saved the config would hand the
## developer who ran it a game whose settings the run had overwritten.
static var persist := not OS.get_cmdline_args().has("--script")


# --- keys -------------------------------------------------------------------

## The storage prefix of a theme, e.g. `singular80_crystal3d`. An unknown id
## falls back to the classic theme rather than throwing: the router hands this
## screen a payload, and a payload from an older build may name a theme that is
## gone.
static func prefix(theme_id: String) -> String:
	return str(CrystalTower.theme_by_id(theme_id)["keyPrefix"])


## Player-file key of one tier of one theme's bag.
static func bag_key(theme_id: String, tier: int) -> String:
	return "%s_bag%d" % [prefix(theme_id), clampi(tier, 1, CrystalTower.MAX_CRYSTAL_TIER)]


## Player-file key of the equipped crystal, shared with the jumper.
static func equip_key(theme_id: String) -> String:
	return "%s_equipped" % prefix(theme_id)


static func climb_screen(theme_id: String) -> String:
	return str(CLIMB_SCREEN.get(theme_id, "crystal3d"))


# --- counts -----------------------------------------------------------------

## A bag with nothing in it: one entry per tier, all zero.
static func empty() -> Array:
	var counts: Array = []
	counts.resize(CrystalTower.MAX_CRYSTAL_TIER)
	for i in counts.size():
		counts[i] = 0
	return counts


## A bag holding exactly `counts`, padded or cut to the number of tiers.
static func normalize(counts: Array) -> Array:
	var out := empty()
	for tier in range(1, CrystalTower.MAX_CRYSTAL_TIER + 1):
		out[tier - 1] = count_of(counts, tier)
	return out


## Crystals of one tier in a bag. A missing, short or negative entry reads as
## "none" — the screen must never have to defend itself against a hand-edited
## player file.
static func count_of(counts: Array, tier: int) -> int:
	if tier < 1 or tier > counts.size():
		return 0
	return maxi(0, int(counts[tier - 1]))


## Crystals in the bag, summed over every tier.
static func total(counts: Array) -> int:
	var sum := 0
	for value in counts:
		sum += maxi(0, int(value))
	return sum


## Points the bag is worth — the same price per tier the run score uses.
static func value(counts: Array) -> int:
	return CrystalTower.inventory_value(counts)


# --- storage ----------------------------------------------------------------

## The player's bag for a theme. An empty bag when there is no `Game` to ask,
## which is the case in a `--script` run: autoloads are not registered there.
##
## Not called `load()`: that is the engine's global resource loader, and a class
## function of that name does not win. Measured on 2026-10-01 — every `:=` in
## `deposit()` and `equip()` inferred `Resource` from the global instead of the
## declared `Array`, and the file refused to parse with six errors that all
## pointed at the indexing two lines further down.
static func load_bag(theme_id: String) -> Array:
	var game := _game()
	var counts := empty()
	if game == null:
		return counts
	for tier in range(1, CrystalTower.MAX_CRYSTAL_TIER + 1):
		var raw: float = float(game.call("get_number", bag_key(theme_id, tier), 0.0))
		counts[tier - 1] = maxi(0, int(raw)) if is_finite(raw) else 0
	return counts


## Writes a bag back. Nothing is written when persistence is off.
static func store_bag(theme_id: String, counts: Array) -> void:
	if not persist:
		return
	var game := _game()
	if game == null:
		return
	var clean := normalize(counts)
	for tier in range(1, CrystalTower.MAX_CRYSTAL_TIER + 1):
		game.call("set_number", bag_key(theme_id, tier), float(clean[tier - 1]))


## Adds a climb's crystals to the bag and returns the bag as it is afterwards.
## This is the one call a finished run needs: everything a climb found is kept
## instead of disappearing with the screen.
static func deposit(theme_id: String, counts: Array) -> Array:
	var bag := load_bag(theme_id)
	for tier in range(1, CrystalTower.MAX_CRYSTAL_TIER + 1):
		bag[tier - 1] = int(bag[tier - 1]) + count_of(counts, tier)
	store_bag(theme_id, bag)
	return bag


## The equipped crystal of a theme (0 = none).
static func equipped_tier(theme_id: String) -> int:
	var game := _game()
	if game == null:
		return 0
	var raw: float = float(game.call("get_number", equip_key(theme_id), 0.0))
	return clampi(int(raw), 0, CrystalTower.MAX_CRYSTAL_TIER) if is_finite(raw) else 0


## Takes one crystal of `tier` out of the bag and equips it, which is what the
## jump and speed bonuses in the tower hang on. Reports the tier now equipped, or
## the one already equipped when the bag had none left to give — an equip is
## never free.
static func equip(theme_id: String, tier: int) -> int:
	var target := clampi(tier, 1, CrystalTower.MAX_CRYSTAL_TIER)
	var bag := load_bag(theme_id)
	if count_of(bag, target) <= 0:
		return equipped_tier(theme_id)
	bag[target - 1] = count_of(bag, target) - 1
	store_bag(theme_id, bag)
	var game := _game()
	if game != null and persist:
		game.call("set_number", equip_key(theme_id), float(target))
	return target


static func _game() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null("Game")


# --- merging ----------------------------------------------------------------

## The full merge cascade for a bag: three of a tier become one of the next,
## repeatedly, from the lowest tier up. `steps` lists the single merges so the
## scene can play them one by one; `counts` is the bag afterwards.
static func merge(counts: Array) -> Dictionary:
	var plan := CrystalTower.plan_merges(normalize(counts))
	return {"counts": plan["counts"], "steps": plan["steps"], "merges": int(plan["merges"])}


## How many crystals one press of the merge button produces; 0 disables it.
static func mergeable(counts: Array) -> int:
	return int(merge(counts)["merges"])