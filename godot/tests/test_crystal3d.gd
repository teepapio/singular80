class_name TestCrystal3d
extends RefCounted
## Rule and screen tests for "Crystal Jumper 3D". The tower itself is covered by
## the "Crystal Tower" suite in `test_logic.gd`; this file owns the *Flusskette*,
## the chain of quick pickups that pays more the faster the player climbs.
##
## The screen is loaded **by path** rather than as `CrystalJumperScreen`: a static
## reference pulls it into the compile chain of `run_tests.gd`, which runs before
## the engine registers the autoloads.

var t: TestKit
## Autoloads are not registered in `--script` mode, so they are fetched by path.
var _router: Node
var _screen_script: GDScript


## Entry point used by `run_tests.gd`.
func run(kit: TestKit, tree: SceneTree = null) -> void:
	t = kit
	_suite(_flow_chain)
	_suite(_flow_scoring)
	_suite(_forge_bag)
	if tree == null:
		return
	# Before the jumper's own screen suite: that one bails out when
	# `crystal_jumper_screen.gd` cannot be loaded, and the forge is a separate
	# file — a parse error in one screen must not take the other's checks with it.
	await _forge_screen(tree)
	_router = tree.root.get_node_or_null("/root/Router")
	_screen_script = load("res://src/game/crystal3d/crystal_jumper_screen.gd")
	if _router == null or _screen_script == null:
		# The real screen suite below is called "Crystal Tower — Screen"; this early
		# exit reports the same thing from the same place and needs a name of its
		# own, or a red run names two suites for one failure.
		t.suite("Crystal Tower — Screen fehlt")
		t.check(false, "Der Crystal-Screen laesst sich oeffnen")
		t.suite_done()
		t.close_suite()
		return
	await _screen_flow(tree)
	t.close_suite()


## Runs one suite and fails it if it returned before its own `t.suite_done()`,
## which is what a GDScript runtime error does.
func _suite(body: Callable) -> void:
	body.call()
	t.close_suite()


# --- Flusskette -------------------------------------------------------------

