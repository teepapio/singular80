class_name Game2048Screen
extends Screen
## 2048 — sliding tile puzzle with a one-move preview, undo, keyboard, gamepad
## and swipe input. Port of `scenes/Game2048Scene.ts`.
## The tile the next move spawns is already on the board as a dashed ghost, so
## the player plans a step ahead instead of reacting to a spawn; it rides along
## with the slide and becomes permanent with that move. Rules live in `Twenty48`.

const TILE := 118.0
const GAP := 14.0
const PITCH := TILE + GAP
const BOARD_SIZE := Twenty48.SIZE * TILE + float(Twenty48.SIZE + 1) * GAP
const BOARD_X := 150.0
const BOARD_Y := 108.0
const MOVE_TIME := 0.11
const SWIPE_MIN := 28.0
## Centre of the ghost tile in the score panel, mirroring the board's.
const NEXT_CENTER := Vector2(975, 396)
const NEXT_SIZE := 68.0

const STYLES := {
	2: {"bg": Color("eee4da"), "fg": Color("776e65")},
	4: {"bg": Color("ede0c8"), "fg": Color("776e65")},
	8: {"bg": Color("f2b179"), "fg": Color("f9f6f2")},
	16: {"bg": Color("f59563"), "fg": Color("f9f6f2")},
	32: {"bg": Color("f67c5f"), "fg": Color("f9f6f2")},
	64: {"bg": Color("f65e3b"), "fg": Color("f9f6f2")},
	128: {"bg": Color("edcf72"), "fg": Color("f9f6f2")},
	256: {"bg": Color("edcc61"), "fg": Color("f9f6f2")},
	512: {"bg": Color("edc850"), "fg": Color("f9f6f2")},
	1024: {"bg": Color("edc53f"), "fg": Color("f9f6f2")},
	2048: {"bg": Color("edc22e"), "fg": Color("f9f6f2")},
}
const SUPER := {"bg": Color("3c3a32"), "fg": Color("f9f6f2")}

var board: Array = []
var score := 0
var highscore := 0
var best := 2
## The tile the next move adds. Empty when the board is too full for one.
var pending: Dictionary = {}
var history: Dictionary = {}
var won := false
var keep_playing := false

var _view: BoardView
var _next_view: NextView
var _score_label: Label
var _highscore_label: Label
var _best_label: Label
## The last values written to the three labels; see `_refresh`.
var _shown_score := -1
var _shown_highscore := -1
var _shown_best := -1
var _drag_start := Vector2.ZERO
var _dragging := false
var _rng := RandomNumberGenerator.new()


func _ready_game() -> void:
	var background := Ui.rect(Color("080c16"))
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stage().add_child(background)

	_view = BoardView.new()
	_view.screen = self
	_view.size = Vector2(1280, 720)
	_view.mouse_filter = Control.MOUSE_FILTER_STOP
	_view.gui_input.connect(_on_view_input)
	stage().add_child(_view)

	_build_ui()
	reset_game()


func _build_ui() -> void:
	var layer := stage()
	var title := Ui.label("▣  2048", 40, UiTheme.TEXT, true)
	title.position = Vector2(0, 24)
	title.size = Vector2(1280, 48)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(title)

	var panel := Ui.rect(Color(0.043, 0.071, 0.125, 0.85), 16, UiTheme.BORDER, 3)
	panel.position = Vector2(760, BOARD_Y - 10.0)
	panel.size = Vector2(420, BOARD_SIZE + 20.0)
	layer.add_child(panel)

	_score_label = _stat(layer, Vector2(860, 168), "POINTS", "0")
	_highscore_label = _stat(layer, Vector2(1090, 168), "HIGHSCORE", "0")
	_best_label = _stat(layer, Vector2(975, 268), "BIGGEST TILE", "2")
	# The ghost tile is drawn by the board view; these are its labels.
	var next_caption := Ui.label("NEXT TILE", 14, UiTheme.TEXT_DIM)
	next_caption.position = NEXT_CENTER + Vector2(-100, -80)
	next_caption.size = Vector2(200, 22)
	next_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(next_caption)
	var next_note := Ui.label("hatches with the next brood and is then final", 12, UiTheme.ACCENT)
	next_note.position = Vector2(790, NEXT_CENTER.y + 46.0)
	next_note.size = Vector2(360, 20)
	next_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(next_note)

	# Its own control, because the board view paints *under* the panel — the
	# preview must be a later sibling.
	_next_view = NextView.new()
	_next_view.screen = self
	_next_view.position = NEXT_CENTER - Vector2(NEXT_SIZE, NEXT_SIZE) * 0.5
	_next_view.size = Vector2(NEXT_SIZE, NEXT_SIZE)
	layer.add_child(_next_view)

	# Controls under the board, where the panel was wasting the width.
	var controls := Ui.label("← ↑ → ↓  ·  W A S D  ·  Swipe   to move\nU / Z   undo        R   restart        ESC   pause", 13, Color("94a3b8"))
	controls.position = Vector2(146, 658)
	controls.size = Vector2(560, 46)
	layer.add_child(controls)

	_place(layer, Loc.resolve("New game"), Vector2(970, 512), func() -> void: reset_game())
	_place(layer, "Undo", Vector2(970, 570), func() -> void: undo())
	_place(layer, "◀  Lobby", Vector2(970, 628), func() -> void: Router.to_lobby())


