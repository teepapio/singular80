extends Node
## Persistent player state: settings, per-game highscores and the selected
## arena loadout. Mirrors what the browser build kept in `localStorage`.

const CONFIG_PATH := "user://singular80.cfg"

const KEY_MUTED := "muted"
const KEY_WEAPON := "arena_weapon"
const KEY_MODE := "arena_mode"
const KEY_SERVER := "server_url"
const KEY_TOUCH := "touch_controls"
const KEY_LANGUAGE := "language"

## Well-known highscore keys. The `singular80_` prefix matches the dashboard and
## the web build, so a player's history stays consistent across both.
const HS_ARENA := "singular80_highscore"
const HS_TETRIS := "singular80_tetris_highscore"
const HS_HOLDEM := "singular80_holdem_highscore"
const HS_FREECELL := "singular80_freecell_highscore"
const HS_DAME := "singular80_dame_highscore"
const HS_CRYSTAL := "singular80_crystal3d_highscore"
const HS_CRYSTAL_CHRISTMAS := "singular80_crystal3d_christmas_highscore"
const HS_CRYSTAL_HALLOWEEN := "singular80_crystal3d_halloween_highscore"
const HS_MERGE_CHRISTMAS := "singular80_merge3d_christmas_highscore"
const HS_MERGE_HALLOWEEN := "singular80_merge3d_halloween_highscore"
const HS_HORSE := "singular80_horserunner_highscore"
const HS_DRAGON := "singular80_dragonrpg_highscore"
const HS_2048 := "singular80_2048_highscore"
const HS_DRAGONFLIGHT := "singular80_dragonflight_highscore"
const HS_METRO := "singular80_metro3d_highscore"
const HS_PANG := "singular80_pang_highscore"
const HS_CANDY := "singular80_candy_highscore"
const HS_SIEDLER := "singular80_siedler_highscore"

var muted: bool = false
var arena_weapon: String = "pistol"
var arena_mode: String = "classic"
var server_url: String = ""
var touch_controls: bool = true
## The language the player chose, e.g. `"en"`. Empty means "no choice yet" and
## `Loc` then goes by the device language. Not a `Loc` field: this file holds
## only what belongs into `user://singular80.cfg`.
var language: String = ""

var _highscores: Dictionary = {}
var _numbers: Dictionary = {}
var _voter_id: String = ""

var _config := ConfigFile.new()


func _ready() -> void:
	load_settings()


func load_settings() -> void:
	_config = ConfigFile.new()
	_config.load(CONFIG_PATH)
	muted = bool(_config.get_value("audio", KEY_MUTED, false))
	arena_weapon = str(_config.get_value("arena", KEY_WEAPON, "pistol"))
	arena_mode = str(_config.get_value("arena", KEY_MODE, "classic"))
	server_url = str(_config.get_value("net", KEY_SERVER, ""))
	touch_controls = bool(_config.get_value("input", KEY_TOUCH, true))
	language = str(_config.get_value("text", KEY_LANGUAGE, ""))
	for section in _config.get_sections():
		if section == "highscore":
			for key in _config.get_section_keys(section):
				var value: Variant = _config.get_value(section, key, 0)
				if value is int or value is float:
					_highscores[key] = int(value)
		elif section.begins_with("number."):
			for key in _config.get_section_keys(section):
				_numbers[section.substr(7) + "/" + str(key)] = float(_config.get_value(section, key, 0.0))


func save_settings() -> void:
	_config.set_value("audio", KEY_MUTED, muted)
	_config.set_value("arena", KEY_WEAPON, arena_weapon)
	_config.set_value("arena", KEY_MODE, arena_mode)
	_config.set_value("net", KEY_SERVER, server_url)
	_config.set_value("input", KEY_TOUCH, touch_controls)
	_config.set_value("text", KEY_LANGUAGE, language)
	for key in _highscores:
		_config.set_value("highscore", key, int(_highscores[key]))
	for key in _numbers:
		var parts: PackedStringArray = str(key).split("/", false, 1)
		if parts.size() == 2:
			_config.set_value("number." + parts[0], parts[1], float(_numbers[key]))
	_config.save(CONFIG_PATH)


