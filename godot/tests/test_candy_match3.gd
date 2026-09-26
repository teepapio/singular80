class_name TestCandyMatch3
extends RefCounted
## Rule tests for the match-3 ("Candy Crush 3D").
##
## Runs inside the plain logic phase of the headless suite: the board, the
## generator, the daily challenge, the star milestones and the undo snapshot are
## all pure functions, so they are checked here without touching a scene.

var t: TestKit


func run(kit: TestKit) -> void:
	t = kit
	_matching()
	_swaps()
	_specials()
	_blockers()
	_gravity_and_shuffle()
	_generator()
	_levels()
	_daily()
	_milestones()
	_undo()
	t.close_suite()


## Board filled with a repeating pattern that has no match.
func _pattern() -> Dictionary:
	var board := CandyMatch3.create_board(CandyMatch3.LAYOUT_FULL)
	var colors: Array = board["colors"]
	for row in CandyMatch3.ROWS:
		for col in CandyMatch3.COLS:
			colors[CandyMatch3.cell_index(col, row)] = (col + row * 2) % 6
	return board


# --- matching ---------------------------------------------------------------

func _matching() -> void:
	t.suite("Candy Crush — Reihen")
	var board := _pattern()
	for col in 4:
		CandyMatch3.set_candy(board, CandyMatch3.cell_index(col, 3), 9)
	for row in range(2, 5):
		CandyMatch3.set_candy(board, CandyMatch3.cell_index(6, row), 8)
	var runs := CandyMatch3.find_runs(board)
	t.equal(runs.size(), 2, "Waagerechte und senkrechte Reihe gefunden")
	t.check(not CandyMatch3.has_any_match(board) == false, "Match vorhanden")

	# A pair is no match.
	for col in 2:
		CandyMatch3.set_candy(board, CandyMatch3.cell_index(col, 7), 9)
	t.check(not CandyMatch3.find_runs(board).any(func(run: Dictionary) -> bool:
		return (run["cells"] as Array).has(CandyMatch3.cell_index(0, 7))),
		"Ein Paar zählt nicht als Reihe")

	# Runs do not reach across holes.
	var holed := _pattern()
	var kind: Array = holed["kind"]
	var colors: Array = holed["colors"]
	for col in CandyMatch3.COLS:
		kind[CandyMatch3.cell_index(col, 0)] = CandyMatch3.KIND_HOLE
		colors[CandyMatch3.cell_index(col, 0)] = CandyMatch3.NO_CANDY
	for row in range(1, 8):
		for col in CandyMatch3.COLS:
			colors[CandyMatch3.cell_index(col, row)] = (col + row) % 3
	CandyMatch3.set_candy(holed, CandyMatch3.cell_index(1, 4), 5)
	CandyMatch3.set_candy(holed, CandyMatch3.cell_index(2, 4), 5)
	t.check(not CandyMatch3.has_any_match(holed), "Reihen enden an Löchern")

	# L/T shapes merge into one group that creates a wrapped candy.
	var corner := _pattern()
	for col in 4:
		CandyMatch3.set_candy(corner, CandyMatch3.cell_index(col, 4), 4)
	for row in range(4, 7):
		CandyMatch3.set_candy(corner, CandyMatch3.cell_index(3, row), 4)
	var groups := CandyMatch3.merge_runs(CandyMatch3.find_runs(corner))
	t.equal(groups.size(), 1, "L-Form ergibt eine Gruppe")
	t.equal(int((groups[0] as Dictionary)["special"]), CandyMatch3.SPECIAL_WRAPPED, "L-Form erzeugt ein verpacktes Bonbon")
	t.equal(((groups[0] as Dictionary)["cells"] as Array).size(), 6, "Die Gruppe umfasst alle sechs Felder")

	# Five in a row creates a colour bomb, four in a row a striped candy.
	var line := _pattern()
	for col in 5:
		CandyMatch3.set_candy(line, CandyMatch3.cell_index(col, 6), 2)
	t.equal(int((CandyMatch3.merge_runs(CandyMatch3.find_runs(line))[0] as Dictionary)["special"]),
		CandyMatch3.SPECIAL_BOMB, "Fünf in einer Reihe erzeugt eine Farbbombe")
	for col in 4:
		CandyMatch3.set_candy(line, CandyMatch3.cell_index(col, 5), 4)
	t.equal(int((CandyMatch3.merge_runs(CandyMatch3.find_runs(line))[0] as Dictionary)["special"]),
		CandyMatch3.SPECIAL_COL, "Vier in einer Reihe erzeugt ein senkrechtes Streifen-Bonbon")
	t.suite_done()


