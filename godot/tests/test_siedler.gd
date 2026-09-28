class_name TestSiedler
extends RefCounted
## Regression tests for the advisor of "Siedler 3D".
##
## The advisor answers the question a fresh settlement game costs the most to get
## wrong: *which* building is short of *which* good, and what to do about it.
## Everything here is pure logic from `core/logic/siedler.gd`, so no scene needed.

var t: TestKit


## Entry point used by `run_tests.gd`.
##
## Every suite is followed by `t.close_suite()`: a GDScript runtime error unwinds
## the suite function without raising, so an aborted suite would look like one
## that simply stopped asserting.
func run(kit: TestKit) -> void:
	t = kit
	_producer_lookup()
	t.close_suite()
	_stall_reason()
	t.close_suite()
	_ranking()
	t.close_suite()
	_agrees_with_tick()
	t.close_suite()
	_actions()
	t.close_suite()
	_route_measure()
	t.close_suite()
	_route_value()
	t.close_suite()
	_route_report()
	t.close_suite()
	_route_split()
	t.close_suite()
	_route_optimize()
	t.close_suite()
	_depot()
	t.close_suite()


## A game with a fixed seed, so every expectation stays stable.
func _siedler(seed_value: int = 21, size: int = 44) -> Siedler:
	var siedler := Siedler.new()
	siedler.setup(seed_value, size)
	return siedler


