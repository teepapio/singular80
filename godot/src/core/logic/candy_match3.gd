class_name CandyMatch3
extends RefCounted
## Logic for "Candy Crush 3D" — a match-3 with themed worlds and a generated
## level ladder.
##
## The board is a flat grid of {@link COLS} × {@link ROWS} cells. Every cell has
## a kind (open, hole, icing, stone), an optional candy with a colour and a
## special kind, and the remaining blocker layers. A board is a Dictionary of
## four `Array` columns so the whole state can be copied cheaply for
## the undo stack.
##
## Levels are *generated* deterministically from `(world, index)`, which is what
## makes a huge level count cheap: 6 worlds × {@link LEVELS_PER_WORLD} levels.
## The random source is an explicit seeded generator, so the same key always
## produces the same level — on every device and in the tests.
##
## Two special candies that are swapped into each other are worth more together
## than apart; which combination that is follows from the two kinds alone
## ({@link combo_kind}) and the blast always runs through the cell the player
## dragged to ({@link combo_blast}). The screen shows that blast on the board
## while a special is selected, so the table can be read instead of guessed.

# --- board geometry ---------------------------------------------------------
const COLS := 8
const ROWS := 9
const CELL_COUNT := 72

# --- cell kinds -------------------------------------------------------------
const KIND_HOLE := 0
const KIND_OPEN := 1
## Frosted block: cracks from matches in its neighbourhood.
const KIND_ICING := 2
## Hard block: only special blasts break it.
const KIND_STONE := 3

# --- special candies --------------------------------------------------------
const SPECIAL_NONE := 0
## Horizontal stripes — activating it clears the whole row.
const SPECIAL_ROW := 1
## Vertical stripes — activating it clears the whole column.
const SPECIAL_COL := 2
## Wrapped — activating it blows up the 3×3 area around it.
const SPECIAL_WRAPPED := 3
## Colour bomb — swapping it clears every candy of the other candy's colour.
const SPECIAL_BOMB := 4

const NO_CANDY := -1

const MAX_STARS := 3


# --- indexing ---------------------------------------------------------------

static func cell_index(col: int, row: int) -> int:
	return row * COLS + col


static func col_of(cell: int) -> int:
	return cell % COLS


static func row_of(cell: int) -> int:
	return int(floor(float(cell) / float(COLS)))


static func cell_x(col: int) -> float:
	return float(col) - float(COLS - 1) * 0.5


static func cell_y(row: int) -> float:
	return float(row) - float(ROWS - 1) * 0.5


## Are the two cells orthogonal neighbours?
static func are_neighbours(a: int, b: int) -> bool:
	return absi(col_of(a) - col_of(b)) + absi(row_of(a) - row_of(b)) == 1


static func special_name(special: int) -> String:
	match special:
		SPECIAL_ROW:
			return "Streifen-Bonbon (Reihe)"
		SPECIAL_COL:
			return "Streifen-Bonbon (Spalte)"
		SPECIAL_WRAPPED:
			return "Verpacktes Bonbon"
		SPECIAL_BOMB:
			return "Farbbombe"
		_:
			return "Bonbon"


static func is_striped(special: int) -> bool:
	return special == SPECIAL_ROW or special == SPECIAL_COL


# --- seeded random ----------------------------------------------------------

## Deterministic PRNG (mulberry32).
##
## A small class and not a lambda on purpose: GDScript captures lambda
## variables by value, so a closure would restart from its initial state on
## every call and the refill would always deal the same colour again.
class Rng extends RefCounted:
	var state: int = 0

	func _init(seed_value: int) -> void:
		state = seed_value & 0xFFFFFFFF


	func next_float() -> float:
		state = (state + 0x6D2B79F5) & 0xFFFFFFFF
		var t: int = state
		t = ((t ^ (t >> 15)) * (t | 1)) & 0xFFFFFFFF
		t = (t + (((t ^ (t >> 7)) * (t | 61)) & 0xFFFFFFFF)) & 0xFFFFFFFF
		return float((t ^ (t >> 14)) & 0xFFFFFFFF) / 4294967296.0


## Mulberry32, so a level is reproducible from its seed alone.
static func mulberry32(seed_value: int) -> Rng:
	return Rng.new(seed_value)


## Stable 32-bit hash of a string — turns world/level keys into seeds.
static func hash_string(value: String) -> int:
	var hash_value := 0x811C9DC5
	for i in value.length():
		hash_value = (hash_value ^ value.unicode_at(i)) & 0xFFFFFFFF
		hash_value = (hash_value * 0x01000193) & 0xFFFFFFFF
	return hash_value & 0x7FFFFFFF


static func random_int(rng: Rng, max_exclusive: int) -> int:
	if max_exclusive <= 0:
		return 0
	return clampi(int(rng.next_float() * float(max_exclusive)), 0, max_exclusive - 1)


# --- board ------------------------------------------------------------------

## Builds a board from a layout mask. One string per row, `#` is an open cell and
## `.` is a hole (no candy ever falls through it).
static func create_board(layout: Array) -> Dictionary:
	var kind: Array = []
	kind.resize(CELL_COUNT)
	kind.fill(KIND_HOLE)
	for row in ROWS:
		var line := str(layout[row]) if row < layout.size() else ""
		for col in COLS:
			if line.length() > col and line[col] == "#":
				kind[cell_index(col, row)] = KIND_OPEN
	var layers: Array = []
	layers.resize(CELL_COUNT)
	layers.fill(0)
	var colors: Array = []
	colors.resize(CELL_COUNT)
	colors.fill(NO_CANDY)
	var specials: Array = []
	specials.resize(CELL_COUNT)
	specials.fill(SPECIAL_NONE)
	return {"kind": kind, "layers": layers, "colors": colors, "specials": specials}


static func clone_board(board: Dictionary) -> Dictionary:
	return {
		"kind": (board["kind"] as Array).duplicate(),
		"layers": (board["layers"] as Array).duplicate(),
		"colors": (board["colors"] as Array).duplicate(),
		"specials": (board["specials"] as Array).duplicate(),
	}


static func has_candy(board: Dictionary, cell: int) -> bool:
	return (board["kind"] as Array)[cell] == KIND_OPEN and (board["colors"] as Array)[cell] != NO_CANDY


static func open_cells(board: Dictionary) -> Array:
	var out: Array = []
	var kind: Array = board["kind"]
	for cell in kind.size():
		if kind[cell] == KIND_OPEN:
			out.append(cell)
	return out


static func blocker_cells(board: Dictionary) -> Array:
	var out: Array = []
	var kind: Array = board["kind"]
	for cell in kind.size():
		if kind[cell] == KIND_ICING or kind[cell] == KIND_STONE:
			out.append(cell)
	return out


static func set_candy(board: Dictionary, cell: int, color: int, special: int = SPECIAL_NONE) -> void:
	(board["colors"] as Array)[cell] = color
	(board["specials"] as Array)[cell] = special


static func clear_candy(board: Dictionary, cell: int) -> void:
	(board["colors"] as Array)[cell] = NO_CANDY
	(board["specials"] as Array)[cell] = SPECIAL_NONE


# --- matching ---------------------------------------------------------------

