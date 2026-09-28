class_name TetrisRules
extends RefCounted
## Scoring, T-Spin detection, rotation (Super Rotation System) and board-threat
## rules for Tetris. The screen owns the animation; everything that decides
## *whether a move was skilful, what it is worth and where a piece may turn*
## lives here so it can be unit tested without a viewport.
## Reference: the modern Tetris Guideline scoring model (T-Spin via the
## three-corner rule, Back-to-Back for difficult clears, combo, Perfect Clear)
## and its Super Rotation System (four states, per-piece kick tables).

## `TetrisScreen.PIECES` index of the T piece.
const T_PIECE_TYPE := 5

## `TetrisScreen.PIECES` index of the I piece; it gets its own kick table.
const I_PIECE_TYPE := 0

## Points for a line clear before level and difficulty bonuses.
const LINE_SCORES: Array[int] = [0, 100, 300, 500, 800]

## T-Spin line-clear bases. Index = lines cleared, so a T-Spin triple pays 1600.
const TSPIN_SCORES: Array[int] = [400, 800, 1200, 1600]

## Extra points per Back-to-Back step (50, 100, 200, …).
const B2B_STEP := 50

## Points per combo step (50, 100, 150, …).
const COMBO_STEP := 50

## Perfect-Clear bases. Index = lines cleared, so wiping the well with a single
## line pays 800 and with a Quad 2000.
const PC_SCORES: Array[int] = [0, 800, 1200, 1800, 2000]

## A back-to-back Quad Perfect Clear pays this instead of `PC_SCORES[4]`.
const PC_B2B_QUAD := 3200

## How long a Perfect Clear is celebrated, in seconds.
const PC_CELEBRATION := 1.6

## How many upcoming pieces the queue may show.
const PREVIEW_OPTIONS: Array[int] = [3, 4, 5, 6]

## The well counts as "tower grows" above this fill ratio …
const DANGER_RATIO := 0.62

## … and as critical above this one.
const CRITICAL_RATIO := 0.82


## True when a T-Spin counts as such: the last move was a rotation, the piece is
## a T, and at least three of the four corners of the T's 3x3 box are occupied.
## `corners` is a 2x2 array of booleans, laid out filled/empty, filled/empty.
## `corners` is a 2×2 array of booleans, laid out filled/empty, filled/empty.
static func is_t_spin(piece_type: int, last_move_was_rotation: bool, corners: Array) -> bool:
	if not last_move_was_rotation or piece_type != T_PIECE_TYPE:
		return false
	return corner_count(corners) >= 3


## Number of occupied corners, or -1 for a malformed input.
static func corner_count(corners: Array) -> int:
	if corners.size() != 2:
		return -1
	var filled := 0
	for row in corners:
		if (row as Array).size() != 2:
			return -1
		for cell in row:
			if bool(cell):
				filled += 1
	return filled


## True when a T-Spin only reached two occupied corners, i.e. a T-Spin Mini.
static func is_t_spin_mini(corners: Array) -> bool:
	return corner_count(corners) == 2


## Corner occupancy of a T's 3x3 box, as a 2x2 array of booleans.
##
## `filled_at(x, y)` answers whether a board cell is occupied. Cells outside the
## well and above the ceiling count as occupied, which is what makes wall kicks
## into the floor register as T-Spins.
static func t_corners(x: int, y: int, filled_at: Callable) -> Array:
	return [
		[bool(filled_at.call(x, y)), bool(filled_at.call(x + 2, y))],
		[bool(filled_at.call(x, y + 2)), bool(filled_at.call(x + 2, y + 2))],
	]


