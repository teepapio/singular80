class_name Lobby3DScreen
extends WorldScreen
## Walkable 3D lobby — a circular plaza with one area per game category around a
## central campfire. Port of `scenes/Lobby3DScene.ts` plus `lobby.ts`.
##
## The knight is walked with the virtual stick (or WASD/arrows/gamepad), each
## category plaza holds one pedestal per game, and standing next to a pedestal
## plus pressing the interact button (or tapping its card) starts the game.

const MOVE_SPEED := 15.0
const RUN_MULT := 1.7
const CAMERA_HEIGHT := 11.5
const CAMERA_DISTANCE := 12.5
const HUB_RADIUS := 7.0
const MAP_SIZE := 190.0
const MAP_PADDING := 8.0
const MAP_INTERVAL := 1.0 / 15.0

const ZONE_PROPS := {
	"action": ["rpg/torch", "rpg/skull", "rpg/bone_pile"],
	"adventure": ["rpg/pine_tree", "rpg/campfire", "rpg/portal_gate"],
	"board": ["rpg/stone_pillar", "rpg/rune_stone", "rpg/gravestone"],
	"cards": ["rpg/barrel", "rpg/crate", "rpg/chest"],
	"puzzle": ["rpg/crystal_cluster", "rpg/stalagmite", "rpg/rock_large"],
}

const SCENERY := [
	{"key": "rpg/pine_tree", "count": 10, "minR": 36.0, "maxR": 45.0, "minS": 1.0, "maxS": 1.8},
	{"key": "rpg/dead_tree", "count": 6, "minR": 36.0, "maxR": 45.0, "minS": 1.0, "maxS": 1.7},
	{"key": "rpg/broken_pillar", "count": 5, "minR": 36.0, "maxR": 45.0, "minS": 1.0, "maxS": 1.6},
	{"key": "rpg/rock_small", "count": 10, "minR": 9.0, "maxR": 13.0, "minS": 0.8, "maxS": 1.4},
	{"key": "rpg/rock_large", "count": 4, "minR": 9.0, "maxR": 13.0, "minS": 1.0, "maxS": 1.5},
	{"key": "rpg/bush", "count": 8, "minR": 9.0, "maxR": 13.0, "minS": 0.8, "maxS": 1.4},
	{"key": "rpg/grass_tuft", "count": 10, "minR": 9.0, "maxR": 13.0, "minS": 0.9, "maxS": 1.6},
	{"key": "rpg/mushroom", "count": 6, "minR": 9.0, "maxR": 13.0, "minS": 0.9, "maxS": 1.5},
]

var pos := Vector3(0, 0, 7)
var facing := PI
var player: Node3D
var fire_light: OmniLight3D
var hub_ring: MeshInstance3D
var zones: Array[Dictionary] = []
var pedestals: Array[Dictionary] = []
var active_zone: Dictionary = {}
var active_pedestal: Dictionary = {}
var transitioning := false
var gallery_portal: Node3D
var gallery_label: Label3D
var gallery_ring: MeshInstance3D
var _gallery_near := false

var _stick: VirtualStick
var _map: Minimap
var _panel: Control
var _panel_icon: Label
var _panel_name: Label
var _panel_tag: Label
var _panel_games: VBoxContainer
var _toast: Label
var _panel_buttons: Array[Button] = []
var _panel_games_list: Array[Dictionary] = []
var _minimap_timer := 0.0
var _interact_held := false


func _ready_world() -> void:
	set_fog(Color("05070d"), 0.0)
	environment_node.environment.fog_enabled = false
	sun.light_energy = 1.15
	sun.light_color = Color("ffe8c0")
	fill.light_energy = 0.45
	camera.fov = 58.0
	camera.far = 320.0

	# `zones` before the ground: the stone floors are laid on the plazas, so the
	# ground builder needs the layout it is paving.
	zones = Lobby.zone_layout()
	_build_ground()
	_build_hub()
	_build_zones()
	_build_scenery()
	_build_gallery_portal()
	_build_player()
	_build_hud_panels()
	camera.position = Vector3(pos.x, CAMERA_HEIGHT, pos.z + CAMERA_DISTANCE)
	camera.look_at(Vector3(pos.x, 2.2, pos.z), Vector3.UP)
	hide_loading()
	_refresh_panel({})


