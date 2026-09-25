class_name Mechanic
extends RefCounted
## Base class for optional arena mechanics (the `content/mechanics.json` hook).
##
## A mechanic is a small, self-contained rule set that can react to the arena's
## lifecycle. The arena scene implements every method a mechanic may call, so a
## mechanic never needs to know about rendering, pooling or the scene tree.

var id: String = ""
var mechanic_name: String = ""
var description: String = ""


func init_mechanic(_host: Node) -> void:
	pass


func update_mechanic(_host: Node, _delta: float) -> void:
	pass


## Returns a velocity override, or `null` to keep the normal movement.
func movement_override(_host: Node, _delta: float) -> Variant:
	return null


## Lets a mechanic modify the shot right before it is fired.
func on_fire(_host: Node, shot: Dictionary) -> Dictionary:
	return shot


func on_enemy_killed(_host: Node, _enemy: Variant) -> void:
	pass


func on_level_up(_host: Node, _level: int) -> void:
	pass


## Short status line for the HUD ("" hides it).
func hud(_host: Node) -> String:
	return ""
