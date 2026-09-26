class_name Checkers
extends RefCounted
## Rules and AI for the Dame (international draughts) subgame.
## Port of `src/game/checkers.ts`.
##
## The board is a flat array of 64 squares (`index = row * 8 + col`):
##   0 = empty, 1 = player man, 2 = player king, -1 = opponent man, -2 = opponent king.
## White (the player) starts at the bottom and moves up, black starts at the top.

const BOARD_SIZE := 8
const CELL_COUNT := BOARD_SIZE * BOARD_SIZE

const EMPTY := 0
const WHITE_MAN := 1
const WHITE_KING := 2
const BLACK_MAN := -1
const BLACK_KING := -2

const WHITE := 1
const BLACK := -1

const DIRS_KING := [Vector2i(-1, -1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(1, 1)]
const DIRS_WHITE_MAN := [Vector2i(-1, -1), Vector2i(-1, 1)]
const DIRS_BLACK_MAN := [Vector2i(1, -1), Vector2i(1, 1)]

const MATE := 1000000
const MAN_VALUE := 100
const KING_VALUE := 180


static func index_of(row: int, col: int) -> int:
	return row * BOARD_SIZE + col


static func row_of(square: int) -> int:
	return int(floor(float(square) / BOARD_SIZE))


static func col_of(square: int) -> int:
	return square % BOARD_SIZE


static func in_bounds(row: int, col: int) -> bool:
	return row >= 0 and row < BOARD_SIZE and col >= 0 and col < BOARD_SIZE


## Playable (dark) squares sit where `(row + col)` is odd.
static func is_playable(row: int, col: int) -> bool:
	return (row + col) % 2 == 1


static func side_of(piece: int) -> int:
	if piece > 0:
		return WHITE
	if piece < 0:
		return BLACK
	return 0


static func is_king(piece: int) -> bool:
	return piece == WHITE_KING or piece == BLACK_KING


static func opposite(side: int) -> int:
	return BLACK if side == WHITE else WHITE


static func dirs_for(piece: int) -> Array:
	if is_king(piece):
		return DIRS_KING
	return DIRS_WHITE_MAN if piece > 0 else DIRS_BLACK_MAN


## 12 pieces per side on the three rows closest to each player.
static func create_initial_board() -> PackedInt32Array:
	var board := PackedInt32Array()
	board.resize(CELL_COUNT)
	for i in CELL_COUNT:
		board[i] = EMPTY
	for row in 3:
		for col in BOARD_SIZE:
			if is_playable(row, col):
				board[index_of(row, col)] = BLACK_MAN
	for row in range(BOARD_SIZE - 3, BOARD_SIZE):
		for col in BOARD_SIZE:
			if is_playable(row, col):
				board[index_of(row, col)] = WHITE_MAN
	return board


static func promote_piece(piece: int, square: int) -> int:
	if piece == WHITE_MAN and row_of(square) == 0:
		return WHITE_KING
	if piece == BLACK_MAN and row_of(square) == BOARD_SIZE - 1:
		return BLACK_KING
	return piece


static func count_pieces(board: PackedInt32Array, side: int) -> int:
	var count := 0
	for square in CELL_COUNT:
		if side_of(board[square]) == side:
			count += 1
	return count


## All single steps (quiet and capturing) available to the piece on `from`.
## Each step is `[from, to, captured]`.
static func generate_piece_steps(board: PackedInt32Array, from: int) -> Array:
	var piece := board[from]
	var side := side_of(piece)
	if side == 0:
		return []
	var row := row_of(from)
	var col := col_of(from)
	var steps: Array = []
	for dir: Vector2i in dirs_for(piece):
		var nr: int = row + dir.x
		var nc: int = col + dir.y
		if not in_bounds(nr, nc):
			continue
		var target := index_of(nr, nc)
		if board[target] == EMPTY:
			steps.append([from, target, -1])
			continue
		if side_of(board[target]) == side:
			continue
		var jr: int = nr + dir.x
		var jc: int = nc + dir.y
		if not in_bounds(jr, jc):
			continue
		if board[index_of(jr, jc)] != EMPTY:
			continue
		steps.append([from, index_of(jr, jc), target])
	return steps


static func apply_step(board: PackedInt32Array, step: Array) -> PackedInt32Array:
	var next := board.duplicate()
	var piece := next[step[0]]
	next[step[0]] = EMPTY
	if step[2] >= 0:
		next[step[2]] = EMPTY
	next[step[1]] = promote_piece(piece, step[1])
	return next


static func apply_turn(board: PackedInt32Array, turn: Dictionary) -> PackedInt32Array:
	var next := board.duplicate()
	var turn_steps: Array = turn["steps"]
	for step: Array in turn_steps:
		var piece: int = next[step[0]]
		next[step[0]] = EMPTY
		if step[2] >= 0:
			next[step[2]] = EMPTY
		next[step[1]] = promote_piece(piece, step[1])
	return next


## Recursively extends a capture chain, mutating `board` while exploring and
## restoring it afterwards. Completed chains are pushed onto `out`.
static func _collect_captures(board: PackedInt32Array, from: int, acc: Array, captured: int, side: int, out: Array) -> void:
	var piece := board[from]
	var row := row_of(from)
	var col := col_of(from)

	for dir: Vector2i in dirs_for(piece):
		var nr: int = row + dir.x
		var nc: int = col + dir.y
		if not in_bounds(nr, nc):
			continue
		var victim := index_of(nr, nc)
		var victim_piece := board[victim]
		if victim_piece == EMPTY or side_of(victim_piece) == side:
			continue
		var jr: int = nr + dir.x
		var jc: int = nc + dir.y
		if not in_bounds(jr, jc):
			continue
		var land := index_of(jr, jc)
		if board[land] != EMPTY:
			continue

		acc.append([from, land, victim])
		board[victim] = EMPTY
		board[from] = EMPTY
		board[land] = piece

		if promote_piece(piece, land) != piece:
			out.append({"steps": acc.duplicate(true), "captures": captured + 1})
		else:
			var before := out.size()
			_collect_captures(board, land, acc, captured + 1, side, out)
			if out.size() == before:
				out.append({"steps": acc.duplicate(true), "captures": captured + 1})

		acc.pop_back()
		board[land] = EMPTY
		board[from] = piece
		board[victim] = victim_piece


## Every complete turn the side can play (quiet steps plus capture chains).
static func generate_turns(board: PackedInt32Array, side: int) -> Array:
	var turns: Array = []
	for from in CELL_COUNT:
		if side_of(board[from]) != side:
			continue
		var captures: Array = []
		_collect_captures(board, from, [], 0, side, captures)
		if not captures.is_empty():
			for turn in captures:
				turns.append(turn)
			continue
		for step in generate_piece_steps(board, from):
			if step[2] < 0:
				turns.append({"steps": [step], "captures": 0})
	return turns


static func has_moves(board: PackedInt32Array, side: int) -> bool:
	for from in CELL_COUNT:
		if side_of(board[from]) != side:
			continue
		if not generate_piece_steps(board, from).is_empty():
			return true
	return false


# --- Schlagzug-Analyse -------------------------------------------------------
# Alles, was der Bildschirm zum Anzeigen und für den Hinweis braucht: welcher
# Stein wie viele Steine schlägt, welcher Schlagzug der stärkste ist und welche
# Steine überhaupt ziehen dürfen. Reine Abfragen — sie verändern nichts und
# werden einmal pro Stellung gerechnet, nicht pro Bild.


## Rang einer Kette: mehr Steine schlägt eine Dame, bei Gleichstand das
## niedrigere Feld. Fest sortiert, damit derselbe Aufbau immer denselben
## Tipp ergibt und die Markierung nicht springt.
static func _chain_rank(board: PackedInt32Array, turn: Dictionary) -> int:
	var steps: Array = turn["steps"]
	var from := int((steps[0] as Array)[0])
	return int(turn["captures"]) * 10000 + (1000 if is_king(board[from]) else 0) + CELL_COUNT - from


## Jeder schlagende Stein mit seiner stärksten Kette, stärkster zuerst.
## Einträge: `{"from": int, "captures": int, "steps": Array}`.
static func capture_candidates(board: PackedInt32Array, side: int) -> Array:
	var chains: Dictionary = {}
	var ranks: Dictionary = {}
	for turn in generate_turns(board, side):
		var captures := int(turn["captures"])
		if captures <= 0:
			continue
		var from := int(((turn["steps"] as Array)[0] as Array)[0])
		var rank := _chain_rank(board, turn)
		if ranks.has(from) and rank <= int(ranks[from]):
			continue
		ranks[from] = rank
		chains[from] = {"from": from, "captures": captures, "steps": turn["steps"]}
	var out: Array = chains.values()
	out.sort_custom(func(a, b) -> bool:
		if int(a["captures"]) != int(b["captures"]):
			return int(a["captures"]) > int(b["captures"])
		return int(a["from"]) < int(b["from"]))
	return out


## Der stärkste Schlagzug der Seite — oder `{}`, wenn es keinen gibt.
static func best_capture(board: PackedInt32Array, side: int) -> Dictionary:
	var candidates := capture_candidates(board, side)
	if candidates.is_empty():
		return {}
	var top: Dictionary = candidates[0]
	return {"steps": top["steps"], "captures": int(top["captures"])}


## Alle Felder der Seite, von denen ein legaler Zug ausgeht. Beantwortet die
## Frage "welche Steine dürfen ziehen?", wenn nichts zu schlagen ist.
static func movable_squares(board: PackedInt32Array, side: int) -> Array:
	var out: Array = []
	for square in CELL_COUNT:
		if side_of(board[square]) != side:
			continue
		if not generate_piece_steps(board, square).is_empty():
			out.append(square)
	return out


# --- AI ---------------------------------------------------------------------

## Static evaluation from black's point of view: positive is good for black.
static func evaluate(board: PackedInt32Array) -> float:
	var score := 0.0
	for square in CELL_COUNT:
		var piece := board[square]
		if piece == EMPTY:
			continue
		var side := side_of(piece)
		var row := row_of(square)
		var col := col_of(square)
		var value := 0.0
		if is_king(piece):
			value = KING_VALUE
		else:
			value = MAN_VALUE
			var progress := (BOARD_SIZE - 1 - row) if side == WHITE else row
			value += progress * 5.0
			if (side == WHITE and row == BOARD_SIZE - 1) or (side == BLACK and row == 0):
				value += 8.0
		if col >= 2 and col <= 5:
			value += 4.0
		score += value if side == BLACK else -value
	return score


static func _negamax(board: PackedInt32Array, depth: int, ply: int, side: int, alpha: float, beta: float) -> float:
	var turns := generate_turns(board, side)
	if turns.is_empty():
		return -(float(MATE) - float(ply))
	if depth <= 0:
		return -float(side) * evaluate(board)

	turns.sort_custom(func(a, b) -> bool: return int(a["captures"]) > int(b["captures"]))
	var best := -INF
	for turn in turns:
		var next := apply_turn(board, turn)
		var value := -_negamax(next, depth - 1, ply + 1, opposite(side), -beta, -alpha)
		best = maxf(best, value)
		alpha = maxf(alpha, best)
		if alpha >= beta:
			break
	return best


static func search_depth(board: PackedInt32Array) -> int:
	var pieces := 0
	for square in CELL_COUNT:
		if board[square] != EMPTY:
			pieces += 1
	return 5 if pieces <= 8 else 4


## Picks a turn for `side` with a shallow alpha-beta search; ties are broken
## randomly so repeated games do not feel identical.
static func choose_turn(board: PackedInt32Array, side: int, depth: int = -1) -> Dictionary:
	var turns := generate_turns(board, side)
	if turns.is_empty():
		return {}
	if depth < 0:
		depth = search_depth(board)
	turns.sort_custom(func(a, b) -> bool: return int(a["captures"]) > int(b["captures"]))

	var best_score := -INF
	var best: Array = []
	for turn in turns:
		var next := apply_turn(board, turn)
		var score := -_negamax(next, depth - 1, 1, opposite(side), -INF, INF)
		if score > best_score:
			best_score = score
			best = [turn]
		elif score == best_score:
			best.append(turn)
	if best.is_empty():
		return {}
	return best[randi() % best.size()]
