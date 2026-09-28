class_name TetrisScreen
extends Screen
## Tetris — bag randomiser, hold slot, ghost piece, DAS/ARR handling, the Super
## Rotation System and the Perfect Clear celebration for a completely wiped
## well.
## Port of `scenes/TetrisScene.ts`.

const COLS := 10
const ROWS := 20
const CELL := 30.0
const BOARD_X := 490.0
const BOARD_Y := 60.0
const BOARD_W := COLS * CELL
const BOARD_H := ROWS * CELL
const DAS := 0.15
const ARR := 0.045
const SOFT_DROP := 0.045

## Gold of a wiped well: the headline, the bonus and the glow in the well.
const PERFECT_COLOR := Color("fde68a")

## Violet of a T-Spin: the announcement, the landing spot of the turn that
## scores, and the hint that names the turn.
const SPIN_COLOR := Color("c084fc")

## The Perfect Clear announcement spans the whole stage, because a long line
## ("PERFECT CLEAR!  ·  QUAD  ·  B2B ×2") must not be cut off at the well.
const PERFECT_HEADLINE_Y := 286.0
const PERFECT_BONUS_Y := 348.0

## How far the bonus drifts upwards while it fades, and how fast it gets there
## (in fractions of that distance per second).
const PERFECT_RISE := 24.0
const PERFECT_RISE_SPEED := 3.0

const PIECES := [
	{"color": Color("22d3ee"), "matrix": [[0, 0, 0, 0], [1, 1, 1, 1], [0, 0, 0, 0], [0, 0, 0, 0]]},
	{"color": Color("3b82f6"), "matrix": [[1, 0, 0], [1, 1, 1], [0, 0, 0]]},
	{"color": Color("f59e0b"), "matrix": [[0, 0, 1], [1, 1, 1], [0, 0, 0]]},
	{"color": Color("facc15"), "matrix": [[1, 1], [1, 1]]},
	{"color": Color("22c55e"), "matrix": [[0, 1, 1], [1, 1, 0], [0, 0, 0]]},
	{"color": Color("a855f7"), "matrix": [[0, 1, 0], [1, 1, 1], [0, 0, 0]]},
	{"color": Color("ef4444"), "matrix": [[1, 1, 0], [0, 1, 1], [0, 0, 0]]},
]

var board: Array = []
var piece: Dictionary = {}
var queue: Array = []
var hold_type := -1
var can_hold := true
var score := 0
var lines := 0
var level := 1
var highscore := 0
var drop_timer := 0.0
var drop_interval := 0.8
var h_dir := 0
var h_timer := 0.0
var paused := false
var game_over := false

# --- skill scoring ---
# A T-Spin only counts when the *last* successful action was a rotation, so any
# move, slide or drop cancels the pending spin.
var last_move_was_rotation := false
var combo := 0
var back_to_back := 0
var clear_message := ""
var clear_message_color := Color("facc15")
var clear_flash := 0.0
var danger := 0

# --- rotation (Super Rotation System) ---
# Every piece remembers its state, because the kick a turn needs depends on
# which way it points: 0 is the spawn state, then R, 2 and L.
var spin_preview: Dictionary = {}
# Free cells per row, cached for the preview: it asks every frame's worth of
# "would this row be full", and counting empties is far cheaper than copying the
# whole well.
var row_holes: Array[int] = []

# --- Perfect Clear ---
# Wiping the well is the biggest moment the game has, so it gets its own
# announcement, its own fanfare and a run counter the player can chase.
var perfect_clears := 0
var perfect_flash := 0.0
var _perfect_rise := 0.0

## How many upcoming pieces the queue shows; clamped to `TetrisRules`.
var preview_size := 4

var _board_view: BoardView
var _score_label: Label
var _level_label: Label
var _lines_label: Label
var _highscore_label: Label
var _combo_label: Label
var _b2b_label: Label
var _perfect_stat_label: Label
var _danger_label: Label
var _message_label: Label
var _perfect_headline: Label
var _perfect_bonus: Label
var _preview_button: Button
var _spin_hint: Label
var _modal: Control


func _ready_game() -> void:
	var background := Ui.rect(Color("080c16"))
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stage().add_child(background)

	_board_view = BoardView.new()
	_board_view.screen = self
	_board_view.size = Vector2(1280, 720)
	_board_view.mouse_filter = Control.MOUSE_FILTER_STOP
	stage().add_child(_board_view)

	_build_ui()
	reset_game()


