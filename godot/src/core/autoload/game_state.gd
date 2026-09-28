extends Node
## Persistent player state: settings, per-game highscores and the selected
## arena loadout. Mirrors what the browser build kept in `localStorage`.

const CONFIG_PATH := "user://singular80.cfg"
## The file is written to this and then renamed over the old one, so a crash in
## between leaves the previous progress instead of a truncated file.
const CONFIG_TMP := "user://singular80.cfg.tmp"

## How long changes are collected before one goes to the disk. A level game
## submits a star per level and 240 candy levels share one `number.stars/candy3d`
## section, so every single `submit_stars` used to re-serialise the whole map —
## on the main thread, while the player is still playing.
const SAVE_DEBOUNCE := 0.75

## Longest a section or key name may be. A `ConfigFile` is a line-based format,
## so a name carrying a newline would not survive the round trip, and a name
## nobody in this code could have written is a foreign file, not player progress.
const NAME_MAX := 96

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
## The language the player chose, e.g. `"en"`. Empty means "no choice yet", and
## `Loc` then follows the device language.
var language: String = ""

var _highscores: Dictionary = {}
var _numbers: Dictionary = {}

var _config := ConfigFile.new()
## Whether the player's config may be written at all. `run_tests.gd` is a
## `--script` run and the autoloads are really there, so the suite's
## `set_muted`, `set_server_url` and every `submit_score`/`submit_stars` reached
## the real `save_settings()` and replaced the developer's language, sound,
## server address, touch setting, highscores and stars with the suite's values —
## no error anywhere, and a game that started in German again the next morning.
## `Loc.persist` is the same switch for the language choice; this one covers the
## whole file. Off in a `--script` run, on in every real launch, and nothing in
## the game turns it off.
static var persist := not OS.get_cmdline_args().has("--script")

## A change is waiting for the debounce to run out.
var _save_due: bool = false
var _save_timer: Timer
## The file exists but could not be read — a truncated or foreign config. It is
## then left exactly as it is: what is in memory would be the defaults, and
## writing those over it would throw away whatever it still held.
var _load_failed: bool = false


func _ready() -> void:
	load_settings()
	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.timeout.connect(_write_config)
	add_child(_save_timer)


func _exit_tree() -> void:
	# The one moment guaranteed on every way out — quit, scene change, app kill
	# on Android — and therefore the last chance a debounced write still fits in.
	flush_settings()


func load_settings() -> void:
	_config = ConfigFile.new()
	_highscores.clear()
	_numbers.clear()
	# No file at all is a fresh install, not an error. A file that is there and
	# does not parse is a different matter: `load()` would quietly leave the
	# defaults in place and the next write would save exactly those defaults over
	# a file the player may still be able to recover by hand.
	_load_failed = FileAccess.file_exists(CONFIG_PATH) and _config.load(CONFIG_PATH) != OK
	if _load_failed:
		push_warning("Player config unreadable, left untouched: %s" % CONFIG_PATH)
		return
	muted = bool(_config.get_value("audio", KEY_MUTED, false))
	arena_weapon = str(_config.get_value("arena", KEY_WEAPON, "pistol"))
	arena_mode = str(_config.get_value("arena", KEY_MODE, "classic"))
	server_url = str(_config.get_value("net", KEY_SERVER, ""))
	touch_controls = bool(_config.get_value("input", KEY_TOUCH, true))
	language = str(_config.get_value("text", KEY_LANGUAGE, ""))
	for section in _config.get_sections():
		if section == "highscore":
			for key in _config.get_section_keys(section):
				var name := str(key)
				var value: Variant = _config.get_value(section, key, 0)
				if _is_storable(name) and (value is int or value is float):
					_highscores[name] = int(value)
		elif section == "number":
			# A number without a namespace, like `candy_palette` or the crystal's
			# `singular80_crystal3d_unlocked`.
			for key in _config.get_section_keys(section):
				var value: Variant = _number_of(section, str(key))
				if _is_storable(str(key)) and value != null:
					_numbers[str(key)] = value
		elif section.begins_with("number."):
			# `number.stars/candy3d` and friends. The group is validated too: a
			# `number.` with nothing behind it used to be read as the key "/…".
			var group := section.substr(7)
			if not _is_storable(group):
				continue
			for key in _config.get_section_keys(section):
				var name := str(key)
				var value: Variant = _number_of(section, name)
				if _is_storable(name) and value != null:
					_numbers[group + "/" + name] = value


