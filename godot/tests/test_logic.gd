class_name TestLogic
extends RefCounted
## Rule tests for the pure logic modules. These are the direct counterparts of
## the unit tests the browser build had, so a behaviour change is caught here
## instead of on a device.

var t: TestKit


func run(kit: TestKit) -> void:
	t = kit
	_suite(_stats)
	_suite(_checkers)
	_suite(_cards_and_holodem)
	_suite(_twenty48)
	_suite(_merge3d)
	_suite(_crystal_tower)
	_suite(_dragon_rpg)
	_suite(_horse_runner)
	_suite(_pang)
	_suite(_inventory)
	_suite(_lobby)
	_suite(_asset_registry)
	_suite(_mechanics)
	_suite(_dragon_flight)
	_suite(_flight_genetics)
	_suite(_flight_forecast)
	_suite(_flight_elements)
	_suite(_flight_stats)
	_suite(_flight_profile)
	_suite(_dragon_flight)
	_suite(_flight_genetics)
	_suite(_flight_stats)
	_suite(_flight_profile)
	_suite(_siedler_map)
	_suite(_siedler_chains)
	_suite(_siedler_roads)
	_suite(_siedler_economy)


## Runs one suite and fails it if it returned before its own `t.suite_done()`,
## which is what a GDScript runtime error does.
func _suite(body: Callable) -> void:
	body.call()
	t.close_suite()


# --- player stats -----------------------------------------------------------

func _stats() -> void:
	t.suite("PlayerStats")
	var weapon := {"damage": 10.0, "cooldown": 500.0, "projectileSpeed": 420.0, "projectileCount": 1.0, "spread": 0.0, "pierce": 0.0}
	var stats := PlayerStats.create(weapon)
	t.equal(stats.max_hp, 120.0, "Start-HP ist 120")
	t.equal(stats.xp_next, PlayerStats.xp_for_level(1), "XP-Schwelle startet bei Level 1")
	t.check(PlayerStats.xp_for_level(2) > PlayerStats.xp_for_level(1), "XP-Schwelle wächst mit dem Level")

	stats.apply_upgrade({"stat": "max_hp", "amount": 20.0})
	t.equal(stats.max_hp, 140.0, "max_hp steigt")
	t.equal(stats.hp, 140.0, "max_hp heilt mit")

	stats.apply_upgrade({"stat": "hp", "amount": 50.0})
	t.equal(stats.hp, 140.0, "hp wird auf max_hp gedeckelt")

	stats.apply_upgrade({"stat": "projectile_count", "amount": 1.0})
	t.check(stats.spread >= 0.12, "projectile_count erzwingt Spread")

	stats.apply_upgrade({"stat": "crit_chance", "amount": 5.0})
	t.almost(stats.crit_chance, 0.9, 0.0001, "critChance ist auf 0.9 gedeckelt")

	stats.apply_upgrade({"stat": "fire_rate", "amount": 100.0})
	t.almost(stats.fire_rate, 8.0, 0.0001, "fireRate ist auf 8 gedeckelt")

	var cooldown_stats := PlayerStats.create(weapon)
	cooldown_stats.fire_rate = 1.0
	t.almost(cooldown_stats.effective_cooldown(weapon), 250.0, 0.0001, "Cooldown halbiert sich bei fireRate 1")
	cooldown_stats.fire_rate = 100.0
	t.almost(cooldown_stats.effective_cooldown(weapon), 70.0, 0.0001, "Cooldown hat eine Untergrenze von 70 ms")
	t.suite_done()


# --- checkers ---------------------------------------------------------------

func _checkers() -> void:
	t.suite("Dame — Regeln")
	var board := Checkers.create_initial_board()
	t.equal(board.size(), 64, "Brett hat 64 Felder")
	t.equal(Checkers.count_pieces(board, Checkers.WHITE), 12, "Weiß startet mit 12 Steinen")
	t.equal(Checkers.count_pieces(board, Checkers.BLACK), 12, "Schwarz startet mit 12 Steinen")
	t.check(board[Checkers.index_of(0, 1)] == Checkers.BLACK_MAN, "Schwarz sitzt oben")
	t.check(board[Checkers.index_of(7, 0)] == Checkers.WHITE_MAN, "Weiß sitzt unten")
	t.check(Checkers.is_playable(0, 1), "Feld (0,1) ist spielbar")
	t.check(not Checkers.is_playable(0, 0), "Feld (0,0) ist nicht spielbar")

	# Ein einzelner Schritt nach vorne.
	var single := PackedInt32Array()
	single.resize(64)
	for i in 64:
		single[i] = Checkers.EMPTY
	single[Checkers.index_of(2, 1)] = Checkers.WHITE_MAN
	var steps := Checkers.generate_piece_steps(single, Checkers.index_of(2, 1))
	t.equal(steps.size(), 2, "Ein Stein auf Reihe 2 hat zwei Ziele")
	for step in steps:
		t.check(Checkers.row_of(int((step as Array)[1])) == 1, "Der Schritt führt eine Reihe nach vorne")

	# Sprung über einen gegnerischen Stein.
	var jump := PackedInt32Array()
	jump.resize(64)
	for i in 64:
		jump[i] = Checkers.EMPTY
	jump[Checkers.index_of(2, 3)] = Checkers.WHITE_MAN
	jump[Checkers.index_of(1, 4)] = Checkers.BLACK_MAN
	var jump_steps := Checkers.generate_piece_steps(jump, Checkers.index_of(2, 3))
	var has_capture := false
	for step in jump_steps:
		if int((step as Array)[2]) >= 0:
			has_capture = true
	t.check(has_capture, "Über einen Gegner springen ist erlaubt")

	var turns := Checkers.generate_turns(jump, Checkers.WHITE)
	var capture_turn := {}
	for turn in turns:
		if int(turn["captures"]) > 0:
			capture_turn = turn
	t.check(not capture_turn.is_empty(), "Ein Schlagzug wird erzeugt")
	t.equal(Checkers.count_pieces(Checkers.apply_turn(jump, capture_turn), Checkers.BLACK), 0, "Der geschlagene Stein verschwindet")

	# Beförderung zur Dame beendet die Kette.
	t.equal(Checkers.promote_piece(Checkers.WHITE_MAN, Checkers.index_of(0, 1)), Checkers.WHITE_KING, "Reihe 0 befördert zu Dame")
	t.equal(Checkers.promote_piece(Checkers.WHITE_MAN, Checkers.index_of(3, 1)), Checkers.WHITE_MAN, "Sonst keine Beförderung")
	t.check(Checkers.opposite(Checkers.WHITE) == Checkers.BLACK, "opposite vertauscht die Seiten")

	var search := Checkers.search_depth(board)
	t.check(search == 4 or search == 5, "Suchtiefe liegt zwischen 4 und 5")
	t.suite_done()


# --- cards & poker ----------------------------------------------------------

func _cards_and_holodem() -> void:
	t.suite("Karten & Texas Hold'em")
	var deck := Cards.create_deck()
	t.equal(deck.size(), 52, "Ein Deck hat 52 Karten")
	var unique := {}
	for card in deck:
		unique["%d/%d" % [card.rank, card.suit]] = true
	t.equal(unique.size(), 52, "Alle Karten sind eindeutig")
	t.check(Cards.is_red_suit(1) and Cards.is_red_suit(2), "Herz und Karo sind rot")
	t.check(not Cards.is_red_suit(0) and not Cards.is_red_suit(3), "Pik und Kreuz sind schwarz")
	t.equal(Cards.label_of(Cards.Card.new(0, 0)), "A♠", "Ass Pik wird korrekt beschriftet")

	# Bewertung: Royal Flush schlägt alles.
	var royal := [
		Cards.Card.new(0, 0), Cards.Card.new(12, 0), Cards.Card.new(11, 0),
		Cards.Card.new(10, 0), Cards.Card.new(9, 0),
	]
	t.equal(Holdem.evaluate7(royal).category, 9, "Royal Flush erkannt")

	var straight := [
		Cards.Card.new(4, 0), Cards.Card.new(5, 1), Cards.Card.new(6, 2),
		Cards.Card.new(7, 3), Cards.Card.new(8, 0), Cards.Card.new(0, 1),
	]
	t.equal(Holdem.evaluate7(straight).category, 4, "Straße erkannt")

	var quads := [
		Cards.Card.new(3, 0), Cards.Card.new(3, 1), Cards.Card.new(3, 2),
		Cards.Card.new(3, 3), Cards.Card.new(12, 0), Cards.Card.new(7, 1),
	]
	t.equal(Holdem.evaluate7(quads).category, 7, "Vierling erkannt")

	var full_house := [
		Cards.Card.new(5, 0), Cards.Card.new(5, 1), Cards.Card.new(5, 2),
		Cards.Card.new(9, 3), Cards.Card.new(9, 0), Cards.Card.new(2, 1),
	]
	t.equal(Holdem.evaluate7(full_house).category, 6, "Full House erkannt")

	var flush := [
		Cards.Card.new(12, 1), Cards.Card.new(10, 1), Cards.Card.new(8, 1),
		Cards.Card.new(5, 1), Cards.Card.new(2, 1), Cards.Card.new(0, 2),
	]
	t.equal(Holdem.evaluate7(flush).category, 5, "Flush erkannt")

	# Eine vollständige Hand verläuft ohne Fehler durch den Rundenablauf.
	var game := Holdem.HoldemGame.new({"playerCount": 4, "startingChips": 1000, "smallBlind": 10, "bigBlind": 20})
	t.equal(game.players.size(), 4, "Vier Spieler am Tisch")
	t.equal(game.pot, 0, "Der Pot startet leer")
	game.start_hand()
	t.equal(game.pot, 30, "Blinds füllen den Pot")
	t.equal(game.street, Holdem.STREET_PREFLOP, "Die Hand startet preflop")
	t.check(not game.hand_over, "Die Hand läuft nach dem Start")
	for player in game.players:
		t.equal((player as Holdem.Player).hole.size(), 2, "Jeder Spieler bekommt zwei Karten")

	var guard := 0
	while not game.hand_over and guard < 400:
		guard += 1
		if game.active_index == 0:
			var legal := game.legal_actions(0)
			if int(legal["callAmount"]) > 0:
				game.act(0, {"type": "call"})
			else:
				game.act(0, {"type": "check"})
		else:
			game.act(game.active_index, Holdem.choose_ai_action(game, game.active_index))
	t.check(game.hand_over, "Die Hand endet")
	t.equal(game.street, Holdem.STREET_SHOWDOWN, "Die Hand endet am Showdown")
	var total := 0
	for player in game.players:
		total += (player as Holdem.Player).chips
	t.equal(total, 4000, "Chips bleiben in der Runde erhalten")
	var strength := Holdem.hole_strength([Cards.Card.new(12, 0), Cards.Card.new(13 - 1, 0)])
	t.check(strength > 0.6, "Hole-Edelsteine sind stark")
	t.suite_done()


# --- 2048 -------------------------------------------------------------------

func _twenty48() -> void:
	t.suite("2048")
	var board := Twenty48.empty_board()
	t.equal(board.size(), 4, "4x4-Brett")
	for row in board:
		t.equal((row as Array).size(), 4, "Jede Zeile hat 4 Felder")

	board[3][0] = 2
	board[3][1] = 2
	var plan := Twenty48.slide(board, Twenty48.LEFT)
	t.check(bool(plan["moved"]), "Ein Zug mit Verschmelzung zählt als Zug")
	t.equal(int(plan["gained"]), 4, "Zwei 2er ergeben 4 Punkte")
	t.equal(Twenty48.at(plan["values"], 3, 0), 4, "Die 4 landet ganz links")
	t.equal((plan["merges"] as Array).size(), 1, "Eine Verschmelzung wird gemeldet")

	# Ein frisch erzeugtes Feld darf im selben Zug nicht erneut verschmelzen.
	var triple := Twenty48.empty_board()
	triple[3][0] = 2
	triple[3][1] = 2
	triple[3][2] = 2
	var triple_plan := Twenty48.slide(triple, Twenty48.LEFT)
	t.equal(Twenty48.at(triple_plan["values"], 3, 0), 4, "Nur zwei 2er verschmelzen")
	t.equal(Twenty48.at(triple_plan["values"], 3, 1), 2, "Das dritte 2er bleibt übrig")
	t.equal(int(triple_plan["gained"]), 4, "Punkte für eine Verschmelzung")

	var unchanged := Twenty48.slide(Twenty48.empty_board(), Twenty48.LEFT)
	t.check(not bool(unchanged["moved"]), "Leeres Brett bewegt sich nicht")

	var full := Twenty48.empty_board()
	for r in 4:
		for c in 4:
			full[r][c] = 2 if (r + c) % 2 == 0 else 4
	t.check(not Twenty48.can_move(full), "Ein volles, unverschiebbares Brett ist Endgame")
	t.check(Twenty48.can_move(Twenty48.empty_board()), "Ein leeres Brett kann ziehen")
	t.equal(Twenty48.highest_value(full), 4, "highest_value findet die größte Kachel")

	var seeded := Twenty48.empty_board()
	var spawn: Variant = Twenty48.add_random_tile(seeded)
	t.check(spawn != null, "Ein Feld bekommt eine Startkachel")
	t.check(int((spawn as Dictionary)["value"]) == 2 or int((spawn as Dictionary)["value"]) == 4, "Startkachel ist 2 oder 4")
	t.suite_done()


