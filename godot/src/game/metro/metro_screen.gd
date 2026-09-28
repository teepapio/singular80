class_name MetroScreen
extends WorldScreen
## Metropol 3D — build and run a metro network on a tilted 3D city block. Port
## of the 2D OluMetro game. All rules live in `metro.gd`; this file only turns
## that state into meshes, routes touch input and draws the HUD.
## Batching is the whole budget: one `ArrayMesh` ribbon per line (rebuilt only
## when its station list changes), one bead `MultiMesh` per line for direction,
## one `MultiMesh` for every waiting commuter, sun and fog on the in-game clock.

const GROUND_Y := 0.0
const WATER_Y := -0.18
const RIBBON_Y := GROUND_Y + 0.07
const SYMBOL_Y := 2.9
const GLYPH_Y := 2.05
## Height of the demand marker: above the interchange ring and the type-change
## sign, so a stuck station is readable from the normal camera distance.
const DEMAND_Y := 5.9
## Spacing of the direction beads along a line, in world units.
const BEAD_SPACING := 3.4
const MAX_BEADS := 34
## How many waiting commuters are drawn; the rest only count towards the HUD.
const MAX_CROWD := 300
const CROWD_RING := 2.2
const MAX_POPUPS := 14
const POPUP_LIFE := 1.1
const SPARKLES := 90
## Camera rig.
const CAM_MIN_DISTANCE := 22.0
const CAM_MAX_DISTANCE := 96.0
const CAM_DEFAULT_DISTANCE := 56.0
const CAM_PITCH := 0.92
const CAM_YAW_STEP := 0.22
const TAP_SLOP := 24.0
const PAN_SPEED := 0.05
## How many attempts the city-dressing pass makes.
const DECOR_ATTEMPTS := 170

enum Tool { BUILD, TRAIN, WAGON, REMOVE }

var metro := Metro.new()
var tool: int = Tool.BUILD
## The line the player is currently chaining taps into, or -1.
var drawing_line: int = -1

# --- world nodes ------------------------------------------------------------
var _water_root: Node3D
var _line_root: Node3D
var _station_root: Node3D
var _train_root: Node3D
var _scenery: Node3D
var _sparkles: MultiMeshInstance3D
var _crowd: MultiMeshInstance3D

var _line_meshes: Array[MeshInstance3D] = []
var _bead_nodes: Array[MultiMeshInstance3D] = []
var _bead_phase := PackedFloat32Array()
var _station_nodes: Array[Node3D] = []
var _train_nodes: Array[Node3D] = []
var _crossing_props: Array[Node3D] = []
var _decor_nodes: Array[Node3D] = []

var _symbol_meshes: Dictionary = {}
var _meshes: Dictionary = {}
var _decor_keys: Array[String] = [
	"rpg/pine_tree", "rpg/bush", "rpg/rock_small", "rpg/dead_tree", "rpg/stone_pillar",
]
var _decor_templates: Array[Node3D] = []
var _sparkle_data := PackedFloat32Array()

# --- camera -----------------------------------------------------------------
var cam_focus := Vector3(48.0, 0.0, 34.0)
var cam_distance := CAM_DEFAULT_DISTANCE
var cam_yaw := 0.0
var _light_blend := 1.0

# --- input ------------------------------------------------------------------
var _pointers: Dictionary = {}
var _pointer_start: Dictionary = {}
var _pointer_time: Dictionary = {}
var _gesture := false
var _gesture_span := 0.0
var _gesture_angle := 0.0
var _gesture_mid := Vector2.ZERO
var _dragged := false

# --- hud --------------------------------------------------------------------
var _money_label: Label
var _waiting_label: Label
var _riding_label: Label
var _day_label: Label
var _clock_label: Label
var _phase_label: Label
var _demand_label: Label
var _peak_label: Label
var _happiness: ProgressBar
var _critical_panel: Panel
var _critical_label: Label
var _resource_values: Array[Label] = []
var _tool_buttons: Array[Button] = []
var _finish_button: Button
var _speed_button: Button
var _pause_button: Button
var _inspect_panel: Panel
var _inspect_title: Label
var _inspect_body: Label
var _inspect_branch: Button
var _inspect_station := -1
var _popups: Array[Label] = []
var _popup_life := PackedFloat32Array()
var _popup_world := PackedVector2Array()
var _modal_layer: Control
var _started := false


# --- setup ------------------------------------------------------------------

func _ready_world() -> void:
	metro = Metro.new()
	_build_world()
	_build_meshes()
	_build_ui()
	_popup_pool()
	_set_tool(Tool.BUILD)
	_show_mode_select()
	hide_loading()


func _build_world() -> void:
	set_fog(Color("0b1220"), 0.005)
	set_ambient(Color("9ec5ff"), 0.9)
	sun.light_energy = 1.15
	sun.light_color = Color(1.0, 0.96, 0.88)
	sun.shadow_enabled = false
	fill.light_energy = 0.4
	fill.light_color = Color("7f9ddb")
	camera.fov = 46.0
	camera.far = 400.0

	_water_root = Node3D.new()
	add_child(_water_root)
	_line_root = Node3D.new()
	add_child(_line_root)
	_station_root = Node3D.new()
	add_child(_station_root)
	_train_root = Node3D.new()
	add_child(_train_root)
	_scenery = Node3D.new()
	add_child(_scenery)

	cam_focus = Vector3(Metro.MAP_SIZE.x * 0.5, 0.0, Metro.MAP_SIZE.y * 0.5)
	cam_distance = CAM_DEFAULT_DISTANCE
	_apply_camera(1.0)

	# Ground plate plus a survey grid: the schematic look of a planning table.
	var plate := MeshInstance3D.new()
	var plate_mesh := BoxMesh.new()
	plate_mesh.size = Vector3(Metro.MAP_SIZE.x + 18.0, 1.0, Metro.MAP_SIZE.y + 18.0)
	plate.mesh = plate_mesh
	plate.material_override = WorldScreen.standard_material(Color("1d2c20"))
	plate.position = Vector3(Metro.MAP_SIZE.x * 0.5, -0.52, Metro.MAP_SIZE.y * 0.5)
	add_child(plate)

	var half := Vector2(Metro.MAP_SIZE.x, Metro.MAP_SIZE.y) * 0.5
	var grid := ImmediateMesh.new()
	grid.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in 17:
		var x := half.x * (float(i) / 16.0 * 2.0 - 1.0)
		grid.surface_add_vertex(Vector3(half.x + x, 0.02, -half.y))
		grid.surface_add_vertex(Vector3(half.x + x, 0.02, half.y))
	for i in 13:
		var z := half.y * (float(i) / 12.0 * 2.0 - 1.0)
		grid.surface_add_vertex(Vector3(0.0, 0.02, half.y + z))
		grid.surface_add_vertex(Vector3(half.x * 2.0, 0.02, half.y + z))
	grid.surface_end()
	var grid_node := MeshInstance3D.new()
	grid_node.mesh = grid
	var grid_mat := StandardMaterial3D.new()
	grid_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	grid_mat.vertex_color_use_as_albedo = true
	grid_mat.albedo_color = Color(0.36, 0.54, 0.44, 0.3)
	grid_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	grid_node.material_override = grid_mat
	add_child(grid_node)

	_build_sparkles()


## Drifting highlights on the water — the cheapest convincing moving surface.
func _build_sparkles() -> void:
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.75, 0.02, 0.16)
	_sparkles = MultiMeshInstance3D.new()
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = SPARKLES
	multimesh.visible_instance_count = 0
	_sparkles.multimesh = multimesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.85, 0.95, 1.0, 0.45)
	mat.emission_enabled = true
	mat.emission = Color(0.7, 0.9, 1.0)
	mat.emission_energy_multiplier = 0.9
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_sparkles.material_override = mat
	_water_root.add_child(_sparkles)

	var rng := RandomNumberGenerator.new()
	rng.seed = 20240917
	_sparkle_data.resize(SPARKLES * 3)
	for i in SPARKLES:
		_sparkle_data[i * 3] = rng.randf_range(0.0, Metro.MAP_SIZE.x)
		_sparkle_data[i * 3 + 1] = rng.randf_range(0.0, Metro.MAP_SIZE.y)
		_sparkle_data[i * 3 + 2] = rng.randf() * TAU


