class_name DameScreen
extends Screen
## Dame (international draughts) against a computer opponent, with an optional
## local two-player mode. Port of `scenes/DameScene.ts`.

const CELL := 68.0
const BOARD_PX := Checkers.BOARD_SIZE * CELL
const BOARD_X := 640.0 - BOARD_PX * 0.5
const BOARD_Y := 96.0
const MAX_CROWNS := 24
const AI_DELAY := 0.26

var board: PackedInt32Array = Checkers.create_initial_board()
var side := Checkers.WHITE
var selected := -1
var legal_targets: Array = []
var forced_from := -1
var last_move_from := -1
var last_move_to := -1
var history: Array = []
var two_player := false
var ai_thinking := false
var game_over := false
var wins := 0
var ai_timer := 0.0
var show_legal := true

var _view: BoardView
var _player_label: Label
var _ai_label: Label
var _message_label: Label
var _wins_label: Label
var _mode_button: Button


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
	var title := Ui.label("◼  DAME", 28, UiTheme.TEXT, true)
	title.position = Vector2(0, 16)
	title.size = Vector2(1280, 34)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(title)

	_player_label = Ui.label("", 18, Color("f1f5f9"), true)
	_player_label.position = Vector2(180, 56)
	_player_label.size = Vector2(360, 26)
	_player_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(_player_label)

	_ai_label = Ui.label("", 18, Color("f1f5f9"), true)
	_ai_label.position = Vector2(740, 56)
	_ai_label.size = Vector2(360, 26)
	_ai_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(_ai_label)

	_message_label = Ui.label("", 17, Color("7dd3fc"), true)
	_message_label.position = Vector2(380, 56)
	_message_label.size = Vector2(520, 26)
	_message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(_message_label)

	_wins_label = Ui.label("", 15, Color("facc15"))
	_wins_label.position = Vector2(0, 636)
	_wins_label.size = Vector2(1280, 22)
	_wins_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(_wins_label)

	var hint := Ui.label("Stein antippen, dann Zielfeld wählen  ·  Schlagzüge werden markiert  ·  ♛ wird zur Königin", 13, UiTheme.TEXT_DIM)
	hint.position = Vector2(0, 660)
	hint.size = Vector2(1280, 20)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(hint)

	_button(layer, 330, 694, "Neu", func() -> void: reset_game())
	_button(layer, 560, 694, "Zurück", func() -> void: undo())
	_mode_button = _button(layer, 790, 694, "2 Spieler", _toggle_mode)
	_button(layer, 1020, 694, "Lobby", func() -> void: Router.to_lobby())


func _button(layer: Control, x: float, y: float, text: String, on_press: Callable) -> Button:
	var button := Ui.button(text, Vector2(200, 44), UiTheme.PANEL_LIGHT, on_press)
	button.position = Vector2(x - 100, y - 22)
	layer.add_child(button)
	return button


func reset_game() -> void:
	board = Checkers.create_initial_board()
	side = Checkers.WHITE
	selected = -1
	legal_targets = []
	forced_from = -1
	last_move_from = -1
	last_move_to = -1
	history = []
	ai_thinking = false
	game_over = false
	ai_timer = 0.0
	_refresh()


func _toggle_mode() -> void:
	two_player = not two_player
	_mode_button.text = "1 Spieler" if two_player else "2 Spieler"
	reset_game()


func _process(delta: float) -> void:
	super(delta)
	if Input.is_action_just_pressed("restart"):
		reset_game()
		return
	if Input.is_action_just_pressed("undo"):
		undo()
		return
	if game_over or two_player:
		return
	if side == Checkers.BLACK:
		ai_timer -= delta
		if not ai_thinking and ai_timer <= 0.0:
			ai_thinking = true
			_run_ai()
	_refresh()