## Score a completed line clear.
##
## `lines` 0-4, `level` the current level, `combo` the number of *previous*
## consecutive clears, `back_to_back` the current B2B chain length, `tspin` the
## spin kind ("none", "mini" or "full").
##
## Returns the awarded points plus the text the HUD shows and the chain values
## for the next clear, so the screen never has to duplicate the bookkeeping.
static func score_clear(lines: int, level: int, combo: int, back_to_back: int, tspin: String) -> Dictionary:
	var count: int = clampi(lines, 0, 4)
	var spin := tspin if tspin in ["mini", "full"] else "none"
	if count == 0 and spin == "none":
		return {
			"points": 0, "base": 0, "b2bBonus": 0, "comboBonus": 0,
			"message": "", "difficult": false, "combo": 0, "back_to_back": 0, "flash": 0.0,
		}

	# A T-Spin that clears no line at all is still worth 400 and still opens a
	# Back-to-Back chain, which is what makes setting one up feel rewarding.
	var difficult := count == 4 or spin != "none"

	var base := 0
	if spin != "none":
		# `TSPIN_SCORES` is indexed by lines cleared: index 0 is the line-less
		# T-Spin, 1 a Single, 2 a Double and 3 a Triple.
		base = TSPIN_SCORES[count]
		if spin == "mini":
			base = int(round(float(base) * 0.5))
	else:
		base = LINE_SCORES[count]

	# A Back-to-Back step only pays out on difficult clears.
	var b2b_bonus := 0
	var next_b2b := 0
	if difficult:
		next_b2b = back_to_back + 1
		if back_to_back > 0:
			b2b_bonus = B2B_STEP * back_to_back

	# A combo step pays out from the second consecutive clear onwards. A T-Spin
	# without a line neither advances nor breaks the chain.
	var combo_bonus := 0
	var next_combo := combo
	if count > 0:
		next_combo = combo + 1
		if combo > 0:
			combo_bonus = COMBO_STEP * combo

	return {
		"points": (base + b2b_bonus + combo_bonus) * maxi(1, level),
		"base": base,
		"b2bBonus": b2b_bonus,
		"comboBonus": combo_bonus,
		"message": _message(count, spin, back_to_back, next_combo),
		"difficult": difficult,
		"combo": next_combo,
		"back_to_back": next_b2b,
		"flash": float(count) * 0.12 + (0.18 if spin != "none" else 0.0),
	}


static func _message(count: int, spin: String, back_to_back: int, combo: int) -> String:
	var parts: Array[String] = []
	if count == 4:
		parts.append("QUAD!")
	elif spin != "none":
		parts.append("T-SPIN %s" % ("MINI" if spin == "mini" else "FULL"))
		if count > 1:
			parts.append(["", "SINGLE", "DOUBLE", "TRIPLE", "QUAD"][count])
	elif count == 3:
		parts.append("TETRIS!")
	elif count == 2:
		parts.append("DOUBLE")
	if back_to_back > 0:
		parts.append("B2B ×%d" % (back_to_back + 1))
	# A combo only becomes news from the second consecutive clear onwards.
	if combo > 1:
		parts.append("COMBO ×%d" % combo)
	return "  ·  ".join(parts)


## True when the well holds no block at all — the board was wiped completely.
##
## A board without rows is not a Perfect Clear; there is no well to clear.
static func is_perfect_clear(board: Array) -> bool:
	if board.is_empty():
		return false
	for row in board:
		for value in row:
			if int(value) != 0:
				return false
	return true


## Score a Perfect Clear, the biggest moment the game has.
##
## `lines` is the size of the clear that emptied the well (at least one), `level`
## the current level and `back_to_back` the chain that came in. A Perfect Clear
## always counts as a difficult clear, so it opens or extends that chain — a Quad
## Perfect Clear directly after another difficult clear is worth the most of
## anything in the game.
static func perfect_clear(lines: int, level: int, back_to_back: int) -> Dictionary:
	var count: int = clampi(lines, 1, 4)
	var b2b_quad := count == 4 and back_to_back > 0
	var base: int = PC_B2B_QUAD if b2b_quad else PC_SCORES[count]
	var chain: int = maxi(1, back_to_back + 1)

	var parts: Array[String] = ["PERFECT CLEAR!"]
	if count > 1:
		parts.append(["", "SINGLE", "DOUBLE", "TRIPLE", "QUAD"][count])
	if b2b_quad:
		parts.append("B2B ×%d" % chain)

	return {
		"points": base * maxi(1, level),
		"base": base,
		"text": "  ·  ".join(parts),
		"back_to_back": chain,
		"seconds": PC_CELEBRATION,
		"b2b_quad": b2b_quad,
	}