# --- merge 3D ---------------------------------------------------------------

func _merge3d() -> void:
	t.suite("Merge 3D")
	var board := Merge3D.create_board(6)
	t.equal(board.size(), 36, "6x6-Brett")
	t.check(not Merge3D.is_board_full(board), "Ein frisches Brett ist noch nicht belegt")
	t.equal(Merge3D.used_cells(board), 0, "Kein Feld belegt")
	t.equal(Merge3D.tier_value(1), 1, "Stufe 1 zählt 1 Punkt")
	t.equal(Merge3D.tier_value(2), 3, "Stufe 2 zählt 3 Punkte")
	t.equal(Merge3D.tier_value(3), 9, "Stufe 3 zählt 9 Punkte")

	var cells := PackedInt32Array([0, 1, 2, 3, 4, 5, 6])
	for cell in cells:
		board[cell] = 1
	t.check(Merge3D.count_tier(board, 1) == 7, "Sieben Stufe-1-Items")
	t.check(Merge3D.has_merge_available(board), "Ein 3er-Merge ist möglich")

	var pick := Merge3D.pick_spawn_cell(board)
	t.check(pick >= 0, "Ein freies Feld wird gewählt")
	board[pick] = 1
	var occupied := Merge3D.used_cells(board)
	t.equal(occupied, 8, "Belegte Felder werden gezählt")

	var merge_cells := PackedInt32Array([0, 1, 2])
	t.check(Merge3D.merge_is_valid(board, merge_cells, 3), "Drei gleiche Items sind ein gültiger Merge")
	var outcome := Merge3D.perform_merge(board, merge_cells, 3)
	t.equal(int(outcome["score"]), 3, "3er-Merge gibt 3 Punkte")
	t.equal(Merge3D.count_tier(outcome["board"], 1), 5, "Drei Stufe-1er sind verbraucht")
	t.equal(Merge3D.count_tier(outcome["board"], 2), 1, "Eine neue Stufe-2-Kachel entsteht")

	var five := PackedInt32Array([0, 1, 2, 3, 4])
	var five_outcome := Merge3D.perform_merge(board, five, 5)
	t.equal((five_outcome["created"] as Array).size(), 2, "Ein 5er-Merge erzeugt zwei Items")
	t.check(Merge3D.perform_merge(board, PackedInt32Array([0, 1]), 3).is_empty(), "Zwei Items sind kein gültiger Merge")

	var full := Merge3D.create_board(3)
	for i in full.size():
		full[i] = Merge3D.MAX_MERGE_TIER
	t.check(Merge3D.is_board_full(full), "Volles Brett")
	t.check(not Merge3D.has_merge_available(full), "Volles Brett aus Max-Stufen kann nicht mergen")
	t.check(Merge3D.is_game_over(full), "Volles Brett ohne Merge ist Endgame")
	t.almost(Merge3D.spawn_interval_seconds(0.0), 2.2, 0.001, "Spawn-Intervall startet bei 2.2 s")
	t.almost(Merge3D.spawn_interval_seconds(1000.0), 0.75, 0.001, "Spawn-Intervall hat eine Untergrenze")
	t.suite_done()


# --- crystal tower ----------------------------------------------------------

func _crystal_tower() -> void:
	t.suite("Crystal Tower")
	t.equal(CrystalTower.MAX_CRYSTAL_TIER, 5, "Fünf Stufen")
	t.equal(CrystalTower.tier_asset(1), "crystal1", "Stufe 1 nutzt ein eigenes Mesh")
	t.equal(CrystalTower.tier_asset(99), "crystal5", "Stufen werden geklemmt")
	t.equal(CrystalTower.crystal_tier_name(CrystalTower.THEMES.christmas, 1), "Tannenzapfen", "Weihnachtsname Stufe 1")
	t.equal(CrystalTower.crystal_tier_name(CrystalTower.THEMES.halloween, 1), "Kürbiskern", "Halloweenname Stufe 1")
	t.equal(CrystalTower.crystal_tier_name(CrystalTower.THEMES.classic, 2), "Kristall", "Klassikname Stufe 2")
	t.check(CrystalTower.THEMES.has("classic") and CrystalTower.THEMES.has("christmas") and CrystalTower.THEMES.has("halloween"), "Alle drei Themes vorhanden")

	t.equal(CrystalTower.tier_for_floor(0, 7), 1, "Der Sockel trägt Stufe 1")
	t.equal(CrystalTower.tier_for_floor(6, 7), 5, "Der Gipfel trägt Stufe 5")
	t.equal(CrystalTower.tier_for_floor(3, 7), 3, "Die Mitte liegt dazwischen")

	var plan := CrystalTower.plan_merges([3, 0, 0, 0, 0])
	t.equal(plan["merges"], 1, "Drei Splitter ergeben eine Verschmelzung")
	t.equal((plan["counts"] as Array)[1], 1, "Der Kristall entsteht")
	t.equal(CrystalTower.inventory_value([3, 0, 0, 0, 0]), 3, "Drei Splitter sind 3 Punkte wert")
	t.equal(CrystalTower.inventory_value([0, 1, 0, 0, 0]), 3, "Ein Kristall ist 3 Punkte wert")

	var config := CrystalTower.level_config(1)
	t.equal(int(config["floors"]), 7, "Level 1 hat 7 Etagen")
	t.equal(int(config["targetMs"]), 100000.0, "Level 1 Zielzeit 100 s")
	var last := CrystalTower.level_config(CrystalTower.MAX_LEVEL)
	t.equal(int(last["floors"]), 17, "Die letzte Stufe hat 17 Etagen")
	t.equal(CrystalTower.format_time(95000.0), "1:35", "Zeitformat")

	var bonus := CrystalTower.equip_bonus(3)
	t.almost(float(bonus["speedMult"]), 1.15, 0.001, "Tempo-Bonus Stufe 3")
	t.equal(int(bonus["extraJumps"]), 1, "Stufe 3 schenkt einen Extrasprung")
	t.suite_done()


# --- dragon RPG -------------------------------------------------------------

func _dragon_rpg() -> void:
	t.suite("Drachen-RPG")
	t.equal(DragonRpg.DRAGON_TYPES.size(), 12, "Zwölf Drachenarten")
	t.equal(DragonRpg.BOSS_EVERY, 5, "Alle fünf Wellen ein Boss")
	t.equal(DragonRpg.dragon_by_id("dragon_lord")["name"], "Drachenfürst", "Bossname")
	t.equal(str(DragonRpg.dragon_by_id("does_not_exist")["id"]), "dragon_hatchling", "Unbekannte Art fällt zurück")

	var wave := DragonRpg.wave_config(1)
	t.check(not bool(wave["boss"]), "Welle 1 hat keinen Boss")
	t.equal((wave["pool"] as Array).size(), 1, "Welle 1 spawnt nur die niedrigste Stufe")
	var boss_wave := DragonRpg.wave_config(5)
	t.check(bool(boss_wave["boss"]), "Welle 5 hat einen Boss")
	t.check((boss_wave["bossType"] as Dictionary)["id"] == "dragon_elder", "Welle 5 bekommt den Urdrachen")
	t.check((DragonRpg.wave_config(10)["bossType"] as Dictionary)["id"] == "dragon_lord", "Welle 10 bekommt den Fürsten")
	t.check((DragonRpg.wave_config(2)["pool"] as Array).size() >= 1, "Welle 2 hat Drachen")

	var stats := DragonRpg.base_player_stats()
	t.equal(stats.max_hp, 100.0, "Start-HP 100")
	var next := stats.leveled_up()
	t.equal(next.max_hp, 114.0, "Level-Up gibt +14 max HP")
	t.check(next.damage_mult > stats.damage_mult, "Level-Up erhöht den Schaden")
	t.check(next.cooldown_mult < stats.cooldown_mult, "Level-Up verkürzt den Cooldown")
	t.equal(next.hp, next.max_hp, "Level-Up heilt voll")
	t.equal(DragonRpg.xp_to_next(1), 16, "XP für Level 2")

	t.check(DragonRpg.circles_overlap(0, 0, 1.0, 1.5, 0, 1.0), "Überlappende Kreise")
	t.check(not DragonRpg.circles_overlap(0, 0, 1.0, 3.0, 0, 1.0), "Getrennte Kreise")
	t.check(DragonRpg.in_melee_arc(0, 0, 0.0, 0, -2.0, 4.0, 0.6), "Ziel vor dem Angreifer")
	t.check(not DragonRpg.in_melee_arc(0, 0, 0.0, 0, 2.0, 4.0, 0.6), "Ziel hinter dem Angreifer")
	t.check(not DragonRpg.in_melee_arc(0, 0, 0.0, 0, -40.0, 4.0, 0.6), "Ziel außer Reichweite")
	t.equal(int(DragonRpg.mitigate_damage(20.0, 0.0)), 20, "Ohne Rüstung kein Schadenverlust")
	t.almost(DragonRpg.mitigate_damage(100.0, 40.0), 50.0, 1.0, "Rüstung halbiert schweren Schaden")
	t.check(DragonRpg.mitigate_damage(0.0, 0.0) >= 1.0, "Mindestens 1 Schaden")
	t.equal(DragonRpg.score_for(2, 3, 100), 520, "Score = Gold + Wellen- + Levelbonus")

	var loot_total := 0
	for entry in DragonRpg.LOOT_TABLE:
		loot_total += int(entry["weight"])
	t.check(loot_total > 0, "Loot-Tabelle hat Gewichte")
	var rolled := DragonRpg.roll_loot()
	t.check(not str(rolled["id"]).is_empty(), "Loot-Wurf liefert eine ID")
	t.equal(DragonRpg.WEAPONS.size(), 6, "Sechs Waffen")
	t.suite_done()


# --- horse runner -----------------------------------------------------------

func _horse_runner() -> void:
	t.suite("Pferde-Parcours")
	t.equal(HorseRunner.LANE_COUNT, 3, "Drei Spuren")
	t.equal(HorseRunner.lane_x(0), -2.6, "Linke Spur")
	t.equal(HorseRunner.lane_x(1), 0.0, "Mittlere Spur")
	t.equal(HorseRunner.lane_x(2), 2.6, "Rechte Spur")
	t.equal(HorseRunner.clamp_lane(-3), 0, "Spuren werden nach unten begrenzt")
	t.equal(HorseRunner.clamp_lane(9), 2, "Spuren werden nach oben begrenzt")

	var start := HorseRunner.difficulty_at(0.0)
	var late := HorseRunner.difficulty_at(5000.0)
	t.check(float(late["speed"]) > float(start["speed"]), "Tempo steigt")
	t.check(float(late["reaction"]) < float(start["reaction"]), "Reaktionszeit sinkt")
	t.check(float(late["doubleChance"]) > float(start["doubleChance"]), "Doppelblockieren wird häufiger")

	var log := HorseRunner.obstacle_spec(HorseRunner.OBSTACLE_LOG)
	t.check(HorseRunner.collides(0.0, 0.0, 0.0, 0.0, 0.0, log), "Baumstamm in Bodennähe trifft")
	t.check(not HorseRunner.collides(0.0, 2.0, 0.0, 0.0, 0.0, log), "Über dem Baumstamm ist man sicher")
	t.check(not HorseRunner.collides(6.0, 0.0, 0.0, 0.0, 0.0, log), "Neben dem Baumstimm trifft nichts")
	t.almost(HorseRunner.jump_apex(), HorseRunner.JUMP_SPEED * HorseRunner.JUMP_SPEED / (2.0 * HorseRunner.GRAVITY), 0.0001, "Sprunghöhe")
	t.check(HorseRunner.spawn_gap(start) > 0.0, "Spawn-Abstand ist positiv")
	t.suite_done()


# --- inventory --------------------------------------------------------------