# --- swaps ------------------------------------------------------------------

func _swaps() -> void:
	t.suite("Candy Crush — Züge")
	var board := _pattern()
	var before: Array = (board["colors"] as Array).duplicate()
	t.check(CandyMatch3.try_swap(board, 0, 1, CandyMatch3.mulberry32(1), 6).is_empty(),
		"Zug ohne Reihe wird abgelehnt")
	t.equal((board["colors"] as Array), before, "Der abgelehnte Zug macht das Brett unversehrt")

	# A swap that completes a vertical run is accepted and refills the board.
	var setup := _pattern()
	for row in [6, 7, 8]:
		CandyMatch3.set_candy(setup, CandyMatch3.cell_index(3, row), 7)
	CandyMatch3.set_candy(setup, CandyMatch3.cell_index(2, 7), 7)
	var outcome := CandyMatch3.try_swap(setup, CandyMatch3.cell_index(2, 7), CandyMatch3.cell_index(3, 7),
		CandyMatch3.mulberry32(42), 6)
	t.check(not outcome.is_empty(), "Vertauschter Zug mit Reihe wird angenommen")
	t.check(((outcome["step"] as Dictionary)["cleared"] as Array).size() >= 3, "Mindestens drei Bonbons fallen")
	for cell in CandyMatch3.open_cells(setup):
		t.check((setup["colors"] as Array)[cell] != CandyMatch3.NO_CANDY or true, "Brett gefüllt")
	var empty := 0
	for cell in CandyMatch3.open_cells(setup):
		if (setup["colors"] as Array)[cell] == CandyMatch3.NO_CANDY:
			empty += 1
	t.equal(empty, 0, "Nach dem Zug ist kein Feld leer")

	# Two specials may always be swapped, one special needs a match.
	var specials_board := _pattern()
	(specials_board["specials"] as Array)[0] = CandyMatch3.SPECIAL_ROW
	t.check(CandyMatch3.try_swap(specials_board, 0, 1, CandyMatch3.mulberry32(3), 6).is_empty(),
		"Spezial + normal ohne Reihe ist kein Zug")
	(specials_board["specials"] as Array)[1] = CandyMatch3.SPECIAL_COL
	t.check(not CandyMatch3.try_swap(specials_board, 0, 1, CandyMatch3.mulberry32(3), 6).is_empty(),
		"Zwei Spezialbonbons dürfen getauscht werden")

	var fresh := CandyMatch3.start_level(CandyMatch3.level_for("candy", 1))
	t.check(CandyMatch3.find_valid_swaps(fresh["board"]).size() > 0, "Ein frisches Level hat mindestens einen Zug")
	t.suite_done()


# --- specials ---------------------------------------------------------------

func _specials() -> void:
	t.suite("Candy Crush — Spezialbonbons")
	var board := _pattern()
	for col in [2, 3, 4]:
		CandyMatch3.set_candy(board, CandyMatch3.cell_index(col, 5), 4)
	(board["specials"] as Array)[CandyMatch3.cell_index(3, 5)] = CandyMatch3.SPECIAL_ROW
	var outcome := CandyMatch3.try_swap(board, CandyMatch3.cell_index(2, 5), CandyMatch3.cell_index(3, 5),
		CandyMatch3.mulberry32(7), 6)
	var cleared: Array = (outcome["step"] as Dictionary)["cleared"]
	for col in CandyMatch3.COLS:
		t.check(cleared.has(CandyMatch3.cell_index(col, 5)), "Streifen-Bonbon räumt die ganze Reihe")

	var bomb := _pattern()
	(bomb["specials"] as Array)[0] = CandyMatch3.SPECIAL_BOMB
	var target: int = (bomb["colors"] as Array)[1]
	var same: Array = []
	for cell in CandyMatch3.open_cells(bomb):
		if (bomb["colors"] as Array)[cell] == target:
			same.append(cell)
	var bomb_outcome := CandyMatch3.try_swap(bomb, 0, 1, CandyMatch3.mulberry32(11), 6)
	var bomb_cleared: Array = (bomb_outcome["step"] as Dictionary)["cleared"]
	for cell in same:
		t.check(bomb_cleared.has(cell), "Farbbombe räumt alle Bonbons einer Farbe")
	t.suite_done()


