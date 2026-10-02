class_name WorldScreen
extends Node3D
## Base class of every 3D subgame.
##
## Owns the environment, the follow camera and the 2D HUD layer; touch controls
## come from `add_stick()` / `add_action_button()`.
## Subclasses build in `_ready_world()` and per-frame logic in `_update_world()`.

const HUD_HEIGHT := 56
## Draw order inside `hud_root`, see `Screen.CHROME_Z`.
const CHROME_Z := 10
const MODAL_Z := 20

var screen_id: String = ""
var data: Dictionary = {}

var camera: Camera3D
var hud: CanvasLayer
var hud_root: Control
var environment_node: WorldEnvironment
var sun: DirectionalLight3D
var fill: DirectionalLight3D
var elapsed: float = 0.0

var _loading_label: Label
## Actions an on-screen button pressed and has not released yet.
var _held_actions: Array[StringName] = []


func _ready() -> void:
	_build_environment()
	_build_hud_layer()
	_ready_world()
	if not data.is_empty():
		_on_data(data)


## Override point.
func _ready_world() -> void:
	pass


func _on_data(_payload: Dictionary) -> void:
	pass


func _process(delta: float) -> void:
	elapsed += delta
	_fade_notify(delta)
	_update_world(delta)


## Override point for per-frame logic.
func _update_world(_delta: float) -> void:
	pass


# --- world helpers ----------------------------------------------------------

func _build_environment() -> void:
	environment_node = WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.027, 0.05)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.58, 0.77, 1.0)
	env.ambient_light_energy = 0.55
	env.fog_enabled = true
	env.fog_light_color = Color(0.02, 0.027, 0.05)
	env.fog_density = 0.008
	environment_node.environment = env
	add_child(environment_node)

	sun = DirectionalLight3D.new()
	sun.light_energy = 1.1
	sun.light_color = Color(1.0, 0.95, 0.86)
	sun.rotation_degrees = Vector3(-52, 38, 0)
	sun.shadow_enabled = false
	add_child(sun)

	fill = DirectionalLight3D.new()
	fill.light_energy = 0.35
	fill.light_color = Color(0.55, 0.62, 1.0)
	fill.rotation_degrees = Vector3(-18, -140, 0)
	add_child(fill)

	camera = Camera3D.new()
	camera.fov = 58.0
	camera.near = 0.1
	camera.far = 400.0
	camera.position = Vector3(0, 12, 14)
	camera.current = true
	add_child(camera)


## Builds the shared 2D overlay (top bar + loading label). Subclasses add to `hud_root`.
func _build_hud_layer() -> void:
	hud = CanvasLayer.new()
	add_child(hud)
	hud_root = Control.new()
	hud_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hud_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_root.theme = UiTheme.shared()
	hud.add_child(hud_root)

	# One builder for both base classes, see `Ui.top_bar`. The only difference
	# is the entry point into the suggestion dialog: a 3D screen has no `Control`
	# to hand `SuggestDialog.open`. `screen_id` is set by the router before the
	# screen enters the tree, so a companion declared for this screen is in the
	# bar from the first frame.
	var bar := Ui.top_bar(HUD_HEIGHT, self, func() -> void: SuggestDialog.open_world(self), GameRegistry.companions_of(screen_id))
	bar.z_index = CHROME_Z
	hud_root.add_child(bar)

	_loading_label = Ui.title(Loc.t("ui.loading"), 26, UiTheme.TEXT_DIM)
	_loading_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_loading_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hud_root.add_child(_loading_label)


## Releases every action that an on-screen button pressed.
##
## `Router.go_to` frees the screen, and a button that is still held never gets
## its `button_up` — the action then stays pressed for the rest of the session
## and the next screen starts with a permanently held "fire", "jump" or "dash".
func _exit_tree() -> void:
	for action in _held_actions:
		Input.action_release(action)
	_held_actions.clear()


## Full-screen modal layer used for pause and game-over states.
## The 2D twin is `Screen.modal()`. Crystal jumper, Metro and Siedler each
## grew their own layer for this, three incompatible spellings of one idea.
func modal() -> Control:
	var layer := Control.new()
	layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.set_meta("modal", true)
	layer.z_index = MODAL_Z
	hud_root.add_child(layer)
	return layer


## Removes every modal layer created by `modal()`.
func close_modals() -> void:
	for child in hud_root.get_children():
		if child.has_meta("modal"):
			child.queue_free()


