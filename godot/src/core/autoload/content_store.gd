extends Node
## Loads the data-driven game content.
##
## The bundled JSON in `res://assets/content/` is always available, so the app
## works fully offline. When a backend is configured the pack is refreshed from
## `GET /api/content` on start, which is how content changes reach players
## without an app update.

signal content_reloaded

const BUNDLED_DIR := "res://assets/content"
const FILES := ["enemies", "weapons", "upgrades", "modes", "mechanics"]

var version: int = 0
var enemies: Array[Dictionary] = []
var weapons: Array[Dictionary] = []
var upgrades: Array[Dictionary] = []
var modes: Array[Dictionary] = []
var mechanics: Array[Dictionary] = []
var using_remote: bool = false


func _ready() -> void:
	reload()


## Re-reads the bundled files. Always safe to call, never blocks.
func reload() -> void:
	_load_bundled()


## Refreshes from the backend when one is configured. Called in the background
## after startup so the app is playable immediately.
func reload_remote() -> void:
	if not Game.has_server():
		return
	var remote: Variant = await Api.get_content()
	if remote is Dictionary:
		_apply_pack(remote, true)
		content_reloaded.emit()


func _load_bundled() -> void:
	var pack: Dictionary = {}
	for name in FILES:
		var path := "%s/%s.json" % [BUNDLED_DIR, name]
		if not FileAccess.file_exists(path):
			continue
		var text := FileAccess.get_file_as_string(path)
		var parsed: Variant = JSON.parse_string(text)
		if parsed is Array:
			pack[name] = parsed
	_apply_pack(pack, false)
	version = 0


func _apply_pack(pack: Dictionary, remote: bool) -> void:
	var enemies_raw: Variant = pack.get("enemies", [])
	if enemies_raw is Array and not (enemies_raw as Array).is_empty():
		enemies = _as_dicts(enemies_raw)
	var weapons_raw: Variant = pack.get("weapons", [])
	if weapons_raw is Array and not (weapons_raw as Array).is_empty():
		weapons = _as_dicts(weapons_raw)
	var upgrades_raw: Variant = pack.get("upgrades", [])
	if upgrades_raw is Array and not (upgrades_raw as Array).is_empty():
		upgrades = _as_dicts(upgrades_raw)
	var modes_raw: Variant = pack.get("modes", [])
	if modes_raw is Array and not (modes_raw as Array).is_empty():
		modes = _as_dicts(modes_raw)
	var mechanics_raw: Variant = pack.get("mechanics", [])
	if mechanics_raw is Array and not (mechanics_raw as Array).is_empty():
		mechanics = _as_dicts(mechanics_raw)
	var version_value: Variant = pack.get("version", 0)
	if version_value is int or version_value is float:
		version = int(version_value)
	using_remote = remote


func _as_dicts(value: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry in value:
		if entry is Dictionary:
			out.append(entry)
	return out


# --- lookups ----------------------------------------------------------------

func enemy_by_id(id: String) -> Dictionary:
	for def in enemies:
		if str(def.get("id", "")) == id:
			return def
	return enemies[0] if not enemies.is_empty() else {}


func weapon_by_id(id: String) -> Dictionary:
	for def in weapons:
		if str(def.get("id", "")) == id:
			return def
	return weapons[0] if not weapons.is_empty() else {}


func mode_by_id(id: String) -> Dictionary:
	for def in modes:
		if str(def.get("id", "")) == id:
			return def
	return modes[0] if not modes.is_empty() else {}


func enabled_mechanics() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for def in mechanics:
		if bool(def.get("enabled", false)):
			out.append(def)
	return out
