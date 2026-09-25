class_name VirtualStick
extends Control
## On-screen thumb stick.
##
## Every action game in the app is fully playable with this stick plus the
## on-screen buttons — keyboard and gamepad input is merged in by the owning
## screen, so a phone, a tablet and a desktop all work without mode switching.
## The base recentres to wherever the finger lands, which makes it usable on
## any screen size.

signal moved(vector: Vector2)

const BASE_RADIUS := 92.0
const KNOB_RADIUS := 42.0
const DEADZONE := 0.14
## Full footprint of the control; callers need it before `_ready` runs.
const SIZE := Vector2(BASE_RADIUS * 2.6, BASE_RADIUS * 2.6)

var value: Vector2 = Vector2.ZERO
var active: bool = false
var accent: Color = UiTheme.ACCENT
var label_text: String = ""
var follow_touch: bool = true

var _touch_index: int = -1
var _origin: Vector2 = Vector2.ZERO
var _knob: Vector2 = Vector2.ZERO


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = SIZE
	size = SIZE
	pivot_offset = size * 0.5
	_origin = size * 0.5
	_knob = _origin
	set_process(true)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed and _touch_index == -1:
			_touch_index = touch.index
			_activate(touch.position)
			accept_event()
		elif not touch.pressed and touch.index == _touch_index:
			_release()
			accept_event()
	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		if drag.index == _touch_index:
			_update(drag.position)
			accept_event()
	elif event is InputEventMouseButton and not DisplayServer.is_touchscreen_available():
		var click := event as InputEventMouseButton
		if click.button_index == MOUSE_BUTTON_LEFT:
			if click.pressed:
				_activate(click.position)
			else:
				_release()
			accept_event()
	elif event is InputEventMouseMotion and not DisplayServer.is_touchscreen_available():
		if _touch_index == -1 and active:
			_update((event as InputEventMouseMotion).position)
			accept_event()


func _activate(local_position: Vector2) -> void:
	active = true
	if follow_touch:
		_origin = local_position
		_knob = local_position
	_update(local_position)
	queue_redraw()


func _update(local_position: Vector2) -> void:
	var offset := local_position - _origin
	var length := offset.length()
	if length > BASE_RADIUS:
		offset = offset / length * BASE_RADIUS
	_knob = _origin + offset
	var raw := offset / BASE_RADIUS
	if raw.length() < DEADZONE:
		value = Vector2.ZERO
	else:
		# Rescale past the deadzone so the first responsive pixel is at zero.
		var scaled := (raw.length() - DEADZONE) / (1.0 - DEADZONE)
		value = raw.normalized() * clampf(scaled, 0.0, 1.0)
	moved.emit(value)
	queue_redraw()


func _release() -> void:
	_touch_index = -1
	active = false
	value = Vector2.ZERO
	_origin = size * 0.5
	_knob = _origin
	moved.emit(value)
	queue_redraw()


func _draw() -> void:
	var base := UiTheme.BG
	var alpha := 0.55 if active else 0.28
	draw_circle(_origin, BASE_RADIUS, Color(base.r, base.g, base.b, alpha * 0.75))
	draw_arc(_origin, BASE_RADIUS, 0.0, TAU, 48, Color(accent.r, accent.g, accent.b, alpha + 0.2), 3.0, true)
	draw_arc(_origin, BASE_RADIUS * 0.32, 0.0, TAU, 32, Color(accent.r, accent.g, accent.b, alpha * 0.5), 2.0, true)
	draw_circle(_knob, KNOB_RADIUS, Color(accent.r, accent.g, accent.b, 0.35 if active else 0.18))
	draw_arc(_knob, KNOB_RADIUS, 0.0, TAU, 32, Color(accent.r, accent.g, accent.b, 0.95 if active else 0.55), 3.0, true)
	if label_text != "":
		var font := Ui.font_bold()
		if font != null:
			var size := font.get_string_size(label_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 16)
			draw_string(font, _origin + Vector2(-size.x * 0.5, -BASE_RADIUS - 14.0), label_text,
					HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(UiTheme.TEXT_MUTED.r, UiTheme.TEXT_MUTED.g, UiTheme.TEXT_MUTED.b, 0.8))


## Merges the stick, the keyboard and a gamepad into one direction vector.
## `keys_x`/`keys_y` are the InputMap actions for the horizontal/vertical axis.
static func combined(stick: Vector2, keys_x: StringName, keys_y: StringName, deadzone: float = 0.25) -> Vector2:
	var from_keys := Vector2(
		Input.get_axis("move_left", "move_right"),
		Input.get_axis("move_up", "move_down")
	)
	if from_keys.length() > deadzone:
		return from_keys.normalized()
	if stick.length() > 0.02:
		return stick
	return Vector2.ZERO