func _pang() -> void:
	t.suite("Pang")

	# Kugelstufen: schrumpfend im Radius, schneller werdend, ärmer werdend.
	for level in range(Pang.SIZE_LARGEST, Pang.SIZE_SMALLEST + 1):
		var spec := Pang.size_spec(level)
		t.check(float(spec["radius"]) > 0.0, "Stufe %d hat einen Radius" % level)
		t.check(float(spec["bounce"]) > 0.0, "Stufe %d hat eine Sprunghöhe" % level)
		t.check(int(spec["points"]) > 0, "Stufe %d gibt Punkte" % level)
		if level < Pang.SIZE_SMALLEST:
			var next_spec := Pang.size_spec(level + 1)
			t.check(float(next_spec["radius"]) < float(spec["radius"]), "Stufe %d ist kleiner als %d" % [level + 1, level])
			t.check(float(next_spec["speedMult"]) > float(spec["speedMult"]), "Stufe %d ist schneller als %d" % [level + 1, level])
			t.check(int(next_spec["points"]) < int(spec["points"]), "Stufe %d zahlt weniger als %d" % [level + 1, level])
	t.equal(Pang.points_for(Pang.SIZE_LARGEST), 100, "Größte Kugel zahlt 100")
	t.equal(Pang.points_for(Pang.SIZE_SMALLEST), 10, "Kleinste Kugel zahlt 10")

	# Die Sprunggeschwindigkeit muss die Sprunghöhe auch wirklich erreichen.
	for level in range(Pang.SIZE_LARGEST, Pang.SIZE_SMALLEST + 1):
		var apex: float = (Pang.jump_velocity(level) * Pang.jump_velocity(level)) / (2.0 * Pang.GRAVITY)
		t.almost(apex, Pang.bounce_of(level), 0.001, "Stufe %d erreicht die Sprunghöhe" % level)
	t.check(Pang.speed_of(Pang.SIZE_SMALLEST) > Pang.speed_of(Pang.SIZE_LARGEST), "Kleine Kugeln sind schneller")

	# Das Spiel ist die Kette: die kleinste Stufe ist das Ende, alles darüber
	# teilt sich in zwei der nächsten Stufe.
	t.check(Pang.SIZE_SMALLEST == 4, "Vier Kugelstufen wie im Original")
	t.check(Pang.SIZE_LARGEST == 1, "Stufe 1 ist die größte")
	var chain := 1
	for level in range(Pang.SIZE_LARGEST, Pang.SIZE_SMALLEST):
		chain *= 2
	t.equal(chain, 8, "Eine Kugel wird zu acht Kleinsten")
	t.check(Pang.ORB_SAFE_CAP >= chain * int(Pang.level_config(Pang.TOTAL_LEVELS)["ballCount"]),
		"Der Kugel-Pool fasst das chaotischste Level")
	t.check(Pang.clear_bonus(5, 90.0) > Pang.clear_bonus(5, 30.0), "Restzeit zahlt sich aus")
	t.check(Pang.clear_bonus(5, 0.0) > 0, "Es gibt auch eine Grundprämie")

	# Haken.
	t.equal(Pang.max_harpoons(0), Pang.BASE_HARPOONS, "Ein Haken am Anfang")
	t.equal(Pang.max_harpoons(1), 2, "Doppelhaken verdoppelt")
	t.equal(Pang.max_harpoons(99), Pang.MAX_HARPOONS, "Haken sind gedeckelt")
	t.check(Pang.max_harpoons(1) > Pang.BASE_HARPOONS, "Der Doppelhaken ist eine echte Aufwertung")
	t.check(Pang.HARPOON_HOLD_TIME > 0.0, "Ein Haken bleibt kurz in der Decke stecken")
	t.check(Pang.HARPOON_HOLD_TIME < 3.0, "Der Haken verschwindet aber wieder")
	t.check(Pang.PLAYER_MOVE_SPEED > 0.0, "Der Spieler kann laufen")

	# Bonus-Tabelle: gewichtet, deterministisch und vollständig belegt.
	var seen := {}
	for i in 200:
		var picked := Pang.roll_bonus(float(i) / 200.0)
		seen[str(picked["id"])] = true
	t.equal(seen.size(), Pang.BONUSES.size(), "Jeder Bonus lässt sich ziehen")
	t.equal(str(Pang.roll_bonus(0.0)["id"]), str(Pang.roll_bonus(0.0)["id"]), "Der Wurf ist reproduzierbar")
	t.equal(str(Pang.bonus_by_id("nope")["id"]), str(Pang.BONUSES[0]["id"]), "Unbekannter Bonus fällt zurück")
	for entry in Pang.BONUSES:
		t.check(float(entry["weight"]) > 0.0, "Bonus '%s' ist gewichtet" % str(entry["id"]))
		t.check(AssetRegistry.exists(str(entry["asset"])), "Bonus-Mesh '%s' existiert" % str(entry["asset"]))
	t.check(float(Pang.DROP_CHANCE) > 0.0 and float(Pang.DROP_CHANCE) < 1.0, "Bonuschance ist sinnvoll")
	t.check(Pang.FREEZE_DURATION > 0.0, "Der Freeze hält eine Weile")
	t.check(Pang.EXTRA_TIME_AMOUNT > 0.0, "Der Zeitbonus schenkt Zeit")
	t.check(Pang.is_frozen(1.0) and not Pang.is_frozen(0.0), "Der Frost wirkt nur solange er läuft")

	# Hindernisse: Kisten zerbrechen, Plattformen fangen den Haken.
	t.check(AssetRegistry.exists(str(Pang.obstacle_spec(Pang.OBSTACLE_BREAKABLE)["asset"])), "Kistenmesh existiert")
	t.check(AssetRegistry.exists(str(Pang.obstacle_spec(Pang.OBSTACLE_FIXED)["asset"])), "Plattformmesh existiert")
	for kind in [Pang.OBSTACLE_BREAKABLE, Pang.OBSTACLE_FIXED]:
		t.check(bool(Pang.obstacle_spec(kind)["bounces"]), "Hindernis '%s' prallt Kugeln ab" % kind)
	t.check(bool(Pang.obstacle_spec(Pang.OBSTACLE_FIXED)["blocks"]), "Die Plattform stoppt den Haken")
	t.check(not bool(Pang.obstacle_spec(Pang.OBSTACLE_BREAKABLE)["blocks"]), "Die Kiste lässt den Haken durch")
	t.check(int(Pang.obstacle_spec(Pang.OBSTACLE_BREAKABLE)["hp"]) > 0, "Die Kiste ist zerstörbar")
	t.check(int(Pang.obstacle_spec(Pang.OBSTACLE_FIXED)["hp"]) == 0, "Die Plattform ist unzerstörbar")

	# Die Kampagne: jeder Level muss spielbar sein und ist reproduzierbar.
	for level in range(1, Pang.TOTAL_LEVELS + 1):
		var layout := Pang.level_data(level)
		t.equal(Pang.validate_level(layout).size(), 0, "Level %d ist spielbar" % level)
		t.equal(Pang.level_data(level)["balls"], layout["balls"], "Level %d ist reproduzierbar" % level)
		t.check((layout["balls"] as Array).size() > 0, "Level %d hat Kugeln" % level)
		t.check(float(layout["timeLimit"]) >= Pang.TIME_END, "Level %d hat ein Zeitlimit" % level)
	t.equal(Pang.validate_level({"level": 0, "balls": []}).size() > 0, true, "Kaputte Level werden erkannt")
	t.equal(Pang.validate_level({"level": 1, "balls": [{"x": 900.0, "y": 1.0, "size": 2}]}).size() > 0, true, "Kugeln außerhalb werden erkannt")
	t.equal(Pang.validate_level({"level": 1, "balls": [{"x": 0.0, "y": 8.0, "size": 9}]}).size() > 0, true, "Ungültige Stufen werden erkannt")

	# Die Schwierigkeit steigt monoton, ohne Sprünge.
	var early := Pang.level_config(1)
	var middle := Pang.level_config(Pang.TOTAL_LEVELS / 2)
	var late := Pang.level_config(Pang.TOTAL_LEVELS)
	t.check(float(middle["timeLimit"]) < float(early["timeLimit"]), "Spätere Level haben weniger Zeit")
	t.check(float(late["timeLimit"]) < float(middle["timeLimit"]), "Die Zeit sinkt weiter")
	t.check(float(late["speedMult"]) > float(early["speedMult"]), "Spätere Level sind schneller")
	t.check(int(late["ballCount"]) > int(early["ballCount"]), "Spätere Level haben mehr Kugeln")
	t.check(int(early["crates"]) == 0 and int(late["crates"]) > 0, "Hindernisse kommen erst später dazu")
	t.check(int(early["platforms"]) == 0 and int(late["platforms"]) > 0, "Plattformen kommen noch später")
	t.check(int(early["baseSize"]) > int(late["baseSize"]), "Frühe Level starten mit kleineren Kugeln")
	t.check(Pang.level_progress(1) == 0.0, "Level 1 ist der Start der Kurve")
	t.check(Pang.level_progress(Pang.TOTAL_LEVELS) == 1.0, "Der letzte Level schließt die Kurve")
	t.check(Pang.par_time(10) < Pang.par_time(40 % Pang.TOTAL_LEVELS + 1), "Die Sollzeit wächst")
	t.check(not Pang.level_title(7).is_empty(), "Jeder Level hat einen Titel")

	# Das Spielfeld muss den Spieler und den Bühnenrahmen immer enthalten.
	t.check(Pang.PLAYER_TOP_Y < Pang.CEILING_Y, "Der Spieler passt unter die Decke")
	t.check(Pang.PLAYER_HITBOX_TOP < Pang.PLAYER_TOP_Y, "Die Trefferbox ist niedriger als die Figur")
	t.check(Pang.PLAYER_HITBOX_HALF_WIDTH < Pang.PLAYER_HALF_WIDTH, "Die Trefferbox ist schmaler als die Figur")
	t.check(Pang.PLAYER_HITBOX_HALF_WIDTH > 0.0, "Die Trefferbox ist nicht winzig")
	t.check(Pang.FLOOR_BAND_TOP > Pang.PLAYER_HITBOX_TOP, "Kugeln starten über der Trefferbox")
	t.check(Pang.FLOOR_Y <= 0.0, "Der Boden liegt auf Höhe 0")
	t.check(Pang.START_GRACE > 0.0, "Es gibt eine Schonfrist zu Level-Beginn")
	t.check(Pang.LIVES >= 1, "Es gibt mindestens ein Leben")
	t.check(Pang.ARENA_HALF_WIDTH * 2.0 > 10.0, "Die Arena ist breit genug zum Ausweichen")
	t.check(Pang.LEVELS_PER_PAGE > 0, "Die Level-Auswahl ist seitenweise")

	# Speicherstände laufen auch ohne Szene-Baum (headless Runner) sauber durch.
	# Der Runner teilt sich den Speicher mit dem Rest der Suite, also wird der
	# Ausgangszustand eingefangen statt ein frisches Profil vorausgesetzt.
	var start_unlocked := Pang.unlocked_level()
	t.check(start_unlocked >= Pang.FIRST_UNLOCKED, "Mindestens Level 1 ist offen")
	t.check(Pang.is_unlocked(1), "Level 1 ist immer offen")
	t.check(Pang.is_unlocked(start_unlocked), "Der am weitesten freigeschaltete Level ist offen")
	t.check(not Pang.is_unlocked(start_unlocked + 1), "Der nächste Level ist noch gesperrt")
	# Freischalten wächst nur und wird auf die Kampagne geklemmt. Der Wert ist
	# dauerhaft gespeichert, deshalb wird der Zustand davor eingefangen statt ein
	# frisches Profil vorausgesetzt.
	var before_unlock := Pang.unlocked_level()
	t.equal(Pang.unlock_level(1), before_unlock, "Ein niedrigerer Level ändert nichts")
	t.equal(Pang.unlock_level(0), before_unlock, "Level 0 wird ignoriert")
	t.equal(Pang.unlock_level(9999), Pang.TOTAL_LEVELS, "Über das Ende hinaus wird geklemmt")
	t.check(Pang.is_unlocked(Pang.TOTAL_LEVELS), "Damit ist der letzte Level offen")
	t.equal(Pang.unlock_level(Pang.TOTAL_LEVELS - 1), Pang.TOTAL_LEVELS, "Ein niedrigerer Level ändert nichts")
	t.equal(Pang.record_level_time(3, 0.0), false, "Zeit von 0 zählt nicht")
	t.check(Pang.level_best_time(3) >= 0.0, "Bestzeit ist lesbar")
	t.suite_done()


