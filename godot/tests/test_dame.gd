class_name TestDame
extends RefCounted
## Tests for "Dame": the capture analysis behind the board marks and the hint,
## plus the hint's way through a real screen.
##
## In its own file next to `checkers.gd`, so the game's rule coverage travels
## with the game and never collides with another board game's suite.

var t: TestKit


## Entry point used by `run_tests.gd`. The screen suite needs the scene tree.
func run(kit: TestKit, tree: SceneTree) -> void:
	t = kit
	_suite(_capture_analysis)
	_suite(_movable_pieces)
	await _hint_at_the_board(tree)


## Runs one suite and fails it if it returned before its own `t.suite_done()`,
## which is what a GDScript runtime error does.
func _suite(body: Callable) -> void:
	body.call()
	t.close_suite()


# --- helpers ----------------------------------------------------------------


## An empty board with the given `square = piece` pairs. Playable squares only:
## `index_of(row, col)` with `(row + col)` odd.
func _board(pieces: Dictionary) -> PackedInt32Array:
	var board := PackedInt32Array()
	board.resize(Checkers.CELL_COUNT)
	for i in Checkers.CELL_COUNT:
		board[i] = Checkers.EMPTY
	for square in pieces:
		board[int(square)] = int(pieces[square])
	return board


func _at(row: int, col: int) -> int:
	return Checkers.index_of(row, col)


## The entry of `candidates` for the piece standing on `square`, or `{}`.
func _entry_for(candidates: Array, square: int) -> Dictionary:
	for entry in candidates:
		if int((entry as Dictionary)["from"]) == square:
			return entry
	return {}


## Where a chain ends, and how many stones it takes.
func _chain_ends_at(turn: Dictionary) -> Array:
	var steps: Array = turn["steps"]
	var last: Array = steps[steps.size() - 1]
	return [int(last[1]), int(turn["captures"])]


# --- suites -----------------------------------------------------------------


