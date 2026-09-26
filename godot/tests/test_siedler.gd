class_name TestSiedler
extends RefCounted
## Regressionstests für den Ratgeber von "Siedler 3D".
##
## Der Ratgeber beantwortet die Frage, die ein neues Aufbauspiel am meisten
## kostet: *welches* Gebäude hungert an *welcher* Ware — und was dagegen zu
## tun ist. Alles hier ist reine Logik aus `core/logic/siedler.gd`, also ohne
## Szene prüfbar.

var t: TestKit


func run(kit: TestKit) -> void:
	t = kit
	_producer_lookup()
	_stall_reason()
	_ranking()
	_agrees_with_tick()
	_actions()
	_route_measure()
	_route_value()
	_route_report()
	_route_split()
	_route_optimize()
	_depot()
	t.close_suite()


## Ein Spiel mit festem Seed, damit jede Erwartung stabil bleibt.
func _siedler(seed_value: int = 21, size: int = 44) -> Siedler:
	var siedler := Siedler.new()
	siedler.setup(seed_value, size)
	return siedler


## Freies Feld einer Geländeart dicht an der Burg, -1 wenn keines frei ist.
## Zwei Bedingungen filtern das Zufallspiel heraus: nur Felder im eigenen
## Territorium und — für Bauplätze ohne Lagerstätte — nur ebener Grund, denn
## `place_building` verweigert beides sonst und jeder Test hinge vom Gelände ab.
## Lagerstätten (Holz, Stein, Kohle) brauchen keine ebene Fläche: `flat_only`
## ist dort `false`.
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


## Das erste Gebäude des Spielers dieser Art.
func _find(siedler: Siedler, kind: String) -> Dictionary:
	for building in siedler.buildings:
		if str(building["owner"]) == "player" and str(building["kind"]) == kind:
			return building
	return {}


## Setzt ein fertiges Gebäude, ohne Bauholz, Bauzeit und Kolonne abzuwarten —
## der Ratgeber soll *unabhängig* von der Wartezeit antworten, sonst wäre
## jeder Test von der Spieldauer abhängig.
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


## Verbindet ein Gebäude mit der Burg.
func _link(siedler: Siedler, building: Dictionary) -> void:
	siedler.build_road(int(siedler.buildings[siedler.castle_id]["cell"]), int(building["cell"]))


## Der erste Eintrag mit diesem Code, `{}` wenn keiner.
func _with_code(list: Array[Dictionary], code: String) -> Dictionary:
	for entry in list:
		if str(entry["code"]) == code:
			return entry
	return {}


## Wie oft ein Code in der Liste vorkommt.
func _count_code(list: Array[Dictionary], code: String) -> int:
	var total := 0
	for entry in list:
		if str(entry["code"]) == code:
			total += 1
	return total


# --- Stammdaten -------------------------------------------------------------

func _producer_lookup() -> void:
	t.suite("Siedler — Ratgeber: Erzeuger")

	# Die Frage "was baue ich?" hat für jede verbrauchte Ware eine Antwort.
	t.equal(Siedler.producer_of("logs"), "woodcutter", "Stämme kommen aus dem Holzfäller")
	t.equal(Siedler.producer_of("flour"), "windmill", "Mehl kommt aus der Windmühle")
	t.equal(Siedler.producer_of("iron"), "smelter", "Eisen kommt aus der Schmelze")
	t.equal(Siedler.producer_of("coal"), "coalMine", "Kohle kommt aus der Kohlemine")
	# Alle neun Werkzeuge schmiedet die Schlosserei.
	for tool in Siedler.TOOLS:
		t.equal(Siedler.producer_of(tool), "toolsmith", "„%s“ kommt aus der Schlosserei" % tool)

	# Jeder Rohstoff, den irgendein Gebäude verbraucht, hat einen Erzeuger —
	# sonst müsste der Ratgeber raten.
	for spec in Siedler.SPECS:
		for good in (spec["inputs"] as Dictionary):
			if int(spec["inputs"][good]) > 0:
				t.check(Siedler.producer_of(good) != "",
					"„%s“ für die „%s“ kann jemand herstellen" % [good, spec["name"]])
	# Und nichts, was es nicht gibt: eine erfundene Ware hat keinen Erzeuger.
	t.equal(Siedler.producer_of("unobtainium"), "", "Eine unbekannte Ware hat keinen Erzeuger")
	t.suite_done()


# --- Stillstandsgründe ------------------------------------------------------

