class_name DragonFlightHatcheryScreen
extends WorldScreen
## The Drachenflug hatchery — a 3D breeding valley.
##
## Dragons stand on pedestals, eggs lie in nests and breeding is done by pairing
## two of them. The interesting part is genetics: every dragon carries two
## alleles per gene, a child inherits one from each parent, and a recessive
## gene only shows when both parents carry it. So a rare dragon has to be bred
## out of two carriers, which is what the pedigree view is for.

const PEDESTALS := 6
const NEST_SPOTS := 4
const PEDESTAL_RADIUS := 7.5

var profile: Dictionary = {}
var parent_a := 0
var parent_b := 0
var now := 0.0
## The trait this pairing is bred for. Set by the player from the chip grid.
var target_trait := "riesenwuchs"

var dragons: Array = []
var nests: Array = []
var pedestals: Array[Dictionary] = []
var hover_uid := 0

var dragon_nodes: Array[Dictionary] = []
var _label_title: Label
var _label_slots: Label
var _label_info: Label
var _label_pedigree: Label
var _label_goal: Label
var _forecast_box: VBoxContainer
var _candidate_box: VBoxContainer
var _target_grid: GridContainer
var _target_chips: Dictionary = {}
var _pair_button: Button
var _lay_button: Button
var _breed_box: VBoxContainer
var _list: VBoxContainer
var _progress: Array[ProgressBar] = []
var _timer := 0.0


func _ready_world() -> void:
	profile = DragonFlight.load_profile()
	now = Time.get_unix_time_from_system()
	_setup_theme()
	_build_valley()
	_build_pedestals()
	_build_nests()
	_build_roost()
	_build_ui()
	_build_target_chips()
	refresh()
	hide_loading()


func _setup_theme() -> void:
	set_fog(Color("cfe8ff"), 0.0022)
	set_ambient(Color("dbeafe"), 0.8)
	sun.light_color = Color("fff4d6")
	sun.light_energy = 1.35
	fill.light_color = Color("a5b4fc")
	fill.light_energy = 0.45
	camera.fov = 52.0
	camera.far = 320.0
	# Shifted right, because the hatchery panel covers the left third of the
	# screen and the pedestals have to stay visible next to it.
	camera.position = Vector3(4.5, 11.0, 20.0)
	camera.look_at(Vector3(3.0, 1.5, -2.0), Vector3.UP)


func _build_valley() -> void:
	var ground := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(90.0, 0.6, 70.0)
	ground.mesh = mesh
	ground.material_override = WorldScreen.standard_material(Color("5f8f4a"))
	ground.position = Vector3(0.0, -0.3, 0.0)
	add_child(ground)

	# A pond gives the middle of the valley something to reflect the sky in.
	var pond := MeshInstance3D.new()
	var pond_mesh := CylinderMesh.new()
	pond_mesh.top_radius = 7.0
	pond_mesh.bottom_radius = 7.0
	pond_mesh.height = 0.12
	pond_mesh.radial_segments = 20
	pond.mesh = pond_mesh
	pond.material_override = WorldScreen.standard_material(Color("38bdf8"), 0.15)
	pond.material_override.roughness = 0.15
	pond.position = Vector3(0.0, 0.02, 13.0)
	add_child(pond)

	for i in 14:
		var tree := WorldScreen.mesh("rpg/pine_tree" if i % 3 else "tree", Color("3f7a34"), randf_range(1.2, 2.4))
		if tree == null:
			continue
		var angle := randf() * TAU
		# Outside the pedestal ring, so a tree never hides a dragon.
		var radius := randf_range(PEDESTAL_RADIUS + 9.0, 40.0)
		tree.position = Vector3(cos(angle) * radius, 0.0, sin(angle) * radius * 0.8 - 6.0)
		add_child(tree)
	for i in 8:
		var rock := WorldScreen.mesh("rpg/rock_small", Color("8a8f98"), randf_range(0.8, 1.8))
		if rock == null:
			continue
		var angle2 := randf() * TAU
		rock.position = Vector3(cos(angle2) * randf_range(11.0, 22.0), 0.0, sin(angle2) * randf_range(9.0, 20.0))
		add_child(rock)