## Every horizontal and vertical run of three or more equal candies.
## Entries are `{cells, horizontal, color}`.
static func find_runs(board: Dictionary) -> Array:
	var runs: Array = []
	var colors: Array = board["colors"]
	for row in ROWS:
		var start := 0
		var color := NO_CANDY
		for col in COLS + 1:
			var value := NO_CANDY
			if col < COLS:
				var cell := cell_index(col, row)
				if has_candy(board, cell):
					value = colors[cell]
			if value != NO_CANDY and value == color:
				continue
			if color != NO_CANDY and col - start >= 3:
				var cells: Array = []
				for i in range(start, col):
					cells.append(cell_index(i, row))
				runs.append({"cells": cells, "horizontal": true, "color": color})
			start = col
			color = value
	for col in COLS:
		var start := 0
		var color := NO_CANDY
		for row in ROWS + 1:
			var value := NO_CANDY
			if row < ROWS:
				var cell := cell_index(col, row)
				if has_candy(board, cell):
					value = colors[cell]
			if value != NO_CANDY and value == color:
				continue
			if color != NO_CANDY and row - start >= 3:
				var cells: Array = []
				for i in range(start, row):
					cells.append(cell_index(col, i))
				runs.append({"cells": cells, "horizontal": false, "color": color})
			start = row
			color = value
	return runs


static func has_any_match(board: Dictionary) -> bool:
	return not find_runs(board).is_empty()


## Groups overlapping runs and derives the special candy each group creates.
## Entries: `{cells, color, special, createAt, runLength}`.
static func merge_runs(runs: Array, prefer: Array = []) -> Array:
	var groups: Array = []
	var claimed: Array = []
	for i in runs.size():
		claimed.append(false)

	for seed_index in runs.size():
		if claimed[seed_index]:
			continue
		claimed[seed_index] = true
		var members: Array = [runs[seed_index]]
		var grew := true
		while grew:
			grew = false
			for i in runs.size():
				if claimed[i]:
					continue
				var shares := false
				for member in members:
					for cell in (member as Dictionary)["cells"]:
						if ((runs[i] as Dictionary)["cells"] as Array).has(cell):
							shares = true
							break
					if shares:
						break
				if not shares:
					continue
				claimed[i] = true
				members.append(runs[i])
				grew = true

		var cell_set := {}
		var horizontal: Array = []
		var vertical: Array = []
		var longest := 0
		for member in members:
			var run: Dictionary = member
			for cell in run["cells"]:
				cell_set[cell] = true
			longest = maxi(longest, (run["cells"] as Array).size())
			if run["horizontal"]:
				horizontal.append(run)
			else:
				vertical.append(run)
		var all: Array = cell_set.keys()
		all.sort()

		var special := SPECIAL_NONE
		if longest >= 5:
			special = SPECIAL_BOMB
		elif not horizontal.is_empty() and not vertical.is_empty():
			special = SPECIAL_WRAPPED
		elif longest == 4:
			var run4: Dictionary = horizontal[0] if not horizontal.is_empty() else vertical[0]
			special = SPECIAL_COL if run4["horizontal"] else SPECIAL_ROW

		var create_at: int = all[all.size() / 2]
		var chosen := -1
		for cell in prefer:
			if cell_set.has(cell):
				chosen = cell
				break
		if chosen < 0 and not horizontal.is_empty() and not vertical.is_empty():
			for cell in (horizontal[0]["cells"] as Array):
				if (vertical[0]["cells"] as Array).has(cell):
					chosen = cell
					break
		if chosen >= 0:
			create_at = chosen

		groups.append({
			"cells": all.duplicate(),
			"color": (runs[seed_index] as Dictionary)["color"],
			"special": special,
			"createAt": create_at,
			"runLength": longest,
		})
	return groups


## Cells a special candy clears when it goes off.
static func blast_cells(board: Dictionary, cell: int, out: Array, seen: Dictionary) -> void:
	var col := col_of(cell)
	var row := row_of(cell)
	var special: int = (board["specials"] as Array)[cell]
	if special == SPECIAL_ROW:
		for c in COLS:
			_add_unique(out, seen, cell_index(c, row))
		return
	if special == SPECIAL_COL:
		for r in ROWS:
			_add_unique(out, seen, cell_index(col, r))
		return
	if special == SPECIAL_WRAPPED:
		for dr in range(-1, 2):
			for dc in range(-1, 2):
				var c := col + dc
				var r := row + dr
				if c < 0 or c >= COLS or r < 0 or r >= ROWS:
					continue
				_add_unique(out, seen, cell_index(c, r))
		return
	if special == SPECIAL_BOMB:
		var colors: Array = board["colors"]
		for other in colors.size():
			if colors[other] == colors[cell]:
				_add_unique(out, seen, other)


static func _add_unique(out: Array, seen: Dictionary, cell: int) -> void:
	if cell < 0 or cell >= CELL_COUNT or seen.has(cell):
		return
	seen[cell] = true
	out.append(cell)


static func _damage_blocker(board: Dictionary, cell: int) -> String:
	var layers: Array = board["layers"]
	var kind: Array = board["kind"]
	if layers[cell] <= 0 or (kind[cell] != KIND_ICING and kind[cell] != KIND_STONE):
		return ""
	layers[cell] -= 1
	if layers[cell] > 0:
		return "hit"
	kind[cell] = KIND_OPEN
	layers[cell] = 0
	return "broken"


## Lets candies fall into the gaps of their column. Holes and blockers stop the
## fall, exactly like a solid board cell. Returns `[{from, to}, …]`.
static func apply_gravity(board: Dictionary) -> Array:
	var moves: Array = []
	var kind: Array = board["kind"]
	var colors: Array = board["colors"]
	var specials: Array = board["specials"]
	for col in COLS:
		var write_row := ROWS - 1
		for row in range(ROWS - 1, -1, -1):
			var cell := cell_index(col, row)
			if kind[cell] != KIND_OPEN:
				write_row = row - 1
				continue
			if colors[cell] == NO_CANDY:
				continue
			var target := cell_index(col, write_row)
			if target != cell:
				colors[target] = colors[cell]
				specials[target] = specials[cell]
				colors[cell] = NO_CANDY
				specials[cell] = SPECIAL_NONE
				moves.append({"from": cell, "to": target})
			write_row -= 1
	return moves


## Fills every empty open cell with a random candy. Returns the refilled cells.
static func refill(board: Dictionary, color_count: int, rng: Rng) -> Array:
	var spawned: Array = []
	var kind: Array = board["kind"]
	var colors: Array = board["colors"]
	for cell in CELL_COUNT:
		if kind[cell] != KIND_OPEN or colors[cell] != NO_CANDY:
			continue
		colors[cell] = random_int(rng, maxi(1, color_count))
		(board["specials"] as Array)[cell] = SPECIAL_NONE
		spawned.append(cell)
	return spawned


# --- resolution -------------------------------------------------------------