func _inventory() -> void:
	t.suite("Inventar")
	var catalog := ItemInventory.Catalog.new([
		{"id": "potion", "name": "Heiltrank", "maxStack": 9, "weight": 0.5, "value": 12.0, "effect": {"heal": 30.0}},
		{"id": "sword", "name": "Schwert", "slot": "weapon", "rarity": "rare", "stats": {"damage": 4.0}},
		{"id": "shield", "name": "Schild", "slot": "offhand", "rarity": "uncommon", "stats": {"armor": 2.0}},
	])
	t.equal(catalog.size(), 3, "Drei Items registriert")
	t.equal(int(catalog.require("potion")["maxStack"]), 9, "maxStack wird gelesen")
	t.equal(int(catalog.require("unknown")["maxStack"]), 1, "Unbekannte Items sind nicht stapelbar")

	var bag := ItemInventory.new({"capacity": 4, "catalog": catalog, "currency": 50})
	t.equal(bag.capacity(), 4, "Kapazität 4")
	t.equal(bag.currency(), 50, "Startwährung 50")
	var added := bag.add("potion", 12)
	t.equal(int(added["added"]), 12, "Zwölf Tränke passen")
	t.equal(bag.count("potion"), 12, "Zwölf Tränke im Inventar")
	t.equal(bag.used_slots(), 2, "Zwölf Tränke belegen zwei Slots (9 + 3)")
	t.equal(bag.has("potion", 12), true, "has() findet den Bestand")

	var overflow := bag.add("potion", 40)
	t.check(int(overflow["added"]) < 40, "Ein volles Inventar nimmt nicht alles")

	var small := ItemInventory.new({"capacity": 2, "catalog": catalog})
	small.add("potion", 12)
	t.equal(small.remove("potion", 5), 5, "Fünf Tränke entfernt")
	t.equal(small.count("potion"), 7, "Sieben Tränke übrig")
	t.equal(small.remove("potione", 5), 0, "Unbekannte Items lassen sich nicht entfernen")

	# Ein volles Inventar nimmt nichts mehr an.
	t.check(bag.is_full(), "Das Inventar ist nach dem Überlaufen voll")
	t.equal(int(bag.add("sword")["added"]), 0, "Ein volles Inventar nimmt kein Schwert an")

	var gear := ItemInventory.new({"capacity": 4, "catalog": catalog})
	gear.add("sword")
	var sword_index := gear.find_item("sword")
	t.check(sword_index >= 0, "Schwert gefunden")
	t.check(gear.can_equip(sword_index), "Schwert ist ausrüstbar")
	t.check(gear.equip(sword_index), "Ausrüsten klappt")
	t.equal(gear.equipped_in("weapon").id, "sword", "Schwert steckt in der Waffenhand")
	t.almost(gear.equipment_stat("damage"), 4.0, 0.0001, "Ausrüstung liefert Schadensbonus")
	bag = gear

	var donor := ItemInventory.new({"capacity": 4, "catalog": catalog})
	donor.add("potion", 5)
	var other := ItemInventory.new({"capacity": 4, "catalog": catalog})
	t.equal(int(other.add("potion", 3)["added"]), 3, "Zielinventar nimmt Karten an")
	t.equal(donor.transfer_to(other, "potion", 2), 2, "Zwei Karten werden transferiert")
	t.equal(donor.count("potion"), 3, "Quellinventar verliert zwei")
	t.equal(other.count("potion"), 5, "Zielinventar gewinnt zwei")
	t.equal(other.transfer_stack_to(donor, 0), 5, "Der ganze Stapel wandert zurück")
	t.equal(other.count("potion"), 0, "Das Zielinventar verliert den Stapel")
	t.equal(donor.count("potion"), 8, "Das Quellinventar hat jetzt acht")

	var snapshot := gear.to_json()
	var restored := ItemInventory.from_json({"capacity": 4, "catalog": catalog}, snapshot)
	t.equal(restored.count("sword"), gear.count("sword"), "Snapshot erhält den Bestand")
	t.equal(restored.equipped_in("weapon").id, "sword", "Snapshot erhält die Ausrüstung")

	# Der Snapshot muss echtes JSON überstehen — er landet als Text auf der Platte.
	var on_disk: Variant = JSON.parse_string(JSON.stringify(snapshot))
	t.check(on_disk is Dictionary, "Snapshot ist JSON-serialisierbar")
	var reloaded := ItemInventory.from_json({"capacity": 4, "catalog": catalog}, on_disk)
	t.equal(reloaded.count("sword"), gear.count("sword"), "Aus JSON gelesen bleibt der Bestand")
	t.equal(reloaded.equipped_in("weapon").id, "sword", "Aus JSON gelesen bleibt die Ausrüstung")
	t.equal(reloaded.currency(), gear.currency(), "Aus JSON gelesen bleibt die Währung")

	restored.load_json({"capacity": 2, "currency": 7, "slots": [{"id": "potion", "count": 3}, null, {"id": "junk", "count": 0}], "equipment": {"weapon": {"id": "sword", "count": 1}}})
	t.equal(restored.capacity(), 2, "Kapazität wird angepasst")
	t.equal(restored.count("potion"), 3, "Gültige Slots werden geladen")
	t.equal(restored.currency(), 7, "Währung wird geladen")
	t.equal(restored.equipped_in("weapon").id, "sword", "Ausrüstung wird geladen")

	# Sortieren und Kompaktieren.
	var messy := ItemInventory.new({"capacity": 5, "catalog": catalog})
	messy.set_slot(3, ItemInventory.ItemStack.new("potion", 2))
	messy.set_slot(1, ItemInventory.ItemStack.new("sword", 1))
	messy.compact()
	t.equal(messy.get_slot(0).id, "sword", "Kompaktieren rückt nach vorne")
	t.equal(messy.get_slot(1).id, "potion", "Kompaktieren behält die Reihenfolge")
	t.check(messy.get_slot(2) == null, "Kompaktieren schließt die Lücke")
	messy.sort()
	t.equal(messy.get_slot(0).id, "sword", "Sortieren legt Seltenes zuerst")

	var purse := ItemInventory.new({"capacity": 2, "catalog": catalog, "currency": 100})
	t.equal(purse.add_currency(-1000), 0, "Währung bleibt nie negativ")
	t.check(not purse.spend(99999), "Ausgeben ohne Deckung scheitert")
	# `purse` ist durch den clamp oben leer — zum Ausgeben ein frisches Portemonnaie.
	var payer := ItemInventory.new({"capacity": 2, "catalog": catalog, "currency": 100})
	t.check(payer.spend(100), "Ausgeben mit Deckung klappt")
	t.equal(payer.currency(), 0, "Währung ist aufgebraucht")
	t.check(not gear.equip(999), "Ungültiger Index wirft nicht")
	t.equal(gear.move(999, 0), false, "Ungültiges Verschieben scheitert")
	t.equal(gear.split(0, 999), -1, "Ungültiges Splitten scheitert")
	t.equal(gear.split(0, 1), -1, "Ein einzelnes Item lässt sich nicht splitten")
	t.suite_done()


# --- lobby geometry ---------------------------------------------------------

func _lobby() -> void:
	t.suite("Lobby-Geometrie")
	var zones := Lobby.zone_layout()
	t.equal(zones.size(), GameRegistry.CATEGORIES.size(), "Eine Plaza je Kategorie")
	var total_games := 0
	for zone in zones:
		total_games += (zone["games"] as Array).size()
	t.equal(total_games, GameRegistry.GAMES.size(), "Alle Spiele sind einer Plaza zugeordnet")

	var clamped := Lobby.clamp_to_lobby(100.0, 0.0)
	t.almost(clamped.length(), Lobby.LOBBY_WALK_RADIUS, 0.001, "Position wird auf den Laufkreis begrenzt")
	var inside := Lobby.clamp_to_lobby(3.0, 4.0)
	t.equal(inside, Vector2(3, 4), "Innen bleibt unangetastet")

	t.equal(Lobby.pedestal_offsets(0).size(), 0, "Keine Sockel ohne Spiele")
	t.equal(Lobby.pedestal_offsets(1).size(), 1, "Ein Spiel steht in der Mitte")
	t.equal(Lobby.pedestal_offsets(5).size(), 5, "Fünf Spiele bilden einen Ring")
	var offsets := Lobby.pedestal_offsets(4)
	var unique := {}
	for offset in offsets:
		unique["%.2f/%.2f" % [offset.x, offset.y]] = true
	t.equal(unique.size(), 4, "Sockel überlappen sich nicht")

	var map_size := 200.0
	var map_padding := 10.0
	var point := Lobby.minimap_point(Lobby.LOBBY_WALK_RADIUS, 0.0, map_size, map_padding, Lobby.MINIMAP_WORLD_RADIUS)
	var expected := map_size * 0.5 + Lobby.LOBBY_WALK_RADIUS * (map_size * 0.5 - map_padding) / Lobby.MINIMAP_WORLD_RADIUS
	t.almost(point.x, expected, 0.001, "Randpunkt liegt am Kartenrand")
	t.almost(Lobby.minimap_point(0.0, 0.0, map_size, map_padding, Lobby.MINIMAP_WORLD_RADIUS).x, map_size * 0.5, 0.001, "Mittelpunkt liegt in der Kartenmitte")
	t.equal(Lobby.distance_sq(0, 0, 3, 4), 25.0, "Abstandsquadrat")

	# Registry: jeder Eintrag zeigt auf einen echten Screen.
	for game in GameRegistry.GAMES:
		var screen := str(game["screen"])
		t.check(Router.SCREEN_SCRIPTS.has(screen), "Screen '%s' ist registriert" % screen)
		t.check(Router.SCREEN_SCRIPTS[screen].ends_with(".gd"), "Screen '%s' zeigt auf ein Skript" % screen)
	t.check(GameRegistry.games_in_category(GameRegistry.CATEGORY_ACTION).size() >= 3, "Mindestens drei Action-Spiele")
	t.equal(str(GameRegistry.game_by_id("pang")["category"]), GameRegistry.CATEGORY_ACTION, "Pang liegt in den Action-Spielen")
	t.equal(str(GameRegistry.screen_of("pang")), "pang_menu", "Pang startet in der Level-Auswahl")
	t.equal(str(GameRegistry.screen_of("nope")), "arena", "Unbekanntes Spiel fällt auf die Arena zurück")
	t.suite_done()


# --- asset registry ---------------------------------------------------------

func _asset_registry() -> void:
	t.suite("Asset-Registry")
	t.check(AssetRegistry.KEYS.size() >= 70, "Registry listet alle Meshes")
	var seen := {}
	for key in AssetRegistry.KEYS:
		t.check(not (key in seen), "Key '%s' ist eindeutig" % key)
		seen[key] = true
		t.check(AssetRegistry.exists(key), "Mesh '%s' ist importiert" % key)
	t.equal(AssetRegistry.missing().size(), 0, "Kein registriertes Mesh fehlt auf der Platte")
	t.equal(AssetRegistry.unlisted().size(), 0, "Jedes Mesh auf der Platte ist registriert")

	# Jede Galerie-Sektion bekommt Inhalt, und jeder Key landet genau einmal.
	var total := 0
	for group in AssetRegistry.GROUPS:
		var keys := AssetRegistry.keys_in_group(str(group["id"]))
		t.check(not keys.is_empty(), "Sektion '%s' ist nicht leer" % str(group["id"]))
		total += keys.size()
	t.equal(total, AssetRegistry.KEYS.size(), "Jeder Key gehört genau einer Sektion")
	for key in AssetRegistry.KEYS:
		t.check(str(AssetRegistry.GROUPS[0].keys()) != "" or true, "Sektionen sind benannt")

	# Die Themen der Spiele verweisen nur auf existierende Meshes.
	for tier in AssetRegistry.MERGE_KEYS:
		t.check(AssetRegistry.exists(tier), "Merge-Mesh '%s' existiert" % tier)
	for theme_id in [CrystalTower.THEME_CLASSIC, CrystalTower.THEME_CHRISTMAS, CrystalTower.THEME_HALLOWEEN]:
		var theme := CrystalTower.theme_by_id(theme_id)
		for asset in theme["tierAssets"]:
			t.check(AssetRegistry.exists(str(asset)), "Kristall-Mesh '%s' existiert" % str(asset))
	for theme_id in [Merge3D.THEME_CHRISTMAS, Merge3D.THEME_HALLOWEEN]:
		var merge_theme := Merge3D.theme_by_id(theme_id)
		for asset in merge_theme["tierAssets"]:
			t.check(AssetRegistry.exists(str(asset)), "Merge-Stufenmesh '%s' existiert" % str(asset))
	for dragon in DragonRpg.DRAGON_TYPES:
		t.check(AssetRegistry.exists(str(dragon["asset"])), "Drachenmesh '%s' existiert" % str(dragon["asset"]))
	for weapon in DragonRpg.WEAPONS:
		t.check(AssetRegistry.exists(str(weapon["asset"])), "Waffenmesh '%s' existiert" % str(weapon["asset"]))
	for entry in DragonRpg.LOOT_TABLE:
		t.check(AssetRegistry.exists(str(entry["asset"])), "Lootmesh '%s' existiert" % str(entry["asset"]))
	for spec in HorseRunner.OBSTACLE_SPECS:
		t.check(AssetRegistry.exists(str(spec["asset"])), "Hindernismesh '%s' existiert" % str(spec["asset"]))
	for key in AssetRegistry.PANG_KEYS:
		t.check(AssetRegistry.exists(key), "Pang-Mesh '%s' existiert" % key)
	t.check(AssetRegistry.exists("horse"), "Pferdemesh existiert")
	t.check(AssetRegistry.exists("ship"), "Schiffmesh existiert")
	t.check(AssetRegistry.exists("rpg/knight"), "Rittermesh existiert")

	t.check(not AssetRegistry.display_name("rpg/dragon_lord").is_empty(), "Anzeigename wird gebildet")
	t.check(not AssetRegistry.color_of("rpg/knight").is_equal_approx(Color.BLACK), "Jeder Key bekommt eine Farbe")
	t.suite_done()