func _build_pedestals() -> void:
	for i in PEDESTALS:
		var angle := TAU * float(i) / float(PEDESTALS)
		var spot := Vector3(cos(angle) * PEDESTAL_RADIUS, 0.0, sin(angle) * PEDESTAL_RADIUS * 0.75 - 2.0)
		var mesh := WorldScreen.mesh("flight/pedestal", Color("94a3b8"), 1.0)
		if mesh == null:
			var box := MeshInstance3D.new()
			var box_mesh := BoxMesh.new()
			box_mesh.size = Vector3(1.2, 1.4, 1.2)
			box.mesh = box_mesh
			box.material_override = WorldScreen.standard_material(Color("94a3b8"))
			mesh = box
		mesh.position = spot
		add_child(mesh)
		pedestals.append({"spot": spot, "node": null, "uid": 0, "ring": null})

		# A coloured ring marks a dragon that is selected as a parent.
		var ring := MeshInstance3D.new()
		var torus := TorusMesh.new()
		torus.inner_radius = 0.85
		torus.outer_radius = 1.05
		torus.rings = 20
		ring.mesh = torus
		ring.material_override = WorldScreen.standard_material(Color("fbbf24"), 1.4)
		ring.position = spot + Vector3(0.0, 0.12, 0.0)
		ring.visible = false
		add_child(ring)
		pedestals[i]["ring"] = ring


func _build_nests() -> void:
	for i in NEST_SPOTS:
		var spot := Vector3(-9.0 + float(i) * 6.0, 0.0, 15.0)
		var nest := WorldScreen.mesh("flight/nest", Color("8b5a2b"), 1.2)
		if nest == null:
			var box := MeshInstance3D.new()
			var box_mesh := BoxMesh.new()
			box_mesh.size = Vector3(1.6, 0.3, 1.6)
			box.mesh = box_mesh
			box.material_override = WorldScreen.standard_material(Color("8b5a2b"))
			nest = box
		nest.position = spot
		add_child(nest)
		var egg_node: Node3D = null
		nests.append({"spot": spot, "nest": nest, "egg": egg_node, "bar": null})


## The player's own dragon perches in the middle, wings slowly moving.
func _build_roost() -> void:
	var roost := WorldScreen.mesh("flight/roost", Color("8b5a2b"), 1.4)
	if roost == null:
		return
	roost.position = Vector3(0.0, 0.0, -8.0)
	add_child(roost)


func _build_ui() -> void:
	var panel := Ui.panel(UiTheme.PANEL, UiTheme.BORDER, 14)
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.position = Vector2(20, 74)
	panel.custom_minimum_size = Vector2(430, 560)
	hud_root.add_child(panel)
	var box := Ui.vbox(6)
	panel.add_child(box)
	_label_title = Ui.label("ZUCHTALLEE", 24, UiTheme.ACCENT, true)
	box.add_child(_label_title)

	# Everything below scrolls, so a long breed list can never reach the button.
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(400, 0)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var body := Ui.vbox(6)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(body)
	box.add_child(scroll)

	_label_slots = Ui.label("", 15, UiTheme.TEXT)
	body.add_child(_label_slots)
	_label_info = Ui.label("", 14, UiTheme.TEXT_DIM)
	_label_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(_label_info)
	_label_pedigree = Ui.label("", 13, UiTheme.TEXT_MUTED)
	_label_pedigree.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(_label_pedigree)
	_pair_button = Ui.button("Paaren", Vector2(400, 48), UiTheme.ACCENT, _on_pair)
	body.add_child(_pair_button)

	# Zuchtziel: which trait this pairing is bred for. The chips are the whole
	# breeding plan in one block, and the list below answers "which two of my
	# dragons can actually produce it".
	body.add_child(Ui.label("Zuchtziel", 16, UiTheme.TEXT, true))
	_target_grid = GridContainer.new()
	_target_grid.columns = 3
	_target_grid.add_theme_constant_override("h_separation", 4)
	_target_grid.add_theme_constant_override("v_separation", 4)
	body.add_child(_target_grid)
	_label_goal = Ui.label("", 14, UiTheme.TEXT)
	_label_goal.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(_label_goal)
	_candidate_box = Ui.vbox(3)
	body.add_child(_candidate_box)

	# Zuchtvorhersage: what the pair that is actually selected will produce.
	body.add_child(Ui.label("Zuchtvorhersage", 16, UiTheme.TEXT, true))
	_forecast_box = Ui.vbox(2)
	body.add_child(_forecast_box)

	body.add_child(Ui.label("Eier im Nest", 17, UiTheme.TEXT, true))
	_list = Ui.vbox(4)
	body.add_child(_list)

	# Egg currency and the breeds that are still missing.
	_lay_button = Ui.button("Ei legen", Vector2(400, 44), UiTheme.PANEL_LIGHT, _on_lay_egg)
	body.add_child(_lay_button)
	_breed_box = Ui.vbox(3)
	body.add_child(_breed_box)

	var back := Ui.button("◀ Hangar", Vector2(160, 46), UiTheme.PANEL_LIGHT, func() -> void:
		Sfx.select()
		Router.go_to("dragonflight")
	)
	back.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	back.position = Vector2(-184, -96)
	hud_root.add_child(back)

	var hint := Ui.label("Tippe einen Sockel an, um ihn als Elternteil zu wählen", 15, UiTheme.TEXT_DIM)
	hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	hint.position = Vector2(0, -104)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud_root.add_child(hint)

	# WorldScreen brings its own `notify()`; nothing to add here.