## Resolves one step of a move: matches, special blasts, blocker damage, gravity
## and refill. Returns `{}` when the board is stable (no match left).
##
## Options: `chain`, `colorCount`, `prefer`, `forceSpecial`, `blast`.
static func resolve_step(board: Dictionary, rng: Rng, options: Dictionary = {}) -> Dictionary:
	var chain: int = int(options.get("chain", 1))
	var color_count: int = int(options.get("colorCount", 6))
	var force_special: int = int(options.get("forceSpecial", SPECIAL_NONE))
	var force_set: bool = options.has("forceSpecial")
	var prefer: Array = options.get("prefer", [])
	var blast_input: Array = options.get("blast", [])

	var groups: Array = []
	if force_set and force_special == SPECIAL_NONE and blast_input.is_empty():
		pass
	else:
		groups = merge_runs(find_runs(board), prefer)
	if groups.is_empty() and blast_input.is_empty():
		return {}

	var cleared: Array = []
	var clear_seen := {}
	var created: Array = []
	var created_cells := {}
	var damage: Array = []
	var damage_seen := {}

	for cell in blast_input:
		_add_unique(cleared, clear_seen, cell)
	for group in groups:
		for cell in (group as Dictionary)["cells"]:
			_add_unique(cleared, clear_seen, cell)

	var score := 0.0
	for group in groups:
		var cells: Array = (group as Dictionary)["cells"]
		score += float(cells.size()) * 60.0 + float(maxi(0, int((group as Dictionary)["runLength"]) - 3)) * 20.0
		var special: int = (group as Dictionary)["special"]
		if force_set:
			special = force_special
		var create_at: int = int((group as Dictionary)["createAt"])
		if special != SPECIAL_NONE and not created_cells.has(create_at):
			created_cells[create_at] = true
			created.append({"cell": create_at, "color": (group as Dictionary)["color"], "special": special})
			score += 200.0

	# Chain reactions: every special that gets cleared goes off as well.
	var specials: Array = board["specials"]
	var kind: Array = board["kind"]
	var layers: Array = board["layers"]
	var queue: Array = (cleared as Array).duplicate()
	var handled := {}
	while not queue.is_empty():
		var cell: int = queue[queue.size() - 1]
		queue.remove_at(queue.size() - 1)
		if handled.has(cell):
			continue
		handled[cell] = true
		if not has_candy(board, cell):
			# A blast reached a cell without candy — only blockers stand there.
			if layers[cell] > 0 and not damage_seen.has(cell):
				damage_seen[cell] = true
				damage.append({"cell": cell, "direct": true})
			continue
		if specials[cell] != SPECIAL_NONE:
			var extra: Array = []
			blast_cells(board, cell, extra, {})
			score += 40.0 * float(extra.size())
			for other in extra:
				if not clear_seen.has(other):
					_add_unique(cleared, clear_seen, other)
					queue.append(other)
		# Icing cracks when a match happens right next to it.
		var col := col_of(cell)
		var row := row_of(cell)
		for dr in range(-1, 2):
			for dc in range(-1, 2):
				if dr == 0 and dc == 0:
					continue
				var c := col + dc
				var r := row + dr
				if c < 0 or c >= COLS or r < 0 or r >= ROWS:
					continue
				var other := cell_index(c, r)
				if kind[other] != KIND_ICING or damage_seen.has(other):
					continue
				damage_seen[other] = true
				damage.append({"cell": other, "direct": false})

	var blockers_hit: Array = []
	var blockers_broken: Array = []
	for entry in damage:
		var cell: int = int((entry as Dictionary)["cell"])
		if not bool((entry as Dictionary)["direct"]) and kind[cell] == KIND_STONE:
			continue
		match _damage_blocker(board, cell):
			"hit":
				blockers_hit.append(cell)
				score += 40.0
			"broken":
				blockers_broken.append(cell)
				score += 120.0

	var cleared_colors: Array = []
	var colors: Array = board["colors"]
	for cell in cleared:
		if created_cells.has(cell):
			continue
		if has_candy(board, cell):
			cleared_colors.append(colors[cell])
			score += 60.0
		colors[cell] = NO_CANDY
		specials[cell] = SPECIAL_NONE
	for entry in created:
		set_candy(board, int((entry as Dictionary)["cell"]), int((entry as Dictionary)["color"]), int((entry as Dictionary)["special"]))

	return {
		"cleared": cleared,
		"clearedColors": cleared_colors,
		"blockersHit": blockers_hit,
		"blockersBroken": blockers_broken,
		"created": created,
		"fell": apply_gravity(board),
		"spawned": refill(board, color_count, rng),
		"chain": chain,
		"score": int(round(score * (1.0 + float(chain - 1) * 0.5))),
	}


# --- combinations ------------------------------------------------------------

## Two special candies swapped into each other are worth more together than
## apart. Which combination that is follows from the two kinds alone, and the
## blast always runs through the cell the player dragged to — the pair on screen
## is the pair that goes off.
const COMBO_NONE := 0
## Two colour bombs: the whole board.
const COMBO_BOMB := 1
## Colour bomb + plain candy: every candy of that colour.
const COMBO_COLOUR := 2
## Colour bomb + striped: the whole colour turns striped and goes off.
const COMBO_FUSE := 3
## Colour bomb + wrapped: the whole colour turns wrapped and goes off.
const COMBO_STORM := 4
## Wrapped + wrapped: a five by five detonation.
const COMBO_SQUARE := 5
## Wrapped + striped: three rows and three columns.
const COMBO_CROSS := 6
## Two stripes of the same kind: three lines of that direction.
const COMBO_LINES := 7
## A row stripe and a column stripe: three rows *and* three columns.
const COMBO_STAR := 8


## The combination two special kinds form, or {@link COMBO_NONE} when they form
## none — a special swapped with a plain candy is an ordinary match, and two
## specials always combine.
static func combo_kind(special_a: int, special_b: int) -> int:
	var has_bomb: bool = special_a == SPECIAL_BOMB or special_b == SPECIAL_BOMB
	if has_bomb:
		if special_a == SPECIAL_BOMB and special_b == SPECIAL_BOMB:
			return COMBO_BOMB
		if special_a == SPECIAL_WRAPPED or special_b == SPECIAL_WRAPPED:
			return COMBO_STORM
		if is_striped(special_a) or is_striped(special_b):
			return COMBO_FUSE
		return COMBO_COLOUR
	if special_a == SPECIAL_WRAPPED and special_b == SPECIAL_WRAPPED:
		return COMBO_SQUARE
	if special_a == SPECIAL_WRAPPED or special_b == SPECIAL_WRAPPED:
		return COMBO_CROSS
	if is_striped(special_a) and is_striped(special_b):
		return COMBO_LINES if special_a == special_b else COMBO_STAR
	return COMBO_NONE


## Every combination has its own name, because a player should be able to learn
## the table by name instead of memorising silhouettes.
static func combo_name(kind: int) -> String:
	match kind:
		COMBO_BOMB:
			return "Farbflut"
		COMBO_COLOUR:
			return "Farbwelle"
		COMBO_FUSE:
			return "Zündschnur"
		COMBO_STORM:
			return "Farbsturm"
		COMBO_SQUARE:
			return "Detonation"
		COMBO_CROSS:
			return "Kreuzfeuer"
		COMBO_LINES:
			return "Dreifachblitz"
		COMBO_STAR:
			return "Blitzkreuz"
		_:
			return ""


## The `width` full lines through `cell` — its row for a horizontal stripe, its
## column for a vertical one. `width` 1 is a single stripe, 3 the combination
## that also takes the neighbouring line on each side.
static func _line_cells(cell: int, row_lines: bool, width: int) -> Array:
	var out: Array = []
	var col := col_of(cell)
	var row := row_of(cell)
	var reach := int(width / 2)
	for offset in range(-reach, reach + 1):
		if row_lines:
			var r := row + offset
			if r < 0 or r >= ROWS:
				continue
			for c in COLS:
				out.append(cell_index(c, r))
			continue
		var c := col + offset
		if c < 0 or c >= COLS:
			continue
		for r in ROWS:
			out.append(cell_index(c, r))
	return out


## The square of `radius` cells around `cell`, clipped to the board.
static func _area_cells(cell: int, radius: int) -> Array:
	var out: Array = []
	var col := col_of(cell)
	var row := row_of(cell)
	for dr in range(-radius, radius + 1):
		for dc in range(-radius, radius + 1):
			var c := col + dc
			var r := row + dr
			if c < 0 or c >= COLS or r < 0 or r >= ROWS:
				continue
			out.append(cell_index(c, r))
	return out


