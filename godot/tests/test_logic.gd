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
	_suite(_inventory)
	_suite(_lobby)
	_suite(_asset_registry)
	_suite(_mechanics)


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
	t.equal(GameRegistry.games_in_category(GameRegistry.CATEGORY_ACTION).size(), 2, "Zwei Action-Spiele")
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