## One chip per gene. They are built once and only repainted afterwards, so
## changing the goal never rebuilds twelve buttons.
func _build_target_chips() -> void:
	for gene in DragonFlight.TRAITS:
		var id := str(gene["id"])
		var chip := Ui.button(str(gene["name"]), Vector2(130, 32), Color(str(gene["hue"])), _on_pick_target.bind(id))
		chip.add_theme_font_size_override("font_size", 12)
		chip.tooltip_text = "%s · %s" % [str(gene["desc"]), "rezessiv" if bool(gene.get("recessive", false)) else "dominant"]
		_target_grid.add_child(chip)
		_target_chips[id] = chip


## The selected chip keeps its gene colour, the rest fade back — so the current
## breeding goal is readable at a glance even in a list of twelve.
func _paint_target_chips() -> void:
	for id in _target_chips:
		var chip: Button = _target_chips[id]
		var hue := Color(str(DragonFlight.trait_by_id(str(id))["hue"]))
		var selected: bool = str(id) == target_trait
		chip.add_theme_stylebox_override("normal", _chip_box(hue if selected else hue.darkened(0.55),
			hue if selected else UiTheme.BORDER))
		chip.add_theme_color_override("font_color", Color("0b1220") if selected else hue.lightened(0.2))


## A tighter stylebox than `UiTheme.flat`: the chips are small, and the shared
## content margins would eat a third of a 130 px button.
func _chip_box(fill: Color, border: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.set_corner_radius_all(7)
	box.border_color = border
	box.set_border_width_all(2)
	box.content_margin_left = 4
	box.content_margin_right = 4
	box.content_margin_top = 2
	box.content_margin_bottom = 2
	return box


func _on_pick_target(id: String) -> void:
	Sfx.select()
	target_trait = id
	_refresh_panel()


# --- refresh ----------------------------------------------------------------

func refresh() -> void:
	now = Time.get_unix_time_from_system()
	var owned := DragonFlight.dragons_of(profile)
	dragons = owned
	_place_dragons()
	_place_eggs()
	_refresh_panel()
	_refresh_list()


## Puts up to `PEDESTALS` dragons on the pedestals, newest generation first.
func _place_dragons() -> void:
	var sorted: Array = dragons.duplicate()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ga := int(a.get("gen", 1))
		var gb := int(b.get("gen", 1))
		if ga == gb:
			return int(a.get("uid", 0)) > int(b.get("uid", 0))
		return ga > gb
	)
	for i in pedestals.size():
		var spot: Dictionary = pedestals[i]
		if i < sorted.size():
			var dragon: Dictionary = sorted[i]
			spot["uid"] = int(dragon["uid"])
			if spot["node"] == null:
				spot["node"] = _dragon_node(dragon, Vector3(1.0, 1.46, 1.0))
				(spot["node"] as Node3D).position = spot["spot"] + Vector3(0.0, 1.5, 0.0)
			_set_dragon_look(spot["node"], dragon)
			spot["node"].visible = true
		else:
			spot["uid"] = 0
			if spot["node"] != null and is_instance_valid(spot["node"]):
				(spot["node"] as Node3D).visible = false