## The cells the combination of the special candies at `a` and `b` clears, or an
## empty array when they form none. The blast is centred on `b`, so call it with
## the cell the player dragged *to* as `b` — and before the swap, to see it.
static func combo_blast(board: Dictionary, a: int, b: int) -> Array:
	var specials: Array = board["specials"]
	var colors: Array = board["colors"]
	var kind := combo_kind(specials[a], specials[b])
	if kind == COMBO_NONE:
		return Array()
	var blast: Array = []
	var seen := {}
	match kind:
		COMBO_BOMB:
			for cell in CELL_COUNT:
				_add_unique(blast, seen, cell)
		COMBO_COLOUR, COMBO_FUSE, COMBO_STORM:
			# The partner's colour decides. The bomb itself always goes with it,
			# whatever colour of its own it wears.
			var partner: int = b if specials[a] == SPECIAL_BOMB else a
			var color: int = int(colors[partner])
			for cell in CELL_COUNT:
				if int(colors[cell]) == color:
					_add_unique(blast, seen, cell)
			_add_unique(blast, seen, a if specials[a] == SPECIAL_BOMB else b)
		COMBO_SQUARE:
			for cell in _area_cells(b, 2):
				_add_unique(blast, seen, cell)
		COMBO_CROSS, COMBO_STAR:
			for cell in _line_cells(b, true, 3):
				_add_unique(blast, seen, cell)
			for cell in _line_cells(b, false, 3):
				_add_unique(blast, seen, cell)
		COMBO_LINES:
			# Both stripes point the same way, so the lines run the way they do.
			var row_lines: bool = specials[a] == SPECIAL_ROW or specials[b] == SPECIAL_ROW
			for cell in _line_cells(b, row_lines, 3):
				_add_unique(blast, seen, cell)
	return blast


# --- swaps ------------------------------------------------------------------


static func swap_cells(board: Dictionary, a: int, b: int) -> void:
	var colors: Array = board["colors"]
	var specials: Array = board["specials"]
	var color: int = colors[a]
	var special: int = specials[a]
	colors[a] = colors[b]
	specials[a] = specials[b]
	colors[b] = color
	specials[b] = special


## Does the board have a run of three or more through `cell`?
static func matches_at(board: Dictionary, cell: int) -> bool:
	if not has_candy(board, cell):
		return false
	var colors: Array = board["colors"]
	var color: int = colors[cell]
	var col := col_of(cell)
	var row := row_of(cell)
	var horizontal := 1
	var vertical := 1
	for c in range(col - 1, -1, -1):
		var other := cell_index(c, row)
		if not has_candy(board, other) or colors[other] != color:
			break
		horizontal += 1
	for c in range(col + 1, COLS):
		var other := cell_index(c, row)
		if not has_candy(board, other) or colors[other] != color:
			break
		horizontal += 1
	for r in range(row - 1, -1, -1):
		var other := cell_index(col, r)
		if not has_candy(board, other) or colors[other] != color:
			break
		vertical += 1
	for r in range(row + 1, ROWS):
		var other := cell_index(col, r)
		if not has_candy(board, other) or colors[other] != color:
			break
		vertical += 1
	return horizontal >= 3 or vertical >= 3


## The move the player tried. Returns `{}` when the swap is illegal (the board is
## left untouched). Otherwise `{step, cells, combo}`.
static func try_swap(board: Dictionary, a: int, b: int, rng: Rng, color_count: int) -> Dictionary:
	if not are_neighbours(a, b):
		return {}
	if not has_candy(board, a) or not has_candy(board, b):
		return {}
	swap_cells(board, a, b)

	var specials: Array = board["specials"]
	var colors: Array = board["colors"]
	var combo := combo_kind(specials[a], specials[b])
	var blast := combo_blast(board, a, b)

	if blast.is_empty():
		if not matches_at(board, a) and not matches_at(board, b):
			swap_cells(board, a, b)
			return {}
	elif combo == COMBO_FUSE or combo == COMBO_STORM:
		# The colour bomb hands its special down to the whole colour before
		# everything goes off — a wrapped partner stays wrapped instead of
		# being watered down to a stripe.
		var bomb: int = a if specials[a] == SPECIAL_BOMB else b
		var other: int = b if bomb == a else a
		var color: int = int(colors[other])
		var spread: int = SPECIAL_WRAPPED if combo == COMBO_STORM else int(specials[other])
		for cell in CELL_COUNT:
			if cell == other or int(colors[cell]) != color:
				continue
			specials[cell] = spread

	var is_combo := not blast.is_empty()
	var options := {"chain": 1, "colorCount": color_count, "blast": blast}
	if is_combo:
		# A combo blast must not create another special on top.
		options["forceSpecial"] = SPECIAL_NONE
		options["prefer"] = []
	else:
		options["prefer"] = [b, a]
	var step := resolve_step(board, rng, options)
	if step.is_empty():
		swap_cells(board, a, b)
		return {}
	return {"step": step, "cells": [a, b], "combo": combo}


# --- move availability ------------------------------------------------------

static func _is_legal_swap(board: Dictionary, a: int, b: int) -> bool:
	if not has_candy(board, a) or not has_candy(board, b):
		return false
	swap_cells(board, a, b)
	var specials: Array = board["specials"]
	var legal: bool = (specials[a] != SPECIAL_NONE and specials[b] != SPECIAL_NONE) or matches_at(board, a) or matches_at(board, b)
	swap_cells(board, a, b)
	return legal


static func has_valid_swap(board: Dictionary) -> bool:
	for cell in CELL_COUNT:
		if not has_candy(board, cell):
			continue
		var col := col_of(cell)
		var row := row_of(cell)
		for step: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var c: int = col + step.x
			var r: int = row + step.y
			if c < 0 or c >= COLS or r < 0 or r >= ROWS:
				continue
			if _is_legal_swap(board, cell, cell_index(c, r)):
				return true
	return false


## Every legal swap as `[{a, b}, …]`.
static func find_valid_swaps(board: Dictionary, limit: int = 4096) -> Array:
	var found: Array = []
	for cell in CELL_COUNT:
		if not has_candy(board, cell):
			continue
		var col := col_of(cell)
		var row := row_of(cell)
		for step: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var c: int = col + step.x
			var r: int = row + step.y
			if c < 0 or c >= COLS or r < 0 or r >= ROWS:
				continue
			var other := cell_index(c, r)
			if not _is_legal_swap(board, cell, other):
				continue
			found.append({"a": cell, "b": other})
			if found.size() >= limit:
				return found
	return found


## Re-deals the candies until the board neither matches right away nor offers a
## move. Returns `false` when the board cannot be saved (too empty).
static func shuffle_board(board: Dictionary, rng: Rng, color_count: int, attempts: int = 40) -> bool:
	var cells: Array = []
	for cell in open_cells(board):
		if (board["colors"] as Array)[cell] != NO_CANDY:
			cells.append(cell)
	if cells.size() < 3:
		return false
	var colors: Array = board["colors"]
	var specials: Array = board["specials"]
	for attempt in attempts:
		var pool: Array = []
		for cell in cells:
			pool.append({"color": colors[cell], "special": specials[cell]})
		for i in range(pool.size() - 1, 0, -1):
			var j := random_int(rng, i + 1)
			var swap: Dictionary = pool[i]
			pool[i] = pool[j]
			pool[j] = swap
		for i in cells.size():
			set_candy(board, cells[i], int((pool[i] as Dictionary)["color"]), int((pool[i] as Dictionary)["special"]))
		if not has_any_match(board) and has_valid_swap(board):
			return true
	for attempt in attempts:
		for cell in cells:
			set_candy(board, cell, random_int(rng, color_count), SPECIAL_NONE)
		if not has_any_match(board) and has_valid_swap(board):
			return true
	# Last resort: a greedy deal that cannot create a match in the first place.
	for attempt in attempts:
		_fill_match_free(board, color_count, rng)
		for cell in cells:
			if int((board["specials"] as Array)[cell]) != SPECIAL_NONE:
				set_candy(board, cell, int((board["colors"] as Array)[cell]), SPECIAL_NONE)
		if not has_any_match(board) and has_valid_swap(board):
			return true
	return false


# --- worlds and level generation -------------------------------------------

const LEVELS_PER_WORLD := 40

