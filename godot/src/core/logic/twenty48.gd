class_name Twenty48
extends RefCounted
## Pure 2048 rules.
##
## `slide` returns the resulting board plus a detailed plan of how every tile
## moved, which the scene turns into animations. `merged` guarantees a tile
## that was just created by a merge cannot merge again on the same move.
##
## The tile that follows the next move is decided one move early and lives on
## the board as a *ghost* (`plan_tile`, `slide_pending`, `can_move_pending`).
## The ghost is a normal tile for the slide — it moves, it merges and its points
## count — and with that move it becomes permanent. That is what turns a board
## game of luck into one move of planning: the player can set up the ghost's
## merge instead of hoping for the right spawn.

const SIZE := 4
const WIN_VALUE := 2048
## Classic odds: a ghost is a 2 nine times out of ten.
const FOUR_CHANCE := 0.1

const UP := "up"
const DOWN := "down"
const LEFT := "left"
const RIGHT := "right"

const DIRS := {
	UP: Vector2i(-1, 0),
	DOWN: Vector2i(1, 0),
	LEFT: Vector2i(0, -1),
	RIGHT: Vector2i(0, 1),
}


static func empty_board() -> Array:
	var board: Array = []
	for r in SIZE:
		var row: Array = []
		for c in SIZE:
			row.append(0)
		board.append(row)
	return board


static func clone_board(board: Array) -> Array:
	var out: Array = []
	for row in board:
		out.append((row as Array).duplicate())
	return out


static func at(board: Array, row: int, col: int) -> int:
	return int((board[row] as Array)[col])


static func set_at(board: Array, row: int, col: int, value: int) -> void:
	(board[row] as Array)[col] = value


## Slide + merge every tile in the given direction and report the full move plan.
static func slide(board: Array, dir: String) -> Dictionary:
	var step: Vector2i = DIRS[dir] if DIRS.has(dir) else DIRS[LEFT]
	var working := empty_board()
	var merged: Array = []
	for r in SIZE:
		var row: Array = []
		for c in SIZE:
			row.append(false)
		merged.append(row)
	var moves: Array = []
	var merge_list: Array = []
	var gained := 0
	var moved := false

	var order: Array = [0, 1, 2, 3]
	if step.x > 0:
		order.reverse()

	for r: int in order:
		var cols: Array = [0, 1, 2, 3]
		if step.y > 0:
			cols.reverse()
		for c: int in cols:
			var value: int = at(board, r, c)
			if value == 0:
				continue

			var cr: int = r
			var cc: int = c
			var merge_at := Vector2i(-1, -1)
			while true:
				var nr: int = cr + step.x
				var nc: int = cc + step.y
				if nr < 0 or nr >= SIZE or nc < 0 or nc >= SIZE:
					break
				var occupant := at(working, nr, nc)
				if occupant == 0:
					cr = nr
					cc = nc
					continue
				if occupant == value and not (merged[nr][nc] as bool):
					merge_at = Vector2i(nr, nc)
					cr = nr
					cc = nc
				break

			if merge_at.x >= 0:
				if cr != r or cc != c:
					moves.append({"from": Vector2i(r, c), "to": Vector2i(cr, cc)})
				merge_list.append({
					"row": merge_at.x, "col": merge_at.y, "value": value * 2,
					"sources": [Vector2i(r, c), Vector2i(cr, cc)],
				})
				set_at(working, merge_at.x, merge_at.y, value * 2)
				set_at(merged, merge_at.x, merge_at.y, true)
				gained += value * 2
				moved = true
			else:
				set_at(working, r, c, 0)
				set_at(working, cr, cc, value)
				if cr != r or cc != c:
					moves.append({"from": Vector2i(r, c), "to": Vector2i(cr, cc)})
					moved = true

	return {"values": working, "moved": moved, "gained": gained, "moves": moves, "merges": merge_list}


## True as long as at least one empty cell or equal neighbour pair exists.
static func can_move(board: Array) -> bool:
	for r in SIZE:
		for c in SIZE:
			if at(board, r, c) == 0:
				return true
			if c + 1 < SIZE and at(board, r, c) == at(board, r, c + 1):
				return true
			if r + 1 < SIZE and at(board, r, c) == at(board, r + 1, c):
				return true
	return false


