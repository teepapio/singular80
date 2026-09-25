class_name Holdem
extends RefCounted
## Texas Hold'em engine: deck management, 7-card evaluation, betting rounds,
## side pots and the computer opponents.
## Port of `src/game/holdem.ts`.

const CATEGORY_NAMES := [
	"High Card", "Paar", "Zwei Paare", "Drilling", "Straße", "Flush",
	"Full House", "Vierling", "Straight Flush", "Royal Flush",
]

const STREET_PREFLOP := "preflop"
const STREET_FLOP := "flop"
const STREET_TURN := "turn"
const STREET_RIVER := "river"
const STREET_SHOWDOWN := "showdown"


class Player:
	extends RefCounted
	var name: String = ""
	var is_human: bool = false
	var chips: int = 0
	var hole: Array = []
	var bet: int = 0
	var committed: int = 0
	var folded: bool = false
	var all_in: bool = false
	var has_acted: bool = false
	var last_action: String = ""

	func _init() -> void:
		hole = []


class HandValue:
	extends RefCounted
	## 0 = high card … 9 = royal flush. `score` packs the category and the
	## tie-break kickers into one comparable integer.
	var category: int = 0
	var hand_name: String = ""
	var score: int = 0

	func _init(p_category: int = 0, p_name: String = "", p_score: int = 0) -> void:
		category = p_category
		hand_name = p_name
		score = p_score


static func rank_value(rank: int) -> int:
	return 14 if rank == 0 else rank + 1


static func _straight_high(values: Array) -> int:
	var set := {}
	for v in values:
		set[v] = true
	if set.has(14):
		set[1] = true
	for high in range(14, 4, -1):
		if set.has(high) and set.has(high - 1) and set.has(high - 2) and set.has(high - 3) and set.has(high - 4):
			return high
	return 0


static func _make_score(category: int, kickers: Array) -> int:
	var score := category
	for i in 5:
		score = score * 15 + (int(kickers[i]) if i < kickers.size() else 0)
	return score


static func _value(category: int, kickers: Array) -> HandValue:
	return HandValue.new(category, CATEGORY_NAMES[category], _make_score(category, kickers))


## Best five-card hand out of 5, 6 or 7 cards.
static func evaluate7(cards: Array) -> HandValue:
	var rank_counts := PackedInt32Array()
	rank_counts.resize(13)
	var suit_ranks := [[], [], [], []]
	for card in cards:
		rank_counts[card.rank] += 1
		(suit_ranks[card.suit] as Array).append(rank_value(card.rank))

	var distinct: Array = []
	for rank in range(12, -1, -1):
		if rank_counts[rank] > 0:
			distinct.append(rank_value(rank))

	var straight_flush_high := 0
	var flush_suit := -1
	for suit in 4:
		var ranks: Array = suit_ranks[suit]
		if ranks.size() >= 5:
			flush_suit = suit
			var high := _straight_high(ranks)
			if high > straight_flush_high:
				straight_flush_high = high
	if straight_flush_high > 0:
		return _value(9 if straight_flush_high == 14 else 8, [straight_flush_high])

	for rank in 13:
		if rank_counts[rank] == 4:
			var quad := rank_value(rank)
			var kicker := 0
			for v in distinct:
				if v != quad:
					kicker = v
					break
			return _value(7, [quad, kicker])

	var trips: Array = []
	var pairs: Array = []
	for rank in range(12, -1, -1):
		if rank_counts[rank] >= 3:
			trips.append(rank_value(rank))
		elif rank_counts[rank] == 2:
			pairs.append(rank_value(rank))
	if not trips.is_empty():
		var pair: int = trips[1] if trips.size() >= 2 else (pairs[0] if not pairs.is_empty() else 0)
		if pair > 0:
			return _value(6, [trips[0], pair])

	if flush_suit >= 0:
		var suited: Array = (suit_ranks[flush_suit] as Array).duplicate()
		suited.sort_custom(func(a, b) -> bool: return int(a) > int(b))
		return _value(5, suited.slice(0, 5))

	var straight := _straight_high(distinct)
	if straight > 0:
		return _value(4, [straight])

	if not trips.is_empty():
		var trip: int = trips[0]
		var kickers: Array = []
		for v in distinct:
			if v != trip:
				kickers.append(v)
			if kickers.size() == 2:
				break
		kickers.push_front(trip)
		return _value(3, kickers)

	if pairs.size() >= 2:
		var high: int = pairs[0]
		var low: int = pairs[1]
		var kicker := 0
		for v in distinct:
			if v != high and v != low:
				kicker = v
				break
		return _value(2, [high, low, kicker])

	if pairs.size() == 1:
		var pair: int = pairs[0]
		var kickers: Array = []
		for v in distinct:
			if v != pair:
				kickers.append(v)
			if kickers.size() == 3:
				break
		kickers.push_front(pair)
		return _value(1, kickers)

	return _value(0, distinct.slice(0, 5))


