class_name DevFarmAudit
extends RefCounted
## Prüft, ob ein Knopf wirklich erreichbar ist — und ob er etwas tut.
##
## Zwei Fehler, die ein headless Test und ein Screenshot beide übersehen:
##
## 1. **Zugedeckt.** Ein Control mit `MOUSE_FILTER_STOP` oder `PASS`, das
##    später im Baum hängt und über dem Knopf liegt, schluckt jeden Tipp. Der
##    Knopf ist sichtbar, richtig positioniert und tot.
## 2. **Nicht verdrahtet.** `Ui.button()` verbindet nur
##    `if on_press.is_valid()`. Fehlt der Callback, ist der Knopf ebenfalls tot
##    — und `pressed` feuert nie, egal was man antippt.
##
## Die Prüfung geht den Weg, den auch der Finger geht.
##
## Zwei Dinge haben hier eine Weile gedauert und sind deshalb festgehalten:
##
## - **Eingaben kommen über `Viewport.push_input`, nicht über
##   `Input.parse_input_event`.** Letzteres landet nicht im GUI des Viewports;
##   ein damit geschickter Klick bewegt gar nichts. Die Farm benutzt
##   `push_input`.
## - **Ein reines `InputEventScreenTouch` löst bei einem `Button` nichts aus.**
##   Controls verstehen keine rohen Touch-Events; erst die Maus-Emulation aus
##   `project.godot` macht daraus einen Klick, und die passiert in der
##   Plattformschicht, nicht beim Einspeisen. Der Audit schickt deshalb
##   **beides** — genau so, wie es auf dem Gerät ankommt.
##
## Für die Deckung wird **Godots eigener Treffertest** benutzt
## (`gui_get_hovered_control` nach einer Mausbewegung). Eine selbst
## nachgebaute Trefferlogik driftet irgendwann von der des Engines weg und
## meldet dann genau das Gegenteil der Wahrheit.

## Wie lange nach dem Bauen gewartet wird, bevor die Rects stimmen.
const SETTLE_FRAMES := 3


## Ein Fund. `kind` ist maschinenlesbar, `message` auf Deutsch.
static func finding(kind: String, severity: String, where: String, message: String) -> Dictionary:
	return {"kind": kind, "severity": severity, "where": where, "message": message}


## Sucht alle bedienbaren Controls unterhalb von `root`.
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
static func audit_screen(screen: Control, tree: SceneTree) -> Array[Dictionary]:
	var findings: Array[Dictionary] = []
	if screen == null or not is_instance_valid(screen):
		return [finding("no-screen", "fail", "-", "Kein Bildschirm geladen.")]
	var viewport := screen.get_viewport()
	if viewport == null:
		return [finding("no-viewport", "fail", "-", "Der Bildschirm hängt an keinem Viewport.")]

	var controls := interactive_controls(screen)
	for control in controls:
		var where := _describe(control)
		var rect := control.get_global_rect()

		if rect.size.x <= 1.0 or rect.size.y <= 1.0:
			findings.append(finding(
				"zero-size", "fail", where,
				"Der Knopf hat die Größe %s — er ist nicht antastbar." % _vec(rect.size),
			))
			continue
		if _off_window(rect, viewport):
			findings.append(finding(
				"off-screen", "fail", where,
				"Der Knopf liegt bei %s, also außerhalb des Fensters." % _vec(rect.position),
			))
			continue

		var centre := rect.get_center()
		var on_top := await _control_at_point(viewport, centre)
		if on_top != null and on_top != control and not _related(on_top, control):
			findings.append(finding(
				"covered", "fail", where,
				"Über dem Knopf liegt '%s' — jeder Tipp geht dort hin." % _describe(on_top),
			))
			continue

		if not await _fires(viewport, control, centre):
			findings.append(finding(
				"no-response", "fail", where,
				"Der Knopf bekommt den Tipp, aber `pressed` feuert nicht — er ist nicht verdrahtet.",
			))
	return findings


## Welches Control läge an diesem Punkt obenauf?
##
## Godot beantwortet das selbst: eine Mausbewegung auf den Punkt, dann
## `gui_get_hovered_control()`. Das ist dieselbe Logik, nach der auch ein
## Klick im Spiel entscheidet — nachzubauen wäre eine zweite Wahrheit.
static func _control_at_point(viewport: Viewport, point: Vector2) -> Control:
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	viewport.push_input(motion, true)
	await viewport.get_tree().process_frame
	return viewport.gui_get_hovered_control() as Control


## Schickt Tipp und Klick auf `point` und meldet, ob `pressed` kam.
##
## Beides, weil es ein Gerät auch tut: erst der Touch, und daraus — über
## `pointing/emulate_mouse_from_touch` — der Klick, auf den ein `Button`
## überhaupt hört.
static func _fires(viewport: Viewport, control: BaseButton, point: Vector2) -> bool:
	var fired := [false]
	var on_pressed := func() -> void: fired[0] = true
	control.pressed.connect(on_pressed)

	_push(viewport, _touch(point, true))
	_push(viewport, _mouse(point, true))
	await viewport.get_tree().process_frame
	_push(viewport, _mouse(point, false))
	_push(viewport, _touch(point, false))
	await viewport.get_tree().process_frame

	if control.pressed.is_connected(on_pressed):
		control.pressed.disconnect(on_pressed)
	return fired[0]


static func _push(viewport: Viewport, event: InputEvent) -> void:
	viewport.push_input(event, true)


static func _touch(point: Vector2, pressed: bool) -> InputEventScreenTouch:
	var event := InputEventScreenTouch.new()
	event.index = 0
	event.pressed = pressed
	event.position = point
	return event


static func _mouse(point: Vector2, pressed: bool) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = point
	event.global_position = point
	return event


## Liegt der Knopf wenigstens teilweise im Fenster?
static func _off_window(rect: Rect2, viewport: Viewport) -> bool:
	var window := Rect2(Vector2.ZERO, viewport.get_visible_rect().size)
	return not window.intersects(rect)


## Zwei Controls hängen zusammen, wenn das eine Vorfahr des anderen ist: eine
## Beschriftung *über* ihrem Knopf ist kein Problem, eine Karte *darunter* auch
## nicht — nur ein Control, das weder Vorfahr noch Nachfahr ist, verdeckt.
static func _related(a: Control, b: Control) -> bool:
	var current: Node = a
	while current != null:
		if current == b:
			return true
		current = current.get_parent()
	current = b
	while current != null:
		if current == a:
			return true
		current = current.get_parent()
	return false


static func _describe(control: Control) -> String:
	if control is BaseButton:
		var text := str((control as BaseButton).text).strip_edges()
		if text != "":
			return "%s \"%s\"" % [control.get_class(), text]
	return "%s %s" % [control.get_class(), str(control.name)]


static func _vec(v: Vector2) -> String:
	return "(%.0f, %.0f)" % [v.x, v.y]
