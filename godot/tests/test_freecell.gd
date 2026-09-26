class_name TestFreecell
extends RefCounted
## Rule tests for FreeCell: the supermove capacity, the safety test and above all
## the "Tipp" — every move `Cards.freecell_suggest` proposes has to be a legal
## move, because that is the promise the hint makes to the player.
##
## The rules run in the plain logic phase of the headless suite: the board is
## four arrays of cards, so none of this needs a scene. `ScreenChecks` then
## takes the same feature to the real screen.

var t: TestKit


func run(kit: TestKit) -> void:
	t = kit
	_sequences()
	_capacity()
	_safety()
	_hint_text()
	_suggestion()
	_legality()
	_dead_end()
	_opening()
	t.close_suite()


# --- helpers ----------------------------------------------------------------

const PIK := 0
const HERZ := 1
const KARO := 2
const KREUZ := 3
## Suit letters for the test boards: P = Pik, H = Herz, K = Karo, C = Kreuz.
const SUIT_LETTERS := {"P": PIK, "H": HERZ, "K": KARO, "C": KREUZ}


func card(rank: int, suit: int) -> Cards.Card:
	return Cards.Card.new(rank, suit)


## `"3K"` is the 3 of diamonds, `"0P"` the ace of spades. Ranks run 0..12
## exactly as in the game, so `"0P"` is an ace and `"12P"` the queen.
func card_of(text: String) -> Cards.Card:
	return card(int(text.substr(0, text.length() - 1)), int(SUIT_LETTERS[text.substr(text.length() - 1, 1)]))


## A board with one entry per column, top card last. Short lists are filled up
## to the usual eight, missing entries become empty columns.
func board(rows: Array) -> Array:
	var out: Array = []
	for c in 8:
		var column: Array = []
		if c < rows.size():
			for text in (rows[c] as Array):
				column.append(card_of(str(text)))
		out.append(column)
	return out


## A board with `empty` empty columns and one filler card everywhere else — for
## the capacity maths, where the number of empty columns is what is tested.
func mostly_full(empty: int) -> Array:
	var out: Array = []
	for c in 8:
		out.append([] if c < empty else [card(c, c % 4)])
	return out


func free_cells_of(texts: Array) -> Array:
	var out: Array = [null, null, null, null]
	for i in texts.size():
		out[i] = card_of(str(texts[i]))
	return out


func four_empty_cells() -> Array:
	return [null, null, null, null]


## Free cells array with exactly `count` of them empty. The occupied ones hold
## a card that can never go home, so they do not add a suggestion of their own.
func cells_free(count: int) -> Array:
	var out: Array = []
	for i in 4:
		out.append(null if i < count else card(2, PIK))
	return out


## Foundation piles of the given heights, filled from the ace upwards.
func foundations_of(heights: Array) -> Array:
	var out: Array = []
	for h in 4:
		var pile: Array = []
		for rank in int(heights[h] if h < heights.size() else 0):
			pile.append(card(rank, h))
		out.append(pile)
	return out


func kinds(list: Array) -> Array:
	var out: Array = []
	for move in list:
		out.append(str((move as Dictionary)["kind"]))
	return out


func first_of(list: Array, kind: String) -> Dictionary:
	for move in list:
		if str((move as Dictionary)["kind"]) == kind:
			return move
	return {}


## The proposal of that kind that moves exactly `count` cards.
func moving_of(list: Array, kind: String, count: int) -> Dictionary:
	for move in list:
		if str((move as Dictionary)["kind"]) == kind and int((move as Dictionary)["count"]) == count:
			return move
	return {}


