class_name Test2048
extends RefCounted
## Tests for 2048 and its one-move preview, the "ghost" tile: the tile the next
## move adds, already on the board, which rides along with the slide and becomes
## permanent in that move. The rules are pure functions; the screen suite at the
## end drives the real screen so snapshot, undo and endgame cannot drift.

var t: TestKit
## Autoloads are not registered in `--script` mode, so they are fetched by path.
var _router: Node
## Loaded by path, never as `Game2048Screen`: a static reference would pull the
## screen into the compile chain of `run_tests.gd`, which runs before the engine
## registers the autoloads.
var _screen_script: GDScript


## Entry point used by `run_tests.gd`.
func run(kit: TestKit, tree: SceneTree) -> void:
	t = kit
	_ghost()
	t.close_suite()
	_ghost_is_a_tile()
	t.close_suite()
	_ghost_and_the_end()
	t.close_suite()
	await _screen_plays(tree)
	t.close_suite()


## A board with the given rows, `0` meaning free.
func _rows(values: Array) -> Array:
	var board := Twenty48.empty_board()
	for r in Twenty48.SIZE:
		for c in Twenty48.SIZE:
			Twenty48.set_at(board, r, c, int(values[r][c]))
	return board


## A full board of alternating 2 and 4: no free cell, no equal neighbours, no
## move. The classic dead end.
func _locked() -> Array:
	var values: Array = []
	for r in Twenty48.SIZE:
		var row: Array = []
		for c in Twenty48.SIZE:
			row.append(2 if (r + c) % 2 == 0 else 4)
		values.append(row)
	return _rows(values)


## `cell` freed, everything else untouched.
func _without(board: Array, cell: Vector2i) -> Array:
	var out := Twenty48.clone_board(board)
	Twenty48.set_at(out, cell.x, cell.y, 0)
	return out