func _build_ui() -> void:
	var layer := stage()
	var title := Ui.label("▦  TETRIS", 28, UiTheme.TEXT, true)
	title.position = Vector2(0, 14)
	title.size = Vector2(1280, 34)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(title)

	_score_label = _stat(layer, 74, "PUNKTE", "0")
	_level_label = _stat(layer, 142, "LEVEL", "1")
	_lines_label = _stat(layer, 210, "LINIEN", "0")
	_combo_label = _stat(layer, 278, "COMBO", "0")
	_b2b_label = _stat(layer, 346, "BACK-TO-BACK", "0")
	_perfect_stat_label = _stat(layer, 414, "PERFEKT", "—")

	_danger_label = Ui.label("", 15, Color("f87171"), true)
	_danger_label.position = Vector2(24, 486)
	_danger_label.size = Vector2(226, 44)
	_danger_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_danger_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layer.add_child(_danger_label)

	# Under the danger line: which turn would score a T-Spin right now, and what
	# it brings. Without it a kick the player does not know by heart is invisible,
	# and the whole T-Spin scoring stays theoretical.
	_spin_hint = Ui.label("", 13, SPIN_COLOR, true)
	_spin_hint.position = Vector2(18, 532)
	_spin_hint.size = Vector2(238, 46)
	_spin_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_spin_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layer.add_child(_spin_hint)

	# The clear announcement sits over the well so the eye stays on the board.
	_message_label = Ui.label("", 30, Color("facc15"), true)
	_message_label.position = Vector2(BOARD_X, BOARD_Y + BOARD_H * 0.32)
	_message_label.size = Vector2(BOARD_W, 40)
	_message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message_label.add_theme_constant_override("outline_size", 8)
	_message_label.add_theme_color_override("font_outline_color", Color("020617"))
	_message_label.modulate.a = 0.0
	layer.add_child(_message_label)

	# A wiped well replaces that small line with a headline and a bonus that
	# floats away, so the best moment of a run cannot be mistaken for a Single.
	# 38 px keeps even the longest line ("…  ·  QUAD  ·  B2B ×2") clear of the
	# stat column on the left and the queue on the right.
	_perfect_headline = Ui.label("", 38, PERFECT_COLOR, true)
	_perfect_headline.position = Vector2(0, PERFECT_HEADLINE_Y)
	_perfect_headline.size = Vector2(1280, 56)
	_perfect_headline.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_perfect_headline.add_theme_constant_override("outline_size", 10)
	_perfect_headline.add_theme_color_override("font_outline_color", Color("020617"))
	_perfect_headline.modulate.a = 0.0
	layer.add_child(_perfect_headline)

	_perfect_bonus = Ui.label("", 30, Color.WHITE, true)
	_perfect_bonus.position = Vector2(0, PERFECT_BONUS_Y)
	_perfect_bonus.size = Vector2(1280, 40)
	_perfect_bonus.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_perfect_bonus.add_theme_constant_override("outline_size", 8)
	_perfect_bonus.add_theme_color_override("font_outline_color", Color("020617"))
	_perfect_bonus.modulate.a = 0.0
	layer.add_child(_perfect_bonus)

	var preview_caption := Ui.label("PREVIEW", 15, UiTheme.TEXT_DIM)
	preview_caption.position = Vector2(970, 68)
	preview_caption.size = Vector2(180, 20)
	preview_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(preview_caption)

	var hold_caption := Ui.label("HOLD", 15, UiTheme.TEXT_DIM)
	hold_caption.position = Vector2(970, 500)
	hold_caption.size = Vector2(180, 20)
	hold_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(hold_caption)

	_highscore_label = Ui.label("", 15, Color("facc15"))
	_highscore_label.position = Vector2(0, 664)
	_highscore_label.size = Vector2(1280, 22)
	_highscore_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(_highscore_label)

	_build_touch_controls(layer)

	# The full control reference lives in the pause overlay; on-screen players
	# only need the essentials.
	var hint := Ui.label("← →  move   ·   ↓  soft drop   ·   ↑  rotate   ·   Space  hard drop   ·   C  hold   ·   ESC  pause", 13, UiTheme.TEXT_MUTED)
	hint.position = Vector2(170, 692)
	hint.size = Vector2(810, 20)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(hint)


## German control reference, shown inside the pause overlay.
const CONTROL_HELP := "← →  bewegen\n↓  sanft fallen\n↑ / W / X  drehen\nZ  gegen den Uhrzeigersinn\nLeertaste  hart fallen\nC / Shift  halten\nESC / P  Pause\nR  neu starten"

