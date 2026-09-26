class_name Siedler
extends RefCounted
## Rules of "Siedler 3D" — a tribute to *Die Siedler* (Blue Byte, Amiga 1993).
##
## Pure logic, no nodes and no scene tree: the screen builds the 3D world from
## the arrays below and feeds user actions back in. Same split as `metro.gd` and
## `dragon_rpg.gd`, so the whole economy stays unit-testable.
##
## What it reproduces from the original:
##
##  - **The flag/road relay network.** Goods never travel "to the consumer"
##    directly. Flags (Fahnen) are transport hubs, a road segment between two
##    flags is worked by carriers that each carry exactly one item, and an item
##    is *handed over* at every flag to the next carrier. This is the mechanic
##    the series was invented around: the more flags you put on a road, the more
##    carriers share the load, the shorter each walk, the higher the throughput.
##    Too few flags and goods pile up.
##  - **Production chains** as documented for Siedler 1 — logs → planks,
##    grain → flour → bread, ore + coal → iron, iron + wood → *tools*.
##  - **Tools gate labour.** A building only runs when a settler stands there
##    *holding the right tool*, which the Schlosserei forges from 1 iron + 1 wood.
##  - **Miners eat**, and an unfed settlement grinds to a halt.
##  - **Territory via military buildings.** A watchtower only expands your
##    territory while garrisoned, and knights are armed by the blacksmith.
##
## Deliberate improvements over the 1993 original, whose steep learning curve
## and invisible state were its most common criticisms: every building reports
## *why* it is idle, a good nobody consumes is flagged instead of silently
## congesting, roads report their throughput, and the *Ratgeber* turns all of it
## into one ranked answer — which building is starved of which good, and what
## the player should do about it.

# --- goods ------------------------------------------------------------------

## The nine tools of the Schlosserei, each forged from 1 iron + 1 wood.
const TOOLS: Array[String] = [
	"shovel", "hammer", "rod", "scythe", "cleaver", "axe", "saw", "pickaxe", "pliers",
]

## Everything a settler can eat.
const FOODS: Array[String] = ["bread", "fish", "ham"]

const GOODS: Array[String] = [
	"logs", "planks", "stone", "grain", "flour", "bread", "fish", "pork", "ham",
	"coal", "ironOre", "iron", "goldOre", "goldBar", "sword", "shield",
	"shovel", "hammer", "rod", "scythe", "cleaver", "axe", "saw", "pickaxe", "pliers",
]

const GOOD_NAMES := {
	"logs": "Baumstämme", "planks": "Bauholz", "stone": "Stein", "grain": "Korn",
	"flour": "Mehl", "bread": "Brot", "fish": "Fisch", "pork": "Schwein",
	"ham": "Schinken", "coal": "Kohle", "ironOre": "Eisenerz", "iron": "Eisen",
	"goldOre": "Golderz", "goldBar": "Goldbarren", "sword": "Schwert",
	"shield": "Schild", "shovel": "Schaufel", "hammer": "Hammer", "rod": "Angel",
	"scythe": "Sense", "cleaver": "Fleischerbeil", "axe": "Axt", "saw": "Säge",
	"pickaxe": "Spitzhacke", "pliers": "Zange",
}

## Good families, used to colour the carriers and group the priority panel.
const GOOD_CLASS := {
	"logs": "wood", "planks": "wood", "stone": "stone", "grain": "food",
	"flour": "food", "bread": "food", "fish": "food", "pork": "food",
	"ham": "food", "coal": "metal", "ironOre": "metal", "iron": "metal",
	"goldOre": "metal", "goldBar": "metal", "sword": "weapon", "shield": "weapon",
	"shovel": "tool", "hammer": "tool", "rod": "tool", "scythe": "tool",
	"cleaver": "tool", "axe": "tool", "saw": "tool", "pickaxe": "tool",
	"pliers": "tool",
}

const CLASS_COLORS := {
	"food": Color("84cc16"), "wood": Color("a16207"), "stone": Color("94a3b8"),
	"metal": Color("38bdf8"), "tool": Color("fbbf24"), "weapon": Color("ef4444"),
}

## Goods the castle keeps as surplus, and the tools it hands out to settlers.
const CASTLE_SINKS: Array[String] = [
	"planks", "stone", "iron", "coal", "goldBar", "sword", "shield",
	"bread", "fish", "ham",
	"shovel", "hammer", "rod", "scythe", "cleaver", "axe", "saw", "pickaxe", "pliers",
]

# --- buildings --------------------------------------------------------------

const KINDS: Array[String] = [
	"castle", "warehouse", "woodcutter", "forester", "sawmill", "quarry", "farm",
	"pigFarm", "windmill", "butcher", "bakery", "fishery", "coalMine", "ironMine",
	"goldMine", "smelter", "toolsmith", "goldsmith", "blacksmith", "watchtower",
]

const RES_NAMES := {
	"grass": "Freie Fläche", "forest": "Wald", "stone": "Stein", "coal": "Kohle",
	"iron": "Eisenerz", "gold": "Golderz", "water": "Wasser",
}

## Per-building data. `requires` is the terrain the site must stand on, `harvest`
## the deposit it binds and drains, `hungry` marks a worker that eats extra.
const SPECS: Array[Dictionary] = [
	{
		"kind": "castle", "name": "Burg", "icon": "♜", "cost": {"planks": 0, "stone": 0},
		"tool": "", "workers": 0, "inputs": {}, "outputs": {}, "cycle": 1.0,
		"requires": "grass", "harvest": "", "hungry": false, "territory": 0,
		"desc": "Hauptquartier. Hier lagern Bauholz, Eisen und die Werkzeuge — und hier werden Siedler für freie Arbeitsplätze ausgebildet.",
	},
	{
		"kind": "warehouse", "name": "Lager", "icon": "⌂", "cost": {"planks": 6, "stone": 0},
		"tool": "", "workers": 0, "inputs": {}, "outputs": {}, "cycle": 1.0,
		"requires": "grass", "harvest": "", "hungry": false, "territory": 0,
		"desc": "Erhöht die Siedler-Obergrenze um 6 und vergrößert die Lagerkapazität der Burg.",
	},
	{
		"kind": "woodcutter", "name": "Holzfäller", "icon": "⚔", "cost": {"planks": 2, "stone": 0},
		"tool": "axe", "workers": 1, "inputs": {}, "outputs": {"logs": 1}, "cycle": 3.2,
		"requires": "forest", "harvest": "forest", "hungry": false, "territory": 0,
		"desc": "Fällt Bäume und liefert Baumstämme. Braucht eine Axt aus der Schlosserei.",
	},
	{
		"kind": "forester", "name": "Förster", "icon": "❦", "cost": {"planks": 2, "stone": 0},
		"tool": "", "workers": 1, "inputs": {}, "outputs": {}, "cycle": 6.0,
		"requires": "grass", "harvest": "", "hungry": false, "territory": 0,
		"desc": "Pflanzt nach, was der Holzfäller gefällt hat. Ohne Förster ist der Wald irgendwann leer — und ohne Holz steht die ganze Siedlung still.",
	},
	{
		"kind": "sawmill", "name": "Schreiner", "icon": "⌸", "cost": {"planks": 4, "stone": 2},
		"tool": "saw", "workers": 1, "inputs": {"logs": 2}, "outputs": {"planks": 2}, "cycle": 3.4,
		"requires": "grass", "harvest": "", "hungry": false, "territory": 0,
		"desc": "Wandelt Baumstämme in Bauholz. Jedes Gebäude kostet Bauholz.",
	},
	{
		"kind": "quarry", "name": "Steinmetz", "icon": "◭", "cost": {"planks": 3, "stone": 0},
		"tool": "pickaxe", "workers": 1, "inputs": {}, "outputs": {"stone": 1}, "cycle": 4.0,
		"requires": "stone", "harvest": "stone", "hungry": false, "territory": 0,
		"desc": "Bricht Bausteine aus dem Steinbruch.",
	},
	{
		"kind": "farm", "name": "Getreidefarm", "icon": "❀", "cost": {"planks": 3, "stone": 0},
		"tool": "scythe", "workers": 1, "inputs": {}, "outputs": {"grain": 3}, "cycle": 3.4,
		"requires": "grass", "harvest": "", "hungry": false, "territory": 0,
		"desc": "Baut Korn an — Ausgangspunkt der gesamten Nahrungskette.",
	},
	{
		"kind": "pigFarm", "name": "Schweinefarm", "icon": "◕", "cost": {"planks": 4, "stone": 2},
		"tool": "", "workers": 1, "inputs": {"grain": 1}, "outputs": {"pork": 1}, "cycle": 5.0,
		"requires": "grass", "harvest": "", "hungry": true, "territory": 0,
		"desc": "Füttert Schweine mit Korn.",
	},
	{
		"kind": "windmill", "name": "Windmühle", "icon": "✳", "cost": {"planks": 5, "stone": 2},
		"tool": "", "workers": 1, "inputs": {"grain": 2}, "outputs": {"flour": 2}, "cycle": 3.0,
		"requires": "grass", "harvest": "", "hungry": false, "territory": 0,
		"desc": "Mahlt Korn zu Mehl. Dreht sich nur, wenn sie Korn bekommt.",
	},
	{
		"kind": "butcher", "name": "Metzger", "icon": "⚒", "cost": {"planks": 4, "stone": 2},
		"tool": "cleaver", "workers": 1, "inputs": {"pork": 1}, "outputs": {"ham": 1}, "cycle": 3.2,
		"requires": "grass", "harvest": "", "hungry": true, "territory": 0,
		"desc": "Zerlegt Schweine zu Schinken.",
	},
	{
		"kind": "bakery", "name": "Bäckerei", "icon": "◑", "cost": {"planks": 5, "stone": 2},
		"tool": "", "workers": 1, "inputs": {"flour": 2}, "outputs": {"bread": 2}, "cycle": 2.2,
		"requires": "grass", "harvest": "", "hungry": false, "territory": 0,
		"desc": "Backt Mehl zu Brot. Ohne Brot stehen die Minen still.",
	},
	{
		"kind": "fishery", "name": "Fischerhütte", "icon": "❧", "cost": {"planks": 4, "stone": 0},
		"tool": "rod", "workers": 1, "inputs": {}, "outputs": {"fish": 1}, "cycle": 3.4,
		"requires": "water", "harvest": "water", "hungry": false, "territory": 0,
		"desc": "Fischt auf offenen Wasser. Braucht eine Angel.",
	},
	{
		"kind": "coalMine", "name": "Kohlemine", "icon": "●", "cost": {"planks": 4, "stone": 2},
		"tool": "pickaxe", "workers": 1, "inputs": {}, "outputs": {"coal": 1}, "cycle": 4.4,
		"requires": "coal", "harvest": "coal", "hungry": true, "territory": 0,
		"desc": "Fördert Kohle. Braucht Spitzhacke und Nahrung für den Bergmann.",
	},
	{
		"kind": "ironMine", "name": "Eisenmine", "icon": "◐", "cost": {"planks": 4, "stone": 2},
		"tool": "pickaxe", "workers": 1, "inputs": {}, "outputs": {"ironOre": 1}, "cycle": 4.8,
		"requires": "iron", "harvest": "iron", "hungry": true, "territory": 0,
		"desc": "Fördert Eisenerz. Braucht Spitzhacke und Nahrung.",
	},
	{
		"kind": "goldMine", "name": "Goldmine", "icon": "○", "cost": {"planks": 5, "stone": 3},
		"tool": "pickaxe", "workers": 1, "inputs": {}, "outputs": {"goldOre": 1}, "cycle": 5.4,
		"requires": "gold", "harvest": "gold", "hungry": true, "territory": 0,
		"desc": "Fördert Golderz für die Goldschmiede.",
	},
	{
		"kind": "smelter", "name": "Schmelze", "icon": "▲", "cost": {"planks": 5, "stone": 4},
		"tool": "", "workers": 1, "inputs": {"ironOre": 1, "coal": 1}, "outputs": {"iron": 1}, "cycle": 4.2,
		"requires": "grass", "harvest": "", "hungry": false, "territory": 0,
		"desc": "Schmilzt Eisenerz mit Kohle zu Eisen — der Grundstein jeder Schlosserei.",
	},
	{
		"kind": "toolsmith", "name": "Schlosserei", "icon": "⚒", "cost": {"planks": 6, "stone": 4},
		"tool": "hammer", "workers": 1, "inputs": {"iron": 1, "logs": 1}, "outputs": {}, "cycle": 2.6,
		"requires": "grass", "harvest": "", "hungry": false, "territory": 0,
		"desc": "Schmiedet aus 1 Eisen + 1 Holz beliebige Werkzeuge. Über die Werkzeugknöpfe steuerst du die Reihenfolge selbst!",
	},
	{
		"kind": "goldsmith", "name": "Goldschmiede", "icon": "◉", "cost": {"planks": 5, "stone": 4},
		"tool": "pliers", "workers": 1, "inputs": {"goldOre": 1, "coal": 1}, "outputs": {"goldBar": 1}, "cycle": 5.2,
		"requires": "grass", "harvest": "", "hungry": false, "territory": 0,
		"desc": "Schmilzt Golderz mit Kohle zu Goldbarren. Gold hebt die Moral deiner Ritter im Angriff.",
	},
	{
		"kind": "blacksmith", "name": "Schmiede", "icon": "⚑", "cost": {"planks": 6, "stone": 4},
		"tool": "pliers", "workers": 1, "inputs": {"iron": 1, "coal": 1}, "outputs": {"sword": 1, "shield": 1}, "cycle": 5.0,
		"requires": "grass", "harvest": "", "hungry": false, "territory": 0,
		"desc": "Fertigt Schwert und Schild. Damit rüstest du Ritter für den Wachturm aus.",
	},
	{
		"kind": "watchtower", "name": "Wachturm", "icon": "⌂", "cost": {"planks": 5, "stone": 6},
		"tool": "", "workers": 0, "inputs": {}, "outputs": {}, "cycle": 1.0,
		"requires": "grass", "harvest": "", "hungry": false, "territory": 7,
		"desc": "Erweitert das Territorium, solange mindestens 1 Ritter stationiert ist.",
	},
]

## Which mesh dresses which building.
const MESH_BY_KIND := {
	"castle": "siedler/castle", "warehouse": "siedler/warehouse",
	"woodcutter": "siedler/woodcutter", "forester": "siedler/forester",
	"sawmill": "siedler/sawmill", "quarry": "siedler/quarry",
	"farm": "siedler/farm", "pigFarm": "siedler/farm",
	"windmill": "siedler/windmill", "butcher": "siedler/sawmill",
	"bakery": "siedler/bakery", "fishery": "siedler/fishery",
	"coalMine": "siedler/coal_mine", "ironMine": "siedler/iron_mine",
	"goldMine": "siedler/gold_mine", "smelter": "siedler/smelter",
	"toolsmith": "siedler/toolsmith", "goldsmith": "siedler/smelter",
	"blacksmith": "siedler/blacksmith", "watchtower": "siedler/watchtower",
}

