class_name FireGlow
extends Node3D
## The part of a mesh that burns which is not geometry: the light it throws, the
## embers that leave it, the pool it leaves on the ground — and the emission it
## does *not* have.
##
## A player stood in front of the campfire in the mesh gallery and wrote "has to
## be more beautiful". The mesh is not the reason, and the fix is not a new mesh.
## Rendered in a hall as cold as that one (a `bae6fd` point lamp, everything else
## grey) the campfire came out as **a pale cream traffic cone over six brown
## blocks**. Two measured causes, both of them in the numbers rather than in the
## shape:
##
## - **The flame is emissive enough to erase its own colour.** `build_campfire()`
##   in `scripts/blender/generate_rpg_meshes.py` gives the flame cone an emission
##   strength of 2.6 and the core 2.8. Emission is *added* to the surface colour,
##   and the orange albedo (0.98, 0.70, 0.35) times 2.6 is (2.5, 1.8, 0.9) — past
##   white on every channel, so the renderer clips it and the fire comes out the
##   colour of a paper cone. Damping the same two surfaces to 0.8 and changing
##   nothing else turns that cone orange with a hot tip, which is the difference
##   between the two pictures in this file's history.
## - **Nothing lit it.** Every other object in the hall is a shape under a lamp. A
##   campfire is the one object whose entire job is to throw light, and it stood
##   there as cold geometry under a cold lamp.
##
## So a fire keeps the materials it was built with, its emission is clamped to
## the point where the colour survives, and this node adds what geometry cannot
## do: a warm light that flickers instead of sitting still, embers that climb out
## of the flame, and the glow the fire leaves underneath itself.
##
## It is hung in `WorldScreen.mesh()`, the one funnel every 3D screen loads its
## meshes through, so the lobby, the dragon RPG and the gallery get all of it
## without a line of screen code.
##
## Everything is built once, in `_ready` or in `attach()`, and `_process` writes
## two floats and reads nothing: no allocation per frame, and one extra node next
## to a mesh that had already cost a `PackedScene.instantiate()`.

## The meshes that burn, and where their fire is.
##
## `light` is how far above the mesh's own origin the light sits, in the mesh's
## own units. The campfire is 1.05 units tall and its flame runs from 0.15 to
## 1.05, so 0.62 is mid flame — which is where a real fire's light comes from.
## Measured: at the tip (1.02) the light misses the logs and only the ground
## warms; in the middle of the flame the logs themselves go warm brown.
##
## These numbers are read in the mesh's *own* space, and the fire is a child of
## the instance, so a screen that scales a mesh — the gallery fits every mesh to
## one size, 3.3 m, which is 3.1x this one — scales the fire with it.
##
## Only meshes that stand still belong here. A fireball in flight would hang a
## light and an emitter on every projectile in the air, which is a limit, not a
## look. The wall torch is out for the same reason: four of them stand in the
## lobby, and the lobby is not short of lights.
const FIRES := {
	"rpg/campfire": {"light": 0.62},
}

## The colour of the fire, and the one colour every part of it wears: the light
## it throws and the pool it leaves. Warm orange, and the same orange the dragon
## RPG has always used for its brazier.
const FIRE_COLOR := Color("ff9a4d")

## The emission a burning surface is allowed to keep.
##
## The point where the albedo stops being clipped: at 0.8 the flame's own orange
## (0.98, 0.70, 0.35) survives, and the cone still glows. Measured against the
## imported `rpg/campfire`, whose two flame surfaces carry 2.47 and 2.66.
##
## A ceiling and not a multiplier, so a mesh that is rebuilt with a calmer
## emission keeps whatever it was given.
const EMISSION_MAX := 0.8

## The light, in the units the hall's own lamps use (`WorldScreen`'s lamps run at
## energy 9 to 18): enough to warm the logs it stands between and the floor
## around them, and low enough that the flame next to it keeps its own colour
## instead of going white — which is the mistake a light *inside* the flame makes.
const LIGHT_ENERGY := 3.4
const LIGHT_RANGE := 9.0

