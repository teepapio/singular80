class_name TouchButton
extends Button
## An action button that every finger can press, not just the first one.
##
## `project.godot` runs `emulate_mouse_from_touch`, and that is what keeps the
## whole game alive on a tablet: Godot's `Button` answers to
## `InputEventMouseButton` and to nothing else. The translation is one finger
## wide. `Input` remembers the index of the first `InputEventScreenTouch` it
## sees (`mouse_from_touch_index`) and emulates the mouse for that index and no
## other — `Input::_parse_input_event_impl` in `core/input/input.cpp`. A second
## finger therefore arrives as a raw `InputEventScreenTouch`, which
## `BaseButton` never inspects.
##
## With a virtual stick under the left thumb that is not an edge case, it is the
## normal way to play: the stick claims the first finger, and from then on
## nothing the right thumb does reaches the button next to it. Measured on the
## dragon flight screen: a raw `InputEventScreenTouch` and no mouse event with
## it, while the button alone does get both. "I cannot fire while steering" was
## exactly that, and it hit every 3D screen because they all build their buttons
## through `WorldScreen.add_action_button()`.
##
## So this class reads the raw touch events itself, per index, and does what a
## `Button` does with a mouse: `button_down` on the way down, `button_up` and
## `pressed` on the way up, and a finger that slides off cancels the last one —
## dragging away is how a player aborts a tap without lifting.
##
## Mouse events are deliberately ignored. `emulate_touch_from_mouse` sends the
## touch event for a click before the mouse event for the same click, so
## answering to both would press every button twice; and this project pins both
## settings in `project.godot` instead of relying on a device default.

## The finger that holds the button down, or -1 while it is free.
var _touch_index: int = -1
var _held := false
## Set while the finger slides outside the button; it cancels `pressed`.
var _slid_off := false
## The two looks, captured in `_ready`: `Button` paints its `pressed` stylebox
## only while the mouse bookkeeping it keeps says a button is down, and that
## bookkeeping belongs to the path this class does not take. So the held look
## is the `normal` box swapped out for the `pressed` one.
var _idle_style: StyleBox = null
var _held_style: StyleBox = null


func _ready() -> void:
	_idle_style = get_theme_stylebox(&"normal")
	_held_style = get_theme_stylebox(&"pressed")


func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			# The first finger that lands here owns the button. A second one on
			# a button that is already held must not take it over — the player
			# can be sliding a finger off it, or holding it with a thumb.
			if _touch_index == -1 and not disabled:
				_touch_index = touch.index
				_slid_off = false
				_set_held(true)
				emit_signal(&"button_down")
		elif touch.index == _touch_index:
			_touch_index = -1
			_set_held(false)
			emit_signal(&"button_up")
			if not _slid_off:
				emit_signal(&"pressed")
		accept_event()
	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		# `Control.has_point` is not exposed to GDScript; its own definition is
		# exactly this one (`Control::has_point` is `get_rect().has_point`).
		if drag.index == _touch_index:
			_slid_off = not get_rect().has_point(drag.position)
		accept_event()
	elif event is InputEventMouseButton or event is InputEventMouseMotion:
		accept_event()


func _set_held(held: bool) -> void:
	if held == _held:
		return
	_held = held
	add_theme_stylebox_override(&"normal", _held_style if held else _idle_style)