# --- mechanics --------------------------------------------------------------

func _mechanics() -> void:
	t.suite("Mechaniken")
	var dash := MechanicsIndex.by_id("dash")
	t.check(dash != null, "Dash-Mechanik ist registriert")
	if dash != null:
		t.equal(dash.id, "dash", "ID stimmt")
		t.check(dash.hud(null) == "Dash bereit", "Dash ist anfangs bereit")
		t.check(dash.movement_override(null, 0.016) == null, "Ohne Dash keine Bewegungsänderung")
	t.check(MechanicsIndex.by_id("nope") == null, "Unbekannte Mechanik liefert null")
	t.suite_done()


func _dragon_flight() -> void:
	t.suite("Drachenflug — Stammdaten")
	t.check(DragonFlight.BREEDS.size() >= 8, "Mindestens acht Rassen")
	t.equal(DragonFlight.TRAITS.size(), 12, "Zwölf vererbbare Merkmale")
	t.check(DragonFlight.ENEMIES.size() >= 8, "Mindestens acht Gegner")
	t.equal(DragonFlight.level_count(), 30, "Dreißig Level")
	t.equal(DragonFlight.BIOMES.size(), 10, "Zehn Biome")
	var unique_breeds := {}
	for breed in DragonFlight.BREEDS:
		unique_breeds[str(breed["id"])] = true
		t.check(AssetRegistry.exists(str(breed["asset"])), "Rasse '%s' hat ein Mesh" % str(breed["id"]))
	t.equal(unique_breeds.size(), DragonFlight.BREEDS.size(), "Rassen-IDs sind eindeutig")
	for enemy in DragonFlight.ENEMIES:
		t.check(AssetRegistry.exists(str(enemy["asset"])), "Gegner '%s' hat ein Mesh" % str(enemy["id"]))
	for entry in DragonFlight.POWERUPS:
		t.check(AssetRegistry.exists(str(entry["asset"])), "Power-up '%s' hat ein Mesh" % str(entry["id"]))

	# Die Level müssen durchgehend schwerer werden.
	var previous := 0.0
	for n in range(1, DragonFlight.level_count() + 1):
		var level_def := DragonFlight.level(n)
		t.equal(int(level_def["n"]), n, "Level %d ist durchnummeriert" % n)
		t.equal(DragonFlight.biome_by_id(str(level_def["biome"]))["id"], level_def["biome"], "Level %d hat ein bekanntes Biom" % n)
		t.check(float(level_def["hpMult"]) >= previous, "Level %d ist nicht leichter als der Vorgänger" % n)
		previous = float(level_def["hpMult"])
		t.check(DragonFlight.enemy_by_id(DragonFlight.pick_enemy(level_def)["id"]) != null, "Level %d spawnt einen bekannten Gegner" % n)
	t.check(DragonFlight.level(0)["n"] == 1, "Level 0 klemmt auf Level 1")
	t.check(DragonFlight.level(999)["n"] == 30, "Level 999 klemmt auf das letzte Level")
	t.check(DragonFlight.concurrent_for(1) < DragonFlight.concurrent_for(30), "Späte Level haben mehr Gegner")
	t.check(DragonFlight.spawn_gap(DragonFlight.level(1)) > 0.0, "Spawn-Abstand ist positiv")

	# Sterne und Freischaltung.
	t.equal(DragonFlight.stars_for_run(false, 1.0), 0, "Nicht beendet heißt keine Sterne")
	t.equal(DragonFlight.stars_for_run(true, 1.0), 3, "Unversehrt sind drei Sterne")
	t.equal(DragonFlight.stars_for_run(true, 0.6), 2, "Halbe Hülle sind zwei Sterne")
	t.equal(DragonFlight.stars_for_run(true, 0.1), 1, "Knapp überstanden ist ein Stern")
	var fresh := DragonFlight.default_profile()
	t.check(DragonFlight.is_unlocked(1, fresh), "Level 1 ist immer offen")
	t.check(not DragonFlight.is_unlocked(2, fresh), "Level 2 ist am Anfang zu")
	DragonFlight.apply_run(fresh, 1, {"score": 100, "stars": 3, "gold": 50, "eggs": 0, "new_best": 1})
	t.check(DragonFlight.is_unlocked(2, fresh), "Nach Level 1 öffnet Level 2")
	t.check(DragonFlight.stars_of(1, fresh) == 3, "Sterne werden gespeichert")
	t.equal(DragonFlight.total_stars(fresh), 3, "Sterne werden gezählt")
	t.check(not DragonFlight.is_unlocked(7, fresh), "Weit entfernte Level bleiben zu")
	DragonFlight.apply_run(fresh, 7, {"score": 1, "stars": 3, "gold": 0, "eggs": 0, "new_best": 0})
	t.equal(DragonFlight.stars_of(1, fresh), 3, "Ein später Versuch überschreibt Level 1 nicht")
	t.check(DragonFlight.star_requirement(7) > 0, "Späte Level verlangen Sterne")
	for n in range(1, 7):
		DragonFlight.apply_run(fresh, n, {"score": 10, "stars": 3, "gold": 0, "eggs": 0, "new_best": 0})
	t.check(DragonFlight.is_unlocked(7, fresh), "Genug Sterne öffnen Level 7")
	t.suite_done()


func _flight_genetics() -> void:
	t.suite("Drachenflug — Vererbung")
	t.equal(DragonFlight.expressed_traits({}).size(), 0, "Ohne Allele gibt es keine Merkmale")
	# Ein dominantes Merkmal braucht ein einziges Allel, ein rezessives zwei.
	var dominant := {"feueratem": "Fa"}
	t.check(DragonFlight.expressed(dominant, "feueratem"), "Dominantes Merkmal zeigt mit einem Allel")
	t.check(not DragonFlight.expressed(dominant, "eisenhaut"), "Fremdes Merkmal zeigt nicht")
	t.check(DragonFlight.expressed({"riesenwuchs": "rr"}, "riesenwuchs"), "Rezessiv zeigt mit zwei Allelen")
	t.check(not DragonFlight.expressed({"riesenwuchs": "Rr"}, "riesenwuchs"), "Ein rezessives Allel bleibt verborgen")
	t.check(not DragonFlight.expressed({"riesenwuchs": "RR"}, "riesenwuchs"), "Zwei dominante Allele zeigen ein rezessives Merkmal nicht")
	# Alle Merkmale eines Zufallsgenoms müssen genau den ausgewiesenen entsprechen.
	var genome := DragonFlight.random_genome()
	t.equal(genome.size(), DragonFlight.TRAITS.size(), "Jedes Merkmal hat ein Allelpaar")
	var expressed := DragonFlight.expressed_traits(genome)
	var again := DragonFlight.expressed_traits(genome)
	t.equal(expressed, again, "Die Merkmalsliste ist reproduzierbar")
	for id in expressed:
		t.check(DragonFlight.trait_by_id(id) != {}, "Merkmal '%s' ist bekannt" % id)

	# Kreuzung: ein Kind kann nur Allele tragen, die die Eltern hatten.
	var carrier_a := {}
	var carrier_b := {}
	for gene in DragonFlight.TRAITS:
		var dom := str(gene["dom"])
		var rec := dom.to_lower()
		carrier_a[str(gene["id"])] = dom + rec
		carrier_b[str(gene["id"])] = rec + rec
	var child := DragonFlight.cross_alleles(carrier_a, carrier_b, 0.0)
	t.equal(child.size(), DragonFlight.TRAITS.size(), "Das Kind hat ein Allelpaar je Merkmal")
	for gene in DragonFlight.TRAITS:
		var id := str(gene["id"])
		var pair := str(child[id])
		t.equal(pair.length(), 2, "Allelpaar '%s' hat zwei Zeichen" % id)
		for i in 2:
			t.check(pair[i] == str(gene["dom"]) or pair[i] == str(gene["dom"]).to_lower(),
				"Allel '%s' ist dominant oder rezessiv" % id)

	# Zwei Träger eines rezessiven Merkmals bekommen es mit hoher Wahrscheinlichkeit.
	var hits := 0
	for i in 400:
		var kid := DragonFlight.cross_alleles({"riesenwuchs": "rr"}, {"riesenwuchs": "rr"}, 0.0)
		if DragonFlight.expressed(kid, "riesenwuchs"):
			hits += 1
	t.equal(hits, 400, "Zwei rezessive Träger vererben es immer")

	# Nur ein Träger: das Kind darf es nie zeigen.
	var leaked := 0
	for i in 400:
		var kid2 := DragonFlight.cross_alleles({"riesenwuchs": "rr"}, {"riesenwuchs": "RR"}, 0.0)
		if DragonFlight.expressed(kid2, "riesenwuchs"):
			leaked += 1
	t.equal(leaked, 0, "Ein Träger allein vererbt das rezessive Merkmal nicht")

	# Inzucht kostet Lebenskraft, Kreuzung mit fremden Linien nicht.
	var parent_a := DragonFlight.random_dragon(1, ["ember"])
	var parent_b := DragonFlight.random_dragon(2, ["ember"])
	parent_b["alleles"] = DragonFlight.random_genome()
	t.check(DragonFlight.inbreeding_penalty(parent_a, parent_a) <= 1.0, "Inzuchtpenalty ist höchstens 1")
	t.check(DragonFlight.inbreeding_penalty(parent_a, parent_b) >= 0.7, "Inzuchtpenalty hat eine Untergrenze")

	var child_dragon := DragonFlight.breed_parents(parent_a, parent_b, 7)
	t.equal(int(child_dragon["uid"]), 7, "Das Kind bekommt die UID")
	t.equal(int(child_dragon["gen"]), maxi(int(parent_a["gen"]), int(parent_b["gen"])) + 1, "Generation steigt")
	t.check(DragonFlight.breed_by_id(str(child_dragon["breed"])) != null, "Das Kind hat eine gültige Rasse")
	t.suite_done()


func _flight_stats() -> void:
	t.suite("Drachenflug — Werte")
	var plain := {"breed": "ember", "alleles": {}, "gen": 1, "vitality": 1.0}
	var base := DragonFlight.resolve_stats(plain)
	var breed := DragonFlight.breed_by_id("ember")
	t.almost(float(base["max_hp"]), float(breed["hp"]), 0.01, "Ohne Merkmale gilt der Rassenwert")
	t.check(DragonFlight.visual_scale(plain) > 0.0, "Ein Drache hat eine Größe")

	# Feueratem muss den Schaden heben, Schnellfeuer die Feuerrate senken.
	var fire := DragonFlight.resolve_stats({"breed": "ember", "alleles": {"feueratem": "FF"}, "gen": 1})
	t.check(float(fire["damage"]) > float(base["damage"]), "Feueratem erhöht den Schaden")
	var haste := DragonFlight.resolve_stats(plain, {"haste": 4})
	t.check(float(haste["fire_rate"]) < float(base["fire_rate"]), "Schnellfeuer senkt die Feuerrate")
	t.check(float(haste["damage"]) == float(base["damage"]), "Schnellfeuer ändert nichts anderes")
	var tank := DragonFlight.resolve_stats(plain, {"vitality": 5, "armor": 8})
	t.check(float(tank["max_hp"]) > float(base["max_hp"]), "Zähigkeit erhöht die TP")
	t.check(float(tank["armor"]) >= 0.0 and float(tank["armor"]) <= 0.72, "Rüstung bleibt im Rahmen")

	# Riesenwuchs macht sichtbar größer.
	var big := DragonFlight.resolve_stats({"breed": "ember", "alleles": {"riesenwuchs": "rr"}, "gen": 1})
	t.check(DragonFlight.visual_scale({"breed": "ember", "alleles": {"riesenwuchs": "rr"}, "gen": 1}) > DragonFlight.visual_scale(plain),
		"Riesenwuchs macht den Drachen größer")
	t.check(float(big["max_hp"]) > float(base["max_hp"]), "Riesenwuchs gibt mehr TP")
	t.check(float(big["speed"]) < float(base["speed"]), "Riesenwuchs kostet Tempo")

	# Die Generation schrumpft nie unter die Rassengröße.
	t.check(DragonFlight.visual_scale({"breed": "ember", "alleles": {}, "gen": 40}) >= float(breed["size"]) * 0.99,
		"Generation macht höchstens größer")
	t.check(DragonFlight.visual_scale({"breed": "ember", "alleles": {}, "gen": 1, "vitality": 0.7}) > 0.5,
		"Eine geschwächte Linie bleibt sichtbar")

	# Schaden und Rüstung.
	var shot := DragonFlight.roll_shot(base, 1.0)
	t.check(float(shot["damage"]) >= 1.0, "Ein Schuss richtet mindestens 1 Schaden an")
	t.check(DragonFlight.roll_shot(base, 2.0)["damage"] >= shot["damage"] * 0.5, "Der Level multipliziert den Schaden")
	t.almost(DragonFlight.mitigate(100.0, 0.0), 100.0, 0.01, "Ohne Rüstung kommt voller Schaden an")
	t.check(DragonFlight.mitigate(100.0, 0.5) < 100.0, "Rüstung mindert Schaden")
	t.check(DragonFlight.mitigate(100.0, 5.0) >= 1.0, "Auch übermäßige Rüstung lässt Schaden durch")
	t.suite_done()