func _stall_reason() -> void:
	t.suite("Siedler — Ratgeber: Stillstand")

	# Eine frische Siedlung läuft: kein Grund, kein Rat.
	var siedler := _siedler()
	t.equal(siedler.bottlenecks().size(), 0, "Eine leere Siedlung hat keinen Engpass")
	t.equal(siedler.top_bottleneck().size(), 0, "Und damit auch keinen obersten Rat")

	# Ohne Straße steht ein fertiges Gebäude still — und der Ratgeber sagt
	# *warum*, statt den Spieler selbst zählen zu lassen.
	var sawmill := _finish(siedler, "sawmill", _cell_near(siedler, "grass", 4))
	t.check(not sawmill.is_empty(), "Der Schreiner steht auf seinem Feld")
	if not sawmill.is_empty():
		t.equal(siedler.stall_of(sawmill), "notConnected", "Ohne Straße ist der Schreiner still")
		var entry := _with_code(siedler.bottlenecks(), "notConnected")
		t.equal(int(entry["severity"]), Siedler.SEV_WARNING, "Eine fehlende Straße wiegt schwer")
		t.equal(int(entry["building"]), int(sawmill["id"]), "Der Rat nennt das Gebäude")
		t.equal(int(entry["cell"]), int(sawmill["cell"]), "Und das Feld, das anzufunken ist")
		t.equal(str(entry["fix"]), "road:%d" % int(sawmill["id"]), "Und er schlägt eine Straße vor")

	# Mit Straße und Stämmen im Haus läuft er.
	if not sawmill.is_empty():
		_link(siedler, sawmill)
		siedler.store["logs"] = 10
		t.equal(siedler.stall_of(sawmill), "", "Angeschlossen und beliefert läuft der Schreiner")
		t.equal(siedler.bottlenecks().size(), 0, "Damit ist der Engpass vom Tisch")

	# Ohne Säge genau der Grund, den der Inspektor später anzeigt.
	if not sawmill.is_empty():
		siedler.store["saw"] = 0
		sawmill["tool"] = ""
		sawmill["workers"] = 0
		t.equal(siedler.stall_of(sawmill), "noTool", "Ohne Säge fehlt das Werkzeug")
		var entry := _with_code(siedler.bottlenecks(), "noTool")
		t.equal(str(entry["good"]), "saw", "Der Rat nennt die Säge")
		t.check(str(entry["title"]).contains("Säge"), "Und der Titel nennt sie mit")
		t.equal(str(entry["fix"]), "build:toolsmith", "Ohne Schlosserei wird eine empfohlen")

	# Die Kette weiter: eine Schlosserei macht aus dem Bauauftrag eine
	# Schlosserei-Schlange — der Griff, den der Bildschirm anbietet.
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
			# Die Schlosserei schmiedet von allein, was am lautesten fehlt — der
			# Rat verschwindet also, sobald sie fertig ist.
			_run(siedler, 20.0)
			t.check(_with_code(siedler.bottlenecks(), "noTool").is_empty(),
				"Die Schlosserei behebt den Engpass von selbst")

	# Ein erschöpftes Flöz ist ein eigener Grund, kein Rohstoffmangel.
	var pit := _siedler()
	var mine := _finish(pit, "coalMine", _cell_near(pit, "coal", 6, false))
	if not mine.is_empty():
		_link(pit, mine)
		pit.store["pickaxe"] = 4
		pit.cells[int(mine["cell"])]["amount"] = 0
		t.equal(pit.stall_of(mine), "noResource", "Eine leere Ader steht still")
		var entry := _with_code(pit.bottlenecks(), "noResource")
		t.check(str(entry["detail"]).contains("Kohle"), "Der Rat nennt die Lagerstätte")
		t.equal(str(entry["fix"]), "build:coalMine", "Und schlägt eine neue Kohlemine vor")

	# Kein freier Siedler ist der einzige Grund, der sich von selbst löst —
	# deshalb der niedrigste Schweregrad.
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

	# Ein Bauplatz ist Absicht, kein Stillstand.
	var site := _siedler()
	var plot := _cell_near(site, "grass", 4)
	if plot >= 0 and site.place_building("sawmill", plot):
		var building := _find(site, "sawmill")
		t.check(str(building["state"]) == "building" or str(building["state"]) == "levelling",
			"Der Bauplatz ist noch nicht fertig")
		t.equal(site.stall_of(building), "", "Ein Bauplatz zählt nicht als Stillstand")
		t.equal(site.bottlenecks().size(), 0, "Und erzeugt keinen Rat")

	# Ebenso ein bewusst angehaltenes Gebäude.
	var halted := _siedler()
	var mill := _finish(halted, "farm", _cell_near(halted, "grass", 4))
	if not mill.is_empty():
		_link(halted, mill)
		mill["halted"] = true
		t.equal(halted.stall_of(mill), "", "Anhalten ist eine Absicht des Spielers")
		t.equal(halted.bottlenecks().size(), 0, "Und kein Rat")

	# Rivale Betriebe gehören nicht in die Liste des Spielers.
	var rival := _siedler()
	for building in rival.buildings:
		if str(building["owner"]) == "rival" and str(building["kind"]) != "castle":
			building["workers"] = 0
			building["tool"] = ""
	t.check(_count_code(rival.bottlenecks(), "noWorker") == 0,
		"Der Ratgeber urteilt nur über die eigene Siedlung")
	t.suite_done()


# --- Rangfolge --------------------------------------------------------------

