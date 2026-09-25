class_name MechanicsIndex
extends RefCounted
## Registry of available mechanics, keyed by the id used in
## `content/mechanics.json`.

const FACTORIES := {
	"dash": "res://src/core/logic/mechanics/dash_mechanic.gd",
}


static func by_id(id: String) -> Mechanic:
	if not FACTORIES.has(id):
		return null
	var script: GDScript = load(FACTORIES[id])
	if script == null:
		return null
	return script.new()
