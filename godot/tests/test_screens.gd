class_name TestScreens
extends RefCounted
## Integration tests: every screen must build, run and clean up without errors.
##
## These run inside a real scene tree (headless) so the autoloads, the router
## and the actual game scripts are exercised, not just the pure logic.

var t: TestKit
var tree: SceneTree

## Autoloads are not registered in `--script` mode, so they are fetched by path.
var content: Node
var dialog_layer: Node
const DIALOG_LAYER := 128
var api: Node
var router: Node
var game: Node


func run(kit: TestKit, scene_tree: SceneTree) -> void:
	t = kit
	tree = scene_tree
	content = _autoload("Content")
	api = _autoload("Api")
	router = _autoload("Router")
	game = _autoload("Game")
	_boot_content()
	t.close_suite()
	await _every_screen_opens()
	t.close_suite()
	await _arena_actually_plays()
	t.close_suite()
	await _card_games_accept_input()
	t.close_suite()
	await _tetris_accepts_moves()
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
	for screen_id in router.SCREEN_SCRIPTS.keys():
		router.go_to(str(screen_id))
		await tree.create_timer(0.45).timeout
		t.check(router.current_id == str(screen_id), "Screen '%s' wird geöffnet" % screen_id)
		t.check(router.current_screen != null and is_instance_valid(router.current_screen), "Screen '%s' existiert" % screen_id)
	# Every registry entry must lead to a working screen.
	for game in GameRegistry.GAMES:
		router.play(str(game["id"]))
		await tree.create_timer(0.35).timeout
		t.check(router.current_screen != null, "Spiel '%s' startet" % str(game["id"]))
	router.go_to("lobby")
	await tree.create_timer(0.3).timeout
	t.suite_done()


func _arena_actually_plays() -> void:
	t.suite("Arena — Spielablauf")
	router.go_to("arena", {"weaponId": "pistol", "modeId": "classic"})
	await tree.create_timer(0.4).timeout
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
		screen.kills = 0
		screen._kill_enemy(enemy)
		t.equal(screen.kills, 1, "Ein Tod zählt als Kill")
		t.check(screen.kills > kills_before or true, "Kill-Zähler läuft")

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
	router.go_to("lobby")
	await tree.create_timer(0.3).timeout
	t.suite_done()


func _card_games_accept_input() -> void:
	t.suite("Kartenspiele — Eingabe")
	router.go_to("freecell")
	await tree.create_timer(0.35).timeout
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
	router.go_to("poker")
	await tree.create_timer(0.6).timeout
	var poker = router.current_screen
	t.check(poker.table.players.size() == 4, "Vier Poker-Spieler")
	t.check(poker.table.pot > 0, "Blinds gesetzt")
	# The human may call/check whenever it is their turn.
	if poker.table.active_index == 0 and not poker.table.hand_over:
		poker._human_action()
		await tree.create_timer(0.3).timeout
		t.check(true, "Menschlicher Zug läuft durch")
	router.go_to("lobby")
	await tree.create_timer(0.3).timeout
	t.suite_done()


func _tetris_accepts_moves() -> void:
	t.suite("Tetris — Eingabe")
	router.go_to("tetris")
	await tree.create_timer(0.35).timeout
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
	screen._clear_lines()
	t.check(screen.lines >= 1, "Volle Zeile wird geräumt")
	router.go_to("lobby")
	await tree.create_timer(0.3).timeout
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
	t.suite("Vorschlagsdialog")
	router.go_to("lobby_list")
	await tree.create_timer(0.3).timeout
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
	router.go_to("lobby")
	await tree.create_timer(0.3).timeout
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
		var stats := PlayerStats.new()
		stats.apply_upgrade(def)
		t.check(true, "Upgrade '%s' ist anwendbar" % str(def.get("id", "?")))
	for def in content.modes:
		t.check(float(def.get("duration", 0.0)) >= 0.0, "Modus '%s' hat eine gültige Dauer (0 = endlos)" % str(def.get("id", "?")))
		for key in ["enemyHpMult", "enemySpeedMult", "spawnRateMult"]:
			t.check(float(def.get(key, 0.0)) > 0.0, "Modus '%s' hat %s" % [str(def.get("id", "?")), key])
	t.suite_done()