static func _clamp01(value: float) -> float:
	return clampf(value, 0.0, 1.0)


## Rough pre-flop strength (0..1) based on ranks, pairs and suitedness.
static func hole_strength(hole: Array) -> float:
	if hole.size() < 2:
		return 0.0
	var v1 := float(rank_value(hole[0].rank))
	var v2 := float(rank_value(hole[1].rank))
	var high := maxf(v1, v2)
	var low := minf(v1, v2)
	var suited: bool = hole[0].suit == hole[1].suit
	var gap := int(high - low)

	var score := ((high - 2.0) / 12.0) * 0.5 + ((low - 2.0) / 12.0) * 0.28
	if int(high) == int(low):
		score += 0.34 + ((high - 2.0) / 12.0) * 0.16
	if suited:
		score += 0.08
	if gap == 1:
		score += 0.08
	elif gap == 2:
		score += 0.04
	if int(high) == 14:
		score += 0.06
	return _clamp01(score)


## Rough strength (0..1) of a made hand, used by the computer opponents.
static func made_strength(cards: Array) -> float:
	var hand := evaluate7(cards)
	var bases: Array = [0.1, 0.32, 0.52, 0.7, 0.8, 0.87, 0.93, 0.97, 0.99, 1.0]
	var base: float = float(bases[hand.category])
	var kicker := float(hand.score % 15)
	return _clamp01(base + (kicker / 14.0) * 0.05)


## A simple, occasionally bluffing opponent.
static func choose_ai_action(game: HoldemGame, index: int) -> Dictionary:
	var player: Holdem.Player = game.players[index]
	var legal := game.legal_actions(index)
	var to_call: int = int(legal["callAmount"])

	var base := hole_strength(player.hole) if game.community.is_empty() else made_strength(player.hole + game.community)
	var strength: float = _clamp01(base + (randf() - 0.5) * 0.18)
	var pot_odds := (float(to_call) / float(game.pot + to_call)) if to_call > 0 else 0.0

	if to_call > 0 and strength < 0.3 + pot_odds * 0.55:
		if randf() > strength * 0.7:
			return {"type": "fold"}

	if bool(legal["canRaise"]):
		if strength > 0.9 and randf() < 0.5:
			return {"type": "allin"}
		var raise_chance := 0.06
		if strength > 0.78:
			raise_chance = 0.8
		elif strength > 0.6:
			raise_chance = 0.45
		elif strength > 0.45:
			raise_chance = 0.15
		if randf() < raise_chance:
			var factor := 0.5
			if strength > 0.82:
				factor = 1.0
			elif strength > 0.66:
				factor = 0.75
			var raise_by: int = maxi(game.min_raise, int(round((float(game.pot) * factor) / float(game.big_blind))) * game.big_blind)
			var target: int = mini(game.current_bet + raise_by, int(legal["maxRaiseTo"]))
			if target < int(legal["minRaiseTo"]):
				target = mini(int(legal["minRaiseTo"]), int(legal["maxRaiseTo"]))
			if target > game.current_bet:
				return {"type": "raise", "target": target}

	if to_call <= 0:
		return {"type": "check"}
	return {"type": "call"}


