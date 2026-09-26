class_name Cards
extends RefCounted
## Shared deck helpers for the card subgames.
## Port of `src/game/cards.ts`.
##
## Ranks are stored as indices 0..12 where 0 = "A" ... 12 = "K".
## Suits are indices 0..3: spades, hearts, diamonds, clubs.

const SUIT_SYMBOLS := ["♠", "♥", "♦", "♣"]
const SUIT_NAMES := ["Pik", "Herz", "Karo", "Kreuz"]
const RANK_LABELS := ["A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"]

const RED := Color(0.863, 0.149, 0.149)
const BLACK_SUIT := Color(0.118, 0.161, 0.231)


## Builds a full French deck of 52 cards in deterministic order.
static func create_deck() -> Array:
	var deck: Array = []
	for suit in 4:
		for rank in 13:
			deck.append(Card.new(rank, suit))
	return deck


## In-place Fisher-Yates shuffle.
static func shuffle(items: Array) -> void:
	for i in range(items.size() - 1, 0, -1):
		var j := randi() % (i + 1)
		var tmp: Variant = items[i]
		items[i] = items[j]
		items[j] = tmp


static func is_red_suit(suit: int) -> bool:
	return suit == 1 or suit == 2


static func is_red_card(card: Card) -> bool:
	return is_red_suit(card.suit)


static func label_of(card: Card) -> String:
	return RANK_LABELS[card.rank] + SUIT_SYMBOLS[card.suit]


static func color_for_suit(suit: int) -> Color:
	return RED if is_red_suit(suit) else BLACK_SUIT


# ══ FreeCell ═══════════════════════════════════════════════════════════════
# Alles ab hier gehört allein `godot/src/game/freecell`. Die Deck-Helfer oben
# bleiben das, was Poker benutzt. Die FreeCell-Regeln stehen hier statt im
# Screen, damit sie ohne Szene prüfbar sind — der Screen zeichnet nur noch.


## Wie viele der vier freien Zellen leer sind.
static func freecell_free_count(free_cells: Array) -> int:
	var count := 0
	for cell in free_cells:
		if cell == null:
			count += 1
	return count


## Wie viele der acht Stapel gerade leer sind.
static func freecell_empty_count(columns: Array) -> int:
	var count := 0
	for column in columns:
		if (column as Array).is_empty():
			count += 1
	return count


## Die Karten ab `start` bilden eine absteigende Folge mit wechselnder Farbe.
static func freecell_sequence(cards: Array, start: int) -> bool:
	if start < 0 or start >= cards.size():
		return false
	for i in range(start, cards.size() - 1):
		var a: Card = cards[i]
		var b: Card = cards[i + 1]
		if a.rank != b.rank + 1 or is_red_card(a) == is_red_card(b):
			return false
	return true


## Die berühmte Supermove-Kapazität: wie viele Karten auf `target` passen, wenn
## die freien Zellen und Leerstapel zur Verfügung stehen. Auf einen leeren
## Stapel zählt der Stapel selbst nicht mit.
static func freecell_capacity(free_cells: Array, columns: Array, target: int) -> int:
	var target_empty := target >= 0 and target < columns.size() and (columns[target] as Array).is_empty()
	var shifts := maxi(0, freecell_empty_count(columns) - (1 if target_empty else 0))
	return (freecell_free_count(free_cells) + 1) * int(pow(2.0, float(shifts)))


## Die Karte darf gefahrlos auf ihr eigenes Fundament: ihr Ziel ist dran und
## kein gegenüberliegendes Fundament ist weiter hinten. Wer sie liegen lässt,
## verliert sonst die Option, das andere vorzuziehen.
static func freecell_safe(foundations: Array, card: Card) -> bool:
	if card == null or card.suit < 0 or card.suit >= foundations.size():
		return false
	if (foundations[card.suit] as Array).size() != card.rank:
		return false
	if card.rank <= 1:
		return true
	for suit in foundations.size():
		if is_red_suit(suit) == is_red_card(card):
			continue
		if (foundations[suit] as Array).size() < card.rank:
			return false
	return true


