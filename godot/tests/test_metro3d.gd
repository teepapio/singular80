class_name TestMetro3d
extends RefCounted
## Tests for the demand forecast of "Metropol 3D", the feature that makes a
## missing line visible before the queue collapses. The screen is reached through
## the router, never as a static `MetroScreen`: that would drag it into the
## compile chain of `run_tests.gd`, which runs before the autoloads exist.

var t: TestKit


## Entry point used by `run_tests.gd`. `tree` is null when only the pure logic
## is wanted.
func run(kit: TestKit, tree: SceneTree) -> void:
	t = kit
	_suite(_bedarfsprognose)
	_suite(_fehlende_linien)
	_suite(_berufsverkehr)
	if tree == null:
		return
	await _anschluss_marker(tree)
	t.close_suite()


## Runs one suite and fails it if it returned before its own `t.suite_done()`,
## which is what a GDScript runtime error does.
func _suite(body: Callable) -> void:
	body.call()
	t.close_suite()


# --- helpers ----------------------------------------------------------------

## Does this sentence name that kind of station, in whichever language it is?
##
## The station type reaches the screen through two different routes: the HUD line
## is built with `Loc.f`, which resolves the *values* too, and the notify line is
## formatted with `%` and only then handed to `Loc` as a finished sentence — which
## no catalogue entry can match. So the test asks for the type's name in both
## spellings instead of guessing which route produced the line.
func _names(sentence: String, kind: int) -> bool:
	var text := Loc.resolve(sentence)
	var source := Metro.type_name(kind)
	return text.contains(Loc.resolve(source)) or text.contains(source)


## Three starting stations with fixed types, so the assertions do not depend on
## the seed of the city.
func _demo(kinds: Array[int]) -> Metro:
	var metro := Metro.new()
	metro.start(Metro.Mode.NORMAL, 4711)
	for index in kinds.size():
		metro.stations[index]["type"] = kinds[index]
	metro.refresh_transfers()
	return metro


## Puts `count` commuters into the queue of `station_id`, all wanting `kind`.
func _queue(metro: Metro, station_id: int, kind: int, count: int) -> void:
	var waiting: Array = metro.stations[station_id]["waiting"]
	for i in count:
		waiting.append(metro._alloc_passenger(kind))


## The event kinds of everything the logic queued up so far.
func _event_kinds(metro: Metro) -> Dictionary:
	var out: Dictionary = {}
	for event in metro.take_events():
		out[str(event["kind"])] = true
	return out


# --- Bedarfsprognose --------------------------------------------------------

