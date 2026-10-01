class_name CrystalForgeScreen
extends WorldScreen
## "Crystal Forge" — the Crystal Jumper's own scene for what it does with the
## crystals a climb hands over: the bag, the merge (three of a tier become one
## of the next) and the equipped crystal that makes the next climb faster.
##
## Reached from the "Merge" button every Crystal Jumper screen carries in its top
## bar (`GameRegistry.COMPANIONS`). Merging used to exist only on the summit
## panel, which opens once per finished tower — so a player asking where the
## merge is had nothing to find between runs.
##
## All three editions share this screen; a theme only swaps names, tints, meshes
## and the payload the router hands over.

const PHASE_IDLE := 0
const PHASE_GATHER := 1
const PHASE_BURST := 2
const PHASE_SETTLE := 3

## Forge geometry. The camera looks left of the pedestal, so the forge sits in
## the right half of the screen and the panel has the left one.
const PEDESTAL_RADIUS := 2.6
const BAG_RADIUS := 1.7
const TIER_GAP := 0.62
const SHOWN_PER_TIER := 6
const CRYSTAL_SCALE := 0.5
const MERGE_HEIGHT := 1.5
const MERGE_GATHER := 0.42
const MERGE_BURST := 0.24
const MERGE_SETTLE := 0.36
const RING_SPEED := 0.5

const PANEL_WIDTH := 620.0
const PANEL_MARGIN := 24.0

var theme: Dictionary = {}
var theme_id := CrystalTower.THEME_CLASSIC
var climb_screen := "crystal3d"

var counts: Array = []
var equipped := 0

var merge_phase := PHASE_IDLE
var merge_timer := 0.0
var merge_steps: Array = []
var merge_created: Node3D = null
var merge_created_tier := 0
var merge_point := Vector3(0.0, MERGE_HEIGHT, 0.0)

var tier_templates: Array = []
var spin_ring: MeshInstance3D
var burst_ring: MeshInstance3D
var burst_light: OmniLight3D
var bag_root: Node3D
var actors: Array[Node3D] = []

var _bag_column: VBoxContainer
var _merge_button: Button
var _points_label: Label
var _equipped_label: Label
var _empty_label: Label


func _ready_world() -> void:
	# The payload is set by the router before the screen enters the tree, so
	# `data` is readable here — and the theme decides the meshes, the tints and
	# the names, all of which are built below. `_on_data()` would arrive too late
	# for that: the base class calls it after `_ready_world()`.
	theme_id = str(data.get("theme", CrystalTower.THEME_CLASSIC))
	climb_screen = str(data.get("back", CrystalForge.climb_screen(theme_id)))
	theme = CrystalTower.theme_by_id(theme_id)
	counts = CrystalForge.load_bag(theme_id)
	equipped = CrystalForge.equipped_tier(theme_id)

	_setup_theme()
	_build_forge()
	_build_ui()
	hide_loading()
	_refresh()


func _setup_theme() -> void:
	set_fog(theme["background"], 0.014)
	set_ambient(theme["sky"], 0.7)
	sun.light_color = Color.WHITE
	sun.light_energy = 1.2
	fill.light_color = theme["sky"]
	fill.light_energy = 0.35
	camera.fov = 60.0
	camera.far = 200.0
	camera.position = Vector3(-4.0, 4.4, 9.6)
	camera.look_at(Vector3(-3.2, 1.5, 0.0), Vector3.UP)

	_build_ground()
	_load_tier_templates()


## A ground disc with two rings, so the forge has a floor to stand on without a
## second mesh asset.
func _build_ground() -> void:
	var ground := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = 14.0
	mesh.bottom_radius = 14.0
	mesh.height = 0.4
	mesh.radial_segments = 32
	ground.mesh = mesh
	ground.material_override = WorldScreen.standard_material(theme["ground"])
	ground.position.y = -0.2
	add_child(ground)

	var line_material := WorldScreen.standard_material((theme["grid"] as Array)[0])
	for radius in [6.0, 11.0]:
		var ring := MeshInstance3D.new()
		var torus := TorusMesh.new()
		torus.inner_radius = float(radius) - 0.06
		torus.outer_radius = float(radius)
		ring.mesh = torus
		ring.material_override = line_material
		ring.position.y = 0.02
		add_child(ring)


