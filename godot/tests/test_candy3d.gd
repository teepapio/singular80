class_name TestCandy3d
extends RefCounted
## Tests for "Candy Crush 3D" that belong to this game. `TestCandyMatch3` holds
## the pure rules; what is here is what a rules test cannot reach — the run
## summary, the screen's frame loop, the clocks its timers read and the panels it
## builds. The combination table is the exception: pure as well, but a rule nobody
## can see on the board is a rule nobody uses, so table, preview and result row
## are checked together.
##
## The screen script is never referenced statically: that would pull it into
## `run_tests.gd`'s compile chain, which runs before the autoloads are registered.

## The two cells the combination tests fire from: column 3, rows 4 and 5.
## Written as `row * 8 + col`, because that is what `cell_index` does.
const _A := 4 * 8 + 3
const _B := 5 * 8 + 3
## A colour no other candy on the test board wears, and a cell that shares a row
## with one of its candies but touches none of them — so a test can tell a line
## from a square.
const SPARSE := 6
const _WATCH := 0 * 8 + 2

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
	await _combinations(tree)
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


## The screen's timers must run on the delta it is handed. `WorldScreen` only
## ticks `elapsed` inside `_process`, so a screen that reads `elapsed` for its
## cascade freezes the moment it is stepped from anywhere else — and a board stuck
## in the busy mode is a board the player cannot touch.
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


# --- combinations ------------------------------------------------------------

## Two special candies swapped into each other are worth more together than
## apart — and the player has to be able to *see* that before paying a move.
## The rules of the table are pure, but they only mean something next to the
## preview on the board and the peak in the result screen, so all three live in
## one suite.
func _combinations(tree: SceneTree) -> void:
	t.suite("Candy Crush — Kombinationen")
	_table()
	_colour_bomb()
	await _preview(tree)
	t.suite_done()