## Die sinnvollen nächsten Züge, bester zuerst: sichere Karten nach Hause, dann
## was eine Spalte freilegt, dann was eine Folge zusammenbaut, und zuletzt das
## Beiseitelegen einer Karte, damit überhaupt etwas zu sagen ist. Leer heißt,
## dass kein sinnvoller Zug mehr offen ist. Jeder Vorschlag ist ein legaler Zug
## — das ist die Zusage, die der Tipp dem Spieler gibt.
static func freecell_suggest(free_cells: Array, foundations: Array, columns: Array, limit: int = 6) -> Array:
	var out: Array = []

	# 1. Nach Hause. Eine sichere Karte zu legen ist nie ein Fehler, und sie
	#    gibt die Zelle und den Stapel wieder frei.
	for i in free_cells.size():
		var cell: Variant = free_cells[i]
		if cell == null or not freecell_safe(foundations, cell):
			continue
		out.append(_freecell_move({"zone": "cell", "index": i, "start": 0},
				{"zone": "foundation", "index": (cell as Card).suit}, "safe", 400 + (cell as Card).rank))

	for c in columns.size():
		var column: Array = columns[c]
		if column.is_empty():
			continue
		var top: Card = column[column.size() - 1]
		if not freecell_safe(foundations, top):
			continue
		out.append(_freecell_move({"zone": "col", "index": c, "start": column.size() - 1},
				{"zone": "foundation", "index": top.suit}, "safe", 400 + top.rank))

	# 2. Karten aus den Zellen legen: auf eine passende Karte darunter oder in
	#    einen leeren Stapel, der dadurch wieder beweglich wird.
	for i in free_cells.size():
		var cell: Variant = free_cells[i]
		if cell == null:
			continue
		for d in columns.size():
			var target: Array = columns[d]
			if not target.is_empty():
				if _freecell_fits(cell, target[target.size() - 1]):
					out.append(_freecell_move({"zone": "cell", "index": i, "start": 0},
							{"zone": "col", "index": d, "empty": false}, "build", 180, 1,
							cell, target[target.size() - 1]))
				continue
			# Irgendein leerer Stapel tut es — einer als Rat genügt.
			out.append(_freecell_move({"zone": "cell", "index": i, "start": 0},
					{"zone": "col", "index": d, "empty": true}, "shift", 190))
			break

	# 3. Folgen verschieben.
	for c in columns.size():
		var column: Array = columns[c]
		for s in column.size():
			if not freecell_sequence(column, s):
				continue
			var count := column.size() - s
			for d in columns.size():
				if d == c:
					continue
				var target: Array = columns[d]
				if target.is_empty() or not _freecell_fits(column[s], target[target.size() - 1]):
					continue
				if count > freecell_capacity(free_cells, columns, d):
					continue
				# s == 0 heißt: die Folge ist der ganze Stapel, er wird leer.
				# Der beste Zug im Spiel, weil ein leerer Stapel alles erlaubt.
				if s == 0:
					out.append(_freecell_move({"zone": "col", "index": c, "start": 0},
							{"zone": "col", "index": d, "empty": false}, "build", 300, count,
							column[0], target[target.size() - 1], "  ·  Spalte %d wird frei" % (c + 1)))
				else:
					out.append(_freecell_move({"zone": "col", "index": c, "start": s},
							{"zone": "col", "index": d, "empty": false}, "build", 200 + count * 12, count,
							column[s], target[target.size() - 1]))

	# 4. Die unterste Karte eines Stapels in eine freie Zelle legen. Legt sie
	#    eine Folge frei, ist das der eigentliche Gewinn — sonst bleibt es ein
	#    Zug, denn ein Tipp, der schweigt, hilft niemandem.
	for c in columns.size():
		var column: Array = columns[c]
		var last := column.size() - 1
		if last < 0 or not freecell_sequence(column, last):
			continue
		var weight := 120 if last > 0 and freecell_sequence(column, last - 1) else 60
		for i in free_cells.size():
			if free_cells[i] != null:
				continue
			out.append(_freecell_move({"zone": "col", "index": c, "start": last},
					{"zone": "cell", "index": i}, "park", weight, 1, column[last], null))
			break

	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["score"]) > int(b["score"]))
	if out.size() > limit:
		out.resize(limit)
	return out


## Ein Vorschlag als ein Satz für die Hinweiszeile.
static func freecell_hint_text(move: Dictionary) -> String:
	var from: Dictionary = move["from"]
	var to: Dictionary = move["to"]
	var what := str(move["label"])
	if int(move["count"]) > 1:
		what += " +%d" % (int(move["count"]) - 1)
	var zone := str(to["zone"])
	if zone == "foundation":
		return "%s kommt sicher auf das %s-Fundament" % [what, SUIT_NAMES[int(to["index"])]]
	if zone == "cell":
		return "%s in die freie Zelle %d" % [what, int(to["index"]) + 1]
	if int(to.get("empty", false)):
		if str(from["zone"]) == "cell":
			return "%s gibt Zelle %d frei" % [what, int(from["index"]) + 1]
		return "%s in den leeren Stapel %d" % [what, int(to["index"]) + 1]
	return "%s passt auf %s in Spalte %d%s" % [what, str(move["onto"]), int(to["index"]) + 1, str(move.get("note", ""))]


## Passt die Karte auf die andere (Farbe und Wurfhöhe müssen stimmen).
static func _freecell_fits(card: Card, onto: Card) -> bool:
	return onto.rank == card.rank + 1 and is_red_card(onto) != is_red_card(card)


static func _freecell_move(from: Dictionary, to: Dictionary, kind: String, score: int,
		count: int = 1, head: Card = null, onto: Card = null, note: String = "") -> Dictionary:
	return {
		"from": from,
		"to": to,
		"kind": kind,
		"score": score,
		"count": count,
		"label": "" if head == null else label_of(head),
		"onto": "" if onto == null else label_of(onto),
		"note": note,
	}


class Card:
	extends RefCounted
	var rank: int
	var suit: int

	func _init(card_rank: int = 0, card_suit: int = 0) -> void:
		rank = card_rank
		suit = card_suit

	func _to_string() -> String:
		return Cards.label_of(self)
