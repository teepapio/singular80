class_name TestCandy3d
extends RefCounted
## Tests for "Candy Crush 3D" that belong to this game.
##
## `TestCandyMatch3` holds the rules — board, generator, stars, undo — because
## those are pure functions that need no scene. What is here is what a rules
## test cannot reach: the run summary, the screen's own frame loop, the clocks
## its timers read and the panels it builds. Own file, so this game and the
## shared sweep in `test_screens.gd` never edit the same lines.
##
## The screen script is never referenced statically: a static reference would
## pull it into `run_tests.gd`'s compile chain, which happens before the
## autoloads are registered, and every autoload inside the screen would then
## fail to resolve. `test_metro_screens.gd` avoids the same trap the same way.

var t: TestKit
var _router: Node
var _game: Node


## Entry point used by `run_tests.gd`.
func run(kit: TestKit, tree: SceneTree) -> void:
	t = kit
	_router = tree.root.get_node_or_null("/root/Router")
	_game = tree.root.get_node_or_null("/root/Game")
	t.check(_router != null, "Der Router ist erreichbar")
	t.check(_game != null, "Der Spielstand ist erreichbar")
	if _router == null or _game == null:
		t.close_suite()
		return
	await _clock(tree)
	t.close_suite()
	await _result_summary(tree)
	t.close_suite()
	_moments()
	t.close_suite()


# --- the story of a finished run --------------------------------------------

## What the result screen reports back. Pure functions on a run state, so this
## part needs no screen: peaks, the rows they produce and the gap to the next
## star.
func _moments() -> void:
	t.suite("Candy Crush — Momente")
	var level := CandyMatch3.level_for("crystals", 5)
	var game := CandyMatch3.start_level(level)
	t.equal(CandyMatch3.run_moments(game).size(), 0, "Ein ungespieltes Level hat keine Momente")
	t.equal(int((CandyMatch3.star_gap(game) as Dictionary)["stars"]), 2, "Am Anfang fehlen Punkte zum zweiten Stern")
	t.check(int((CandyMatch3.star_gap(game) as Dictionary)["missing"]) > 0, "Die Lücke zum Stern ist positiv")

	# Peaks, not sums: a small step after a big one must not lower the record.
	CandyMatch3.apply_step_to_state(game, _step(900, 1, 9, 2))
	CandyMatch3.apply_step_to_state(game, _step(120, 1, 3, 0))
	CandyMatch3.apply_step_to_state(game, _step(60, 1, 3, 1))
	var peaks := CandyMatch3.highlights(game)
	t.equal(int(peaks["step"]), 900, "Der beste Einzelschritt bleibt")
	t.equal(int(peaks["clear"]), 9, "Der größte Match bleibt")
	t.equal(int(peaks["specials"]), 3, "Spezialbonbons werden über den Zug addiert")
	t.equal(int(peaks["moves"]), 0, "Hand-Schritte zählen nicht als Züge")

	# A peak that never happened stays out, every row carries number and unit.
	var hand := CandyMatch3.run_moments(game)
	t.equal(hand.size(), 3, "Ein einzelner Schritt liefert Match, Spezial und Zug")
	var labels: Array = []
	for moment in hand:
		labels.append(str((moment as Dictionary)["label"]))
	t.check(not labels.has("Längste Kette"), "Eine Kette von 1 ist kein Highlight")

	# A real run through the level: the moments have to describe what happened.
	var played := CandyMatch3.start_level(level)
	var turns := 0
	while not CandyMatch3.is_won(played) and int(played["movesLeft"]) > 0 and turns < 200:
		turns += 1
		var swaps := CandyMatch3.find_valid_swaps(played["board"])
		if swaps.is_empty():
			CandyMatch3.shuffle_board(played["board"], played["rng"], int(level["colors"]))
			continue
		var swap: Dictionary = swaps[0]
		var outcome := CandyMatch3.try_swap(played["board"], int((swap as Dictionary)["a"]), int((swap as Dictionary)["b"]),
			played["rng"], int(level["colors"]))
		if outcome.is_empty():
			break
		played["movesLeft"] = int(played["movesLeft"]) - 1
		CandyMatch3.continue_cascades(played, outcome["step"])
	t.check(turns > 0, "Der Durchlauf spielt echte Züge")
	var record := CandyMatch3.highlights(played)
	t.equal(int(record["moves"]), turns, "Jeder Zug wird gezählt")
	t.check(int(record["step"]) > 0, "Der beste Zug hat Punkte")
	t.check(int(record["stepMove"]) >= 1 and int(record["stepMove"]) <= turns,
		"Der beste Zug wird einem echten Zug zugeschlagen")
	var moments := CandyMatch3.run_moments(played)
	t.check(moments.size() >= 2, "Die Partie hat mehrere Momente (%d)" % moments.size())
	var best_clear := 0
	for moment in moments:
		var row: Dictionary = moment
		t.check(int(row["value"]) > 0, "'%s' hat einen Wert" % str(row["label"]))
		t.check(not str(row["label"]).is_empty() and not str(row["unit"]).is_empty(), "Die Zeile ist beschriftet")
		if str(row["label"]) == "Größter Match":
			best_clear = int(row["value"])
	t.check(best_clear >= 3, "Der größte Match umfasst mindestens drei Bonbons")

	# The gap follows the score: below both thresholds, between them, then done.
	var thresholds: Array = level["starScores"]
	var gap := CandyMatch3.star_gap(played)
	if int(played["score"]) >= int(thresholds[1]):
		t.check(gap.is_empty(), "Über dem höchsten Schwellwert gibt es keinen Stern mehr zu holen")
	elif int(played["score"]) >= int(thresholds[0]):
		t.equal(int((gap as Dictionary)["stars"]), 3, "Über dem ersten Schwellwert zählt der dritte Stern")
	else:
		t.equal(int((gap as Dictionary)["stars"]), 2, "Sonst zählt der zweite Stern")
	if not gap.is_empty():
		t.equal(int((gap as Dictionary)["missing"]), maxi(0,
			int(thresholds[int((gap as Dictionary)["stars"]) - 2]) - int(played["score"])),
			"Die Lücke ist die Differenz zum Schwellwert")
	t.equal(CandyMatch3.star_ordinal(2), "zum zweiten Stern", "Zweiter Stern")
	t.equal(CandyMatch3.star_ordinal(3), "zum dritten Stern", "Dritter Stern")

	# An undone move leaves nothing behind — a chain the player took back is not
	# their highlight.
	var undone := CandyMatch3.start_level(level)
	var before_undo := CandyMatch3.snapshot_state(undone)
	var first := CandyMatch3.find_valid_swaps(undone["board"], 1)[0] as Dictionary
	undone["movesLeft"] = int(undone["movesLeft"]) - 1
	CandyMatch3.continue_cascades(undone, CandyMatch3.try_swap(undone["board"],
		int(first["a"]), int(first["b"]), undone["rng"], int(level["colors"]))["step"])
	t.check(int(CandyMatch3.highlights(undone)["step"]) > 0, "Der Zug zählt zuerst einmal")
	CandyMatch3.restore_state(undone, before_undo)
	t.equal(int(CandyMatch3.highlights(undone)["step"]), 0, "Nach Undo ist der Moment zurückgenommen")
	t.equal(int(CandyMatch3.highlights(undone)["moves"]), 0, "Nach Undo zählt kein Zug")
	t.suite_done()