## How full the well is, 0.0–1.0, over all cells.
static func fill_ratio(board: Array) -> float:
	var filled := 0
	var cells := 0
	for row in board:
		for value in row:
			cells += 1
			if int(value) != 0:
				filled += 1
	if cells == 0:
		return 0.0
	return float(filled) / float(cells)


## Threat level 0 (safe), 1 (tower grows) or 2 (critical).
static func danger_level(board: Array) -> int:
	var ratio := fill_ratio(board)
	if ratio < DANGER_RATIO:
		return 0
	return 2 if ratio >= CRITICAL_RATIO else 1


## The German warning for a threat level; empty while the well is safe.
static func danger_text(board: Array) -> String:
	var level := danger_level(board)
	if level == 0:
		return ""
	var free := 0
	for row in board:
		var empty := true
		for value in row:
			if int(value) != 0:
				empty = false
				break
		if empty:
			free += 1
	if level == 1:
		return Loc.f("The tower grows  ·  %d free rows", [free])
	return Loc.f("DANGER!  Only %d free rows left", [free])


## The next `count` pieces, padded with -1 when the queue runs dry.
static func preview_chain(queue: Array, count: int) -> Array[int]:
	var out: Array[int] = []
	for i in maxi(1, count):
		out.append(int(queue[i]) if i < queue.size() else -1)
	return out


## Clamp a stored preview-count setting onto the nearest allowed option.
static func preview_count(value: int) -> int:
	var best := PREVIEW_OPTIONS[0]
	for option in PREVIEW_OPTIONS:
		if absi(option - value) < absi(best - value):
			best = option
	return best


# --- Rotation: the Super Rotation System -------------------------------------
#
# A piece has four states, 0 (the one it spawns in), R, 2 and L, and a turn is
# never just "rotate and hope": the guideline shifts the piece through a table of
# five offsets and takes the first that fits. Those offsets are the reason a
# T-Spin is possible at all — a T that rotates flush into a wall has to be
# *lifted* out of it, and only the table knows by how much. Without them the
# T-Spin scoring, the Back-to-Back chain and the HUD spin preview are
# unreachable code.
#
# The tables are published with y pointing **up**; the board counts its rows down,
# so `kicks()` flips the sign on the way out.

## The four rotation states, in turn order. Every piece spawns in 0.
const STATE_0 := 0
const STATE_R := 1
const STATE_2 := 2
const STATE_L := 3

## Kick offsets for the J, L, S, T and Z, one list per turn. First the plain
## rotation, then the four offsets that may rescue it.
const KICKS_JLSTZ := {
	"0>1": [[0, 0], [-1, 0], [-1, 1], [0, -2], [-1, -2]],
	"1>0": [[0, 0], [1, 0], [1, -1], [0, 2], [1, 2]],
	"1>2": [[0, 0], [1, 0], [1, -1], [0, 2], [1, 2]],
	"2>1": [[0, 0], [-1, 0], [-1, 1], [0, -2], [-1, -2]],
	"2>3": [[0, 0], [1, 0], [1, 1], [0, -2], [1, -2]],
	"3>2": [[0, 0], [-1, 0], [-1, -1], [0, 2], [-1, 2]],
	"3>0": [[0, 0], [-1, 0], [-1, -1], [0, 2], [-1, 2]],
	"0>3": [[0, 0], [1, 0], [1, 1], [0, -2], [1, -2]],
}