## Independent re-derivation of the FreeCell rules, used to check that the hint
## never proposes something the player would not have been allowed to do.
func is_legal(free_cells: Array, foundations: Array, columns: Array, move: Dictionary) -> bool:
	var from: Dictionary = move["from"]
	var to: Dictionary = move["to"]
	var moved: Array = []
	if str(from["zone"]) == "cell":
		var held: Variant = free_cells[int(from["index"])]
		if held == null:
			return false
		moved = [held]
	else:
		var origin: Array = columns[int(from["index"])]
		var start := int(from["start"])
		if start < 0 or start >= origin.size():
			return false
		moved = origin.slice(start)
		# One card may always leave; a longer run has to be a real run.
		if moved.size() > 1:
			for i in range(0, moved.size() - 1):
				var a: Cards.Card = moved[i]
				var b: Cards.Card = moved[i + 1]
				if a.rank != b.rank + 1 or Cards.is_red_card(a) == Cards.is_red_card(b):
					return false
	var zone := str(to["zone"])
	if zone == "foundation":
		if moved.size() != 1:
			return false
		var head: Cards.Card = moved[0]
		if int(to["index"]) != head.suit:
			return false
		var pile: Array = foundations[int(to["index"])]
		if pile.is_empty():
			return head.rank == 0
		return head.rank == (pile[pile.size() - 1] as Cards.Card).rank + 1
	if zone == "cell":
		if free_cells[int(to["index"])] != null:
			return false
		return moved.size() == 1
	var target: Array = columns[int(to["index"])]
	if str(from["zone"]) == "col" and int(from["index"]) == int(to["index"]):
		return false
	var empties := Cards.freecell_empty_count(columns)
	var free := Cards.freecell_free_count(free_cells)
	var target_empty: bool = (columns[int(to["index"])] as Array).is_empty()
	var room := (free + 1) * int(pow(2.0, float(maxi(0, empties - (1 if target_empty else 0)))))
	if moved.size() > room:
		return false
	if target_empty:
		return true
	var under: Cards.Card = target[target.size() - 1]
	var lead: Cards.Card = moved[0]
	return under.rank == lead.rank + 1 and Cards.is_red_card(under) != Cards.is_red_card(lead)


# --- suites -----------------------------------------------------------------

func _sequences() -> void:
	t.suite("FreeCell — Folgen")
	t.check(Cards.freecell_sequence([card(6, PIK), card(5, HERZ)], 0), "Absteigend und farblich wechselnd ist eine Folge")
	t.check(Cards.freecell_sequence([card(6, PIK), card(5, KARO), card(4, KREUZ)], 0), "Drei Karten in Folge")
	t.check(Cards.freecell_sequence([card(9, PIK), card(6, PIK), card(5, HERZ)], 1), "Der Schnitt zählt als Start")
	t.check(not Cards.freecell_sequence([card(9, PIK), card(6, PIK), card(5, HERZ)], 0), "Die ganze Spalte ist keine Folge")
	t.check(not Cards.freecell_sequence([card(6, PIK), card(4, HERZ)], 0), "Eine Lücke ist keine Folge")
	t.check(not Cards.freecell_sequence([card(6, PIK), card(5, PIK)], 0), "Zwei Farben sind keine Folge")
	t.check(Cards.freecell_sequence([card(6, PIK)], 0), "Eine einzelne Karte ist eine Folge")
	t.check(not Cards.freecell_sequence([card(6, PIK)], 1), "Hinter dem Stapel liegt nichts")
	t.check(not Cards.freecell_sequence([], 0), "Ein leerer Stapel hat keine Folge")
	t.suite_done()


func _capacity() -> void:
	t.suite("FreeCell — Supermove-Kapazität")
	# Ohne freie Zelle und ohne leeren Stapel bleibt genau eine Karte.
	t.equal(Cards.freecell_capacity(cells_free(0), mostly_full(0), 0), 1, "Nichts frei: nur eine Karte")
	t.equal(Cards.freecell_capacity(cells_free(1), mostly_full(0), 0), 2, "Eine Zelle verdoppelt")
	# Auf einen leeren Stapel zählt der Stapel selbst nicht mit.
	t.equal(Cards.freecell_capacity(cells_free(1), mostly_full(1), 0), 2, "Ein leerer Stapel wie eine Zelle")
	t.equal(Cards.freecell_capacity(cells_free(1), mostly_full(2), 0), 4, "Jeder weitere Leerstapel verdoppelt")
	t.equal(Cards.freecell_capacity(cells_free(1), mostly_full(3), 0), 8, "Drei Leerstapel: acht Karten")
	t.equal(Cards.freecell_capacity(cells_free(4), mostly_full(1), 0), 5, "Vier Zellen zählen jede für sich")
	# Auf einen belegten Stapel zählt sein eigener Platz mit.
	t.equal(Cards.freecell_capacity(cells_free(1), mostly_full(0), 1), 2, "Der belegte Stapel verdoppelt mit")
	t.equal(Cards.freecell_capacity(cells_free(0), mostly_full(2), 0), 2, "Ohne Zelle tragen zwei Leerstapel zwei Karten")
	t.suite_done()