## Adds a button whose centre is `center` inside the fixed 1280x720 stage.
func _place(layer: Control, text: String, center: Vector2, on_press: Callable) -> void:
	var button := Ui.button(text, Vector2(360, 50), UiTheme.PANEL_LIGHT, on_press)
	button.position = center - Vector2(180, 25)
	layer.add_child(button)


func _stat(layer: Control, center: Vector2, caption: String, value: String) -> Label:
	var label := Ui.label(caption, 14, UiTheme.TEXT_DIM)
	label.position = center - Vector2(100, 34)
	label.size = Vector2(200, 22)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(label)
	var result := Ui.value_label(value)
	result.position = center - Vector2(100, 6)
	result.size = Vector2(200, 40)
	layer.add_child(result)
	return result


func reset_game() -> void:
	board = Twenty48.empty_board()
	score = 0
	best = 2
	won = false
	keep_playing = false
	history = {}
	highscore = Game.highscore(Game.HS_2048)
	close_modals()
	_rng.randomize()
	pending = Twenty48.opening(board, _rng)
	_refresh()


func _process(delta: float) -> void:
	super(delta)
	if Input.is_action_just_pressed("restart"):
		reset_game()
		return
	if Input.is_action_just_pressed("pause"):
		_toggle_pause()
		return
	if Input.is_action_just_pressed("undo"):
		undo()
		return
	if _modal_open():
		return
	if Input.is_action_just_pressed("move_left"):
		_move(Twenty48.LEFT)
	elif Input.is_action_just_pressed("move_right"):
		_move(Twenty48.RIGHT)
	elif Input.is_action_just_pressed("move_up"):
		_move(Twenty48.UP)
	elif Input.is_action_just_pressed("move_down"):
		_move(Twenty48.DOWN)
	# Also after a rejected move: the ghost can be the tile that blocks the last
	# one, so a dead board is reachable without ever completing a move.
	_check_end()
	_refresh()


func _modal_open() -> bool:
	return has_modal()


func _move(dir: String) -> void:
	var plan := Twenty48.slide_pending(board, dir, pending)
	if not bool(plan["moved"]):
		return
	history = {"values": Twenty48.clone_board(board), "score": score, "pending": pending.duplicate(true)}
	board = plan["values"]
	score += int(plan["gained"])
	pending = Twenty48.plan_tile(board, _rng)
	best = maxi(best, Twenty48.highest_value(board))
	Sfx.hit()
	_check_end()
	_refresh()


## Win and loss are decided on the board the player is looking at — tiles plus
## ghost — because that is the position they have to move in.
func _check_end() -> void:
	if _modal_open():
		return
	# `won` silences only the win dialog: after "keep playing" the run must still
	# be able to end.
	if not won and Twenty48.has_value(board, Twenty48.WIN_VALUE):
		_on_win()
		return
	if not Twenty48.can_move_pending(board, pending):
		_on_game_over()


func undo() -> void:
	if history.is_empty() or _modal_open():
		return
	board = history["values"]
	score = int(history["score"])
	pending = history["pending"]
	history = {}
	Sfx.kill()
	_refresh()


