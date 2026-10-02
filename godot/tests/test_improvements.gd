class_name TestImprovements
extends RefCounted
## Rule tests for the improvements layered on top of the original port: T-Spin
## scoring, queue preview and board danger, wave forecasting and kill chains,
## loot rarity. Kept in their own file so the feature work can be validated
## independently of the rest of the suite.

var t: TestKit


func run(kit: TestKit) -> void:
	t = kit
	_suite(_tetris_scoring)
	_suite(_tetris_spin)
	_suite(_tetris_preview)
	_suite(_tetris_danger)
	_suite(_arena_waves)
	_suite(_arena_chains)
	_suite(_loot_rarity)
	_suite(_suggestion_context)
	_suite(_lod_tiers)
	_suite(_gallery_layout)


## Runs one suite and fails it if it returned before its own `t.suite_done()`,
## which is what a swallowed runtime error looks like.
func _suite(fn: Callable) -> void:
	fn.call()
	t.close_suite()


# --- Tetris: scoring --------------------------------------------------------

func _empty_well(rows: int = 20, cols: int = 10) -> Array:
	var board: Array = []
	for _y in rows:
		var row: Array = []
		for _x in cols:
			row.append(0)
		board.append(row)
	return board


func _tetris_scoring() -> void:
	t.suite("Tetris — Punktewertung")

	var none := TetrisRules.score_clear(0, 1, 0, 0, "none")
	t.equal(none["points"], 0, "Ohne geräumte Zeile gibt es keine Punkte")
	t.equal(none["combo"], 0, "Die Kette wird ohne Zeile zurückgesetzt")
	t.equal(none["message"], "", "Ohne Zeile gibt es keinen Text")

	t.equal(TetrisRules.score_clear(1, 1, 0, 0, "none")["points"], 100, "Single: 100")
	t.equal(TetrisRules.score_clear(2, 1, 0, 0, "none")["points"], 300, "Double: 300")
	t.equal(TetrisRules.score_clear(3, 1, 0, 0, "none")["points"], 500, "Triple: 500")
	t.equal(TetrisRules.score_clear(4, 1, 0, 0, "none")["points"], 800, "Quad: 800")
	t.equal(TetrisRules.score_clear(4, 1, 0, 0, "none")["message"], "QUAD!", "Quad meldet sich")
	t.check(str(TetrisRules.score_clear(3, 1, 0, 0, "none")["message"]).contains("TETRIS"), "Triple meldet TETRIS")
	t.equal(TetrisRules.score_clear(1, 1, 0, 0, "none")["message"], "", "Eine einzelne Zeile meldet nichts")

	# Level multiplier applies to everything.
	t.equal(TetrisRules.score_clear(2, 3, 0, 0, "none")["points"], 900, "Level 3 verdreifacht die 300")

	# T-Spins beat the plain clear of the same size; guideline values are 400
	# without a line, then 800/1200/1600.
	t.equal(TetrisRules.score_clear(0, 1, 0, 0, "full")["points"], 400, "T-Spin ohne Zeile: 400")
	t.equal(TetrisRules.score_clear(1, 1, 0, 0, "full")["points"], 800, "T-Spin Single: 800")
	t.equal(TetrisRules.score_clear(2, 1, 0, 0, "full")["points"], 1200, "T-Spin Double: 1200")
	t.equal(TetrisRules.score_clear(3, 1, 0, 0, "full")["points"], 1600, "T-Spin Triple: 1600")
	t.check(str(TetrisRules.score_clear(2, 1, 0, 0, "full")["message"]).contains("T-SPIN FULL"), "T-Spin meldet sich")
	t.check(str(TetrisRules.score_clear(1, 1, 0, 0, "mini")["message"]).contains("T-SPIN MINI"), "T-Spin Mini meldet sich")
	t.equal(TetrisRules.score_clear(1, 1, 0, 0, "mini")["points"], 400, "T-Spin Mini halbiert die 800")
	t.equal(TetrisRules.score_clear(0, 1, 0, 0, "mini")["points"], 200, "T-Spin Mini ohne Zeile halbiert die 400")

	# A line-less T-Spin opens a chain but must not break an existing combo.
	var no_lines := TetrisRules.score_clear(0, 1, 3, 1, "full")
	t.equal(no_lines["combo"], 3, "Ein T-Spin ohne Zeile unterbricht die Combo nicht")
	t.equal(no_lines["back_to_back"], 2, "Ein T-Spin ohne Zeile verlängert B2B")
	t.equal(no_lines["b2bBonus"], 50, "Der T-Spin ohne Zeile zahlt den B2B-Schritt")
	t.check(bool(no_lines["difficult"]), "Ein T-Spin ohne Zeile gilt als schwierig")

	# Back-to-Back only grows on difficult clears and pays out from the second.
	var first := TetrisRules.score_clear(4, 1, 0, 0, "none")
	t.equal(first["back_to_back"], 1, "Ein Quad startet die B2B-Kette")
	t.equal(first["b2bBonus"], 0, "Die erste schwierige Zeile zahlt noch keinen B2B-Bonus")
	var second := TetrisRules.score_clear(4, 1, 0, 1, "none")
	t.equal(second["back_to_back"], 2, "Das zweite Quad verlängert die Kette")
	t.equal(second["b2bBonus"], 50, "Der zweite B2B-Schritt zahlt 50")
	t.equal(second["points"], 850, "Quad plus B2B: 800 + 50")
	t.equal(first["message"], "QUAD!", "Die erste schwierige Zeile nennt noch keine Kette")
	var third := TetrisRules.score_clear(4, 1, 0, 2, "none")
	t.equal(third["b2bBonus"], 100, "Der dritte B2B-Schritt zahlt 100")
	t.check(str(third["message"]).contains("B2B ×3"), "Die Meldung nennt die Kettenlänge")

	var easy := TetrisRules.score_clear(1, 1, 0, 3, "none")
	t.equal(easy["back_to_back"], 0, "Ein Single bricht die B2B-Kette")
	t.equal(easy["b2bBonus"], 0, "Ein Single zahlt keinen B2B-Bonus")

	var b2b_tspin := TetrisRules.score_clear(2, 1, 0, 1, "full")
	t.equal(b2b_tspin["b2bBonus"], 50, "Ein T-Spin Double gilt als schwierig und zahlt B2B")

	# Combo counts consecutive clears and pays from the second onwards.
	var c1 := TetrisRules.score_clear(1, 1, 0, 0, "none")
	t.equal(c1["combo"], 1, "Die erste Zeile startet die Combo")
	t.equal(c1["comboBonus"], 0, "Die erste Zeile zahlt keinen Combo-Bonus")
	var c2 := TetrisRules.score_clear(1, 1, 1, 0, "none")
	t.equal(c2["combo"], 2, "Die zweite Zeile erhöht die Combo")
	t.equal(c2["comboBonus"], 50, "Die zweite Zeile zahlt 50 Combo-Punkte")
	t.equal(c2["points"], 150, "Single plus Combo: 100 + 50")
	t.check(str(c2["message"]).contains("COMBO ×2"), "Die Meldung nennt die Combo")

	# A cleared line is always awarded the level multiplier.
	t.check(TetrisRules.score_clear(1, 5, 3, 2, "full")["points"] > TetrisRules.score_clear(1, 5, 0, 0, "full")["points"],
		"Hohe Kette und hohes Level zahlen mehr")
	t.check(float(TetrisRules.score_clear(3, 1, 0, 0, "full")["flash"]) > 0.0, "Eine Dreierreihe blitzt auf")
	t.check(float(TetrisRules.score_clear(1, 1, 0, 0, "none")["flash"]) < 0.2, "Eine einzelne Zeile blitzt nur kurz")

	# A wiped well is worth more than any other clear, so its rules live in the
	# scoring suite.
	_perfect_clear_scoring()
	t.suite_done()


