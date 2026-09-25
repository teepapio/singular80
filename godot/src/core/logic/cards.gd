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


class Card:
	extends RefCounted
	var rank: int
	var suit: int

	func _init(card_rank: int = 0, card_suit: int = 0) -> void:
		rank = card_rank
		suit = card_suit

	func _to_string() -> String:
		return Cards.label_of(self)