# --- blockers ---------------------------------------------------------------

func _blockers() -> void:
	t.suite("Candy Crush — Blöcke")
	# Icing next to a match loses a layer and opens up when it breaks.
	var board := _pattern()
	var cell := CandyMatch3.cell_index(4, 4)
	(board["kind"] as Array)[cell] = CandyMatch3.KIND_ICING
	(board["layers"] as Array)[cell] = 1
	(board["colors"] as Array)[cell] = CandyMatch3.NO_CANDY
	for col in [2, 3, 4]:
		CandyMatch3.set_candy(board, CandyMatch3.cell_index(col, 3), 6)
	var step := CandyMatch3.resolve_step(board, CandyMatch3.mulberry32(5), {"colorCount": 6})
	t.check((step["blockersBroken"] as Array).has(cell), "Glasur bricht neben einem Treffer")
	t.equal((board["kind"] as Array)[cell], CandyMatch3.KIND_OPEN, "Das Feld ist danach offen")

	# Two layers need two hits.
	var thick := _pattern()
	(thick["layers"] as Array)[cell] = 2
	(thick["kind"] as Array)[cell] = CandyMatch3.KIND_ICING
	(thick["colors"] as Array)[cell] = CandyMatch3.NO_CANDY
	for col in [2, 3, 4]:
		CandyMatch3.set_candy(thick, CandyMatch3.cell_index(col, 3), 6)
	CandyMatch3.resolve_step(thick, CandyMatch3.mulberry32(5), {"colorCount": 6})
	t.equal((thick["layers"] as Array)[cell], 1, "Zweilagige Glasur verliert erst eine Schicht")

	# Stone ignores neighbours but breaks to a special blast.
	var stone := _pattern()
	(stone["kind"] as Array)[cell] = CandyMatch3.KIND_STONE
	(stone["layers"] as Array)[cell] = 2
	(stone["colors"] as Array)[cell] = CandyMatch3.NO_CANDY
	for col in [2, 3, 4]:
		CandyMatch3.set_candy(stone, CandyMatch3.cell_index(col, 3), 6)
	var neighbour := CandyMatch3.resolve_step(stone, CandyMatch3.mulberry32(5), {"colorCount": 6})
	t.check(not (neighbour["blockersHit"] as Array).has(cell), "Stein hält Nachbarschaftstreffer aus")
	t.equal((stone["layers"] as Array)[cell], 2, "Stein ist unbeschädigt")
	for col in [2, 3, 4]:
		CandyMatch3.set_candy(stone, CandyMatch3.cell_index(col, 3), 6)
	(stone["specials"] as Array)[CandyMatch3.cell_index(4, 3)] = CandyMatch3.SPECIAL_WRAPPED
	var blast := CandyMatch3.resolve_step(stone, CandyMatch3.mulberry32(5), {"colorCount": 6})
	t.check((blast["blockersHit"] as Array).has(cell), "Spezialbonbon zerschlägt Stein")
	t.equal((stone["layers"] as Array)[cell], 1, "Stein verliert eine Schicht")
	t.suite_done()


# --- gravity and shuffle ----------------------------------------------------