func _load_tier_templates() -> void:
	tier_templates = []
	for tier in range(1, CrystalTower.MAX_CRYSTAL_TIER + 1):
		var key := str((theme["tierAssets"] as Array)[tier - 1])
		var template := WorldScreen.mesh(key, CrystalTower.crystal_tier_color(theme, tier), 1.0, 0.35 if tier >= 3 else 0.0)
		tier_templates.append(template if template != null else _crystal_fallback(CrystalTower.crystal_tier_color(theme, tier)))


## A simple faceted gem, used when a mesh cannot be loaded.
func _crystal_fallback(color: Color) -> Node3D:
	var root := Node3D.new()
	var gem := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.42
	mesh.height = 1.3
	mesh.radial_segments = 8
	mesh.rings = 5
	gem.mesh = mesh
	gem.material_override = WorldScreen.standard_material(color, 0.6)
	root.add_child(gem)
	return root


## Pedestal, the two rings the merge plays on, the bag display and the three
## pre-built actors the merge animation reuses. Everything a merge needs exists
## before the first frame: the animation only moves nodes, it never builds one.
func _build_forge() -> void:
	var pedestal := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = PEDESTAL_RADIUS
	mesh.bottom_radius = PEDESTAL_RADIUS + 0.25
	mesh.height = 0.5
	mesh.radial_segments = 24
	pedestal.mesh = mesh
	pedestal.material_override = WorldScreen.standard_material(theme["platform"])
	pedestal.position.y = 0.25
	add_child(pedestal)

	spin_ring = MeshInstance3D.new()
	var spin_torus := TorusMesh.new()
	spin_torus.inner_radius = PEDESTAL_RADIUS - 0.14
	spin_torus.outer_radius = PEDESTAL_RADIUS
	spin_ring.mesh = spin_torus
	spin_ring.material_override = WorldScreen.standard_material(theme["accent"], 1.5)
	spin_ring.position.y = 0.56
	add_child(spin_ring)

	burst_ring = MeshInstance3D.new()
	var burst_torus := TorusMesh.new()
	burst_torus.inner_radius = 1.38
	burst_torus.outer_radius = 1.46
	burst_ring.mesh = burst_torus
	burst_ring.material_override = WorldScreen.standard_material(Color.WHITE, 2.0)
	burst_ring.position = merge_point
	burst_ring.visible = false
	add_child(burst_ring)

	burst_light = OmniLight3D.new()
	burst_light.light_color = Color.WHITE
	burst_light.light_energy = 0.0
	burst_light.omni_range = 12.0
	burst_light.position = merge_point
	add_child(burst_light)

	var glow := OmniLight3D.new()
	glow.light_color = theme["accent"]
	glow.light_energy = 9.0
	glow.omni_range = 14.0
	glow.position = Vector3(0.0, 2.6, 0.0)
	add_child(glow)

	bag_root = Node3D.new()
	add_child(bag_root)

	for i in CrystalForge.MERGE_RULE:
		var actor := _spawn_tier_node(1)
		actor.visible = false
		add_child(actor)
		actors.append(actor)


## One crystal of a tier. The merge re-parents this node instead of building a
## new one, so a cascade of a dozen steps allocates a dozen nodes and not one
## per frame.
func _spawn_tier_node(tier: int) -> Node3D:
	if tier_templates.is_empty():
		return _crystal_fallback(CrystalTower.crystal_tier_color(theme, tier))
	var template: Node3D = tier_templates[clampi(tier, 1, tier_templates.size()) - 1]
	var node := template.duplicate() as Node3D
	node.scale = Vector3.ONE * CRYSTAL_SCALE
	return node


# --- interface --------------------------------------------------------------

