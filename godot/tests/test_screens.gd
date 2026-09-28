class_name TestScreens
extends RefCounted
## Integration tests: every screen must build, run and clean up without errors.
## They run inside a real (headless) scene tree, so the autoloads, the router and
## the actual game scripts are exercised, not just the pure logic.

var t: TestKit
var tree: SceneTree
## Screen ids a scoped run should open; empty means "all of them".
var _screen_filter := ""
var _wanted_screens: Dictionary = {}

## Autoloads are not registered in `--script` mode, so they are fetched by path.
var content: Node
var dialog_layer: Node
const DIALOG_LAYER := 128
var api: Node
var router: Node
var game: Node


func run(kit: TestKit, scene_tree: SceneTree, screens: String = "") -> void:
	t = kit
	tree = scene_tree
	_screen_filter = screens
	for entry in screens.split(",", false):
		var id := entry.strip_edges()
		if not id.is_empty():
			_wanted_screens[id] = true
	content = _autoload("Content")
	api = _autoload("Api")
	router = _autoload("Router")
	game = _autoload("Game")
	_boot_content()
	t.close_suite()
	await _every_screen_opens()
	t.close_suite()
	# Everything below opens a screen the scope did not ask for, or mutates global
	# state that belongs to another game — the MeshGallery mark list and
	# `api._queue`. `TestKit.suite()` only deactivates the *assertions* of a suite
	# that was filtered out; its body still runs, and these bodies cost seconds
	# and leave the tree in a state the next suite then measures. So they gate
	# themselves on `is_selected()`, which is the contract `test_kit.gd` documents
	# for integration suites. The sweep above is the exception and is allowed
	# explicitly by the runner, so it needs no gate of its own.
	await _arena_actually_plays()
	t.close_suite()
	await _card_games_accept_input()
	t.close_suite()
	await _tetris_accepts_moves()
	t.close_suite()
	await _candy_match3_plays()
	t.close_suite()
	await _mesh_gallery_flow()
	t.close_suite()
	await _suggest_dialog_posts()
	t.close_suite()
	await _suggest_dialog_closes()
	t.close_suite()
	_content_values()
	t.close_suite()
	_content_is_in_sync()
	t.close_suite()


func _autoload(name: String) -> Node:
	var node := tree.root.get_node_or_null("/root/" + name)
	return node


## May this integration suite run at all?
##
## `TestKit.suite()` deactivates the assertions of a filtered-out suite but still
## runs its body, and these bodies are exactly the ones that must not run in a
## scoped sweep: they open a foreign screen, they clear `api._queue`, and the
## gallery flow empties the shared mark list that the mesh gallery itself keeps.
## The gate turns "counted nowhere" into "did not happen", which is what
## `test_kit.gd` has always documented for an integration suite.
func _gated(name: String) -> bool:
	return t.is_selected(name)


func _boot_content() -> void:
	t.suite("Content")
	t.check(content.enemies.size() > 0, "Gegner geladen")
	t.check(content.weapons.size() > 0, "Waffen geladen")
	t.check(content.upgrades.size() > 0, "Upgrades geladen")
	t.check(content.modes.size() > 0, "Modi geladen")
	t.check(content.mechanics.size() > 0, "Mechaniken geladen")
	var weapon: Dictionary = content.weapon_by_id("pistol")
	t.check(weapon.has("damage"), "Startwaffe 'pistol' existiert")
	t.equal(str(content.weapon_by_id("nope")["id"]), str(content.weapons[0]["id"]), "Unbekannte Waffe fällt zurück")
	var startable := 0
	for w in content.weapons:
		if int(w.get("unlockWave", 0)) <= 0:
			startable += 1
	t.check(startable >= 3, "Mindestens drei Startwaffen")
	t.suite_done()