## Arranges for the config to be written. The write itself is collected over
## `SAVE_DEBOUNCE` and lands atomically, so a burst of stars costs one write
## instead of one per level. The setters below do not promise a file on the disk
## when they return — `flush_settings()` is how one gets one right now.
func save_settings() -> void:
	if not persist:
		return
	_save_due = true
	if _save_timer == null:
		# Before `_ready` — no tree to run a timer in. Write straight away rather
		# than drop the change.
		_write_config()
		return
	if _save_timer.is_stopped():
		# Leading edge: the first change of a burst goes out at once, so a process
		# that dies a moment later still has it. Not restarted on every change —
		# a continuous stream of writes would then postpone the file forever.
		_save_timer.start(SAVE_DEBOUNCE)


## Writes the config now, if anything is waiting for it. The way out is the one
## place where a debounced write may no longer fit.
func flush_settings() -> void:
	if not persist or not _save_due:
		return
	_write_config()


func _write_config() -> void:
	if _save_timer != null:
		_save_timer.stop()
	_save_due = false
	if _load_failed:
		# The file on the disk could not be read, so what is in memory is a set
		# of defaults and not the player's progress. Writing would replace a
		# damaged file with those defaults and lose the rest of it for good.
		return
	_config.set_value("audio", KEY_MUTED, muted)
	_config.set_value("arena", KEY_WEAPON, arena_weapon)
	_config.set_value("arena", KEY_MODE, arena_mode)
	_config.set_value("net", KEY_SERVER, server_url)
	_config.set_value("input", KEY_TOUCH, touch_controls)
	_config.set_value("text", KEY_LANGUAGE, language)
	for key in _highscores:
		var name := str(key)
		if _is_storable(name):
			_config.set_value("highscore", name, int(_highscores[key]))
	for key in _numbers:
		var name := str(key)
		if not _is_storable(name):
			continue
		var parts: PackedStringArray = name.split("/", false, 1)
		if parts.size() == 2:
			_config.set_value("number." + parts[0], parts[1], float(_numbers[key]))
		elif not name.contains("/"):
			# A number without a namespace. This used to fall through and the
			# value was gone after the next start, so the crystal's unlocked
			# levels and the candy palette reset themselves every session.
			_config.set_value("number", name, float(_numbers[key]))
	var err := _config.save(CONFIG_TMP)
	if err != OK:
		push_warning("Player config not writable: %s" % CONFIG_PATH)
		# The old file is still there and complete, so a plain write is the next
		# best thing — it is not atomic, but it beats losing the progress.
		_config.save(CONFIG_PATH)
		return
	var from := ProjectSettings.globalize_path(CONFIG_TMP)
	var to := ProjectSettings.globalize_path(CONFIG_PATH)
	if DirAccess.rename_absolute(from, to) != OK:
		push_warning("Player config not renamed, writing it directly: %s" % CONFIG_PATH)
		_config.save(CONFIG_PATH)


## A name that can be written back unchanged. `ConfigFile` is a line-based
## format, so a name with a newline in it would not round-trip; a hand-edited
## file has no business being rewritten anyway.
func _is_storable(name: String) -> bool:
	var trimmed := name.strip_edges()
	if trimmed == "" or trimmed.length() > NAME_MAX:
		return false
	return not trimmed.contains("\n") and not trimmed.contains("\r")


## One number out of the file, or `null` when the entry is not a finite number.
func _number_of(section: String, key: String) -> Variant:
	var value: Variant = _config.get_value(section, key, null)
	if not (value is int or value is float):
		return null
	var number := float(value)
	return number if is_finite(number) else null


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

## The language the player picked. `Loc` is the only caller and validates the
## value first; this just keeps the one config file in one place.
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


## Reads a whole set of level keys in one go, so the level select does not do 240
## settings reads per redraw.
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

