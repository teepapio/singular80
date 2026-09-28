class_name Loc
extends RefCounted
## Language, translation lookup, locale-aware number formatting.
## Two key kinds, in order: `keys` (ids like `ui.back_to_lobby`) and `text` (the
## German source string as its own key, which is what `Ui.label` passes to
## `resolve()` — so existing labels translate without rewriting 650 call sites).
## Invariant: `resolve()` is idempotent, because `_values` holds every string a
## catalogue emits. A missing translation falls back active -> `de` -> the key.
## Separators come from the catalogue (`1.234` de, `1,234` en). Persistence goes
## through `Game.set_language`, not a `ConfigFile` here.

const DIR := "res://assets/locale"
## Mirrored from `locale/identical.json`; read, never treated as a language.
const IDENTICAL_FILE := "identical.json"
## Language the source text is written in. Fallback for every other language,
## so it must always have a catalogue.
const SOURCE := "de"

static var _booted := false
static var _code := ""
static var _keys: Dictionary = {}
static var _text: Dictionary = {}
## Every string the active catalogue emits. This is why two `resolve()`
## calls in a row return the same string.
static var _values: Dictionary = {}
static var _numbers: Dictionary = {"decimal": ".", "group": ",", "percent": " %"}
static var _catalogues: Dictionary = {}
static var _registered := false
## German template -> how many `%` placeholders it has. Only the source counts;
## every other catalogue is measured against it before it is used.
static var _specifiers: Dictionary = {}
## Entries that are equal in every language on purpose — brand names, symbol
## patterns, loanwords. Mirrored from `locale/identical.json`; they leave the
## coverage denominator, because calling "Tetris" untranslated would make
## the number a complaint about the one thing that is right.
static var _identical: Dictionary = {}

const _MISSING := "__loc_missing__"


# --- Start ------------------------------------------------------------------

## Loads the catalogues and applies the chosen language (the device's on first
## start). Idempotent: `Ui` may need the language without `main.gd` calling it.
static func boot() -> void:
	if _booted:
		return
	_booted = true
	_load_all()
	var wanted := stored_code()
	if wanted != "" and _catalogues.has(wanted):
		_apply(wanted)
		return
	var system := system_code()
	if system != "" and _catalogues.has(system):
		_apply(system)
		return
	if _catalogues.has(SOURCE):
		_apply(SOURCE)
		return
	# No readable catalogue: the key *is* the German source text, so behaviour
	# is exactly what it was before multi-language.
	_code = SOURCE


static func _ensure() -> void:
	if not _booted:
		boot()


static func _load_all() -> void:
	_catalogues.clear()
	_specifiers.clear()
	_load_identical()
	var dir := DirAccess.open(DIR)
	if dir == null:
		push_warning("Loc: %s nicht lesbar — das Spiel bleibt in der Quellsprache." % DIR)
		return
	# The source language first: it supplies the sentences every translation is
	# measured against. `DirAccess` neither sorts nor guarantees an order, and an
	# alphabet with `en` before `de` would take every translation unchecked.
	_load_catalogue("%s.json" % SOURCE, dir)
	for file in dir.get_files():
		if file != "%s.json" % SOURCE:
			_load_catalogue(file, dir)
	_register_translations()


## The entries `locale/identical.json` marks as equal in every language.
##
## Without this the coverage figure calls "Tetris", "‖ Pause" and "★ %d  %s"
## untranslated, which is a complaint about the one thing that is right — and a
## number that cries wolf is a number nobody reads.
static func _load_identical() -> void:
	_identical = {}
	var file := "%s/%s" % [DIR, IDENTICAL_FILE]
	if not FileAccess.file_exists(file):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(file))
	if not (parsed is Dictionary):
		return
	# One entry per language: "Bonbonland" is the French name of the Candy world
	# while the English one says "Candy Land", so a single shared list would have
	# to call one of them untranslated.
	for code in (parsed as Dictionary).keys():
		var entry: Variant = (parsed as Dictionary)[code]
		if not (entry is Dictionary):
			continue
		_identical[code] = {}
		for section in ["keys", "text"]:
			for key in (entry as Dictionary).get(section, []):
				_identical[code][str(key)] = true


static func _load_catalogue(file: String, dir: DirAccess) -> void:
	# `identical.json` lives in the same directory and is a tool, not a
	# language. Reading it as one would put "identical" in the language picker.
	if not file.ends_with(".json") or file == IDENTICAL_FILE:
		return
	var raw := FileAccess.get_file_as_string("%s/%s" % [DIR, file])
	var parsed: Variant = JSON.parse_string(raw)
	if not (parsed is Dictionary):
		push_warning("Loc: %s ist kein Objekt und wird übersprungen." % file)
		return
	var catalogue: Dictionary = parsed
	var code := str(catalogue.get("code", file.trim_suffix(".json")))
	if code == "":
		return
	var numbers: Variant = catalogue.get("numbers", {})
	_catalogues[code] = {
		"name": str(catalogue.get("name", code)),
		"native": str(catalogue.get("native", catalogue.get("name", code))),
		"keys": _checked(code, catalogue.get("keys", {}), true),
		"text": _checked(code, catalogue.get("text", {}), false),
		"numbers": numbers if numbers is Dictionary else {},
	}


