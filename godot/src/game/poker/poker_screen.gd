class_name PokerScreen
extends Screen
## Texas Hold'em against three computer opponents.
## Port of `scenes/PokerScene.ts` plus the `holdem.ts` engine.

const STARTING_CHIPS := 1000
const SMALL_BLIND := 10
const BIG_BLIND := 20
const PLAYER_COUNT := 4
const AI_DELAY := 0.8
const NEXT_HAND_DELAY := 3.4

const COMMUNITY_COUNT := 5
const COMMUNITY_W := 88.0
const COMMUNITY_H := 112.0
const COMMUNITY_GAP := 12.0
const COMMUNITY_Y := 228.0
const COMMUNITY_X := 640.0 - (float(COMMUNITY_COUNT) * COMMUNITY_W + float(COMMUNITY_COUNT - 1) * COMMUNITY_GAP) * 0.5

const SEATS := [
	{"cx": 640.0, "cardY": 452.0, "cardW": 104.0, "cardH": 146.0, "scale": 1.0, "nameY": 420.0, "statusY": 440.0, "betX": 640.0, "betY": 560.0, "dealerX": 790.0, "dealerY": 478.0},
	{"cx": 150.0, "cardY": 250.0, "cardW": 62.0, "cardH": 88.0, "scale": 0.68, "nameY": 350.0, "statusY": 370.0, "betX": 150.0, "betY": 226.0, "dealerX": 52.0, "dealerY": 334.0},
	{"cx": 640.0, "cardY": 56.0, "cardW": 62.0, "cardH": 88.0, "scale": 0.68, "nameY": 158.0, "statusY": 178.0, "betX": 776.0, "betY": 110.0, "dealerX": 738.0, "dealerY": 140.0},
	{"cx": 1130.0, "cardY": 250.0, "cardW": 62.0, "cardH": 88.0, "scale": 0.68, "nameY": 350.0, "statusY": 370.0, "betX": 1130.0, "betY": 226.0, "dealerX": 1228.0, "dealerY": 334.0},
]

## The legend of the three types sits right under the header — the only strip
## that collides with neither cards nor buttons at 1280 wide.
const LEGEND_POS := Vector2(700, 54)
const LEGEND_SIZE := Vector2(570, 26)
## How many hands the legend stays up before fading out.
const LEGEND_HANDS := 3
## How many balance numbers a seat shows — more would overflow on a phone.
const READ_COUNTS := 2

var table: Holdem.HoldemGame
var highscore := 0
var raise_to := 0
var busy := false
var next_hand_timer := 0.0
var waiting_next := false

var _view: TableView
var _pot_label: Label
var _message_label: Label
var _name_labels: Array = []
var _status_labels: Array = []
var _bet_labels: Array = []
var _fold_button: Button
var _check_call_button: Button
var _raise_button: Button
var _allin_button: Button
var _next_button: Button
var _raise_label: Label
var _legend_label: Label
var _hands := 0


func _ready_game() -> void:
	# No `styles` in the options: the engine assigns seat 1 the rock, seat 2 the
	# wild one and seat 3 the bluffer by itself. The order is fixed, so a player
	# learns who plays how.
	table = Holdem.HoldemGame.new({
		"playerCount": PLAYER_COUNT,
		"startingChips": STARTING_CHIPS,
		"smallBlind": SMALL_BLIND,
		"bigBlind": BIG_BLIND,
		"names": ["Du", "Alice", "Bob", "Cara", "Dan", "Eve"],
	})
	highscore = Game.highscore(Game.HS_HOLDEM)

	var background := Ui.rect(Color("080c16"))
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stage().add_child(background)

	_view = TableView.new()
	_view.screen = self
	_view.size = Vector2(1280, 720)
	stage().add_child(_view)

	_build_ui()
	_start_hand()