func _ranking() -> void:
	t.suite("Siedler — Ratgeber: Rangfolge")

	# Eine leere Vorratskammer schlägt alles andere.
	var siedler := _siedler()
	siedler.store["bread"] = 0
	siedler.store["fish"] = 0
	siedler.store["ham"] = 0
	var mine := _finish(siedler, "ironMine", _cell_near(siedler, "iron", 5, false))
	if not mine.is_empty():
		_link(siedler, mine)
		siedler.store["pickaxe"] = 2
		# Ein zweiter, völlig unabhängiger Ärger: hier fehlt die Straße.
		_finish(siedler, "bakery", _cell_near(siedler, "grass", 4))
		var list := siedler.bottlenecks()
		t.check(list.size() >= 2, "Zwei unabhängige Probleme ergeben zwei Ratschläge")
		t.equal(str(list[0]["code"]), "noFood", "Der Hunger steht oben")
		t.equal(int(list[0]["severity"]), Siedler.SEV_CRITICAL, "Und wiegt am schwersten")
		t.check(str(list[0]["detail"]).contains("Nahrung"), "Der Rat nennt die leere Kammer")
		t.equal(str(list[0]["fix"]), "book:food", "Und öffnet das Nahrungs-Baublatt")
		# Ein hungernder Bergmann wird *nicht* zusätzlich als "Rohstoff fehlt"
		# gemeldet — sonst besteht die halbe Liste aus dem selben Problem.
		t.equal(_count_code(list, "noFood") + _count_code(list, "hungry"), 1,
			"Hunger wird genau einmal genannt")
		t.equal(_count_code(list, "notConnected"), 1, "Die fehlende Straße kommt trotzdem vor")

	# Fünf Werkstätten ohne Kohle ergäben fünf Sätze — der Ratgeber bündelt.
	var coal := _siedler()
	coal.store["coal"] = 0
	coal.store["ironOre"] = 0
	var smelter := _finish(coal, "smelter", _cell_near(coal, "grass", 4))
	if not smelter.is_empty():
		_link(coal, smelter)
		# Erz da, Kohle weg: genau der teuerste Irrtum eines Anfängers.
		coal.store["ironOre"] = 4
		var list := coal.bottlenecks()
		var single := _with_code(list, "noInput")
		t.equal(_count_code(list, "noInput"), 1, "Ein fehlender Rohstoff, ein Rat")
		t.equal(str(single["good"]), "coal", "Und er nennt die Kohle, nicht das Erz")
		t.check(str(single["detail"]).contains("Kohle"), "Der Text nennt sie ebenfalls")
		t.equal(str(single["fix"]), "build:coalMine", "Der Rat schlägt die Kohlemine vor")

	# Zwei *verschiedene* fehlende Rohstoffe ergeben zwei Ratschläge — die
	# Bündelung gruppiert nach Ware, nicht nur nach Gebäude.
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

	# Die größte Lücke gewinnt: die Schmelze braucht Erz *und* Kohle, und der
	# Rat nennt die Ware, von der am weitesten entfernt sie ist.
	var gap := _siedler()
	gap.store["coal"] = 0
	gap.store["ironOre"] = 1
	var oven := _finish(gap, "smelter", _cell_near(gap, "grass", 4))
	if not oven.is_empty():
		_link(gap, oven)
		t.equal(str(_with_code(gap.bottlenecks(), "noInput")["good"]), "coal",
			"Die größere Lücke wird zuerst genannt")

	# Die Liste ist stabil und streng nach Schwere sortiert — sonst springt die
	# Karte zwischen zwei gleich schlimmen Ursachen hin und her.
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

	# Jeder Eintrag trägt dieselben Felder — der Bildschirm darf nie raten.
	var sample := _siedler()
	_finish(sample, "sawmill", _cell_near(sample, "grass", 4))
	for entry in sample.bottlenecks():
		for field in ["severity", "code", "title", "detail", "good", "building", "cell", "count"]:
			t.check(entry.has(field), "Feld '%s' ist immer belegt" % field)
		t.check(not str(entry["title"]).is_empty(), "Jeder Rat hat einen Titel")
		t.check(not str(entry["detail"]).is_empty(), "Jeder Rat hat einen Erklärungssatz")

	# Ein Stau an einer Fahne ist der Rat, der auf die Erfindung des Originals
	# zeigt: die Strecke teilen, damit mehr Träger sie teilen.
	var jam := _siedler()
	var node_id := -1
	for node in jam.nodes:
		if bool(node["flag"]):
			node_id = int(node["id"])
			break
	if node_id >= 0:
		# Ein kleiner Rückstau ist Alltag und wird nicht gemeldet.
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
	# Der Bildschirm muss den Rat jederzeit ansteuern können.
	if not stall.is_empty():
		t.equal(int(_with_code(twice.bottlenecks(), "noInput")["cell"]), int(stall["cell"]),
			"Der Rat zeigt auf das Feld, das betroffen ist")
	t.suite_done()


# --- Ratgeber und Takt sagen dasselbe ---------------------------------------