# --- tunables ---------------------------------------------------------------

const CASTLE_SERFS := 10
const WAREHOUSE_SERFS := 6
const STORE_CAP := 400
## Flags are dropped at this spacing, which is what sets a road's throughput.
const FLAG_SPACING := 5
const IDEAL_SEGMENT := 7.0
const CARRIER_SPEED := 3.1
const SERF_SPEED := 2.6
const MAX_CARRIERS_PER_ROAD := 6
const EAT_INTERVAL := 22.0
const MINER_EAT_INTERVAL := 13.0
const BUILD_TIME := 6.0
const LEVEL_TIME := 3.5

## Deposit blobs the generator scatters, and how much each covered cell holds.
## A bound mine drains one unit per cycle, so a seam has to last a while.
const DEPOSITS: Array[Dictionary] = [
	{"res": "forest", "blobs": 46, "perCell": 90},
	{"res": "stone", "blobs": 18, "perCell": 220},
	{"res": "coal", "blobs": 12, "perCell": 260},
	{"res": "iron", "blobs": 11, "perCell": 240},
	{"res": "gold", "blobs": 6, "perCell": 140},
]

## Open water carries a shoal a fishery can work.
const WATER_SHOAL := 400

# --- state ------------------------------------------------------------------

var map_size: int = 46
## `{"res": String, "amount": int, "height": float, "building": int, "flag": int}`
var cells: Array[Dictionary] = []
## `{"id", "kind", "cell", "node", "x", "z", "owner", "state", "progress",
##   "workers", "tool", "input", "output", "halted", "cycle_t", "garrison", "status"}`
var buildings: Array[Dictionary] = []
## `{"id", "kind", "cell", "x", "z", "building", "queue", "edges", "flag"}`
var nodes: Array[Dictionary] = []
## `{"id", "a", "b", "kind", "priority", "length", "carriers"}`
var edges: Array[Dictionary] = []
## `{"id", "owner", "building", "tool", "hunger", "x", "z", "phase", "state"}`
var serfs: Array[Dictionary] = []
## Goods physically in the castle store.
var store: Dictionary = {}
## Tools the player ordered; the Schlosserei works through the list.
var tool_queue: Array[String] = []
var good_priority: Dictionary = {}
var attacks: Array[Dictionary] = []

var castle_id: int = -1
var rival_castle_ids: Array[int] = []
var time: float = 0.0
var speed: float = 1.0
var knights: int = 0
var territory_radius: float = 4.0
## `-1` nobody, `0` player, `1` rival. Rebuilt by `refresh_territory`.
var owner_grid: PackedInt32Array = PackedInt32Array()
var won: bool = false
var lost: bool = false
var produced_total: int = 0
var delivered_total: int = 0
var notice: String = ""
var notice_time: float = 0.0
var seed_value: int = 0

var _routes: Dictionary = {}
var _routes_dirty: bool = true
## Handelswege: Zähler je Straße *und* Ware, Index `edge * GOODS.size() + Ware`.
## Ein flaches Feld statt einer Karte voller Finder — und gefüllt wird nur, wenn
## ein Träger wirklich etwas aufnimmt, also ein Schreibzugriff pro Umschlag
## und keiner pro Frame.
var _traffic := PackedInt32Array()
## Laufende Summe der Zähler, damit `measured_carriers()` O(1) bleibt.
var _traffic_total: int = 0
var _rng := RandomNumberGenerator.new()


# --- static lookups ---------------------------------------------------------

## Every kind the player may place, i.e. everything but the castle.
static func buildable_kinds() -> Array[String]:
	var out: Array[String] = []
	for kind in KINDS:
		if kind != "castle":
			out.append(kind)
	return out


static func spec_of(kind: String) -> Dictionary:
	for spec in SPECS:
		if spec["kind"] == kind:
			return spec
	return SPECS[0]


static func spec_index(kind: String) -> int:
	for i in SPECS.size():
		if SPECS[i]["kind"] == kind:
			return i
	return 0


static func is_food_good(good: String) -> bool:
	return good in FOODS


static func is_tool_good(good: String) -> bool:
	return good in TOOLS


static func empty_stock() -> Dictionary:
	var out: Dictionary = {}
	for good in GOODS:
		out[good] = 0
	return out


static func stock_add(stock: Dictionary, good: String, amount: int) -> void:
	stock[good] = int(stock.get(good, 0)) + amount


## True when every wanted good is present in at least the requested amount.
static func stock_has(stock: Dictionary, need: Dictionary) -> bool:
	for good in GOODS:
		var want := int(need.get(good, 0))
		if want > 0 and int(stock.get(good, 0)) < want:
			return false
	return true


static func stock_take(stock: Dictionary, need: Dictionary) -> void:
	for good in GOODS:
		var want := int(need.get(good, 0))
		if want > 0:
			stock[good] = maxi(0, int(stock.get(good, 0)) - want)


## German name of a good.
static func good_name(good: String) -> String:
	return str(GOOD_NAMES.get(good, good))


static func status_text(status: String) -> String:
	match status:
		"ok": return "arbeitet"
		"site": return "Bauplatz — wartet auf Bauholz & Stein"
		"levelling": return "Planieren (Schaufel nötig)"
		"building": return "wird gebaut (Hammer nötig)"
		"noWorker": return "kein Siedler am Platz"
		"noTool": return "Werkzeug fehlt"
		"noInput": return "Rohstoff fehlt"
		"noResource": return "Lagerstätte erschöpft"
		"hungry": return "Siedler unversorgt"
		"halted": return "angehalten"
		"notConnected": return "nicht an die Straße angeschlossen"
		"unreachable": return "Straßennetz unterbrochen"
	return status


# --- map --------------------------------------------------------------------

func cell_index(x: int, y: int) -> int:
	return y * map_size + x


func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < map_size and y < map_size


## World-space centre of a cell.
func cell_to_world(index: int) -> Vector2:
	return Vector2(
		float(index % map_size) - float(map_size) * 0.5 + 0.5,
		float(index / map_size) - float(map_size) * 0.5 + 0.5
	)


## World-space XZ position, at a height offset above the cell.
func cell_position(index: int, y_offset: float = 0.0) -> Vector3:
	var world := cell_to_world(index)
	return Vector3(world.x, float(cells[index]["height"]) + y_offset, world.y)


## The cell a world XZ position falls on, or -1 when it is off the map.
func world_to_cell(x: float, z: float) -> int:
	var gx := int(round(x)) + int(map_size / 2)
	var gy := int(round(z)) + int(map_size / 2)
	if not in_bounds(gx, gy):
		return -1
	return cell_index(gx, gy)


## A cell counts as flat when no orthogonal neighbour is more than `tolerance`
## steps away. Deliberately forgiving: only genuinely hilly ground forces the
## player to spend a Schaufel on a Planierer.
func is_flat(index: int, tolerance: float = 2.0) -> bool:
	var cell: Dictionary = cells[index]
	var low: float = cell["height"]
	var high: float = cell["height"]
	for offset: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var nx: int = index % map_size + offset.x
		var ny: int = index / map_size + offset.y
		if not in_bounds(nx, ny):
			continue
		var h: float = cells[cell_index(nx, ny)]["height"]
		low = minf(low, h)
		high = maxf(high, h)
	return high - low <= tolerance


## Builds the island: a noise heightmap, water below the shoreline, smoothed
## coast and scattered deposits.
func generate(seed_value_: int, size: int) -> void:
	seed_value = seed_value_
	map_size = size
	_rng.seed = seed_value_

	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.055
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 4

	cells.clear()
	var half := float(size) * 0.5
	for y in size:
		for x in size:
			var nx := float(x) / float(size)
			var ny := float(y) / float(size)
			# Radial falloff keeps the island away from the map edge.
			var dist := Vector2(nx - 0.5, ny - 0.5).length() * 2.0
			var base := noise.get_noise_2d(nx * 5.0, ny * 5.0) * 0.5 + 0.5
			var height := base * 0.75 + (1.0 - dist) * 0.45
			var res := "water" if height < 0.42 else "grass"
			var h := 0.0 if res == "water" else snappedf((height - 0.42) * 9.0, 0.1)
			cells.append({
				"res": res,
				"amount": WATER_SHOAL if res == "water" else 0,
				"height": h,
				"building": -1,
				"flag": -1,
			})

	_scatter_deposits()
	_smooth_coast()
	owner_grid = PackedInt32Array()
	owner_grid.resize(cells.size())
	owner_grid.fill(-1)


func _scatter_deposits() -> void:
	for deposit in DEPOSITS:
		for blob in int(deposit["blobs"]):
			var cx := 2 + _rng.randi_range(0, map_size - 5)
			var cy := 2 + _rng.randi_range(0, map_size - 5)
			var radius := 1 + _rng.randi_range(0, 2)
			for y in range(cy - radius, cy + radius + 1):
				for x in range(cx - radius, cx + radius + 1):
					if x < 1 or y < 1 or x >= map_size - 1 or y >= map_size - 1:
						continue
					var cell: Dictionary = cells[cell_index(x, y)]
					if cell["res"] != "grass":
						continue
					if Vector2(x - cx, y - cy).length() > float(radius):
						continue
					# Overlapping blobs stack, so rich stands exist.
					cell["res"] = deposit["res"]
					cell["amount"] = int(cell["amount"]) + int(deposit["perCell"])


## Smooths the coastline a touch so beaches are not staircases.
func _smooth_coast() -> void:
	for y in range(1, map_size - 1):
		for x in range(1, map_size - 1):
			var index := cell_index(x, y)
			if cells[index]["res"] != "grass":
				continue
			var water := 0
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					if cells[cell_index(x + dx, y + dy)]["res"] == "water":
						water += 1
			if water >= 6:
				# Newly flooded coast still counts as fishable water.
				cells[index]["res"] = "water"
				cells[index]["amount"] = WATER_SHOAL
				cells[index]["height"] = 0.0


# --- setup ------------------------------------------------------------------

## A ready-to-play settlement: player castle in the middle, two rival camps in
## opposite quadrants, and a starter road so the flag idea is visible at once.
func setup(seed_value_: int = 0, size: int = 46) -> void:
	if seed_value_ == 0:
		seed_value_ = _rng.randi() % 100000
	generate(seed_value_, size)

	nodes.clear()
	edges.clear()
	buildings.clear()
	serfs.clear()
	attacks.clear()
	store = empty_stock()
	tool_queue.clear()
	good_priority.clear()
	castle_id = -1
	rival_castle_ids.clear()
	time = 0.0
	speed = 1.0
	knights = 0
	territory_radius = 4.0
	won = false
	lost = false
	produced_total = 0
	delivered_total = 0
	notice = ""
	notice_time = 0.0
	_routes.clear()
	_routes_dirty = true
	_reset_traffic()

	var center := _nearest_grass(cell_index(map_size / 2, map_size / 2))
	place_castle(center, "player")

	# The castle is the seed of the whole economy. The starting pickaxes are not
	# a convenience: a Spitzhacke has to exist before iron can be mined, and
	# iron is what the Schlosserei turns into every other tool. The larder is
	# what breaks the other cycle — mines eat, but the food chain needs a Sense,
	# and a Sense needs iron, and iron needs a *mined* seam.
	stock_add(store, "planks", 30)
	stock_add(store, "stone", 20)
	stock_add(store, "logs", 12)
	stock_add(store, "bread", 14)
	stock_add(store, "fish", 8)
	store["hammer"] = 3
	store["shovel"] = 2
	store["axe"] = 1
	store["pickaxe"] = 3

	var spots := [
		Vector2i(int(float(map_size) * 0.22), int(float(map_size) * 0.24)),
		Vector2i(int(float(map_size) * 0.78), int(float(map_size) * 0.76)),
	]
	for spot in spots:
		var spot_cell := _find_castle_cell(cell_index(spot.x, spot.y), 12)
		if spot_cell < 0:
			continue
		var rival := place_castle(spot_cell, "rival")
		rival_castle_ids.append(rival)
		_seed_rival_camp(rival)

	refresh_territory()
	var castle_cell: int = buildings[castle_id]["cell"]
	var starter := _nearest_flat_grass(
		castle_cell % map_size + 5, castle_cell / map_size + 3, castle_cell
	)
	build_road(castle_cell, starter, 3)


func _nearest_grass(near: int) -> int:
	var nx: int = near % map_size
	var ny: int = near / map_size
	var best := -1
	var best_distance := INF
	for i in cells.size():
		if cells[i]["res"] != "grass":
			continue
		var d := Vector2(float(i % map_size - nx), float(i / map_size - ny)).length()
		if d < best_distance:
			best_distance = d
			best = i
	return best


## Nearest flat, empty grass to `near`, used for castle and camp placement.
func _find_castle_cell(near: int, min_dist: float) -> int:
	var nx: int = near % map_size
	var ny: int = near / map_size
	var best := -1
	var best_score := INF
	for i in cells.size():
		var cell: Dictionary = cells[i]
		if cell["res"] != "grass" or int(cell["amount"]) > 0 or int(cell["building"]) >= 0:
			continue
		if not is_flat(i):
			continue
		var x: int = i % map_size
		var y: int = i / map_size
		# Keep camps away from the coastline so they have room to grow.
		if x < 4 or y < 4 or x >= map_size - 4 or y >= map_size - 4:
			continue
		var d := Vector2(float(x - nx), float(y - ny)).length()
		# Prefer cells at least `min_dist` away, then the closest one overall.
		var score := d if d >= min_dist else d + 1000.0
		if score < best_score:
			best_score = score
			best = i
	return best if best >= 0 else _nearest_grass(near)


func _nearest_flat_grass(x: int, y: int, fallback: int) -> int:
	for radius in range(1, 12):
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if maxi(absi(dx), absi(dy)) != radius:
					continue
				var nx := x + dx
				var ny := y + dy
				if not in_bounds(nx, ny):
					continue
				var index := cell_index(nx, ny)
				var cell: Dictionary = cells[index]
				if cell["res"] != "grass" or int(cell["building"]) >= 0 or int(cell["flag"]) >= 0:
					continue
				if not is_flat(index):
					continue
				return index
	return fallback