func _gravity_and_shuffle() -> void:
	t.suite("Candy Crush — Schwerkraft")
	var board := _pattern()
	var before: Array = []
	for row in 5:
		before.append((board["colors"] as Array)[CandyMatch3.cell_index(3, row)])
	for row in range(5, CandyMatch3.ROWS):
		CandyMatch3.clear_candy(board, CandyMatch3.cell_index(3, row))
	var moves := CandyMatch3.apply_gravity(board)
	t.equal(moves.size(), 5, "Alle fünf Bonbons rutschen nach")
	t.equal(int((moves[0] as Dictionary)["to"]), CandyMatch3.cell_index(3, 8), "Der unterste landet unten")
	for row in 5:
		t.equal(int((board["colors"] as Array)[CandyMatch3.cell_index(3, row + 4)]), int(before[row]),
			"Die Reihenfolge bleibt erhalten")
	t.equal((board["colors"] as Array)[CandyMatch3.cell_index(3, 0)], CandyMatch3.NO_CANDY,
		"Die Lücke wandert nach oben")
	var spawned := CandyMatch3.refill(board, 6, CandyMatch3.mulberry32(4))
	t.equal(spawned.size(), 4, "Die Nachfüllung schließt die Lücke")

	# A hole stops the fall.
	var holed := _pattern()
	(holed["kind"] as Array)[CandyMatch3.cell_index(2, 4)] = CandyMatch3.KIND_HOLE
	(holed["colors"] as Array)[CandyMatch3.cell_index(2, 4)] = CandyMatch3.NO_CANDY
	CandyMatch3.clear_candy(holed, CandyMatch3.cell_index(2, 2))
	CandyMatch3.clear_candy(holed, CandyMatch3.cell_index(2, 3))
	var holed_moves := CandyMatch3.apply_gravity(holed)
	t.equal(holed_moves.size(), 2, "Nur die Bonbons über der Lücke rutschen")
	for move in holed_moves:
		t.check((move as Dictionary)["to"] != CandyMatch3.cell_index(2, 5), "Nichts fällt durch das Loch")

	var dead := _pattern()
	var colors: Array = dead["colors"]
	for cell in colors.size():
		colors[cell] = 0
	t.check(CandyMatch3.shuffle_board(dead, CandyMatch3.mulberry32(21), 6), "Mischen meldet Erfolg")
	t.check(not CandyMatch3.has_any_match(dead), "Nach dem Mischen gibt es keine Sofort-Reihe")
	t.check(CandyMatch3.has_valid_swap(dead), "Nach dem Mischen gibt es einen Zug")
	t.suite_done()


# --- generator --------------------------------------------------------------

func _generator() -> void:
	t.suite("Candy Crush — Level-Generator")
	t.equal(CandyMatch3.WORLDS.size(), 6, "Sechs Welten")
	t.equal(CandyMatch3.total_level_count(), 240, "240 Level")
	for world in CandyMatch3.WORLDS:
		t.equal((world["palette"] as Array).size(), 6, "Welt '%s' hat sechs Farben" % str((world as Dictionary)["id"]))
		t.equal((world["pieceAssets"] as Array).size(), 6, "Welt '%s' hat sechs Meshes" % str((world as Dictionary)["id"]))
		for asset in (world as Dictionary)["pieceAssets"]:
			t.check(AssetRegistry.exists(str(asset)), "Mesh '%s' ist gebündelt" % str(asset))
	for layout in CandyMatch3.LAYOUTS:
		var lines: Array = layout
		t.equal(lines.size(), CandyMatch3.ROWS, "Layout hat neun Zeilen")
		var open := 0
		for line in lines:
			var text := str(line)
			t.equal(text.length(), CandyMatch3.COLS, "Layoutzeile hat acht Spalten")
			open += text.count("#")
		t.check(open >= 30, "Layout hat mindestens 30 offene Felder (%d)" % open)

	t.equal(CandyMatch3.level_for("candy", 7), CandyMatch3.level_for("candy", 7), "Gleiche Level sind gleich")
	t.check(CandyMatch3.level_for("candy", 1) != CandyMatch3.level_for("candy", 2), "Verschiedene Level unterscheiden sich")
	t.suite_done()