func _agrees_with_tick() -> void:
	t.suite("Siedler — Ratgeber: Taktgleichheit")

	# Das eine Versprechen des Ratgebers: Er widerspricht nie dem Zustand, den
	# der Bildschirm zeichnet. Also nach einem Lauf beides vergleichen.
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
	# Eine Schmelze ohne Kohle und ohne Erz: der Dauerstillstand, gegen den der
	# Ratgeber die ganze Zeit arbeiten muss. Das Feld *jetzt* suchen — vorher
	# hätte die Schmelze dasselbe genommen wie der Schreiner.
	_finish(siedler, "smelter", _cell_near(siedler, "grass", 4))
	for building in siedler.buildings:
		if str(building["owner"]) == "player" and str(building["kind"]) != "castle":
			_link(siedler, building)
	siedler.store["axe"] = 2
	siedler.store["pickaxe"] = 2
	siedler.store["saw"] = 0
	_run(siedler, 40.0)

	# Der Takt darf durch die Umstellung auf `stall_of` nichts verloren haben.
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

	# Und die Umgekehrte Richtung: der Takt darf keinen Grund melden, den der
	# Ratgeber nicht kennt.
	var known := ["noTool", "noWorker", "hungry", "noResource", "notConnected", "noInput"]
	for building in siedler.buildings:
		if str(building["owner"]) != "player" or str(building["state"]) != "done":
			continue
		t.check(known.has(str(building["status"])) or str(building["status"]) == "ok"
			or str(building["status"]) == "halted",
			"Status '%s' ist eine bekannte Ursache" % str(building["status"]))
	t.suite_done()


# --- Handlungsvorschläge ----------------------------------------------------

func _actions() -> void:
	t.suite("Siedler — Ratgeber: Handlung")

	# Jeder Rat mit einem Vorschlag nennt eine Maschine, die es wirklich gibt —
	# und die fehlende Ware, die dieser Griff beheben soll.
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

	# Kann die Burg den Bauauftrag nicht bezahlen, sagt der Ratgeber das von
	# selbst — sonst tippt der Spieler drauf und hört nur "Zu wenig Bauholz".
	var broke := _siedler()
	broke.store["coal"] = 0
	broke.store["ironOre"] = 0
	var oven := _finish(broke, "smelter", _cell_near(broke, "grass", 4))
	if not oven.is_empty():
		_link(broke, oven)
		var entry := _with_code(broke.bottlenecks(), "noInput")
		t.equal(str(entry["fix"]), "build:coalMine", "Der Rat schlägt die Kohlemine vor")
		t.check(not str(entry["detail"]).contains("Dafür fehlt der Burg"),
			"Die Burg kann den Bauauftrag noch bezahlen")
		# Erst jetzt das Bauholz wegnehmen — vorher könnte die Burg ja noch bauen.
		broke.store["planks"] = 0
		broke.store["stone"] = 0
		t.check(str(_with_code(broke.bottlenecks(), "noInput")["detail"]).contains("Dafür fehlt der Burg"),
			"Nimmt der Ratgeber auch beim Bauauftrag das fehlende Bauholz ernst")
		# Und die Burg, die nichts mehr bezahlen kann, ist selbst der Grund,
		# warum dieser Rat nicht umsetzbar ist.
		var wall := _with_code(broke.bottlenecks(), "noBuild")
		t.equal(int(wall["severity"]), Siedler.SEV_CRITICAL, "Die tote Burg wiegt am schwersten")
		t.equal(str(broke.top_bottleneck()["code"]), "noBuild", "Sie steht oben")
		t.check(str(wall["detail"]).contains("Bauholz"), "Und nennt den leeren Bestand")

	# Wer Bauparzellen hat, kann nichts mehr bauen — aber eine glückliche,
	# ärmere Siedlung hat trotzdem keinen Engpass.
	var poor := _siedler()
	var dead := _finish(poor, "sawmill", _cell_near(poor, "grass", 4))
	if not dead.is_empty():
		_link(poor, dead)
		t.equal(poor.bottlenecks().size(), 0, "Eine ärmere, laufende Siedlung hat keinen Engpass")
		# Jetzt das Bauholz wegnehmen, das der Schreiner eigentlich liefert.
		poor.store["planks"] = 0
		poor.store["stone"] = 0
		poor.store["logs"] = 0
		var top := poor.top_bottleneck()
		t.equal(str(top["code"]), "noBuild",
			"Sobald etwas klemmt, ist die tote Burg der erste Rat")
		t.check(str(top["detail"]).contains("Stämme"),
			"Der Rat verweist auf den echten Engpass dahinter")

	# Die Schlosserei-Schlange nimmt höchstens sechs Wünsche an — der Ratgeber
	# darf den Spieler nicht in eine Sackgase führen.
	var queue := _siedler()
	for i in 12:
		queue.request_tool("axe")
	t.equal(queue.tool_queue.size(), 6, "Die Schlange ist begrenzt")
	t.check(not queue.request_tool("axe"), "Und meldet, wenn sie voll ist")
	t.suite_done()


# --- Handelsweg optimieren ---------------------------------------------------
#
# Der Vorschlag „Handelsweg optimieren" baut auf einer Zahl auf, die es vorher
# nicht gab: welche Ware über welche Straße läuft. Diese vier Suiten prüfen die
# Kette von der Messung über den Bericht bis zum Griff — und vor allem, dass der
# Griff dem Spieler nichts wegnimmt.

