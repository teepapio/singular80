class_name TetrisRules
extends RefCounted
## Scoring, T-Spin detection and board-threat rules for Tetris.
##
## The screen owns the animation; everything that decides *whether a move was
## skilful and what it is worth* lives here so it can be unit tested without a
## viewport.
##
## Reference: the modern Tetris Guideline scoring model (T-Spin via the
## three-corner rule, Back-to-Back for difficult clears, combo for consecutive
## line clears).

## `TetrisScreen.PIECES` index of the T piece.
const T_PIECE_TYPE := 5

## Points for a line clear before level and difficulty bonuses.
const LINE_SCORES: Array[int] = [0, 100, 300, 500, 800]

## T-Spin line-clear bases. Index = lines cleared, so a T-Spin triple pays 1600.
const TSPIN_SCORES: Array[int] = [400, 800, 1200, 1600]

## Extra points per Back-to-Back step (50, 100, 200, …).
const B2B_STEP := 50

## Points per combo step (50, 100, 150, …).
const COMBO_STEP := 50

## How many upcoming pieces the queue may show.
const PREVIEW_OPTIONS: Array[int] = [3, 4, 5, 6]

## The well counts as "tower grows" above this fill ratio …
const DANGER_RATIO := 0.62

## … and as critical above this one.
const CRITICAL_RATIO := 0.82


## True when a T-Spin counts as such: the last move was a rotation, the piece is
## a T, and at least three of the four corners of the T's 3×3 box are occupied.
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


## Corner occupancy of a T's 3×3 box, as a 2×2 array of booleans.
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
## `lines` 0–4, `level` the current level, `combo` the number of *previous*
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
		return "Der Turm wächst  ·  %d freie Reihen" % free
	return "GEFAHR!  Nur noch %d freie Reihen" % free


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