func _bedarfsprognose() -> void:
	t.suite("Metropol 3D — Bedarfsprognose")

	# No line at all: everybody at the housing estate is stuck.
	var metro := _demo([Metro.Kind.HOME, Metro.Kind.OFFICE, Metro.Kind.SPORTS])
	_queue(metro, 0, Metro.Kind.OFFICE, 4)
	_queue(metro, 0, Metro.Kind.SPORTS, 2)
	metro._update_service()
	t.equal(metro.stranded_at(0), 6, "Ohne jede Linie kommt niemand vom Wohnen weg")
	t.equal(metro.stranded_total, 6, "Die Stadt zählt alle festgefahrenen Fahrgäste")
	t.equal(metro.service_state(0), Metro.Service.BLOCKED, "Sechs Wartende ohne Anschluss sind ein Stau")
	t.equal(metro.stranded_kind(0), Metro.Kind.OFFICE, "Der stärkste Wunsch des Bahnhofs wird gemeldet")
	t.equal(metro.stranded_at(9), 0, "Ein unbekannter Bahnhof hat keine Wartenden")
	t.equal(metro.stranded_kind(9), -1, "Und keinen Wunsch")
	t.equal(metro.forecast(9).size(), 0, "Und keine Prognose")

	# The line to the office frees most of the queue and the marker follows.
	var office := metro.begin_line(0)
	metro.extend_line(office, 1)
	metro.finish_line(office)
	metro._update_service()
	t.equal(metro.stranded_at(0), 2, "Nur die Sportplatz-Wartenden bleiben hängen")
	t.equal(metro.service_state(0), Metro.Service.PARTIAL, "Zwei sind noch kein Stau")
	t.equal(metro.stranded_kind(0), Metro.Kind.SPORTS, "Der Marker zielt jetzt auf den Sportplatz")
	var rows := metro.forecast(0)
	t.equal(rows.size(), 2, "Die Ansicht kennt beide Zielgruppen")
	t.equal(int(rows[0]["kind"]), Metro.Kind.OFFICE, "Die größte Gruppe steht vorn")
	t.check(bool(rows[0]["route"]), "Das Büro ist von hier aus erreichbar")
	t.equal(int(rows[1]["kind"]), Metro.Kind.SPORTS, "Danach der Sportplatz")
	t.check(not bool(rows[1]["route"]), "Der Sportplatz ist es nicht")
	t.equal(metro.stranded_at(1), 0, "Ein Bahnhof ohne Wartende hat nichts zu melden")

	# The warning has a threshold, so one lost ride stays quiet.
	var edge := _demo([Metro.Kind.HOME, Metro.Kind.OFFICE, Metro.Kind.SPORTS])
	_queue(edge, 0, Metro.Kind.SPORTS, Metro.STRANDED_MIN - 1)
	edge._update_service()
	t.check(edge.service_state(0) != Metro.Service.BLOCKED,
		"Unter der Schwelle bleibt der Bahnhof unauffällig")
	_queue(edge, 0, Metro.Kind.SPORTS, 1)
	edge._update_service()
	t.equal(edge.service_state(0), Metro.Service.BLOCKED, "Ab der Schwelle steht die Warnung")
	t.equal(edge.stranded_kind(0), Metro.Kind.SPORTS, "Und nennt den Sportplatz")
	t.equal(edge.stranded_total, Metro.STRANDED_MIN, "Die Stadt zählt dieselben Fahrgäste")

	# One line that reaches the destination clears the station completely.
	var served := _demo([Metro.Kind.HOME, Metro.Kind.OFFICE, Metro.Kind.SPORTS])
	_queue(served, 0, Metro.Kind.OFFICE, 2)
	served._update_service()
	t.equal(served.service_state(0), Metro.Service.PARTIAL, "Zwei Festgefahrene sind noch kein Stau")
	var line := served.begin_line(0)
	served.extend_line(line, 1)
	served.finish_line(line)
	served._update_service()
	t.equal(served.stranded_at(0), 0, "Die Linie zum Büro räumt den Bahnhof")
	t.equal(served.service_state(0), Metro.Service.OK, "Der Bahnhof ist wieder bedient")
	t.equal(served.stranded_total, 0, "Die Stadt hat niemanden mehr ohne Anschluss")

	# Two lines at one station: the stadium is reachable over the interchange.
	var hub := _demo([Metro.Kind.HOME, Metro.Kind.OFFICE, Metro.Kind.SPORTS])
	var first := hub.begin_line(0)
	hub.extend_line(first, 1)
	hub.finish_line(first)
	var second := hub.begin_line(1)
	hub.extend_line(second, 2)
	hub.finish_line(second)
	t.check(hub.is_transfer(1), "Der mittlere Bahnhof ist ein Streckenknoten")
	_queue(hub, 0, Metro.Kind.SPORTS, 3)
	hub._update_service()
	t.equal(hub.stranded_at(0), 0, "Über den Streckenknoten ist der Sportplatz erreichbar")
	t.check(bool((hub.forecast(0)[0] as Dictionary)["route"]), "Die Prognose nennt den Umstieg als Weg")
	# Without a permit the very same ride does not exist.
	hub.transfer_permits = 0
	hub._update_service()
	t.equal(hub.stranded_at(0), 3, "Ohne Umstiegsfreigabe fährt niemand um")
	t.check(not bool((hub.forecast(0)[0] as Dictionary)["route"]), "Die Prognose verschweigt den Weg nicht")

	# The real tick keeps the numbers up to date, not just a manual call.
	var live := _demo([Metro.Kind.HOME, Metro.Kind.OFFICE, Metro.Kind.SPORTS])
	_queue(live, 0, Metro.Kind.SPORTS, 3)
	var running := live.begin_line(0)
	live.extend_line(running, 1)
	live.finish_line(running)
	live.update(0.05)
	t.equal(live.stranded_at(0), 3, "Der Lauf hält die Prognose selbst aktuell")
	live.extend_line(running, 2)
	live.update(0.05)
	t.equal(live.stranded_total, 0, "Und befreit sie, sobald die Linie gebaut ist")
	t.suite_done()


# --- Fehlende Linien ---------------------------------------------------------

