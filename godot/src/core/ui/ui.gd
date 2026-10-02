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

## Smallest row height a list may use. 44 px is the Android minimum touch
## target, and a list that "fits" by shrinking its rows below this is worse than
## one that scrolls — the entries stop being something a finger can hit.
const LIST_ROW_MIN := 44.0
## Largest row a list shows while there is room for more. The flat list lobby and
## the theme dialog both used 78 for their full-height entry.
const LIST_ROW_MAX := 78.0
## How far a finger may travel on a list before the drag counts as a scroll
## rather than a press.
##
## `gui/common/default_scroll_deadzone` is 0 and Godot's own gate is
## `abs(drag_accum) > deadzone`, so with 0 a single pixel of wobble starts a
## scroll, `gui_input` calls `accept_event()` and the row under the finger is
## never pressed. 30 is the value the deadzone arrived with (godot#13996, "Make
## BaseButton not emit press when container is scrolled") and stays under the
## travel a deliberate swipe needs. The touch branch only runs while
## `DisplayServer.is_touchscreen_available()`, so a desktop run is unaffected.
const LIST_SCROLL_DEADZONE := 30
## Name of the row box inside a list from `Ui.scroll_list()`. A name rather than
## a child index, because the `ScrollContainer` also holds two internal bars.
const LIST_ROWS := "rows"


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


## `MOUSE_FILTER_IGNORE`, and that is the whole point of these two factories.
##
## `Control` defaults to `MOUSE_FILTER_STOP`, and Godot hands a click to the
## topmost Control that stops it — later siblings first, children before parents,
## with `z_index` **not** consulted. A box container has no `gui_input` of its
## own, so it can never do anything with a click, yet a full-rect one silently
## eats every click underneath it. An empty, invisible `Control` in `main.gd`
## did exactly that to every 2D screen of the game.
##
## This is the rule Godot's own documentation gives under "User Interface nodes
## and input": the event does not trigger if the control "is obstructed by
## another Control on top, which doesn't have mouse_filter set to
## MOUSE_FILTER_IGNORE". So `STOP` goes on what the player can actually press —
## `Ui.button`, `Ui.backdrop` — and `IGNORE` on everything that only arranges
## pixels. A real target sets it back to `STOP`.
static func hbox(separation: int = 12) -> HBoxContainer:
	var node := HBoxContainer.new()
	node.add_theme_constant_override("separation", separation)
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return node


static func vbox(separation: int = 12) -> VBoxContainer:
	var node := VBoxContainer.new()
	node.add_theme_constant_override("separation", separation)
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
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


# --- lists -------------------------------------------------------------------
#
# A list of rows inside a box of a fixed height has exactly two honest answers:
# the rows fit, or the list scrolls. A plain `VBoxContainer` of rows in a fixed
# panel has neither — nothing clips it, so with one row more than fits the lower
# rows are painted over whatever is below the panel and then over the edge of
# the screen, and the buttons there cannot be reached.
#
# That is not a hypothetical. Measured on the 3D lobby's game panel, rebuilt at
# the size and position `lobby3d_screen.gd` gives it in a 1280x720 window: the
# panel is a fixed 250 high, the head above the list takes 91, and the "Puzzle"
# plaza lists six games that need 270 of the 135 that are left. Nothing clamps
# the column, so it grows to 361 — and the last row ends at y = 793, 73 px below
# the bottom of the screen. The "3D Adventures" plaza with five games is 27 px
# over the edge.
#
# `Ui.scroll_list()` is the box that clips and `Ui.list_row()` is the arithmetic
# that decides how tall a row may be; `test_core.gd` measures both.

## The height one row of `count` rows may have so the list fits into `available`
## pixels — never more than `row_max`, never below `LIST_ROW_MIN`.
##
## The floor is the point. A list with more entries than the space can hold does
## not get its rows squeezed until they fit; it is told the truth, keeps rows a
## finger can hit, and has to scroll. The floor yields to a caller whose own
## `row_max` is already smaller than `LIST_ROW_MIN`, though — a screen that ships
## 40 px rows is stating a decision, and handing back 44 would make its list
## taller than it asked for and still not fit. `count` of zero or less has no row
## to size and answers with `row_max`.
static func list_row(available: float, count: int, gap: float, row_max: float = LIST_ROW_MAX) -> float:
	if count <= 0:
		return row_max
	var gaps := maxf(0.0, gap) * float(count - 1)
	var ceiling := maxf(1.0, row_max)
	return clampf((available - gaps) / float(count), minf(LIST_ROW_MIN, ceiling), ceiling)


