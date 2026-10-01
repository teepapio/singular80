class_name MeshGalleryScreen
extends WorldScreen
## One long hall. Two rows of pedestals on either side, every mesh of the
## registry in walking order — walk down the nave and they pass on either side,
## step into the aisle between the rows and the far ones do. Three detail levels
## can be switched, and in front of a mesh the player presses E for the ordinary
## suggestion dialog, with that mesh named.
##
## The geometry lives in `MeshGallery`, so it is testable without a screen.

const MOVE_SPEED := 7.5
const CAMERA_HEIGHT := 9.0
const CAMERA_DISTANCE := 11.0
const SPIN_SPEED := 0.9
## Fallback rate for the info caption when nothing flagged a change. The change
## flag is what normally drives it; this bounds the staleness if a flag is missed.
const INFO_INTERVAL := 0.1

## How tall a mesh appears on its pedestal, whatever its real size is.
const MESH_ON_PEDESTAL := 1.75

# --- the hall ---------------------------------------------------------------

## How far the outer row stands from the middle line plus the aisle behind it,
## and with it the walls.
const HALL_HALF_WIDTH := 8.6
const WALL_HEIGHT := 4.2

## How far away a mesh may be before it goes into the scene — and how far it may
## have walked on before it leaves it again. Four pedestals to a step means
## twice as many meshes stand in as much hall, and a mesh on "high" carries
## fifty times the triangles of one on "low", so the window follows the level:
## on "high" it is narrower than the one this hall had with two rows, so it
## costs about what it did then while showing twice as much per screen.
const LOAD_DISTANCE := {"low": 48.0, "med": 40.0, "high": 30.0}
## Meshes taken into the scene per frame. One every 0.6 s of walking, so the
## hitch stays a few milliseconds instead of a visible pause.
const LOADS_PER_FRAME := 2
## The window is rebuilt after the player has walked this far, not every frame.
const SWEEP_STEP := 1.0

## The far end of the hall has to disappear into something, and the fog does
## the culling the eye expects.
const VIEW_FAR := 170.0
const FOG_COLOR := "060a14"
const FOG_DENSITY := 0.02

var tier := "low"

## Every key of the registry, in walking order. The four rows take them in turn.
var keys: Array[String] = []

var pos := Vector3(0, 0, 0)
var facing := PI
var player: Node3D
var slot_nodes: Array[Dictionary] = []
var active_slot := -1
var _interact_held := false

## The pedestal index range that currently holds a mesh, and the z the range was
## last computed for. Animation and streaming both walk only this window.
var _low := 0
var _high := -1
var _sweep_z := 1.0e9
var _reload := true

var _stick: VirtualStick
var _tier_label: Label
var _tier_buttons: Array[Button] = []
var _counter_label: Label
var _info_name: Label
var _info_meta: Label
var _info_hint: Label
## The info caption is rebuilt on a change flag or at 10 Hz, not every frame.
var _info_dirty := true
var _info_timer := 0.0


func _ready_world() -> void:
	tier = str(data.get("tier", "low")) if str(data.get("tier", "")) in AssetRegistry.TIERS else "low"
	keys = []
	keys.assign(AssetRegistry.KEYS)
	pos = Vector3(0, 0, MeshGallery.walk_bounds(keys.size()).y - 1.0)
	_build_hall()
	_build_slots()
	_build_player()
	_build_panels()
	_refresh_panel()
	_refresh_info()
	hide_loading()


# --- construction -----------------------------------------------------------

## The hall is built from primitives on purpose: it has to look deliberate, and
## it must never depend on a bundled mesh being importable.
func _build_hall() -> void:
	var bounds := MeshGallery.walk_bounds(keys.size())
	var length: float = absf(bounds.x) + absf(bounds.y) + 8.0
	var middle: float = (bounds.x + bounds.y) * 0.5

	camera.far = VIEW_FAR
	set_fog(Color(FOG_COLOR), FOG_DENSITY)

	var floor := MeshInstance3D.new()
	var plane := BoxMesh.new()
	plane.size = Vector3(HALL_HALF_WIDTH * 2.0, 0.2, length)
	floor.mesh = plane
	floor.material_override = WorldScreen.standard_material(Color("111827"), 0.85)
	floor.position = Vector3(0, -0.1, middle)
	add_child(floor)

	# A stripe down the middle makes the walk forward readable at a glance.
	var runner := MeshInstance3D.new()
	var stripe := BoxMesh.new()
	stripe.size = Vector3(1.4, 0.02, length)
	runner.mesh = stripe
	runner.material_override = WorldScreen.standard_material(Color("1e3a5f"), 0.4)
	runner.position = Vector3(0, 0.01, middle)
	add_child(runner)

	for side: float in [-1.0, 1.0]:
		var wall := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.4, WALL_HEIGHT, length)
		wall.mesh = box
		wall.material_override = WorldScreen.standard_material(Color("1f2937"), 0.7)
		wall.position = Vector3(side * HALL_HALF_WIDTH, WALL_HEIGHT * 0.5, middle)
		add_child(wall)


