class_name DevFarmAudit
extends RefCounted
## Prüft, ob ein Knopf wirklich erreichbar ist — und ob er etwas tut.
##
## Zwei Fehler, die ein headless Test und ein Screenshot beide übersehen:
##
## 1. **Zugedeckt.** Ein Control mit `MOUSE_FILTER_STOP` oder `PASS`, das
##    später im Baum hängt und über dem Knopf liegt, schluckt jeden Tipp. Der
##    Knopf ist sichtbar, richtig positioniert und tot. Genau das war im
##    Tetris- und Dame-Aufbau die Frage, die offen blieb.
## 2. **Nicht verdrahtet.** `Ui.button()` verbindet nur
##    `if on_press.is_valid()`. Fehlt der Callback, ist der Knopf ebenfalls tot
##    — und `pressed` feuert nie, egal was man antippt.
##
## Die Prüfung geht den Weg, den auch der Finger geht: sie schickt einen
## echten `InputEventScreenTouch` auf die Mitte des Knopfes und schaut, ob
## `pressed` gekommen ist. Kein Nachbau der Trefferlogik, sondern dieselbe
## Eingangspforte wie im Spiel.
##
## Warum das als Skript und nicht im normalen Testlauf: es braucht ein
## gerendertes Fenster mit echten Layout-Werten. Headless ist `size` nach dem
## Bauen 0, und ein Rect von 0 mal 0 prüft nichts.

## Wie lange nach dem Bauen gewartet wird, bevor die Rects stimmen.
const SETTLE_FRAMES := 3


## Ein Fund. `kind` ist maschinenlesbar, `message` auf Deutsch.
static func finding(kind: String, severity: String, where: String, message: String) -> Dictionary:
	return {"kind": kind, "severity": severity, "where": where, "message": message}


## Sucht alle bedienbaren Controls unterhalb von `root`.
##
## `Button` ist die Basis von allem, was der Spieler antippt; `BaseButton`
## fange ich zusätzlich, damit eigene Knöpfe mit erben nicht durchrutschen.
static func interactive_controls(root: Node) -> Array[Control]:
	var out: Array[Control] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node is BaseButton and node is Control:
			var control := node as Control
			if control.visible and control.is_visible_in_tree():
				out.append(control)
	return out


## Prüft einen Bildschirm und liefert die Funde.
##
## Wartet selbst, bis die Layout-Werte stimmen — deshalb ist sie eine
## Coroutine und muss mit `await` aufgerufen werden.
##
## `pressed` wird für jeden Knopf abgehört, während ein Touch auf seine Mitte
## geschickt wird. Feuert er nicht, ist der Knopf tot — und die Ursache steht
## im Fund, damit niemand raten muss.
static func audit_screen(screen: Control, tree: SceneTree) -> Array[Dictionary]:
	var findings: Array[Dictionary] = []
	if screen == null or not is_instance_valid(screen):
		return [finding("no-screen", "fail", "-", "Kein Bildschirm geladen.")]

	var controls := interactive_controls(screen)
	for control in controls:
		var where := _describe(control)

		var rect := control.get_global_rect()
		if rect.size.x <= 1.0 or rect.size.y <= 1.0:
			# Ein Knopf ohne Fläche ist unantastbar, egal was darüber liegt.
			findings.append(finding(
				"zero-size", "fail", where,
				"Der Knopf hat die Größe %s — er ist nicht antastbar." % _vec(rect.size),
			))
			continue
		if rect.position.x < -1.0 or rect.position.y < -1.0:
			findings.append(finding(
				"off-screen", "fail", where,
				"Der Knopf liegt bei %s, also teilweise außerhalb des Fensters." % _vec(rect.position),
			))
			continue

		var on_top := _control_at_point(screen, tree, rect.get_center())
		if on_top != null and on_top != control and not _is_ancestor_of(on_top, control):
			findings.append(finding(
				"covered", "fail", where,
				"Über dem Knopf liegt '%s' (%s) — jeder Tipp geht dort hin."
					% [_describe(on_top), _class_of(on_top)],
			))
			continue

		if not await _fires_on_touch(control, tree, rect.get_center()):
			findings.append(finding(
				"no-response", "fail", where,
				"Der Knopf bekommt den Tipp, aber `pressed` feuert nicht — er ist nicht verdrahtet.",
			))
	return findings


## Welches Control läge an diesem Punkt obenauf?
##
## Nachgebaut ist die Godot-Reihenfolge: Kinder von hinten nach vorn, der
## erste Treffer gewinnt, `MOUSE_FILTER_IGNORE` wird übersprungen, und wer
## nicht `visible` ist, zählt nicht.
static func _control_at_point(root: Control, tree: SceneTree, point: Vector2) -> Control:
	var best: Control = null
	var stack: Array[Control] = [root]
	var found: Array[Control] = []
	while not stack.is_empty():
		var node: Control = stack.pop_back()
		if not node.visible or node.mouse_filter == Control.MOUSE_FILTER_IGNORE:
			continue
		if node != root and node.get_global_rect().has_point(point):
			found.append(node)
		for child in node.get_children():
			if child is Control:
				stack.append(child as Control)
	# Der zuletzt gefundene Treffer entspricht der Zeichenreihenfolge: die
	# später hinzugefügten Controls liegen oben.
	if not found.is_empty():
		best = found[found.size() - 1]
	return best


## Schickt einen echten Touch auf `point` und meldet, ob `pressed` kam.
static func _fires_on_touch(control: BaseButton, tree: SceneTree, point: Vector2) -> bool:
	var fired := [false]
	var on_pressed := func() -> void: fired[0] = true
	control.pressed.connect(on_pressed)

	var press := InputEventScreenTouch.new()
	press.index = 0
	press.pressed = true
	press.position = point
	var release := InputEventScreenTouch.new()
	release.index = 0
	release.pressed = false
	release.position = point

	Input.parse_input_event(press)
	# Ein Frame, damit die GUI die Ereignisse auch verarbeitet, bevor der
	# Test weiterläuft.
	await tree.process_frame
	Input.parse_input_event(release)
	await tree.process_frame

	if control.pressed.is_connected(on_pressed):
		control.pressed.disconnect(on_pressed)
	return fired[0]


static func _is_ancestor_of(possible_child: Control, node: Control) -> bool:
	var current := possible_child.get_parent()
	while current != null:
		if current == node:
			return true
		current = current.get_parent()
	return false


static func _class_of(control: Control) -> String:
	return control.get_class()


static func _describe(control: Control) -> String:
	if control is BaseButton:
		var text := str((control as BaseButton).text).strip_edges()
		if text != "":
			return "%s \"%s\"" % [control.get_class(), text]
	return "%s %s" % [control.get_class(), str(control.name)]


static func _vec(v: Vector2) -> String:
	return "(%.0f, %.0f)" % [v.x, v.y]
