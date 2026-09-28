class_name Screen
extends Control
## Base class of every 2D subgame.
##
## Provides the persistent top bar plus two layout helpers: `content_layer()`
## fills the window (menus), `stage()` is the centred 1280x720 playfield.
## Subclasses build their interface in `_ready_game()`, never in `_ready`.

const BAR_HEIGHT := 52
const DESIGN := Vector2(1280, 720)
## Draw order inside `_root`. Godot paints later siblings on top, and
## `_ready_game()` appends the screen's own content to the same `_root` after
## the bar exists — the four menu screens that paint an opaque full-rect
## background covered the brand, "◀ Lobby", "Vorschlag", ⚙ and the mute button,
## and with them every `show_toast`. On `main_menu`, `game_over` and
## `pang_menu` nothing else offers ⚙, so the server address was unreachable
## there. The bar therefore floats above the content, and a modal layer above
## the bar, which is what a dimmed pause overlay has always done.
const CHROME_Z := 10
const MODAL_Z := 20

var screen_id: String = ""
var data: Dictionary = {}

var _root: Control
var _stage: Control
var _bar: Control
var _toast: Label
var _toast_timer: float = 0.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = UiTheme.shared()
	_build()
	_ready_game()


## Override point: build the game's own interface.
func _ready_game() -> void:
	pass


func _process(delta: float) -> void:
	if _toast_timer > 0.0:
		_toast_timer -= delta
		if _toast_timer <= 0.0 and _toast != null:
			_toast.visible = false


# --- chrome -----------------------------------------------------------------

func _build() -> void:
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_stage = Control.new()
	_stage.set_anchors_preset(Control.PRESET_CENTER, true)
	_stage.offset_left = -DESIGN.x * 0.5
	_stage.offset_top = -DESIGN.y * 0.5
	_stage.offset_right = DESIGN.x * 0.5
	_stage.offset_bottom = DESIGN.y * 0.5
	_stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_stage)

	_bar = _build_top_bar()
	_bar.z_index = CHROME_Z
	_root.add_child(_bar)

	_toast = Ui.label("", 17, UiTheme.TEXT)
	_toast.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	# `offset_*`, never `position`: with the centre preset `position` is
	# measured from the parent origin, so the rect would land at
	# (-260, 300) — half off screen and the text hard against the left edge.
	_toast.offset_left = -260.0
	_toast.offset_right = 260.0
	_toast.offset_top = 300.0
	_toast.offset_bottom = 340.0
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.visible = false
	_toast.z_index = CHROME_Z
	_root.add_child(_toast)


func _build_top_bar() -> Control:
	return Ui.top_bar(BAR_HEIGHT, self, func() -> void: SuggestDialog.open(self))


## Container for adaptive, full-window layouts (menus, lobbies).
func content_layer() -> Control:
	return _root


## The centred 1280x720 playfield. Games with a fixed layout build inside it.
func stage() -> Control:
	return _stage


## Shows a transient message in the middle of the screen.
## Text goes through `Loc.resolve`; a toast is the one caption with no `Ui.*` call.
func show_toast(text: String, seconds: float = 2.2) -> void:
	if _toast == null:
		return
	_toast.text = Loc.resolve(text)
	_toast.visible = true
	_toast_timer = seconds


## Full-screen modal layer used for pause and game-over states.
func modal() -> Control:
	var layer := Control.new()
	layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.set_meta("modal", true)
	# Above the bar (`CHROME_Z`): the overlay's backdrop dims whatever is
	# under it, the top bar included — as it always did.
	layer.z_index = MODAL_Z
	_root.add_child(layer)
	return layer


## Removes every modal layer created by `modal()`.
func close_modals() -> void:
	for child in _root.get_children():
		if child.has_meta("modal"):
			child.queue_free()


func has_modal() -> bool:
	for child in _root.get_children():
		if child.has_meta("modal"):
			return true
	return false
