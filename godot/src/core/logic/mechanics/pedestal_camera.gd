class_name PedestalCamera
extends Mechanic
## A pan / zoom / tap camera rig for a 3D screen that shows pedestals.
##
## ## What it is for
##
## suggestion #21 asked, for the Drachenflug hatchery: "make the areas with the
## pedestals scrollable, zoomable, draggable, when i click on a Dragon IT shall
## be selected". The hatchery is the first screen that wants this, not the only
## one — and by then three 3D screens in this game hand-rolled the same gesture
## without agreeing on it: the metro map (`metro_screen.gd`) keeps its own
## `_pointers` dictionary, the settler map (`siedler_screen.gd`) has a `Pointer`
## helper inside `siedler.gd`, and the hatchery had no gesture at all. This file
## is the part all of them need and none of them should write twice: which
## pointers are down, whether a press has become a drag, where the focus point
## may go, and how far the camera may zoom.
##
## ## A tap is a release, not a press
##
## The hatchery used to select a dragon when a finger went *down*. The moment the
## same screen also pans, every drag that happens to start over a dragon selects
## it — and `_assign_parent()` in the screen toggles, so a drag that starts and
## ends on the same dragon selects it and then drops it again. That is the
## difference between "the area is draggable" and "the area fights the player",
## so `pointer_up()` is what reports a tap and the screen picks after it.
##
## ## Why this file is not the whole input handler
##
## A screen maps its own `InputEvent`s onto these five calls, and it has to drop
## what Godot manufactures. That last half is not optional:
## `pointing/emulate_mouse_from_touch` and `pointing/emulate_touch_from_mouse`
## are both true in `project.godot`, so every finger arrives *twice* — once as
## an `InputEventScreenTouch` and once as an `InputEventMouseButton` — and every
## desktop click arrives twice as well. Godot marks its own copies
## `InputEvent.DEVICE_ID_EMULATION`; the class reference says exactly that
## ("Device ID used for emulated mouse input from a touchscreen, or for emulated
## touch input from a mouse"), and `core/input/input.cpp` (4.5) is where the
## copies are built: under `emulate_mouse_from_touch` only the touch that took
## `mouse_from_touch_index` is translated, and that index is *not* necessarily
## 0. So an emulated mouse event filed under a fixed index 0 opens a phantom
## second pointer, the valley pans on its own, and a pinch fires while the player
## only ever used one finger. A screen therefore drops emulated events outright
## and this file never sees the duplicate.
##
## ## Wiring it into a screen
##
##     var cam := MechanicsIndex.by_id("pedestal_camera") as PedestalCamera
##     cam.pitch = deg_to_rad(23.3)
##     cam.min_distance = 12.0
##     cam.max_distance = 42.0
##     cam.bounds = Rect2(-18.0, -14.0, 32.0, 34.0)   # x/z the focus may reach
##     cam.remember_home(Vector3(3.0, 1.5, -2.0), 24.0)
##     cam.snap(camera)                               # first frame, no lerp
##
##     # every frame, in _update_world(delta)
##     cam.apply(camera, delta)
##
##     # and on input, after dropping InputEvent.DEVICE_ID_EMULATION
##     cam.pointer_down(touch.index, touch.position)   # press / drag / release
##     if cam.pointer_up(touch.index):                 # a tap, not a drag
##         select(cam.pick(camera, cam.last_tap, spots))
##
## The aim points in `spots` are the world positions a finger may select. A
## dragon stands 1.5 above its plinth, so the plinth top is the wrong point and
## the tap misses by a dragon's height. `PackedVector3Array` keeps the hot path
## free of allocations, and the same array is reused for every tap.

## How far a pointer may travel before its press counts as a drag. 22 px is what
## `Siedler.Pointer.TAP_SLOP` and the metro map use; below it a shaky thumb
## selects a dragon while the player meant to look around.
const TAP_SLOP := 22.0
## The smallest span two fingers are allowed to have before a pinch reads as
## zoom. Below it the ratio explodes and one frame throws the camera to a limit.
const MIN_SPAN := 1.0
## Screen pixels a drag covers per world unit at the starting distance. The
## effective value is scaled with the zoom, so a drag moves the same number of
## *screen* pixels of valley at every distance — otherwise a drag at max zoom
## flings the camera across the map and one at min zoom appears to do nothing.
const PAN_SPEED := 0.055
## How fast the real camera catches up with the goal. A lerp, not a jump: a
## pinch reads as the valley settling under the fingers instead of a cut.
const FOLLOW_SPEED := 9.0