# --- world ------------------------------------------------------------------

func _build_ground() -> void:
	# Named so that a test can find the three surfaces by name and measure them:
	# the lawn, the paths and the flagstones are the only flat vertex-coloured
	# meshes in the screen, and they are the only ones whose winding matters.
	_ground_child(_lawn(), &"lawn")
	_ground_child(_dirt(), &"dirt")
	_ground_child(_stone_floors(), &"stone_floors")


func _ground_child(node: MeshInstance3D, node_name: StringName) -> void:
	if node == null:
		return
	node.name = node_name
	add_child(node)


## The grass: one vertex-coloured polar mesh, built once and never touched
## again.
##
## It used to be a flat dark disc under a glowing blue grid, which said "test
## level" rather than "outdoors". The lawn replaces both, and the mottling is
## per vertex rather than per patch so that forty units of ground read as grass
## instead of as one colour of paint.
func _lawn() -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for ring in Lobby.LAWN_RINGS:
		var inner := Lobby.lawn_ring_radius(ring)
		var outer := Lobby.lawn_ring_radius(ring + 1)
		for sector in Lobby.LAWN_SECTORS:
			var a0 := TAU * float(sector) / float(Lobby.LAWN_SECTORS)
			var a1 := TAU * float(sector + 1) / float(Lobby.LAWN_SECTORS)
			_lawn_quad(st, inner, outer, a0, a1, ring, sector)
	return _ground_node(st)


## One cell of the lawn. The tone is picked from the grid cell rather than from
## the quad, so a vertex shared with a neighbour is drawn the same colour in
## both and the lawn never shows its own tessellation.
func _lawn_quad(st: SurfaceTool, inner: float, outer: float, a0: float, a1: float, ring: int, sector: int) -> void:
	_lawn_vertex(st, inner, a0, ring, sector)
	_lawn_vertex(st, outer, a0, ring + 1, sector)
	_lawn_vertex(st, outer, a1, ring + 1, sector + 1)
	_lawn_vertex(st, inner, a0, ring, sector)
	_lawn_vertex(st, outer, a1, ring + 1, sector + 1)
	_lawn_vertex(st, inner, a1, ring, sector + 1)


func _lawn_vertex(st: SurfaceTool, radius: float, angle: float, ring: int, sector: int) -> void:
	_ground_vertex(st, _polar(radius, angle, 0.0), Lobby.grass_tone(ring, sector))


## The dirt: a ring the plazas stand on, one spur per plaza and one to the mesh
## gallery, and the disc the spurs meet in.
##
## Three overlapping surfaces, one mesh, one draw call. They overlap on purpose,
## so each is laid a hundredth of a unit above the one beneath it rather than
## fighting it for the same depth.
func _dirt() -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half := Lobby.PATH_WIDTH * 0.5
	var outer := Lobby.CATEGORY_RING_RADIUS + half
	var inner := Lobby.CATEGORY_RING_RADIUS - half
	for sector in Lobby.LAWN_SECTORS:
		var a0 := TAU * float(sector) / float(Lobby.LAWN_SECTORS)
		var a1 := TAU * float(sector + 1) / float(Lobby.LAWN_SECTORS)
		# The tone is picked from the sector, so neighbouring segments agree along
		# the seam they share and the ring does not show 72 stripes.
		_ground_quad(st,
			_polar(inner, a0, Lobby.PATH_Y), _polar(outer, a0, Lobby.PATH_Y),
			_polar(outer, a1, Lobby.PATH_Y), _polar(inner, a1, Lobby.PATH_Y),
			Lobby.dirt_tone(sector, 0))

	for target in Lobby.path_targets():
		# Spurs are rectangles, so their side is the target's direction turned a
		# quarter turn — and they start inside the crossing disc, which swallows
		# their inner ends instead of leaving a wedge of grass at the junction.
		var from := target.normalized() * Lobby.PATH_CROSSING_RADIUS
		var side := Vector2(-target.y, target.x).normalized() * half
		# Wound from-side → target-side → target+side → from+side: the reverse of
		# the intuitive order, because a spur's left edge runs *outward* while the
		# ring's runs clockwise. The normal is what tells the two apart.
		_ground_quad(st,
			_from_xz(from - side, Lobby.SPOKE_Y), _from_xz(target - side, Lobby.SPOKE_Y),
			_from_xz(target + side, Lobby.SPOKE_Y), _from_xz(from + side, Lobby.SPOKE_Y),
			Lobby.dirt_tone(int(target.x), int(target.y)))

	for sector in Lobby.LAWN_SECTORS:
		var a0 := TAU * float(sector) / float(Lobby.LAWN_SECTORS)
		var a1 := TAU * float(sector + 1) / float(Lobby.LAWN_SECTORS)
		_ground_tri(st,
			_from_xz(Vector2.ZERO, Lobby.CROSSING_Y),
			_polar(Lobby.PATH_CROSSING_RADIUS, a0, Lobby.CROSSING_Y),
			_polar(Lobby.PATH_CROSSING_RADIUS, a1, Lobby.CROSSING_Y),
			Lobby.dirt_tone(sector, 1))
	return _ground_node(st)