## Which two special kinds form which combination.
func _table() -> void:
	var m := CandyMatch3
	t.equal(m.combo_kind(m.SPECIAL_NONE, m.SPECIAL_NONE), m.COMBO_NONE, "Zwei normale Bonbons kombinieren nicht")
	t.equal(m.combo_kind(m.SPECIAL_ROW, m.SPECIAL_NONE), m.COMBO_NONE,
		"Ein Spezialbonbon und ein normales Bonbon kombinieren nicht")
	t.equal(m.combo_kind(m.SPECIAL_ROW, m.SPECIAL_ROW), m.COMBO_LINES, "Zwei gleichgerichtete Streifen: Dreifachblitz")
	t.equal(m.combo_kind(m.SPECIAL_COL, m.SPECIAL_COL), m.COMBO_LINES, "Zwei senkrechte Streifen: Dreifachblitz")
	t.equal(m.combo_kind(m.SPECIAL_ROW, m.SPECIAL_COL), m.COMBO_STAR, "Quer zueinander: Blitzkreuz")
	t.equal(m.combo_kind(m.SPECIAL_ROW, m.SPECIAL_WRAPPED), m.COMBO_CROSS, "Verpackt mit Streifen: Kreuzfeuer")
	t.equal(m.combo_kind(m.SPECIAL_WRAPPED, m.SPECIAL_WRAPPED), m.COMBO_SQUARE, "Zwei Verpackte: Detonation")
	t.equal(m.combo_kind(m.SPECIAL_BOMB, m.SPECIAL_NONE), m.COMBO_COLOUR, "Farbbombe mit Bonbon: Farbwelle")
	t.equal(m.combo_kind(m.SPECIAL_BOMB, m.SPECIAL_ROW), m.COMBO_FUSE, "Farbbombe mit Streifen: Zündschnur")
	t.equal(m.combo_kind(m.SPECIAL_BOMB, m.SPECIAL_WRAPPED), m.COMBO_STORM, "Farbbombe mit Verpacktem: Farbsturm")
	t.equal(m.combo_kind(m.SPECIAL_BOMB, m.SPECIAL_BOMB), m.COMBO_BOMB, "Zwei Farbbomben: Farbflut")

	# The direction of the drag cannot change what the two candies become.
	var kinds: Array = [m.SPECIAL_ROW, m.SPECIAL_COL, m.SPECIAL_WRAPPED, m.SPECIAL_BOMB]
	for first in kinds:
		for second in kinds:
			t.equal(m.combo_kind(first, second), m.combo_kind(second, first),
				"'%s' + '%s' ist symmetrisch" % [m.special_name(first), m.special_name(second)])

	# Every combination carries its own name — a player should be able to learn
	# the table by name instead of memorising silhouettes.
	var names := {}
	for kind in range(m.COMBO_NONE, m.COMBO_STAR + 1):
		var name := m.combo_name(kind)
		if kind == m.COMBO_NONE:
			t.equal(name, "", "Ohne Kombination gibt es keinen Namen")
			continue
		t.check(not name.is_empty(), "Kombination %d hat einen Namen" % kind)
		t.check(not names.has(name), "'%s' ist nur einmal vergeben" % name)
		names[name] = true
	t.equal(names.size(), 8, "Jede der acht Kombinationen hat einen eigenen Namen")

	# Two stripes beat one: the combination is more than the sum of its parts.
	var board := _combo_board(m.SPECIAL_ROW, m.SPECIAL_ROW)
	var blast := m.combo_blast(board, _A, _B)
	var single: Array = []
	m.blast_cells(board, _A, single, {})
	t.check(blast.size() > single.size() * 2, "Der Dreifachblitz räumt mehr als das Doppelte eines Streifens")
	t.equal(blast.size(), m.COLS * 3, "Drei vollständige Reihen")
	for col in m.COLS:
		for row in [4, 5, 6]:
			t.check(blast.has(m.cell_index(col, row)), "Reihe %d ist dabei" % row)
	for row in [3, 7]:
		t.check(not blast.has(m.cell_index(0, row)), "Reihe %d bleibt stehen" % row)
	t.check(m.combo_blast(_combo_board(m.SPECIAL_NONE, m.SPECIAL_NONE), _A, _B).is_empty(),
		"Ohne Kombination bleibt das Brett unberührt")

	# The blast is centred on the cell the player dragged *to*: the columns are
	# the ones around `_B`, not around `_A`.
	var vertical := _combo_board(m.SPECIAL_COL, m.SPECIAL_COL)
	var columns := m.combo_blast(vertical, _A, _B)
	t.equal(columns.size(), m.ROWS * 3, "Drei vollständige Spalten")
	for row in m.ROWS:
		for col in [2, 3, 4]:
			t.check(columns.has(m.cell_index(col, row)), "Spalte %d ist dabei" % col)
	for col in [1, 5]:
		t.check(not columns.has(m.cell_index(col, 4)), "Spalte %d bleibt stehen" % col)

	# A cross clears both axes: three rows and three columns.
	var cross := m.combo_blast(_combo_board(m.SPECIAL_ROW, m.SPECIAL_COL), _A, _B)
	t.equal(cross.size(), m.COLS * 3 + m.ROWS * 3 - 9, "Blitzkreuz: drei Reihen und drei Spalten")
	t.check(cross.has(m.cell_index(2, 4)) and cross.has(m.cell_index(4, 6)), "Das Kreuz reicht in alle vier Ecken des Sprungs")
	t.check(not cross.has(m.cell_index(1, 3)), "Was weder in einer Reihe noch Spalte liegt, bleibt")
	# Wrapped plus striped is the same cross, only stronger than a single wrapped candy.
	var single_wrapped: Array = []
	m.blast_cells(_combo_board(m.SPECIAL_WRAPPED, m.SPECIAL_NONE), _A, single_wrapped, {})
	t.check(cross.size() > single_wrapped.size() * 3, "Kreuzfeuer ist mehr als dreimal ein einzelnes Verpacktes")

	# Two wrapped candies blow a five-by-five field.
	var square := m.combo_blast(_combo_board(m.SPECIAL_WRAPPED, m.SPECIAL_WRAPPED), _A, _B)
	t.equal(square.size(), 25, "Die Detonation räumt 5 × 5")
	t.check(square.has(m.cell_index(1, 3)) and square.has(m.cell_index(5, 7)), "Sie reicht zwei Felder in jede Richtung")
	t.check(not square.has(m.cell_index(0, 2)), "Am Rand der Detonation steht noch etwas")

	# Two colour bombs clear the whole board.
	t.equal(m.combo_blast(_combo_board(m.SPECIAL_BOMB, m.SPECIAL_BOMB), _A, _B).size(), m.CELL_COUNT,
		"Die Farbflut kennt keine Grenze")


