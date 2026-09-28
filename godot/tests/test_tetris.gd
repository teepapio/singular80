class_name TestTetris
extends RefCounted
## Tests for the rotation of Tetris: the Super Rotation System, its kick tables
## and the T-Spin preview. T-Spin scoring, the Back-to-Back chain and the violet
## board marks all hang off the last move having been a turn — and a turn only
## lands in a notch because the piece was dropped or shoved there. The piece
## boxes mirror `TetrisScreen.PIECES`; the screen is never named statically,
## because that would pull it into the compile chain of `run_tests.gd`, which
## runs before the autoloads are registered.

var t: TestKit

## The seven spawn states, exactly as `TetrisScreen.PIECES` holds them. They are
## the SRS boxes: the guideline's state 0 for every piece.
const I := [[0, 0, 0, 0], [1, 1, 1, 1], [0, 0, 0, 0], [0, 0, 0, 0]]
const J := [[1, 0, 0], [1, 1, 1], [0, 0, 0]]
const L := [[0, 0, 1], [1, 1, 1], [0, 0, 0]]
const O := [[1, 1], [1, 1]]
const S := [[0, 1, 1], [1, 1, 0], [0, 0, 0]]
const T := [[0, 1, 0], [1, 1, 1], [0, 0, 0]]
const Z := [[1, 1, 0], [0, 1, 1], [0, 0, 0]]


## Entry point used by `run_tests.gd`. The tree is unused — every rule here is a
## pure function — but the parameter is accepted so the runner may pass it.
func run(kit: TestKit, _tree: SceneTree = null) -> void:
	t = kit
	_drehen()
	t.close_suite()
	_kick_tabellen()
	t.close_suite()
	_tspin_drehen()
	t.close_suite()
	_vorschau()
	t.close_suite()


# --- helpers ---------------------------------------------------------------

## A well of `cols` × `rows` cells, 0 meaning free.
func _well(cols: int, rows: int) -> Array:
	var board: Array = []
	for y in rows:
		var row: Array = []
		for x in cols:
			row.append(0)
		board.append(row)
	return board


## A well written top row first, `.` free and `X` occupied.
func _shape(rows: Array) -> Array:
	var board: Array = []
	for line in rows:
		var row: Array = []
		for letter in str(line):
			row.append(0 if letter == "." else 1)
		board.append(row)
	return board


## The collision test of the screen: walls and floor block, the space above the
## ceiling is free — the ceiling itself the rules watch, because a kick points
## upwards.
func _collider(board: Array) -> Callable:
	var cols: int = (board[0] as Array).size()
	return func(matrix: Array, x: int, y: int) -> bool:
		for my in matrix.size():
			for mx in (matrix[my] as Array).size():
				if int((matrix[my] as Array)[mx]) == 0:
					continue
				var bx: int = x + mx
				var by: int = y + my
				if bx < 0 or bx >= cols or by >= board.size():
					return true
				if by >= 0 and int((board[by] as Array)[bx]) != 0:
					return true
		return false


## The screen's `_filled_at`: walls and floor count as occupied, the open space
## above the well does not. This is what lets a wall and a floor count as corners.
func _filled(board: Array) -> Callable:
	var cols: int = (board[0] as Array).size()
	return func(x: int, y: int) -> bool:
		if x < 0 or x >= cols or y >= board.size():
			return true
		if y < 0:
			return false
		return int((board[y] as Array)[x]) != 0


## The free cells per row, which the screen caches so the preview needs no copy
## of the well.
func _holes(board: Array) -> Array[int]:
	var out: Array[int] = []
	for row in board:
		var empty_cells := 0
		for value in row:
			if int(value) == 0:
				empty_cells += 1
		out.append(empty_cells)
	return out


## A plain call of the preview, so the tests do not have to repeat the argument
## list of eight parameters everywhere.
func _preview(board: Array, type: int, state: int, x: int, y: int, matrix: Array) -> Dictionary:
	return TetrisRules.spin_preview(type, state, x, y, matrix, _holes(board), _filled(board), _collider(board))


func _plan(board: Array, type: int, state: int, x: int, y: int, matrix: Array, clockwise: bool) -> Dictionary:
	return TetrisRules.plan_rotation(type, state, x, y, matrix, clockwise, _collider(board))