func _safety() -> void:
	t.suite("FreeCell — Sicherheit")
	var none := foundations_of([0, 0, 0, 0])
	t.check(Cards.freecell_safe(none, card(0, PIK)), "Ein Ass ist immer sicher")
	t.check(not Cards.freecell_safe(none, card(1, HERZ)), "Die Zwei nicht — ihr Ass fehlt")
	t.check(not Cards.freecell_safe(none, card(2, PIK)), "Die Drei darf nicht vor die Karo-Drei")
	t.check(not Cards.freecell_safe(none, card(5, KREUZ)), "Auch die Sechs nicht")
	var even := foundations_of([3, 3, 3, 2])
	t.check(Cards.freecell_safe(even, card(3, PIK)), "Die Pik-Vier ist sicher, beide roten sind gleich weit")
	t.check(not Cards.freecell_safe(even, card(3, HERZ)), "Die Herz-Vier nicht — die Kreuz-Vier fehlt noch")
	t.check(Cards.freecell_safe(foundations_of([1, 0, 0, 0]), card(1, PIK)), "Die Zwei auf dem fertigen Ass")
	t.suite_done()


func _hint_text() -> void:
	t.suite("FreeCell — Tipptext")
	var none := foundations_of([0, 0, 0, 0])

	var home: Dictionary = Cards.freecell_suggest(four_empty_cells(), none, board([["0P"]]), 1)[0]
	t.equal(str(home["kind"]), "safe", "Ein Ass geht nach Hause")
	t.check(Cards.freecell_hint_text(home).contains("Pik-Fundament"), "Der Text nennt das Fundament")

	# 4♦ 3♠ 2♥ neben dem Kreuz-5: eine Folge, die komplett umsetzt.
	var cols := board([["4K", "3P", "2H"], ["5C"]])
	var run: Dictionary = first_of(Cards.freecell_suggest(four_empty_cells(), none, cols, 8), "build")
	t.equal(int(run["count"]), 3, "Die ganze Folge wird als ein Zug vorgeschlagen")
	var text := Cards.freecell_hint_text(run)
	t.check(text.contains(Cards.label_of(cols[0][0])), "Der Text zeigt die erste Karte der Folge")
	t.check(text.contains("+2"), "und sagt, wie viele mitkommen")
	t.check(text.contains(Cards.label_of(cols[1][0])), "und worauf die Folge passt")

	# Eine Zellenkarte, die einen leeren Stapel belegt.
	cols = board([["9H"], [], [], [], [], [], [], []])
	var shift: Dictionary = first_of(Cards.freecell_suggest(free_cells_of(["7C"]), none, cols, 8), "shift")
	t.check(Cards.freecell_hint_text(shift).contains("Zelle 1"), "Eine Zellenkarte gibt die Zelle frei")

	# Eine einzelne Karte beiseitelegen.
	cols = board([["7H", "6P"]])
	var park: Dictionary = first_of(Cards.freecell_suggest(four_empty_cells(), none, cols, 8), "park")
	t.check(park.size() > 0, "Der Ausgrabungszug wird überhaupt vorgeschlagen")
	t.check(Cards.freecell_hint_text(park).contains("freie Zelle"), "Der Text nennt die freie Zelle")
	t.suite_done()


