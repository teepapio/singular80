class_name TestMerge3d
extends RefCounted
## Rule tests for the Merge 3D editions (Christmas and Halloween) and the Tipp
## button on the real screen. The screen is reached through the router, never
## named statically: that would pull its autoload references into the compile
## chain of `run_tests.gd`, which runs before the engine registers them.

var t: TestKit
var _router: Node


## Entry point used by `run_tests.gd`.
func run(kit: TestKit, tree: SceneTree) -> void:
	t = kit
	_router = tree.root.get_node_or_null("/root/Router")
	_hint()
	t.close_suite()
	_hint_text_and_pressure()
	t.close_suite()
	await _screen_hint(tree)
	t.close_suite()
	await _board_heights(tree)
	t.close_suite()


# --- logic -------------------------------------------------------------------

## The tip has to point at a *legal* merge, and at the most valuable one.
func _hint() -> void:
	t.suite("Merge 3D — Tipp")
	var empty := Merge3D.create_board(6)
	t.check(Merge3D.find_hint(empty, 3).is_empty(), "Ein leeres Brett hat keinen Tipp")

	# Two of a kind, one of another: nothing to merge yet.
	var board := Merge3D.create_board(6)
	board[0] = 1
	board[1] = 1
	board[2] = 3
	t.check(Merge3D.find_hint(board, 3).is_empty(), "Zerstreute Items ergeben keinen Tipp")
	t.equal(Merge3D.merge_opportunities(board, 3), 0, "und keine Gelegenheit")

	# The third one arrives — now there is something to point at.
	board[3] = 1
	var hint := Merge3D.find_hint(board, 3)
	t.equal(hint.size(), 3, "Der Tipp nennt drei Felder")
	t.equal(Array(hint), [0, 1, 3], "Er zählt die Felder von klein nach groß")
	t.check(Merge3D.merge_is_valid(board, hint, 3), "Der Tipp ist selbst ein gültiger Merge")
	t.equal(Merge3D.merge_opportunities(board, 3), 1, "Das Brett hat eine Gelegenheit")

	# Seven low items, but a triple of the next tier: the tip takes the better
	# merge, because that is the one worth points.
	board[4] = 2
	board[5] = 2
	board[6] = 2
	for i in range(7):
		board[i + 10] = 1
	t.equal(Array(Merge3D.find_hint(board, 3)), [4, 5, 6], "Der Tipp nimmt die höchste Stufe")

	# Nothing above the maximum tier may ever be suggested.
	var maxed := Merge3D.create_board(6)
	for i in maxed.size():
		maxed[i] = Merge3D.MAX_MERGE_TIER
	t.check(Merge3D.find_hint(maxed, 3).is_empty(), "Max-Stufen werden nicht gemergt")
	t.equal(Merge3D.merge_opportunities(maxed, 3), 0, "und zählen als keine Gelegenheit")

	# 5er mode asks for five and gets nothing until it can get five.
	var wide := Merge3D.create_board(6)
	for i in 4:
		wide[i] = 1
	t.check(Merge3D.find_hint(wide, 5).is_empty(), "Vier gleiche sind kein 5er-Merge")
	wide[4] = 1
	wide[5] = 1
	wide[6] = 1
	t.equal(Merge3D.find_hint(wide, 5).size(), 5, "Fünf gleiche ergeben einen 5er-Tipp")
	t.equal(Merge3D.merge_opportunities(wide, 5), 1, "Der 5er-Tipp ist eine Gelegenheit")
	t.equal(Merge3D.merge_opportunities(wide, 3), 2, "Für den 3er-Merge sind es zwei")

	# The invariant the tip button leans on: both questions get one answer.
	var mixed := Merge3D.create_board(6)
	mixed[0] = 4
	mixed[1] = 4
	mixed[2] = 4
	mixed[3] = 3
	t.equal(Merge3D.has_merge_available(mixed), not Merge3D.find_hint(mixed, 3).is_empty(),
		"has_merge_available und der Tipp sind sich einig")
	t.check(Merge3D.find_hint(empty, 0).is_empty(), "Ein Tipp ohne Ziel ist kein Tipp")
	t.equal(Merge3D.merge_score(2, 3), 9, "Drei Stufe-2er sind 9 Punkte wert")
	t.equal(Merge3D.merge_score(2, 5), 15, "Fünf Stufe-2er sind 15 Punkte wert")
	t.equal(Merge3D.merge_score(2, 0), 0, "Nichts gemergt ist nichts wert")
	t.suite_done()


