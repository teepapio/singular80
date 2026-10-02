class_name Lobby3DScreen
extends WorldScreen
## Walkable 3D lobby — one area per game category on a ring, with an open
## crossing in the middle. Port of `scenes/Lobby3DScene.ts` plus `lobby.ts`.
##
## The knight is walked with the virtual stick (or WASD/arrows/gamepad), each
## category plaza holds one pedestal per game, and standing next to a pedestal
## plus pressing the interact button (or tapping its card) starts the game.
##
## The middle of the map is the crossing and nothing else: no disc, no rim, no
## props. It used to be a raised platform with a turning ring, a campfire, four
## torches and a rune-stone signpost — the one place a player arrives at, stands
## in and leaves again, because none of it did anything.

const MOVE_SPEED := 15.0
const RUN_MULT := 1.7
const CAMERA_HEIGHT := 11.5
const CAMERA_DISTANCE := 12.5
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

var pos := Vector3(0, 0, 7)
var facing := PI
var player: Node3D
var zones: Array[Dictionary] = []
var pedestals: Array[Dictionary] = []
var active_zone: Dictionary = {}
var active_pedestal: Dictionary = {}
var transitioning := false
var gallery_portal: Node3D
var gallery_label: Label3D
var gallery_ring: MeshInstance3D
var _gallery_near := false
## Where the gallery portal stands, read once. `Lobby.gallery_position()` builds
## the whole plaza layout, and `_at_gallery()` asks for it every frame.
var _gallery_spot := Vector2.ZERO

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

	_build_ground()
	zones = Lobby.zone_layout()
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
	var ground := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = 130.0
	mesh.bottom_radius = 130.0
	mesh.height = 0.2
	mesh.radial_segments = 64
	ground.mesh = mesh
	ground.material_override = WorldScreen.standard_material(Color("1b2436"))
	ground.position.y = -0.1
	add_child(ground)

	var grid := ImmediateMesh.new()
	var previous := Vector3.ZERO
	for i in range(49):
		var x := -96.0 + float(i) * 4.0
		if i == 0:
			grid.surface_begin(Mesh.PRIMITIVE_LINES)
		grid.surface_add_vertex(Vector3(x, 0.02, -48))
		grid.surface_add_vertex(Vector3(x, 0.02, 48))
	for i in range(25):
		var z := -48.0 + float(i) * 4.0
		grid.surface_add_vertex(Vector3(-48, 0.02, z))
		grid.surface_add_vertex(Vector3(48, 0.02, z))
	grid.surface_end()
	var grid_mesh := MeshInstance3D.new()
	grid_mesh.mesh = grid
	var grid_mat := StandardMaterial3D.new()
	grid_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	grid_mat.vertex_color_use_as_albedo = true
	grid_mat.albedo_color = Color("334155")
	grid_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	grid_mat.albedo_color.a = 0.35
	grid_mesh.material_override = grid_mat
	add_child(grid_mesh)


func _build_zones() -> void:
	for zone in zones:
		var category: Dictionary = zone["category"]
		var accent: Color = category["accent"]
		var cx: float = zone["x"]
		var cz: float = zone["z"]

		var platform := MeshInstance3D.new()
		var mesh := CylinderMesh.new()
		mesh.top_radius = Lobby.ZONE_RADIUS * 0.94
		mesh.bottom_radius = Lobby.ZONE_RADIUS
		mesh.height = 0.4
		mesh.radial_segments = 48
		platform.mesh = mesh
		platform.material_override = WorldScreen.standard_material(Color("1a2436"))
		platform.position = Vector3(cx, 0.2, cz)
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

		# The plaza's own landmark, high above the pedestals. Named `banner`,
		# not `totem`: GDScript gives one function body one namespace, so two
		# `var totem` in two different loops are a parse error.
		var banner := mesh_or_null("rpg/crystal_cluster", accent, 1.1)
		if banner != null:
			banner.position = Vector3(cx, 4.9, cz)
			add_child(banner)

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

			# The rim runs around the *edge* of the plinth, not across its top
			# face: the game's own mesh stands on that face now, and a ring
			# underneath was covered by every wide object.
			var ring := MeshInstance3D.new()
			var ring_torus := TorusMesh.new()
			ring_torus.inner_radius = Lobby.PEDESTAL_RIM_INNER
			ring_torus.outer_radius = Lobby.PEDESTAL_RIM_OUTER
			ring_torus.rings = 24
			ring.mesh = ring_torus
			ring.material_override = WorldScreen.standard_material(game_accent, 1.6)
			ring.position = Vector3(px, Lobby.PEDESTAL_TOP - 0.04, pz)
			add_child(ring)

			var totem := _pedestal_totem(game, px, pz)
			if totem != null:
				add_child(totem)

			pedestals.append({"game": game, "node": base, "x": px, "z": pz, "ring": ring})


## The mesh that represents `game` on its plinth: the game's own silhouette,
## normalised to one size and stood on the top face.
##
## It keeps the colours it was drawn with. The accent lives on the rim now, and
## tinting the object as well turned every horse, castle and bonbon into the
## same coloured lump the crystal used to be.
func _pedestal_totem(game: Dictionary, x: float, z: float) -> Node3D:
	var node := mesh_or_null(Lobby.totem_of(str(game["id"])), Color.WHITE, 1.0)
	if node == null:
		# A mesh that failed to import must not leave a bare plinth: the old
		# crystal still says "a game is here", in the game's colour.
		node = mesh_or_null(Lobby.DEFAULT_TOTEM, game["accent"], 1.0)
	if node == null:
		return null
	WorldScreen.fit_on_base(node, Lobby.PEDESTAL_MESH_SIZE)
	node.position = Vector3(x, Lobby.PEDESTAL_TOP, z)
	return node


func _build_scenery() -> void:
	for spec in Lobby.SCENERY:
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
	_gallery_spot = spot
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


## Tries a bundled mesh and returns `null` when the import is missing, so the
## caller can decide what an absent object should look like instead.
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
##
## Reads the cached spot: `Lobby.gallery_position()` builds the whole plaza
## layout, five dictionaries and a game list each, and this runs every frame.
func _at_gallery(p: Vector3) -> bool:
	return Lobby.distance_sq(p.x, p.z, _gallery_spot.x, _gallery_spot.y) <= Lobby.GALLERY_TRIGGER * Lobby.GALLERY_TRIGGER


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


## Corner minimap: world disc, gallery portal, category plazas with icons and the
## player.
##
## The middle of the map carries no hub circle any more — there is nothing there
## to point at. What is left in the middle is the gallery portal, and it is the
## one thing on the map besides the plazas, so it gets the mark.
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
		var gallery_point := Lobby.minimap_point(screen._gallery_spot.x, screen._gallery_spot.y, size.x, MAP_PADDING, Lobby.MINIMAP_WORLD_RADIUS)
		var gallery_near: bool = screen._gallery_near
		draw_circle(gallery_point, Lobby.GALLERY_TRIGGER * scale, Color(0.216, 0.757, 0.965, 0.95 if gallery_near else 0.55))
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
