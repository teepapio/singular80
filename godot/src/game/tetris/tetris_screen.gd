class_name TetrisScreen
extends Screen
## Tetris — bag randomiser, hold slot, ghost piece, DAS/ARR handling.
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
const ROTATION_KICKS := [0, -1, 1, -2, 2]

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

var _board_view: BoardView
var _score_label: Label
var _level_label: Label
var _lines_label: Label
var _highscore_label: Label
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

	_score_label = _stat(layer, 78, "PUNKTE", "0")
	_level_label = _stat(layer, 168, "LEVEL", "1")
	_lines_label = _stat(layer, 258, "LINIEN", "0")
	_stat(layer, 352, "NÄCHSTER", "")

	_highscore_label = Ui.label("", 15, Color("facc15"))
	_highscore_label.position = Vector2(0, 666)
	_highscore_label.size = Vector2(1280, 22)
	_highscore_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(_highscore_label)

	var controls := Ui.label("← →  bewegen\n↓  sanft fallen\n↑ / W / X  drehen\nZ  gegen den Uhrzeigersinn\nLeertaste  hart fallen\nC / Shift  halten\nESC / P  Pause\nR  neu starten", 16, Color("cbd5e1"))
	controls.position = Vector2(800, 92)
	controls.size = Vector2(320, 200)
	layer.add_child(controls)

	_build_touch_controls(layer)

	var hint := Ui.label("Tippe die Tasten unten an  ·  dieselben Aktionen gehen mit Tastatur und Gamepad", 13, UiTheme.TEXT_MUTED)
	hint.position = Vector2(0, 694)
	hint.size = Vector2(1280, 20)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(hint)


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

	var hold := Ui.button("Halt", Vector2(100, 58), UiTheme.PANEL_LIGHT, func() -> void:
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
	highscore = Game.highscore(Game.HS_TETRIS)
	close_modals()
	_spawn_next()
	_refresh()


func _process(delta: float) -> void:
	super(delta)
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
	return {"type": type, "matrix": matrix, "x": int(floor(float(COLS - (source[0] as Array).size()) * 0.5)), "y": 0}


func _spawn_next() -> void:
	if queue.is_empty():
		_refill_queue()
	var type: int = int(queue.pop_front())
	piece = _make_piece(type)
	drop_timer = 0.0
	if _collides(piece["matrix"], piece["x"], piece["y"]):
		piece = {}
		_trigger_game_over()


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


func _rotate(clockwise: bool) -> void:
	if piece.is_empty():
		return
	var rotated := _rotate_matrix(piece["matrix"], clockwise)
	for kick in ROTATION_KICKS:
		if not _collides(rotated, int(piece["x"]) + int(kick), piece["y"]):
			piece["matrix"] = rotated
			piece["x"] = int(piece["x"]) + int(kick)
			return


func _rotate_matrix(matrix: Array, clockwise: bool) -> Array:
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


func _try_move_down() -> bool:
	if piece.is_empty():
		return false
	if _collides(piece["matrix"], piece["x"], int(piece["y"]) + 1):
		return false
	piece["y"] = int(piece["y"]) + 1
	return true


func ghost_y() -> int:
	if piece.is_empty():
		return 0
	var y := int(piece["y"])
	while not _collides(piece["matrix"], piece["x"], y + 1):
		y += 1
	return y


func _hard_drop() -> void:
	if piece.is_empty():
		return
	var distance := 0
	while _try_move_down():
		distance += 1
	score += distance * 2
	Sfx.hit()
	_lock_piece()


func _lock_piece() -> void:
	if piece.is_empty():
		return
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
	_clear_lines()
	if not game_over:
		_spawn_next()


func _clear_lines() -> void:
	var cleared := 0
	var y := ROWS - 1
	# `y` wandert immer eine Zeile nach oben; eine geräumte Zeile kompensiert das,
	# damit die darunterliegende erneut geprüft wird.
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
	if cleared == 0:
		return
	lines += cleared
	var base := 100
	if cleared == 2:
		base = 300
	elif cleared == 3:
		base = 500
	elif cleared >= 4:
		base = 800
	score += base * level
	var next_level := 1 + int(floor(float(lines) / 10.0))
	if next_level != level:
		level = next_level
		drop_interval = maxf(0.08, 0.8 - float(level - 1) * 0.065)
		Sfx.level_up()
	else:
		Sfx.kill()


func _toggle_pause() -> void:
	if game_over:
		return
	paused = not paused
	if paused:
		_show_overlay("Pause", UiTheme.TEXT, [
			["Fortsetzen", func() -> void: _toggle_pause()],
			["Neu starten", func() -> void: reset_game()],
			["◀  Lobby", func() -> void: Router.to_lobby()],
		])
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
	var column := Ui.vbox(16)
	center.add_child(column)
	column.add_child(Ui.title(title, 52, title_color))
	if not info.is_empty():
		var text := Ui.label("\n".join(info), 22, info_color)
		text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		column.add_child(text)
	for entry in buttons:
		column.add_child(Ui.button(str(entry[0]), Vector2(380, 58), UiTheme.ACCENT if entry[0] == buttons[0][0] else UiTheme.PANEL_LIGHT, entry[1]))


func _refresh() -> void:
	_board_view.queue_redraw()
	if _score_label != null:
		_score_label.text = str(score)
		_level_label.text = str(level)
		_lines_label.text = str(lines)
		_highscore_label.text = "Highscore: %d" % highscore


func _move_h(dir: int) -> void:
	if piece.is_empty():
		return
	if not _collides(piece["matrix"], int(piece["x"]) + dir, piece["y"]):
		piece["x"] = int(piece["x"]) + dir


## Draws the well, the settled blocks, the ghost and the active piece.
class BoardView:
	extends Control
	var screen: TetrisScreen

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
			_piece(screen.piece["matrix"], int(screen.piece["x"]), int(screen.piece["y"]), color, false)

		draw_rect(board_rect.grow(1.5), Color("475569"), false, 3.0)
		var next_type: int = int(screen.queue[0]) if screen.queue.size() > 0 else -1
		_preview(next_type, Vector2(245, 425), 22.0)
		_preview(screen.hold_type, Vector2(245, 586), 22.0)

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