## One shared mesh per symbol family and per prop, so the whole map still runs
## in a handful of draw calls. Nothing is instantiated per frame.
func _build_meshes() -> void:
	var sphere := SphereMesh.new()
	sphere.radius = 0.38
	sphere.height = 0.76
	sphere.radial_segments = 10
	sphere.rings = 6
	_symbol_meshes[Metro.Symbol.ROUND] = sphere

	var cube := BoxMesh.new()
	cube.size = Vector3(0.66, 0.66, 0.66)
	_symbol_meshes[Metro.Symbol.SQUARE] = cube
	_symbol_meshes[Metro.Symbol.CROSS] = cube

	var prism := PrismMesh.new()
	prism.size = Vector3(0.86, 0.5, 0.86)
	_symbol_meshes[Metro.Symbol.TRIANGLE] = prism

	var hex := CylinderMesh.new()
	hex.top_radius = 0.44
	hex.bottom_radius = 0.44
	hex.height = 0.52
	hex.radial_segments = 6
	hex.rings = 1
	_symbol_meshes[Metro.Symbol.HEX] = hex
	_symbol_meshes[Metro.Symbol.STAR] = _star_mesh()

	_meshes["station"] = _mesh_of("metro/station")
	_meshes["interchange"] = _mesh_of("metro/interchange")
	_meshes["transfer"] = _mesh_of("metro/transfer_ring")
	_meshes["loco"] = _mesh_of("metro/loco")
	_meshes["car"] = _mesh_of("metro/car")
	_meshes["bridge"] = _mesh_of("metro/bridge")
	_meshes["portal"] = _mesh_of("metro/tunnel_portal")
	_meshes["house"] = _mesh_of("metro/house")
	_meshes["tower"] = _mesh_of("metro/tower")
	_meshes["park"] = _mesh_of("metro/park")
	_meshes["passenger"] = _mesh_of("metro/passenger")

	for key in _decor_keys:
		var template := WorldScreen.mesh(key)
		if template != null:
			_decor_templates.append(template)

	_crowd = MultiMeshInstance3D.new()
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = _meshes["passenger"]
	# `use_colors` may only be switched while the MultiMesh is still empty, so
	# the commuters get their destination colour — otherwise every
	# `set_instance_color` below is refused and the crowd stays grey.
	multimesh.use_colors = true
	multimesh.instance_count = MAX_CROWD
	multimesh.visible_instance_count = 0
	_crowd.multimesh = multimesh
	var crowd_mat := StandardMaterial3D.new()
	crowd_mat.vertex_color_use_as_albedo = true
	crowd_mat.roughness = 0.85
	_crowd.material_override = crowd_mat
	_station_root.add_child(_crowd)


## The shared `Mesh` of one registry key. The temporary instance is released
## again; the `Mesh` resource itself survives on its own reference.
func _mesh_of(key: String) -> Mesh:
	var node := WorldScreen.mesh(key)
	if node == null:
		return null
	var found := _first_mesh(node)
	node.free()
	return found


func _first_mesh(node: Node) -> Mesh:
	for child in node.get_children():
		if child is MeshInstance3D:
			var mesh: Mesh = (child as MeshInstance3D).mesh
			if mesh != null:
				return mesh
		var nested := _first_mesh(child)
		if nested != null:
			return nested
	return null


## A five-pointed star prism, built once.
static func _star_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var top := 0.26
	var outline: Array[Vector2] = []
	for i in 10:
		var angle := float(i) * PI / 5.0 - PI * 0.5
		var radius := 0.46 if i % 2 == 0 else 0.2
		outline.append(Vector2(cos(angle), sin(angle)) * radius)
	for i in outline.size():
		var a := outline[i]
		var b := outline[(i + 1) % outline.size()]
		_tri(st, Vector3(0.0, top, 0.0), Vector3(a.x, top, a.y), Vector3(b.x, top, b.y))
		_tri(st, Vector3(0.0, -top, 0.0), Vector3(b.x, -top, b.y), Vector3(a.x, -top, a.y))
		var a_low := Vector3(a.x, -top, a.y)
		var b_low := Vector3(b.x, -top, b.y)
		_tri(st, Vector3(a.x, top, a.y), a_low, b_low)
		_tri(st, Vector3(a.x, top, a.y), b_low, Vector3(b.x, top, b.y))
	return st.commit()


static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)


static func _quad(st: SurfaceTool, a: Vector3, ca: Color, b: Vector3, cb: Color, c: Vector3, cc: Color, d: Vector3, cd: Color) -> void:
	_vertex(st, a, ca)
	_vertex(st, b, cb)
	_vertex(st, c, cc)
	_vertex(st, a, ca)
	_vertex(st, c, cc)
	_vertex(st, d, cd)


static func _vertex(st: SurfaceTool, at: Vector3, color: Color) -> void:
	st.set_color(color)
	st.add_vertex(at)


# --- stations ---------------------------------------------------------------

## Grows the station pool to match the city. Nodes are reused, never rebuilt.
func _sync_stations() -> void:
	while _station_nodes.size() < metro.stations.size():
		_station_nodes.append(_make_station_node())
	for index in metro.stations.size():
		var station: Dictionary = metro.stations[index]
		var node := _station_nodes[index]
		var pos: Vector2 = station["pos"]
		node.position = Vector3(pos.x, 0.0, pos.y)
		var kind := int(station["type"])
		var color := Metro.type_color(kind)
		var interchange := metro.is_transfer(int(station["id"]))
		_apply_building(node, interchange, color)
		var symbol: Node3D = node.get_node("Symbol")
		var body: MeshInstance3D = symbol.get_node("Body")
		body.mesh = _symbol_meshes[Metro.type_symbol(kind)]
		if body.material_override == null:
			body.material_override = WorldScreen.standard_material(color, 0.4)
		else:
			(body.material_override as StandardMaterial3D).albedo_color = color
		# The cross symbol is two bars, so it needs a second child.
		var extra: MeshInstance3D = symbol.get_node("Extra")
		var is_cross := Metro.type_symbol(kind) == Metro.Symbol.CROSS
		extra.visible = is_cross
		if is_cross and extra.material_override == null:
			extra.material_override = WorldScreen.standard_material(color, 0.4)
		var glyph: Label3D = node.get_node("Glyph")
		if glyph.text != Metro.type_glyph(kind):
			glyph.text = Metro.type_glyph(kind)
		glyph.modulate = color
		var ring: MeshInstance3D = node.get_node("Ring")
		ring.visible = interchange
		# Overcrowding warning; the glow brightens as the timer runs down.
		var warn: MeshInstance3D = node.get_node("Warn")
		var over := float(station["over"])
		warn.visible = over > 0.0
		if warn.visible:
			var mat := warn.material_override as StandardMaterial3D
			var urgency := clampf(over / Metro.OVERCROWD_LIMIT, 0.0, 1.0)
			mat.emission = Color("fbbf24").lerp(Color("ef4444"), urgency)
			mat.emission_energy_multiplier = 0.8 + urgency * 2.4
		(node.get_node("Changing") as Node3D).visible = float(station["shape_in"]) > 0.0
		# Demand marker: the destination this queue is stuck on, so the next
		# line can be aimed at it instead of guessed.
		var demand: Label3D = node.get_node("Demand")
		var wanted := metro.stranded_kind(int(station["id"]))
		var stuck := wanted >= 0 and metro.service_state(int(station["id"])) == Metro.Service.BLOCKED
		demand.visible = stuck
		if stuck:
			var flag := "⚠ %s" % Metro.type_glyph(wanted)
			if demand.text != flag:
				demand.text = flag


func _make_station_node() -> Node3D:
	var root := Node3D.new()
	_station_root.add_child(root)

	var base := MeshInstance3D.new()
	base.name = "Base"
	base.material_override = WorldScreen.standard_material(Color("dfe6f0"))
	root.add_child(base)

	var symbol := Node3D.new()
	symbol.name = "Symbol"
	symbol.position = Vector3(0.0, SYMBOL_Y, 0.0)
	root.add_child(symbol)

	var body := MeshInstance3D.new()
	body.name = "Body"
	body.mesh = _symbol_meshes[Metro.Symbol.ROUND]
	symbol.add_child(body)

	var extra := MeshInstance3D.new()
	extra.name = "Extra"
	extra.mesh = _symbol_meshes[Metro.Symbol.SQUARE]
	extra.rotation = Vector3(0.0, 0.0, PI * 0.25)
	extra.visible = false
	symbol.add_child(extra)

	root.add_child(_make_glyph("Glyph", GLYPH_Y, 96, 0.0075, 22))
	var ring := MeshInstance3D.new()
	ring.name = "Ring"
	ring.mesh = _meshes["transfer"]
	ring.position = Vector3(0.0, 4.0, 0.0)
	ring.visible = false
	root.add_child(ring)

	var warn := MeshInstance3D.new()
	warn.name = "Warn"
	warn.mesh = _torus_mesh(1.3, 0.1)
	warn.position = Vector3(0.0, 0.16, 0.0)
	warn.visible = false
	warn.material_override = WorldScreen.standard_material(Color("fbbf24"), 1.0)
	root.add_child(warn)

	var changing := Node3D.new()
	changing.name = "Changing"
	changing.position = Vector3(0.0, 4.7, 0.0)
	changing.add_child(_make_glyph("Sign", 0.0, 110, 0.008, 20, Color("fbbf24")))
	changing.visible = false
	root.add_child(changing)

	var demand := _make_glyph("Demand", DEMAND_Y, 110, 0.008, 20, Color("f87171"))
	demand.visible = false
	root.add_child(demand)
	return root


