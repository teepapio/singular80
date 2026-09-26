class_name TestCrystal3d
extends RefCounted
## Rule and screen tests for "Crystal Jumper 3D" and its two themed editions.
##
## The tower itself is covered by the "Crystal Tower" suite in `test_logic.gd`.
## This file owns what the crystal3d scope added afterwards: the Flusskette, the
## chain of quick pickups that pays more the faster the player climbs.
##
## The screen suite loads `crystal_jumper_screen.gd` **by path** rather than as
## `CrystalJumperScreen`: a static reference would pull the screen into the
## compile chain of `run_tests.gd`, which runs before the engine registers the
## autoloads, and every autoload inside the screen would fail to resolve
## (`test_screens.gd` and `test_metro_screens.gd` avoid the same trap the same way).

var t: TestKit
## Autoloads are not registered in `--script` mode, so they are fetched by path.
var _router: Node
var _screen_script: GDScript


## Entry point used by `run_tests.gd`.
func run(kit: TestKit, tree: SceneTree = null) -> void:
	t = kit
	_suite(_flow_chain)
	_suite(_flow_scoring)
	if tree == null:
		return
	_router = tree.root.get_node_or_null("/root/Router")
	_screen_script = load("res://src/game/crystal3d/crystal_jumper_screen.gd")
	if _router == null or _screen_script == null:
		t.suite("Crystal Tower — Screen")
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


# --- Punkte -----------------------------------------------------------------

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

	# Der Startpunkt sammelt beim Einstieg einen Kristall ein, und die Engine
	# tickt weiter, während die Suite wartet. Für die Kettenprüfungen wird der
	# Lauf deshalb auf null gesetzt, sonst hingen die Erwartungen am Zeitpunkt.
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