func _build_ui() -> void:
	var frame := Ui.panel(Color(0.031, 0.047, 0.086, 0.92), theme["accent"], 16)
	frame.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	frame.offset_left = PANEL_MARGIN
	frame.offset_right = PANEL_MARGIN + PANEL_WIDTH
	frame.offset_top = 70.0
	frame.offset_bottom = -70.0
	hud_root.add_child(frame)

	var column := Ui.vbox(8)
	frame.add_child(column)

	column.add_child(Ui.title("Crystal Forge", 32, theme["accent"]))
	column.add_child(Ui.label(str(theme["title"]), 16, UiTheme.TEXT_DIM))
	# The same sentence the summit panel explains the rule with, so the two places
	# that merge crystals say it identically.
	column.add_child(Ui.label("Merge: 3 crystals → 1 of the next tier", 15, UiTheme.TEXT_DIM))

	_bag_column = Ui.vbox(4)
	column.add_child(_bag_column)

	_empty_label = Ui.label("Inventory empty", 16, UiTheme.TEXT_MUTED)
	_bag_column.add_child(_empty_label)

	_points_label = Ui.label("", 18, UiTheme.TEXT, true)
	column.add_child(_points_label)
	_equipped_label = Ui.label("", 15, UiTheme.TEXT_DIM)
	column.add_child(_equipped_label)

	_merge_button = Ui.button(Loc.f("Merge (%d×)", [0]), Vector2(PANEL_WIDTH - 48.0, 56.0), UiTheme.ACCENT, start_merge)
	column.add_child(_merge_button)

	var actions := Ui.hbox(10)
	column.add_child(actions)
	actions.add_child(Ui.button("Climb", Vector2(200, 48), UiTheme.PANEL_LIGHT, func() -> void:
		Sfx.select()
		Router.go_to(climb_screen)
	))
	actions.add_child(Ui.button(Loc.t("ui.back_to_lobby"), Vector2(200, 48), UiTheme.PANEL_LIGHT, func() -> void:
		Sfx.select()
		Router.to_lobby()
	))


## Rebuilds every number the bag shows. Runs on an action, never per frame.
func _refresh() -> void:
	for child in _bag_column.get_children():
		if child == _empty_label:
			continue
		# `remove_child` first: `queue_free` alone would leave the old rows on
		# screen for one more frame, on top of the new ones.
		_bag_column.remove_child(child)
		child.queue_free()
	_empty_label.visible = CrystalForge.total(counts) == 0

	for tier in range(1, CrystalTower.MAX_CRYSTAL_TIER + 1):
		_bag_column.add_child(_bag_row(tier))

	_points_label.text = Loc.f("Points: %d", [CrystalForge.value(counts)])
	_equipped_label.text = Loc.f("Equipped: %s", [CrystalTower.crystal_tier_name(theme, equipped)]) if equipped > 0 else ""
	var pending: int = CrystalForge.mergeable(counts)
	_merge_button.text = Loc.f("Merge (%d×)", [pending])
	Ui.with_disabled(_merge_button, pending <= 0 or merge_phase != PHASE_IDLE)
	_sync_bag()


## One tier of the bag: its colour, its name, how many are in it and — when the
## bag holds one — the button that equips it for the next climb.
func _bag_row(tier: int) -> HBoxContainer:
	var color: Color = CrystalTower.crystal_tier_color(theme, tier)
	var row := Ui.hbox(10)
	var swatch := Ui.rect(color, 6, color.lightened(0.35), 1)
	swatch.custom_minimum_size = Vector2(24, 24)
	row.add_child(swatch)
	var caption := Ui.label(Loc.f("◆ %s ×%d", [CrystalTower.crystal_tier_name(theme, tier), CrystalForge.count_of(counts, tier)]), 18, color, true)
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(caption)
	if CrystalForge.count_of(counts, tier) > 0:
		# The equipped crystal is already spent: the button says so by being grey,
		# which is also why `equip()` takes one out of the bag.
		row.add_child(Ui.with_disabled(
			Ui.button("Equip", Vector2(120, 34), UiTheme.PANEL_LIGHT, func() -> void: _equip(tier)),
			tier == equipped,
		))
	return row


## Lays the bag out as rings of crystals above the pedestal, one ring per tier.
func _sync_bag() -> void:
	for child in bag_root.get_children():
		bag_root.remove_child(child)
		child.queue_free()
	for tier in range(1, CrystalTower.MAX_CRYSTAL_TIER + 1):
		var want: int = mini(CrystalForge.count_of(counts, tier), SHOWN_PER_TIER)
		var y: float = 1.0 + float(tier - 1) * TIER_GAP
		for i in want:
			var node := _spawn_tier_node(tier)
			bag_root.add_child(node)
			var angle := float(i) * TAU / float(SHOWN_PER_TIER)
			node.position = Vector3(cos(angle) * BAG_RADIUS, y, sin(angle) * BAG_RADIUS)
			node.rotation.y = angle


func _equip(tier: int) -> void:
	if merge_phase != PHASE_IDLE:
		return
	equipped = CrystalForge.equip(theme_id, tier)
	Sfx.coin()
	_refresh()


# --- loop -------------------------------------------------------------------

func _update_world(delta: float) -> void:
	var dt: float = minf(delta, 0.05)
	spin_ring.rotation.y += dt * RING_SPEED
	_spin_crystals(dt)
	_update_merge(dt)