func _make_glyph(node_name: String, height: float, font_size: int, pixel_size: float, outline: int, color := Color.WHITE) -> Label3D:
	var label := Label3D.new()
	label.name = node_name
	label.text = "W"
	label.font = UiTheme.font_bold()
	label.font_size = font_size
	label.pixel_size = pixel_size
	label.position = Vector3(0.0, height, 0.0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.shaded = false
	label.double_sided = true
	label.modulate = color
	label.outline_size = outline
	label.outline_modulate = Color(0.02, 0.03, 0.06, 0.9)
	return label


## Swaps a station between the small halt and the big interchange mesh.
func _apply_building(node: Node3D, interchange: bool, color: Color) -> void:
	var base: MeshInstance3D = node.get_node("Base")
	var wanted: Mesh = _meshes["interchange"] if interchange else _meshes["station"]
	if base.mesh == wanted:
		return
	base.mesh = wanted
	if wanted == null:
		return
	WorldScreen.tint(base, Color("dfe6f0").lerp(color, 0.22))
	base.scale = Vector3.ONE * (0.92 if interchange else 1.0)


static func _torus_mesh(major: float, minor: float) -> TorusMesh:
	var mesh := TorusMesh.new()
	mesh.inner_radius = major - minor
	mesh.outer_radius = major + minor
	mesh.rings = 24
	mesh.ring_segments = 6
	return mesh


# --- lines ------------------------------------------------------------------

## Rebuilds the ribbon of every line flagged dirty by the logic module.
func _sync_lines() -> void:
	var dirty := PackedInt32Array()
	for index in metro.lines.size():
		if int(metro.lines[index].get("dirty", 0)) > 0:
			metro.lines[index]["dirty"] = 0
			dirty.append(index)
	if dirty.is_empty():
		return
	for index in dirty:
		_rebuild_line(index)
	_sync_crossings()


func _ensure_line_nodes(index: int) -> void:
	while _line_meshes.size() <= index:
		_line_meshes.append(null)
		_bead_nodes.append(null)
		_bead_phase.append(0.0)
	if _line_meshes[index] != null:
		return
	var ribbon := MeshInstance3D.new()
	ribbon.material_override = _ribbon_material()
	_line_root.add_child(ribbon)
	_line_meshes[index] = ribbon
	var beads := MultiMeshInstance3D.new()
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	var bead := BoxMesh.new()
	bead.size = Vector3(0.9, 0.1, 0.16)
	multimesh.mesh = bead
	multimesh.instance_count = MAX_BEADS
	multimesh.visible_instance_count = 0
	beads.multimesh = multimesh
	_line_root.add_child(beads)
	_bead_nodes[index] = beads


static func _ribbon_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.65
	mat.metallic = 0.1
	mat.emission_enabled = true
	mat.emission = Color(0.15, 0.15, 0.15)
	mat.emission_energy_multiplier = 0.3
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


## One ribbon mesh with vertex colours: the line colour, orange where a
## provisional crossing has no bridge, raised over bridges and dipped under
## tunnels.
func _rebuild_line(index: int) -> void:
	_ensure_line_nodes(index)
	var ribbon: MeshInstance3D = _line_meshes[index]
	var beads: MultiMeshInstance3D = _bead_nodes[index]
	var line: Dictionary = metro.lines[index]
	var path: PackedVector2Array = line["path"]
	var crossings: Array = line["crossings"]
	var color := Metro.line_color(int(line["color"]))
	if path.size() < 2:
		ribbon.mesh = null
		beads.multimesh.visible_instance_count = 0
		return
	var half := Metro.LINE_HALF_WIDTH
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(path.size() - 1):
		var a := path[i]
		var b := path[i + 1]
		var direction := b - a
		if direction.length_squared() < 0.000001:
			continue
		var side := Vector2(-direction.y, direction.x).normalized() * half
		var ha := _vertex_height(crossings, i)
		var hb := _vertex_height(crossings, i + 1)
		var shade := _segment_tint(crossings, i, color)
		_quad(st,
			Vector3(a.x + side.x, ha, a.y + side.y), shade,
			Vector3(a.x - side.x, ha, a.y - side.y), shade.darkened(0.3),
			Vector3(b.x + side.x, hb, b.y + side.y), shade,
			Vector3(b.x - side.x, hb, b.y - side.y), shade.darkened(0.3))
	st.generate_normals()
	ribbon.mesh = st.commit()
	var bead_mat := StandardMaterial3D.new()
	bead_mat.albedo_color = color.lightened(0.55)
	bead_mat.emission_enabled = true
	bead_mat.emission = color
	bead_mat.emission_energy_multiplier = 1.7
	beads.material_override = bead_mat
	_bead_phase[index] = 0.0


## Height of a path vertex between its two segments, so bridges ramp in and out.
func _vertex_height(crossings: Array, index: int) -> float:
	var before := _segment_height(crossings, index - 1)
	var after := _segment_height(crossings, index)
	if before == Metro.BRIDGE_HEIGHT or after == Metro.BRIDGE_HEIGHT:
		return Metro.BRIDGE_HEIGHT
	if before == Metro.TUNNEL_DEPTH and after == Metro.TUNNEL_DEPTH:
		return Metro.TUNNEL_DEPTH
	return RIBBON_Y


func _segment_height(crossings: Array, segment: int) -> float:
	if segment < 0:
		return RIBBON_Y
	for entry in crossings:
		if int(entry["segment"]) == segment:
			match int(entry["kind"]):
				Metro.Crossing.BRIDGE:
					return Metro.BRIDGE_HEIGHT
				Metro.Crossing.TUNNEL:
					return Metro.TUNNEL_DEPTH
				Metro.Crossing.PROVISIONAL:
					return Metro.BRIDGE_HEIGHT * 0.55
	return RIBBON_Y


func _segment_tint(crossings: Array, segment: int, color: Color) -> Color:
	for entry in crossings:
		if int(entry["segment"]) == segment and int(entry["kind"]) == Metro.Crossing.PROVISIONAL:
			return Color("f97316")
	return color


## Bridge decks under the crossings and tunnel mouths at the ends of a buried
## run. Rebuilt whenever any line changed.
func _sync_crossings() -> void:
	for node in _crossing_props:
		node.queue_free()
	_crossing_props = []
	var bridge: Mesh = _meshes["bridge"]
	var portal: Mesh = _meshes["portal"]
	if bridge == null and portal == null:
		return
	for line in metro.lines:
		var path: PackedVector2Array = line["path"]
		var crossings: Array = line["crossings"]
		if path.size() < 2 or crossings.is_empty():
			continue
		for entry in crossings:
			var segment := int(entry["segment"])
			if segment < 0 or segment >= path.size() - 1:
				continue
			var kind := int(entry["kind"])
			var a := path[segment]
			var b := path[segment + 1]
			var dir := (b - a)
			if dir.length_squared() < 0.000001:
				continue
			dir = dir.normalized()
			if kind == Metro.Crossing.TUNNEL:
				_crossing_props.append(_crossing_prop(portal, a, dir, Color("7c8ba1"), Metro.TUNNEL_DEPTH, 1.0))
				_crossing_props.append(_crossing_prop(portal, b, dir, Color("7c8ba1"), Metro.TUNNEL_DEPTH, 1.0))
			else:
				var tint := Color("9aa8b8") if kind == Metro.Crossing.BRIDGE else Color("f97316")
				var mid := (a + b) * 0.5
				var length := clampf(a.distance_to(b) + 1.4, 1.0, 4.0)
				_crossing_props.append(_crossing_prop(bridge, mid, dir, tint, Metro.BRIDGE_HEIGHT - 0.1, length))


func _crossing_prop(mesh: Mesh, at: Vector2, dir: Vector2, color: Color, height: float, length: float) -> Node3D:
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.position = Vector3(at.x, height, at.y)
	node.rotation.y = atan2(dir.x, dir.y)
	node.scale = Vector3(0.85 * length, 1.0, 1.0)
	node.material_override = WorldScreen.standard_material(color)
	_line_root.add_child(node)
	return node


## Fills the empty blocks with city props, skipping water, stations and tracks.
func _place_decor() -> void:
	for node in _decor_nodes:
		node.queue_free()
	_decor_nodes = []
	if _decor_templates.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 4711
	for attempt in DECOR_ATTEMPTS:
		var pos := Vector2(
			rng.randf_range(2.0, Metro.MAP_SIZE.x - 2.0),
			rng.randf_range(2.0, Metro.MAP_SIZE.y - 2.0)
		)
		if metro.in_rivers(pos):
			continue
		if metro.station_at(pos, Metro.STATION_GRAB + 3.0) >= 0:
			continue
		if metro.line_at(pos, 2.4) >= 0:
			continue
		var template: Node3D = _decor_templates[rng.randi() % _decor_templates.size()]
		var node := template.duplicate() as Node3D
		node.scale = Vector3.ONE * rng.randf_range(0.8, 1.6)
		node.position = Vector3(pos.x, 0.0, pos.y)
		node.rotation.y = rng.randf() * TAU
		_scenery.add_child(node)
		_decor_nodes.append(node)


# --- trains -----------------------------------------------------------------

## One node per train: a locomotive plus one car per WAGON_CAPACITY seats.
func _sync_trains() -> void:
	while _train_nodes.size() < metro.trains.size():
		_train_nodes.append(_make_train_node())
	for index in metro.trains.size():
		var train: Dictionary = metro.trains[index]
		var node := _train_nodes[index]
		var line_id := int(train["line"])
		if line_id < 0 or line_id >= metro.lines.size():
			node.visible = false
			continue
		var line: Dictionary = metro.lines[line_id]
		var path: PackedVector2Array = line["path"]
		var cum: PackedFloat32Array = line["cum"]
		if path.size() < 2:
			node.visible = false
			continue
		node.visible = true
		var arc := float(train["arc"])
		var where := Metro.position_at_arc(path, cum, arc)
		var heading := Metro.heading_at_arc(path, cum, arc)
		var height := _segment_height(line["crossings"], int(train["segment"]))
		node.position = Vector3(where.x, height + 0.44, where.y)
		node.rotation.y = atan2(heading.x, heading.y)
		# Match the consist to the capacity.
		var cars := ceili(float(train["capacity"]) / float(Metro.WAGON_CAPACITY))
		var body: Node3D = node.get_node("Body")
		for child in body.get_children():
			if child.name == "Car":
				(child as Node3D).visible = int(child.get_meta("seat", 0)) < cars


func _make_train_node() -> Node3D:
	var root := Node3D.new()
	_train_root.add_child(root)
	var body := Node3D.new()
	body.name = "Body"
	root.add_child(body)

	var loco := MeshInstance3D.new()
	loco.name = "Loco"
	loco.mesh = _meshes["loco"]
	if loco.mesh != null:
		WorldScreen.tint(loco, Color("f8fafc"))
	body.add_child(loco)

	for i in 4:
		var car := MeshInstance3D.new()
		car.name = "Car"
		car.mesh = _meshes["car"]
		car.set_meta("seat", i + 1)
		if car.mesh != null:
			WorldScreen.tint(car, Color("dde5ef"))
		car.position = Vector3(0.0, 0.0, -(2.55 * float(i + 1)))
		car.visible = i < 3
		body.add_child(car)
	return root


# --- crowd ------------------------------------------------------------------

## Every waiting commuter in the city in one MultiMesh, arranged in a ring
## around their station and bobbing gently.
func _sync_crowd() -> void:
	var multimesh := _crowd.multimesh
	var written := 0
	var bob := elapsed * 1.6
	for station in metro.stations:
		var waiting: Array = station["waiting"]
		if waiting.is_empty():
			continue
		var pos: Vector2 = station["pos"]
		var count := waiting.size()
		for slot in count:
			if written >= MAX_CROWD:
				break
			var index := int(waiting[slot])
			var kind := int(metro.passengers[index]["type"])
			# Golden-angle spiral: even coverage whatever the queue length.
			var angle := float(slot) * 2.399963 + float(station["id"])
			var radius := CROWD_RING * sqrt((float(slot) + 0.5) / float(count))
			var offset := Vector2(cos(angle), sin(angle)) * radius
			var height := 0.62 + sin(bob + angle * 3.0) * 0.07
			multimesh.set_instance_transform(written, Transform3D(
				Basis().rotated(Vector3.UP, -angle),
				Vector3(pos.x + offset.x, height, pos.y + offset.y)
			))
			multimesh.set_instance_color(written, Metro.type_color(kind))
			written += 1
	multimesh.visible_instance_count = written


## The direction beads that scroll along every line each frame.
func _update_beads(delta: float) -> void:
	for index in _bead_nodes.size():
		var beads: MultiMeshInstance3D = _bead_nodes[index]
		if beads == null or index >= metro.lines.size():
			continue
		var line: Dictionary = metro.lines[index]
		var path: PackedVector2Array = line["path"]
		var cum: PackedFloat32Array = line["cum"]
		var total := float(line["length"])
		if path.size() < 2 or total <= 0.0:
			beads.multimesh.visible_instance_count = 0
			continue
		var count := clampi(int(total / BEAD_SPACING), 1, MAX_BEADS)
		beads.multimesh.visible_instance_count = count
		var phase := fposmod(_bead_phase[index] + delta * 2.4, total)
		_bead_phase[index] = phase
		for i in count:
			var arc := fposmod(phase + float(i) * (total / float(count)), total)
			var where := Metro.position_at_arc(path, cum, arc)
			var heading := Metro.heading_at_arc(path, cum, arc)
			beads.multimesh.set_instance_transform(i, Transform3D(
				Basis().rotated(Vector3.UP, atan2(heading.x, heading.y)),
				Vector3(where.x, RIBBON_Y + 0.1, where.y)
			))


func _update_sparkles(delta: float) -> void:
	var multimesh := _sparkles.multimesh
	if multimesh == null or metro.rivers.is_empty():
		multimesh.visible_instance_count = 0
		return
	multimesh.visible_instance_count = SPARKLES
	for i in SPARKLES:
		var phase := fposmod(_sparkle_data[i * 3 + 2] + delta * 0.5, TAU)
		_sparkle_data[i * 3 + 2] = phase
		var x: float = _sparkle_data[i * 3] + sin(elapsed * 0.5 + phase) * 1.5
		var z: float = _sparkle_data[i * 3 + 1] + cos(elapsed * 0.42 + phase) * 1.5
		multimesh.set_instance_transform(i, Transform3D(
			Basis().rotated(Vector3.UP, phase),
			Vector3(x, WATER_Y + 0.06, z)
		))


# --- lighting ---------------------------------------------------------------

## Day and night follow the in-game clock, so the city visibly wakes up, the
## commute peaks read as dusk, and night trains glow.
func _update_sky(delta: float) -> void:
	var target := metro.daylight() if metro.running else 0.6
	_light_blend = lerpf(_light_blend, target, clampf(delta * 0.7, 0.0, 1.0))
	var day := clampf(_light_blend, 0.0, 1.0)
	sun.light_color = Color("ff9a5c").lerp(Color(1.0, 0.96, 0.88), day)
	sun.light_energy = 0.25 + day * 0.95
	fill.light_color = Color("3b5b9a").lerp(Color("9ec5ff"), day)
	fill.light_energy = 0.3 + day * 0.35
	var env := environment_node.environment
	env.ambient_light_color = Color("4a6ba8").lerp(Color("bcd8ff"), day)
	env.ambient_light_energy = 0.45 + day * 0.6
	set_fog(Color("070c18").lerp(Color("a9c9f0"), day), 0.005)


# --- HUD --------------------------------------------------------------------

func _build_ui() -> void:
	var panel := Ui.rect(Color(0.031, 0.047, 0.086, 0.72), 12, Color(1, 1, 1, 0.1), 1)
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	panel.offset_left = 12
	panel.offset_right = 292
	panel.offset_top = 66
	panel.offset_bottom = 218
	hud_root.add_child(panel)

	var column := Ui.vbox(2)
	column.position = Vector2(24, 74)
	column.custom_minimum_size = Vector2(256, 0)
	hud_root.add_child(column)
	column.add_child(Ui.label("▣ METROPOL", 20, UiTheme.ACCENT, true))
	_money_label = _value(column, "Einnahmen", "0 $", Color("4ade80"))
	_waiting_label = _value(column, "Wartende", "0", Color("fbbf24"))
	_riding_label = _value(column, "In den Zügen", "0", Color("38bdf8"))
	column.add_child(Ui.label("Satisfaction", 14, UiTheme.TEXT_DIM))
	_happiness = Ui.bar(Color("4ade80"), 14.0)
	_happiness.custom_minimum_size = Vector2(250, 14)
	column.add_child(_happiness)

	var right := Ui.vbox(2)
	right.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	right.position = Vector2(-300, 70)
	right.custom_minimum_size = Vector2(288, 0)
	hud_root.add_child(right)
	_day_label = Ui.label("MO  Day 1", 22, UiTheme.TEXT, true)
	_day_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	right.add_child(_day_label)
	_clock_label = Ui.label("08:00", 30, UiTheme.ACCENT, true)
	_clock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	right.add_child(_clock_label)
	_phase_label = Ui.label("Morning", 16, UiTheme.TEXT_DIM)
	_phase_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	right.add_child(_phase_label)
	# Two forecast lines: what the city is missing now, and what the next
	# commute peak will ask for. Both come from the logic module.
	_demand_label = Ui.label("", 16, UiTheme.DANGER, true)
	_demand_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_demand_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_demand_label.custom_minimum_size = Vector2(288, 0)
	right.add_child(_demand_label)
	_peak_label = Ui.label("", 15, UiTheme.WARNING)
	_peak_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_peak_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_peak_label.custom_minimum_size = Vector2(288, 0)
	right.add_child(_peak_label)

	_critical_panel = Ui.rect(Color(0.32, 0.05, 0.05, 0.88), 10, Color("ef4444"), 2)
	_critical_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_critical_panel.position = Vector2(-170, 68)
	_critical_panel.size = Vector2(340, 42)
	_critical_panel.visible = false
	hud_root.add_child(_critical_panel)
	_critical_label = Ui.label("", 17, Color("fecaca"), true)
	_critical_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_critical_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_critical_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_critical_panel.add_child(_critical_label)

	_build_resource_chips()
	_build_tool_row()

	var hint := Ui.label("Tap stations to chain them  ·  tapping the first station again closes a loop", 14, UiTheme.TEXT_DIM)
	hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	hint.position = Vector2(0, -58)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud_root.add_child(hint)

	_build_inspector()
	_set_tool(Tool.BUILD)


func _value(parent: VBoxContainer, caption: String, value: String, color: Color) -> Label:
	var line := Ui.hbox(8)
	parent.add_child(line)
	line.add_child(Ui.label(caption, 15, UiTheme.TEXT_DIM))
	var spacer := Ui.spacer()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(spacer)
	var result := Ui.label(value, 20, color, true)
	line.add_child(result)
	return result


func _build_resource_chips() -> void:
	var row := Ui.hbox(8)
	row.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	row.position = Vector2(12, 226)
	hud_root.add_child(row)
	var chips: Array[Dictionary] = [
		{"icon": "▤", "caption": "Loks", "color": UiTheme.SUCCESS},
		{"icon": "▥", "caption": "Wagen", "color": UiTheme.SUCCESS},
		{"icon": "⌒", "caption": "Brücken", "color": UiTheme.WARNING},
		{"icon": "◠", "caption": "Tunnel", "color": UiTheme.WARNING},
		{"icon": "▣", "caption": "Linien", "color": UiTheme.ACCENT},
		{"icon": "⇄", "caption": "Umstiege", "color": Color("a855f7")},
	]
	for chip in chips:
		var cell := Ui.rect(Color(0.031, 0.047, 0.086, 0.8), 10, Color(1, 1, 1, 0.1), 1)
		cell.custom_minimum_size = Vector2(100, 56)
		row.add_child(cell)
		var inner := Ui.vbox(0)
		inner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		inner.offset_left = 9
		inner.offset_right = -9
		inner.offset_top = 5
		inner.offset_bottom = -4
		cell.add_child(inner)
		var head := Ui.hbox(5)
		inner.add_child(head)
		head.add_child(Ui.label(str(chip["icon"]), 15, Color(chip["color"]), true))
		head.add_child(Ui.label(str(chip["caption"]), 13, UiTheme.TEXT_DIM))
		var value_label := Ui.label("0", 22, Color(chip["color"]), true)
		inner.add_child(value_label)
		_resource_values.append(value_label)


func _build_tool_row() -> void:
	var row := Ui.hbox(8)
	row.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	row.position = Vector2(16, -112)
	hud_root.add_child(row)
	var entries: Array[Dictionary] = [
		{"text": "▣ Build", "tool": Tool.BUILD, "accent": UiTheme.ACCENT},
		{"text": "▤ Local", "tool": Tool.TRAIN, "accent": UiTheme.SUCCESS},
		{"text": "▥ Car", "tool": Tool.WAGON, "accent": UiTheme.SUCCESS},
		{"text": "✂ Harvest", "tool": Tool.REMOVE, "accent": UiTheme.DANGER},
	]
	_tool_buttons = []
	for entry in entries:
		var value := int(entry["tool"])
		var button := Ui.button(str(entry["text"]), Vector2(112, 52), UiTheme.PANEL_LIGHT, func() -> void: _set_tool(value))
		row.add_child(button)
		_tool_buttons.append(button)

	var help_button := Ui.button("?", Vector2(52, 52), UiTheme.PANEL_LIGHT, _show_help)
	help_button.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	help_button.position = Vector2(490, -112)
	hud_root.add_child(help_button)

	_finish_button = Ui.button("Done ✓", Vector2(130, 52), UiTheme.WARNING, _finish_drawing)
	_finish_button.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_finish_button.position = Vector2(-292, -112)
	_finish_button.visible = false
	hud_root.add_child(_finish_button)

	_speed_button = Ui.button("1x", Vector2(80, 52), UiTheme.PANEL_LIGHT, _on_speed)
	_speed_button.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_speed_button.position = Vector2(-190, -112)
	hud_root.add_child(_speed_button)

	_pause_button = Ui.button("‖", Vector2(80, 52), UiTheme.PANEL_LIGHT, _on_pause)
	_pause_button.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_pause_button.position = Vector2(-98, -112)
	hud_root.add_child(_pause_button)


func _build_inspector() -> void:
	_inspect_panel = Ui.rect(Color(0.031, 0.047, 0.086, 0.94), 12, Color("38bdf8"), 2)
	_inspect_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_inspect_panel.position = Vector2(-180, 70)
	_inspect_panel.size = Vector2(360, 250)
	_inspect_panel.visible = false
	hud_root.add_child(_inspect_panel)
	var column := Ui.vbox(6)
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	column.offset_left = 18
	column.offset_right = -18
	column.offset_top = 14
	column.offset_bottom = -14
	_inspect_panel.add_child(column)
	_inspect_title = Ui.label("Station", 22, UiTheme.ACCENT, true)
	column.add_child(_inspect_title)
	_inspect_body = Ui.label("", 15, UiTheme.TEXT)
	_inspect_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_inspect_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_inspect_body)
	var row := Ui.hbox(8)
	column.add_child(row)
	_inspect_branch = Ui.button("Branch a line here", Vector2(224, 44), UiTheme.SUCCESS, _branch_from_inspector)
	row.add_child(_inspect_branch)
	row.add_child(Ui.button("Close", Vector2(120, 44), UiTheme.PANEL_LIGHT, func() -> void:
		_inspect_panel.visible = false
		_inspect_station = -1
	))