## The three combinations the colour bomb is part of differ in what they do to
## the partner's colour — and the difference is visible in what gets cleared.
##
## The colour is deliberately sparse: six candies in six different places, so a
## test can tell "the colour went" from "the lines went" from "the squares went".
func _colour_bomb() -> void:
	var m := CandyMatch3
	# Colour wave: the colour, and nothing around it.
	var plain := _bomb_board(m.SPECIAL_NONE)
	var sparse := _sparse_cells(plain)
	t.equal(sparse.size(), 6, "Die Farbe liegt sechsmal verstreut auf dem Brett")
	var cleared := _cleared_by(plain)
	var gone := 0
	for cell in sparse:
		if cleared.has(cell):
			gone += 1
	t.equal(gone, sparse.size(), "Die Farbwelle räumt jedes Bonbon der Farbe")
	t.check(cleared.has(_A), "Die Farbbombe geht mit")
	t.check(not cleared.has(_WATCH), "Die Farbwelle holt nichts aus der Nachbarschaft")

	# Striped: the whole colour turns striped, so it takes its lines along.
	var fuse := _bomb_board(m.SPECIAL_ROW)
	var fuse_sparse := _sparse_cells(fuse)
	var fuse_cleared := _cleared_by(fuse)
	var lines := 0
	for cell in fuse_sparse:
		if _row_gone(fuse_cleared, m.row_of(cell)):
			lines += 1
	t.equal(lines, fuse_sparse.size(), "Jede Reihe mit Farbe geht als ganze mit (%d von %d)" % [lines, fuse_sparse.size()])
	t.check(fuse_cleared.has(_WATCH), "Die Zündschnur reicht bis ans andere Ende der Reihe")
	t.check(_row_gone(fuse_cleared, 0), "Reihe 0 ist restlos weg")
	t.check(not _row_gone(fuse_cleared, 2), "Reihe 2 ohne Farbe bleibt stehen")

	# Colour storm: the same colour, but every one of them explodes in its own
	# three by three area — a wrapped partner must not be watered down to a stripe.
	var storm := _bomb_board(m.SPECIAL_WRAPPED)
	var storm_sparse := _sparse_cells(storm)
	var storm_cleared := _cleared_by(storm)
	var squares := 0
	for cell in storm_sparse:
		if _area_gone(storm_cleared, cell):
			squares += 1
	t.equal(squares, storm_sparse.size(), "Jedes Bonbon der Farbe sprengt sein eigenes 3 × 3 (%d von %d)" % [squares, storm_sparse.size()])
	t.check(not storm_cleared.has(_WATCH), "Der Farbsturm holt nicht die ganze Reihe")
	t.check(not _row_gone(storm_cleared, 0), "Der Farbsturm lässt die Reihe unvollständig stehen")
	t.check(cleared.size() < storm_cleared.size() and cleared.size() < fuse_cleared.size(),
		"Eine Farbbombe auf ein Spezialbonbon räumt mehr als die Farbwelle")


## Every candy of the sparse colour — read *before* the move rearranges the board.
func _sparse_cells(board: Dictionary) -> Array:
	var out: Array = []
	for cell in CandyMatch3.CELL_COUNT:
		if (board["colors"] as Array)[cell] == SPARSE:
			out.append(cell)
	return out


## The cells the first step of the swap `_A` → `_B` cleared.
func _cleared_by(board: Dictionary) -> Array:
	var outcome := CandyMatch3.try_swap(board, _A, _B, CandyMatch3.mulberry32(5), 6)
	return (outcome["step"] as Dictionary)["cleared"]


## Is the whole row cleared? Sparse colours leave most of a row standing, so this
## is what tells a line from a single candy.
func _row_gone(cleared: Array, row: int) -> bool:
	for col in CandyMatch3.COLS:
		if not cleared.has(CandyMatch3.cell_index(col, row)):
			return false
	return true


## Is the three by three area around `cell` completely cleared?
func _area_gone(cleared: Array, cell: int) -> bool:
	for dr in range(-1, 2):
		for dc in range(-1, 2):
			var c: int = CandyMatch3.col_of(cell) + dc
			var r: int = CandyMatch3.row_of(cell) + dr
			if c < 0 or c >= CandyMatch3.COLS or r < 0 or r >= CandyMatch3.ROWS:
				continue
			if not cleared.has(CandyMatch3.cell_index(c, r)):
				return false
	return true


# --- the combination on the board and in the summary -------------------------