func _build_ui() -> void:
	var layer := stage()
	var title := Ui.label("♠  TEXAS HOLD'EM", 28, UiTheme.TEXT, true)
	title.position = Vector2(0, 16)
	title.size = Vector2(1280, 34)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(title)

	for i in PLAYER_COUNT:
		var seat: Dictionary = SEATS[i]
		var name_label := Ui.label("", 17, Color("f1f5f9"), true)
		name_label.position = Vector2(float(seat["cx"]) - 130.0, float(seat["nameY"]))
		name_label.size = Vector2(260, 24)
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		layer.add_child(name_label)
		_name_labels.append(name_label)

		var status_label := Ui.label("", 14, Color("7dd3fc"))
		status_label.position = Vector2(float(seat["cx"]) - 130.0, float(seat["statusY"]))
		status_label.size = Vector2(260, 22)
		status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		layer.add_child(status_label)
		_status_labels.append(status_label)

		var bet_label := Ui.label("", 15, Color("facc15"), true)
		bet_label.position = Vector2(float(seat["betX"]) - 90.0, float(seat["betY"]) - 12.0)
		bet_label.size = Vector2(180, 24)
		bet_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		layer.add_child(bet_label)
		_bet_labels.append(bet_label)

	_pot_label = Ui.label("", 20, Color("facc15"), true)
	_pot_label.position = Vector2(440, 192)
	_pot_label.size = Vector2(400, 28)
	_pot_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(_pot_label)

	_message_label = Ui.label("", 22, UiTheme.TEXT, true)
	_message_label.position = Vector2(240, 378)
	_message_label.size = Vector2(800, 30)
	_message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(_message_label)

	_raise_label = Ui.label("Erhöhen auf: 0", 16, Color("7dd3fc"))
	_raise_label.position = Vector2(540, 596)
	_raise_label.size = Vector2(200, 24)
	_raise_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(_raise_label)

	# The legend fades once every seat shows its type, where the name is enough.
	_legend_label = Ui.label(Holdem.legend(), 14, Color("94a3b8"))
	_legend_label.position = LEGEND_POS
	_legend_label.size = LEGEND_SIZE
	_legend_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	layer.add_child(_legend_label)

	_fold_button = _action(170, 650, 150, 56, "Fold", UiTheme.PANEL_LIGHT, func() -> void: _act({"type": "fold"}))
	_check_call_button = _action(350, 650, 210, 56, "Check", UiTheme.ACCENT, func() -> void: _human_action())
	_adjust(480, 650, 44, 44, "−", func() -> void: _nudge_raise(-BIG_BLIND))
	_raise_button = _action(640, 650, 190, 56, "Erhöhen", UiTheme.PANEL_LIGHT, func() -> void: _act({"type": "raise", "target": raise_to}))
	_adjust(772, 650, 44, 44, "+", func() -> void: _nudge_raise(BIG_BLIND))
	_allin_button = _action(900, 650, 170, 56, "All-in", Color(0.153, 0.212, 0.345), func() -> void: _act({"type": "allin"}))
	_next_button = _action(1090, 650, 190, 56, "Nächste Hand", UiTheme.SUCCESS, _start_hand)


func _action(x: float, y: float, w: float, h: float, text: String, color: Color, on_press: Callable) -> Button:
	var button := Ui.button(text, Vector2(w, h), color, on_press)
	button.position = Vector2(x - w * 0.5, y - h * 0.5)
	stage().add_child(button)
	return button


func _adjust(x: float, y: float, w: float, h: float, text: String, on_press: Callable) -> void:
	var button := Ui.button(text, Vector2(w, h), UiTheme.PANEL_LIGHT, on_press)
	button.position = Vector2(x - w * 0.5, y - h * 0.5)
	stage().add_child(button)


func _nudge_raise(delta: int) -> void:
	var legal := table.legal_actions(0)
	raise_to = clampi(raise_to + delta, int(legal["minRaiseTo"]), int(legal["maxRaiseTo"]))
	Sfx.select()
	_refresh()


func _start_hand() -> void:
	waiting_next = false
	next_hand_timer = 0.0
	busy = false
	_hands += 1
	for i in table.players.size():
		if (table.players[i] as Holdem.Player).chips <= 0:
			table.rebuy(i)
	raise_to = 0
	table.start_hand()
	var legal := table.legal_actions(0)
	raise_to = int(legal["minRaiseTo"])
	_run_ai_turns()
	_refresh()


func _human_action() -> void:
	if busy or waiting_next or table.hand_over:
		return
	var legal := table.legal_actions(0)
	if int(legal["callAmount"]) <= 0:
		_act({"type": "check"})
	else:
		_act({"type": "call"})


func _act(action: Dictionary) -> void:
	if busy or waiting_next or table.hand_over:
		return
	if not table.act(0, action):
		return
	Sfx.deal()
	_run_ai_turns()
	_refresh()