## Buildings are addressed by their index in `buildings`, so the id is the slot
## they occupy.
## Buildings are addressed by their index in `buildings`, so the id has to be
## the slot they occupy. Forgetting this once left `castle_id` at -1 and the
## castle never hired a settler.
func place_castle(cell: int, owner: String) -> int:
	var building := _new_building("castle", cell, owner, "done")
	building["id"] = buildings.size()
	var node := _add_node("building", cell, building["id"], false)
	building["node"] = node["id"]
	node["building"] = building["id"]
	buildings.append(building)
	cells[cell]["building"] = building["id"]
	if owner == "player":
		castle_id = building["id"]
	_routes_dirty = true
	return building["id"]


func _new_building(kind: String, cell: int, owner: String, state: String) -> Dictionary:
	var world := cell_to_world(cell)
	return {
		"id": -1, "kind": kind, "cell": cell, "node": -1,
		"x": world.x, "z": world.y, "owner": owner, "state": state,
		"progress": 0.0, "workers": 0, "tool": "", "input": empty_stock(),
		"output": empty_stock(), "halted": false, "cycle_t": 0.0,
		"garrison": 0, "status": "ok" if state == "done" else state,
	}


## Rival camps get a working economy without a second transport simulation.
func _seed_rival_camp(castle: int) -> void:
	var wanted: Array[String] = [
		"woodcutter", "sawmill", "quarry", "farm", "windmill", "bakery",
		"coalMine", "ironMine", "smelter", "toolsmith",
	]
	var castle_cell: int = buildings[castle]["cell"]
	var cx: int = castle_cell % map_size
	var cy: int = castle_cell / map_size
	for kind in wanted:
		var cell := _find_deposit_near(kind, cx, cy, 16)
		if cell < 0:
			continue
		var building := _new_building(kind, cell, "rival", "done")
		building["id"] = buildings.size()
		# Rivals keep a small standing garrison.
		building["garrison"] = 1
		var node := _add_node("building", cell, building["id"], false)
		building["node"] = node["id"]
		node["building"] = building["id"]
		buildings.append(building)
		cells[cell]["building"] = building["id"]
		var spec := spec_of(kind)
		if str(spec["harvest"]) != "":
			cells[cell]["amount"] = maxi(0, int(cells[cell]["amount"]) - 20)


func _find_deposit_near(kind: String, cx: int, cy: int, reach: int) -> int:
	var spec := spec_of(kind)
	var need := str(spec["harvest"]) if str(spec["harvest"]) != "" else str(spec["requires"])
	var best := -1
	var best_distance := INF
	for y in range(cy - reach, cy + reach + 1):
		for x in range(cx - reach, cx + reach + 1):
			if not in_bounds(x, y):
				continue
			var index := cell_index(x, y)
			var cell: Dictionary = cells[index]
			if int(cell["building"]) >= 0 or int(cell["flag"]) >= 0:
				continue
			if str(cell["res"]) != need or not is_flat(index):
				continue
			var d := Vector2(float(x - cx), float(y - cy)).length()
			if d < best_distance:
				best_distance = d
				best = index
	return best


func _add_node(kind: String, cell: int, building: int, flag: bool) -> Dictionary:
	var world := cell_to_world(cell)
	var node := {
		"id": nodes.size(), "kind": kind, "cell": cell, "x": world.x, "z": world.y,
		"building": building, "queue": [], "edges": [], "flag": flag,
	}
	nodes.append(node)
	return node


# --- territory --------------------------------------------------------------

## Recomputes the ownership grid. Runs every tick from the military step, so
## `in_territory` can read the cache cheaply during placement previews.
func refresh_territory() -> void:
	owner_grid.fill(-1)
	for i in buildings.size():
		var building: Dictionary = buildings[i]
		var spec := spec_of(str(building["kind"]))
		var owner := str(building["owner"])
		var is_castle := str(building["kind"]) == "castle"
		var radius := 0
		if owner == "player" and (is_castle or (int(spec["territory"]) > 0 and int(building["garrison"]) > 0)):
			radius = int(territory_radius) if is_castle else int(spec["territory"])
		elif owner == "rival" and (is_castle or int(spec["territory"]) > 0):
			radius = 5 if is_castle else int(spec["territory"])
		if radius <= 0:
			continue
		var cell: int = building["cell"]
		var cx: int = cell % map_size
		var cy: int = cell / map_size
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if not in_bounds(cx + dx, cy + dy):
					continue
				if dx * dx + dy * dy > radius * radius:
					continue
				var index := cell_index(cx + dx, cy + dy)
				if owner == "player":
					owner_grid[index] = 0
				elif owner_grid[index] < 0:
					owner_grid[index] = 1


func in_territory(cell: int) -> bool:
	return cell >= 0 and cell < owner_grid.size() and owner_grid[cell] == 0


## Share of the non-water map the player holds, 0..1.
func territory_share() -> float:
	var mine := 0
	var total := 0
	for i in cells.size():
		if cells[i]["res"] == "water":
			continue
		total += 1
		if owner_grid[i] == 0:
			mine += 1
	return float(mine) / float(maxi(1, total))


# --- placement --------------------------------------------------------------

## Whether a building of `kind` may be started on `cell`, and why not.
func can_place(kind: String, cell: int) -> Dictionary:
	var spec := spec_of(kind)
	var missing := {
		"planks": maxi(0, int(spec["cost"]["planks"]) - int(store.get("planks", 0))),
		"stone": maxi(0, int(spec["cost"]["stone"]) - int(store.get("stone", 0))),
	}
	if cell < 0 or cell >= cells.size():
		return {"ok": false, "reason": "Kein gültiges Feld", "missing": missing}
	var map_cell: Dictionary = cells[cell]
	if int(map_cell["building"]) >= 0:
		return {"ok": false, "reason": "Feld ist bereits bebaut", "missing": missing}
	var requires := str(spec["requires"])
	if str(map_cell["res"]) == "water" and requires != "water":
		return {"ok": false, "reason": "Kein Bauen auf Wasser", "missing": missing}
	if requires != "" and str(map_cell["res"]) != requires:
		return {"ok": false, "reason": "Braucht %s" % RES_NAMES[requires], "missing": missing}
	if str(spec["harvest"]) == "" and not is_flat(cell):
		return {"ok": false, "reason": "Gelände zu steil — Planierer nötig", "missing": missing}
	if not in_territory(cell):
		return {"ok": false, "reason": "Außerhalb des Territoriums", "missing": missing}
	return {"ok": true, "reason": "", "missing": missing}


## Starts a construction site, spending the building material from the castle.
func place_building(kind: String, cell: int) -> bool:
	var check := can_place(kind, cell)
	if not check["ok"]:
		_notify(str(check["reason"]))
		return false
	var spec := spec_of(kind)
	if int(store.get("planks", 0)) < int(spec["cost"]["planks"]) \
			or int(store.get("stone", 0)) < int(spec["cost"]["stone"]):
		_notify("Zu wenig Bauholz/Stein (fehlt: %d Bauholz, %d Stein)" % [
			int(check["missing"]["planks"]), int(check["missing"]["stone"]),
		])
		return false
	store["planks"] = int(store["planks"]) - int(spec["cost"]["planks"])
	store["stone"] = int(store["stone"]) - int(spec["cost"]["stone"])

	# Sloped ground needs a Planierer with a Schaufel before the walls go up.
	var state := "building" if is_flat(cell) else "levelling"
	var building := _new_building(kind, cell, "player", state)
	building["id"] = buildings.size()
	var node := _add_node("building", cell, building["id"], false)
	building["node"] = node["id"]
	node["building"] = building["id"]
	buildings.append(building)
	cells[cell]["building"] = building["id"]
	_routes_dirty = true
	if int(spec["territory"]) > 0:
		refresh_territory()
	return true


func demolish(building_id: int) -> bool:
	if building_id < 0 or building_id >= buildings.size():
		return false
	var building: Dictionary = buildings[building_id]
	if str(building["owner"]) != "player" or str(building["kind"]) == "castle":
		return false
	var cell: int = building["cell"]
	_drop_node(int(building["node"]))
	cells[cell]["building"] = -1
	# Half the material comes back, so a misclick is recoverable.
	var spec := spec_of(str(building["kind"]))
	stock_add(store, "planks", int(spec["cost"]["planks"]) / 2)
	stock_add(store, "stone", int(spec["cost"]["stone"]) / 2)
	for serf in serfs:
		if int(serf["building"]) == building_id:
			serf["building"] = -1
			serf["tool"] = ""
			serf["state"] = "idle"
	buildings.remove_at(building_id)
	_reindex_buildings()
	_routes_dirty = true
	refresh_territory()
	return true


func _reindex_buildings() -> void:
	for i in buildings.size():
		buildings[i]["id"] = i


# --- the road network -------------------------------------------------------

## Flags a road of this length needs, following the original's spacing rule.
static func flags_for(length: float) -> int:
	return maxi(2, int(ceil(length / float(FLAG_SPACING))) + 1)


static func carrier_count_for(length: float, priority: int) -> int:
	var by_length := maxi(1, int(round(IDEAL_SEGMENT / maxf(1.0, length))))
	var by_priority := 1 + int(floor(float(priority) / 2.0))
	return mini(MAX_CARRIERS_PER_ROAD, by_length * by_priority)


## The shortest hop a building needs to reach the network is a stub with a single
## carrier; everything the player actually walks on is a road, and only a road
## scales its carrier count with length and priority.
const LINK_LENGTH := 1.7
## How close a flag has to be to a road to split it. Shared by the finger and
## by the optimiser, so both always cut the road they were looking at.
const FLAG_NEAR := 3.2


## Builds a road between two cells. The route is a breadth-first search, so it
## walks around buildings and existing structures instead of dead-ending.
func build_road(from_cell: int, to_cell: int, priority: int = 3) -> Dictionary:
	if from_cell == to_cell:
		return {"ok": false, "reason": "Start und Ziel sind identisch", "flags": 0}
	if from_cell < 0 or to_cell < 0 or from_cell >= cells.size() or to_cell >= cells.size():
		return {"ok": false, "reason": "Kein gültiges Feld", "flags": 0}
	# The two endpoints may hold a building *or* be water — a fishery is built
	# out on the lake, and drawing a road to it is the whole point.
	var passable := func(index: int) -> bool:
		var is_end := index == from_cell or index == to_cell
		var cell: Dictionary = cells[index]
		if str(cell["res"]) == "water":
			return is_end
		return is_end or int(cell["building"]) < 0

	var path := _find_road_path(from_cell, to_cell, passable)
	if path.is_empty():
		return {"ok": false, "reason": _road_block_reason(from_cell, to_cell), "flags": 0}

	# A building on a cell links directly, otherwise the cell needs a flag.
	# Flags are dropped every FLAG_SPACING so the carriers share the walk.
	var chain: Array[int] = []
	var since_flag := 0
	for i in path.size():
		var cell: int = path[i]
		var is_end := i == path.size() - 1
		var on_building := int(cells[cell]["building"]) >= 0
		if on_building or is_end or since_flag >= FLAG_SPACING:
			var node := _node_at(cell)
			if chain.is_empty() or chain[chain.size() - 1] != node:
				chain.append(node)
			since_flag = 0 if (on_building or is_end) else since_flag + 1
		else:
			since_flag += 1

	var flags := 0
	for i in range(chain.size() - 1):
		var edge := _link_if_needed(chain[i], chain[i + 1])
		if edge.is_empty():
			continue
		edge["priority"] = priority
		_rebalance(edge)
		if bool(nodes[chain[i]]["flag"]):
			flags += 1
		if bool(nodes[chain[i + 1]]["flag"]):
			flags += 1

	_routes_dirty = true
	return {"ok": true, "reason": "", "flags": flags}


func _find_road_path(from_cell: int, to_cell: int, passable: Callable) -> PackedInt32Array:
	var previous := PackedInt32Array()
	previous.resize(cells.size())
	previous.fill(-1)
	var seen := PackedByteArray()
	seen.resize(cells.size())
	seen[from_cell] = 1
	var queue: Array[int] = [from_cell]
	var head := 0
	while head < queue.size():
		var index: int = queue[head]
		head += 1
		if index == to_cell:
			break
		var x: int = index % map_size
		var y: int = index / map_size
		for offset: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nx := x + offset.x
			var ny := y + offset.y
			if not in_bounds(nx, ny):
				continue
			var next_index := cell_index(nx, ny)
			if seen[next_index] == 1 or not bool(passable.call(next_index)):
				continue
			seen[next_index] = 1
			previous[next_index] = index
			queue.append(next_index)
	if seen[to_cell] == 0:
		return PackedInt32Array()
	var path := PackedInt32Array()
	var cursor := to_cell
	while cursor != from_cell:
		path.append(cursor)
		cursor = previous[cursor]
		if cursor < 0:
			return PackedInt32Array()
	path.append(from_cell)
	path.reverse()
	return path


## A readable reason a road could not be laid, for the toast.
func _road_block_reason(from_cell: int, to_cell: int) -> String:
	if str(cells[from_cell]["res"]) == "water" or str(cells[to_cell]["res"]) == "water":
		return "Wasser blockiert den Weg"
	var fx: int = from_cell % map_size
	var fy: int = from_cell / map_size
	var tx: int = to_cell % map_size
	var ty: int = to_cell / map_size
	var steps := maxi(absi(tx - fx), absi(ty - fy))
	for i in range(steps + 1):
		var t := 0.0 if steps == 0 else float(i) / float(steps)
		var x := int(round(float(fx) + float(tx - fx) * t))
		var y := int(round(float(fy) + float(ty - fy) * t))
		var index := cell_index(x, y)
		if str(cells[index]["res"]) == "water":
			return "Wasser blockiert den Weg"
		if int(cells[index]["building"]) >= 0 and index != from_cell and index != to_cell:
			return "Ein Gebäude steht im Weg"
	return "Kein freier Weg — die Fläche ist eingekesselt"


func _node_at(cell: int) -> int:
	var building_id: int = cells[cell]["building"]
	if building_id >= 0:
		return int(buildings[building_id]["node"])
	return _ensure_flag(cell)


func _ensure_flag(cell: int) -> int:
	var existing: int = cells[cell]["flag"]
	if existing >= 0:
		return existing
	var node := _add_node("flag", cell, -1, true)
	cells[cell]["flag"] = node["id"]
	return node["id"]


func _add_edge(a: int, b: int, kind: String) -> Dictionary:
	var length := Vector2(
		float(nodes[a]["x"]) - float(nodes[b]["x"]),
		float(nodes[a]["z"]) - float(nodes[b]["z"])
	).length()
	var edge := {
		"id": edges.size(), "a": a, "b": b, "kind": kind,
		"priority": 3, "length": length, "carriers": [],
	}
	var count := 1 if kind == "link" else carrier_count_for(length, 3)
	for i in count:
		edge["carriers"].append(_new_carrier(i, count))
	edges.append(edge)
	nodes[a]["edges"].append(edge["id"])
	nodes[b]["edges"].append(edge["id"])
	# Neue Kante, neue Ids: die Verkehrsmessung beginnt von vorn, sonst hinge
	# eine Zahl an einer Straße, die es nicht mehr gibt.
	_reset_traffic()
	_routes_dirty = true
	return edge