func _popup_pool() -> void:
	_popup_life.resize(MAX_POPUPS)
	_popup_world.resize(MAX_POPUPS)
	for i in MAX_POPUPS:
		var label := Ui.label("", 19, Color("4ade80"), true)
		label.size = Vector2(120, 26)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.visible = false
		hud_root.add_child(label)
		_popups.append(label)


func _show_popup(text: String, world: Vector2, color: Color) -> void:
	for i in _popups.size():
		if _popup_life[i] > 0.0:
			continue
		_popup_life[i] = POPUP_LIFE
		_popup_world[i] = world
		_popups[i].text = text
		_popups[i].add_theme_color_override("font_color", color)
		_popups[i].visible = true
		return


func _update_popups(delta: float) -> void:
	for i in _popups.size():
		if _popup_life[i] <= 0.0:
			continue
		_popup_life[i] -= delta
		var label := _popups[i]
		if _popup_life[i] <= 0.0:
			label.visible = false
			continue
		var world: Vector2 = _popup_world[i]
		var screen := camera.unproject_position(Vector3(world.x, 2.0, world.y))
		var rise := (1.0 - _popup_life[i] / POPUP_LIFE) * 48.0
		label.position = screen - Vector2(60.0, 0.0) - Vector2(0.0, rise)
		label.modulate = Color(1, 1, 1, clampf(_popup_life[i] / POPUP_LIFE, 0.0, 1.0))