## The flagstone floor of every plaza, as one mesh laid over the platforms.
##
## The stones are inset from one another so the joint shows between them, which
## is why they are separate quads on a darker platform rather than a texture on
## its top face — the project ships no textures to map one with.
func _stone_floors() -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var radius := Lobby.ZONE_RADIUS * 0.94
	for zone in zones:
		var cx: float = zone["x"]
		var cz: float = zone["z"]
		for cell in Lobby.flagstone_cells(radius):
			var x0 := cx + float(cell["x0"])
			var z0 := cz + float(cell["z0"])
			var x1 := cx + float(cell["x1"])
			var z1 := cz + float(cell["z1"])
			_ground_quad(st,
				Vector3(x0, Lobby.FLAGSTONE_Y, z0), Vector3(x1, Lobby.FLAGSTONE_Y, z0),
				Vector3(x1, Lobby.FLAGSTONE_Y, z1), Vector3(x0, Lobby.FLAGSTONE_Y, z1),
				Lobby.STONE_TONES[int(cell["tone"])])
	return _ground_node(st)


## Commits `st` into a mesh node carrying the shared ground material, or `null`
## when the surface came out empty — a registry without categories must not
## leave a screen that throws while it builds its own floor.
func _ground_node(st: SurfaceTool) -> MeshInstance3D:
	st.generate_normals()
	var mesh := st.commit()
	if mesh == null:
		return null
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = _ground_material()
	return node


## One material for every ground surface: lawn, dirt and stone.
##
## `vertex_color_use_as_albedo` is what lets a single mesh carry three surfaces,
## and `CULL_DISABLED` means a floor seen from above is never lost to a winding
## mistake — the price is a second pass over a flat, back-facing layer, which on
## three static meshes is cheaper than the bug it rules out.
func _ground_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.95
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


func _ground_vertex(st: SurfaceTool, at: Vector3, color: Color) -> void:
	st.set_color(color)
	st.add_vertex(at)


## A horizontal quad wound so that its normal points up: the corners are given
## clockwise seen from above, which is the winding Godot treats as front-facing.
func _ground_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, color: Color) -> void:
	_ground_vertex(st, a, color)
	_ground_vertex(st, b, color)
	_ground_vertex(st, c, color)
	_ground_vertex(st, a, color)
	_ground_vertex(st, c, color)
	_ground_vertex(st, d, color)


func _ground_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, color: Color) -> void:
	_ground_vertex(st, a, color)
	_ground_vertex(st, b, color)
	_ground_vertex(st, c, color)


func _polar(radius: float, angle: float, height: float) -> Vector3:
	return Vector3(cos(angle) * radius, height, sin(angle) * radius)


func _from_xz(at: Vector2, height: float) -> Vector3:
	return Vector3(at.x, height, at.y)