## The height a list of `count` rows of `row` occupies, gaps included — the
## other half of `Ui.list_row()`, and what a caller compares against the room it
## has to decide whether the list has to scroll at all.
static func list_height(count: int, row: float, gap: float) -> float:
	if count <= 0:
		return 0.0
	return row * float(count) + maxf(0.0, gap) * float(count - 1)


## A vertical list of rows that scrolls instead of growing out of its box.
##
## `ScrollContainer` turns `clip_contents` on in its constructor, so a list built
## here cannot paint a pixel outside the panel it sits in — the whole point. It
## wants exactly one child, the row box `Ui.list_box()` hands out; `add_child`
## on the container itself would put a second column beside the scrolled content
## rather than inside it.
##
## Horizontal scrolling is off (a row is as wide as the list) and `follow_focus`
## is on, so a caller that gives a row the focus sees it scrolled into view
## without scrolling by hand. `scroll_deadzone` keeps a tap a tap — see
## `LIST_SCROLL_DEADZONE`.
static func scroll_list(separation: int = 8) -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.follow_focus = true
	scroll.scroll_deadzone = LIST_SCROLL_DEADZONE
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var box := VBoxContainer.new()
	box.name = LIST_ROWS
	# Same rule as `Ui.vbox`: a box that only arranges pixels has no `gui_input`
	# of its own, and a full-width one that stops the mouse eats every press meant
	# for the rows inside it.
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", separation)
	scroll.add_child(box)
	return scroll


## The row box of a list from `Ui.scroll_list()`, or `null` for anything else.
static func list_box(scroll: ScrollContainer) -> VBoxContainer:
	if scroll == null or not is_instance_valid(scroll):
		return null
	return scroll.get_node_or_null(LIST_ROWS) as VBoxContainer


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
##
## `companions` are the buttons a screen declares for itself
## (`GameRegistry.companions_of`), each one a `{"label", "screen", "payload"}`
## dictionary. They sit in front of "◀ Lobby", because they are the screen's own
## action and the bar's stock buttons are the ways out of it. An empty list is
## the normal answer and adds nothing to the bar.
##
## Ahead of the companions sits the theme button, and only where there is one:
## `ThemePicker` answers from the registry whether this screen has other
## editions of its game, and a game that has none gets exactly the bar it had.
## The button wears the current edition's own icon and accent, because that is
## what the editions differ in — and it is 60 wide rather than a caption, so
## three more of them would still fit a phone.
static func top_bar(height: float, owner: Node, on_suggest: Callable, companions: Array = []) -> HBoxContainer:
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

	var screen_id := ThemePicker.screen_id_of(owner)
	if ThemePicker.has_editions(screen_id):
		var edition := ThemePicker.current_edition(screen_id)
		var accent: Color = edition.get("accent", UiTheme.ACCENT)
		var theme_button := button(str(edition.get("icon", "")), Vector2(60.0, TOP_BAR_BUTTON), accent, func() -> void:
			Sfx.select()
			ThemePicker.open(owner)
		)
		# A tooltip costs nothing on a desktop run and says nothing on a phone —
		# which is fine, the dialog spells every edition out.
		theme_button.tooltip_text = Loc.resolve(str(edition.get("name", "")))
		bar.add_child(theme_button)

	for entry in companions:
		var companion := _companion_button(entry as Dictionary)
		if companion != null:
			bar.add_child(companion)

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


## One screen's own top-bar button, or `null` for an entry without a target.
##
## A function of its own because a lambda may not capture a variable declared
## inside a `for` body: the compiler rejects it, and the workaround of one
## lambda outside the loop would give every button the target of the last entry.
static func _companion_button(entry: Dictionary) -> Button:
	var target := str(entry.get("screen", ""))
	if target.is_empty():
		return null
	var payload: Dictionary = entry.get("payload", {})
	return button(str(entry.get("label", "Merge")), Vector2(150, TOP_BAR_BUTTON), UiTheme.ACCENT, func() -> void:
		Sfx.select()
		Router.go_to(target, payload)
	)


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