func _new_carrier(index: int, count: int) -> Dictionary:
	return {
		"t": float(index) / float(maxi(1, count)), "dir": 1, "load": "",
		"x": 0.0, "z": 0.0, "phase": float(index) * 1.7, "waiting": 0.0,
	}


func _link_if_needed(a: int, b: int) -> Dictionary:
	if a < 0 or b < 0 or a == b:
		return {}
	for edge_id in nodes[a]["edges"]:
		var edge: Dictionary = edges[edge_id]
		if (int(edge["a"]) == a and int(edge["b"]) == b) or (int(edge["a"]) == b and int(edge["b"]) == a):
			return edge
	var length := Vector2(
		float(nodes[a]["x"]) - float(nodes[b]["x"]),
		float(nodes[a]["z"]) - float(nodes[b]["z"])
	).length()
	return _add_edge(a, b, "link" if length <= LINK_LENGTH else "road")


## Adds one more flag on an existing road, raising that segment's throughput.
func add_flag(cell: int) -> bool:
	if cell < 0 or cell >= cells.size():
		return false
	var map_cell: Dictionary = cells[cell]
	if int(map_cell["building"]) >= 0 or str(map_cell["res"]) == "water":
		_notify("Hier kann keine Flagge stehen")
		return false
	if int(map_cell["flag"]) >= 0:
		_notify("Hier steht schon eine Flagge")
		return false
	var edge := _nearest_road(cell, FLAG_NEAR)
	if edge.is_empty():
		_notify("Keine Straße in der Nähe zum Unterteilen")
		return false
	_split_road(edge, _ensure_flag(cell))
	return true


## Die Straße, die einem Feld am nächsten liegt, `{}` wenn keine in `radius`.
## Der Optimierer sucht damit genauso wie der Finger des Spielers — beide
## benutzen dieselbe Reichweite, sonst teilte der Optimierer eine andere Strecke
## als die, die er gerade ausgewertet hat.
func _nearest_road(cell: int, radius: float) -> Dictionary:
	var world := cell_to_world(cell)
	var best := {}
	var best_distance := radius
	for edge in edges:
		if str(edge["kind"]) != "road":
			continue
		for node_id in [int(edge["a"]), int(edge["b"])]:
			var d := Vector2(
				float(nodes[node_id]["x"]) - world.x,
				float(nodes[node_id]["z"]) - world.y
			).length()
			if d < best_distance:
				best_distance = d
				best = edge
	return best


## Teilt eine Straße an einer Fahne in der Mitte. Getrennt von `add_flag`, weil
## der Optimierer das Feld selbst wählt und keine Fehlermeldung braucht.
func _split_road(edge: Dictionary, mid_node: int) -> void:
	_split_edge(edge, mid_node)
	_routes_dirty = true


## Replaces one road with two, so the carriers are shared over a shorter walk.
func _split_edge(edge: Dictionary, mid_node: int) -> void:
	var a: int = int(edge["a"])
	var b: int = int(edge["b"])
	var priority: int = int(edge["priority"])
	nodes[a]["edges"].erase(edge["id"])
	nodes[b]["edges"].erase(edge["id"])
	edges.erase(edge)
	# Edge ids shifted, so re-find the survivors by their endpoints.
	edges.append(_renumbered_edge(a, mid_node, priority))
	var second := _renumbered_edge(mid_node, b, priority)
	edges.append(second)
	_reset_traffic()


## Builds a road edge and returns it already stored (helper for `_split_edge`).
func _renumbered_edge(a: int, b: int, priority: int) -> Dictionary:
	var edge := _add_edge(a, b, "road")
	edge["priority"] = priority
	_rebalance(edge)
	return edge


func set_road_priority(edge_id: int, priority: int) -> void:
	if edge_id < 0 or edge_id >= edges.size():
		return
	var edge: Dictionary = edges[edge_id]
	edge["priority"] = clampi(priority, 0, 8)
	_rebalance(edge)


## Priorität einer Straße, `-1` wenn es keine gibt. Der Bildschirm braucht sie
## für die Plus- und Minus-Knöpfe der Handelsweg-Karte.
func edge_priority(edge_id: int) -> int:
	if edge_id < 0 or edge_id >= edges.size():
		return -1
	return int(edges[edge_id]["priority"])


func _rebalance(edge: Dictionary) -> void:
	# Ein Stummel trägt immer genau einen Träger; nur eine Straße teilt sich die
	# Last nach Länge und Priorität.
	var want := 1
	if str(edge["kind"]) == "road":
		want = carrier_count_for(float(edge["length"]), int(edge["priority"]))
	var carriers: Array = edge["carriers"]
	while carriers.size() > want:
		carriers.pop_back()
	while carriers.size() < want:
		carriers.append(_new_carrier(carriers.size(), want))


## Items per minute on a road, for the throughput readout.
func edge_throughput(edge_id: int) -> float:
	if edge_id < 0 or edge_id >= edges.size():
		return 0.0
	var edge: Dictionary = edges[edge_id]
	var carriers: Array = edge["carriers"]
	var moving := 0
	for carrier in carriers:
		if str(carrier["load"]) != "":
			moving += 1
	if carriers.is_empty():
		return 0.0
	var cycle := (float(edge["length"]) / CARRIER_SPEED) * 2.0
	return (float(moving) / float(carriers.size())) * (60.0 / maxf(0.1, cycle))


func _drop_node(node_id: int) -> void:
	if node_id < 0 or node_id >= nodes.size():
		return
	for edge_id in (nodes[node_id]["edges"] as Array).duplicate():
		_remove_edge(int(edge_id))
	var queue: Array[int] = [node_id]
	while not queue.is_empty():
		var index: int = queue.pop_back()
		if index < 0 or index >= nodes.size():
			continue
		nodes[index]["building"] = -1
		if bool(nodes[index]["flag"]):
			cells[int(nodes[index]["cell"])]["flag"] = -1
		nodes.remove_at(index)
		for i in nodes.size():
			nodes[i]["edges"] = (nodes[i]["edges"] as Array).filter(
				func(edge_id: int) -> bool: return edge_id != index
			)
	_routes_dirty = true


func _remove_edge(edge_id: int) -> void:
	if edge_id < 0 or edge_id >= edges.size():
		return
	edges.remove_at(edge_id)
	for i in edges.size():
		edges[i]["id"] = i
	_reset_traffic()


# --- routing ----------------------------------------------------------------

## Flags and buildings that can accept `good`, for one route table.
func _sinks_for(good: String) -> Dictionary:
	var sinks: Dictionary = {}
	if good in CASTLE_SINKS and castle_id >= 0:
		sinks[int(buildings[castle_id]["node"])] = true
	for building in buildings:
		if str(building["owner"]) != "player":
			continue
		var spec := spec_of(str(building["kind"]))
		if int(spec["inputs"].get(good, 0)) > 0:
			sinks[int(building["node"])] = true
	return sinks


func _rebuild_routes() -> void:
	_routes.clear()
	for good in GOODS:
		var distance := PackedInt32Array()
		distance.resize(nodes.size())
		distance.fill(-1)
		var next_hop := PackedInt32Array()
		next_hop.resize(nodes.size())
		next_hop.fill(-1)
		var sinks := _sinks_for(good)
		if sinks.is_empty():
			_routes[good] = {"dist": distance, "next": next_hop, "orphan": true}
			continue
		var queue: Array[int] = []
		for sink in sinks:
			distance[sink] = 0
			queue.append(sink)
		# Breadth-first over the node graph: `next` points one step to a sink.
		var head := 0
		while head < queue.size():
			var node_id: int = queue[head]
			head += 1
			for edge_id in nodes[node_id]["edges"]:
				var edge: Dictionary = edges[edge_id]
				var other: int = int(edge["b"]) if int(edge["a"]) == node_id else int(edge["a"])
				if int(distance[other]) >= 0:
					continue
				distance[other] = int(distance[node_id]) + 1
				next_hop[other] = node_id
				queue.append(other)
		_routes[good] = {"dist": distance, "next": next_hop, "orphan": false}
	_routes_dirty = false


func route_for(good: String) -> Dictionary:
	if _routes_dirty:
		_rebuild_routes()
	if _routes.has(good):
		return _routes[good]
	var empty_distance := PackedInt32Array()
	empty_distance.resize(nodes.size())
	empty_distance.fill(-1)
	var empty_next := PackedInt32Array()
	empty_next.resize(nodes.size())
	empty_next.fill(-1)
	var table := {"dist": empty_distance, "next": empty_next, "orphan": true}
	_routes[good] = table
	return table


## Goods nothing on the map consumes — the common cause of a stalled economy.
func orphan_goods() -> Array[String]:
	var out: Array[String] = []
	for good in GOODS:
		if bool(route_for(good)["orphan"]):
			out.append(good)
	return out


## Items waiting at flags, i.e. visible congestion.
func stuck_goods() -> int:
	var count := 0
	for node in nodes:
		count += (node["queue"] as Array).size()
	return count


# --- Handelswege optimieren --------------------------------------------------
#
# Der Vorschlag „Handelsweg optimieren" ist im Kern eine Frage, die das Spiel
# bisher nicht beantworten konnte: *welche* Straße trägt *welche* Ware. Ohne
# diese Zahl ist jede Optimierung blind — der Spieler sieht nur, dass irgendwo
# Ware liegt, und muss raten, woher sie kam. Erfundene Straßenprioritäten und
# erfundene Umwege wären schlimmer als gar keine, also wird gemessen.
#
# `_tick_carriers` zählt jeden Umschlag je Straße und Ware. Daraus entstehen
# zwei Dinge: ein Bericht (`trade_report`) und ein Griff
# (`optimize_trade_routes`), der genau die zwei Stellschrauben nachjustiert,
# die es in Siedler 1 gab — die Strecke teilen und die Priorität verschieben.
#
# Der Griff ist bewusst konservativ, weil eine Optimierung dem Spieler nie
# etwas nehmen darf:
#  - Prioritäten werden nur *erhöht*, nie gesenkt. Träger gehören zur Straße,
#    auf der sie laufen, und werden nicht umverteilt; eine gesenkte Priorität
#    nähme der Siedlung also nur Träger weg, ohne etwas zu gewinnen.
#  - Eine Extra-Fahne nur dort, wo *gemessen* Ware wartet. `build_road` setzt
#    nach dem Original alle fünf Felder eine; ohne den Stau als Bedingung würde
#    der Optimierer jede Straße bis auf zwei Felder zerteilen. Das wäre mehr
#    Durchsatz und ein Wald aus Fahnen, und beides ist keine Optimierung.
#  - Höchstens `MAX_SPLITS` Fahnen pro Durchgang. Der Griff ist ein Schritt,
#    kein Wald aus Fahnen — wer mehr will, tippt erneut und sieht den Fortschritt.
#  - Der Griff ist wiederholbar und idempotent: zweimal tippen ändert nichts.

## Ab hier lohnt eine Extra-Fahne. `build_road` setzt nach dem Original alle
## `FLAG_SPACING` Felder eine, und darunter zu teilen hieße, die Karte mit
## Fahnen zuzupflastern, ohne die Strecke kürzer zu machen. Der Optimierer geht
## darunter *nur* dort, wo gemessen Ware wartet.
const SPLIT_LENGTH := FLAG_SPACING
## Fahnen je Optimierer-Durchgang. Der Griff soll ein Schritt sein, kein Wald.
const MAX_SPLITS := 4
## Erst ab so vielen gemessenen Umschlägen wird eine Priorität umgehängt. Davor
## wäre das Raten auf ein einzelnes Träger-Los.
const MEASURE_MIN := 12
## Ab so vielen wartenden Waren gilt eine Strecke als verstopft. Zwei sind
## Alltag im Spielbetrieb, vier sind ein Stau.
const ROUTE_JAM := 4
## Wie weit die gesuchte Extra-Fahne höchstens von der Streckenmitte entfernt
## sein darf: ein Anteil der Länge plus ein Feld Toleranz. Sie soll die Mitte
## treffen, nicht das Ende.
const SPLIT_MIDDLE := 0.2


## Wie wertvoll eine Ware für *diese* Siedlung gerade ist, 1 bis 5.
##
## 5 = ein fertiges Gebäude hungert danach, 4 = Nahrung (Siedler hungern
## unabhängig vom Bauplan), 3 = irgendein Abnehmer, 2 = nur die Vorratskammer,
## 1 = Füllgut, 0 = unbekannt.
##
## Das ist bewusst *nicht* die Ware, die eine Zahl am/globalen Katalog nennt,
## sondern die, für die gerade ein Gebäude wirklich wartet. Genau dieser
## Unterschied macht den Vorschlag glaubwürdig: Der Optimierer stuft eine
## Straße danach ein, ob die Siedlung die Ware braucht, nicht danach, ob sie
## sie erzeugen kann.
func trade_value(good: String) -> int:
	if good == "" or not GOODS.has(good):
		return 0
	# Nahrung zuerst: ein Minenhaus ohne Essen ist wertlos, egal was es baut.
	if is_food_good(good):
		return 4
	var hungry := 0
	var wants := 0
	for building in buildings:
		if str(building["owner"]) != "player" or str(building["state"]) != "done":
			continue
		var need := int(spec_of(str(building["kind"]))["inputs"].get(good, 0))
		if need <= 0:
			continue
		wants += 1
		if int((building["input"] as Dictionary).get(good, 0)) < need:
			hungry += 1
	if hungry > 0:
		return 5
	if wants > 0:
		return 3
	if good in CASTLE_SINKS:
		return 2
	return 1


## Die Priorität, die eine Straße verdient, die `good` transportiert: sie folgt
## dem Wert der Ware. `2` reicht für Füllgut, `6` für eine, auf die ein fertiges
## Gebäude wartet. Dieselbe Leiter für jeden, damit der Bericht und der Griff
## nie um eine Stufe streiten.
func priority_for(good: String) -> int:
	match trade_value(good):
		5: return 6
		4: return 5
		3: return 4
		2: return 3
	return 2


## Ware, die an den beiden Endpunkten einer Strecke liegt und auf einen Träger
## wartet. Beide Enden zählen: die Strecke ist voll, sobald an *einem* nichts
## mehr abfließt.
func _edge_waiting(edge: Dictionary) -> int:
	var total := 0
	for node_id in [int(edge["a"]), int(edge["b"])]:
		if node_id >= 0 and node_id < nodes.size():
			total += (nodes[node_id]["queue"] as Array).size()
	return total