## What the tip says, and when it decides to offer itself.
func _hint_text_and_pressure() -> void:
	t.suite("Merge 3D — Tipptext und Brettdruck")
	var board := Merge3D.create_board(6)
	t.check(not Merge3D.is_pressing(board), "Ein leeres Brett ist nicht unter Druck")
	for i in board.size() - Merge3D.PRESSURE_CELLS - 1:
		board[i] = 1
	t.check(not Merge3D.is_pressing(board), "Fünf freie Felder sind noch Luft")
	board[board.size() - Merge3D.PRESSURE_CELLS] = 1
	t.check(Merge3D.is_pressing(board), "Vier freie Felder sind Druck")
	t.check(not Merge3D.is_pressing(board, 0), "Mit der Grenze null zählt nur ein volles Brett")
	var tiny := Merge3D.create_board(3)
	for i in tiny.size():
		tiny[i] = Merge3D.MAX_MERGE_TIER
	t.check(Merge3D.is_pressing(tiny, 0), "Ein volles 3x3-Brett ist unter Druck")

	var christmas := Merge3D.theme_by_id(Merge3D.THEME_CHRISTMAS)
	var cells := PackedInt32Array([0, 1, 2])
	board[0] = 1
	board[1] = 1
	board[2] = 1
	var text := Merge3D.hint_text(christmas, board, cells)
	t.check(text.contains("Tannenzapfen"), "Der Tipptext nennt die Ausgangsstufe")
	t.check(text.contains("Zuckerstange"), "und die Zielstufe")
	t.check(text.contains("+3"), "und den Gewinn")
	t.equal(Merge3D.hint_text(christmas, board, PackedInt32Array()), "",
	"Ohne Felder gibt es keinen Tipptext")
	t.check(Merge3D.hint_text(Merge3D.theme_by_id(Merge3D.THEME_HALLOWEEN), board, cells).contains("Süßigkeit"),
	"Halloween benutzt seine eigenen Tiernamen")
	t.suite_done()


# --- screen ------------------------------------------------------------------