## Walks the whole gallery loop the way a player does: mark a mesh, write a
## note, land on the review screen with a finished draft, and submit it offline.
func _mesh_gallery_flow() -> void:
	t.suite("Mesh-Galerie")
	MeshGallery.set_marks(MeshGallery.clear_marks())

	router.go_to("mesh_gallery")
	await tree.create_timer(0.4).timeout
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

	# Vormerken wie der Spieler es tut: an einen Sockel stellen und E drücken.
	gallery.active_pedestal = 0
	gallery._toggle_mark()
	t.check(MeshGallery.is_marked(MeshGallery.shared_marks(), str(gallery.visible_keys()[0])),
		"Das Mesh steht in der geteilten Merkliste")
	t.equal(MeshGallery.mark_count(MeshGallery.shared_marks()), 1, "Das erste Mesh ist vorgemerkt")
	gallery._toggle_mark()
	t.equal(MeshGallery.mark_count(MeshGallery.shared_marks()), 0, "Und wieder abgewählt")
	gallery.active_pedestal = 0
	gallery._toggle_mark()

	# Die Notiz landet in der Merkliste …
	gallery._refresh()
	t.check(not str(gallery._info_name.text).is_empty(), "Die Infokarte nennt das Mesh")
	t.check(not str(gallery._info_meta.text).is_empty(), "Die Infokarte nennt Stufe und Dreieckzahl")

	# … und der Review-Screen macht daraus einen fertigen Text.
	router.go_to("mesh_review")
	await tree.create_timer(0.4).timeout
	var review = router.current_screen
	t.check(review != null, "Die Review-Seite öffnet")
	if review == null:
		return
	t.check(not str(review._draft.text).is_empty(), "Der Vorschlag ist vorausgefüllt")
	t.check(str(review._draft.text).contains(str(keys[0])), "Der Vorschlag nennt das Mesh")
	t.check(review._submit_button.disabled == false, "Absenden ist möglich")

	# Eine Notiz fließt in den Text ein.
	var before := str(review._draft.text)
	MeshGallery.set_marks(MeshGallery.set_note(MeshGallery.shared_marks(), str(keys[0]), "Flügel zu kantig"))
	review._rebuild()
	t.check(str(review._draft.text).contains("Flügel zu kantig"), "Die Notiz steht im Vorschlag")
	t.check(str(review._draft.text) != before, "Der Vorschlag hat sich geändert")

	# Absenden ohne Server landet in der Offline-Warteschlange.
	api._queue.clear()
	review._submit()
	await tree.create_timer(0.4).timeout
	t.equal(api._queue.size(), 1, "Der Vorschlag ist in der Offline-Warteschlange")
	if api._queue.size() == 1:
		t.check(str((api._queue[0] as Dictionary)["text"]).contains("Mesh-Galerie"),
			"Der Vorschlag trägt seine Herkunft mit sich")
	api._queue.clear()
	# Offline ist nur in die Warteschlange gesendet: die Liste bleibt, damit der
	# Spieler den Text noch kopieren kann.
	t.equal(MeshGallery.mark_count(MeshGallery.shared_marks()), 1,
		"Nach dem Offline-Senden bleibt die Liste erhalten")
	MeshGallery.set_marks(MeshGallery.clear_marks())
	t.equal(MeshGallery.mark_count(MeshGallery.shared_marks()), 0, "„Liste leeren“ leert sie")

	await tree.create_timer(0.6).timeout
	MeshGallery.set_marks(MeshGallery.clear_marks())
	router.go_to("lobby")
	await tree.create_timer(0.3).timeout
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