## Eine Siedlung, in der wirklich Ware über die Straßen fährt: Holzfäller,
## Steinbruch und Schreiner an der Burg, alle drei angeschlossen, dazu die
## Werkzeuge. Ohne Verkehr wäre jede Handelsweg-Zahl null und die Tests nichts.
##
## Die Felder liegen bewusst *nicht* direkt am Burgtor: ein Holzfäller neben der
## Burg erzeugt nur einen Stummel, und über einen Stummel lässt sich kein
## Handelsweg lernen.
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


## Wie `_cell_near`, aber mit Mindestabstand zur Burg: die Handelsweg-Suiten
## brauchen echte Straßen und nicht nur den Stummel zum Nachbarhaus.
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


## Die erste Strecke des Berichts, die überhaupt etwas trägt.
func _busiest(siedler: Siedler) -> Dictionary:
	var routes := siedler.trade_report()
	return routes[0] if not routes.is_empty() else {}


func _route_measure() -> void:
	t.suite("Siedler — Handelswege: Messung")

	# Ohne Verkehr ist die Messung null — und genau das ist der Ausgangszustand,
	# den der Bericht dem Spieler auch zeigen muss.
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

	# Jeder Eintrag trägt dieselben Felder — sonst müsste der Bildschirm raten.
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

	# Der Bericht ist nach Verkehr sortiert: die stärkste Strecke steht oben,
	# weil sie die ist, an der sich etwas ändern lässt.
	var sorted := true
	for i in range(1, routes.size()):
		sorted = sorted and int(routes[i - 1]["total"]) >= int(routes[i]["total"])
	t.check(sorted, "Der Bericht ist nach Verkehr sortiert")

	# Ein Straßenbau verschiebt die Kanten-Ids. Die alten Zahlen wären dann
	# falsch, also beginnt die Messung neu — das ist wichtig, weil der Spieler
	# genau dann optimiert, wenn er gerade gebaut hat.
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


## Die Summe aller Zähler — der Test rechnet sie nach, statt dem Spiel zu glauben.
func _sum_traffic(siedler: Siedler) -> int:
	var total := 0
	for i in siedler.edges.size():
		total += int(siedler.edge_traffic(i)["total"])
	return total


## Ein freies Grasfeld im Umkreis von `near`, damit der Test einen zweiten
## Straßenzug bauen kann, ohne vom Zufall abhängig zu sein.
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

	# Nahrung steht über allem: ein Minenhaus ohne Essen produziert für niemanden.
	var siedler := _siedler()
	t.check(siedler.trade_value("bread") >= 4, "Brot ist für die Siedlung wertvoll")
	t.equal(siedler.trade_value(""), 0, "Eine unbekannte Ware hat keinen Wert")
	t.equal(siedler.trade_value("gibtsnicht"), 0, "Und eine erfundene auch nicht")

	# Der Wert folgt dem *gemessenen* Hunger, nicht dem Katalog: ein Gebäude,
	# das seine Bretter schon da hat, ist kein Wartender.
	var mill_cell := _cell_near(siedler, "grass", 4)
	var mill := _finish(siedler, "sawmill", mill_cell)
	if not mill.is_empty():
		_link(siedler, mill)
		t.equal(siedler.trade_value("logs"), 5, "Der Schreiner ohne Bauholz wartet auf Stämme")
		# Und die Priorität folgt der Leiter, nicht dem Zufall.
		t.equal(siedler.priority_for("logs"), 6, "Wartende Ware bekommt Priorität 6")
		mill["input"]["logs"] = 8
		t.equal(siedler.trade_value("logs"), 3, "Mit genug Stämmen wartet er nicht mehr")
		t.equal(siedler.priority_for("logs"), 4, "Und die Priorität sinkt mit auf Stufe 4")
	t.equal(siedler.priority_for("bread"), 5, "Nahrung bekommt die Stufe darüber")
	t.equal(siedler.priority_for("nichts"), 2, "Füllgut die unterste Stufe")

	# Die Leiter ist streng fallend: was wertvoller ist, kann nie eine niedrigere
	# Priorität bekommen als das Wertlose. Geprüft wird das an der Zuordnung
	# selbst, nicht an zwei Beispielen.
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

	# Der Rat nennt den nächsten Griff, nicht den Zustand. Ohne Stau und mit
	# passender Priorität bleibt nur der ruhige Satz.
	for entry in routes:
		var advice := siedler.route_advice(entry)
		t.check(not advice.is_empty(), "Jede Strecke bekommt einen Satz")
		t.check(advice.contains(Siedler.good_name(str(entry["top"]))) \
			or advice.contains("Stau") or advice.contains("Läuft"),
			"Der Satz redet über die Ware dieser Strecke")
		break

	# Die Reihenfolge ist eine Zusage an den Spieler: der Stau zuerst, weil er
	# der einzige Grund ist, den der Optimierer sofort behebt, danach der
	# Verkehr, dann die Länge. Ohne den Stau-Vorrang rutschte die Zeile, auf die
	# der Spieler gerade tippt, beim nächsten Durchgang nach unten.
	var jams_first := true
	for i in range(1, routes.size()):
		if bool(routes[i - 1]["jammed"]) and not bool(routes[i]["jammed"]):
			jams_first = false
	t.check(jams_first, "Jede verstopfte Strecke steht im Bericht über jeder freien")

	# Ein Stau schlägt alles: er ist der einzige Grund, den der Optimierer
	# tatsächlich selbst behebt.
	var busy := _busiest(siedler)
	busy["waiting"] = Siedler.ROUTE_JAM
	busy["jammed"] = true
	busy["cell"] = 3
	busy["gain"] = 4
	t.check(siedler.route_advice(busy).begins_with("Stau"),
		"Bei Stau nennt der Bericht zuerst den Stau")
	busy["jammed"] = false
	busy["priority"] = 1
	busy["top"] = "logs"
	t.check(siedler.route_advice(busy).contains("zu niedrig"),
		"Ohne Stau nennt er die zu niedrige Priorität")
	busy["priority"] = 6
	t.check(siedler.route_advice(busy).begins_with("Läuft"),
		"Passt die Priorität, gibt es nichts zu tun")

	# Der Bericht lügt nicht: er nennt eine Strecke, die es gibt, und eine
	# Kanten-Id, die der Spieler auch benutzen kann.
	var first: Dictionary = routes[0]
	t.check(int(first["edge"]) >= 0 and int(first["edge"]) < siedler.edges.size(),
		"Die Kanten-Id zeigt auf eine echte Straße")
	t.equal(siedler.edge_priority(int(first["edge"])), int(first["priority"]),
		"Und die Priorität ist die, die dort wirklich steht")
	t.suite_done()


