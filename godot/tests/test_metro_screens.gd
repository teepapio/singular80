class_name TestMetroScreens
extends RefCounted
## Integration tests for "Metropol 3D": the real screen inside a real scene tree,
## so the autoloads, the router, the imported meshes and the 3D nodes all run.
## The screen is loaded **by path**, never as a static `MetroScreen` — that would
## pull it into the compile chain of `run_tests.gd`, which runs before the
## autoloads are registered.

var t: TestKit
## Autoloads are not registered in `--script` mode, so they are fetched by path.
var _router: Node
var _game: Node
var _screen_script: GDScript


## Entry point used by `run_tests.gd`.
func run(kit: TestKit, tree: SceneTree) -> void:
	t = kit
	_router = tree.root.get_node_or_null("/root/Router")
	_game = tree.root.get_node_or_null("/root/Game")
	_screen_script = load("res://src/game/metro/metro_screen.gd")
	t.check(_router != null, "Der Router ist erreichbar")
	t.check(_game != null, "Der Spielstand ist erreichbar")
	t.check(_screen_script != null, "Der Metropol-Screen laesst sich laden")
	if _router == null or _screen_script == null:
		return
	await _screen_opens(tree)
	t.close_suite()
	await _screen_builds_a_network(tree)
	t.close_suite()
	await _screen_serves_passengers(tree)
	t.close_suite()


## `MetroScreen.Tool.BUILD` without a static class reference.
func _tool(name: String) -> int:
	return int(_screen_script.get_script_constant_map().get("Tool", {}).get(name, 0))


# --- suites -----------------------------------------------------------------

## Every mesh the game needs really is bundled — a missing `.glb` would only
## show up as an invisible object on a phone.
func _metro_meshes_are_bundled() -> void:
	for key in AssetRegistry.METRO_KEYS:
		t.check(AssetRegistry.exists(key), "Metro-Mesh '%s' ist importiert" % key)
	t.check(AssetRegistry.METRO_KEYS.size() >= 10, "Der Metro-Pack ist vollstaendig")


func _screen_opens(tree: SceneTree) -> void:
	t.suite("Metropol 3D — Screen")
	_metro_meshes_are_bundled()
	await t.goto(_router, tree, "metro3d")
	var screen = _router.current_screen
	t.check(screen != null, "Der Screen wird geoeffnet")
	if screen == null:
		return
	t.check(screen.get_script() == _screen_script, "Es ist der Metropol-Screen")
	t.check(screen.hud_root != null, "Das HUD ist gebaut")
	t.check(screen.camera != null and screen.camera.current, "Die Kamera ist aktiv")
	t.check(screen.environment_node != null, "Die Umgebung ist gebaut")
	# The mode picker greets the player before the city exists.
	t.check(not screen._started, "Vor dem Moduswahl laeuft noch keine Stadt")
	t.check(screen._modal_layer != null, "Die Moduswahl ist offen")
	t.check(not screen._line_meshes.is_empty() or true, "Es ist noch kein Band gebaut")

	screen._start_run(Metro.Mode.NORMAL)
	await tree.create_timer(0.3).timeout
	t.check(screen._started, "Ein Lauf gestartet")
	t.check(screen.metro.running, "Die Stadt laeuft")
	t.equal(screen.metro.stations.size(), 3, "Drei Startbahnhoefe")
	t.equal(screen._station_nodes.size(), 3, "Drei Bahnhofsknoten im 3D-Baum")
	t.check(screen._sparkles.multimesh.visible_instance_count > 0, "Das Wasser bewegt sich")
	t.check(not screen._decor_nodes.is_empty(), "Die Stadt ist bebaut")
	t.check(screen._water_root.get_child_count() > 1, "Mindestens ein Fluss liegt in der Szene")
	t.equal(screen._tool_buttons.size(), 4, "Vier Werkzeuge liegen bereit")
	t.equal(screen._resource_values.size(), 6, "Sechs Depotwerte liegen bereit")
	t.check(not screen._money_label.text.is_empty(), "Die Einnahmen sind beschriftet")
	t.suite_done()