## Staut sich auf dieser Strecke Ware? Das ist die *einzige* Bedingung, unter der
## der Optimierer eine Extra-Fahne setzt — und sie ist eine Messung, keine
## Vermutung: gezählt wird, was tatsächlich wartet.
func _is_jammed(edge: Dictionary) -> bool:
	return _edge_waiting(edge) >= ROUTE_JAM


## Wie viele Träger eine Strecke dadurch gewinnt, dass man sie teilt. Ein
## positiver Wert heißt: die Strecke ist länger als die eigene Fahnenweite und
## hat zu wenige Träger; `0` heißt: teilen lohnt hier nichts, und der
## Optimierer lässt die Finger davon.
func split_gain(edge: Dictionary) -> int:
	if str(edge["kind"]) != "road":
		return 0
	var length := float(edge["length"])
	if length <= SPLIT_LENGTH:
		return 0
	var priority := int(edge["priority"])
	var before := (edge["carriers"] as Array).size()
	# Geteilte Strecken sind jede halb so lang, und genau daraus leitet
	# `carrier_count_for` die Trägerzahl ab.
	var after := 0
	for i in 2:
		after += carrier_count_for(length * 0.5, priority)
	return after - before


## Das Feld neben der Streckenmitte, in dem eine Extra-Fahne das meiste
## brächte, `-1` wenn die Strecke zu kurz ist oder das Feld belegt ist.
##
## Der Mittelpunkt wird bewusst *nicht* auf das Feld genau in der Mitte gelegt:
## Liegt dort ein Haus, geht die Fahne an die nächste Lücke, denn eine Fahne
## mitten im Haus ist keine.
func best_split_cell(edge: Dictionary) -> int:
	if split_gain(edge) <= 0:
		return -1
	var a: Dictionary = nodes[int(edge["a"])]
	var b: Dictionary = nodes[int(edge["b"])]
	var mid := (Vector2(float(a["x"]), float(a["z"])) + Vector2(float(b["x"]), float(b["z"]))) * 0.5
	var best := -1
	var best_distance := 0.0
	for i in nodes.size():
		var node: Dictionary = nodes[i]
		# Nur Flaggen sind Kandidaten: bei einem Gebäude wäre eine Fahne
		# doppelt gemünzt, das Haus ist selbst ein Verkehrsknoten.
		if not bool(node["flag"]):
			continue
		var d := Vector2(float(node["x"]), float(node["z"])).distance_to(mid)
		if d > float(edge["length"]) * SPLIT_MIDDLE + 1.0:
			continue
		var cell := int(node["cell"])
		# Steht auf dem Feld wirklich *diese* Fahne? Sonst wäre es ein Feld,
		# auf dem schon eine andere steht, und die kann man nicht doppelt setzen.
		if cell < 0 or cell >= cells.size() or int(cells[cell]["flag"]) != int(node["id"]):
			continue
		if best < 0 or d < best_distance:
			best = cell
			best_distance = d
	# Gibt es in der Mitte keine Fahne, wird eine neue gesetzt — dafür muss das
	# Feld frei sein. Die engste Lücke um die Mitte herum gewinnt, und ein
	# völlig verbautes Kreuz zwingt zum weiteren Umkreis.
	if best < 0:
		var centre := world_to_cell(mid.x, mid.y)
		if centre < 0:
			return -1
		best = _free_cell_near(centre, 1)
		if best < 0:
			best = _free_cell_near(centre, 2)
	return best


## Das nächste freie Feld für eine Fahne, in einem kleinen Fenster um
## `near_cell` gesucht — nicht über die ganze Karte, denn das hier läuft für
## jede Strecke des Berichts. Nur Gras ohne Gebäude: Wasser trägt keine Fahne,
## und ein Haus steht dort schon. Das Feld muss *nicht* flach sein — Fahnen
## brauchen keinen Planierer.
func _free_cell_near(near_cell: int, radius: int = 1) -> int:
	if near_cell < 0 or near_cell >= cells.size():
		return -1
	var cx: int = near_cell % map_size
	var cy: int = near_cell / map_size
	var origin := cell_to_world(near_cell)
	var best := -1
	var best_distance := 2.5
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var x := cx + dx
			var y := cy + dy
			if not in_bounds(x, y):
				continue
			var index := cell_index(x, y)
			if not _flag_free(index):
				continue
			var d := cell_to_world(index).distance_to(origin)
			if d < best_distance:
				best_distance = d
				best = index
	return best


## Kann auf diesem Feld eine Fahne stehen? Ein Haus ist selbst ein Knoten, und
## Wasser trägt keinen Träger.
func _flag_free(cell: int) -> bool:
	if cell < 0 or cell >= cells.size():
		return false
	var map_cell: Dictionary = cells[cell]
	if int(map_cell["building"]) >= 0 or int(map_cell["flag"]) >= 0:
		return false
	return str(map_cell["res"]) != "water"


## Eine Änderung am Straßennetz macht die Messung wertlos: die Kanten-Ids
## verschieben sich, und alte Zahlen würden die falschen Straßen belohnen. Also
## fängt das Zählen danach wieder bei null an — genau das ist der Moment, in
## dem der Spieler zum ersten Mal optimiert.
func _reset_traffic() -> void:
	_traffic.clear()
	_traffic_total = 0


## Zählt einen Umschlag auf der Kante, damit der Bericht weiß, was wo
## entlanggeht. Wird nur aufgerufen, wenn ein Träger *etwas* aufnimmt, kostet
## es also eine Zahl und ein Feld pro gelieferter Ware — nicht pro Frame.
func _count_carrier(edge_id: int, good: String) -> void:
	if good == "" or edge_id < 0 or edge_id >= edges.size():
		return
	var index := GOODS.find(good)
	if index < 0:
		return
	# Nur wachsen: eine geschrumpfte Tabelle gehört zu einem Netz, das es nicht
	# mehr gibt, und wird durch `_reset_traffic` ohnehin geleert.
	var want := edges.size() * GOODS.size()
	if _traffic.size() < want:
		var have := _traffic.size()
		_traffic.resize(want)
		for i in range(have, want):
			_traffic[i] = 0
	var slot := edge_id * GOODS.size() + index
	if slot >= _traffic.size():
		return
	_traffic[slot] += 1
	_traffic_total += 1


## Zählt den Umschlag eines Trägers, der gerade etwas aufgenommen hat.
func _note_traffic(edge: Dictionary, carrier: Dictionary) -> void:
	_count_carrier(int(edge["id"]), str(carrier["load"]))


## Warenumschläge seit der letzten Änderung am Straßennetz. Ohne diese Zahl ist
## jede Empfehlung blind — deshalb ist sie auch Teil des Berichts.
func measured_carriers() -> int:
	return _traffic_total


## Der genaue Verkehr einer Strecke je Ware, gemessen seit der letzten Änderung
## am Straßennetz: `{"total": int, "counts": {Ware: Anzahl}, "best": Ware}`.
## Leer heißt: hier ist nichts gefahren.
##
## Das ist die Messung hinter dem ganzen Vorschlag. Ohne sie wüsste niemand,
## welche Straße welche Ware trägt — und eine Optimierung, die nicht weiß, was
## sie optimiert, ist nur Raten mit einem netten Knopf.
func edge_traffic(edge_id: int) -> Dictionary:
	var counts: Dictionary = {}
	var total := 0
	if edge_id < 0 or edge_id >= edges.size():
		return {"total": 0, "counts": counts, "best": ""}
	var base := edge_id * GOODS.size()
	for i in GOODS.size():
		var slot := base + i
		if slot >= _traffic.size():
			break
		var count := _traffic[slot]
		if count <= 0:
			continue
		counts[GOODS[i]] = count
		total += count
	return {"total": total, "counts": counts, "best": hottest_name(counts)}


## Die meistgefahrene Ware einer Strecke, `""` ohne Verkehr. Bei Gleichstand
## gewinnt die wertvollere — trägt die Strecke beides, geht es um die
## wichtigere, und das ist auch die, für die es Träger braucht.
func hottest_name(counts: Dictionary) -> String:
	var best := ""
	var best_count := 0
	for good in counts:
		var count := int(counts[good])
		if count > best_count or (count == best_count and trade_value(good) > trade_value(best)):
			best_count = count
			best = good
	return best


## Jede Strecke, auf der Ware unterwegs ist — der Bericht, den die Karte
## „Handelswege" anzeigt und aus dem der Optimierer arbeitet.
##
## Auch die kurzen Anliegerstummel zwischen Haus und Fahne stehen drin. Sie
## sind kein Handelsweg im eigentlichen Sinn, tragen aber die halbe Lieferung
## einer jungen Siedlung; sie zu verschweigen hieße, dem Spieler die Zahl
## vorenthalten, nach der er gerade fragt. Der Bericht nennt ihre Sorte, damit
## die Karte sie als das kennzeichnet, was sie sind.
##
## Sortiert nach Verkehr, dann nach Länge: die volle Straße steht oben, weil
## sie die ist, an der sich etwas ändern lässt. Jeder Eintrag trägt dieselben
## Felder, damit der Bildschirm nie raten muss.
func trade_report() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for edge in edges:
		var traffic := edge_traffic(int(edge["id"]))
		var top := str(traffic["best"])
		if top == "":
			continue
		var counts: Dictionary = traffic["counts"]
		var waiting := _edge_waiting(edge)
		var length := float(edge["length"])
		out.append({
			"edge": int(edge["id"]),
			"a": int(edge["a"]),
			"b": int(edge["b"]),
			"kind": str(edge["kind"]),
			"length": length,
			"carriers": (edge["carriers"] as Array).size(),
			"top": top,
			"top_count": int(counts.get(top, 0)),
			"total": int(traffic["total"]),
			"waiting": waiting,
			"jammed": waiting >= ROUTE_JAM,
			"priority": int(edge["priority"]),
			"value": trade_value(top),
			"gain": split_gain(edge),
			"cell": best_split_cell(edge),
			"throughput": edge_throughput(int(edge["id"])),
		})
	out.sort_custom(_busier_route)
	return out


## Sortierregel des Berichts: Verkehr zuerst, dann Länge. Der zweite Schlüssel
## ist nicht Kosmetik — ohne ihn springt die Liste, sobald zwei Straßen
## gleichauf liegen, und der Spieler verliert die Zeile, die er las.
func _busier_route(a: Dictionary, b: Dictionary) -> bool:
	if int(a["total"]) != int(b["total"]):
		return int(a["total"]) > int(b["total"])
	return float(a["length"]) > float(b["length"])


## Was der Optimierer an dieser Strecke tun würde, als ein Satz für die Karte.
## Reihenfolge ist die Dringlichkeit: erst der Stau, dann die zu niedrige
## Priorität, dann der Lauf ohne Handlungsbedarf.
##
## Wichtig: der Satz nennt auch das *Teilen* nur, wenn Ware wartet. Er ist ein
## Rat, kein Befehl — eine Fahne ohne Stau ist Kram, und das soll der Spieler
## hier genauso sehen wie der Optimierer.
func route_advice(entry: Dictionary) -> String:
	var good := str(entry["top"])
	var waiting := int(entry["waiting"])
	# Ein Stummel zwischen Haus und Fahne trägt per Konstruktion genau einen
	# Träger. Ihm eine Priorität zu raten wäre eine Lüge, also sagt der Bericht
	# das auch so — und der Optimierer lässt ihn in Ruhe.
	if str(entry["kind"]) == "link":
		return "Anliegerstrecke zwischen Haus und Fahne — ein Träger, nicht teilbar."
	if bool(entry["jammed"]):
		var hint := "Stau: %d Waren warten an dieser Strecke." % waiting
		if int(entry["cell"]) >= 0:
			return "%s Eine Extra-Fahne bringt %d Träger." % [hint, int(entry["gain"])]
		return hint
	var want := priority_for(good)
	if want > int(entry["priority"]):
		return "„%s“ kommt hier an, aber Priorität %d ist zu niedrig." % [
			good_name(good), int(entry["priority"]),
		]
	return "Läuft: %.0f Felder, %d Träger, Priorität %d." % [
		float(entry["length"]), int(entry["carriers"]), int(entry["priority"]),
	]


## Der eine Handgriff des Vorschlags „Handelsweg optimieren".
##
## Er justiert die zwei Stellschrauben des Originals und sonst nichts:
##  1. eine Extra-Fahne dort, wo gemessen Ware wartet,
##  2. die Priorität auf die Ware heben, die diese Siedlung wirklich braucht.
##
## Beides ist monoton und wiederholbar: Prioritäten werden nur erhöht, es werden
## höchstens `MAX_SPLITS` Fahnen gesetzt, und ein zweiter Durchgang über dieselbe
## Lage ändert nichts mehr. Das ist der ganze Sinn der Sache — ein Griff, der
## schadet, wäre kein Griff, sondern ein zweites Spiel.
##
## Der Bericht nennt jeden Handgriff einzeln, damit der Spieler nachlesen kann,
## was die Maschine an seiner Siedlung geändert hat.
func optimize_trade_routes() -> Array[String]:
	var done: Array[String] = []
	var flags := 0
	var raised := 0

	# 1. Strecken teilen, aber nur dort, wo Ware wartet. Der Stau ist die
	#    Bedingung, nicht die Länge: `build_road` setzt nach dem Original alle
	#    fünf Felder eine Fahne, und ohne den Stau als Maßstab würde der
	#    Optimierer jede Straße bis auf zwei Felder zerteilen.
	#
	#    Nach jedem Schnitt verschieben sich die Kanten-Ids, deshalb wird jede
	#    Strecke über ihre Endpunkte wiedergefunden — und eine Strecke ist danach
	#    endgültig geteilt, steht also in diesem Durchgang kein zweites Mal zur Wahl.
	for entry in trade_report():
		if flags >= MAX_SPLITS:
			break
		if not bool(entry["jammed"]):
			continue
		var edge := _edge_between(int(entry["a"]), int(entry["b"]))
		if edge.is_empty() or split_gain(edge) <= 0:
			continue
		var cell := best_split_cell(edge)
		if cell < 0:
			continue
		if int(cells[cell]["flag"]) < 0 and not _ensure_flag_quiet(cell):
			continue
		var mid := int(cells[cell]["flag"])
		_split_road(edge, mid)
		flags += 1
		var halves := carriers_of(_edge_between(int(entry["a"]), mid)) \
			+ carriers_of(_edge_between(mid, int(entry["b"])))
		done.append("Fahne bei (%d, %d) — die Strecke trägt jetzt %d Träger." % [
			cell % map_size, cell / map_size, halves,
		])

	# 2. Prioritäten anheben, aber nur auf echten Straßen, nur wo wirklich Ware
	#    fließt und nur wo es eine brauchbare Messung gibt. Vor `MEASURE_MIN`
	#    Umschlägen wäre jede Zahl geraten, und auf einem Stummel würde eine
	#    höhere Priorität gar nichts bewirken.
	if measured_carriers() >= MEASURE_MIN:
		for entry in trade_report():
			if str(entry["kind"]) != "road":
				continue
			var edge := _edge_between(int(entry["a"]), int(entry["b"]))
			if edge.is_empty():
				continue
			var want := priority_for(str(entry["top"]))
			if want <= int(edge["priority"]):
				continue
			set_road_priority(int(edge["id"]), want)
			raised += 1
			done.append("Priorität %d → %d auf der Strecke mit „%s“." % [
				int(entry["priority"]), want, good_name(str(entry["top"])),
			])

	if flags <= 0 and raised <= 0:
		if measured_carriers() < MEASURE_MIN:
			done.append("Noch zu wenig Verkehr gemessen — die Strecken bleiben, wie sie sind.")
		else:
			done.append("Nichts zu tun: die Strecken tragen schon, was sie sollen.")
	_notify(_route_summary(flags, raised, done))
	return done