const LAYOUT_FULL: Array = [
	"########",
	"########",
	"########",
	"########",
	"########",
	"########",
	"########",
	"########",
	"########",
]

## Board masks the generator picks from (see {@link create_board}).
const LAYOUTS: Array = [
	LAYOUT_FULL,
	[
		"##....##", "##....##", "########", "########", "########",
		"########", "########", "##....##", "##....##",
	],
	[
		"..####..", "..####..", "########", "########", "########",
		"########", "########", "..####..", "..####..",
	],
	[
		"########", "##..####", "##..####", "####..##", "####..##",
		"##..####", "##..####", "####..##", "####..##",
	],
	[
		"########", ".######.", "..####..", "..####..", "...##...",
		"..####..", "..####..", ".######.", "########",
	],
	[
		"########", "##.##.##", "########", "##.##.##", "########",
		"##.##.##", "########", "##.##.##", "########",
	],
	[
		"........", ".######.", ".######.", ".######.", ".######.",
		".######.", ".######.", ".######.", "........",
	],
	[
		"########", "###..###", "###..###", "###..###", "###..###",
		"###..###", "###..###", "###..###", "########",
	],
]

## Every world: six board colours, six Blender meshes and a mood.
const WORLDS: Array[Dictionary] = [
	{
		"id": "candy", "name": "Bonbonland", "icon": "✦",
		"tagline": "Zuckerwatte, Karamell und Schokolade",
		"palette": ["ef4444", "facc15", "38bdf8", "22c55e", "f472b6", "a855f7"],
		"background": "2a1039", "plate": ["4c1d95", "3b0764"], "accent": "f472b6",
		"pieceAssets": [
			"candy/bonbon", "candy/lolly", "candy/jellybean",
			"candy/gumdrop", "candy/chocolate", "candy/heart",
		],
		"icing": "f5d0fe", "stone": "9ca3af",
		"levelNames": [
			"Zuckerwelle", "Bonbon-Brise", "Karamellpfütze", "Gummibärchen-Lach",
			"Schokoladen-Schacht", "Herzlich-Süß", "Lolly-Regen", "Marshmallow-Boot",
			"Nougat-Berg", "Zitronen-Fladen", "Toffee-Turm", "Zuckerwatte-Wolke",
			"Bonbon-Box", "Kirschen-Boom", "Pfefferminze-Pfeffer", "Gummi-Gummi",
		],
	},
	{
		"id": "crystals", "name": "Kristallbruch", "icon": "◆",
		"tagline": "Splitter, Prismen und leuchtende Kerne",
		"palette": ["22d3ee", "34d399", "fbbf24", "f472b6", "60a5fa", "c084fc"],
		"background": "08172e", "plate": ["1e3a5f", "15294a"], "accent": "22d3ee",
		"pieceAssets": ["crystal", "crystal1", "crystal2", "crystal3", "crystal4", "crystal5"],
		"icing": "a5f3fc", "stone": "94a3b8",
		"levelNames": [
			"Splitterfeld", "Quarz-Grube", "Bergkristall", "Fluorit-Gang",
			"Juwelenschacht", "Amethystader", "Prismenpfad", "Smaragdkluft",
			"Sternenglanz", "Eisberg-Spiegel", "Citrin-Katze", "Labyrinth-Licht",
			"Kalktuff-Höhle", "Gipskristall", "Obsidian-Saum", "Diamantdunst",
		],
	},
	{
		"id": "flowers", "name": "Blütenmeer", "icon": "❦",
		"tagline": "Rosen, Tulpen und Seerosen im Wind",
		"palette": ["fb7185", "fde047", "f9a8d4", "ffffff", "86efac", "c4b5fd"],
		"background": "14301f", "plate": ["1f5133", "173d26"], "accent": "fb7185",
		"pieceAssets": [
			"candy/rose", "candy/tulip", "candy/sunflower",
			"candy/daisy", "candy/lily", "candy/lotus",
		],
		"icing": "fef3c7", "stone": "9ca3af",
		"levelNames": [
			"Rosenrain", "Tulpenbeet", "Sonnenblumen-Feld", "Gänseblümchen-Wiese",
			"Lilien-Teich", "Seerosen-Becken", "Kornblumen-Kante", "Mohnfeld",
			"Orchideen-Bogen", "Lavendel-Hang", "Pfingstrose-Pfad", "Gartenlaube",
			"Ranken-Dschungel", "Wildblüten-Wildnis", "Märchenblüte", "Duftgarten",
		],
	},
	{
		"id": "halloween", "name": "Kürbiskirmes", "icon": "◑",
		"tagline": "Zuckerwatte, Kürbisse und Geister",
		"palette": ["fb923c", "4ade80", "a78bfa", "f87171", "fef3c7", "22d3ee"],
		"background": "1b0b2e", "plate": ["3b0764", "2e0a4f"], "accent": "f97316",
		"pieceAssets": [
			"halloween_seed", "halloween_candy", "halloween_mini_pumpkin",
			"halloween_pumpkin", "halloween_ghost_pumpkin", "rpg/skull",
		],
		"icing": "ddd6fe", "stone": "94a3b8",
		"levelNames": [
			"Kürbisschatten", "Zahnstocher-Kerze", "Hexslumpen", "Spinnennetz",
			"Geisterkürbis", "Schädel-Kamin", "Fledermaus-Flug", "Süßigkeiten-Boos",
			"Nebelhöllen", "Rasenmäher-Lauf", "Süßkartoffel", "Gruselgarten",
			"Würfel-Fluch", "Todesblüte", "Mitternachtswiese", "Knochenkirmes",
		],
	},
	{
		"id": "xmas", "name": "Weihnachtsmarkt", "icon": "✧",
		"tagline": "Zuckerstangen, Glaskugeln und Stollensterne",
		"palette": ["ef4444", "22c55e", "facc15", "7dd3fc", "fda4af", "a16207"],
		"background": "0b1a2f", "plate": ["14406b", "0e2f50"], "accent": "ef4444",
		"pieceAssets": [
			"xmas_pinecone", "xmas_candy_cane", "xmas_bauble",
			"xmas_gingerbread_star", "xmas_star", "candy/gift",
		],
		"icing": "e0f2fe", "stone": "94a3b8",
		"levelNames": [
			"Tannenzapfen-Teppich", "Zuckerstangen-Gasse", "Glaskugeln-Baum",
			"Lebkuchen-Plätzchen", "Christstern-Spitze", "Geschenk-Stapel",
			"Glocken-Konzert", "Schneeflocken-Teppich", "Kerzen-Kranz", "Punschstand",
			"Nussknacker", "Rutschbahn", "Wintermarkt", "Frost-Star",
			"Weihnachtswunder", "Nordlicht-Kerzen",
		],
	},
	{
		"id": "gems", "name": "Schatzgrube", "icon": "◈",
		"tagline": "Amulette, Ringe und gekrönte Schätze",
		"palette": ["38bdf8", "4ade80", "fb7185", "c084fc", "fbbf24", "e2e8f0"],
		"background": "1c1206", "plate": ["5b3d0f", "452d0b"], "accent": "fbbf24",
		"pieceAssets": [
			"rpg/gem", "rpg/ring", "rpg/amulet", "rpg/crown", "rpg/coin", "rpg/crystal_cluster",
		],
		"icing": "fde68a", "stone": "9ca3af",
		"levelNames": [
			"Münz-Automat", "Ring-Reihen", "Amulett-Archiv", "Kronen-Schatzkammer",
			"Kristall-Cluster", "Geldbeutel-Gang", "Tresor-Treppe", "Diamant-Wächter",
			"Goldbarren-Silo", "Perlen-Kette", "Rubin-Grube", "Saphir-Schacht",
			"Zeugenschatz", "Drachenhort", "Königsschatz", "Singular-Krone",
		],
	},
]