## Where the focus starts, and where `reset()` returns to.
var home := Vector3.ZERO
## The point the camera looks at. Pan moves it; it is clamped to `bounds`.
var focus := Vector3.ZERO
## Distance from the focus to the camera. Smaller is closer.
var distance := 24.0
## Around the focus, 0 looking from `+z` towards `-z`.
var yaw := 0.0
## Down towards the focus. The default is a shallow 23°, the angle the hatchery
## and the metro map were drawn at: steeper and six pedestals in a ring no
## longer fit on a phone.
var pitch := 0.407
var min_distance := 11.0
var max_distance := 42.0
## The box the focus may reach, `x`/`y` as the world x/z minimum and `size` as
## its extent. Without it the valley can be dragged off the screen and the
## player has no way back but the reset button.
var bounds := Rect2(-20.0, -16.0, 40.0, 40.0)

## Where the last tap was, in screen pixels, for a screen that picks after the
## release.
var last_tap := Vector2.ZERO

## The distance `remember_home()` was given. The pick radius is measured against
## it, because that is the distance the screen's own numbers were written at.
var _home_distance := 24.0

## Pointer bookkeeping. Two dictionaries and a few numbers, all written on
## press and only read on move and release — the drag flag in particular must
## not be recomputed from the current position, because a position compared with
## itself never leaves the slop radius and the pan becomes unreachable.
var _at: Dictionary = {}
var _start: Dictionary = {}
var _dragged := false
var _span := 0.0
var _mid := Vector2.ZERO
var _pinching := false


func _init() -> void:
	id = "pedestal_camera"
	mechanic_name = "Pedestal camera"
	# No description on purpose, as in `merge_drag.gd`: a description is a line
	# the player reads, and the screen's own hint label says this one.
	description = ""


# --- configuration -----------------------------------------------------------

## Sets the framing the screen was drawn at. A screen calls this once, from the
## camera position and target it had been placing by hand, so the first frame of
## the rig is the frame the screen used to draw and nothing moves on entry.
func remember_home(point: Vector3, home_distance: float) -> void:
	home = point
	focus = point
	_home_distance = maxf(home_distance, 0.001)
	distance = clampf(home_distance, min_distance, max_distance)


## Back to the framing from `remember_home()`. Pan and zoom are lost with it,
## which is the point: it is the one control that always works, on a phone with
## no pinch and no spare thumb.
func reset() -> void:
	focus = home
	yaw = 0.0
	distance = clampf(_home_distance, min_distance, max_distance)


## Puts the camera exactly on the goal — the first frame, and after a reset,
## where a lerp would show the valley sliding in from its old spot.
func snap(camera: Camera3D) -> void:
	if camera == null:
		return
	camera.position = goal()
	camera.look_at(focus, Vector3.UP)


## Drives the camera towards the goal. `delta` is the frame time; the weight is
## clamped, so a long frame cannot overshoot into a jitter.
func apply(camera: Camera3D, delta: float) -> void:
	if camera == null:
		return
	camera.position = camera.position.lerp(goal(), clampf(FOLLOW_SPEED * delta, 0.0, 1.0))
	camera.look_at(focus, Vector3.UP)


## The position the camera is heading for, so a screen can size its own controls
## — a zoom slider, a pick radius — to the current distance.
func goal() -> Vector3:
	var horizontal := cos(pitch) * distance
	return focus + Vector3(sin(yaw) * horizontal, sin(pitch) * distance, cos(yaw) * horizontal)


# --- gesture -----------------------------------------------------------------

## How many pointers are down. Two or more means a pinch is running.
func tracking() -> int:
	return _at.size()


## Whether this pointer index is currently down.
func has_pointer(index: int) -> bool:
	return _at.has(index)


## A pointer went down. A second finger turns the press into a pinch, so it can
## no longer end as a tap on whatever it happened to land on.
func pointer_down(index: int, position: Vector2) -> void:
	_at[index] = position
	_start[index] = position
	_dragged = false
	if _at.size() >= 2:
		_begin_pinch()


## A pointer moved. Returns whether this move panned the camera, which a screen
## can use to put a "tap to select" hint away while the valley is being dragged.
func pointer_move(index: int, position: Vector2) -> bool:
	if not _at.has(index):
		return false
	var step: Vector2 = position - _at[index]
	_at[index] = position
	if not _dragged and _start[index].distance_to(position) > TAP_SLOP:
		_dragged = true
	if _at.size() >= 2:
		_pinch()
	elif _dragged:
		# Negated, because the valley follows the finger: dragging right moves
		# the content right, which moves the focus left.
		_pan(-step * PAN_SPEED * (distance / min_distance))
		return true
	return false