func _flow_chain() -> void:
	t.suite("Crystal Tower — Flusskette")

	# The first pickup always starts a chain; `last_ms < 0` means "none yet".
	t.equal(CrystalTower.next_flow(0.0, -1.0, 0), 1, "Der erste Fund startet die Kette")
	t.equal(CrystalTower.next_flow(1000.0, -1.0, 0), 1, "Ohne Vorlauf gibt es keine Kette")

	# Inside the window the chain grows, one step per pickup.
	t.equal(CrystalTower.next_flow(1000.0, 0.0, 1), 2, "Zweiter Fund verlängert")
	t.equal(CrystalTower.next_flow(2500.0, 1000.0, 4), 5, "Fünfter Fund in der Kette")
	t.almost(CrystalTower.FLOW_WINDOW_MS, 3000.0, 0.001, "Das Fenster beträgt drei Sekunden")
	t.equal(CrystalTower.next_flow(4000.0, 1000.0, 4), 5, "Genau am Fensterende zählt die Kette noch")
	t.equal(CrystalTower.next_flow(4001.0, 1000.0, 4), 1, "Nach drei Sekunden Pause neu beginnen")
	t.equal(CrystalTower.next_flow(6000.0, 1000.0, 4), 1, "Auch eine lange Pause beginnt neu")
	t.equal(CrystalTower.next_flow(4000.0, 1000.0, 0), 1, "Ohne Kette gibt es nur den ersten Fund")

	# The chain is capped, but keeps paying at the cap.
	var capped := CrystalTower.next_flow(1000.0, 0.0, CrystalTower.MAX_FLOW)
	t.equal(capped, CrystalTower.MAX_FLOW, "Die Kette endet bei %d" % CrystalTower.MAX_FLOW)
	t.equal(CrystalTower.flow_multiplier(capped), CrystalTower.MAX_FLOW, "Der Multiplikator ist die Kette")
	t.check(CrystalTower.flow_step_bonus(capped, 5) == CrystalTower.flow_step_bonus(CrystalTower.MAX_FLOW, 5),
		"Am Cap zahlt die Kette weiter")

	# The bar: full right after a pickup, half at half the window, empty after.
	t.almost(CrystalTower.flow_ratio(1000.0, 1000.0, 3), 1.0, 0.001, "Voller Balken direkt nach dem Fund")
	t.almost(CrystalTower.flow_ratio(2500.0, 1000.0, 3), 0.5, 0.001, "Halb leer nach der halben Zeit")
	t.almost(CrystalTower.flow_ratio(4000.0, 1000.0, 3), 0.0, 0.001, "Leer, wenn das Fenster abgelaufen ist")
	t.almost(CrystalTower.flow_left_ms(1500.0, 1000.0, 3), 2500.0, 0.001, "Restzeit der Kette")
	t.equal(CrystalTower.flow_left_ms(4000.0, 1000.0, 3), 0.0, "Keine negative Restzeit")
	t.equal(CrystalTower.flow_left_ms(0.0, -1.0, 0), 0.0, "Ohne Kette ist der Balken leer")
	t.equal(CrystalTower.flow_left_ms(1000.0, 1000.0, 1), 0.0, "Ein einzelner Fund zeigt keinen Balken")
	t.almost(CrystalTower.flow_ratio(0.0, -1.0, 0), 0.0, 0.001, "Ohne Kette kein Füllstand")
	t.check(CrystalTower.flow_ratio(1000.0, 1000.0, 3) >= 0.0 and CrystalTower.flow_ratio(1000.0, 1000.0, 3) <= 1.0,
		"Der Füllstand bleibt zwischen 0 und 1")

	# Names: one pickup is not a flow, a long chain gets its title.
	t.equal(CrystalTower.flow_title(1), "", "Ein einzelner Fund hat keinen Titel")
	t.equal(CrystalTower.format_flow(0), "", "Ohne Kette bleibt die Anzeige leer")
	t.equal(CrystalTower.format_flow(1), "", "Ein einzelner Fund bleibt stumm")
	t.equal(CrystalTower.format_flow(2), "×2 Doppel", "Kette 2 zeigt Name und Faktor")
	t.check(CrystalTower.flow_title(CrystalTower.MAX_FLOW) == "Singular", "Die längste Kette trägt den Namen des Spiels")
	t.check(CrystalTower.flow_title(999) == "Singular", "Überlange Ketten werden geklemmt")
	t.suite_done()


# --- flow scoring ------------------------------------------------------------

func _flow_scoring() -> void:
	t.suite("Crystal Tower — Flusspunkte")

	t.equal(CrystalTower.tier_value(1), 1, "Stufe 1 zählt 1 Punkt")
	t.equal(CrystalTower.tier_value(5), 81, "Stufe 5 zählt 81 Punkte")
	t.equal(CrystalTower.tier_value(99), 81, "Stufen werden geklemmt")

	# Step one pays nothing extra, every later step pays the full value again.
	t.equal(CrystalTower.flow_step_bonus(1, 1), 0, "Der erste Fund zahlt keinen Bonus")
	t.equal(CrystalTower.flow_step_bonus(2, 1), 1, "Faktor 2 zahlt den Stufenwert einmal")
	t.equal(CrystalTower.flow_step_bonus(4, 3), 27, "Faktor 4 zahlt den Stufenwert dreimal")
	t.equal(CrystalTower.flow_step_bonus(0, 5), 0, "Ohne Kette gibt es keinen Flussbonus")

	# A full chain of five tier-3 crystals: 0 + 9 + 18 + 27 + 36.
	var counts := [0, 0, 0, 0, 0]
	var bonus := 0
	for step in range(1, 6):
		counts[2] = int(counts[2]) + 1
		bonus += CrystalTower.flow_step_bonus(step, 3)
	t.equal(bonus, 90, "Eine Kette von fünf zahlt 0+9+18+27+36")
	t.equal(CrystalTower.run_score(counts, bonus), 45 + 90, "Punkte sind Inventar plus Fluss")
	t.equal(CrystalTower.run_score(counts, 0), 45, "Ohne Fluss zählt nur das Inventar")
	t.equal(CrystalTower.run_score([0, 0, 0, 0, 0], 0), 0, "Ein leerer Lauf ist 0 Punkte")
	t.equal(CrystalTower.run_score([1, 0, 0, 0, 0], -5), 1, "Ein negativer Bonus wird nicht abgezogen")

	# The flow is worth real points next to the inventory, which is the point.
	t.equal(CrystalTower.flow_step_bonus(5, 2), 4 * CrystalTower.tier_value(2), "Faktor 5 zahlt den Wert viermal")
	var chain_bonus := 0
	for step in range(1, CrystalTower.MAX_FLOW + 1):
		chain_bonus += CrystalTower.flow_step_bonus(step, 1)
	t.equal(chain_bonus, 45, "Eine volle Kette zahlt 0+1+…+9 Splitter")
	var long_bonus := 0
	for step in range(1, 13):
		long_bonus += CrystalTower.flow_step_bonus(step, 1)
	t.equal(long_bonus, 63, "Über das Cap hinaus zahlt jeder Fund weiter mit ×10")
	t.check(CrystalTower.run_score([12, 0, 0, 0, 0], long_bonus) > CrystalTower.run_score([12, 0, 0, 0, 0], 0) * 4,
		"Eine einzige saubere Kette vervielfacht das Ergebnis desselben Laufs")
	t.suite_done()