func _suggestion() -> void:
	t.suite("FreeCell — Tippvorschlag")
	var none := foundations_of([0, 0, 0, 0])

	# Eine sichere Karte schlägt alles.
	var cells := free_cells_of(["0P"])
	var cols := board([["5H", "6P", "7K"]])
	var list := Cards.freecell_suggest(cells, none, cols)
	t.check(not list.is_empty(), "Es gibt überhaupt etwas zu zeigen")
	t.equal(str(list[0]["kind"]), "safe", "Die sichere Karte kommt zuerst")
	t.check(int(list[0]["score"]) - int(list[1]["score"]) > 100, "Und mit Abstand vor allen anderen")

	# Ohne sichere Karte: die Folge 7♦ 6♠ 5♥ passt auf die Spalte mit der 8♠.
	cols = board([["8C", "7K", "6P", "5H"], ["8P"], ["12P"], ["9H"], ["3K"], ["4K"], ["11H"], ["5C"]])
	list = Cards.freecell_suggest(four_empty_cells(), none, cols)
	var run: Dictionary = moving_of(list, "build", 3)
	t.equal(int(run["to"]["index"]), 1, "Die Dreierfolge passt auf die 8♠ in Spalte 2")
	t.equal(int(run["from"]["start"]), 1, "und lässt die 8♣ darüber liegen")
	for move in list:
		t.check(is_legal(four_empty_cells(), none, cols, move),
				"Zug erlaubt: %s" % Cards.freecell_hint_text(move))

	# Eine Folge, die den ganzen Stapel aufräumt, ist der beste Zug überhaupt.
	cols = board([["7K", "6P", "5H"], ["8C"]])
	list = Cards.freecell_suggest(four_empty_cells(), none, cols)
	t.equal(int(list[0]["score"]), 300, "Ein leerer Stapel ist das wertvollste Ziel")
	t.check(Cards.freecell_hint_text(list[0]).contains("wird frei"), "Der Text sagt, dass die Spalte leer wird")
	t.check(is_legal(four_empty_cells(), none, cols, list[0]), "und der Zug ist erlaubt")

	# Eine Zellenkarte belegt einen leeren Stapel und macht so wieder Platz.
	cols = board([["9H"], [], [], [], [], [], [], []])
	cells = free_cells_of(["7C"])
	list = Cards.freecell_suggest(cells, none, cols)
	t.equal(str(list[0]["kind"]), "shift", "Die Zellenkarte wandert in den leeren Stapel")
	t.check(is_legal(cells, none, cols, list[0]), "und das ist erlaubt")

	# Das Ausgraben: die oberste Karte weg, darunter wird eine Folge frei.
	cols = board([["7H", "6P"], ["12P"], ["9H"], ["3K"], ["8P"], ["4K"], ["11H"], ["5C"]])
	list = Cards.freecell_suggest(four_empty_cells(), none, cols)
	t.check(kinds(list).has("park"), "Auch das Ausgraben wird gefunden")
	t.check(is_legal(four_empty_cells(), none, cols, first_of(list, "park")), "und ist erlaubt")

	# Die Liste lässt sich begrenzen und ist absteigend sortiert.
	var many := Cards.freecell_suggest(four_empty_cells(), none, cols, 3)
	t.equal(many.size(), 3, "Die Vorschlagsliste lässt sich begrenzen")
	t.check(Cards.freecell_suggest(four_empty_cells(), none, cols).size() > 3, "Es waren auch mehr Vorschläge da")
	var best := -1
	var worst := 10000
	for move in many:
		best = maxi(best, int((move as Dictionary)["score"]))
		worst = mini(worst, int((move as Dictionary)["score"]))
	t.check(worst <= best, "Die besten Züge stehen vorn")
	t.suite_done()


func _legality() -> void:
	t.suite("FreeCell — Tipp ist immer erlaubt")
	var none := foundations_of([0, 0, 0, 0])
	var decks := [
		board([["0P", "1H", "2P"], ["3H"], [], ["5K", "4H"]]),
		board([["9P", "8H", "7K", "6P"], ["10H", "9K"], [], [], [], ["2C"], [], []]),
		board([["11P", "10H", "9K", "8C"], ["7P"], ["6H"], [], [], [], [], [], []]),
		board([["12P", "11H", "10K", "9C", "8P"], [], ["5P", "4H"], ["3K"], ["7H"], [], [], [], []]),
	]
	var cell_sets := [
		free_cells_of(["0C", "4P"]),
		free_cells_of(["12H"]),
		four_empty_cells(),
		free_cells_of(["0P", "1P"]),
	]
	var found_sets := [
		none,
		foundations_of([1, 0, 2, 1]),
		foundations_of([0, 3, 0, 2]),
		foundations_of([2, 2, 1, 1]),
	]
	var checked := 0
	var bad := 0
	for i in decks.size():
		var deck: Array = decks[i]
		for cells in [cell_sets[i], four_empty_cells()]:
			for founds in [found_sets[i], none]:
				for move in Cards.freecell_suggest(cells, founds, deck, 12):
					if not is_legal(cells, founds, deck, move):
						bad += 1
						t.fail("Unzulässiger Vorschlag: %s" % Cards.freecell_hint_text(move))
					checked += 1
	t.equal(bad, 0, "Kein einziger Vorschlag war unzulässig (%d geprüft)" % checked)
	t.check(checked > 20, "Genug Vorschläge durchgelaufen")

	# Dichter als am Anfang einer Partie.
	var tight := board([["8P", "7H", "6K"], ["5P", "4H", "3K"], ["2P", "1H"]])
	for move in Cards.freecell_suggest(four_empty_cells(), none, tight, 12):
		t.check(is_legal(four_empty_cells(), none, tight, move),
				"Zug bleibt erlaubt: %s" % Cards.freecell_hint_text(move))
	t.suite_done()


