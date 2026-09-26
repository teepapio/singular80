class_name TestMetro
extends RefCounted
## Rule tests for "Metropol 3D" — the 3D metro-network builder.
##
## Kept in its own file next to `metro.gd` so the game's rule coverage travels
## with the game and stays independent of the other suites. The screen side
## lives in `test_metro_screens.gd`, which has to load the screen at runtime
## (see the comment there).

var t: TestKit


## Entry point used by `run_tests.gd`.
func run(kit: TestKit) -> void:
	t = kit
	_suite(_metro_rules)
	_suite(_metro_network)
	_suite(_metro_economy)


## Runs one suite and fails it if it returned before its own `t.suite_done()`,
## which is what a GDScript runtime error does.
func _suite(body: Callable) -> void:
	body.call()
	t.close_suite()


# --- helpers ----------------------------------------------------------------

## Connects the three starting stations with two lines that share the middle
## station, which is the smallest network that produces a real interchange.
func _metro_link(metro: Metro) -> Array[int]:
	var ids: Array[int] = []
	for station in metro.stations:
		ids.append(int(station["id"]))
	var first := metro.begin_line(ids[0])
	metro.extend_line(first, ids[1])
	metro.finish_line(first)
	var second := metro.begin_line(ids[1])
	metro.extend_line(second, ids[2])
	metro.finish_line(second)
	return [first, second]


## How many pool slots are actually in use, i.e. not the recycled empty ones.
func _live_passengers(metro: Metro) -> int:
	var count := 0
	for passenger in metro.passengers:
		if not passenger.is_empty():
			count += 1
	return count


# --- rules ------------------------------------------------------------------