## Perfect Clear: the well is empty again, the player gets the biggest bonus of
## the game and a chain that survives even a plain single.
func _perfect_clear_scoring() -> void:
	t.equal(TetrisRules.is_perfect_clear([]), false, "Ohne Senke gibt es keinen Perfect Clear")
	t.check(TetrisRules.is_perfect_clear(_empty_well(4, 6)), "Eine leere Senke ist ein Perfect Clear")

	var busy := _empty_well(4, 6)
	(busy[3] as Array)[0] = 1
	t.equal(TetrisRules.is_perfect_clear(busy), false, "Ein einzelner Stein ist kein Perfect Clear")
	var nearly := _empty_well(4, 6)
	(nearly[0] as Array)[5] = 1
	t.equal(TetrisRules.is_perfect_clear(nearly), false, "Auch ein Stein ganz oben verhindert ihn")

	# Guideline values: 800/1200/1800/2000, all multiplied by the level.
	var single := TetrisRules.perfect_clear(1, 1, 0)
	t.equal(single["points"], 800, "Perfect Clear Single: 800")
	t.equal(single["text"], "PERFECT CLEAR!", "Ein einzelner Perfect Clear meldet sich")
	t.equal(single["back_to_back"], 1, "Ein Perfect Clear startet die B2B-Kette")
	t.equal(single["b2b_quad"], false, "Ein einzelner Perfect Clear ist kein B2B Quad")
	t.almost(float(single["seconds"]), TetrisRules.PC_CELEBRATION, 0.001, "Die Feier dauert die angegebene Zeit")

	t.equal(TetrisRules.perfect_clear(2, 1, 0)["points"], 1200, "Perfect Clear Double: 1200")
	t.equal(TetrisRules.perfect_clear(3, 1, 0)["points"], 1800, "Perfect Clear Triple: 1800")
	t.equal(TetrisRules.perfect_clear(4, 1, 0)["points"], 2000, "Perfect Clear Quad: 2000")
	t.check(str(TetrisRules.perfect_clear(2, 1, 0)["text"]).contains("DOUBLE"), "Die Meldung nennt die Größe")
	t.equal(TetrisRules.perfect_clear(1, 4, 0)["points"], 3200, "Level 4 vervierfacht die 800")

	# A perfect clear always clears at least one line, so it can never pay nothing
	# and still open a chain.
	t.equal(TetrisRules.perfect_clear(0, 1, 0)["points"], 800, "Eine leere Zeilenangabe zählt als Single")

	# The B2B Quad is the most expensive move in the game.
	var b2b := TetrisRules.perfect_clear(4, 1, 2)
	t.equal(b2b["points"], TetrisRules.PC_B2B_QUAD, "Ein B2B Quad zahlt 3200")
	t.equal(b2b["b2b_quad"], true, "Der zweite Quad in Folge ist ein B2B Quad")
	t.equal(b2b["back_to_back"], 3, "Die Kette läuft weiter")
	t.check(str(b2b["text"]).contains("B2B ×3"), "Die Meldung nennt die Kette")
	t.check(str(b2b["text"]).contains("QUAD"), "Die Meldung nennt die Größe")
	t.equal(TetrisRules.perfect_clear(4, 1, 0)["b2b_quad"], false, "Der erste Quad ist noch kein B2B Quad")
	t.equal(TetrisRules.perfect_clear(3, 1, 2)["points"], 1800, "Ein B2B Triple zahlt nicht den Quad-Bonus")

	# A perfect clear is always a difficult clear: it never breaks a chain, no
	# matter how few lines it actually cleared.
	t.equal(TetrisRules.perfect_clear(1, 1, 5)["back_to_back"], 6, "Ein einzelner Perfect Clear verlängert die Kette")
	t.equal(TetrisRules.perfect_clear(1, 1, 5)["b2b_quad"], false, "Ein einzelner Perfect Clear zahlt den Quad-Bonus nicht")

	# Worth more than the same clear without the empty bonus — and much more when
	# it extends an existing chain.
	t.check(int(TetrisRules.perfect_clear(1, 1, 0)["points"]) > int(TetrisRules.score_clear(1, 1, 0, 0, "none")["points"]),
		"Ein Perfect Clear zahlt mehr als ein Single")
	t.check(int(TetrisRules.perfect_clear(4, 1, 1)["points"]) > int(TetrisRules.perfect_clear(4, 1, 0)["points"]),
		"Der B2B Quad ist mehr wert als der erste Quad")


# --- Tetris: T-Spin detection ----------------------------------------------