## One pedestal per mesh, four to a depth — inner and outer, left and right.
func _build_slots() -> void:
	for i in keys.size():
		var root := Node3D.new()
		root.position = MeshGallery.slot_position(i)
		add_child(root)

		var column := MeshInstance3D.new()
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = MeshGallery.PEDESTAL_RADIUS
		cylinder.bottom_radius = MeshGallery.PEDESTAL_RADIUS * 1.15
		cylinder.height = MeshGallery.PEDESTAL_HEIGHT
		column.mesh = cylinder
		column.position.y = MeshGallery.PEDESTAL_HEIGHT * 0.5
		column.material_override = WorldScreen.standard_material(Color("475569"), 0.55)
		root.add_child(column)

		var ring := MeshInstance3D.new()
		var torus := TorusMesh.new()
		torus.inner_radius = MeshGallery.PEDESTAL_RADIUS * 1.05
		torus.outer_radius = MeshGallery.PEDESTAL_RADIUS * 1.35
		torus.rings = 20
		ring.mesh = torus
		ring.position.y = MeshGallery.PEDESTAL_HEIGHT + 0.02
		ring.material_override = WorldScreen.standard_material(Color("64748b"), 0.4)
		root.add_child(ring)

		var holder := Node3D.new()
		holder.position.y = MeshGallery.PEDESTAL_HEIGHT
		root.add_child(holder)

		# A label standing on the pedestal, always facing the player.
		var sign := Label3D.new()
		sign.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		sign.font_size = 44
		sign.outline_size = 14
		sign.outline_modulate = Color("020617")
		sign.position = Vector3(0, 1.9, 0)
		# A `Label3D` resolves nothing on its own, so the display name has to be
		# translated where it is assigned.
		sign.text = Loc.resolve(AssetRegistry.display_name(str(keys[i])))
		sign.modulate = AssetRegistry.color_of(str(keys[i]))
		holder.add_child(sign)

		slot_nodes.append({
			"root": root, "holder": holder, "sign": sign, "ring": ring,
			"key": str(keys[i]), "mesh": null,
		})


func _build_player() -> void:
	player = Node3D.new()
	var knight := WorldScreen.mesh("rpg/knight", Color("cbd5e1"), 1.0)
	if knight != null:
		player.add_child(knight)
	# The light travels with the player: the hall is far too long to light.
	var light := OmniLight3D.new()
	light.light_color = Color("bae6fd")
	light.light_energy = 9.0
	light.omni_range = 22.0
	light.position = Vector3(0, 2.6, 0)
	player.add_child(light)
	player.position = pos
	add_child(player)


# --- HUD --------------------------------------------------------------------

