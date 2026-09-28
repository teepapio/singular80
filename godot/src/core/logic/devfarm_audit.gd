class_name DevFarmAudit
extends RefCounted
## Whether a button is really reachable, and really does something.
## Catches the two failures a headless test and a screenshot both miss:
## **covered** (a later sibling Control with MOUSE_FILTER_STOP swallows every
## tap) and **not wired** (`Ui.button()` only connects `if on_press.is_valid()`,
## so a missing callback leaves `pressed` silent).
## Two things that cost time to find, so they are written down:
##  - Input goes through `Viewport.push_input`, never `Input.parse_input_event`,
##    which never reaches the viewport GUI and moves nothing.
##  - A bare `InputEventScreenTouch` triggers nothing on a `Button`; only the
##    mouse emulation from `project.godot` turns it into a click, and that runs
##    in the platform layer, not at push time. Hence the audit sends **both**,
##    the way a device delivers them.
## Coverage uses Godot's own hit test (`gui_get_hovered_control` after a mouse
## move); a hand-rolled one eventually drifts and reports the opposite of truth.

## Frames to wait after building before the rects are settled.
const SETTLE_FRAMES := 3


## One finding. `kind` is machine-readable, `message` is German (the player
## reads it in the farm report).
static func finding(kind: String, severity: String, where: String, message: String) -> Dictionary:
	return {"kind": kind, "severity": severity, "where": where, "message": message}


## All operable controls below `root`.
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


## Audits a screen and returns the findings. Waits itself until the layout
## values are settled, which is why it is a coroutine and needs `await`.
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


## Which control would be on top at this point? Godot answers that itself: move
## the mouse there and ask `gui_get_hovered_control()`. Same logic a real click
## uses — rebuilding it here would be a second truth.
static func _control_at_point(viewport: Viewport, point: Vector2) -> Control:
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	viewport.push_input(motion, true)
	await viewport.get_tree().process_frame
	return viewport.gui_get_hovered_control() as Control


## Sends tap and click at `point`, reports whether `pressed` arrived. Both,
## because a device does both: the touch first and, through
## `pointing/emulate_mouse_from_touch`, the click a `Button` listens to.
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


## Is the button at least partly inside the window?
static func _off_window(rect: Rect2, viewport: Viewport) -> bool:
	var window := Rect2(Vector2.ZERO, viewport.get_visible_rect().size)
	return not window.intersects(rect)


## Two controls are related when one is an ancestor of the other: a label *over*
## its button is no problem, nor is a card *under* it — only a control that is
## neither ancestor nor descendant covers the button.
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