func _tetris_spin() -> void:
	t.suite("Tetris — T-Spin-Erkennung")

	var all_four := [[true, true], [true, true]]
	var three := [[true, true], [true, false]]
	var two := [[true, true], [false, false]]
	var none := [[false, false], [false, false]]

	t.check(TetrisRules.is_t_spin(TetrisRules.T_PIECE_TYPE, true, three), "Drei belegte Ecken zählen als T-Spin")
	t.check(TetrisRules.is_t_spin(TetrisRules.T_PIECE_TYPE, true, all_four), "Vier belegte Ecken zählen als T-Spin")
	t.check(not TetrisRules.is_t_spin(TetrisRules.T_PIECE_TYPE, true, two), "Zwei Ecken reichen für einen vollen T-Spin nicht")
	t.check(not TetrisRules.is_t_spin(TetrisRules.T_PIECE_TYPE, true, none), "Ohne Ecken gibt es keinen T-Spin")
	t.check(not TetrisRules.is_t_spin(TetrisRules.T_PIECE_TYPE, false, all_four),
		"Nur nach einer Drehung zählt es als T-Spin")
	t.check(not TetrisRules.is_t_spin(3, true, all_four), "Nur das T zählt als T-Spin")

	t.check(TetrisRules.is_t_spin_mini(two), "Zwei Ecken ergeben einen T-Spin Mini")
	t.check(not TetrisRules.is_t_spin_mini(three), "Drei Ecken sind kein Mini mehr")
	t.check(not TetrisRules.is_t_spin_mini(all_four), "Vier Ecken sind kein Mini")
	t.equal(TetrisRules.corner_count(none), 0, "Leere Ecken werden gezählt")
	t.equal(TetrisRules.corner_count([[true]]), -1, "Kaputte Ecken werden abgewiesen")
	t.check(not TetrisRules.is_t_spin(TetrisRules.T_PIECE_TYPE, true, [[true]]), "Kaputte Ecken sind kein T-Spin")

	# The corner sampler mirrors the screen's `_filled_at`: walls, the floor and
	# the ceiling all count as filled, which is what lets a wall kick register.
	var board := _empty_well(4, 6)
	var wall_and_floor := func(x: int, y: int) -> bool:
		return x < 0 or y >= board.size() or int((board[y] as Array)[x]) != 0
	t.equal(TetrisRules.corner_count(TetrisRules.t_corners(0, 1, wall_and_floor)), 0,
		"Eine leere Senke in der Mitte zählt keine Ecke")
	t.equal(TetrisRules.corner_count(TetrisRules.t_corners(-1, 1, wall_and_floor)), 2,
		"Die linke Wand gilt als belegt")
	t.equal(TetrisRules.corner_count(TetrisRules.t_corners(-1, 2, wall_and_floor)), 3,
		"Wand plus Boden ergeben drei belegte Ecken")
	t.check(TetrisRules.is_t_spin(TetrisRules.T_PIECE_TYPE, true, TetrisRules.t_corners(-1, 2, wall_and_floor)),
		"Ein T an der Wand über dem Boden ist ein T-Spin")

	var nothing := func(_x: int, _y: int) -> bool:
		return false
	t.equal(TetrisRules.corner_count(TetrisRules.t_corners(2, 0, nothing)), 0, "Nichts ist belegt")
	t.suite_done()


# --- Tetris: queue preview --------------------------------------------------

func _tetris_preview() -> void:
	t.suite("Tetris — Vorschaukette")

	t.equal(TetrisRules.preview_chain([1, 2, 3, 4, 5], 3), [1, 2, 3] as Array[int],
		"Die Vorschau zeigt die ersten drei Steine der Warteschlange")
	t.equal(TetrisRules.preview_chain([1, 2], 4), [1, 2, -1, -1] as Array[int],
		"Eine kurze Warteschlange wird aufgefüllt")
	t.equal(TetrisRules.preview_chain([], 3), [-1, -1, -1] as Array[int],
		"Eine leere Warteschlange liefert nur Platzhalter")
	t.equal(TetrisRules.preview_chain([1, 2, 3], 1).size(), 1, "Ein Vorschau von einem Stein funktioniert")
	t.check(TetrisRules.preview_chain([1, 2, 3], 0).size() >= 1, "Null Vorschau wird auf mindestens einen gehoben")

	t.equal(TetrisRules.preview_count(4), 4, "4 ist eine erlaubte Vorschaulänge")
	t.equal(TetrisRules.preview_count(3), 3, "3 ist eine erlaubte Vorschaulänge")
	t.equal(TetrisRules.preview_count(6), 6, "6 ist eine erlaubte Vorschaulänge")
	t.equal(TetrisRules.preview_count(99), 6, "Eine zu große Vorschaulänge wird auf das Maximum begrenzt")
	t.equal(TetrisRules.preview_count(-5), 3, "Eine negative Vorschaulänge wird auf das Minimum begrenzt")
	t.equal(TetrisRules.preview_count(4), TetrisRules.preview_count(4), "Die Vorschaulänge ist stabil")
	for option in TetrisRules.PREVIEW_OPTIONS:
		t.equal(TetrisRules.preview_count(option), option, "Option %d bleibt erhalten" % option)
	t.suite_done()


# --- Tetris: board danger ---------------------------------------------------

func _tetris_danger() -> void:
	t.suite("Tetris — Brettgefahr")

	var empty := _empty_well(4, 5)
	t.almost(TetrisRules.fill_ratio(empty), 0.0, 0.0001, "Ein leeres Brett ist zu 0 % gefüllt")
	t.equal(TetrisRules.danger_level(empty), 0, "Ein leeres Brett ist unbedenklich")
	t.equal(TetrisRules.danger_text(empty), "", "Ohne Gefahr gibt es keine Warnung")

	# 20×10 well: 140 of 200 cells is 70 %, i.e. past the first threshold.
	var busy := _empty_well(20, 10)
	for y in 14:
		for x in 10:
			(busy[y] as Array)[x] = 1
	t.almost(TetrisRules.fill_ratio(busy), 0.7, 0.0001, "Ein zu 70 % gefülltes Brett")
	t.equal(TetrisRules.danger_level(busy), 1, "Bei 70 % warnt das Spiel vor dem Turm")
	t.check(TetrisRules.danger_text(busy).contains("Der Turm wächst"), "Die Warnung nennt den Turm")
	t.check(TetrisRules.danger_text(busy).contains("6 freie Reihen"), "Die Warnung zählt die freien Reihen")

	var calm := _empty_well(20, 10)
	for y in 12:
		for x in 10:
			(calm[y] as Array)[x] = 1
	t.equal(TetrisRules.danger_level(calm), 0, "Bei 60 % bleibt es ruhig")

	var full := _empty_well(4, 5)
	for row in full:
		for x in 5:
			(row as Array)[x] = 1
	t.almost(TetrisRules.fill_ratio(full), 1.0, 0.0001, "Ein volles Brett ist zu 100 % gefüllt")
	t.equal(TetrisRules.danger_level(full), 2, "Bei 100 % ist es kritisch")
	t.check(TetrisRules.danger_text(full).contains("GEFAHR"), "Die kritische Warnung schlägt Alarm")
	t.check(TetrisRules.danger_text(full).contains("0 freie Reihen"), "Ein volles Brett hat keine freie Reihe")

	t.equal(TetrisRules.danger_level(_empty_well(0, 0)), 0, "Ein Brett ohne Zellen ist harmlos")
	t.almost(TetrisRules.fill_ratio([]), 0.0, 0.0001, "Eine leere Brettliste ergibt 0")
	t.suite_done()


# --- Arena: waves -----------------------------------------------------------

