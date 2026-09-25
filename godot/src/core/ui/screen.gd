class_name Screen
extends Control
## Base class of every 2D subgame.
##
## Provides the persistent top bar (back to lobby, suggestion form, sound
## toggle) and two layout helpers:
##  - `content_layer()` fills the whole window — used by menu-style screens
##  - `stage()` is the fixed 1280x720 design area, centred — used by the games
##    whose playfield must keep its exact proportions on every device
##
## The stretched canvas plus anchor presets make every screen adapt to phone
## and tablet aspect ratios without extra work.

const BAR_HEIGHT := 52
const DESIGN := Vector2(1280, 720)

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
	_root.add_child(_bar)

	_toast = Ui.label("", 17, UiTheme.TEXT)
	_toast.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_toast.position = -Vector2(260, 0) + Vector2(0, 300)
	_toast.size = Vector2(520, 40)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.visible = false
	_root.add_child(_toast)


func _build_top_bar() -> Control:
	var bar := HBoxContainer.new()
	bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	bar.offset_bottom = BAR_HEIGHT
	bar.offset_left = 10
	bar.offset_right = -10
	bar.add_theme_constant_override("separation", 8)
	bar.alignment = BoxContainer.ALIGNMENT_BEGIN

	var brand := Ui.label("SINGULAR 80", 20, UiTheme.ACCENT, true)
	brand.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	brand.custom_minimum_size = Vector2(190, 0)
	bar.add_child(brand)

	var spacer := Ui.spacer()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)

	bar.add_child(Ui.button("◀ Lobby", Vector2(120, 40), UiTheme.PANEL_LIGHT, func() -> void:
		Sfx.select()
		Router.to_lobby()
	))
	bar.add_child(Ui.button("Vorschlag", Vector2(150, 40), UiTheme.PANEL_LIGHT, func() -> void:
		SuggestDialog.open(self)
	))
	var mute: Button
	mute = Ui.button(_mute_label(), Vector2(110, 40), UiTheme.PANEL_LIGHT, func() -> void:
		Game.toggle_muted()
		mute.text = _mute_label()
	)
	bar.add_child(mute)
	return bar


func _mute_label() -> String:
	return "♪ Ton an" if not Game.muted else "♪ stumm"


## Container for adaptive, full-window layouts (menus, lobbies).
func content_layer() -> Control:
	return _root


## The centred 1280x720 playfield. Games with a fixed layout build inside it.
func stage() -> Control:
	return _stage


## Shows a transient message in the middle of the screen.
func show_toast(text: String, seconds: float = 2.2) -> void:
	if _toast == null:
		return
	_toast.text = text
	_toast.visible = true
	_toast_timer = seconds


## Full-screen modal layer used for pause and game-over states.
func modal() -> Control:
	var layer := Control.new()
	layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.set_meta("modal", true)
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