## Rotates and bobs the crystals on the pedestal. Every node is pre-built, so
## this is a loop over existing nodes and not an allocation per frame.
func _spin_crystals(dt: float) -> void:
	for child in bag_root.get_children():
		if child is Node3D:
			var node := child as Node3D
			node.rotation.y += dt * 0.7
			node.position.y += sin(elapsed * 2.0 + node.position.x) * dt * 0.02


# --- merging ----------------------------------------------------------------

## Merges the whole cascade in one press: the button plans every step, then the
## animation plays them one after another and the bag is written once at the end.
## Pressing it again does nothing — a half-finished merge would write a bag that
## the plan no longer describes.
func start_merge() -> void:
	if merge_phase != PHASE_IDLE:
		return
	merge_steps = (CrystalForge.merge(counts)["steps"] as Array).duplicate()
	if merge_steps.is_empty():
		return
	_next_merge_step()


func _next_merge_step() -> void:
	if merge_steps.is_empty():
		merge_phase = PHASE_IDLE
		_clear_actors()
		CrystalForge.store_bag(theme_id, counts)
		_refresh()
		return
	var step: Dictionary = merge_steps.pop_front()
	var from_tier := int(step["from"])
	var to_tier := int(step["to"])
	counts[from_tier - 1] = maxi(0, CrystalForge.count_of(counts, from_tier) - CrystalForge.MERGE_RULE)
	counts[to_tier - 1] = CrystalForge.count_of(counts, to_tier) + 1
	merge_created_tier = to_tier
	merge_created = _spawn_tier_node(to_tier)
	merge_created.position = merge_point
	merge_created.scale = Vector3.ONE * CRYSTAL_SCALE * 0.05
	add_child(merge_created)

	for actor in actors:
		actor.visible = true
		actor.scale = Vector3.ONE * CRYSTAL_SCALE
		actor.position = merge_point + Vector3(randf_range(-1.1, 1.1), randf_range(-0.5, 0.2), randf_range(-1.1, 1.1))
	merge_phase = PHASE_GATHER
	merge_timer = 0.0
	Sfx.dash()
	_refresh()


func _update_merge(dt: float) -> void:
	if merge_phase == PHASE_IDLE:
		return
	merge_timer += dt
	if merge_phase == PHASE_GATHER:
		var t: float = minf(1.0, merge_timer / MERGE_GATHER)
		for i in actors.size():
			actors[i].position = actors[i].position.lerp(merge_point, clampf(dt * 6.0, 0.0, 1.0))
			actors[i].rotation.y += dt * 4.0
			actors[i].scale = Vector3.ONE * CRYSTAL_SCALE * (1.0 - 0.7 * t * t)
		if merge_created != null:
			merge_created.rotation.y += dt * 5.0
			merge_created.scale = Vector3.ONE * CRYSTAL_SCALE * (0.05 + 0.35 * t)
		if t >= 1.0:
			merge_phase = PHASE_BURST
			merge_timer = 0.0
			burst_ring.visible = true
			burst_ring.material_override = WorldScreen.standard_material(CrystalTower.crystal_tier_color(theme, merge_created_tier), 2.0)
			burst_light.light_color = CrystalTower.crystal_tier_color(theme, merge_created_tier)
			burst_light.light_energy = 22.0
		return
	if merge_phase == PHASE_BURST:
		var t: float = minf(1.0, merge_timer / MERGE_BURST)
		burst_ring.scale = Vector3.ONE * (0.3 + t * 2.4)
		burst_light.light_energy = 22.0 * (1.0 - t)
		if merge_created != null:
			merge_created.scale = Vector3.ONE * CRYSTAL_SCALE * (0.4 + 1.4 * (1.0 - pow(1.0 - t, 3.0)))
			merge_created.rotation.y += dt * 12.0
		if t >= 1.0:
			burst_ring.visible = false
			burst_ring.scale = Vector3.ONE
			burst_light.light_energy = 0.0
			merge_phase = PHASE_SETTLE
			merge_timer = 0.0
			_clear_actors()
			if merge_created != null:
				merge_created.queue_free()
				merge_created = null
			_refresh()
		return
	if merge_timer / MERGE_SETTLE >= 1.0:
		merge_phase = PHASE_IDLE
		Sfx.kill()
		_next_merge_step()


func _clear_actors() -> void:
	for actor in actors:
		actor.visible = false