## The board has to show the blast before the move costs anything, and the
## result screen has to name the biggest combination of the run.
func _preview(tree: SceneTree) -> void:
	var m := CandyMatch3
	var screen = await _open_candy(tree)
	if screen == null:
		return
	var board: Dictionary = screen.state["board"]
	var pair := _candy_pair(board)
	t.check(pair.x >= 0, "Das Brett hat zwei benachbarte Bonbons")
	if pair.x < 0:
		return
	var a: int = pair.x
	var b: int = pair.y
	var moves_before: int = int(screen.state["movesLeft"])
	_keep_level_open(screen)

	# Holding a striped candy shows the three lines a second one would add.
	(board["specials"] as Array)[a] = m.SPECIAL_ROW
	(board["specials"] as Array)[b] = m.SPECIAL_ROW
	screen.selected = a
	screen._show_combo_partners(a)
	t.equal(screen.combo_label, m.combo_name(m.COMBO_LINES), "Die Vorschau nennt die Kombination")
	var blast := m.combo_blast(board, a, b)
	var marked_cells := 0
	for cell in blast:
		if screen.combo_set.has(cell):
			marked_cells += 1
	t.equal(marked_cells, blast.size(), "Die Vorschau markiert jeden Einschlagsbereich")
	t.check(screen.combo_set.size() > m.COLS, "Die Vorschau umfasst mehr als eine Reihe")
	t.equal(int(screen.state["movesLeft"]), moves_before, "Die Vorschau kostet keinen Zug")
	t.check(screen._toast_label.text.contains(m.combo_name(m.COMBO_LINES)), "Der Bildschirm nennt die Kombination")

	# The marked candies grow, the rest of the board stays as it is.
	var marked := -1
	for target in screen.combo_set.keys():
		if int(target) != a and int(target) != b and screen.pieces.has(int(target)):
			marked = int(target)
			break
	t.check(marked >= 0, "Die Vorschau trifft ein Feld mit Bonbon")
	if marked >= 0:
		var scale_before: float = (screen.pieces[marked] as Dictionary)["scale"]
		for i in 6:
			screen._update_world(0.1)
		t.check(float((screen.pieces[marked] as Dictionary)["scale"]) > scale_before,
			"Ein getroffenes Bonbon wächst sichtbar")
		t.check(screen._toast_label.visible, "Der Hinweis bleibt stehen")

	# A plain neighbour is no partner — the board must not promise anything.
	(board["specials"] as Array)[b] = m.SPECIAL_NONE
	screen._show_combo_partners(a)
	t.equal(screen.combo_set.size(), 0, "Ein normales Bonbon zeigt keine Kombination")
	(board["specials"] as Array)[b] = m.SPECIAL_ROW

	# Setting the combination off: one move, a bigger clear, and a name.
	screen._try_swap(a, b)
	t.equal(screen.mode, screen.MODE_BUSY, "Die Kombination sperrt das Brett wie jeder Zug")
	t.equal(screen.combo_set.size(), 0, "Nach dem Zug ist die Vorschau weg")
	t.equal(int(screen.state["movesLeft"]), moves_before - 1, "Die Kombination kostet einen Zug")
	for i in 80:
		if screen.mode != screen.MODE_BUSY:
			break
		screen._update_world(0.35)
	t.equal(screen.mode, screen.MODE_SELECT, "Die Kettenreaktion endet im Auswahlmodus")
	t.check(screen._toast_label.text.contains(m.combo_name(m.COMBO_LINES)),
		"Der Zug meldet die Kombination zurück")
	var peaks := m.highlights(screen.state)
	t.equal(int(peaks["combos"]), 1, "Die Kombination zählt als Peak")
	t.check(int(peaks["comboBest"]) >= blast.size(), "Der Peak merkt sich die Größe des Einschlags")
	t.equal(str(peaks["comboName"]), m.combo_name(m.COMBO_LINES), "Der Peak merkt sich den Namen")
	t.equal(int(peaks["comboMove"]), 1, "Der Peak merkt sich den Zug")

	# The result screen tells the story: one row for the best combination.
	var moment_row := {}
	for moment in m.run_moments(screen.state):
		if str((moment as Dictionary)["label"]).begins_with("Kombination:"):
			moment_row = moment
	t.check(not moment_row.is_empty(), "Das Ergebnis nennt die Kombination")
	if not moment_row.is_empty():
		t.equal(int(moment_row["value"]), int(peaks["comboBest"]), "Die Zeile nennt die Bonbonszahl")
		t.equal(int(moment_row["move"]), 1, "Die Zeile nennt ihren Zug")

	# Undo takes the peak with it — a combination the player takes back is not
	# their best one.
	screen._undo()
	t.equal(int(m.highlights(screen.state)["combos"]), 0, "Nach Undo zählt keine Kombination")
	t.equal(int(m.highlights(screen.state)["comboBest"]), 0, "Nach Undo ist der Einschlag zurückgenommen")
	var gone := true
	for moment in m.run_moments(screen.state):
		if str((moment as Dictionary)["label"]).begins_with("Kombination:"):
			gone = false
	t.check(gone, "Nach Undo nennt das Ergebnis keine Kombination")

	# The board a player gets may have holes and blockers in it. The preview and
	# the move have to work on every layout, not only on the one the test
	# happened to start with.
	for key in ["crystals:8", "halloween:21", "gems:40"]:
		var parts := str(key).split(":")
		screen._start_level(m.level_for(parts[0], int(parts[1])))
		_keep_level_open(screen)
		var other: Dictionary = screen.state["board"]
		var spot := _candy_pair(other)
		if spot.x < 0:
			t.check(false, "Level %s hat zwei benachbarte Bonbons" % key)
			continue
		(other["specials"] as Array)[spot.x] = m.SPECIAL_WRAPPED
		(other["specials"] as Array)[spot.y] = m.SPECIAL_COL
		screen._show_combo_partners(spot.x)
		t.equal(screen.combo_label, m.combo_name(m.COMBO_CROSS), "Kreuzfeuer auf Level %s" % key)
		t.check(screen.combo_set.size() > m.COLS, "Die Vorschau auf %s ist breit genug" % key)
		screen._try_swap(spot.x, spot.y)
		for i in 80:
			if screen.mode != screen.MODE_BUSY:
				break
			screen._update_world(0.35)
		t.equal(screen.mode, screen.MODE_SELECT, "Auf %s läuft die Kombination aus" % key)
		t.check(not m.has_any_match(other), "Das Brett von %s ist danach ruhig" % key)
		var empty := 0
		for cell in m.open_cells(other):
			if (other["colors"] as Array)[cell] == m.NO_CANDY:
				empty += 1
		t.equal(empty, 0, "Auf %s bleibt nach dem großen Einschlag kein Feld leer" % key)
		t.equal(int(m.highlights(screen.state)["comboMove"]), 1, "Auf %s ist es der erste Zug" % key)


