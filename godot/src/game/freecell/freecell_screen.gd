class_name FreeCellScreen
extends Screen
## FreeCell — solitaire with four free cells, supermove capacity, an undo stack
## and the "Hint" button that points at the single best next move. The rules
## live in `Cards.freecell_*`; this file only draws them. Port of
## `scenes/FreeCellScene.ts`.

const COLS := 8
const CARD_W := 104.0
const CARD_H := 144.0
const GAP := 18.0
const MARGIN := 161.0
const TOP_Y := 60.0
const TABLEAU_Y := 230.0
const TABLEAU_BOTTOM := 616.0
const BASE_DY := 32.0
const MIN_DY := 10.0
## A hint removes a decision, so it costs points — otherwise one key solves
## the game.
const HINT_COST := 25
## Seconds the hint stays lit.
const HINT_LIFE := 5.0
## How far a finger travels before a tap turns into a drag. Below this the two
## are indistinguishable to a player, and treating every touch as a drag would
## break tap-tap.
const DRAG_THRESHOLD := 10.0
## The lifted run floats this far above the finger, so a hand never covers the
## cards it is carrying.
const DRAG_LIFT := 86.0
## Seconds the red frame of a refused drop stays on screen.
const REFUSE_LIFE := 0.45
const CONTROLS := "Tap cards and then pick a target  ·  A = bank a card safely  ·  U = undo  ·  R = new  ·  F1 = tip"

var free_cells: Array = [null, null, null, null]
var foundations: Array = [[], [], [], []]
var columns: Array = []
var selection: Dictionary = {}
var moves := 0
var score := 0
var highscore := 0
var won := false
var history: Array = []
## Hints asked for this deal, so the counter shows the tip is rationed.
var hints_used := 0
## The lit hint and the seconds it has left.
var hint_move: Dictionary = {}
var hint_life := 0.0
var _hint_cursor := 0

## Pointer state of the current gesture. `_pointer_down` spans press to release,
## `_drag_active` only starts once the finger has travelled `DRAG_THRESHOLD`, and
## `_drag_grab` is where inside the source card the press landed, so the lifted
## run does not jump under the finger when the drag begins.
var _pointer_down := false
var _drag_active := false
var _drag_press := Vector2.ZERO
var _drag_pos := Vector2.ZERO
var _drag_grab := Vector2.ZERO
## The place that just refused a move, and how long its red frame lasts.
var _refused := Rect2()
var _refuse_life := 0.0

var _view: BoardView
var _moves_label: Label
var _score_label: Label
var _highscore_label: Label
var _help_label: Label


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
	new_deal()


func col_x(index: int) -> float:
	return MARGIN + float(index) * (CARD_W + GAP)


## Vertical overlap between cards so even long columns stay inside the board.
func stack_dy(count: int) -> float:
	if count <= 1:
		return BASE_DY
	var max_dy: float = (TABLEAU_BOTTOM - TABLEAU_Y - CARD_H) / float(count - 1)
	return maxf(MIN_DY, minf(BASE_DY, max_dy))


func _build_ui() -> void:
	var layer := stage()
	var title := Ui.label("♣  FREECELL", 26, UiTheme.TEXT, true)
	title.position = Vector2(0, 20)
	title.size = Vector2(1280, 34)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(title)

	_moves_label = _stat(layer, 300)
	_score_label = _stat(layer, 640)
	_highscore_label = _stat(layer, 980)

	var help_label := Ui.label(CONTROLS, 13, UiTheme.TEXT_DIM)
	help_label.position = Vector2(0, 650)
	help_label.size = Vector2(1280, 20)
	help_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(help_label)
	_help_label = help_label

	_button(layer, 160, 692, Loc.t("freecell.new_deal"), func() -> void: new_deal(), 200.0)
	_button(layer, 400, 692, "Back", func() -> void: undo(), 200.0)
	_button(layer, 640, 692, "Auto", func() -> void: auto_move(), 200.0)
	_button(layer, 880, 692, Loc.t("freecell.hint_cost", {"cost": HINT_COST}), func() -> void: hint(), 200.0)
	_button(layer, 1120, 692, "Lobby", func() -> void: Router.to_lobby(), 200.0)