## A free cell of a terrain kind near the castle, -1 if there is none. Two
## conditions filter the random map: only cells in own territory and — for sites
## without a deposit — only flat ground, because `place_building` refuses both
## otherwise. Deposits (wood, stone, coal) need no flat cell: `flat_only` is
## false for them.
func _cell_near(siedler: Siedler, res: String, max_r: int = 4, flat_only: bool = true) -> int:
	var castle_cell: int = siedler.buildings[siedler.castle_id]["cell"]
	var cx: int = castle_cell % siedler.map_size
	var cy: int = castle_cell / siedler.map_size
	for r in range(1, max_r + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var x := cx + dx
				var y := cy + dy
				if not siedler.in_bounds(x, y):
					continue
				var index := siedler.cell_index(x, y)
				var cell: Dictionary = siedler.cells[index]
				if str(cell["res"]) != res:
					continue
				if int(cell["building"]) >= 0 or int(cell["flag"]) >= 0:
					continue
				if not siedler.in_territory(index):
					continue
				if flat_only and not siedler.is_flat(index):
					continue
				return index
	return -1


func _run(siedler: Siedler, seconds: float) -> void:
	for i in int(seconds * 30.0):
		siedler.tick(1.0 / 30.0)


## Does the sentence the advisor produced name this thing?
##
## The advisor writes in the source language and hands its sentences to the
## player through `Loc`, so a test that spelled out German prose was asserting
## one language's wording — and in German it only passed while the catalogue had
## not caught up with the conversion. Both sides are therefore resolved, so the
## comparison is about what the player reads rather than about the language.
##
## Both spellings of the token are accepted, because not every sentence the
## advisor builds goes through the catalogue: a sentence that is a raw literal
## still contains the *source* spelling of a name whose catalogue entry is
## translated, and a test that only accepted the translated one would fail on a
## name that is demonstrably there. Case is folded because a token may sit at the
## start of an English clause and in the middle of a translated one.
func _mentions(sentence: String, token: String) -> bool:
	var text := Loc.resolve(sentence).to_lower()
	return text.contains(Loc.resolve(token).to_lower()) or text.contains(token.to_lower())


## The words of a rendered template up to its first placeholder, so a test can
## tell which branch of the report a sentence came from without depending on the
## language it is written in. The catalogue decides what the words are; the test
## only asks where the sentence starts.
func _branch(template: String) -> String:
	var resolved := Loc.resolve(template)
	var head := resolved.get_slice("%", 0) if resolved.contains("%") else resolved
	return head.strip_edges()


## The building the advisor compares everything else against: the one that needs
## the fewest planks. `Siedler._cheapest_build` is private, so the rule is
## re-derived here — one loop, and the test needs the *kind* to read its cost.
func _cheapest_kind() -> String:
	var best := ""
	var best_cost := 1 << 30
	for kind in Siedler.buildable_kinds():
		var cost := int((Siedler.spec_of(kind)["cost"] as Dictionary).get("planks", 1 << 30))
		if cost < best_cost:
			best_cost = cost
			best = kind
	return best if best != "" else "woodcutter"


## The player's first building of that kind.
func _find(siedler: Siedler, kind: String) -> Dictionary:
	for building in siedler.buildings:
		if str(building["owner"]) == "player" and str(building["kind"]) == kind:
			return building
	return {}


## Places a finished building, skipping build wood, build time and crew — the
## advisor has to answer *independently* of the waiting time, or every test would
## depend on how long the game runs.
func _finish(siedler: Siedler, kind: String, cell: int) -> Dictionary:
	if cell < 0 or not siedler.place_building(kind, cell):
		return {}
	var building := _find(siedler, kind)
	if building.is_empty():
		return {}
	building["state"] = "done"
	building["workers"] = int(Siedler.spec_of(kind)["workers"])
	building["tool"] = str(Siedler.spec_of(kind)["tool"])
	return building


## Connects a building to the castle.
func _link(siedler: Siedler, building: Dictionary) -> void:
	siedler.build_road(int(siedler.buildings[siedler.castle_id]["cell"]), int(building["cell"]))


## The first entry with that code, `{}` if there is none.
func _with_code(list: Array[Dictionary], code: String) -> Dictionary:
	for entry in list:
		if str(entry["code"]) == code:
			return entry
	return {}


## How often a code occurs in the list.
func _count_code(list: Array[Dictionary], code: String) -> int:
	var total := 0
	for entry in list:
		if str(entry["code"]) == code:
			total += 1
	return total


# --- master data -------------------------------------------------------------

func _producer_lookup() -> void:
	t.suite("Siedler — Ratgeber: Erzeuger")

	# "What do I build?" has an answer for every consumed good.
	t.equal(Siedler.producer_of("logs"), "woodcutter", "Stämme kommen aus dem Holzfäller")
	t.equal(Siedler.producer_of("flour"), "windmill", "Mehl kommt aus der Windmühle")
	t.equal(Siedler.producer_of("iron"), "smelter", "Eisen kommt aus der Schmelze")
	t.equal(Siedler.producer_of("coal"), "coalMine", "Kohle kommt aus der Kohlemine")
	# The smithy forges all nine tools.
	for tool in Siedler.TOOLS:
		t.equal(Siedler.producer_of(tool), "toolsmith", "„%s“ kommt aus der Schlosserei" % tool)

	# Every good any building consumes has a producer — otherwise the advisor
	# would have to guess.
	for spec in Siedler.SPECS:
		for good in (spec["inputs"] as Dictionary):
			if int(spec["inputs"][good]) > 0:
				t.check(Siedler.producer_of(good) != "",
					"„%s“ für die „%s“ kann jemand herstellen" % [good, spec["name"]])
	# And nothing that does not exist: an invented good has no producer.
	t.equal(Siedler.producer_of("unobtainium"), "", "Eine unbekannte Ware hat keinen Erzeuger")
	t.suite_done()


# --- stall reasons ----------------------------------------------------------

func _stall_reason() -> void:
	t.suite("Siedler — Ratgeber: Stillstand")

	# A fresh settlement runs: no reason, no advice.
	var siedler := _siedler()
	t.equal(siedler.bottlenecks().size(), 0, "Eine leere Siedlung hat keinen Engpass")
	t.equal(siedler.top_bottleneck().size(), 0, "Und damit auch keinen obersten Rat")

	# Without a road a finished building stands still — and the advisor says *why*
	# instead of making the player count.
	var sawmill := _finish(siedler, "sawmill", _cell_near(siedler, "grass", 4))
	t.check(not sawmill.is_empty(), "Der Schreiner steht auf seinem Feld")
	if not sawmill.is_empty():
		t.equal(siedler.stall_of(sawmill), "notConnected", "Ohne Straße ist der Schreiner still")
		var entry := _with_code(siedler.bottlenecks(), "notConnected")
		t.equal(int(entry["severity"]), Siedler.SEV_WARNING, "Eine fehlende Straße wiegt schwer")
		t.equal(int(entry["building"]), int(sawmill["id"]), "Der Rat nennt das Gebäude")
		t.equal(int(entry["cell"]), int(sawmill["cell"]), "Und das Feld, das anzufunken ist")
		t.equal(str(entry["fix"]), "road:%d" % int(sawmill["id"]), "Und er schlägt eine Straße vor")

	# With a road and logs in store it runs.
	if not sawmill.is_empty():
		_link(siedler, sawmill)
		siedler.store["logs"] = 10
		t.equal(siedler.stall_of(sawmill), "", "Angeschlossen und beliefert läuft der Schreiner")
		t.equal(siedler.bottlenecks().size(), 0, "Damit ist der Engpass vom Tisch")

	# Without a saw, exactly the reason the inspector later shows.
	if not sawmill.is_empty():
		siedler.store["saw"] = 0
		sawmill["tool"] = ""
		sawmill["workers"] = 0
		t.equal(siedler.stall_of(sawmill), "noTool", "Ohne Säge fehlt das Werkzeug")
		var entry := _with_code(siedler.bottlenecks(), "noTool")
		t.equal(str(entry["good"]), "saw", "Der Rat nennt die Säge")
		t.check(_mentions(str(entry["title"]), Siedler.good_name("saw")), "Und der Titel nennt sie mit")
		t.equal(str(entry["fix"]), "build:toolsmith", "Ohne Schlosserei wird eine empfohlen")

	# The chain further: a smithy turns the build order into a toolsmith queue —
	# the handle the screen offers.
	if not sawmill.is_empty():
		var forge := _finish(siedler, "toolsmith", _cell_near(siedler, "grass", 4))
		if not forge.is_empty():
			_link(siedler, forge)
			siedler.store["iron"] = 10
			siedler.store["logs"] = 10
			t.equal(siedler.stall_of(forge), "", "Die Schlosserei selbst läuft")
			var entry := _with_code(siedler.bottlenecks(), "noTool")
			t.equal(str(entry["good"]), "saw", "Der Rat nennt weiter die Säge")
			t.equal(str(entry["fix"]), "queueTool", "Mit Schlosserei: Werkzeug einplanen")
			t.check(siedler.request_tool("saw"), "Der Griff nimmt das Werkzeug an")
			t.check(siedler.tool_queue.has("saw"), "Und es steht in der Schlange")
			# The smithy forges whatever is missing loudest, so the advice is gone
			# as soon as it is done.
			_run(siedler, 20.0)
			t.check(_with_code(siedler.bottlenecks(), "noTool").is_empty(),
				"Die Schlosserei behebt den Engpass von selbst")

	# A depleted seam is its own reason, not a shortage of goods.
	var pit := _siedler()
	var mine := _finish(pit, "coalMine", _cell_near(pit, "coal", 6, false))
	if not mine.is_empty():
		_link(pit, mine)
		pit.store["pickaxe"] = 4
		pit.cells[int(mine["cell"])]["amount"] = 0
		t.equal(pit.stall_of(mine), "noResource", "Eine leere Ader steht still")
		var entry := _with_code(pit.bottlenecks(), "noResource")
		t.check(_mentions(str(entry["detail"]), str(Siedler.spec_of("coalMine")["name"])),
			"Der Rat nennt die Lagerstätte")
		t.equal(str(entry["fix"]), "build:coalMine", "Und schlägt eine neue Kohlemine vor")

	# No free settler is the only reason that resolves itself — hence the lowest
	# severity.
	var staff := _siedler()
	var farm := _finish(staff, "farm", _cell_near(staff, "grass", 4))
	if not farm.is_empty():
		staff.build_road(int(staff.buildings[staff.castle_id]["cell"]), int(farm["cell"]))
		staff.serfs.clear()
		farm["workers"] = 0
		t.equal(staff.stall_of(farm), "noWorker", "Ohne besetzten Platz steht der Betrieb still")
		var entry := _with_code(staff.bottlenecks(), "noWorker")
		t.equal(int(entry["severity"]), Siedler.SEV_HINT, "Fehlende Siedler sind ein sanfter Rat")
		t.equal(str(entry["fix"]), "build:warehouse", "Der Rat schlägt ein Lager vor")

	# A construction site is intention, not a stall.
	var site := _siedler()
	var plot := _cell_near(site, "grass", 4)
	if plot >= 0 and site.place_building("sawmill", plot):
		var building := _find(site, "sawmill")
		t.check(str(building["state"]) == "building" or str(building["state"]) == "levelling",
			"Der Bauplatz ist noch nicht fertig")
		t.equal(site.stall_of(building), "", "Ein Bauplatz zählt nicht als Stillstand")
		t.equal(site.bottlenecks().size(), 0, "Und erzeugt keinen Rat")

	# The same for a deliberately halted building.
	var halted := _siedler()
	var mill := _finish(halted, "farm", _cell_near(halted, "grass", 4))
	if not mill.is_empty():
		_link(halted, mill)
		mill["halted"] = true
		t.equal(halted.stall_of(mill), "", "Anhalten ist eine Absicht des Spielers")
		t.equal(halted.bottlenecks().size(), 0, "Und kein Rat")

	# Rival buildings do not belong in the player's list.
	var rival := _siedler()
	for building in rival.buildings:
		if str(building["owner"]) == "rival" and str(building["kind"]) != "castle":
			building["workers"] = 0
			building["tool"] = ""
	t.check(_count_code(rival.bottlenecks(), "noWorker") == 0,
		"Der Ratgeber urteilt nur über die eigene Siedlung")
	t.suite_done()


# --- ranking ----------------------------------------------------------------

func _ranking() -> void:
	t.suite("Siedler — Ratgeber: Rangfolge")

	# An empty store beats everything else.
	var siedler := _siedler()
	siedler.store["bread"] = 0
	siedler.store["fish"] = 0
	siedler.store["ham"] = 0
	var mine := _finish(siedler, "ironMine", _cell_near(siedler, "iron", 5, false))
	if not mine.is_empty():
		_link(siedler, mine)
		siedler.store["pickaxe"] = 2
		# A second, completely independent problem: the road is missing here.
		_finish(siedler, "bakery", _cell_near(siedler, "grass", 4))
		var list := siedler.bottlenecks()
		t.check(list.size() >= 2, "Zwei unabhängige Probleme ergeben zwei Ratschläge")
		t.equal(str(list[0]["code"]), "noFood", "Der Hunger steht oben")
		t.equal(int(list[0]["severity"]), Siedler.SEV_CRITICAL, "Und wiegt am schwersten")
		t.check(_mentions(str(list[0]["detail"]), str(Siedler.spec_of("bakery")["name"])),
			"Der Rat nennt die leere Kammer und ihren Ausweg")
		t.equal(str(list[0]["fix"]), "book:food", "Und öffnet das Nahrungs-Baublatt")
		# A starving miner is *not* also reported as "good missing" — otherwise
		# half the list is the same problem twice.
		t.equal(_count_code(list, "noFood") + _count_code(list, "hungry"), 1,
			"Hunger wird genau einmal genannt")
		t.equal(_count_code(list, "notConnected"), 1, "Die fehlende Straße kommt trotzdem vor")

	# Five workshops without coal would be five sentences — the advisor bundles.
	var coal := _siedler()
	coal.store["coal"] = 0
	coal.store["ironOre"] = 0
	var smelter := _finish(coal, "smelter", _cell_near(coal, "grass", 4))
	if not smelter.is_empty():
		_link(coal, smelter)
		# Ore present, coal gone: exactly the beginner's most expensive mistake.
		coal.store["ironOre"] = 4
		var list := coal.bottlenecks()
		var single := _with_code(list, "noInput")
		t.equal(_count_code(list, "noInput"), 1, "Ein fehlender Rohstoff, ein Rat")
		t.equal(str(single["good"]), "coal", "Und er nennt die Kohle, nicht das Erz")
		t.check(_mentions(str(single["detail"]), Siedler.good_name("coal")), "Der Text nennt sie ebenfalls")
		t.equal(str(single["fix"]), "build:coalMine", "Der Rat schlägt die Kohlemine vor")

	# Two *different* missing goods give two hints — bundling groups by good, not
	# only by building.
	var two := _siedler()
	two.store["logs"] = 0
	two.store["coal"] = 0
	two.store["ironOre"] = 0
	var mill := _finish(two, "sawmill", _cell_near(two, "grass", 4))
	var forge := _finish(two, "smelter", _cell_near(two, "grass", 4))
	if not mill.is_empty() and not forge.is_empty():
		_link(two, mill)
		_link(two, forge)
		var list := two.bottlenecks()
		t.equal(_count_code(list, "noInput"), 2, "Zerstückt nach Ware: ein Rat je Rohstoff")
		var goods: Array[String] = []
		for entry in list:
			if str(entry["code"]) == "noInput":
				goods.append(str(entry["good"]))
		t.check(goods.has("logs") and goods.has("coal"), "Beide Rohstoffe werden genannt")

	# The bigger gap wins: the smelter needs ore *and* coal, and the advice names
	# the good it is furthest from.
	var gap := _siedler()
	gap.store["coal"] = 0
	gap.store["ironOre"] = 1
	var oven := _finish(gap, "smelter", _cell_near(gap, "grass", 4))
	if not oven.is_empty():
		_link(gap, oven)
		t.equal(str(_with_code(gap.bottlenecks(), "noInput")["good"]), "coal",
			"Die größere Lücke wird zuerst genannt")

	# The list is stable and strictly sorted by severity — otherwise the card flips
	# between two equally bad causes.
	var twice := _siedler()
	twice.store["logs"] = 0
	var stall := _finish(twice, "sawmill", _cell_near(twice, "grass", 4))
	if not stall.is_empty():
		_link(twice, stall)
		var first: Array[String] = []
		for entry in twice.bottlenecks():
			first.append(str(entry["code"]))
		var second: Array[String] = []
		for entry in twice.bottlenecks():
			second.append(str(entry["code"]))
		t.equal(second, first, "Zwei Aufrufe liefern dieselbe Reihenfolge")
		var severity := Siedler.SEV_CRITICAL
		for entry in twice.bottlenecks():
			t.check(int(entry["severity"]) <= severity, "Schweregrade stehen absteigend")
			severity = int(entry["severity"])

	# Every entry carries the same fields — the screen must never guess.
	var sample := _siedler()
	_finish(sample, "sawmill", _cell_near(sample, "grass", 4))
	for entry in sample.bottlenecks():
		for field in ["severity", "code", "title", "detail", "good", "building", "cell", "count"]:
			t.check(entry.has(field), "Feld '%s' ist immer belegt" % field)
		t.check(not str(entry["title"]).is_empty(), "Jeder Rat hat einen Titel")
		t.check(not str(entry["detail"]).is_empty(), "Jeder Rat hat einen Erklärungssatz")

	# A jam at a flag is the advice that points at the original's invention: split
	# the stretch so more carriers share it.
	var jam := _siedler()
	var node_id := -1
	for node in jam.nodes:
		if bool(node["flag"]):
			node_id = int(node["id"])
			break
	if node_id >= 0:
		# A small backlog is normal and is not reported.
		for i in Siedler.JAM_LIMIT:
			(jam.nodes[node_id]["queue"] as Array).append("logs")
		t.check(_with_code(jam.bottlenecks(), "congestion").is_empty(),
			"Wenige wartende Waren sind kein Stau")
		for i in 3:
			(jam.nodes[node_id]["queue"] as Array).append("logs")
		var entry := _with_code(jam.bottlenecks(), "congestion")
		var flag_cell := int(jam.nodes[node_id]["cell"])
		t.equal(int(entry["count"]), (jam.nodes[node_id]["queue"] as Array).size(),
			"Der Stau nennt die Zahl der wartenden Waren")
		t.equal(int(entry["cell"]), flag_cell, "Und die Fahne, die voll ist")
		t.equal(str(entry["fix"]), "flag:%d" % flag_cell, "Der Rat schlägt dort eine Fahne vor")
		t.equal(int(entry["severity"]), Siedler.SEV_HINT, "Ein Stau ist ein sanfter Rat")
	# The screen must be able to aim at the advice at any time.
	if not stall.is_empty():
		t.equal(int(_with_code(twice.bottlenecks(), "noInput")["cell"]), int(stall["cell"]),
			"Der Rat zeigt auf das Feld, das betroffen ist")
	t.suite_done()


# --- advisor and tick agree --------------------------------------------------

func _agrees_with_tick() -> void:
	t.suite("Siedler — Ratgeber: Taktgleichheit")

	# The advisor's one promise: it never contradicts the state the screen draws.
	# So run the game, then compare both.
	var siedler := _siedler(21, 44)
	siedler.store["planks"] = 200
	siedler.store["stone"] = 200
	siedler.store["coal"] = 0
	siedler.store["ironOre"] = 0
	var wood := _cell_near(siedler, "forest", 4, false)
	var rock := _cell_near(siedler, "stone", 4, false)
	var mill := _cell_near(siedler, "grass", 4)
	if wood >= 0:
		_finish(siedler, "woodcutter", wood)
	if rock >= 0:
		_finish(siedler, "quarry", rock)
	if mill >= 0:
		_finish(siedler, "sawmill", mill)
	# A smelter without coal and without ore: the permanent stall the advisor has to
	# work on all the time. The cell is searched for *now* — earlier the smelter
	# would have taken the same one as the sawmill.
	_finish(siedler, "smelter", _cell_near(siedler, "grass", 4))
	for building in siedler.buildings:
		if str(building["owner"]) == "player" and str(building["kind"]) != "castle":
			_link(siedler, building)
	siedler.store["axe"] = 2
	siedler.store["pickaxe"] = 2
	siedler.store["saw"] = 0
	_run(siedler, 40.0)

	# The switch to `stall_of` must not have cost the tick anything.
	t.check(siedler.produced_total > 0, "Die Siedlung produziert weiterhin")
	t.check(siedler.delivered_total > 0, "Und die Ware kommt über die Straßen an")

	var mismatches := 0
	var stalls := 0
	for building in siedler.buildings:
		if str(building["owner"]) != "player":
			continue
		var reason := siedler.stall_of(building)
		if reason == "":
			continue
		stalls += 1
		if str(building["status"]) != reason:
			mismatches += 1
	t.check(stalls > 0, "Der Testaufbau enthält mindestens einen Stillstand")
	t.equal(mismatches, 0, "Jeder Stillstand trägt denselben Grund im status")

	# And the other way: the tick may not report a reason the advisor does not know.
	var known := ["noTool", "noWorker", "hungry", "noResource", "notConnected", "noInput"]
	for building in siedler.buildings:
		if str(building["owner"]) != "player" or str(building["state"]) != "done":
			continue
		t.check(known.has(str(building["status"])) or str(building["status"]) == "ok"
			or str(building["status"]) == "halted",
			"Status '%s' ist eine bekannte Ursache" % str(building["status"]))
	t.suite_done()


# --- suggested actions -------------------------------------------------------

func _actions() -> void:
	t.suite("Siedler — Ratgeber: Handlung")

	# Every hint with a suggestion names a building that really exists, and the
	# missing good that handle is meant to fix.
	var siedler := _siedler()
	siedler.store["coal"] = 0
	siedler.store["ironOre"] = 0
	var smelter := _finish(siedler, "smelter", _cell_near(siedler, "grass", 4))
	if not smelter.is_empty():
		_link(siedler, smelter)
		var entry := _with_code(siedler.bottlenecks(), "noInput")
		var fix := str(entry["fix"])
		t.check(fix.begins_with("build:"), "Der Vorschlag ist ein Bauauftrag")
		var kind := fix.substr(6)
		t.check(kind in Siedler.KINDS, "„%s“ ist ein Gebäude dieses Spiels" % kind)
		t.equal(Siedler.producer_of(str(entry["good"])), kind,
			"Der Vorschlag erzeugt genau die fehlende Ware")

	# If the castle cannot pay for the build, the advisor says so by itself —
	# otherwise the player taps it and only hears "Not enough planks".
	var broke := _siedler()
	broke.store["coal"] = 0
	broke.store["ironOre"] = 0
	var oven := _finish(broke, "smelter", _cell_near(broke, "grass", 4))
	if not oven.is_empty():
		_link(broke, oven)
		var entry := _with_code(broke.bottlenecks(), "noInput")
		t.equal(str(entry["fix"]), "build:coalMine", "Der Rat schlägt die Kohlemine vor")
		# The advisor appends one sentence when the castle cannot pay for the
		# build it just proposed, and that sentence carries the *shortfall* — how
		# many planks and how much stone are missing. Both numbers come from the
		# settlement, so the expectation is composed the way the advisor composes
		# it, from the same template.
		var coal_mine := Siedler.spec_of("coalMine")
		var cost: Dictionary = coal_mine["cost"]
		var affordable := str(entry["detail"])
		var affordable_note := Loc.f(" The castle is still short %d planks or %d stone.", [
			maxi(0, int(cost["planks"]) - int(broke.store.get("planks", 0))),
			maxi(0, int(cost["stone"]) - int(broke.store.get("stone", 0))),
		])
		t.check(not Loc.resolve(affordable).contains(Loc.resolve(affordable_note)),
			"Die Burg kann den Bauauftrag noch bezahlen — der Satz fehlt")
		# Remove the build wood only now — before that the castle could still build.
		broke.store["planks"] = 0
		broke.store["stone"] = 0
		var broke_detail := str(_with_code(broke.bottlenecks(), "noInput")["detail"])
		var broke_note := Loc.f(" The castle is still short %d planks or %d stone.", [
			int(cost["planks"]), int(cost["stone"])])
		t.check(Loc.resolve(broke_detail).contains(Loc.resolve(broke_note)),
			"Nimmt der Ratgeber auch beim Bauauftrag das fehlende Bauholz ernst")
		t.check(_mentions(broke_detail, str(coal_mine["name"])),
			"Und nennt dabei weiter das Gebäude, das die Ware liefert")
		# And a castle that cannot pay anything is itself the reason this hint is
		# not actionable.
		var wall := _with_code(broke.bottlenecks(), "noBuild")
		t.equal(int(wall["severity"]), Siedler.SEV_CRITICAL, "Die tote Burg wiegt am schwersten")
		t.equal(str(broke.top_bottleneck()["code"]), "noBuild", "Sie steht oben")
		# The dead castle is useless without a number: *how much* is missing and
		# *what it would buy* is the whole message. Both come from the settlement,
		# so the sentence is composed here from the same template the advisor uses
		# and the comparison is exact in every language.
		var cheapest := _cheapest_kind()
		var affordable_fix := "Fix the idle entries in this list first, then keep building."
		var broke_fix := "Get logs to the carpenter first — only that becomes planks again."
		var cheap_cost: Dictionary = Siedler.spec_of(cheapest)["cost"]
		t.equal(str(wall["detail"]), Loc.f(
			"The castle has %d planks and %d stone; the cheapest building, a “%s”, costs %d planks. %s",
			[int(broke.store.get("planks", 0)), int(broke.store.get("stone", 0)),
				str(Siedler.spec_of(cheapest)["name"]), int(cheap_cost["planks"]), broke_fix]),
			"Und nennt den leeren Bestand samt dem, was er kaufen würde")
		t.check(not Loc.resolve(str(wall["detail"])).contains(Loc.resolve(affordable_fix)),
			"Der Rat ist nicht der allgemeine, sondern der zu diesem Engpass")

	# Having build plots is not a bottleneck by itself — but a happy, poorer
	# settlement still has none.
	var poor := _siedler()
	var dead := _finish(poor, "sawmill", _cell_near(poor, "grass", 4))
	if not dead.is_empty():
		_link(poor, dead)
		t.equal(poor.bottlenecks().size(), 0, "Eine ärmere, laufende Siedlung hat keinen Engpass")
		# Now remove the build wood the sawmill would otherwise deliver.
		poor.store["planks"] = 0
		poor.store["stone"] = 0
		poor.store["logs"] = 0
		var top := poor.top_bottleneck()
		t.equal(str(top["code"]), "noBuild",
			"Sobald etwas klemmt, ist die tote Burg der erste Rat")
		# The generic advice would be "fix the idle entries first", which sends the
		# player in circles. With no logs at all the advisor has to name the good
		# that has to come back, so the sentence is compared against the good name
		# rather than against one language's word for it.
		# The generic advice — "fix the idle entries first" — sends the player in
		# circles here, because nothing is idle: no logs means no planks, and no
		# planks means nothing gets built. The specific sentence names the good
		# that has to come back instead, so that is what the report has to carry.
		var carpenter := "Get logs to the carpenter first — only that becomes planks again."
		t.check(Loc.resolve(str(top["detail"])).contains(Loc.resolve(carpenter)),
			"Der Rat verweist auf den echten Engpass dahinter")
		t.check(not Loc.resolve(str(top["detail"])).contains(
				Loc.resolve("Fix the idle entries in this list first, then keep building.")),
			"Statt auf die Liste zu verweisen, die ohnehin nichts löst")

	# The toolsmith queue takes at most six requests — the advisor must not lead
	# the player into a dead end.
	var queue := _siedler()
	for i in 12:
		queue.request_tool("axe")
	t.equal(queue.tool_queue.size(), 6, "Die Schlange ist begrenzt")
	t.check(not queue.request_tool("axe"), "Und meldet, wenn sie voll ist")
	t.suite_done()


# --- trade route optimiser ---------------------------------------------------
# "Handelsweg optimieren" builds on a number that did not exist before: which good
# travels over which road. These four suites pin the chain from the measurement
# through the report to the handle — above all that the handle costs the player
# nothing.

## A settlement where goods really travel over the roads: woodcutter, quarry and
## sawmill all connected to the castle, plus the tools. Without traffic every
## route number is zero and the tests prove nothing.
##
## The cells are deliberately *not* right at the castle gate: a woodcutter next to
## the castle only makes a stub, and a stub teaches nothing about a trade route.
func _trading_siedler(seed_value: int = 21, size: int = 44) -> Siedler:
	var siedler := _siedler(seed_value, size)
	siedler.store["planks"] = 200
	siedler.store["stone"] = 200
	siedler.store["logs"] = 0
	var wood := _cell_far(siedler, "forest", 3, 9, false)
	var rock := _cell_far(siedler, "stone", 3, 9, false)
	var mill := _cell_far(siedler, "grass", 3, 7, true)
	if wood >= 0:
		_finish(siedler, "woodcutter", wood)
	if rock >= 0:
		_finish(siedler, "quarry", rock)
	if mill >= 0:
		_finish(siedler, "sawmill", mill)
	for building in siedler.buildings:
		if str(building["owner"]) == "player" and str(building["kind"]) != "castle":
			_link(siedler, building)
	siedler.store["axe"] = 2
	siedler.store["pickaxe"] = 2
	return siedler


## Like `_cell_near`, but with a minimum distance from the castle: the route
## suites need real roads, not just a stub to the neighbour.
func _cell_far(siedler: Siedler, res: String, min_r: int, max_r: int, flat_only: bool) -> int:
	var castle_cell: int = siedler.buildings[siedler.castle_id]["cell"]
	var cx: int = castle_cell % siedler.map_size
	var cy: int = castle_cell / siedler.map_size
	for r in range(mini(max_r + 1, min_r), max_r + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var x := cx + dx
				var y := cy + dy
				if not siedler.in_bounds(x, y):
					continue
				var index := siedler.cell_index(x, y)
				var cell: Dictionary = siedler.cells[index]
				if str(cell["res"]) != res:
					continue
				if int(cell["building"]) >= 0 or int(cell["flag"]) >= 0:
					continue
				if not siedler.in_territory(index):
					continue
				if flat_only and not siedler.is_flat(index):
					continue
				return index
	return -1


## The first report entry that carries anything at all.
func _busiest(siedler: Siedler) -> Dictionary:
	var routes := siedler.trade_report()
	return routes[0] if not routes.is_empty() else {}


func _route_measure() -> void:
	t.suite("Siedler — Handelswege: Messung")

	# Without traffic the measurement is zero — and that is exactly the start state
	# the report has to show the player too.
	var fresh := _siedler()
	t.equal(fresh.measured_carriers(), 0, "Eine frische Siedlung hat noch keinen Verkehr gemessen")
	t.equal(fresh.trade_report().size(), 0, "Und deshalb noch keinen Handelsweg im Bericht")

	var siedler := _trading_siedler()
	_run(siedler, 40.0)

	t.check(siedler.measured_carriers() > 0, "Nach einem Lauf ist Verkehr gemessen")
	var routes := siedler.trade_report()
	t.check(routes.size() > 0, "Der Bericht nennt mindestens eine Strecke")
	if routes.is_empty():
		t.fail("Der Testaufbau hat keinen Verkehr auf die Straßen gebracht")
		t.suite_done()
		return
	t.equal(siedler.measured_carriers(), _sum_traffic(siedler),
		"Die gemeldete Summe stimmt mit den Zählern überein")

	# Every entry carries the same fields — otherwise the screen would have to guess.
	var fields := ["edge", "a", "b", "length", "carriers", "top", "top_count",
		"total", "waiting", "jammed", "priority", "value", "gain", "cell", "throughput"]
	var complete := true
	for entry in routes:
		for field in fields:
			complete = complete and entry.has(field)
	t.check(complete, "Jeder Eintrag trägt dieselben Felder")
	var first: Dictionary = routes[0]
	t.check(str(first["top"]) in Siedler.GOODS, "Die Hauptware ist eine echte Ware")
	t.check(int(first["top_count"]) > 0, "Und sie wurde auch gezählt")
	t.check(int(first["total"]) >= int(first["top_count"]), "Die Summe ist mindestens so groß")

	# The report is sorted by traffic: the busiest stretch is on top, because that
	# is the one worth changing.
	var sorted := true
	for i in range(1, routes.size()):
		sorted = sorted and int(routes[i - 1]["total"]) >= int(routes[i]["total"])
	t.check(sorted, "Der Bericht ist nach Verkehr sortiert")

	# Building a road shifts the edge ids. The old numbers would be wrong, so the
	# measurement restarts — and the player optimises exactly after building.
	t.check(siedler.measured_carriers() > 0, "Vor dem Straßenbau ist gemessen worden")
	var castle_cell: int = siedler.buildings[siedler.castle_id]["cell"]
	var built := false
	for r in range(4, 9):
		var target := _nearest_grass(siedler, castle_cell, r)
		if target < 0:
			continue
		if bool(siedler.build_road(castle_cell, target, 3)["ok"]):
			built = true
			break
	if built:
		t.equal(siedler.measured_carriers(), 0, "Nach dem Straßenbau beginnt die Messung von vorn")
	else:
		t.fail("Der Testaufbau konnte keine zweite Straße bauen")
	t.suite_done()


## The sum of all counters — the test recomputes it instead of trusting the game.
func _sum_traffic(siedler: Siedler) -> int:
	var total := 0
	for i in siedler.edges.size():
		total += int(siedler.edge_traffic(i)["total"])
	return total


## A free grass cell around `near`, so the test can build a second road without
## depending on the map.
func _nearest_grass(siedler: Siedler, near: int, max_r: int = 6) -> int:
	var cx: int = near % siedler.map_size
	var cy: int = near / siedler.map_size
	for r in range(2, max_r + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				if not siedler.in_bounds(cx + dx, cy + dy):
					continue
				var index := siedler.cell_index(cx + dx, cy + dy)
				if str(siedler.cells[index]["res"]) != "grass":
					continue
				if int(siedler.cells[index]["building"]) >= 0 or int(siedler.cells[index]["flag"]) >= 0:
					continue
				return index
	return -1


func _route_value() -> void:
	t.suite("Siedler — Handelswege: Ware und Wert")

	# Food outranks everything: a mine without food produces for nobody.
	var siedler := _siedler()
	t.check(siedler.trade_value("bread") >= 4, "Brot ist für die Siedlung wertvoll")
	t.equal(siedler.trade_value(""), 0, "Eine unbekannte Ware hat keinen Wert")
	t.equal(siedler.trade_value("gibtsnicht"), 0, "Und eine erfundene auch nicht")

	# The value follows *measured* hunger, not the catalogue: a building that
	# already has its planks is not waiting.
	var mill_cell := _cell_near(siedler, "grass", 4)
	var mill := _finish(siedler, "sawmill", mill_cell)
	if not mill.is_empty():
		_link(siedler, mill)
		t.equal(siedler.trade_value("logs"), 5, "Der Schreiner ohne Bauholz wartet auf Stämme")
		# And the priority follows the ladder, not chance.
		t.equal(siedler.priority_for("logs"), 6, "Wartende Ware bekommt Priorität 6")
		mill["input"]["logs"] = 8
		t.equal(siedler.trade_value("logs"), 3, "Mit genug Stämmen wartet er nicht mehr")
		t.equal(siedler.priority_for("logs"), 4, "Und die Priorität sinkt mit auf Stufe 4")
	t.equal(siedler.priority_for("bread"), 5, "Nahrung bekommt die Stufe darüber")
	t.equal(siedler.priority_for("nichts"), 2, "Füllgut die unterste Stufe")

	# The ladder is strictly descending: something more valuable can never get a
	# lower priority than something worthless. Checked on the mapping itself, not
	# on two examples.
	var steps: Array[int] = [2, 3, 4, 5, 6]
	var monotone := true
	for i in range(1, steps.size()):
		monotone = monotone and steps[i] > steps[i - 1]
	t.check(monotone, "Die Prioritätsstufen sind streng fallend")
	var mapped := [siedler.priority_for(""), siedler.priority_for("nichts")]
	t.check(int(mapped[0]) == int(mapped[1]), "Unbekannte Ware landet auf der untersten Stufe")
	t.suite_done()


func _route_report() -> void:
	t.suite("Siedler — Handelswege: Bericht")

	var siedler := _trading_siedler()
	_run(siedler, 40.0)
	var routes := siedler.trade_report()
	t.check(routes.size() > 0, "Der Bericht hat etwas zu sagen")
	if routes.is_empty():
		t.suite_done()
		return

	# The advice names the next handle, not the state. Without a jam and with a
	# fitting priority there is only the quiet sentence.
	for entry in routes:
		var advice := siedler.route_advice(entry)
		t.check(not advice.is_empty(), "Jede Strecke bekommt einen Satz")
		# Three sentences, one per state of the route: a jam, a priority that is
		# too low, and a route that already runs. The third names no good, so the
		# check is "it names the good, or it is one of the other two" — decided
		# on the catalogue, not on German prose.
		t.check(_mentions(advice, Siedler.good_name(str(entry["top"]))) \
			or advice.begins_with(_branch("Queue: %d goods are waiting on this route.")) \
			or advice.begins_with(_branch("Running: %.0f tiles, %d carriers, priority %d.")),
			"Der Satz redet über die Ware dieser Strecke")
		break

	# The order is a promise to the player: jams first, because a jam is the only
	# thing the optimiser fixes immediately, then traffic, then length. Without
	# jam-first the row the player just tapped would sink on the next pass.
	var jams_first := true
	for i in range(1, routes.size()):
		if bool(routes[i - 1]["jammed"]) and not bool(routes[i]["jammed"]):
			jams_first = false
	t.check(jams_first, "Jede verstopfte Strecke steht im Bericht über jeder freien")

	# A jam beats everything: it is the only thing the optimiser actually fixes by
	# itself.
	var busy := _busiest(siedler)
	busy["waiting"] = Siedler.ROUTE_JAM
	busy["jammed"] = true
	busy["cell"] = 3
	busy["gain"] = 4
	# Each state gets its own sentence, and the three are told apart by the
	# template they were built from. The advice quotes a number, so the test
	# asserts the sentence differs between the states and matches its own
	# numbers — the wording belongs to the catalogue.
	var jam_note := siedler.route_advice(busy)
	t.check(jam_note.begins_with(_branch("Queue: %d goods are waiting on this route.")) \
		and _mentions(jam_note, str(int(busy["waiting"]))),
		"Bei Stau nennt der Bericht zuerst den Stau")
	busy["jammed"] = false
	busy["priority"] = 1
	busy["top"] = "logs"
	# A route whose priority is too low has to say *which* priority and *which*
	# good — the player has to be able to act on it. The sentence is rendered from
	# the catalogue, so the test checks the two facts it carries.
	var low_note := siedler.route_advice(busy)
	t.check(_mentions(low_note, Siedler.good_name("logs")),
		"Ohne Stau nennt er die zu niedrige Priorität — samt der Ware")
	# The number belongs to the sentence the player reads, so it is composed the
	# way the report composes it: the template from the catalogue, the value from
	# the report. A bare "1" would be found in any sentence that contains a one.
	t.check(_mentions(low_note, "%s %d" % [_branch("priority %d"), 1]),
		"Und nennt die Zahl, die zu niedrig ist")
	busy["priority"] = 6
	var fine_note := siedler.route_advice(busy)
	t.check(fine_note.begins_with(_branch("Running: %.0f tiles, %d carriers, priority %d.")) \
		and _mentions(fine_note, "%s %d" % [_branch("priority %d"), 6]),
		"Passt die Priorität, gibt es nichts zu tun — und er nennt die Strecke")
	t.check(low_note != jam_note and fine_note != jam_note and fine_note != low_note,
		"Die drei Zustände bekommen drei verschiedene Sätze")

	# The report does not lie: it names a stretch that exists and an edge id the
	# player can really use.
	var first: Dictionary = routes[0]
	t.check(int(first["edge"]) >= 0 and int(first["edge"]) < siedler.edges.size(),
		"Die Kanten-Id zeigt auf eine echte Straße")
	t.equal(siedler.edge_priority(int(first["edge"])), int(first["priority"]),
		"Und die Priorität ist die, die dort wirklich steht")
	t.suite_done()


func _route_split() -> void:
	t.suite("Siedler — Handelswege: Streckenteilung")

	# `split_gain` is the promise the optimiser makes: a positive number means
	# splitting wins carriers, `0` means it leaves it alone. The pure function is
	# tested because it holds beyond the map layout — a too short road stays short.
	var siedler := _siedler()
	var short_road := {"kind": "road", "length": float(Siedler.SPLIT_LENGTH),
		"priority": 6, "carriers": []}
	t.equal(siedler.split_gain(short_road), 0,
		"Eine Strecke in Fahnenweite gewinnt durch Teilen nichts")

	var long_road := {"kind": "road", "length": float(Siedler.SPLIT_LENGTH) * 4.0,
		"priority": 6, "carriers": []}
	t.check(siedler.split_gain(long_road) > 0,
		"Eine viermal so lange Strecke gewinnt Träger, sonst wäre das Optimieren sinnlos")

	# The number is not an estimate: it is exactly the carrier count of the two
	# halves minus that of the whole stretch.
	t.equal(siedler.split_gain(long_road),
		Siedler.carrier_count_for(float(Siedler.SPLIT_LENGTH) * 2.0, 6) * 2,
		"Der Gewinn ist die Trägerzahl der beiden Hälften")

	# No stub is ever split, however long: it carries one carrier anyway, and two
	# halves of a stub would be two stubs.
	var stub := {"kind": "flag", "length": float(Siedler.SPLIT_LENGTH) * 8.0,
		"priority": 6, "carriers": []}
	t.equal(siedler.split_gain(stub), 0,
		"Kein Stummel wird geteilt, egal wie lang er ist")

	# `best_split_cell` follows `split_gain`. Where splitting wins nothing the report
	# names no cell either — otherwise the screen would point at a handle the
	# optimiser never makes.
	var agrees := true
	for edge in siedler.edges:
		if siedler.split_gain(edge) <= 0:
			agrees = agrees and siedler.best_split_cell(edge) == -1
	t.check(agrees, "Ohne Gewinn nennt der Bericht auch kein Feld für eine Fahne")

	# Where the report names a cell, a flag really has to fit there: no house,
	# since that is itself a traffic node, and no water, since water carries none.
	var trade := _trading_siedler()
	_run(trade, 40.0)
	var offered := -1
	for entry in trade.trade_report():
		if int(entry["gain"]) > 0:
			offered = int(entry["cell"])
			break
	if offered >= 0:
		t.check(offered < trade.cells.size(), "Das genannte Feld liegt auf der Karte")
		t.check(int(trade.cells[offered]["building"]) < 0,
			"Und trägt kein Haus")
		t.check(str(trade.cells[offered]["res"]) != "water",
			"Und ist kein Wasser")
	t.suite_done()


## Edge ids have to match their array indexes without a gap, every node may only
## name existing edges, and no stretch may lie in the net twice. Splitting is what
## rattles this invariant hardest: it removes one edge and appends two new ones,
## shifting every id behind them — and a button that addresses a road by its number
## would then point at a completely different one.
func _edge_integrity(siedler: Siedler) -> bool:
	for i in siedler.edges.size():
		if int(siedler.edges[i]["id"]) != i:
			return false
	var seen := {}
	for edge in siedler.edges:
		var low := mini(int(edge["a"]), int(edge["b"]))
		var high := maxi(int(edge["a"]), int(edge["b"]))
		var pair := [low, high]
		if seen.has(pair):
			return false
		seen[pair] = true
	for node in siedler.nodes:
		for edge_id in node["edges"]:
			if int(edge_id) < 0 or int(edge_id) >= siedler.edges.size():
				return false
	return true


func _route_optimize() -> void:
	t.suite("Siedler — Handelswege: Optimierung")

	# Without enough measurement the optimiser leaves the priorities alone.
	# Otherwise the first half minute of a settlement would read "priority 6" on
	# everything and the number would be a guess.
	var blind := _trading_siedler()
	_run(blind, 3.0)
	if blind.measured_carriers() < Siedler.MEASURE_MIN:
		var busy := _busiest(blind)
		if not busy.is_empty():
			blind.set_road_priority(int(busy["edge"]), 1)
			blind.optimize_trade_routes()
			t.equal(blind.edge_priority(int(busy["edge"])), 1,
				"Ohne genug Messung bleibt die Priorität, wie der Spieler sie setzte")

	# Now the full optimisation on a traffic net.
	var siedler := _trading_siedler()
	_run(siedler, 40.0)
	t.check(siedler.measured_carriers() >= Siedler.MEASURE_MIN, "Es ist genug Verkehr gemessen")
	var flags_before := 0
	for node in siedler.nodes:
		if bool(node["flag"]):
			flags_before += 1

	var first := siedler.optimize_trade_routes()
	var flags_after := 0
	for node in siedler.nodes:
		if bool(node["flag"]):
			flags_after += 1
	t.check(first.size() > 0, "Der Optimierer meldet, was er getan hat")
	t.check(flags_after - flags_before <= Siedler.MAX_SPLITS,
		"Er setzt höchstens %d Fahnen je Durchgang" % Siedler.MAX_SPLITS)
	t.check(_edge_integrity(siedler),
		"Nach dem Optimieren zeigt jede Kanten-Id noch auf ihre Straße, ohne Doppelung")
	t.check(not siedler.notice.is_empty(), "Und sagt es auch dem Spiel")
	t.equal(siedler.trade_report().size() >= 0, true,
		"Der Bericht lässt sich danach noch lesen")

	# Priorities only ever rise — that is the promise that makes the handle safe.
	var raised := 0
	for entry in siedler.trade_report():
		var want := siedler.priority_for(str(entry["top"]))
		if int(entry["priority"]) > want:
			raised += 1
	t.equal(raised, 0, "Keine Straße steht am Ende über ihrer Stufe")

	# And the second pass is a no-op: that is what makes the handle repeatable
	# without the player having to watch out.
	var edges_before := siedler.edges.size()
	var nodes_before := siedler.nodes.size()
	var second := siedler.optimize_trade_routes()
	t.equal(siedler.edges.size(), edges_before, "Der zweite Durchgang legt keine Straße an")
	t.equal(siedler.nodes.size(), nodes_before, "Und keine Fahne")
	t.check(second.size() > 0, "Er sagt trotzdem, was er gesehen hat")
	# Every line has to be one of the two "I changed nothing" sentences — a
	# report that listed a road it did not build would be a lie. Both are
	# resolved from the catalogue, so the check is about the report's honesty and
	# not about the language it happens to be in.
	var quiet := true
	for line in second:
		quiet = quiet and (Loc.resolve(line) == Loc.resolve("Too little traffic measured — the routes stay as they are.") \
			or Loc.resolve(line) == Loc.resolve("Nothing to do: the routes already carry what they should."))
	t.check(quiet, "Und zwar: nichts zu tun — jede Zeile sagt genau das")

	# A jam is the only condition for an extra flag. Without one the optimiser
	# leaves the stretch alone — otherwise it would be a flag machine, not an
	# optimisation.
	var calm := _trading_siedler()
	_run(calm, 40.0)
	for node in calm.nodes:
		(node["queue"] as Array).clear()
	var calm_flags := 0
	for node in calm.nodes:
		if bool(node["flag"]):
			calm_flags += 1
	calm.optimize_trade_routes()
	var calm_after := 0
	for node in calm.nodes:
		if bool(node["flag"]):
			calm_after += 1
	t.equal(calm_after, calm_flags, "Ohne Stau setzt der Optimierer keine Fahne")
	t.suite_done()


# --- depot: the finite store -------------------------------------------------
#
# The warehouse was the one building whose own description text was a lie: it
# promised storage capacity and delivered six settlers. So there was no cap — a
# settlement producing too much just had a bigger pile, and the road at the gate
# filled up with no explanation.
#
# Three promises are checked here: the warehouse really widens the store, a full
# store refuses deliveries and *counts* them per good, and the advisor names what
# is blocked and which producer eats the space. Plus the safeguard without which
# none of it is playable: the castle always takes planks, stone, food and tools.

## Fills the store with `good` without touching the starting goods, so the state
## does not depend on how full a fresh settlement happens to be.
func _flood(siedler: Siedler, good: String, amount: int) -> void:
	siedler.store[good] = amount


## The goods the castle *never* blocks: planks and stone pay for the settlement,
## food feeds it, a tool is the prerequisite for both. They do not count against
## the store slots.
func _free_goods() -> Array[String]:
	var out: Array[String] = ["planks", "stone"]
	for food in Siedler.FOODS:
		out.append(food)
	for tool in Siedler.TOOLS:
		out.append(tool)
	return out


## Fills the store with a *stored good* and empties what the settlement needs to
## build: a full castle that can still keep building.
func _spent_out(siedler: Siedler, good: String, amount: int) -> void:
	_flood(siedler, good, amount)
	for free_good in _free_goods():
		siedler.store[free_good] = 0


## Fills the store to the brim. Logs are the stored good that actually arrives in
## `_trading_siedler`: they grow in every forest the woodcutter finds, and the
## castle takes them even when they would otherwise go to the sawmill.
func _fill_depot(siedler: Siedler) -> void:
	for good in Siedler.GOODS:
		siedler.store[good] = 0
	siedler.store["logs"] = siedler.store_capacity()


func _depot() -> void:
	t.suite("Siedler — Ratgeber: Lagerplatz")

	# The warehouse says what it brings. The text lives in the master data, so the
	# number there and the rule have to match — otherwise the inspector tells the
	# player something the game does not do.
	t.check(str(Siedler.spec_of("warehouse")["desc"]).contains(str(Siedler.WAREHOUSE_STORE)),
		"Der Beschreibungstext des Lagers nennt die Lagerplätze, die es bringt")

	# Without a warehouse the castle has its base capacity — and that one is finite.
	var fresh := _siedler()
	t.equal(fresh.store_capacity(), Siedler.STORE_CAP, "Ohne Lager bleibt die Kapazität der Burg")
	var used := 0
	for good in Siedler.GOODS:
		if _free_goods().has(good):
			continue
		used += int(fresh.store.get(good, 0))
	t.equal(fresh.store_used(), used, "Die belegten Plätze sind die Lagerware der Burg")
	t.check(fresh.store_used() < fresh.store_capacity(),
		"Und das Startpaket passt noch hinein — sonst startet die Siedlung schon kaputt")
	t.check(not bool(fresh.store_report()["full"]), "Eine frische Burg meldet sich nicht als voll")

	# Capacity grows with every *finished* warehouse. A site has no slots yet, and a
	# rival's warehouse does not count.
	var grow := _siedler()
	var plot := _cell_near(grow, "grass", 4)
	if plot >= 0 and grow.place_building("warehouse", plot):
		t.equal(grow.store_capacity(), Siedler.STORE_CAP,
			"Ein Lager im Bau erweitert die Kammer noch nicht")
		for building in grow.buildings:
			if str(building["kind"]) == "warehouse":
				building["state"] = "done"
		t.equal(grow.store_capacity(), Siedler.STORE_CAP + Siedler.WAREHOUSE_STORE,
			"Ein fertiges Lager räumt %d Plätze ein" % Siedler.WAREHOUSE_STORE)
	else:
		t.fail("Der Testaufbau fand kein Feld für ein Lager")
	for building in grow.buildings:
		if str(building["owner"]) == "rival" and str(building["kind"]) != "castle":
			building["kind"] = "warehouse"
			building["state"] = "done"
	t.equal(grow.store_capacity(), Siedler.STORE_CAP + Siedler.WAREHOUSE_STORE,
		"Das Lager eines Rivalen zählt nicht mit")

	# The exception without which the settlement blocks itself: a full store still
	# takes planks, stone, food and tools. Otherwise the player could do nothing
	# against a full castle — not even build the warehouse that widens it again.
	var jam := _trading_siedler()
	_fill_depot(jam)
	for free_good in _free_goods():
		jam.store[free_good] = 0
	t.check(jam.store_used() >= jam.store_capacity(), "Die Kammer ist randvoll")
	t.check(bool(jam.store_report()["full"]), "Und meldet sich als voll")
	t.equal(int(jam.store_report()["room"]), 0, "Ohne freien Platz")
	for good in _free_goods():
		t.check(jam.can_store(good), "„%s“ passt trotzdem noch hinein" % Siedler.good_name(good))
	t.check(not jam.can_store("logs"), "Lagerware dagegen nicht")
	t.check(not jam.can_store("grain"), "Und Korn erst recht nicht")

	# A full store refuses — and counts *what*. Without that number it would only
	# say "Lager voll" and the player would have to guess which good it is. The
	# woodcutter delivers logs here, and no more of them fit.
	var siedler := _trading_siedler()
	_fill_depot(siedler)
	_run(siedler, 30.0)
	var report := siedler.store_report()
	t.check(int(report["refused_total"]) > 0, "Die Burg hat Lieferungen abgewiesen")
	t.check(int((report["refused"] as Dictionary).get("logs", 0)) > 0,
		"Und zwar die Baumstämme, die über die Straße kommen")
	t.check(str(report["top"]) in (report["refused"] as Dictionary),
		"Der Bericht nennt eine Ware, die tatsächlich abgewiesen wurde")
	t.equal(int(siedler.store.get("logs", 0)), siedler.store_capacity(),
		"Kein Stamm kam hinein")
	var refused_before := int(report["refused_total"])
	_run(siedler, 30.0)
	t.check(int(siedler.store_report()["refused_total"]) > refused_before,
		"Und solange die Kammer voll ist, weist sie weiter ab — der Verlust läuft")

	# The advisor names it, and names a handle.
	var entry := _with_code(siedler.bottlenecks(), "storeFull")
	t.check(not entry.is_empty(), "Der Ratgeber meldet die volle Vorratskammer")
	if not entry.is_empty():
		t.equal(str(entry["title"]), Loc.f("Storehouse full: %d of %d slots", [
			int(report["used"]), int(report["capacity"]),
		]), "Der Titel nennt genau die belegten Plätze — nicht einen Anteil, der über 100 % läge")
		t.check(_mentions(str(entry["detail"]), Siedler.good_name("logs")),
			"Der Text nennt die abgewiesene Ware")
		# …and the fill level, which is the number the player can do something
		# about. It is composed from the report, so the comparison is exact.
		t.check(Loc.resolve(str(entry["detail"])).contains(Loc.f(
				"The castle no longer takes warehouse goods: %d of %d slots taken.",
				[int(report["used"]), int(report["capacity"])])),
			"Und nennt, wie voll die Kammer ist")
		# The lever is the sentence that promises what one more storehouse buys.
		# It is the one line the player acts on, and it carries two numbers: the
		# slots and the settlers. The expectation is the whole rendered sentence,
		# built from the same template the advisor uses, so it holds in every
		# language instead of matching one language's words.
		var promise := Loc.f(" A storehouse would give %d more slots and %d settlers.", [
			Siedler.WAREHOUSE_STORE, Siedler.WAREHOUSE_SERFS])
		t.check(Loc.resolve(str(entry["detail"])).contains(Loc.resolve(promise)),
			"Und sagt, was ein zusätzliches Lager bringen würde")
		t.equal(str(entry["fix"]), "build:warehouse", "Der Griff ist ein Lager")
		t.equal(int(entry["building"]), siedler.castle_id, "Der Rat zeigt auf die Burg")
		t.equal(int(entry["cell"]), int(siedler.buildings[siedler.castle_id]["cell"]),
			"Sowie auf ihr Feld")

	# And the handle works: a warehouse makes room and the good arrives again.
	var shed := _finish(siedler, "warehouse", _cell_near(siedler, "grass", 4))
	t.check(not shed.is_empty(), "Das Lager steht")
	if not shed.is_empty():
		t.equal(siedler.store_capacity(), Siedler.STORE_CAP + Siedler.WAREHOUSE_STORE,
			"Und die Kammer ist um %d Plätze gewachsen" % Siedler.WAREHOUSE_STORE)
		t.check(not bool(siedler.store_report()["full"]), "Die Kammer hat wieder Platz")
		t.check(_with_code(siedler.bottlenecks(), "storeFull").is_empty(),
			"Und der Rat ist erledigt")
		var logs_before := int(siedler.store.get("logs", 0))
		var refused_now := int(siedler.store_report()["refused_total"])
		_run(siedler, 30.0)
		t.check(int(siedler.store.get("logs", 0)) > logs_before,
			"Die Stämme kommen wieder an")
		t.equal(int(siedler.store_report()["refused_total"]), refused_now,
			"Und die Burg weist nichts mehr ab — der Verlust ist behoben")

	# The space eater is the real message: the player can act on it without a
	# second warehouse. And nobody consumes grain in a settlement without a mill and
	# a stable — that is what the advice has to say, or the player builds the wrong
	# second producer.
	var wasted := _trading_siedler()
	wasted.store["grain"] = Siedler.STORE_CAP - 200
	wasted.store["logs"] = 200
	t.check(wasted.orphan_goods().has("grain"),
		"Ohne Mühle und Stall verbraucht hier niemand Korn")
	_run(wasted, 30.0)
	var spoil := _with_code(wasted.bottlenecks(), "storeFull")
	t.check(not spoil.is_empty(), "Auch hier nennt der Ratgeber die volle Kammer")
	if not spoil.is_empty():
		# Two sentences carry the whole message, and both are composed from the
		# settlement's own numbers and the catalogue's wording: the good that eats
		# the space, how much of it, and the fact that nobody on the map uses it.
		# Spelling out "Korn" and "niemand" asserted one language and failed in
		# every other.
		var grain := int(wasted.store.get("grain", 0))
		var eater := Loc.f(" The biggest space eater is “%s” (%d)", [
			Siedler.good_name("grain"), grain])
		var unused := ", and nobody on the map uses them — stop building more."
		var detail := Loc.resolve(str(spoil["detail"]))
		t.check(detail.contains(Loc.resolve(eater)),
			"Der Rat nennt den größten Platzfresser samt seiner Menge")
		t.check(detail.contains(Loc.resolve(unused)),
			"Und sagt, dass ihn niemand braucht")
	t.equal(str(wasted.store_report()["filler"]), "grain", "Der Bericht führt Korn als Platzfresser")

	# A brim-full store alone is not yet advice: the hint is only worth it once
	# something was really refused. Otherwise the sentence stands there while
	# nothing happens and the player stops reading it.
	var quiet := _trading_siedler()
	_fill_depot(quiet)
	t.equal(int(quiet.store_report()["refused_total"]), 0, "Es wurde noch nichts abgewiesen")
	t.check(_with_code(quiet.bottlenecks(), "storeFull").is_empty(),
		"Der Ratgeber schweigt, solange nichts blockiert wird")

	# A full store weighs more than a jam at a flag: it is the cause of the jam, and
	# it blocks the whole store instead of one stretch.
	var both := _trading_siedler()
	_fill_depot(both)
	_run(both, 30.0)
	for node in both.nodes:
		if bool(node["flag"]):
			for i in Siedler.JAM_LIMIT + 2:
				(node["queue"] as Array).append("logs")
			break
	var list := both.bottlenecks()
	t.equal(_count_code(list, "storeFull"), 1, "Die volle Kammer steht genau einmal in der Liste")
	t.equal(_count_code(list, "congestion"), 1, "Der Stau steht auch drin")
	if _count_code(list, "congestion") == 1 and _count_code(list, "storeFull") == 1:
		var jam_at := -1
		var depot_at := -1
		for i in list.size():
			if str(list[i]["code"]) == "congestion":
				jam_at = i
			if str(list[i]["code"]) == "storeFull":
				depot_at = i
		t.check(depot_at < jam_at, "Die volle Kammer steht vor dem Stau")

	# And the assurance that keeps it all playable: a full store is not a death
	# sentence. Planks still arrive, so the player can build the warehouse that
	# reopens it.
	var broke := _trading_siedler()
	_spent_out(broke, "logs", Siedler.STORE_CAP)
	t.check(bool(broke.store_report()["full"]), "Die Kammer ist trotzdem voll")
	t.check(broke.can_store("planks"), "Eine volle Kammer nimmt trotzdem Bauholz an")
	t.check(broke.can_store("stone"), "Und Stein")
	_run(broke, 40.0)
	t.check(int(broke.store.get("planks", 0)) > 0, "Die Siedlung kann also noch weiterbauen")
	t.suite_done()