## Builds a dragon node from its breed mesh, sized and coloured by its genes.
func _dragon_node(dragon: Dictionary, stand: Vector3) -> Node3D:
	var breed := DragonFlight.breed_by_id(str(dragon.get("breed", "ember")))
	var node := Node3D.new()
	var body := WorldScreen.mesh(str(breed["asset"]), Color.WHITE, 1.0)
	if body != null:
		node.add_child(body)
		_tint(body, Color(str(breed["body"])), Color(str(breed["belly"])), Color(str(breed["accent"])))
	else:
		var box := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(1.2, 1.0, 2.2)
		box.mesh = mesh
		box.material_override = WorldScreen.standard_material(Color(str(breed["body"])))
		node.add_child(box)
	add_child(node)
	# Breed size, gene growth and generation all change how big the dragon reads.
	node.scale = Vector3.ONE * DragonFlight.visual_scale(dragon) * stand.y / 1.5
	node.position = Vector3.ZERO
	return node


## Re-applies the body colours, so buying or breeding visibly changes a dragon.
func _set_dragon_look(node: Node, dragon: Dictionary) -> void:
	var breed := DragonFlight.breed_by_id(str(dragon.get("breed", "ember")))
	var scale := DragonFlight.visual_scale(dragon)
	node.scale = Vector3(scale, scale, scale)
	for child in node.get_children():
		_tint(child, Color(str(breed["body"])), Color(str(breed["belly"])), Color(str(breed["accent"])))


func _tint(root: Node, body: Color, belly: Color, accent: Color) -> void:
	for child in root.get_children():
		if child is GeometryInstance3D:
			var geometry := child as GeometryInstance3D
			var part := str(child.name)
			var color := body
			if part.contains("Belly") or part.contains("Jaw") or part.contains("Snout"):
				color = belly
			elif part.contains("Eye") or part.contains("Horn") or part.contains("Spike") or part.contains("Crest") or part.contains("Fin") or part.contains("Strut"):
				color = accent
			geometry.material_override = WorldScreen.standard_material(color, 1.6 if part.contains("Eye") else 0.0)
		_tint(child, body, belly, accent)


func _place_eggs() -> void:
	var eggs := DragonFlight.eggs_of(profile)
	for i in nests.size():
		var nest: Dictionary = nests[i]
		var node: Node3D = nest["egg"]
		if i < eggs.size():
			var dragon: Dictionary = eggs[i]
			if node == null or not is_instance_valid(node):
				var breed := DragonFlight.breed_by_id(str(dragon.get("breed", "ember")))
				node = WorldScreen.mesh(str(breed.get("egg", "flight/egg")), Color(str(breed["eggColor"])), 1.0)
				if node == null:
					node = WorldScreen.mesh("flight/egg", Color(str(breed["eggColor"])), 1.0)
				if node == null:
					var sphere := MeshInstance3D.new()
					var mesh := SphereMesh.new()
					mesh.radius = 0.5
					mesh.height = 1.0
					sphere.mesh = mesh
					sphere.material_override = WorldScreen.standard_material(Color(str(breed["eggColor"])))
					node = sphere
				nest["egg"] = node
				node.position = nest["spot"] + Vector3(0.0, 0.25, 0.0)
				add_child(node)
			node.visible = true
			# A ready egg rocks; an incubating one grows slightly.
			var ready_ratio := 1.0 - DragonFlight.egg_progress(dragon, now)
			node.scale = Vector3.ONE * (0.85 + 0.35 * ready_ratio)
		elif node != null and is_instance_valid(node):
			node.visible = false


func _refresh_panel() -> void:
	var a := DragonFlight.dragon_by_uid(profile, parent_a)
	var b := DragonFlight.dragon_by_uid(profile, parent_b)
	_label_slots.text = "Elternteil A: %s\nElternteil B: %s" % [_dragon_label(a), _dragon_label(b)]
	var cost := 0
	if not a.is_empty() and not b.is_empty() and parent_a != parent_b:
		cost = DragonFlight.pairing_cost(a, b)
		_label_info.text = "Kosten %d ◈" % cost
		_pair_button.disabled = int(profile.get("gold", 0)) < cost
		_pair_button.text = "Paaren (%d ◈)" % cost
	else:
		_label_info.text = "Wähle zwei verschiedene Drachen auf den Sockeln."
		_pair_button.disabled = true
		_pair_button.text = "Paaren"
	for spot in pedestals:
		var ring: MeshInstance3D = spot["ring"]
		ring.visible = int(spot["uid"]) != 0 and (int(spot["uid"]) == parent_a or int(spot["uid"]) == parent_b)
	_refresh_pedigree()
	_refresh_goal()
	_refresh_forecast(a, b)
	_refresh_egg_button()
	_refresh_breeds()


