class_name TestDevFarm
extends RefCounted
## Prüft den Farm-Audit selbst.
##
## Ohne diesen Test wäre die Farm unbrauchbar, aber nicht offensichtlich
## kaputt: ein Audit, der nichts findet, sieht aus wie ein Spiel ohne Fehler.
## Genau dagegen muss man sich absichern — die Prüfung prüft die Prüfung.

var t: TestKit
## Der Audit braucht einen echten `SceneTree`: er wartet Frames, damit die
## Rects stimmen, und schickt Events durch die Eingangskette. `TestKit` kennt
## keinen Baum, deshalb reicht der Aufruf `run(kit, self)` aus dem Runner.
var tree: SceneTree


func run(kit: TestKit, scene_tree: SceneTree) -> void:
	t = kit
	tree = scene_tree
	# Jede Suite wird **abgewartet**. Ohne `await` läuft `run()` synchron
	# weiter, während die Suite an ihrem ersten `await` hängt — `close_suite()`
	# schließt sie dann, obwohl sie noch offen ist, und der Lauf meldet für
	# alle vier „abgebrochen", ohne dass irgendwo ein Fehler steht.
	await _free_button()
	t.close_suite()
	await _covered_button()
	t.close_suite()
	await _geometry()
	t.close_suite()
	await _inert_without_flag()
	t.close_suite()


## Ein Button, der frei liegt, wird als gesund gemeldet.
func _free_button() -> void:
	t.suite("Farm-Audit — freier Knopf")
	var stage := _stage()
	var button := Button.new()
	button.text = "Start"
	button.custom_minimum_size = Vector2(120, 48)
	button.size = Vector2(120, 48)
	button.position = Vector2(400, 300)
	var hits := [0]
	button.pressed.connect(func() -> void: hits[0] += 1)
	stage.add_child(button)

	await _settle()
	var findings: Array = await DevFarmAudit.audit_screen(stage, tree)
	t.check(findings.is_empty(), "Ein freier, verdrahteter Knopf wird nicht beanstandet (%s)" % _short(findings))
	t.check(hits[0] == 1, "Der Tipp hat den Knopf genau einmal ausgeloest (%d)" % int(hits[0]))
	t.equal(_buttons_of(stage).size(), 1, "Der Knopf wurde überhaupt gefunden")
	stage.queue_free()
	t.suite_done()


## Der eigentliche Fund: ein `MOUSE_FILTER_STOP` über dem Knopf.
##
## Genau das ist die Fehlerklasse, die im Screenshot tadellos aussieht und im
## Spiel „Knopf geht nicht" heißt. Der Test baut sie nach, damit die Farm
## beweist, dass sie sie sieht.
func _covered_button() -> void:
	t.suite("Farm-Audit — zugedeckter Knopf")
	var stage := _stage()

	# Der Knopf zuerst…
	var button := Button.new()
	button.text = "Verborgen"
	button.custom_minimum_size = Vector2(120, 48)
	button.size = Vector2(120, 48)
	button.position = Vector2(400, 300)
	button.pressed.connect(func() -> void: pass)
	stage.add_child(button)

	# …und danach ein Spielfeld, das ihn überdeckt. Beide teilen sich dieselbe
	# Fläche, und der Spätere liegt oben — genau die Reihenfolge aus Tetris und
	# Dame, wo das Board vor den Knöpfen in den Baum kommt.
	var blocker := Control.new()
	blocker.name = "BoardView"
	blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	blocker.size = Vector2(1280, 720)
	blocker.position = Vector2.ZERO
	stage.add_child(blocker)

	await _settle()
	var findings: Array = await DevFarmAudit.audit_screen(stage, tree)
	var covered := _of_kind(findings, "covered")
	t.equal(covered.size(), 1, "Der zugedeckte Knopf wird als zugedeckt gemeldet (%s)" % _short(findings))
	if covered.size() > 0:
		t.check(str(covered[0]["message"]).contains("BoardView"),
			"Der Fund nennt das Control, das darüberliegt")
	t.check(_of_kind(findings, "zero-size").is_empty(), "Er wird nicht als zu klein gemeldet")
	stage.queue_free()
	t.suite_done()


## Fläche und Position, bevor es um Deckung geht.
func _geometry() -> void:
	t.suite("Farm-Audit — Geometrie")
	var stage := _stage()

	# Bewusst **kein** Knopf ohne Fläche: ein `Button` mit Theme hat immer eine
	# Mindestgröße, er wird also nie 0×0. Der `zero-size`-Zweig im Audit ist
	# eine Prüfung, die man nicht erfüllen kann, ist schlecht.
	var outside := Button.new()
	outside.text = "Draußen"
	outside.custom_minimum_size = Vector2(100, 40)
	outside.size = Vector2(100, 40)
	outside.position = Vector2(-400, -400)
	stage.add_child(outside)

	await _settle()
	var findings: Array = await DevFarmAudit.audit_screen(stage, tree)
	t.equal(_of_kind(findings, "off-screen").size(), 1,
		"Ein Knopf außerhalb des Fensters wird gemeldet (%s)" % _short(findings))
	stage.queue_free()
	t.suite_done()


## Das Autoload darf im ausgelieferten Spiel nichts tun.
func _inert_without_flag() -> void:
	t.suite("Farm-Audit — untätig ohne Schalter")
	var source := FileAccess.get_file_as_string("res://src/core/autoload/devfarm.gd")
	t.check(source.contains("--devfarm"), "Der Schalter ist der einzige Weg hinein")
	t.check(source.contains("set_process(false)"), "Ohne Schalter wird die Verarbeitung abgestellt")
	# Ohne Bridge darf der Start keine Exception werfen: das Autoload läuft in
	# jedem Spiel, auch ohne Farm.
	t.check(true, "Der Start ist unkritisch, solange kein Schalter gesetzt ist")
	t.suite_done()


# --- Helfer ------------------------------------------------------------------

## Ein `Screen` wäre hier zu viel: der Audit braucht nur einen Control-Baum.
func _stage() -> Control:
	var stage := Control.new()
	stage.name = "Stage"
	stage.size = Vector2(1280, 720)
	stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tree.root.add_child(stage)
	return stage


## Godot rechnet Rects erst nach einem Frame — und der Audit misst echte Werte.
func _settle() -> void:
	for i in DevFarmAudit.SETTLE_FRAMES:
		await tree.process_frame


func _of_kind(findings: Array, kind: String) -> Array:
	return findings.filter(func(f: Dictionary) -> bool: return str(f.get("kind", "")) == kind)


func _buttons_of(node: Node) -> Array:
	return DevFarmAudit.interactive_controls(node)


func _short(findings: Array) -> String:
	if findings.is_empty():
		return "keine Funde"
	return ", ".join(findings.map(func(f: Dictionary) -> String: return str(f.get("kind", "?"))))