## The T-Spin-Double board, in columns 0–5. The T comes to rest at box origin
## (2, 3) on the bump at (5, 2); turning it clockwise costs no kick and lets it
## drop two rows into the slot at (2, 5), where three corners of its box are
## occupied and two rows are one cell short of full:
##
##     . . . . . .   the T falls in here and rests at row 3
##     X X . . . .   ← its flat side on the bump at column 2
##     X X X . . X   ← the slot begins: the T fills the hole at column 3
##     X X X . . X   ← and both holes of this row
##     X X X . X X   ← the third corner, closing the box
##     X X X X X X
var _double_board: Array = [
	"......", "......", "......", "......", "XX....",
	"XXX..X", "XXX..X", "XXX.XX", "XXXXXX",
]


# --- the turn itself --------------------------------------------------------

func _drehen() -> void:
	t.suite("Tetris — Drehen & Wall-Kicks")

	# A turn is rigid: no block may be lost or duplicated, or the well would fill
	# with holes nobody placed.
	for box in [I, J, L, O, S, T, Z]:
		t.equal(TetrisRules.cell_count(TetrisRules.rotate_matrix(box, true)), TetrisRules.cell_count(box),
			"Eine Drehung behält alle Steine")
		t.equal(TetrisRules.cell_count(TetrisRules.rotate_matrix(box, false)), TetrisRules.cell_count(box),
			"Die Gegenrichtung ebenso")

	# Four turns clockwise are the piece again — the proof that the boxes are
	# turned about their middle and not shifted.
	for box in [I, J, L, S, T, Z]:
		var turned: Array = box
		for step in 4:
			turned = TetrisRules.rotate_matrix(turned, true)
		t.equal(turned, box, "Vier Vierteldrehungen ergeben das Ausgangsstück")

	# The guideline's states: the T points up, right, down, left, and the I stands
	# upright in the third column of its box.
	t.equal(TetrisRules.rotate_matrix(T, true), [[0, 1, 0], [0, 1, 1], [0, 1, 0]], "Der T zeigt nach rechts")
	t.equal(TetrisRules.rotate_matrix(T, false), [[0, 1, 0], [1, 1, 0], [0, 1, 0]], "Der T zeigt nach links")
	t.equal(TetrisRules.rotate_matrix(T, false).size(), 3, "Der T bleibt in seiner 3×3-Box")
	t.equal(TetrisRules.rotate_matrix(I, true), [[0, 0, 1, 0], [0, 0, 1, 0], [0, 0, 1, 0], [0, 0, 1, 0]],
		"Der I kippt in die dritte Spalte seiner 4×4-Box")

	# The four states, and the turn that leads into them.
	t.equal(TetrisRules.next_state(0, true), 1, "Aus 0 wird im Uhrzeigersinn R")
	t.equal(TetrisRules.next_state(1, true), 2, "Aus R wird 2")
	t.equal(TetrisRules.next_state(2, true), 3, "Aus 2 wird L")
	t.equal(TetrisRules.next_state(3, true), 0, "Aus L wird wieder 0")
	t.equal(TetrisRules.next_state(0, false), 3, "Gegen den Uhrzeigersinn geht 0 nach L")
	t.equal(TetrisRules.next_state(3, false), 2, "Gegen den Uhrzeigersinn geht L nach 2")
	t.equal(TetrisRules.state_name(1), "R", "Die Zustände heißen wie in den Tabellen")
	t.equal(TetrisRules.state_name(2), "2", "Auch die 180°-Drehung hat einen Namen")

	# An empty well: the plain turn fits, no kick is used, nothing moves.
	var open := _well(10, 20)
	var plan := _plan(open, 5, 0, 3, 4, T, true)
	t.check(not plan.is_empty(), "Auf freiem Feld dreht sich der T")
	t.equal(int(plan["state"]), 1, "Der T landet im Zustand R")
	t.equal(int(plan["x"]), 3, "Ohne Kicker bleibt die Spalte")
	t.equal(int(plan["y"]), 4, "Ohne Kicker bleibt die Reihe")
	t.equal(plan["kick"], Vector2i.ZERO, "Der erste Eintrag jeder Tabelle ist die reine Drehung")
	t.equal(plan["matrix"], TetrisRules.rotate_matrix(T, true), "Der gedrehte T wandert mit")

	# Two turns in a row walk the states round, each out of its own table.
	var twice := _plan(open, 5, 1, 3, 4, plan["matrix"], true)
	t.equal(int(twice["state"]), 2, "Die zweite Drehung führt in die 180°-Lage")
	t.equal(twice["matrix"], [[0, 0, 0], [1, 1, 1], [0, 1, 0]], "Zwei Drehungen zeigen den T nach unten")

	# A shaft three cells wide with a lid: the T has nowhere to turn to. Both
	# directions are tried, and the ceiling stops a kick from lifting the piece
	# out of the well — above it counts as free.
	var shaft := _shape(["011", "000", "000", "111"])
	t.check(_plan(shaft, 5, 0, 0, 0, T, true).is_empty(), "Im engen Schacht geht die Drehung nicht")
	t.check(_plan(shaft, 5, 0, 0, 0, T, false).is_empty(), "Auch rückwärts nicht")
	t.equal(TetrisRules.top_row(T), 0, "Der T beginnt in der obersten Boxreihe")

	# Falling: how far a piece comes to rest, counted in rows.
	t.equal(TetrisRules.drop_distance(T, 3, 0, _collider(open)), 18, "Der T fällt bis auf den Boden")
	t.equal(TetrisRules.drop_distance(O, 4, 4, _collider(open)), 14, "Der Quadrat fällt genauso weit")
	t.equal(TetrisRules.drop_distance(T, 1, 0, _collider(_shape(["......", "......", "......", "XXXXXX"]))), 1,
		"Eine Zeile unter dem T beendet den Fall")
	t.equal(TetrisRules.drop_distance(T, 3, 0, _collider(_shape(["....", "...."]))), 0,
		"Neben der Wand fällt gar nichts")
	t.suite_done()