func _fehlende_linien() -> void:
	t.suite("Metropol 3D — Fehlende Linien")

	var metro := _demo([Metro.Kind.HOME, Metro.Kind.OFFICE, Metro.Kind.SPORTS])
	_queue(metro, 0, Metro.Kind.SPORTS, 3)
	metro._update_service()
	t.check(metro.unmet.has(Metro.Kind.SPORTS), "Der Sportplatz fehlt im Netz")
	t.equal(metro.unmet_total, 3, "Drei Fahrgäste warten auf eine Linie, die es nicht gibt")
	t.equal(int((metro.unmet_top())["kind"]), Metro.Kind.SPORTS, "Die stärkste Lücke kommt zuerst")
	var text := metro.demand_text()
	t.check(text.contains("Sportplatz"), "Das HUD nennt den fehlenden Zielort")
	t.check(text.contains("3"), "Und die Zahl der Wartenden")
	var kinds := _event_kinds(metro)
	t.check(kinds.has("unmet"), "Die Lücke meldet sich als Ereignis")
	t.check(kinds.has("stranded"), "Der festgefahrene Bahnhof ebenso")

	# Building the missing line closes the gap — and the news is not repeated.
	var office := metro.begin_line(0)
	metro.extend_line(office, 1)
	metro.finish_line(office)
	var stadium := metro.begin_line(1)
	metro.extend_line(stadium, 2)
	metro.finish_line(stadium)
	metro._update_service()
	t.check(metro.unmet.is_empty(), "Jetzt fährt eine Linie zum Sportplatz")
	t.equal(metro.unmet_total, 0, "Die Lücke ist geschlossen")
	t.equal(metro.stranded_total, 0, "Niemand steht mehr ohne Anschluss da")
	t.equal(metro.demand_text(), "", "Ohne Lücke bleibt die Anzeige leer")
	t.equal(metro.unmet_top().size(), 0, "Es gibt nichts mehr zu melden")
	t.check(not _event_kinds(metro).has("unmet"), "Eine geschlossene Lücke meldet sich nicht noch einmal")

	# A line that only connects two homes covers nothing of the morning demand.
	var blind := _demo([Metro.Kind.HOME, Metro.Kind.PARK, Metro.Kind.HOME])
	var link := blind.begin_line(0)
	blind.extend_line(link, 1)
	blind.finish_line(link)
	_queue(blind, 0, Metro.Kind.OFFICE, 2)
	blind._update_service()
	t.equal(blind.stranded_at(0), 2, "Bürowartende kommen hier nicht weg")
	t.check(blind.unmet.has(Metro.Kind.OFFICE), "Und das Büro fehlt im ganzen Netz")
	t.check(blind.demand_text().contains("Büro"), "Das HUD nennt genau diese Lücke")
	t.suite_done()


# --- Berufsverkehrs-Prognose ------------------------------------------------

func _berufsverkehr() -> void:
	t.suite("Metropol 3D — Berufsverkehrs-Prognose")

	var metro := _demo([Metro.Kind.HOME, Metro.Kind.OFFICE, Metro.Kind.HOME])
	metro.day = 0
	metro.day_timer = Metro.DAY_DURATION * (10.0 / 24.0)
	t.equal(metro.hour_of_day(), 10, "Der Test steht um zehn Uhr")
	t.equal(metro.next_peak_hour(), 17, "Als Nächstes kommt der Feierabendverkehr")
	metro.day_timer = Metro.DAY_DURATION * (19.0 / 24.0)
	t.equal(metro.next_peak_hour(), 8, "Danach der Morgen des nächsten Tages")
	metro.day_timer = Metro.DAY_DURATION * (4.0 / 24.0)
	t.equal(metro.next_peak_hour(), 8, "Vor sechs kommt der Morgenverkehr")
	metro.day_timer = Metro.DAY_DURATION * (8.0 / 24.0)

	# Monday morning: the housing estate commutes to the office.
	var peak := metro.peak_demand()
	t.check(peak.size() > 0, "Der Berufsverkehr verlangt Ziele")
	t.equal(int(peak[0]["kind"]), Metro.Kind.OFFICE, "Die Wohnung pendelt morgens ins Büro")
	t.check(not bool(peak[0]["route"]), "Ohne Linie ist das Büro nicht abgedeckt")
	t.check(metro.peak_text().contains("08:00"), "Die Prognose nennt die Stunde")
	t.check(metro.peak_text().contains("Büro"), "Und das offene Ziel")

	# The line that the forecast asked for turns the warning off.
	var line := metro.begin_line(0)
	metro.extend_line(line, 1)
	metro.finish_line(line)
	t.check(bool((metro.peak_demand()[0] as Dictionary)["route"]), "Mit der Linie ist der Verkehr abgedeckt")
	t.equal(metro.peak_text(), "08:00 abgedeckt", "Die Prognose meldet Erfolg")

	# The forecast follows the calendar, not a fixed list.
	metro.day = 5
	var weekend := metro.peak_demand()
	t.equal(weekend.size(), 0, "Am Wochenende fragt hier niemand nach dem Büro")
	t.equal(metro.peak_text(), "", "Ohne Nachfrage gibt es keine Prognose")
	metro.day = 6
	metro.day_timer = Metro.DAY_DURATION * (18.0 / 24.0)
	t.equal(metro.next_peak_hour(), 8, "Nach dem Wochenende wartet der Montagmorgen")
	t.check(metro.peak_demand().size() > 0, "Und der Montagmorgen hat wieder Ziele im Gepäck")
	t.suite_done()