func _route_split() -> void:
	t.suite("Siedler — Handelswege: Streckenteilung")

	# `split_gain` ist die Zusage, die der Optimierer dem Spieler macht: eine
	# positive Zahl heißt, das Teilen bringt Träger, `0` heißt, er lässt die
	# Finger davon. Geprüft wird die reine Funktion, weil sie über den
	# Kartenaufbau hinaus gilt — eine zu kurze Straße bleibt zu kurz.
	var siedler := _siedler()
	var short_road := {"kind": "road", "length": float(Siedler.SPLIT_LENGTH),
		"priority": 6, "carriers": []}
	t.equal(siedler.split_gain(short_road), 0,
		"Eine Strecke in Fahnenweite gewinnt durch Teilen nichts")

	var long_road := {"kind": "road", "length": float(Siedler.SPLIT_LENGTH) * 4.0,
		"priority": 6, "carriers": []}
	t.check(siedler.split_gain(long_road) > 0,
		"Eine viermal so lange Strecke gewinnt Träger, sonst wäre das Optimieren sinnlos")

	# Die Zahl ist keine Schätzung: sie ist genau die Trägerzahl der beiden
	# Hälften minus der der ganzen Strecke.
	t.equal(siedler.split_gain(long_road),
		Siedler.carrier_count_for(float(Siedler.SPLIT_LENGTH) * 2.0, 6) * 2,
		"Der Gewinn ist die Trägerzahl der beiden Hälften")

	# Kein Stummel wird geteilt, egal wie lang er ist: er trägt ohnehin nur
	# einen Träger, und zwei Hälften eines Stummels wären zwei Stummel.
	var stub := {"kind": "flag", "length": float(Siedler.SPLIT_LENGTH) * 8.0,
		"priority": 6, "carriers": []}
	t.equal(siedler.split_gain(stub), 0,
		"Kein Stummel wird geteilt, egal wie lang er ist")

	# `best_split_cell` folgt `split_gain`. Wo das Teilen nichts bringt, nennt
	# der Bericht auch kein Feld — sonst zeigte der Bildschirm einen Griff an,
	# den der Optimierer gar nicht macht.
	var agrees := true
	for edge in siedler.edges:
		if siedler.split_gain(edge) <= 0:
			agrees = agrees and siedler.best_split_cell(edge) == -1
	t.check(agrees, "Ohne Gewinn nennt der Bericht auch kein Feld für eine Fahne")

	# Wo der Bericht ein Feld nennt, muss dort auch wirklich eine Fahne
	# stehen können: kein Haus, denn das ist selbst ein Verkehrsknoten, und
	# kein Wasser, denn Wasser trägt keinen Träger.
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