func _build_hub() -> void:
	var hub := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = HUB_RADIUS
	mesh.bottom_radius = HUB_RADIUS
	mesh.height = 0.5
	mesh.radial_segments = 48
	hub.mesh = mesh
	hub.material_override = WorldScreen.standard_material(Color("243349"))
	hub.position.y = 0.25
	add_child(hub)

	hub_ring = MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = HUB_RADIUS - 0.34
	torus.outer_radius = HUB_RADIUS - 0.06
	hub_ring.mesh = torus
	hub_ring.material_override = WorldScreen.standard_material(Color("38bdf8"), 1.4)
	hub_ring.position.y = 0.52
	add_child(hub_ring)

	var campfire := mesh_or_null("rpg/campfire", Color("ff9a4d"), 1.5)
	if campfire != null:
		campfire.position = Vector3(0, 0.5, 0)
		add_child(campfire)

	fire_light = OmniLight3D.new()
	fire_light.light_color = Color("ffa15c")
	fire_light.light_energy = 26.0
	fire_light.omni_range = 34.0
	fire_light.position = Vector3(0, 3, 0)
	add_child(fire_light)

	for i in 4:
		var angle := (float(i) / 4.0) * TAU + PI * 0.25
		var torch := mesh_or_null("rpg/torch", Color.WHITE, 1.0)
		if torch == null:
			continue
		torch.position = Vector3(cos(angle) * (HUB_RADIUS - 1.2), 0.5, sin(angle) * (HUB_RADIUS - 1.2))
		torch.rotation.y = angle + PI
		add_child(torch)

	var signpost := mesh_or_null("rpg/rune_stone", Color("38bdf8"), 1.6)
	if signpost != null:
		signpost.position = Vector3(0, 0, -3.2)
		add_child(signpost)


func _build_zones() -> void:
	for zone in zones:
		var category: Dictionary = zone["category"]
		var accent: Color = category["accent"]
		var cx: float = zone["x"]
		var cz: float = zone["z"]

		# The platform is the joint colour and the flagstones are laid on it, so a
		# plaza reads as paving rather than as a raised disc of the floor's colour.
		var platform := MeshInstance3D.new()
		var mesh := CylinderMesh.new()
		mesh.top_radius = Lobby.ZONE_RADIUS * 0.94
		mesh.bottom_radius = Lobby.ZONE_RADIUS
		mesh.height = Lobby.ZONE_PLATFORM_HEIGHT
		mesh.radial_segments = 48
		platform.mesh = mesh
		platform.material_override = WorldScreen.standard_material(Lobby.STONE_JOINT)
		platform.position = Vector3(cx, Lobby.ZONE_PLATFORM_HEIGHT * 0.5, cz)
		add_child(platform)

		var rim := MeshInstance3D.new()
		var torus := TorusMesh.new()
		torus.inner_radius = Lobby.ZONE_RADIUS * 0.94 - 0.16
		torus.outer_radius = Lobby.ZONE_RADIUS * 0.94
		rim.mesh = torus
		rim.material_override = WorldScreen.standard_material(accent, 1.3)
		rim.position = Vector3(cx, 0.44, cz)
		add_child(rim)

		var light := OmniLight3D.new()
		light.light_color = accent
		light.light_energy = 14.0
		light.omni_range = 30.0
		light.position = Vector3(cx, 6, cz)
		add_child(light)

		var pole := MeshInstance3D.new()
		var pole_mesh := CylinderMesh.new()
		pole_mesh.top_radius = 0.2
		pole_mesh.bottom_radius = 0.3
		pole_mesh.height = 4.4
		pole_mesh.radial_segments = 8
		pole.mesh = pole_mesh
		pole.material_override = WorldScreen.standard_material(Color("334155"))
		pole.position = Vector3(cx, 2.6, cz)
		add_child(pole)

		var totem := mesh_or_null("rpg/crystal_cluster", accent, 1.1)
		if totem != null:
			totem.position = Vector3(cx, 4.9, cz)
			add_child(totem)

		var props: Array = ZONE_PROPS.get(str(category["id"]), [])
		for i in props.size():
			var angle := (float(i) / float(maxi(1, props.size()))) * TAU + PI / 6.0
			var prop := mesh_or_null(str(props[i]), Color.WHITE, 1.1)
			if prop == null:
				continue
			prop.position = Vector3(cx + cos(angle) * (Lobby.ZONE_RADIUS - 1.9), 0.4, cz + sin(angle) * (Lobby.ZONE_RADIUS - 1.9))
			prop.rotation.y = randf() * TAU
			add_child(prop)

		var games: Array = zone["games"]
		var offsets := Lobby.pedestal_offsets(games.size())
		for i in games.size():
			var game: Dictionary = games[i]
			var game_accent: Color = game["accent"]
			var px: float = cx + offsets[i].x
			var pz: float = cz + offsets[i].y

			var base := MeshInstance3D.new()
			var base_mesh := CylinderMesh.new()
			base_mesh.top_radius = 1.05
			base_mesh.bottom_radius = 1.25
			base_mesh.height = 0.8
			base_mesh.radial_segments = 20
			base.mesh = base_mesh
			base.material_override = WorldScreen.standard_material(Color("0f172a"), 0.55)
			base.position = Vector3(px, 0.7, pz)
			add_child(base)

			var ring := MeshInstance3D.new()
			var ring_torus := TorusMesh.new()
			ring_torus.inner_radius = 0.91
			ring_torus.outer_radius = 1.0
			ring.mesh = ring_torus
			ring.material_override = WorldScreen.standard_material(game_accent, 1.6)
			ring.position = Vector3(px, 1.16, pz)
			add_child(ring)

			var beacon := mesh_or_null("rpg/crystal_cluster", game_accent, 0.85)
			if beacon != null:
				beacon.position = Vector3(px, 2.0, pz)
				add_child(beacon)

			pedestals.append({"game": game, "node": base, "x": px, "z": pz, "ring": ring})


