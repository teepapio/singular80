class_name UiTheme
extends RefCounted
## Builds the shared theme in code: colours, font and the styleboxes every
## screen reuses. Building it programmatically keeps the look consistent and
## avoids shipping a binary `.tres`.

const BG := Color(0.031, 0.047, 0.086)
const PANEL := Color(0.059, 0.090, 0.165)
const PANEL_LIGHT := Color(0.098, 0.141, 0.239)
const BORDER := Color(0.278, 0.341, 0.412)
const TEXT := Color(0.973, 0.980, 0.988)
const TEXT_DIM := Color(0.580, 0.639, 0.706)
const TEXT_MUTED := Color(0.392, 0.455, 0.545)
const ACCENT := Color(0.055, 0.647, 0.898)
const SUCCESS := Color(0.133, 0.773, 0.369)
const WARNING := Color(0.961, 0.620, 0.043)
const DANGER := Color(0.937, 0.267, 0.267)

const FONT_REGULAR := "res://assets/fonts/DejaVuSans.ttf"
const FONT_BOLD := "res://assets/fonts/DejaVuSans-Bold.ttf"

static var _shared: Theme = null
## Fonts are loaded once and reused by every screen. `Ui.label()` asks for one
## per label, `CardRenderer` per drawn card and `VirtualStick._draw()` on every
## drag event, so `load()` per call is a resource lookup in a hot path.
static var _font_regular: Font = null
static var _font_bold: Font = null


static func shared() -> Theme:
	if _shared == null:
		_shared = _build()
	return _shared


static func font_regular() -> Font:
	if _font_regular == null:
		_font_regular = load(FONT_REGULAR) as Font
	return _font_regular


static func font_bold() -> Font:
	if _font_bold == null:
		_font_bold = load(FONT_BOLD) as Font
	return _font_bold


static func _build() -> Theme:
	var theme := Theme.new()
	var regular := font_regular()
	var bold := font_bold()
	if regular != null:
		theme.default_font = regular
	theme.default_font_size = 18

	# Buttons -------------------------------------------------------------
	var normal := flat(PANEL_LIGHT, BORDER, 10)
	var hover := flat(PANEL_LIGHT.lightened(0.12), ACCENT, 10)
	var pressed := flat(PANEL_LIGHT.darkened(0.2), ACCENT, 10)
	var disabled := flat(Color(0.078, 0.110, 0.165), Color(0.16, 0.20, 0.26), 10)
	theme.set_stylebox("normal", "Button", normal)
	theme.set_stylebox("hover", "Button", hover)
	theme.set_stylebox("pressed", "Button", pressed)
	theme.set_stylebox("disabled", "Button", disabled)
	# No "focus" stylebox: `Ui.button`, `add_action_button` and the two raw
	# `Button.new()` call sites all set `focus_mode = FOCUS_NONE`, so it can
	# never be drawn.
	theme.set_color("font_color", "Button", TEXT)
	theme.set_color("font_hover_color", "Button", Color.WHITE)
	theme.set_color("font_pressed_color", "Button", Color.WHITE)
	theme.set_color("font_disabled_color", "Button", TEXT_MUTED)
	theme.set_color("font_outline_color", "Button", Color(0.008, 0.016, 0.031, 0.7))
	theme.set_constant("outline_size", "Button", 3)
	theme.set_font("font", "Button", bold)
	theme.set_font_size("font_size", "Button", 18)
	theme.set_constant("h_separation", "Button", 6)

	# Labels ---------------------------------------------------------------
	theme.set_color("font_color", "Label", TEXT)
	theme.set_color("font_outline_color", "Label", Color(0.008, 0.016, 0.031, 0.75))
	theme.set_constant("outline_size", "Label", 4)
	theme.set_font("font", "Label", regular)
	theme.set_font_size("font_size", "Label", 18)
	theme.set_color("default_color", "RichTextLabel", TEXT)
	theme.set_font("normal_font", "RichTextLabel", regular)
	theme.set_font("bold_font", "RichTextLabel", bold)
	theme.set_font_size("normal_font_size", "RichTextLabel", 18)
	theme.set_font_size("bold_font_size", "RichTextLabel", 18)

	# Panels ---------------------------------------------------------------
	theme.set_stylebox("panel", "PanelContainer", flat(PANEL, BORDER, 12))
	theme.set_stylebox("panel", "Panel", flat(PANEL, BORDER, 12))

	# Line edits -----------------------------------------------------------
	theme.set_stylebox("normal", "LineEdit", flat(Color(0.043, 0.071, 0.125), BORDER, 8))
	theme.set_stylebox("focus", "LineEdit", flat(Color(0.043, 0.071, 0.125), ACCENT, 8))
	theme.set_color("font_color", "LineEdit", TEXT)
	theme.set_color("font_placeholder_color", "LineEdit", TEXT_MUTED)
	theme.set_color("caret_color", "LineEdit", ACCENT)
	theme.set_font("font", "LineEdit", regular)
	theme.set_font_size("font_size", "LineEdit", 18)

	# Text areas ------------------------------------------------------------
	theme.set_stylebox("normal", "TextEdit", flat(Color(0.043, 0.071, 0.125), BORDER, 8))
	theme.set_stylebox("focus", "TextEdit", flat(Color(0.043, 0.071, 0.125), ACCENT, 8))
	theme.set_color("font_color", "TextEdit", TEXT)
	theme.set_color("font_placeholder_color", "TextEdit", TEXT_MUTED)
	theme.set_color("caret_color", "TextEdit", ACCENT)
	theme.set_font("font", "TextEdit", regular)
	theme.set_font_size("font_size", "TextEdit", 18)

	# Sliders / progress -----------------------------------------------------
	theme.set_stylebox("background", "ProgressBar", flat(Color(0.043, 0.071, 0.125), BORDER, 6))
	theme.set_stylebox("fill", "ProgressBar", flat(ACCENT, ACCENT, 6))
	# No HSlider and no CheckBox theme: the game has neither. The switches in
	# the settings are buttons (`Ui.button`), and "sound" and "touch controls"
	# are toggles, not check boxes.

	theme.set_color("font_color", "PopupMenu", TEXT)
	theme.set_stylebox("panel", "PopupMenu", flat(PANEL, BORDER, 10))

	return theme


static func flat(fill: Color, border: Color = Color(0, 0, 0, 0), radius: int = 8, width: int = 2) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.set_corner_radius_all(radius)
	if border.a > 0.0:
		box.border_color = border
		box.set_border_width_all(width)
	box.content_margin_left = 14
	box.content_margin_right = 14
	box.content_margin_top = 8
	box.content_margin_bottom = 8
	return box


## Parses `#rrggbb` (as used throughout the content JSON) into a `Color`.
static func from_hex(value: String, fallback: Color = Color.WHITE) -> Color:
	var text := value.strip_edges()
	if text.begins_with("#"):
		text = text.substr(1)
	if text.length() == 3:
		text = text[0] + text[0] + text[1] + text[1] + text[2] + text[2]
	if text.length() != 6:
		return fallback
	if not text.is_valid_hex_number(false):
		return fallback
	return Color("#" + text)
