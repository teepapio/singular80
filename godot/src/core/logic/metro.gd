class_name Metro
extends RefCounted
## Rules of "Metropol 3D" — the 3D metro-network builder.
##
## Pure logic, no nodes and no scene tree: the screen builds the 3D world from
## the arrays below and feeds user actions back in. That keeps routing, city
## growth, the card economy and the collapse condition unit-testable, and it
## mirrors how `dragon_flight.gd` and `holdem.gd` are structured.
##
## Port of the 2D game in `~/edi-dev/projects/OluMetro` (Station / Line / Train
## / Passenger / GameManager) rebuilt for a tilted 3D city: lines are rounded
## ribbons, trains follow arc length instead of raw station pairs, and rivers
## are real water the network has to bridge or tunnel.

# --- station kinds ----------------------------------------------------------
## The destination "type" of a station. A passenger always wants to travel to a
## station of the same kind, so the enum doubles as the colour/shape palette.
enum Kind {
	HOME, OFFICE, SHOP, HOSPITAL, SCHOOL, FACTORY, THEATER, SPORTS, HOTEL,
	RESTAURANT, MUSEUM, CHURCH, PARK, AIRPORT, STADIUM, LIBRARY, BANK,
}

## Six geometric symbol families, so a station type is recognisable by its
## silhouette alone — long before the player can read the label.
enum Symbol { ROUND, SQUARE, TRIANGLE, CROSS, STAR, HEX }

# --- line colours -----------------------------------------------------------
enum LineColor { PINK, ORANGE, TEAL, PURPLE, CORAL }

# --- game modes -------------------------------------------------------------
enum Mode { NORMAL, ENDLESS, EXTREME }

## How a line segment deals with water.
enum Crossing { NONE, BRIDGE, TUNNEL, PROVISIONAL }

## How well the queue at a station is served: every line takes the commuters
## off, a few are stuck, or the station has no way out at all.
enum Service { OK, PARTIAL, BLOCKED }

## Display metadata per `Kind`, index-aligned with the enum above.
const TYPES: Array[Dictionary] = [
	{"name": "Wohnen", "glyph": "W", "color": Color("f59e0b"), "symbol": Symbol.ROUND},
	{"name": "Büro", "glyph": "B", "color": Color("3b82f6"), "symbol": Symbol.SQUARE},
	{"name": "Markt", "glyph": "M", "color": Color("10b981"), "symbol": Symbol.TRIANGLE},
	{"name": "Klinik", "glyph": "K", "color": Color("ef4444"), "symbol": Symbol.CROSS},
	{"name": "Schule", "glyph": "S", "color": Color("06b6d4"), "symbol": Symbol.STAR},
	{"name": "Werk", "glyph": "I", "color": Color("78716c"), "symbol": Symbol.HEX},
	{"name": "Theater", "glyph": "T", "color": Color("a855f7"), "symbol": Symbol.STAR},
	{"name": "Sportplatz", "glyph": "P", "color": Color("22c55e"), "symbol": Symbol.ROUND},
	{"name": "Hotel", "glyph": "H", "color": Color("e879f9"), "symbol": Symbol.SQUARE},
	{"name": "Restaurant", "glyph": "R", "color": Color("fb923c"), "symbol": Symbol.TRIANGLE},
	{"name": "Museum", "glyph": "U", "color": Color("c084fc"), "symbol": Symbol.CROSS},
	{"name": "Kirche", "glyph": "C", "color": Color("fcd34d"), "symbol": Symbol.STAR},
	{"name": "Park", "glyph": "A", "color": Color("4ade80"), "symbol": Symbol.HEX},
	{"name": "Flughafen", "glyph": "F", "color": Color("38bdf8"), "symbol": Symbol.ROUND},
	{"name": "Stadion", "glyph": "D", "color": Color("84cc16"), "symbol": Symbol.SQUARE},
	{"name": "Bibliothek", "glyph": "L", "color": Color("94a3b8"), "symbol": Symbol.TRIANGLE},
	{"name": "Bank", "glyph": "N", "color": Color("eab308"), "symbol": Symbol.CROSS},
]

const LINE_COLORS: Array[Color] = [
	Color("ff3399"),
	Color("ff9900"),
	Color("00cccc"),
	Color("9933cc"),
	Color("ff664d"),
]

const LINE_COLOR_NAMES: Array[String] = ["Pink", "Orange", "Türkis", "Violett", "Koralle"]

## Where people want to go, by origin kind, time of day and weekday/weekend.
## Mirrors the commute table of the original game: the clock is not decoration,
## it decides which destinations even exist right now.
const ROUTES: Dictionary = {
	Kind.HOME: {
		"weekday_morning": [Kind.OFFICE, Kind.FACTORY, Kind.HOSPITAL, Kind.SCHOOL],
		"weekday_evening": [Kind.SHOP, Kind.RESTAURANT, Kind.THEATER, Kind.SPORTS],
		"weekend": [Kind.PARK, Kind.MUSEUM, Kind.SPORTS, Kind.RESTAURANT, Kind.THEATER],
		"weekday_night": [],
	},
	Kind.OFFICE: {
		"weekday_morning": [Kind.BANK, Kind.RESTAURANT],
		"weekday_evening": [Kind.HOME, Kind.RESTAURANT, Kind.SHOP],
		"weekday_night": [Kind.BANK, Kind.RESTAURANT],
		"weekend": [],
	},
	Kind.SHOP: {"always": [Kind.HOME, Kind.RESTAURANT, Kind.PARK]},
	Kind.HOSPITAL: {"always": [Kind.HOME]},
	Kind.SCHOOL: {
		"weekday_morning": [Kind.HOME],
		"weekday_evening": [Kind.HOME, Kind.PARK, Kind.SPORTS],
		"weekday_night": [Kind.HOME],
		"weekend": [],
	},
	Kind.FACTORY: {
		"weekday_morning": [Kind.HOME, Kind.SHOP, Kind.RESTAURANT],
		"weekday_evening": [Kind.HOME, Kind.SHOP, Kind.RESTAURANT],
		"weekday_night": [Kind.HOME],
		"weekend": [Kind.HOME],
	},
	Kind.THEATER: {"always": [Kind.HOME, Kind.RESTAURANT]},
	Kind.MUSEUM: {"always": [Kind.HOME, Kind.RESTAURANT]},
	Kind.STADIUM: {"always": [Kind.HOME, Kind.RESTAURANT]},
	Kind.SPORTS: {"always": [Kind.HOME, Kind.RESTAURANT]},
	Kind.PARK: {"always": [Kind.HOME, Kind.RESTAURANT]},
	Kind.RESTAURANT: {"always": [Kind.HOME, Kind.THEATER, Kind.PARK]},
	Kind.HOTEL: {"always": [Kind.MUSEUM, Kind.THEATER, Kind.RESTAURANT, Kind.PARK, Kind.STADIUM]},
	Kind.BANK: {
		"weekday_morning": [Kind.HOME, Kind.OFFICE, Kind.SHOP],
		"weekday_evening": [Kind.HOME, Kind.OFFICE, Kind.SHOP],
		"weekday_night": [Kind.HOME],
		"weekend": [],
	},
	Kind.AIRPORT: {"always": [Kind.HOTEL, Kind.HOME, Kind.OFFICE]},
	Kind.CHURCH: {
		"weekday_morning": [Kind.HOME],
		"weekday_evening": [Kind.HOME],
		"weekday_night": [Kind.HOME],
		"weekend": [Kind.HOME, Kind.RESTAURANT],
	},
	Kind.LIBRARY: {"always": [Kind.HOME, Kind.SCHOOL]},
}

## Probability that a commuter follows the commute table instead of any random
## other kind present in the city.
const LIKELY_CHANCE := 0.7

