class_name MeshGalleryScreen
extends WorldScreen
## A round room with one pedestal per mesh. The player walks around, switches
## between three detail levels, marks a mesh as "needs work" with a note, and
## everything collected goes to the dashboard as one finished suggestion.
##
## The geometry and the suggestion text live in `MeshGallery`, so they are
## testable without a screen.

const MOVE_SPEED := 7.5
const CAMERA_HEIGHT := 9.6
const CAMERA_DISTANCE := 12.5
const ROOM_RADIUS := 17.0
const SPIN_SPEED := 0.9

## How tall a mesh appears on its pedestal, whatever its real size is.
const MESH_ON_PEDESTAL := 1.75

var group_id := "helden"
var tier := "low"
var page_index := 0

## The list of meshes to improve lives in `MeshGallery` so the review screen and
## this screen always see the same one — a private copy would silently drop the
## player's work when they walk over to the review.

var pos := Vector3(0, 0, 9)
var facing := PI
var player: Node3D
var pedestals: Array[Node3D] = []
var slot_nodes: Array[Dictionary] = []
var active_pedestal := -1
var _interact_held := false

var _stick: VirtualStick
var _info_panel: Control
var _info_name: Label
var _info_meta: Label
var _info_note: Label
var _group_label: Label
var _tier_label: Label
var _page_label: Label
var _marks_label: Label
var _mark_button: Button
var _tier_buttons: Array[Button] = []
var _group_buttons: Array[Button] = []
## The ids behind `_group_buttons`, in the same order.
var _group_ids: Array[String] = []


func _ready_world() -> void:
	# The lobby portal can open the gallery straight into a collection or a
	# detail level; otherwise start with the first group that owns any mesh.
	group_id = str(data.get("group", "")) if not AssetRegistry.keys_in_group(str(data.get("group", ""))).is_empty() else _first_group()
	tier = str(data.get("tier", "low")) if str(data.get("tier", "")) in AssetRegistry.TIERS else "low"
	_build_room()
	_build_slots()
	_build_player()
	MeshGallery.set_marks(MeshGallery.shared_marks())
	_build_panels()
	_refresh()
	hide_loading()


## The first registry group that owns at least one mesh.
func _first_group() -> String:
	for group in AssetRegistry.GROUPS:
		if not AssetRegistry.keys_in_group(str(group["id"])).is_empty():
			return str(group["id"])
	return "helden"


# --- construction -----------------------------------------------------------

## The room is built from primitives on purpose: it has to look deliberate, and
## it must never depend on a bundled mesh being importable.
func _build_room() -> void:
	var floor := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(ROOM_RADIUS * 1.98, ROOM_RADIUS * 1.98)
	floor.mesh = plane
	floor.material_override = WorldScreen.standard_material(Color("111827"), 0.85)
	add_child(floor)

	var disc := MeshInstance3D.new()
	var disc_mesh := CylinderMesh.new()
	disc_mesh.top_radius = ROOM_RADIUS
	disc_mesh.bottom_radius = ROOM_RADIUS
	disc_mesh.height = 0.2
	disc.mesh = disc_mesh
	disc.material_override = WorldScreen.standard_material(Color("1b2438"), 0.7)
	disc.position.y = 0.1
	add_child(disc)

	# A low wall closes the room, so the player cannot wander into the void.
	var wall := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = ROOM_RADIUS
	torus.outer_radius = ROOM_RADIUS + 0.5
	torus.rings = 48
	torus.ring_segments = 6
	wall.mesh = torus
	wall.material_override = WorldScreen.standard_material(Color("334155"), 0.6)
	wall.position.y = 0.5
	add_child(wall)

	# A pillar of light in the middle marks where the player starts.
	var beacon := WorldScreen.mesh("rpg/crystal_cluster", Color("38bdf8"), 1.6, 0.8)
	if beacon != null:
		beacon.position = Vector3(0, 0.6, 0)
		add_child(beacon)
		var light := OmniLight3D.new()
		light.light_color = Color("38bdf8")
		light.light_energy = 12.0
		light.omni_range = 14.0
		light.position = Vector3(0, 2.4, 0)
		add_child(light)


## One pedestal per slot of the current page, holding the mesh of that tier.
func _build_slots() -> void:
	for i in MeshGallery.ARC_SIZE:
		var root := Node3D.new()
		root.position = MeshGallery.pedestal_position(i)
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
		sign.text = ""
		holder.add_child(sign)

		pedestals.append(root)
		slot_nodes.append({"root": root, "holder": holder, "sign": sign, "ring": ring, "key": ""})