## The I rotates about a different point and therefore kicks differently: it is
## the only piece that may move two cells sideways.
const KICKS_I := {
	"0>1": [[0, 0], [-2, 0], [1, 0], [-2, -1], [1, 2]],
	"1>0": [[0, 0], [2, 0], [-1, 0], [2, 1], [-1, -2]],
	"1>2": [[0, 0], [-1, 0], [2, 0], [-1, 2], [2, -1]],
	"2>1": [[0, 0], [1, 0], [-2, 0], [1, -2], [-2, 1]],
	"2>3": [[0, 0], [2, 0], [-1, 0], [2, 1], [-1, -2]],
	"3>2": [[0, 0], [-2, 0], [1, 0], [-2, -1], [1, 2]],
	"3>0": [[0, 0], [1, 0], [-2, 0], [1, -2], [-2, 1]],
	"0>3": [[0, 0], [-1, 0], [2, 0], [-1, 2], [2, -1]],
}


## The matrix `matrix` turned a quarter turn. Squares only — which is what the
## SRS boxes are — and rigid: the box keeps its size and every block keeps its
## place in it, so a turn never loses or moves a cell on its own.
static func rotate_matrix(matrix: Array, clockwise: bool) -> Array:
	var n := matrix.size()
	var out: Array = []
	for y in n:
		var row: Array = []
		for x in n:
			row.append(1 if clockwise else 0)
		out.append(row)
	for y in n:
		for x in n:
			if clockwise:
				out[y][x] = int((matrix[n - 1 - x] as Array)[y])
			else:
				out[y][x] = int((matrix[x] as Array)[n - 1 - y])
	return out


## How many cells of the matrix are set — the invariant a rotation must keep.
static func cell_count(matrix: Array) -> int:
	var count := 0
	for row in matrix:
		for value in row:
			if int(value) != 0:
				count += 1
	return count


## The state a turn out of `state` leads to: 0 -> R -> 2 -> L -> 0 clockwise, and
## back the other way anticlockwise.
static func next_state(state: int, clockwise: bool) -> int:
	return posmod(state + (1 if clockwise else 3), 4)


## The short name the tables and the HUD use for a state.
static func state_name(state: int) -> String:
	return ["0", "R", "2", "L"][posmod(state, 4)]


## The five kick offsets of one turn, in board coordinates: x to the right, y
## downwards. Empty for a half turn: the guideline tabulates the four quarter
## turns, and the game only ever turns a quarter (`next_state` steps by one).
static func kicks(piece_type: int, from_state: int, to_state: int) -> Array[Vector2i]:
	var table: Dictionary = KICKS_I if piece_type == I_PIECE_TYPE else KICKS_JLSTZ
	var entries: Array = table.get("%d>%d" % [from_state, to_state], [])
	var out: Array[Vector2i] = []
	for entry in entries:
		out.append(Vector2i(int(entry[0]), -int(entry[1])))
	return out


## True for the eight quarter turns, the only ones the tables describe.
static func is_quarter_turn(from_state: int, to_state: int) -> bool:
	var step := posmod(to_state - from_state, 4)
	return step == 1 or step == 3


## A kick in words, for the hint in the HUD: "Kick ↓2" or "ohne Kick".
static func kick_text(kick: Vector2i) -> String:
	if kick == Vector2i.ZERO:
		return "ohne Kick"
	var parts: Array[String] = []
	if kick.x < 0:
		parts.append("←%d" % -kick.x)
	elif kick.x > 0:
		parts.append("→%d" % kick.x)
	if kick.y < 0:
		parts.append("↑%d" % -kick.y)
	elif kick.y > 0:
		parts.append("↓%d" % kick.y)
	return "Kick " + "+".join(parts)


## The topmost row of the matrix that holds a block, or the matrix height when it
## is empty.
static func top_row(matrix: Array) -> int:
	for y in matrix.size():
		for value in matrix[y] as Array:
			if int(value) != 0:
				return y
	return matrix.size()


## True when the piece may stand there: clear of the walls and the floor, and not
## lifted out over the ceiling. `collides` answers the first part — the screen
## passes its own `_collides`, which treats the space above the well as free, so
## an upward kick has to be stopped here.
static func _fits(matrix: Array, x: int, y: int, collides: Callable) -> bool:
	if y + top_row(matrix) < 0:
		return false
	return not bool(collides.call(matrix, x, y))