## What the violet marks on the board mean, shown next to the control reference:
## the kick tables are only fair if the game says what they do.
const SPIN_HELP := "Violett: Rahmen und Geisterbild zeigen den\nT-Spin, den die nächste Drehung bringt — samt\nKick und Zeilenzahl. Die Drehung selbst ist\nes, die zählt; nötig ist sie immer."


## On-screen controls so the game is fully playable without a keyboard.
func _build_touch_controls(layer: Control) -> void:
	var size := Vector2(66, 58)
	var left := Ui.button("◀", size, UiTheme.PANEL_LIGHT, func() -> void:
		_move_h(-1)
		_refresh()
	)
	left.position = Vector2(20, 586)
	layer.add_child(left)

	var right := Ui.button("▶", size, UiTheme.PANEL_LIGHT, func() -> void:
		_move_h(1)
		_refresh()
	)
	right.position = Vector2(94, 586)
	layer.add_child(right)

	var down := Ui.button("▼", size, UiTheme.PANEL_LIGHT, func() -> void:
		if _try_move_down():
			score += 1
		else:
			_lock_piece()
		_refresh()
	)
	down.position = Vector2(94, 650)
	layer.add_child(down)

	var drop := Ui.button("⤓", Vector2(90, 58), UiTheme.ACCENT, func() -> void:
		_hard_drop()
		_refresh()
	)
	drop.position = Vector2(20, 650)
	layer.add_child(drop)

	var hold := Ui.button("Stop", Vector2(100, 58), UiTheme.PANEL_LIGHT, func() -> void:
		_hold_piece()
		_refresh()
	)
	hold.position = Vector2(996, 650)
	layer.add_child(hold)

	var rotate := Ui.button("↻", Vector2(72, 58), UiTheme.PANEL_LIGHT, func() -> void:
		_rotate(true)
		_refresh()
	)
	rotate.position = Vector2(1188, 650)
	layer.add_child(rotate)

	var rotate_ccw := Ui.button("↺", Vector2(72, 58), UiTheme.PANEL_LIGHT, func() -> void:
		_rotate(false)
		_refresh()
	)
	rotate_ccw.position = Vector2(1108, 650)
	layer.add_child(rotate_ccw)

	# How far to look ahead is a matter of taste, so it is a button rather than a
	# buried setting.
	_preview_button = Ui.button("", Vector2(100, 30), UiTheme.PANEL_LIGHT, _cycle_preview)
	_preview_button.position = Vector2(1010, 452)
	layer.add_child(_preview_button)


## Steps the queue preview through `TetrisRules.PREVIEW_OPTIONS`.
func _cycle_preview() -> void:
	var index := TetrisRules.PREVIEW_OPTIONS.find(preview_size)
	preview_size = TetrisRules.PREVIEW_OPTIONS[(index + 1) % TetrisRules.PREVIEW_OPTIONS.size()]
	_refresh()


func _stat(layer: Control, y: float, caption: String, value: String) -> Label:
	var label := Ui.label(caption, 15, UiTheme.TEXT_DIM)
	label.position = Vector2(60, y)
	label.size = Vector2(180, 20)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(label)
	if value == "":
		return label
	var result := Ui.value_label(value)
	result.position = Vector2(60, y + 24)
	result.size = Vector2(180, 36)
	layer.add_child(result)
	return result


func reset_game() -> void:
	board = []
	for y in ROWS:
		var row: Array = []
		for x in COLS:
			row.append(0)
		board.append(row)
	_recompute_row_holes()
	queue = []
	hold_type = -1
	can_hold = true
	score = 0
	lines = 0
	level = 1
	drop_timer = 0.0
	drop_interval = 0.8
	h_dir = 0
	h_timer = 0.0
	paused = false
	game_over = false
	last_move_was_rotation = false
	combo = 0
	back_to_back = 0
	clear_message = ""
	clear_flash = 0.0
	perfect_clears = 0
	perfect_flash = 0.0
	_perfect_rise = 0.0
	if _perfect_headline != null:
		_perfect_headline.modulate.a = 0.0
		_perfect_bonus.modulate.a = 0.0
	danger = 0
	highscore = Game.highscore(Game.HS_TETRIS)
	close_modals()
	_spawn_next()
	_refresh()


