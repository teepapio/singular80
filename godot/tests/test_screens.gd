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
	# state that belongs to another game — `api._queue` and the suggestion
	# dialog. `TestKit.suite()` only deactivates the *assertions* of a suite
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
## gallery flow builds a hall of 170 pedestals. The gate turns "counted
## nowhere" into "did not happen", which is what `test_kit.gd` has always
## documented for an integration suite.
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


## Screens whose layout must fit the narrowest viewport the game will ever be
## given. Add an id here once its layout has been checked.
##
## The defect is general, so the measurement is: a `Button` is exactly as wide
## as its own text and `custom_minimum_size` is a floor rather than a ceiling,
## so one long caption inside a fixed-width panel pushes the whole row — and
## with it everything to the right of it — past the edge of the screen. The
## dragon hangar did exactly that: its "Your dragons" panel wanted 1262 px
## instead of the 330 it declares, and the row 2134 px against the 1244 px a
## 1280-wide viewport leaves. Measured on the device layout, not estimated.
##
## `pang_menu` has the same shape — its level cards put a non-wrapping
## "Reinforcements: …" caption into a fixed card and reach x = 1425 — and
## belongs to another lane, so it is named here rather than silently ignored.
const WIDTH_CHECKED := ["dragonflight"]


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
		# Every screen is measured here, because this is the one pass that opens
		# all of them; see `_unreachable_controls()` for what that measures.
		for dead in _unreachable_controls(router.current_screen):
			t.check(false, "'%s': %s" % [screen_id, dead])
		if WIDTH_CHECKED.has(str(screen_id)):
			# Two frames: a container answers `size` from its children's minimums
			# on the next sort, so measuring in the frame the screen arrives would
			# read the layout it had before the last rebuild.
			await tree.process_frame
			await tree.process_frame
			var over := _right_overflow(router.current_screen)
			t.check(over <= 1.0, "'%s' ragt %.0f px über den rechten Rand" % [screen_id, over])
	# Every registry entry must lead to a working screen.
	for game in GameRegistry.GAMES:
		if not _wants(str(game["screen"])):
			continue
		checked += 1
		var game_id := str(game["id"])
		await _goto(str(game["screen"]))
		t.check(router.current_screen != null, "Spiel '%s' startet" % game_id)
		for dead in _unreachable_controls(router.current_screen):
			t.check(false, "'%s': %s" % [game_id, dead])
	if checked == 0:
		# Never report success for a sweep that opened nothing — that is how a
		# mis-typed scope would look green.
		t.check(false, "Screen-Filter '%s' passt zu keinem bekannten Screen" % _screen_filter)
	else:
		await _goto("lobby")
	t.suite_done()


## How far the screen's content reaches past the right edge, in pixels.
##
## A container never shrinks below what its children demand, so an overflowing
## layout does not get clipped at the screen border — it pushes its own rect
## past it, and whatever sits on the right (here: the upgrades panel and the
## start button) is simply not there any more.
##
## The budget is `min(screen width, Screen.DESIGN.x)`: `stretch/aspect` is
## `expand`, which gives the viewport `max(1280, 1280 × aspect)` and therefore
## never less than the design width, so 1280 is the narrowest case the layout
## has to survive and it is the one worth asserting.
func _right_overflow(screen: Node) -> float:
	if screen == null or not (screen is Control):
		return 0.0
	var budget := minf((screen as Control).size.x, Screen.DESIGN.x)
	return _rightmost(screen, 0.0) - budget


## The rightmost visible pixel any descendant reaches.
##
## The accumulator travels as the *return* value: GDScript hands a `float` to a
## callee by copy, so `acc` written inside the recursion never reaches the
## caller. The first version of this function returned `-1280` on a screen that
## was 2134 px wide, and a check that is always negative never fails.
func _rightmost(node: Node, right: float) -> float:
	var best := right
	if node is Control:
		var control := node as Control
		if control.is_visible_in_tree():
			best = maxf(best, control.global_position.x + control.size.x)
	for child in node.get_children():
		best = _rightmost(child, best)
	return best


## True when a screen should be opened: everything without a filter, otherwise
## only the ids the scope owns.
func _wants(screen_id: String) -> bool:
	if _wanted_screens.is_empty():
		return true
	return _wanted_screens.has(screen_id)


## Every control on the screen a click can no longer reach.
##
## Godot decides where a pointer event goes by walking the tree: later siblings
## first, children before parents, skipping invisible nodes and everything
## marked `MOUSE_FILTER_IGNORE`. `z_index` is **not** part of that walk — a
## control can paint on top of another and still lose every click to it.
##
## That is why this needed a test and not a look at a screenshot. `main.gd` held
## an empty, full-rect `Control` with the default `MOUSE_FILTER_STOP`, added
## after the router's screen host: it painted nothing and swallowed every mouse
## and touch event of every 2D screen, top bar and game card alike. A headless
## run cannot click, and this suite only ever switched screens and called
## methods, so the entire game could be button-dead and still be green.
func _unreachable_controls(screen: Node) -> Array[String]:
	var dead: Array[String] = []
	if screen == null or not is_instance_valid(screen):
		return dead
	_collect_unreachable(screen, dead)
	return dead