# --- tuning -----------------------------------------------------------------
const MAP_SIZE := Vector2(96.0, 68.0)
const MAP_MARGIN := 9.0
## How close a tap has to be to a station to grab it, and how close two stations
## may sit before a new one is placed elsewhere.
const STATION_GRAB := 7.0
const STATION_MIN_GAP := 13.0
const STATION_CAPACITY := 20
## Seconds a station may stay over capacity before the network collapses.
const OVERCROWD_LIMIT := 10.0
## A queue only counts as stranded once at least this many of its commuters
## cannot be moved by any line: one lost ride is normal traffic, three is a
## missing line.
const STRANDED_MIN := 3
## Seconds between two commuters at one station, before the difficulty ramp.
const PASSENGER_SPAWN_BASE := 8.0
const NEW_STATION_BASE := 35.0
## A card is offered every `CARD_INTERVAL_DAYS` days. The 2D original only
## offered one on Sundays, which a mobile run of three to five minutes never
## reaches — every second day keeps the economy visible.
const CARD_INTERVAL_DAYS := 2
const CARD_TITLE := "Planungstag"
## Hard ceiling on commuters in the whole city. Endless mode would otherwise
## grow the pool without bound; the newest spawn is simply skipped instead.
const MAX_PASSENGERS := 600
const DAY_DURATION := 25.7
## The weekly bonus arrives a little after the third card, so the two rewards
## never land on the same second.
const WEEK_DURATION := 102.8
const DAY_NAMES: Array[String] = ["MO", "DI", "MI", "DO", "FR", "SA", "SO"]
const TRAIN_SPEED := 9.0
## Provisional crossings (no bridge token left) crawl along the planks.
const PROVISIONAL_FACTOR := 0.45
const TRAIN_BASE_CAPACITY := 10
const WAGON_CAPACITY := 8
const STATION_WAIT := 0.9
## A passenger is happiest when delivered instantly and gives up after this.
const MAX_WAIT := 120.0
## Below this a delivery still counts as "on time" and pays a bonus.
const PUNCTUAL_WAIT := 30.0
const PUNCTUAL_BONUS := 5
const PUNCTUAL_STREAK_CAP := 5
const MONEY_PER_DELIVERY := 10
const MAX_LINES := 5
const SPEEDS: Array[float] = [0.5, 1.0, 2.0]
const SPEED_NAMES: Array[String] = ["1x", "2x", "3x"]
const SHAPE_CHANGE_MIN := 40.0
const SHAPE_CHANGE_MAX := 80.0
## Seconds between the "type change" warning and the actual change.
const SHAPE_WARNING := 5.0
## Parallel lines at one station are spread apart so their ribbons stay visible.
const PARALLEL_OFFSET := 1.15
const CORNER_RADIUS := 2.6
const CORNER_SAMPLES := 7
const LINE_HALF_WIDTH := 0.62
## Height of a bridge deck and depth of a tunnel below the water plane.
const BRIDGE_HEIGHT := 1.1
const TUNNEL_DEPTH := -1.0
const RIVER_MIN := 1
const RIVER_MAX := 2
const RIVER_WIDTH_MIN := 2.4
const RIVER_WIDTH_MAX := 4.2
const RUSH_DURATION := 14.0
const RUSH_MULTIPLIER := 2.2
## Cards of the Sunday draw and of the weekly reward.
const CARD_POOL: Array[String] = ["train", "train", "wagon", "wagon", "line", "bridge", "tunnel", "transfer"]
const CARD_CHOICES := 3
const START_TRAINS := 4
const START_WAGONS := 3
const START_BRIDGES := 1
const START_TUNNELS := 1
## Difficulty ramp: 1.0 at the start, +1.0 every 120 s of game time. The 2D
## original used 60 s, which reaches 11x after ten minutes and is unsurvivable
## once the depot can only hand out one locomotive per week.
const DIFFICULTY_DIVISOR := 150.0
## Hours of the day that always trigger a rush hour.
const RUSH_HOURS: Array[int] = [8, 17]
## Largest camera distance the game allows, mirrored by the screen.
const CAM_MAX_DISTANCE := 96.0

const CARD_NAMES: Dictionary = {
	"train": "Lokomotive",
	"wagon": "Beiwagen",
	"line": "Neue Linie",
	"bridge": "Brücke",
	"tunnel": "Tunnel",
	"transfer": "Umstiegsfreigabe",
}

const CARD_HINTS: Dictionary = {
	"train": "Setzt eine Lokomotive ins Depot",
	"wagon": "Ein Beiwagen, +6 Sitzplätze",
	"line": "Eine weitere Linienfarbe",
	"bridge": "Volle Geschwindigkeit über Wasser",
	"tunnel": "Unterirdisch durchs Wasser",
	"transfer": "Jeder Fahrgast darf ein Umstieg mehr nutzen",
}

# --- run state --------------------------------------------------------------

var mode: int = Mode.NORMAL
var running: bool = false
var over: bool = false
var speed_index: int = 0

var game_time: float = 0.0
var day_timer: float = 0.0
var week_timer: float = 0.0
var day: int = 0

## `{"id", "type", "pos", "waiting", "lines", "spawn", "over", "shape_in"}`
var stations: Array[Dictionary] = []
## `{"id", "color", "stations", "trains", "loop", "path", "cum", "station_arc",
##   "length", "crossings"}`
var lines: Array[Dictionary] = []
## `{"id", "line", "capacity", "index", "arc", "segment", "stopped", "wait",
##   "forward", "passengers"}`
var trains: Array[Dictionary] = []
## `{"type", "wait", "train", "transfers"}` — a dense pool that stations and
## trains reference by index, so boarding never has to search.
var passengers: Array[Dictionary] = []
## `{"station", "lines"}` — every station served by two or more lines.
var transfers: Array[Dictionary] = []
## Water polygons in the same XZ plane the stations use (Vector2 = x/z).
var rivers: Array[PackedVector2Array] = []

var money: int = 0
var delivered: int = 0
var waiting_total: int = 0
var riding_total: int = 0
var streak: int = 0
var best_streak: int = 0
var punctual: int = 0
## Commuters in the whole city whose destination no line can reach, and how
## many of them wait for a destination kind that no line stops at at all.
## Filled by the demand forecast, read by the HUD and the station markers.
var stranded_total: int = 0
var unmet: Dictionary = {}
var unmet_total: int = 0
var max_lines: int = MAX_LINES
var transfer_permits: int = 1
var resources: Dictionary = {
	"trains": START_TRAINS,
	"wagons": START_WAGONS,
	"bridges": START_BRIDGES,
	"tunnels": START_TUNNELS,
}
var used_colors: Array[int] = []
## Milestone thresholds already celebrated, so the popup fires once per run.
var milestones: Array[int] = []

## One-shot notifications for the screen (deliveries, cards, collapse, hints).
var events: Array[Dictionary] = []
## Modal choices waiting to be shown; the run is frozen while this is non-empty.
var modals: Array[Dictionary] = []

var new_station_timer: float = 0.0
var shape_change_timer: float = 0.0
var rush_active: bool = false
var rush_timer: float = 0.0

var _next_station_id: int = 0
## Recycled slots of `passengers`, so a long run never grows the array.
var _free_passengers: Array[int] = []
var _rush_hours_done: Array[int] = []
var _rng := RandomNumberGenerator.new()


# --- lifecycle --------------------------------------------------------------

## Starts a fresh run. A non-zero `seed_value` makes the city reproducible.
func start(new_mode: int = Mode.NORMAL, seed_value: int = 0) -> void:
	mode = new_mode
	running = true
	over = false
	speed_index = 0
	game_time = 0.0
	day_timer = 0.0
	week_timer = 0.0
	day = 0
	stations = []
	lines = []
	trains = []
	passengers = []
	transfers = []
	rivers = []
	events = []
	modals = []
	used_colors = []
	milestones = []
	money = 0
	delivered = 0
	waiting_total = 0
	riding_total = 0
	streak = 0
	best_streak = 0
	punctual = 0
	stranded_total = 0
	unmet = {}
	unmet_total = 0
	transfer_permits = 1
	resources = {
		"trains": START_TRAINS,
		"wagons": START_WAGONS,
		"bridges": START_BRIDGES,
		"tunnels": START_TUNNELS,
	}
	max_lines = MAX_LINES
	_next_station_id = 0
	_free_passengers = []
	_rush_hours_done = []
	rush_active = false
	rush_timer = 0.0
	_rng.seed = seed_value if seed_value != 0 else (int(Time.get_unix_time_from_system() * 1000.0) ^ randi()) | 1
	_generate_rivers()
	for pos in initial_station_positions(3):
		_spawn_station_at(pos, _unused_kind())
	new_station_timer = NEW_STATION_BASE
	shape_change_timer = 60.0
	emit_event("start", {})


func speed() -> float:
	return SPEEDS[clampi(speed_index, 0, SPEEDS.size() - 1)]


func cycle_speed() -> void:
	speed_index = (speed_index + 1) % SPEEDS.size()


## Unlimited capacity in Endless mode, so `capacity_of` never divides by zero.
func capacity_of(_station_id: int) -> int:
	if mode == Mode.ENDLESS:
		return 1 << 20
	return STATION_CAPACITY


## True while a card/upgrade choice is on screen — the world is frozen then.
func frozen() -> bool:
	return not modals.is_empty()


# --- main loop --------------------------------------------------------------

## Advances the simulation. `delta` is real seconds; the game clock scales it.
func update(delta: float) -> void:
	if over or not running or frozen():
		return
	var dt: float = minf(delta, 0.05) * speed()
	if dt <= 0.0:
		return
	game_time += dt
	day_timer += dt
	if day_timer >= DAY_DURATION:
		day_timer -= DAY_DURATION
		_advance_day()
	week_timer += dt
	if week_timer >= WEEK_DURATION:
		week_timer -= WEEK_DURATION
		_offer_upgrade()
	_update_growth(dt)
	update_train_segments()
	_update_stations(dt)
	_update_trains(dt)
	_update_service()
	_recount()
	_celebrate()


func _advance_day() -> void:
	day = (day + 1) % 7
	_rush_hours_done = []
	emit_event("day", {"day": day})
	if day % CARD_INTERVAL_DAYS == 0:
		_offer_cards()


# --- city growth ------------------------------------------------------------

func _update_growth(dt: float) -> void:
	if rush_active:
		rush_timer -= dt
		if rush_timer <= 0.0:
			rush_active = false
			emit_event("rush_over", {})
	var hour := hour_of_day()
	if RUSH_HOURS.has(hour) and not _rush_hours_done.has(hour):
		_rush_hours_done.append(hour)
		trigger_rush()

	new_station_timer -= dt * difficulty()
	if new_station_timer <= 0.0:
		new_station_timer = NEW_STATION_BASE * _rng.randf_range(0.8, 1.2)
		var kind := _unused_kind()
		if kind >= 0:
			var spot := _free_station_position()
			if spot.x > -900.0:
				_spawn_station_at(spot, kind)
				emit_event("new_station", {"pos": spot})

	shape_change_timer -= dt
	if shape_change_timer <= 0.0 and not stations.is_empty():
		shape_change_timer = _rng.randf_range(SHAPE_CHANGE_MIN, SHAPE_CHANGE_MAX)
		var station: Dictionary = stations[_rng.randi() % stations.size()]
		if float(station["shape_in"]) <= 0.0:
			station["shape_in"] = SHAPE_WARNING
			emit_event("shape_warning", {"station": int(station["id"])})


## Rush hour: a short burst of extra passengers announced by the city.
func trigger_rush(duration: float = RUSH_DURATION) -> void:
	if rush_active or over:
		return
	rush_active = true
	rush_timer = duration
	emit_event("rush", {"duration": duration})