func _build_scenery() -> void:
	for spec in SCENERY:
		for i in int(spec["count"]):
			var angle := randf() * TAU
			var radius: float = float(spec["minR"]) + randf() * (float(spec["maxR"]) - float(spec["minR"]))
			var object := mesh_or_null(str(spec["key"]), Color.WHITE, randf() * 2.0)
			if object == null:
				continue
			object.position = Vector3(cos(angle) * radius, 0, sin(angle) * radius)
			object.rotation.y = randf() * TAU
			add_child(object)
	for i in 20:
		var angle := (float(i) / 20.0) * TAU
		var pillar := mesh_or_null("rpg/stone_pillar", Color.WHITE, 1.5)
		if pillar == null:
			continue
		pillar.position = Vector3(cos(angle) * 42.0, 0, sin(angle) * 42.0)
		pillar.rotation.y = angle
		add_child(pillar)


## The way into the mesh gallery: a lit ring with a floating crystal. Standing
## in it and pressing the interact button (or the on-screen button) opens the
## gallery, where every bundled mesh can be inspected and marked for rework.
func _build_gallery_portal() -> void:
	var spot := Lobby.gallery_position()
	gallery_portal = Node3D.new()
	gallery_portal.position = Vector3(spot.x, 0.0, spot.y)
	add_child(gallery_portal)

	var disc := MeshInstance3D.new()
	var disc_mesh := CylinderMesh.new()
	disc_mesh.top_radius = 2.2
	disc_mesh.bottom_radius = 2.4
	disc_mesh.height = 0.25
	disc_mesh.radial_segments = 24
	disc.mesh = disc_mesh
	disc.material_override = WorldScreen.standard_material(Color("0b1220"), 0.4)
	disc.position.y = 0.12
	gallery_portal.add_child(disc)

	gallery_ring = MeshInstance3D.new()
	var ring_torus := TorusMesh.new()
	ring_torus.inner_radius = 2.1
	ring_torus.outer_radius = 2.45
	ring_torus.rings = 28
	gallery_ring.mesh = ring_torus
	gallery_ring.material_override = WorldScreen.standard_material(Color("38bdf8"), 1.8)
	gallery_ring.position.y = 0.3
	gallery_portal.add_child(gallery_ring)

	var crystal := mesh_or_null("crystal", Color("38bdf8"), 1.5)
	if crystal == null:
		crystal = mesh_or_null("rpg/crystal_cluster", Color("38bdf8"), 1.2)
	if crystal != null:
		crystal.position = Vector3(0, 2.2, 0)
		gallery_portal.add_child(crystal)

	var light := OmniLight3D.new()
	light.light_color = Color("38bdf8")
	light.light_energy = 18.0
	light.omni_range = 22.0
	light.position = Vector3(0, 2.6, 0)
	gallery_portal.add_child(light)

	gallery_label = Label3D.new()
	# A `Label3D` has no `Ui.*` helper behind it, so it resolves nothing on its
	# own: the caption has to be translated where it is assigned.
	gallery_label.text = Loc.f("◈  MESH GALLERY", [])
	gallery_label.font_size = 60
	gallery_label.outline_size = 16
	gallery_label.outline_modulate = Color("020617")
	gallery_label.modulate = Color("7dd3fc")
	gallery_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	gallery_label.position = Vector3(0, 4.2, 0)
	gallery_portal.add_child(gallery_label)

	for i in 3:
		var angle := TAU * float(i) / 3.0
		var post := mesh_or_null("rpg/rune_stone", Color("475569"), 1.0)
		if post == null:
			continue
		post.position = Vector3(cos(angle) * 3.3, 0.0, sin(angle) * 3.3)
		post.rotation.y = angle
		gallery_portal.add_child(post)