func _build_player() -> void:
	player = Node3D.new()
	var knight := WorldScreen.mesh("rpg/knight", Color("cbd5e1"), 1.0)
	if knight != null:
		player.add_child(knight)
	player.position = pos
	add_child(player)


# --- HUD --------------------------------------------------------------------

func _build_panels() -> void:
	_stick = add_stick("bottom_left")
	add_action_button("E", 70.0, "interact")

	var left := VBoxContainer.new()
	left.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	left.position = Vector2(16, HUD_HEIGHT + 10)
	left.custom_minimum_size = Vector2(372, 0)
	left.add_theme_constant_override("separation", 4)
	hud_root.add_child(left)

	left.add_child(Ui.label("◈  MESH GALLERY", 24, UiTheme.ACCENT, true))
	_tier_label = Ui.label("", 14, UiTheme.TEXT_DIM)
	_tier_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tier_label.custom_minimum_size = Vector2(360, 0)
	left.add_child(_tier_label)

	var tier_row := Ui.hbox(6)
	left.add_child(tier_row)
	for name in AssetRegistry.TIERS:
		var tier_id: String = name
		var button := Ui.button(AssetRegistry.tier_label(tier_id), Vector2(112, 40), UiTheme.PANEL_LIGHT, func() -> void:
			_set_tier(tier_id)
		)
		tier_row.add_child(button)
		_tier_buttons.append(button)

	var group_row := HFlowContainer.new()
	group_row.custom_minimum_size = Vector2(348, 0)
	group_row.add_theme_constant_override("h_separation", 4)
	group_row.add_theme_constant_override("v_separation", 4)
	left.add_child(group_row)
	for group in AssetRegistry.GROUPS:
		var group_id_value: String = str(group["id"])
		# An empty collection would be a dead end, so it gets no button.
		if AssetRegistry.keys_in_group(group_id_value).is_empty():
			continue
		var button := Ui.button(Loc.f("%s %s", [str(group["icon"]), str(group["name"])]), Vector2(112, 28), UiTheme.PANEL_LIGHT, func() -> void:
			_set_group(group_id_value)
		)
		button.add_theme_font_size_override("font_size", 12)
		group_row.add_child(button)
		_group_buttons.append(button)
		_group_ids.append(group_id_value)
	_group_label = Ui.label("", 14, UiTheme.TEXT_DIM)
	left.add_child(_group_label)

	var page_row := Ui.hbox(6)
	left.add_child(page_row)
	page_row.add_child(Ui.button("◀", Vector2(48, 38), UiTheme.PANEL_LIGHT, func() -> void: _turn_page(-1)))
	_page_label = Ui.label("", 15, UiTheme.TEXT, true)
	_page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_page_label.custom_minimum_size = Vector2(180, 38)
	_page_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	page_row.add_child(_page_label)
	page_row.add_child(Ui.button("▶", Vector2(48, 38), UiTheme.PANEL_LIGHT, func() -> void: _turn_page(1)))

	_marks_label = Ui.label("", 15, Color("facc15"), true)
	left.add_child(_marks_label)

	# The card that describes whatever the player is standing in front of.
	_info_panel = Ui.panel(Color(0.043, 0.063, 0.110, 0.9))
	_info_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_info_panel.offset_left = 16
	_info_panel.offset_right = -16
	_info_panel.offset_top = -206
	_info_panel.offset_bottom = -16
	hud_root.add_child(_info_panel)

	var info_column := Ui.vbox(6)
	info_column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	info_column.offset_left = 16
	info_column.offset_right = -16
	info_column.offset_top = 12
	info_column.offset_bottom = -12
	_info_panel.add_child(info_column)

	_info_name = Ui.label("", 24, UiTheme.TEXT, true)
	info_column.add_child(_info_name)
	_info_meta = Ui.label("", 14, UiTheme.TEXT_DIM)
	info_column.add_child(_info_meta)

	var note_row := Ui.hbox(8)
	info_column.add_child(note_row)
	_info_note = Ui.label("", 15, Color("cbd5e1"))
	_info_note.custom_minimum_size = Vector2(0, 34)
	_info_note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_info_note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	note_row.add_child(_info_note)
	_mark_button = Ui.button("Shortlist", Vector2(190, 34), UiTheme.ACCENT, _toggle_mark)
	note_row.add_child(_mark_button)

	var actions := Ui.hbox(8)
	actions.alignment = BoxContainer.ALIGNMENT_END
	info_column.add_child(actions)
	actions.add_child(Ui.button("Write a note", Vector2(220, 40), UiTheme.PANEL_LIGHT, func() -> void:
		Sfx.select()
		Router.go_to("mesh_review")
	))
	actions.add_child(Ui.button("Submit a suggestion", Vector2(260, 40), UiTheme.ACCENT, func() -> void:
		Sfx.select()
		Router.go_to("mesh_review")
	))