## Plan a turn. The first kick that fits wins, exactly as the guideline asks, so
## the same call both moves the piece and tells the player which offset paid off.
## Empty when the piece cannot be turned at all — then the screen leaves it be.
static func plan_rotation(piece_type: int, state: int, x: int, y: int, matrix: Array, clockwise: bool, collides: Callable) -> Dictionary:
	var to_state := next_state(state, clockwise)
	var turned := rotate_matrix(matrix, clockwise)
	for kick in kicks(piece_type, state, to_state):
		var nx := x + kick.x
		var ny := y + kick.y
		if not _fits(turned, nx, ny, collides):
			continue
		return {"matrix": turned, "x": nx, "y": ny, "state": to_state, "kick": kick}
	return {}


## How far the piece falls from `(x, y)`, in rows.
static func drop_distance(matrix: Array, x: int, y: int, collides: Callable) -> int:
	var distance := 0
	while _fits(matrix, x, y + distance + 1, collides):
		distance += 1
	return distance


## How many rows the piece would complete where it stands: a row becomes full
## when the piece covers exactly the cells that were still empty. `row_holes` is
## the well's free cells per row, so the preview needs no copy of the board.
static func rows_completed(matrix: Array, x: int, y: int, row_holes: Array) -> int:
	var per_row := {}
	for py in matrix.size():
		for px in (matrix[py] as Array).size():
			if int((matrix[py] as Array)[px]) == 0:
				continue
			var row: int = y + int(py)
			if row < 0:
				continue
			per_row[row] = int(per_row.get(row, 0)) + 1
	var cleared := 0
	for row in per_row:
		var cells := int(per_row[row])
		if cells > 0 and row < row_holes.size() and int(row_holes[row]) == cells:
			cleared += 1
	return cleared


## The name a T-Spin gets, e.g. "T-Spin Double".
static func spin_name(spin: String, rows: int) -> String:
	var name := "T-Spin Mini" if spin == "mini" else "T-Spin"
	if rows > 0:
		name += " " + ["", "Single", "Double", "Triple", "Quad"][clampi(rows, 1, 4)]
	return name


## The turn the player should make *right now* to score a T-Spin, and the place
## the piece would come to rest afterwards. Empty when neither turn spins.
##
## This is what turns the kick tables from hidden plumbing into a decision: a
## player no longer has to know them by heart to see that the T fits into the
## notch. The turn with the most rows wins, a full spin beating a mini, and the
## result carries the kick so the board can draw the landing spot.
static func spin_preview(piece_type: int, state: int, x: int, y: int, matrix: Array, row_holes: Array, filled_at: Callable, collides: Callable) -> Dictionary:
	if piece_type != T_PIECE_TYPE:
		return {}
	var best := {}
	var best_rows := -1
	var best_full := false
	for clockwise in [true, false]:
		var plan := plan_rotation(piece_type, state, x, y, matrix, clockwise, collides)
		if plan.is_empty():
			continue
		var landing: int = int(plan["y"]) + drop_distance(plan["matrix"], int(plan["x"]), int(plan["y"]), collides)
		var corners := t_corners(int(plan["x"]), landing, filled_at)
		if not is_t_spin(piece_type, true, corners):
			continue
		var full := not is_t_spin_mini(corners)
		var rows := rows_completed(plan["matrix"], int(plan["x"]), landing, row_holes)
		if rows < best_rows or (rows == best_rows and best_full and not full):
			continue
		best_rows = rows
		best_full = full
		var spin := "full" if full else "mini"
		best = {
			"matrix": plan["matrix"],
			"x": int(plan["x"]),
			"y": landing,
			"from_state": state,
			"state": int(plan["state"]),
			"kick": plan["kick"],
			"spin": spin,
			"rows": rows,
			"label": "%s  ·  %s→%s  %s" % [
				spin_name(spin, rows),
				state_name(state),
				state_name(int(plan["state"])),
				kick_text(plan["kick"]),
			],
		}
	return best