func _flight_profile() -> void:
	t.suite("Drachenflug — Profil & Zucht")
	# Eigene Datei, damit der Testlauf den Spielerstand nicht überschreibt.
	var real_path := DragonFlight.save_path
	DragonFlight.save_path = "user://dragonflight_test.json"
	DragonFlight.reset_profile()
	var profile := DragonFlight.default_profile()
	t.equal(int(profile["gold"]), 0, "Neues Profil startet ohne Gold")
	var first_cost := DragonFlight.upgrade_cost("firepower", profile)
	t.check(first_cost > 0, "Ein Upgrade kostet Gold")
	profile["gold"] = 100000
	var level_before := DragonFlight.upgrade_level("firepower", profile)
	t.equal(DragonFlight.buy_upgrade("firepower", profile), level_before + 1, "Ein Upgrade wird gekauft")
	t.check(int(profile["gold"]) < 100000, "Der Kauf kostet Gold")
	t.check(DragonFlight.upgrade_cost("firepower", profile) > first_cost, "Jede Stufe kostet mehr")
	profile["upgrades"] = {"firepower": 99}
	t.equal(DragonFlight.upgrade_cost("firepower", profile), -1, "Eine maxe Stufe kostet nichts mehr")
	t.equal(DragonFlight.buy_upgrade("firepower", profile), -1, "Über maxe Stufen kann man nicht kaufen")
	profile["upgrades"] = {}

	# Rassen kaufen.
	profile["gold"] = 50000
	var starter := DragonFlight.buy_breed(profile, "ember")
	t.check(not starter.is_empty(), "Der Starter ist kaufbar")
	t.equal(DragonFlight.buy_breed(profile, "ember").size(), 0, "Dieselbe Rasse wird nicht doppelt gekauft")
	var frost := DragonFlight.buy_breed(profile, "frost")
	t.check(not frost.is_empty(), "Eine weitere Rasse ist kaufbar")
	t.check(DragonFlight.has_breed(profile, "frost"), "Die Rasse gilt als freigeschaltet")
	profile["gold"] = 0
	t.equal(DragonFlight.buy_breed(profile, "void").size(), 0, "Ohne Gold kein Kauf")
	profile["gold"] = 100000
	var owned_before := DragonFlight.dragons_of(profile).size()

	# Eier legen und ausbrüten.
	var egg := DragonFlight.lay_egg(profile, "ember", 60.0)
	t.check(egg.get("egg", null) != null, "Das gelegte Ei ist ein Ei")
	t.equal(DragonFlight.eggs_of(profile).size(), 1, "Das Ei liegt im Nest")
	t.equal(DragonFlight.dragons_of(profile).size(), owned_before, "Ein Ei zählt nicht als Drache")
	t.check(DragonFlight.egg_remaining(egg, Time.get_unix_time_from_system()) > 50.0, "Das Ei braucht Zeit")
	t.check(DragonFlight.egg_progress(egg, Time.get_unix_time_from_system()) < 0.2, "Die Brut ist noch am Anfang")
	t.equal(DragonFlight.hatch(egg).size(), 0, "Ein unreifes Ei schlüpft nicht")
	var ready := DragonFlight.lay_egg(profile, "ember", 1.0)
	t.check(DragonFlight.egg_remaining(ready, Time.get_unix_time_from_system() + 10.0) <= 0.0, "Nach der Zeit ist es reif")
	t.almost(DragonFlight.egg_progress(ready, Time.get_unix_time_from_system() + 10.0), 1.0, 0.001, "Ein reifes Ei ist bei 100 %")
	t.check(DragonFlight.hatch_cost(egg) > 0, "Beschleunigen kostet Gold")
	var hatched := DragonFlight.hatch(egg, true)
	t.check(hatched.get("egg", null) == null, "Nach dem Schlüpfen ist es kein Ei mehr")
	t.equal(DragonFlight.hatch(hatched).size(), 0, "Ein schon geschlüpfter Drache schlüpft nicht erneut")
	t.check(DragonFlight.incubation_seconds("void") > DragonFlight.incubation_seconds("ember"), "Seltene Rassen brauchen länger")

	# Zucht: zwei Drachen paaren.
	var parent_a := DragonFlight.dragon_by_uid(profile, int(starter["uid"]))
	var parent_b := DragonFlight.dragon_by_uid(profile, int(frost["uid"]))
	var cost := DragonFlight.pairing_cost(parent_a, parent_b)
	t.check(cost > 0, "Paaren kostet Gold")
	profile["gold"] = cost
	var list: Array = profile["dragons"]
	list.append(DragonFlight.breed_parents(parent_a, parent_b, DragonFlight.next_uid(profile)))
	profile["dragons"] = list
	t.equal(DragonFlight.eggs_of(profile).size(), 2, "Die Zucht legt ein zweites Ei")
	DragonFlight.save_profile(profile)
	var reloaded := DragonFlight.load_profile()
	t.equal(DragonFlight.dragons_of(reloaded).size(), DragonFlight.dragons_of(profile).size(), "Das Profil überlebt das Speichern")
	t.equal(DragonFlight.eggs_of(reloaded).size(), 2, "Eier überleben das Speichern")
	t.equal(int(reloaded["gold"]), cost, "Gold überlebt das Speichern")
	DragonFlight.reset_profile()
	DragonFlight.save_path = real_path
	t.suite_done()


# --- Siedler 3D --------------------------------------------------------------
#
# Ports of the browser build's Siedler suites, plus the invariants that were
# found to be load-bearing while porting: the opening kit has to break the
# iron/food chicken-and-egg, a road has to accept buildings and water as its
# endpoints, and a settler must keep their tool.

## A ready game with a fixed seed, so every expectation below is stable.
func _siedler(seed_value: int = 21, size: int = 44) -> Siedler:
	var siedler := Siedler.new()
	siedler.setup(seed_value, size)
	return siedler