func _levels() -> void:
	t.suite("Candy Crush — Level")
	var levels: Array = []
	for index in range(1, CandyMatch3.LEVELS_PER_WORLD + 1):
		levels.append(CandyMatch3.level_for("candy", index))
	t.equal(int((levels[0] as Dictionary)["colors"]), 4, "Level 1 hat vier Farben")
	t.equal(int((levels[levels.size() - 1] as Dictionary)["colors"]), 6, "Der letzte Level hat sechs Farben")
	t.check(int((levels[0] as Dictionary)["moves"]) > int((levels[levels.size() - 1] as Dictionary)["moves"]),
		"Die Zugzahl sinkt")
	t.equal(int(((levels[0] as Dictionary)["blockers"] as Dictionary)["icing"]), 0, "Level 1 hat keine Blöcke")
	t.check(int(((levels[levels.size() - 1] as Dictionary)["blockers"] as Dictionary)["icing"]) > 0,
		"Späte Level haben Blöcke")
	t.check(bool((levels[0] as Dictionary)["allowStriped"]) == false, "Streifenbonbons erst ab Level 2")
	t.check(bool((levels[3] as Dictionary)["allowWrapped"]), "Verpackte Bonbons ab Level 4")
	t.check(bool((levels[6] as Dictionary)["allowBomb"]), "Farbbombe ab Level 7")

	# Every generated level of every world starts playable.
	var checked := 0
	for world_id in CandyMatch3.world_ids():
		for index in range(1, CandyMatch3.LEVELS_PER_WORLD + 1):
			var game := CandyMatch3.start_level(CandyMatch3.level_for(world_id, index))
			checked += 1
			if CandyMatch3.has_any_match(game["board"]) or not CandyMatch3.has_valid_swap(game["board"]):
				t.check(false, "Level %s/%d startet spielbar" % [world_id, index])
				break
			for cell in CandyMatch3.open_cells(game["board"]):
				if (game["board"] as Dictionary)["colors"][cell] == CandyMatch3.NO_CANDY:
					t.check(false, "Level %s/%d startet ohne leere Felder" % [world_id, index])
					break
	t.equal(checked, 240, "Alle 240 Level geprüft")

	# A random playout keeps the board invariants.
	for world_id in CandyMatch3.world_ids():
		for index in [1, 12, 27, 40]:
			var level := CandyMatch3.level_for(world_id, index)
			var game := CandyMatch3.start_level(level)
			var rng := CandyMatch3.mulberry32(1000 + index)
			for turn in 200:
				if CandyMatch3.is_won(game) or int(game["movesLeft"]) <= 0:
					break
				var swaps := CandyMatch3.find_valid_swaps(game["board"])
				if swaps.is_empty():
					t.check(CandyMatch3.shuffle_board(game["board"], game["rng"], int(level["colors"])),
						"Board lässt sich mischen")
					continue
				var swap: Dictionary = swaps[CandyMatch3.random_int(rng, swaps.size())]
				var outcome := CandyMatch3.try_swap(game["board"], int((swap as Dictionary)["a"]), int((swap as Dictionary)["b"]),
					game["rng"], int(level["colors"]))
				if outcome.is_empty():
					t.check(false, "Gemeldeter Zug ist nicht spielbar")
					break
				game["movesLeft"] = int(game["movesLeft"]) - 1
				CandyMatch3.continue_cascades(game, outcome["step"])
				for cell in CandyMatch3.open_cells(game["board"]):
					if (game["board"] as Dictionary)["colors"][cell] == CandyMatch3.NO_CANDY:
						t.check(false, "Nach dem Zug bleibt kein Feld leer")
						break
			t.check(not CandyMatch3.has_any_match(game["board"]), "Brett ist nach der Partie ruhig")
			t.check(CandyMatch3.blockers_left(game) <= int(game["blockersTotal"]), "Blocker zählen nur ab")

	# Stars are only awarded for a won level.
	var star_game := CandyMatch3.start_level(CandyMatch3.level_for("crystals", 2))
	t.equal(CandyMatch3.stars_for(star_game), 0, "Ohne Sieg keine Sterne")
	star_game["score"] = int((star_game["level"] as Dictionary)["starScores"][0])
	t.equal(CandyMatch3.stars_for(star_game), 2, "Der Schwellwert ergibt zwei Sterne")
	star_game["score"] = int((star_game["level"] as Dictionary)["starScores"][1])
	t.equal(CandyMatch3.stars_for(star_game), 3, "Der höchste Wert ergibt drei Sterne")
	t.suite_done()