func _button(layer: Control, x: float, y: float, text: String, on_press: Callable, width: float = 180.0) -> void:
	var button := Ui.button(text, Vector2(width, 44), UiTheme.PANEL_LIGHT, on_press)
	button.position = Vector2(x - width * 0.5, y - 22)
	layer.add_child(button)


func _stat(layer: Control, x: float) -> Label:
	var label := Ui.label("", 18, UiTheme.TEXT)
	label.position = Vector2(x - 160, 618)
	label.size = Vector2(320, 24)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(label)
	return label


func new_deal() -> void:
	var deck := Cards.create_deck()
	Cards.shuffle(deck)
	free_cells = [null, null, null, null]
	foundations = [[], [], [], []]
	columns = []
	for c in COLS:
		columns.append([])
	for i in deck.size():
		(columns[i % COLS] as Array).append(deck[i])
	selection = {}
	moves = 0
	score = 0
	won = false
	history = []
	hints_used = 0
	_hint_cursor = 0
	_clear_hint()
	_end_gesture()
	highscore = Game.highscore(Game.HS_FREECELL)
	close_modals()
	_refresh()


func _process(delta: float) -> void:
	super(delta)
	# The hint pulses while it stands — the only reason to redraw here.
	if hint_life > 0.0:
		hint_life = maxf(0.0, hint_life - delta)
		if hint_life <= 0.0:
			hint_move = {}
			_refresh()
		_redraw_view()
	if _refuse_life > 0.0:
		_refuse_life = maxf(0.0, _refuse_life - delta)
		_redraw_view()
	if Input.is_action_just_pressed("restart"):
		new_deal()
		return
	if won:
		return
	if Input.is_action_just_pressed("undo"):
		undo()
		return
	if Input.is_action_just_pressed("suggest"):
		hint()
		return


## "A" is bound to no input action in the project, so the letter is handled
## here — the help line has always advertised it.
func _unhandled_input(event: InputEvent) -> void:
	if won or not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo or key.keycode != KEY_A:
		return
	auto_move()


## Only the emulated mouse events, never the raw touch events.
##
## `project.godot` turns on both `emulate_mouse_from_touch` and
## `emulate_touch_from_mouse`, so Godot hands the board **two** events for one
## finger press: `Input::_parse_input_event_impl` (`core/input/input.cpp`, 4.5.1,
## lines 840-877) dispatches the real `InputEventScreenTouch` *and* re-enters the
## same function with an emulated `InputEventMouseButton` at the same position.
## The reverse is true for a real mouse (lines 783-794). This handler used to
## answer to both, so every tap ran `_click` twice: the first call selected the
## card, the second one took the selection straight back off it (the
## `selection["start"] == card_index` branch in `_click_column`). Net effect on a
## phone: nothing was ever selectable, hence nothing was ever movable.
##
## `BaseButton` listens to the mouse events only, which is exactly why the
## buttons of this game work on the tablet while the board did not.
func _on_view_input(event: InputEvent) -> void:
	if won:
		return
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index != MOUSE_BUTTON_LEFT:
			return
		if button.pressed:
			_press(button.position)
		else:
			_release(button.position)
		return
	# A drag is delivered to the control that owns the press (`Viewport::
	# _gui_input_event` routes motion to `gui.mouse_focus`), so the run follows
	# the finger even where it leaves the board.
	if event is InputEventMouseMotion and _pointer_down:
		_pointer_move((event as InputEventMouseMotion).position)


func _press(pos: Vector2) -> void:
	_pointer_down = true
	_drag_active = false
	_drag_press = pos
	_drag_pos = pos
	# Tap-tap first: a press on a place the selection may go moves at once,
	# which is the two-tap move the player already knows.
	if _try_drop_at(pos):
		return
	_select_at(pos)