## A resolved step in the shape `apply_step_to_state` reads.
func _step(score: int, chain: int, cleared: int, created: int) -> Dictionary:
	var cells: Array = []
	for i in cleared:
		cells.append(i)
	var made: Array = []
	for i in created:
		made.append({"cell": i, "color": 0, "special": CandyMatch3.SPECIAL_ROW})
	var colors: Array = []
	for i in cleared:
		colors.append(0)
	return {"score": score, "chain": chain, "cleared": cells, "created": made, "clearedColors": colors}


## The screen's timers must run on the delta it is handed.
##
## `WorldScreen` only ticks `elapsed` inside `_process`. A screen that reads
## `elapsed` for its cascade therefore freezes the moment it is stepped from
## anywhere else, and a board stuck in the busy mode is a board the player
## cannot touch — which is exactly what the shared sweep walked into.
func _clock(tree: SceneTree) -> void:
	t.suite("Candy Crush — Frame-Takt")
	var screen = await _open_candy(tree)
	if screen == null:
		return

	var swaps := CandyMatch3.find_valid_swaps(screen.state["board"], 1)
	screen._try_swap(int((swaps[0] as Dictionary)["a"]), int((swaps[0] as Dictionary)["b"]))
	t.equal(screen.mode, screen.MODE_BUSY, "Ein Zug sperrt das Brett während der Kettenreaktion")

	var elapsed_before: float = screen.elapsed
	var clock_before: float = screen.clock
	screen._update_world(0.1)
	t.equal(screen.elapsed, elapsed_before, "Die Basis-Uhr laeuft nicht mit")
	t.check(screen.clock > clock_before, "Die eigene Uhr folgt dem Delta")
	screen.elapsed = elapsed_before
	screen.clock = clock_before

	var frames := 0
	while screen.mode == screen.MODE_BUSY and frames < 80:
		screen._update_world(0.35)
		frames += 1
	t.check(frames > 0, "Die Kettenreaktion braucht Bildschirmbilder")
	t.equal(screen.mode, screen.MODE_SELECT, "Die Kettenreaktion endet im Auswahlmodus")
	t.check(screen.steps.is_empty(), "Der Zugsschritt ist abgearbeitet")
	t.check(not CandyMatch3.has_any_match(screen.state["board"]), "Das Brett ist danach ruhig")

	# The board is playable again, and the move really costs one.
	var moves_left: int = int(screen.state["movesLeft"])
	var next_swap := CandyMatch3.find_valid_swaps(screen.state["board"], 1)
	if not next_swap.is_empty():
		screen._try_swap(int((next_swap[0] as Dictionary)["a"]), int((next_swap[0] as Dictionary)["b"]))
		t.equal(int(screen.state["movesLeft"]), moves_left - 1, "Der naechste Zug wird angenommen")
		for i in 80:
			if screen.mode != screen.MODE_BUSY:
				break
			screen._update_world(0.35)
		t.equal(screen.mode, screen.MODE_SELECT, "Auch der zweite Zug laeuft aus")
	t.suite_done()