func _process(delta: float) -> void:
	super(delta)
	# The clear announcement fades on its own, even while the game is paused, so
	# a stacked-up screen never shows a stale "TETRIS!".
	if clear_flash > 0.0:
		clear_flash = maxf(0.0, clear_flash - delta * 1.8)
		if _message_label != null:
			_message_label.modulate.a = clampf(clear_flash * 2.2, 0.0, 1.0)
	_fade_perfect_clear(delta)

	if Input.is_action_just_pressed("restart"):
		reset_game()
		return
	if Input.is_action_just_pressed("pause"):
		_toggle_pause()
		return
	if paused or game_over or piece.is_empty():
		return

	_handle_horizontal(delta)
	if _pressed_any(["rotate_cw"]):
		_rotate(true)
	if _pressed_any(["rotate_ccw"]):
		_rotate(false)
	if _pressed_any(["hold_piece"]):
		_hold_piece()
	if _pressed_any(["hard_drop"]):
		_hard_drop()

	var soft := Input.is_action_pressed("soft_drop")
	var interval: float = SOFT_DROP if soft else drop_interval
	drop_timer += delta
	var guard := 0
	while drop_timer >= interval and guard < 40:
		guard += 1
		drop_timer -= interval
		if not _try_move_down():
			_lock_piece()
			break
		if soft:
			score += 1
	_refresh()



func _pressed_any(actions: Array) -> bool:
	for action in actions:
		if Input.is_action_just_pressed(action):
			return true
	return false


func _handle_horizontal(delta: float) -> void:
	if Input.is_action_just_pressed("move_left"):
		_move_h(-1)
		h_dir = -1
		h_timer = DAS
	if Input.is_action_just_pressed("move_right"):
		_move_h(1)
		h_dir = 1
		h_timer = DAS

	var left_held := Input.is_action_pressed("move_left")
	var right_held := Input.is_action_pressed("move_right")
	if h_dir == -1 and not left_held:
		h_dir = 1 if right_held else 0
		h_timer = DAS
	elif h_dir == 1 and not right_held:
		h_dir = -1 if left_held else 0
		h_timer = DAS

	if h_dir != 0:
		h_timer -= delta
		var guard := 0
		while h_timer <= 0.0 and guard < 20:
			guard += 1
			_move_h(h_dir)
			h_timer += ARR


func _collides(matrix: Array, px: int, py: int) -> bool:
	for y in matrix.size():
		var row: Array = matrix[y]
		for x in row.size():
			if int(row[x]) == 0:
				continue
			var bx: int = px + x
			var by: int = py + y
			if bx < 0 or bx >= COLS or by >= ROWS:
				return true
			if by >= 0 and int(board[by][bx]) != 0:
				return true
	return false


func _refill_queue() -> void:
	var bag: Array = [0, 1, 2, 3, 4, 5, 6]
	for i in range(bag.size() - 1, 0, -1):
		var j := randi() % (i + 1)
		var tmp: Variant = bag[i]
		bag[i] = bag[j]
		bag[j] = tmp
	queue.append_array(bag)


func _make_piece(type: int) -> Dictionary:
	var source: Array = (PIECES[type] as Dictionary)["matrix"]
	var matrix: Array = []
	for row in source:
		matrix.append((row as Array).duplicate())
	# Every piece comes out of the hold slot and out of the queue pointing up, so
	# the rotation state always starts at 0.
	return {
		"type": type, "matrix": matrix, "state": TetrisRules.STATE_0,
		"x": int(floor(float(COLS - (source[0] as Array).size()) * 0.5)), "y": 0,
	}


func _spawn_next() -> void:
	if queue.is_empty():
		_refill_queue()
	var type: int = int(queue.pop_front())
	piece = _make_piece(type)
	drop_timer = 0.0
	if _collides(piece["matrix"], piece["x"], piece["y"]):
		piece = {}
		_trigger_game_over()
	_update_spin_preview()


func _hold_piece() -> void:
	if piece.is_empty() or not can_hold:
		return
	var current: int = piece["type"]
	can_hold = false
	if hold_type == -1:
		hold_type = current
		_spawn_next()
		can_hold = false
	else:
		var swapped := hold_type
		hold_type = current
		piece = _make_piece(swapped)
		if _collides(piece["matrix"], piece["x"], piece["y"]):
			piece = {}
			_trigger_game_over()
	_update_spin_preview()


## Turn the piece. The Super Rotation System decides *how far* it has to be
## shoved for the turn to work, which is what makes a T-Spin out of a wall or a
## floor possible; the rules own the tables, the screen only moves the piece and
## remembers the new state.
func _rotate(clockwise: bool) -> void:
	if piece.is_empty():
		return
	var plan := TetrisRules.plan_rotation(
		int(piece["type"]), int(piece["state"]), int(piece["x"]), int(piece["y"]),
		piece["matrix"] as Array, clockwise, _collides)
	if plan.is_empty():
		return
	piece["matrix"] = plan["matrix"]
	piece["x"] = int(plan["x"])
	piece["y"] = int(plan["y"])
	piece["state"] = int(plan["state"])
	last_move_was_rotation = true
	_update_spin_preview()