func _pointer_move(pos: Vector2) -> void:
	_drag_pos = pos
	if selection.is_empty():
		return
	if not _drag_active and _drag_press.distance_to(pos) >= DRAG_THRESHOLD:
		_drag_active = true
		_drag_grab = _drag_press - _selection_rect().position
		Sfx.select()
	_redraw_view()


func _release(pos: Vector2) -> void:
	var dragged := _drag_active
	_drag_active = false
	_pointer_down = false
	if selection.is_empty():
		return
	if not dragged:
		# A plain tap: the press has already selected or moved.
		return
	if _try_drop_at(pos):
		return
	# Dropped on nothing that takes it. The selection stays, so the player can
	# carry on with a second tap instead of having to pick the run up again.
	_refuse(_hit(pos))
	_redraw_view()


## What lies under the finger: a free cell, a foundation, a tableau column with
## the card it holds, or nothing. The 18 px gap between two columns belongs to
## both of them, each taking the half nearest to it — a finger never lands on a
## line of maths, and the gap used to swallow the tap whole.
func _hit(pos: Vector2) -> Dictionary:
	var empty := {"zone": "none", "index": -1, "card": -1, "rect": Rect2()}
	if pos.y < TABLEAU_Y:
		for i in 4:
			if _in_slot(pos, col_x(i)):
				return {"zone": "cell", "index": i, "card": 0, "rect": _slot_rect(col_x(i))}
		for i in 4:
			if _in_slot(pos, col_x(4 + i)):
				return {"zone": "foundation", "index": i, "card": 0, "rect": _slot_rect(col_x(4 + i))}
		return empty
	var col := clampi(int(floor((pos.x - MARGIN) / (CARD_W + GAP))), 0, COLS - 1)
	if not _in_slot(pos, col_x(col)):
		return empty
	var cards: Array = columns[col]
	if cards.is_empty():
		return {"zone": "column", "index": col, "card": -1, "rect": _card_rect(col, 0, stack_dy(1))}
	var dy := stack_dy(cards.size())
	for j in range(cards.size() - 1, -1, -1):
		# Topmost first: the cards overlap, so the one drawn on top at this
		# height is the one whose band covers it.
		var rect := _card_rect(col, j, dy)
		if pos.y >= rect.position.y and pos.y <= rect.end.y:
			return {"zone": "column", "index": col, "card": j, "rect": rect}
	# Below the last card: still this column, and still a place to drop.
	return {"zone": "column", "index": col, "card": -1, "rect": _card_rect(col, cards.size() - 1, dy)}


## Is the finger within the horizontal slot of a card, gap included?
func _in_slot(p: Vector2, x: float) -> bool:
	return p.x >= x - GAP * 0.5 and p.x < x + CARD_W + GAP * 0.5


func _slot_rect(x: float) -> Rect2:
	return Rect2(Vector2(x, TOP_Y), Vector2(CARD_W, CARD_H))


func _card_rect(col: int, card: int, dy: float) -> Rect2:
	return Rect2(Vector2(col_x(col), TABLEAU_Y + float(card) * dy), Vector2(CARD_W, CARD_H))


## Try to move the current selection to whatever is under `pos`.
func _try_drop_at(pos: Vector2) -> bool:
	var hit := _hit(pos)
	match str(hit["zone"]):
		"cell":
			return _try_move_to_cell(int(hit["index"]))
		"foundation":
			return _try_move_to_foundation(int(hit["index"]))
		"column":
			return _try_move_to_column(int(hit["index"]))
	return false


## Select what is under `pos`. Only reached when the place does not take the
## current selection, or when there is none.
func _select_at(pos: Vector2) -> void:
	var hit := _hit(pos)
	match str(hit["zone"]):
		"cell":
			_click_cell(int(hit["index"]))
		"column":
			_click_column(int(hit["index"]), int(hit["card"]))
		_:
			if not selection.is_empty():
				_refuse(hit)
			else:
				_refresh()