class HoldemGame:
	extends RefCounted
	var players: Array = []
	var small_blind: int = 10
	var big_blind: int = 20
	var starting_chips: int = 1000

	var deck: Array = []
	var deck_index: int = 0
	var community: Array = []
	var pot: int = 0
	var street: String = STREET_SHOWDOWN
	var dealer: int = -1
	var active_index: int = 0
	var current_bet: int = 0
	var min_raise: int = 0
	var hand_over: bool = true
	var awards: Array = []
	var showdown_values: Array = []

	func _init(options: Dictionary = {}) -> void:
		var count: int = maxi(2, int(options.get("playerCount", 4)))
		starting_chips = int(options.get("startingChips", 1000))
		small_blind = int(options.get("smallBlind", 10))
		big_blind = int(options.get("bigBlind", 20))
		var names: Array = options.get("names", ["Du", "Alice", "Bob", "Cara", "Dan", "Eve"])
		for i in count:
			var player := Player.new()
			player.name = str(names[i]) if i < names.size() else "KI %d" % i
			player.is_human = i == 0
			player.chips = starting_chips
			players.append(player)
		reset()

	func reset() -> void:
		for player in players:
			player.chips = starting_chips
			player.hole = []
			player.bet = 0
			player.committed = 0
			player.folded = false
			player.all_in = false
			player.has_acted = false
			player.last_action = ""
		community = []
		deck = []
		deck_index = 0
		pot = 0
		street = STREET_SHOWDOWN
		dealer = -1
		active_index = 0
		current_bet = 0
		min_raise = big_blind
		hand_over = true
		awards = []
		showdown_values = []

	## Starts the next hand, rotating the dealer button and posting blinds.
	func start_hand() -> void:
		var count := players.size()
		deck = Cards.create_deck()
		Cards.shuffle(deck)
		deck_index = 0
		community = []
		pot = 0
		awards = []
		showdown_values = []
		hand_over = false
		current_bet = 0
		min_raise = big_blind
		dealer = (dealer + 1) % count

		for player in players:
			player.hole = []
			player.bet = 0
			player.committed = 0
			player.folded = false
			player.all_in = false
			player.has_acted = false
			player.last_action = ""

		var small_index: int = dealer if count == 2 else (dealer + 1) % count
		var big_index: int = (dealer + 1) % count if count == 2 else (dealer + 2) % count
		_commit(small_index, small_blind)
		_commit(big_index, big_blind)
		current_bet = big_blind
		min_raise = big_blind

		for round in 2:
			for step in range(1, count + 1):
				var i := (dealer + step) % count
				players[i].hole.append(deck[deck_index])
				deck_index += 1

		street = STREET_PREFLOP
		active_index = big_index
		_advance()

	func current_player() -> Player:
		return players[active_index]

	## Best five-card hand for a seat, or `null` before five cards are known.
	func best_value(index: int) -> Variant:
		var player: Player = players[index]
		if player.hole.size() + community.size() < 5:
			return null
		return Holdem.evaluate7(player.hole + community)

	func legal_actions(index: int) -> Dictionary:
		var player: Player = players[index]
		var to_call: int = maxi(0, current_bet - player.bet)
		var max_raise_to: int = player.bet + player.chips
		return {
		"canFold": true,
		"canCheck": to_call <= 0,
		"canCall": to_call > 0 and player.chips > 0,
		"callAmount": mini(to_call, player.chips),
		"canRaise": player.chips > to_call and max_raise_to > current_bet,
		"minRaiseTo": mini(current_bet + min_raise, max_raise_to),
		"maxRaiseTo": max_raise_to,
	}

	## Applies an action for `index` and advances turn order.
	func act(index: int, action: Dictionary) -> bool:
		if hand_over or index != active_index:
			return false
		var player: Player = players[index]
		if player.folded or player.all_in:
			return false
		var to_call := current_bet - player.bet
		var kind := str(action.get("type", ""))

		match kind:
			"fold":
				player.folded = true
				player.has_acted = true
				player.last_action = "Fold"
			"check":
				if to_call > 0:
					return false
				player.has_acted = true
				player.last_action = "Check"
			"call":
				if to_call <= 0:
					return false
				_commit(index, to_call)
				player.has_acted = true
				player.last_action = ("All-in %d" % player.bet) if player.all_in else ("Call %d" % player.bet)
			"raise":
				var max_to := player.bet + player.chips
				var target: int = mini(int(action.get("target", 0)), max_to)
				if target <= current_bet:
					return false
				if target < current_bet + min_raise and target < max_to:
					return false
				var increment := target - current_bet
				_commit(index, target - player.bet)
				if increment >= min_raise:
					min_raise = increment
				current_bet = player.bet
				player.has_acted = true
				player.last_action = ("All-in %d" % player.bet) if player.all_in else ("Erhöht %d" % player.bet)
			"allin":
				var total := player.bet + player.chips
				if total > current_bet:
					var step_up := total - current_bet
					_commit(index, player.chips)
					if step_up >= min_raise:
						min_raise = step_up
					current_bet = player.bet
				else:
					_commit(index, player.chips)
				player.has_acted = true
				player.last_action = "All-in %d" % player.bet
			_:
				return false

		_advance()
		return true

	## When a player busts, top their stack back up so the table keeps playing.
	func rebuy(index: int) -> void:
		players[index].chips = starting_chips

	func _commit(index: int, amount: int) -> int:
		var player: Player = players[index]
		var put: int = mini(amount, player.chips)
		player.chips -= put
		player.bet += put
		player.committed += put
		pot += put
		if player.chips == 0:
			player.all_in = true
		return put

	func _next_actor() -> int:
		var count := players.size()
		for step in range(1, count + 1):
			var i := (active_index + step) % count
			var player: Player = players[i]
			if player.folded or player.all_in:
				continue
			if not player.has_acted or player.bet < current_bet:
				return i
		return -1

	func _advance() -> void:
		var remaining := 0
		var last_alive := -1
		for i in players.size():
			if not players[i].folded:
				remaining += 1
				last_alive = i
		if remaining == 1:
			_award_uncontested(last_alive)
			return
		var next := _next_actor()
		if next >= 0:
			active_index = next
			return
		_next_street()

	func _next_street() -> void:
		for player in players:
			player.bet = 0
			player.has_acted = false
			if not player.folded:
				player.last_action = ""
		current_bet = 0
		min_raise = big_blind

		match street:
			STREET_PREFLOP:
				_deal_community(3)
				street = STREET_FLOP
			STREET_FLOP:
				_deal_community(1)
				street = STREET_TURN
			STREET_TURN:
				_deal_community(1)
				street = STREET_RIVER
			_:
				showdown()
				return
		_position_after_deal()

	func _position_after_deal() -> void:
		active_index = dealer
		var next := _next_actor()
		if next < 0:
			_next_street()
			return
		active_index = next

	func _deal_community(count: int) -> void:
		for i in count:
			community.append(deck[deck_index])
			deck_index += 1

	func _award_uncontested(winner: int) -> void:
		var amount := pot
		players[winner].chips += amount
		awards = [{"amount": amount, "winners": [winner]}]
		street = STREET_SHOWDOWN
		hand_over = true
		active_index = winner
		showdown_values = []
		for i in players.size():
			showdown_values.append(null if players[i].folded else best_value(i))

	## Resolves the pot(s), including side pots.
	func showdown() -> void:
		street = STREET_SHOWDOWN
		hand_over = true

		var committed: Array = []
		for player in players:
			committed.append(player.committed)
		var values: Array = []
		for i in players.size():
			values.append(null if players[i].folded else best_value(i))
		showdown_values = values

		var levels: Array = []
		for amount in committed:
			if int(amount) > 0 and not (int(amount) in levels):
				levels.append(int(amount))
		levels.sort()
		var awards_out: Array = []
		var previous := 0

		for level in levels:
			var amount := 0
			for contribution in committed:
				amount += maxi(0, mini(int(contribution), int(level)) - previous)
			previous = int(level)
			if amount <= 0:
				continue

			var eligible: Array = []
			for i in players.size():
				if not players[i].folded and int(committed[i]) >= int(level):
					eligible.append(i)
			if eligible.is_empty():
				continue

			var best_score := -1
			for i in eligible:
				var hand: Variant = values[i]
				if hand != null and (hand as Holdem.HandValue).score > best_score:
					best_score = (hand as Holdem.HandValue).score
			var winners: Array = []
			for i in eligible:
				var hand: Variant = values[i]
				if hand != null and (hand as Holdem.HandValue).score == best_score:
					winners.append(i)
			var share: int = int(floor(float(amount) / float(winners.size())))
			var distributed := 0
			for winner in winners:
				players[winner].chips += share
				distributed += share
			var remainder := amount - distributed
			if remainder > 0:
				players[winners[0]].chips += remainder
			awards_out.append({"amount": amount, "winners": winners})

		awards = awards_out
