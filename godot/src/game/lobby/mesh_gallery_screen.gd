class_name MeshGalleryScreen
extends WorldScreen
## One long hall. Rows of pedestals on either side, every mesh of the registry in
## walking order — walk down the nave and they pass on either side, step into an
## aisle and the ones behind it do. Three detail levels can be switched, and in
## front of a mesh the player presses E for the ordinary suggestion dialog, with
## that mesh named.
##
## The geometry lives in `MeshGallery`, so it is testable without a screen.

## Metres per second. A player asked for twice the old pace, and 15 m/s is about
## what a full-height hall lets through: the camera has to keep up (see
## `CAMERA_LERP`) and a depth of pedestals goes by in 0.7 s, which is still four
## times as long as a press of the interact button needs.
const MOVE_SPEED := 15.0
## The camera chases the player with a first-order lag, so its steady-state
## distance behind the target is `speed / lerp_speed`. At the old 7.5 m/s and 7.0
## that was a metre; doubled without this it would have been two, and the knight
## would have visibly skated away from the camera.
const CAMERA_LERP := 12.0
## Height and distance behind the player. Measured against the frustum of the
## gallery camera (58° vertical, so 42°/48° horizontal on a 16:10 tablet and a
## 20:9 phone): at the old 9/11 only 12.6 m of floor was visible either side of
## the player, and the outermost of ten rows stands 19.6 m out. 15/16 puts the
## player at the centre of a hall they can see across.
const CAMERA_HEIGHT := 15.0
const CAMERA_DISTANCE := 16.0
const SPIN_SPEED := 0.9
## Fallback rate for the info caption when nothing flagged a change. The change
## flag is what normally drives it; this bounds the staleness if a flag is missed.
const INFO_INTERVAL := 0.1

## How tall a mesh appears on its pedestal, whatever its real size is. Ninety per
## cent more than the 1.75 m it stood at before, which a player asked for; the
## rows keep their 4.2 m spacing, so neighbours leave 0.9 m between them.
const MESH_ON_PEDESTAL := 3.3

# --- the hall ---------------------------------------------------------------

## How tall the walls stand. How far to the side they do is not a number here
## any more: it follows the outermost row, so widening the hall cannot leave the
## wall standing in the aisle.
const WALL_HEIGHT := 5.4

## How far away a mesh may be before it goes into the scene — and how far it may
## have walked on before it leaves it again. Ten pedestals share a depth now, and
## the depths are 2.2 times further apart, so the window holds about as many
## meshes as it did with four to a depth: measured over the whole hall, 84 → 90
## resident meshes on "low" and 52 → 50 on "high", which carries fifty times the
## triangles each.
const LOAD_DISTANCE := {"low": 48.0, "med": 40.0, "high": 30.0}
## Meshes taken into the scene per frame. One every 0.6 s of walking, so the
## hitch stays a few milliseconds instead of a visible pause.
const LOADS_PER_FRAME := 2
## The window is rebuilt after the player has walked this far, not every frame.
const SWEEP_STEP := 1.0

## The far end of the hall has to disappear into something, and the fog does
## the culling the eye expects.
const VIEW_FAR := 190.0
const FOG_COLOR := "060a14"
const FOG_DENSITY := 0.02

var tier := "low"

## Every key of the registry, in walking order. The ten rows take them in turn.
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

## The two colours of the pedestal ring, read once. `Color("facc15")` parses a
## string every time it is constructed, and the animation asks for it for every
## resident mesh in every frame — ninety times over, for a caption the player
## reads once.
var _ring_idle := Color("64748b")
var _ring_active := Color("facc15")


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
	var half_width := MeshGallery.hall_half_width()

	camera.far = VIEW_FAR
	set_fog(Color(FOG_COLOR), FOG_DENSITY)

	var floor := MeshInstance3D.new()
	var plane := BoxMesh.new()
	plane.size = Vector3(half_width * 2.0, 0.2, length)
	floor.mesh = plane
	floor.material_override = WorldScreen.standard_material(Color("111827"), 0.85)
	floor.position = Vector3(0, -0.1, middle)
	add_child(floor)

	# There is no stripe down the middle any more. A player wrote "remove the
	# path in the middle", and the stripe was what made it one: it ran the length
	# of a 165 m hall and read as a road through it, while what tells the player
	# how far they have come is the pedestals themselves. Ten rows to a depth
	# frame the nave on both sides without a mark on the floor.
	for side: float in [-1.0, 1.0]:
		var wall := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.4, WALL_HEIGHT, length)
		wall.mesh = box
		wall.material_override = WorldScreen.standard_material(Color("1f2937"), 0.7)
		wall.position = Vector3(side * half_width, WALL_HEIGHT * 0.5, middle)
		add_child(wall)