## The turn that would score a T-Spin with the piece where it is now, and the
## spot it would come to rest in. Cached rather than recomputed per frame: it
## changes only when the piece or the well does, and the board view only reads
## it.
func _update_spin_preview() -> void:
	spin_preview = {}
	if piece.is_empty() or game_over:
		return
	spin_preview = TetrisRules.spin_preview(
		int(piece["type"]), int(piece["state"]), int(piece["x"]), int(piece["y"]),
		piece["matrix"] as Array, row_holes, _filled_at, _collides)


## Count the free cells per row once, after the well changed.
func _recompute_row_holes() -> void:
	row_holes.clear()
	for y in ROWS:
		var empty_cells := 0
		for x in COLS:
			if int(board[y][x]) == 0:
				empty_cells += 1
		row_holes.append(empty_cells)


func _try_move_down() -> bool:
	if piece.is_empty():
		return false
	if _collides(piece["matrix"], piece["x"], int(piece["y"]) + 1):
		return false
	piece["y"] = int(piece["y"]) + 1
	last_move_was_rotation = false
	_update_spin_preview()
	return true


func ghost_y() -> int:
	if piece.is_empty():
		return 0
	var y := int(piece["y"])
	while not _collides(piece["matrix"], piece["x"], y + 1):
		y += 1
	return y


## Whether the well is crowded enough to hurt; drives the HUD warning.
func danger_level() -> int:
	return TetrisRules.danger_level(board)


func _hard_drop() -> void:
	if piece.is_empty():
		return
	var distance := 0
	while _try_move_down():
		distance += 1
	score += distance * 2
	Sfx.hit()
	_lock_piece()


## True when a board cell counts as occupied for T-Spin detection. Walls and the
## ceiling above the well count too, which is what makes a wall kick register.
func _filled_at(x: int, y: int) -> bool:
	if x < 0 or x >= COLS or y >= ROWS:
		return true
	if y < 0:
		return false
	return int(board[y][x]) != 0


## The spin kind the current piece would score when it locks right now.
func current_spin() -> String:
	if piece.is_empty():
		return "none"
	var corners := TetrisRules.t_corners(int(piece["x"]), int(piece["y"]), _filled_at)
	if not TetrisRules.is_t_spin(int(piece["type"]), last_move_was_rotation, corners):
		return "none"
	return "mini" if TetrisRules.is_t_spin_mini(corners) else "full"


func _lock_piece() -> void:
	if piece.is_empty():
		return
	# The corners must be sampled before the piece joins the well.
	var spin := current_spin()
	var matrix: Array = piece["matrix"]
	for py in matrix.size():
		for px in (matrix[py] as Array).size():
			if int((matrix[py] as Array)[px]) == 0:
				continue
			var by: int = int(piece["y"]) + py
			var bx: int = int(piece["x"]) + px
			if by >= 0 and by < ROWS and bx >= 0 and bx < COLS:
				board[by][bx] = int(piece["type"]) + 1
	piece = {}
	last_move_was_rotation = false
	_clear_lines(spin)
	# The well moved, so the free cells per row are stale — and the next piece's
	# preview counts with them.
	_recompute_row_holes()
	if not game_over:
		_spawn_next()
	else:
		_update_spin_preview()


func _clear_lines(spin: String = "none") -> void:
	var cleared := 0
	var y := ROWS - 1
	# `y` steps up one row at a time; a cleared row compensates, so the one
	# below is checked again.
	while y >= 0:
		var full := true
		for x in COLS:
			if int(board[y][x]) == 0:
				full = false
				break
		if full:
			board.remove_at(y)
			var empty_row: Array = []
			for x in COLS:
				empty_row.append(0)
			board.insert(0, empty_row)
			cleared += 1
			y += 1
		y -= 1

	# `score_clear` may reset a chain that a plain single breaks, so the chain
	# that came *in* is kept for the Perfect Clear check below.
	var chain_before := back_to_back
	var award := TetrisRules.score_clear(cleared, level, combo, back_to_back, spin)
	combo = int(award["combo"])
	back_to_back = int(award["back_to_back"])
	if cleared == 0:
		return

	lines += cleared
	score += int(award["points"])
	# The well was just emptied: that outranks every other announcement.
	var perfect := TetrisRules.is_perfect_clear(board)
	if perfect:
		_celebrate_perfect_clear(cleared, chain_before)
	else:
		_announce_clear(award, spin)

	var next_level := 1 + int(floor(float(lines) / 10.0))
	if next_level != level:
		level = next_level
		drop_interval = maxf(0.08, 0.8 - float(level - 1) * 0.065)
		if not perfect:
			Sfx.level_up()
	elif not perfect:
		Sfx.kill()


