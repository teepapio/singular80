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
## The squares a selection may land on, and the turn each stands for. Both are
## kept: a target is only the end of a capture chain, the turn is what is
## actually played.
var legal_targets: Array = []
var legal_turns: Array = []
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
## Capture marks for the hint side, one `{"from", "captures"}` per capturing
## stone, recomputed once per position for the red board badges.
var capture_marks: Array = []
## The chain the hint shows, and the squares it marks as movable when nothing
## can be captured.
var hint_steps: Array = []
var hint_moves: Array = []
var _status := ""

var _view: BoardView
var _player_label: Label
var _ai_label: Label
var _message_label: Label
var _capture_label: Label
var _wins_label: Label
var _mode_button: Button
var _hint_button: Button


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
	_wins_label.position = Vector2(0, 642)
	_wins_label.size = Vector2(520, 22)
	_wins_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(_wins_label)

	_capture_label = Ui.label("", 17, Color("f87171"), true)
	_capture_label.position = Vector2(760, 642)
	_capture_label.size = Vector2(520, 22)
	_capture_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(_capture_label)

	var hint := Ui.label("Stein antippen, dann Zielfeld wählen  ·  Schlagzüge werden markiert  ·  ♛ wird zur Königin", 13, UiTheme.TEXT_DIM)
	hint.position = Vector2(0, 666)
	hint.size = Vector2(1280, 18)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(hint)

	_hint_button = _button(layer, 200, 694, "Tipp", show_hint)
	_button(layer, 420, 694, "Neu", func() -> void: reset_game())
	_button(layer, 640, 694, "Zurück", func() -> void: undo())
	_mode_button = _button(layer, 860, 694, "2 Spieler", _toggle_mode)
	_button(layer, 1080, 694, "Lobby", func() -> void: Router.to_lobby())


func _button(layer: Control, x: float, y: float, text: String, on_press: Callable) -> Button:
	var button := Ui.button(text, Vector2(200, 44), UiTheme.PANEL_LIGHT, on_press)
	button.position = Vector2(x - 100, y - 22)
	layer.add_child(button)
	return button


func reset_game() -> void:
	board = Checkers.create_initial_board()
	side = Checkers.WHITE
	forced_from = -1
	last_move_from = -1
	last_move_to = -1
	history = []
	ai_thinking = false
	game_over = false
	ai_timer = 0.0
	_clear_selection()
	_clear_hint()
	_recompute_captures()
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


func _clear_selection() -> void:
	selected = -1
	legal_targets = []
	legal_turns = []


func _refresh() -> void:
	_view.queue_redraw()
	_player_label.text = "Du: %d Steine" % Checkers.count_pieces(board, Checkers.WHITE)
	_ai_label.text = ("KI: %d Steine" % Checkers.count_pieces(board, Checkers.BLACK)) if not two_player else "Gegner: %d Steine" % Checkers.count_pieces(board, Checkers.BLACK)
	_wins_label.text = "Du %d  :  %d KI" % [wins, 0] if not two_player else "Du %d  :  %d Gegner" % [wins, 0]
	_hint_button.disabled = game_over
	if not _status.is_empty():
		_message_label.text = _status
	elif game_over:
		_message_label.text = "Spiel vorbei — Neu starten"
	elif two_player:
		_message_label.text = "Du bist am Zug" if side == Checkers.WHITE else "Gegner ist am Zug"
	else:
		_message_label.text = "Du bist am Zug" if side == Checkers.WHITE else "KI denkt …"


# --- Making captures visible -----------------------------------------------
# The player never has to guess whether a capture is due: every stone that can
# capture wears its count, and the hint lays out the strongest chain with its
# path, so the marked move can be tapped right away.

## The side marks and hints belong to: whoever is to move in two-player mode,
## always the human in single-player.
func _hint_side() -> int:
	return side if two_player else Checkers.WHITE


## Badges and label are computed once per position — never per frame.
func _recompute_captures() -> void:
	capture_marks = [] if game_over else Checkers.capture_candidates(board, _hint_side())
	_update_capture_label()


func _update_capture_label() -> void:
	if game_over or capture_marks.is_empty():
		_capture_label.text = ""
		_capture_label.add_theme_color_override("font_color", UiTheme.TEXT_DIM)
		return
	_capture_label.text = "Größter Schlag: %d Steine" % int((capture_marks[0] as Dictionary)["captures"])
	_capture_label.add_theme_color_override("font_color", Color("f87171"))


func _clear_hint() -> void:
	hint_steps = []
	hint_moves = []
	_status = ""


## Picks the strongest capture and draws its path, or marks the movable stones
## when nothing can be captured.
func show_hint() -> void:
	if game_over:
		return
	_clear_hint()
	if _hint_side() != side:
		_status = "Die KI ist am Zug"
		Sfx.select()
		_refresh()
		return
	var chain := Checkers.best_capture(board, side)
	if chain.is_empty():
		hint_moves = Checkers.movable_squares(board, side)
		_status = "Kein Schlagzug — %d Steine dürfen ziehen" % hint_moves.size()
	else:
		var steps: Array = chain["steps"]
		hint_steps = steps
		selected = int((steps[0] as Array)[0])
		legal_targets = [steps[steps.size() - 1]]
		legal_turns = [chain]
		_status = "Tipp: %d Steine, Zielfeld ist markiert" % int(chain["captures"])
	Sfx.select()
	_refresh()


