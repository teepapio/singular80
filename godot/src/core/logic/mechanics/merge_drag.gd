class_name MergeDrag
extends Mechanic
## Drag to merge, the way Merge Dragons does it: the rules behind suggestion #28
## ("Weihnachts-Merge 3D: this should be a drag to merge game like Merge
## Dragons"). The Christmas and Halloween themes stay exactly where they are —
## only the gesture and the merge rules are new, and both editions share them
## because the themes live in the data, not in the rules.
##
## ## Where the rules come from
##
## Nothing below is invented. Every rule is a measured behaviour of the
## original, and the source is named here so the next session does not research
## it a second time (measured 2026-10-02):
##
## 1. **Dragging is the merge.** "You can drag them by pressing on them and
##    dragging your finger around the screen." —
##    <https://www.mergedragons.com/tips-and-tricks>
## 2. **Three give one, five give two.** "Matching 5 is better than 3 … You get
##    a bonus object!" (Tip #1, same page).
## 3. **Fives come first.** "The game will always merge in multiples of 5 where
##    possible but if you have other multiples it will make 3 merges to minimise
##    the left overs" — r/MergeDragons, *Large Group Merge Bonuses*. So a group
##    of eight becomes three items of the next tier: 5 → 2, then 3 → 1.
## 4. **Standing together is not merging.** "Require Overlap … allows you to
##    place more than 2 identical objects adjacent to each other without
##    merging" — the Merge Dragons wiki, *Merging*. Players leave that setting
##    on, because tidying a camp without triggering a merge is play in itself.
##    A group here therefore never merges on its own: only a drop does.
## 5. **A drop that finds nothing to merge with is a move.** "There are two ways
##    to move objects. You can drag them … Or, you can tap to select them, then
##    tap on an empty space where you want it to go." (same page as 1.)
## 6. **Chain reactions are off by default.** The camp settings players are told
##    to use are "require overlap" ON and "allow chain reactions" OFF, so
##    `chain_merges` starts false: a merge leaves its leftovers for the next drop
##    instead of playing itself out. The behaviour is there for anyone who wants
##    it, one flag away.
##
## ## What is the screen's and what is this file's
##
## The finger is the screen's: it maps a touch onto the board plane and draws the
## item that follows it. Everything a rule can decide is here — which cells a
## drop takes, what comes out, whether a drop is refused, and why. A screen does
## `begin()` on press, `hover()` while the item follows the finger, `preview()`
## for the counter, and `release()` on lift, then builds its nodes from the plan
## that comes back.
##
## The board is the shape `Merge3D` already uses — a flat `PackedInt32Array` of
## tiers with `0` for an empty cell — so a board is handed over unchanged and
## the two modules agree on what a cell is without a conversion step.
##
## ## Wiring it into a board screen
##
##     var drag := MechanicsIndex.by_id('merge_drag') as MergeDrag
##     drag.max_tier = Merge3D.MAX_MERGE_TIER
##
##     # press — the cell under the finger, and the node that leaves the board
##     if drag.begin(board, _cell_at(event.position), GRID):
##         grabbed = items[drag.origin()]['node']
##
##     # while dragging — the item follows the finger, the board does not move
##     drag.hover(_cell_at(event.position))
##     grabbed.position = event.position
##
##     # lift — one line per kind of outcome
##     var plan := drag.release()
##     if plan['outcome'] == MergeDrag.MERGED or plan['outcome'] == MergeDrag.MOVED:
##         board = plan['board']
##         for cell in plan['consumed']:
##             _remove_item_node(cell)
##         for entry in plan['left']:
##             _add_item_node(entry['cell'], entry['tier'], false)
##         for entry in plan['created']:
##             _add_item_node(entry['cell'], entry['tier'], true)
##         for step in plan['steps']:
##             score += Merge3D.merge_score(step['tier'], step['required'])
##
## `_cell_at()` is the one ray a screen needs, and
## `godot/src/game/candy_match3/candy_match3_screen.gd:869` already has the same
## one: `Plane(Vector3(0, 0, 1), 0.0).intersects_ray()` against
## `camera.project_ray_origin()` / `project_ray_normal()`, then
## `Vector2(point.x, point.z)` into `cell_at()`. Mind the sign of the row axis —
## a board that counts its rows towards `-z` needs `-point.z`, and getting it
## wrong puts every drop one tile off, which a player reads as "the game ignores
## my drag".