## Drives the computer seats until the human's turn again (or the hand ends).
## Each decision is spaced out so the action stays readable.
func _run_ai_turns() -> void:
	busy = true
	while not table.hand_over and table.active_index != 0:
		await get_tree().create_timer(AI_DELAY).timeout
		if not is_inside_tree():
			return
		if table.hand_over:
			break
		if table.active_index <= 0 or table.active_index >= table.players.size():
			break
		var decision := Holdem.choose_ai_action(table, table.active_index)
		if not table.act(table.active_index, decision):
			break
		_refresh()
	busy = false
	if table.hand_over:
		_on_hand_over()
		return
	var legal := table.legal_actions(0)
	raise_to = clampi(raise_to, int(legal["minRaiseTo"]), int(legal["maxRaiseTo"]))
	_refresh()


func _on_hand_over() -> void:
	waiting_next = true
	next_hand_timer = NEXT_HAND_DELAY
	var total := 0
	for player in table.players:
		total += (player as Holdem.Player).chips
	highscore = maxi(highscore, total)
	Game.submit_score(Game.HS_HOLDEM, total)
	_refresh()


func _process(delta: float) -> void:
	super(delta)
	if not waiting_next:
		return
	next_hand_timer -= delta
	if next_hand_timer <= 0.0:
		_start_hand()


func _refresh() -> void:
	_view.queue_redraw()
	if _pot_label == null:
		return
	_pot_label.text = "Pot: %s" % Ui.format_number(table.pot)
	for i in PLAYER_COUNT:
		var player: Holdem.Player = table.players[i]
		var read: Dictionary = table.style_read(i)
		var style_name := str(read["label"])
		# The type goes with the name, not the status field: status is what happens
		# now, the type is what holds for good. Its colour makes the table readable
		# at a glance.
		var name_label := _name_labels[i] as Label
		name_label.text = "%s  %s%s" % [
			player.name,
			Ui.format_number(player.chips),
			("   %s" % style_name) if not style_name.is_empty() else "",
		]
		name_label.add_theme_color_override("font_color", UiTheme.TEXT if player.is_human else Color(str(read["color"])))

		var status := player.last_action
		if player.folded:
			status = "Fold"
		elif player.all_in:
			status = "All-in"
		var status_label := _status_labels[i] as Label
		status_label.text = status if player.is_human else _read_text(read, status)
		status_label.add_theme_color_override("font_color", Color("7dd3fc") if player.is_human else Color(str(read["color"])))
		(_bet_labels[i] as Label).text = ("%s" % Ui.format_number(player.bet)) if player.bet > 0 else ""
	if _legend_label != null:
		_legend_label.visible = _hands <= LEGEND_HANDS

	var human_turn: bool = not table.hand_over and table.active_index == 0 and not busy and not waiting_next
	var legal: Dictionary = table.legal_actions(0)
	_fold_button.disabled = not human_turn
	_check_call_button.disabled = not human_turn
	_raise_button.disabled = not human_turn or not bool(legal["canRaise"])
	_allin_button.disabled = not human_turn
	_next_button.disabled = not waiting_next
	_raise_button.visible = human_turn
	_raise_label.visible = human_turn
	_check_call_button.text = "Check" if int(legal["callAmount"]) <= 0 else "Call %s" % Ui.format_number(int(legal["callAmount"]))
	_raise_label.text = "Erhöhen auf: %s" % Ui.format_number(raise_to)

	if waiting_next:
		var winner := _pot_winner_text()
		_message_label.text = "%s   ·   Nächste Hand in %d …" % [winner, int(ceil(next_hand_timer))]
	elif table.hand_over:
		_message_label.text = _pot_winner_text()
	elif human_turn:
		_message_label.text = "Du bist am Zug"
	else:
		var actor: Holdem.Player = table.current_player()
		var actor_read: Dictionary = table.style_read(table.active_index)
		var cue := " (%s)" % str(actor_read["label"]) if not actor.is_human and not str(actor_read["label"]).is_empty() else ""
		_message_label.text = "%s%s ist am Zug" % [actor.name, cue]