# --- stations & passengers --------------------------------------------------

func _update_stations(dt: float) -> void:
	var pressure := difficulty() * (RUSH_MULTIPLIER if rush_active else 1.0)
	for station in stations:
		var waiting: Array = station["waiting"]
		for pid in waiting:
			passengers[int(pid)]["wait"] = float(passengers[int(pid)]["wait"]) + dt

		# Type change: warn first, then swap.
		var shape_in := float(station["shape_in"])
		if shape_in > 0.0:
			shape_in -= dt
			if shape_in <= 0.0:
				_change_station_kind(station)
				shape_in = -1.0
			station["shape_in"] = shape_in

		# Overcrowding is the actual fail state, with a visible countdown.
		var over_timer := float(station["over"])
		if waiting.size() > capacity_of(int(station["id"])):
			if over_timer <= 0.0:
				emit_event("overcrowd", {"station": int(station["id"])})
			over_timer += dt
			if over_timer >= OVERCROWD_LIMIT:
				collapse(int(station["id"]))
				return
		elif over_timer > 0.0:
			over_timer = 0.0
		station["over"] = over_timer

		# New commuters, but only where a line already stops.
		var spawn := float(station["spawn"]) - dt * pressure
		if spawn <= 0.0:
			var base := PASSENGER_SPAWN_BASE / difficulty()
			spawn = _rng.randf_range(base * 0.5, base * 1.5)
			if not (station["lines"] as Array).is_empty():
				_spawn_passenger(station)
		station["spawn"] = spawn


func _spawn_passenger(station: Dictionary) -> void:
	if passengers.size() >= MAX_PASSENGERS:
		return
	var kind := _pick_destination(int(station["type"]))
	if kind < 0:
		return
	(station["waiting"] as Array).append(_alloc_passenger(kind))


## Reserves a pool slot for a new commuter and returns its index.
func _alloc_passenger(kind: int) -> int:
	var record := {
		"type": kind,
		"wait": 0.0,
		"train": -1,
		"transfers": transfer_permits,
	}
	if _free_passengers.is_empty():
		passengers.append(record)
		return passengers.size() - 1
	var index: int = _free_passengers.pop_back()
	passengers[index] = record
	return index


## Releases a pool slot. Every station and train must already have dropped its
## reference, which is what the callers guarantee.
func _drop_passenger(index: int) -> void:
	if index < 0 or index >= passengers.size():
		return
	passengers[index] = {}
	_free_passengers.append(index)


## Commute table first, any other kind in the city as the fallback.
func _pick_destination(origin: int) -> int:
	var present: Array[int] = []
	for station in stations:
		var kind := int(station["type"])
		if kind != origin and not present.has(kind):
			present.append(kind)
	if present.is_empty():
		return -1
	var likely := likely_destinations(origin, day, hour_of_day(), present)
	if likely.is_empty():
		return int(present[_rng.randi() % present.size()])
	if _rng.randf() >= LIKELY_CHANCE:
		return int(present[_rng.randi() % present.size()])
	return int(likely[_rng.randi() % likely.size()])


## Mean happiness of everyone in the network, 0..100.
func happiness() -> float:
	var total := 0.0
	var count := 0
	for station in stations:
		for pid in station["waiting"]:
			total += passenger_happiness(float(passengers[int(pid)]["wait"]))
			count += 1
	for train in trains:
		count += (train["passengers"] as Array).size()
		total += 100.0 * float((train["passengers"] as Array).size())
	if count == 0:
		return 100.0
	return total / float(count)


## The station closest to collapsing, or -1. Drives the warning ring and HUD.
func critical_station() -> int:
	var worst := -1
	var worst_pressure := 0.0
	for station in stations:
		var over_timer := float(station["over"])
		var ratio := float((station["waiting"] as Array).size()) / float(capacity_of(int(station["id"])))
		var pressure := over_timer + ratio * OVERCROWD_LIMIT * 0.5
		if pressure > worst_pressure:
			worst_pressure = pressure
			worst = int(station["id"])
	if worst_pressure <= 0.01:
		return -1
	return worst


## Seconds left before the critical station collapses, or -1.
func critical_countdown() -> float:
	var id := critical_station()
	if id < 0:
		return -1.0
	return maxf(OVERCROWD_LIMIT - float(stations[id]["over"]), 0.0)


func _recount() -> void:
	var waiting := 0
	for station in stations:
		waiting += (station["waiting"] as Array).size()
	waiting_total = waiting
	var riding := 0
	for train in trains:
		riding += (train["passengers"] as Array).size()
	riding_total = riding


func collapse(station_id: int) -> void:
	if over:
		return
	over = true
	running = false
	emit_event("over", {
		"station": station_id,
		"money": money,
		"delivered": delivered,
		"punctual": punctual,
		"best_streak": best_streak,
		"time": game_time,
		"days": int(game_time / DAY_DURATION) + 1,
		"lines": lines.size(),
		"trains": trains.size(),
	})


# --- milestones -------------------------------------------------------------

## Small celebrations that make a long run readable. Fired once per threshold.
func _celebrate() -> void:
	_check_milestone(10, "10 Fahrgäste zugestellt", delivered >= 10)
	_check_milestone(50, "50 Fahrgäste zugestellt", delivered >= 50)
	_check_milestone(150, "150 Fahrgäste zugestellt", delivered >= 150)
	_check_milestone(400, "400 Fahrgäste zugestellt", delivered >= 400)
	_check_milestone(5, "5 Züge im Einsatz", trains.size() >= 5)
	_check_milestone(12, "12 Züge im Einsatz", trains.size() >= 12)
	_check_milestone(6, "6 Streckenknoten", transfers.size() >= 6)
	_check_milestone(4, "4 Brücken gebaut", _built("bridge") >= 4)
	_check_milestone(3, "Alle Linienfarben genutzt", lines.size() >= max_lines)


func _check_milestone(threshold: int, text: String, reached: bool) -> void:
	if not reached or milestones.has(threshold):
		return
	milestones.append(threshold)
	emit_event("milestone", {"text": text})


## How many crossings of the given kind exist across the whole network.
func _built(kind: String) -> int:
	var target := int(Crossing.BRIDGE) if kind == "bridge" else int(Crossing.TUNNEL)
	var count := 0
	for line in lines:
		for entry in line["crossings"]:
			if int(entry["kind"]) == target:
				count += 1
	return count


# --- routing ----------------------------------------------------------------

## Stations a train visits after the one it is standing at, in travel order.
static func stations_ahead(sequence: Array, from_station: int) -> Array[int]:
	var out: Array[int] = []
	if sequence.size() < 2:
		return out
	var index := sequence.find(from_station)
	if index < 0:
		return out
	for i in range(1, sequence.size()):
		out.append(int(sequence[(index + i) % sequence.size()]))
	return out


## Can this train still reach the destination, directly or with a transfer?
## `permits` is how many transfers the passenger has left.
func can_train_help(line_id: int, station_id: int, kind: int, permits: int) -> bool:
	var ahead := stations_ahead(lines[line_id]["stations"], station_id)
	for next in ahead:
		if int(stations[next]["type"]) == kind:
			return true
	if permits <= 0:
		return false
	for next in ahead:
		if is_transfer(next) and _other_line_serves_kind(next, line_id, kind):
			return true
	return false


## Should this passenger change trains here? 1 = yes, 0 = no.
func should_transfer(line_id: int, station_id: int, kind: int, permits: int) -> int:
	if permits <= 0 or _line_serves_kind(line_id, kind):
		return 0
	if not is_transfer(station_id):
		return 0
	return 1 if _other_line_serves_kind(station_id, line_id, kind) else 0


func is_transfer(station_id: int) -> bool:
	for entry in transfers:
		if int(entry["station"]) == station_id:
			return true
	return false


func lines_at_station(station_id: int) -> Array[int]:
	var out: Array[int] = []
	for line in lines:
		if (line["stations"] as Array).has(station_id):
			out.append(int(line["id"]))
	return out


func _line_serves_kind(line_id: int, kind: int) -> bool:
	for station_id in lines[line_id]["stations"]:
		if int(stations[int(station_id)]["type"]) == kind:
			return true
	return false


func _other_line_serves_kind(station_id: int, except_line: int, kind: int) -> bool:
	for entry in transfers:
		if int(entry["station"]) != station_id:
			continue
		for other in entry["lines"]:
			if int(other) != except_line and _line_serves_kind(int(other), kind):
				return true
	return false


## Rebuilds the interchange list: every station with two or more lines.
func refresh_transfers() -> void:
	var next: Array[Dictionary] = []
	var served: Dictionary = {}
	for line in lines:
		for station_id in line["stations"]:
			var id := int(station_id)
			if not served.has(id):
				served[id] = [] as Array[int]
			# A ring lists its first station twice — count the line only once.
			if not (served[id] as Array).has(int(line["id"])):
				(served[id] as Array).append(int(line["id"]))
	for key in served:
		var members: Array = served[key]
		if members.size() >= 2:
			next.append({"station": int(key), "lines": members.duplicate()})
	transfers = next
	for station in stations:
		station["lines"] = lines_at_station(int(station["id"]))


# --- demand forecast --------------------------------------------------------

## Grades every queue against the network so the next line can be *planned*
## instead of guessed: a flag on the map says which station is stuck and which
## destination its commuters are waiting for, and the city-wide figures say
## what the next commute peak will ask for.
##
## Everything here is derived from the same `can_train_help` the boarding code
## uses, so a flag never promises a ride the trains would refuse. Only stations
## that really have people in line are examined, which ties the cost to the
## crowd and not to the size of the city.