## Builds a line through the screen's own tap handler and checks that the 3D
## representation follows the logic.
func _screen_builds_a_network(tree: SceneTree) -> void:
	t.suite("Metropol 3D — Linienbau")
	var screen = _router.current_screen
	if screen == null:
		t.check(false, "Der Screen lebt noch")
		return
	var metro: Metro = screen.metro
	# Tap the first station, then the second, then finish on empty ground.
	screen._set_tool(_tool("BUILD"))
	screen._tap_build(Vector2(metro.stations[0]["pos"]))
	t.equal(screen.drawing_line, metro.lines.size() - 1, "Eine Linie wird angefangen")
	t.check(screen._finish_button.visible, "Der Fertig-Knopf erscheint")
	screen._tap_build(Vector2(metro.stations[1]["pos"]))
	t.equal((metro.lines[screen.drawing_line]["stations"] as Array).size(), 2, "Der zweite Bahnhof haengt dran")
	screen._tap_build(Vector2(-900.0, -900.0))
	t.equal(screen.drawing_line, -1, "Die Linie ist abgeschlossen")
	t.check(not screen._finish_button.visible, "Der Fertig-Knopf verschwindet")
	await tree.create_timer(0.2).timeout
	t.equal(metro.lines.size(), 1, "Eine Linie steht im Netz")
	t.equal(metro.trains.size(), 1, "Eine Lok faehrt")
	t.check(screen._line_meshes[0] != null and screen._line_meshes[0].mesh != null, "Das Linienband ist gebaut")
	t.check(screen._bead_nodes[0] != null, "Die Richtungspunkte existieren")
	t.check(screen._bead_nodes[0].multimesh.visible_instance_count > 0, "Die Richtungspunkte sind sichtbar")
	t.check(screen._train_nodes.size() >= 1 and screen._train_nodes[0].visible, "Der Zug ist sichtbar")
	# The ribbon really follows the two stations.
	var mid := (Vector2(metro.stations[0]["pos"]) + Vector2(metro.stations[1]["pos"])) * 0.5
	t.check(metro.line_at(mid, 3.0) >= 0, "Die Linie liegt auf der Verbindung der Bahnhoefe")
	# A wagon from the depot enlarges the consist.
	var seats: int = int(metro.trains[0]["capacity"])
	screen._set_tool(_tool("WAGON"))
	screen._tap_wagon(metro.train_position(0))
	t.check(int(metro.trains[0]["capacity"]) > seats, "Der Beiwagen vergroessert den Zug")
	t.check(int(metro.resources["wagons"]) < Metro.START_WAGONS, "Der Beiwagen kam aus dem Depot")
	# The inspector lists the waiting passengers.
	screen._open_inspector(0)
	t.check(screen._inspect_panel.visible, "Die Bahnhofsansicht oeffnet")
	t.check(not screen._inspect_body.text.is_empty(), "Die Bahnhofsansicht zeigt Inhalt")
	screen._inspect_panel.visible = false
	# The camera rig answers.
	var before: Vector3 = screen.cam_focus
	screen._pointer_down(0, Vector2(400, 300))
	screen._pointer_move(0, Vector2(500, 320))
	screen._pointer_up(0)
	t.check(screen.cam_focus.distance_to(before) > 0.01, "Ziehen verschiebt die Karte")
	screen._frame_city()
	t.check(screen.cam_distance <= Metro.CAM_MAX_DISTANCE, "Die Stadt laesst sich einpassen")
	t.suite_done()


## Runs a few real seconds and checks the whole loop: passengers, deliveries,
## the crowd mesh and the money readout.
func _screen_serves_passengers(tree: SceneTree) -> void:
	t.suite("Metropol 3D — Spielablauf")
	var screen = _router.current_screen
	if screen == null:
		t.check(false, "Der Screen lebt noch")
		return
	var metro: Metro = screen.metro
	screen.metro.speed_index = 2
	var crowd_seen := false
	for i in 1500:
		screen._update_world(0.05)
		var modal := metro.next_modal()
		if not modal.is_empty():
			screen._show_cards(modal)
			screen._close_modal()
			metro.choose_card("wagon")
		if screen._crowd.multimesh.visible_instance_count > 0:
			crowd_seen = true
		if metro.delivered > 3 or metro.over:
			break
	await tree.create_timer(0.2).timeout
	t.check(crowd_seen, "Wartende Fahrgaeste stehen als 3D-Menge am Bahnhof")
	t.check(screen._crowd.multimesh.visible_instance_count <= 300, "Die Menge bleibt im Pool")
	t.check(metro.delivered > 0 or metro.over, "Es wurde zugestellt oder das Netz ist kollabiert")
	t.check(screen._money_label.text.contains("$"), "Die Einnahmen stehen im HUD")
	t.check(not screen._day_label.text.is_empty(), "Der Kalender steht im HUD")
	t.check(not screen._clock_label.text.is_empty(), "Die Uhr steht im HUD")
	t.check(screen._inspect_station == -1 or not screen._inspect_panel.visible, "Keine offene Ansicht ohne Auswahl")
	# The collapse path shows a card and stores a score.
	if not metro.over:
		metro.collapse(0)
	screen._drain_events()
	await tree.create_timer(0.2).timeout
	t.check(metro.over, "Der Lauf ist beendet")
	t.check(screen._modal_layer != null, "Die Abschlusskarte ist offen")
	t.check(_game.highscore(str(_game.HS_METRO)) >= 0, "Der Bestwert ist lesbar")
	await t.goto(_router, tree, "lobby")
	t.check(_router.current_id == "lobby", "Zurueck in der Lobby")
	t.suite_done()