## The goal line and the list of dragons that can serve it. This is what turns
## breeding from a blind roll into a plan: the roster says which dragons carry
## the gene, and `best_pair()` names the two that give the best odds.
func _refresh_goal() -> void:
	_paint_target_chips()
	var gene := DragonFlight.trait_by_id(target_trait)
	var recessive: bool = bool(gene.get("recessive", false))
	var carriers := DragonFlight.goal_carriers(profile, target_trait)
	var needed := 2 if recessive else 1
	var lines: Array[String] = ["Ziel: %s · %s · %d von %d Trägern" % [
		str(gene.get("name", target_trait)), "rezessiv" if recessive else "dominant",
		mini(carriers, needed), needed,
	]]
	var best := DragonFlight.best_pair(profile, target_trait)
	if best.is_empty():
		lines.append("Zu wenige Drachen im Stall.")
		_label_goal.text = "\n".join(lines)
		_refresh_candidates()
		return
	var a: Dictionary = best["a"]
	var b: Dictionary = best["b"]
	lines.append("Beste Paarung: %s (%s) × %s (%s) = %d %%" % [
		_dragon_label(a), DragonFlight.allele_pair(a.get("alleles", {}), target_trait),
		_dragon_label(b), DragonFlight.allele_pair(b.get("alleles", {}), target_trait),
		roundi(float(best["chance"]) * 100.0),
	])
	if float(best["chance"]) <= 0.0:
		lines.append("Kein Paar bringt es — ein zweiter Träger fehlt.")
	_label_goal.text = "\n".join(lines)
	_refresh_candidates()


## Every dragon that helps with the goal, best first. Tapping one selects it as
## a parent, exactly like tapping its pedestal.
func _refresh_candidates() -> void:
	for child in _candidate_box.get_children():
		child.queue_free()
	var candidates := DragonFlight.target_candidates(profile, target_trait, 5)
	if candidates.is_empty():
		_candidate_box.add_child(Ui.label("Keine Drachen im Stall.", 13, UiTheme.TEXT_MUTED))
		return
	var hue := Color(str(DragonFlight.trait_by_id(target_trait)["hue"]))
	for entry in candidates:
		var dragon: Dictionary = entry["dragon"]
		var uid := int(entry["uid"])
		var alleles: Dictionary = dragon.get("alleles", {})
		var state := DragonFlight.gene_state(alleles, target_trait)
		var mark := "zeigt" if state == DragonFlight.GENE_SHOWS else ("Träger" if DragonFlight.is_carrier(alleles, target_trait) else "—")
		var caption := "%s · %s · %s" % [_dragon_label(dragon), DragonFlight.allele_pair(alleles, target_trait), mark]
		if uid == parent_a:
			caption = "A · " + caption
		elif uid == parent_b:
			caption = "B · " + caption
		# The gene's own colour, so the list belongs to the chosen goal.
		_candidate_box.add_child(Ui.button(caption, Vector2(400, 32), hue.darkened(0.74), _on_pick_candidate.bind(uid)))


func _on_pick_candidate(uid: int) -> void:
	_assign_parent(uid)
	_refresh_panel()


## Shared by the pedestals and the candidate list. The first pick fills A, a
## second different dragon fills B, and tapping a selected dragon again drops
## it — so a mis-tap is always recoverable. (Before, a second pick overwrote A,
## which meant B could never be filled and breeding was unreachable by tapping.)
func _assign_parent(uid: int) -> void:
	if uid == 0:
		return
	if parent_a == 0:
		parent_a = uid
	elif uid == parent_a:
		parent_a = 0
	elif parent_b == 0:
		parent_b = uid
	elif uid == parent_b:
		parent_b = 0
	else:
		parent_b = uid
	Sfx.select()


