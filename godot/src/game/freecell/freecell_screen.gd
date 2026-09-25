class_name FreeCellScreen
extends Screen
## FreeCell — solitaire with four free cells, supermove capacity, an undo stack
## and the "auto" hint that plays out every safe card. Port of
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

var free_cells: Array = [null, null, null, null]
var foundations: Array = [[], [], [], []]
var columns: Array = []
var selection: Dictionary = {}
var moves := 0
var score := 0
var highscore := 0
var won := false
var history: Array = []

var _view: BoardView
var _moves_label: Label
var _score_label: Label
var _highscore_label: Label


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

	var hint := Ui.label("Karten antippen und dann ein Ziel wählen  ·  A = sichere Karten ablegen  ·  U = zurück  ·  R = neu", 13, UiTheme.TEXT_DIM)
	hint.position = Vector2(0, 650)
	hint.size = Vector2(1280, 20)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(hint)

	_button(layer, 300, 692, "Neu", func() -> void: new_deal())
	_button(layer, 500, 692, "Zurück", func() -> void: undo())
	_button(layer, 760, 692, "Auto", func() -> void: auto_move())
	_button(layer, 980, 692, "Lobby", func() -> void: Router.to_lobby())


func _button(layer: Control, x: float, y: float, text: String, on_press: Callable) -> void:
	var button := Ui.button(text, Vector2(180, 44), UiTheme.PANEL_LIGHT, on_press)
	button.position = Vector2(x - 90, y - 22)
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
	highscore = Game.highscore(Game.HS_FREECELL)
	close_modals()
	_refresh()


func _process(_delta: float) -> void:
	super(_delta)
	if Input.is_action_just_pressed("restart"):
		new_deal()
		return
	if won:
		return
	if Input.is_action_just_pressed("undo"):
		undo()
		return
	if Input.is_action_just_pressed("fire") and Input.is_key_pressed(KEY_A):
		auto_move()


func _on_view_input(event: InputEvent) -> void:
	if won:
		return
	var pos := Vector2.ZERO
	if event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed:
		pos = (event as InputEventScreenTouch).position
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		pos = (event as InputEventMouseButton).position
	else:
		return
	_click(pos)


func _click(pos: Vector2) -> void:
	for i in 4:
		if _in_rect(pos, col_x(i), TOP_Y, CARD_W, CARD_H):
			_click_cell(i)
			return
	for i in 4:
		if _in_rect(pos, col_x(4 + i), TOP_Y, CARD_W, CARD_H):
			_click_foundation(i)
			return
	var col := int(floor((pos.x - MARGIN) / (CARD_W + GAP)))
	if col < 0 or col >= COLS or pos.y < TABLEAU_Y or pos.y > TABLEAU_BOTTOM or pos.x > col_x(col) + CARD_W:
		return
	var cards: Array = columns[col]
	var dy := stack_dy(cards.size())
	for j in range(cards.size() - 1, -1, -1):
		var y := TABLEAU_Y + float(j) * dy
		if pos.y >= y and pos.y <= y + CARD_H:
			_click_column(col, j)
			return
	_click_column(col, -1)


func _in_rect(p: Vector2, x: float, y: float, w: float, h: float) -> bool:
	return p.x >= x and p.x <= x + w and p.y >= y and p.y <= y + h


func _click_cell(cell: int) -> void:
	if not selection.is_empty():
		if str(selection["from"]) == "cell" and int(selection["index"]) == cell:
			selection = {}
			_refresh()
			return
		if _try_move_to_cell(cell):
			return
	if free_cells[cell] != null:
		selection = {"from": "cell", "index": cell, "start": 0}
	else:
		selection = {}
	_refresh()


func _click_foundation(foundation: int) -> void:
	if selection.is_empty():
		return
	_try_move_to_foundation(foundation)


func _click_column(col: int, card_index: int) -> void:
	if not selection.is_empty():
		if str(selection["from"]) == "col" and int(selection["index"]) == col and int(selection["start"]) == card_index:
			selection = {}
			_refresh()
			return
		if _try_move_to_column(col):
			return
	_select_column(col, card_index)


func _select_column(col: int, card_index: int) -> void:
	var cards: Array = columns[col]
	if card_index < 0 or card_index >= cards.size() or not _is_sequence(cards, card_index):
		selection = {}
	else:
		selection = {"from": "col", "index": col, "start": card_index}
	Sfx.select()
	_refresh()


func _is_sequence(cards: Array, start: int) -> bool:
	for i in range(start, cards.size() - 1):
		var a: Cards.Card = cards[i]
		var b: Cards.Card = cards[i + 1]
		if a.rank != b.rank + 1:
			return false
		if Cards.is_red_card(a) == Cards.is_red_card(b):
			return false
	return true


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


func _count_free_cells() -> int:
	var count := 0
	for cell in free_cells:
		if cell == null:
			count += 1
	return count


func _count_empty_columns() -> int:
	var count := 0
	for column in columns:
		if (column as Array).is_empty():
			count += 1
	return count