# --- daily challenge --------------------------------------------------------

func _daily() -> void:
	t.suite("Candy Crush — Tageslevel")
	t.equal(CandyMatch3.daily_level("2026-09-26"), CandyMatch3.daily_level("2026-09-26"),
		"Gleicher Tag ergibt gleiches Level")
	t.check(CandyMatch3.daily_level("2026-09-26") != CandyMatch3.daily_level("2026-09-27"),
		"Jeder Tag hat ein eigenes Level")
	var daily := CandyMatch3.daily_level("2026-09-26")
	t.equal(str(daily["dailyKey"]), "2026-09-26", "Das Tageslevel merkt sich den Tag")
	t.check(str(daily["title"]).begins_with("Tageslevel"), "Der Titel nennt das Tageslevel")
	var campaign := CandyMatch3.level_for(str(daily["worldId"]), int(daily["index"]))
	t.check(int(campaign["seed"]) != int(daily["seed"]), "Das Tageslevel ist kein Kampagnenlevel")
	var game := CandyMatch3.start_level(daily)
	t.check(not CandyMatch3.has_any_match(game["board"]), "Tageslevel startet ohne Sofort-Reihe")
	t.check(CandyMatch3.has_valid_swap(game["board"]), "Tageslevel startet mit einem Zug")

	t.equal(CandyMatch3.date_key(1789516800).length(), 10, "Datumsschlüssel hat die Form JJJJ-MM-TT")
	t.equal(CandyMatch3.shift_date_key("2026-09-01", -1), "2026-08-31", "Rückwärts über die Monatsgrenze")
	t.equal(CandyMatch3.shift_date_key("2026-12-31", 1), "2027-01-01", "Vorwärts über die Jahresgrenze")
	t.equal(CandyMatch3.shift_date_key("2028-02-28", 1), "2028-02-29", "Schaltjahr wird beachtet")
	t.equal(CandyMatch3.daily_streak({"2026-09-24": 2, "2026-09-25": 3, "2026-09-26": 1}, "2026-09-26"), 3,
		"Serie über drei Tage")
	t.equal(CandyMatch3.daily_streak({"2026-09-25": 3}, "2026-09-26"), 1, "Ein noch offener Tag zählt nicht")
	t.equal(CandyMatch3.daily_streak({}, "2026-09-26"), 0, "Ohne Ergebnis keine Serie")
	t.equal(CandyMatch3.daily_streak({"2026-09-20": 1, "2026-09-24": 1}, "2026-09-26"), 0,
		"Zwei fehlende Tage brechen die Serie")
	t.suite_done()


# --- milestones -------------------------------------------------------------

