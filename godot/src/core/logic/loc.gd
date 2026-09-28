class_name Loc
extends RefCounted
## Sprache, Übersetzungen und locale-abhängige Formatierung.
##
## ## Zwei Sorten Schlüssel
##
## Der Katalog `res://assets/locale/<code>.json` kennt beide, und die
## Reihenfolge der Auflösung ist fest:
##
##  1. `keys` — handgeschriebene Kennungen wie `ui.back_to_lobby`. Sie sind
##     stabil, wenn der deutsche Satz sich umformuliert, und sie erlauben eine
##     Übersetzung pro Kontext. Im Code: `Loc.t("ui.back_to_lobby")`.
##  2. `text` — der deutsche Quellstring *als* Schlüssel, z. B. `"◀ Lobby"`.
##     Damit bekommt jede vorhandene Beschriftung eine Übersetzung, ohne dass
##     650 Aufrufstellen umgeschrieben werden müssen. Im Code entsteht sie
##     nirgends: `Ui.label`, `Ui.button`, `Ui.title`, `notify` und `show_toast`
##     schicken ihren Text durch `resolve()`.
##
## Fehlt eine Übersetzung, gilt die Kette **aktive Sprache → `de` → der
## Schlüssel selbst**. Ein Spieler sieht also immer einen Satz, nie
## `ui.back_to_lobby` und nie eine leere Zeile. Welche Sprache wie weit
## übersetzt ist, sagt `coverage()`.
##
## ## `resolve()` ist idempotent
##
## `Ui.label(Loc.t("ui.play"))` ist ein sehr wahrscheinlicher Aufruf. Würde
## `resolve()` das Ergebnis erneut übersetzen, hinge die Anzeige davon ab, ob
## ein übersetzter Satz zufällig selbst ein Quellstring ist — „Lobby" ist im
## Französischen „Lobby", im Deutschen aber ein Quellstring. Deshalb merkt sich
## `_values` jede Zeichenkette, die der Katalog *herausgibt*, und `resolve()`
## gibt sie unverändert zurück. Ein zweiter Durchlauf ist damit eine
## No-Op, und die Frage stellt sich nicht mehr.
##
## ## Zahlen
##
## `Ui.format_number` ging fest von `.` als Tausendertrennzeichen aus — in
## Deutsch richtig, überall sonst falsch. `Loc.number` liest die Trennzeichen aus
## dem Katalog, deshalb steht `1.234` in Deutsch und `1,234` in Englisch da.
##
## ## Persistenz
##
## `Loc` besitzt keine `ConfigFile`. Die bleibt bei `Game` (`user://singular80.cfg`),
## damit es eine Datei und nicht zwei gibt; `Loc` schreibt über
## `Game.set_language`. Fehlt das Autoload — im `--script`-Testlauf — bleibt die
## Auswahl im Speicher, und das ist genau richtig: ein Test soll die Sprache
## wechseln können, ohne die Spielerdatei anzufassen.

const DIR := "res://assets/locale"
## Sprache, in der der Quelltext im Code steht. Sie ist der Rückfall für alle
## anderen und muss deshalb immer einen Katalog haben.
const SOURCE := "de"

static var _booted := false
static var _code := ""
static var _keys: Dictionary = {}
static var _text: Dictionary = {}
## Jede Zeichenkette, die der aktive Katalog herausgibt. Das ist der Grund, warum
## `resolve()` zweimal hintereinander dasselbe liefert.
static var _values: Dictionary = {}
static var _numbers: Dictionary = {"decimal": ".", "group": ",", "percent": " %"}
static var _catalogues: Dictionary = {}
static var _registered := false
## German template -> how many `%` placeholders it has. Only the source counts;
## every other catalogue is measured against it before it is used.
static var _specifiers: Dictionary = {}

const _MISSING := "__loc_missing__"


# --- Start -------------------------------------------------------------------

## Lädt die Kataloge und setzt die Sprache, die der Spieler gewählt hat — beim
## ersten Start die des Geräts. Idempotent, weil sich `Ui` auch ohne den
## ausdrücklichen Aufruf von `main.gd` die Sprache holen können muss.
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
	# Kein Katalog lesbar: der Schlüssel *ist* der deutsche Quelltext, also ist
	# das Verhalten exakt das von vor der Mehrsprachigkeit.
	_code = SOURCE


func _ensure() -> void:
	if not _booted:
		boot()