func _refresh() -> void:
	_view.queue_redraw()
	_player_label.text = "Du: %d Steine" % Checkers.count_pieces(board, Checkers.WHITE)
	_ai_label.text = ("KI: %d Steine" % Checkers.count_pieces(board, Checkers.BLACK)) if not two_player else "Gegner: %d Steine" % Checkers.count_pieces(board, Checkers.BLACK)
	_wins_label.text = "Du %d  :  %d KI" % [wins, 0] if not two_player else "Du %d  :  %d Gegner" % [wins, 0]
	if game_over:
		_message_label.text = "Spiel vorbei — Neu starten"
	elif two_player:
		_message_label.text = "Du bist am Zug" if side == Checkers.WHITE else "Gegner ist am Zug"
	else:
		_message_label.text = "Du bist am Zug" if side == Checkers.WHITE else "KI denkt …"


func undo() -> void:
	if history.is_empty() or ai_thinking:
		return
	var snapshot: Dictionary = history.pop_back()
	board = snapshot["board"]
	side = int(snapshot["side"])
	selected = -1
	legal_targets = []
	forced_from = -1
	last_move_from = int(snapshot["lastFrom"])
	last_move_to = int(snapshot["lastTo"])
	game_over = false
	Sfx.kill()
	_refresh()


func _push_history() -> void:
	history.append({
		"board": board.duplicate(),
		"side": side,
		"lastFrom": last_move_from,
		"lastTo": last_move_to,
	})
	if history.size() > 200:
		history.pop_front()


func _on_view_input(event: InputEvent) -> void:
	if game_over or (not two_player and side != Checkers.WHITE):
		return
	var pos := Vector2.ZERO
	if event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed:
		pos = (event as InputEventScreenTouch).position
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		pos = (event as InputEventMouseButton).position
	else:
		return
	var col := int(floor((pos.x - BOARD_X) / CELL))
	var row := int(floor((pos.y - BOARD_Y) / CELL))
	if not Checkers.in_bounds(row, col):
		return
	_handle_click(Checkers.index_of(row, col))


func _handle_click(square: int) -> void:
	if not legal_targets.is_empty():
		var match_index := -1
		for i in legal_targets.size():
			if int((legal_targets[i] as Array)[1]) == square:
				match_index = i
				break
		if match_index >= 0:
			var turn: Dictionary = _build_turn(legal_targets[match_index])
			_play_turn(turn, false)
			return

	# Otherwise treat the click as a new selection.
	if Checkers.side_of(board[square]) != side:
		selected = -1
		legal_targets = []
		_refresh()
		return
	if forced_from >= 0 and square != forced_from:
		selected = -1
		legal_targets = []
		_refresh()
		return

	var turns := Checkers.generate_turns(board, side)
	var chain: Array = []
	for turn in turns:
		var steps: Array = turn["steps"]
		if steps.is_empty():
			continue
		if int((steps[0] as Array)[0]) == square:
			chain.append(turn)
	if chain.is_empty():
		selected = -1
		legal_targets = []
		_refresh()
		return
	selected = square
	legal_targets = []
	for turn in chain:
		var steps: Array = turn["steps"]
		legal_targets.append(steps[steps.size() - 1])
	Sfx.select()
	_refresh()


func _build_turn(last_step: Array) -> Dictionary:
	var from := int(last_step[0])
	var turns := Checkers.generate_turns(board, side)
	for turn in turns:
		var steps: Array = turn["steps"]
		if steps.size() == 1 and steps[0] == last_step:
			return turn
	# The click came from a partially built selection: rebuild the chain.
	for turn in turns:
		var steps: Array = turn["steps"]
		if steps.size() > 1 and int((steps[0] as Array)[0]) == from:
			for step in steps:
				if step == last_step:
					return turn
	return {"steps": [last_step], "captures": 1 if int(last_step[2]) >= 0 else 0}


func _play_turn(turn: Dictionary, by_ai: bool) -> void:
	_push_history()
	var steps: Array = turn["steps"]
	last_move_from = int((steps[0] as Array)[0])
	last_move_to = int((steps[steps.size() - 1] as Array)[1])
	board = Checkers.apply_turn(board, turn)
	selected = -1
	legal_targets = []
	# A chain may have to be continued by the same piece.
	forced_from = -1
	if steps.size() > 1 and Checkers.is_king(board[last_move_to]):
		forced_from = last_move_to
	elif steps.size() > 1:
		forced_from = last_move_to
	Sfx.hit()
	if not _finish_turn(by_ai):
		side = Checkers.opposite(side)
		if not two_player and side == Checkers.BLACK:
			ai_timer = AI_DELAY
			ai_thinking = false
	_refresh()