## The result screen has to say what the level was like, not only how many
## stars it earned. Drives the screen to a finished run and reads the panel.
func _result_summary(tree: SceneTree) -> void:
	t.suite("Candy Crush — Ergebnisbildschirm")
	var screen = await _open_candy(tree)
	if screen == null:
		return

	# One real move, so the summary describes a run instead of an empty board.
	var swaps := CandyMatch3.find_valid_swaps(screen.state["board"], 1)
	screen._try_swap(int((swaps[0] as Dictionary)["a"]), int((swaps[0] as Dictionary)["b"]))
	for i in 80:
		if screen.mode != screen.MODE_BUSY:
			break
		screen._update_world(0.35)
	t.equal(screen.mode, screen.MODE_SELECT, "Der Zug ist durch")
	t.check(int(CandyMatch3.highlights(screen.state)["step"]) > 0, "Der Zug hat einen besten Zug notiert")

	# A won level: score over the first star threshold, every goal fulfilled.
	var level: Dictionary = screen.state["level"]
	var collected: Array = screen.state["collected"]
	for goal in (level["goals"] as Array):
		var entry := goal as Dictionary
		if str(entry["kind"]) == "collect":
			collected[int(entry["color"])] = int(entry["target"])
	screen.state["score"] = int((level["starScores"] as Array)[0])
	screen._win()

	t.equal(CandyMatch3.stars_for(screen.state), 2, "Der Schwellwert ergibt zwei Sterne")
	var gap := CandyMatch3.star_gap(screen.state)
	t.equal(int((gap as Dictionary)["stars"]), 3, "Es fehlt der dritte Stern")
	t.check(int((gap as Dictionary)["missing"]) > 0, "Die Lücke zum dritten Stern ist positiv")

	var text := _collect_text(screen.hud_root)
	t.check(text.contains("Level geschafft!"), "Der Ergebnistitel steht da")
	t.check(text.contains("Punkte:"), "Das Ergebnis nennt die Punkte")
	t.check(text.contains("Züge:"), "Das Ergebnis nennt die verbrauchten Züge")
	t.check(text.contains("★☆"), "Zwei von drei Sternen sind sichtbar")
	# The run summary: what the level was like and what is still missing.
	t.check(text.contains("Bester Zug"), "Das Ergebnis nennt den besten Zug")
	t.check(text.contains("Zug 1"), "Der beste Zug nennt seinen Zug")
	t.check(text.contains("Größter Match"), "Das Ergebnis nennt den größten Match")
	t.check(text.contains(CandyMatch3.star_ordinal(3)), "Das Ergebnis nennt den fehlenden Stern")
	t.check(text.contains(Ui.format_number(int((gap as Dictionary)["missing"]))), "Die Lücke ist als Zahl da")
	t.suite_done()


# --- helpers -----------------------------------------------------------------

## Switches to the screen and waits only as long as the switch takes, then
## closes the level select: the test starts where a player starts, on the board
## and not behind the level picker.
##
## The router publishes `current_id` as soon as the screen is in the tree but
## ignores the next request until the fade ended, so both conditions matter.
func _open_candy(tree: SceneTree):
	var waited := 0.0
	while _router.transitioning and waited < 2.0:
		await tree.process_frame
		waited += 1.0 / 60.0
	_router.go_to("candy3d")
	waited = 0.0
	while waited < 2.0:
		await tree.process_frame
		waited += 1.0 / 60.0
		if _router.current_id == "candy3d" and not _router.transitioning:
			await tree.process_frame
			break
	var screen = _router.current_screen
	t.check(screen != null, "Der Bildschirm öffnet")
	if screen == null or screen.state.is_empty():
		return null
	screen._select_root.visible = false
	t.check(screen.pieces.size() > 0, "Bonbons liegen auf dem Brett")
	return screen


## Every label below a node, joined. The result screen is text, so its text is
## the assertion.
func _collect_text(node: Node) -> String:
	var out := ""
	if node is Label:
		out += (node as Label).text + "\n"
	for child in node.get_children():
		out += _collect_text(child)
	return out