# --- Forge ------------------------------------------------------------------

## The bag and the merge plan, with no scene tree: a `--script` run has no
## autoloads, so `CrystalForge` has to answer with an empty bag instead of
## throwing, and every number below is computed, never stored.
func _forge_bag() -> void:
	t.suite("Crystal Forge — Bag")

	# One number per tier, under the theme's own prefix, so the three editions
	# never share a bag.
	t.equal(CrystalForge.bag_key("classic", 1), "singular80_crystal3d_bag1", "Der Beutel liegt unter dem Theme-Praefix")
	t.equal(CrystalForge.bag_key("christmas", 5), "singular80_crystal3d_christmas_bag5", "Weihnachten hat einen eigenen Beutel")
	t.equal(CrystalForge.bag_key("halloween", 3), "singular80_crystal3d_halloween_bag3", "Halloween hat einen eigenen Beutel")
	t.equal(CrystalForge.bag_key("gibtsnicht", 1), "singular80_crystal3d_bag1", "Ein unbekanntes Thema faellt auf classic zurueck")
	# The jumper writes its equipped tier under this key; a second spelling would
	# be two answers to one question.
	t.equal(CrystalForge.equip_key("classic"), "singular80_crystal3d_equipped", "Der ausgeruestete Kristall teilt den Schluessel mit dem Turm")
	t.equal(CrystalForge.climb_screen("christmas"), "crystal3d_christmas", "Zurueck geht es in dasselbe Thema")
	t.equal(CrystalForge.climb_screen("gibtsnicht"), "crystal3d", "Ein unbekanntes Thema klettert im klassischen Turm")

	# A bag is always five numbers long, and a bad entry reads as "none".
	t.equal(CrystalForge.empty().size(), CrystalTower.MAX_CRYSTAL_TIER, "Der Beutel hat eine Zahl je Stufe")
	t.equal(CrystalForge.total(CrystalForge.empty()), 0, "Ein neuer Beutel ist leer")
	t.equal(CrystalForge.count_of([1, -2, 3], 2), 0, "Eine negative Zahl zaehlt nicht")
	t.equal(CrystalForge.count_of([1, 2], 9), 0, "Eine Stufe ohne Eintrag ist leer")
	t.equal(CrystalForge.normalize([7]).size(), CrystalTower.MAX_CRYSTAL_TIER, "Ein kurzes Array wird auf fuenf Stufen aufgefuellt")
	t.equal(CrystalForge.count_of(CrystalForge.normalize([7]), 1), 7, "Der erste Eintrag ueberlebt das Auffuellen")

	# The same price per tier the run score uses, so the bag and the tower agree.
	t.equal(CrystalForge.value([0, 0, 1, 0, 0]), CrystalTower.tier_value(3), "Der Beutel zaehlt nach Stufenvwert")
	t.equal(CrystalForge.value([1, 1, 1, 1, 1]), 1 + 3 + 9 + 27 + 81, "Ein Beutel mit je einer Kristalle")

	# Three of a kind, from the lowest tier up, repeatedly.
	t.equal(CrystalForge.mergeable([3, 0, 0, 0, 0]), 1, "Drei gleiche ergeben eine Merge")
	t.equal(CrystalForge.mergeable([2, 0, 0, 0, 0]), 0, "Zwei gleiche ergeben keine Merge")
	t.equal(CrystalForge.mergeable([2, 2, 2, 2, 2]), 0, "Je zwei gleiche ergeben nichts")
	var plan := CrystalForge.merge([9, 3, 0, 0, 0])
	t.equal(int(plan["merges"]), 5, "Neun Splitter plus drei Kristalle ergeben fuenf Merges")
	t.equal((plan["counts"] as Array)[0], 0, "Die niedrigste Stufe ist leer")
	t.equal((plan["counts"] as Array)[1], 0, "Auch die zweite Stufe ist leer")
	t.equal((plan["counts"] as Array)[2], 2, "Was bleibt, sind zwei Juwele")
	t.equal((plan["steps"] as Array).size(), 5, "Jede Merge wird einzeln animiert")

	# A climb hands its crystals over: they add up, they do not replace.
	t.equal(CrystalForge.deposit("classic", [3, 1, 0, 0, 0])[0], 3, "Der Lauf legt seine Kristalle in den Beutel")
	t.equal(CrystalForge.deposit("classic", [3, 1, 0, 0, 0])[1], 1, "Der Beutel zaehlt nach Stufe")
	t.equal(CrystalForge.total(CrystalForge.deposit("classic", [3, 1, 0, 0, 0])), 4, "Vier Kristalle im Beutel")
	# Nothing is written to the player file under `--script`.
	t.check(not CrystalForge.persist, "Ein Testlauf schreibt die Spielerdatei nicht")

	# The button that makes the forge findable at all: the top bar of every
	# Crystal Jumper screen carries it, so the merge is one tap away instead of
	# waiting for the summit panel at the end of a run.
	for screen_id in ["crystal3d", "crystal3d_christmas", "crystal3d_halloween"]:
		var companions := GameRegistry.companions_of(screen_id)
		t.equal(companions.size(), 1, "'%s' hat genau einen zweiten Knopf" % screen_id)
		if companions.size() == 1:
			t.equal(str((companions[0] as Dictionary)["screen"]), "crystal_forge", "'%s' oeffnet die Schmiede" % screen_id)
			t.check(not (companions[0] as Dictionary)["payload"].is_empty(), "'%s' sagt der Schmiede, welches Thema" % screen_id)
	t.equal(GameRegistry.companions_of("tetris").size(), 0, "Ein Spiel ohne Schmiede behaelt seine Leiste")
	t.equal(GameRegistry.companions_of("crystal_forge").size(), 0, "Die Schmiede verlinkt sich nicht auf sich selbst")
	t.suite_done()