func _build_panels() -> void:
	_stick = add_stick("bottom_left")
	add_action_button("E", 70.0, "interact")

	# Everything the player reads sits in one column at the top left, so the
	# bottom of the screen belongs to the stick and the action button alone.
	var left := VBoxContainer.new()
	left.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	left.position = Vector2(16, HUD_HEIGHT + 10)
	left.custom_minimum_size = Vector2(392, 0)
	left.add_theme_constant_override("separation", 6)
	hud_root.add_child(left)

	left.add_child(Ui.label("◈  MESH GALLERY", 24, UiTheme.ACCENT, true))
	_tier_label = Ui.label("", 14, UiTheme.TEXT_DIM)
	_tier_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tier_label.custom_minimum_size = Vector2(380, 0)
	left.add_child(_tier_label)

	var tier_row := Ui.hbox(6)
	left.add_child(tier_row)
	for name in AssetRegistry.TIERS:
		var tier_id: String = name
		var button := Ui.button(AssetRegistry.tier_label(tier_id), Vector2(124, 40), UiTheme.PANEL_LIGHT, func() -> void:
			_set_tier(tier_id)
		)
		tier_row.add_child(button)
		_tier_buttons.append(button)

	_counter_label = Ui.label("", 15, UiTheme.TEXT, true)
	left.add_child(_counter_label)

	var info := Ui.panel(Color(0.043, 0.063, 0.110, 0.9))
	info.custom_minimum_size = Vector2(380, 0)
	left.add_child(info)
	var column := Ui.vbox(4)
	info.add_child(column)
	_info_name = Ui.label("", 22, UiTheme.TEXT, true)
	_info_name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info_name.custom_minimum_size = Vector2(356, 0)
	column.add_child(_info_name)
	_info_meta = Ui.label("", 13, UiTheme.TEXT_DIM)
	_info_meta.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info_meta.custom_minimum_size = Vector2(356, 0)
	column.add_child(_info_meta)
	_info_hint = Ui.label("", 13, UiTheme.TEXT_MUTED)
	_info_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info_hint.custom_minimum_size = Vector2(356, 0)
	column.add_child(_info_hint)


# --- state ------------------------------------------------------------------

func _set_tier(next_tier: String) -> void:
	if not (next_tier in AssetRegistry.TIERS) or next_tier == tier:
		return
	tier = next_tier
	# Every resident mesh is on the wrong level now; the window reloads them.
	_reload_stream()
	_info_dirty = true
	Sfx.select()
	_refresh_panel()


## The mesh the player is standing in front of, or `""`.
func active_key() -> String:
	return MeshGallery.key_at(keys, active_slot)


## Opens the ordinary suggestion dialog, naming the mesh in front of the player.
##
## The same window the top bar opens — the gallery has no second one of its own
## any more, and the context is the only thing that differs: it carries the
## mesh, so the dashboard knows which one an idea is about.
func open_suggestion() -> void:
	Sfx.select()
	SuggestDialog.open_world(self, MeshGallery.context(active_key()))


# --- world ------------------------------------------------------------------

func _update_world(delta: float) -> void:
	_stream_step()
	# The dialog lives in its own layer above the screen: while it is up the
	# player stays where they stood, and the stick under their thumb does not
	# walk them down the hall behind the panel.
	if SuggestDialog.is_open():
		return

	var vector := VirtualStick.combined(_stick.value, &"move_left", &"move_right")
	if vector.length() > 0.05:
		var walk := MeshGallery.walk_bounds(keys.size())
		facing = atan2(-vector.x, -vector.y)
		# The hall is a nave with an aisle on either side: the middle lane, the
		# band the inner row closes off, the aisle between the two rows. z is
		# clamped first, because whether the player may stand beside a pedestal
		# at all depends on how far along they got — and which side they came
		# from decides which way a blocked one pushes them out.
		pos.z = clampf(pos.z + vector.y * MOVE_SPEED * delta, walk.x, walk.y)
		pos.x = MeshGallery.lane_x(pos.x + vector.x * MOVE_SPEED * delta, pos.z, pos.x)

	player.position = Vector3(pos.x, sin(elapsed * 3.0) * 0.04, pos.z)
	player.rotation.y = facing
	follow_camera(player.position, CAMERA_HEIGHT, CAMERA_DISTANCE, 7.0, delta)

	var nearest := MeshGallery.nearest_slot(keys, _ground())
	if nearest != active_slot:
		active_slot = nearest
		_info_dirty = true
	var pressed := Input.is_action_pressed("interact")
	if pressed and not _interact_held and active_slot >= 0:
		open_suggestion()
	_interact_held = pressed

	_animate_slots(delta)
	_info_timer -= delta
	# Four `Loc.f` calls and a join for a caption that only changes when the
	# player walks to another pedestal. The animation above still runs every
	# frame; the text waits for the change or the 10 Hz tick.
	if _info_dirty or _info_timer <= 0.0:
		_info_dirty = false
		_info_timer = INFO_INTERVAL
		_refresh_info()


## The player on the floor, without the bob `player.position` carries.
func _ground() -> Vector3:
	return Vector3(pos.x, 0.0, pos.z)