## The `{name}` placeholders of a text, sorted, so two texts can be compared.
static func _placeholders(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	var pattern := RegEx.new()
	pattern.compile("\\{[a-z_][a-z0-9_]*\\}")
	for found in pattern.search_all(text):
		out.append(found.get_string())
	out.sort()
	return out


## How many `%` placeholders a text has — `%%` does not count as one.
##
## A space is deliberately not accepted as a flag. `printf` allows `% d`, but in
## this catalogue `% ` is a literal percent sign in prose — "+12 % Feuerrate",
## "+3 % Rüstung je Stufe" — and treating the next word as a conversion made the
## guard report a German sentence and its English translation as incompatible
## over nothing but the case of one letter: `F` is not a conversion character,
## `f` is. The trade is one format style the game does not use.
static func _count_specifiers(text: String) -> int:
	var count := 0
	var i := 0
	while i < text.length():
		if text[i] != "%":
			i += 1
			continue
		if i + 1 < text.length() and text[i + 1] == "%":
			i += 2
			continue
		var j := i + 1
		while j < text.length() and "-+#0123456789.*".contains(text[j]):
			j += 1
		if j < text.length() and "sdfxXo".contains(text[j]):
			count += 1
		i = j + 1
	return count


## Drops translations whose placeholders no longer match the German original.
## A dropped placeholder is not a bad sentence, it is a crash mid-game:
## `String % Array` aborts when the counts disagree, and a `{name}` with no
## argument leaves a hole. A wrong-language sentence is an annoyance; a crashed
## game is a bug report filed by a player.
## The two halves are checked differently on purpose: a `text` entry is a German
## template formatted with `%` by `Loc.f`, a `keys` entry is filled from named
## arguments with `{name}` by `Loc.t`. Counting `%` in a `{name}` sentence would
## find nothing and accept everything.
static func _checked(code: String, section: Variant, named: bool) -> Dictionary:
	if not (section is Dictionary):
		return {}
	var out: Dictionary = {}
	for key in section:
		var value: Variant = section[key]
		if not (value is String):
			out[key] = value
			continue
		if code == SOURCE:
			_specifiers[key] = _signature(value, named)
			out[key] = value
			continue
		if not _specifiers.has(key) or _signature(value, named) == str(_specifiers[key]):
			out[key] = value
			continue
		push_warning("Loc: '%s' in %s has different placeholders than the German text and stays unused."
			% [key, code])
	return out


## What a text has to keep intact to be substitutable.
## The equal-on-purpose entries of one language.
static func _locked(code: String) -> Dictionary:
	return _identical.get(code, {})


static func _signature(text: String, named: bool) -> String:
	if named:
		return ",".join(_placeholders(text))
	var parts := PackedStringArray()
	for index in _count_specifiers(text):
		parts.append("s")
	return ",".join(parts)


## Also hands the catalogues to Godot's `TranslationServer`, so `tr("ui.play")`
## works and — more importantly — `Control` re-translates itself on
## `set_locale`, which picks up dynamically set labels (the sound button, a
## status line) with no special handling. `Loc.t` stays the preferred spelling in
## code: only it knows the fallback chain and the placeholders.
static func _register_translations() -> void:
	if _registered:
		return
	_registered = true
	for code in _catalogues:
		var translation := Translation.new()
		translation.locale = code
		var catalogue: Dictionary = _catalogues[code]
		for section in ["keys", "text"]:
			for key in catalogue[section]:
				_add_message(translation, str(key), catalogue[section][key])
		TranslationServer.add_translation(translation)


static func _add_message(translation: Translation, key: String, value: Variant) -> void:
	if value is String:
		translation.add_message(key, value)
	elif value is Dictionary:
		# Plural forms become `key/one`, `key/other`: `tr()` knows no plural rules,
		# so each form gets its own id.
		for form in value:
			translation.add_message("%s/%s" % [key, form], str(value[form]))


static func _apply(code: String) -> void:
	var catalogue: Dictionary = _catalogues.get(code, {})
	_code = code
	_keys = catalogue.get("keys", {})
	_text = catalogue.get("text", {})
	# Defaults first, then the catalogue on top of them: a language that only
	# overrides the decimal point keeps a sane thousands separator.
	_numbers = {"decimal": ".", "group": ",", "percent": " %"}
	var numbers: Dictionary = catalogue.get("numbers", {})
	for name in numbers:
		_numbers[name] = numbers[name]
	_values = {}
	for section in [_keys, _text]:
		for value in section.values():
			_collect_values(value, _values)
	TranslationServer.set_locale(code)


static func _collect_values(value: Variant, into: Dictionary) -> void:
	if value is String:
		into[value] = true
	elif value is Dictionary:
		for nested in value.values():
			_collect_values(nested, into)


# --- Choosing a language ----------------------------------------------------

## The active language, e.g. `"en"`.
static func code() -> String:
	_ensure()
	return _code


static func is_source() -> bool:
	return code() == SOURCE


## All languages with a catalogue, sorted by their own name — the picker shows
## "Deutsch", "English", "Français" rather than the code.
static func available() -> Array[Dictionary]:
	_ensure()
	var out: Array[Dictionary] = []
	for code in _catalogues:
		var catalogue: Dictionary = _catalogues[code]
		out.append({
			"code": str(code),
			"name": str(catalogue.get("name", code)),
			"native": str(catalogue.get("native", code)),
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a["native"]).to_lower() < str(b["native"]).to_lower())
	return out


static func codes() -> PackedStringArray:
	_ensure()
	var out := PackedStringArray()
	for entry in available():
		out.append(str(entry["code"]))
	return out


static func native_name(code: String) -> String:
	_ensure()
	var catalogue: Dictionary = _catalogues.get(code, {})
	return str(catalogue.get("native", code))


## Switches language, remembers it and points Godot at it.
## Accepts what the device reports: `"fr_FR"` finds the `fr` catalogue. An
## unknown code changes nothing and returns `false` — silently falling back to
## another language would be worse than a message.
static func set_code(code: String) -> bool:
	_ensure()
	var wanted := code
	if not _catalogues.has(wanted):
		wanted = code.split("_")[0].split("-")[0].to_lower()
	if not _catalogues.has(wanted):
		return false
	if wanted != _code:
		_apply(wanted)
	_persist(wanted)
	return true


## The player's stored choice, or `""`.
static func stored_code() -> String:
	var game := _game()
	if game != null and game.has_method("language"):
		return str(game.call("language"))
	return ""


## The device language, reduced to two letters (`de`).
static func system_code() -> String:
	var locale := OS.get_locale()
	if locale == "":
		return ""
	return locale.split("_")[0].split("-")[0].to_lower()


static func _game() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null("Game")


static func _persist(code: String) -> void:
	var game := _game()
	if game != null and game.has_method("set_language"):
		game.call("set_language", code)


# --- Translating ------------------------------------------------------------

## Translates an id, e.g. `Loc.t("ui.back_to_lobby")`.
## `args` fills `{placeholders}` in the translation, in preference to
## `String.format` for two reasons: argument order differs per language, and a
## missing argument with `%s` crashes mid-game instead of leaving a gap.
static func t(key: String, args: Dictionary = {}) -> String:
	if key == "":
		return ""
	_ensure()
	return _interpolate(_raw(key), args)


## Like `t`, but picks the plural form that fits the number.
static func tn(key: String, count: int, args: Dictionary = {}) -> String:
	if key == "":
		return ""
	_ensure()
	var filled := args.duplicate()
	filled["count"] = count
	filled["n"] = count
	return _interpolate(_raw(key, float(count)), filled)


## Translates a German source text. Used by `Ui` and the base classes; game code
## calls `t`.
static func resolve(value: String) -> String:
	if value == "":
		return ""
	_ensure()
	if _values.has(value):
		return value
	if _text.has(value):
		var found: Variant = _text[value]
		return found if found is String else value
	return value


## Translates a **template** and substitutes the values afterwards.
## `Ui.label("Bestwert: %s" % best)` is untranslatable in that order: the string is
## formatted first and labelled second, so the catalogue would have to hold a
## finished sentence with the name already inside it. `Loc.f` reverses the order
## without rewriting the text:
##
##     Loc.f("Bestwert: %s", [best])
##
## The template keeps its `%` placeholders, so a translation has to carry them
## over unchanged — checked when the catalogue is read (`_checked`).
static func f(template: String, values: Array) -> String:
	_ensure()
	return resolve(template) % values


static func has(key: String) -> bool:
	_ensure()
	return _keys.has(key) or _text.has(key)


static func _raw(key: String, count: float = 0.0) -> String:
	if _keys.has(key):
		return _pick(_keys[key], count)
	if _text.has(key):
		return _pick(_text[key], count)
	# Fall back to the source language: a half-translated language shows German
	# where it has nothing yet, not the key.
	var source: Dictionary = _catalogues.get(SOURCE, {})
	var source_keys: Dictionary = source.get("keys", {})
	var source_text: Dictionary = source.get("text", {})
	if source_keys.has(key):
		return _pick(source_keys[key], count)
	if source_text.has(key):
		return _pick(source_text[key], count)
	return key


## An entry is either a string or a list of plural forms.
static func _pick(value: Variant, count: float) -> String:
	if value is String:
		return value
	if value is Dictionary:
		var forms: Dictionary = value
		var wanted := _plural_category(count)
		if forms.has(wanted):
			return str(forms[wanted])
		if forms.has("other"):
			return str(forms["other"])
		for form in forms:
			return str(forms[form])
	return ""


## CLDR, as far as the catalogue languages reach.
## German, English and Spanish have `one` only at exactly one thing. French also
## counts zero as singular — "0 point", not "0 points" — and that is where most
## translations go wrong. Languages with `few`/`many` (Slavic, Polish) need a
## rule each; `other` is the fallback, so a missing form breaks nothing.
static func _plural_category(count: float) -> String:
	if _code.begins_with("fr"):
		return "one" if (is_equal_approx(count, 1.0) or is_zero_approx(count)) else "other"
	return "one" if is_equal_approx(count, 1.0) else "other"


static func _interpolate(text: String, args: Dictionary) -> String:
	if args.is_empty() or not text.contains("{"):
		return text
	var out := text
	for name in args:
		out = out.replace("{%s}" % name, str(args[name]))
	return out


# --- Numbers ----------------------------------------------------------------

## `1234` -> `1.234` (German) resp. `1,234` (English).
static func number(value: int) -> String:
	_ensure()
	var negative := value < 0
	return ("-" if negative else "") + _grouped(str(absi(value)))


## `1.5` -> `1,5`. Thousands stay grouped: a score above 1000 happens in every
## game.
static func decimal(value: float, digits: int = 1) -> String:
	_ensure()
	var text := String.num(value, digits)
	var negative := text.begins_with("-")
	if negative:
		text = text.substr(1)
	var parts := text.split(".")
	var out := _grouped(parts[0])
	if parts.size() > 1 and parts[1] != "":
		out += str(_numbers.get("decimal", ".")) + parts[1]
	return ("-" if negative else "") + out


## `0.42` -> `42 %`.
static func percent(ratio: float, digits: int = 0) -> String:
	return decimal(ratio * 100.0, digits) + str(_numbers.get("percent", " %"))


static func _grouped(digits: String) -> String:
	var group := str(_numbers.get("group", ","))
	if group == "" or digits.length() <= 3:
		return digits
	var out := ""
	var count := 0
	for i in range(digits.length() - 1, -1, -1):
		out = digits[i] + out
		count += 1
		if count % 3 == 0 and i > 0:
			out = group + out
	return out


# --- Coverage ---------------------------------------------------------------

## Share of keys translated in `code` (0.0 ... 1.0). An entry counts as translated
## only if it differs from the German source — an entry filled in but left
## unchanged is not done.
static func coverage(code: String) -> float:
	_ensure()
	var source: Dictionary = _catalogues.get(SOURCE, {})
	if source.is_empty():
		return 1.0
	var catalogue: Dictionary = _catalogues.get(code, {})
	if catalogue.is_empty():
		return 0.0
	var total := 0
	var done := 0
	for section in ["keys", "text"]:
		var want: Dictionary = source.get(section, {})
		var have: Dictionary = catalogue.get(section, {})
		for key in want:
			if _locked(code).has(key):
				continue
			total += 1
			if str(have.get(key, "")) != str(want[key]) and str(have.get(key, "")) != "":
				done += 1
	return float(done) / float(total) if total > 0 else 1.0


## Keys still German in `code`. For tests, and for the language picker, which may
## say how far a language has got.
static func missing(code: String) -> PackedStringArray:
	_ensure()
	var source: Dictionary = _catalogues.get(SOURCE, {})
	var catalogue: Dictionary = _catalogues.get(code, {})
	var out := PackedStringArray()
	for section in ["keys", "text"]:
		var want: Dictionary = source.get(section, {})
		var have: Dictionary = catalogue.get(section, {})
		for key in want:
			if _locked(code).has(key):
				continue
			var translated := str(have.get(key, ""))
			if translated == "" or translated == str(want[key]):
				out.append(key)
	return out


## Clears the caches. Tests only: in the game the language loads exactly once.
static func reset() -> void:
	_booted = false
	_registered = false
	_code = ""
	_keys = {}
	_text = {}
	_values = {}
	_numbers = {"decimal": ".", "group": ",", "percent": " %"}
	_catalogues = {}
	_specifiers = {}
	_identical = {}