## Which piece takes how many stones, and which capture is the strongest one.
func _capture_analysis() -> void:
	t.suite("Dame — Schlagzug-Analyse")

	# The opening has no capture at all.
	var opening := Checkers.create_initial_board()
	t.equal(Checkers.capture_candidates(opening, Checkers.WHITE).size(), 0, "Zur Eröffnung schlägt niemand")
	t.check(Checkers.best_capture(opening, Checkers.WHITE).is_empty(), "Ohne Schlagzug gibt es keinen Tipp")
	t.check(Checkers.best_capture(opening, Checkers.BLACK).is_empty(), "Auch Schwarz hat zum Start keinen Schlagzug")

	# Weiß (5,2) springt über (4,3) nach (3,4) und über (2,3) nach (1,2).
	var chain := _board({
		_at(5, 2): Checkers.WHITE_MAN,
		_at(4, 3): Checkers.BLACK_MAN,
		_at(2, 3): Checkers.BLACK_MAN,
	})
	var candidates := Checkers.capture_candidates(chain, Checkers.WHITE)
	t.equal(candidates.size(), 1, "Nur ein Stein kann schlagen")
	t.equal(int((candidates[0] as Dictionary)["from"]), _at(5, 2), "Der schlagende Stein wird genannt")
	t.equal(int((candidates[0] as Dictionary)["captures"]), 2, "Seine stärkste Kette nimmt zwei Steine")
	t.equal(Checkers.capture_candidates(chain, Checkers.BLACK).size(), 1, "Schwarz sieht denselben Aufbau von unten")
	t.equal(int((Checkers.capture_candidates(chain, Checkers.BLACK)[0] as Dictionary)["captures"]), 1, "Schwarz schlägt den weißen Stein")

	var best := Checkers.best_capture(chain, Checkers.WHITE)
	t.equal(int(best["captures"]), 2, "Der Tipp zählt beide Steine")
	t.equal((best["steps"] as Array).size(), 2, "Der Tipp zeigt beide Sprünge")
	t.equal(int(_chain_ends_at(best)[0]), _at(1, 2), "Der Tipp endet auf dem letzten Landefeld")
	t.equal(Checkers.count_pieces(Checkers.apply_turn(chain, best), Checkers.BLACK), 0, "Der Tippzug räumt beide Steine weg")

	# Derselbe Stein kann auch nur einen schlagen — der Tipp nimmt die Kette.
	var shorter := _board({
		_at(5, 2): Checkers.WHITE_MAN,
		_at(4, 3): Checkers.BLACK_MAN,
		_at(2, 3): Checkers.BLACK_MAN,
		_at(4, 1): Checkers.BLACK_MAN,
	})
	var twice := Checkers.capture_candidates(shorter, Checkers.WHITE)
	t.equal(twice.size(), 1, "Zwei Ketten desselben Steins ergeben eine Marke")
	t.equal(int((twice[0] as Dictionary)["captures"]), 2, "Die längere Kette gewinnt")
	t.equal(Checkers.count_pieces(Checkers.apply_turn(shorter, Checkers.best_capture(shorter, Checkers.WHITE)), Checkers.BLACK), 1, "Der kurze Sprung übrig gelassen")

	# Zwei schlagende Steine: der stärkere steht vorn.
	var both := _board({
		_at(5, 2): Checkers.WHITE_MAN,
		_at(4, 3): Checkers.BLACK_MAN,
		_at(2, 3): Checkers.BLACK_MAN,
		_at(7, 4): Checkers.WHITE_MAN,
		_at(6, 5): Checkers.BLACK_MAN,
	})
	var marks := Checkers.capture_candidates(both, Checkers.WHITE)
	t.equal(marks.size(), 2, "Beide schlagenden Steine werden markiert")
	t.equal(int((marks[0] as Dictionary)["from"]), _at(5, 2), "Der stärkere Schlag steht vorn")
	t.equal(int((marks[1] as Dictionary)["from"]), _at(7, 4), "Der schwächere Schlag folgt")
	t.equal(int((marks[1] as Dictionary)["captures"]), 1, "Der zweite Stein schlägt genau einen")
	t.equal(int(_chain_ends_at(Checkers.best_capture(both, Checkers.WHITE))[0]), _at(1, 2), "Der Tipp folgt der Reihenfolge")

	# Gleiche Zahl geschlagener Steine: die Dame wird vorgezogen.
	var kings := _board({
		_at(5, 0): Checkers.WHITE_KING,
		_at(4, 1): Checkers.BLACK_MAN,
		_at(6, 5): Checkers.WHITE_MAN,
		_at(5, 4): Checkers.BLACK_MAN,
	})
	var ranked := Checkers.capture_candidates(kings, Checkers.WHITE)
	t.equal(ranked.size(), 2, "Beide Steine schlagen einen")
	t.equal(int((ranked[0] as Dictionary)["from"]), _at(5, 0), "Bei Gleichstand gewinnt die Dame")
	t.equal(int(_chain_ends_at(Checkers.best_capture(kings, Checkers.WHITE))[0]), _at(3, 2), "Die Dame ist der Tipp")

	# Derselbe Aufbau, dieselbe Antwort: der Hinweis springt nicht.
	t.equal(Checkers.best_capture(kings, Checkers.WHITE), Checkers.best_capture(kings, Checkers.WHITE), "Der Tipp ist reproduzierbar")

	# Eine Dame mit zwei gleich langen Sprüngen zählt als eine Marke.
	var twin := _board({
		_at(3, 2): Checkers.WHITE_KING,
		_at(2, 1): Checkers.BLACK_MAN,
		_at(4, 3): Checkers.BLACK_MAN,
	})
	t.equal(Checkers.capture_candidates(twin, Checkers.WHITE).size(), 1, "Zwei Sprünge, eine Marke")
	t.equal(int((Checkers.capture_candidates(twin, Checkers.WHITE)[0] as Dictionary)["captures"]), 1, "Die Marke zählt den besten Sprung")

	# Kein Schlag für eine Seite, die nichts zu schlagen hat.
	var lone := _board({_at(6, 5): Checkers.BLACK_MAN})
	t.check(Checkers.best_capture(lone, Checkers.BLACK).is_empty(), "Ein einzelner Stein ohne Nachbar schlägt nicht")
	t.suite_done()