# --- the kick tables --------------------------------------------------------

func _kick_tabellen() -> void:
	t.suite("Tetris — Drehen & Wall-Kicks")

	# Every quarter turn of every piece kind has its five offsets. A half turn is
	# not part of the system and has no table.
	for type in [TetrisRules.I_PIECE_TYPE, TetrisRules.T_PIECE_TYPE]:
		for from_state in 4:
			for to_state in 4:
				var list := TetrisRules.kicks(type, from_state, to_state)
				if not TetrisRules.is_quarter_turn(from_state, to_state):
					t.check(list.is_empty(), "Eine halbe Drehung hat keine Tabelle")
					continue
				t.equal(list.size(), 5, "Jede Vierteldrehung hat fünf Kicker")
				t.equal(list[0], Vector2i.ZERO, "Der erste Kicker ist immer die reine Drehung")

	# The T's famous entry: 0→R is lifted out of the floor, which is the fourth
	# offset of the table. The tables are printed with y upwards, so the board
	# sees it as two rows *down*.
	var jlstz := TetrisRules.kicks(TetrisRules.T_PIECE_TYPE, 0, 1)
	t.equal(jlstz, [Vector2i(0, 0), Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(0, 2), Vector2i(-1, 2)] as Array[Vector2i],
		"Die Tabelle 0→R hebt den T aus dem Boden")
	t.equal(jlstz[2], Vector2i(-1, -1), "Der dritte Kicker geht eine Spalte links und eine Reihe hoch")
	t.equal(jlstz[3], Vector2i(0, 2), "Der vierte Kicker zieht den T zwei Reihen tiefer")

	# The mirror turn is the mirror image of the first one.
	t.equal(TetrisRules.kicks(TetrisRules.T_PIECE_TYPE, 0, 3)[1], Vector2i(1, 0),
		"Der erste Kicker von 0→L zeigt nach rechts statt nach links")
	t.equal(TetrisRules.kicks(TetrisRules.T_PIECE_TYPE, 0, 3)[2], Vector2i(1, -1),
		"Der dritte Kicker von 0→L hebt den T nach rechts oben")
	t.equal(TetrisRules.kicks(TetrisRules.T_PIECE_TYPE, 0, 3)[3], Vector2i(0, 2),
		"Der vierte Kicker zieht ihn zwei Reihen tiefer")

	# The I rotates about a different point: it alone may move two cells.
	t.check(TetrisRules.kicks(TetrisRules.I_PIECE_TYPE, 0, 1) != TetrisRules.kicks(TetrisRules.T_PIECE_TYPE, 0, 1),
		"Der I hat eine eigene Tabelle")
	t.check(TetrisRules.kicks(TetrisRules.I_PIECE_TYPE, 0, 1).has(Vector2i(-2, 0)),
		"Der I darf beim Drehen zwei Spalten springen")
	t.check(not TetrisRules.kicks(TetrisRules.T_PIECE_TYPE, 0, 1).has(Vector2i(-2, 0)),
		"Der T springt nie zwei Spalten")
	t.equal(TetrisRules.kicks(TetrisRules.I_PIECE_TYPE, 1, 0)[1], Vector2i(2, 0),
		"Der I dreht zurück mit zwei Spalten Versatz")

	# A kick is worth saying out loud; the hint in the HUD says it.
	t.equal(TetrisRules.kick_text(Vector2i.ZERO), "ohne Kick", "Ohne Versatz gibt es keinen Kicker")
	t.equal(TetrisRules.kick_text(Vector2i(0, 2)), "Kick ↓2", "Zwei Reihen tiefer wird nach unten gezählt")
	t.equal(TetrisRules.kick_text(Vector2i(-1, -1)), "Kick ←1+↑1", "Ein Kicker in zwei Richtungen nennt beide")
	t.equal(TetrisRules.kick_text(Vector2i(2, 0)), "Kick →2", "Nach rechts zählt als Pfeil nach rechts")

	# A T jammed under an overhang on the floor. Clockwise is walled in on every
	# offset; anticlockwise only the third one frees it — one column to the right
	# and one row *up*. A list of horizontal offsets could never do that, and
	# this is the case a player runs into as soon as the stack gets uneven.
	var jam := _shape([".....", ".X...", ".....", ".....", "XXXXX"])
	t.check(_plan(jam, 5, 0, 1, 2, T, true).is_empty(), "Im Uhrzeigersinn ist der T eingeklemmt")
	var freed := _plan(jam, 5, 0, 1, 2, T, false)
	t.check(not freed.is_empty(), "Gegen den Uhrzeigersinn kommt er frei")
	t.equal(freed["kick"], Vector2i(1, -1), "Nur der dritte Kicker passt: eine Spalte rechts, eine Reihe hoch")
	t.equal(int(freed["x"]), 2, "Der T landet eine Spalte weiter rechts")
	t.equal(int(freed["y"]), 1, "und eine Reihe höher, unter dem Überhang hindurch")
	t.equal(int(freed["state"]), 3, "und zeigt nach links")
	t.suite_done()