func _build_player() -> void:
	player = Node3D.new()
	var knight := mesh_or_null("rpg/knight", Color("cbd5e1"), 1.0)
	if knight != null:
		player.add_child(knight)
	player.position = pos
	add_child(player)


## Tries a bundled mesh and falls back to a coloured primitive so the lobby is
## never empty even if an import is missing.
func mesh_or_null(key: String, color: Color, scale: float) -> Node3D:
	var node := WorldScreen.mesh(key, color, scale)
	if node != null:
		return node
	return null


# --- HUD --------------------------------------------------------------------

func _build_hud_panels() -> void:
	_stick = add_stick("bottom_left")
	var interact := add_action_button("E", 70.0, "interact")
	interact.position = interact.position + Vector2(0, -84)

	var list_button := Ui.button("Lust", Vector2(110, 40), UiTheme.PANEL_LIGHT, func() -> void:
		Sfx.select()
		Router.go_to("lobby_list")
	)
	list_button.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	list_button.position = Vector2(_stick.size.x + 40.0, -52.0)
	hud_root.add_child(list_button)

	var gallery_button := Ui.button("◈ Gallery", Vector2(150, 40), UiTheme.PANEL_LIGHT, func() -> void:
		Sfx.select()
		Router.go_to("mesh_gallery")
	)
	gallery_button.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	gallery_button.position = Vector2(_stick.size.x + 40.0, -100.0)
	hud_root.add_child(gallery_button)

	_map = Minimap.new()
	_map.screen = self
	_map.custom_minimum_size = Vector2(MAP_SIZE, MAP_SIZE)
	_map.size = Vector2(MAP_SIZE, MAP_SIZE)
	_map.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_map.position = Vector2(14, 66)
	hud_root.add_child(_map)

	_panel = Control.new()
	_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_panel.custom_minimum_size = Vector2(360, 250)
	_panel.size = Vector2(360, 250)
	_panel.position = Vector2(-380, -300)
	_panel.visible = false
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_root.add_child(_panel)

	var background := Ui.rect(Color(0.031, 0.047, 0.086, 0.85), 14, UiTheme.BORDER, 2)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel.add_child(background)

	var column := Ui.vbox(6)
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	column.offset_left = 14
	column.offset_right = -14
	column.offset_top = 12
	column.offset_bottom = -12
	_panel.add_child(column)

	_panel_icon = Ui.label("", 26, UiTheme.ACCENT, true)
	column.add_child(_panel_icon)
	_panel_name = Ui.label("", 20, UiTheme.TEXT, true)
	column.add_child(_panel_name)
	_panel_tag = Ui.label("", 13, UiTheme.TEXT_DIM)
	column.add_child(_panel_tag)
	_panel_games = Ui.vbox(6)
	_panel_games.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_panel_games)

	_toast = Ui.label(Loc.t("lobby.walk_hint"), 18, UiTheme.TEXT, true)
	_toast.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_toast.position = Vector2(-300, -190)
	_toast.size = Vector2(600, 34)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.add_theme_color_override("font_outline_color", Color(0.02, 0.03, 0.06))
	_toast.add_theme_constant_override("outline_size", 6)
	hud_root.add_child(_toast)