## What the type has shown so far. Until a seat acts, its promise stands there
## ("calls everything"); afterwards the balance ("Raise 4  ·  Fold 2"), so the
## badges can be checked against reality over time. At most two numbers — on a
## phone the line would overflow the seat otherwise.
func _read_text(read: Dictionary, status: String) -> String:
	var parts: Array = []
	if int(read["seen"]) <= 0:
		parts.append(str(read["hint"]))
	else:
		# Raises first, folds second: these are the two numbers to read the
		# counter-image from. Calls are only the rest.
		var shown := 0
		for entry in [["Raise", int(read["raises"])], ["Fold", int(read["folds"])], ["Call", int(read["calls"])]]:
			if int(entry[1]) <= 0:
				continue
			parts.append("%s %d" % [str(entry[0]), int(entry[1])])
			shown += 1
			if shown == READ_COUNTS:
				break
	if not status.is_empty():
		parts.append(status)
	return "  ·  ".join(parts)


func _pot_winner_text() -> String:
	for award in table.awards:
		var names: Array = []
		for winner in award["winners"]:
			names.append((table.players[int(winner)] as Holdem.Player).name)
		if not names.is_empty():
			return "%s gewinnt %s" % [" & ".join(names), Ui.format_number(int(award["amount"]))]
	return "Hand beendet"


## Draws the felt table, the community cards, every seat and the dealer button.
class TableView:
	extends Control
	var screen: PokerScreen

	func _draw() -> void:
		if screen == null:
			return
		draw_circle(Vector2(640, 356), 270.0, Color("0b3b2e"))
		draw_arc(Vector2(640, 356), 270.0, 0.0, TAU, 64, Color("1f2937"), 10.0, true)
		draw_arc(Vector2(640, 356), 260.0, 0.0, TAU, 64, Color("334155"), 3.0, true)
		draw_arc(Vector2(640, 356), 240.0, 0.0, TAU, 64, Color(0.043, 0.071, 0.125, 0.5), 2.0, true)

		for i in COMMUNITY_COUNT:
			var rect := Rect2(Vector2(COMMUNITY_X + float(i) * (COMMUNITY_W + COMMUNITY_GAP), COMMUNITY_Y), Vector2(COMMUNITY_W, COMMUNITY_H))
			if i < screen.table.community.size():
				CardRenderer.card(self, rect, screen.table.community[i])
			else:
				CardRenderer.slot(self, rect)

		for i in screen.table.players.size():
			var player: Holdem.Player = screen.table.players[i]
			var seat: Dictionary = SEATS[i]
			var scale: float = float(seat["scale"])
			var card_w: float = float(seat["cardW"])
			var card_h: float = float(seat["cardH"])
			for k in player.hole.size():
				var offset: float = float(k) * card_w * 0.55
				var rect := Rect2(Vector2(float(seat["cx"]) - card_w * 0.5 + offset, float(seat["cardY"])), Vector2(card_w, card_h))
				if i == 0 or not screen.table.hand_over:
					CardRenderer.card(self, rect, player.hole[k], i == 0 or not screen.table.hand_over, false, scale)
				else:
					CardRenderer.card(self, rect, player.hole[k], false)
			if player.bet > 0:
				_chip(Vector2(float(seat["betX"]), float(seat["betY"])))
			if screen.table.dealer == i:
				_dealer(Vector2(float(seat["dealerX"]), float(seat["dealerY"])))

		# Showdown hands.
		if screen.table.hand_over and not screen.table.showdown_values.is_empty():
			for i in screen.table.showdown_values.size():
				var hand: Variant = screen.table.showdown_values[i]
				if hand == null:
					continue
				var seat: Dictionary = SEATS[i]
				var text := (hand as Holdem.HandValue).hand_name
				_label(Vector2(float(seat["cx"]), float(seat["cardY"]) + float(seat["cardH"]) + 26.0), text, 18, Color("facc15"))

	func _chip(pos: Vector2) -> void:
		draw_circle(pos, 9.0, Color("dc2626"))
		draw_arc(pos, 9.0, 0.0, TAU, 18, Color("fecaca"), 2.0, true)

	func _dealer(pos: Vector2) -> void:
		draw_circle(pos, 13.0, Color("f8fafc"))
		_label(pos, "D", 16, Color("0f172a"), 1.0)

	func _label(pos: Vector2, text: String, size: int, color: Color, center_y: float = 0.0) -> void:
		var font := Ui.font_bold()
		if font == null:
			return
		var metrics := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size)
		draw_string(font, pos - Vector2(metrics.x * 0.5, center_y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)