## Ancestry of the first selected parent, so a bred dragon can be traced back.
func _refresh_pedigree() -> void:
	var dragon := DragonFlight.dragon_by_uid(profile, parent_a)
	if dragon.is_empty():
		_label_pedigree.text = ""
		return
	var line := "A · %s" % _dragon_label(dragon)
	var parents := DragonFlight.parent_uids(dragon)
	if parents.is_empty():
		line += "  ·  Stammlinie"
	else:
		var names: Array[String] = []
		for uid in parents:
			var parent := DragonFlight.dragon_by_uid(profile, int(uid))
			names.append(_dragon_label(parent) if not parent.is_empty() else "?")
		line += "  ·  Eltern: %s" % ", ".join(names)
	var ancestors := DragonFlight.ancestors(profile, int(dragon["uid"]), 2)
	if not ancestors.is_empty():
		var older: Array[String] = []
		for entry in ancestors:
			older.append(_dragon_label(entry))
		line += "  ·  Vorfahren: %s" % ", ".join(older)
	_label_pedigree.text = line


## The breeding forecast: every trait with the chance this exact pair produces
## it. The top entries are the traits worth pairing for.
func _refresh_forecast(a: Dictionary, b: Dictionary) -> void:
	for child in _forecast_box.get_children():
		child.queue_free()
	if a.is_empty() or b.is_empty() or parent_a == parent_b:
		_forecast_box.add_child(Ui.label("Noch kein Paar gewählt.", 14, UiTheme.TEXT_MUTED))
		return
	var forecast := DragonFlight.breeding_forecast(a, b)
	# The goal the player picked comes first, the rest stays sorted by chance:
	# without this the trait they are actually chasing could be cut off the
	# seven-row tail entirely.
	var ordered: Array[Dictionary] = []
	for entry in forecast:
		if str(entry["id"]) == target_trait:
			ordered.append(entry)
	for entry in forecast:
		if str(entry["id"]) != target_trait:
			ordered.append(entry)
	# Only the interesting tail: things likely, and things worth chasing.
	var shown := 0
	for entry in ordered:
		var chance := float(entry["chance"])
		var is_goal: bool = str(entry["id"]) == target_trait
		if chance < 0.05 and not is_goal:
			continue
		shown += 1
		if shown > 7:
			break
		var row := Ui.vbox(0)
		_forecast_box.add_child(row)
		var head := Ui.hbox(6)
		row.add_child(head)
		head.add_child(Ui.rect(Color(str(entry["hue"])), 10, Color(0, 0, 0, 0), 0))
		head.add_child(Ui.label(str(entry["name"]) if not is_goal else "▶ " + str(entry["name"]),
			14, Color(str(entry["hue"])), true))
		head.add_child(Ui.spacer())
		head.add_child(Ui.label("%d %%" % roundi(chance * 100.0), 14, Color.WHITE, true))
		var bar := Ui.bar(Color(str(entry["hue"])), 8.0)
		Ui.set_bar(bar, chance, Color(str(entry["hue"])))
		row.add_child(bar)
		var parents: Array[String] = []
		if bool(entry["a"]):
			parents.append("A")
		if bool(entry["b"]):
			parents.append("B")
		if not parents.is_empty():
			row.add_child(Ui.label("trägt %s" % ", ".join(parents), 11, UiTheme.TEXT_MUTED))


## The egg currency is spent here: every egg lands in a nest and hatches on its
## own, so the currency always has a use.
func _refresh_egg_button() -> void:
	var price := DragonFlight.egg_cost(profile)
	var eggs := int(profile.get("eggs", 0))
	_lay_button.text = "Ei legen (%d Eier, %d ◈)" % [eggs, price]
	_lay_button.disabled = eggs < 1 or int(profile.get("gold", 0)) < price
	var free_nest := _free_nest()
	_lay_button.text = "Ei legen — kein Nest frei" if free_nest < 0 else _lay_button.text
	_lay_button.disabled = _lay_button.disabled or free_nest < 0


func _free_nest() -> int:
	for i in nests.size():
		if i >= DragonFlight.eggs_of(profile).size():
			return i
	return -1


func _on_lay_egg() -> void:
	var price := DragonFlight.egg_cost(profile)
	if int(profile.get("eggs", 0)) < 1 or int(profile.get("gold", 0)) < price:
		notify("Nicht genug Eier oder Gold")
		return
	profile["eggs"] = int(profile["eggs"]) - 1
	profile["gold"] = int(profile["gold"]) - price
	var dragon := DragonFlight.lay_egg(profile, "", 45.0)
	dragon["egg"]["ready_at"] = now + 45.0
	DragonFlight.save_profile(profile)
	Sfx.coin()
	notify("Ein Ei liegt im Nest")
	refresh()


