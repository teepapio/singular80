class_name TestPoker
extends RefCounted
## Regeltests für Texas Hold'em.
##
## Eigene Datei neben `holdem.gd`, damit die Abdeckung dieses Spiels mit dem
## Spiel wandert. Die gemeinsame Suite in `test_logic.gd` prüft weiterhin Deck,
## Handbewertung und den Rundenablauf; hier steht alles um die
## Gegner-Persönlichkeiten, weil nur die eine Frage beantworten müssen:
## Zeigt der Tisch den Typ an, und spielt der Typ auch so?

var t: TestKit


## Entry point used by `run_tests.gd`.
func run(kit: TestKit) -> void:
	t = kit
	_suite(_poker_profiles)
	_suite(_poker_reading)
	_suite(_poker_tallies)


## Runs one suite and fails it if it returned before its own `t.suite_done()`,
## which is what a GDScript runtime error does.
func _suite(body: Callable) -> void:
	body.call()
	t.close_suite()


# --- helpers ----------------------------------------------------------------

## Spielt `hands` Hände und zählt, wie oft jeder KI-Sitz gefaltet, erhöht und
## gerufen hat. Der menschliche Sitz callt stumpf, damit die Gegner wirklich
## bis zum Showdown spielen. Der Rückgabe-Wert ist nach Sitz indexiert.
func _play_hands(hands: int) -> Dictionary:
	var game := Holdem.HoldemGame.new({"playerCount": 4, "startingChips": 4000})
	var counts: Dictionary = {}
	for i in game.players.size():
		counts[i] = {"folds": 0, "raises": 0, "calls": 0}

	for _n in hands:
		for i in game.players.size():
			if (game.players[i] as Holdem.Player).chips < 500:
				game.rebuy(i)
		game.start_hand()
		var guard := 0
		while not game.hand_over and guard < 600:
			guard += 1
			var seat := game.active_index
			if seat <= 0:
				var legal := game.legal_actions(0)
				game.act(0, {"type": "call"} if int(legal["callAmount"]) > 0 else {"type": "check"})
				continue
			if seat >= game.players.size():
				break
			var before: Dictionary = game.style_read(seat)
			game.act(seat, Holdem.choose_ai_action(game, seat))
			var after: Dictionary = game.style_read(seat)
			for key in counts[seat]:
				var tally: Dictionary = counts[seat]
				tally[key] = int(tally[key]) + int(after[key]) - int(before[key])
	return counts


# --- profile ----------------------------------------------------------------

func _poker_profiles() -> void:
	t.suite("Poker — Persönlichkeiten")

	# Genau drei Typen, und jeder ist vollständig beschrieben — die Anzeige liest
	# dieselben Felder, die `choose_ai_action` rechnet.
	t.equal(Holdem.STYLE_SEATS.size(), 3, "Drei Gegner-Typen am Tisch")
	t.equal(Holdem.STYLES.size(), 3, "Jeder Typ hat ein Profil")
	for style in Holdem.STYLE_SEATS:
		t.check(Holdem.has_style(str(style)), "Typ %s ist bekannt" % style)
		t.check(not Holdem.style_label(str(style)).is_empty(), "%s hat einen Namen" % style)
		t.check(not Holdem.style_hint(str(style)).is_empty(), "%s hat eine Kurzbeschreibung" % style)
		t.equal(Holdem.style_color(str(style)).length(), 6, "%s hat eine Farbe" % style)
		var profile := Holdem.style_profile(str(style))
		for key in ["fold_bias", "raise_scale", "bluff", "size_scale"]:
			t.check(profile.has(key), "Profil von %s hat %s" % [style, key])

	# Der Typ, den der Spieler nicht ist, hat keinen Namen.
	t.check(not Holdem.has_style(""), "Der Mensch hat keinen Typ")
	t.equal(Holdem.style_label(""), "", "Der menschliche Sitz bekommt keine Anzeige")
	t.equal(Holdem.style_for_seat(0), "", "Sitz 0 ist der Mensch")

	# Die Sitzreihenfolge ist fest, damit man die Gesichter zuordnen lernt.
	t.equal(Holdem.style_for_seat(1), Holdem.STYLE_TIGHT, "Sitz 1 ist der Stein")
	t.equal(Holdem.style_for_seat(2), Holdem.STYLE_LOOSE, "Sitz 2 spielt wild")
	t.equal(Holdem.style_for_seat(3), Holdem.STYLE_BLUFF, "Sitz 3 blufft")
	t.equal(Holdem.style_for_seat(4), Holdem.style_for_seat(1), "Ein fünfter Sitz wiederholt die Folge")

	# Ein unbekannter Typ fällt auf sichere Werte zurück, statt zu crashen.
	t.equal(Holdem.style_label("quatsch"), "", "Ein unbekannter Typ wird nicht angezeigt")
	t.equal(Holdem.style_profile("quatsch"), Holdem.style_profile(Holdem.STYLE_TIGHT), "Unbekannt heißt: so spielt der Stein")

	# Die Legende nennt jeden Typ mit Namen — sie entsteht aus denselben Feldern
	# wie die Anzeige am Sitz, kann also nicht veralten.
	var legend := Holdem.legend()
	for style in Holdem.STYLE_SEATS:
		t.check(legend.contains(Holdem.style_label(str(style))), "Legende nennt %s" % style)

	# Ein Spiel weist jedem KI-Sitz seinen Typ zu, und `styles` darf ihn
	# überschreiben, ohne dass der Konstruktor auf einem Tippfehler abbricht.
	# Der Eintrag an Stelle 0 bleibt ungenutzt — dort sitzt der Mensch.
	var game := Holdem.HoldemGame.new({
		"playerCount": 4,
		"styles": ["", Holdem.STYLE_BLUFF, "quatsch", ""],
	})
	t.equal((game.players[0] as Holdem.Player).style, "", "Der menschliche Sitz bleibt typenlos")
	t.equal((game.players[1] as Holdem.Player).style, Holdem.STYLE_BLUFF, "Ein gesetzter Typ greift")
	t.equal((game.players[2] as Holdem.Player).style, Holdem.style_for_seat(2), "Ein Unsinnstyp fällt auf die Sitzreihenfolge zurück")
	t.equal((game.players[3] as Holdem.Player).style, Holdem.style_for_seat(3), "Sitz 3 bekommt seinen Typ")

	# Der Typ überlebt jede Hand — eine Persönlichkeit wechselt nicht.
	game.start_hand()
	t.equal((game.players[1] as Holdem.Player).style, Holdem.STYLE_BLUFF, "Der Typ bleibt über die Hand erhalten")
	game.reset()
	t.equal((game.players[3] as Holdem.Player).style, Holdem.style_for_seat(3), "Auch ein Reset ändert den Typ nicht")
	t.suite_done()