static func highest_value(board: Array) -> int:
	var best := 0
	for row in board:
		for value in row:
			best = maxi(best, int(value))
	return best


## How many cells are taken. The ghost is not counted — it is a promise, not a
## tile, and the board is one move behind the player's plan.
static func count_tiles(board: Array) -> int:
	var count := 0
	for row in board:
		for value in row:
			if int(value) != 0:
				count += 1
	return count


static func has_value(board: Array, value: int) -> bool:
	for row in board:
		for cell in row:
			if int(cell) == value:
				return true
	return false


## Every free cell as a Vector2i, in reading order.
static func empty_cells(board: Array) -> Array:
	var out: Array = []
	for r in SIZE:
		for c in SIZE:
			if at(board, r, c) == 0:
				out.append(Vector2i(r, c))
	return out


## Places a new 2 (90%) or 4 (10%) on a random empty cell. Mutates `board`.
static func add_random_tile(board: Array) -> Variant:
	var empty := empty_cells(board)
	if empty.is_empty():
		return null
	var slot: Vector2i = empty[randi() % empty.size()]
	var value := 2 if randf() < 0.9 else 4
	set_at(board, slot.x, slot.y, value)
	return {"row": slot.x, "col": slot.y, "value": value}


# --- the ghost tile ---------------------------------------------------------

## Picks the tile the next move will add: which cell, and how big.
##
## The caller owns the generator, so a run is reproducible from its seed — which
## is also what makes this testable. An empty dictionary means the board is full
## and the next move brings nothing.
static func plan_tile(board: Array, rng: RandomNumberGenerator) -> Dictionary:
	var empty := empty_cells(board)
	if empty.is_empty():
		return {}
	var slot: Vector2i = empty[rng.randi_range(0, empty.size() - 1)]
	var value := 4 if rng.randf() < FOUR_CHANCE else 2
	return {"row": slot.x, "col": slot.y, "value": value}


## Opening position: one real tile plus the ghost the player sees first.
##
## One real tile and one ghost is the classic two-tile start. Dealing two real
## tiles *and* a ghost would hand out one tile more than 2048 does for the whole
## run — a preview must not be a free tile.
static func opening(board: Array, rng: RandomNumberGenerator) -> Dictionary:
	var first := plan_tile(board, rng)
	if first.is_empty():
		return {}
	set_at(board, int(first["row"]), int(first["col"]), int(first["value"]))
	return plan_tile(board, rng)


## The board as the player sees it: `board` with the ghost laid on top.
##
## A ghost that no longer fits (an out-of-date snapshot, a board that was
## restored under it) is ignored rather than allowed to eat a real tile.
static func stage_ghost(board: Array, pending: Dictionary) -> Array:
	var staged := clone_board(board)
	if pending.is_empty():
		return staged
	var row := int(pending["row"])
	var col := int(pending["col"])
	if at(staged, row, col) != 0:
		return staged
	set_at(staged, row, col, int(pending["value"]))
	return staged


## Slides the board including the ghost and reports the same plan as `slide`.
##
## The returned `values` already contain the ghost as a real tile; the caller
## plans the next one. As everywhere in 2048, `moved == false` means the plan is
## to be discarded — a ghost that neither moves nor merges is not a move.
static func slide_pending(board: Array, dir: String, pending: Dictionary) -> Dictionary:
	return slide(stage_ghost(board, pending), dir)


## True while a move exists — ghost included.
##
## Not the same question as `can_move(board)`: the ghost is a real tile for the
## slide, so it brings its own merges — and it can also be the stone that blocks
## the last legal move. Whoever asks has to ask about the board the player sees,
## otherwise a game can dead-end without the dialog ever appearing.
static func can_move_pending(board: Array, pending: Dictionary) -> bool:
	return can_move(stage_ghost(board, pending))


## Applies a move and spawns a tile in one call.
static func apply_move(board: Array, dir: String) -> Dictionary:
	var plan := slide(board, dir)
	var spawn: Variant = null
	if bool(plan["moved"]):
		spawn = add_random_tile(plan["values"])
	plan["spawn"] = spawn
	return plan