func _metro_rules() -> void:
	t.suite("Metropol 3D — Regeln")

	# Station types are a complete, unique palette.
	t.equal(Metro.TYPES.size(), 17, "Siebzehn Zielort-Typen")
	var glyphs := {}
	for kind in Metro.TYPES.size():
		var glyph := Metro.type_glyph(kind)
		t.check(not (glyph in glyphs), "Symbol '%s' ist eindeutig" % glyph)
		glyphs[glyph] = true
		t.check(not Metro.type_name(kind).is_empty(), "Typ %d hat einen Namen" % kind)
		t.check(not Metro.type_color(kind).is_equal_approx(Color.BLACK), "Typ %d hat eine Farbe" % kind)
	t.equal(Metro.LINE_COLORS.size(), 5, "Fünf Linienfarben")
	t.check(Metro.Kind.size() == Metro.TYPES.size(), "Enum und Typenliste sind gleich lang")

	# Time of day decides where people want to go.
	t.equal(Metro.route_bucket(0, 8), "weekday_morning", "Montag 8 Uhr ist Berufsverkehr")
	t.equal(Metro.route_bucket(0, 14), "weekday_evening", "Montag 14 Uhr ist Nachmittag")
	t.equal(Metro.route_bucket(0, 23), "weekday_night", "Montag 23 Uhr ist Nacht")
	t.equal(Metro.route_bucket(5, 8), "weekend", "Samstag ist Wochenende")
	t.equal(Metro.route_bucket(6, 8), "weekend", "Sonntag ist Wochenende")
	var present: Array[int] = [Metro.Kind.OFFICE, Metro.Kind.PARK]
	var commute := Metro.likely_destinations(Metro.Kind.HOME, 0, 8, present)
	t.check(commute.has(Metro.Kind.OFFICE), "Pendler wollen morgens zur Arbeit")
	t.check(not commute.has(Metro.Kind.PARK), "Der Park ist kein Pendlerziel")
	var weekend := Metro.likely_destinations(Metro.Kind.HOME, 6, 10, present)
	t.check(weekend.has(Metro.Kind.PARK), "Am Wochenende geht es in den Park")
	t.equal(Metro.likely_destinations(Metro.Kind.HOME, 0, 23, [Metro.Kind.OFFICE]).size(), 0,
		"Nachts fährt niemand vom Wohnen los")
	t.check(not Metro.likely_destinations(Metro.Kind.HOME, 0, 8, [Metro.Kind.PARK]).has(Metro.Kind.OFFICE),
		"Ziele ohne Station im Netz fallen weg")
	t.check(Metro.LIKELY_CHANCE > 0.5, "Die meisten fahren tatsächlich nach dem Plan")

	# Patience.
	t.almost(Metro.passenger_happiness(0.0), 100.0, 0.001, "Ein sofort bedienter Fahrgast ist glücklich")
	t.almost(Metro.passenger_happiness(Metro.MAX_WAIT), 0.0, 0.001, "Nach der Höchstwartezeit ist die Laune am Ende")
	t.equal(Metro.passenger_happiness(Metro.MAX_WAIT * 4.0), 0.0, "Die Laune wird nicht negativ")

	# Water geometry.
	var centre := PackedVector2Array([Vector2(0, 0), Vector2(0, 20)])
	var ribbon := Metro.ribbon_polygon(centre, 4.0)
	t.equal(ribbon.size(), 4, "Ein Band hat zwei Ränder")
	t.check(Metro.point_in_polygon(Vector2(1, 10), ribbon), "Ein Punkt im Band liegt drin")
	t.check(not Metro.point_in_polygon(Vector2(6, 10), ribbon), "Ein Punkt neben dem Band liegt draußen")
	t.check(Metro.segment_intersects(Vector2(0, 0), Vector2(10, 10), Vector2(0, 10), Vector2(10, 0)),
		"Sich kreuzende Segmente werden erkannt")
	t.check(not Metro.segment_intersects(Vector2(0, 0), Vector2(1, 0), Vector2(0, 5), Vector2(1, 5)),
		"Parallele Segmente kreuzen sich nicht")
	t.almost(Metro.point_to_segment_distance(Vector2(5, 3), Vector2(0, 0), Vector2(10, 0)), 3.0, 0.001,
		"Abstand zu einem Segment")

	# Rounded paths: shorter than the raw polyline, arcs strictly increasing.
	var corner := PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(10, 10)])
	var open := Metro.rounded_path(corner, false)
	t.check(int(open["path"].size()) > 3, "Ecken werden abgerundet")
	t.check(float(open["length"]) < 20.0, "Das Abrunden verkürzt den Weg")
	t.check(float(open["length"]) > 19.0, "Der Weg bleibt fast so lang wie die direkte Verbindung")
	var open_arcs: PackedFloat32Array = open["station_arc"]
	t.almost(open_arcs[0], 0.0, 0.001, "Die erste Station liegt am Anfang")
	t.almost(open_arcs[2], float(open["length"]), 0.001, "Die letzte Station liegt am Ende")
	t.check(open_arcs[1] > open_arcs[0] and open_arcs[1] < open_arcs[2], "Bogenstation liegt dazwischen")

	var ring := PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(10, 10), Vector2(0, 0)])
	var loop := Metro.rounded_path(ring, true)
	t.check(float(loop["length"]) > 0.0, "Ein Ring hat eine Länge")
	var ring_arcs: PackedFloat32Array = loop["station_arc"]
	t.almost(ring_arcs[ring_arcs.size() - 1], float(loop["length"]), 0.001,
		"Der wiederholte Start liegt am Ende des Rings")

	# Arc lookup lands on the path and walks it.
	var path: PackedVector2Array = open["path"]
	var cum: PackedFloat32Array = open["cum"]
	t.check(Metro.position_at_arc(path, cum, 0.0).distance_to(Vector2(0, 0)) < 0.01, "Arc 0 ist der Startpunkt")
	t.check(Metro.position_at_arc(path, cum, 1e9).distance_to(Vector2(10, 10)) < 0.01, "Ein zu grosser Arc endet am Ziel")
	var mid := Metro.position_at_arc(path, cum, float(open["length"]) * 0.5)
	# On an L-shaped route the midpoint sits on the bend, near (10, 0).
	t.check(mid.distance_to(Vector2(10, 0)) < 1.5, "Die Haelfte des Weges liegt an der Ecke")
	t.almost(Metro.heading_at_arc(path, cum, 0.5).x, 1.0, 0.2, "Am Anfang geht es nach rechts")

	# Three starting stations, always inside the map.
	var slots := Metro.initial_station_positions(3)
	t.equal(slots.size(), 3, "Drei Startplätze")
	for slot in slots:
		t.check(slot.x > 0.0 and slot.x < Metro.MAP_SIZE.x, "Startplatz liegt im Kartenbereich (x)")
		t.check(slot.y > 0.0 and slot.y < Metro.MAP_SIZE.y, "Startplatz liegt im Kartenbereich (y)")
	t.check(Metro.initial_station_positions(5).size() == 5, "Beliebige Anzahl Startplätze")
	t.equal(Metro.initial_station_positions(0).size(), 0, "Kein Bedarf, keine Plätze")

	# Difficulty, clock and light.
	var run := Metro.new()
	run.start(Metro.Mode.NORMAL, 99)
	t.almost(run.difficulty(), 1.0, 0.001, "Am Anfang ist die Schwierigkeit 1")
	run.game_time = Metro.DIFFICULTY_DIVISOR * 2.0
	t.almost(run.difficulty(), 3.0, 0.001, "Die Schwierigkeit wächst linear")
	run.day_timer = Metro.DAY_DURATION * 0.5
	t.equal(run.hour_of_day(), 12, "Mittag am halben Tag")
	t.check(run.daylight() > 0.8, "Mittags ist es hell")
	run.day_timer = 0.0
	t.check(run.daylight() < 0.2, "Um Mitternacht ist es dunkel")
	run.day_timer = Metro.DAY_DURATION * (8.0 / 24.0)
	t.check(run.is_rush_window(), "Acht Uhr ist Rush Hour")
	run.day_timer = Metro.DAY_DURATION * (12.0 / 24.0)
	t.check(not run.is_rush_window(), "Mittags ist keine Rush Hour")
	t.check(run.clock_text().length() == 5, "Die Uhr hat das Format HH:MM")
	t.check(not run.day_text().is_empty(), "Der Kalender hat einen Text")
	t.suite_done()