# --- reading ----------------------------------------------------------------

func _poker_reading() -> void:
	t.suite("Poker — Tisches lesen")

	# Der Stein hält länger durch als der Wilde, mit jedem Einsatz.
	for to_call in [0, 20, 100, 400]:
		var pot := 300
		t.check(Holdem.fold_threshold(Holdem.STYLE_TIGHT, to_call, pot) >= Holdem.fold_threshold(Holdem.STYLE_LOOSE, to_call, pot),
			"Der Stein hält bei %d länger durch als der Wilde" % to_call)
		t.check(Holdem.fold_threshold(Holdem.STYLE_LOOSE, to_call, pot) <= 1.0, "Die Fold-Schwelle des Wilden bleibt eine Wahrscheinlichkeit")
		t.check(Holdem.fold_threshold(Holdem.STYLE_TIGHT, to_call, pot) <= 1.0, "Die Fold-Schwelle des Steins bleibt eine Wahrscheinlichkeit")

	# Kein Preis verlangt keine Stärke: mit Blind und Passivität hält der Stein
	# durch, der Wilde sowieso.
	t.almost(Holdem.fold_threshold(Holdem.STYLE_TIGHT, 0, 300), 0.5, 0.001, "Der Stein checkt preislos")
	t.check(Holdem.fold_threshold(Holdem.STYLE_LOOSE, 0, 300) < 0.2, "Der Wilde checkt fast immer")

	# Ein teurer Einsatz verschiebt die Schwelle auch für den Wilden nach oben.
	t.check(Holdem.fold_threshold(Holdem.STYLE_LOOSE, 900, 300) > Holdem.fold_threshold(Holdem.STYLE_LOOSE, 20, 300),
		"Ein teurer Einsatz macht auch den Wilden vorsichtig")

	# Der Bluff-Typ ist der einzige, der mit schwachen Karten raiset.
	t.check(Holdem.bluff_chance(Holdem.STYLE_BLUFF, 0.2) > 0.0, "Der Bluff-Typ raiset mit Müll")
	t.almost(Holdem.bluff_chance(Holdem.STYLE_TIGHT, 0.2), 0.0, 0.001, "Der Stein blufft nie")
	t.almost(Holdem.bluff_chance(Holdem.STYLE_TIGHT, 0.9), 0.0, 0.001, "Auch mit Topkarte blufft der Stein nicht")
	t.check(Holdem.bluff_chance(Holdem.STYLE_BLUFF, 0.2) > Holdem.bluff_chance(Holdem.STYLE_LOOSE, 0.2), "Der Bluff-Typ blufft am meisten")

	# Starke Hände raisen alle, aber der Stein raisst am seltensten.
	for strength in [0.5, 0.7, 0.85]:
		t.check(Holdem.raise_chance(Holdem.STYLE_TIGHT, strength) <= Holdem.raise_chance(Holdem.STYLE_LOOSE, strength),
			"Der Stein raiset bei %.2f nicht häufiger als der Wilde" % strength)
	t.check(Holdem.raise_chance(Holdem.STYLE_LOOSE, 0.85) > Holdem.raise_chance(Holdem.STYLE_LOOSE, 0.2), "Stärke erhöht die Raise-Chance")

	# Der Stein setzt auch kleiner als der Wilde.
	t.check(Holdem.raise_size(Holdem.STYLE_TIGHT, 0.85) < Holdem.raise_size(Holdem.STYLE_LOOSE, 0.85), "Der Stein setzt kleiner")

	# Und das zeigt sich in der Praxis: über viele Hände hinweg ist der Stein der
	# am häufigsten faltende Sitz, der Bluff-Typ der raisende.
	seed(20260926)
	var counts := _play_hands(60)
	var tight: Dictionary = counts[1]
	var loose: Dictionary = counts[2]
	var bluffer: Dictionary = counts[3]
	t.check(int(tight["folds"]) > int(loose["folds"]),
		"Der Stein faltet öfter als der Wilde (%d zu %d)" % [int(tight["folds"]), int(loose["folds"])])
	t.check(int(tight["raises"]) <= int(loose["raises"]),
		"Der Stein raiset nicht häufiger als der Wilde (%d zu %d)" % [int(tight["raises"]), int(loose["raises"])])
	t.check(int(loose["calls"]) > int(tight["calls"]),
		"Der Wilde ruft häufiger als der Stein (%d zu %d)" % [int(loose["calls"]), int(tight["calls"])])
	t.check(int(bluffer["raises"]) > int(tight["raises"]),
		"Der Bluff-Typ raiset am meisten (%d zu %d)" % [int(bluffer["raises"]), int(tight["raises"])])

	# Auch ein Dreier-Tisch startet und endet, und der menschliche Sitz bleibt
	# ahnungslos: er ist kein Typ.
	var plain := Holdem.HoldemGame.new({"playerCount": 3})
	plain.start_hand()
	var guard := 0
	while not plain.hand_over and guard < 400:
		guard += 1
		var seat := plain.active_index
		if seat <= 0:
			var legal := plain.legal_actions(0)
			plain.act(0, {"type": "call"} if int(legal["callAmount"]) > 0 else {"type": "check"})
			continue
		plain.act(seat, Holdem.choose_ai_action(plain, seat))
	t.check(plain.hand_over, "Auch ein Dreier-Tisch endet")
	t.equal(plain.style_read(0)["label"], "", "Der menschliche Sitz zeigt keinen Typ")
	t.suite_done()