func _every_screen_opens() -> void:
	t.suite("Screens")
	var checked := 0
	# A scoped run opens only the screens it owns: this loop is what dominates
	# the wall-clock time, so narrowing it is the difference between a game agent
	# waiting seconds and waiting minutes.
	for screen_id in router.SCREEN_SCRIPTS.keys():
		if not _wants(str(screen_id)):
			continue
		checked += 1
		var arrived := await _goto(str(screen_id))
		t.check(arrived and router.current_id == str(screen_id), "Screen '%s' wird geöffnet" % screen_id)
		t.check(router.current_screen != null and is_instance_valid(router.current_screen), "Screen '%s' existiert" % screen_id)
	# Every registry entry must lead to a working screen.
	for game in GameRegistry.GAMES:
		if not _wants(str(game["screen"])):
			continue
		checked += 1
		var game_id := str(game["id"])
		await _goto(str(game["screen"]))
		t.check(router.current_screen != null, "Spiel '%s' startet" % game_id)
	if checked == 0:
		# Never report success for a sweep that opened nothing — that is how a
		# mis-typed scope would look green.
		t.check(false, "Screen-Filter '%s' passt zu keinem bekannten Screen" % _screen_filter)
	else:
		await _goto("lobby")
	t.suite_done()


## True when a screen should be opened: everything without a filter, otherwise
## only the ids the scope owns.
func _wants(screen_id: String) -> bool:
	if _wanted_screens.is_empty():
		return true
	return _wanted_screens.has(screen_id)


## Switches to a screen and waits only as long as the switch actually takes.
##
## The sweep used to sleep a fixed 0.45 s per screen — about 11 s of the suite's
## wall clock spent doing nothing. The router publishes `current_id` as soon as the
## screen is in the tree, so polling ends the wait after the fade (0.12 s) instead
## of guessing: faster, and it cannot under-wait a slow screen. The cap keeps a
## broken screen from hanging the run.
func _goto(screen_id: String, data: Dictionary = {}, cap := 2.0) -> bool:
	return await t.goto(router, tree, screen_id, data, cap)


func _arena_actually_plays() -> void:
	if not _gated("Arena — Spielablauf"):
		return
	t.suite("Arena — Spielablauf")
	await _goto("arena", {"weaponId": "pistol", "modeId": "classic"})
	var screen = router.current_screen
	if screen == null:
		t.check(false, "Arena geöffnet")
		return
	t.check(screen.stats != null, "Spielerstats existieren")
	t.check(screen.enemies.size() == 220, "Feindpool ist angelegt")
	t.check(screen.bullets.size() == 400, "Geschosspool ist angelegt")
	t.check(screen.gems.size() == 160, "Kristallpool ist angelegt")

	var kills_before: int = screen.kills
	# Fire a few shots straight at a spawned enemy.
	screen.spawn_accumulator = 999.0
	screen._update_spawning(0.5)
	var alive := 0
	for enemy in screen.enemies:
		if not enemy.def.is_empty():
			alive += 1
	t.check(alive > 0, "Gegner spawnen")

	var enemy = screen._free_enemy()
	t.check(enemy != null, "Freier Gegenslot vorhanden")
	if enemy != null:
		screen._spawn_enemy(enemy, content.enemy_by_id("slime"), Vector2(640, 360), 1.0, 1.0, 1.0)
		screen._kill_enemy(enemy)
		t.equal(screen.kills, kills_before + 1, "Ein Tod zählt als Kill")
		t.check(not bool(enemy.def), "Und der Slot ist wieder frei")
		# The counter has to keep running, not latch at one — the arena reads it
		# for the run summary and for the chain bonus.
		var second = screen._free_enemy()
		t.check(second != null, "Auch ein zweiter Slot ist frei")
		if second != null:
			screen._spawn_enemy(second, content.enemy_by_id("slime"), Vector2(600, 360), 1.0, 1.0, 1.0)
			screen._kill_enemy(second)
			t.equal(screen.kills, kills_before + 2, "Der Kill-Zähler läuft weiter")

	# XP pickup and levelling.
	screen.stats.xp = 0.0
	screen.stats.xp_next = 1.0
	screen._gain_xp(1.0)
	t.check(screen.stats.level >= 2, "Genug XP löst ein Level-Up aus")
	t.equal(screen.pending_level_ups, 1, "Level-Up wartet auf Auswahl")
	t.check(screen.choosing_upgrade, "Upgrade-Auswahl ist offen")
	screen._choose_upgrade(0)
	t.check(not screen.choosing_upgrade, "Upgrade-Auswahl schließt wieder")

	# Pause and split spawning.
	screen.toggle_pause()
	t.check(screen.paused, "Pause aktiv")
	screen.toggle_pause()
	t.check(not screen.paused, "Pause beendet")

	var split_def := {"id": "x", "splitInto": str(content.enemies[0]["id"]), "splitCount": 2, "radius": 16.0}
	var child = screen._free_enemy()
	if child != null:
		screen._spawn_enemy(child, content.enemy_by_id("slime"), Vector2(300, 300), 1.0, 1.0, 1.0)
		screen._spawn_split(split_def, Vector2(300, 300))
	await _goto("lobby")
	t.suite_done()