## An empty cell, and the tiers are 1..max_tier.
const EMPTY_CELL := 0
const MERGE_3 := 3
const MERGE_5 := 5
## A 5-merge pays two items, a 3-merge one. The second item is the "bonus
## object" the original's first tip is about.
const SPAWN_2 := 2
## The ceiling of the ladder, matching `Merge3D.MAX_MERGE_TIER`. A tier that is
## already the top one does not merge: the drop is refused rather than inventing
## a tier above the ladder.
const MAX_TIER := 5
## A chain ends on its own — every step turns five items into two or three into
## one, so the board always loses items. The cap is a guard for a caller that
## hands in a `max_tier` the board does not use, and costs nothing.
const CHAIN_STEP_CAP := 32

## What a drop did, or why it did nothing. A screen has to be able to say *why*
## a drop was refused: "nothing happened" is the one message a player cannot act
## on.
const MERGED := "merged"
const MOVED := "moved"
const NO_DRAG := "no-drag"
const OUT_OF_RANGE := "out-of-range"
const SAME_CELL := "same-cell"
const OTHER_TIER := "other-tier"
const TOP_TIER := "top-tier"
const TOO_SMALL := "group-too-small"

## Which cells count as neighbours, clockwise from the top. Four, not eight:
## a merge chain in the original follows the tiles, and a square board with
## diagonals would let two items hold a group together that a player sees as two
## separate rows.
const NEIGHBOURS: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]

## The highest tier that still merges. A screen hands its own ladder in, so the
## rules carry no second copy of the five numbers in `Merge3D`.
var max_tier: int = MAX_TIER
## Whether one merge may trigger the next (rule 6). Off, like the original's
## setting.
var chain_merges := false

## The board as it was when the finger went down, the cell the item was taken
## from, and the cell it is currently over. The board keeps the item in place —
## a cell is only emptied inside a plan — so a refused drop changes nothing and
## a screen can assign the returned board without asking.
var _board := PackedInt32Array()
var _origin := -1
var _hover := -1

## Scratch space for the group search, grown once per board size and then
## reused. A drag asks for the group on every frame the counter is visible, and
## a search that allocated per call would be the one allocation in this game
## that scales with the finger.
var _group := PackedInt32Array()
var _seen := PackedInt32Array()
var _stack := PackedInt32Array()
var _group_count := 0
## Visit stamps, so a search never clears the buffer it is about to read.
var _stamp := 0

## The board's shape in columns and rows. `Merge3D`'s board is square, so
## `begin()` can take the width alone; a rectangular board passes both.
var _width := 0
var _height := 0


func _init() -> void:
	id = "merge_drag"
	mechanic_name = "Merge Dragons drag"
	# No description on purpose. A description is a line the player can read, and
	# this mechanic has none of its own: the screen's instruction label says the
	# rules to the player, and this file's header says them to whoever reads it.
	description = ""


# --- the drag ----------------------------------------------------------------

## A finger went down on `cell`. Returns false when there is nothing to pick up,
## which is also how the screen learns that a touch on bare board is not a drag.
## `width` is the board's column count, `height` its row count (0 means square).
func begin(board: PackedInt32Array, cell: int, width: int, height: int = 0) -> bool:
	_board = board
	_width = maxi(width, 1)
	_height = maxi(height, _width) if height > 0 else _width
	_ensure_buffers(board.size())
	_origin = -1
	_hover = -1
	if cell < 0 or cell >= board.size() or board[cell] == EMPTY_CELL:
		return false
	_origin = cell
	_hover = cell
	return true


## The item follows the finger. -1 means it left the board, which is how a
## player aborts a merge by dragging away.
func hover(cell: int) -> void:
	_hover = cell if cell >= 0 and cell < _board.size() else -1


## The drag is over, one way or the other. The state is cleared; the plan is
## the caller's from here.
func cancel() -> void:
	_origin = -1
	_hover = -1


func dragging() -> bool:
	return _origin >= 0


## The cell the item was taken from, -1 when no drag is running.
func origin() -> int:
	return _origin


## The cell the item is over right now, -1 for off-board.
func target() -> int:
	return _hover