# --- a T-Spin out of a turn -------------------------------------------------

func _tspin_drehen() -> void:
	t.suite("Tetris — Drehen & Wall-Kicks")

	# The board above, seen from the T: it rests on the bump at (2, 3), the turn
	# costs no kick, and the piece drops two rows into the slot.
	var notch := _shape(_double_board)
	var preview := _preview(notch, 5, 0, 2, 3, T)
	t.check(not preview.is_empty(), "Die Vorschau erkennt den T-Spin")
	t.equal(str(preview["spin"]), "full", "Drei Ecken ergeben einen vollen T-Spin")
	t.equal(int(preview["rows"]), 2, "Der T-Spin Double räumt zwei Reihen")
	t.equal(int(preview["state"]), 1, "Die Vorschau nennt den Zustand R")
	t.equal(int(preview["from_state"]), 0, "und den Zustand, aus dem heraus gedreht wird")
	t.equal(preview["kick"], Vector2i.ZERO, "hier kostet die Drehung keinen Kicker")
	t.equal(int(preview["x"]), 2, "Das Stück landet in der Senke")
	t.equal(int(preview["y"]), 5, "zwei Reihen tiefer, wo es zur Ruhe kommt")
	t.equal(preview["matrix"], TetrisRules.rotate_matrix(T, true), "in der Lage, die der T-Spin braucht")
	t.equal(str(preview["label"]), "T-Spin Double  ·  0→R  ohne Kick", "Der Hinweis nennt Turn, Kicker und Ertrag")

	# What the scoring table promises for that arrangement: 1200 instead of 300
	# for a plain Double. The whole point of the feature.
	t.equal(int(TetrisRules.score_clear(int(preview["rows"]), 1, 0, 0, str(preview["spin"]))["points"]), 1200,
		"Der T-Spin Double ist mehr wert als ein gewöhnlicher")
	t.equal(int(TetrisRules.score_clear(int(preview["rows"]), 1, 0, 0, "none")["points"]), 300,
		"und der Vergleich dazu")

	# The preview must not invent a spin where there is none, and it must stay
	# quiet for the other six pieces.
	var open := _well(10, 20)
	t.check(_preview(open, 5, 0, 3, 0, T).is_empty(), "Auf freiem Feld gibt es keinen T-Spin")
	for type in [0, 1, 2, 3, 4, 6]:
		t.check(_preview(open, int(type), 0, 3, 0, _box_of(int(type))).is_empty(),
			"Außer dem T gibt es keinen T-Spin")
	t.check(_preview(notch, 5, 1, 2, 5, TetrisRules.rotate_matrix(T, true)).is_empty(),
		"Ein T, der schon im Ziel liegt, muss erst gedreht werden")

	t.equal(TetrisRules.spin_name("full", 0), "T-Spin", "Ein T-Spin ohne Linie")
	t.equal(TetrisRules.spin_name("full", 1), "T-Spin Single", "Ein T-Spin Single")
	t.equal(TetrisRules.spin_name("full", 3), "T-Spin Triple", "Ein T-Spin Triple")
	t.equal(TetrisRules.spin_name("full", 4), "T-Spin Quad", "Ein T-Spin Quad")
	t.equal(TetrisRules.spin_name("mini", 2), "T-Spin Mini Double", "Ein T-Spin Mini Double")
	t.equal(TetrisRules.spin_name("mini", 0), "T-Spin Mini", "Ein T-Spin Mini ohne Linie")

	# Rows a piece would complete, counted from the free cells per row.
	t.equal(TetrisRules.rows_completed(TetrisRules.rotate_matrix(T, true), 2, 5, _holes(notch)), 2,
		"Der T am Ziel schließt zwei Reihen")
	t.equal(TetrisRules.rows_completed(T, 0, 0, _holes(_shape(["XXXX", "XXXX"]))), 0,
		"Ein Stück auf einem bereits vollen Brett räumt nichts extra")
	t.suite_done()