## Trägerzahl einer Strecke, `0` wenn es keine gibt.
func carriers_of(edge: Dictionary) -> int:
	if edge.is_empty():
		return 0
	return (edge["carriers"] as Array).size()


## Die Kante zwischen zwei Knoten, `{}` wenn es keine gibt. Nach jedem Schnitt
## verschieben sich die Ids, deshalb sucht der Optimierer nach Endpunkten
## statt nach Nummer.
func _edge_between(a: int, b: int) -> Dictionary:
	if a < 0 or b < 0 or a >= nodes.size() or b >= nodes.size():
		return {}
	for edge in nodes[a]["edges"]:
		var id := int(edge)
		if id < 0 or id >= edges.size():
			continue
		var other: Dictionary = edges[id]
		var x: int = int(other["a"])
		var y: int = int(other["b"])
		if (x == a and y == b) or (x == b and y == a):
			return other
	return {}


## Setzt eine Fahne, ohne eine Meldung zu erzeugen — der Optimierter hat seine
## eigene Liste, und zwei Meldungen für einen Handgriff sind eine zu viel.
func _ensure_flag_quiet(cell: int) -> bool:
	if cell < 0 or cell >= cells.size() or not _flag_free(cell):
		return false
	_ensure_flag(cell)
	return true


## Eine Zeile Zusammenfassung für die Meldung, damit der Spieler auch ohne die
## Karte weiß, was passiert ist.
func _route_summary(flags: int, raised: int, done: Array[String]) -> String:
	if flags <= 0 and raised <= 0:
		return done[0] if not done.is_empty() else "Die Handelswege sind in Ordnung."
	var parts: Array[String] = []
	if flags > 0:
		parts.append("eine Fahne" if flags == 1 else "%d Fahnen" % flags)
	if raised > 0:
		parts.append("eine Priorität" if raised == 1 else "%d Prioritäten" % raised)
	return "Handelswege optimiert: " + " und ".join(parts) + "."


# --- ticking ----------------------------------------------------------------

func tick(delta_raw: float) -> void:
	if won or lost:
		return
	var delta := minf(0.25, delta_raw) * speed
	if delta <= 0.0:
		return
	time += delta
	if notice_time > 0.0:
		notice_time -= delta_raw
		if notice_time <= 0.0:
			notice = ""
	if _routes_dirty:
		_rebuild_routes()

	_tick_construction(delta)
	_tick_production(delta)
	_tick_serfs(delta)
	_tick_carriers(delta)
	_tick_food(delta)
	_tick_military(delta)
	_check_victory()


## An idle settler who can take `tool` — either already holding it, or free and
## able to pick one up from the castle store. Permanently assigned settlers are
## never borrowed, so a busy workforce genuinely slows construction.
func _find_worker_for(tool: String) -> Dictionary:
	for serf in serfs:
		if str(serf["owner"]) != "player" or int(serf["building"]) >= 0:
			continue
		if tool == "":
			return serf
		if str(serf["tool"]) == tool:
			return serf
		if str(serf["tool"]) == "" and int(store.get(tool, 0)) > 0:
			return serf
	return {}


## Hands a tool from the castle store to a settler, if one is available.
func _equip(serf: Dictionary, tool: String) -> bool:
	if tool == "":
		return true
	if str(serf["tool"]) == tool:
		return true
	if int(store.get(tool, 0)) <= 0:
		return false
	store[tool] = int(store[tool]) - 1
	serf["tool"] = tool
	return true


func _tick_construction(delta: float) -> void:
	for building in buildings:
		if str(building["owner"]) != "player":
			continue
		var state := str(building["state"])
		if state != "levelling" and state != "building":
			continue
		# Levelling needs a Schaufel, raising the walls needs a Hammer.
		var tool := "shovel" if state == "levelling" else "hammer"
		var duration := LEVEL_TIME if state == "levelling" else BUILD_TIME
		var worker := _find_worker_for(tool)
		if worker.is_empty() or not _equip(worker, tool):
			building["status"] = state
			continue
		worker["state"] = "work"
		building["progress"] = float(building["progress"]) + delta / duration
		if float(building["progress"]) < 1.0:
			continue
		building["progress"] = 0.0
		# The settler goes back to the pool but *keeps* their tool, exactly as in
		# the original — tools are personal kit, not a consumable.
		worker["building"] = -1
		worker["state"] = "idle"
		if state == "levelling":
			building["state"] = "building"
		else:
			building["state"] = "done"
			# Level the plot so the finished building sits square.
			var cell: int = building["cell"]
			cells[cell]["height"] = snappedf(float(cells[cell]["height"]), 1.0)
		if int(spec_of(str(building["kind"]))["territory"]) > 0:
			refresh_territory()


## The castle is the settlement's warehouse, so it also *issues* materials to
## workshops that are short. Produced goods always travel by road; only the
## central stockpile hands out inputs directly, which keeps the Schlosserei
## bootstrap-able and stops the whole economy stalling on one missing delivery.
func _pull_from_store(building: Dictionary, need: Dictionary) -> bool:
	var took := false
	for good in GOODS:
		var want := int(need.get(good, 0))
		if want <= 0:
			continue
		var input: Dictionary = building["input"]
		var missing := want - int(input.get(good, 0))
		if missing <= 0:
			continue
		var available := mini(missing, int(store.get(good, 0)))
		if available <= 0:
			continue
		store[good] = int(store[good]) - available
		stock_add(input, good, available)
		took = true
	return took


func _tick_production(delta: float) -> void:
	for building in buildings:
		if str(building["state"]) != "done":
			continue
		if bool(building["halted"]):
			building["status"] = "halted"
			continue
		var spec := spec_of(str(building["kind"]))
		if int(spec["workers"]) == 0:
			building["status"] = "ok"
			continue
		if str(building["owner"]) == "rival":
			_rival_produce(building, spec, delta)
			continue

		# Der Stillstandsgrund wird an *einer* Stelle begründet, damit der
		# Ratgeber nie etwas anderes melden kann als der Takt tut.
		var reason := stall_of(building)
		if reason == "noInput":
			# The castle is the settlement's warehouse, so it hands out what it
			# has: one missing delivery must not stall a whole workshop.
			_pull_from_store(building, spec["inputs"])
			if stock_has(building["input"], spec["inputs"]):
				reason = ""
		if reason != "":
			building["status"] = reason
			building["cycle_t"] = 0.0
			continue

		building["status"] = "ok"
		building["cycle_t"] = float(building["cycle_t"]) + delta
		if float(building["cycle_t"]) < float(spec["cycle"]):
			continue
		building["cycle_t"] = float(building["cycle_t"]) - float(spec["cycle"])
		if str(spec["harvest"]) != "":
			var cell: int = building["cell"]
			cells[cell]["amount"] = maxi(0, int(cells[cell]["amount"]) - 1)
		stock_take(building["input"], spec["inputs"])
		var output: Dictionary = building["output"]
		for good in GOODS:
			var amount := int(spec["outputs"].get(good, 0))
			if amount > 0:
				stock_add(output, good, amount)
				produced_total += amount
		# The forester is the only way the wood cycle closes.
		if str(building["kind"]) == "forester":
			_replant(building)
		if str(building["kind"]) == "toolsmith":
			_queue_tool()


## Rivals skip the transport sim and swap goods inside their own camp.
func _rival_produce(building: Dictionary, spec: Dictionary, delta: float) -> void:
	if str(spec["harvest"]) != "" and int(cells[int(building["cell"])]["amount"]) <= 0:
		building["status"] = "noResource"
		return
	if not stock_has(building["input"], spec["inputs"]):
		building["status"] = "noInput"
		building["cycle_t"] = 0.0
		return
	building["status"] = "ok"
	building["cycle_t"] = float(building["cycle_t"]) + delta
	if float(building["cycle_t"]) < float(spec["cycle"]):
		return
	building["cycle_t"] = float(building["cycle_t"]) - float(spec["cycle"])
	if str(spec["harvest"]) != "":
		var cell: int = building["cell"]
		cells[cell]["amount"] = maxi(0, int(cells[cell]["amount"]) - 1)
	stock_take(building["input"], spec["inputs"])
	var output: Dictionary = building["output"]
	for good in GOODS:
		var amount := int(spec["outputs"].get(good, 0))
		if amount > 0:
			stock_add(output, good, amount)
	if str(building["kind"]) == "toolsmith":
		# Rivals keep a token tool supply so their mines stay alive.
		stock_add(output, TOOLS[_rng.randi() % TOOLS.size()], 1)


## Refills a spent forest cell near the forester, so wood is not a dead end.
func _replant(forester: Dictionary) -> void:
	var cell: int = forester["cell"]
	var fx: int = cell % map_size
	var fy: int = cell / map_size
	var best := -1
	# A fully felled stand scores 0, so the comparison has to start above it.
	var best_amount := INF
	for dy in range(-4, 5):
		for dx in range(-4, 5):
			var x := fx + dx
			var y := fy + dy
			if not in_bounds(x, y):
				continue
			var index := cell_index(x, y)
			if str(cells[index]["res"]) != "forest":
				continue
			var amount: int = cells[index]["amount"]
			if amount >= 40:
				continue
			if float(amount) < best_amount:
				best_amount = float(amount)
				best = index
	if best < 0:
		return
	cells[best]["amount"] = mini(90, int(cells[best]["amount"]) + 30)


## The Schlosserei forges one tool per completed cycle: whatever the player
## queued, or — with an empty queue — whatever the most stalled building needs.
func _queue_tool() -> void:
	var tool := ""
	if not tool_queue.is_empty():
		tool = tool_queue.pop_front()
	else:
		tool = _most_wanted_tool()
	if tool == "":
		return
	for building in buildings:
		if str(building["kind"]) == "toolsmith" and str(building["owner"]) == "player":
			stock_add(building["output"], tool, 1)
			produced_total += 1
			return


func _most_wanted_tool() -> String:
	var need: Dictionary = {}
	for building in buildings:
		if str(building["owner"]) != "player" or str(building["state"]) != "done":
			continue
		var spec := spec_of(str(building["kind"]))
		var tool := str(spec["tool"])
		if tool != "" and str(building["status"]) == "noTool":
			need[tool] = int(need.get(tool, 0)) + 1
	var best := ""
	var best_score := 0
	for tool in need:
		var score := int(need[tool]) * 10 + int(good_priority.get(tool, 2))
		if score > best_score:
			best_score = score
			best = tool
	return best


## Queues a tool for the Schlosserei. Returns false when the queue is full.
func request_tool(tool: String) -> bool:
	if tool_queue.size() >= 6:
		_notify("Werkzeugschlange ist voll")
		return false
	tool_queue.append(tool)
	return true


func clear_tool_queue() -> void:
	tool_queue.clear()


func set_good_priority(good: String, value: int) -> void:
	good_priority[good] = clampi(value, 0, 5)


# --- settlers ---------------------------------------------------------------

func serf_quota() -> int:
	var quota := CASTLE_SERFS
	for building in buildings:
		if str(building["owner"]) == "player" and str(building["kind"]) == "warehouse":
			quota += WAREHOUSE_SERFS
	return quota


func current_serfs() -> int:
	var count := 0
	for serf in serfs:
		if str(serf["owner"]) == "player":
			count += 1
	return count


## Hires idle settlers up to the quota, spawning them at the castle.
func _tick_serfs(delta: float) -> void:
	var quota := serf_quota()
	if current_serfs() < quota and castle_id >= 0:
		var node: Dictionary = nodes[int(buildings[castle_id]["node"])]
		serfs.append({
			"id": serfs.size(), "owner": "player", "building": -1, "tool": "",
			"hunger": 0.0, "x": float(node["x"]), "z": float(node["z"]),
			"phase": _rng.randf() * 6.0, "state": "idle",
		})

	# Assign free settlers to workplaces, and hand out the tool they need.
	for building in buildings:
		if str(building["owner"]) != "player" or str(building["state"]) != "done":
			continue
		var spec := spec_of(str(building["kind"]))
		if int(spec["workers"]) == 0:
			continue
		while int(building["workers"]) < int(spec["workers"]):
			var serf := _find_worker_for(str(spec["tool"]))
			if serf.is_empty():
				break
			if str(spec["tool"]) != "" and not _equip(serf, str(spec["tool"])):
				building["status"] = "noTool"
				break
			serf["building"] = int(building["id"])
			serf["state"] = "work"
			building["tool"] = str(spec["tool"])
			building["workers"] = int(building["workers"]) + 1

	# Release workers whose building was demolished or conquered.
	for serf in serfs:
		var building_id: int = serf["building"]
		if building_id < 0:
			continue
		if building_id >= buildings.size():
			serf["building"] = -1
			serf["tool"] = ""
			continue
		if str(buildings[building_id]["owner"]) != str(serf["owner"]):
			serf["building"] = -1
			serf["state"] = "idle"
			serf["tool"] = ""

	_move_serfs(delta)