## The small line over the well that names an ordinary clear.
func _announce_clear(award: Dictionary, spin: String) -> void:
	clear_message = str(award["message"])
	clear_message_color = SPIN_COLOR if spin != "none" else Color("facc15")
	clear_flash = clampf(float(award["flash"]), 0.2, 0.7)
	if _message_label == null:
		return
	_message_label.text = clear_message
	_message_label.add_theme_color_override("font_color", clear_message_color)
	_message_label.modulate.a = 1.0


## The well is empty. This is the highlight of a run, so it gets the whole
## screen: a bonus, a fanfare, a gold wave through the well and a counter that
## stays for the rest of the run.
##
## `chain_before` is the Back-to-Back chain that came in with this clear.
func _celebrate_perfect_clear(cleared: int, chain_before: int) -> void:
	var award := TetrisRules.perfect_clear(cleared, level, chain_before)
	# A Perfect Clear counts as difficult, so it opens or extends the chain even
	# when the clear that emptied the well was a plain single.
	back_to_back = maxi(back_to_back, int(award["back_to_back"]))
	score += int(award["points"])
	perfect_clears += 1
	perfect_flash = float(award["seconds"])
	_perfect_rise = 0.0
	# The small announcement would compete with the headline, so it stands down.
	clear_message = str(award["text"])
	clear_message_color = PERFECT_COLOR
	clear_flash = 0.0
	Sfx.coin()
	Sfx.level_up()
	if _perfect_headline == null:
		return
	_message_label.modulate.a = 0.0
	_perfect_headline.text = str(award["text"])
	_perfect_headline.modulate.a = 1.0
	_perfect_bonus.text = "+%d" % int(award["points"])
	_perfect_bonus.position.y = PERFECT_BONUS_Y
	_perfect_bonus.modulate.a = 1.0


## Runs the celebration down: the headline fades, the bonus floats away and the
## gold wave in the well dies out. Like the clear announcement it keeps running
## while the game is paused, so a frozen celebration never stays behind.
func _fade_perfect_clear(delta: float) -> void:
	if perfect_flash <= 0.0 or _perfect_headline == null:
		return
	perfect_flash = maxf(0.0, perfect_flash - delta)
	_perfect_rise = minf(_perfect_rise + delta * PERFECT_RISE * PERFECT_RISE_SPEED, PERFECT_RISE)
	_perfect_headline.modulate.a = clampf(perfect_flash * 1.6, 0.0, 1.0)
	_perfect_bonus.position.y = PERFECT_BONUS_Y - _perfect_rise
	_perfect_bonus.modulate.a = clampf(perfect_flash * 2.2, 0.0, 1.0)
	if _board_view != null:
		_board_view.queue_redraw()


func _toggle_pause() -> void:
	if game_over:
		return
	paused = not paused
	if paused:
		# The control reference and the explanation of the spin marks sit side by
		# side; both are multi-line, so the overlay gets two columns.
		var help: Array = [SPIN_HELP] + Array(CONTROL_HELP.split("\n"))
		_show_overlay("Pause", UiTheme.TEXT, [
			["Fortsetzen", func() -> void: _toggle_pause()],
			["Neu starten", func() -> void: reset_game()],
			["◀  Lobby", func() -> void: Router.to_lobby()],
		], help)
	else:
		close_modals()
	_refresh()


func _trigger_game_over() -> void:
	if game_over:
		return
	game_over = true
	Sfx.game_over()
	var is_record := score > 0 and score >= highscore
	if score > highscore:
		Game.submit_score(Game.HS_TETRIS, score)
		highscore = score
	var rows := [
		["Punkte: %d" % score],
		["Linien: %d   ·   Level: %d" % [lines, level]],
		["Perfekte Clears: %d" % perfect_clears],
		["★ Neuer Highscore! ★" if is_record else "Highscore: %d" % highscore],
	]
	_show_overlay("GAME OVER", Color("f87171"), [
		["🔁  Nochmal", func() -> void: reset_game()],
		["◀  Lobby", func() -> void: Router.to_lobby()],
	], rows, Color("facc15") if is_record else Color("cbd5e1"))


