class_name Cards
extends RefCounted
## Shared deck helpers for the card subgames.
##
## Ranks are stored as indices 0..12 where 0 = "A" ... 12 = "K".
## Suits are indices 0..3: spades, hearts, diamonds, clubs.
##
## Ranks are stored as indices 0..12 where 0 = "A" ... 12 = "K".
## Suits are indices 0..3: spades, hearts, diamonds, clubs.

const SUIT_SYMBOLS := ["♠", "♥", "♦", "♣"]
## The suit names are a display name, not a deck index, and they reach the player
## inside a sentence — so they get keys, and the sentence around them stays a
## template the catalogue can reorder.
const SUIT_LOC_KEYS: Array[String] = [
	"cards.suit.spades",
	"cards.suit.hearts",
	"cards.suit.diamonds",
	"cards.suit.clubs",
]
const RANK_LABELS := ["A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"]


## The suit name in the player's language.
static func suit_name(index: int) -> String:
	if index < 0 or index >= SUIT_LOC_KEYS.size():
		return ""
	return Loc.t(SUIT_LOC_KEYS[index])

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


# == FreeCell =================================================================
# Everything below belongs to `godot/src/game/freecell` alone; the deck helpers
# above stay what Poker uses. The FreeCell rules live here instead of in the
# screen so they are testable without a scene — the screen only draws.


## How many of the four free cells are empty.
static func freecell_free_count(free_cells: Array) -> int:
	var count := 0
	for cell in free_cells:
		if cell == null:
			count += 1
	return count


## How many of the eight columns are currently empty.
static func freecell_empty_count(columns: Array) -> int:
	var count := 0
	for column in columns:
		if (column as Array).is_empty():
			count += 1
	return count


## The cards from `start` on form a descending sequence of alternating colour.
static func freecell_sequence(cards: Array, start: int) -> bool:
	if start < 0 or start >= cards.size():
		return false
	for i in range(start, cards.size() - 1):
		var a: Card = cards[i]
		var b: Card = cards[i + 1]
		if a.rank != b.rank + 1 or is_red_card(a) == is_red_card(b):
			return false
	return true


## The famous supermove capacity: how many cards fit on `target` with the free
## cells and empty columns at hand. Moving onto an empty column does not count
## that column itself.
static func freecell_capacity(free_cells: Array, columns: Array, target: int) -> int:
	var target_empty := target >= 0 and target < columns.size() and (columns[target] as Array).is_empty()
	var shifts := maxi(0, freecell_empty_count(columns) - (1 if target_empty else 0))
	return (freecell_free_count(free_cells) + 1) * int(pow(2.0, float(shifts)))


## The card may safely go to its own foundation: its target is on it and no
## foundation of the other colour is further behind. Leaving it lying there
## costs the option of playing the other one first.
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


## The sensible next moves, best first: safe cards home, then what frees a column,
## then what builds a sequence, and last parking a card so there is something to
## say at all. Empty means no sensible move is left. Every suggestion is a legal
## move — that is the promise the tip makes to the player.
static func freecell_suggest(free_cells: Array, foundations: Array, columns: Array, limit: int = 6) -> Array:
	var out: Array = []

	# 1. Home. Playing a safe card is never a mistake and it frees the cell and
	#    the column again.
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

	# 2. Move cards out of the cells: onto a matching card below, or into an empty
	#    column that thereby becomes movable again.
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
			# Any empty column will do — one is advice enough.
			out.append(_freecell_move({"zone": "cell", "index": i, "start": 0},
					{"zone": "col", "index": d, "empty": true}, "shift", 190))
			break

	# 3. Move sequences.
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
				# s == 0 means the sequence is the whole column, which becomes empty:
				# the best move in the game, because an empty column allows anything.
				if s == 0:
					out.append(_freecell_move({"zone": "col", "index": c, "start": 0},
							{"zone": "col", "index": d, "empty": false}, "build", 300, count,
							column[0], target[target.size() - 1], "  ·  Spalte %d wird frei" % (c + 1)))
				else:
					out.append(_freecell_move({"zone": "col", "index": c, "start": s},
							{"zone": "col", "index": d, "empty": false}, "build", 200 + count * 12, count,
							column[s], target[target.size() - 1]))

	# 4. Move the bottom card of a column into a free cell. If that frees a
	#    sequence, that is the real gain — otherwise it is still a move, because a
	#    tip that says nothing helps nobody.
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


## One suggestion as a sentence for the hint line.
static func freecell_hint_text(move: Dictionary) -> String:
	var from: Dictionary = move["from"]
	var to: Dictionary = move["to"]
	var what := str(move["label"])
	if int(move["count"]) > 1:
		what += " +%d" % (int(move["count"]) - 1)
	var zone := str(to["zone"])
	if zone == "foundation":
		return Loc.f("%s goes safely onto the %s foundation", [what, suit_name(int(to["index"]))])
	if zone == "cell":
		return Loc.f("%s into the free cell %d", [what, int(to["index"]) + 1])
	if int(to.get("empty", false)):
		if str(from["zone"]) == "cell":
			return Loc.f("%s frees cell %d", [what, int(from["index"]) + 1])
		return Loc.f("%s into the empty stack %d", [what, int(to["index"]) + 1])
	return Loc.f("%s fits onto %s in column %d%s", [what, str(move["onto"]), int(to["index"]) + 1, str(move.get("note", ""))])


## Does the card fit on the other one (suit and rank must both match)?
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