# --- modal layer ------------------------------------------------------------

func _modal_root() -> Control:
	if _modal_layer != null and is_instance_valid(_modal_layer):
		return _modal_layer
	_modal_layer = Control.new()
	_modal_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_modal_layer.mouse_filter = Control.MOUSE_FILTER_STOP
	hud_root.add_child(_modal_layer)
	return _modal_layer


func _close_modal() -> void:
	if _modal_layer != null and is_instance_valid(_modal_layer):
		_modal_layer.queue_free()
	_modal_layer = null


func _show_mode_select() -> void:
	var root := _modal_root()
	root.add_child(Ui.backdrop(0.84))
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var column := Ui.vbox(8)
	center.add_child(column)
	column.add_child(Ui.title("▣ METROPOL", 46, UiTheme.ACCENT))
	var intro := Ui.label("Build a subway network that keeps a growing city alive.", 17, UiTheme.TEXT_DIM)
	intro.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(intro)
	for mode in [Metro.Mode.NORMAL, Metro.Mode.ENDLESS, Metro.Mode.EXTREME]:
		var value := int(mode)
		column.add_child(Ui.button(Metro.mode_name(value), Vector2(380, 54), UiTheme.PANEL_LIGHT, func() -> void:
			_start_run(value)
		))
		var hint := Ui.label(Metro.mode_hint(value), 14, UiTheme.TEXT_MUTED)
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		column.add_child(hint)