func _move_serfs(delta: float) -> void:
	for serf in serfs:
		if str(serf["owner"]) != "player":
			continue
		var building_id: int = serf["building"]
		if building_id < 0 or building_id >= buildings.size():
			if castle_id >= 0:
				var node: Dictionary = nodes[int(buildings[castle_id]["node"])]
				serf["x"] = lerpf(float(serf["x"]), float(node["x"]), minf(1.0, delta * 2.0))
				serf["z"] = lerpf(float(serf["z"]), float(node["z"]) + 0.9, minf(1.0, delta * 2.0))
			serf["phase"] = float(serf["phase"]) + delta * 2.0
			continue
		var target: Dictionary = nodes[int(buildings[building_id]["node"])]
		var to_target := Vector2(float(target["x"]) - float(serf["x"]), float(target["z"]) - float(serf["z"]))
		var distance := to_target.length()
		if distance > 0.35:
			var step := minf(distance, SERF_SPEED * delta)
			serf["x"] = float(serf["x"]) + (to_target.x / distance) * step
			serf["z"] = float(serf["z"]) + (to_target.y / distance) * step
			serf["phase"] = float(serf["phase"]) + (step / 0.42) * PI
			serf["state"] = "walk"
		else:
			serf["phase"] = float(serf["phase"]) + delta * 3.0
			serf["state"] = "work"


# --- food -------------------------------------------------------------------

func food_pieces() -> int:
	var total := 0
	for food in FOODS:
		total += int(store.get(food, 0))
	return total


## Settlers that have gone without food.
func hungry_serfs() -> int:
	var count := 0
	for serf in serfs:
		if str(serf["owner"]) == "player" and float(serf["hunger"]) >= 1.0:
			count += 1
	return count


func _tick_food(delta: float) -> void:
	for serf in serfs:
		if str(serf["owner"]) != "player":
			continue
		var building_id: int = serf["building"]
		var spec: Dictionary = {}
		if building_id >= 0 and building_id < buildings.size():
			spec = spec_of(str(buildings[building_id]["kind"]))
		var interval := MINER_EAT_INTERVAL if bool(spec.get("hungry", false)) else EAT_INTERVAL
		serf["hunger"] = float(serf["hunger"]) + delta / interval
		if float(serf["hunger"]) < 1.0:
			continue
		serf["hunger"] = float(serf["hunger"]) - 1.0
		if not _eat():
			serf["hunger"] = 1.2


func _eat() -> bool:
	for food in FOODS:
		if int(store.get(food, 0)) > 0:
			store[food] = int(store[food]) - 1
			return true
	return false


# --- carriers: the relay network -------------------------------------------

func _tick_carriers(delta: float) -> void:
	for edge in edges:
		var a: Dictionary = nodes[int(edge["a"])]
		var b: Dictionary = nodes[int(edge["b"])]
		var step := (CARRIER_SPEED * delta) / maxf(0.6, float(edge["length"]))
		for carrier in edge["carriers"]:
			carrier["t"] = float(carrier["t"]) + step * float(carrier["dir"])
			if float(carrier["t"]) >= 1.0:
				carrier["t"] = 1.0
				_deliver(carrier, b)
				carrier["t"] = 0.0
				carrier["dir"] = -1
				_load_from(carrier, b, a)
				_note_traffic(edge, carrier)
				carrier["waiting"] = 0.0
			elif float(carrier["t"]) <= 0.0:
				carrier["t"] = 0.0
				_deliver(carrier, a)
				carrier["dir"] = 1
				_load_from(carrier, a, b)
				_note_traffic(edge, carrier)
				carrier["waiting"] = 0.0

			# An empty carrier dawdles at the flag before setting off again.
			if str(carrier["load"]) == "" and float(carrier["waiting"]) < 0.6:
				carrier["waiting"] = float(carrier["waiting"]) + delta
				carrier["t"] = float(carrier["t"]) - step * float(carrier["dir"]) * minf(1.0, float(carrier["waiting"]) * 1.5)
				carrier["t"] = clampf(float(carrier["t"]), 0.0, 1.0)

			var pos := float(carrier["t"]) if int(carrier["dir"]) == 1 else 1.0 - float(carrier["t"])
			carrier["x"] = lerpf(float(a["x"]), float(b["x"]), pos)
			carrier["z"] = lerpf(float(a["z"]), float(b["z"]), pos)
			carrier["phase"] = float(carrier["phase"]) + (CARRIER_SPEED * delta) * 2.2


## Hands a carried item over at `node` — the core of the original's relay.
func _deliver(carrier: Dictionary, node: Dictionary) -> void:
	var good := str(carrier["load"])
	carrier["load"] = ""
	if good == "":
		return
	var building_id: int = node["building"]
	if building_id >= 0:
		var building: Dictionary = buildings[building_id]
		var spec := spec_of(str(building["kind"]))
		if int(spec["inputs"].get(good, 0)) > 0:
			stock_add(building["input"], good, 1)
			if str(building["owner"]) == "player":
				delivered_total += 1
			return
		if str(building["kind"]) == "castle" and str(building["owner"]) == "player":
			if int(store.get(good, 0)) < STORE_CAP:
				stock_add(store, good, 1)
				delivered_total += 1
				return
	# Nothing here wants it — it waits and will be carried on.
	(node["queue"] as Array).append(good)


## Picks the highest-priority item at `from` that still has a route via `to`.
func _load_from(carrier: Dictionary, from: Dictionary, to: Dictionary) -> void:
	var from_id := int(from["id"])
	var to_id := int(to["id"])
	var building_id: int = from["building"]
	if building_id >= 0:
		var building: Dictionary = buildings[building_id]
		var output: Dictionary = building["output"]
		# Prefer goods the building has finished, highest priority first.
		var best := ""
		var best_score := -1.0
		for good in GOODS:
			if int(output.get(good, 0)) <= 0:
				continue
			var route := route_for(good)
			if bool(route["orphan"]) or int(route["next"][from_id]) != to_id:
				continue
			var score := _priority_of(good) * 100.0 - float(output[good])
			if score > best_score:
				best_score = score
				best = good
		if best != "":
			output[best] = int(output[best]) - 1
			carrier["load"] = best
			return

	var queue: Array = from["queue"]
	var best_index := -1
	var best_score := -1.0
	for i in queue.size():
		var good := str(queue[i])
		var route := route_for(good)
		if bool(route["orphan"]) or int(route["next"][from_id]) != to_id:
			continue
		var score := _priority_of(good) * 100.0 - float(i)
		if score > best_score:
			best_score = score
			best_index = i
	if best_index >= 0:
		carrier["load"] = str(queue[best_index])
		queue.remove_at(best_index)


func _priority_of(good: String) -> int:
	return int(good_priority.get(good, 1))


# --- Ratgeber: was bremst die Siedlung? --------------------------------------
#
# Das Original kritisierten vor allem zwei Dinge: die steile Lernkurve und den
# unsichtbaren Zustand. Der Zustand ist inzwischen sichtbar — jedes Gebäude
# kennt sein `status`. Was fehlte, war die *Gesamt*antwort: welcher Engpass die
# ganze Siedlung bremst, welche Ware genau fehlt und was der Spieler dagegen
# tun soll. Genau das liefert diese Sektion: eine Rangliste, ein Satz pro
# Ursache, mit einer Maschine, die den nächsten sinnvollen Griff nennt.
#
# Zwei Regeln, die den Ratgeber glaubwürdig machen:
#  - `stall_of` ist die *einzige* Stelle, die einen Stillstand begründet. Der
#    Takt und der Ratgeber fragen dieselbe Frage, also kann die Empfehlung nie
#    dem widersprechen, was der Bildschirm gerade zeichnet.
#  - Jeder Eintrag trägt dieselben Felder, damit der Bildschirm nie raten muss.

## Wie schwer ein Stillstand wiegt. Der Bildschirm färbt den obersten Eintrag
## rot, orange oder ruhig — "die Wirtschaft ist kaputt" und "ein Gebäude
## pausiert" sollen sich unterscheiden.
const SEV_HINT := 1
const SEV_WARNING := 2
const SEV_CRITICAL := 3

## Wie viele Waren an einer Fahne liegen dürfen, bevor der Ratgeber eine
## zusätzliche Fahne vorschlägt. Zwei sind Alltag im Spielbetrieb, fünf sind
## ein Stau.
const JAM_LIMIT := 4

## Das Gebäude, das `good` herstellt — die Antwort auf "was baue ich?", wenn
## eine Werkstatt leer ausgeht. Alle neun Werkzeuge kommen aus der Schlosserei.
static func producer_of(good: String) -> String:
	for spec in SPECS:
		if int(spec["outputs"].get(good, 0)) > 0:
			return str(spec["kind"])
	if good in TOOLS:
		return "toolsmith"
	return ""


## Das Erste, das `building` am Arbeiten hindert, `""` wenn es läuft. Die
## Reihenfolge ist die des Taktes: fehlt einem Gebäude sowohl das Werkzeug
## als auch der Siedler, meldet es das Werkzeug — denn das kann der Spieler
## tatsächlich beschaffen. Bauplätze und bewusst angehaltene Gebäude sind
## keine Stillstände, sondern Absicht.
func stall_of(building: Dictionary) -> String:
	if str(building["state"]) != "done" or bool(building["halted"]):
		return ""
	if str(building["owner"]) == "rival":
		return ""
	var spec := spec_of(str(building["kind"]))
	if int(spec["workers"]) == 0:
		return ""
	# Das Werkzeug sperrt die Arbeit, ganz wie im Original.
	var tool := str(spec["tool"])
	if tool != "" and str(building["tool"]) == "" and int(store.get(tool, 0)) <= 0:
		return "noTool"
	if int(building["workers"]) < int(spec["workers"]):
		return "noWorker"
	if bool(spec["hungry"]) and food_pieces() <= 0:
		return "hungry"
	if str(spec["harvest"]) != "" and int(cells[int(building["cell"])]["amount"]) <= 0:
		return "noResource"
	if (nodes[int(building["node"])]["edges"] as Array).is_empty():
		return "notConnected"
	# Die Burg ist die Vorratskammer und gibt Betriebsstoffe direkt aus, also
	# zählt ihr Lager mit — sonst widerspräche der Ratgeber dem Takt, der den
	# Stoff noch im selben Schritt nachzieht.
	if _missing_input(building) != "":
		return "noInput"
	return ""


## Welcher Rohstoff `building` fehlt — die größte Lücke zuerst, denn
## "Kohle fehlt" muss *eine* Ware nennen, sonst ist es keine Handlung.
## Die Burg zählt mit: sie gibt Betriebsstoffe direkt aus.
func _missing_input(building: Dictionary) -> String:
	var need: Dictionary = spec_of(str(building["kind"]))["inputs"]
	var held: Dictionary = building["input"]
	var worst := ""
	var worst_gap := 0
	for good in GOODS:
		var want := int(need.get(good, 0))
		if want <= 0:
			continue
		var gap := want - int(held.get(good, 0)) - int(store.get(good, 0))
		if gap > worst_gap:
			worst_gap = gap
			worst = good
	return worst


## Jeder Grund, aus dem die Siedlung nicht auf voller Leistung läuft — der
## dringendste zuerst. *Ein* Eintrag pro Ursache, nicht pro Gebäude: sonst
## steht fünfmal derselbe Satz in der Leiste, und der Spieler sieht nicht,
## dass ein einzelnes fehlendes Kohlefeld fünf Werkstätten lahmlegt.
## Eine leere Liste heißt: jedes Gebäude arbeitet.
func bottlenecks() -> Array[Dictionary]:
	var groups: Dictionary = {}
	var keys: Array[String] = []
	var starving := false

	for building in buildings:
		if str(building["owner"]) != "player":
			continue
		var reason := stall_of(building)
		if reason == "":
			continue
		if reason == "hungry":
			# Eine leere Vorratskammer ist *ein* Problem, nicht eines pro
			# hungernden Bergmann — sonst besteht die halbe Zeile aus "Hunger".
			starving = true
			continue
		var good := ""
		if reason == "noTool":
			good = str(spec_of(str(building["kind"]))["tool"])
		elif reason == "noInput":
			good = _missing_input(building)
		var key := reason if good == "" else "%s:%s" % [reason, good]
		if not groups.has(key):
			groups[key] = {"code": reason, "good": good, "ids": [], "kinds": []}
			keys.append(key)
		var group: Dictionary = groups[key]
		(group["ids"] as Array).append(int(building["id"]))
		(group["kinds"] as Array).append(str(spec_of(str(building["kind"]))["name"]))

	var out: Array[Dictionary] = []
	if starving or (food_pieces() <= 0 and hungry_serfs() > 0):
		out.append(_food_entry())
	for key in keys:
		var group: Dictionary = groups[key]
		out.append(_stall_entry(
			str(group["code"]), str(group["good"]), group["ids"], group["kinds"]
		))
	# Eine Burg, die nichts mehr bezahlen kann, ist die eigentliche Sackgasse:
	# Sie blockiert *jeden* Ausweg, den die Liste oben vorschlägt. Sie zählt
	# aber nur, wenn überhaupt etwas stillsteht — eine ärmere, glückliche
	# Siedlung hat keinen Engpass.
	if not out.is_empty() and not _can_build_anything():
		out.append(_no_build_entry(out))
	# Ware, die sich an einer Fahne stapelt, heißt: die Straße ist länger als
	# ihre Trägerzahl verkraftet. Genau die Mechanik des Originals.
	var jam := _worst_jam()
	if jam >= 0:
		out.append(_jam_entry(jam))

	out.sort_custom(_more_urgent)
	return out


## Der eine dringendste Punkt, `{}` wenn nichts ansteht.
func top_bottleneck() -> Dictionary:
	var list := bottlenecks()
	return list[0] if not list.is_empty() else {}


## Dringendste zuerst, danach der Grund, der die meisten Gebäude lahmlegt, und
## zuletzt eine feste Reihenfolge — sonst springt die Karte zwischen zwei
## gleich schlimmen Ursachen hin und her.
func _more_urgent(a: Dictionary, b: Dictionary) -> bool:
	if int(a["severity"]) != int(b["severity"]):
		return int(a["severity"]) > int(b["severity"])
	if int(a["count"]) != int(b["count"]):
		return int(a["count"]) > int(b["count"])
	return str(a["code"]) < str(b["code"])


## Jeder Eintrag trägt dieselben Felder: `severity`, `code`, `title`, `detail`,
## `good`, `building` (anzuspringen), `cell` (anzufunken) und `count`.
func _entry(severity: int, code: String, title: String, detail: String, good: String,
		building_id: int = -1, cell: int = -1, count: int = 1) -> Dictionary:
	return {
		"severity": severity, "code": code, "title": title, "detail": detail,
		"good": good, "building": building_id, "cell": cell, "count": count,
	}