func _card_games_accept_input() -> void:
	if not _gated("Kartenspiele — Eingabe"):
		return
	t.suite("Kartenspiele — Eingabe")
	await _goto("freecell")
	var free_cell = router.current_screen
	t.check(free_cell.columns.size() == 8, "Acht Stapel")
	var total := 0
	for column in free_cell.columns:
		total += (column as Array).size()
	t.equal(total, 52, "Alle 52 Karten ausgeteilt")
	var moves_before: int = free_cell.moves
	# Auto move is a no-op at deal time; undo must not crash.
	free_cell.auto_move()
	t.check(free_cell.moves >= moves_before, "Auto-Zug ist sicher")
	free_cell.undo()
	await _goto("poker")
	var poker = router.current_screen
	t.check(poker.table.players.size() == 4, "Vier Poker-Spieler")
	t.check(poker.table.pot > 0, "Blinds gesetzt")
	# The human may call/check whenever it is their turn — and the move has to
	# land on the table: the seat commits chips, is marked as having acted, and
	# the chips arrive in the pot. `t.check(true, …)` proved none of that; it only
	# proved the call returned.
	#
	# `_start_hand` hands the first decision to the computer seats and spaces their
	# turns out over `AI_DELAY`, so "it is the human's turn" is a moment in the
	# future, not a state the screen is in when the router arrives. The old test
	# asked the question once and skipped the whole block when the answer was no —
	# which is how a tautology survived. The wait is bounded, and a human that
	# never gets a turn is a failure, not a skipped assertion.
	var seat: Dictionary = poker.table.players[0]
	var deadline := Time.get_ticks_msec() + 5000
	while (poker.busy or poker.table.active_index != 0 or poker.table.hand_over \
			or bool(seat["folded"]) or bool(seat["all_in"])) \
			and Time.get_ticks_msec() < deadline:
		await tree.create_timer(0.1).timeout
	t.check(not poker.busy and poker.table.active_index == 0 and not poker.table.hand_over,
		"Der Bildschirm lässt den Menschen ziehen, nicht die Computer")
	if not poker.busy and poker.table.active_index == 0 and not poker.table.hand_over \
			and not bool(seat["folded"]) and not bool(seat["all_in"]):
		var chips_before: int = int(seat["chips"])
		var pot_before: int = poker.table.pot
		var owed: int = int((poker.table.legal_actions(0) as Dictionary)["callAmount"])
		poker._human_action()
		await tree.create_timer(0.3).timeout
		t.check(bool(seat["has_acted"]) or poker.table.hand_over,
			"Der menschliche Zug wurde auf dem Platz vermerkt")
		# A check pays nothing and a call pays exactly what was owed — the
		# accounting the showdown and the side pots are built on.
		var paid: int = chips_before - int(seat["chips"])
		t.equal(paid, owed, "Der Mensch hat genau den geforderten Betrag gesetzt (schuldet %d)" % owed)
		t.equal(int(poker.table.pot) - pot_before, paid,
			"Der Topf ist um genau so viel gewachsen, wie der Mensch gesetzt hat")
		t.check(int(seat["bet"]) >= paid, "Und der Einsatz steht auf seinem Platz")
	else:
		t.fail("Der Menschen kam nie an die Reihe — der Zug wurde gar nicht geprüft")
	await _goto("lobby")
	t.suite_done()