func _try_move_to_column(col: int) -> bool:
	if selection.is_empty():
		return false
	if str(selection["from"]) == "col" and int(selection["index"]) == col:
		return false
	var moving := _selection_cards()
	if moving.is_empty():
		return false
	var target: Array = columns[col]
	if not target.is_empty():
		var top: Cards.Card = target[target.size() - 1]
		var first: Cards.Card = moving[0]
		if top.rank != first.rank + 1 or Cards.is_red_card(top) == Cards.is_red_card(first):
			return false
	var free_count := _count_free_cells()
	var empty_cols := _count_empty_columns()
	var capacity: int = 0
	if target.is_empty():
		capacity = (free_count + 1) * int(pow(2.0, float(maxi(0, empty_cols - 1))))
	else:
		capacity = (free_count + 1) * int(pow(2.0, float(empty_cols)))
	if moving.size() > capacity:
		return false
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
	if selection.is_empty() or free_cells[cell] != null:
		return false
	var card: Variant
	if str(selection["from"]) == "cell":
		card = free_cells[int(selection["index"])]
	else:
		var column: Array = columns[int(selection["index"])]
		if int(selection["start"]) != column.size() - 1:
			return false
		card = column[column.size() - 1]
	if card == null:
		return false
	_push_history()
	_remove_selection(1)
	free_cells[cell] = card
	selection = {}
	moves += 1
	Sfx.kill()
	_refresh()
	return true


func _try_move_to_foundation(foundation: int) -> bool:
	if selection.is_empty():
		return false
	var card: Variant
	if str(selection["from"]) == "cell":
		card = free_cells[int(selection["index"])]
	else:
		var column: Array = columns[int(selection["index"])]
		card = column[column.size() - 1] if int(selection["start"]) == column.size() - 1 else null
	if card == null or card.suit != foundation:
		return false
	var pile: Array = foundations[foundation]
	var ok: bool = false
	if pile.is_empty():
		ok = card.rank == 0
	else:
		ok = card.rank == (pile[pile.size() - 1] as Cards.Card).rank + 1
	if not ok:
		return false
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
	if (foundations[card.suit] as Array).size() != card.rank:
		return false
	if card.rank <= 1:
		return true
	for suit in 4:
		if Cards.is_red_suit(suit) == Cards.is_red_card(card):
			continue
		if (foundations[suit] as Array).size() < card.rank:
			return false
	return true


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
	Sfx.kill()
	_check_win()
	_refresh()


func _push_history() -> void:
	history.append({
		"freeCells": free_cells.duplicate(),
		"foundations": foundations.duplicate(true),
		"columns": columns.duplicate(true),
		"moves": moves,
		"score": score,
	})
	if history.size() > 300:
		history.pop_front()


func undo() -> void:
	if won or history.is_empty():
		return
	var snapshot: Dictionary = history.pop_back()
	free_cells = (snapshot["freeCells"] as Array).duplicate()
	foundations = (snapshot["foundations"] as Array).duplicate(true)
	columns = (snapshot["columns"] as Array).duplicate(true)
	moves = int(snapshot["moves"])
	score = int(snapshot["score"])
	selection = {}
	Sfx.kill()
	_refresh()


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
	column.add_child(Ui.title("🏆  GEWONNEN!", 52, Color("4ade80")))
	column.add_child(Ui.label("Züge: %d\nPunkte: %d" % [moves, score], 22, Color("e2e8f0")))
	column.add_child(Ui.button("Neues Spiel", Vector2(360, 56), UiTheme.ACCENT, func() -> void: new_deal()))
	column.add_child(Ui.button("Lobby", Vector2(360, 56), UiTheme.PANEL_LIGHT, func() -> void: Router.to_lobby()))


func _refresh() -> void:
	_view.queue_redraw()
	if _moves_label == null:
		return
	_moves_label.text = "Züge: %d" % moves
	_score_label.text = "Punkte: %d" % score
	_highscore_label.text = "Bestwert: %d" % highscore


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
				var selected: bool = not screen.selection.is_empty() and str(screen.selection["from"]) == "cell" and int(screen.selection["index"]) == i
				CardRenderer.card(self, Rect2(Vector2(x, TOP_Y), Vector2(CARD_W, CARD_H)), card, true, selected)
			else:
				_text("frei", Vector2(x, TOP_Y), CARD_W, CARD_H, 18, UiTheme.TEXT_MUTED, 0.9)

		for c in COLS:
			var x := screen.col_x(c)
			var column: Array = screen.columns[c]
			if column.is_empty():
				CardRenderer.slot(self, Rect2(Vector2(x, TABLEAU_Y), Vector2(CARD_W, CARD_H)))
				continue
			var dy := screen.stack_dy(column.size())
			for j in column.size():
				var selected: bool = not screen.selection.is_empty() and str(screen.selection["from"]) == "col" and int(screen.selection["index"]) == c and j >= int(screen.selection["start"])
				CardRenderer.card(self, Rect2(Vector2(x, TABLEAU_Y + float(j) * dy), Vector2(CARD_W, CARD_H)), column[j], true, selected)

	func _text(text: String, pos: Vector2, w: float, h: float, size: int, color: Color, alpha: float) -> void:
		var font := Ui.font_bold()
		if font == null:
			return
		var metrics := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size)
		draw_string(font, pos + Vector2((w - metrics.x) * 0.5, (h + float(size) * 0.7) * 0.5), text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(color.r, color.g, color.b, alpha))