func _rng(seed_value: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	return rng


# --- the ghost tile ---------------------------------------------------------

func _ghost() -> void:
	t.suite("2048 — Vorschau")

	var board := Twenty48.empty_board()
	var rng := _rng(20250926)
	var tile := Twenty48.plan_tile(board, rng)
	t.check(not tile.is_empty(), "Ein leeres Brett bekommt eine Vorschau")
	t.check(int(tile["value"]) == 2 or int(tile["value"]) == 4, "Die Vorschau ist eine 2 oder eine 4")
	t.equal(Twenty48.at(board, int(tile["row"]), int(tile["col"])), 0, "Die Vorschau zeigt auf ein freies Feld")
	t.equal(board.size(), 4, "Die Vorschau verändert das Brett nicht")

	# Same seed, same tile: a run is reproducible, which is what makes the
	# preview testable at all.
	t.equal(Twenty48.plan_tile(board, _rng(20250926)), tile, "Gleicher Same ergibt dieselbe Vorschau")
	t.check(Twenty48.plan_tile(board, _rng(7)) != tile, "Ein anderer Same ergibt eine andere Vorschau")

	var picks := 0
	for i in 40:
		var next := Twenty48.plan_tile(board, rng)
		picks += 1
		t.check(Twenty48.at(board, int(next["row"]), int(next["col"])) == 0, "Keine Vorschau landet auf einer belegten Kachel")
	t.equal(picks, 40, "Der Generator liefert bei Platz durch")

	t.check(Twenty48.plan_tile(_locked(), rng).is_empty(), "Ein volles Brett verspricht keine Kachel")

	# The opening: one real tile, one ghost — the classic two-tile start.
	var start := Twenty48.empty_board()
	var ghost := Twenty48.opening(start, _rng(4711))
	t.equal(Twenty48.count_tiles(start), 1, "Der Start legt genau eine echte Kachel")
	t.check(not ghost.is_empty(), "Der Start zeigt schon eine Vorschau")
	t.equal(Twenty48.at(start, int(ghost["row"]), int(ghost["col"])), 0, "Die Startvorschau blockiert keine Kachel")

	t.suite_done()


## The ghost slides, merges and pays — it is a normal tile for that one move.
func _ghost_is_a_tile() -> void:
	t.suite("2048 — Vorschau zählt mit")

	var board := Twenty48.empty_board()
	var slide := Twenty48.slide_pending(board, Twenty48.LEFT, {"row": 0, "col": 3, "value": 2})
	t.check(bool(slide["moved"]), "Eine Vorschau, die wegrutscht, ist ein Zug")
	t.equal(Twenty48.at(slide["values"], 0, 0), 2, "Die Vorschau rutscht wie eine Kachel mit")
	var moves: Array = slide["moves"]
	t.equal(moves.size(), 1, "Der Zugplan kennt die Vorschau")
	t.equal(moves[0]["from"], Vector2i(0, 3), "Die Vorschau startet auf ihrem Feld")

	var merge_board := Twenty48.empty_board()
	Twenty48.set_at(merge_board, 0, 0, 2)
	var merge := Twenty48.slide_pending(merge_board, Twenty48.LEFT, {"row": 0, "col": 1, "value": 2})
	t.equal(Twenty48.at(merge["values"], 0, 0), 4, "Vorschau und Kachel verschmelzen")
	t.equal(int(merge["gained"]), 4, "Die Verschmelzung mit der Vorschau zählt 4 Punkte")
	t.equal(Twenty48.count_tiles(merge["values"]), 1, "Aus zwei Kacheln wird eine")

	# A ghost that is already wedged in a corner and has no partner is not a
	# move — the plan has to be discarded, exactly as in every other 2048.
	var stuck := Twenty48.slide_pending(Twenty48.empty_board(), Twenty48.LEFT, {"row": 0, "col": 0, "value": 2})
	t.check(not bool(stuck["moved"]), "Eine Vorschau ohne Ziel ist kein Zug")

	# Without a ghost the module behaves like plain 2048.
	var plain := Twenty48.slide_pending(_without(_locked(), Vector2i(3, 3)), Twenty48.LEFT, {})
	t.equal(Twenty48.count_tiles(plain["values"]), 15, "Ohne Vorschau bleibt die Kachelzahl gleich")

	# A ghost from an outdated snapshot must never eat a real tile.
	var stale_board := Twenty48.empty_board()
	Twenty48.set_at(stale_board, 0, 0, 8)
	var stale := Twenty48.slide_pending(stale_board, Twenty48.LEFT, {"row": 0, "col": 0, "value": 2})
	t.equal(Twenty48.at(stale["values"], 0, 0), 8, "Eine veraltete Vorschau überschreibt keine Kachel")
	t.check(Twenty48.can_move_pending(_locked(), {"row": 0, "col": 0, "value": 2}) == false,
			"Eine Vorschau ohne Platz macht ein totes Brett nicht wieder lebendig")

	t.suite_done()


## The endgame is decided about board *plus* ghost, not about the board alone.
func _ghost_and_the_end() -> void:
	t.suite("2048 — Vorschau und Endgame")

	# A free cell always leaves a move, so a ghost can never rescue a board that
	# is already dead. It can do the opposite: it is a real tile for the slide, so
	# it may be the one that fills the last free cell and matches nothing. That is
	# why the screen checks for the end before every input instead of waiting for
	# a move that can no longer happen.
	var blocked := _without(_locked(), Vector2i(3, 0))
	t.check(Twenty48.can_move(blocked), "Das Brett allein laesst sich noch ziehen")
	t.check(not Twenty48.can_move_pending(blocked, {"row": 3, "col": 0, "value": 4}),
			"Eine Vorschau in der Ecke kann den letzten Zug blockieren")
	t.check(Twenty48.can_move_pending(blocked, {"row": 3, "col": 0, "value": 2}),
			"Eine passende Vorschau verschmilzt und das Spiel geht weiter")
	t.equal(Twenty48.count_tiles(blocked), 15, "Das Brett hat genau ein freies Feld")
	t.check(Twenty48.can_move_pending(blocked, {}), "Ohne Vorschau bleibt das Brett ziehbar")

	t.suite_done()


# --- screen -----------------------------------------------------------------

## The real screen: the ghost merges for real, the next one is planned, and undo
## puts the old preview back.
func _screen_plays(tree: SceneTree) -> void:
	t.suite("2048 — Screen")
	_router = tree.root.get_node_or_null("/root/Router")
	_screen_script = load("res://src/game/g2048/g2048_screen.gd")
	t.check(_router != null, "Der Router ist erreichbar")
	t.check(_screen_script != null, "Der 2048-Screen laesst sich laden")
	if _router == null or _screen_script == null:
		t.suite_done()
		return
	if not await t.goto(_router, tree, "g2048"):
		t.check(false, "Der 2048-Screen wird geoeffnet")
		t.suite_done()
		return
	var screen = _router.current_screen
	if screen == null:
		t.check(false, "Der 2048-Screen wird geoeffnet")
		t.suite_done()
		return
	t.check(screen.get_script() == _screen_script, "Es ist der 2048-Screen")

	# A fresh game shows one tile and the ghost it will add.
	t.equal(Twenty48.count_tiles(screen.board), 1, "Der Bildschirm startet mit einer Kachel")
	t.check(not screen.pending.is_empty(), "Der Bildschirm zeigt sofort eine Vorschau")
	t.equal(Twenty48.at(screen.board, int(screen.pending["row"]), int(screen.pending["col"])), 0,
			"Die Vorschau liegt auf einem freien Feld")

	# A 2 next to a 2, so the move is deterministic: the ghost merges.
	screen.board = Twenty48.empty_board()
	Twenty48.set_at(screen.board, 3, 0, 2)
	screen.pending = {"row": 3, "col": 1, "value": 2}
	screen.score = 0
	screen.history = {}
	var shown: Dictionary = screen.pending.duplicate(true)
	screen._move(Twenty48.LEFT)
	t.equal(Twenty48.at(screen.board, 3, 0), 4, "Der Bildschirm verschmilzt die Vorschau")
	t.equal(int(screen.score), 4, "Die Vorschau bringt dem Bildschirm Punkte")
	t.check(not screen.pending.is_empty(), "Der Bildschirm plant die naechste Vorschau")
	t.equal(Twenty48.at(screen.board, int(screen.pending["row"]), int(screen.pending["col"])), 0,
			"Die neue Vorschau blockiert keine Kachel")
	t.equal(int(screen.history["score"]), 0, "Der Zug hat den vorherigen Stand gesichert")

	# Undo takes the preview with it, otherwise the ghost shown after the undo
	# would be a tile the player never saw coming.
	screen.undo()
	t.equal(int(screen.score), 0, "Rueckgaengig nimmt die Punkte zurueck")
	t.equal(Twenty48.count_tiles(screen.board), 1, "Rueckgaengig stellt die Kachel wieder her")
	t.equal(Twenty48.at(screen.board, 3, 0), 2, "Rueckgaengig loest die Verschmelzung wieder auf")
	t.equal(screen.pending, shown, "Rueckgaengig stellt auch die Vorschau wieder her")
	t.check(screen.history.is_empty(), "Nach Rueckgaengig gibt es nichts mehr zurueckzunehmen")

	# The redraw with a ghost on the board and in the panel must not choke.
	screen.close_modals()
	screen._view.queue_redraw()
	await tree.process_frame
	screen.pending = {}
	screen._view.queue_redraw()
	await tree.process_frame
	t.check(true, "Der Screen zeichnet die Vorschau ohne Fehler")

	# A ghost that blocks the last move ends the game even though no move was
	# completed — the check cannot wait for a move that can no longer happen.
	screen.board = _without(_locked(), Vector2i(3, 0))
	screen.pending = {"row": 3, "col": 0, "value": 2}
	screen._check_end()
	t.check(not screen.has_modal(), "Eine verschmelzende Vorschau laesst das Spiel weiterlaufen")
	screen.pending = {"row": 3, "col": 0, "value": 4}
	screen._check_end()
	t.check(screen.has_modal(), "Eine blockierende Vorschau beendet das Spiel")

	# 2048 opens the win dialog — and reaching it does not silence the loss one,
	# or "keep playing" would be a run without an ending. `close_modals` only
	# queues the layer away, so the frame has to turn before the next check.
	screen.close_modals()
	await tree.process_frame
	screen.won = false
	screen.score = 4096
	screen.board = _rows([[0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 2048]])
	screen.pending = {}
	screen._check_end()
	t.check(screen.won and screen.has_modal(), "2048 oeffnet den Sieg-Dialog")
	screen.close_modals()
	await tree.process_frame
	screen.board = _locked()
	screen._check_end()
	t.check(screen.has_modal(), "Nach 2048 kann das Spiel trotzdem enden")
	screen.close_modals()
	await tree.process_frame
	t.suite_done()