func has_modal() -> bool:
	for child in hud_root.get_children():
		if child.has_meta("modal"):
			return true
	return false


func hide_loading() -> void:
	if _loading_label != null:
		_loading_label.visible = false


## Shows a transient message across the lower third of the screen.
## Named `notify` so a 3D game with a toast of its own does not shadow it.
var _notify_label: Label
var _notify_time := 0.0


func notify(text: String, seconds: float = 2.2) -> void:
	if _notify_label == null:
		_notify_label = Ui.label("", 22, UiTheme.TEXT, true)
		_notify_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
		_notify_label.offset_left = 0
		_notify_label.offset_right = 0
		_notify_label.offset_top = -190
		_notify_label.offset_bottom = -150
		_notify_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_notify_label.add_theme_constant_override("outline_size", 8)
		_notify_label.add_theme_color_override("font_outline_color", Color("020617"))
		_notify_label.modulate.a = 0.0
		hud_root.add_child(_notify_label)
	_notify_label.text = Loc.resolve(text)
	_notify_label.modulate.a = 1.0
	_notify_time = seconds


func _fade_notify(delta: float) -> void:
	if _notify_time <= 0.0 or _notify_label == null:
		return
	_notify_time = maxf(0.0, _notify_time - delta)
	_notify_label.modulate.a = clampf(_notify_time * 2.5, 0.0, 1.0)


## Camera that trails a target from a fixed offset; height/distance in world units.
func follow_camera(target: Vector3, height: float, distance: float, lerp_speed: float = 6.0, delta: float = 0.016) -> void:
	var goal := Vector3(target.x, target.y + height, target.z + distance)
	camera.position = camera.position.lerp(goal, clampf(lerp_speed * delta, 0.0, 1.0))
	camera.look_at(target, Vector3.UP)


# --- touch ------------------------------------------------------------------

## Adds a thumb stick anchored to a screen corner; returns it for per-frame reads.
##
## Corner insets go through `offset_*`, never `position`: `position` is measured
## from the parent origin, so "24 px above the bottom edge" lands off screen.
## Size is read once up front because `Control` re-clamps an inconsistent offset
## pair.
func add_stick(corner: String = "bottom_left", label_text: String = "") -> VirtualStick:
	var stick := VirtualStick.new()
	stick.label_text = label_text
	stick.size = VirtualStick.SIZE
	hud_root.add_child(stick)
	var extent := stick.size
	if corner == "bottom_right":
		stick.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
		stick.offset_left = -24.0 - extent.x
	else:
		stick.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
		stick.offset_left = 24.0
	stick.offset_right = stick.offset_left + extent.x
	stick.offset_top = -24.0 - extent.y
	stick.offset_bottom = -24.0
	return stick


## Adds a round action button to the bottom-right cluster.
##
## A `TouchButton`, not a `Button`: the stick under the other thumb holds the
## first finger, and a plain `Button` only ever sees the one finger Godot
## emulates into a mouse — see `TouchButton` for the whole story. Typed as
## `Button` because `TouchButton` is one and callers may store it as either.
func add_action_button(text: String, radius: float = 62.0, action: StringName = &"", on_press: Callable = Callable(), offset: Vector2 = Vector2.ZERO) -> Button:
	var node := TouchButton.new()
	node.text = text
	node.custom_minimum_size = Vector2(radius, radius)
	node.size = Vector2(radius, radius)
	node.focus_mode = Control.FOCUS_NONE
	node.add_theme_font_size_override("font_size", int(radius * 0.34))
	node.add_theme_stylebox_override("normal", UiTheme.flat(Color(0.098, 0.141, 0.239, 0.75), UiTheme.ACCENT, int(radius * 0.5)))
	node.add_theme_stylebox_override("hover", UiTheme.flat(Color(0.153, 0.212, 0.345, 0.85), UiTheme.ACCENT, int(radius * 0.5)))
	node.add_theme_stylebox_override("pressed", UiTheme.flat(UiTheme.ACCENT.darkened(0.25), Color.WHITE, int(radius * 0.5)))
	if not action.is_empty():
		# Holding the button feeds the same InputMap action, so game code reads
		# one source only. The press is remembered, because `button_up` does not
		# arrive if the screen is freed while the button is held — `_exit_tree`
		# releases what is left.
		node.button_down.connect(func() -> void:
			Input.action_press(action)
			if not _held_actions.has(action):
				_held_actions.append(action)
		)
		node.button_up.connect(func() -> void:
			Input.action_release(action)
			_held_actions.erase(action)
		)
	if on_press.is_valid():
		node.pressed.connect(on_press)
	hud_root.add_child(node)
	# Corner inset via offsets, for the same reason as in `add_stick()`.
	var extent := node.size
	node.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	node.offset_left = -28.0 + offset.x - extent.x
	node.offset_right = -28.0 + offset.x
	node.offset_top = -28.0 + offset.y - extent.y
	node.offset_bottom = -28.0 + offset.y
	return node