func group_count() -> int:
	return _group_count


## The group's cells in ascending order, for a screen that rings them while the
## drag runs. Reading them one at a time is what keeps the per-frame path free of
## allocations.
func group_at(index: int) -> int:
	if index < 0 or index >= _group_count:
		return -1
	return _group[index]


## What a drop on the current cell would do, without touching the board: the
## outcome, the tier under the finger, how many items the group holds and how
## many come out of it. Cheap enough to ask every frame.
func preview() -> Dictionary:
	var verdict := classify()
	var result := {"outcome": verdict, "tier": 0, "group": 0, "created": 0, "steps": 0}
	if _origin >= 0 and _origin < _board.size():
		result["tier"] = _board[_origin]
	if verdict == MERGED:
		var plan := merge_plan(_group_count + 1, int(result["tier"]), max_tier)
		var created := 0
		for step in plan:
			created += int(step["created"])
		result["group"] = _group_count + 1
		result["steps"] = plan.size()
		result["created"] = created
	return result


# --- the rules ---------------------------------------------------------------

## The merges one drop performs on a group of `group_size` items of `tier`, in
## the order they happen. Fives first, then threes, which is rule 3 and the
## reason a group of eight pays three items instead of one plus five stragglers.
## A group below three pays nothing — that is the whole of rule 1.
static func merge_plan(group_size: int, tier: int, tier_cap: int = MAX_TIER) -> Array:
	var steps: Array = []
	if tier <= EMPTY_CELL or tier >= tier_cap:
		return steps
	var left := group_size
	while left >= MERGE_5:
		steps.append({"required": MERGE_5, "created": SPAWN_2, "tier": tier})
		left -= MERGE_5
	while left >= MERGE_3:
		steps.append({"required": MERGE_3, "created": 1, "tier": tier})
		left -= MERGE_3
	return steps


## How many items a group of `group_size` pays. The number a screen shows while
## the item follows the finger.
static func plan_yield(group_size: int, tier: int, tier_cap: int = MAX_TIER) -> int:
	var total := 0
	for step in merge_plan(group_size, tier, tier_cap):
		total += int(step["created"])
	return total


## Whether a group of this size merges at all.
static func group_merges(group_size: int) -> bool:
	return group_size >= MERGE_3


## The verdict for the current drag, with the group of the target cell filled in.
## The one place that decides what a drop means; `preview()` and `release()` both
## read it, so the counter on the screen and the merge that follows it can never
## disagree.
func classify() -> String:
	# The group belongs to the verdict: cleared first, so a counter that reads
	# `group_count()` after a refused drop sees nothing rather than the group of
	# the cell the finger crossed a moment ago.
	_group_count = 0
	if _origin < 0:
		return NO_DRAG
	if _origin >= _board.size():
		return OUT_OF_RANGE
	if _hover < 0 or _hover >= _board.size():
		return OUT_OF_RANGE
	if _hover == _origin:
		return SAME_CELL
	var tier: int = _board[_origin]
	if _board[_hover] == EMPTY_CELL:
		return MOVED
	if _board[_hover] != tier:
		return OTHER_TIER
	if tier >= max_tier:
		return TOP_TIER
	_collect_group(_board, _hover, tier, _origin)
	if not group_merges(_group_count + 1):
		return TOO_SMALL
	return MERGED