func _tetris_accepts_moves() -> void:
	if not _gated("Tetris — Eingabe"):
		return
	t.suite("Tetris — Eingabe")
	await _goto("tetris")
	var screen = router.current_screen
	t.check(screen.board.size() == 20, "20 Reihen")
	var start_y: int = screen.piece["y"]
	screen._try_move_down()
	t.check(int(screen.piece["y"]) == start_y + 1, "Stück fällt eine Zeile")
	screen._hard_drop()
	t.check(screen.piece != null, "Nach dem Hard Drop kommt ein neues Stück")
	screen._rotate(true)
	screen._hold_piece()
	t.check(screen.hold_type >= 0, "Halt-Slot gefüllt")
	# Fill a row and clear it.
	for x in 10:
		screen.board[19][x] = 1
	screen.board[18][0] = 1
	screen._clear_lines()
	t.check(screen.lines >= 1, "Volle Zeile wird geräumt")
	t.check(not TetrisRules.is_perfect_clear(screen.board), "Ein Stein bleibt liegen")
	t.check(screen.perfect_clears == 0, "Das ist kein Perfect Clear")
	t.check(not str(screen.clear_message).contains("PERFECT"), "Der Bildschirm meldet keinen Perfect Clear")

	# The other way round: the well is empty afterwards, so the game celebrates.
	screen.reset_game()
	for x in range(4, 10):
		screen.board[16][x] = 1
	screen.piece = screen._make_piece(0)
	screen.piece["x"] = 0
	screen.piece["y"] = 15
	screen._lock_piece()
	screen._refresh()
	t.check(TetrisRules.is_perfect_clear(screen.board), "Die Senke ist danach komplett leer")
	t.check(screen.perfect_clears == 1, "Der Perfect Clear wird gezählt")
	t.check(str(screen.clear_message).contains("PERFECT CLEAR"), "Der Bildschirm meldet den Perfect Clear")
	t.check(screen.back_to_back >= 1, "Der Perfect Clear eröffnet eine B2B-Kette")
	t.check(screen._perfect_stat_label.text == "1", "Der Zähler im Bild steht auf 1")
	t.check(screen._perfect_headline.text.contains("PERFECT CLEAR"), "Die Schlagzeile steht an")
	t.check(screen._perfect_bonus.text.begins_with("+"), "Der Bonus wird als Punktzahl gezeigt")
	t.check(screen.score > 0, "Der Perfect Clear bringt Punkte")

	# The celebration fades on its own instead of standing over the well.
	var seconds: float = screen.perfect_flash
	screen._fade_perfect_clear(seconds + 0.1)
	t.equal(screen.perfect_flash, 0.0, "Die Feier ist vorbei")
	t.equal(screen._perfect_headline.modulate.a, 0.0, "Die Schlagzeile ist ausgeblendet")
	screen.reset_game()
	t.equal(screen.perfect_clears, 0, "Ein neuer Lauf zählt wieder von null")
	await _goto("lobby")
	t.suite_done()