## A pointer was released. `true` means the release was a *tap* — the press
## never left the slop radius and no second finger joined — and `last_tap` holds
## where it happened. `false` covers a drag, a pinch and an index this rig does
## not track, which is what the second release of one gesture looks like.
func pointer_up(index: int) -> bool:
	if not _at.has(index):
		return false
	var was_tap := not _dragged
	last_tap = _at[index]
	_at.erase(index)
	_start.erase(index)
	if _at.size() >= 2:
		_begin_pinch()
	else:
		_pinching = false
	if _at.is_empty():
		# Nothing is down any more, so the next press starts a fresh press and
		# not the tail of this one.
		_dragged = false
	return was_tap


## A pointer the system took away — a cancelled touch, a focus change. The
## gesture is over and nothing is selected.
func cancel(index: int) -> void:
	if not _at.has(index):
		return
	_at.erase(index)
	_start.erase(index)
	_pinching = _at.size() >= 2
	if _at.is_empty():
		_dragged = false


## Moves the focus on the ground plane along the screen axes. The yaw turns
## those axes with the camera, so "left" stays left once the valley is turned.
func _pan(screen_delta: Vector2) -> void:
	var forward := Vector3(sin(yaw), 0.0, cos(yaw))
	var right := Vector3(forward.z, 0.0, -forward.x)
	var moved := focus - forward * screen_delta.y + right * screen_delta.x
	moved.x = clampf(moved.x, bounds.position.x, bounds.end.x)
	moved.z = clampf(moved.z, bounds.position.y, bounds.end.y)
	focus = moved


## Starts (or restarts) the pinch. The span is kept so the next move can be
## measured against it, and `_dragged` is set so letting go of one finger cannot
## read as a tap.
func _begin_pinch() -> void:
	var keys := _at.keys()
	if keys.size() < 2:
		return
	var a: Vector2 = _at[keys[0]]
	var b: Vector2 = _at[keys[1]]
	_span = maxf(a.distance_to(b), MIN_SPAN)
	_mid = (a + b) * 0.5
	_pinching = true
	_dragged = true


## One step of a two-finger gesture: the span zooms, the middle pans. Spreading
## the fingers moves in, because the span grows and the distance is divided by
## it — the same rule `metro_screen.gd` uses, and the one that matches what
## every other app on the device does.
func _pinch() -> void:
	if not _pinching:
		return
	var keys := _at.keys()
	if keys.size() < 2:
		return
	var a: Vector2 = _at[keys[0]]
	var b: Vector2 = _at[keys[1]]
	var span := maxf(a.distance_to(b), MIN_SPAN)
	zoom(_span / span)
	_span = span
	var mid := (a + b) * 0.5
	_pan((_mid - mid) * PAN_SPEED * (distance / min_distance))
	_mid = mid


## A zoom step: `0.9` moves in, `1.1` out. Clamped, so a long gesture stops at
## the limit instead of putting the camera inside the ground.
func zoom(factor: float) -> void:
	distance = clampf(distance * factor, min_distance, max_distance)


# --- picking -----------------------------------------------------------------

## Screen position → the index of the nearest aim point, or -1.
##
## The radius is in world units and is scaled with the current zoom: a fixed
## radius that feels right close up becomes unreachable once the valley is
## zoomed out, and every tap then lands between two dragons. The reference is
## the distance from `remember_home()`, the one the screen's numbers were
## written at.
func pick(camera: Camera3D, screen_position: Vector2, spots: PackedVector3Array, radius: float) -> int:
	if camera == null:
		return -1
	return pick_ray(camera.project_ray_origin(screen_position), camera.project_ray_normal(screen_position),
		spots, pick_radius(radius))


## `radius` in world units at the current zoom. Split out of `pick()` so a
## screen can size its own hit area from the same number, and so the scaling is
## testable without a scene tree.
func pick_radius(radius: float) -> float:
	return radius * (distance / _home_distance)


## The same, on a ray that is already known. Split out so the rule is testable
## without a scene tree, and so a screen that already has a ray does not project
## twice.
##
## The distance is measured from the *ray* to the point, not from the camera: a
## dragon behind the player projects onto the ray as well, and only the sign of
## `along` tells the two apart.
func pick_ray(origin: Vector3, direction: Vector3, spots: PackedVector3Array, radius: float) -> int:
	var best := -1
	var best_distance := radius
	for i in spots.size():
		var to: Vector3 = spots[i] - origin
		var along := to.dot(direction)
		if along <= 0.0:
			continue
		var gap := origin + direction * along
		var distance := gap.distance_to(spots[i])
		if distance < best_distance:
			best_distance = distance
			best = i
	return best