## The lift. Returns the plan, which always carries a `board` — for a refused
## drop that is the board that went in, so a screen can assign it blind.
##
## `outcome` is the verdict, `steps` one entry per merge (`tier`, `required`,
## `cells`, `spawned`) so the caller can score with `Merge3D.merge_score()` and
## animate step by step, `consumed` and `created` are the flat lists for building
## nodes, `left` holds the items that stayed on the board (the dragged item when
## a merge left it out) with the cell each ended up in, and `chain` counts the
## merges the one drop performed.
func release() -> Dictionary:
	var verdict := classify()
	var result := {
		"outcome": verdict,
		"board": _board,
		"steps": [],
		"consumed": PackedInt32Array(),
		"created": [],
		"left": [],
		"chain": 0,
	}
	if verdict == MOVED:
		var moved_board := _board.duplicate()
		var tier: int = _board[_origin]
		moved_board[_origin] = EMPTY_CELL
		moved_board[_hover] = tier
		result["board"] = moved_board
		result["consumed"] = PackedInt32Array([_origin])
		result["left"] = [{"cell": _hover, "tier": tier}]
	elif verdict == MERGED:
		var board := _board
		var held := _origin
		var target := _hover
		var merges := 0
		var consumed := PackedInt32Array()
		var created: Array = []
		var left: Array = []
		var steps: Array = []
		while merges < CHAIN_STEP_CAP:
			var turn := _merge_once(board, held, target)
			if turn.is_empty():
				break
			board = turn["board"]
			consumed.append_array(turn["consumed"])
			created.append_array(turn["created"])
			left.append_array(turn["left"])
			for step in turn["steps"]:
				steps.append(step)
			merges += 1
			if not chain_merges:
				break
			# The chain continues with whatever the merge just produced: the
			# first new item that has a group of its own tier waiting.
			held = -1
			target = _next_chain_cell(board, turn["created"])
			if target < 0:
				break
		result["board"] = board
		result["steps"] = steps
		result["consumed"] = consumed
		result["created"] = created
		result["left"] = left
		result["chain"] = merges
	_origin = -1
	_hover = -1
	return result


# --- board geometry ----------------------------------------------------------

## The cell a point on the board belongs to, or -1 for a point off the board.
## Board-local, in the layout the screens use: x to the right, y downwards
## (which is their z), cell 0 top left. A screen that maps its drag ray onto the
## board plane takes the drop target from here instead of repeating the grid
## arithmetic — and repeating it is how a drag ends up one tile off the item it
## was dropped on.
static func cell_at(point: Vector2, cell_size: float, width: int, height: int = 0) -> int:
	if cell_size <= 0.0 or width < 1:
		return -1
	var rows := height if height > 0 else width
	var col := int(round(point.x / cell_size + (float(width) - 1.0) * 0.5))
	var row := int(round(point.y / cell_size + (float(rows) - 1.0) * 0.5))
	if col < 0 or col >= width or row < 0 or row >= rows:
		return -1
	return row * width + col


## The centre of a cell in the same layout — the inverse of `cell_at()`, and what
## a screen gives the item node while it follows the finger.
static func cell_center(cell: int, cell_size: float, width: int, height: int = 0) -> Vector2:
	if width < 1 or cell < 0:
		return Vector2.ZERO
	var rows := height if height > 0 else width
	var col := cell % width
	var row := int(floor(float(cell - col) / float(width)))
	return Vector2(
		(float(col) - (float(width) - 1.0) * 0.5) * cell_size,
		(float(row) - (float(rows) - 1.0) * 0.5) * cell_size
	)


# --- internals ---------------------------------------------------------------

## One merge of the group around `target` on `board`. `held` is the cell the
## dragged item came from, or -1 when the item is already on the board (the
## second round of a chain). Returns {} when there is nothing to do, and
## otherwise the new board plus the cells, the new items and the survivors.
func _merge_once(board: PackedInt32Array, held: int, target: int) -> Dictionary:
	if target < 0 or target >= board.size():
		return {}
	var tier: int = board[target]
	if tier <= EMPTY_CELL or tier >= max_tier:
		return {}
	_collect_group(board, target, tier, held)
	# The pool decides where the result appears: the target first, so the merge
	# happens where the player let go, then the rest of the group, and the
	# dragged item last — it was on its way out, and a leftover belongs next to
	# the result rather than back in the hole it came from.
	var pool := PackedInt32Array()
	pool.append(target)
	for i in _group_count:
		var cell: int = _group[i]
		if cell != target:
			pool.append(cell)
	if held >= 0:
		pool.append(held)
	var plan := merge_plan(pool.size(), tier, max_tier)
	if plan.is_empty():
		return {}

	var merged_board := board.duplicate()
	if held >= 0:
		merged_board[held] = EMPTY_CELL
	var consumed := PackedInt32Array()
	var created: Array = []
	var left: Array = []
	var steps: Array = []
	var at := 0
	for step in plan:
		var count: int = mini(int(step["required"]), pool.size() - at)
		if count < 1:
			break
		var cells := PackedInt32Array()
		var spawned: Array = []
		for i in count:
			var cell: int = pool[at + i]
			cells.append(cell)
			consumed.append(cell)
			merged_board[cell] = EMPTY_CELL
		for i in int(step["created"]):
			var cell: int = cells[i]
			merged_board[cell] = tier + 1
			spawned.append({"cell": cell, "tier": tier + 1})
			created.append({"cell": cell, "tier": tier + 1})
		steps.append({
			"tier": tier,
			"required": count,
			"cells": cells,
			"spawned": spawned,
		})
		at += count
	# The plan can leave items over — a group of four pays a 3-merge — and the
	# dragged item is the one that is out of place when it does: it is already
	# lifted off its cell. It lands on the first free tile next to the result,
	# and only goes home when the board around the result is closed.
	if held >= 0 and not consumed.has(held):
		var spot := _free_near(merged_board, target)
		var home := spot if spot >= 0 else held
		merged_board[home] = tier
		left.append({"cell": home, "tier": tier})
	return {"board": merged_board, "steps": steps, "consumed": consumed, "created": created, "left": left}


