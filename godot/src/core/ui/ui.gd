class_name Ui
extends RefCounted
## Small factory helpers for building consistent UI trees in code.
##
## `label`, `title`, `value_label` and `button` run their text through
## `Loc.resolve()`, so being multi-language is decided in one place. Callers
## that want a key rather than a sentence write `Ui.label(Loc.t("ui.play"))`.

## Height of the top bar's buttons. The bar itself is as tall as its base class
## wants (`Screen.BAR_HEIGHT`, `WorldScreen.HUD_HEIGHT`), the buttons are the
## same size in both — they used to drift (40 vs 42) between two copies of the
## same bar.
const TOP_BAR_BUTTON := 40.0


## Shared font instances, loaded once and reused by every screen.
## `UiTheme` owns the cache; this is the shortcut for the two hot callers.
static func font_bold() -> Font:
	return UiTheme.font_bold()


static func label(text: String, size: int = 18, color: Color = UiTheme.TEXT, bold: bool = false) -> Label:
	var node := Label.new()
	node.text = Loc.resolve(text)
	node.add_theme_font_size_override("font_size", size)
	node.add_theme_color_override("font_color", color)
	node.add_theme_font_override("font", UiTheme.font_bold() if bold else UiTheme.font_regular())
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return node


static func title(text: String, size: int = 52, color: Color = UiTheme.TEXT) -> Label:
	var node := label(text, size, color, true)
	node.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	node.add_theme_color_override("font_outline_color", UiTheme.ACCENT)
	node.add_theme_constant_override("outline_size", 4)
	return node


static func value_label(text: String, size: int = 30) -> Label:
	var node := label(text, size, UiTheme.TEXT, true)
	node.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return node


static func button(text: String, size: Vector2, accent: Color = UiTheme.PANEL_LIGHT, on_press: Callable = Callable()) -> Button:
	var node := Button.new()
	node.text = Loc.resolve(text)
	node.custom_minimum_size = size
	node.focus_mode = Control.FOCUS_NONE
	node.add_theme_stylebox_override("normal", UiTheme.flat(accent, UiTheme.BORDER, 10))
	node.add_theme_stylebox_override("hover", UiTheme.flat(accent.lightened(0.14), UiTheme.ACCENT, 10))
	node.add_theme_stylebox_override("pressed", UiTheme.flat(accent.darkened(0.2), UiTheme.ACCENT, 10))
	node.add_theme_stylebox_override("disabled", UiTheme.flat(Color(0.078, 0.110, 0.165), Color(0.16, 0.20, 0.26), 10))
	node.add_theme_font_size_override("font_size", int(clampf(size.y * 0.42, 14, 26)))
	if on_press.is_valid():
		node.pressed.connect(on_press)
	return node


static func panel(fill: Color = UiTheme.PANEL, border: Color = UiTheme.BORDER, radius: int = 12) -> PanelContainer:
	var node := PanelContainer.new()
	node.add_theme_stylebox_override("panel", UiTheme.flat(fill, border, radius))
	return node


static func spacer(minimum: Vector2 = Vector2.ZERO) -> Control:
	var node := Control.new()
	node.custom_minimum_size = minimum
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return node


static func expander() -> Control:
	var node := Control.new()
	node.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	node.size_flags_vertical = Control.SIZE_EXPAND_FILL
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return node


static func hbox(separation: int = 12) -> HBoxContainer:
	var node := HBoxContainer.new()
	node.add_theme_constant_override("separation", separation)
	return node


static func vbox(separation: int = 12) -> VBoxContainer:
	var node := VBoxContainer.new()
	node.add_theme_constant_override("separation", separation)
	return node


## A flat coloured rectangle — used for bars, frames and decorative blocks.
static func rect(color: Color, radius: int = 8, border: Color = Color(0, 0, 0, 0), border_width: int = 0) -> Panel:
	var node := Panel.new()
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.set_corner_radius_all(radius)
	if border.a > 0.0:
		box.border_color = border
		box.set_border_width_all(border_width)
	node.add_theme_stylebox_override("panel", box)
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return node