func _update_world(delta: float) -> void:
	if transitioning:
		return
	var input_vector := VirtualStick.combined(_stick.value, &"move_left", &"move_right")
	if input_vector.length() > 0.05:
		var run: float = RUN_MULT if (Input.is_key_pressed(KEY_SHIFT) or _is_sprint) else 1.0
		pos.x += input_vector.x * MOVE_SPEED * run * delta
		pos.z += input_vector.y * MOVE_SPEED * run * delta
		facing = atan2(-input_vector.x, -input_vector.y)
		var clamped := Lobby.clamp_to_lobby(pos.x, pos.z)
		pos.x = clamped.x
		pos.z = clamped.y

	var zone := _zone_at(pos)
	_refresh_panel(zone)
	var nearest := _nearest_pedestal(pos)
	_refresh_near(nearest)

	var interact_now := Input.is_action_pressed("interact")
	if interact_now and not _interact_held:
		if not nearest.is_empty():
			_start(nearest["game"])
		elif _gallery_near:
			Router.go_to("mesh_gallery")
	_interact_held = interact_now

	_gallery_near = _at_gallery(pos)
	if gallery_ring != null:
		gallery_ring.rotation.y += delta * 1.2
		gallery_ring.scale = Vector3.ONE * (1.06 if _gallery_near else 1.0)
	if gallery_label != null:
		gallery_label.modulate = Color("facc15") if _gallery_near else Color("7dd3fc")

	player.position = Vector3(pos.x, sin(elapsed * 3.0) * 0.05, pos.z)
	player.rotation.y = facing

	fire_light.light_energy = 26.0 + sin(elapsed * 5.0) * 6.0
	hub_ring.rotation.y += delta * 0.4

	follow_camera(Vector3(pos.x, 2.2, pos.z), CAMERA_HEIGHT, CAMERA_DISTANCE, 5.0, delta)

	_minimap_timer += delta
	if _minimap_timer >= MAP_INTERVAL:
		_minimap_timer = 0.0
		_map.active_zone = str(zone.get("category", {}).get("id", "")) if not zone.is_empty() else ""
		_map.queue_redraw()


var _is_sprint := false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key := event as InputEventKey
		if key.keycode == KEY_SHIFT:
			_is_sprint = key.pressed


func _zone_at(p: Vector3) -> Dictionary:
	for zone in zones:
		if Lobby.distance_sq(p.x, p.z, float(zone["x"]), float(zone["z"])) <= Lobby.ZONE_RADIUS * Lobby.ZONE_RADIUS:
			return zone
	return {}


## True while the player stands in the gallery portal.
func _at_gallery(p: Vector3) -> bool:
	var spot := Lobby.gallery_position()
	return Lobby.distance_sq(p.x, p.z, spot.x, spot.y) <= Lobby.GALLERY_TRIGGER * Lobby.GALLERY_TRIGGER


func _nearest_pedestal(p: Vector3) -> Dictionary:
	var nearest: Dictionary = {}
	var best := Lobby.PEDESTAL_TRIGGER * Lobby.PEDESTAL_TRIGGER
	for pedestal in pedestals:
		var dist := Lobby.distance_sq(p.x, p.z, float(pedestal["x"]), float(pedestal["z"]))
		if dist <= best:
			best = dist
			nearest = pedestal
	return nearest