func set_fog(color: Color, density: float) -> void:
	var env := environment_node.environment
	env.fog_light_color = color
	env.background_color = color
	env.fog_density = density


func set_ambient(sky: Color, energy: float) -> void:
	var env := environment_node.environment
	env.ambient_light_color = sky
	env.ambient_light_energy = energy


# --- mesh helpers -----------------------------------------------------------

## Applies a colour to every `StandardMaterial3D` in a freshly imported scene.
static func tint(root: Node, color: Color, emission: float = 0.0) -> void:
	for child in root.get_children():
		if child is GeometryInstance3D:
			var geometry := child as GeometryInstance3D
			geometry.material_override = standard_material(color, emission)
		tint(child, color, emission)


static func standard_material(color: Color, emission: float = 0.0) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.82
	material.metallic = 0.05
	if emission > 0.0:
		material.emission_enabled = true
		material.emission = color
		material.emission_energy_multiplier = emission
	return material


## The bounding box of an instantiated mesh, in that node's own space.
##
## An imported glTF is a `Node3D` with `MeshInstance3D` children, so the bounds
## have to be collected over the whole subtree and pulled back through each
## child's own transform. An empty `AABB` (detectable with `has_surface()`) when
## there is no geometry at all.
##
## `AABB * Transform3D` is not used here: it documents itself as an inverse
## transform under the assumption of an orthonormal basis, and the eight corners
## say exactly what happens instead. The transforms walked are the nodes' own,
## before any scaling is applied to the root.
static func bounds_of(root: Node) -> AABB:
	var union := AABB()
	var found := false
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var current: Node = stack.pop_back()
		if current is MeshInstance3D:
			var surface: Mesh = (current as MeshInstance3D).mesh
			if surface != null:
				var xform: Transform3D = (current as MeshInstance3D).transform
				var box: AABB = surface.get_aabb()
				var placed := AABB(xform * box.position, Vector3.ZERO)
				for i in 8:
					placed = placed.expand(xform * box.get_endpoint(i))
				union = placed if not found else union.merge(placed)
				found = true
		for child in current.get_children():
			if child is Node3D:
				stack.append(child)
	return union


## Scales a mesh so its largest dimension is `target` and stands it on its own
## base: its lowest point ends up at y = 0 in the node's own space. Returns the
## scale it applied, or `0.0` when there was no geometry to measure.
##
## The bundled meshes share no dimensions: a coin is a flat disc, a castle is
## three units tall. Shown at their original size next to each other, one
## pedestal carries a bucket and the next a flagpole, and half of them float
## above the plinth or sink into it, because every mesh was authored standing on
## its own origin. Normalising the largest axis gives every pedestal the same
## visual weight; anchoring the base puts each object where it was drawn.
static func fit_on_base(root: Node3D, target: float) -> float:
	var box := bounds_of(root)
	if not box.has_surface():
		return 0.0
	var largest := maxf(box.size.x, maxf(box.size.y, box.size.z))
	if largest <= 0.0001:
		return 0.0
	var applied := clampf(target / largest, 0.01, 1000.0)
	root.scale = Vector3.ONE * applied
	var centre := box.get_center()
	root.position = Vector3(-centre.x * applied, -box.position.y * applied, -centre.z * applied)
	return applied


## Loads one of the bundled Blender meshes, scaled and tinted. Returns `null`
## when the import failed so callers can fall back to a primitive.
static func mesh(key: String, color: Color = Color.WHITE, scale: float = 1.0, emission: float = 0.0) -> Node3D:
	# A key that already is a `res://` path (the gallery's LOD tiers) is used as is.
	var path := key if key.begins_with("res://") else "res://assets/meshes/%s.glb" % key
	if not ResourceLoader.exists(path):
		return null
	var packed: PackedScene = load(path)
	if packed == null:
		return null
	var instance := packed.instantiate()
	instance.scale = Vector3.ONE * scale
	if color != Color.WHITE or emission > 0.0:
		tint(instance, color, emission)
	return instance