## The first free tile next to `cell`, or -1 when the four neighbours are taken.
## Where an item the merge did not take ends up.
func _free_near(board: PackedInt32Array, cell: int) -> int:
	var col := cell % _width
	var row := int(floor(float(cell - col) / float(_width)))
	for offset in NEIGHBOURS:
		var nc := col + offset.x
		var nr := row + offset.y
		if nc < 0 or nc >= _width or nr < 0 or nr >= _height:
			continue
		var neighbour := nr * _width + nc
		if board[neighbour] == EMPTY_CELL:
			return neighbour
	return -1


## The first new item of `created` that has a group of its own tier big enough to
## merge, or -1. The second round of a chain starts here.
func _next_chain_cell(board: PackedInt32Array, created: Array) -> int:
	for entry in created:
		var cell := int(entry["cell"])
		var tier := int(entry["tier"])
		if tier <= EMPTY_CELL or tier >= max_tier:
			continue
		_collect_group(board, cell, tier, -1)
		if group_merges(_group_count):
			return cell
	return -1


## The same-tier cells around `start`, four neighbours, `start` included — except
## `blocked`, the cell the dragged item came from. That one is not on the board
## any more, and counting it would let an item hold a group together that the
## player has just pulled apart: pulling one bauble out of a row of five must not
## leave a group of five behind.
##
## Filled into `_group` in ascending order, so a plan is the same list every
## time and a test can name its cells. No allocation: the buffers belong to the
## mechanic and are reused for the life of the board.
func _collect_group(board: PackedInt32Array, start: int, tier: int, blocked: int) -> void:
	_group_count = 0
	if start < 0 or start >= board.size() or board[start] != tier:
		return
	_stamp += 1
	_seen[start] = _stamp
	_stack[0] = start
	var top := 1
	while top > 0:
		top -= 1
		var cell: int = _stack[top]
		_group[_group_count] = cell
		_group_count += 1
		var col := cell % _width
		var row := int(floor(float(cell - col) / float(_width)))
		for offset in NEIGHBOURS:
			var nc := col + offset.x
			var nr := row + offset.y
			if nc < 0 or nc >= _width or nr < 0 or nr >= _height:
				continue
			var neighbour := nr * _width + nc
			if neighbour == blocked or board[neighbour] != tier or _seen[neighbour] == _stamp:
				continue
			_seen[neighbour] = _stamp
			_stack[top] = neighbour
			top += 1
	_sort_group()


## The cells of the last search, lowest first. Insertion sort on a board's worth
## of integers: nothing here is big enough to be worth a quicksort, and a merge
## plan that lists its cells in a fixed order is a plan a test can assert on.
func _sort_group() -> void:
	for i in range(1, _group_count):
		var value: int = _group[i]
		var j := i - 1
		while j >= 0 and _group[j] > value:
			_group[j + 1] = _group[j]
			j -= 1
		_group[j + 1] = value


func _ensure_buffers(size: int) -> void:
	var count := maxi(size, 1)
	if _group.size() < count:
		_group.resize(count)
	if _seen.size() < count:
		# A new board starts with fresh stamps, so nothing is ever "already
		# visited" on the first search over it.
		_seen.resize(count)
		_seen.fill(0)
		_stamp = 0
	if _stack.size() < count:
		_stack.resize(count)