func _dead_end() -> void:
	t.suite("FreeCell — Sackgasse")
	# Acht Einzelkarten, alle gerade: nichts passt aufeinander, nichts ist
	# sicher, keine Zelle frei und kein leerer Stapel. Der Tipp muss schweigen,
	# statt sich zu irgendeiner erfundenen Karte zu versteigen.
	var cells := cells_free(0)
	var none := foundations_of([0, 0, 0, 0])
	var stuck := board([["2P"], ["4P"], ["6P"], ["8P"], ["10P"], ["12P"], ["2H"], ["4H"]])
	t.check(Cards.freecell_suggest(cells, none, stuck).is_empty(), "Eine hoffnungslose Lage liefert keinen Vorschlag")
	t.equal(Cards.freecell_empty_count(stuck), 0, "Und keiner der acht Stapel ist leer")
	t.equal(Cards.freecell_free_count(cells), 0, "und keine Zelle ist frei")
	t.equal(Cards.freecell_capacity(cells, stuck, 0), 1, "Ohne Zelle bewegt sich dort nur eine Karte")
	t.check(not Cards.freecell_suggest(four_empty_cells(), none, board([["2P"], ["3H"]])).is_empty(),
			"Sobald eine Karte passt, meldet sich der Tipp wieder")
	t.suite_done()


## Der Tipp muss auf einem echten, frisch gemischten Brett funktionieren — nicht
## nur auf den Lagen, die man sich ausdenkt. 40 Partien, jeder Vorschlag gegen
## die unabhängig nachgezählten Regeln geprüft.
func _opening() -> void:
	t.suite("FreeCell — Tipp am Anfang")
	var none := foundations_of([0, 0, 0, 0])
	var silent := 0
	var checked := 0
	var bad := 0
	for attempt in 40:
		var deck := Cards.create_deck()
		Cards.shuffle(deck)
		var cols: Array = []
		for c in 8:
			cols.append([])
		for i in deck.size():
			(cols[i % 8] as Array).append(deck[i])
		var cells := four_empty_cells()
		var list := Cards.freecell_suggest(cells, none, cols)
		if list.is_empty():
			silent += 1
		for move in list:
			if not is_legal(cells, none, cols, move):
				bad += 1
			checked += 1
	t.equal(silent, 0, "Auf keinem der 40 Bretter schweigt der Tipp")
	t.equal(bad, 0, "und keiner seiner Vorschläge war unzulässig")
	t.check(checked > 100, "Über hundert Vorschläge aus echten Partien geprüft (%d)" % checked)
	t.suite_done()



# --- the same feature on the real screen ------------------------------------

