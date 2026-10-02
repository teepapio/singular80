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
	await _hatchery_camera()
	t.close_suite()
	_content_values()
	t.close_suite()
	_content_is_in_sync()
	t.close_suite()


## suggestion #21: "make the areas with the pedestals scrollable, zoomable,
## draggable, when i click on a Dragon IT shall be selected".
##
## Three of the six pedestals used to stand behind the 430 px panel on the left
## and could not be reached at all, because the camera was nailed to one spot.
## So the suite does what a player does: opens the hatchery, drags the valley,
## taps a dragon, zooms with the buttons, and puts the ring back where it was.
func _hatchery_camera() -> void:
	if not _gated("Drachenflug — Kamera"):
		return
	t.suite("Drachenflug — Kamera")
	await _goto("dragonflight_hatchery")
	var screen = router.current_screen
	if screen == null:
		t.check(false, "Bruterei geöffnet")
		return
	t.check(screen.cam != null, "Die Bruterei hat eine Kamera-Rig")
	t.check(screen.cam is PedestalCamera, "Und es ist die aus den Mechaniken")
	t.check(screen._aim.size() == screen.pedestals.size(),
		"Jeder Sockel hat einen Zielpunkt, auf den ein Tipp zielen kann")
	var cam: PedestalCamera = screen.cam
	var home: Vector3 = cam.focus

	# The rig is configured for this valley, not for a default: the zoom has to
	# bracket the framing the screen was drawn at, and the pan box has to reach
	# the whole ring. Before the rig the camera was nailed to one spot, and the
	# panel over the left third of the screen put the pedestals behind it out of
	# reach for good.
	#
	# 24.01 is the distance the old fixed camera stood at; the screen's own
	# constants are not read here, and that is deliberate. Naming a game screen
	# (`DragonFlightHatcheryScreen.CAM_NEAR`) makes it a compile-time dependency
	# of this file, this file is loaded before the autoloads are registered, and
	# the screen then fails on its first `Sfx` and stays failed — the router
	# cannot instantiate it for the rest of the run. The rig's own numbers say
	# the same thing without the dependency.
	t.check(cam.min_distance < 24.01 and 24.01 < cam.max_distance,
		"Die Zoomgrenzen liegen um die alte Einstellung herum")
	t.check(cam.pitch > 0.0 and cam.pitch < PI * 0.25, "Und die Kamera schaut von oben auf das Tal")
	for i in screen.pedestals.size():
		var spot: Vector3 = screen.pedestals[i]["spot"]
		t.check(spot.x > cam.bounds.position.x and spot.x < cam.bounds.end.x,
			"Sockel %d liegt im Schieberahmen" % i)
		t.check(spot.z > cam.bounds.position.y and spot.z < cam.bounds.end.y,
			"und der auch in der Tiefe hineinpasst")

	# The framing has to be the one the valley was drawn at, or the first frame
	# after this commit would have moved the whole scene. The constant is read
	# off the open screen, not off the class: `screen` is an untyped Variant, so
	# this is a lookup at runtime and the file keeps no compile-time edge into
	# the game scripts.
	t.almost(cam.focus.distance_to(screen.CAM_HOME), 0.0, 0.001,
		"Die Bruterei startet in ihrer alten Einstellung")

	# A drag pans. Nothing is selected, however the drag ends — that is the
	# difference between a draggable area and one that fights the player.
	t.check(screen.parent_a == 0 and screen.parent_b == 0, "Vorher ist kein Drache gewählt")
	# The valley follows the finger, so a finger to the right walks the focus to
	# the left — which is how a pedestal hidden behind the panel is brought out
	# from under it.
	var from := Vector2(400.0, 400.0)
	screen.cam.pointer_down(0, from)
	for step in 12:
		screen.cam.pointer_move(0, from + Vector2(float(step) * 20.0, 0.0))
	t.check(cam.focus.x < home.x - 0.5, "Ein Fingerzug nach rechts schiebt das Tal nach links")
	t.check(not screen.cam.pointer_up(0), "Und der Abschluss ist kein Tipp")
	t.check(screen.parent_a == 0 and screen.parent_b == 0, "Ein Zug wählt keinen Drachen aus")

	# A fresh profile has two dragons, so the two pedestals on the left stand
	# empty and there is nothing to reach for. The ring is filled the way the
	# game fills it — one more dragon per free plinth, then the screen's own
	# `_place_dragons()` — because a test that only ever looks at the default
	# save would pass while the complaint stands.
	for i in screen.pedestals.size():
		if int(screen.pedestals[i]["uid"]) == 0:
			screen.dragons.append(DragonFlight.random_dragon(900 + i, ["ember"]))
	screen._place_dragons()
	var left: int = -1
	for i in screen.pedestals.size():
		var spot: Vector3 = screen.pedestals[i]["spot"]
		if spot.x < -7.0 and screen.pedestals[i]["uid"] != 0:
			left = i
			break
	t.check(left >= 0, "Der Stable hat einen Drachen ganz links")
	if left >= 0:
		# The complaint, measured and not argued. The panel sits at x = 20 and is
		# 430 wide, so it ends at 450 and swallows every tap left of it: in the
		# framing this screen was drawn at, the left pedestal is behind it …
		screen.cam.reset()
		screen.cam.snap(screen.camera)
		var hidden: Vector2 = screen.camera.unproject_position(screen._aim[left])
		t.check(hidden.x < 450.0, "Im alten Bild steht der linke Drache hinter dem Panel")
		# … and after a drag he stands clear of it. That is the whole suggestion.
		screen.cam.pointer_down(0, from)
		for step in 60:
			screen.cam.pointer_move(0, from + Vector2(float(step) * 20.0, 0.0))
		screen.cam.pointer_up(0)
		screen.cam.apply(screen.camera, 1.0)
		var seen: Vector2 = screen.camera.unproject_position(screen._aim[left])
		t.check(seen.x > 470.0, "Linksher geschoben steht derselbe Drache frei")
		# And a tap there really is that dragon.
		# 3.4 is the hatchery's own pick radius, in the framing it was drawn at.
		var picked: int = screen.cam.pick(screen.camera, seen, screen._aim, 3.4)
		t.equal(picked, left, "Ein Tipp auf ihn trifft diesen Drachen")
		if picked == left:
			screen._pick_at(seen)
			t.check(screen.parent_a == int(screen.pedestals[left]["uid"]) or screen.parent_b == int(screen.pedestals[left]["uid"]),
				"Und er wird als Elternteil gewählt")

	# Zoom: the buttons, and the limits behind them.
	screen.cam.reset()
	t.almost(cam.focus.distance_to(home), 0.0, 0.001, "Zurücksetzen bringt das Tal an seinen Platz")
	var out: float = cam.distance
	screen._on_zoom(1.25)
	t.check(cam.distance > out, "Der −-Knopf geht weiter weg")
	screen._on_zoom(0.8)
	screen._on_zoom(0.8)
	t.check(cam.distance < out, "Der +-Knopf geht näher heran")
	for i in 40:
		screen._on_zoom(0.5)
	t.check(cam.distance >= cam.min_distance - 0.001, "Der Zoom bleibt über der Untergrenze")
	for i in 40:
		screen._on_zoom(2.0)
	t.check(cam.distance <= cam.max_distance + 0.001, "und unter der Obergrenze")

	# Two separate facts about the camera, and the second one is about the screen
	# rather than about the rig. `apply()` walks a camera that was put somewhere
	# wrong back onto the goal …
	screen.cam.reset()
	screen.camera.position = screen.cam.goal() + Vector3(0.0, 6.0, 0.0)
	for i in 60:
		screen.cam.apply(screen.camera, 1.0 / 60.0)
	t.check(screen.camera.position.distance_to(cam.goal()) < 0.01,
		"Die Rig holt die Zielposition in einer Sekunde Frames ein")
	# … and the screen really calls it, every frame. Frames and not seconds here:
	# a headless tree draws as many frames as it can, so a wall-clock wait would
	# be a measurement of the machine instead of of the screen.
	screen.camera.position = screen.cam.goal() + Vector3(0.0, 6.0, 0.0)
	var away: float = screen.camera.position.distance_to(cam.goal())
	for i in 5:
		await tree.process_frame
	var nearer: float = screen.camera.position.distance_to(cam.goal())
	t.check(nearer < away - 0.001, "Und der Bildschirm zieht die Kamera in jedem Frame nach")
	t.check(nearer > 0.0, "wobei ein Frame nicht die ganze Strecke überspringt")

	# Godot delivers every finger twice: `emulate_mouse_from_touch` and
	# `emulate_touch_from_mouse` are both on, so a touch arrives again as a mouse
	# click and a click again as a touch. Handled, both copies reach the rig and
	# the second one opens a phantom pointer — the valley then pans by itself and
	# one finger fires a pinch. Godot marks its own copies
	# `InputEvent.DEVICE_ID_EMULATION` (4.5 class reference, `InputEvent`), and
	# the screen drops exactly those. Called directly here, because a test that
	# pushed the event through the input pipeline would be testing Godot's
	# routing as much as the screen's answer to it.
	var echo := InputEventScreenTouch.new()
	echo.index = 0
	echo.position = Vector2(1240.0, 700.0)
	echo.pressed = true
	echo.device = InputEvent.DEVICE_ID_EMULATION
	screen._unhandled_input(echo)
	t.equal(cam.tracking(), 0, "Ein emuliertes Touch-Echo kommt im Rig nicht an")
	var finger := InputEventScreenTouch.new()
	finger.index = 0
	finger.position = Vector2(1240.0, 700.0)
	finger.pressed = true
	screen._unhandled_input(finger)
	t.equal(cam.tracking(), 1, "Der echte Touch schon")
	finger.pressed = false
	screen._unhandled_input(finger)
	t.equal(cam.tracking(), 0, "und sein Loslassen schließt den Zug ab")
	t.suite_done()


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

	# A player asked for three things about the hall itself: no path down the
	# middle, ten rows, and meshes ninety per cent taller. The rows are
	# `MeshGallery`'s business and its own suite pins them; these three are the
	# screen's, and each one is a number a regression would show up in.
	t.equal(str(MeshGalleryScreen.MESH_ON_PEDESTAL), 3.3,
		"Die Meshes auf den Sockeln sind rund neunzig Prozent größer")
	t.equal(str(MeshGalleryScreen.MOVE_SPEED), 15.0, "Der Spieler läuft doppelt so schnell")
	var floor_marks := 0
	for child in gallery.get_children():
		if child is MeshInstance3D and (child as MeshInstance3D).mesh is BoxMesh:
			var mark_size: Vector3 = ((child as MeshInstance3D).mesh as BoxMesh).size
			# The stripe down the middle was the only mesh that lay flat on the
			# floor and was longer than it was wide; the floor slab and the two
			# walls are the only boxes left, and the walls stand upright.
			if mark_size.y < 0.1 and mark_size.z > mark_size.x:
				floor_marks += 1
	t.equal(floor_marks, 0, "Es gibt keinen Weg mehr in der Mitte der Halle")
	t.check(MeshGallery.hall_half_width() > MeshGallery.OUTER_ROW_OFFSET,
		"Die Wand steht hinter der äußersten Reihe, nicht auf ihr")

	# Every level loads.
	for tier_id in AssetRegistry.TIERS:
		gallery._set_tier(tier_id)
		t.equal(str(gallery.tier), tier_id, "Stufe '%s' lässt sich einschalten" % tier_id)
	gallery._set_tier("low")

	# Walk forward until a pedestal is close enough to look at. Every row has an
	# aisle a `CLEAR` short of it, and the nave is the aisle of the inner row, so
	# a player walking down the middle already looks at a mesh — however far
	# forward. The position goes through `lane_x` because the pedestal stands in
	# the band that row closes off, and a player is never allowed to stand there.
	# The row is the second one, so this also covers a pedestal the nave cannot
	# see: from the middle, the row in front always wins.
	var row := 2
	var here := MeshGallery.slot_position(row * 2)
	var lane := float(MeshGallery.side_of(row * 2)) * MeshGallery.lane_of(row)
	gallery.pos = Vector3(MeshGallery.lane_x(lane, here.z, lane), 0, here.z)
	gallery._update_world(0.016)
	await tree.create_timer(0.5).timeout
	t.equal(int(gallery.active_slot), row * 2,
		"Aus dem Gang vor einer Reihe steht genau diese Reihe vorn")
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

	# The aisles are not decoration. Standing in front of a row puts that row in
	# front of the player, and it is the only way the rows behind it can be read
	# or written about at all — from the nave the row in front is always the
	# nearer one, and no distance rule can change that. The outermost row is the
	# claim worth pinning: it stands five times as far out as the first one, and
	# the hall now has five rows a side.
	var far_row := MeshGallery.ROWS_PER_SIDE - 1
	for probe_row in [0, 1, far_row]:
		var far := MeshGallery.slot_position(probe_row * 2)
		var aisle := float(MeshGallery.side_of(probe_row * 2)) * MeshGallery.lane_of(probe_row)
		gallery.pos = Vector3(MeshGallery.lane_x(aisle, far.z, aisle), 0, far.z)
		gallery._update_world(0.016)
		t.equal(int(gallery.active_slot), probe_row * 2,
			"Im Gang vor Reihe %d steht das Mesh dieser Reihe vorn" % probe_row)
		t.check(AssetRegistry.exists(str(gallery.active_key())),
			"Das ferne Mesh ist gebündelt")
	# And the middle of the nave still finds the inner row, which is the one a
	# player who never leaves it ever sees.
	var nave := MeshGallery.slot_position(0)
	gallery.pos = Vector3(0.0, 0.0, nave.z)
	gallery._update_world(0.016)
	t.check(gallery.active_slot >= 0, "Auch auf dem Mittelstrich steht ein Mesh vorn")

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