func _show_help() -> void:
	var root := _modal_root()
	root.add_child(Ui.backdrop(0.88))
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var panel := Ui.panel(UiTheme.PANEL, UiTheme.BORDER, 14)
	center.add_child(panel)
	var column := Ui.vbox(7)
	column.custom_minimum_size = Vector2(600, 0)
	panel.add_child(column)
	column.add_child(Ui.title("How to play", 32, UiTheme.ACCENT))
	var lines: Array[String] = [
		"▪ Jeder Fahrgast will zu einer Station des gleichen Typs. Farbe und Symbol zeigen den Typ, der Buchstabe steht für den genauen Zielort.",
		"▪ ▣ Bauen: Station antippen, dann die weiteren Stationen antippen. Den ersten Bahnhof erneut antippen schließt einen Ring. Auf leere Fläche tippen beendet die Linie.",
		"▪ Tippen auf eine Station mit Linienanschluss öffnet die Ansicht — von dort kannst du eine Linie dorthin verzweigen.",
		"▪ ▤ Lok: Werkzeug wählen, dann auf eine Linie tippen. Beim Bauen einer Linie wird automatisch eine Lok eingesetzt, solange das Depot eine hergibt.",
		"▪ ▥ Wagen: Werkzeug wählen, dann auf einen Zug tippen. Jeder Wagen bringt %d Sitzplätze." % Metro.WAGON_CAPACITY,
		"▪ ✂ Abbau: Linie oder Zug antippen, um sie zu entfernen. Im Extrem-Modus ist das gesperrt.",
		"▪ Flüsse lassen sich nur mit Brücke oder Tunnel überqueren. Fehlt beides, entsteht eine provisorische Brücke — die Züge fahren dort nur halb so schnell.",
		"▪ Zwei Linien an einem Bahnhof ergeben einen Streckenknoten. Dort dürfen Fahrgäste umsteigen, sofern sie eine Umstiegsfreigabe haben.",
		"▪ Bedarfsprognose: über einem Bahnhof steht ⚠ mit dem Zielort, den niemand erreichen kann. Oben rechts steht, was die Stadt gerade vermisst und was der nächste Berufsverkehr verlangt — baue die fehlende Linie, bevor die Warteschlange steht.",
		"▪ Alle %d Tage gibt es Karten, zusätzlich jede Woche ein Bonus. Uhrzeit und Wochentag bestimmen, wohin die Menschen wollen." % Metro.CARD_INTERVAL_DAYS,
		"▪ Bleibt ein Bahnhof %d Sekunden mit mehr als %d Wartenden stehen, kollabiert das Netz." % [int(Metro.OVERCROWD_LIMIT), Metro.STATION_CAPACITY],
		"▪ Schnell und pünktlich bringt Bonus: Wer unter %d Sekunden wartet, zahlt zusätzlich — und eine Serie lohnt sich immer mehr." % int(Metro.PUNCTUAL_WAIT),
		"▪ Kamera: ziehen verschiebt, zwei Finger zoomen und drehen, Mausrad zoomt, Q und E drehen, R zeigt die ganze Stadt.",
	]
	for text in lines:
		var label := Ui.label(text, 15, UiTheme.TEXT)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.custom_minimum_size = Vector2(600, 0)
		column.add_child(label)
	var row := Ui.hbox(8)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_child(row)
	row.add_child(Ui.button("Got it", Vector2(200, 48), UiTheme.ACCENT, func() -> void:
		_close_modal()
	))
	if _started:
		row.add_child(Ui.button("Lobby", Vector2(160, 48), UiTheme.PANEL_LIGHT, func() -> void: Router.to_lobby()))


func _show_cards(modal: Dictionary) -> void:
	var root := _modal_root()
	root.add_child(Ui.backdrop(0.82))
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var column := Ui.vbox(12)
	center.add_child(column)
	column.add_child(Ui.title(str(modal["title"]), 36, UiTheme.WARNING))
	var hint := Ui.label(str(modal.get("hint", "")), 16, UiTheme.TEXT_DIM)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(hint)
	var row := Ui.hbox(12)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_child(row)
	for option in modal["options"]:
		var kind := str(option["kind"])
		var card := Ui.button("", Vector2(196, 156), UiTheme.PANEL_LIGHT, func() -> void:
			metro.choose_card(kind)
			_close_modal()
			_refresh_resources()
		)
		var inner := Ui.vbox(4)
		inner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		inner.alignment = BoxContainer.ALIGNMENT_CENTER
		card.add_child(inner)
		var icon := Ui.label(_card_icon(kind), 30, _card_color(kind), true)
		icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		inner.add_child(icon)
		var name_label := Ui.label(str(option["name"]), 19, UiTheme.TEXT, true)
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		inner.add_child(name_label)
		var hint_label := Ui.label(str(option["hint"]), 13, UiTheme.TEXT_DIM)
		hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		inner.add_child(hint_label)
		row.add_child(card)


static func _card_icon(kind: String) -> String:
	match kind:
		"train":
			return "▤"
		"wagon":
			return "▥"
		"line":
			return "▣"
		"bridge":
			return "⌒"
		"tunnel":
			return "◠"
		"transfer":
			return "⇄"
	return "✦"


static func _card_color(kind: String) -> Color:
	match kind:
		"train", "wagon":
			return UiTheme.SUCCESS
		"line":
			return UiTheme.ACCENT
		"bridge", "tunnel":
			return UiTheme.WARNING
	return Color("a855f7")


func _show_game_over(payload: Dictionary) -> void:
	var record := Game.submit_score(Game.HS_METRO, int(payload.get("money", 0)))
	Game.set_number("metro3d/best_days", float(payload.get("days", 1)))
	var root := _modal_root()
	root.add_child(Ui.backdrop(0.88))
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var column := Ui.vbox(7)
	center.add_child(column)
	column.add_child(Ui.title("The network collapsed", 42, UiTheme.DANGER))
	var station_id := int(payload.get("station", -1))
	if station_id >= 0 and station_id < metro.stations.size():
		var sub := Ui.label(Loc.f("%s was over capacity for too long.", [Metro.type_name(int(metro.stations[station_id]["type"]))]), 17, UiTheme.TEXT_DIM)
		sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		column.add_child(sub)
	var money_label := Ui.label(Loc.f("Income: %s $", [Ui.format_number(int(payload.get("money", 0)))]), 30, Color("4ade80"), true)
	money_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(money_label)
	if record:
		var best := Ui.label("New best!", 20, UiTheme.WARNING, true)
		best.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		column.add_child(best)
	column.add_child(_centered("Zugestellt %d   ·   Pünktlich %d   ·   Beste Serie %d" % [
		int(payload.get("delivered", 0)),
		int(payload.get("punctual", 0)),
		int(payload.get("best_streak", 0)),
	], 17, UiTheme.TEXT))
	column.add_child(_centered("Überlebt %s   ·   Tage %d   ·   Linien %d   ·   Züge %d" % [
		metro.survival_text(),
		int(payload.get("days", 1)),
		int(payload.get("lines", 0)),
		int(payload.get("trains", 0)),
	], 17, UiTheme.TEXT_DIM))
	var row := Ui.hbox(10)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_child(row)
	row.add_child(Ui.button("New network", Vector2(200, 52), UiTheme.ACCENT, func() -> void: Router.go_to(screen_id)))
	row.add_child(Ui.button("Lobby", Vector2(160, 52), UiTheme.PANEL_LIGHT, func() -> void: Router.to_lobby()))


func _centered(text: String, size: int, color: Color) -> Label:
	var label := Ui.label(text, size, color)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return label


# --- rivers -----------------------------------------------------------------

## Triangulates the water polygons as fans around their centroid; the ribbons
## are convex enough for that.
func _build_rivers() -> void:
	for child in _water_root.get_children():
		if child != _sparkles:
			child.queue_free()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.16, 0.42, 0.62, 0.8)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.12
	mat.metallic = 0.35
	mat.emission_enabled = true
	mat.emission = Color(0.1, 0.3, 0.45)
	mat.emission_energy_multiplier = 0.35
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	for river in metro.rivers:
		if river.size() < 3:
			continue
		var centroid := Vector2.ZERO
		for point in river:
			centroid += point
		centroid /= float(river.size())
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for i in river.size():
			var a := river[i]
			var b := river[(i + 1) % river.size()]
			_tri(st, Vector3(centroid.x, WATER_Y, centroid.y), Vector3(a.x, WATER_Y, a.y), Vector3(b.x, WATER_Y, b.y))
		st.generate_normals()
		var node := MeshInstance3D.new()
		node.mesh = st.commit()
		node.material_override = mat
		_water_root.add_child(node)


# --- input ------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not _started or metro.over or _modal_layer != null:
		return
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			_pointer_down(touch.index, touch.position)
		else:
			_pointer_up(touch.index)
		return
	if event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		_pointer_move(drag.index, drag.position)
		return
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_LEFT:
			if button.pressed:
				_pointer_down(0, button.position)
			else:
				_pointer_up(0)
			return
		if button.button_index == MOUSE_BUTTON_WHEEL_UP and button.pressed:
			_zoom(0.9)
			return
		if button.button_index == MOUSE_BUTTON_WHEEL_DOWN and button.pressed:
			_zoom(1.1)
			return
		return
	if event is InputEventMouseMotion and _pointers.has(0):
		_pointer_move(0, (event as InputEventMouseMotion).position)
		return
	if event is InputEventKey and event.is_pressed():
		_key(event as InputEventKey)


func _key(key: InputEventKey) -> void:
	match key.keycode:
		KEY_1:
			_set_tool(Tool.BUILD)
		KEY_2:
			_set_tool(Tool.TRAIN)
		KEY_3:
			_set_tool(Tool.WAGON)
		KEY_4:
			_set_tool(Tool.REMOVE)
		KEY_SPACE:
			_on_pause()
		KEY_TAB:
			_on_speed()
		KEY_ESCAPE:
			_finish_drawing()
		KEY_R:
			_frame_city()
		KEY_F:
			_zoom(0.8)
		KEY_Q:
			cam_yaw -= CAM_YAW_STEP
		KEY_E:
			cam_yaw += CAM_YAW_STEP