# --- state ------------------------------------------------------------------

func visible_keys() -> Array[String]:
	return MeshGallery.page(AssetRegistry.keys_in_group(group_id), page_index)


func page_count() -> int:
	return MeshGallery.pages_for(AssetRegistry.keys_in_group(group_id).size())


func _set_tier(next_tier: String) -> void:
	if not (next_tier in AssetRegistry.TIERS) or next_tier == tier:
		return
	tier = next_tier
	Sfx.select()
	_refresh()


func _set_group(next_group: String) -> void:
	if next_group == group_id:
		return
	group_id = next_group
	page_index = 0
	Sfx.select()
	_refresh()


func _turn_page(step: int) -> void:
	var count := page_count()
	if count <= 1:
		return
	page_index = posmod(page_index + step, count)
	Sfx.select()
	_refresh()


## The list of meshes the player has marked, always the shared one.
func _marks() -> Dictionary:
	return MeshGallery.shared_marks()


func _toggle_mark() -> void:
	var key := MeshGallery.key_at(visible_keys(), active_pedestal)
	if key == "":
		return
	var result := MeshGallery.toggle(_marks(), key)
	MeshGallery.set_marks(result["marks"])
	if bool(result["marked"]):
		MeshGallery.set_marks(MeshGallery.set_tier(_marks(), key, tier))
		Sfx.level_up()
		notify(Loc.f("%s shortlisted", [AssetRegistry.display_name(key)]), 1.4)
	else:
		Sfx.select()
		notify(Loc.f("%s removed again", [AssetRegistry.display_name(key)]), 1.2)
	_refresh()


# --- world ------------------------------------------------------------------

func _update_world(delta: float) -> void:
	var vector := VirtualStick.combined(_stick.value, &"move_left", &"move_right")
	if vector.length() > 0.05:
		pos.x += vector.x * MOVE_SPEED * delta
		pos.z += vector.y * MOVE_SPEED * delta
		facing = atan2(-vector.x, -vector.y)
		# The room is a disc, not a plane.
		var radius := Vector2(pos.x, pos.z).length()
		if radius > ROOM_RADIUS - 1.0:
			pos.x *= (ROOM_RADIUS - 1.0) / radius
			pos.z *= (ROOM_RADIUS - 1.0) / radius

	player.position = Vector3(pos.x, sin(elapsed * 3.0) * 0.04, pos.z)
	player.rotation.y = facing
	follow_camera(player.position, CAMERA_HEIGHT, CAMERA_DISTANCE, 7.0, delta)

	active_pedestal = MeshGallery.nearest_pedestal(visible_keys(), pos)
	var pressed := Input.is_action_pressed("interact")
	if pressed and not _interact_held and active_pedestal >= 0:
		_toggle_mark()
	_interact_held = pressed

	_animate_slots(delta)
	_refresh_info()


## Spins every mesh on its pedestal and makes the nearest one glow.
func _animate_slots(delta: float) -> void:
	for i in slot_nodes.size():
		var slot: Dictionary = slot_nodes[i]
		var holder: Node3D = slot["holder"]
		if str(slot["key"]) == "":
			continue
		holder.rotation.y += delta * SPIN_SPEED
		# The pedestal the player stands at lifts, so the eye finds it instantly.
		var bob := sin(elapsed * 2.0 + float(i)) * 0.09
		var wanted := MeshGallery.PEDESTAL_HEIGHT + bob + (0.6 if i == active_pedestal else 0.0)
		holder.position.y = lerpf(holder.position.y, wanted, 0.14)
		var ring: MeshInstance3D = slot["ring"]
		var ring_material := ring.material_override as StandardMaterial3D
		if ring_material == null:
			continue
		var ring_color := Color("facc15") if i == active_pedestal else Color("64748b")
		if MeshGallery.is_marked(_marks(), str(slot["key"])):
			ring_color = Color("34d399")
		ring_material.albedo_color = ring_material.albedo_color.lerp(ring_color, 0.12)


# --- refresh ----------------------------------------------------------------

func _refresh() -> void:
	_rebuild_meshes()
	_refresh_panel()


