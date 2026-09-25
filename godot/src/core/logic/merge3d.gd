class_name Merge3D
extends RefCounted
## Logic for the two "Merge 3D" editions (Christmas and Halloween).
## Port of `src/game/merge3d.ts`.
##
## The board is a flat array of grid cells; `EMPTY_CELL` (0) is free, anything
## else is the tier (1..MAX_MERGE_TIER) of the item in it. Merging three
## identical items upgrades them to one item of the next tier, merging five
## upgrades them to two.

const MAX_MERGE_TIER := 5
const MERGE_3 := 3
const MERGE_5 := 5
const EMPTY_CELL := 0

const THEME_CHRISTMAS := "christmas"
const THEME_HALLOWEEN := "halloween"

const THEMES := {
	THEME_CHRISTMAS: {
		"id": THEME_CHRISTMAS,
		"title": "Weihnachts-Merge 3D",
		"icon": "✦",
		"tierNames": ["Tannenzapfen", "Zuckerstange", "Glaskugel", "Lebkuchenstern", "Christstern"],
		"tierColors": [Color("b45309"), Color("ef4444"), Color("7dd3fc"), Color("d97706"), Color("facc15")],
		"tierAssets": ["xmas_pinecone", "xmas_candy_cane", "xmas_bauble", "xmas_gingerbread_star", "xmas_star"],
		"background": Color("0a1220"),
		"ground": Color("e2e8f0"),
		"tileColors": [Color("f1f5f9"), Color("cbd5e1")],
		"particle": Color("ffffff"),
		"particleFall": true,
		"accent": Color("ef4444"),
		"sky": Color("bfdbfe"),
		"highscoreKey": Game.HS_MERGE_CHRISTMAS,
	},
	THEME_HALLOWEEN: {
		"id": THEME_HALLOWEEN,
		"title": "Halloween-Merge 3D",
		"icon": "☽",
		"tierNames": ["Kürbiskern", "Süßigkeit", "Mini-Kürbis", "Kürbis", "Geisterkürbis"],
		"tierColors": [Color("fef3c7"), Color("f472b6"), Color("fb923c"), Color("ea580c"), Color("a7f3d0")],
		"tierAssets": ["halloween_seed", "halloween_candy", "halloween_mini_pumpkin", "halloween_pumpkin", "halloween_ghost_pumpkin"],
		"background": Color("0b0616"),
		"ground": Color("1e1035"),
		"tileColors": [Color("2e1065"), Color("3b0764")],
		"particle": Color("fb923c"),
		"particleFall": false,
		"accent": Color("f97316"),
		"sky": Color("7c3aed"),
		"highscoreKey": Game.HS_MERGE_HALLOWEEN,
	},
}


static func theme_by_id(id: String) -> Dictionary:
	return THEMES[THEME_HALLOWEEN if id == THEME_HALLOWEEN else THEME_CHRISTMAS]


static func tier_name(theme: Dictionary, tier: int) -> String:
	if tier <= 0:
		return "—"
	var index: int = clampi(tier, 1, MAX_MERGE_TIER) - 1
	return str((theme["tierNames"] as Array)[index])


static func tier_color(theme: Dictionary, tier: int) -> Color:
	if tier <= 0:
		return Color("64748b")
	var index: int = clampi(tier, 1, MAX_MERGE_TIER) - 1
	return (theme["tierColors"] as Array)[index]


static func tier_asset(theme: Dictionary, tier: int) -> String:
	var index: int = clampi(tier, 1, MAX_MERGE_TIER) - 1
	return str((theme["tierAssets"] as Array)[index])


## Score value of a single item of the given tier.
static func tier_value(tier: int) -> int:
	if tier <= 0:
		return 0
	return int(pow(3.0, float(mini(MAX_MERGE_TIER, tier) - 1)))


static func create_board(size: int) -> PackedInt32Array:
	var count: int = maxi(1, size)
	var board := PackedInt32Array()
	board.resize(count * count)
	board.fill(EMPTY_CELL)
	return board


static func free_cells(board: PackedInt32Array) -> PackedInt32Array:
	var result := PackedInt32Array()
	for i in board.size():
		if board[i] == EMPTY_CELL:
			result.append(i)
	return result


static func count_tier(board: PackedInt32Array, tier: int) -> int:
	var count := 0
	for cell in board:
		if cell == tier:
			count += 1
	return count


static func highest_tier(board: PackedInt32Array) -> int:
	var highest := 0
	for cell in board:
		highest = maxi(highest, cell)
	return highest


static func used_cells(board: PackedInt32Array) -> int:
	var used := 0
	for cell in board:
		if cell != EMPTY_CELL:
			used += 1
	return used


## Pick a random free cell, or -1 when the board is full.
static func pick_spawn_cell(board: PackedInt32Array) -> int:
	var free := free_cells(board)
	if free.is_empty():
		return -1
	return free[randi() % free.size()]


## Can the given selection be merged? All selected cells must hold the same
## tier, that tier must not be the maximum, and at least `required` cells must
## be selected.
static func merge_is_valid(board: PackedInt32Array, cells: PackedInt32Array, required: int, max_tier: int = MAX_MERGE_TIER) -> bool:
	if cells.size() < required or required < 1:
		return false
	var first := cells[0]
	if first < 0 or first >= board.size():
		return false
	var tier := board[first]
	if tier == EMPTY_CELL or tier >= max_tier:
		return false
	for i in required:
		var cell := cells[i]
		if cell < 0 or cell >= board.size():
			return false
		if board[cell] != tier:
			return false
	return true


## Performs a 3- or 5-merge on the first `required` selected cells. A 3-merge
## turns three items into one of the next tier, a 5-merge five into two.
## Returns `{}` when the selection is not a valid merge.
static func perform_merge(board: PackedInt32Array, cells: PackedInt32Array, required: int, max_tier: int = MAX_MERGE_TIER) -> Dictionary:
	if not merge_is_valid(board, cells, required, max_tier):
		return {}
	var next := board.duplicate()
	var tier := next[cells[0]]
	var created_count := 2 if required >= MERGE_5 else 1
	for i in required:
		next[cells[i]] = EMPTY_CELL
	var created: Array = []
	for i in created_count:
		var cell := cells[i]
		next[cell] = tier + 1
		created.append({"cell": cell, "tier": tier + 1})
	return {"board": next, "created": created, "score": tier_value(tier) * required, "consumedTier": tier}


## Whether any tier on the board still has enough items for a 3-merge.
static func has_merge_available(board: PackedInt32Array, max_tier: int = MAX_MERGE_TIER) -> bool:
	for tier in range(1, max_tier):
		if count_tier(board, tier) >= MERGE_3:
			return true
	return false


static func is_board_full(board: PackedInt32Array) -> bool:
	for cell in board:
		if cell == EMPTY_CELL:
			return false
	return true


## The run is lost once the board is full and no merge can free a cell.
static func is_game_over(board: PackedInt32Array, max_tier: int = MAX_MERGE_TIER) -> bool:
	return is_board_full(board) and not has_merge_available(board, max_tier)


## Spawn interval in seconds; shrinks as the run progresses but never below `min`.
static func spawn_interval_seconds(elapsed: float, base: float = 2.2, min_interval: float = 0.75) -> float:
	return maxf(min_interval, base - maxf(0.0, elapsed) * 0.015)


## Which tier a newly spawned item gets: mostly tier 1, sometimes tier 2.
static func spawn_tier(elapsed: float) -> int:
	var bonus_chance: float = minf(0.35, maxf(0.0, elapsed) * 0.004)
	return 2 if randf() < bonus_chance else 1