func _enemy_defs() -> Array:
	return [
		{"id": "slime", "name": "Schleim", "weight": 10.0, "minWave": 1, "boss": false},
		{"id": "bat", "name": "Fledermaus", "weight": 6.0, "minWave": 1, "boss": false},
		{"id": "ghost", "name": "Geist", "weight": 4.0, "minWave": 4, "boss": false},
		{"id": "hidden", "name": "Versteckt", "weight": 0.0, "minWave": 1, "boss": false},
		{"id": "warden", "name": "Wärter", "weight": 3.0, "minWave": 1, "boss": true},
		{"id": "titan", "name": "Titan", "weight": 3.0, "minWave": 8, "boss": true},
	]


func _arena_waves() -> void:
	t.suite("Arena — Wellenvorschau")

	t.equal(ArenaRuns.wave_at(0.0), 1, "Bei null Sekunden ist Welle 1")
	t.equal(ArenaRuns.wave_at(29.9), 1, "Welle 1 dauert 30 Sekunden")
	t.equal(ArenaRuns.wave_at(30.0), 2, "Nach 30 Sekunden kommt Welle 2")
	t.equal(ArenaRuns.wave_at(95.0), 4, "Nach 95 Sekunden ist Welle 4")
	t.equal(ArenaRuns.wave_at(-5.0), 1, "Eine negative Zeit zählt als Welle 1")
	t.almost(ArenaRuns.time_to_next_wave(0.0), 30.0, 0.001, "Zu Welle 1 bleiben 30 Sekunden")
	t.almost(ArenaRuns.time_to_next_wave(15.0), 15.0, 0.001, "Nach 15 Sekunden bleiben 15")
	t.almost(ArenaRuns.time_to_next_wave(30.0), 30.0, 0.001, "Eine frische Welle startet die Uhr neu")
	t.almost(ArenaRuns.time_to_next_wave(45.0), 15.0, 0.001, "Nach 45 Sekunden bleiben 15")

	var defs := _enemy_defs()
	t.equal(ArenaRuns.eligible(defs, 1).size(), 2, "In Welle 1 gibt es zwei normale Gegner")
	t.equal(ArenaRuns.eligible(defs, 4).size(), 3, "Ab Welle 4 kommt ein dritter Gegner dazu")
	for entry in ArenaRuns.eligible(defs, 4):
		t.check(not bool(entry["boss"]), "Die Vorschau verspricht keine Bosse")
		t.check(float(entry["weight"]) > 0.0, "Die Vorschau verspricht keine Gewicht-0-Gegner")
		t.check(int(entry["minWave"]) <= 4, "Die Vorschau kennt keine gesperrten Gegner")

	var preview := ArenaRuns.wave_preview(defs, 4, 3)
	t.equal(preview.size(), 3, "Die Vorschau zeigt alle verfügbaren Gegner")
	t.equal(str(preview[0]["id"]), "slime", "Der schwerste Gegner steht vorn")
	t.equal(str(preview[1]["id"]), "bat", "Danach der zweitschwerste")
	t.equal(ArenaRuns.wave_preview(defs, 1, 1).size(), 1, "Die Vorschau lässt sich begrenzen")

	t.equal(ArenaRuns.boss_preview(defs, 1)["id"], "warden", "Der erste Bosse ist der Wärter")
	t.equal(ArenaRuns.boss_preview(defs, 7)["id"], "warden", "Vor Welle 8 bleibt es beim Wärter")
	t.equal(ArenaRuns.boss_preview(defs, 8)["id"], "titan", "Ab Welle 8 ist der Titan der aktuelle Boss")
	t.equal(ArenaRuns.boss_preview(defs, 99)["id"], "titan", "Auch weit später bleibt der Titan")
	t.equal(ArenaRuns.boss_preview([], 9).size(), 0, "Ohne Bosse gibt es keinen Boss")

	t.almost(ArenaRuns.boss_countdown(0.0, 120.0), 120.0, 0.001, "Der erste Boss kommt nach zwei Minuten")
	t.almost(ArenaRuns.boss_countdown(100.0, 120.0), 20.0, 0.001, "Nach 100 Sekunden bleiben 20 Sekunden")
	t.equal(ArenaRuns.boss_threat(5.0), 2, "Fünf Sekunden vorher ist es kritisch")
	t.equal(ArenaRuns.boss_threat(15.0), 1, "Fünfzehn Sekunden vorher warnt das Spiel")
	t.equal(ArenaRuns.boss_threat(90.0), 0, "Weit im Voraus droht nichts")

	var text := ArenaRuns.preview_text(defs, 2, 0.0)
	t.check(text.contains("Welle 2"), "Die Vorschau nennt die kommende Welle")
	t.check(text.contains("Schleim"), "Die Vorschau nennt einen Gegner")
	t.check(text.contains("Geist") == false, "Die Vorschau kündigt noch nicht gesperrte Gegner an")
	t.check(ArenaRuns.preview_text([], 3, 0.0).contains("Welle 3"), "Ohne Gegner bleibt die Wellennummer")
	t.equal(ArenaRuns.color_of({"rarity": "epic"}), ArenaRuns.RARITY_COLORS["epic"], "Die Seltenheit bestimmt die Farbe")
	t.check(ArenaRuns.color_of({}).is_equal_approx(ArenaRuns.RARITY_COLORS["common"]), "Ohne Seltenheit ist alles gewöhnlich")
	t.suite_done()


# --- Arena: kill chains -----------------------------------------------------