## The forge in a real scene tree: it opens from the payload it is given, shows
## one row per tier and plays the whole cascade through.
func _forge_screen(tree: SceneTree) -> void:
	t.suite("Crystal Forge — Screen")
	var router := tree.root.get_node_or_null("/root/Router")
	if router == null:
		t.check(false, "Der Router laeuft")
		return
	await t.goto(router, tree, "crystal_forge", {"theme": "christmas", "back": "crystal3d_christmas"})
	var screen = router.current_screen
	t.check(screen != null, "Die Schmiede wird geoeffnet")
	if screen == null:
		return
	t.check(screen.get_script() == load("res://src/game/crystal3d/crystal_forge_screen.gd"), "Es ist die Schmiede")
	t.equal(screen.theme_id, "christmas", "Das Payload bestimmt das Thema")
	t.equal(screen.climb_screen, "crystal3d_christmas", "Und wohin der Kletter-Knopf zurueckgeht")
	t.check(screen._bag_column != null and screen._merge_button != null, "Beutel und Merge-Knopf sind gebaut")
	# Five tier rows plus the "inventory empty" line.
	t.equal(screen._bag_column.get_child_count(), CrystalTower.MAX_CRYSTAL_TIER + 1, "Eine Zeile je Stufe")
	t.check(screen._empty_label.visible, "Ein leerer Beutel sagt es")
	t.check(screen._merge_button.disabled, "Ohne drei gleiche bleibt der Merge-Knopf aus")
	t.equal(screen.actors.size(), CrystalForge.MERGE_RULE, "Die drei Merge-Akteure liegen bereit")

	# Three of a tier: the button wakes up and names what it will produce.
	screen.counts = [3, 0, 0, 0, 0]
	screen._refresh()
	t.check(not screen._merge_button.disabled, "Drei gleiche wecken den Merge-Knopf")
	t.check(screen._merge_button.text.contains("1"), "Der Knopf nennt die Anzahl der Merges")
	t.check(not screen._empty_label.visible, "Der Beutel ist nicht mehr leer")
	t.equal(screen.bag_root.get_child_count(), 3, "Die drei Kristalle stehen auf dem Amboss")
	t.equal(CrystalForge.mergeable(screen.counts), 1, "Die Logik sieht dieselbe Merge")

	# The cascade: three leave, one of the next tier arrives, and the scene comes
	# back to rest with the bag written.
	screen.start_merge()
	t.check(screen.merge_phase != 0, "Die Merge laeuft")
	t.equal(screen.counts[0], 0, "Die drei Splitter sind weg")
	t.equal(screen.counts[1], 1, "Ein Kristall ist dafuer da")
	screen.start_merge()
	t.check(screen.merge_phase != 0, "Ein zweiter Tastendruck unterbricht nichts, er wird nur abgelehnt")
	for _i in 60:
		screen._update_merge(0.05)
	t.equal(screen.merge_phase, 0, "Die Animation kommt zur Ruhe")
	t.check(screen.burst_ring == null or not screen.burst_ring.visible, "Der Blitzring ist wieder aus")
	t.check(screen.bag_root.get_child_count() >= 1, "Das Ergebnis steht auf dem Amboss")
	for actor in screen.actors:
		t.check(not actor.visible, "Die Akteure verschwinden nach der Merge")
	t.check(screen._merge_button.disabled, "Nach der Merge ist wieder nichts zu mergen")
	t.equal(screen._points_label.text, Loc.f("Points: %d", [CrystalTower.tier_value(2)]), "Die Punkte zeigen das Ergebnis")

	# What a finished climb hands over is what the forge shows. The bag is fed with
	# the crystals as they were found — before any merge at the summit — so the
	# forge and the summit are two places that hold crystals, not two halves of
	# one number.
	screen.counts = CrystalForge.deposit("christmas", [3, 1, 0, 0, 0])
	screen._refresh()
	t.check(not screen._empty_label.visible, "Der Beutel zeigt, was ein Lauf abgelegt hat")
	t.equal(screen._points_label.text, Loc.f("Points: %d", [3 * CrystalTower.tier_value(1) + CrystalTower.tier_value(2)]), "Die Punkte zaehlen den Beutel nach Stufenvwert")
	t.check(not screen._merge_button.disabled, "Drei Splitter im Beutel lassen sich schmelzen")

	# A bag that cannot merge anything says so and leaves the button alone.
	screen.counts = [1, 1, 0, 0, 0]
	screen._refresh()
	t.check(screen._merge_button.disabled, "Zwei verschiedene Stufen ergeben keine Merge")
	t.suite_done()