# --- tally ------------------------------------------------------------------

func _poker_tallies() -> void:
	t.suite("Poker — Typen-Bilanz")

	var game := Holdem.HoldemGame.new({"playerCount": 4})
	game.start_hand()
	# Wer am Zug ist, entscheidet. Der Test hängt sich an den Zug und nicht an
	# eine feste Platznummer, damit die Reihenfolge des Motors hier nichts
	# zu bedeuten hat.
	var seat := game.active_index
	var player: Holdem.Player = game.players[seat]
	t.check(not player.style.is_empty(), "Der aktive Sitz hat einen Typen")
	t.check(game.act(seat, {"type": "fold"}), "Der aktive Sitz darf folden")
	var read: Dictionary = game.style_read(seat)
	t.equal(int(read["folds"]), 1, "Ein Fold wird gezählt")
	t.equal(int(read["raises"]), 0, "Fold zählt nicht als Raise")
	t.equal(int(read["seen"]), 1, "Ein Zug ist eine Beobachtung")
	t.almost(float(read["fold_rate"]), 1.0, 0.001, "Die Fold-Quote ist 1.0")
	t.equal(str(read["label"]), Holdem.style_label(player.style), "Die Bilanz nennt den Typen dieses Sitzes")
	t.equal(str(read["hint"]), Holdem.style_hint(player.style), "Die Bilanz nennt dessen Kurzbeschreibung")
	t.equal(str(read["color"]), Holdem.style_color(player.style), "Die Bilanz trägt dessen Farbe")

	# Ein frischer Sitz hat noch nichts beobachtet, die Quote ist 0 — die
	# Anzeige zeigt dann das Versprechen des Typs statt einer erfundenen Zahl.
	var other := 1 if seat != 1 else 2
	t.equal(int(game.style_read(other)["seen"]), 0, "Ein ungespielter Sitz hat keine Bilanz")
	t.almost(float(game.style_read(other)["fold_rate"]), 0.0, 0.001, "Ohne Beobachtung keine Quote")

	# Alle Felder, die die Anzeige am Sitz braucht, kommen aus einem Aufruf.
	t.check(game.style_read(0).has("style"), "Die Anzeige liefert den Typ")
	t.check(game.style_read(0).has("label"), "Die Anzeige liefert den Namen")
	t.check(game.style_read(0).has("hint"), "Die Anzeige liefert den Kurztext")
	t.check(game.style_read(0).has("color"), "Die Anzeige liefert die Farbe")
	for key in ["seen", "folds", "raises", "calls", "fold_rate"]:
		t.check(game.style_read(0).has(key), "Die Anzeige liefert %s" % key)
	t.suite_done()