## Walks the match-3 the way a player does: the level select opens, a real swap
## costs a move, the cascade plays out, undo takes it back and the palette
## switch repaints the board.
func _candy_match3_plays() -> void:
	if not _gated("Candy Crush — Spielablauf"):
		return
	t.suite("Candy Crush — Spielablauf")
	await _goto("candy3d")
	var screen = router.current_screen
	t.check(screen != null, "Der Bildschirm öffnet")
	if screen == null:
		return
	t.check(not screen.state.is_empty(), "Ein Level ist geladen")
	t.check(screen.pieces.size() > 0, "Bonbons liegen auf dem Brett")
	t.check(screen._select_root.visible, "Die Levelauswahl startet offen")
	screen._select_root.visible = false

	# Screen-space picking: the board centre maps to the middle cell.
	# `TestScreens` is a RefCounted, so the viewport comes from the tree.
	var centre: Vector2 = tree.root.get_visible_rect().size * 0.5
	t.check(screen._cell_at(centre) >= 0, "Die Bildschirmmitte trifft ein Feld")

	var swaps := CandyMatch3.find_valid_swaps(screen.state["board"], 1)
	t.check(not swaps.is_empty(), "Es gibt einen spielbaren Zug")
	var moves_before: int = screen.state["movesLeft"]
	screen._try_swap(int((swaps[0] as Dictionary)["a"]), int((swaps[0] as Dictionary)["b"]))
	t.equal(int(screen.state["movesLeft"]), moves_before - 1, "Der Zug kostet einen Zug")
	t.check(int(screen.state["score"]) > 0, "Der Zug bringt Punkte")
	t.check(screen.undo_stack.size() == 1, "Der Zug liegt im Undo-Stapel")

	# The cascade runs itself out, then the board is interactive again.
	for i in 40:
		screen._update_world(0.35)
		if screen.mode == 0:
			break
	t.equal(screen.mode, 0, "Die Kettenreaktion endet im Auswahlmodus")
	t.check(not CandyMatch3.has_any_match(screen.state["board"]), "Das Brett ist danach ruhig")

	screen._undo()
	t.equal(int(screen.state["movesLeft"]), moves_before, "Undo gibt den Zug zurück")
	t.equal(int(screen.state["score"]), 0, "Undo nimmt die Punkte zurück")

	# A dead swap must not cost anything.
	var illegal := CandyMatch3.cell_index(0, 0)
	if CandyMatch3.has_candy(screen.state["board"], illegal):
		screen._try_swap(illegal, CandyMatch3.cell_index(7, 8))
		t.equal(int(screen.state["movesLeft"]), moves_before, "Ein unmöglicher Zug kostet nichts")

	screen._toggle_palette()
	t.check(screen.palette_mode == CandyMatch3.PALETTE_CLASSIC, "Die Palette wechselt")
	screen._toggle_palette()
	t.check(screen.palette_mode == CandyMatch3.PALETTE_CONTRAST, "und wieder zurück")

	screen._show_hint()
	t.check(screen.hint_cells.size() == 2, "Der Hinweis markiert zwei Felder")
	screen._show_level_select()
	t.check(screen._select_root.visible, "Die Levelauswahl lässt sich öffnen")
	await tree.create_timer(0.2).timeout
	await _goto("lobby")
	t.suite_done()


## The dialog is a stateless helper class, so it is loaded by path — that also
## keeps the test independent of the autoload registration order.
func _suggest_script() -> GDScript:
	return load("res://src/core/ui/suggest_dialog.gd")

## The dialog adds a CanvasLayer to the window root; find it by that marker.
func _suggest_layer() -> Node:
	for child in tree.root.get_children():
		if child is CanvasLayer and (child as CanvasLayer).layer == DIALOG_LAYER:
			return child
	return null


func _suggest_dialog_posts() -> void:
	if not _gated("Vorschlagsdialog"):
		return
	t.suite("Vorschlagsdialog")
	await _goto("lobby_list")
	var host = router.current_screen
	t.check(_suggest_script().is_open() == false, "Dialog startet geschlossen")
	_suggest_script().open(host)
	await tree.create_timer(0.3).timeout
	dialog_layer = _suggest_layer()
	t.check(dialog_layer != null, "Dialog öffnet")
	t.check(_suggest_script().is_open(), "Dialog meldet 'offen'")
	t.check(_suggest_layer().get_child_count() == 1, "Dialog besteht aus einer Ebene")

	# Without a server the suggestion is queued and reported as saved.
	var view: Dictionary = await api.submit_suggestion("Testvorschlag aus dem GDScript-Test", "Test")
	t.check(view.is_empty(), "Ohne Server wird nichts gesendet")
	t.check(api._queue.size() == 1, "Der Vorschlag landet in der Offline-Warteschlange")
	api._queue.clear()
	t.suite_done()


func _suggest_dialog_closes() -> void:
	# The second half of the dialog suite: it continues the state the first one
	# left behind, so it is gated under its own name — which is the name it was
	# already counted under, since `t.suite()` is not called again here.
	if not t.is_selected("Vorschlagsdialog"):
		return
	_suggest_script().close()
	t.check(not _suggest_script().is_open(), "Dialog schließt sofort")
	await tree.create_timer(0.2).timeout
	t.check(not is_instance_valid(dialog_layer), "Dialog-Fenster wurde freigegeben")
	t.check(_suggest_layer() == null, "Kein Dialog-Fenster mehr im Baum")
	# Reopening must work after a close.
	_suggest_script().open(router.current_screen)
	await tree.create_timer(0.2).timeout
	t.check(_suggest_script().is_open(), "Dialog lässt sich erneut öffnen")
	_suggest_script().close()
	await _goto("lobby")
	t.suite_done()