# --- Screen -----------------------------------------------------------------

## The visible half of the forecast: a red flag over a station whose queue has
## no way out, a HUD line naming the missing line, and both disappearing as
## soon as the player builds it.
func _anschluss_marker(tree: SceneTree) -> void:
	t.suite("Metropol 3D — Anschluss-Marker")
	var router := tree.root.get_node_or_null("/root/Router")
	t.check(router != null, "Der Router ist erreichbar")
	if router == null:
		t.suite_done()
		return
	await t.goto(router, tree, "metro3d")
	var screen = router.current_screen
	t.check(screen != null, "Der Screen wird geöffnet")
	if screen == null:
		t.suite_done()
		return
	screen._start_run(Metro.Mode.NORMAL)
	await tree.create_timer(0.3).timeout
	var metro: Metro = screen.metro

	# A city with a clear gap: the stadium line exists, but not on the way home.
	metro.stations[0]["type"] = Metro.Kind.HOME
	metro.stations[1]["type"] = Metro.Kind.OFFICE
	metro.stations[2]["type"] = Metro.Kind.PARK
	var stadium := metro._spawn_station_at(Vector2(72.0, 52.0), Metro.Kind.SPORTS)
	var home := metro.begin_line(0)
	metro.extend_line(home, 1)
	metro.finish_line(home)
	var away := metro.begin_line(2)
	metro.extend_line(away, stadium)
	metro.finish_line(away)
	for i in Metro.STRANDED_MIN:
		(metro.stations[0]["waiting"] as Array).append(metro._alloc_passenger(Metro.Kind.SPORTS))
	screen._update_world(0.05)

	var marker: Label3D = screen._station_nodes[0].get_node("Demand")
	t.check(marker.visible, "Der Marker steht über dem festgefahrenen Bahnhof")
	t.check(marker.text.contains("P"), "Er nennt den gesuchten Zielort")
	var quiet: Label3D = screen._station_nodes[1].get_node("Demand")
	t.check(not quiet.visible, "Der bediente Bahnhof bleibt ohne Marker")
	# The HUD and the notify line are the two places the player reads this. Both
	# name the destination the city is missing, and both reach the screen through
	# `Loc` — so the expectation is the destination's own name rather than the
	# German word "ohne Anschluss", which the source no longer produces and which
	# the assertion therefore never actually checked. Both spellings are accepted:
	# a caption assembled with `%` before it reaches `Loc` still carries the source
	# spelling, and one assembled by `Loc.f` carries the translated one.
	t.equal(screen._demand_label.text, metro.demand_text(),
		"Das HUD zeigt genau den Text der Logik")
	t.check(not metro.demand_text().is_empty() and _names(screen._demand_label.text, Metro.Kind.SPORTS),
		"Und nennt den Zielort, für den es keine Linie gibt")
	t.check(screen._peak_label.text.contains(":"), "Die Berufsverkehrs-Prognose steht im HUD")
	t.check(screen._notify_label != null and not screen._notify_label.text.is_empty() \
			and _names(screen._notify_label.text, Metro.Kind.SPORTS),
		"Der Hinweis auf dem Weg zum Bahnhof erscheint und nennt den gesuchten Zielort")

	# Building the line the forecast asked for clears the station.
	metro.extend_line(home, 2)
	screen._update_world(0.05)
	t.check(not marker.visible, "Mit der passenden Linie verschwindet der Marker")
	t.equal(metro.stranded_total, 0, "Und niemand steht mehr ohne Anschluss da")
	t.equal(metro.demand_text(), "", "Das HUD hat nichts mehr zu melden")

	await t.goto(router, tree, "lobby")
	t.check(router.current_id == "lobby", "Zurück in die Lobby")
	t.suite_done()