## Two sines at rates that share no period, so the flicker never settles into a
## beat the eye can learn. The floor is the dimmest the fire gets; the span is
## how much brighter than that it gets.
const FLICKER_HZ := 5.1
const FLICKER_SECOND_HZ := 13.7
const FLICKER_FLOOR := 0.78
const FLICKER_SPAN := 0.22

## Embers. Fourteen is what it takes to read as sparks at gallery distance; the
## count is per fire mesh, and there is at most one fire mesh resident at a time.
const EMBER_COUNT := 14
const EMBER_RADIUS := 0.035
const EMBER_LIFETIME := 1.6

## The pool of light on the ground. Drawn from a gradient rather than shipped as
## a texture file: one `GradientTexture2D` the GPU makes the disc out of.
const POOL_DIAMETER := 2.0
const POOL_TEXTURE_SIZE := 128
const POOL_ALPHA := 0.55
const POOL_HEIGHT := 0.02

var fire_key := ""
var _light: OmniLight3D
var _pool: Sprite3D
var _embers: CPUParticles3D
var _time := 0.0
## A per-instance offset, so two campfires in one hall do not breathe together.
var _phase := 0.0


## The logical key of a mesh, from either spelling a caller has: `rpg/campfire`
## or the gallery's `res://assets/meshes/med/rpg/campfire.glb`.
##
## The gallery loads one detail level, so it asks for a path rather than a key —
## and every caller of `WorldScreen.mesh()` has to know which of the two it got
## before it can decide anything about that mesh.
static func mesh_key(id: String) -> String:
	var key := id
	if key.begins_with(AssetRegistry.MESH_DIR):
		key = key.substr(AssetRegistry.MESH_DIR.length() + 1)
	if key.ends_with(".glb"):
		key = key.substr(0, key.length() - 4)
	for tier in AssetRegistry.TIERS:
		if key.begins_with("%s/" % tier):
			return key.substr(tier.length() + 1)
	return key


## True when this mesh burns and a `FireGlow` belongs on it.
static func burns(key: String) -> bool:
	return FIRES.has(key)


## Hangs the fire on `host`, or returns `null` when `key` is not a fire — which
## is the answer for every other mesh in the game.
static func attach(host: Node3D, key: String) -> FireGlow:
	if not FIRES.has(key):
		return null
	# Before the tint, and before any caller can put a `material_override` on the
	# mesh: the clamp works per surface, and an override would hide all of them.
	_clamp_emission(host)
	var glow := FireGlow.new()
	glow.fire_key = key
	host.add_child(glow)
	return glow


## Holds every glowing surface of a burning mesh to `EMISSION_MAX`.
##
## Each material is duplicated rather than written to: the ones on a glTF are
## shared with every other instance of that file, and a resource that comes from
## the import cache does not belong to the game.
static func _clamp_emission(root: Node) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D:
			var instance := node as MeshInstance3D
			for i in instance.get_surface_count():
				var material := instance.get_active_material(i)
				if material is StandardMaterial3D:
					_damp(material as StandardMaterial3D, instance, i)
		for child in node.get_children():
			stack.append(child)


static func _damp(material: StandardMaterial3D, instance: MeshInstance3D, surface: int) -> void:
	if not material.emission_enabled or material.emission_energy_multiplier <= EMISSION_MAX:
		return
	var copy := material.duplicate() as StandardMaterial3D
	copy.emission_energy_multiplier = EMISSION_MAX
	instance.set_surface_override_material(surface, copy)


func _ready() -> void:
	var place: Dictionary = FIRES.get(fire_key, {})
	var height := float(place.get("light", 0.5))
	_phase = randf() * TAU
	_build_light(height)
	_build_embers(height)
	_build_pool()


## The flicker. Two sines, two property writes, nothing allocated — the whole
## per-frame cost of a fire in the game.
func _process(delta: float) -> void:
	_time += delta
	var flicker := sin(_time * FLICKER_HZ + _phase) * 0.62 + sin(_time * FLICKER_SECOND_HZ + _phase * 1.7) * 0.38
	var breath := FLICKER_FLOOR + FLICKER_SPAN * flicker
	if _light != null:
		_light.light_energy = LIGHT_ENERGY * breath
	if _pool != null:
		_pool.modulate.a = POOL_ALPHA * (0.7 + 0.3 * breath)