## The answer to "which of my pieces may move at all?".
func _movable_pieces() -> void:
	t.suite("Dame — Ziehbare Steine")

	var lone := _board({_at(4, 1): Checkers.WHITE_MAN})
	t.equal(Checkers.movable_squares(lone, Checkers.WHITE), [_at(4, 1)], "Der einzige Stein zieht")
	t.equal(Checkers.movable_squares(lone, Checkers.BLACK), [], "Die Gegenseite hat nichts zum Ziehen")

	# Ein Stein auf der letzten Reihe kann nicht mehr vor.
	var stuck := _board({_at(0, 1): Checkers.WHITE_MAN})
	t.equal(Checkers.movable_squares(stuck, Checkers.WHITE), [], "Reihe 0 ist blockiert")

	# Der Rückraum zählt mit — dort zieht ein Stein nach vorne.
	var back := _board({_at(6, 5): Checkers.WHITE_MAN})
	t.equal(Checkers.movable_squares(back, Checkers.WHITE), [_at(6, 5)], "Ein Stein im Rückraum zieht")
	var black_back := _board({_at(6, 5): Checkers.BLACK_MAN})
	t.equal(Checkers.movable_squares(black_back, Checkers.WHITE), [], "Ein schwarzer Stein ist kein Zug für Weiß")

	# Ein eingeklemmter Stein steht nicht in der Liste: vor ihm stehen Gegner,
	# und über ihnen ist das Landefeld besetzt.
	var blocked := _board({
		_at(4, 1): Checkers.WHITE_MAN,
		_at(3, 0): Checkers.BLACK_MAN,
		_at(3, 2): Checkers.BLACK_MAN,
		_at(2, 3): Checkers.BLACK_MAN,
	})
	t.equal(Checkers.movable_squares(blocked, Checkers.WHITE), [], "Ein eingeklemmter Stein darf nicht ziehen")
	t.suite_done()


## The marks and the hint on the real screen, and the move the hint offers.
func _hint_at_the_board(tree: SceneTree) -> void:
	t.suite("Dame — Tipp am Brett")
	var router := tree.root.get_node_or_null("/root/Router")
	if router == null:
		t.check(false, "Der Router ist erreichbar")
		return
	router.go_to("dame")
	await tree.create_timer(0.4).timeout
	var screen = router.current_screen
	t.check(screen != null, "Der Dame-Screen ist offen")
	if screen == null:
		return

	# The opening is a quiet one: nothing to mark, nothing to hint.
	t.equal(screen.capture_marks.size(), 0, "Zur Eröffnung trägt kein Stein eine Marke")
	screen.show_hint()
	t.equal(screen.hint_moves.size() > 0, true, "Der Tipp zeigt, welche Steine ziehen dürfen")
	t.equal(screen.hint_steps.size(), 0, "Ohne Schlagzug zeichnet der Tipp keinen Weg")

	# Now a position with a two-jump capture.
	screen.board = _board({
		_at(5, 2): Checkers.WHITE_MAN,
		_at(4, 3): Checkers.BLACK_MAN,
		_at(2, 3): Checkers.BLACK_MAN,
	})
	screen.side = Checkers.WHITE
	screen._recompute_captures()
	t.equal(screen.capture_marks.size(), 1, "Der schlagende Stein trägt eine Marke")
	t.equal(int((screen.capture_marks[0] as Dictionary)["captures"]), 2, "Die Marke nennt beide Steine")

	screen.show_hint()
	t.equal(screen.hint_steps.size(), 2, "Der Tipp zeichnet den ganzen Weg")
	t.equal(screen.legal_targets.size(), 1, "Der Tipp lässt genau ein Zielfeld zu")
	t.equal(int((screen.legal_targets[0] as Array)[1]), _at(1, 2), "Zielfeld ist das Ende der Kette")
	t.equal(screen.legal_turns.size(), 1, "Der Tipp hält den ganzen Zug bereit")

	# And the offered move really plays the whole chain, not just its last jump.
	screen._handle_click(_at(1, 2))
	t.equal(Checkers.count_pieces(screen.board, Checkers.BLACK), 0, "Beide geschlagenen Steine sind weg")
	t.equal(int(screen.board[_at(1, 2)]), Checkers.WHITE_MAN, "Der eigene Stein steht am Ende der Kette")
	t.equal(int(screen.board[_at(5, 2)]), Checkers.EMPTY, "Das Startfeld ist leer")
	t.equal(screen.hint_steps.size(), 0, "Nach dem Zug ist der Tipp weg")
	t.suite_done()
