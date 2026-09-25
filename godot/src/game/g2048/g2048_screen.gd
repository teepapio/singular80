class_name Game2048Screen
extends Screen
## 2048 — sliding tile puzzle with undo, keyboard, gamepad and swipe input.
## Port of `scenes/Game2048Scene.ts`.

const TILE := 118.0
const GAP := 14.0
const PITCH := TILE + GAP
const BOARD_SIZE := Twenty48.SIZE * TILE + float(Twenty48.SIZE + 1) * GAP
const BOARD_X := 150.0
const BOARD_Y := 108.0
const MOVE_TIME := 0.11
const SWIPE_MIN := 28.0

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
var history: Dictionary = {}
var won := false
var keep_playing := false

var _view: BoardView
var _score_label: Label
var _highscore_label: Label
var _best_label: Label
var _drag_start := Vector2.ZERO
var _dragging := false


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

	_score_label = _stat(layer, Vector2(870, 166), "PUNKTE", "0")
	_highscore_label = _stat(layer, Vector2(1075, 166), "HIGHSCORE", "0")
	_best_label = _stat(layer, Vector2(970, 264), "GRÖSSTE KACHEL", "2")

	var controls := Ui.label("← ↑ → ↓   verschieben\nW A S D   verschieben\nWischen   (Touch)\nU / Z     rückgängig\nR         neu starten\nESC       Pause", 15, Color("cbd5e1"))
	controls.position = Vector2(792, 316)
	controls.size = Vector2(360, 180)
	layer.add_child(controls)

	_place(layer, "Neu starten", Vector2(970, 512), func() -> void: reset_game())
	_place(layer, "Rückgängig", Vector2(970, 570), func() -> void: undo())
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
	Twenty48.add_random_tile(board)
	Twenty48.add_random_tile(board)
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
	_refresh()


func _modal_open() -> bool:
	return has_modal()


func _move(dir: String) -> void:
	var plan := Twenty48.slide(board, dir)
	if not bool(plan["moved"]):
		return
	history = {"values": Twenty48.clone_board(board), "score": score}
	board = plan["values"]
	score += int(plan["gained"])
	var spawn: Variant = Twenty48.add_random_tile(board)
	best = maxi(best, Twenty48.highest_value(board))
	Sfx.hit()
	if not won and Twenty48.has_value(board, Twenty48.WIN_VALUE):
		_on_win()
	elif not Twenty48.can_move(board):
		_on_game_over()
	_refresh()


func undo() -> void:
	if history.is_empty() or _modal_open():
		return
	board = history["values"]
	score = int(history["score"])
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
	column.add_child(Ui.title("2048 erreicht!", 44, Color("edc22e")))
	column.add_child(Ui.label("Punkte: %s" % Ui.format_number(score), 24, UiTheme.TEXT))
	column.add_child(Ui.button("Weiter spielen", Vector2(360, 56), UiTheme.ACCENT, func() -> void:
		keep_playing = true
		close_modals()
	))
	column.add_child(Ui.button("Neu starten", Vector2(360, 56), UiTheme.PANEL_LIGHT, func() -> void: reset_game()))


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
	column.add_child(Ui.title("Kein Zug mehr", 44, Color("f87171")))
	column.add_child(Ui.label("Punkte: %s   ·   Beste Kachel: %d" % [Ui.format_number(score), best], 22, UiTheme.TEXT))
	column.add_child(Ui.button("Neu starten", Vector2(360, 56), UiTheme.ACCENT, func() -> void: reset_game()))
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
	column.add_child(Ui.button("Fortsetzen", Vector2(360, 56), UiTheme.ACCENT, func() -> void: close_modals()))
	column.add_child(Ui.button("Neu starten", Vector2(360, 56), UiTheme.PANEL_LIGHT, func() -> void: reset_game()))
	column.add_child(Ui.button("Lobby", Vector2(360, 56), UiTheme.PANEL_LIGHT, func() -> void: Router.to_lobby()))


func _refresh() -> void:
	_view.queue_redraw()
	if _score_label == null:
		return
	_score_label.text = Ui.format_number(score)
	_highscore_label.text = Ui.format_number(highscore)
	_best_label.text = str(best)


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


## Draws the well and every tile, including the two freshly spawned ones.
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