## Puts the score goal of the running level out of reach. One combination clears
## a third of the board, and a level that ended here would take the screen away
## from the test in the middle of the measurement.
func _keep_level_open(screen) -> void:
	for goal in (screen.state["level"]["goals"] as Array):
		if str((goal as Dictionary)["kind"]) == "score":
			(goal as Dictionary)["target"] = 10000000


## A board with a pattern that never matches, so a test can place exactly the
## two candies it needs.
func _clean_board() -> Dictionary:
	var board := CandyMatch3.create_board(CandyMatch3.LAYOUT_FULL)
	var colors: Array = board["colors"]
	for row in CandyMatch3.ROWS:
		for col in CandyMatch3.COLS:
			colors[CandyMatch3.cell_index(col, row)] = (col + row * 2) % 6
	return board


func _combo_board(special_a: int, special_b: int) -> Dictionary:
	var board := _clean_board()
	(board["specials"] as Array)[_A] = special_a
	(board["specials"] as Array)[_B] = special_b
	return board


## The same board with one colour (SPARSE) on six scattered candies, a colour
## bomb on `_A` and `partner` on `_B`. Scattered means: no colour candy stands
## next to another, so a test can see exactly how far a combination reaches.
func _bomb_board(partner: int) -> Dictionary:
	var board := _clean_board()
	var colors: Array = board["colors"]
	for cell in [CandyMatch3.cell_index(0, 0), CandyMatch3.cell_index(7, 1),
			CandyMatch3.cell_index(1, 4), CandyMatch3.cell_index(6, 5),
			CandyMatch3.cell_index(3, 7), _B]:
		colors[cell] = SPARSE
	(board["specials"] as Array)[_A] = CandyMatch3.SPECIAL_BOMB
	(board["specials"] as Array)[_B] = partner
	return board


## Two neighbouring cells that both hold a candy — the screen plays a real
## generated level, so the test has to look instead of assuming.
func _candy_pair(board: Dictionary) -> Vector2i:
	for row in CandyMatch3.ROWS - 1:
		for col in CandyMatch3.COLS:
			var a := CandyMatch3.cell_index(col, row)
			var b := CandyMatch3.cell_index(col, row + 1)
			if CandyMatch3.has_candy(board, a) and CandyMatch3.has_candy(board, b):
				return Vector2i(a, b)
	return Vector2i(-1, -1)


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