static func world_ids() -> Array[String]:
	var out: Array[String] = []
	for world in WORLDS:
		out.append(str((world as Dictionary)["id"]))
	return out


static func world_by_id(id: String) -> Dictionary:
	for world in WORLDS:
		if str((world as Dictionary)["id"]) == id:
			return world
	return WORLDS[0]


## Colour-blind friendly palette (Okabe-Ito): the six hues stay apart for
## deuteranopia and protanopia and differ in lightness, so the board stays
## readable without relying on hue alone. The six piece shapes per world are
## distinct anyway.
const HIGH_CONTRAST_PALETTE: Array[String] = ["e69f00", "56b4e9", "009e73", "f0e442", "0072b2", "cc79a7"]

const PALETTE_CLASSIC := "classic"
const PALETTE_CONTRAST := "contrast"


static func palette_color(world: Dictionary, index: int, mode: String = PALETTE_CLASSIC) -> Color:
	var palette: Array = HIGH_CONTRAST_PALETTE if mode == PALETTE_CONTRAST else (world["palette"] as Array)
	return Color(str(palette[clampi(index, 0, palette.size() - 1)]))


# --- goals ------------------------------------------------------------------

## One of `{"kind": "score" | "clear" | "collect", …}`.
static func goal_text(goal: Dictionary) -> String:
	match str(goal["kind"]):
		"score":
			return "Punkte sammeln — %d" % int(goal["target"])
		"clear":
			return "Blöcke räumen — %d" % int(goal["target"])
		_:
			return "Farbe %d einsammeln — %d" % [int(goal["color"]) + 1, int(goal["target"])]


## Deterministically builds level `(world, index)`. The optional `salt` creates
## a variant of that level (the daily challenge) without touching the campaign.
static func level_for(world_id: String, index: int, salt: String = "") -> Dictionary:
	var world := world_by_id(world_id)
	var level_index := clampi(index, 1, LEVELS_PER_WORLD)
	var world_index: int = world_ids().find(world_id)
	var seed_text := "%s:%d" % [world_id, level_index]
	if salt != "":
		seed_text = "%s:%d:%s" % [world_id, level_index, salt]
	var seed_value: int = hash_string(seed_text)
	var rng := mulberry32(seed_value)
	var step := float(level_index - 1) / float(LEVELS_PER_WORLD - 1)

	var colors := 4
	if level_index > 2:
		colors = 5 if level_index <= 9 else 6
	var moves: int = maxi(14, int(round(30.0 - step * 13.0)))
	var layout: Array = LAYOUT_FULL
	if level_index == 3:
		layout = LAYOUTS[1]
	elif level_index > 3:
		layout = LAYOUTS[random_int(rng, LAYOUTS.size())]
	var open := 0
	for line in layout:
		open += str(line).count("#")
	var icing: int = 0
	if level_index >= 3:
		icing = int(round(float(open) * maxf(0.0, step * 0.36 - (0.12 if level_index < 6 else 0.0))))
	var icing_layers: int = 2 if level_index >= 6 else 1
	var stone: int = int(round(float(open) * step * 0.12)) if level_index >= 10 else 0

	var goals: Array = []
	var score_target: int = int(round(float(moves) * float(110 + level_index * 6)))
	if icing + stone > 0:
		goals.append({"kind": "clear", "target": icing + stone})
		if level_index % 5 == 0:
			goals.append({"kind": "score", "target": int(round(float(score_target) * 1.4))})
	else:
		goals.append({"kind": "score", "target": score_target})
	if level_index >= 5:
		goals.append({"kind": "collect", "color": random_int(rng, colors), "target": 20 + level_index * 2})
	if level_index >= 12 and level_index % 3 == 0:
		var first_collect := -1
		for goal in goals:
			if str((goal as Dictionary)["kind"]) == "collect":
				first_collect = int((goal as Dictionary)["color"])
				break
		var color := random_int(rng, colors)
		if first_collect >= 0 and first_collect == color:
			color = (color + 1) % colors
		goals.append({"kind": "collect", "color": color, "target": 24 + level_index})

	var names: Array = (world["levelNames"] as Array)
	return {
		"worldId": world_id,
		"index": level_index,
		"number": world_index * LEVELS_PER_WORLD + level_index,
		"title": "%s %d" % [str(names[(level_index - 1) % names.size()]), level_index],
		"colors": colors,
		"moves": moves,
		"layout": layout,
		"goals": goals,
		"starScores": [moves * 170, moves * 320],
		"seed": seed_value,
		"blockers": {"icing": icing, "icingLayers": icing_layers, "stone": stone},
		"allowStriped": level_index >= 2,
		"allowWrapped": level_index >= 4,
		"allowBomb": level_index >= 7,
		"dailyKey": "",
	}


## The daily challenge: one level per calendar day, picked deterministically from
## the date. Every player worldwide plays the same board, and it is a level that
## does not exist in the campaign (the date is part of the seed).
static func daily_level(day: String) -> Dictionary:
	var rng := mulberry32(hash_string("daily:%s" % day))
	var world := WORLDS[random_int(rng, WORLDS.size())]
	var index := 1 + random_int(rng, LEVELS_PER_WORLD)
	var level := level_for(str((world as Dictionary)["id"]), index, "daily-%s" % day)
	level["title"] = "Tageslevel · %s" % str(level["title"])
	level["number"] = 0
	level["dailyKey"] = day
	return level


static func total_level_count() -> int:
	return WORLDS.size() * LEVELS_PER_WORLD


# --- world milestones -------------------------------------------------------

## Star milestones of a world; every reached milestone keeps paying out.
const WORLD_MILESTONES: Array[Dictionary] = [
	{"stars": 10, "label": "+3 Züge in jedem Level", "moves": 3, "undos": 0, "bomb": false},
	{"stars": 25, "label": "Start-Farbbombe", "moves": 0, "undos": 0, "bomb": true},
	{"stars": 45, "label": "+2 Züge und +1 Undo", "moves": 2, "undos": 1, "bomb": true},
]


## Everything the collected stars of a world unlock.
static func world_bonus(stars: int) -> Dictionary:
	var bonus := {"moves": 0, "undos": 0, "bomb": false}
	for milestone in WORLD_MILESTONES:
		if stars < int((milestone as Dictionary)["stars"]):
			continue
		bonus["moves"] = int(bonus["moves"]) + int((milestone as Dictionary)["moves"])
		bonus["undos"] = int(bonus["undos"]) + int((milestone as Dictionary)["undos"])
		bonus["bomb"] = bool(bonus["bomb"]) or bool((milestone as Dictionary)["bomb"])
	return bonus


## The next milestone still out of reach, or `{}` when all are earned.
static func next_milestone(stars: int) -> Dictionary:
	for milestone in WORLD_MILESTONES:
		if stars < int((milestone as Dictionary)["stars"]):
			return milestone
	return {}


## Stars of one world from a `{levelKey: stars}` map.
static func world_stars(levels: Dictionary, world_id: String) -> int:
	var world_index: int = world_ids().find(world_id)
	var total := 0
	for index in range(1, LEVELS_PER_WORLD + 1):
		total += int(levels.get(str(world_index * LEVELS_PER_WORLD + index), 0))
	return total


# --- run state --------------------------------------------------------------

## The peaks of a run. A hand-built state gets these filled in, so every reader
## can ask for a key without guarding it first.
const DEFAULT_PEAKS: Dictionary = {
	"moves": 0, "chain": 0, "clear": 0, "specials": 0, "step": 0, "stepMove": 0,
	"combos": 0, "comboBest": 0, "comboName": "", "comboMove": 0,
}


static func _fill_peaks(peaks: Dictionary) -> Dictionary:
	for key in DEFAULT_PEAKS:
		if not peaks.has(key):
			peaks[key] = DEFAULT_PEAKS[key]
	return peaks