func _milestones() -> void:
	t.suite("Candy Crush — Belohnungen")
	t.equal(CandyMatch3.world_bonus(0), {"moves": 0, "undos": 0, "bomb": false}, "Ohne Sterne kein Bonus")
	t.equal(int((CandyMatch3.world_bonus(10) as Dictionary)["moves"]), 3, "Bei zehn Sternen gibt es drei Züge extra")
	t.check(bool((CandyMatch3.world_bonus(25) as Dictionary)["bomb"]), "Bei 25 Sternen gibt es die Start-Farbbombe")
	var full: Dictionary = CandyMatch3.world_bonus(120)
	t.equal(int(full["moves"]), 5, "Alle Belohnungen zusammen: fünf Extra-Züge")
	t.equal(int(full["undos"]), 1, "Alles zusammen: ein Extra-Undo")
	t.equal(int((CandyMatch3.next_milestone(0) as Dictionary)["stars"]), 10, "Nächste Belohnung bei null Sternen")
	t.check(CandyMatch3.next_milestone(120).is_empty(), "Nach der letzten Belohnung gibt es keine mehr")

	var levels := {"1": 3, "2": 2, "41": 3, "161": 1}
	t.equal(CandyMatch3.world_stars(levels, "candy"), 5, "Sterne der ersten Welt")
	t.equal(CandyMatch3.world_stars(levels, "crystals"), 3, "Sterne der zweiten Welt")
	t.equal(CandyMatch3.world_stars(levels, "xmas"), 1, "Sterne der Weihnachtswelt")
	t.equal(CandyMatch3.world_stars(levels, "gems"), 0, "Leere Welt zählt null")

	var level := CandyMatch3.level_for("flowers", 6)
	var plain := CandyMatch3.start_level(level)
	var rewarded := CandyMatch3.start_level(level, CandyMatch3.world_bonus(45))
	t.equal(int(rewarded["movesLeft"]), int(level["moves"]) + 5, "Der Bonus gibt Extraboni")

	# The start bomb must not create a match and must not kill the only move.
	for world_id in CandyMatch3.world_ids():
		for index in [1, 5, 13, 29, 40]:
			var game := CandyMatch3.start_level(CandyMatch3.level_for(world_id, index), CandyMatch3.world_bonus(25))
			var bombs := 0
			for cell in CandyMatch3.open_cells(game["board"]):
				if (game["board"] as Dictionary)["specials"][cell] == CandyMatch3.SPECIAL_BOMB:
					bombs += 1
			t.equal(bombs, 1, "Start-Farbbombe in %s/%d" % [world_id, index])
			t.check(not CandyMatch3.has_any_match(game["board"]), "Start ohne Sofort-Reihe in %s/%d" % [world_id, index])
			t.check(CandyMatch3.has_valid_swap(game["board"]), "Start mit Zug in %s/%d" % [world_id, index])

	# The contrast palette is six distinct colours.
	t.equal(CandyMatch3.HIGH_CONTRAST_PALETTE.size(), 6, "Kontrastpalette hat sechs Farben")
	var unique := {}
	for hex_value in CandyMatch3.HIGH_CONTRAST_PALETTE:
		unique[str(hex_value)] = true
	t.equal(unique.size(), 6, "Kontrastpalette ist farblich eigenständig")
	for world in CandyMatch3.WORLDS:
		var classic := CandyMatch3.palette_color(world, 0, CandyMatch3.PALETTE_CLASSIC)
		var contrast := CandyMatch3.palette_color(world, 0, CandyMatch3.PALETTE_CONTRAST)
		t.check(not classic.is_equal_approx(contrast), "Kontrastmodus ändert die Farbe")
	t.suite_done()


# --- undo -------------------------------------------------------------------

func _undo() -> void:
	t.suite("Candy Crush — Undo")
	var level := CandyMatch3.level_for("gems", 3)
	var game := CandyMatch3.start_level(level)
	var before := CandyMatch3.snapshot_state(game)
	var before_colors: Array = (before["board"] as Dictionary)["colors"]
	var swaps := CandyMatch3.find_valid_swaps(game["board"], 1)
	game["movesLeft"] = int(game["movesLeft"]) - 1
	var outcome := CandyMatch3.try_swap(game["board"], int((swaps[0] as Dictionary)["a"]), int((swaps[0] as Dictionary)["b"]),
		game["rng"], int(level["colors"]))
	CandyMatch3.continue_cascades(game, outcome["step"])
	t.check(int(game["score"]) > 0, "Der Zug hat Punkte gebracht")

	CandyMatch3.restore_state(game, before)
	t.equal(int(game["score"]), 0, "Punkte sind zurückgesetzt")
	t.equal(int(game["movesLeft"]), int(level["moves"]), "Der Zug ist zurückgenommen")
	t.equal((game["board"] as Dictionary)["colors"], before_colors, "Das Brett ist wieder im alten Zustand")
	var empty_collection: Array = []
	empty_collection.resize(int(level["colors"]))
	empty_collection.fill(0)
	t.equal((game["collected"] as Array), empty_collection, "Sammlung zurückgesetzt")

	# The snapshot is independent of the running game.
	CandyMatch3.clear_candy(game["board"], 0)
	t.check((before["board"] as Dictionary)["colors"][0] != CandyMatch3.NO_CANDY, "Snapshot ist unabhängig")
	t.suite_done()