## The place that just said no: a red frame where the cards were dropped, and
## the selection stays where it was. Clearing the selection here is what made a
## mis-aimed tap look like a game that had stopped listening.
func _refuse(hit: Dictionary) -> void:
	var rect: Rect2 = hit["rect"]
	if rect.size == Vector2.ZERO:
		return
	_refused = rect
	_refuse_life = REFUSE_LIFE
	_redraw_view()


func _click_cell(cell: int) -> void:
	if not selection.is_empty():
		if str(selection["from"]) == "cell" and int(selection["index"]) == cell:
			selection = {}
			_refresh()
			return
		if _try_move_to_cell(cell):
			return
		_refuse({"rect": _slot_rect(col_x(cell))})
		return
	if free_cells[cell] != null:
		selection = {"from": "cell", "index": cell, "start": 0}
	else:
		selection = {}
	_refresh()


func _click_column(col: int, card_index: int) -> void:
	if not selection.is_empty():
		if str(selection["from"]) == "col" and int(selection["index"]) == col and int(selection["start"]) == card_index:
			# The same card again: let the run go.
			selection = {}
			_refresh()
			return
		if _try_move_to_column(col):
			return
		# Anything can be tapped at while something is held, but only a real
		# destination counts as one. The held cards stay where they are.
		var cards: Array = columns[col]
		var dy: float = stack_dy(maxi(cards.size(), 1))
		var rect := _card_rect(col, card_index if card_index >= 0 else maxi(cards.size() - 1, 0), dy)
		_refuse({"rect": rect})
		return
	_select_column(col, card_index)


func _select_column(col: int, card_index: int) -> void:
	var cards: Array = columns[col]
	if not Cards.freecell_sequence(cards, card_index):
		selection = {}
	else:
		selection = {"from": "col", "index": col, "start": card_index}
	Sfx.select()
	_refresh()


func _selection_cards() -> Array:
	if selection.is_empty():
		return []
	if str(selection["from"]) == "cell":
		var card: Variant = free_cells[int(selection["index"])]
		return [] if card == null else [card]
	var column: Array = columns[int(selection["index"])]
	var start := int(selection["start"])
	if start < 0 or start >= column.size():
		return []
	return column.slice(start)


func _remove_selection(count: int) -> void:
	if str(selection["from"]) == "cell":
		free_cells[int(selection["index"])] = null
		return
	var column: Array = columns[int(selection["index"])]
	var start := int(selection["start"])
	for i in count:
		column.remove_at(start)


## How many cards the current selection would carry, without copying the run
## out of its column. The drag highlight asks this for every destination on
## every frame, so it must not allocate.
func _selection_count() -> int:
	if selection.is_empty():
		return 0
	if str(selection["from"]) == "cell":
		return 1
	var column: Array = columns[int(selection["index"])]
	var start := int(selection["start"])
	if start < 0 or start >= column.size():
		return 0
	return column.size() - start


## The card that would sit on top of the run — the one a target has to accept.
func _selection_lead() -> Cards.Card:
	if selection.is_empty():
		return null
	if str(selection["from"]) == "cell":
		return free_cells[int(selection["index"])]
	var column: Array = columns[int(selection["index"])]
	var start := int(selection["start"])
	if start < 0 or start >= column.size():
		return null
	return column[start]


## The single card the selection could park, or null when it is a run of more
## than one — only the bottom card of a column may go into a free cell.
func _selection_single() -> Variant:
	if _selection_count() != 1:
		return null
	return _selection_lead()


## Where the lifted run stands while it is being dragged: the source card's
## place, shifted by the finger and lifted clear of it.
func _selection_rect() -> Rect2:
	if selection.is_empty():
		return Rect2()
	if str(selection["from"]) == "cell":
		return _slot_rect(col_x(int(selection["index"])))
	var column: Array = columns[int(selection["index"])]
	var start := int(selection["start"])
	if start < 0 or start >= column.size():
		return Rect2()
	return _card_rect(int(selection["index"]), start, stack_dy(column.size()))