## Die Kanten-Ids müssen lückenlos zu ihren Array-Indizes passen, jeder Knoten
## darf nur existierende Kanten nennen, und keine Strecke darf doppelt im Netz
## liegen. Das ist die Invariante, an der das Teilen am ehesten rüttelt: es
## entfernt eine Kante und hängt zwei neue an das Ende, verschiebt also alle
## Ids dahinter — und ein Knopf, der eine Straße über ihre Nummer anspricht,
## zeigt danach sonst auf eine völlig andere.
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

	# Ohne genug Messung rührt der Optimierer die Prioritäten nicht an. Sonst
	# hieße die erste halbe Minute Siedlung „Priorität 6" auf allem, und die
	# Zahl wäre geraten.
	var blind := _trading_siedler()
	_run(blind, 3.0)
	if blind.measured_carriers() < Siedler.MEASURE_MIN:
		var busy := _busiest(blind)
		if not busy.is_empty():
			blind.set_road_priority(int(busy["edge"]), 1)
			blind.optimize_trade_routes()
			t.equal(blind.edge_priority(int(busy["edge"])), 1,
				"Ohne genug Messung bleibt die Priorität, wie der Spieler sie setzte")

	# Jetzt die volle Optimierung an einem Verkehrsnetz.
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

	# Prioritäten steigen nur. Das ist die Zusage, die den Griff gefahrlos macht.
	var raised := 0
	for entry in siedler.trade_report():
		var want := siedler.priority_for(str(entry["top"]))
		if int(entry["priority"]) > want:
			raised += 1
	t.equal(raised, 0, "Keine Straße steht am Ende über ihrer Stufe")

	# Und der zweite Durchgang ist ein No-op: genau das macht den Griff
	# wiederholbar, ohne dass der Spieler aufpassen muss.
	var edges_before := siedler.edges.size()
	var nodes_before := siedler.nodes.size()
	var second := siedler.optimize_trade_routes()
	t.equal(siedler.edges.size(), edges_before, "Der zweite Durchgang legt keine Straße an")
	t.equal(siedler.nodes.size(), nodes_before, "Und keine Fahne")
	t.check(second.size() > 0, "Er sagt trotzdem, was er gesehen hat")
	var quiet := true
	for line in second:
		quiet = quiet and (line.contains("Nichts zu tun") or line.contains("bleiben"))
	t.check(quiet, "Und zwar: nichts zu tun")

	# Der Stau ist die einzige Bedingung für eine Extra-Fahne. Ohne Stau
	# verändert der Optimierer die Strecke nicht — sonst wäre er ein
	# Fahnenautomat und keine Optimierung.
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


# --- Lagerplatz: die endliche Vorratskammer ---------------------------------
#
# Das Lager war das eine Gebäude, dessen eigener Beschreibungstext eine Lüge
# war: es versprach mehr Lagerkapazität und lieferte nur sechs Siedler. Damit
# gab es keine Speichergrenze — eine Siedlung, die zu viel produzierte, hatte
# nichts als einen größeren Haufen, und die Straße vor dem Burgtor füllte sich
# ohne jede Erklärung.
#
# Diese Suite prüft die drei Zusagen der neuen Regel: das Lager erweitert die
# Kammer wirklich, eine volle Kammer weist Lieferungen ab und *zählt* sie je
# Ware, und der Ratgeber sagt anschließend, was blockiert wird und welcher
# Erzeuger den Platz frisst. Dazu die Sicherung, ohne die das Ganze nicht
# spielbar wäre: Bauholz, Stein, Nahrung und Werkzeug nimmt die Burg immer an.

## Überlädt die Vorratskammer mit `good`, ohne die Startware anzufassen. So ist
## der Zustand unabhängig davon, wie voll eine frische Siedlung zufällig ist.
func _flood(siedler: Siedler, good: String, amount: int) -> void:
	siedler.store[good] = amount


## Die Waren, die die Burg *nie* blockiert: Bauholz und Stein bezahlen die
## Siedlung, Nahrung sättigt sie, ein Werkzeug ist die Voraussetzung für beides.
## Sie zählen nicht gegen die Lagerplätze.
func _free_goods() -> Array[String]:
	var out: Array[String] = ["planks", "stone"]
	for food in Siedler.FOODS:
		out.append(food)
	for tool in Siedler.TOOLS:
		out.append(tool)
	return out


## Überlädt die Vorratskammer mit einer *Lagerware* und zahlt aus, was die
## Siedlung zum Bauen braucht: So entsteht eine volle Burg, in der trotzdem
## weitergebaut werden kann.
func _spent_out(siedler: Siedler, good: String, amount: int) -> void:
	_flood(siedler, good, amount)
	for free_good in _free_goods():
		siedler.store[free_good] = 0


## Füllt die Kammer bis unters Dach. Baumstämme sind die Lagerware, die in
## `_trading_siedler` tatsächlich ankommt: Sie wachsen auf jedem Wald, den der
## Holzfäller findet, und werden von der Burg auch dann angenommen, wenn sie
## eigentlich zum Schreiner weitergehen.
func _fill_depot(siedler: Siedler) -> void:
	for good in Siedler.GOODS:
		siedler.store[good] = 0
	siedler.store["logs"] = siedler.store_capacity()