## Everything a move changes, deep-copied so an undo can restore it exactly.
## The run peaks belong to it: a chain the player undoes is never credited.
static func snapshot_state(state: Dictionary) -> Dictionary:
	return {
		"board": clone_board(state["board"]),
		"score": int(state["score"]),
		"movesLeft": int(state["movesLeft"]),
		"collected": (state["collected"] as Array).duplicate(),
		"blockersTotal": int(state["blockersTotal"]),
		"highlights": highlights(state).duplicate(true),
	}


static func restore_state(state: Dictionary, snapshot: Dictionary) -> void:
	state["board"] = clone_board(snapshot["board"])
	state["score"] = int(snapshot["score"])
	state["movesLeft"] = int(snapshot["movesLeft"])
	state["collected"] = (snapshot["collected"] as Array).duplicate()
	state["blockersTotal"] = int(snapshot["blockersTotal"])
	state["highlights"] = _fill_peaks((snapshot.get("highlights", {}) as Dictionary).duplicate(true))


## A colour for `cell` that cannot complete a run of three (used by the start bomb).
static func _safe_color_at(board: Dictionary, cell: int, color_count: int, rng: Rng) -> int:
	var colors: Array = board["colors"]
	var col := col_of(cell)
	var row := row_of(cell)
	var banned := {}
	for axis in [Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(1, -1)]:
		var forward_a: int = _color_at(colors, col + axis.x, row + axis.y)
		var forward_b: int = _color_at(colors, col + axis.x * 2, row + axis.y * 2)
		var back_a: int = _color_at(colors, col - axis.x, row - axis.y)
		var back_b: int = _color_at(colors, col - axis.x * 2, row - axis.y * 2)
		if forward_a != NO_CANDY_OUTSIDE and forward_a == forward_b:
			banned[forward_a] = true
		if back_a != NO_CANDY_OUTSIDE and back_a == back_b:
			banned[back_a] = true
		if forward_a != NO_CANDY_OUTSIDE and forward_a == back_a:
			banned[forward_a] = true
	var options: Array = []
	for color in color_count:
		if not banned.has(color):
			options.append(color)
	if options.is_empty():
		return random_int(rng, color_count)
	return int(options[random_int(rng, options.size())])


## Sentinel for "outside the board or no candy" — never a real colour.
const NO_CANDY_OUTSIDE := -2


static func _color_at(colors: Array, col: int, row: int) -> int:
	if col < 0 or col >= COLS or row < 0 or row >= ROWS:
		return NO_CANDY_OUTSIDE
	return colors[cell_index(col, row)]


## Puts a colour bomb on the board without creating an instant match.
static func _place_start_bomb(board: Dictionary, color_count: int, rng: Rng) -> void:
	var kind: Array = board["kind"]
	var mid_col := float(COLS - 1) * 0.5
	var mid_row := float(ROWS - 1) * 0.5
	var best := -1
	var best_distance := INF
	for cell in CELL_COUNT:
		if kind[cell] != KIND_OPEN:
			continue
		var distance := Vector2(float(col_of(cell)) - mid_col, float(row_of(cell)) - mid_row).length()
		if distance >= best_distance:
			continue
		best_distance = distance
		best = cell
	if best < 0:
		return
	set_candy(board, best, _safe_color_at(board, best, color_count, rng), SPECIAL_BOMB)


## Fills the board without any immediate match.
static func _fill_match_free(board: Dictionary, color_count: int, rng: Rng) -> void:
	var kind: Array = board["kind"]
	for row in ROWS:
		for col in COLS:
			var cell := cell_index(col, row)
			if kind[cell] != KIND_OPEN:
				continue
			var banned := {}
			if col >= 2:
				var a := cell_index(col - 1, row)
				var b := cell_index(col - 2, row)
				if has_candy(board, a) and has_candy(board, b) and (board["colors"] as Array)[a] == (board["colors"] as Array)[b]:
					banned[(board["colors"] as Array)[a]] = true
			if row >= 2:
				var a := cell_index(col, row - 1)
				var b := cell_index(col, row - 2)
				if has_candy(board, a) and has_candy(board, b) and (board["colors"] as Array)[a] == (board["colors"] as Array)[b]:
					banned[(board["colors"] as Array)[a]] = true
			var options: Array = []
			for color in color_count:
				if not banned.has(color):
					options.append(color)
			var pick := random_int(rng, color_count)
			if not options.is_empty():
				pick = int(options[random_int(rng, options.size())])
			set_candy(board, cell, pick, SPECIAL_NONE)


static func _place_blockers(board: Dictionary, level: Dictionary, rng: Rng) -> void:
	var pool: Array = open_cells(board)
	for i in range(pool.size() - 1, 0, -1):
		var j := random_int(rng, i + 1)
		var swap: int = pool[i]
		pool[i] = pool[j]
		pool[j] = swap
	# Keep the middle column free so a board never starts sealed shut.
	var middle := int(floor(float(COLS) * 0.5))
	var usable: Array = []
	for cell in pool:
		if col_of(cell) != middle:
			usable.append(cell)
	var blockers: Dictionary = level["blockers"]
	var kind: Array = board["kind"]
	var layers: Array = board["layers"]
	var cursor := 0
	for i in int((blockers as Dictionary)["icing"]):
		if cursor >= usable.size():
			break
		kind[usable[cursor]] = KIND_ICING
		layers[usable[cursor]] = int((blockers as Dictionary)["icingLayers"])
		cursor += 1
	for i in int((blockers as Dictionary)["stone"]):
		if cursor >= usable.size():
			break
		kind[usable[cursor]] = KIND_STONE
		layers[usable[cursor]] = 2
		cursor += 1


static func start_level(level: Dictionary, bonus: Dictionary = {}) -> Dictionary:
	var world := world_by_id(str(level["worldId"]))
	var board := create_board(level["layout"])
	var rng := mulberry32(int(level["seed"]) ^ 0x9E3779B9)
	var reward := bonus if not bonus.is_empty() else world_bonus(0)
	_place_blockers(board, level, rng)
	# Re-deal until the board neither matches right away nor is dead — a level
	# must always start with at least one legal move. The reward bomb is placed
	# inside the loop because recolouring the middle cell can kill the only move.
	for attempt in 8:
		_fill_match_free(board, int(level["colors"]), rng)
		if bool((reward as Dictionary).get("bomb", false)):
			_place_start_bomb(board, int(level["colors"]), rng)
		if has_valid_swap(board):
			break
	var collected: Array = []
	collected.resize(int(level["colors"]))
	collected.fill(0)
	return {
		"level": level,
		"world": world,
		"board": board,
		"score": 0,
		"movesLeft": int(level["moves"]) + int((reward as Dictionary)["moves"]),
		"collected": collected,
		"blockersTotal": blocker_cells(board).size(),
		"bonus": reward,
		"rng": rng,
		"highlights": DEFAULT_PEAKS.duplicate(true),
	}


static func blockers_left(state: Dictionary) -> int:
	return blocker_cells(state["board"]).size()


## `[{goal, current, target, done}, …]` — one entry per level goal.
static func goal_progress(state: Dictionary) -> Array:
	var out: Array = []
	var left := blockers_left(state)
	for goal in (state["level"]["goals"] as Array):
		var entry := goal as Dictionary
		match str(entry["kind"]):
			"score":
				out.append({
					"goal": entry,
					"current": mini(int(state["score"]), int(entry["target"])),
					"target": int(entry["target"]),
					"done": int(state["score"]) >= int(entry["target"]),
				})
			"clear":
				out.append({
					"goal": entry,
					"current": mini(int(state["blockersTotal"]) - left, int(entry["target"])),
					"target": int(entry["target"]),
					"done": left == 0,
				})
			_:
				var collected: int = (state["collected"] as Array)[int(entry["color"])]
				out.append({
					"goal": entry,
					"current": mini(collected, int(entry["target"])),
					"target": int(entry["target"]),
					"done": collected >= int(entry["target"]),
				})
	return out