func _content_values() -> void:
	t.suite("Content-Integrität")
	for def in content.enemies:
		t.check(def.has("id") and def.has("hp") and def.has("speed"), "Gegner '%s' ist vollständig" % str(def.get("id", "?")))
		var shape := str(def.get("shape", "circle"))
		t.check(shape in ["circle", "square", "triangle", "diamond", "hexagon"], "Gegner '%s' hat eine gültige Form" % str(def.get("id", "?")))
		var behavior := str(def.get("behavior", "chase"))
		t.check(behavior in ["chase", "zigzag", "orbit"], "Gegner '%s' hat ein gültiges Verhalten" % str(def.get("id", "?")))
	for def in content.weapons:
		t.check(float(def.get("damage", 0.0)) > 0.0, "Waffe '%s' hat Schaden" % str(def.get("id", "?")))
		t.check(float(def.get("cooldown", 0.0)) >= 70.0, "Waffe '%s' respektiert die Cooldown-Untergrenze" % str(def.get("id", "?")))
		t.check(not str(def.get("color", "")).is_empty(), "Waffe '%s' hat eine Farbe" % str(def.get("id", "?")))
	for def in content.upgrades:
		t.check(not str(def.get("stat", "")).is_empty(), "Upgrade '%s' hat ein Stat" % str(def.get("id", "?")))
		t.check(str(def.get("rarity", "")) in ["common", "uncommon", "rare", "epic"], "Upgrade '%s' hat eine gültige Seltenheit" % str(def.get("id", "?")))
		# "Anwendbar" means the stat block *changed*. `t.check(true, …)` called an
		# upgrade applicable whether the number moved or the card was silently
		# dropped — which is exactly what happens when the pack writes `maxHp`
		# and the block knows `max_hp`, so the amount is compared before and after
		# on the form the game actually hands over.
		var stats := PlayerStats.new()
		var applied := ArenaRuns.applied_form(def)
		var field := str(applied["stat"])
		var before: float = float(stats.get(field))
		stats.apply_upgrade(applied)
		t.check(float(stats.get(field)) != before,
			"Upgrade '%s' ist anwendbar — '%s' ging von %s auf %s"
			% [str(def.get("id", "?")), field, before, float(stats.get(field))])
		# …and the caps the rules promise still hold after a hundred copies.
		var spammed := PlayerStats.new()
		for i in 100:
			spammed.apply_upgrade(applied)
		t.check(spammed.crit_chance <= 0.9 and spammed.fire_rate <= 8.0,
			"Upgrade '%s' hält die Obergrenzen der Regeln ein" % str(def.get("id", "?")))
	for def in content.modes:
		t.check(float(def.get("duration", 0.0)) >= 0.0, "Modus '%s' hat eine gültige Dauer (0 = endlos)" % str(def.get("id", "?")))
		for key in ["enemyHpMult", "enemySpeedMult", "spawnRateMult"]:
			t.check(float(def.get(key, 0.0)) > 0.0, "Modus '%s' hat %s" % [str(def.get("id", "?")), key])
	t.suite_done()