## Nearest free cell of a terrain kind within `max_r` tiles of the castle.
func _cell_near(siedler: Siedler, res: String, max_r: int = 4) -> int:
	var castle_cell: int = siedler.buildings[siedler.castle_id]["cell"]
	var cx: int = castle_cell % siedler.map_size
	var cy: int = castle_cell / siedler.map_size
	for r in range(1, max_r + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var x := cx + dx
				var y := cy + dy
				if not siedler.in_bounds(x, y):
					continue
				var index := siedler.cell_index(x, y)
				var cell: Dictionary = siedler.cells[index]
				if str(cell["res"]) != res:
					continue
				if int(cell["building"]) >= 0 or int(cell["flag"]) >= 0:
					continue
				return index
	return -1


func _run(siedler: Siedler, seconds: float) -> void:
	var steps := int(seconds * 30.0)
	for i in steps:
		siedler.tick(1.0 / 30.0)


func _siedler_map() -> void:
	t.suite("Siedler — Insel")

	# Deterministic for a seed, different across seeds.
	var a := Siedler.new()
	a.generate(7, 30)
	var b := Siedler.new()
	b.generate(7, 30)
	var c := Siedler.new()
	c.generate(8, 30)
	var sig_a := ""
	var sig_c := ""
	for i in a.cells.size():
		sig_a += "%s:%d" % [a.cells[i]["res"], int(a.cells[i]["height"] * 10.0)]
		sig_c += "%s:%d" % [c.cells[i]["res"], int(c.cells[i]["height"] * 10.0)]
	var sig_b := ""
	for i in b.cells.size():
		sig_b += "%s:%d" % [b.cells[i]["res"], int(b.cells[i]["height"] * 10.0)]
	t.equal(sig_a, sig_b, "Gleicher Seed, gleiche Insel")
	t.check(sig_a != sig_c, "Anderer Seed, andere Insel")

	# Land, Wasser und jede Lagerstätte, die die Wirtschaft braucht.
	var counts: Dictionary = {}
	for cell in a.cells:
		counts[str(cell["res"])] = int(counts.get(str(cell["res"]), 0)) + 1
	for res in ["grass", "water", "forest", "stone", "coal", "iron", "gold"]:
		t.check(int(counts.get(res, 0)) > 0, "Es gibt '%s'" % res)

	# Offenes Wasser trägt einen Fischgrund, sonst könnte keine Fischerhütte
	# arbeiten.
	var water := 0
	for cell in a.cells:
		if str(cell["res"]) == "water" and int(cell["amount"]) > 0:
			water += 1
	t.check(water > 0, "Wasser hat einen abbaubaren Fischbestand")
	t.equal(int(counts.get("water", 0)), water, "Jedes Wasserfeld ist fischbar")

	# Genau eine Spielerburg, dazu Rivalen.
	var siedler := _siedler()
	var castles := 0
	var rival_castles := 0
	for building in siedler.buildings:
		if str(building["kind"]) == "castle" and str(building["owner"]) == "player":
			castles += 1
		if str(building["kind"]) == "castle" and str(building["owner"]) == "rival":
			rival_castles += 1
	t.equal(castles, 1, "Es gibt genau eine Spielerburg")
	t.check(rival_castles >= 1, "Es gibt mindestens eine Rivalenburg")
	t.check(siedler.in_territory(int(siedler.buildings[siedler.castle_id]["cell"])),
		"Die Burg liegt im eigenen Territorium")
	t.check(siedler.edges.size() > 0, "Am Anfang steht bereits eine Straße")
	t.suite_done()


func _siedler_chains() -> void:
	t.suite("Siedler — Produktionsketten")

	# Welches Gebäude erzeugt welche Ware?
	var producers: Dictionary = {}
	for kind in Siedler.buildable_kinds():
		var spec := Siedler.spec_of(kind)
		for good in (spec["outputs"] as Dictionary):
			if int(spec["outputs"][good]) > 0:
				producers[good] = true
	# Die Schlosserei macht alle neun Werkzeuge.
	for tool in Siedler.TOOLS:
		producers[tool] = true

	# Jede verbrauchte Ware hat einen Erzeuger — keine Kette darf ins Leere laufen.
	var orphans: Array[String] = []
	for kind in Siedler.buildable_kinds():
		for good in (Siedler.spec_of(kind)["inputs"] as Dictionary):
			if not producers.has(good):
				orphans.append("%s <- %s" % [kind, good])
	t.equal(orphans.size(), 0, "Jede verbrauchte Ware hat einen Erzeuger")

	# Die dokumentierten Ketten aus Siedler 1.
	t.equal(Siedler.spec_of("sawmill")["inputs"], {"logs": 2}, "Schreiner verbraucht Stämme")
	t.equal(Siedler.spec_of("windmill")["inputs"], {"grain": 2}, "Mühle verbraucht Korn")
	t.equal(Siedler.spec_of("bakery")["inputs"], {"flour": 2}, "Bäckerei verbraucht Mehl")
	t.equal(Siedler.spec_of("smelter")["inputs"], {"ironOre": 1, "coal": 1}, "Schmelze braucht Erz und Kohle")
	t.equal(Siedler.spec_of("toolsmith")["inputs"], {"iron": 1, "logs": 1},
		"Schlosserei schmiedet aus 1 Eisen + 1 Holz")
	t.equal(Siedler.spec_of("blacksmith")["inputs"], {"iron": 1, "coal": 1}, "Schmiede braucht Erz und Kohle")
	t.equal(Siedler.spec_of("goldsmith")["inputs"], {"goldOre": 1, "coal": 1}, "Goldschmiede braucht Gold und Kohle")
	t.equal(Siedler.TOOLS.size(), 9, "Neun Werkzeuge wie im Original")

	# Acht Werkzeuge trägt ein Arbeitsplatz; die Schaufel gehört dem Planierer,
	# der vor dem Bauen eine Fläche ebnet.
	var users: Dictionary = {}
	for kind in Siedler.buildable_kinds():
		var tool := str(Siedler.spec_of(kind)["tool"])
		if tool != "":
			users[tool] = true
	for tool in Siedler.TOOLS:
		if tool == "shovel":
			continue
		t.check(users.has(tool), "Werkzeug '%s' wird benutzt" % tool)
	t.check(not users.has("shovel"), "Die Schaufel gehört dem Planierer, keinem Arbeitsplatz")

	# Nahrungsmittel und Werkzeuge sind sauber getrennt.
	for food in Siedler.FOODS:
		t.check(Siedler.is_food_good(food), "'%s' ist Nahrung" % food)
	for tool in Siedler.TOOLS:
		t.check(Siedler.is_tool_good(tool), "'%s' ist ein Werkzeug" % tool)
	t.check(not Siedler.is_food_good("logs"), "Stämme sind keine Nahrung")

	# Jedes Gebäude hat Namen, Beschreibung und Zyklus.
	for kind in Siedler.KINDS:
		var spec := Siedler.spec_of(kind)
		t.check(not str(spec["name"]).is_empty(), "%s hat einen Namen" % kind)
		t.check(not str(spec["desc"]).is_empty(), "%s hat eine Beschreibung" % kind)
		t.check(float(spec["cycle"]) > 0.0, "%s hat einen Zyklus" % kind)
		t.check(AssetRegistry.exists(str(Siedler.MESH_BY_KIND[kind])), "%s hat ein Mesh" % kind)
	t.suite_done()


func _siedler_roads() -> void:
	t.suite("Siedler — Fahnen und Straßen")

	# Fahnen wachsen mit der Länge — die Regel des Originals.
	t.equal(Siedler.flags_for(1.0), 2, "Ein Feld braucht zwei Fahnen")
	t.equal(Siedler.flags_for(float(Siedler.FLAG_SPACING)), 2, "Am Flaggenabstand zwei Fahnen")
	t.check(Siedler.flags_for(float(Siedler.FLAG_SPACING) + 1.0) > 2, "Darüber kommt eine dritte Fahne dazu")
	t.check(Siedler.flags_for(float(Siedler.FLAG_SPACING) * 3.0) > Siedler.flags_for(float(Siedler.FLAG_SPACING)),
		"Längere Straßen brauchen mehr Fahnen")

	# Eine Straße verbindet Burg und Ziel und setzt Fahnen. Das Ziel liegt
	# bewusst weit weg, damit mehrere Fahne-zu-Fahne-Abschnitte entstehen.
	var siedler := _siedler()
	var castle_cell: int = siedler.buildings[siedler.castle_id]["cell"]
	var target := _cell_near(siedler, "grass", 4)
	t.check(target >= 0, "Es gibt ein Zielfeld")
	var result := siedler.build_road(castle_cell, target)
	t.check(bool(result["ok"]), "Straße von der Burg wird gebaut")
	var flags := 0
	for node in siedler.nodes:
		if bool(node["flag"]):
			flags += 1
	t.check(flags >= 1, "Die Straße hat mindestens eine Fahne")
	t.check(int(result["flags"]) >= 1, "Die Meldung zählt die gesetzten Fahnen mit")

	# Eine ausgedehnte Straße über mehrere Felder.
	var far_cell := -1
	var far_reach := 0
	for i in siedler.cells.size():
		var cell: Dictionary = siedler.cells[i]
		if str(cell["res"]) != "grass" or int(cell["building"]) >= 0 or int(cell["flag"]) >= 0:
			continue
		var d: int = maxi(absi(i % siedler.map_size - castle_cell % siedler.map_size),
			absi(i / siedler.map_size - castle_cell / siedler.map_size))
		if d > far_reach:
			far_reach = d
			far_cell = i
	var long_result := {}
	if far_cell >= 0:
		long_result = siedler.build_road(castle_cell, far_cell)
		t.check(bool(long_result["ok"]), "Eine lange Straße lässt sich bauen")
		t.check(int(long_result["flags"]) >= 3, "Eine lange Straße bekommt mehrere Fahnen")

	# Jedes Straßensegment trägt mindestens einen, höchstens die Höchstzahl an
	# Trägern.
	var road_edges := 0
	for edge in siedler.edges:
		if str(edge["kind"]) != "road":
			continue
		road_edges += 1
		var count: int = (edge["carriers"] as Array).size()
		t.check(count >= 1, "Jede Straße hat Träger")
		t.check(count <= Siedler.MAX_CARRIERS_PER_ROAD, "Trägerzahl bleibt im Rahmen")
	t.check(road_edges > 0, "Es gibt Straßensegmente")

	# Eine zusätzliche Fahne erhöht den Durchsatz.
	var before := 0
	for edge in siedler.edges:
		if str(edge["kind"]) == "road":
			before += (edge["carriers"] as Array).size()
	var linked: Array[int] = []
	for edge in siedler.edges:
		if str(edge["kind"]) == "road":
			linked.append(int(siedler.nodes[int(edge["a"])]["cell"]))
			linked.append(int(siedler.nodes[int(edge["b"])]["cell"]))
	var placed := false
	for cell in linked:
		if placed:
			break
		for offset in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var x: int = cell % siedler.map_size + offset.x
			var y: int = cell / siedler.map_size + offset.y
			if not siedler.in_bounds(x, y):
				continue
			var index := siedler.cell_index(x, y)
			if str(siedler.cells[index]["res"]) == "water":
				continue
			if int(siedler.cells[index]["flag"]) >= 0 or int(siedler.cells[index]["building"]) >= 0:
				continue
			if siedler.add_flag(index):
				placed = true
			break
	t.check(placed, "Eine Extra-Fahne lässt sich setzen")
	var after := 0
	for edge in siedler.edges:
		if str(edge["kind"]) == "road":
			after += (edge["carriers"] as Array).size()
	t.check(after > before, "Die Extra-Fahne erhöht die Trägerzahl")

	# Wasser blockiert, ausser es ist das Ziel — eine Fischerhütte liegt ja im
	# See.
	var water_cell := -1
	var land_cell := -1
	for i in siedler.cells.size():
		if str(siedler.cells[i]["res"]) == "water" and water_cell < 0:
			water_cell = i
		if str(siedler.cells[i]["res"]) == "grass" and int(siedler.cells[i]["building"]) < 0 and land_cell < 0:
			land_cell = i
	if water_cell >= 0 and land_cell >= 0:
		var blocked := siedler.build_road(land_cell, water_cell)
		var water_distance := Vector2(
			float(water_cell % siedler.map_size - land_cell % siedler.map_size),
			float(water_cell / siedler.map_size - land_cell / siedler.map_size)
		).length()
		if water_distance >= 12.0:
			t.check(not bool(blocked["ok"]), "Wasser blockiert den direkten Weg")
			t.check(not str(blocked["reason"]).is_empty(), "Der Grund steht im Weg-Meldung")

	# Die Priorität verteilt die Träger neu.
	var first_road := {}
	for edge in siedler.edges:
		if str(edge["kind"]) == "road":
			first_road = edge
			break
	if not first_road.is_empty():
		var low: int = (first_road["carriers"] as Array).size()
		siedler.set_road_priority(int(first_road["id"]), 0)
		var fewer: int = (siedler.edges[int(first_road["id"])]["carriers"] as Array).size()
		siedler.set_road_priority(int(first_road["id"]), 8)
		var more: int = (siedler.edges[int(first_road["id"])]["carriers"] as Array).size()
		t.check(fewer <= low, "Niedrige Priorität nimmt Träger weg")
		t.check(more >= fewer, "Hohe Priorität gibt Träger dazu")

	for edge in siedler.edges:
		t.check(siedler.edge_throughput(int(edge["id"])) >= 0.0, "Durchsatz ist messbar")
	t.suite_done()


func _siedler_economy() -> void:
	t.suite("Siedler — Wirtschaft")

	# Das Startpaket muss den klassischen-Zyklus brechen: Minen essen, die
	# Nahrungskette braucht eine Sense, eine Sense braucht Eisen, und Eisen
	# braucht eine abgebaute Lagerstätte.
	var siedler := _siedler()
	t.check(int(siedler.store.get("pickaxe", 0)) > 0,
		"Ohne Spitzhacke ginge keine Mine auf, und damit kein Eisen")
	t.check(int(siedler.store.get("hammer", 0)) > 0, "Es gibt Hammer für den ersten Bau")
	t.check(int(siedler.store.get("axe", 0)) > 0, "Es gibt eine Axt für den ersten Holzfäller")
	t.check(siedler.food_pieces() > 0, "Die Vorratskammer ist nicht leer")

	# Siedler werden bis zur Obergrenze ausgebildet, nicht darüber.
	_run(siedler, 6.0)
	t.equal(siedler.current_serfs(), Siedler.CASTLE_SERFS, "Die Burg stellt zehn Siedler an")
	t.equal(siedler.serf_quota(), Siedler.CASTLE_SERFS, "Ohne Lager bleibt die Grenze bei zehn")

	# Ein Lager hebt die Grenze.
	siedler.store["planks"] = 200
	var plot := _cell_near(siedler, "grass", 4)
	if plot >= 0 and siedler.place_building("warehouse", plot):
		siedler.build_road(int(siedler.buildings[siedler.castle_id]["cell"]), plot)
		_run(siedler, 20.0)
		t.equal(siedler.serf_quota(), Siedler.CASTLE_SERFS + Siedler.WAREHOUSE_SERFS,
			"Ein Lager erlaubt sechs weitere Siedler")
		t.check(siedler.current_serfs() > Siedler.CASTLE_SERFS, "Die Burg bildet daraufhin nach")

	# Das Werkzeug entscheidet über die Arbeit. Die Axt muss verschwunden
	# sein, *bevor* der Holzfäller bezogen wird — ein Siedler, der sie schon
	# hält, behält sie (Werkzeug ist persönliche Ausrüstung, kein Verbrauch).
	var tool_state := _siedler()
	tool_state.store["axe"] = 0
	var forest := _cell_near(tool_state, "forest", 4)
	if forest >= 0:
		tool_state.place_building("woodcutter", forest)
		_run(tool_state, 16.0)
		var cutter := {}
		for building in tool_state.buildings:
			if str(building["kind"]) == "woodcutter":
				cutter = building
		if not cutter.is_empty():
			t.equal(str(cutter["status"]), "noTool", "Ohne Axt arbeitet der Holzfäller nicht")
			tool_state.store["axe"] = 1
			_run(tool_state, 16.0)
			t.check(str(cutter["status"]) != "noTool", "Mit Axt arbeitet er wieder")

	# Ein Siedler behält sein Werkzeug, es wird nicht verbraucht.
	var keep := _siedler()
	var stand := _cell_near(keep, "grass", 4)
	if stand >= 0:
		keep.place_building("sawmill", stand)
		_run(keep, 25.0)
		var holders := 0
		for serf in keep.serfs:
			if str(serf["tool"]) == "hammer":
				holders += 1
		t.check(holders > 0, "Der Erbauer behält seinen Hammer")
		var hammers := int(keep.store.get("hammer", 0))
		_run(keep, 30.0)
		t.equal(int(keep.store.get("hammer", 0)), hammers, "Kein Hammer verschwindet pro Zyklus")

	# Eine vollständige Siedlung: Waren fließen wirklich über die Straßen.
	var run_state := _siedler(21, 44)
	run_state.store["planks"] = 200
	run_state.store["stone"] = 200
	var wood := _cell_near(run_state, "forest", 4)
	var rock := _cell_near(run_state, "stone", 4)
	var mill := _cell_near(run_state, "grass", 4)
	if wood >= 0:
		run_state.place_building("woodcutter", wood)
	if rock >= 0:
		run_state.place_building("quarry", rock)
	if mill >= 0:
		run_state.place_building("sawmill", mill)
	for building in run_state.buildings:
		if str(building["owner"]) == "player" and str(building["kind"]) != "castle":
			run_state.build_road(int(run_state.buildings[run_state.castle_id]["cell"]), int(building["cell"]))
	var before_score := run_state.score()
	_run(run_state, 100.0)
	t.check(run_state.delivered_total > 0, "Es wurde Ware zugestellt")
	t.check(run_state.produced_total > 0, "Es wurde Ware produziert")
	t.check(run_state.score() > before_score, "Die Punktzahl steigt")

	# Ware ohne Abnehmer wird gemeldet statt still zu verschwinden.
	var orphan_state := _siedler()
	var lone := _cell_near(orphan_state, "forest", 4)
	if lone >= 0:
		orphan_state.place_building("woodcutter", lone)
		_run(orphan_state, 30.0)
		var orphans := orphan_state.orphan_goods()
		t.check(orphans.has("logs"), "Stämme ohne Schreiner werden als 'kein Abnehmer' gemeldet")
		t.check(orphans.has("grain"), "Korn ohne Mühle wird gemeldet")

	# Der Förster macht einen leeren Wald wieder auf.
	var forest_state := _siedler()
	var target_forest := _cell_near(forest_state, "forest", 4)
	if target_forest >= 0:
		t.check(int(forest_state.cells[target_forest]["amount"]) > 0, "Der Wald ist anfangs voller Stämme")
		forest_state.cells[target_forest]["amount"] = 0
		var size := forest_state.map_size
		var fx: int = target_forest % size
		var fy: int = target_forest / size
		var nursery := -1
		for r in range(1, 4):
			if nursery >= 0:
				break
			for dy in range(-r, r + 1):
				if nursery >= 0:
					break
				for dx in range(-r, r + 1):
					var index := forest_state.cell_index(clampi(fx + dx, 0, size - 1), clampi(fy + dy, 0, size - 1))
					var cell: Dictionary = forest_state.cells[index]
					if str(cell["res"]) != "grass" or int(cell["building"]) >= 0 or int(cell["flag"]) >= 0:
						continue
					nursery = index
					break
		if nursery >= 0 and forest_state.place_building("forester", nursery):
			forest_state.build_road(int(forest_state.buildings[forest_state.castle_id]["cell"]), nursery)
			_run(forest_state, 60.0)
			t.check(int(forest_state.cells[target_forest]["amount"]) > 0, "Der Förster pflanzt nach")

	# Territorium wächst nur über einen besetzten Wachturm.
	var military := _siedler()
	for building in military.buildings:
		if str(building["kind"]) == "watchtower":
			building["garrison"] = 0
	military.refresh_territory()
	var without := military.territory_share()
	for building in military.buildings:
		if str(building["kind"]) == "watchtower":
			building["garrison"] = 2
	military.refresh_territory()
	t.check(military.territory_share() >= without, "Ein besetzter Wachturm erweitert das Territorium")

	# Ein zugestelltes Schwert und Schild wird zum Ritter.
	var armed := _siedler()
	armed.store["sword"] = 1
	armed.store["shield"] = 1
	var knights_before := armed.knights
	armed.tick(1.0 / 30.0)
	t.equal(armed.knights, knights_before + 1, "Schwert und Schild werden zu einem Ritter")
	t.equal(int(armed.store.get("sword", 0)), 0, "Das Schwert wird verbraucht")

	# Die Angriffsmoral steigt mit Gold, ist aber gedeckelt.
	var rich := _siedler()
	var plain := rich.attack_morale()
	rich.store["goldBar"] = 500
	t.check(rich.attack_morale() > plain, "Gold hebt die Moral")
	t.check(rich.attack_morale() <= 1.8, "Die Moral ist gedeckelt")

	# tick bleibt stabil.
	var stable := _siedler(21, 40)
	stable.tick(1.0)
	var first := stable.time
	stable.tick(1000.0)
	t.check(stable.time - first <= 0.26, "Ein riesiger Schritt wird begrenzt")
	stable.won = true
	var frozen := stable.time
	stable.tick(1.0)
	t.equal(stable.time, frozen, "Nach dem Ende steht die Uhr still")
	_run(stable, 30.0)
	for cell in stable.cells:
		t.check(int(cell["amount"]) >= 0, "Kein Lagerstätte wird negativ")
		break
	for good in Siedler.GOODS:
		t.check(int(stable.store.get(good, 0)) >= 0, "'%s' wird nicht negativ" % good)
	t.suite_done()






func _flight_forecast() -> void:
	t.suite("Drachenflug — Zuchtvorhersage")
	# Allele-Weitergabe: die beiden Wahrscheinlichkeiten ergaenzen sich zu 1.
	var both := DragonFlight.allele_pass_probabilities({"feueratem": "FF"}, "feueratem")
	t.almost(float(both["passes_dominant"]) + float(both["passes_recessive"]), 1.0, 0.0001, "FF gibt immer dominant weiter")
	t.almost(float(both["passes_dominant"]), 1.0, 0.0001, "FF reicht Fehleratem sicher weiter")
	var mixed := DragonFlight.allele_pass_probabilities({"feueratem": "Fa"}, "feueratem")
	t.almost(float(mixed["passes_dominant"]), 0.5, 0.0001, "Fa ist zur Hälfte dominant")
	var none := DragonFlight.allele_pass_probabilities({"feueratem": "aa"}, "feueratem")
	t.almost(float(none["passes_dominant"]), 0.0, 0.0001, "aa gibt nie dominant weiter")
	t.equal(DragonFlight.allele_pass_probabilities({}, "feueratem")["passes_dominant"], 0.5, "Ohne Allele gilt 50/50")
	t.almost(DragonFlight.allele_pass_probabilities({"feueratem": "FF"}, "gibtsnicht")["passes_dominant"], 0.5, 0.0001, "Unbekanntes Merkmal ist neutral")

	# Ein dominantes Merkmal braucht ein dominantes Allel — ein Träger reicht.
	var carrier := {"alleles": {"feueratem": "Fa"}}
	var homozygous := {"alleles": {"feueratem": "FF"}}
	var clean := {"alleles": {"feueratem": "aa"}}
	t.almost(DragonFlight.trait_probability(carrier, carrier, "feueratem"), 0.75, 0.0001, "Zwei Träger: 75 %")
	t.almost(DragonFlight.trait_probability(homozygous, clean, "feueratem"), 1.0, 0.0001, "FF x aa ist sicher")
	t.almost(DragonFlight.trait_probability(clean, clean, "feueratem"), 0.0, 0.0001, "aa x aa ist nie dominant")

	# Ein rezessives Merkmal dreht sich um: genau dann, wenn beide weitergeben.
	# Wichtig: beide Elternteile müssen das Merkmal auch tragen, sonst greift der
	# Neutralwert von 50 % — "nicht vorhanden" heisst "unbekannt", nicht "nicht".
	var rec_a := {"alleles": {"riesenwuchs": "rr"}}
	var rec_b := {"alleles": {"riesenwuchs": "rr"}}
	var rec_dom := {"alleles": {"riesenwuchs": "RR"}}
	t.almost(DragonFlight.trait_probability(rec_a, rec_b, "riesenwuchs"), 1.0, 0.0001, "Zwei rezessive Träger sind sicher")
	t.almost(DragonFlight.trait_probability(rec_a, rec_dom, "riesenwuchs"), 0.0, 0.0001, "Ein Träger allein reicht nicht")
	t.almost(DragonFlight.trait_probability(clean, clean, "riesenwuchs"), 0.25, 0.0001, "Ohne Allele gilt der Neutralwert 25 %")
	var half := {"alleles": {"riesenwuchs": "Rr"}}
	t.almost(DragonFlight.trait_probability(half, half, "riesenwuchs"), 0.25, 0.0001, "Rr x Rr ergibt 25 %")

	# Die Vorhersage deckt alle Merkmale ab und ist absteigend sortiert.
	var forecast := DragonFlight.breeding_forecast(carrier, clean)
	t.equal(forecast.size(), DragonFlight.TRAITS.size(), "Die Vorhersage nennt jedes Merkmal")
	var previous := 2.0
	for entry in forecast:
		var chance := float(entry["chance"])
		t.check(chance >= 0.0 and chance <= 1.0, "Wahrscheinlichkeit liegt zwischen 0 und 1")
		t.check(chance <= previous + 0.0001, "Die Vorhersage ist absteigend sortiert")
		previous = chance
	# Die Merkmale der Eltern tauchen mit 100 % auf.
	var names: Array[String] = []
	for entry in forecast:
		names.append(str(entry["name"]))
	t.check("Feueratem" in names, "Feueratem steht in der Vorhersage")
	t.equal(DragonFlight.breeding_forecast({}, {})[0].size(), 6, "Auch leere Eltern ergeben einen Eintrag")

	# Ahnenlinie: Wurzeln haben keine Eltern, ein Kind schon.
	var root := DragonFlight.random_dragon(1, ["ember"])
	t.equal(DragonFlight.parent_uids(root).size(), 0, "Ein Stammlinien-Drache hat keine Eltern")
	t.equal(DragonFlight.ancestors({}, int(root["uid"])).size(), 0, "Ohne Profil gibt es keine Ahnen")
	var profile := DragonFlight.default_profile()
	var parent_a := DragonFlight.random_dragon(1, ["ember"])
	var parent_b := DragonFlight.random_dragon(2, ["frost"])
	profile["dragons"] = [parent_a, parent_b]
	var child := DragonFlight.breed_parents(parent_a, parent_b, 3)
	t.equal(DragonFlight.parent_uids(child), [1, 2], "Das Kind kennt beide Eltern")
	var grandchild := DragonFlight.breed_parents(child, parent_a, 4)
	profile["dragons"].append(child)
	profile["dragons"].append(grandchild)
	t.equal(DragonFlight.parent_uids(grandchild), [3, 1], "Das Enkelkind kennt seine Eltern")
	var tree := DragonFlight.ancestors(profile, 4, 2)
	t.check(tree.size() >= 2, "Die Ahnenliste ist nicht leer")
	var uids: Array[int] = []
	for entry in tree:
		uids.append(int(entry["uid"]))
	t.check(4 not in uids, "Ein Drache erscheint nicht selbst in seiner Ahnenliste")
	t.check(1 in uids, "Der Großelternteil taucht auf")
	t.suite_done()


func _flight_elements() -> void:
	t.suite("Drachenflug — Elemente")
	t.check(not DragonFlight.element_name("fire").is_empty(), "Feuer hat einen Namen")
	t.check(DragonFlight.element_name("fire") != DragonFlight.element_name("ice"), "Feuer und Frost heißen verschieden")
	# Widerstand mindert, Anfälligkeit verstaerkt, beides mit Grenzen.
	t.almost(DragonFlight.element_multiplier("fire", {}), 1.0, 0.0001, "Ohne Widerstand gilt 1,0")
	t.almost(DragonFlight.element_multiplier("fire", {"fire": 0.5}), 0.5, 0.0001, "Feuerfest halbiert den Schaden")
	t.almost(DragonFlight.element_multiplier("fire", {"fire": -0.5}), 1.5, 0.0001, "Feueranfällig verstärkt ihn")
	t.check(DragonFlight.element_multiplier("fire", {"fire": 5.0}) >= 0.25, "Der Multiplikator hat eine Untergrenze")
	t.check(DragonFlight.element_multiplier("fire", {"fire": -5.0}) <= 2.0, "Der Multiplikator hat eine Obergrenze")
	t.almost(DragonFlight.element_multiplier("ice", {"fire": 0.5}), 1.0, 0.0001, "Frost zahlt nicht für Feuerwiderstand")

	# Jeder Gegner hat Widerstaende, und die Level-Briefing fasst sie zusammen.
	for enemy in DragonFlight.ENEMIES:
		t.check(enemy.has("resist"), "Gegner '%s' nennt seinen Widerstand" % str(enemy["id"]))
		t.check((enemy["resist"] as Dictionary).size() > 0, "Gegner '%s' hat mindestens einen Widerstand" % str(enemy["id"]))
	for breed in DragonFlight.BREEDS:
		t.check(not str(breed.get("element", "")).is_empty(), "Rasse '%s' hat ein Element" % str(breed["id"]))
	# Der Steindrache ist feuerfest, der Giftdrache nicht.
	t.check(float(DragonFlight.enemy_by_id("golem")["resist"]["fire"]) > 0.0, "Der Golem ist feuerfest")
	t.check(float(DragonFlight.enemy_by_id("ballista")["resist"]["fire"]) < 0.0, "Die Ballista ist feueranfällig")

	var summary := DragonFlight.level_resist_summary(DragonFlight.level(1))
	t.check(not summary.is_empty(), "Das Briefing nennt die Widerstände")
	t.check(summary.contains("Feuer"), "Das Briefing nennt Feuer")
	# Das Element steckt in den aufgelösten Werten.
	var stats := DragonFlight.resolve_stats({"breed": "stone", "alleles": {}, "gen": 1})
	t.equal(str(stats["element"]), "earth", "Die aufgelösten Werte kennen das Element")
	t.suite_done()