func undo() -> void:
	if history.is_empty() or ai_thinking:
		return
	var snapshot: Dictionary = history.pop_back()
	board = snapshot["board"]
	side = int(snapshot["side"])
	forced_from = -1
	last_move_from = int(snapshot["lastFrom"])
	last_move_to = int(snapshot["lastTo"])
	game_over = false
	_clear_selection()
	_clear_hint()
	_recompute_captures()
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
			_play_turn(legal_turns[match_index], false)
			return

	# Otherwise a new selection — the old hint is void now.
	_clear_hint()
	if Checkers.side_of(board[square]) != side:
		_clear_selection()
		_refresh()
		return
	if forced_from >= 0 and square != forced_from:
		_clear_selection()
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
		_clear_selection()
		_refresh()
		return
	selected = square
	legal_targets = []
	legal_turns = []
	for turn in chain:
		var steps: Array = turn["steps"]
		# The target is where the chain ends; the whole turn is kept, so a
		# two-jump chain plays in full instead of only its last jump.
		legal_targets.append(steps[steps.size() - 1])
		legal_turns.append(turn)
	Sfx.select()
	_refresh()


func _play_turn(turn: Dictionary, by_ai: bool) -> void:
	_push_history()
	var steps: Array = turn["steps"]
	last_move_from = int((steps[0] as Array)[0])
	last_move_to = int((steps[steps.size() - 1] as Array)[1])
	board = Checkers.apply_turn(board, turn)
	_clear_selection()
	_clear_hint()
	# `generate_turns` yields complete chains — the turn ends here. Leaving
	# `forced_from` set would block the side that moves next.
	forced_from = -1
	Sfx.hit()
	if not _finish_turn(by_ai):
		side = Checkers.opposite(side)
		if not two_player and side == Checkers.BLACK:
			ai_timer = AI_DELAY
			ai_thinking = false
	_recompute_captures()
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
		_recompute_captures()
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

		# Stones that may move, and the capture path shown by the hint.
		for move in screen.hint_moves:
			_highlight(int(move), Color(0.133, 0.773, 0.369, 0.30))
		for step in screen.hint_steps:
			_highlight(int((step as Array)[1]), Color(0.980, 0.800, 0.086, 0.55))
			if int((step as Array)[2]) >= 0:
				_highlight(int((step as Array)[2]), Color(0.937, 0.267, 0.267, 0.75))

		for square in Checkers.CELL_COUNT:
			var piece := screen.board[square]
			if piece == Checkers.EMPTY:
				continue
			_piece(square, piece)

		_overlay()
		draw_rect(Rect2(BOARD_X, BOARD_Y, BOARD_PX, BOARD_PX), Color("1c1208"), false, 4.0)

	## Badges and the hint's step numbers, on top of the pieces.
	func _overlay() -> void:
		var font := Ui.font_bold()
		if font == null:
			return
		for mark in screen.capture_marks:
			_badge(font, int((mark as Dictionary)["from"]), int((mark as Dictionary)["captures"]))
		var order := 0
		for step in screen.hint_steps:
			order += 1
			var landed: int = int((step as Array)[1])
			_glyph(font, landed, str(order), 17, Color("fde68a"))
			var taken: int = int((step as Array)[2])
			if taken >= 0:
				_glyph(font, taken, "×", 22, Color("fca5a5"))

	## The red count on a piece that can capture: how many stones it takes.
	func _badge(font: Font, square: int, count: int) -> void:
		var center := _center(square) + Vector2(CELL * 0.30, -CELL * 0.30)
		draw_circle(center, CELL * 0.20, Color("b91c1c"))
		draw_arc(center, CELL * 0.20, 0.0, TAU, 20, Color("fecaca"), 2.0, true)
		var text := str(count)
		var metrics := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 16)
		draw_string(font, center - Vector2(metrics.x * 0.5, -6.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color("fee2e2"))

	## A short mark in the top-left corner of a square.
	func _glyph(font: Font, square: int, text: String, size: int, color: Color) -> void:
		var metrics := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size)
		draw_string(font, _center(square) - Vector2(CELL * 0.28, CELL * 0.28) - Vector2(metrics.x * 0.5, 0.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)

	func _center(square: int) -> Vector2:
		var pos := Vector2(BOARD_X + float(Checkers.col_of(square)) * CELL, BOARD_Y + float(Checkers.row_of(square)) * CELL)
		return pos + Vector2(CELL, CELL) * 0.5

	func _highlight(square: int, color: Color) -> void:
		var pos := Vector2(BOARD_X + float(Checkers.col_of(square)) * CELL, BOARD_Y + float(Checkers.row_of(square)) * CELL)
		draw_rect(Rect2(pos + Vector2(3, 3), Vector2(CELL - 6.0, CELL - 6.0)), color)

	func _piece(square: int, piece: int) -> void:
		var center := _center(square)
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