## The tip on the real screen: the button marks a merge, "Verschmelzen" finishes
## it, and a player who sits still on a closing board gets it offered.
func _screen_hint(tree: SceneTree) -> void:
	t.suite("Merge 3D — Tipp am Screen")
	t.check(_router != null, "Der Router ist erreichbar")
	if _router == null:
		t.suite_done()
		return
	if not await t.goto(_router, tree, "merge3d_christmas"):
		t.check(false, "Der Weihnachts-Screen öffnet")
		t.suite_done()
		return
	var screen = _router.current_screen
	t.check(screen != null, "Der Weihnachts-Screen öffnet")
	if screen == null:
		t.suite_done()
		return
	t.check(screen._hint_button != null, "Der Tipp-Knopf sitzt im HUD")
	t.check(screen._hint_label != null, "Die Tipp-Zeile sitzt im HUD")

	# A board the player can see: three of a kind and nothing else.
	_lay_out(screen, {0: 2, 7: 2, 14: 2})
	screen._show_hint()
	t.equal(screen.selected.size(), 3, "Der Tipp wählt drei Felder")
	t.check(screen.hint_cells.has(0) and screen.hint_cells.has(14), "Er markiert genau die drei Gleichen")
	t.check(screen._hint_label.text.contains("Zuckerstange"), "Die Zeile nennt den Ertrag")
	t.check(screen.hint_until > screen.elapsed, "Der Tipp pulsiert eine Weile")

	var score_before: int = screen.score
	screen._try_merge()
	t.check(screen.score > score_before, "Der Merge über den Tipp bringt Punkte")
	t.check(screen.hint_cells.is_empty(), "Nach dem Merge ist der Tipp weg")
	t.equal(screen.selected.size(), 0, "und die Auswahl ist leer")

	# A tap of the player's own ends the tip.
	_lay_out(screen, {1: 1, 2: 1, 3: 1})
	screen._show_hint()
	t.equal(screen.hint_cells.size(), 3, "Der Tipp markiert wieder drei Felder")
	screen._toggle_cell(1)
	t.check(screen.hint_cells.is_empty(), "Ein eigener Tipppunkt beendet den Tipp")
	t.equal(screen.selected.size(), 2, "Die Auswahl gehört wieder dem Spieler")

	# Nothing to merge: the tip says so instead of pointing at thin air.
	_lay_out(screen, {0: 1, 1: 2})
	screen._show_hint()
	t.check(screen.hint_cells.is_empty(), "Ohne drei Gleiche markiert der Tipp nichts")
	t.check(screen._hint_label.text.contains("nichts zu mergen"), "Der Tipp sagt, dass nichts zu mergen ist")

	# 5er mode: a triple is still a legal merge there, so the tip offers it and
	# the merge button takes the fallback.
	_lay_out(screen, {0: 1, 1: 1, 2: 1})
	screen.required = Merge3D.MERGE_5
	screen._show_hint()
	t.equal(screen.selected.size(), 3, "Im 5er-Modus bietet der Tipp den 3er-Merge an")
	t.check(Merge3D.merge_is_valid(screen.board, screen.selected, Merge3D.MERGE_3),
		"Der Tipp ist auch im 5er-Modus ein gültiger Merge")
	score_before = screen.score
	screen._try_merge()
	t.check(screen.score > score_before, "Der 3er-Fallback aus dem Tipp bringt Punkte")
	screen.required = Merge3D.MERGE_3

	# The rule line follows the mode, so it never contradicts the tip.
	screen._toggle_mode()
	t.equal(screen.required, Merge3D.MERGE_5, "Der Modus wechselt auf den 5er-Merge")
	t.check(screen._instruction_label.text.contains("5 gleiche"), "Die Regelzeile nennt fünf gleiche Items")
	screen._toggle_mode()
	t.equal(screen.required, Merge3D.MERGE_3, "und wieder zurück auf drei")

	# Under pressure and idle, the board offers the merge by itself.
	var crowded := {0: 1, 1: 1, 2: 1, 3: 4, 4: 4, 5: 4}
	for i in range(6, screen.board.size() - 2):
		crowded[i] = 1
	_lay_out(screen, crowded)
	screen.spawn_timer = 5.0
	screen.since_merge = 99.0
	screen._update_world(0.016)
	t.equal(screen.selected.size(), 3, "Der Tipp kommt von selbst, wenn das Brett fast voll ist")
	t.check(Merge3D.is_pressing(screen.board), "Das Brett stand wirklich unter Druck")
	t.check(screen.since_merge < 1.0, "Der Idle-Zähler startet danach neu")
	t.check(screen._hint_label.text.contains("Tipp:"), "Der automatische Tipp sagt, was er anbietet")

	# On a board with room to breathe it stays quiet.
	_lay_out(screen, {0: 1, 1: 1, 2: 1})
	screen.spawn_timer = 5.0
	screen.since_merge = 99.0
	screen._update_world(0.016)
	t.check(screen.hint_cells.is_empty(), "Auf einem leeren Brett bietet sich der Tipp nicht an")
	await tree.create_timer(0.2).timeout
	_router.go_to("lobby")
	t.suite_done()


# --- board heights -----------------------------------------------------------