func _rebuild_meshes() -> void:
	var keys := visible_keys()
	for i in slot_nodes.size():
		var slot: Dictionary = slot_nodes[i]
		var key := MeshGallery.key_at(keys, i)
		slot["key"] = key
		var holder: Node3D = slot["holder"]
		var sign: Label3D = slot["sign"]
		for child in holder.get_children():
			if child is MeshInstance3D:
				child.queue_free()
		if key == "":
			sign.text = ""
			continue
		sign.text = AssetRegistry.display_name(key)
		sign.modulate = AssetRegistry.color_of(key)
		# If this one mesh misses the chosen level, fall back to the finest that
		# exists — otherwise a low-poly mesh stands under the label "Hoch".
		var use_tier := AssetRegistry.best_available(key, tier)
		var node := WorldScreen.mesh(AssetRegistry.tier_path_of(key, use_tier), AssetRegistry.color_of(key))
		if node == null:
			node = WorldScreen.mesh(key, AssetRegistry.color_of(key))
		if node != null:
			_fitted(node)
			holder.add_child(node)
		else:
			var box := MeshInstance3D.new()
			var box_mesh := BoxMesh.new()
			box_mesh.size = Vector3(0.6, 0.6, 0.6)
			box.mesh = box_mesh
			box.material_override = WorldScreen.standard_material(AssetRegistry.color_of(key))
			holder.add_child(box)


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


## True when at least one mesh of the current collection actually ships this
## detail level. In the full build that is every level; in a build without
## `med/` and `high/` (the slim APK) it is only `low` — and a level that is not
## there must not be offered, because the gallery would then show the low-poly
## mesh under the heading „Mittel“.
func _tier_in_collection(tier_id: String) -> bool:
	for key in visible_keys():
		if AssetRegistry.tier_exists(key, tier_id):
			return true
	return false


func _refresh_panel() -> void:
	var keys := visible_keys()
	# A level this build does not have at all falls back to the finest that
	# exists — otherwise the gallery shows low meshes under another label.
	if not _tier_in_collection(tier):
		for candidate in AssetRegistry.TIERS:
			if AssetRegistry.TIERS.find(candidate) > AssetRegistry.TIERS.find(tier):
				if _tier_in_collection(candidate):
					tier = candidate
					break
	if _page_label != null:
		_page_label.text = "Seite %d / %d" % [page_index + 1, maxi(1, page_count())]
	if _tier_label != null:
		_tier_label.text = MeshGallery.tier_caption(tier)
	if _group_label != null:
		_group_label.text = "%d Meshes in dieser Sammlung" % AssetRegistry.keys_in_group(group_id).size()
	if _marks_label != null:
		var count := MeshGallery.mark_count(_marks())
		_marks_label.text = "Vorgemerkt: %d" % count
	for i in _tier_buttons.size():
		var tier_id: String = AssetRegistry.TIERS[i]
		var enabled := tier_id == tier
		Ui.with_disabled(_tier_buttons[i], not enabled)
	for i in _group_buttons.size():
		if i < _group_ids.size():
			Ui.with_disabled(_group_buttons[i], _group_ids[i] != group_id)


func _refresh_info() -> void:
	if _info_name == null:
		return
	var keys := visible_keys()
	var key := MeshGallery.key_at(keys, active_pedestal)
	if key == "":
		_info_name.text = "Laufe zu einem Sockel, um ein Mesh zu betrachten"
		_info_meta.text = "Die Sammlung zeigt %d Meshes · Detailstufe %s" % [
			AssetRegistry.keys_in_group(group_id).size(), str(AssetRegistry.TIER_LABELS[tier]),
		]
		_info_note.text = ""
		_mark_button.disabled = true
		return
	_mark_button.disabled = false
	_info_name.text = "%s  %s" % [AssetRegistry.group_of(key).substr(0, 1).to_upper(), AssetRegistry.display_name(key)]
	# Label and triangle count must match the level that actually stands there,
	# or a slim build claims "1.000 Dreiecke" over a 200-triangle mesh.
	var shown := AssetRegistry.best_available(key, tier)
	var shown_label := str(AssetRegistry.TIER_LABELS[shown])
	if shown != tier:
		shown_label += " (statt %s)" % str(AssetRegistry.TIER_LABELS[tier])
	_info_meta.text = "%s   ·   %s   ·   %s Dreiecke   ·   %s" % [
		key, shown_label, AssetRegistry.tri_text(key, shown),
		"Vorgemerkt" if MeshGallery.is_marked(_marks(), key) else "nicht vorgemerkt",
	]
	var note := MeshGallery.mark_note(_marks(), key)
	_info_note.text = ("Notiz: %s" % note) if note != "" else "Keine Notiz — mit „Vormerken“ auf die Liste"
	_mark_button.text = "Vormerken ✓" if MeshGallery.is_marked(_marks(), key) else "Vormerken"