func _drag_ghost_rect() -> Rect2:
	var rect := _selection_rect()
	rect.position = _drag_pos - _drag_grab - Vector2(0.0, DRAG_LIFT)
	return rect


## The `offset`-th card of the held run, read in place. A dictionary and a
## few ints, no array — this runs for every dragged card on every redraw.
func _card_at_selection(offset: int) -> Variant:
	if offset < 0 or offset >= _selection_count():
		return null
	if str(selection["from"]) == "cell":
		return free_cells[int(selection["index"])]
	return (columns[int(selection["index"])] as Array)[int(selection["start"]) + offset]


## While a run is lifted it is drawn at the finger, so its old place must not
## be drawn as well.
func _is_lifted_card(col: int, card: int) -> bool:
	return _drag_active and not selection.is_empty() \
			and str(selection["from"]) == "col" and int(selection["index"]) == col \
			and card >= int(selection["start"])


func _is_lifted_cell(cell: int) -> bool:
	return _drag_active and not selection.is_empty() \
			and str(selection["from"]) == "cell" and int(selection["index"]) == cell


func _can_move_to_column(col: int) -> bool:
	if selection.is_empty():
		return false
	if str(selection["from"]) == "col" and int(selection["index"]) == col:
		return false
	var count := _selection_count()
	if count <= 0:
		return false
	var first := _selection_lead()
	var target: Array = columns[col]
	if not target.is_empty():
		var top: Cards.Card = target[target.size() - 1]
		if top.rank != first.rank + 1 or Cards.is_red_card(top) == Cards.is_red_card(first):
			return false
	return count <= Cards.freecell_capacity(free_cells, columns, col)


func _can_move_to_cell(cell: int) -> bool:
	if free_cells[cell] != null or _selection_single() == null:
		return false
	if str(selection["from"]) == "cell":
		return int(selection["index"]) != cell
	var column: Array = columns[int(selection["index"])]
	return int(selection["start"]) == column.size() - 1


func _can_move_to_foundation(foundation: int) -> bool:
	var card: Variant = _selection_single()
	if card == null or card.suit != foundation:
		return false
	var pile: Array = foundations[foundation]
	if pile.is_empty():
		return card.rank == 0
	return card.rank == (pile[pile.size() - 1] as Cards.Card).rank + 1


func _try_move_to_column(col: int) -> bool:
	if not _can_move_to_column(col):
		return false
	var moving := _selection_cards()
	var target: Array = columns[col]
	_push_history()
	_remove_selection(moving.size())
	for card in moving:
		target.append(card)
	selection = {}
	moves += 1
	Sfx.hit()
	_check_win()
	_refresh()
	return true


func _try_move_to_cell(cell: int) -> bool:
	if not _can_move_to_cell(cell):
		return false
	var card: Variant = _selection_single()
	_push_history()
	_remove_selection(1)
	free_cells[cell] = card
	selection = {}
	moves += 1
	Sfx.kill()
	_refresh()
	return true


func _try_move_to_foundation(foundation: int) -> bool:
	if not _can_move_to_foundation(foundation):
		return false
	var card: Variant = _selection_single()
	var pile: Array = foundations[foundation]
	_push_history()
	_remove_selection(1)
	pile.append(card)
	selection = {}
	moves += 1
	score += 10
	Sfx.level_up()
	_check_win()
	_refresh()
	return true


## True when the card's own foundation is ready and no opposite-suit foundation
## is further behind — the classic FreeCell safety test.
func _is_safe(card: Cards.Card) -> bool:
	return Cards.freecell_safe(foundations, card)


