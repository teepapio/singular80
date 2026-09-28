extends Node
## Registers every input action the game uses, in code.
##
## Doing this at runtime (instead of hand-writing the serialized `[input]`
## section of `project.godot`) keeps the action list reviewable and guarantees
## that a fresh checkout behaves identically on every machine.

const KEY_ACTIONS: Dictionary = {
	"move_up": [KEY_W, KEY_UP],
	"move_down": [KEY_S, KEY_DOWN],
	"move_left": [KEY_A, KEY_LEFT],
	"move_right": [KEY_D, KEY_RIGHT],
	"aim_up": [KEY_W, KEY_UP],
	"aim_down": [KEY_S, KEY_DOWN],
	"aim_left": [KEY_A, KEY_LEFT],
	"aim_right": [KEY_D, KEY_RIGHT],
	"dash": [KEY_SPACE],
	"jump": [KEY_SPACE],
	"fire": [KEY_J, KEY_CTRL],
	"interact": [KEY_E, KEY_ENTER, KEY_KP_ENTER],
	"pause": [KEY_ESCAPE],
	"confirm": [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE],
	"cancel": [KEY_ESCAPE],
	"restart": [KEY_R],
	"undo": [KEY_U, KEY_Z],
	"hold_piece": [KEY_C, KEY_SHIFT],
	"rotate_cw": [KEY_UP, KEY_W, KEY_X],
	"rotate_ccw": [KEY_Z, KEY_CTRL],
	"hard_drop": [KEY_SPACE],
	"soft_drop": [KEY_DOWN, KEY_S],
	"suggest": [KEY_F1],
	"quick_save": [KEY_F5],
}

## Buttons of a standard gamepad, in the order the games expect them.
const PAD_ACTIONS: Dictionary = {
	"fire": [JOY_BUTTON_A],
	"jump": [JOY_BUTTON_A],
	"dash": [JOY_BUTTON_B],
	"interact": [JOY_BUTTON_A],
	"confirm": [JOY_BUTTON_A],
	"cancel": [JOY_BUTTON_B],
	"pause": [JOY_BUTTON_START],
	"restart": [JOY_BUTTON_Y],
	"undo": [JOY_BUTTON_X],
}

const PAD_AXIS_ACTIONS: Dictionary = {
	"move_left": [JOY_AXIS_LEFT_X, -1.0],
	"move_right": [JOY_AXIS_LEFT_X, 1.0],
	"move_up": [JOY_AXIS_LEFT_Y, -1.0],
	"move_down": [JOY_AXIS_LEFT_Y, 1.0],
	"aim_left": [JOY_AXIS_RIGHT_X, -1.0],
	"aim_right": [JOY_AXIS_RIGHT_X, 1.0],
	"aim_up": [JOY_AXIS_RIGHT_Y, -1.0],
	"aim_down": [JOY_AXIS_RIGHT_Y, 1.0],
}


func _enter_tree() -> void:
	process_priority = -100
	_register_all()


func _register_all() -> void:
	for action in KEY_ACTIONS:
		_ensure_action(action)
		for keycode in KEY_ACTIONS[action]:
			var event := InputEventKey.new()
			event.physical_keycode = keycode
			InputMap.action_add_event(action, event)

	for action in PAD_ACTIONS:
		_ensure_action(action)
		for button in PAD_ACTIONS[action]:
			var event := InputEventJoypadButton.new()
			event.button_index = button
			InputMap.action_add_event(action, event)

	for action in PAD_AXIS_ACTIONS:
		_ensure_action(action)
		var axis: int = PAD_AXIS_ACTIONS[action][0]
		var direction: float = PAD_AXIS_ACTIONS[action][1]
		var event := InputEventJoypadMotion.new()
		event.axis = axis
		event.axis_value = direction
		InputMap.action_add_event(action, event)

	# No mouse button is bound to a shared action, on purpose.
	#
	# `project.godot` sets `pointing/emulate_mouse_from_touch = true`, so on a
	# device every finger press arrives as a left mouse button. A mouse event on
	# a *shared* action therefore means "somebody touched the screen anywhere",
	# and every screen that polls that action acts on it: the top bar's ⚙,
	# "◀ Lobby", "Vorschlag" and the mute button all shoot the weapon of a game
	# that reads `fire` (dragon flight, dragon RPG, Pang). It looked like a
	# single binding; it was a button press on the entire top bar.
	#
	# `fire` is fed by the key and the gamepad above and by
	# `WorldScreen.add_action_button()`, which is the only control a player can
	# actually aim with. The arena game additionally checks
	# `Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)` in its own code, where
	# that check belongs.


func _ensure_action(action: StringName) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action, 0.35)