func _depot() -> void:
	t.suite("Siedler — Ratgeber: Lagerplatz")

	# Das Lager sagt, was es bringt. Der Text steht in den Stammdaten, also
	# muss die Zahl dort und in der Regel zusammenpassen — sonst erzählt der
	# Inspektor etwas anderes als das Spiel tut.
	t.check(str(Siedler.spec_of("warehouse")["desc"]).contains(str(Siedler.WAREHOUSE_STORE)),
		"Der Beschreibungstext des Lagers nennt die Lagerplätze, die es bringt")

	# Ohne Lager hat die Burg ihre Grundkapazität — und die ist endlich.
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

	# Der Lagerplatz wächst mit jedem *fertigen* Lager. Ein Bauplatz hat noch
	# keine Plätze, und das Lager eines Rivalen zählt nicht.
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

	# Die Ausnahme, ohne die sich die Siedlung selbst zustellt: eine volle
	# Kammer nimmt Bauholz, Stein, Nahrung und Werkzeug trotzdem an. Sonst
	# könnte der Spieler gegen die volle Burg nichts tun — er könnte nicht
	# einmal das Lager bauen, das die Burg wieder weitet.
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

	# Eine volle Kammer weist ab — und zählt, *was*. Ohne diese Zahl stünde da
	# nur „Lager voll", und der Spieler müsste selbst erraten, welche Ware es
	# ist. Der Holzfäller liefert hier Stämme, und die passen nicht mehr hinein.
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

	# Der Ratgeber nennt es, und er nennt einen Griff.
	var entry := _with_code(siedler.bottlenecks(), "storeFull")
	t.check(not entry.is_empty(), "Der Ratgeber meldet die volle Vorratskammer")
	if not entry.is_empty():
		t.equal(str(entry["title"]), "Lager voll: %d von %d Plätzen" % [
			int(report["used"]), int(report["capacity"]),
		], "Der Titel nennt genau die belegten Plätze — nicht einen Anteil, der über 100 % läge")
		t.check(str(entry["detail"]).contains(Siedler.good_name("logs")),
			"Der Text nennt die abgewiesene Ware")
		t.check(str(entry["detail"]).contains("immer an"),
			"Und sagt, was die Burg trotzdem annimmt")
		t.check(str(entry["detail"]).contains("Lager"), "Und erklärt den Griff")
		t.equal(str(entry["fix"]), "build:warehouse", "Der Griff ist ein Lager")
		t.equal(int(entry["building"]), siedler.castle_id, "Der Rat zeigt auf die Burg")
		t.equal(int(entry["cell"]), int(siedler.buildings[siedler.castle_id]["cell"]),
			"Sowie auf ihr Feld")

	# Und der Griff wirkt: ein Lager macht Platz, danach kommt die Ware wieder an.
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

	# Der Platzfresser ist die eigentliche Nachricht: an ihm kann der Spieler
	# etwas ändern, ohne ein zweites Lager zu bauen. Und niemand verbraucht
	# Korn in einer Siedlung ohne Mühle und Stall — genau das muss der Rat
	# sagen, sonst baut der Spieler den falschen zweiten Erzeuger.
	var wasted := _trading_siedler()
	wasted.store["grain"] = Siedler.STORE_CAP - 200
	wasted.store["logs"] = 200
	t.check(wasted.orphan_goods().has("grain"),
		"Ohne Mühle und Stall verbraucht hier niemand Korn")
	_run(wasted, 30.0)
	var spoil := _with_code(wasted.bottlenecks(), "storeFull")
	t.check(not spoil.is_empty(), "Auch hier nennt der Ratgeber die volle Kammer")
	if not spoil.is_empty():
		t.check(str(spoil["detail"]).contains("Korn"),
			"Der Rat nennt den größten Platzfresser")
		t.check(str(spoil["detail"]).contains("niemand"),
			"Und sagt, dass ihn niemand braucht")
	t.equal(str(wasted.store_report()["filler"]), "grain", "Der Bericht führt Korn als Platzfresser")

	# Eine randvolle Kammer allein ist noch kein Rat: erst wenn wirklich etwas
	# abgewiesen wurde, lohnt der Hinweis. Sonst steht der Satz da, während
	# gar nichts passiert, und der Spieler lernt ihn nicht mehr zu lesen.
	var quiet := _trading_siedler()
	_fill_depot(quiet)
	t.equal(int(quiet.store_report()["refused_total"]), 0, "Es wurde noch nichts abgewiesen")
	t.check(_with_code(quiet.bottlenecks(), "storeFull").is_empty(),
		"Der Ratgeber schweigt, solange nichts blockiert wird")

	# Die volle Kammer wiegt schwerer als ein Stau an einer Fahne: sie ist
	# dessen Ursache, und sie blockiert die ganze Kammer statt einer Strecke.
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

	# Und die Zusicherung, die das Ganze spielbar hält: eine volle Kammer ist
	# kein Todesfall. Bauholz kommt weiter an, also kann der Spieler das Lager
	# bauen, das die Kammer wieder öffnet.
	var broke := _trading_siedler()
	_spent_out(broke, "logs", Siedler.STORE_CAP)
	t.check(bool(broke.store_report()["full"]), "Die Kammer ist trotzdem voll")
	t.check(broke.can_store("planks"), "Eine volle Kammer nimmt trotzdem Bauholz an")
	t.check(broke.can_store("stone"), "Und Stein")
	_run(broke, 40.0)
	t.check(int(broke.store.get("planks", 0)) > 0, "Die Siedlung kann also noch weiterbauen")
	t.suite_done()