## One pedestal per mesh, one per row and side to a depth.
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

		# A label standing on the pedestal, always facing the player. It has to
		# clear the mesh above it, so its height follows `MESH_ON_PEDESTAL`
		# rather than sitting at a fixed 1.9 m — with a mesh ninety per cent
		# taller the sign would have been inside the knight's shield.
		var sign := Label3D.new()
		sign.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		sign.font_size = 44
		sign.outline_size = 14
		sign.outline_modulate = Color("020617")
		sign.position = Vector3(0, MESH_ON_PEDESTAL * 1.18, 0)
		# A `Label3D` resolves nothing on its own, so the display name has to be
		# translated where it is assigned.
		sign.text = Loc.resolve(AssetRegistry.display_name(str(keys[i])))
		# `label_color()` and not `color_of()`: the sign is written on the dark
		# hall, and a coal node's own colour sits at 1.4:1 against the wall. The
		# name is what adapts, not the mesh.
		sign.modulate = AssetRegistry.label_color(str(keys[i]))
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
		# The hall is a nave with an aisle in front of every row: the middle
		# lane, then one aisle per row behind it. z is clamped first, because
		# whether the player may stand beside a pedestal at all depends on how
		# far along they got — and which side they came from decides which way a
		# blocked one pushes them out.
		pos.z = clampf(pos.z + vector.y * MOVE_SPEED * delta, walk.x, walk.y)
		pos.x = MeshGallery.lane_x(pos.x + vector.x * MOVE_SPEED * delta, pos.z, pos.x)

	player.position = Vector3(pos.x, sin(elapsed * 3.0) * 0.04, pos.z)
	player.rotation.y = facing
	follow_camera(player.position, CAMERA_HEIGHT, CAMERA_DISTANCE, CAMERA_LERP, delta)

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
		var ring_color := _ring_active if i == active_slot else _ring_idle
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
	# Loaded **untinted**, and that is the whole fix for "they seem to have
	# random colours".
	#
	# The standard colours of a mesh are the ones it was drawn with, and they
	# are in the `.glb`: the knight is steel with a gold trim, a red shield and
	# tan gloves, the metro car is white with a cyan light stripe, the dragon
	# lord is violet with an orange belly. This used to hand `color_of()` to
	# `WorldScreen.mesh()`, which sets `material_override` on *every* surface in
	# the subtree — so all of that was flattened into one hue, and that hue came
	# from a hash of the key's spelling. Steel, red and gold became a single
	# arbitrary colour, twice as many pedestals as before stood in it, and the
	# hall read as a paint mixer.
	#
	# So the mesh keeps its own materials here. The standard palette in
	# `AssetRegistry` is still the answer wherever one colour really is called
	# for: the sign on the pedestal, the info card, and the primitive below
	# that stands in for a mesh nobody bundled.
	var node := WorldScreen.mesh(AssetRegistry.tier_path_of(key, use_tier))
	if node == null:
		node = WorldScreen.mesh(key)
	if node == null:
		var box := MeshInstance3D.new()
		var box_mesh := BoxMesh.new()
		box_mesh.size = Vector3(0.6, 0.6, 0.6)
		box.mesh = box_mesh
		# A primitive has no materials of its own, so here the standard colour
		# *is* the mesh — and it is a chosen one rather than a hashed one.
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
## these do I still have to walk past" in a hall of a hundred and sixty metres.
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
	# The card sits on the same dark panel as the pedestal sign, so it reads in
	# the same readable variant of the key's standard colour.
	_info_name.add_theme_color_override("font_color", AssetRegistry.label_color(key))
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