func _show_overlay(title: String, title_color: Color, buttons: Array, info: Array = [], info_color: Color = Color("cbd5e1")) -> void:
	close_modals()
	_modal = modal()
	_modal.add_child(Ui.backdrop(0.8))
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_modal.add_child(center)
	var row := Ui.hbox(28)
	center.add_child(row)

	var column := Ui.vbox(16)
	row.add_child(column)
	column.add_child(Ui.title(title, 52, title_color))
	for entry in buttons:
		column.add_child(Ui.button(str(entry[0]), Vector2(380, 58), UiTheme.ACCENT if entry[0] == buttons[0][0] else UiTheme.PANEL_LIGHT, entry[1]))

	if not info.is_empty():
		# The control reference sits next to the buttons instead of below them,
		# otherwise the overlay outgrows the screen.
		var help := Ui.vbox(4)
		help.custom_minimum_size = Vector2(300, 0)
		row.add_child(help)
		for line in info:
			var text := Ui.label(str(line), 17, info_color)
			text.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
			help.add_child(text)


func _refresh() -> void:
	_board_view.queue_redraw()
	if _score_label == null:
		return
	_score_label.text = str(score)
	_level_label.text = str(level)
	_lines_label.text = str(lines)
	_highscore_label.text = "Highscore: %d" % highscore
	_combo_label.text = ("×%d" % combo) if combo > 0 else "—"
	_b2b_label.text = ("×%d" % back_to_back) if back_to_back > 0 else "—"
	if _perfect_stat_label != null:
		_perfect_stat_label.text = str(perfect_clears) if perfect_clears > 0 else "—"
	danger = danger_level()
	_danger_label.text = TetrisRules.danger_text(board)
	if _spin_hint != null:
		_spin_hint.text = str(spin_preview["label"]) if not spin_preview.is_empty() else ""
	if _preview_button != null:
		_preview_button.text = "Vorschau %d" % preview_size


func _move_h(dir: int) -> void:
	if piece.is_empty():
		return
	if not _collides(piece["matrix"], int(piece["x"]) + dir, piece["y"]):
		piece["x"] = int(piece["x"]) + dir
		last_move_was_rotation = false
		_update_spin_preview()