## The world-space box of everything a `Node3D` draws, scale included.
##
## Not `WorldScreen.bounds_of`: that measures every mesh in the space of the
## mesh's *own parent*, which is the node's space for its children and one
## level too high when the node **is** the MeshInstance3D — which is exactly
## what the ground, the plate and the tiles are. Their position would then be
## counted twice and every height measured here would be wrong by that much.
func _world_box(node: Node3D) -> AABB:
	var found := false
	var out := AABB()
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		out = node.global_transform * (node as MeshInstance3D).mesh.get_aabb()
		found = true
	for child in node.get_children():
		if child is Node3D:
			var box := _world_box(child as Node3D)
			if box.has_surface():
				out = box if not found else out.merge(box)
				found = true
	return out


## The board's horizontal surfaces, measured on the real screen instead of read
## from the constants that build it: two faces in the same plane fight over the
## depth buffer and flicker (Godot docs, "Depth buffer precision"), and this
## screen moves its camera every frame, so the fight never settles. The plate
## used to end flush with the ground — both tops at y = 0.0.
##
## The items are measured too. Every tier mesh is centred on its own origin and
## the five differ in height by a factor of five, so a single base height for
## all of them left the flat gingerbread star hovering in mid-air and let a
## selected item sink a third of itself into its tile.
func _board_heights(tree: SceneTree) -> void:
	t.suite("Merge 3D — Boardhöhen")
	if not await t.goto(_router, tree, "merge3d_christmas"):
		t.check(false, "Der Weihnachts-Screen öffnet")
		t.suite_done()
		return
	var screen = _router.current_screen
	t.check(screen != null, "Der Weihnachts-Screen steht")
	if screen == null:
		t.suite_done()
		return

	# One item of every tier, so the flat and the tall one are both measured.
	# No spawns while the frame loop is wound on: the board under test is the
	# one this suite laid out.
	screen.spawn_timer = 999.0
	_lay_out(screen, {7: 1, 8: 2, 9: 3, 15: 4, 21: 5})

	# The board itself: the ground, the plate under the grid and the tiles.
	# Only the meshes the screen hangs on itself — an item's geometry hangs on
	# the item node, so the two never get mixed up. The three are told apart by
	# the size the screen builds them with; the scene names none of them.
	var ground_top := -INF
	var plate_top := -INF
	var plate_bottom := INF
	var tile_top := -INF
	var tile_bottom := INF
	var tiles := 0
	var stack: Array[Node] = [screen]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D and node.get_parent() == screen:
			var size: Vector3 = (node as MeshInstance3D).mesh.get_aabb().size
			var box := _world_box(node as Node3D)
			if is_equal_approx(size.x, float(screen.GRID) * float(screen.CELL) + 1.2):
				plate_top = maxf(plate_top, box.end.y)
				plate_bottom = minf(plate_bottom, box.position.y)
			elif is_equal_approx(size.x, float(screen.CELL) * 0.9):
				tiles += 1
				tile_top = maxf(tile_top, box.end.y)
				tile_bottom = minf(tile_bottom, box.position.y)
			elif size.x > size.y:
				ground_top = maxf(ground_top, box.end.y)
		for child in node.get_children():
			stack.append(child)
	t.equal(tiles, screen.GRID * screen.GRID, "Alle Kacheln des Bretts sind gebaut")
	# The measure of the whole suite: three surfaces, three heights. A pair at
	# the same height is the flicker the player reported. The numbers travel
	# with the claim — a failure without them is a riddle.
	t.check(absf(ground_top - plate_top) > 0.005,
		"Boden und Brettplatte liegen nicht in derselben Ebene (%.3f / %.3f)"
			% [ground_top, plate_top])
	t.check(absf(plate_top - tile_top) > 0.005,
		"Brettplatte und Kacheln liegen nicht in derselben Ebene (%.3f / %.3f)"
			% [plate_top, tile_top])
	t.check(tile_bottom > plate_top,
		"Die Kacheln liegen auf der Platte statt darüber zu schweben (%.3f / %.3f)"
			% [tile_bottom, plate_top])
	t.check(plate_bottom < ground_top,
		"Die Brettplatte steckt in den Boden statt mit ihm zu verschmelzen (%.3f / %.3f)"
			% [plate_bottom, ground_top])

	# Every item stands on its tile. The rest height carries one bob of headroom
	# on top of the clearance, so the *lowest* point of the bob — not its middle
	# — is what rests on the tile. And all five rest at the same height, because
	# that height is read from each mesh instead of shared by all of them: a flat
	# gingerbread star used to hang at the height of a bauble, in mid-air, a
	# unit above its own tile.
	var resting := -INF
	var resting_low := INF
	for cell in screen.items:
		var box := _world_box((screen.items[cell] as Dictionary)["node"])
		resting_low = minf(resting_low, box.position.y)
		resting = maxf(resting, box.position.y)
	t.check(resting - tile_top <= 2.0 * screen.ITEM_BOB + 0.005,
		"Die Items ruhen auf ihrer Kachel statt darüber zu schweben (%.3f / %.3f)"
			% [resting - tile_top, 2.0 * screen.ITEM_BOB])
	t.almost(resting_low, resting, 0.005,
		"Alle Items liegen gleich hoch — auch das flachste")

	# The bob may lift an item; it may not sink one into its tile, and it is the
	# only thing that moves them.
	var lowest := INF
	var highest := -INF
	for i in 8:
		screen._update_world(0.05)
		for cell in screen.items:
			var y: float = _world_box((screen.items[cell] as Dictionary)["node"]).position.y
			lowest = minf(lowest, y)
			highest = maxf(highest, y)
	t.check(lowest >= tile_top,
		"Kein Item taucht beim Wippen in seine Kachel hinein (%.3f / %.3f)"
			% [lowest, tile_top])
	t.check(highest - lowest <= 2.0 * screen.ITEM_BOB + 0.005,
		"Der Wipper bewegt die Items um nichts als um sich selbst (%.3f / %.3f)"
			% [highest - lowest, 2.0 * screen.ITEM_BOB])

	# The selected item grows upwards out of the board instead of into it.
	screen.selected = PackedInt32Array([15, 21])
	screen._clear_hint()
	for i in 40:
		screen._update_world(0.05)
	var selected_node: Node3D = (screen.items[15] as Dictionary)["node"]
	t.check(selected_node.scale.x > screen.ITEM_SCALE, "Das ausgewählte Item ist gewachsen")
	t.check(_world_box(selected_node).position.y >= tile_top,
		"Ein ausgewähltes Item sinkt nicht in die Kachel hinein (%.3f / %.3f)"
			% [_world_box(selected_node).position.y, tile_top])
	# And the pool hands the node back with the height that goes with the scale:
	# a reused node starts on the tile, not where the selected one stood.
	screen._remove_item_node(15)
	screen.board[35] = 4
	screen._add_item_node(35, 4, false)
	var reused: Node3D = (screen.items[35] as Dictionary)["node"]
	t.check(_world_box(reused).position.y >= tile_top,
		"Ein aus dem Pool genommener Knoten startet wieder auf der Kachel (%.3f / %.3f)"
			% [_world_box(reused).position.y, tile_top])
	await tree.create_timer(0.2).timeout
	_router.go_to("lobby")
	t.suite_done()


## Puts a board of the test's own making onto the screen, nodes included.
func _lay_out(screen, cells: Dictionary) -> void:
	for cell in screen.items.keys():
		screen._remove_item_node(int(cell))
	screen.board = Merge3D.create_board(6)
	screen.selected = PackedInt32Array()
	screen.hint_cells = PackedInt32Array()
	screen.hint_until = 0.0
	for cell in cells:
		screen.board[int(cell)] = int(cells[cell])
		screen._add_item_node(int(cell), int(cells[cell]), false)
	screen._refresh()