## Spins every resident mesh on its pedestal and makes the nearest one glow.
func _animate_slots(delta: float) -> void:
	for i in range(_low, _high + 1):
		if i < 0 or i >= slot_nodes.size():
			continue
		var slot: Dictionary = slot_nodes[i]
		if slot["mesh"] == null:
			continue
		var holder: Node3D = slot["holder"]
		holder.rotation.y += delta * SPIN_SPEED
		# The pedestal the player stands at lifts, so the eye finds it instantly.
		var bob := sin(elapsed * 2.0 + float(i)) * 0.09
		var wanted := MeshGallery.PEDESTAL_HEIGHT + bob + (0.6 if i == active_slot else 0.0)
		holder.position.y = lerpf(holder.position.y, wanted, 0.14)
		var ring: MeshInstance3D = slot["ring"]
		var ring_material := ring.material_override as StandardMaterial3D
		if ring_material == null:
			continue
		var ring_color := Color("facc15") if i == active_slot else Color("64748b")
		ring_material.albedo_color = ring_material.albedo_color.lerp(ring_color, 0.12)


# --- streaming --------------------------------------------------------------

## Fills the window for the player's current position and loads what is missing,
## at most `LOADS_PER_FRAME` meshes. Called every frame; the window itself is
## only recomputed once the player has walked a step.
func _stream_step() -> void:
	if _reload or absf(pos.z - _sweep_z) >= SWEEP_STEP:
		_sweep()
	var budget := LOADS_PER_FRAME
	for i in range(_low, _high + 1):
		if budget <= 0:
			return
		if i < 0 or i >= slot_nodes.size():
			continue
		var slot: Dictionary = slot_nodes[i]
		if slot["mesh"] != null:
			continue
		_load_slot(i)
		budget -= 1


## Recomputes the resident window around the player and frees what fell out of
## it. The set of pedestals in range is contiguous, so first and last are
## enough to describe it.
func _sweep() -> void:
	_reload = false
	_sweep_z = pos.z
	var here := _ground()
	var reach := load_distance()
	var low := -1
	var high := -1
	for i in slot_nodes.size():
		if here.distance_to(MeshGallery.slot_position(i)) <= reach:
			if low < 0:
				low = i
			high = i
	_low = maxi(low, 0)
	_high = high
	for i in slot_nodes.size():
		if i < _low or i > _high:
			_unload_slot(i)


## Forces the window to be rebuilt and every resident mesh loaded again — what
## switching the detail level does, since a mesh on the pedestal is the one
## level the player asked for, and the window is measured in metres of that
## level rather than in meshes.
func _reload_stream() -> void:
	for i in range(_low, maxi(_high, -1) + 1):
		_unload_slot(i)
	_reload = true


## How far the streaming window reaches with the level that stands on the
## pedestals right now. An unknown level gets the narrowest window, because a
## window that is too wide costs triangles and one that is too narrow only costs
## a mesh a moment later than it should appear.
func load_distance() -> float:
	return float(LOAD_DISTANCE.get(tier, 30.0))


func _load_slot(index: int) -> void:
	var slot: Dictionary = slot_nodes[index]
	if slot["mesh"] != null:
		return
	var key := str(slot["key"])
	# If this one mesh misses the chosen level, fall back to the finest that
	# exists — otherwise a low-poly mesh stands under the label "High".
	var use_tier := AssetRegistry.best_available(key, tier)
	var node := WorldScreen.mesh(AssetRegistry.tier_path_of(key, use_tier), AssetRegistry.color_of(key))
	if node == null:
		node = WorldScreen.mesh(key, AssetRegistry.color_of(key))
	if node == null:
		var box := MeshInstance3D.new()
		var box_mesh := BoxMesh.new()
		box_mesh.size = Vector3(0.6, 0.6, 0.6)
		box.mesh = box_mesh
		box.material_override = WorldScreen.standard_material(AssetRegistry.color_of(key))
		node = box
	_fitted(node)
	var holder: Node3D = slot["holder"]
	holder.add_child(node)
	slot["mesh"] = node


func _unload_slot(index: int) -> void:
	var slot: Dictionary = slot_nodes[index]
	var node: Node = slot["mesh"]
	if node == null:
		return
	slot["mesh"] = null
	node.queue_free()


# --- mesh fitting -----------------------------------------------------------