## Waiting commuters at this station whose destination no line can reach.
func stranded_at(station_id: int) -> int:
	if station_id < 0 or station_id >= stations.size():
		return 0
	return int(stations[station_id].get("stranded", 0))


## The destination the stranded commuters at this station want most, or -1.
func stranded_kind(station_id: int) -> int:
	if station_id < 0 or station_id >= stations.size():
		return -1
	return int(stations[station_id].get("want_kind", -1))


## How well the queue at this station is served right now.
func service_state(station_id: int) -> int:
	var stranded := stranded_at(station_id)
	if stranded <= 0:
		return int(Service.OK)
	if stranded >= STRANDED_MIN:
		return int(Service.BLOCKED)
	return int(Service.PARTIAL)


## The destination breakdown of one station, largest group first. Every entry
## is `{"kind", "want", "route"}`, and `route` false means no line can carry
## them from here — with the transfer permits the network currently has.
func forecast(station_id: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if station_id < 0 or station_id >= stations.size():
		return out
	var station: Dictionary = stations[station_id]
	var wants: PackedInt32Array = station.get("wants", PackedInt32Array())
	var routes: Dictionary = station.get("routes", {})
	for kind in wants.size():
		if int(wants[kind]) <= 0:
			continue
		out.append({"kind": kind, "want": int(wants[kind]), "route": routes.has(kind)})
	out.sort_custom(_by_want)
	return out


static func _by_want(a: Dictionary, b: Dictionary) -> bool:
	return int(a["want"]) > int(b["want"])


## How many commuters wait for a destination kind that no line stops at,
## biggest group first. `{}` when the network covers what the city asks for.
func unmet_top() -> Dictionary:
	var best: Dictionary = {}
	for kind in unmet:
		if best.is_empty() or int(unmet[kind]) > int(best["want"]):
			best = {"kind": int(kind), "want": int(unmet[kind])}
	return best


## One HUD line: what the city is missing right now. Empty when every commuter
## waiting can be moved.
func demand_text() -> String:
	var top := unmet_top()
	if not top.is_empty():
		return "%d warten auf %s — keine Linie fährt dorthin" % [
			int(top["want"]), type_name(int(top["kind"]))]
	if stranded_total > 0:
		return "%d Fahrgäste ohne Anschluss" % stranded_total
	return ""


## The hour of the next commute peak, 0..23 — the running one while it lasts.
func next_peak_hour() -> int:
	var hour := hour_of_day()
	if RUSH_HOURS.has(hour):
		return hour
	for step in range(1, 25):
		var candidate := (hour + step) % 24
		if RUSH_HOURS.has(candidate):
			return candidate
	return hour


## What the next commute peak will ask for: the destination kinds of the
## commute table, weighted by how many commuters leave from that kind here, each
## marked with `route` — whether a line stops at such a station at all.
##
## `hour` defaults to the next peak. A peak that lies ahead of the clock
## belongs to the next day, otherwise the forecast would describe a morning
## that has already passed.
func peak_demand(hour: int = -1) -> Array[Dictionary]:
	var target_day := day
	if hour < 0:
		hour = next_peak_hour()
	if hour < hour_of_day():
		target_day = (day + 1) % 7
	var present: Array[int] = []
	var origins := PackedInt32Array()
	origins.resize(Kind.size())
	for station in stations:
		var kind := int(station["type"])
		if not present.has(kind):
			present.append(kind)
		origins[kind] += 1
	var weight := PackedInt32Array()
	weight.resize(Kind.size())
	for origin in present:
		for target in likely_destinations(origin, target_day, hour, present):
			weight[target] += origins[origin]
	var covered := _covered_kinds()
	var out: Array[Dictionary] = []
	for kind in Kind.size():
		if int(weight[kind]) <= 0:
			continue
		out.append({"kind": kind, "want": int(weight[kind]), "route": covered[kind] == 1})
	out.sort_custom(_by_want)
	return out


## One HUD line: what the next peak wants and whether the network is ready.
func peak_text() -> String:
	var hour := next_peak_hour()
	var open: Array[String] = []
	var asked := false
	for entry in peak_demand(hour):
		asked = true
		if not bool(entry["route"]):
			open.append(type_name(int(entry["kind"])))
	if not asked:
		return ""
	if open.is_empty():
		return "%02d:00 abgedeckt" % hour
	return "%02d:00 ohne Anschluss: %s" % [hour, ", ".join(open)]


## Grades every queue against the network and notes what the city is missing.
## Runs once per tick, after boarding, so the numbers describe what the trains
## have just done.
func _update_service() -> void:
	var served := _served_kinds()
	# Without a transfer permit an interchange opens nothing, so the forecast
	# must not promise a ride the trains would refuse.
	var hubs: Dictionary = _hub_kinds(served) if transfer_permits > 0 else {}
	var covered := _covered_kinds(served)
	var city := PackedInt32Array()
	city.resize(Kind.size())
	var stranded := 0
	for station in stations:
		var wants: PackedInt32Array = station["wants"]
		var stuck: PackedInt32Array = station["stuck"]
		for kind in wants.size():
			wants[kind] = 0
			stuck[kind] = 0
		var waiting: Array = station["waiting"]
		var routes: Dictionary = station["routes"]
		routes.clear()
		# Only a station with a crowd can strand anybody, and the walk over the
		# lines is what makes this the expensive half.
		if not waiting.is_empty():
			for line_id in station["lines"]:
				# A line that was just torn down can still be listed here for a
				# tick; a stale id must not take the forecast down with it.
				if int(line_id) < 0 or int(line_id) >= lines.size():
					continue
				var flags := _kinds_ahead(int(line_id), int(station["id"]), hubs)
				for kind in flags.size():
					if flags[kind] == 1:
						routes[kind] = true
		var count := 0
		var top := -1
		for pid in waiting:
			var kind := int(passengers[int(pid)]["type"])
			wants[kind] += 1
			city[kind] += 1
			if routes.has(kind):
				continue
			stuck[kind] += 1
			count += 1
			if top < 0 or int(stuck[kind]) > int(stuck[top]):
				top = kind
		station["stranded"] = count
		station["want_kind"] = top
		var blocked := count >= STRANDED_MIN
		if blocked and int(station["blocked"]) == 0:
			emit_event("stranded", {"station": int(station["id"]), "kind": top, "count": count})
		station["blocked"] = 1 if blocked else 0
		stranded += count

	var missing: Dictionary = {}
	var total := 0
	for kind in city.size():
		if int(city[kind]) > 0 and covered[kind] == 0:
			missing[kind] = int(city[kind])
			total += int(city[kind])
	for kind in missing:
		if not unmet.has(kind):
			emit_event("unmet", {"kind": int(kind), "want": int(missing[kind])})
	unmet = missing
	unmet_total = total
	stranded_total = stranded


## Per line: which destination kinds it stops at.
func _served_kinds() -> Array:
	var out: Array = []
	for line in lines:
		var flags := PackedByteArray()
		flags.resize(Kind.size())
		for station_id in line["stations"]:
			flags[int(stations[int(station_id)]["type"])] = 1
		out.append(flags)
	return out


## The kinds at least one line stops at anywhere in the network. `served` is
## the per-line table of `_served_kinds` when the caller already has it.
func _covered_kinds(served: Array = []) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(Kind.size())
	if served.is_empty():
		served = _served_kinds()
	for flags in served:
		for kind in flags.size():
			if flags[kind] == 1:
				out[kind] = 1
	return out


## Per interchange: the kinds its lines reach, so `_kinds_ahead` can merge them
## without searching the network again.
func _hub_kinds(served: Array) -> Dictionary:
	var out: Dictionary = {}
	for entry in transfers:
		var merged := PackedByteArray()
		merged.resize(Kind.size())
		for line_id in entry["lines"]:
			var index := int(line_id)
			if index < 0 or index >= served.size():
				continue
			var flags: PackedByteArray = served[index]
			for kind in merged.size():
				if flags[kind] == 1:
					merged[kind] = 1
		out[int(entry["station"])] = merged
	return out


## The destination kinds a commuter at `station_id` can still reach on a train
## of `line_id`: everything the line passes, plus whatever the interchanges on
## the way open up.
func _kinds_ahead(line_id: int, station_id: int, hubs: Dictionary) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(Kind.size())
	for next in stations_ahead(lines[line_id]["stations"], station_id):
		out[int(stations[next]["type"])] = 1
		if not hubs.has(next):
			continue
		var merged: PackedByteArray = hubs[next]
		for kind in out.size():
			if merged[kind] == 1:
				out[kind] = 1
	return out


# --- station creation & growth ----------------------------------------------

func _spawn_station_at(pos: Vector2, kind: int) -> int:
	var id := _next_station_id
	_next_station_id += 1
	var wants := PackedInt32Array()
	wants.resize(Kind.size())
	var stuck := PackedInt32Array()
	stuck.resize(Kind.size())
	stations.append({
		"id": id,
		"type": kind,
		"pos": pos,
		"waiting": [] as Array[int],
		"lines": [] as Array[int],
		"spawn": _rng.randf_range(2.0, 5.0),
		"over": 0.0,
		"shape_in": 0.0,
		# Demand forecast, refilled every tick by `_update_service`.
		"wants": wants,
		"stuck": stuck,
		"routes": {} as Dictionary,
		"stranded": 0,
		"blocked": 0,
		"want_kind": -1,
	})
	return id


## A station changes its kind. Waiting passengers keep their destination, which
## is exactly what makes the warning worth reading before it happens.
func _change_station_kind(station: Dictionary) -> void:
	var before := int(station["type"])
	var kind := _rng.randi() % Kind.size()
	if kind == before:
		kind = (kind + 1) % Kind.size()
	station["type"] = kind
	station["shape_in"] = -1.0
	emit_event("shape_changed", {"station": int(station["id"]), "from": before, "to": kind})


func _unused_kind() -> int:
	var used: Array[int] = []
	for station in stations:
		var kind := int(station["type"])
		if not used.has(kind):
			used.append(kind)
	var free: Array[int] = []
	for kind in Kind.size():
		if not used.has(kind):
			free.append(kind)
	if free.is_empty():
		return _rng.randi() % Kind.size()
	return int(free[_rng.randi() % free.size()])


## Nearest station to a world point, or -1.
func station_at(pos: Vector2, radius: float = STATION_GRAB) -> int:
	var best := -1
	var best_distance := radius
	for station in stations:
		var distance := _station_pos(int(station["id"])).distance_to(pos)
		if distance <= best_distance:
			best_distance = distance
			best = int(station["id"])
	return best


## A spot clear of water and of every existing station, or an off-map marker.
func _free_station_position() -> Vector2:
	for attempt in 50:
		var pos := Vector2(
			_rng.randf_range(MAP_MARGIN, MAP_SIZE.x - MAP_MARGIN),
			_rng.randf_range(MAP_MARGIN, MAP_SIZE.y - MAP_MARGIN)
		)
		if in_rivers(pos):
			continue
		var clear := true
		for station in stations:
			if _station_pos(int(station["id"])).distance_to(pos) < STATION_MIN_GAP:
				clear = false
				break
		if clear:
			return pos
	return Vector2(-1000.0, -1000.0)


## Three starting stations on a jittered grid, so a run never opens in a corner.
static func initial_station_positions(count: int) -> Array[Vector2]:
	var out: Array[Vector2] = []
	if count <= 0:
		return out
	var columns := int(ceil(sqrt(float(count))))
	var rows := int(ceil(float(count) / float(columns)))
	var cell := Vector2(
		(MAP_SIZE.x - MAP_MARGIN * 2.0) / float(maxi(columns, 1)),
		(MAP_SIZE.y - MAP_MARGIN * 2.0) / float(maxi(rows, 1))
	)
	var index := 0
	for row in rows:
		for column in columns:
			if index >= count:
				break
			var base := Vector2(MAP_MARGIN, MAP_MARGIN) + Vector2(
				(float(column) + 0.5) * cell.x,
				(float(row) + 0.5) * cell.y
			)
			out.append(base + Vector2(_slot_jitter(index) * cell.x * 0.3, _slot_jitter(index + 7) * cell.y * 0.3))
			index += 1
	return out


## Deterministic per-slot jitter in -1..1, so the opening city is reproducible.
static func _slot_jitter(index: int) -> float:
	return float((index * 2654435761) % 1024) / 512.0 - 1.0


# --- rivers -----------------------------------------------------------------

## 1-2 winding watercourses, same cubic-Bezier ribbon as the original.
func _generate_rivers() -> void:
	var count := _rng.randi() % (RIVER_MAX - RIVER_MIN + 1) + RIVER_MIN
	for i in count:
		var start_x := _rng.randf_range(MAP_MARGIN + 6.0, MAP_SIZE.x - MAP_MARGIN - 6.0)
		var control := _rng.randi() % 3 + 3
		var centre := PackedVector2Array()
		for j in control:
			var x := clampf(
				start_x + _rng.randf_range(-14.0, 14.0),
				MAP_MARGIN + 2.0,
				MAP_SIZE.x - MAP_MARGIN - 2.0
			)
			var t := float(j) / float(maxi(control - 1, 1))
			centre.append(Vector2(x, MAP_MARGIN * 0.4 + t * (MAP_SIZE.y - MAP_MARGIN * 0.8)))
		rivers.append(ribbon_polygon(centre, _rng.randf_range(RIVER_WIDTH_MIN, RIVER_WIDTH_MAX)))


## Offsets a centre line into a closed polygon of the given width.
static func ribbon_polygon(centre: PackedVector2Array, width: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	if centre.size() < 2:
		return out
	var left := PackedVector2Array()
	var right := PackedVector2Array()
	for i in centre.size():
		var before: Vector2 = centre[maxi(i - 1, 0)]
		var after: Vector2 = centre[mini(i + 1, centre.size() - 1)]
		var direction := after - before
		if direction.length_squared() < 0.000001:
			direction = Vector2.UP
		var normal := Vector2(-direction.y, direction.x).normalized() * (width * 0.5)
		left.append(centre[i] + normal)
		right.append(centre[i] - normal)
	out.append_array(left)
	for i in range(right.size() - 1, -1, -1):
		out.append(right[i])
	return out


func in_rivers(pos: Vector2) -> bool:
	for river in rivers:
		if point_in_polygon(pos, river):
			return true
	return false


static func point_in_polygon(point: Vector2, polygon: PackedVector2Array) -> bool:
	var inside := false
	var count := polygon.size()
	if count < 3:
		return false
	var previous := count - 1
	for current in count:
		var a := polygon[current]
		var b := polygon[previous]
		if (a.y > point.y) != (b.y > point.y):
			if point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x:
				inside = not inside
		previous = current
	return inside


static func segment_intersects(a1: Vector2, a2: Vector2, b1: Vector2, b2: Vector2) -> bool:
	var denominator := (a2.x - a1.x) * (b2.y - b1.y) - (a2.y - a1.y) * (b2.x - b1.x)
	if absf(denominator) < 0.0001:
		return false
	var t := ((b1.x - a1.x) * (b2.y - b1.y) - (b1.y - a1.y) * (b2.x - b1.x)) / denominator
	var u := ((b1.x - a1.x) * (a2.y - a1.y) - (b1.y - a1.y) * (a2.x - a1.x)) / denominator
	return t >= 0.0 and t <= 1.0 and u >= 0.0 and u <= 1.0


static func segment_hits_polygon(a: Vector2, b: Vector2, polygon: PackedVector2Array) -> bool:
	if polygon.size() < 3:
		return false
	if point_in_polygon(a, polygon) or point_in_polygon(b, polygon):
		return true
	for i in polygon.size():
		if segment_intersects(a, b, polygon[i], polygon[(i + 1) % polygon.size()]):
			return true
	return false


func segment_in_rivers(a: Vector2, b: Vector2) -> bool:
	for river in rivers:
		if segment_hits_polygon(a, b, river):
			return true
	return false


# --- geometry ---------------------------------------------------------------

static func point_to_segment_distance(point: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var length_sq := ab.length_squared()
	if length_sq < 0.000001:
		return point.distance_to(a)
	var t := clampf((point - a).dot(ab) / length_sq, 0.0, 1.0)
	return point.distance_to(a + ab * t)


## Straight segments with rounded corners — the iconic metro-map look.
##
## Returns the dense polyline, its cumulative arc lengths and the arc length of
## every station, so a train can be placed by "station index + arc" without
## re-deriving the curve. Stations sit at the middle of their corner arc, which
## is within `CORNER_RADIUS` of where the player tapped.
static func rounded_path(points: PackedVector2Array, closed: bool, radius: float = CORNER_RADIUS, samples: int = CORNER_SAMPLES) -> Dictionary:
	var count := points.size()
	var station_arc := PackedFloat32Array()
	station_arc.resize(maxi(count, 1))
	if count < 2:
		return {"path": PackedVector2Array(), "cum": PackedFloat32Array(), "station_arc": station_arc, "length": 0.0}
	if closed and count >= 4:
		return _ring_path(points, count, radius, samples, station_arc)
	return _open_path(points, count, radius, samples, station_arc)


## A ring stores its first station twice; the corners are built cyclically over
## the real ring so the seam is rounded too.
static func _ring_path(points: PackedVector2Array, count: int, radius: float, samples: int, station_arc: PackedFloat32Array) -> Dictionary:
	var ring := points.slice(0, count - 1)
	var size := ring.size()
	var path := PackedVector2Array()
	var first_radius := minf(radius, ring[0].distance_to(ring[size - 1]) * 0.45)
	path.append(ring[0] + (ring[size - 1] - ring[0]).normalized() * first_radius)
	var arc := 0.0
	for i in size:
		var corner: Vector2 = ring[i]
		var before: Vector2 = ring[(i - 1 + size) % size]
		var after: Vector2 = ring[(i + 1) % size]
		var r := minf(radius, minf(corner.distance_to(before), corner.distance_to(after)) * 0.45)
		if r < 0.05:
			if i > 0:
				arc += path[path.size() - 1].distance_to(corner)
				path.append(corner)
				station_arc[i] = arc
			continue
		var entry := corner + (before - corner).normalized() * r
		var exit := corner + (after - corner).normalized() * r
		arc += path[path.size() - 1].distance_to(entry)
		path.append(entry)
		var middle := arc
		for step in range(1, samples + 1):
			var t := float(step) / float(samples)
			var sample := entry.lerp(corner, t).lerp(corner.lerp(exit, t), t)
			arc += path[path.size() - 1].distance_to(sample)
			path.append(sample)
			if step == samples / 2:
				middle = arc
		station_arc[i] = middle
	station_arc[count - 1] = arc
	return {"path": path, "cum": _cumulative(path), "station_arc": station_arc, "length": arc}


## An open line: the first and last station are the ends, the rest are corners.
static func _open_path(points: PackedVector2Array, count: int, radius: float, samples: int, station_arc: PackedFloat32Array) -> Dictionary:
	var path := PackedVector2Array()
	path.append(points[0])
	station_arc[0] = 0.0
	var arc := 0.0
	for i in range(1, count - 1):
		var corner: Vector2 = points[i]
		var before := points[i - 1]
		var after := points[i + 1]
		var r := minf(radius, minf(corner.distance_to(before), corner.distance_to(after)) * 0.45)
		if r < 0.05:
			arc += path[path.size() - 1].distance_to(corner)
			path.append(corner)
			station_arc[i] = arc
			continue
		var entry := corner + (before - corner).normalized() * r
		var exit := corner + (after - corner).normalized() * r
		arc += path[path.size() - 1].distance_to(entry)
		path.append(entry)
		var middle := arc
		for step in range(1, samples + 1):
			var t := float(step) / float(samples)
			var sample := entry.lerp(corner, t).lerp(corner.lerp(exit, t), t)
			arc += path[path.size() - 1].distance_to(sample)
			path.append(sample)
			if step == samples / 2:
				middle = arc
		station_arc[i] = middle
	arc += path[path.size() - 1].distance_to(points[count - 1])
	path.append(points[count - 1])
	station_arc[count - 1] = arc
	return {"path": path, "cum": _cumulative(path), "station_arc": station_arc, "length": arc}


static func _cumulative(path: PackedVector2Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(maxi(path.size(), 1))
	var total := 0.0
	for i in path.size():
		if i > 0:
			total += path[i].distance_to(path[i - 1])
		out[i] = total
	return out


## World position at an arc length along a path.
static func position_at_arc(path: PackedVector2Array, cum: PackedFloat32Array, arc: float) -> Vector2:
	if path.is_empty():
		return Vector2.ZERO
	if path.size() == 1 or cum.size() != path.size():
		return path[0]
	var target := clampf(arc, 0.0, cum[path.size() - 1])
	for i in range(1, path.size()):
		if cum[i] >= target:
			var span := cum[i] - cum[i - 1]
			var t := 0.0 if span <= 0.0 else (target - cum[i - 1]) / span
			return path[i - 1].lerp(path[i], t)
	return path[path.size() - 1]


## Heading along the path at an arc length, for orienting trains and chevrons.
static func heading_at_arc(path: PackedVector2Array, cum: PackedFloat32Array, arc: float) -> Vector2:
	if path.size() < 2:
		return Vector2.RIGHT
	for i in range(1, path.size()):
		if cum[i] >= arc:
			var direction := path[i] - path[i - 1]
			if direction.length_squared() > 0.000001:
				return direction.normalized()
	return (path[path.size() - 1] - path[path.size() - 2]).normalized()


## Spreads parallel lines apart at shared stations, so ribbons never overlap.
## Uses the same "shared neighbour" test as the original game.
func line_offset(line_id: int, station_index: int) -> Vector2:
	var sequence: Array = lines[line_id]["stations"]
	if station_index < 0 or station_index >= sequence.size():
		return Vector2.ZERO
	var parallel := _parallel_lines(line_id, station_index)
	if parallel.size() <= 1:
		return Vector2.ZERO
	var my_index := parallel.find(line_id)
	if my_index < 0:
		return Vector2.ZERO
	var amount := (float(my_index) - (float(parallel.size()) - 1.0) * 0.5) * PARALLEL_OFFSET
	var direction := Vector2.ZERO
	if station_index > 0:
		direction = _station_pos(int(sequence[station_index])) - _station_pos(int(sequence[station_index - 1]))
	elif station_index < sequence.size() - 1:
		direction = _station_pos(int(sequence[station_index + 1])) - _station_pos(int(sequence[station_index]))
	if direction.length_squared() < 0.000001:
		return Vector2.ZERO
	return Vector2(-direction.y, direction.x).normalized() * amount


## Lines that share a neighbour with this one at the given station, which is
## what makes them run side by side.
func _parallel_lines(line_id: int, station_index: int) -> Array[int]:
	var sequence: Array = lines[line_id]["stations"]
	var out: Array[int] = [line_id]
	var here := int(sequence[station_index])
	var my_before := int(sequence[station_index - 1]) if station_index > 0 else -1
	var my_after := int(sequence[station_index + 1]) if station_index < sequence.size() - 1 else -1
	for other in lines:
		var id := int(other["id"])
		if id == line_id:
			continue
		var other_sequence: Array = other["stations"]
		if not other_sequence.has(here):
			continue
		var at := other_sequence.find(here)
		var their_before := int(other_sequence[at - 1]) if at > 0 else -1
		var their_after := int(other_sequence[at + 1]) if at < other_sequence.size() - 1 else -1
		var shares_side := (my_before >= 0 and my_before == their_before) or (my_after >= 0 and my_after == their_after)
		var crosses_over := (my_before >= 0 and my_before == their_after) or (my_after >= 0 and my_after == their_before)
		if shares_side or crosses_over:
			out.append(id)
	return out


func _station_pos(station_id: int) -> Vector2:
	var raw: Vector2 = stations[station_id]["pos"]
	return raw


# --- line construction ------------------------------------------------------

func can_create_new_line() -> bool:
	return lines.size() < max_lines


## The first colour no line uses yet, or -1.
func available_color() -> int:
	for color in LineColor.size():
		if not used_colors.has(color):
			return color
	return -1


## Begins a new line at `station_id`, or returns -1 when that is impossible.
func begin_line(station_id: int) -> int:
	if station_id < 0 or station_id >= stations.size() or not can_create_new_line():
		return -1
	var color := available_color()
	if color < 0:
		return -1
	var id := lines.size()
	lines.append({
		"id": id,
		"color": color,
		"stations": [station_id] as Array[int],
		"trains": [] as Array[int],
		"loop": false,
		"path": PackedVector2Array(),
		"cum": PackedFloat32Array(),
		"station_arc": PackedFloat32Array(),
		"length": 0.0,
		"crossings": [] as Array[Dictionary],
		# Set by the screen layer: a new line has to be meshed right away.
		"dirty": 1,
	})
	used_colors.append(color)
	refresh_transfers()
	return id


## Rerouting: the player taps a station on an existing line and the line is
## trimmed back to it, so the next taps grow a new branch from there.
##
## Extreme mode forbids this — a linear line may only grow at its far end.
func begin_line_with(line_id: int, station_id: int) -> bool:
	if line_id < 0 or line_id >= lines.size() or station_id < 0:
		return false
	var line: Dictionary = lines[line_id]
	var sequence: Array = line["stations"]
	if not sequence.has(station_id):
		return false
	if mode == Mode.EXTREME:
		if sequence.size() < 2 or int(sequence[sequence.size() - 1]) != station_id:
			return false
	else:
		var index := int(sequence.find(station_id))
		while sequence.size() > index + 1:
			sequence.remove_at(sequence.size() - 1)
	line["loop"] = false
	rebuild_line(line_id)
	refresh_transfers()
	return true


## Extreme mode: only the far end of a linear line may grow.
func can_extend_at(line_id: int, station_id: int) -> bool:
	if mode != Mode.EXTREME:
		return true
	var sequence: Array = lines[line_id]["stations"]
	if sequence.size() < 2:
		return true
	return int(sequence[sequence.size() - 1]) == station_id


## Appends a station while the player chains taps.
## Returns 1 = station added, 2 = ring closed, 0 = rejected.
func extend_line(line_id: int, station_id: int) -> int:
	if line_id < 0 or line_id >= lines.size() or station_id < 0 or station_id >= stations.size():
		return 0
	var line: Dictionary = lines[line_id]
	var sequence: Array = line["stations"]
	if not sequence.has(station_id):
		sequence.append(station_id)
		rebuild_line(line_id)
		refresh_transfers()
		return 1
	# Tapping the first station again with three or more stations closes the ring.
	if sequence.size() >= 3 and int(sequence[0]) == station_id:
		sequence.append(station_id)
		line["loop"] = true
		rebuild_line(line_id)
		refresh_transfers()
		return 2
	return 0


## The player lifted their finger: a finished line gets a depot locomotive, a
## stub with fewer than two stations disappears.
func finish_line(line_id: int) -> void:
	if line_id < 0 or line_id >= lines.size():
		return
	var line: Dictionary = lines[line_id]
	if (line["stations"] as Array).size() < 2:
		_discard_line(line_id)
		return
	if (line["trains"] as Array).is_empty() and int(resources["trains"]) > 0:
		add_train(line_id)


## Drops a line the player cancelled before it had two stations.
func _discard_line(line_id: int) -> void:
	if line_id < 0 or line_id >= lines.size():
		return
	used_colors.erase(int(lines[line_id]["color"]))
	_remove_line_at(line_id)


## Removes a finished line. The train goes back to the depot in Normal and
## Endless mode; Extreme mode locks lines in place.
func remove_line(line_id: int) -> bool:
	if line_id < 0 or line_id >= lines.size() or mode == Mode.EXTREME:
		return false
	var line: Dictionary = lines[line_id]
	for train_id in (line["trains"] as Array).duplicate():
		_drop_train(int(train_id), true)
	used_colors.erase(int(line["color"]))
	_remove_line_at(line_id)
	return true


## Shared teardown: drops the line's trains, refunds its crossings, then shifts
## every remaining line and train onto the new indices.
##
## A line id *is* its index in `lines`, so a removal renumbers both arrays. The
## earlier version handed out ever-growing ids and left the arrays out of sync,
## which silently broke every line built after the first removal.
func _remove_line_at(line_id: int) -> void:
	var line: Dictionary = lines[line_id]
	_refund_crossings(line)
	for train_id in (line["trains"] as Array).duplicate():
		_drop_train(int(train_id), false)
	used_colors.erase(int(line["color"]))
	lines.remove_at(line_id)
	for index in lines.size():
		lines[index]["id"] = index
	for train in trains:
		var owner := int(train["line"])
		if owner == line_id:
			train["line"] = -1
		elif owner > line_id:
			train["line"] = owner - 1
	refresh_transfers()


## Recomputes geometry, parallel offsets and river crossings for one line.
func rebuild_line(line_id: int) -> void:
	if line_id < 0 or line_id >= lines.size():
		return
	var line: Dictionary = lines[line_id]
	_refund_crossings(line)
	var sequence: Array = line["stations"]
	if sequence.size() < 2:
		line["path"] = PackedVector2Array()
		line["cum"] = PackedFloat32Array()
		line["station_arc"] = PackedFloat32Array()
		line["length"] = 0.0
		return
	var raw := PackedVector2Array()
	for index in sequence.size():
		raw.append(_station_pos(int(sequence[index])) + line_offset(line_id, index))
	var built := rounded_path(raw, bool(line["loop"]))
	line["path"] = built["path"]
	line["cum"] = built["cum"]
	line["station_arc"] = built["station_arc"]
	line["length"] = built["length"]
	line["crossings"] = _resolve_crossings(built["path"])


## Gives back the bridge/tunnel tokens the previous rebuild spent, so
## rerouting is free.
func _refund_crossings(line: Dictionary) -> void:
	var bridges := 0
	var tunnels := 0
	for entry in line["crossings"]:
		match int(entry["kind"]):
			int(Crossing.BRIDGE):
				bridges += 1
			int(Crossing.TUNNEL):
				tunnels += 1
	if bridges > 0:
		resources["bridges"] = int(resources["bridges"]) + bridges
	if tunnels > 0:
		resources["tunnels"] = int(resources["tunnels"]) + tunnels
	line["crossings"] = [] as Array[Dictionary]


## Marks every path segment that touches water and pays for it: a bridge if one
## is left, otherwise a tunnel, otherwise a slow provisional plank crossing.
func _resolve_crossings(path: PackedVector2Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var bridges := int(resources["bridges"])
	var tunnels := int(resources["tunnels"])
	for i in range(maxi(path.size() - 1, 0)):
		if not segment_in_rivers(path[i], path[i + 1]):
			continue
		var kind := int(Crossing.PROVISIONAL)
		if bridges > 0:
			bridges -= 1
			kind = int(Crossing.BRIDGE)
		elif tunnels > 0:
			tunnels -= 1
			kind = int(Crossing.TUNNEL)
		out.append({"segment": i, "kind": kind})
	resources["bridges"] = bridges
	resources["tunnels"] = tunnels
	return out


## Crossings on this line that still run on a provisional plank.
func provisional_count(line_id: int) -> int:
	var out := 0
	if line_id < 0 or line_id >= lines.size():
		return out
	for entry in lines[line_id]["crossings"]:
		if int(entry["kind"]) == int(Crossing.PROVISIONAL):
			out += 1
	return out


# --- trains -----------------------------------------------------------------

## Spends a depot locomotive and puts it at the head of a line.
func add_train(line_id: int) -> bool:
	if line_id < 0 or line_id >= lines.size() or int(resources["trains"]) <= 0:
		return false
	var line: Dictionary = lines[line_id]
	if (line["stations"] as Array).size() < 2:
		return false
	resources["trains"] = int(resources["trains"]) - 1
	trains.append({
		"id": trains.size(),
		"line": line_id,
		"capacity": TRAIN_BASE_CAPACITY,
		"index": 0,
		"arc": 0.0,
		"segment": 0,
		"stopped": true,
		"wait": 0.0,
		"forward": true,
		"passengers": [] as Array[int],
	})
	(line["trains"] as Array).append(trains.size() - 1)
	return true


func can_add_wagon(train_id: int) -> bool:
	return int(resources["wagons"]) > 0 and train_id >= 0 and train_id < trains.size()


## +WAGON_CAPACITY seats for one wagon from the depot.
func add_wagon(train_id: int) -> bool:
	if not can_add_wagon(train_id):
		return false
	resources["wagons"] = int(resources["wagons"]) - 1
	trains[train_id]["capacity"] = int(trains[train_id]["capacity"]) + WAGON_CAPACITY
	return true


## Sends a train back to the depot; its riders go home.
func scrap_train(train_id: int) -> bool:
	if mode == Mode.EXTREME or train_id < 0 or train_id >= trains.size():
		return false
	var line_id := int(trains[train_id]["line"])
	if line_id < 0:
		return false
	_drop_train(train_id, false)
	emit_event("scrapped", {"train": train_id, "line": line_id})
	return true


func _drop_train(train_id: int, refund: bool) -> void:
	if train_id < 0 or train_id >= trains.size():
		return
	var line_id := int(trains[train_id]["line"])
	if line_id >= 0 and line_id < lines.size():
		(lines[line_id]["trains"] as Array).erase(train_id)
	for pid in trains[train_id]["passengers"]:
		_drop_passenger(int(pid))
	if refund:
		resources["trains"] = int(resources["trains"]) + 1
	trains.remove_at(train_id)
	# Train ids are their array index, so everything above that index shifts down.
	for index in trains.size():
		trains[index]["id"] = index
	for line in lines:
		var members: Array = line["trains"]
		for slot in members.size():
			var old := int(members[slot])
			members[slot] = old - 1 if old > train_id else old


## Nearest line to a world point, or -1 — used to place a train by tap.
func line_at(pos: Vector2, tolerance: float = 2.6) -> int:
	var best := -1
	var best_distance := tolerance
	for line in lines:
		var path: PackedVector2Array = line["path"]
		for i in range(maxi(path.size() - 1, 0)):
			var distance := point_to_segment_distance(pos, path[i], path[i + 1])
			if distance < best_distance:
				best_distance = distance
				best = int(line["id"])
	return best


## Nearest train to a world point, or -1 — used to attach a wagon.
func train_at(pos: Vector2, radius: float = 3.2) -> int:
	var best := -1
	var best_distance := radius
	for train in trains:
		var distance := train_position(int(train["id"])).distance_to(pos)
		if distance < best_distance:
			best_distance = distance
			best = int(train["id"])
	return best


## World position of a train, derived from its arc length.
func train_position(train_id: int) -> Vector2:
	if train_id < 0 or train_id >= trains.size():
		return Vector2.ZERO
	var line_id := int(trains[train_id]["line"])
	if line_id < 0 or line_id >= lines.size():
		return Vector2.ZERO
	var line: Dictionary = lines[line_id]
	var path: PackedVector2Array = line["path"]
	if path.is_empty():
		return Vector2.ZERO
	var cum: PackedFloat32Array = line["cum"]
	return position_at_arc(path, cum, float(trains[train_id]["arc"]))


## Heading of a train, for orienting the mesh.
func train_heading(train_id: int) -> Vector2:
	if train_id < 0 or train_id >= trains.size():
		return Vector2.RIGHT
	var line_id := int(trains[train_id]["line"])
	if line_id < 0 or line_id >= lines.size():
		return Vector2.RIGHT
	var line: Dictionary = lines[line_id]
	var path: PackedVector2Array = line["path"]
	var cum: PackedFloat32Array = line["cum"]
	if path.is_empty():
		return Vector2.RIGHT
	return heading_at_arc(path, cum, float(trains[train_id]["arc"]))


## Refreshes the path segment each train sits on, so the provisional-crossing
## slow down is a dictionary lookup instead of a search.
func update_train_segments() -> void:
	for train in trains:
		var line_id := int(train["line"])
		if line_id < 0 or line_id >= lines.size():
			continue
		var path: PackedVector2Array = lines[line_id]["path"]
		var cum: PackedFloat32Array = lines[line_id]["cum"]
		if path.size() < 2:
			continue
		var arc := float(train["arc"])
		var segment := 0
		for i in range(1, path.size()):
			segment = i - 1
			if cum[i] >= arc:
				break
		train["segment"] = segment


## Provisional crossings (no bridge token left) crawl along the planks.
func _crossing_factor(line: Dictionary, segment: int) -> float:
	for entry in line["crossings"]:
		if int(entry["segment"]) == segment and int(entry["kind"]) == int(Crossing.PROVISIONAL):
			return PROVISIONAL_FACTOR
	return 1.0


func _update_trains(dt: float) -> void:
	for train in trains:
		var line_id := int(train["line"])
		if line_id < 0 or line_id >= lines.size():
			continue
		var line: Dictionary = lines[line_id]
		if (line["stations"] as Array).size() < 2:
			continue
		if bool(train["stopped"]):
			var wait := float(train["wait"]) + dt
			train["wait"] = wait
			if wait >= STATION_WAIT:
				train["stopped"] = false
				train["wait"] = 0.0
			continue
		_advance_train(train, line, dt)


## Moves a train along its line's arc length and handles the station stop.
## `index` is the station it is heading for, so the direction is implied.
func _advance_train(train: Dictionary, line: Dictionary, dt: float) -> void:
	var sequence: Array = line["stations"]
	var arcs: PackedFloat32Array = line["station_arc"]
	var loop := bool(line["loop"])
	# A ring repeats its first station, so the distinct stops are 0..n-2.
	var stops := sequence.size() - 1 if loop else sequence.size()
	if stops < 1 or arcs.size() < sequence.size():
		return
	var index := clampi(int(train["index"]), 0, stops - 1)
	var step := 1
	if not loop and not bool(train["forward"]):
		step = -1
	var arc := float(train["arc"]) + TRAIN_SPEED * _crossing_factor(line, int(train["segment"])) * dt * float(step)
	var target := float(arcs[index])
	var reached := (step > 0 and arc >= target) or (step < 0 and arc <= target)
	if not reached:
		train["arc"] = arc
		return
	arc = target
	_arrive(train, line, int(sequence[index]))
	if loop:
		index = (index + 1) % stops
	elif step > 0 and index >= stops - 1:
		train["forward"] = false
		index = maxi(index - 1, 0)
	elif step < 0 and index <= 0:
		train["forward"] = true
		index = mini(index + 1, stops - 1)
	else:
		index += step
	train["index"] = index
	train["arc"] = arc
	train["stopped"] = true
	train["wait"] = 0.0


## Unloads everyone who can leave here, then fills up with what fits.
func _arrive(train: Dictionary, line: Dictionary, station_id: int) -> void:
	var station: Dictionary = stations[station_id]
	var line_id := int(line["id"])
	var kind_here := int(station["type"])
	var on_train: Array = train["passengers"]
	var delivered_here: Array[int] = []
	var changing: Array[int] = []
	for index in on_train:
		var passenger: Dictionary = passengers[int(index)]
		var destination := int(passenger["type"])
		if destination == kind_here:
			delivered_here.append(int(index))
		elif should_transfer(line_id, station_id, destination, int(passenger["transfers"])) == 1:
			# The rider stays in the pool and joins this station's queue.
			passenger["transfers"] = int(passenger["transfers"]) - 1
			passenger["wait"] = float(passenger["wait"]) + STATION_WAIT
			(station["waiting"] as Array).append(int(index))
			changing.append(int(index))
			emit_event("transfer", {"pos": station["pos"], "kind": destination})
	for index in delivered_here:
		on_train.erase(index)
	for index in changing:
		on_train.erase(index)
	for index in delivered_here:
		_deliver(index, station)

	var space := int(train["capacity"]) - on_train.size()
	if space <= 0:
		return
	var queue: Array = station["waiting"]
	var boarding: Array[int] = []
	for index in queue:
		if boarding.size() >= space:
			break
		if can_train_help(line_id, station_id, int(passengers[int(index)]["type"]), int(passengers[int(index)]["transfers"])):
			boarding.append(int(index))
	for index in boarding:
		queue.erase(index)
		passengers[index]["train"] = int(train["id"])
		on_train.append(index)


func _deliver(index: int, station: Dictionary) -> void:
	var passenger: Dictionary = passengers[index]
	var on_time := float(passenger["wait"]) <= PUNCTUAL_WAIT
	delivered += 1
	streak += 1
	best_streak = maxi(best_streak, streak)
	if on_time:
		punctual += 1
	var payout := MONEY_PER_DELIVERY
	if on_time:
		payout += PUNCTUAL_BONUS * mini(streak, PUNCTUAL_STREAK_CAP)
	money += payout
	emit_event("delivered", {
		"pos": station["pos"],
		"money": payout,
		"kind": int(passenger["type"]),
		"on_time": on_time,
		"streak": streak,
	})
	_drop_passenger(index)


# --- cards & upgrades -------------------------------------------------------

## Three cards from the shuffled pool, offered every Sunday.
func _offer_cards() -> void:
	var options: Array[Dictionary] = []
	var pool: Array = CARD_POOL.duplicate()
	_shuffle(pool)
	for i in mini(CARD_CHOICES, pool.size()):
		var kind := str(pool[i])
		if kind == "line" and not can_create_new_line():
			kind = "wagon"
		options.append(_card(kind))
	modals.append({"type": "cards", "title": CARD_TITLE, "hint": "Wähle eine Karte", "options": options})


## The weekly reward: one locomotive plus one extra card.
func _offer_upgrade() -> void:
	var pool: Array[String] = ["line", "wagon", "bridge", "tunnel", "transfer"]
	var kind: String = pool[_rng.randi() % pool.size()]
	if kind == "line" and not can_create_new_line():
		kind = "wagon"
	modals.append({
		"type": "upgrade",
		"title": "Wochenbonus",
		"hint": "Ein Zug und ein Extra",
		"options": [_card("train"), _card(kind)],
	})


func _card(kind: String) -> Dictionary:
	return {
		"kind": kind,
		"name": str(CARD_NAMES.get(kind, kind)),
		"hint": str(CARD_HINTS.get(kind, "")),
	}


## The screen pops the next pending modal; `{}` when there is none.
func next_modal() -> Dictionary:
	if modals.is_empty():
		return {}
	return modals.pop_front()


## Applies a chosen card. Returns false for an unknown kind.
func choose_card(kind: String) -> bool:
	match kind:
		"train":
			resources["trains"] = int(resources["trains"]) + 1
		"wagon":
			resources["wagons"] = int(resources["wagons"]) + 1
		"line":
			max_lines += 1
		"bridge":
			resources["bridges"] = int(resources["bridges"]) + 1
		"tunnel":
			resources["tunnels"] = int(resources["tunnels"]) + 1
		"transfer":
			transfer_permits += 1
		_:
			return false
	emit_event("card", {"kind": kind, "name": str(CARD_NAMES.get(kind, kind))})
	return true


func _shuffle(list: Array) -> void:
	for i in range(list.size() - 1, 0, -1):
		var j := _rng.randi() % (i + 1)
		var tmp: Variant = list[i]
		list[i] = list[j]
		list[j] = tmp


# --- scoring ----------------------------------------------------------------

## Money is the score: it rewards both survival time and punctual service.
func score() -> int:
	return money


## Seconds survived, formatted for the game-over card.
func survival_text() -> String:
	var total := int(game_time)
	return "%d:%02d" % [total / 60, total % 60]


# --- events -----------------------------------------------------------------

func emit_event(kind: String, payload: Dictionary) -> void:
	events.append({"kind": kind, "payload": payload})


## Drains the event queue. The screen consumes what it can render.
func take_events() -> Array[Dictionary]:
	var out := events
	events = []
	return out


# --- static lookups ---------------------------------------------------------

static func type_name(kind: int) -> String:
	var index := clampi(kind, 0, TYPES.size() - 1)
	return str(TYPES[index]["name"])


static func type_glyph(kind: int) -> String:
	var index := clampi(kind, 0, TYPES.size() - 1)
	return str(TYPES[index]["glyph"])


static func type_color(kind: int) -> Color:
	var index := clampi(kind, 0, TYPES.size() - 1)
	var value: Color = TYPES[index]["color"]
	return value


static func type_symbol(kind: int) -> int:
	var index := clampi(kind, 0, TYPES.size() - 1)
	return int(TYPES[index]["symbol"])


static func line_color(color: int) -> Color:
	return LINE_COLORS[clampi(color, 0, LINE_COLORS.size() - 1)]


static func line_color_name(color: int) -> String:
	return LINE_COLOR_NAMES[clampi(color, 0, LINE_COLOR_NAMES.size() - 1)]


static func mode_name(value: int) -> String:
	match value:
		Mode.ENDLESS:
			return "Endlos"
		Mode.EXTREME:
			return "Extrem"
	return "Normal"


static func mode_hint(value: int) -> String:
	match value:
		Mode.NORMAL:
			return "Linien frei umbaubar. Eine Station bleibt 10 s überfüllt, kollabiert das Netz."
		Mode.ENDLESS:
			return "Kein Kollaps. Optimiere Wartezeiten, Punktzahl und Zufriedenheit."
		Mode.EXTREME:
			return "Linien sind eingefroren — sie lassen sich nur am Ende verlängern."
	return ""


static func speed_name(index: int) -> String:
	return SPEED_NAMES[clampi(index, 0, SPEED_NAMES.size() - 1)]


## Which commute bucket applies: weekday morning/evening/night or weekend.
static func route_bucket(day_index: int, hour: int) -> String:
	if day_index >= 5:
		return "weekend"
	if hour >= 6 and hour < 12:
		return "weekday_morning"
	if hour >= 12 and hour < 22:
		return "weekday_evening"
	return "weekday_night"


## Likely destinations for a commuter, filtered to kinds that exist in the city.
static func likely_destinations(origin: int, day_index: int, hour: int, present: Array[int]) -> Array[int]:
	var out: Array[int] = []
	if not ROUTES.has(origin):
		return out
	var table: Dictionary = ROUTES[origin]
	var candidates: Array = []
	for key in table:
		if str(key) == route_bucket(day_index, hour):
			candidates = table[key]
			break
	if candidates.is_empty() and table.has("always"):
		candidates = table["always"]
	for kind in candidates:
		if present.has(int(kind)):
			out.append(int(kind))
	return out


static func passenger_happiness(wait: float) -> float:
	return clampf(100.0 - (wait / MAX_WAIT) * 100.0, 0.0, 100.0)


## Difficulty ramp: 1.0 at the start, +1.0 every 60 s.
func difficulty() -> float:
	return 1.0 + game_time / DIFFICULTY_DIVISOR


func hour_of_day() -> int:
	return int(clampf(day_timer / DAY_DURATION, 0.0, 0.9999) * 24.0)


## "08:30" style in-game clock.
func clock_text() -> String:
	var ratio := clampf(day_timer / DAY_DURATION, 0.0, 0.9999)
	var hour := int(ratio * 24.0)
	var minute := int((ratio * 24.0 - float(hour)) * 60.0)
	return "%02d:%02d" % [hour, minute]


func day_text() -> String:
	return "%s  Tag %d" % [DAY_NAMES[clampi(day, 0, DAY_NAMES.size() - 1)], int(game_time / DAY_DURATION) + 1]


## "Morgen", "Nachmittag", "Abend" or "Nacht" — the lighting follows this.
func time_of_day_name() -> String:
	var hour := hour_of_day()
	if hour >= 6 and hour < 12:
		return "Morgen"
	if hour >= 12 and hour < 18:
		return "Nachmittag"
	if hour >= 18 and hour < 22:
		return "Abend"
	return "Nacht"


## The two commute peaks, the hours a rush hour is expected in.
func is_rush_window() -> bool:
	return RUSH_HOURS.has(hour_of_day())


## 0 = full night, 1 = full day, smooth over the whole 24 h cycle.
func daylight() -> float:
	var hour := hour_of_day()
	if hour < 5:
		return 0.12
	if hour < 8:
		return lerpf(0.12, 1.0, float(hour - 5) / 3.0)
	if hour < 17:
		return 1.0
	if hour < 20:
		return lerpf(1.0, 0.18, float(hour - 17) / 3.0)
	return 0.18