func _pointer_down(index: int, position: Vector2) -> void:
	_pointers[index] = position
	_pointer_start[index] = position
	if _pointers.size() >= 2:
		_begin_gesture()
	else:
		_gesture = false
		_dragged = false


func _pointer_move(index: int, position: Vector2) -> void:
	if not _pointers.has(index):
		return
	var previous: Vector2 = _pointers[index]
	_pointers[index] = position
	if _pointer_start[index].distance_to(position) > TAP_SLOP:
		_dragged = true
	if _pointers.size() >= 2:
		_update_gesture()
	elif _dragged:
		_pan_by((previous - position) * PAN_SPEED * (cam_distance / CAM_MIN_DISTANCE))


func _pointer_up(index: int) -> void:
	# The position has to be read before the pointer is dropped, otherwise the
	# tap lands wherever the last drag happened to end.
	var was_tap := _pointers.has(index) and not _dragged
	var tapped := _screen_to_ground(_pointers[index]) if was_tap else Vector2.ZERO
	_pointers.erase(index)
	_pointer_start.erase(index)
	if _pointers.size() >= 2:
		_begin_gesture()
	else:
		_gesture = false
	if was_tap and _started and not metro.over and _modal_layer == null:
		_on_tap_at(tapped)


func _screen_to_ground(screen_position: Vector2) -> Vector2:
	var from := camera.project_ray_origin(screen_position)
	var direction := camera.project_ray_normal(screen_position)
	if absf(direction.y) < 0.0001:
		return Vector2(cam_focus.x, cam_focus.z)
	var distance := (GROUND_Y - from.y) / direction.y
	if distance < 0.0:
		return Vector2(cam_focus.x, cam_focus.z)
	var hit := from + direction * distance
	return Vector2(hit.x, hit.z)


func _begin_gesture() -> void:
	var keys := _pointers.keys()
	if keys.size() < 2:
		return
	var a: Vector2 = _pointers[keys[0]]
	var b: Vector2 = _pointers[keys[1]]
	_gesture = true
	_gesture_span = maxf(a.distance_to(b), 1.0)
	_gesture_angle = atan2(b.y - a.y, b.x - a.x)
	_gesture_mid = (a + b) * 0.5
	_dragged = true


func _update_gesture() -> void:
	var keys := _pointers.keys()
	if keys.size() < 2 or not _gesture:
		return
	var a: Vector2 = _pointers[keys[0]]
	var b: Vector2 = _pointers[keys[1]]
	var span := maxf(a.distance_to(b), 1.0)
	var angle := atan2(b.y - a.y, b.x - a.x)
	_zoom(_gesture_span / span)
	cam_yaw -= angle - _gesture_angle
	_gesture_angle = angle
	var mid := (a + b) * 0.5
	_pan_by((_gesture_mid - mid) * PAN_SPEED * (cam_distance / CAM_MIN_DISTANCE))
	_gesture_mid = mid


## Moves the focus point on the ground plane along the screen axes.
func _pan_by(screen_delta: Vector2) -> void:
	var forward := Vector3(sin(cam_yaw), 0.0, cos(cam_yaw))
	var right := Vector3(forward.z, 0.0, -forward.x)
	var focus := cam_focus - forward * screen_delta.y + right * screen_delta.x
	focus.x = clampf(focus.x, -16.0, Metro.MAP_SIZE.x + 16.0)
	focus.z = clampf(focus.z, -16.0, Metro.MAP_SIZE.y + 16.0)
	cam_focus = focus


func _zoom(factor: float) -> void:
	cam_distance = clampf(cam_distance * factor, CAM_MIN_DISTANCE, CAM_MAX_DISTANCE)


func _frame_city() -> void:
	cam_focus = Vector3(Metro.MAP_SIZE.x * 0.5, 0.0, Metro.MAP_SIZE.y * 0.5)
	cam_distance = CAM_DEFAULT_DISTANCE
	cam_yaw = 0.0


func _apply_camera(weight: float) -> void:
	var horizontal := cos(CAM_PITCH) * cam_distance
	var goal := cam_focus + Vector3(
		sin(cam_yaw) * horizontal,
		sin(CAM_PITCH) * cam_distance,
		cos(cam_yaw) * horizontal
	)
	camera.position = camera.position.lerp(goal, clampf(weight, 0.0, 1.0))
	camera.look_at(cam_focus, Vector3.UP)


# --- tools ------------------------------------------------------------------

func _set_tool(value: int) -> void:
	tool = value
	_finish_drawing()
	var accents: Array[Color] = [UiTheme.ACCENT, UiTheme.SUCCESS, UiTheme.SUCCESS, UiTheme.DANGER]
	for index in _tool_buttons.size():
		var active := index == tool
		_tool_buttons[index].modulate = Color.WHITE if active else Color(0.6, 0.64, 0.7)
		_tool_buttons[index].add_theme_stylebox_override("normal", UiTheme.flat(
			accents[index] if active else UiTheme.PANEL_LIGHT,
			accents[index] if active else UiTheme.BORDER,
			10
		))


func _on_speed() -> void:
	metro.cycle_speed()
	_speed_button.text = Metro.speed_name(metro.speed_index)
	Sfx.select()


func _on_pause() -> void:
	metro.running = not metro.running
	_pause_button.text = "▶" if not metro.running else "‖"
	Sfx.select()


## The whole interaction for one tap on the map.
func _on_tap_at(screen_position: Vector2) -> void:
	var world := _screen_to_ground(screen_position)
	match tool:
		Tool.BUILD:
			_tap_build(world)
		Tool.TRAIN:
			_tap_train(world)
		Tool.WAGON:
			_tap_wagon(world)
		Tool.REMOVE:
			_tap_remove(world)


func _tap_build(world: Vector2) -> void:
	var station := metro.station_at(world, Metro.STATION_GRAB + 2.0)
	# Continuing a line that is already being chained.
	if drawing_line >= 0 and drawing_line < metro.lines.size():
		if station < 0:
			_finish_drawing()
			return
		var sequence: Array = metro.lines[drawing_line]["stations"]
		if sequence.size() >= 3 and int(sequence[0]) == station:
			metro.extend_line(drawing_line, station)
			_finish_drawing()
			_say("Ringlinie geschlossen", UiTheme.SUCCESS)
			return
		if not sequence.has(station):
			metro.extend_line(drawing_line, station)
			Sfx.select()
			_refresh_resources()
			return
		# Tapping the tip again ends the line.
		_finish_drawing()
		return
	if station < 0:
		return
	# A station that already has a line opens the inspector instead.
	if not metro.lines_at_station(station).is_empty():
		_open_inspector(station)
		return
	if not metro.can_create_new_line():
		_say("Keine Linienfarbe mehr frei", UiTheme.DANGER)
		Sfx.hurt()
		return
	var line_id := metro.begin_line(station)
	if line_id < 0:
		return
	drawing_line = line_id
	_finish_button.visible = true
	Sfx.select()
	_say("Weiteren Bahnhof antippen", UiTheme.ACCENT)


## Closes off the line the player was chaining, or reroutes the one the
## inspector selected.
func _finish_drawing() -> void:
	_finish_button.visible = false
	var line_id := drawing_line
	drawing_line = -1
	if line_id < 0 or line_id >= metro.lines.size():
		return
	var built := (metro.lines[line_id]["stations"] as Array).size() >= 2
	metro.finish_line(line_id)
	_mark_all_dirty()
	_refresh_resources()
	if built:
		Sfx.select()
		_say("Linie %s gebaut" % Metro.line_color_name(int(metro.lines[line_id]["color"])), UiTheme.SUCCESS)
	else:
		_place_decor()


func _branch_from_inspector() -> void:
	if _inspect_station < 0:
		return
	var station := _inspect_station
	var serving := metro.lines_at_station(station)
	if serving.is_empty():
		_say("Hier fährt noch keine Linie", UiTheme.WARNING)
		return
	for line_id in serving:
		if metro.begin_line_with(line_id, station):
			drawing_line = line_id
			_finish_button.visible = true
			_inspect_panel.visible = false
			_mark_all_dirty()
			_refresh_resources()
			_say("Linie %s verzweigt" % Metro.line_color_name(int(metro.lines[line_id]["color"])), UiTheme.ACCENT)
			return
	_say("Im Extrem-Modus bleibt die Linie stehen", UiTheme.DANGER)
	Sfx.hurt()


func _tap_train(world: Vector2) -> void:
	if metro.trains_available() <= 0:
		_say("Keine Lokomotive im Depot", UiTheme.DANGER)
		Sfx.hurt()
		return
	var line := metro.line_at(world, 3.0)
	if line < 0:
		_say("Tippe auf eine Linie", UiTheme.TEXT_DIM)
		return
	if metro.add_train(line):
		Sfx.select()
		_say("Lokomotive eingesetzt", UiTheme.SUCCESS)
		_refresh_resources()
	else:
		_say("Diese Linie ist zu kurz", UiTheme.DANGER)