## Returns true when the game ended.
func _finish_turn(_by_ai: bool) -> bool:
	var remaining := Checkers.count_pieces(board, side)
	if remaining == 0:
		game_over = true
		_announce()
		return true
	if not Checkers.has_moves(board, side):
		game_over = true
		_announce()
		return true
	return false


func _announce() -> void:
	if side == Checkers.WHITE:
		wins += 0
	Sfx.level_up()


func _run_ai() -> void:
	var turn := Checkers.choose_turn(board, Checkers.BLACK)
	if turn.is_empty():
		ai_thinking = false
		game_over = true
		_refresh()
		return
	await get_tree().create_timer(0.12).timeout
	if not is_inside_tree():
		return
	_play_turn(turn, true)
	ai_thinking = false


## Draws the wooden board, the pieces, the legal targets and the crowns.
class BoardView:
	extends Control
	var screen: DameScreen

	func _draw() -> void:
		if screen == null:
			return
		draw_rect(Rect2(BOARD_X, BOARD_Y, BOARD_PX, BOARD_PX), Color("3b2a16"))
		for row in Checkers.BOARD_SIZE:
			for col in Checkers.BOARD_SIZE:
				var pos := Vector2(BOARD_X + float(col) * CELL, BOARD_Y + float(row) * CELL)
				var light := Checkers.is_playable(row, col)
				draw_rect(Rect2(pos, Vector2(CELL, CELL)), Color("e8d5b0") if light else Color("4a3418"))
				if not light:
					draw_rect(Rect2(pos, Vector2(CELL, CELL)), Color(0, 0, 0, 0.12), false, 2.0)

		if screen.last_move_from >= 0 and screen.last_move_to >= 0:
			_highlight(screen.last_move_from, Color(0.980, 0.800, 0.086, 0.35))
			_highlight(screen.last_move_to, Color(0.980, 0.800, 0.086, 0.45))

		if screen.selected >= 0:
			_highlight(screen.selected, Color(0.055, 0.647, 0.898, 0.45))
		for step in screen.legal_targets:
			var square: int = int((step as Array)[1])
			if int((step as Array)[2]) >= 0:
				_highlight(square, Color(0.937, 0.267, 0.267, 0.55))
			else:
				_highlight(square, Color(0.133, 0.773, 0.369, 0.45))

		for square in Checkers.CELL_COUNT:
			var piece := screen.board[square]
			if piece == Checkers.EMPTY:
				continue
			_piece(square, piece)

		draw_rect(Rect2(BOARD_X, BOARD_Y, BOARD_PX, BOARD_PX), Color("1c1208"), false, 4.0)

	func _highlight(square: int, color: Color) -> void:
		var pos := Vector2(BOARD_X + float(Checkers.col_of(square)) * CELL, BOARD_Y + float(Checkers.row_of(square)) * CELL)
		draw_rect(Rect2(pos + Vector2(3, 3), Vector2(CELL - 6.0, CELL - 6.0)), color)

	func _piece(square: int, piece: int) -> void:
		var pos := Vector2(BOARD_X + float(Checkers.col_of(square)) * CELL, BOARD_Y + float(Checkers.row_of(square)) * CELL)
		var center := pos + Vector2(CELL, CELL) * 0.5
		var radius := CELL * 0.40
		var fill := Color("f8fafc") if piece > 0 else Color("1f2937")
		var rim := Color("94a3b8") if piece > 0 else Color("0f172a")
		draw_circle(center, radius, fill)
		draw_arc(center, radius, 0.0, TAU, 28, rim, 3.0, true)
		draw_circle(center, radius * 0.62, fill.lightened(0.12) if piece > 0 else fill.darkened(0.18))
		if Checkers.is_king(piece):
			var font := Ui.font_bold()
			if font != null:
				var text := "♛"
				var metrics := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 30)
				draw_string(font, center - Vector2(metrics.x * 0.5, -12.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 30, Color("f59e0b"))