func _on_win() -> void:
	won = true
	Game.submit_score(Game.HS_2048, score)
	Sfx.level_up()
	var layer := modal()
	layer.add_child(Ui.backdrop(0.8))
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(center)
	var column := Ui.vbox(14)
	center.add_child(column)
	column.add_child(Ui.title("2048 reached!", 44, Color("edc22e")))
	column.add_child(Ui.label(Loc.f("Points: %s", [Ui.format_number(score)]), 24, UiTheme.TEXT))
	column.add_child(Ui.button("Keep playing", Vector2(360, 56), UiTheme.ACCENT, func() -> void:
		keep_playing = true
		close_modals()
	))
	column.add_child(Ui.button("Restart", Vector2(360, 56), UiTheme.PANEL_LIGHT, func() -> void: reset_game()))


func _on_game_over() -> void:
	if score > highscore:
		highscore = score
		Game.submit_score(Game.HS_2048, score)
	Sfx.game_over()
	var layer := modal()
	layer.add_child(Ui.backdrop(0.82))
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(center)
	var column := Ui.vbox(14)
	center.add_child(column)
	column.add_child(Ui.title("No moves left", 44, Color("f87171")))
	column.add_child(Ui.label(Loc.f("Points: %s   ·   Best tile: %d", [Ui.format_number(score), best]), 22, UiTheme.TEXT))
	column.add_child(Ui.button("Restart", Vector2(360, 56), UiTheme.ACCENT, func() -> void: reset_game()))
	column.add_child(Ui.button("Lobby", Vector2(360, 56), UiTheme.PANEL_LIGHT, func() -> void: Router.to_lobby()))


func _toggle_pause() -> void:
	if has_modal():
		return
	var layer := modal()
	layer.add_child(Ui.backdrop(0.8))
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(center)
	var column := Ui.vbox(14)
	center.add_child(column)
	column.add_child(Ui.title("Pause", 46))
	column.add_child(Ui.button("Continue", Vector2(360, 56), UiTheme.ACCENT, func() -> void: close_modals()))
	column.add_child(Ui.button("Restart", Vector2(360, 56), UiTheme.PANEL_LIGHT, func() -> void: reset_game()))
	column.add_child(Ui.button("Lobby", Vector2(360, 56), UiTheme.PANEL_LIGHT, func() -> void: Router.to_lobby()))


## The board redraws whenever `_refresh` runs — the tiles animate — but the three
## numbers only change when a move lands, so they are compared before they are
## formatted and assigned. Three `String` allocations per frame bought nothing.
func _refresh() -> void:
	_view.queue_redraw()
	if _next_view != null:
		_next_view.queue_redraw()
	if _score_label == null:
		return
	if score == _shown_score and highscore == _shown_highscore and best == _shown_best:
		return
	_shown_score = score
	_shown_highscore = highscore
	_shown_best = best
	_score_label.text = Ui.format_number(score)
	_highscore_label.text = Ui.format_number(highscore)
	_best_label.text = Loc.number(best)


func _on_view_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			_drag_start = touch.position
			_dragging = true
		elif _dragging:
			_dragging = false
			_swipe(touch.position - _drag_start)
	elif event is InputEventScreenDrag and _dragging:
		pass
	elif event is InputEventMouseButton:
		var click := event as InputEventMouseButton
		if click.button_index == MOUSE_BUTTON_LEFT:
			if click.pressed:
				_drag_start = click.position
				_dragging = true
			elif _dragging:
				_dragging = false
				_swipe(click.position - _drag_start)


func _swipe(delta: Vector2) -> void:
	if delta.length() < SWIPE_MIN:
		return
	if absf(delta.x) > absf(delta.y):
		_move(Twenty48.RIGHT if delta.x > 0.0 else Twenty48.LEFT)
	else:
		_move(Twenty48.DOWN if delta.y > 0.0 else Twenty48.UP)


## Dashed frame, translucent fill, readable value — it is the number the player
## has to plan around. Shared by the board ghost and its twin in the score panel.
static func ghost_tile(view: CanvasItem, rect: Rect2, value: int) -> void:
	var style: Dictionary = STYLES.get(value, SUPER) if STYLES.has(value) else SUPER
	view.draw_rect(rect, Color(style["bg"], 0.8))
	dashed(view, rect.grow(-2.0), UiTheme.ACCENT, 3.0, 12.0)
	centred_text(view, rect, str(value), 40, style["fg"])