func _tap_wagon(world: Vector2) -> void:
	if int(metro.resources["wagons"]) <= 0:
		_say("Kein Beiwagen im Depot", UiTheme.DANGER)
		Sfx.hurt()
		return
	var train := metro.train_at(world, 4.0)
	if train < 0:
		_say("Tippe auf einen Zug", UiTheme.TEXT_DIM)
		return
	if metro.add_wagon(train):
		Sfx.coin()
		_say("+%d Sitzplätze" % Metro.WAGON_CAPACITY, UiTheme.SUCCESS)
		_refresh_resources()


func _tap_remove(world: Vector2) -> void:
	if metro.mode == Metro.Mode.EXTREME:
		_say("Im Extrem-Modus bleibt alles stehen", UiTheme.DANGER)
		return
	var train := metro.train_at(world, 4.0)
	if train >= 0 and metro.scrap_train(train):
		Sfx.hit()
		_say("Zug ausgemustert", UiTheme.WARNING)
		_refresh_resources()
		return
	var line := metro.line_at(world, 3.0)
	if line < 0:
		return
	var color := int(metro.lines[line]["color"])
	if metro.remove_line(line):
		Sfx.hit()
		_say("Linie %s abgerissen" % Metro.line_color_name(color), UiTheme.WARNING)
		_mark_all_dirty()
		_place_decor()
		_refresh_resources()


## Parallel offsets at shared stations change whenever any line changes, so all
## ribbons are rebuilt — there are at most a handful of them.
func _mark_all_dirty() -> void:
	for line in metro.lines:
		line["dirty"] = 1


# --- inspector --------------------------------------------------------------

## The exact destination breakdown a player needs when a train refuses to pick
## somebody up.
func _open_inspector(station_id: int) -> void:
	_inspect_station = station_id
	_inspect_panel.visible = true
	_fill_inspector(station_id)


func _fill_inspector(station_id: int) -> void:
	var station: Dictionary = metro.stations[station_id]
	var kind := int(station["type"])
	_inspect_title.text = "%s  %s" % [Metro.type_glyph(kind), Metro.type_name(kind)]
	var lines: Array[String] = []
	var queue := (station["waiting"] as Array).size()
	var stranded := metro.stranded_at(station_id)
	# Largest group first, each with the answer to "does any of my lines get me
	# there?" — a × means the queue has no way out.
	for entry in metro.forecast(station_id):
		var target := int(entry["kind"])
		lines.append("%s %s ×%d  %s" % [
			Metro.type_glyph(target),
			Metro.type_name(target),
			int(entry["want"]),
			"✓" if bool(entry["route"]) else "×",
		])
	if lines.is_empty():
		lines.append("Keine Wartenden.")
	lines.append("")
	lines.append("Wartende %d von %d" % [queue, metro.capacity_of(station_id)])
	lines.append("Anschluss %d von %d" % [queue - stranded, queue])
	if stranded >= Metro.STRANDED_MIN:
		lines.append("⚠ %d Fahrgäste kommen hier nicht weg." % stranded)
	var served := metro.lines_at_station(station_id)
	lines.append("Linien %d · Streckenknoten %s" % [served.size(), "ja" if metro.is_transfer(station_id) else "nein"])
	_inspect_body.text = "\n".join(lines)
	var can_branch := metro.mode != Metro.Mode.EXTREME and not served.is_empty()
	_inspect_branch.visible = can_branch


# --- events -----------------------------------------------------------------

func _drain_events() -> void:
	for event in metro.take_events():
		var kind := str(event["kind"])
		var payload: Dictionary = event["payload"]
		match kind:
			"delivered":
				var on_time := bool(payload["on_time"])
				_show_popup("+%d$" % int(payload["money"]), _as_vec2(payload["pos"]),
					Color("4ade80") if on_time else UiTheme.TEXT_DIM)
				if on_time:
					Sfx.coin()
			"transfer":
				_show_popup("⇄", _as_vec2(payload["pos"]), Color("38bdf8"))
			"milestone":
				_say(str(payload["text"]), UiTheme.WARNING)
				Sfx.level_up()
			"rush":
				_say("Rush Hour! Deutlich mehr Fahrgäste", UiTheme.DANGER)
			"rush_over":
				_say("Rush Hour vorbei", UiTheme.TEXT_DIM)
			"new_station":
				_say("Neuer Bahnhof eröffnet", UiTheme.ACCENT)
				_place_decor()
			"shape_warning":
				_say("Ein Bahnhof wechselt bald den Typ", UiTheme.WARNING)
			"overcrowd":
				_say("Bahnhof überfüllt!", UiTheme.DANGER)
				Sfx.hurt()
			"stranded":
				# The demand marker has just appeared over this station.
				_say("Bahnhof ohne Anschluss — %d warten auf %s" % [
					int(payload["count"]), Metro.type_name(int(payload["kind"]))
				], UiTheme.DANGER)
				Sfx.hurt()
			"unmet":
				_say("Niemand fährt zum %s — %d Fahrgäste wollen hin" % [
					Metro.type_name(int(payload["kind"])), int(payload["want"])
				], UiTheme.WARNING)
			"card":
				_say("%s erhalten" % str(payload["name"]), UiTheme.SUCCESS)
				_refresh_resources()
			"over":
				_show_game_over(payload)
	# The next card waits until the world is visible again.
	if not metro.frozen() and _modal_layer == null:
		var modal := metro.next_modal()
		if not modal.is_empty():
			_show_cards(modal)


static func _as_vec2(value: Variant) -> Vector2:
	var out: Vector2 = value
	return out


## Player feedback. `notify` renders the message across the lower third, so the
## severity rides on a leading glyph instead of an extra HUD element.
func _say(text: String, color: Color = UiTheme.TEXT) -> void:
	var glyph := "\u2726"
	if color == UiTheme.DANGER:
		glyph = "\u26a0"
	elif color == UiTheme.SUCCESS:
		glyph = "\u2713"
	elif color == UiTheme.WARNING:
		glyph = "\u2605"
	notify(Loc.f("%s  %s", [glyph, text]), 2.4)


# --- loop -------------------------------------------------------------------

func _update_world(delta: float) -> void:
	var dt: float = minf(delta, 0.05)
	if _started:
		metro.update(dt)
		_drain_events()
		_sync_stations()
		_sync_trains()
		_sync_crowd()
		_sync_lines()
		_update_beads(dt)
		_update_sparkles(dt)
		_update_sky(dt)
		_refresh_hud()
	_update_popups(dt)
	_apply_camera(clampf(dt * 9.0, 0.0, 1.0))


func _refresh_resources() -> void:
	var values: Array[int] = [
		int(metro.resources["trains"]),
		int(metro.resources["wagons"]),
		int(metro.resources["bridges"]),
		int(metro.resources["tunnels"]),
		metro.lines.size(),
		metro.transfer_permits,
	]
	for index in _resource_values.size():
		_resource_values[index].text = str(values[index])


func _refresh_hud() -> void:
	_money_label.text = "%s $" % Ui.format_number(metro.money)
	_waiting_label.text = str(metro.waiting_total)
	_riding_label.text = str(metro.riding_total)
	_day_label.text = metro.day_text()
	_clock_label.text = metro.clock_text()
	var phase := metro.time_of_day_name()
	if metro.rush_active:
		phase = "%s · RUSH" % phase
	_phase_label.text = phase
	_phase_label.add_theme_color_override("font_color", UiTheme.DANGER if metro.rush_active else UiTheme.TEXT_DIM)
	# Bedarfsprognose: the missing line, named.
	_demand_label.text = metro.demand_text()
	_peak_label.text = metro.peak_text()
	var happy := metro.happiness()
	Ui.set_bar(_happiness, happy / 100.0, _mood_color(happy))
	var critical := metro.critical_station()
	if critical >= 0 and not metro.over:
		_critical_panel.visible = true
		_critical_label.text = "⚠ %s: %d wartende · Kollaps in %ds" % [
			Metro.type_name(int(metro.stations[critical]["type"])),
			(metro.stations[critical]["waiting"] as Array).size(),
			ceili(metro.critical_countdown()),
		]
	else:
		_critical_panel.visible = false
	if _inspect_station >= 0 and _inspect_station < metro.stations.size():
		_fill_inspector(_inspect_station)


static func _mood_color(value: float) -> Color:
	if value > 60.0:
		return Color("4ade80")
	if value > 30.0:
		return Color("fbbf24")
	return Color("ef4444")


# --- lifecycle --------------------------------------------------------------

func _start_run(mode: int) -> void:
	_close_modal()
	metro.start(mode)
	_started = true
	_build_rivers()
	_sync_stations()
	_sync_lines()
	_place_decor()
	_frame_city()
	_apply_camera(1.0)
	_refresh_resources()
	_refresh_hud()
	_say("%s-Modus" % Metro.mode_name(mode), UiTheme.ACCENT)