## Breeds the player does not own yet, with their gold price.
func _refresh_breeds() -> void:
	for child in _breed_box.get_children():
		child.queue_free()
	var missing: Array[Dictionary] = []
	for breed in DragonFlight.BREEDS:
		if not DragonFlight.has_breed(profile, str(breed["id"])):
			missing.append(breed)
	if missing.is_empty():
		_breed_box.add_child(Ui.label("Alle Rassen im Stall.", 14, UiTheme.SUCCESS))
		return
	_breed_box.add_child(Ui.label("Rassen kaufen", 16, UiTheme.TEXT, true))
	for breed in missing:
		var id := str(breed["id"])
		var price := DragonFlight.breed_price(id)
		var affordable: bool = int(profile.get("gold", 0)) >= price
		var row := Ui.hbox(6)
		_breed_box.add_child(row)
		row.add_child(Ui.label(str(breed["name"]), 14, Color(str(breed["body"])), true))
		row.add_child(Ui.spacer())
		row.add_child(Ui.button("%d ◈" % price, Vector2(88, 32),
			UiTheme.PANEL_LIGHT if affordable else UiTheme.PANEL, _on_buy_breed.bind(id)))


func _dragon_label(dragon: Dictionary) -> String:
	if dragon.is_empty():
		return "—"
	var breed := DragonFlight.breed_by_id(str(dragon["breed"]))
	return "%s (G%d)" % [str(breed["name"]), int(dragon.get("gen", 1))]


func _refresh_list() -> void:
	for child in _list.get_children():
		child.queue_free()
	_progress.clear()
	var eggs := DragonFlight.eggs_of(profile)
	if eggs.is_empty():
		_list.add_child(Ui.label("Keine Eier im Nest. Fliege level und sammle welche.", 14, UiTheme.TEXT_MUTED))
		return
	for dragon in eggs:
		var breed := DragonFlight.breed_by_id(str(dragon["breed"]))
		var remaining := DragonFlight.egg_remaining(dragon, now)
		var row := Ui.vbox(1)
		_list.add_child(row)
		var head := Ui.hbox(6)
		row.add_child(head)
		head.add_child(Ui.label("%s-Ei" % str(breed["name"]), 15, Color(str(breed["eggColor"])), true))
		head.add_child(Ui.spacer())
		head.add_child(Ui.label("%ds" % roundi(remaining) if remaining > 0.0 else "bereit", 14,
			Color("22c55e") if remaining <= 0.0 else UiTheme.TEXT_DIM))
		var bar := Ui.bar(Color("fbbf24"), 10.0)
		Ui.set_bar(bar, DragonFlight.egg_progress(dragon, now), Color(str(breed["eggColor"])))
		row.add_child(bar)
		_progress.append(bar)
		var readout := DragonFlight.egg_readout(dragon)
		_egg_readout_line(row, readout)
		if remaining > 0.0:
			var cost := DragonFlight.hatch_cost(dragon)
			row.add_child(Ui.button("Ausbrüten für %d ◈" % cost, Vector2(400, 34), UiTheme.PANEL_LIGHT, func() -> void:
				_hatch_now(dragon, cost)
			))
		else:
			row.add_child(Ui.button("Schlüpfen lassen", Vector2(400, 34), UiTheme.SUCCESS, func() -> void:
				_hatch_now(dragon, 0)
			))


## What the egg will hatch as, and what it passes on. The genome is already
## rolled when the egg is laid, so showing it here is not a spoiler but the
## answer to "is this egg worth waiting for" — and a hidden carrier is the one
## thing a hatched dragon can never show on its own.
func _egg_readout_line(row: VBoxContainer, readout: Dictionary) -> void:
	var shown: Array[String] = readout.get("traits", [])
	var carriers: Array[String] = readout.get("carriers", [])
	if shown.is_empty() and carriers.is_empty():
		row.add_child(Ui.label("schlüpft ohne Merkmale", 12, UiTheme.TEXT_MUTED))
		return
	var parts: Array[String] = []
	if not shown.is_empty():
		parts.append("schlüpft mit: %s" % _names(shown))
	else:
		parts.append("schlüpft ohne Merkmale")
	if not carriers.is_empty():
		parts.append("trägt weiter: %s" % _names(carriers))
	if bool(readout.get("rare", false)):
		parts.append("seltenes Gen")
	var text := Ui.label(" · ".join(parts), 12,
		Color("fbbf24") if bool(readout.get("rare", false)) else UiTheme.TEXT_DIM)
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(text)