func _collect_unreachable(node: Node, dead: Array[String]) -> void:
	if node is Control:
		var control := node as Control
		if _is_interactive(control) and control.is_visible_in_tree() \
				and control.size.x > 0.0 and control.size.y > 0.0:
			var blocker := _picks(tree.root, control.get_global_rect().get_center())
			# A modal overlay is *meant* to swallow clicks, so it is no defect.
			if blocker != null and _under_modal(blocker):
				return
			# The event travels from the picked node up the parent chain, never
			# down, so only the control itself or one of its own children can
			# deliver it to this button.
			if blocker == null or not _is_self_or_ancestor(blocker, control):
				dead.append("%s '%s' ist von %s verdeckt" % [
					control.get_class(), _caption(control),
					str(blocker.get_path()) if blocker != null else "nichts",
				])
	for child in node.get_children():
		_collect_unreachable(child, dead)


## A `Button`, or a `Control` that handles `gui_input` itself — the two ways this
## codebase makes something tappable.
func _is_interactive(control: Control) -> bool:
	if control is Button:
		return true
	return control.mouse_filter != Control.MOUSE_FILTER_IGNORE \
		and control.has_signal("gui_input") \
		and not control.gui_input.get_connections().is_empty()


func _caption(control: Control) -> String:
	return (control as Button).text if control is Button else ""


func _is_self_or_ancestor(node: Node, target: Node) -> bool:
	var current: Node = node
	while current != null:
		if current == target:
			return true
		current = current.get_parent()
	return false


func _under_modal(node: Node) -> bool:
	var current: Node = node
	while current != null:
		if current.has_meta("modal"):
			return true
		current = current.get_parent()
	return false


## The node Godot would hand a click at `point` to; `null` when it hits nothing.
func _picks(node: Node, point: Vector2) -> Control:
	if not (node is Control):
		# `Node`, `Node3D` and `CanvasLayer` are not clickable themselves, but
		# their children are — a 3D screen's whole HUD hangs off its `CanvasLayer`.
		return _picks_children(node, point)
	var control := node as Control
	if not control.is_visible_in_tree():
		return null
	var hit := _picks_children(control, point)
	if hit != null:
		return hit
	if control.mouse_filter != Control.MOUSE_FILTER_IGNORE and control.get_global_rect().has_point(point):
		return control
	return null


