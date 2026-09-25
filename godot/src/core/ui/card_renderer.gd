class_name CardRenderer
extends RefCounted
## Draws playing cards onto any `CanvasItem`.
##
## Both card games (Texas Hold'em and FreeCell) share this so a card always
## looks the same: rounded white face, coloured rank/suit in the corner, a
## plain blue back and a yellow selection halo.

const FACE := Color(0.973, 0.980, 0.988)
const FACE_BORDER := Color(0.580, 0.639, 0.706)
const BACK := Color(0.114, 0.306, 0.847)
const BACK_BORDER := Color(0.118, 0.227, 0.541)
const BACK_INNER := Color(0.118, 0.251, 0.686)
const SLOT := Color(0.043, 0.071, 0.125, 0.55)
const SLOT_BORDER := Color(0.200, 0.259, 0.333)
const HIGHLIGHT := Color(0.980, 0.800, 0.086)


## Empty slot outline (free cell / foundation / empty tableau column).
static func slot(ci: CanvasItem, rect: Rect2, tint: Color = SLOT_BORDER, radius: float = 7.0) -> void:
	ci.draw_rect(rect, SLOT, true)
	_rounded_outline(ci, rect.grow(-1.0), tint, 2.0, radius)


## Draws one card. `face_up = false` renders the patterned back.
static func card(ci: CanvasItem, rect: Rect2, card: Variant, face_up: bool = true, highlight: bool = false, label_scale: float = 1.0) -> void:
	if highlight:
		_rounded_fill(ci, rect.grow(4.0), HIGHLIGHT, 9.0)

	if face_up and card != null:
		_rounded_fill(ci, rect, FACE, 7.0)
		_rounded_outline(ci, rect.grow(-1.0), FACE_BORDER, 2.0, 7.0)
		var font := Ui.font_bold()
		if font != null:
			var size := int(round(20.0 * label_scale))
			var text := Cards.label_of(card)
			var color: Color = Cards.color_for_suit(card.suit)
			ci.draw_string(font, rect.position + Vector2(9.0 * label_scale, 6.0 * label_scale + size * 0.82),
					text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)
			# A large centre pip makes the card readable at small sizes too.
			var big := int(round(38.0 * label_scale))
			ci.draw_string(font, rect.position + Vector2(rect.size.x * 0.5 - big * 0.34, rect.size.y * 0.72),
					Cards.SUIT_SYMBOLS[card.suit], HORIZONTAL_ALIGNMENT_LEFT, -1, big, color)
		return

	_rounded_fill(ci, rect, BACK, 7.0)
	_rounded_outline(ci, rect.grow(-1.0), BACK_BORDER, 2.0, 7.0)
	var inner := Rect2(rect.position + Vector2(7, 7), rect.size - Vector2(14, 14))
	if inner.size.x > 4.0 and inner.size.y > 4.0:
		_rounded_fill(ci, inner, BACK_INNER, 5.0)


static func _rounded_fill(ci: CanvasItem, rect: Rect2, color: Color, radius: float) -> void:
	var points := PackedVector2Array(_rounded_points(rect, radius))
	if points.size() >= 3:
		ci.draw_colored_polygon(points, color)


static func _rounded_outline(ci: CanvasItem, rect: Rect2, color: Color, width: float, radius: float) -> void:
	var points := PackedVector2Array(_rounded_points(rect, radius))
	points.append(points[0])
	if points.size() >= 3:
		ci.draw_polyline(points, color, width, true)


static func _rounded_points(rect: Rect2, radius: float) -> Array[Vector2]:
	var points: Array[Vector2] = []
	var r: float = minf(radius, minf(rect.size.x, rect.size.y) * 0.5)
	if r <= 0.5:
		return [rect.position, rect.position + Vector2(rect.size.x, 0), rect.end, rect.position + Vector2(0, rect.size.y)]
	var corners := [
		[rect.position + Vector2(r, r), PI, PI * 1.5],
		[rect.position + Vector2(rect.size.x - r, r), PI * 1.5, TAU],
		[rect.end - Vector2(r, r), 0.0, PI * 0.5],
		[rect.position + Vector2(r, rect.size.y - r), PI * 0.5, PI],
	]
	for corner in corners:
		var center: Vector2 = corner[0]
		var from: float = corner[1]
		var to: float = corner[2]
		for step in 5:
			var angle: float = lerp(from, to, float(step) / 4.0)
			points.append(center + Vector2(cos(angle), sin(angle)) * r)
	return points