# --- interaction ------------------------------------------------------------

func _process(delta: float) -> void:
	super._process(delta)
	# The egg list counts down in real time, so refresh it about once a second.
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = 1.0
	if not DragonFlight.eggs_of(profile).is_empty():
		now = Time.get_unix_time_from_system()
		_refresh_list()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed:
		_pick_at((event as InputEventScreenTouch).position)
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		_pick_at((event as InputEventMouseButton).position)


## Screen position → the nearest pedestal within a generous radius.
func _pick_at(screen_point: Vector2) -> void:
	var from := camera.project_ray_origin(screen_point)
	var dir := camera.project_ray_normal(screen_point)
	var best := -1
	var best_distance := 3.4
	for i in pedestals.size():
		var spot: Vector3 = pedestals[i]["spot"]
		var target := spot + Vector3(0.0, 1.5, 0.0)
		var to := target - from
		var along := to.dot(dir)
		if along <= 0.0:
			continue
		var closest := from + dir * along
		var distance := closest.distance_to(target)
		if distance < best_distance:
			best_distance = distance
			best = i
	if best < 0:
		return
	var uid := int(pedestals[best]["uid"])
	if uid == 0:
		return
	_assign_parent(uid)
	_refresh_panel()


func _on_buy_breed(id: String) -> void:
	if DragonFlight.buy_breed(profile, id).is_empty():
		notify("Zu wenig Gold")
		return
	DragonFlight.save_profile(profile)
	Sfx.coin()
	notify("%s ist eingetroffen" % str(DragonFlight.breed_by_id(id)["name"]))
	parent_a = 0
	parent_b = 0
	refresh()


func _on_pair() -> void:
	var a := DragonFlight.dragon_by_uid(profile, parent_a)
	var b := DragonFlight.dragon_by_uid(profile, parent_b)
	if a.is_empty() or b.is_empty() or parent_a == parent_b:
		return
	var cost := DragonFlight.pairing_cost(a, b)
	if int(profile.get("gold", 0)) < cost:
		notify("Zu wenig Gold")
		return
	profile["gold"] = int(profile["gold"]) - cost
	var child := DragonFlight.breed_parents(a, b, DragonFlight.next_uid(profile))
	var seconds := DragonFlight.incubation_seconds(str(child["breed"]))
	child["egg"] = {"ready_at": now + seconds, "total": seconds}
	var list: Array = profile.get("dragons", [])
	list.append(child)
	profile["dragons"] = list
	profile["breeds"] = DragonFlight.unlocked_breeds(profile)
	DragonFlight.save_profile(profile)
	Sfx.level_up()
	notify("Ei gelegt — %.0f s Brütezeit" % seconds)
	parent_b = 0
	refresh()


func _hatch_now(dragon: Dictionary, cost: int) -> void:
	if int(profile.get("gold", 0)) < cost:
		notify("Zu wenig Gold")
		return
	profile["gold"] = int(profile["gold"]) - cost
	var list: Array = profile.get("dragons", [])
	var index := list.find(dragon)
	if index < 0:
		return
	var hatched := DragonFlight.hatch(dragon, cost > 0)
	if hatched.is_empty():
		return
	list[index] = hatched
	profile["dragons"] = list
	profile["hatched"] = int(profile.get("hatched", 0)) + 1
	profile["breeds"] = DragonFlight.unlocked_breeds(profile)
	DragonFlight.save_profile(profile)
	Sfx.level_up()
	var breed := DragonFlight.breed_by_id(str(hatched["breed"]))
	var traits := DragonFlight.expressed_traits(hatched.get("alleles", {}))
	notify("%d schlüpft! Merkmale: %s" % [int(hatched["gen"]), ", ".join(_names(traits)) if not traits.is_empty() else "keine"])
	refresh()


func _names(traits: Array[String]) -> Array[String]:
	var out: Array[String] = []
	for id in traits:
		out.append(str(DragonFlight.trait_by_id(id)["name"]))
	return out