static func is_won(state: Dictionary) -> bool:
	for progress in goal_progress(state):
		if not bool((progress as Dictionary)["done"]):
			return false
	return true


static func stars_for(state: Dictionary) -> int:
	if not is_won(state):
		return 0
	var thresholds: Array = state["level"]["starScores"]
	if int(state["score"]) >= int(thresholds[1]):
		return 3
	if int(state["score"]) >= int(thresholds[0]):
		return 2
	return 1


## The peaks of the run, created on first use so a hand-built state works too.
## `moves` played, `chain` longest cascade, `clear` biggest single clear,
## `specials` created, `step` best single step and `stepMove` the move it
## happened in. `combos` counts the combinations set off, `comboBest` the largest
## of them, with `comboName` and `comboMove` saying which and when.
static func highlights(state: Dictionary) -> Dictionary:
	if not state.has("highlights") or (state["highlights"] as Dictionary).is_empty():
		state["highlights"] = DEFAULT_PEAKS.duplicate(true)
	return _fill_peaks(state["highlights"])


## Notes a combination in the peaks: how many the player set off, and which one
## cleared the most. An ordinary move passes {@link COMBO_NONE} and changes
## nothing.
static func note_combo(best: Dictionary, combo: int, cleared: int, move: int) -> void:
	if combo == COMBO_NONE:
		return
	best["combos"] = int(best["combos"]) + 1
	if cleared <= int(best["comboBest"]):
		return
	best["comboBest"] = cleared
	best["comboName"] = combo_name(combo)
	best["comboMove"] = move


## Run bookkeeping of a resolved step.
static func apply_step_to_state(state: Dictionary, step: Dictionary) -> void:
	state["score"] = int(state["score"]) + int(step["score"])
	var collected: Array = state["collected"]
	for color in (step["clearedColors"] as Array):
		if color >= 0 and color < collected.size():
			collected[color] += 1
	# The peaks of the run: what a player remembers from a level, and what the
	# result screen reports back. Peaks, not sums — the best chain, not all of
	# them together.
	var best := highlights(state)
	best["chain"] = maxi(int(best["chain"]), int(step["chain"]))
	best["clear"] = maxi(int(best["clear"]), (step["cleared"] as Array).size())
	best["specials"] = int(best["specials"]) + (step["created"] as Array).size()
	if int(step["score"]) > int(best["step"]):
		best["step"] = int(step["score"])
		best["stepMove"] = int(best["moves"])


## Plays out the cascades of a move; returns every step until the board settles.
## `combo` is the {@link combo_kind} of the swap, so the peaks can tell a
## combination from an ordinary match.
static func continue_cascades(state: Dictionary, first: Dictionary, combo: int = COMBO_NONE) -> Array:
	var steps: Array = [first]
	var best := highlights(state)
	best["moves"] = int(best["moves"]) + 1
	note_combo(best, combo, (first["cleared"] as Array).size(), int(best["moves"]))
	apply_step_to_state(state, first)
	var chain: int = int(first["chain"])
	for i in 40:
		var step := resolve_step(state["board"], state["rng"], {
			"chain": chain + steps.size(),
			"colorCount": int((state["level"] as Dictionary)["colors"]),
		})
		if step.is_empty():
			break
		apply_step_to_state(state, step)
		steps.append(step)
	return steps


# --- the story of a finished run ---------------------------------------------

## The peaks of the run as rows for the result screen:
## `[{icon, label, value, unit, move}, …]`. A peak that never happened stays
## out, so the first level of the game does not show a wall of zeroes. The
## number is raw — the screen formats it.
static func run_moments(state: Dictionary) -> Array:
	var best := highlights(state)
	var moments: Array = []
	if int(best["chain"]) >= 2:
		moments.append({"icon": "✦", "label": "Längste Kette", "value": int(best["chain"]),
			"unit": "Treffer in Folge", "move": 0})
	if int(best["clear"]) >= 4:
		moments.append({"icon": "◼", "label": "Größter Match", "value": int(best["clear"]),
			"unit": "Bonbons auf einmal", "move": 0})
	if int(best["comboBest"]) > 0:
		moments.append({"icon": "✹", "label": "Kombination: %s" % str(best["comboName"]),
			"value": int(best["comboBest"]), "unit": "Bonbons auf einmal", "move": int(best["comboMove"])})
	if int(best["specials"]) > 0:
		moments.append({"icon": "◆", "label": "Spezialbonbons", "value": int(best["specials"]),
			"unit": "gebildet", "move": 0})
	if int(best["step"]) > 0:
		moments.append({"icon": "★", "label": "Bester Zug", "value": int(best["step"]),
			"unit": "Punkte", "move": int(best["stepMove"])})
	return moments


## What still separates the player from the next star: `{stars, missing}`, or
## `{}` when the run has all three. A lost level reports it as well — it says
## what the level would have asked for.
static func star_gap(state: Dictionary) -> Dictionary:
	var thresholds: Array = state["level"]["starScores"]
	var score := int(state["score"])
	if score < int(thresholds[0]):
		return {"stars": 2, "missing": int(thresholds[0]) - score}
	if score < int(thresholds[1]):
		return {"stars": 3, "missing": int(thresholds[1]) - score}
	return {}


## "zum zweiten Stern" / "zum dritten Stern" — the ordinal belongs to the text,
## the numbers stay in {@link star_gap}.
static func star_ordinal(stars: int) -> String:
	return "zum zweiten Stern" if stars == 2 else "zum dritten Stern"


# --- dates (daily challenge) ------------------------------------------------

## `YYYY-MM-DD` of a unix timestamp in local time, or of today.
static func date_key(unix_time: int = 0) -> String:
	var stamp := unix_time if unix_time > 0 else int(Time.get_unix_time_from_system())
	var parts := Time.get_datetime_dict_from_unix_time(stamp)
	return "%04d-%02d-%02d" % [int(parts["year"]), int(parts["month"]), int(parts["day"])]


static func _is_leap_year(year: int) -> bool:
	return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)


## Shifts a `YYYY-MM-DD` key by whole days.
static func shift_date_key(key: String, days: int) -> String:
	var parts := key.split("-")
	if parts.size() != 3:
		return key
	var year := int(parts[0])
	var month := int(parts[1])
	var day := int(parts[2]) + days
	while day < 1:
		month -= 1
		if month < 1:
			month = 12
			year -= 1
		day += _days_in_month(year, month)
	while day > _days_in_month(year, month):
		day -= _days_in_month(year, month)
		month += 1
		if month > 12:
			month = 1
			year += 1
	return "%04d-%02d-%02d" % [year, month, day]


static func _days_in_month(year: int, month: int) -> int:
	var lengths := [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
	if month == 2 and _is_leap_year(year):
		return 29
	return int(lengths[clampi(month - 1, 0, 11)])


## Consecutive days with a recorded result, counting back from `today`. A streak
## survives a missed *today* as long as yesterday was played, so the counter only
## breaks once two days in a row are missing.
static func daily_streak(days: Dictionary, today: String = "", max_days: int = 400) -> int:
	var anchor := today if today != "" else date_key()
	var cursor := anchor
	if int(days.get(anchor, 0)) <= 0:
		cursor = shift_date_key(anchor, -1)
	if int(days.get(cursor, 0)) <= 0:
		return 0
	var streak := 0
	for i in max_days:
		if int(days.get(cursor, 0)) <= 0:
			break
		streak += 1
		cursor = shift_date_key(cursor, -1)
	return streak