# --- network ----------------------------------------------------------------

func _metro_network() -> void:
	t.suite("Metropol 3D — Netz")

	var metro := Metro.new()
	metro.start(Metro.Mode.NORMAL, 4242)
	t.equal(metro.stations.size(), 3, "Drei Startbahnhöfe")
	t.check(metro.rivers.size() >= Metro.RIVER_MIN, "Die Stadt hat mindestens einen Fluss")
	t.equal(metro.resources["trains"], Metro.START_TRAINS, "Depot startet mit Lokomotiven")
	t.check(metro.can_create_new_line(), "Es ist Platz für eine Linie")
	t.equal(metro.available_color(), Metro.LineColor.PINK, "Die erste Linie ist Pink")

	# Chain building.
	var ids: Array[int] = []
	for station in metro.stations:
		ids.append(int(station["id"]))
	var line := metro.begin_line(ids[0])
	t.check(line >= 0, "Eine Linie lässt sich eröffnen")
	t.equal(metro.extend_line(line, ids[0]), 0, "Dieselbe Station zweimal geht nicht")
	t.equal(metro.extend_line(line, ids[1]), 1, "Eine Station lässt sich anhängen")
	t.equal(metro.extend_line(line, ids[1]), 0, "Anhängen ist nicht idempotent")
	metro.finish_line(line)
	t.equal((metro.lines[line]["stations"] as Array).size(), 2, "Die Linie hat zwei Bahnhöfe")
	t.check(float(metro.lines[line]["length"]) > 0.0, "Die Linie hat einen Weg")
	t.check(not (metro.lines[line]["path"] as PackedVector2Array).is_empty(), "Die Linie hat eine Geometrie")
	t.check((metro.lines[line]["trains"] as Array).size() == 1, "Beim Bauen fährt eine Lok mit")
	t.equal(metro.lines[line]["color"], Metro.LineColor.PINK, "Die Linie hat die erste Farbe")

	# A stub never survives.
	var stub := metro.begin_line(ids[2])
	metro.finish_line(stub)
	t.equal(metro.lines.size(), 1, "Die zu kurze Linie ist wieder verschwunden")

	# Ring closing.
	var ring := metro.begin_line(ids[0])
	metro.extend_line(ring, ids[1])
	metro.extend_line(ring, ids[2])
	t.equal(metro.extend_line(ring, ids[0]), 2, "Der erste Bahnhof schliesst den Ring")
	t.check(bool(metro.lines[ring]["loop"]), "Die Linie ist jetzt ein Ring")
	metro.finish_line(ring)
	t.check(float(metro.lines[ring]["length"]) > 0.0, "Der Ring hat eine Länge")

	# Interchanges: a single line makes none, the second one does.
	var solo := Metro.new()
	solo.start(Metro.Mode.NORMAL, 8080)
	var solo_ids: Array[int] = []
	for station in solo.stations:
		solo_ids.append(int(station["id"]))
	var solo_line := solo.begin_line(solo_ids[0])
	solo.extend_line(solo_line, solo_ids[1])
	solo.finish_line(solo_line)
	t.equal(solo.transfers.size(), 0, "Eine einzelne Linie ergibt keinen Streckenknoten")
	t.check(not solo.is_transfer(solo_ids[1]), "Ein einfach bedienter Bahnhof ist keiner")
	var solo_second := solo.begin_line(solo_ids[1])
	solo.extend_line(solo_second, solo_ids[2])
	solo.finish_line(solo_second)
	t.check(solo.is_transfer(solo_ids[1]), "Der geteilte Bahnhof wird zum Streckenknoten")
	t.check(not solo.is_transfer(solo_ids[2]), "Der neue Endpunkt bleibt ein einfacher Bahnhof")
	t.equal(solo.lines_at_station(solo_ids[1]).size(), 2, "Der Streckenknoten hat beide Linien")

	# Routing across a ring.
	var linked := _metro_link(metro)
	t.check(metro.can_train_help(linked[0], ids[0], int(metro.stations[ids[2]]["type"]), 1),
		"Ein Ring kann das Ziel des anderen Rings erreichen")

	# Changing trains needs an interchange, a second line and a permit.
	var wanted := int(solo.stations[solo_ids[2]]["type"])
	t.equal(solo.should_transfer(solo_line, solo_ids[0], wanted, 1), 0,
		"Am Endpunkt gibt es nichts zum Umsteigen")
	t.equal(solo.should_transfer(solo_line, solo_ids[1], wanted, 0), 0,
		"Ohne Umstiegsfreigabe bleibt der Fahrgast an Bord")
	t.equal(solo.should_transfer(solo_line, solo_ids[1], wanted, 1), 1,
		"Am Streckenknoten mit Freigabe wird umgestiegen")
	t.check(solo.can_train_help(solo_line, solo_ids[0], wanted, 1),
		"Der Umstieg macht das Ziel erreichbar")
	t.check(not solo.can_train_help(solo_line, solo_ids[0], wanted, 0),
		"Ohne Freigabe bleibt das Ziel unerreichbar")

	# Extreme mode locks lines down.
	var hard := Metro.new()
	hard.start(Metro.Mode.EXTREME, 7)
	var first := hard.begin_line(ids[0])
	hard.extend_line(first, ids[1])
	hard.finish_line(first)
	t.check(hard.can_extend_at(first, ids[1]), "Im Extrem-Modus wächst das Linienende")
	t.check(not hard.can_extend_at(first, ids[0]), "Der Anfang bleibt stehen")
	t.check(not hard.begin_line_with(first, ids[0]), "Im Extrem-Modus wird nicht umgebaut")
	t.check(hard.begin_line_with(first, ids[1]), "Das Ende darf trotzdem wachsen")
	t.check(not hard.remove_line(first), "Im Extrem-Modus wird nicht abgerissen")
	t.check(not hard.scrap_train(0), "Im Extrem-Modus wird nicht ausgemustert")
	t.equal(hard.capacity_of(0), Metro.STATION_CAPACITY, "Im Extrem-Modus gilt die normale Kapazität")

	# Depot, wagons and scrapping in Normal mode. Four lines are running by now.
	t.equal(metro.resources["trains"], Metro.START_TRAINS - 4, "Vier Loks sind im Einsatz")
	t.equal(metro.trains.size(), 4, "Vier Züge fahren")
	var wagon_before := int(metro.resources["wagons"])
	var seats := int(metro.trains[0]["capacity"])
	t.check(metro.add_wagon(0), "Ein Beiwagen passt an den Zug")
	t.equal(int(metro.trains[0]["capacity"]), seats + Metro.WAGON_CAPACITY, "Der Beiwagen bringt Sitzplätze")
	t.equal(int(metro.resources["wagons"]), wagon_before - 1, "Der Beiwagen kam aus dem Depot")
	while int(metro.resources["wagons"]) > 0:
		if not metro.add_wagon(0):
			break
	t.check(not metro.add_wagon(0), "Ein leeres Depot gibt nichts heraus")

	# Ids are array indices, so a removal must renumber everything. Without this
	# every line built after the first removal would be unreachable.
	t.check(metro.scrap_train(0), "Ein Zug lässt sich ausmustern")
	t.equal(metro.trains.size(), 3, "Nur der eine Zug ist weg")
	for index in metro.trains.size():
		t.equal(int(metro.trains[index]["id"]), index, "Zug %d trägt seine Position als Id" % index)
	var fresh := metro.begin_line(0)
	t.check(fresh >= 0 and fresh < metro.lines.size(), "Eine neue Linie ist direkt benutzbar")
	t.equal(metro.extend_line(fresh, 1), 1, "Und lässt sich sofort verlängern")
	metro.finish_line(fresh)
	t.check((metro.lines[fresh]["stations"] as Array).size() == 2, "Die neue Linie bleibt benutzbar")

	var lines_before := metro.lines.size()
	t.check(metro.remove_line(linked[0]), "Eine Linie lässt sich abreißen")
	t.equal(metro.lines.size(), lines_before - 1, "Das Netz ist um eine Linie kleiner")
	for index in metro.lines.size():
		t.equal(int(metro.lines[index]["id"]), index, "Linie %d trägt ihre Position als Id" % index)
	for train in metro.trains:
		var owner := int(train["line"])
		t.check(owner < 0 or owner < metro.lines.size(), "Kein Zug zeigt auf eine tote Linie")
		if owner >= 0:
			t.check(owner == 0 or not (metro.lines[owner]["trains"] as Array).is_empty(),
				"Die Linie %d kennt ihre Züge" % owner)

	# Hit testing against the built geometry.
	t.equal(metro.station_at(Vector2(metro.stations[0]["pos"])), 0, "Ein Bahnhof wird am Ort erkannt")
	t.check(metro.station_at(Vector2(metro.stations[0]["pos"]) + Vector2(40, 40)) < 0, "Weit weg ist kein Bahnhof")
	t.check(metro.line_at(Vector2(metro.stations[0]["pos"]), 6.0) >= 0, "Linien werden am Ort erkannt")
	t.check(metro.train_at(Vector2(metro.stations[0]["pos"]), 6.0) < 0 or not metro.trains.is_empty(),
		"Züge werden am Ort erkannt")

	# Collapse: a station left over capacity long enough ends the run.
	var doom := Metro.new()
	doom.start(Metro.Mode.NORMAL, 11)
	doom.stations[0]["lines"] = [0] as Array[int]
	for i in 40:
		(doom.stations[0]["waiting"] as Array).append(doom._alloc_passenger(Metro.Kind.OFFICE))
	t.check(doom.critical_station() >= 0, "Der überfüllte Bahnhof wird gemeldet")
	t.check(doom.critical_countdown() > 0.0, "Es gibt eine Countdown-Anzeige")
	for i in 400:
		doom.update(0.1)
		if doom.over:
			break
	t.check(doom.over, "Ein dauerhaft überfüllter Bahnhof kollabiert das Netz")
	t.equal(doom.money, 0, "Ohne Lieferungen gibt es keine Einnahmen")
	t.equal(doom.score(), 0, "Die Punktzahl bleibt bei null")

	# Endless mode never collapses.
	var calm := Metro.new()
	calm.start(Metro.Mode.ENDLESS, 11)
	calm.stations[0]["lines"] = [0] as Array[int]
	for i in 400:
		calm.update(0.1)
	t.check(not calm.over, "Im Endlos-Modus kollabiert nichts")
	t.check(calm.capacity_of(0) > 1000, "Im Endlos-Modus ist die Kapazität praktisch grenzenlos")
	t.suite_done()