func _build_light(height: float) -> void:
	_light = OmniLight3D.new()
	_light.light_color = FIRE_COLOR
	_light.light_energy = LIGHT_ENERGY
	_light.omni_range = LIGHT_RANGE
	_light.position = Vector3(0.0, height, 0.0)
	add_child(_light)


func _build_embers(height: float) -> void:
	_embers = CPUParticles3D.new()
	_embers.amount = EMBER_COUNT
	_embers.lifetime = EMBER_LIFETIME
	_embers.randomness = 0.5
	# Embers that travelled with the mesh would circle the fire instead of rising
	# out of it — and the gallery spins every pedestal it stands on.
	_embers.local_coords = false
	_embers.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	_embers.emission_sphere_radius = 0.16
	_embers.direction = Vector3.UP
	_embers.spread = 16.0
	# Hot air, not gravity: the only force on an ember is the one that lifts it.
	_embers.gravity = Vector3(0.0, 0.7, 0.0)
	_embers.initial_velocity_min = 0.3
	_embers.initial_velocity_max = 0.75
	_embers.damping_min = 0.1
	_embers.damping_max = 0.35
	_embers.scale_amount_min = 0.5
	_embers.scale_amount_max = 1.0
	_embers.scale_amount_curve = _ember_curve()
	_embers.color_ramp = _ember_ramp()
	_embers.mesh = _ember_mesh()
	_embers.position = Vector3(0.0, height, 0.0)
	add_child(_embers)


## The soft disc of light under the fire, drawn by the GPU out of a gradient so
## that no image has to ship with the game.
func _build_pool() -> void:
	_pool = Sprite3D.new()
	_pool.texture = _pool_texture()
	_pool.pixel_size = POOL_DIAMETER / float(POOL_TEXTURE_SIZE)
	_pool.shaded = false
	_pool.transparent = true
	_pool.modulate = Color(FIRE_COLOR.r, FIRE_COLOR.g, FIRE_COLOR.b, POOL_ALPHA)
	# A `Sprite3D` stands in its own XY plane; laid flat it lies on the ground.
	_pool.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	_pool.position = Vector3(0.0, POOL_HEIGHT, 0.0)
	_pool.render_priority = 2
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.albedo_texture = _pool.texture
	material.albedo_color = FIRE_COLOR
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.disable_receive_shadows = true
	_pool.material_override = material
	add_child(_pool)


## White in the middle and gone at the rim. The material adds it to whatever is
## behind, so the pool brightens the ground instead of covering it.
static func _pool_texture() -> GradientTexture2D:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.45, 1.0])
	gradient.colors = PackedColorArray([
		Color(1.0, 1.0, 1.0, 1.0), Color(1.0, 1.0, 1.0, 0.35), Color(1.0, 1.0, 1.0, 0.0),
	])
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.width = POOL_TEXTURE_SIZE
	texture.height = POOL_TEXTURE_SIZE
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1.0, 0.5)
	return texture


## An ember: gold at birth, orange while it climbs, out before it can fall back.
static func _ember_ramp() -> Gradient:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.35, 1.0])
	gradient.colors = PackedColorArray([
		Color(1.0, 0.92, 0.62, 1.0), Color(1.0, 0.55, 0.15, 0.9), Color(0.9, 0.2, 0.05, 0.0),
	])
	return gradient


## An ember shrinks as it cools. A curve rather than a second particle system:
## one emitter, one draw call.
static func _ember_curve() -> Curve:
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 1.0))
	curve.add_point(Vector2(0.6, 0.8))
	curve.add_point(Vector2(1.0, 0.0))
	return curve


## A four-segment ball, unlit and additive, so an ember is bright whatever the
## light around it does.
static func _ember_mesh() -> SphereMesh:
	var ember := SphereMesh.new()
	ember.radius = EMBER_RADIUS
	ember.height = EMBER_RADIUS * 2.0
	ember.radial_segments = 4
	ember.rings = 2
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	# The ramp above is per particle, and it only reaches the shader when the
	# material reads the vertex colour as its albedo.
	material.vertex_color_use_as_albedo = true
	material.disable_receive_shadows = true
	ember.material = material
	return ember