# --- audio ------------------------------------------------------------------

func set_muted(value: bool) -> void:
	muted = value
	AudioServer.set_bus_mute(0, muted)
	save_settings()


func toggle_muted() -> bool:
	set_muted(not muted)
	return muted


# --- arena loadout ----------------------------------------------------------

func set_arena_weapon(id: String) -> void:
	arena_weapon = id
	save_settings()


func set_arena_mode(id: String) -> void:
	arena_mode = id
	save_settings()


# --- language and input -----------------------------------------------------

## The language the player picked, e.g. `"en"`. `Loc` is the only caller and
## validates the value first — this just keeps the one config file in one place.
func set_language(code: String) -> void:
	language = code
	save_settings()


## The on-screen stick and action buttons, read by every screen that shows a
## world or a playfield.
func set_touch_controls(value: bool) -> void:
	touch_controls = value
	save_settings()


# --- network ----------------------------------------------------------------

## Base URL of the Singular 80 backend. Empty means "offline mode": the bundled
## content is used and the suggestion form queues locally.
func set_server_url(url: String) -> void:
	server_url = url.strip_edges()
	save_settings()


func has_server() -> bool:
	return server_url != ""


# --- highscores -------------------------------------------------------------

func highscore(key: String) -> int:
	return int(_highscores.get(key, 0))


## Stores a score and reports whether it beat the previous record.
func submit_score(key: String, value: int) -> bool:
	var record := highscore(key)
	if value > record:
		_highscores[key] = value
		save_settings()
		return true
	return false


# --- generic numbers (crystal levels, best times, …) -----------------------

func get_number(key: String, fallback: float = 0.0) -> float:
	return float(_numbers.get(key, fallback))


func set_number(key: String, value: float) -> void:
	_numbers[key] = value
	save_settings()


# --- star progress (level games) -------------------------------------------

## Stars collected in one level of a level game. The key is the game's id plus a
## level key, so `candy3d` + `daily:2026-09-26` keeps campaigns and dailies apart.
func stars(game_id: String, level_key: String) -> int:
	return int(get_number("stars/%s/%s" % [game_id, level_key]))


## Stores stars for a level, keeping the best result. Reports whether the record
## improved, so the game can celebrate only real improvements.
func submit_stars(game_id: String, level_key: String, value: int) -> bool:
	var clamped: int = clampi(value, 0, 3)
	if clamped <= 0:
		return false
	if clamped <= stars(game_id, level_key):
		return false
	set_number("stars/%s/%s" % [game_id, level_key], float(clamped))
	return true


## Reads a whole set of level keys in one go — used by the level select to build
## its star map without 240 individual settings reads per redraw.
func star_map(game_id: String, level_keys: Array) -> Dictionary:
	var out := {}
	for key in level_keys:
		var value := int(get_number("stars/%s/%s" % [game_id, str(key)]))
		if value > 0:
			out[str(key)] = value
	return out


## `YYYY-MM-DD` of today, the key of the daily challenge.
func today() -> String:
	return CandyMatch3.date_key()


# --- voter identity ---------------------------------------------------------

## Stable anonymous id used to flag duplicate votes for a suggestion.
func voter_id() -> String:
	if _voter_id != "":
		return _voter_id
	var stored := str(_config.get_value("net", "voter_id", ""))
	if stored.length() >= 6:
		_voter_id = stored
		return _voter_id
	_voter_id = "voter_%s%x" % [
		"%08x" % (randi() & 0xFFFFFFFF),
		int(Time.get_unix_time_from_system() * 1000.0) & 0xFFFFFF,
	]
	_config.set_value("net", "voter_id", _voter_id)
	save_settings()
	return _voter_id