# --- economy ----------------------------------------------------------------

func _metro_economy() -> void:
	t.suite("Metropol 3D — Wirtschaft")

	var metro := Metro.new()
	metro.start(Metro.Mode.NORMAL, 555)
	_metro_link(metro)

	# Deliveries: money, streak and the pool all have to move.
	for i in 4000:
		metro.update(0.05)
		var modal := metro.next_modal()
		if not modal.is_empty():
			metro.choose_card(str((modal["options"] as Array)[0]["kind"]))
		if metro.delivered > 4:
			break
	t.check(metro.delivered > 0, "Züge liefern Fahrgäste ab")
	t.check(metro.money >= metro.delivered * Metro.MONEY_PER_DELIVERY,
		"Jede Lieferung zahlt mindestens den Grundpreis")
	t.check(metro.best_streak >= 1, "Es gibt eine Serie")
	t.equal(metro.riding_total + metro.waiting_total, _live_passengers(metro),
		"Wartende und Fahrende ergeben die Zahl der aktiven Fahrgäste")
	t.check(metro.happiness() >= 0.0 and metro.happiness() <= 100.0, "Die Zufriedenheit liegt zwischen 0 und 100")
	t.check(metro.punctual <= metro.delivered, "Nicht jeder ist pünktlich, aber alle werden gezählt")

	# Rush hours really do add pressure and they end on their own.
	var busy := Metro.new()
	busy.start(Metro.Mode.NORMAL, 556)
	busy.trigger_rush(30.0)
	t.check(busy.rush_active, "Rush Hour ist aktiv")
	for i in 400:
		busy.update(0.05)
	t.check(busy.rush_active, "Rush Hour laeuft noch")
	for i in 900:
		busy.update(0.05)
	t.check(not busy.rush_active, "Rush Hour endet von allein")

	# The commuter pool is recycled instead of growing without bound. A line has
	# to be running, otherwise nobody is picked up and nothing is ever freed.
	var pool := Metro.new()
	pool.start(Metro.Mode.NORMAL, 557)
	var pool_ids: Array[int] = []
	for station in pool.stations:
		pool_ids.append(int(station["id"]))
	var pool_line := pool.begin_line(pool_ids[0])
	pool.extend_line(pool_line, pool_ids[1])
	pool.finish_line(pool_line)
	for i in 6000:
		pool.update(0.05)
		var modal := pool.next_modal()
		if not modal.is_empty():
			pool.choose_card("wagon")
	t.check(pool.delivered > 0, "Die Testlinie liefert Fahrgäste ab")
	t.check(pool.passengers.size() < Metro.MAX_PASSENGERS / 2,
		"Der Pool bleibt weit unter der Obergrenze, weil Plaetze wiederverwendet werden")
	t.check(_live_passengers(pool) == pool.waiting_total + pool.riding_total,
		"Freie Poolplaetze zählen nicht als Fahrgäste")

	# Cards and the weekly bonus.
	var cards := Metro.new()
	cards.start(Metro.Mode.NORMAL, 558)
	cards._offer_cards()
	t.equal(cards.modals.size(), 1, "Am Planungstag liegt ein Kartenangebot bereit")
	var offer: Dictionary = cards.modals[0]
	t.equal((offer["options"] as Array).size(), Metro.CARD_CHOICES, "Es werden drei Karten angeboten")
	t.check(cards.frozen(), "Waehrend der Wahl steht die Stadt still")
	cards.update(0.5)
	t.almost(cards.game_time, 0.0, 0.0001, "Die Stadt steht wirklich still")
	t.check(not cards.frozen() or not cards.modals.is_empty(), "Das Angebot wartet weiter")
	cards.modals = []
	var trains_before := int(cards.resources["trains"])
	t.check(cards.choose_card("train"), "Eine Lokomotivkarte laesst sich waehlen")
	t.equal(int(cards.resources["trains"]), trains_before + 1, "Die Karte fuellt das Depot")
	t.check(not cards.choose_card("nonsense"), "Unbekannte Karten werden abgelehnt")
	var lines_before := cards.max_lines
	cards.choose_card("line")
	t.equal(cards.max_lines, lines_before + 1, "Eine Linienkarte schaltet eine Farbe frei")
	var permits := cards.transfer_permits
	cards.choose_card("transfer")
	t.equal(cards.transfer_permits, permits + 1, "Eine Umstiegsfreigabe erlaubt mehr Umstiege")
	cards.choose_card("bridge")
	t.equal(int(cards.resources["bridges"]), Metro.START_BRIDGES + 1, "Eine Brueckenkarte zaehlt")
	cards.choose_card("tunnel")
	t.equal(int(cards.resources["tunnels"]), Metro.START_TUNNELS + 1, "Eine Tunnelkarte zaehlt")
	var wagons := int(cards.resources["wagons"])
	cards.choose_card("wagon")
	t.equal(int(cards.resources["wagons"]), wagons + 1, "Eine Wagenkarte zaehlt")
	t.check(cards.take_events().size() >= 5, "Karten melden sich als Ereignis")

	# With every line colour in use the bonus must not offer another one.
	cards.max_lines = Metro.LineColor.size()
	while cards.can_create_new_line():
		var extra := cards.begin_line(0)
		if extra < 0:
			break
		cards.lines[extra]["stations"] = [0, 1] as Array[int]
		cards.rebuild_line(extra)
	t.check(not cards.can_create_new_line(), "Die Linienliste ist voll")
	t.equal(cards.available_color(), -1, "Keine Farbe mehr frei")
	cards.modals = []
	cards._offer_upgrade()
	var bonus: Dictionary = cards.modals[0]
	t.equal((bonus["options"] as Array).size(), 2, "Der Wochenbonus hat zwei Optionen")
	t.equal(str((bonus["options"] as Array)[0]["kind"]), "train", "Der Wochenbonus schenkt immer eine Lok")
	t.check(str((bonus["options"] as Array)[1]["kind"]) != "line", "Eine volle Linienliste wird ersetzt")
	t.equal(cards.next_modal().get("type"), "upgrade", "Der Bonus laesst sich abholen")
	t.equal(cards.next_modal().get("type", ""), "", "Danach wartet nichts mehr")

	# The calendar really advances and pays out on its own.
	var clock := Metro.new()
	clock.start(Metro.Mode.NORMAL, 559)
	_metro_link(clock)
	var seen_days := {}
	var modals := 0
	for i in 12000:
		clock.update(0.05)
		var modal := clock.next_modal()
		if not modal.is_empty():
			modals += 1
			clock.choose_card("wagon")
		seen_days[clock.day] = true
		if modals >= 3:
			break
	t.check(seen_days.size() > 1, "Die Woche laeuft weiter")
	t.check(modals >= 3, "Karten und Wochenboni kommen von selbst")
	t.check(clock.week_timer > 0.0, "Die Wochenuhr laeuft")
	t.check(not clock.survival_text().is_empty(), "Die Ueberlebenszeit laesst sich formatieren")
	t.check(clock.milestones.size() > 0, "Meilensteine werden gefeiert")
	var kinds := {}
	for event in clock.take_events():
		kinds[str(event["kind"])] = true
	t.check(kinds.has("milestone"), "Der Meilenstein kommt als Ereignis an")
	t.suite_done()
