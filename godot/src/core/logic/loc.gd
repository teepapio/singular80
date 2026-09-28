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
##
## The language the *code* is written in, and the pivot of the catalogues.
## German is a translation like any other, in `de.json`.
const SOURCE := "en"

static var _booted := false
static var _code := ""
static var _keys: Dictionary = {}
static var _text: Dictionary = {}
## Every string the active catalogue emits. This is why two `resolve()`
## calls in a row return the same string.
static var _values: Dictionary = {}
## …and every string a substitution produced from one of them. A finished
## sentence is in neither `_values` nor the catalogue: `Ui.label` gets
## `Loc.t("ui.highscore_of", {"score": …})` — a German "Bestwert: 1.234" with no
## `{name}` left in it — and measured against the catalogue it looked like an
## untranslated source string. Rebuilt in `_apply`, which is what keeps it small:
## one language holds one set of results at a time.
static var _results: Dictionary = {}
static var _numbers: Dictionary = {"decimal": ".", "group": ",", "percent": " %"}
static var _catalogues: Dictionary = {}
static var _registered := false
## The `Translation` objects this class handed to `TranslationServer`. Held so
## `reset()` can take them back: registering a second time without removing the
## first left a run's worth of catalogues on the server per reset — nine resets,
## 27 objects, ~675 messages each, none of them freed — and `tr()` resolves
## against the *oldest* registered one, so a stale catalogue could answer
## differently from `Loc.t`.
static var _translations: Array[Translation] = []
## Whether `set_code` may write the player's choice to `user://singular80.cfg`.
## `run_tests.gd` is a `--script` run and pins the language for every test it
## loads; persisting that rewrote the real config behind the developer's back —
## muted, loadout, server address, touch, highscores, stars, language all
## replaced by the suite's "de", with no error anywhere and a game that started
## in German again. So a `--script` run starts with persistence off, and only a
## real launch has it on; nothing in the game turns it off.
static var persist := not OS.get_cmdline_args().has("--script")
## Source signatures, `{"section": {key: {form: signature}}}` — `{form: …}` with
## the empty form for a plain string. Only the source is measured; every other
## catalogue is compared against it before it is used. The section belongs in
## the key: a key can sit in both `keys` and `text`, and the two halves speak
## different placeholder grammars (`{name}` and `%`), so one table per key had
## the `text` signature overwrite the `keys` one for the same id.
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
	# A stored language without a catalogue in this build — an `es` left over
	# from a build that had one, or a config that came from elsewhere. Left
	# alone it is invisible in the picker, so the player can never get back to
	# it through the UI, and the next build that re-adds `es.json` switches them
	# back without asking. Remember what was actually applied, once.
	var unreconciled := wanted != ""
	var system := system_code()
	if system != "" and _catalogues.has(system):
		_apply(system)
	elif _catalogues.has(SOURCE):
		_apply(SOURCE)
	else:
		# No readable catalogue: the key *is* the German source text, so behaviour
		# is exactly what it was before multi-language. The engine still has to
		# hear it: `TranslationServer.set_locale` was skipped here, so `tr()` and
		# `Control`'s own re-translation kept serving the project default while
		# the rest of the game ran in the source.
		_code = SOURCE
		TranslationServer.set_locale(SOURCE)
	if unreconciled:
		_persist(_code)


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
	if not _is_catalogue(file):
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
		"keys": _checked(code, "keys", catalogue.get("keys", {})),
		"text": _checked(code, "text", catalogue.get("text", {})),
		"numbers": numbers if numbers is Dictionary else {},
	}


## True for a file that is a language and nothing else.
##
## `DIR` also holds what the tooling puts there, and every `*.json` used to be
## read as a language: `identical.json` was excluded by name, a stray
## `notes.json` was not and put "notes" into the language picker. The name is
## the only thing that tells the two apart at runtime, so it has to follow the
## shape of a language code — two lower-case letters, then optional `-`
## subtags — the same decision `scripts/locale.mjs` makes before it mirrors a
## file at all.
static func _is_catalogue(file: String) -> bool:
	if not file.ends_with(".json") or file == IDENTICAL_FILE:
		return false
	var pattern := RegEx.new()
	pattern.compile("^[a-z]{2}(-[A-Za-z0-9]+)*\\.json$")
	return pattern.search(file) != null