## Plays out every safe card, repeating until nothing more can go home.
func auto_move() -> void:
	if won:
		return
	_push_history()
	var moved_any := false
	var progressed := true
	while progressed:
		progressed = false
		for i in 4:
			var card: Variant = free_cells[i]
			if card != null and _is_safe(card):
				(foundations[card.suit] as Array).append(card)
				free_cells[i] = null
				score += 10
				moves += 1
				moved_any = true
				progressed = true
		for c in COLS:
			var column: Array = columns[c]
			while not column.is_empty():
				var top: Variant = column[column.size() - 1]
				if not _is_safe(top):
					break
				column.pop_back()
				(foundations[top.suit] as Array).append(top)
				score += 10
				moves += 1
				moved_any = true
				progressed = true
	if not moved_any:
		history.pop_back()
		_refresh()
		return
	selection = {}
	_end_gesture()
	Sfx.kill()
	_check_win()
	_refresh()


func _push_history() -> void:
	# Any board change clears the hint — it pointed at cells that have moved —
	# and with it the red frame of a place that has just refused a card.
	_clear_hint()
	_refuse_life = 0.0
	history.append({
		"freeCells": free_cells.duplicate(),
		"foundations": foundations.duplicate(true),
		"columns": columns.duplicate(true),
		"moves": moves,
		"score": score,
		"hints": hints_used,
	})
	if history.size() > 300:
		history.pop_front()


## Shows the single move that gains the most and lights it up. Asking costs
## points and `undo()` does not refund them — otherwise hint/undo/hint would
## make the price free. The board itself is untouched.
func hint() -> void:
	if won:
		return
	var list := Cards.freecell_suggest(free_cells, foundations, columns)
	if list.is_empty():
		hint_move = {}
		hint_life = HINT_LIFE
		_refresh()
		return
	hint_move = list[_hint_cursor % list.size()]
	_hint_cursor += 1
	hints_used += 1
	score = maxi(0, score - HINT_COST)
	hint_life = HINT_LIFE
	Sfx.select()
	_refresh()


func _clear_hint() -> void:
	hint_move = {}
	hint_life = 0.0


func undo() -> void:
	if won or history.is_empty():
		return
	var snapshot: Dictionary = history.pop_back()
	free_cells = (snapshot["freeCells"] as Array).duplicate()
	foundations = (snapshot["foundations"] as Array).duplicate(true)
	columns = (snapshot["columns"] as Array).duplicate(true)
	_refuse_life = 0.0
	# Restoring the previous hint count keeps the cost paid, so undo/redo/undo
	# cannot cycle the points back in.
	var paid := maxi(0, hints_used - int(snapshot.get("hints", hints_used)))
	moves = int(snapshot["moves"])
	score = maxi(0, int(snapshot["score"]) - paid * HINT_COST)
	selection = {}
	_end_gesture()
	_clear_hint()
	Sfx.kill()
	_refresh()


## A board that changed under a finger cancels the gesture: the cards are not
## where the hand left them.
func _end_gesture() -> void:
	_pointer_down = false
	_drag_active = false
	_refuse_life = 0.0


func _check_win() -> void:
	if won:
		return
	var total := 0
	for pile in foundations:
		total += (pile as Array).size()
	if total < 52:
		return
	won = true
	selection = {}
	_clear_hint()
	_end_gesture()
	score += 500
	Game.submit_score(Game.HS_FREECELL, score)
	Sfx.level_up()
	var layer := modal()
	layer.add_child(Ui.backdrop(0.82))
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(center)
	var column := Ui.vbox(14)
	center.add_child(column)
	column.add_child(Ui.title("🏆  WON!", 52, Color("4ade80")))
	column.add_child(Ui.label(Loc.f("Moves: %d\nPoints: %d\nHints: %d", [moves, score, hints_used]), 22, Color("e2e8f0")))
	column.add_child(Ui.button("New game", Vector2(360, 56), UiTheme.ACCENT, func() -> void: new_deal()))
	column.add_child(Ui.button("Lobby", Vector2(360, 56), UiTheme.PANEL_LIGHT, func() -> void: Router.to_lobby()))