## Scales a mesh so every object in the gallery reads at the same size,
## whatever its original dimensions were, and floats it over the pedestal.
##
## An imported glTF is a `Node3D` with `MeshInstance3D` children, so the bounds
## have to be collected over the whole subtree, in the root's own space.
func _fitted(node: Node3D) -> void:
	var union := AABB()
	var found := false
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var current: Node = stack.pop_back()
		if current is MeshInstance3D:
			var mesh: Mesh = (current as MeshInstance3D).mesh
			if mesh != null:
				var box := _placed(mesh.get_aabb(), current.transform)
				union = box if not found else union.merge(box)
				found = true
		for child in current.get_children():
			if child is Node3D:
				stack.append(child)
	if not found:
		return
	var largest := maxf(union.size.x, maxf(union.size.y, union.size.z))
	if largest <= 0.0001:
		return
	var scale := clampf(MESH_ON_PEDESTAL / largest, 0.02, 60.0)
	node.scale = Vector3.ONE * scale
	# Centre it over the pedestal and lift it a little, so nothing intersects
	# the column no matter how the original mesh was oriented.
	node.position = Vector3(0, -union.get_center().y * scale + largest * scale * 0.16, 0)


## An `AABB` moved by a `Transform3D`; `AABB` has no such helper itself.
static func _placed(box: AABB, xform: Transform3D) -> AABB:
	var out := AABB(xform * box.position, Vector3.ZERO)
	for corner in [
		box.position,
		box.position + Vector3(box.size.x, 0, 0),
		box.position + Vector3(0, box.size.y, 0),
		box.position + Vector3(0, 0, box.size.z),
		box.end,
	]:
		out = out.expand(xform * corner)
	return out


# --- refresh ----------------------------------------------------------------

## True when at least one mesh actually ships this detail level. In the full
## build that is every level; in a build without `med/` and `high/` (the slim
## APK) it is only `low` — and a level that is not there must not be offered,
## because the gallery would then show the low-poly mesh under the heading
## "Medium".
func _tier_in_hall(tier_id: String) -> bool:
	return AssetRegistry.tiers_missing(tier_id).is_empty()


func _refresh_panel() -> void:
	# A level this build does not have at all falls back to the finest that
	# exists — otherwise the gallery shows low meshes under another label.
	if not _tier_in_hall(tier):
		for candidate in AssetRegistry.TIERS:
			if AssetRegistry.TIERS.find(candidate) > AssetRegistry.TIERS.find(tier):
				if _tier_in_hall(candidate):
					tier = candidate
					break
	if _tier_label != null:
		_tier_label.text = MeshGallery.tier_caption(tier)
	for i in _tier_buttons.size():
		var tier_id: String = AssetRegistry.TIERS[i]
		Ui.with_disabled(_tier_buttons[i], tier_id != tier)


## Where in the hall the player is. The counter is the answer to "how many of
## these do I still have to walk past" in a hall of nearly two hundred metres.
func _refresh_counter() -> void:
	if _counter_label == null:
		return
	if active_slot >= 0:
		_counter_label.text = Loc.f("Mesh %d / %d", [active_slot + 1, keys.size()])
	else:
		_counter_label.text = Loc.f("%d meshes in the hall", [keys.size()])


func _refresh_info() -> void:
	if _info_name == null:
		return
	_refresh_counter()
	var key := active_key()
	if key == "":
		_info_name.text = Loc.f("Walk along the hall", [])
		_info_name.add_theme_color_override("font_color", UiTheme.TEXT)
		_info_meta.text = MeshGallery.tier_caption(tier)
		_info_hint.text = Loc.f("The meshes stand to the left and to the right", [])
		return
	_info_name.text = Loc.resolve(AssetRegistry.display_name(key))
	_info_name.add_theme_color_override("font_color", AssetRegistry.color_of(key))
	# Label and triangle count must match the level that actually stands there,
	# or a slim build claims "1.000 triangles" over a 200-triangle mesh.
	var shown := AssetRegistry.best_available(key, tier)
	var shown_label := AssetRegistry.tier_label(shown)
	if shown != tier:
		shown_label = Loc.f("%s (instead of %s)", [shown_label, AssetRegistry.tier_label(tier)])
	_info_meta.text = Loc.f("%s   ·   %s   ·   %s triangles", [
		key, shown_label, AssetRegistry.tri_text(key, shown),
	])
	_info_hint.text = Loc.f("E — write a suggestion about this mesh", [])