## The `{name}` placeholders of a text, sorted, so two texts can be compared.
static func _placeholders(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	var pattern := RegEx.new()
	pattern.compile("\\{[a-z_][a-z0-9_]*\\}")
	for found in pattern.search_all(text):
		out.append(found.get_string())
	out.sort()
	return out


## The conversion letter of every `%` placeholder in a text — `%%` does not
## count as one.
##
## A space is deliberately not accepted as a flag. `printf` allows `% d`, but in
## this catalogue `% ` is a literal percent sign in prose — "+12 % Feuerrate",
## "+3 % Rüstung je Stufe" — and treating the next word as a conversion made the
## guard report a German sentence and its English translation as incompatible
## over nothing but the case of one letter: `F` is not a conversion character,
## `f` is. The trade is one format style the game does not use.
static func _specifier_letters(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	var i := 0
	while i < text.length():
		if text[i] != "%":
			i += 1
			continue
		if i + 1 < text.length() and text[i + 1] == "%":
			i += 2
			continue
		var j := i + 1
		# `%1$s` is positional: the number is a flag, and a translation that
		# renumbers the positions swaps the arguments.
		while j < text.length() and "-+#0123456789.*$".contains(text[j]):
			j += 1
		if j < text.length() and "sdfxXoiegcbu".contains(text[j]):
			out.append(text[j])
		i = j + 1
	return out


## What a text has to keep intact to be substitutable — the `{}` names, or the
## conversion letters of the `%` placeholders.
##
## Letters, not a count: `%s` and `%d` both take one argument, so a count said
## they were interchangeable. A translation that turned `%s` into `%d` passed
## the guard and then handed a formatted score to `%d` — `Ui.format_number`
## returns a String — which reads "0" on the caption.
static func _signature(text: String, named: bool) -> String:
	if named:
		return ",".join(_placeholders(text))
	return ",".join(_specifier_letters(text))


## Drops translations whose placeholders no longer match the source original.
## A dropped placeholder is not a bad sentence, it is a crash mid-game:
## `String % Array` aborts when the counts disagree, and a `{name}` with no
## argument leaves a hole. A wrong-language sentence is an annoyance; a crashed
## game is a bug report filed by a player.
## The two sections are checked differently on purpose, which is why the
## section name is an argument and not a boolean: a `text` entry is a source
## template formatted with `%` by `Loc.f`, a `keys` entry is filled from named
## arguments with `{name}` by `Loc.t`. Counting `%` in a `{name}` sentence would
## find nothing and accept everything, and the section is the only thing that
## says which of the two a key is.
static func _checked(code: String, section: String, entries: Variant) -> Dictionary:
	if not (entries is Dictionary):
		return {}
	var named := section == "keys"
	var out: Dictionary = {}
	for key in entries:
		var value: Variant = entries[key]
		if value is Dictionary:
			# A plural used to fall through the `is String` test below and be
			# copied in untouched, so `coverage` — which compared
			# `str(Dictionary)` — read a plural that had lost its "other" as
			# fully translated.
			if code == SOURCE:
				_remember_plural(section, key, value, named)
				out[key] = value
			else:
				var forms := _checked_plural(section, key, value, named)
				if not forms.is_empty():
					out[key] = forms
			continue
		if not (value is String):
			out[key] = value
			continue
		if code == SOURCE:
			_remember(section, key, _signature(value, named))
			out[key] = value
			continue
		var want := _recalled(section, key)
		if want.is_empty() or (want.has("") and _signature(value, named) == str(want[""])):
			out[key] = value
			continue
		push_warning("Loc: '%s' in %s has different placeholders than the source text and stays unused."
			% [key, code])
	return out


## One plural entry, form by form.
##
## The source decides: a form the translation has and the source has not is a
## form nobody asked for, a form whose `{}` names differ from the source form is
## an entry `Loc.t` cannot fill, and a form the source has and the translation
## has not is a half-finished entry that renders as "3 " in a list. Any of the
## three drops the whole entry, and the source language answers instead — a
## complete sentence the player can read beats half of one in their language.
static func _checked_plural(section: String, key: String, forms: Dictionary, named: bool) -> Dictionary:
	var want := _recalled(section, key)
	if want.is_empty():
		return forms
	if want.has(""):
		# The source has a plain string here, so a plural has no form of its own
		# to be measured against.
		push_warning("Loc: '%s' in a catalogue is a plural where the source is one string, and stays unused." % key)
		return {}
	var out: Dictionary = {}
	for form in forms:
		if not want.has(form):
			push_warning("Loc: '%s/%s' in a catalogue has a plural form the source does not, and stays unused." % [key, form])
			return {}
		if _signature(str(forms[form]), named) != str(want[form]):
			push_warning("Loc: '%s/%s' in a catalogue has different placeholders than the source text and stays unused."
				% [key, form])
			return {}
		out[form] = forms[form]
	if out.size() != want.size():
		push_warning("Loc: '%s' in a catalogue is missing a plural form of the source, and stays unused." % key)
		return {}
	return out


## The source signatures of one entry: form -> signature, the empty form for a
## plain string. An entry the source has not got yields an empty Dictionary,
## which the callers read as "nothing to compare against".
static func _recalled(section: String, key: String) -> Dictionary:
	return (_specifiers.get(section, {}) as Dictionary).get(key, {})


static func _remember(section: String, key: String, signature: String) -> void:
	if not _specifiers.has(section):
		_specifiers[section] = {}
	_specifiers[section][key] = {"": signature}


static func _remember_plural(section: String, key: String, forms: Dictionary, named: bool) -> void:
	var per_form: Dictionary = {}
	for form in forms:
		per_form[form] = _signature(str(forms[form]), named)
	if not _specifiers.has(section):
		_specifiers[section] = {}
	_specifiers[section][key] = per_form


## What a text has to keep intact to be substitutable.
## The equal-on-purpose entries of one language.
static func _locked(code: String) -> Dictionary:
	return _identical.get(code, {})


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
		_translations.append(translation)


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
	# One language, one set of finished sentences; see `_results`.
	_results = {}
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
	if game == null:
		return ""
	# `Game.language` is a property, not a method: `has_method("language")` is
	# false for it and `call("language")` throws, so the guard below always
	# answered "no stored choice" and every launch followed the device. Which
	# also meant the reconciliation in `boot` had nothing to reconcile.
	var value: Variant = game.get("language")
	return str(value) if value is String else ""


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


## Writes the player's choice through `Game`, so it lands in the one config
## file. A test run must not: `run_tests.gd` pins a language on every reset, and
## `Game.set_language` saves the whole config — muted, loadout, server address,
## touch, highscores, stars — so a green suite would hand the developer who ran
## it a game whose settings the suite had overwritten. `persist` is the switch,
## and it is off wherever a `--script` run started it.
static func _persist(code: String) -> void:
	if not persist:
		return
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
	# `_values` holds the templates, `_results` what came out of them: a caption
	# the caller interpolated first has no `{name}` left to be recognised by and
	# is in neither the catalogue nor `_values`.
	if _values.has(value) or _results.has(value):
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
	if _keys.has(key) or _text.has(key):
		return true
	# `_raw` falls back to the source, so a key whose translation was dropped or
	# not written yet still answers — in the source language — from `t`. `has`
	# has to answer for everything `t` can answer for, or a caller that asks
	# first sees "no" for a caption it is about to get.
	var source: Dictionary = _catalogues.get(SOURCE, {})
	for section in ["keys", "text"]:
		if (source.get(section, {}) as Dictionary).has(key):
			return true
	return false


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
	# A finished sentence is a source string as far as `resolve` is concerned —
	# `Ui.label(Loc.t("ui.highscore_of", {"score": …}))` hands it straight to the
	# catalogue lookup — so it has to be recognisable as something this language
	# already said. One language, one set: `_apply` drops it.
	_results[out] = true
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
## only if it differs from the source — an entry filled in but left unchanged is
## not done.
##
## The unit is a plural *form*, not a plural: `ui.queue_waiting` needs `one` and
## `other`, and comparing the two entries as one value said a catalogue that had
## lost `other` was done. Half a plural rendered as "3 " in a queue, and 100 %
## coverage is exactly the number nobody would have doubted.
static func coverage(code: String) -> float:
	_ensure()
	# The source measured against itself: every entry is "unchanged", so it would
	# report 0.0 % — and `missing` would name all of them. The source is the
	# measure, not a translation of it.
	if code == SOURCE:
		return 1.0
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
			for form in _forms(want[key]):
				total += 1
				if _translated(have.get(key, null), form, _form(want[key], form)):
					done += 1
	return float(done) / float(total) if total > 0 else 1.0


## Keys still German in `code`. For tests, and for the language picker, which may
## say how far a language has got. A plural that is only half translated is named
## by the form that is missing — `ui.queue_waiting/other` — the same spelling
## `_add_message` gives it.
static func missing(code: String) -> PackedStringArray:
	_ensure()
	var out := PackedStringArray()
	if code == SOURCE:
		return out
	var source: Dictionary = _catalogues.get(SOURCE, {})
	var catalogue: Dictionary = _catalogues.get(code, {})
	for section in ["keys", "text"]:
		var want: Dictionary = source.get(section, {})
		var have: Dictionary = catalogue.get(section, {})
		for key in want:
			if _locked(code).has(key):
				continue
			for form in _forms(want[key]):
				if _translated(have.get(key, null), form, _form(want[key], form)):
					continue
				out.append(key if form == "" else "%s/%s" % [key, form])
	return out


## The units of comparison one entry is made of: the forms the source has, or the
## single empty form of a plain string.
static func _forms(entry: Variant) -> PackedStringArray:
	if entry is Dictionary:
		var out := PackedStringArray()
		for form in entry:
			out.append(str(form))
		return out
	return PackedStringArray([""])


## The text of one unit, `""` where there is none.
static func _form(entry: Variant, form: String) -> String:
	if entry is Dictionary:
		return str((entry as Dictionary).get(form, ""))
	return str(entry) if entry != null else ""


## Whether a unit is really translated: present, and not the source text.
static func _translated(entry: Variant, form: String, reference: String) -> bool:
	var text := _form(entry, form)
	return text != "" and text != reference


## Clears the caches. Tests only: in the game the language loads exactly once.
static func reset() -> void:
	_booted = false
	_registered = false
	# Hand the catalogues back to the engine. `TranslationServer` keeps every
	# `Translation` it was given for the life of the process, so re-registering
	# after a reset without removing the old ones left a second, third, …
	# catalogue per locale — and `tr()` resolved against the first of them, so
	# what Godot said and what `Loc.t` said could drift apart.
	for translation in _translations:
		TranslationServer.remove_translation(translation)
	_translations.clear()
	_code = ""
	_keys = {}
	_text = {}
	_values = {}
	_results = {}
	_numbers = {"decimal": ".", "group": ",", "percent": " %"}
	_catalogues = {}
	_specifiers = {}
	_identical = {}