## Die Werkzeuglücke. Die Schlosserei ist der Grund, weshalb das Original
## anfangs so undurchschaubar war: erst Eisen, dann ein Werkzeug, dann die
## nächste Maschine. Der Ratgeber sagt genau das.
func _tool_entry(good: String, ids: Array, kinds: Array) -> Dictionary:
	var forge := _has_kind("toolsmith")
	var fix := "Die Schlosserei schmiedet jedes Werkzeug aus 1 Eisen + 1 Baumstamm."
	if not forge:
		fix = "Baue eine Schlosserei — sie schmiedet jedes Werkzeug aus 1 Eisen + 1 Baumstamm."
	var entry := _entry(
		SEV_WARNING, "noTool", "Werkzeug fehlt: „%s“" % good_name(good),
		"Still: %s. %s" % [_list_text(kinds), fix], good, _first_id(ids), _cell_of(ids), ids.size()
	)
	entry["fix"] = "queueTool" if forge else "build:toolsmith"
	return entry


## Die Rohstofflücke — die häufigste und für einen Anfänger die teuerste.
## Der Ratgeber nennt die Ware *und* das Gebäude, das sie herstellt.
func _input_entry(good: String, ids: Array, kinds: Array) -> Dictionary:
	var kind := producer_of(good)
	var name := str(spec_of(kind)["name"]) if kind != "" else good_name(good)
	var fix := ""
	if kind == "":
		fix = "Auf der Karte kann niemand %s herstellen." % good_name(good)
	elif not _has_kind(kind):
		fix = "Baue eine „%s“ und schließe sie an die Straße an." % name
		if not _can_pay(kind):
			# Sonst tippt der Spieler auf den Vorschlag und bekommt nur
			# "Zu wenig Bauholz" — der Ratgeber soll den Grund selbst nennen.
			fix += " Dafür fehlt der Burg noch Bauholz (%d) bzw. Stein (%d)." % [
				maxi(0, int(spec_of(kind)["cost"]["planks"]) - int(store.get("planks", 0))),
				maxi(0, int(spec_of(kind)["cost"]["stone"]) - int(store.get("stone", 0))),
			]
	elif _is_stalled(kind):
		fix = "Die „%s“ steht selbst still — behebe zuerst ihren Grund." % name
	else:
		fix = "Die „%s“ liefert, aber die Ware kommt nicht an: auf der Strecke fehlen Fahnen." % name
	var entry := _entry(
		SEV_WARNING, "noInput", "Es fehlt: %s" % good_name(good),
		"Still: %s. %s" % [_list_text(kinds), fix], good, _first_id(ids), _cell_of(ids), ids.size()
	)
	if kind != "" and not _has_kind(kind):
		entry["fix"] = "build:%s" % kind
	elif kind != "" and _is_stalled(kind):
		entry["fix"] = "select:%d" % _first_id_of_kind(kind)
	return entry


func _link_entry(ids: Array, kinds: Array) -> Dictionary:
	var entry := _entry(
		SEV_WARNING, "notConnected", "Nicht angeschlossen: „%s“" % str(kinds[0]),
		"Ohne Straße liefert „%s“ nichts. Baue eine Straße von der Burg bis hierher." % str(kinds[0]),
		"", _first_id(ids), _cell_of(ids), ids.size()
	)
	entry["fix"] = "road:%d" % _first_id(ids)
	return entry


## Kein freier Siedler. Das ist die einzige Ursache, die sich von selbst
## auflöst — deshalb der niedrigste Grad, aber ein Bauplatz-Lager hilft.
func _worker_entry(ids: Array, kinds: Array) -> Dictionary:
	var entry := _entry(
		SEV_HINT, "noWorker", "Keine Siedler frei",
		"Still: %s. Baue ein Lager für 6 weitere Siedler, oder warte die laufenden Arbeiten ab." % _list_text(kinds),
		"", _first_id(ids), _cell_of(ids), ids.size()
	)
	entry["fix"] = "build:warehouse"
	return entry


## Die Ader ist leer. Ein neuer Platz ist nötig — genau deshalb nennt der
## Ratgeber das Gebäude, das man wiederholen soll.
func _resource_entry(ids: Array, kinds: Array, kind: String) -> Dictionary:
	var res := str(RES_NAMES.get(str(spec_of(kind)["requires"]), ""))
	var entry := _entry(
		SEV_WARNING, "noResource", "Lagerstätte leer: %s" % res,
		"Still: %s. Die Ader ist erschöpft — setze eine neue „%s“ auf eine andere Stelle." % [
			_list_text(kinds), str(spec_of(kind)["name"]),
		],
		"", _first_id(ids), _cell_of(ids), ids.size()
	)
	entry["fix"] = "build:%s" % kind
	return entry


## Die Vorratskammer ist leer. Höchster Grad: Minen, Schweine und Jäger
## stehen still, und jeder Siedler hungert.
func _food_entry() -> Dictionary:
	var entry := _entry(
		SEV_CRITICAL, "noFood", "Die Siedler hungern",
		"Nahrung: 0. Minen und Vieh stehen still, jeder Siedler verliert Kraft. Baue eine Farm und eine Bäckerei — oder eine Fischerhütte an offenes Wasser.",
		"bread", -1, -1, maxi(1, hungry_serfs())
	)
	entry["fix"] = "book:food"
	return entry


## Die Burg kann nichts mehr bezahlen. Das ist der Moment, in dem ein neuer
## Spieler stecken bleibt: das Bauholz ist ausgegeben, der Schreiner steht
## still, und niemand sagt, dass *das* der Grund ist. Höchster Grad, denn es
## blockiert jeden Ausweg, den die anderen Ratschläge anbieten.
func _no_build_entry(list: Array[Dictionary]) -> Dictionary:
	var cheapest := _cheapest_build()
	var fix := "Behebe zuerst den Stillstand in dieser Liste, dann weiterbauen."
	for entry in list:
		if str(entry["code"]) == "noInput" and str(entry["good"]) == "logs":
			fix = "Zuerst Stämme zum Schreiner schaffen — nur daraus wird wieder Bauholz."
			break
	return _entry(
		SEV_CRITICAL, "noBuild", "Die Burg kann nichts mehr bauen",
		"Die Burg hat %d Bauholz und %d Stein; das billigste Gebäude, ein „%s“, kostet %d Bauholz. %s" % [
			int(store.get("planks", 0)), int(store.get("stone", 0)),
			str(spec_of(cheapest)["name"]), int(spec_of(cheapest)["cost"]["planks"]), fix,
		],
		"planks", -1, -1, 1
	)


## Kann die Burg noch irgendein Gebäude bezahlen?
func _can_build_anything() -> bool:
	for kind in buildable_kinds():
		if _can_pay(kind):
			return true
	return false


## Hat die Burg das Material für ein Gebäude dieser Art?
func _can_pay(kind: String) -> bool:
	var cost: Dictionary = spec_of(kind)["cost"]
	return int(store.get("planks", 0)) >= int(cost["planks"]) \
		and int(store.get("stone", 0)) >= int(cost["stone"])


## Das billigste Gebäude, das der Spieler bauen darf.
func _cheapest_build() -> String:
	var best := ""
	var best_cost := 1 << 30
	for kind in buildable_kinds():
		var cost := int(spec_of(kind)["cost"]["planks"])
		if cost < best_cost:
			best_cost = cost
			best = kind
	return best if best != "" else "woodcutter"


## Ware, die sich an einer Fahne stapelt. Die Lösung ist die Erfindung des
## Originals: die Strecke teilen, damit mehr Träger sie teilen.
func _jam_entry(cell: int) -> Dictionary:
	var node_id := int(cells[cell]["flag"])
	var waiting := 0
	if node_id >= 0 and node_id < nodes.size():
		waiting = (nodes[node_id]["queue"] as Array).size()
	var entry := _entry(
		SEV_HINT, "congestion", "%d Waren stauen sich" % waiting,
		"An der Fahne (%d, %d) wartet Ware auf einen Träger. Eine Extra-Fahne teilt die Strecke und hebt den Durchsatz." % [
			cell % map_size, cell / map_size,
		],
		"", -1, cell, waiting
	)
	entry["fix"] = "flag:%d" % cell
	return entry


## Die am vollsten Fahne, -1 wenn nirgends etwas klemmt.
func _worst_jam() -> int:
	var worst := -1
	var worst_count := JAM_LIMIT
	for i in nodes.size():
		var node: Dictionary = nodes[i]
		if not bool(node["flag"]):
			continue
		var count := (node["queue"] as Array).size()
		if count > worst_count:
			worst_count = count
			worst = int(node["cell"])
	return worst


## Verteilt eine Stillstandsgruppe auf die passenden Einträge. Der Grund einer
## Gruppe ist derselbe, aber ein Platz kann zwei Ursachen haben (leere Ader
## *und* keine Straße) — die zuerst gefundene gewinnt, wie im Takt auch.
func _stall_entry(code: String, good: String, ids: Array, kinds: Array) -> Dictionary:
	match code:
		"noTool":
			return _tool_entry(good, ids, kinds)
		"noInput":
			return _input_entry(good, ids, kinds)
		"notConnected":
			return _link_entry(ids, kinds)
		"noWorker":
			return _worker_entry(ids, kinds)
		"noResource":
			return _resource_entry(ids, kinds, _kind_of(ids))
	return _entry(SEV_HINT, code, str(code), "Still: %s." % _list_text(kinds),
		good, _first_id(ids), _cell_of(ids), ids.size())


## Die erste Bauplatz-Id aus einer Gruppe.
func _first_id(ids: Array) -> int:
	return int(ids[0]) if not ids.is_empty() else -1


## Das Feld, auf dem das erste Gebäude der Gruppe steht.
func _cell_of(ids: Array) -> int:
	var id := _first_id(ids)
	if id < 0 or id >= buildings.size():
		return -1
	return int(buildings[id]["cell"])


func _kind_of(ids: Array) -> String:
	var id := _first_id(ids)
	if id < 0 or id >= buildings.size():
		return ""
	return str(buildings[id]["kind"])


func _first_id_of_kind(kind: String) -> int:
	for building in buildings:
		if str(building["owner"]) == "player" and str(building["kind"]) == kind:
			return int(building["id"])
	return -1


## Hat der Spieler ein Gebäude dieser Art überhaupt?
func _has_kind(kind: String) -> bool:
	return _first_id_of_kind(kind) >= 0


## Steht *irgendein* Gebäude dieser Art still? Dann ist der fehlende Rohstoff
## ein Symptom, und der Ratgeber zeigt auf das eigentliche Problem.
func _is_stalled(kind: String) -> bool:
	for building in buildings:
		if str(building["owner"]) == "player" and str(building["kind"]) == kind:
			if stall_of(building) != "":
				return true
	return false


## "die Schlosserei", "die Schlosserei und die Bäckerei" — ohne Artikel, weil
## der Ratgeber Warennamen immer in Anführungszeichen setzt.
func _list_text(kinds: Array) -> String:
	var parts: Array[String] = []
	for name in kinds:
		var text := str(name)
		if not parts.has(text):
			parts.append(text)
	if parts.size() == 1:
		return "„%s“" % parts[0]
	var last := parts[parts.size() - 1]
	return "%s und „%s“" % ["„%s“" % ", ".join(parts.slice(0, parts.size() - 1)), last]


# --- military ---------------------------------------------------------------

## Gold raises the attackers' morale, exactly as coin sent to a military
## building did in the original. Capped so gold can never replace soldiers.
func attack_morale() -> float:
	return 1.0 + minf(1.0, float(store.get("goldBar", 0)) / 12.0) * 0.8


func _tick_military(delta: float) -> void:
	# A sword + shield pair that reaches the castle is armed into a knight.
	while int(store.get("sword", 0)) > 0 and int(store.get("shield", 0)) > 0:
		store["sword"] = int(store["sword"]) - 1
		store["shield"] = int(store["shield"]) - 1
		knights += 1

	# Idle knights move into an ungarrisoned watchtower, which is what actually
	# grows the territory.
	for building in buildings:
		if str(building["owner"]) != "player" or str(building["state"]) != "done":
			continue
		if int(spec_of(str(building["kind"]))["territory"]) <= 0:
			continue
		if int(building["garrison"]) > 0 or knights <= 0:
			continue
		knights -= 1
		building["garrison"] = int(building["garrison"]) + 1
	refresh_territory()

	for i in range(attacks.size() - 1, -1, -1):
		var attack: Dictionary = attacks[i]
		var target_id: int = int(attack["target"])
		if target_id < 0 or target_id >= buildings.size():
			attacks.remove_at(i)
			continue
		var target: Dictionary = buildings[target_id]
		if str(target["owner"]) == "player":
			attacks.remove_at(i)
			continue
		# Knights march in, then chew through the garrison.
		attack["timer"] = float(attack["timer"]) + delta
		attack["arrived"] = mini(int(attack["sent"]), int(float(attack["timer"]) / 2.2))
		if int(attack["arrived"]) <= 0:
			continue
		target["garrison"] = float(target["garrison"]) - delta * float(attack["arrived"]) * 0.55 * attack_morale()
		if float(target["garrison"]) <= 0.0:
			_conquer(target, attack)


## Sends up to `count` knights at a rival building.
func send_knights(target_id: int, count: int) -> bool:
	if target_id < 0 or target_id >= buildings.size():
		return false
	if str(buildings[target_id]["owner"]) == "player":
		return false
	var send := mini(count, knights)
	if send <= 0:
		_notify("Keine Ritter bereit")
		return false
	knights -= send
	attacks.append({"target": target_id, "sent": send, "arrived": 0, "timer": 0.0})
	return true


func _conquer(target: Dictionary, attack: Dictionary) -> void:
	attacks.erase(attack)
	var was_castle := str(target["kind"]) == "castle"
	target["owner"] = "player"
	target["garrison"] = 0
	target["status"] = "notConnected"
	cells[int(target["cell"])]["building"] = int(target["id"])
	if was_castle:
		var rival_castles := 0
		for id in rival_castle_ids:
			if id < buildings.size() and str(buildings[id]["owner"]) == "rival":
				rival_castles += 1
		if rival_castles == 0:
			won = true
	else:
		_notify("%s erobert — jetzt an die Straße anschließen!" % spec_of(str(target["kind"]))["name"])
	refresh_territory()
	_routes_dirty = true


func _check_victory() -> void:
	if won or lost:
		return
	if castle_id >= 0 and str(buildings[castle_id]["owner"]) == "rival":
		lost = true


# --- score ------------------------------------------------------------------

## One number for the highscore: economy breadth weighted by population.
func score() -> int:
	var done := 0
	for building in buildings:
		if str(building["owner"]) == "player" and str(building["state"]) == "done":
			done += 1
	return int(
		done * 120
		+ current_serfs() * 45
		+ produced_total * 2
		+ territory_share() * 3000.0
		+ (4000 if won else 0)
	)


func _notify(text: String) -> void:
	notice = text
	notice_time = 2.6