func _refresh_panel(zone: Dictionary) -> void:
	if str(zone.get("category", {}).get("id", "")) == str(active_zone.get("category", {}).get("id", "")) and not zone.is_empty():
		return
	if zone.is_empty() and active_zone.is_empty():
		return
	active_zone = zone
	if zone.is_empty():
		_panel.visible = false
		_toast.visible = true
		_toast.text = Loc.t("lobby.walk_hint")
		return
	_panel.visible = true
	var category: Dictionary = zone["category"]
	_panel_icon.text = str(category["icon"])
	_panel_name.text = Loc.resolve(str(category["name"]))
	_panel_tag.text = Loc.resolve(str(category["tagline"]))
	for child in _panel_games.get_children():
		child.queue_free()
	_panel_buttons.clear()
	_panel_games_list = []
	for game in zone["games"]:
		var entry: Dictionary = game
		var button := Ui.button(Loc.f("%s  %s", [entry["icon"], entry["name"]]), Vector2(0, 40), Color(0.043, 0.071, 0.125, 0.95), func() -> void:
			Sfx.level_up()
			_start(entry)
		)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.add_theme_stylebox_override("normal", UiTheme.flat(Color(0.043, 0.071, 0.125, 0.95), entry["accent"], 8, 2))
		button.add_theme_stylebox_override("hover", UiTheme.flat(Color(0.090, 0.125, 0.212, 0.98), entry["accent"], 8, 2))
		_panel_games.add_child(button)
		_panel_buttons.append(button)
		_panel_games_list.append(entry)
	_panel_games_list = zone["games"]


func _refresh_near(pedestal: Dictionary) -> void:
	if str(pedestal.get("game", {}).get("id", "")) == str(active_pedestal.get("game", {}).get("id", "")) and pedestal.is_empty() == active_pedestal.is_empty():
		return
	active_pedestal = pedestal
	for i in _panel_buttons.size():
		var near: bool = not pedestal.is_empty() and i < _panel_games_list.size() and str(_panel_games_list[i]["id"]) == str(pedestal["game"]["id"])
		_panel_buttons[i].modulate = Color(1, 1, 1) if not near else Color(1.3, 1.3, 1.0)
	if not pedestal.is_empty():
		_toast.visible = true
		_toast.text = Loc.f("E — %s %s", [pedestal["game"]["icon"], pedestal["game"]["name"]])
	elif active_zone.is_empty():
		_toast.visible = true
		_toast.text = Loc.t("lobby.walk_hint")


func _start(game: Dictionary) -> void:
	if transitioning:
		return
	transitioning = true
	Sfx.level_up()
	Router.play(str(game["id"]))


## Corner minimap: world disc, hub, category plazas with icons and the player.
class Minimap:
	extends Control
	var screen: Lobby3DScreen
	var active_zone := ""

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		if screen == null:
			return
		var center := Vector2(size.x * 0.5, size.y * 0.5)
		draw_circle(center, size.x * 0.5 - 2.0, Color(0.031, 0.047, 0.086, 0.8))
		draw_arc(center, size.x * 0.5 - 2.0, 0.0, TAU, 48, Color(0.580, 0.639, 0.706, 0.5), 1.5, true)
		var scale: float = (size.x * 0.5 - MAP_PADDING) / Lobby.MINIMAP_WORLD_RADIUS
		draw_circle(center, HUB_RADIUS * scale, Color(0.141, 0.200, 0.286, 0.95))
		var font := Ui.font_bold()
		for zone in screen.zones:
			var point := Lobby.minimap_point(float(zone["x"]), float(zone["z"]), size.x, MAP_PADDING, Lobby.MINIMAP_WORLD_RADIUS)
			var category: Dictionary = zone["category"]
			var accent: Color = category["accent"]
			var is_active: bool = str(category["id"]) == active_zone
			draw_circle(point, Lobby.ZONE_RADIUS * scale, Color(accent.r, accent.g, accent.b, 0.85 if is_active else 0.4))
			if is_active:
				draw_arc(point, Lobby.ZONE_RADIUS * scale, 0.0, TAU, 24, UiTheme.TEXT, 2.0, true)
			if font != null:
				var glyph := str(category["icon"])
				var metrics := font.get_string_size(glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, 14)
				draw_string(font, point - Vector2(metrics.x * 0.5, -5.0), glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, UiTheme.TEXT)
		var player_point := Lobby.minimap_point(screen.pos.x, screen.pos.z, size.x, MAP_PADDING, Lobby.MINIMAP_WORLD_RADIUS)
		var dir := Vector2(-sin(screen.facing), -cos(screen.facing))
		var arrow := PackedVector2Array([
			player_point + dir * 8.0,
			player_point - dir * 5.0 + Vector2(dir.y, -dir.x) * 5.0,
			player_point - dir * 5.0 - Vector2(dir.y, -dir.x) * 5.0,
		])
		draw_colored_polygon(arrow, UiTheme.TEXT)