func _arena_chains() -> void:
	t.suite("Arena — Kill-Ketten")

	var state: Dictionary = {"chain": 0, "last_kill": 0.0}
	var first := ArenaRuns.register_kill(state, 1.0, 1)
	t.equal(first["chain"], 1, "Der erste Kill startet die Kette")
	t.equal(first["bonus"], 0, "Der erste Kill zahlt keinen Bonus")
	t.equal(first["milestone"], false, "Der erste Kill ist kein Meilenstein")

	var second := ArenaRuns.register_kill(first, 2.0, 1)
	t.equal(second["chain"], 2, "Der zweite Kill verlängert die Kette")
	t.equal(second["bonus"], 1, "Der zweite Kill zahlt 1 EP")
	t.equal(second["milestone"], false, "Zwei Killchains sind noch kein Meilenstein")

	var third := ArenaRuns.register_kill(second, 3.0, 1)
	t.equal(third["chain"], 3, "Der dritte Kill verlängert weiter")
	t.equal(third["bonus"], 2, "Der dritte Kill zahlt 2 EP")
	t.equal(third["milestone"], true, "Beim dritten Kill leuchtet es auf")

	# A gap longer than the window starts a fresh chain.
	var broken := ArenaRuns.register_kill(third, 3.0 + ArenaRuns.CHAIN_WINDOW + 0.5, 1)
	t.equal(broken["chain"], 1, "Eine zu lange Pause bricht die Kette")
	t.equal(broken["bonus"], 0, "Nach dem Bruch gibt es keinen Bonus")
	t.equal(ArenaRuns.register_kill(broken, 3.0 + ArenaRuns.CHAIN_WINDOW, 1)["chain"], 2,
		"Genau am Zeitfenster zählt die Kette noch")

	# The bonus is capped so a long streak cannot run away with the run.
	var long: Dictionary = {"chain": 0, "last_kill": 0.0}
	for i in 40:
		long = ArenaRuns.register_kill(long, float(i) * 0.1, 1)
	t.equal(long["chain"], 40, "Die Kette zählt ohne Unterbrechung weiter")
	t.check(int(long["bonus"]) <= ArenaRuns.CHAIN_CAP, "Der Bonus bleibt gedeckelt")
	t.check(int(long["bonus"]) > 0, "Eine lange Kette zahlt sich aus")

	var decayed := ArenaRuns.decay({"chain": 5, "last_kill": 1.0}, 20.0)
	t.equal(decayed["chain"], 0, "Eine veraltete Kette verschwindet")
	t.equal(ArenaRuns.decay({"chain": 5, "last_kill": 19.0}, 20.0)["chain"], 5, "Eine frische Kette bleibt")
	t.equal(ArenaRuns.decay({"chain": 0, "last_kill": 1.0}, 20.0)["chain"], 0, "Ohne Kette passiert nichts")

	t.equal(ArenaRuns.chain_text({"chain": 1, "last_kill": 0.0}), "", "Ein einzelner Kill zeigt nichts an")
	t.check(ArenaRuns.chain_text({"chain": 4, "last_kill": 0.0}).contains("×4"), "Die Kette wird angezeigt")
	t.check(ArenaRuns.chain_text({"chain": 4, "last_kill": 0.0}).contains("+3 EP"), "Der Bonus wird angezeigt")
	t.suite_done()


# --- Drachen-RPG: loot rarity ---------------------------------------------

func _loot_rarity() -> void:
	t.suite("Drachen-RPG — Loot-Rarität")

	t.equal(DragonRpg.RARITIES.size(), 5, "Es gibt fünf Raritätsstufen")
	for rarity in DragonRpg.RARITIES:
		t.check(not str(rarity["name"]).is_empty(), "Jede Rarität hat einen deutschen Namen")
		t.check(DragonRpg.rarity_by_id(str(rarity["id"])) == rarity, "Jede Rarität ist auffindbar")
	t.equal(DragonRpg.rarity_by_id("nope")["id"], "common", "Eine unbekannte Rarität wird gewöhnlich")
	t.equal(DragonRpg.rarity_index("legendary"), 4, "Legendär ist die höchste Stufe")
	t.equal(DragonRpg.rarity_index("common"), 0, "Gewöhnlich ist die niedrigste Stufe")
	t.equal(DragonRpg.rarity_index("nope"), 0, "Eine unbekannte Rarität hat Index 0")

	for entry in DragonRpg.LOOT_TABLE:
		t.check(DragonRpg.rarity_of(entry).has("color"), "Jeder Loot-Eintrag hat eine Rarität mit Farbe")
		t.check(DragonRpg.rarity_of(entry).has("glow"), "Jeder Loot-Eintrag hat eine Rarität mit Leuchten")
		t.check(DragonRpg.lottery_weight(entry) > 0.0, "Jeder Loot-Eintrag ist erreichbar")

	# Rarity is strictly ordered by loot score, which is what the comparison uses.
	var by_rarity: Array[Dictionary] = []
	for rarity in DragonRpg.RARITIES:
		by_rarity.append({"value": 1, "rarity": str(rarity["id"])})
	for i in range(1, by_rarity.size()):
		t.check(DragonRpg.loot_score(by_rarity[i]) > DragonRpg.loot_score(by_rarity[i - 1]),
			"Rarität %s ist besser als die Stufe davor" % str(by_rarity[i]["rarity"]))

	# Luck shifts the distribution upwards, never downwards.
	var low := 0
	var high := 0
	for _i in 400:
		var a := DragonRpg.roll_loot(0.0)
		var b := DragonRpg.roll_loot(1.0)
		if DragonRpg.rarity_index(str(DragonRpg.rarity_of(a)["id"])) >= 3:
			low += 1
		if DragonRpg.rarity_index(str(DragonRpg.rarity_of(b)["id"])) >= 3:
			high += 1
	t.check(low < 80, "Ohne Glück fällt selten etwas Seltenes (%d von 400)" % low)
	t.check(high > 0, "Mit vollem Glück fällt auch Legendäres")
	t.check(high > low * 2, "Volles Glück liefert deutlich mehr Beute (%d gegen %d)" % [high, low])

	t.equal(DragonRpg.roll_loot(0.5).has("id"), true, "Ein Wurf liefert immer einen Loot-Eintrag")
	t.equal(DragonRpg.roll_loot(-1.0).has("id"), true, "Auch ein unmöglicher Wurf liefert Loot")
	t.equal(DragonRpg.roll_loot(9.0).has("id"), true, "Auch übertriebenes Glück liefert Loot")

	var crown := DragonRpg.loot_by_id("crown")
	var coin := DragonRpg.loot_by_id("coin")
	t.equal(str(DragonRpg.rarity_of(crown)["id"]), "legendary", "Die Krone ist legendär")
	t.equal(str(DragonRpg.rarity_of(coin)["id"]), "common", "Die Goldmünze ist gewöhnlich")
	t.check(DragonRpg.loot_score(crown) > DragonRpg.loot_score(coin), "Die Krone ist die bessere Beute")

	# Comparison against what the player already carries.
	t.equal(DragonRpg.compare_drop(crown, {}), "upgrade", "Ohne Vergleichsstück ist alles eine Verbesserung")
	t.equal(DragonRpg.compare_drop(crown, coin), "upgrade", "Die Krone ist besser als eine Münze")
	t.equal(DragonRpg.compare_drop(coin, crown), "downgrade", "Eine Münze nach der Krone ist schwächer")
	t.equal(DragonRpg.compare_drop(coin, coin), "same", "Gleiche Beute ist weder besser noch schlechter")
	t.equal(DragonRpg.compare_drop(coin, {}), "upgrade", "Auch eine Münze verbessert eine leere Tasche")

	t.equal(DragonRpg.luck_for({"boss": true}), 1.0, "Ein Boss bringt volles Glück")
	t.equal(DragonRpg.luck_for({"boss": false, "tier": 1}), 0.16, "Ein normaler Drache bringt etwas Glück")
	t.check(DragonRpg.luck_for({"boss": false, "tier": 5}) <= 0.4, "Normale Drachen überschreiten die Obergrenze nicht")
	t.check(DragonRpg.luck_for({"boss": false, "tier": 9}) <= 0.4, "Auch ein sehr hoher Drachen bleibt gedeckelt")
	t.suite_done()


# --- Vorschläge tragen ihre Herkunft mit ------------------------------------