# --- Screen -----------------------------------------------------------------

## The real screen in a real scene tree: the HUD has to exist, a pickup has to
## pay out, and the bar has to run out again.
func _screen_flow(tree: SceneTree) -> void:
	t.suite("Crystal Tower — Screen")
	await t.goto(_router, tree, "crystal3d")
	var screen = _router.current_screen
	t.check(screen != null, "Der Crystal-Screen wird geoeffnet")
	if screen == null:
		return
	t.check(screen.get_script() == _screen_script, "Es ist der Crystal-Screen")
	t.check(screen._points_label != null and screen._chain_bar != null and screen._chain_label != null,
		"Ketten- und Punkteanzeige sind gebaut")
	t.equal(screen._label_pool.size(), 8, "Acht schwebende Texte liegen bereit")

	# The spawn point already collects a crystal on entry, and the engine keeps
	# ticking while the suite waits, so the run is zeroed first — otherwise every
	# expectation would hang on the moment it happened to be checked.
	_reset_run(screen)
	screen._update_flow(0.016)
	t.equal(screen.flow_chain, 0, "Zu Beginn läuft keine Kette")
	t.equal(screen._chain_label.text, "", "Zu Beginn steht kein Kettenname im HUD")
	t.equal(screen._chain_bar.value, 0.0, "Der Kettenbalken ist zu Beginn leer")
	t.equal(screen._points_label.text, "0", "Zu Beginn stehen 0 Punkte im HUD")

	# Two quick pickups: the second one pays and shows itself.
	screen._pickup_flow(Vector3(0.0, 2.0, 0.0), 1)
	t.equal(screen.flow_chain, 1, "Der erste Fund startet die Kette")
	t.equal(screen.flow_bonus, 0, "Der erste Fund zahlt noch nichts")
	t.equal(screen._floating.size(), 0, "Ein einzelner Fund bekommt keinen schwebenden Text")
	screen._pickup_flow(Vector3(0.0, 2.0, 0.0), 3)
	t.equal(screen.flow_chain, 2, "Der zweite Fund verlaengert die Kette")
	t.equal(screen.flow_bonus, 9, "Kette 2 auf Stufe 3 zahlt 9 Punkte")
	t.equal(screen._floating.size(), 1, "Der Bonus erscheint als schwebender Text")
	screen._update_flow(0.016)
	t.equal(screen._chain_label.text, "×2 Doppel", "Das HUD zeigt Kette und Namen")
	t.equal(screen._points_label.text, "9", "Das HUD zeigt den Punktestand")
	t.check(screen._chain_bar.value > 0.9, "Der Balken ist frisch gefuellt")

	# Half the window gone: the bar is half empty and the chain still lives.
	screen.flow_last_ms -= CrystalTower.FLOW_WINDOW_MS * 0.5
	screen._update_flow(0.016)
	t.equal(screen.flow_chain, 2, "Die Kette haelt die halbe Zeit durch")
	t.almost(screen._chain_bar.value, 0.5, 0.05, "Der Balken ist halb geleert")
	t.almost(CrystalTower.flow_ratio(screen.elapsed * 1000.0, screen.flow_last_ms, screen.flow_chain),
		screen._chain_bar.value, 0.001, "Der Balken folgt der Logik")

	# Past the window the chain is gone, the paid-out bonus stays.
	screen.flow_last_ms -= CrystalTower.FLOW_WINDOW_MS
	screen._update_flow(0.016)
	t.equal(screen.flow_chain, 0, "Nach dem Fenster ist die Kette vorbei")
	t.equal(screen._chain_label.text, "", "Der Kettenname verschwindet")
	t.equal(screen._chain_bar.value, 0.0, "Der Balken ist wieder leer")
	t.equal(screen.flow_bonus, 9, "Der ausgezahlte Bonus bleibt")
	t.equal(screen._points_label.text, "9", "Die Punkte bleiben stehen")
	t.equal(screen.run_best_flow, 2, "Der Lauf merkt sich seine beste Kette")

	# The floating text ages out instead of piling up forever.
	for _i in 6:
		screen._update_floating(0.4)
	t.equal(screen._floating.size(), 0, "Schwebende Texte verschwinden wieder")
	t.check(screen._label_pool.size() == 8, "Der Pool waechst nicht")
	t.suite_done()


## Puts the run back to its first second: no crystals, no chain, no bonus. The
## player spawns inside a crystal's reach, so a screen suite that wants exact
## numbers has to take the world out of the equation first.
func _reset_run(screen: Node) -> void:
	for i in CrystalTower.MAX_CRYSTAL_TIER:
		screen.counts[i] = 0
	screen.flow_bonus = 0
	screen.flow_chain = 0
	screen.flow_last_ms = -1.0
	screen.run_best_flow = 0
	screen._score_shown = -1
	screen._flow_shown = -1