## Enables or disables a button in one call.
static func with_disabled(node: Button, value: bool) -> Button:
	node.disabled = value
	return node


## Full-screen dimmed backdrop for pause / game-over overlays.
static func backdrop(alpha: float = 0.78) -> ColorRect:
	var node := ColorRect.new()
	node.color = Color(0.008, 0.024, 0.055, alpha)
	node.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	node.mouse_filter = Control.MOUSE_FILTER_STOP
	return node


## Rounded progress bar with an explicit fill colour.
static func bar(color: Color, height: float = 18.0) -> ProgressBar:
	var node := ProgressBar.new()
	node.show_percentage = false
	node.custom_minimum_size = Vector2(0, height)
	node.add_theme_stylebox_override("background", UiTheme.flat(Color(0.118, 0.161, 0.231, 0.9), Color(0, 0, 0, 0), height * 0.5))
	node.add_theme_stylebox_override("fill", UiTheme.flat(color, color, height * 0.5))
	node.max_value = 1.0
	node.value = 1.0
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return node


## Sets a bar's fill and colour in one call.
static func set_bar(node: ProgressBar, ratio: float, color: Color) -> void:
	node.value = clampf(ratio, 0.0, 1.0)
	var fill := node.get_theme_stylebox("fill") as StyleBoxFlat
	if fill != null:
		fill.bg_color = color


## The persistent top bar of every screen, 2D and 3D alike.
##
## One builder, because the two base classes carried the same 35 lines with two
## differences: `SuggestDialog.open` vs `open_world` (passed in as
## `on_suggest`) and the bar's own height (passed in as `height`).
## `owner` is the screen the ⚙ opens the settings on.
static func top_bar(height: float, owner: Node, on_suggest: Callable) -> HBoxContainer:
	var bar := HBoxContainer.new()
	bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	bar.offset_bottom = height
	bar.offset_left = 10
	bar.offset_right = -10
	bar.add_theme_constant_override("separation", 8)
	bar.alignment = BoxContainer.ALIGNMENT_BEGIN

	var brand := label("SINGULAR 80", 20, UiTheme.ACCENT, true)
	brand.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	brand.custom_minimum_size = Vector2(190, 0)
	bar.add_child(brand)

	# Qualified: the local `spacer` would otherwise shadow the factory.
	var spacer := Ui.spacer()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)

	bar.add_child(button(Loc.t("ui.back_to_lobby"), Vector2(120, TOP_BAR_BUTTON), UiTheme.PANEL_LIGHT, func() -> void:
		Sfx.select()
		Router.to_lobby()
	))
	bar.add_child(button(Loc.t("ui.suggestion"), Vector2(150, TOP_BAR_BUTTON), UiTheme.PANEL_LIGHT, on_suggest))
	# `⚙` is in DejaVu Sans; an emoji here would render as an empty box.
	bar.add_child(button(Loc.t("ui.settings_short"), Vector2(60, TOP_BAR_BUTTON), UiTheme.PANEL_LIGHT, func() -> void:
		Sfx.select()
		SettingsDialog.open(owner)
	))
	var mute: Button
	mute = button(mute_label(), Vector2(110, TOP_BAR_BUTTON), UiTheme.PANEL_LIGHT, func() -> void:
		Game.toggle_muted()
		mute.text = mute_label()
	)
	bar.add_child(mute)
	return bar


## Caption of the top bar's sound button, in the active language.
static func mute_label() -> String:
	return Loc.t("ui.sound_on") if not Game.muted else Loc.t("ui.sound_off")


static func format_time(ms: float) -> String:
	var total := int(max(0.0, ms) / 1000.0)
	return "%d:%02d" % [total / 60, total % 60]


## Thousands separator for the active language.
## `Loc` owns the separators: a hard-coded `.` is wrong for English and French.
static func format_number(value: int) -> String:
	return Loc.number(value)
