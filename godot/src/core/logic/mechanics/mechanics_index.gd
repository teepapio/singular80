class_name MechanicsIndex
extends RefCounted
## Registry of available mechanics, keyed by the id used in
## `content/mechanics.json`.

const FACTORIES := {
	"dash": "res://src/core/logic/mechanics/dash_mechanic.gd",
	## The merge boards drag to merge, with the rules researched from Merge
	## Dragons. It is a mechanic like the dash: a rule set that owns a decision
	## a screen would otherwise have to make twice.
	"merge_drag": "res://src/core/logic/mechanics/merge_drag.gd",
	## A 3D area the player can drag, pinch and tap: suggestion #21 asked for it
	## in the Drachenflug hatchery, where the six pedestals stood behind a panel
	## and out of reach. The gesture and the camera goal it owns are the same for
	## every screen with pedestals in it.
	"pedestal_camera": "res://src/core/logic/mechanics/pedestal_camera.gd",
}


static func by_id(id: String) -> Mechanic:
	if not FACTORIES.has(id):
		return null
	var script: GDScript = load(FACTORIES[id])
	if script == null:
		return null
	return script.new()