func _refresh() -> void:
	_redraw_view()
	if _moves_label == null:
		return
	_moves_label.text = Loc.f("Moves: %d", [moves])
	_score_label.text = Loc.f("Points: %d", [score])
	_highscore_label.text = Loc.f("Best: %d", [highscore])
	if _help_label == null:
		return
	if hint_move.is_empty():
		_help_label.add_theme_color_override("font_color", UiTheme.TEXT_DIM)
		if hint_life > 0.0:
			_help_label.text = Loc.f("No useful move left  ·  R reshuffles", [])
		else:
			_help_label.text = CONTROLS
		return
	_help_label.add_theme_color_override("font_color", UiTheme.ACCENT)
	_help_label.text = Loc.f("Tip: %s  ·  −%d points", [Cards.freecell_hint_text(hint_move), HINT_COST])


func _redraw_view() -> void:
	if _view != null:
		_view.queue_redraw()


## Draws the foundations, the free cells and the eight tableau columns.
class BoardView:
	extends Control
	var screen: FreeCellScreen

	func _draw() -> void:
		if screen == null:
			return
		for i in 4:
			var x := screen.col_x(4 + i)
			CardRenderer.slot(self, Rect2(Vector2(x, TOP_Y), Vector2(CARD_W, CARD_H)))
			var pile: Array = screen.foundations[i]
			if not pile.is_empty():
				CardRenderer.card(self, Rect2(Vector2(x, TOP_Y), Vector2(CARD_W, CARD_H)), pile[pile.size() - 1])
			else:
				_text(Cards.SUIT_SYMBOLS[i], Vector2(x, TOP_Y), CARD_W, CARD_H, 52, Cards.color_for_suit(i), 0.22)

		for i in 4:
			var x := screen.col_x(i)
			CardRenderer.slot(self, Rect2(Vector2(x, TOP_Y), Vector2(CARD_W, CARD_H)))
			var card: Variant = screen.free_cells[i]
			if card != null:
				if screen._is_lifted_cell(i):
					continue
				var selected: bool = not screen.selection.is_empty() and str(screen.selection["from"]) == "cell" and int(screen.selection["index"]) == i
				CardRenderer.card(self, Rect2(Vector2(x, TOP_Y), Vector2(CARD_W, CARD_H)), card, true, selected)
			else:
				_text(Loc.t("freecell.free_cell"), Vector2(x, TOP_Y), CARD_W, CARD_H, 18, UiTheme.TEXT_MUTED, 0.9)

		for c in COLS:
			var x := screen.col_x(c)
			var column: Array = screen.columns[c]
			if column.is_empty():
				CardRenderer.slot(self, Rect2(Vector2(x, TABLEAU_Y), Vector2(CARD_W, CARD_H)))
				continue
			var dy := screen.stack_dy(column.size())
			for j in column.size():
				if screen._is_lifted_card(c, j):
					continue
				var selected: bool = not screen.selection.is_empty() and str(screen.selection["from"]) == "col" and int(screen.selection["index"]) == c and j >= int(screen.selection["start"])
				CardRenderer.card(self, Rect2(Vector2(x, TABLEAU_Y + float(j) * dy), Vector2(CARD_W, CARD_H)), column[j], true, selected)

		_drag()
		_hint()
		_refuse_frame()

	## While a run is on the move: every place that takes it lights up green,
	## and the run itself follows the finger instead of lying in its column.
	func _drag() -> void:
		if not screen._drag_active or screen.selection.is_empty():
			return
		for i in 4:
			if screen._can_move_to_cell(i):
				_frame(screen._slot_rect(screen.col_x(i)), UiTheme.SUCCESS, 3.0)
			if screen._can_move_to_foundation(i):
				_frame(screen._slot_rect(screen.col_x(4 + i)), UiTheme.SUCCESS, 3.0)
		for c in COLS:
			if screen._can_move_to_column(c):
				var column: Array = screen.columns[c]
				var top := maxi(column.size() - 1, 0)
				var dy: float = screen.stack_dy(maxi(column.size(), 1))
				_frame(screen._card_rect(c, top, dy), UiTheme.SUCCESS, 3.0)
		# The run itself, drawn from the column so no copy of it is made.
		var count := screen._selection_count()
		var ghost := screen._drag_ghost_rect()
		for k in count:
			var card: Variant = screen._card_at_selection(k)
			if card == null:
				continue
			CardRenderer.card(self, Rect2(ghost.position + Vector2(0.0, float(k) * ghost_dy(count)), Vector2(CARD_W, CARD_H)),
					card, true, true)

	## The red frame on a place that has just refused the run.
	func _refuse_frame() -> void:
		if screen._refuse_life <= 0.0 or screen._refused.size == Vector2.ZERO:
			return
		var fade: float = clampf(screen._refuse_life / 0.2, 0.0, 1.0)
		_frame(screen._refused, UiTheme.DANGER, 4.0 * fade)

	func _frame(rect: Rect2, color: Color, width: float) -> void:
		draw_rect(rect.grow(3.0), Color(color.r, color.g, color.b, 0.75), false, width)

	## Vertical spacing of the lifted run: tighter than on the board, so a long
	## run does not trail far behind its first card.
	func ghost_dy(count: int) -> float:
		return BASE_DY if count <= 1 else minf(screen.stack_dy(count + 1), 26.0)

	## Pulses a frame around the hinted card and around its destination: blue
	## where the card stands, green where it belongs.
	func _hint() -> void:
		if screen.hint_move.is_empty() or screen.hint_life <= 0.0:
			return
		var rects := _hint_rects()
		if rects.size() < 2:
			return
		var wave := sin(float(Time.get_ticks_msec()) * 0.005)
		var fade: float = clampf(screen.hint_life / 0.8, 0.0, 1.0)
		var width := 4.0 + 2.0 * wave
		draw_rect((rects[0] as Rect2).grow(3.0), Color(UiTheme.ACCENT.r, UiTheme.ACCENT.g, UiTheme.ACCENT.b, fade * (0.6 + 0.4 * wave)), false, width)
		draw_rect((rects[1] as Rect2).grow(3.0), Color(UiTheme.SUCCESS.r, UiTheme.SUCCESS.g, UiTheme.SUCCESS.b, fade * (0.6 + 0.4 * wave)), false, width)

	## The two rectangles the hint points at — where the card is and where it goes.
	func _hint_rects() -> Array:
		var from: Dictionary = screen.hint_move["from"]
		var to: Dictionary = screen.hint_move["to"]
		var source := Rect2()
		if str(from["zone"]) == "cell":
			source = Rect2(Vector2(screen.col_x(int(from["index"])), TOP_Y), Vector2(CARD_W, CARD_H))
		else:
			var origin: Array = screen.columns[int(from["index"])]
			var start := int(from["start"])
			if start < origin.size():
				var y := TABLEAU_Y + float(start) * screen.stack_dy(origin.size())
				source = Rect2(Vector2(screen.col_x(int(from["index"])), y), Vector2(CARD_W, CARD_H))
		var target := Rect2()
		var zone := str(to["zone"])
		if zone == "foundation":
			target = Rect2(Vector2(screen.col_x(4 + int(to["index"])), TOP_Y), Vector2(CARD_W, CARD_H))
		elif zone == "cell":
			target = Rect2(Vector2(screen.col_x(int(to["index"])), TOP_Y), Vector2(CARD_W, CARD_H))
		else:
			var column: Array = screen.columns[int(to["index"])]
			var ty := TABLEAU_Y
			if not column.is_empty():
				ty = TABLEAU_Y + float(column.size() - 1) * screen.stack_dy(column.size())
			target = Rect2(Vector2(screen.col_x(int(to["index"])), ty), Vector2(CARD_W, CARD_H))
		if source.size == Vector2.ZERO or target.size == Vector2.ZERO:
			return []
		return [source, target]

	func _text(text: String, pos: Vector2, w: float, h: float, size: int, color: Color, alpha: float) -> void:
		var font := Ui.font_bold()
		if font == null:
			return
		var metrics := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size)
		draw_string(font, pos + Vector2((w - metrics.x) * 0.5, (h + float(size) * 0.7) * 0.5), text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(color.r, color.g, color.b, alpha))