# --- what the player is told -------------------------------------------------

func _vorschau() -> void:
	t.suite("Tetris — Drehen & Wall-Kicks")

	var notch := _shape(_double_board)
	# Counter-clockwise, the same resting T turns into a shape that cannot move
	# at all: one corner, no line, no spin. The preview has to notice that the
	# other direction is the better one and name the Triple... the Double.
	t.equal(_plan(notch, 5, 0, 2, 3, T, false)["kick"], Vector2i.ZERO, "Rückwärts passt der T ohne Kicker")
	t.equal(int(_plan(notch, 5, 0, 2, 3, T, false)["state"]), 3, "Rückwärts führt in den Zustand L")
	var chosen := _preview(notch, 5, 0, 2, 3, T)
	t.equal(int(chosen["state"]), 1, "Die Vorschau wählt die Drehung, die etwas einbringt")
	t.equal(int(chosen["rows"]), 2, "nämlich zwei Reihen")
	t.equal(str(chosen["spin"]), "full", "und einen vollen T-Spin statt des einen daneben")

	# The hint has to fit the column under the danger line, so it names the turn,
	# the kick and the win — and nothing else.
	var label := str(chosen["label"])
	t.check(label.begins_with("T-Spin "), "Der Hinweis beginnt mit dem Gewinn")
	t.check(label.contains("0→R"), "und nennt den Turn, der ihn bringt")
	t.check(label.length() <= 40, "Der Hinweis bleibt kurz genug für die Spalte")

	# An empty well teaches the player nothing, so the hint stays empty there
	# rather than promising a spin that cannot be set up.
	t.check(_preview(_well(10, 20), 5, 0, 3, 0, T).is_empty(), "Auf freiem Feld bleibt der Hinweis leer")
	t.suite_done()


## The spawn box of a piece type, for the loop over the other six.
func _box_of(type: int) -> Array:
	match type:
		0: return I
		1: return J
		2: return L
		3: return O
		4: return S
		6: return Z
	return T