## The hint as the player meets it: a button, a price, a highlight that fades
## and a board that forgets the tip as soon as it changes.
##
## The screen is duck-typed through the router — naming `FreeCellScreen` would
## pull it into the compile chain of `run_tests.gd`, which runs before the
## autoloads exist.
class ScreenChecks:
	extends RefCounted

	var t: TestKit
	var _router: Node
	var _cost: int = 25
	var _life: float = 5.0

	func run(kit: TestKit, tree: SceneTree) -> void:
		t = kit
		_router = tree.root.get_node_or_null("/root/Router")
		if _router == null:
			t.fail("Der Router ist nicht erreichbar")
			return
		await _open(tree)
		t.close_suite()

	## Opens the screen and walks through everything a player does with the tip.
	func _open(tree: SceneTree) -> void:
		t.suite("FreeCell — Tipp am Screen")
		var constants: Dictionary = load("res://src/game/freecell/freecell_screen.gd").get_script_constant_map()
		_cost = int(constants.get("HINT_COST", 25))
		_life = float(constants.get("HINT_LIFE", 5.0))
		t.check(_cost > 0, "Der Tipp hat einen Preis")

		_router.go_to("freecell")
		await tree.create_timer(0.4).timeout
		var screen = _router.current_screen
		t.check(screen != null, "Der Screen wird geöffnet")
		if screen == null:
			t.suite_done()
			return
		t.check(_button_text(screen).contains("Tipp"), "Es gibt eine Tipp-Taste")
		t.check(_button_text(screen).contains(str(_cost)), "und die nennt ihren Preis")

		# Ein fester Punktestand, damit die Kosten eindeutig bleiben.
		screen.score = 200
		var first: String = ""
		screen.hint()
		t.check(not screen.hint_move.is_empty(), "Der Tipp zeigt einen Zug")
		t.equal(screen.hints_used, 1, "und zählt sich")
		t.equal(screen.score, 200 - _cost, "Er kostet genau seinen Preis")
		first = Cards.freecell_hint_text(screen.hint_move)
		t.check(str(screen._help_label.text).contains("Tipp:"), "Die Hinweiszeile erklärt den Zug")
		t.check(str(screen._help_label.text).contains(str(_cost)), "und nennt die Kosten")
		t.check(str(screen._help_label.text).contains(first), "Der Text steht auch in der Zeile")
		t.equal(screen._view._hint_rects().size(), 2, "Quelle und Ziel leuchten auf")

		# Zwei Tipps hintereinander zeigen zwei verschiedene Züge.
		screen.hint()
		t.equal(screen.hints_used, 2, "Der zweite Tipp zählt auch")
		t.equal(screen.score, 200 - 2 * _cost, "und kostet erneut")
		t.check(Cards.freecell_hint_text(screen.hint_move) != first, "Er schlägt etwas anderes vor")

		# Ein Zug wischt den Tipp vom Brett — er zeigte auf alte Felder.
		screen.selection = {"from": "col", "index": 0, "start": (screen.columns[0] as Array).size() - 1}
		t.check(screen._try_move_to_cell(0), "Die unterste Karte kommt in die freie Zelle")
		t.check(screen.hint_move.is_empty(), "Der Tipp ist mit dem Zug verschwunden")

		# Und zurücknehmen holt den Zug zurück, nicht die Tippkosten.
		var after_move: int = screen.score
		screen.hint()
		var paid: int = screen.score
		t.equal(paid, after_move - _cost, "Der Tipp dazwischen hat etwas gekostet")
		screen.undo()
		t.equal(screen.score, paid, "Zurück holt den Zug, nicht die Tippkosten")
		t.check(screen.hint_move.is_empty(), "und der Tipp ist weg")

		# Das Aufleuchten endet von allein, statt über dem Brett zu stehen.
		screen.hint()
		t.check(screen.hint_life > 0.0, "Der Tipp leuchtet eine Weile")
		screen._process(_life + 1.0)
		t.equal(screen.hint_life, 0.0, "und erlischt von allein")
		t.check(screen.hint_move.is_empty(), "Der Tipp verschwindet mit")

		# Eine Lage ohne jeden sinnvollen Zug sagt das auch.
		screen.columns = _stuck_board()
		screen.free_cells = [Cards.Card.new(2, 0), Cards.Card.new(2, 1), Cards.Card.new(2, 2), Cards.Card.new(2, 3)]
		var quiet: int = screen.score
		screen.hint()
		t.check(screen.hint_move.is_empty(), "Es gibt nichts zu zeigen")
		t.equal(screen.score, quiet, "und das kostet nichts")
		t.check(str(screen._help_label.text).contains("R"), "Der Hinweis nennt die Taste für neu mischen")

		# Eine neue Partie beginnt ohne Schulden.
		screen.new_deal()
		t.equal(screen.hints_used, 0, "Ein neues Spiel zählt die Tipps neu")
		t.check(screen.hint_move.is_empty(), "und ohne Tipp")
		t.suite_done()
		_router.go_to("lobby")
		await tree.create_timer(0.3).timeout

	## Eight single cards with even ranks: nothing fits on anything, no ace is
	## reachable. A position the hint has to admit it cannot solve.
	func _stuck_board() -> Array:
		var ranks := [2, 4, 6, 8, 10, 12, 2, 4]
		var out: Array = []
		for i in 8:
			out.append([Cards.Card.new(ranks[i], 0 if i < 6 else 1)])
		return out

	## All button captions of the screen in one string.
	func _button_text(screen: Node) -> String:
		var out := ""
		for child in screen.stage().get_children():
			if child is Button:
				out += str((child as Button).text) + "|"
		return out