## Draws the well, the settled blocks, the ghost and the active piece.
class BoardView:
	extends Control
	var screen: TetrisScreen

	## Where the queue preview starts and how far apart its entries sit.
	const CHAIN_X := 1060.0
	const CHAIN_Y := 108.0
	const CHAIN_STEP := 56.0
	const CHAIN_CELL := 13.0
	const HOLD_Y := 556.0

	func _draw() -> void:
		if screen == null:
			return
		var board_rect := Rect2(BOARD_X, BOARD_Y, BOARD_W, BOARD_H)
		draw_rect(board_rect, Color("0b1220"))
		var x := 0.0
		while x <= float(COLS):
			draw_line(Vector2(BOARD_X + x * CELL, BOARD_Y), Vector2(BOARD_X + x * CELL, BOARD_Y + BOARD_H), Color("1e293b"), 1.0)
			x += 1.0
		var y := 0.0
		while float(y) <= float(ROWS):
			draw_line(Vector2(BOARD_X, BOARD_Y + y * CELL), Vector2(BOARD_X + BOARD_W, BOARD_Y + y * CELL), Color("1e293b"), 1.0)
			y += 1.0

		for row in ROWS:
			for col in COLS:
				var value := int(screen.board[row][col])
				if value != 0:
					_cell(Vector2(BOARD_X + float(col) * CELL, BOARD_Y + float(row) * CELL), (PIECES[value - 1] as Dictionary)["color"], false)

		if not screen.piece.is_empty() and not screen.game_over:
			var color: Color = (PIECES[int(screen.piece["type"])] as Dictionary)["color"]
			_piece(screen.piece["matrix"], int(screen.piece["x"]), screen.ghost_y(), color, true)
			# The turn that would score, in violet: the piece's own ghost says
			# "this is where it falls", the violet one says "this is where it
			# falls if you rotate, and then the spin counts". Without it the kick
			# tables are invisible and a T-Spin looks like bad luck.
			var plan := screen.spin_preview
			if not plan.is_empty():
				_piece(plan["matrix"], int(plan["x"]), int(plan["y"]), SPIN_COLOR, true)
				_spin_frame(Vector2(BOARD_X + float(plan["x"]) * CELL, BOARD_Y + float(plan["y"]) * CELL), SPIN_COLOR)
			_piece(screen.piece["matrix"], int(screen.piece["x"]), int(screen.piece["y"]), color, false)

		# A clear flashes the well, briefly and in the clear's own colour.
		if screen.clear_flash > 0.0:
			draw_rect(board_rect, Color(
				screen.clear_message_color.r,
				screen.clear_message_color.g,
				screen.clear_message_color.b,
				screen.clear_flash * 0.28
			))

		_draw_perfect_clear(board_rect)

		var border := Color("475569")
		if screen.danger == 2:
			border = Color("ef4444")
		elif screen.danger == 1:
			border = Color("f59e0b")
		draw_rect(board_rect.grow(1.5), border, false, 3.0)

		var chain := TetrisRules.preview_chain(screen.queue, screen.preview_size)
		for i in chain.size():
			_preview(chain[i], Vector2(CHAIN_X, CHAIN_Y + float(i) * CHAIN_STEP), CHAIN_CELL)
		_preview(screen.hold_type, Vector2(CHAIN_X, HOLD_Y), 22.0)

	## Outlines the 3×3 box of a T that would score where it lands, so the slot
	## the player has to aim at is visible as a frame and not just as a shape.
	func _spin_frame(at: Vector2, color: Color) -> void:
		draw_rect(Rect2(at - Vector2.ONE, Vector2(CELL * 3.0 + 2.0, CELL * 3.0 + 2.0)), Color(color.r, color.g, color.b, 0.55), false, 2.0)

	## The Perfect Clear celebration: the empty well floods gold, a bright band
	## runs from the ceiling down to the floor and the frame thickens while the
	## announcement is up.
	func _draw_perfect_clear(board_rect: Rect2) -> void:
		if screen.perfect_flash <= 0.0:
			return
		var life: float = clampf(screen.perfect_flash / TetrisRules.PC_CELEBRATION, 0.0, 1.0)
		draw_rect(board_rect, Color(1.0, 0.97, 0.80, 0.10 + 0.26 * life))
		for row in ROWS:
			# Each row fades later than the one above it, so the light travels.
			var wave: float = float(ROWS - 1 - row) / float(ROWS) * 0.55
			var glow: float = clampf((life - wave) * 2.5, 0.0, 1.0) * 0.16
			if glow <= 0.0:
				continue
			draw_rect(Rect2(board_rect.position.x, board_rect.position.y + float(row) * CELL, BOARD_W, CELL),
				Color(1.0, 0.98, 0.85, glow))
		draw_rect(board_rect.grow(1.5), Color(1.0, 0.93, 0.60, 0.30 + 0.70 * life), false, 3.0 + 5.0 * life)

	func _piece(matrix: Array, px: int, py: int, color: Color, ghost: bool) -> void:
		for y in matrix.size():
			for x in (matrix[y] as Array).size():
				if int((matrix[y] as Array)[x]) == 0:
					continue
				var by: int = py + y
				if by < 0:
					continue
				_cell(Vector2(BOARD_X + float(px + x) * CELL, BOARD_Y + float(by) * CELL), color, ghost)

	func _cell(pos: Vector2, color: Color, ghost: bool) -> void:
		var rect := Rect2(pos + Vector2.ONE, Vector2(CELL - 2.0, CELL - 2.0))
		if ghost:
			draw_rect(rect, Color(color.r, color.g, color.b, 0.4), false, 2.0)
			return
		draw_rect(rect, color)
		draw_rect(rect, Color("0f172a"), false, 2.0)

	func _preview(type: int, center: Vector2, cell_size: float) -> void:
		if type < 0:
			return
		var matrix: Array = (PIECES[type] as Dictionary)["matrix"]
		var min_x := 99
		var max_x := -1
		var min_y := 99
		var max_y := -1
		for y in matrix.size():
			for x in (matrix[y] as Array).size():
				if int((matrix[y] as Array)[x]) == 0:
					continue
				min_x = mini(min_x, x)
				max_x = maxi(max_x, x)
				min_y = mini(min_y, y)
				max_y = maxi(max_y, y)
		if max_x < 0:
			return
		var width := float(max_x - min_x + 1) * cell_size
		var height := float(max_y - min_y + 1) * cell_size
		var origin := center - Vector2(width, height) * 0.5 - Vector2(float(min_x) * cell_size, float(min_y) * cell_size)
		var color: Color = (PIECES[type] as Dictionary)["color"]
		for y in matrix.size():
			for x in (matrix[y] as Array).size():
				if int((matrix[y] as Array)[x]) == 0:
					continue
				_cell(origin + Vector2(float(x) * cell_size, float(y) * cell_size), color, false)