func _suggestion_context() -> void:
	t.suite("Vorschlag — Herkunft")

	# Every game supplies its German name, not its technical id.
	t.equal(SuggestionContext.for_screen("arena"), "Space Shoot", "Die Arena kennt ihren Namen")
	t.equal(SuggestionContext.for_screen("tetris"), "Tetris", "Tetris kennt seinen Namen")
	t.equal(SuggestionContext.for_screen("mesh_gallery"), "Mesh-Galerie", "Die Galerie hat einen eigenen Namen")
	t.equal(SuggestionContext.for_screen("lobby"), "Lobby", "Die Lobby heißt Lobby")
	t.equal(SuggestionContext.for_screen(""), "Spiel", "Ohne Bildschirm bleibt eine neutrale Angabe")
	t.equal(SuggestionContext.for_screen("gibtesnicht"), "gibtesnicht", "Ein unbekannter Bildschirm zählt durch")
	# The label is the registry's game name, in the player's language: the code
	# says "Dragon RPG 3D" and the dashboard groups by what `for_screen` answers.
	# Comparing against the catalogue instead of a hard-coded word is what makes
	# the assertion hold in German *and* in English — `de.json` translates the
	# name, so a test that spelled out "Dragon" was asserting the English
	# catalogue while the suite runs pinned to German.
	var dragon_label := Loc.resolve(str(GameRegistry.game_by_id("dragonrpg").get("name", "")))
	t.equal(SuggestionContext.for_screen("dragonrpg"), dragon_label, "Das Drachen-RPG liefert seinen Namen")

	# …and a game owns more screens than the registry lists. The dragon flight has
	# a hangar, a run and a hatchery; Pang has a menu and the game itself.
	# `resolve()` matches a game's id *or* its screen, `for_screen()` only the
	# screen — so a sub-screen the registry does not name falls through to the raw
	# router id, and every idea from that screen is grouped in the dashboard under
	# "dragonflight_run". The raw id must never be the answer.
	for sub in ["dragonflight_run", "dragonflight_hatchery", "pang"]:
		t.check(SuggestionContext.for_screen(sub) != sub,
			"'%s' trägt nicht die rohe Router-Kennung als Herkunft" % sub)

	# A game id resolves just like a screen id.
	t.equal(SuggestionContext.resolve("tetris"), "Tetris", "Eine Spiel-ID wird aufgelöst")
	t.equal(SuggestionContext.resolve("Mesh-Galerie"), "Mesh-Galerie", "Ein freier Text bleibt stehen")
	t.equal(SuggestionContext.resolve(""), "Spiel", "Leer bedeutet neutral")
	t.check(SuggestionContext.resolve("Mesh-Galerie · Drachen").contains("Drachen"), "Ein längerer Kontext bleibt erhalten")
	t.check(SuggestionContext.resolve("x".repeat(200)).length() <= SuggestionContext.MAX_PREFIX,
		"Ein zu langer Kontext wird gekürzt")

	# The context goes in front of the text, so nobody has to type it.
	t.equal(SuggestionContext.compose("tetris", "Bitte T-Spins belohnen"),
		"Tetris: Bitte T-Spins belohnen", "Der Spielname steht vor dem Vorschlag")
	t.equal(SuggestionContext.compose("mesh_gallery", "Die Flügel sind zu eckig"),
		"Mesh-Galerie: Die Flügel sind zu eckig", "Die Galerie steht vor dem Vorschlag")
	t.equal(SuggestionContext.compose("tetris", "  Bitte Ghost-Piece  "),
		"Tetris: Bitte Ghost-Piece", "Leerraum am Textende fällt weg")
	t.equal(SuggestionContext.compose("", "Nur ein Gedanke"), "Nur ein Gedanke",
		"Ohne Kontext wird der Text nicht verändert")

	# The offline queue may not prefix the text twice.
	var once := SuggestionContext.compose("tetris", "Held sauberer zeichnen")
	t.equal(SuggestionContext.compose("tetris", once), once, "Der zweyte Durchlauf ändert nichts")
	t.check(once.begins_with("Tetris: "), "Der Vorschlag behält seine Herkunft")

	# The context must not eat into the 2000-character limit.
	var long_text := "y".repeat(1900)
	t.check(SuggestionContext.compose("lobby", long_text).length() < 2000,
		"Ein langer Vorschlag bleibt unter der Grenze")
	t.suite_done()


# --- Detailstufen -----------------------------------------------------------

func _lod_tiers() -> void:
	t.suite("Mesh — Detailstufen")

	t.equal(AssetRegistry.TIERS, ["low", "med", "high"] as Array[String], "Es gibt drei Stufen")
	# `TIER_LABELS` holds the source-language fallback; `tier_label()` is what the
	# gallery and the level card read, and it asks the catalogue first
	# (`TIER_LOC_KEY`). Comparing against `Loc.t` therefore pins the wiring — the
	# label comes from the catalogue and is translatable — without spelling a
	# word out in any one language. A German run expects "Mittel"/"Hoch", an
	# English one "Medium"/"High".
	t.equal(str(AssetRegistry.TIER_LABELS["low"]), "Low Poly", "Die niedrigste Stufe heißt nach dem Verfahren selbst")
	t.equal(AssetRegistry.tier_label("med"), Loc.t(str(AssetRegistry.TIER_LOC_KEY["med"])),
		"Die mittlere Stufe kommt aus dem Katalog")
	t.equal(AssetRegistry.tier_label("high"), Loc.t(str(AssetRegistry.TIER_LOC_KEY["high"])),
		"Die hohe Stufe kommt aus dem Katalog")
	t.check(not AssetRegistry.tier_label("med").is_empty() and not AssetRegistry.tier_label("high").is_empty(),
		"Beide Stufen haben einen Namen")
	t.check(AssetRegistry.tier_label("med") != AssetRegistry.tier_label("high"),
		"Die beiden Stufen heißen nicht gleich")
	t.check(AssetRegistry.TIER_LOC_KEY.has("med") and AssetRegistry.TIER_LOC_KEY.has("high"),
		"Beide Stufen haben einen Katalogschlüssel")
	t.equal(int(AssetRegistry.TIER_BUDGET["med"]), 1000, "Mittel zielt auf 1 000 Dreiecke")
	t.equal(int(AssetRegistry.TIER_BUDGET["high"]), 10000, "Hoch zielt auf 10 000 Dreiecke")

	t.check(AssetRegistry.tier_path_of("rpg/knight", "low") == AssetRegistry.path_of("rpg/knight"),
		"Low liegt im Mesh-Wurzelordner")
	t.check(AssetRegistry.tier_path_of("rpg/knight", "med").contains("/med/"),
		"Mittel liegt im med-Ordner")
	t.check(AssetRegistry.tier_path_of("rpg/knight", "high").contains("/high/"),
		"Hoch liegt im high-Ordner")
	t.check(AssetRegistry.tier_path_of("rpg/knight", "").ends_with("rpg/knight.glb"),
		"Eine leere Stufe zählt als Low")

	# Every mesh that really is on disk has at least the tier the games use. The
	# registry test in `test_logic.gd` reports a missing mesh; here it is only
	# about the tiers.
	var present: Array[String] = []
	for key in AssetRegistry.KEYS:
		if AssetRegistry.tier_exists(key, "low"):
			present.append(key)
	t.check(present.size() > 0, "Es gibt importierte Meshes")
	for key in present:
		t.check(AssetRegistry.tier_exists(key, "low"), "Low-Fassung von '%s' ist nutzbar" % key)
	t.equal(AssetRegistry.tiers_missing("low").size(), 0, "Keine Low-Fassung fehlt")
	t.equal(AssetRegistry.best_available("rpg/knight", "low"), "low", "Ohne Generator bleibt Low")

	# The measured triangle counts are present and inside the budget.
	var counts := AssetRegistry.tri_counts()
	t.check(counts.size() > 0, "Die Dreieckzahlen wurden gemessen")
	var checked := 0
	var med_low := 0
	var high_low := 0
	for key in AssetRegistry.KEYS:
		var low := AssetRegistry.tri_count(key, "low")
		var med := AssetRegistry.tri_count(key, "med")
		var high := AssetRegistry.tri_count(key, "high")
		if low < 0 or med < 0 or high < 0:
			continue
		checked += 1
		if med < low:
			med_low += 1
		if high < med:
			high_low += 1
	t.check(checked > 0, "Mindestens ein Mesh hat gemessene Zahlen")
	t.equal(med_low, 0, "Mittel ist nie grober als Low")
	t.equal(high_low, 0, "Hoch ist nie grober als Mittel")
	t.check(AssetRegistry.tri_text("rpg/knight", "low") != "—", "Die Zahl wird als Text geliefert")
	t.equal(AssetRegistry.tri_text("gibtesnicht", "low"), "—", "Unbekanntes ergibt einen Gedankenstrich")
	t.suite_done()


