extends Node
## Owns the screen stack: the 3D world host, the 2D UI host and the transitions
## between them. 3D screens go into `world_host`, 2D screens into `screen_host`;
## a switch frees the old node and instantiates the new one.

signal screen_changed(screen_id: String)

const SCREEN_SCRIPTS := {
	"lobby": "res://src/game/lobby/lobby3d_screen.gd",
	"mesh_gallery": "res://src/game/lobby/mesh_gallery_screen.gd",
	"lobby_list": "res://src/game/lobby/lobby_list_screen.gd",
	"main_menu": "res://src/game/arena/main_menu_screen.gd",
	"arena": "res://src/game/arena/arena_screen.gd",
	"game_over": "res://src/game/arena/game_over_screen.gd",
	"tetris": "res://src/game/tetris/tetris_screen.gd",
	"poker": "res://src/game/poker/poker_screen.gd",
	"freecell": "res://src/game/freecell/freecell_screen.gd",
	"dame": "res://src/game/dame/dame_screen.gd",
	"g2048": "res://src/game/g2048/g2048_screen.gd",
	"crystal3d": "res://src/game/crystal3d/crystal_jumper_screen.gd",
	"crystal3d_christmas": "res://src/game/crystal3d/crystal_jumper_screen.gd",
	"crystal3d_halloween": "res://src/game/crystal3d/crystal_jumper_screen.gd",
	# The Crystal Jumper's bag, merge and equip. One screen for all three
	# editions: the payload says which theme it is, see `GameRegistry.COMPANIONS`.
	"crystal_forge": "res://src/game/crystal3d/crystal_forge_screen.gd",
	"merge3d_christmas": "res://src/game/merge3d/merge3d_screen.gd",
	"merge3d_halloween": "res://src/game/merge3d/merge3d_screen.gd",
	"horserunner": "res://src/game/horse_runner/horse_runner_screen.gd",
	"dragonrpg": "res://src/game/dragon_rpg/dragon_rpg_screen.gd",
	"dragonflight": "res://src/game/dragon_flight/hangar_screen.gd",
	"dragonflight_run": "res://src/game/dragon_flight/dragon_flight_screen.gd",
	"dragonflight_hatchery": "res://src/game/dragon_flight/hatchery_screen.gd",
	"metro3d": "res://src/game/metro/metro_screen.gd",
	"pang_menu": "res://src/game/pang/pang_menu_screen.gd",
	"pang": "res://src/game/pang/pang_screen.gd",
	"siedler": "res://src/game/siedler/siedler_screen.gd",
	"candy3d": "res://src/game/candy_match3/candy_match3_screen.gd",
}

## Screens that can be rebuilt without losing anything.
##
## A language change re-renders the current screen: free for a menu, ruinous for
## a playfield. Everything not listed picks the new language up on the next switch.
const REBUILD_SAFE: Array[String] = [
	"lobby", "lobby_list", "main_menu", "mesh_gallery", "pang_menu", "dragonflight",
]

var current_id: String = ""
var current_screen: Node = null
## True while a fade or swap is in flight. Sequenced switches (test sweep, scripted
## intro) wait for this instead of guessing a delay.
var transitioning: bool = false

var world_host: Node3D
var screen_host: Control
var fade: ColorRect



func _ready() -> void:
	process_priority = 100
	world_host = Node3D.new()
	world_host.name = "WorldHost"
	add_child(world_host)

	screen_host = Control.new()
	screen_host.name = "ScreenHost"
	screen_host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen_host.theme = UiTheme.shared()
	add_child(screen_host)

	fade = ColorRect.new()
	fade.name = "Fade"
	fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	fade.color = Color(0.02, 0.03, 0.06, 0.0)
	fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(fade)


## Switches to another screen. Unknown ids fall back to the 3D lobby.
func go_to(screen_id: String, data: Dictionary = {}) -> void:
	if transitioning:
		return
	var path := str(SCREEN_SCRIPTS.get(screen_id, SCREEN_SCRIPTS["lobby"]))
	var script: GDScript = load(path)
	if script == null:
		push_error("Screen-Skript nicht gefunden: %s" % path)
		return
	transitioning = true
	await _fade(1.0)

	if current_screen != null and is_instance_valid(current_screen):
		current_screen.queue_free()
		current_screen = null

	var screen: Node = script.new()
	screen.set("screen_id", screen_id)
	screen.set("data", data)
	current_screen = screen
	if screen is Node3D:
		world_host.add_child(screen)
	else:
		screen_host.add_child(screen)

	current_id = screen_id
	screen_changed.emit(screen_id)
	await _fade(0.0)
	transitioning = false


## Convenience: start the game with the given registry id.
func play(game_id: String) -> void:
	go_to(GameRegistry.screen_of(game_id))


func to_lobby() -> void:
	go_to("lobby")


## True when re-entering the current screen costs the player nothing.
## `SettingsDialog` asks before it rebuilds.
func rebuild_safe() -> bool:
	return current_id != "" and REBUILD_SAFE.has(current_id) and not transitioning


func _fade(target_alpha: float) -> void:
	var tween := create_tween()
	tween.tween_property(fade, "color:a", target_alpha, 0.12)
	await tween.finished