static func _load_all() -> void:
	_catalogues.clear()
	var dir := DirAccess.open(DIR)
	if dir == null:
		push_warning("Loc: %s nicht lesbar — das Spiel bleibt in der Quellsprache." % DIR)
		return
	# The source language first: it supplies the sentences every translation is
	# measured against. `DirAccess` does not sort, and an alphabet with `en`
	# before `de` would take every translation unchecked.
	var files := dir.get_files()
	files.sort_custom(func(a: String, b: String) -> bool:
		var rank := func(name: String) -> int:
			return 0 if name == "%s.json" % SOURCE else 1
		return rank.call(a) < rank.call(b))
	for file in files:
		if not file.ends_with(".json"):
			continue
		var raw := FileAccess.get_file_as_string("%s/%s" % [DIR, file])
		var parsed: Variant = JSON.parse_string(raw)
		if not (parsed is Dictionary):
			push_warning("Loc: %s ist kein Objekt und wird übersprungen." % file)
			continue
		var catalogue: Dictionary = parsed
		var code := str(catalogue.get("code", file.trim_suffix(".json")))
		if code == "":
			continue
		_catalogues[code] = {
			"name": str(catalogue.get("name", code)),
			"native": str(catalogue.get("native", catalogue.get("name", code))),
			"keys": _checked(code, catalogue.get("keys", {})),
			"text": _checked(code, catalogue.get("text", {})),
			"numbers": catalogue.get("numbers", {}) if catalogue.get("numbers", {}) is Dictionary else {},
		}
	_register_translations()


## How many `%` placeholders a text has — `%%` does not count as one.
##
## A translator who drops a placeholder does not produce a bad sentence, they
## produce an exception in the middle of a game: `String % Array` aborts when the
## counts disagree. A translation with the wrong count is therefore **dropped**
## and the German original is used instead. A sentence in the wrong language is
## an annoyance; a crashed game is a bug report, filed by a player.
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
		while j < text.length() and "-+ #0123456789.*".contains(text[j]):
			j += 1
		if j < text.length() and "sdfxXo".contains(text[j]):
			count += 1
		i = j + 1
	return count


## Drops translations whose placeholder count differs from the German original.
static func _checked(code: String, section: Variant) -> Dictionary:
	if not (section is Dictionary):
		return {}
	var out: Dictionary = {}
	for key in section:
		var value: Variant = section[key]
		if not (value is String):
			out[key] = value
			continue
		if code == SOURCE:
			_specifiers[key] = _count_specifiers(value)
			out[key] = value
			continue
		if not _specifiers.has(key) or _count_specifiers(value) == int(_specifiers[key]):
			out[key] = value
			continue
		push_warning("Loc: '%s' in %s has a different placeholder count than the German text and stays unused."
			% [key, code])
	return out


## Meldet die Kataloge auch Godots `TranslationServer`.
##
## Damit funktioniert `tr("ui.play")` und, wichtiger, `Control` übersetzt seinen
## Text bei `set_locale` von selbst neu — was dynamisch gesetzte Beschriftungen
## (der Ton-Knopf, eine Statuszeile) ohne Sonderbehandlung mitnimmt. Die
## bevorzugte Schreibweise im Code bleibt `Loc.t`, weil nur sie die
## Rückfallkette und die Platzhalter kennt.
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
		# Pluralformen als `key/one`, `key/other` — `tr()` kennt keine
		# Pluralregeln, deshalb bekommen sie je eine eigene Kennung.
		for form in value:
			translation.add_message("%s/%s" % [key, form], str(value[form]))


static func _apply(code: String) -> void:
	var catalogue: Dictionary = _catalogues.get(code, {})
	_code = code
	_keys = catalogue.get("keys", {})
	_text = catalogue.get("text", {})
	_numbers = {"decimal": ".", "group": ",", "percent": " %", **catalogue.get("numbers", {})}
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


# --- Sprache wählen ----------------------------------------------------------

## Die aktive Sprache, z. B. `"en"`.
static func code() -> String:
	_ensure()
	return _code


static func is_source() -> bool:
	return code() == SOURCE


## Alle Sprachen mit Katalog, nach eigenem Namen sortiert — die Sprachauswahl
## zeigt den Namen in der Sprache, die sie bezeichnet („Deutsch", „English",
## „Français"), nicht „de".
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


## Wechselt die Sprache, merkt sie sich und stellt Godot darauf ein.
##
## Akzeptiert auch, was das Gerät meldet: `"fr_FR"` findet den Katalog `fr`.
## Ein unbekannter Code ändert nichts und liefert `false` — stillschweigend auf
## eine andere Sprache zu fallen wäre schlimmer als eine Meldung.
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


## Die vom Spieler gespeicherte Wahl, oder `""`.
static func stored_code() -> String:
	var game := _game()
	if game != null and game.has_method("language"):
		return str(game.call("language"))
	return ""