func _picks_children(node: Node, point: Vector2) -> Control:
	for index in range(node.get_child_count() - 1, -1, -1):
		var hit := _picks(node.get_child(index), point)
		if hit != null:
			return hit
	return null


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
		t.check(enemy.def.is_empty(), "Und der Slot ist wieder frei")
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
	var seat = poker.table.players[0]
	var deadline := Time.get_ticks_msec() + 5000
	while (poker.busy or poker.table.active_index != 0 or poker.table.hand_over \
			or seat.get("folded") or seat.get("all_in")) \
			and Time.get_ticks_msec() < deadline:
		await tree.create_timer(0.1).timeout
	t.check(not poker.busy and poker.table.active_index == 0 and not poker.table.hand_over,
		"Der Bildschirm lässt den Menschen ziehen, nicht die Computer")
	if not poker.busy and poker.table.active_index == 0 and not poker.table.hand_over \
			and not seat.get("folded") and not seat.get("all_in"):
		var chips_before: int = int(seat["chips"])
		var pot_before: int = poker.table.pot
		var owed: int = int((poker.table.legal_actions(0) as Dictionary)["callAmount"])
		poker._human_action()
		await tree.create_timer(0.3).timeout
		t.check(seat.get("has_acted") or poker.table.hand_over,
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

	# A build made with `npm run telegram:bake` carries real credentials, so a
	# suite that submits a suggestion in such a build would post it into the
	# owner's chat for real. The credentials are therefore emptied for the length
	# of this suite and put back afterwards — the same reason `test_core` forces
	# them rather than assuming a plain checkout has none.
	var relay: Node = tree.root.get_node_or_null("/root/Telegram")
	var baked_token := ""
	var baked_chat := ""
	if relay != null:
		baked_token = str(relay._token)
		baked_chat = str(relay._chat_id)
		relay._token = ""
		relay._chat_id = ""

	# Without a route the suggestion is queued and reported as saved.
	var view: Dictionary = await api.submit_suggestion("Testvorschlag aus dem GDScript-Test", "Test")
	t.check(view.is_empty(), "Ohne Weg nach draußen wird nichts zugestellt")
	t.check(api._queue.size() == 1, "Der Vorschlag landet in der Offline-Warteschlange")
	api._queue.clear()
	if relay != null:
		relay._token = baked_token
		relay._chat_id = baked_chat
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


## Walks the hall the way a player does: walk forward until a mesh is in front
## of you, look at it, and press E for the ordinary suggestion dialog.
func _mesh_gallery_flow() -> void:
	if not _gated("Mesh-Galerie"):
		return
	t.suite("Mesh-Galerie")

	await _goto("mesh_gallery")
	var gallery = router.current_screen
	t.check(gallery != null, "Die Galerie öffnet")
	if gallery == null:
		return
	# The whole registry stands in the hall — that is what the collections and
	# the pages used to hide.
	t.equal((gallery.keys as Array).size(), AssetRegistry.KEYS.size(),
		"Jedes Mesh der Registry hat einen Sockel")
	t.equal((gallery.slot_nodes as Array).size(), AssetRegistry.KEYS.size(),
		"Jeder Sockel ist gebaut")
	t.equal(str(gallery.tier), "low", "Die Galerie startet in der Fassung, die die Spiele benutzen")

	# Every level loads.
	for tier_id in AssetRegistry.TIERS:
		gallery._set_tier(tier_id)
		t.equal(str(gallery.tier), tier_id, "Stufe '%s' lässt sich einschalten" % tier_id)
	gallery._set_tier("low")

	# Walk forward until a pedestal is close enough to look at. The nave is
	# `LANE_MID` from either inner row and that is less than `NEAR_DISTANCE`, so
	# the player in the middle of the hall already looks at a mesh — standing in
	# the nave finds one, however far forward. The position goes through
	# `lane_x` because the pedestal stands in the band the inner row closes off,
	# and a player is never allowed to stand there.
	var here := MeshGallery.slot_position(4)
	gallery.pos = Vector3(MeshGallery.lane_x(here.x, here.z, here.x), 0, here.z)
	gallery._update_world(0.016)
	await tree.create_timer(0.5).timeout
	t.check(gallery.active_slot >= 0, "Vor einem Sockel steht ein Mesh im Vordergrund")
	var key := str(gallery.active_key())
	t.check(AssetRegistry.exists(key), "Sockel '%s' zeigt ein gebündeltes Mesh" % key)
	t.check((gallery.slot_nodes[int(gallery.active_slot)]["mesh"] as Node) != null,
		"Das Mesh ist in die Szene geladen")

	# The card names it, with the level that really stands there.
	gallery._refresh_info()
	t.check(str(gallery._info_name.text) == Loc.resolve(AssetRegistry.display_name(key)),
		"Die Infokarte nennt das Mesh")
	t.check(str(gallery._info_meta.text).contains(key), "Die Infokarte nennt den Schlüssel")
	# The triangle count, not a German noun: the label word is a translation and
	# is free to change, the number is the claim.
	var counts := AssetRegistry.tri_count(key, str(gallery.tier))
	t.check(counts < 0 or str(gallery._info_meta.text).contains(str(counts)),
		"Die Infokarte nennt die Dreieckzahl")

	# E opens the ordinary suggestion dialog, and the mesh rides along in its
	# origin — the gallery has no second form of its own.
	t.check(_suggest_script().is_open() == false, "Der Dialog startet geschlossen")
	gallery.open_suggestion()
	await tree.create_timer(0.3).timeout
	t.check(_suggest_script().is_open(), "E öffnet das Vorschlagsfenster")
	t.check(_suggest_text().contains(Loc.resolve(AssetRegistry.display_name(key))),
		"Der Vorschlag nennt das Mesh davor")
	_suggest_script().close()
	await tree.create_timer(0.2).timeout
	t.check(not _suggest_script().is_open(), "Der Dialog schließt wieder")

	# The aisle between the two rows is not decoration. Standing in it puts the
	# outer row in front of the player, and that is the only way the far half of
	# the hall can be read or written about at all — from the nave the inner row
	# is always the nearer one, and no distance rule can change that.
	var far := MeshGallery.slot_position(6)
	var aisle: float = float(MeshGallery.side_of(6)) * MeshGallery.LANE_SIDE
	gallery.pos = Vector3(MeshGallery.lane_x(aisle, far.z, aisle), 0, far.z)
	gallery._update_world(0.016)
	t.equal(int(gallery.active_slot), 6, "Im Gang zwischen den Reihen steht das ferne Mesh vorn")
	t.check(AssetRegistry.exists(str(gallery.active_key())),
		"Das ferne Mesh ist gebündelt")

	await _goto("lobby")
	t.suite_done()


## Everything the open dialog has to say, as one string.
func _suggest_text() -> String:
	var layer := _suggest_layer()
	if layer == null:
		return ""
	var out: Array[String] = []
	_collect_text(layer, out)
	return "\n".join(out)


func _collect_text(node: Node, out: Array[String]) -> void:
	for child in node.get_children():
		if child is Label:
			out.append(str((child as Label).text))
		_collect_text(child, out)


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