# --- Galerie: Anordnung -----------------------------------------------------

func _gallery_layout() -> void:
	t.suite("Mesh-Galerie — Halle")

	t.equal(MeshGallery.key_at(["a", "b"], 0), "a", "Der erste Sockel trägt das erste Mesh")
	t.equal(MeshGallery.key_at(["a", "b"], 1), "b", "Der zweite Sockel trägt das zweite Mesh")
	t.equal(MeshGallery.key_at(["a"], 5), "", "Hinter dem Ende ist nichts")
	t.equal(MeshGallery.key_at([], 0), "", "Eine leere Sammlung hat nichts")

	# Two rows on either side, and they alternate — a neighbour is never on the
	# same side at the same depth.
	t.equal(MeshGallery.side_of(0), -1, "Der erste Sockel steht links")
	t.equal(MeshGallery.side_of(1), 1, "Der zweite steht rechts")
	t.equal(MeshGallery.side_of(2), -1, "Der dritte wieder links")
	for i in 24:
		var position := MeshGallery.slot_position(i)
		var inner := (i % MeshGallery.PER_STEP) < 2
		var expected_x: float = MeshGallery.INNER_ROW_OFFSET if inner else MeshGallery.OUTER_ROW_OFFSET
		t.almost(absf(position.x), expected_x, 0.001,
			"Sockel %d steht in einer Reihe" % i)
		t.equal(int(signf(position.x)), MeshGallery.side_of(i),
			"Sockel %d steht auf seiner Seite" % i)
		# Four pedestals share a depth — two per side — and the next set of four
		# stands one spacing further down the hall. `slot_position` is
		# `index / 4`, so the set of four is the invariant and the step is
		# between sets.
		if i % MeshGallery.PER_STEP != 0:
			t.almost(MeshGallery.slot_position(i - 1).z, position.z, 0.001,
				"Die Sockel %d und %d stehen auf gleicher Höhe" % [i - 1, i])
		if i >= MeshGallery.PER_STEP:
			t.almost(position.z,
				MeshGallery.slot_position(i - MeshGallery.PER_STEP).z - MeshGallery.SLOT_SPACING, 0.001,
				"Sockel %d steht eine Reihe weiter" % i)
		for j in range(i):
			t.check(position.distance_to(MeshGallery.slot_position(j)) > 2.0,
				"Sockel %d und %d überlappen nicht" % [i, j])

	# "Which mesh is in front of me" hangs on distance, not on list order. The
	# nave is `LANE_MID` from either inner row and `NEAR_DISTANCE` is wider than
	# that, so a player who walks down the middle already looks at a mesh — and
	# the aisle has to reach as far, or the outer row could never be the answer.
	var keys: Array[String] = []
	for i in 12:
		keys.append("k%d" % i)
	t.equal(MeshGallery.nearest_slot(keys, MeshGallery.slot_position(0)), 0,
		"Am Sockel 0 ist Sockel 0 der nächste")
	t.equal(MeshGallery.nearest_slot(keys, MeshGallery.slot_position(5)), 5,
		"Am Sockel 5 ist Sockel 5 der nächste")
	# Every pedestal has to be reachable, each from the band it stands in —
	# otherwise the hall shows meshes the player can neither read nor write
	# about, and no distance rule can repair it: the nearer row wins from
	# everywhere the player is allowed to stand.
	for i in 12:
		var home := MeshGallery.slot_position(i)
		var outer := (i % MeshGallery.PER_STEP) >= 2
		var reach: float = MeshGallery.LANE_SIDE if outer else MeshGallery.LANE_MID
		var stand := Vector3(float(MeshGallery.side_of(i)) * reach, 0.0, home.z)
		t.equal(MeshGallery.nearest_slot(keys, stand), i,
			"Vor Sockel %d steht Sockel %d im Vordergrund" % [i, i])

	t.equal(MeshGallery.nearest_slot(keys, Vector3(0, 0, MeshGallery.slot_position(6).z)), 4,
		"In der Mitte zählt der innere Sockel auf gleicher Höhe")
	t.equal(MeshGallery.nearest_slot(keys, Vector3(0, 0, MeshGallery.FIRST_SLOT_Z + 20.0)), -1,
		"Weit vor dem ersten Sockel ist keiner nah genug")
	t.equal(MeshGallery.nearest_slot([], MeshGallery.slot_position(0)), -1,
		"Ohne Meshes gibt es keinen Sockel")

	# The walkable floor: a nave, the band the inner pedestals close off, and an
	# aisle between the rows. The aisle runs the whole length of the hall, and
	# the gap between two depths is the one place the player gets across.
	t.almost(MeshGallery.depth_gap(MeshGallery.slot_position(0).z), 0.0, 0.001,
		"Auf einer Reihe ist kein Abstand zur Reihe")
	t.almost(MeshGallery.depth_gap(MeshGallery.slot_position(0).z - MeshGallery.SLOT_SPACING * 0.5),
		MeshGallery.SLOT_SPACING * 0.5, 0.001, "Zwischen zwei Reihen ist halber Abstand")
	t.check(MeshGallery.depth_gap(MeshGallery.FIRST_SLOT_Z + 4.0) > MeshGallery.CLEAR,
		"Vor der ersten Reihe ist der ganze Boden frei")
	t.check(MeshGallery.LANE_MID < MeshGallery.BAND_EDGE
		and MeshGallery.BAND_EDGE < MeshGallery.LANE_SIDE,
		"Schiff, gesperrtes Band und Gang liegen auseinander")
	# Walking the nave: the inner row pushes back, both sides, at its own depth.
	t.almost(MeshGallery.lane_x(3.0, MeshGallery.slot_position(0).z, 0.0),
		MeshGallery.LANE_MID, 0.001, "Das Schiff endet an der inneren Reihe")
	t.almost(MeshGallery.lane_x(-3.0, MeshGallery.slot_position(0).z, 0.0),
		-MeshGallery.LANE_MID, 0.001, "Das Schiff endet auch links")
	# A player caught in the band is pushed back to the side they came from
	# rather than across the hall.
	t.almost(MeshGallery.lane_x(2.0, MeshGallery.slot_position(0).z, MeshGallery.BAND_EDGE),
		MeshGallery.BAND_EDGE, 0.001, "Aus dem Gang geht es nicht nach innen")
	t.almost(MeshGallery.lane_x(-2.0, MeshGallery.slot_position(0).z, -MeshGallery.BAND_EDGE),
		-MeshGallery.BAND_EDGE, 0.001, "Aus dem linken Gang auch nicht")
	# The aisle is continuous: at every depth of the hall the player stands in it
	# wherever they want, which is what makes the outer row reachable at all.
	for i in 24:
		var z := MeshGallery.slot_position(i).z
		t.almost(MeshGallery.lane_x(MeshGallery.LANE_SIDE, z, MeshGallery.LANE_SIDE),
			MeshGallery.LANE_SIDE, 0.001, "Der Gang geht bei Sockel %d durch" % i)
		t.almost(MeshGallery.lane_x(-MeshGallery.LANE_SIDE, z, -MeshGallery.LANE_SIDE),
			-MeshGallery.LANE_SIDE, 0.001, "Der linke Gang auch bei %d" % i)
	# And nowhere along the hall does the resolution leave the knight inside a
	# pedestal's gap, while the aisle stays open the whole way and the gap
	# between two depths lets the player across at all.
	var blocked := 0
	var crossed := false
	var samples := int(-MeshGallery.end_z(40) * 2.0)
	for s in samples:
		var z := -float(s) * 0.5
		for side: float in [-1.0, 1.0]:
			var x := MeshGallery.lane_x(side * MeshGallery.LANE_SIDE, z, side * MeshGallery.LANE_SIDE)
			if absf(x) < MeshGallery.BAND_EDGE:
				blocked += 1
			for j in 40:
				var pedestal := MeshGallery.slot_position(j)
				# The limit is the clearance itself and the positions come out of
				# a `Vector3`, whose components are single precision: the edge of
				# the aisle is the gap minus a rounding error, not above it.
				if Vector2(x, z).distance_to(Vector2(pedestal.x, pedestal.z)) < MeshGallery.CLEAR - 0.001:
					blocked += 1
		if absf(MeshGallery.lane_x(MeshGallery.LANE_SIDE, z, 0.0)) >= MeshGallery.BAND_EDGE:
			crossed = true
	t.equal(blocked, 0, "Der Spieler bleibt in der ganzen Halle im Abstand der Sockel")
	t.check(crossed, "Zwischen zwei Reihen kommt der Spieler in den Gang")

	# The hall reaches exactly as far as its last mesh, and the player may not
	# walk past it or through the rows.
	t.almost(MeshGallery.end_z(0), -MeshGallery.FIRST_SLOT_Z, 0.001,
		"Eine leere Halle hat kein weiteres Ende")
	t.almost(MeshGallery.end_z(1), -MeshGallery.FIRST_SLOT_Z, 0.001,
		"Ein einzelnes Mesh steht am Eingang")
	t.almost(MeshGallery.end_z(12), MeshGallery.slot_position(11).z, 0.001,
		"Das Ende der Halle ist der letzte Sockel")
	var walk := MeshGallery.walk_bounds(12)
	t.check(walk.x < MeshGallery.slot_position(11).z, "Der Spieler kommt nicht hinter dem letzten Mesh vorbei")
	t.check(walk.y > MeshGallery.slot_position(0).z, "Hinter dem ersten Mesh ist noch Platz")
	t.check(MeshGallery.LANE_MID < MeshGallery.INNER_ROW_OFFSET - MeshGallery.PEDESTAL_RADIUS,
		"Das Schiff bleibt neben den Sockeln")
	t.check(MeshGallery.LANE_SIDE < MeshGallery.OUTER_ROW_OFFSET - MeshGallery.PEDESTAL_RADIUS,
		"Der Gang bleibt neben den Sockeln")

	# The point of the hall: no collection, no page, no ring — every mesh of the
	# registry has a pedestal of its own.
	t.almost(MeshGallery.end_z(AssetRegistry.KEYS.size()),
		MeshGallery.slot_position(AssetRegistry.KEYS.size() - 1).z, 0.001,
		"Das letzte Registry-Mesh hat einen Sockel")
	t.check(AssetRegistry.KEYS.size() > 12,
		"Die Halle trägt mehr Meshes als ein Ring")

	# The suggestion names the mesh the player stands in front of, so nobody has
	# to spell out `rpg/dragon_lord` by hand.
	t.equal(MeshGallery.context(), Loc.t("gallery.context"),
		"Die Galerie nennt sich selbst als Herkunft")
	var named := MeshGallery.context("rpg/dragon_lord")
	t.check(named.contains(Loc.resolve(AssetRegistry.display_name("rpg/dragon_lord"))),
		"Der Vorschlag nennt das Mesh davor")
	t.check(named.contains(MeshGallery.context()), "Der Name steht hinter der Galerie")

	t.check(MeshGallery.tier_caption("low").contains("Low Poly"), "Die Low-Stufe wird erklärt")
	t.check(MeshGallery.tier_caption("med").contains("1.000"), "Das Ziel der mittleren Stufe steht dabei")
	t.check(MeshGallery.tier_caption("high").contains("10.000"), "Das Ziel der hohen Stufe steht dabei")
	t.suite_done()