## Frame as dashes: a ghost must be unmistakable, merging the wrong tile costs
## the player a turn.
static func dashed(view: CanvasItem, rect: Rect2, color: Color, width: float, dash: float) -> void:
	var x := rect.position.x
	var y := rect.position.y
	var w := rect.size.x
	var h := rect.size.y
	var offset := 0.0
	while offset < w:
		var run: float = minf(dash, w - offset)
		view.draw_rect(Rect2(x + offset, y, run, width), color)
		view.draw_rect(Rect2(x + offset, y + h - width, run, width), color)
		offset += dash * 2.0
	offset = 0.0
	while offset < h:
		var run: float = minf(dash, h - offset)
		view.draw_rect(Rect2(x, y + offset, width, run), color)
		view.draw_rect(Rect2(x + w - width, y + offset, width, run), color)
		offset += dash * 2.0


## One line of bold text, centred in a rect.
static func centred_text(view: CanvasItem, rect: Rect2, text: String, size: int, color: Color) -> void:
	var font := Ui.font_bold()
	if font == null:
		return
	var metrics := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size)
	view.draw_string(font, rect.position + Vector2((rect.size.x - metrics.x) * 0.5, (rect.size.y + float(size) * 0.72) * 0.5),
			text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)


## Draws the well and every tile, including the ghost that lands with the next move.
class BoardView:
	extends Control
	var screen: Game2048Screen

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP

	func _draw() -> void:
		if screen == null:
			return
		var origin := Vector2(BOARD_X, BOARD_Y)
		draw_rect(Rect2(origin - Vector2(10, 10), Vector2(BOARD_SIZE + 20.0, BOARD_SIZE + 20.0)), Color("111c2f"))
		draw_rect(Rect2(origin - Vector2(10, 10), Vector2(BOARD_SIZE + 20.0, BOARD_SIZE + 20.0)), Color("334155"), false, 3.0)
		for r in Twenty48.SIZE:
			for c in Twenty48.SIZE:
				draw_rect(Rect2(origin + Vector2(float(c) * PITCH + GAP, float(r) * PITCH + GAP), Vector2(TILE, TILE)), Color("16233a"))
		for r in Twenty48.SIZE:
			for c in Twenty48.SIZE:
				var value: int = int(screen.board[r][c])
				if value == 0:
					continue
				_tile(origin + Vector2(float(c) * PITCH + GAP, float(r) * PITCH + GAP), value)
		_ghost(origin)


	## The tile that lands after the next move, drawn on the board where it will
	## sit: dashed frame, translucent, so it never reads as a settled tile.
	func _ghost(origin: Vector2) -> void:
		var tile: Dictionary = screen.pending
		if tile.is_empty():
			return
		var row := int(tile["row"])
		var col := int(tile["col"])
		if Twenty48.at(screen.board, row, col) != 0:
			return
		Game2048Screen.ghost_tile(self, Rect2(origin + Vector2(float(col) * PITCH + GAP, float(row) * PITCH + GAP),
				Vector2(TILE, TILE)), int(tile["value"]))


	func _tile(pos: Vector2, value: int) -> void:
		var style: Dictionary = STYLES.get(value, SUPER) if STYLES.has(value) else SUPER
		var rect := Rect2(pos, Vector2(TILE, TILE))
		draw_rect(rect, style["bg"])
		draw_rect(rect, Color(0, 0, 0, 0.12), false, 2.0)
		var font := Ui.font_bold()
		if font == null:
			return
		var size := 46
		if value >= 1024:
			size = 32
		elif value >= 128:
			size = 38
		var text := str(value)
		var metrics := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size)
		draw_string(font, pos + Vector2((TILE - metrics.x) * 0.5, (TILE + float(size) * 0.72) * 0.5), text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, size, style["fg"])


## The ghost next to the score, so its size reads while the eye is on the
## numbers. Its own control, painted over the panel.
class NextView:
	extends Control
	var screen: Game2048Screen

	func _draw() -> void:
		if screen == null:
			return
		var rect := Rect2(Vector2.ZERO, size)
		var tile: Dictionary = screen.pending
		if tile.is_empty():
			# A full board promises nothing — say so instead of showing a stale tile.
			Game2048Screen.dashed(self, rect, UiTheme.TEXT_DIM, 3.0, 12.0)
			Game2048Screen.centred_text(self, rect, "—", 40, UiTheme.TEXT_DIM)
			return
		Game2048Screen.ghost_tile(self, rect, int(tile["value"]))