## Die Sprache des Geräts, auf zwei Buchstaben gebracht (`de`).
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


# --- Übersetzen --------------------------------------------------------------

## Übersetzt eine Kennung, z. B. `Loc.t("ui.back_to_lobby")`.
##
## `args` ersetzt `{platzhalter}` in der Übersetzung. Das ist `String.format`
## aus zwei Gründen nicht vorzuziehen: die Reihenfolge der Argumente ist in
## anderen Sprachen anders, und ein fehlendes Argument ist bei `%s` ein Absturz
## mitten im Spiel statt eines Satzes mit einer Lücke.
static func t(key: String, args: Dictionary = {}) -> String:
	if key == "":
		return ""
	_ensure()
	return _interpolate(_raw(key), args)


## Wie `t`, wählt aber die Pluralform passend zur Zahl.
static func tn(key: String, count: int, args: Dictionary = {}) -> String:
	if key == "":
		return ""
	_ensure()
	var filled := args.duplicate()
	filled["count"] = count
	filled["n"] = count
	return _interpolate(_raw(key, float(count)), filled)


## Übersetzt einen deutschen Quelltext. Wird von `Ui` und den Basisklassen
## benutzt; im Spielcode ruft man `t`.
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
##
## `Ui.label("Bestwert: %s" % best)` is untranslatable in that order: the string is
## formatted first and labelled second, so the catalogue would have to hold a
## finished sentence with the name already inside it. `Loc.f` reverses the order
## without rewriting the text:
##
##     Loc.f("Bestwert: %s", [best])
##
## The template keeps its `%` placeholders, so a translation has to carry them
## over unchanged. That is checked when the catalogue is read (`_checked`),
## because a forgotten placeholder would otherwise be a crash rather than a
## sentence.
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
	# Rückfall auf die Quellsprache: eine halb übersetzte Sprache soll an den
	# Stellen Deutsch zeigen, an denen sie noch nichts hat — nicht den Schlüssel.
	var source: Dictionary = _catalogues.get(SOURCE, {})
	var source_keys: Dictionary = source.get("keys", {})
	var source_text: Dictionary = source.get("text", {})
	if source_keys.has(key):
		return _pick(source_keys[key], count)
	if source_text.has(key):
		return _pick(source_text[key], count)
	return key


## Ein Eintrag ist entweder eine Zeichenkette oder eine Liste von Pluralformen.
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


## CLDR, so weit die Katalogsprachen kommen.
##
## Deutsch, Englisch und Spanisch haben nur `one` bei genau einer Sache. Das
## Französische zählt auch die Null zum Singular — „0 point", nicht „0 points" —
## und genau daran scheitern die meisten Übersetzungen. Für Sprachen mit `few`
## und `many` (Slawisch, Polnisch) gehört hier je eine Regel hinein; `other` ist
## der Rückfall, deshalb bricht eine fehlende Form nichts.
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


# --- Zahlen ------------------------------------------------------------------

## `1234` → `1.234` (deutsch) bzw. `1,234` (englisch).
static func number(value: int) -> String:
	_ensure()
	var negative := value < 0
	return ("-" if negative else "") + _grouped(str(absi(value)))


## `1.5` → `1,5`. Die Tausendertrennung bleibt, denn eine Punktzahl über 1000
## kommt in jedem Spiel vor.
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


## `0.42` → `42 %`.
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


# --- Deckung -----------------------------------------------------------------

## Anteil der Schlüssel, die in `code` übersetzt sind (0.0 … 1.0). Ein
## übersetzter Eintrag ist einer, der sich vom deutschen Quelltext unterscheidet
## — ein eingetragener, aber unveränderter Wert zählt nicht als fertig.
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
			total += 1
			if str(have.get(key, "")) != str(want[key]) and str(have.get(key, "")) != "":
				done += 1
	return float(done) / float(total) if total > 0 else 1.0


## Die Schlüssel, die in `code` noch auf Deutsch stehen. Für Tests und für die
## Sprachauswahl, die sagen darf, wie weit eine Sprache ist.
static func missing(code: String) -> PackedStringArray:
	_ensure()
	var source: Dictionary = _catalogues.get(SOURCE, {})
	var catalogue: Dictionary = _catalogues.get(code, {})
	var out := PackedStringArray()
	for section in ["keys", "text"]:
		var want: Dictionary = source.get(section, {})
		var have: Dictionary = catalogue.get(section, {})
		for key in want:
			var translated := str(have.get(key, ""))
			if translated == "" or translated == str(want[key]):
				out.append(key)
	return out


## Leert den Zwischenspeicher. Nur für Tests: im Spiel wird die Sprache
## ein einziges Mal geladen.
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