## Walks the whole gallery loop the way a player does: mark a mesh, write a
## note, land on the review screen with a finished draft, and submit it offline.
func _mesh_gallery_flow() -> void:
	if not _gated("Mesh-Galerie"):
		return
	t.suite("Mesh-Galerie")
	MeshGallery.set_marks(MeshGallery.clear_marks())

	await _goto("mesh_gallery")
	var gallery = router.current_screen
	t.check(gallery != null, "Die Galerie öffnet")
	if gallery == null:
		return
	var group_ids: Array[String] = []
	for group in AssetRegistry.GROUPS:
		group_ids.append(str(group["id"]))
	t.check(str(gallery.group_id) in group_ids, "Die Galerie startet in einer bekannten Sammlung")
	t.check(AssetRegistry.keys_in_group(str(gallery.group_id)).size() > 0,
		"Die Startsammlung hat Meshes")
	t.equal(str(gallery.tier), "low", "Die Galerie startet in der Fassung, die die Spiele benutzen")
	t.equal(MeshGallery.mark_count(MeshGallery.shared_marks()), 0, "Die Merkliste startet leer")

	# Every tier loads and every pedestal on the first page is filled.
	for tier_id in AssetRegistry.TIERS:
		gallery._set_tier(tier_id)
		t.equal(str(gallery.tier), tier_id, "Stufe '%s' lässt sich einschalten" % tier_id)
		t.check(gallery.visible_keys().size() > 0, "Stufe '%s' zeigt Meshes" % tier_id)
	gallery._set_tier("low")

	var keys: Array = gallery.visible_keys()
	t.equal(keys.size(), mini(MeshGallery.ARC_SIZE, AssetRegistry.keys_in_group(str(gallery.group_id)).size()),
		"Die erste Seite ist gefüllt")
	for key in keys:
		t.check(AssetRegistry.exists(str(key)), "Sockel '%s' zeigt ein gebündeltes Mesh" % str(key))

	# Marking like a player does: stand at a pedestal and press E.
	gallery.active_pedestal = 0
	gallery._toggle_mark()
	t.check(MeshGallery.is_marked(MeshGallery.shared_marks(), str(gallery.visible_keys()[0])),
		"Das Mesh steht in der geteilten Merkliste")
	t.equal(MeshGallery.mark_count(MeshGallery.shared_marks()), 1, "Das erste Mesh ist vorgemerkt")
	gallery._toggle_mark()
	t.equal(MeshGallery.mark_count(MeshGallery.shared_marks()), 0, "Und wieder abgewählt")
	gallery.active_pedestal = 0
	gallery._toggle_mark()

	# The note lands in the mark list …
	gallery._refresh()
	t.check(not str(gallery._info_name.text).is_empty(), "Die Infokarte nennt das Mesh")
	t.check(not str(gallery._info_meta.text).is_empty(), "Die Infokarte nennt Stufe und Dreieckzahl")

	# … and the review screen turns it into a finished text.
	await _goto("mesh_review")
	var review = router.current_screen
	t.check(review != null, "Die Review-Seite öffnet")
	if review == null:
		return
	t.check(not str(review._draft.text).is_empty(), "Der Vorschlag ist vorausgefüllt")
	t.check(str(review._draft.text).contains(str(keys[0])), "Der Vorschlag nennt das Mesh")
	t.check(review._submit_button.disabled == false, "Absenden ist möglich")

	# A note flows into the text.
	var before := str(review._draft.text)
	MeshGallery.set_marks(MeshGallery.set_note(MeshGallery.shared_marks(), str(keys[0]), "Flügel zu kantig"))
	review._rebuild()
	t.check(str(review._draft.text).contains("Flügel zu kantig"), "Die Notiz steht im Vorschlag")
	t.check(str(review._draft.text) != before, "Der Vorschlag hat sich geändert")

	# Submitting without a server lands in the offline queue.
	api._queue.clear()
	review._submit()
	await tree.create_timer(0.4).timeout
	t.equal(api._queue.size(), 1, "Der Vorschlag ist in der Offline-Warteschlange")
	if api._queue.size() == 1:
		t.check(str((api._queue[0] as Dictionary)["text"]).contains("Mesh-Galerie"),
			"Der Vorschlag trägt seine Herkunft mit sich")
	api._queue.clear()
	# Offline only queues it: the list stays, so the player can still copy the text.
	t.equal(MeshGallery.mark_count(MeshGallery.shared_marks()), 1,
		"Nach dem Offline-Senden bleibt die Liste erhalten")
	MeshGallery.set_marks(MeshGallery.clear_marks())
	t.equal(MeshGallery.mark_count(MeshGallery.shared_marks()), 0, "„Liste leeren“ leert sie")

	await tree.create_timer(0.6).timeout
	MeshGallery.set_marks(MeshGallery.clear_marks())
	await _goto("lobby")
	t.suite_done()


## The app ships its own copy of the content pack (Godot cannot read files from
## outside the project). If this fails, run `npm run content:sync`.
func _content_is_in_sync() -> void:
	t.suite("Content-Synchronisation")
	for name in ["enemies", "weapons", "upgrades", "modes", "mechanics"]:
		var shipped := FileAccess.get_file_as_string("res://assets/content/%s.json" % name)
		t.check(not shipped.is_empty(), "App liefert %s.json mit" % name)
		var parsed: Variant = JSON.parse_string(shipped)
		t.check(parsed is Array, "%s.json ist ein Array" % name)
	t.suite_done()
