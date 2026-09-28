extends RefCounted
## Tests for the language layer: catalogues, resolution, plurals and formatting.
##
## This file exists because the 133 other suites would not have noticed any of
## it. They assert on ids, sizes, pool counts and numbers; not one of them looks
## at a caption. A missing key, a translation with a lost placeholder or a
## separator that is wrong in every language except German would all have gone
## through a green run and shown up as a screen full of `ui.back_to_lobby`.

## The pivot: the language the *code* is written in, and therefore the source
## catalogue. `godot/src` holds English literals, `sync` derives `en.json` from
## them, and `de.json` / `fr.json` translate that — German is a language of the
## game like any other, not the one it is written in.
const SOURCE := "en"

## The language the rest of the suite asserts on. `run_tests.gd` pins it before
## anything runs, because `Loc` otherwise follows the device.
const PINNED := "de"
## The one plural entry of the source.
const PLURAL := "ui.queue_waiting"
## Where a language change ends up if it is allowed to write.
const PLAYER_CONFIG := "user://singular80.cfg"

var t: TestKit
var tree: SceneTree


## Entry point used by `run_tests.gd`.
##
## Every suite is followed by `t.close_suite()`. A GDScript runtime error unwinds
## a function without raising, so a suite that died half-way through reached its
## caller's next line looking perfectly healthy — and the assertions it never got
## to were never counted either. `close_suite()` turns the missing
## `t.suite_done()` into the failure it always was.
func run(kit: TestKit, scene: SceneTree) -> void:
	t = kit
	tree = scene
	_catalogue()
	t.close_suite()
	_resolution()
	t.close_suite()
	_placeholders()
	t.close_suite()
	_plurals()
	t.close_suite()
	_numbers()
	t.close_suite()
	_switching()
	t.close_suite()
	_ui()
	t.close_suite()
	_idempotence()
	t.close_suite()
	_plural_forms()
	t.close_suite()
	_player_file()
	t.close_suite()
	_template_contract()
	t.close_suite()
	_dropped_placeholders()
	t.close_suite()
	_known()
	t.close_suite()
	_number_edges()
	t.close_suite()
	_cold_boot()
	t.close_suite()
	_translations()
	t.close_suite()
	_restore()


## Puts the language back, whatever happened above.
func _restore() -> void:
	Loc.reset()
	Loc.set_code(PINNED)


func _catalogue() -> void:
	t.suite("Sprachen — Kataloge")
	Loc.reset()
	Loc.boot()
	var codes := Loc.codes()
	t.check(codes.size() >= 2, "Mindestens eine Zielsprache ist dabei (nur: %s)" % ", ".join(codes))
	t.check(codes.has(SOURCE), "Die Quellsprache %s hat einen Katalog" % SOURCE)

	# `available()` is what the language picker renders, so the name has to be the
	# one the language calls itself — "Deutsch", "English", "Français" — and not
	# the code. A picker that says "fr" helps nobody who cannot read it.
	for entry in Loc.available():
		t.check(str(entry["native"]) != str(entry["code"]),
			"„%s“ nennt sich selbst, nicht nur „%s“" % [entry["code"], entry["code"]])
	Loc.set_code("en")
	t.equal(Loc.native_name("en"), "English", "Der eigene Name wird in der Sprache gezeigt")
	t.equal(TranslationServer.get_locale(), "en", "Godot steht auf derselben Sprache")

	# The source is what every other language falls back to, so it has to answer
	# with its own text. `missing(SOURCE)` is deliberately not the measure here:
	# that function compares a catalogue against the source, and for the source
	# every entry looks untranslated — it would report all 674 as missing.
	Loc.set_code(SOURCE)
	t.equal(Loc.t("ui.close"), "Close", "Die Quelle antwortet mit ihrem eigenen Text")
	t.equal(Loc.resolve("Felled"), "Felled", "…auch bei einem Quellstring")
	t.equal(Loc.t("ui.gibt.es.nicht"), "ui.gibt.es.nicht", "…und erfindet nichts für einen unbekannten Schlüssel")
	# German is a translation now, and it is the one the game defaults to, so it
	# has to be reachable and complete like any other.
	Loc.set_code(PINNED)
	t.equal(Loc.t("ui.close"), "Schließen", "Deutsch antwortet mit dem Deutschen")
	for code in Loc.codes():
		if code == SOURCE:
			continue
		t.check(Loc.coverage(code) >= 0.999,
			"„%s“ ist übersetzt (%.1f %%)" % [code, Loc.coverage(code) * 100.0])
		t.check(Loc.missing(code).is_empty(), "„%s“ hat nichts Offenes mehr" % code)
	t.suite_done()


func _resolution() -> void:
	t.suite("Sprachen — Auflösung")
	Loc.reset()
	Loc.set_code(PINNED)

	t.equal(Loc.t("ui.close"), "Schließen", "Eine Kennung wird übersetzt")
	t.equal(Loc.resolve("Vorschlag"), "Vorschlag", "Im Deutschen bleibt der Quellstring, wie er ist")
	Loc.set_code("en")
	t.equal(Loc.t("ui.close"), "Close", "Im Englischen wird dieselbe Kennung übersetzt")
	t.equal(Loc.resolve("Suggestion"), "Suggestion", "Ein englischer Quellstring bleibt, wie er ist")
	t.equal(Loc.resolve("gibt es nicht"), "gibt es nicht", "Unbekanntes bleibt unverändert")
	t.equal(Loc.t("ui.gibt.es.nicht"), "ui.gibt.es.nicht", "Eine unbekannte Kennung zeigt sich selbst, nicht nichts")
	# The frame translates, the value does not — and that is the bug this guards.
	# A German string inside an English sentence can never be looked up, because
	# the catalogue is keyed by English.
	t.equal(Loc.resolve(Loc.t("ui.suggest_origin", {"game": "Board games"})), "From: Board games",
		"Ein eingesetztes Argument bleibt unangetastet")

	# The whole design rests on this: a caption may pass through `Ui.label` more
	# than once without drifting. `Ui.label(Loc.t(...))` is a likely call, and
	# „Lobby" is the same word in German and French while being a source string.
	t.equal(Loc.resolve(Loc.t("ui.back_to_lobby")), Loc.t("ui.back_to_lobby"),
		"Ein zweiter Durchlauf ändert nichts")
	t.equal(Loc.resolve(Loc.resolve("Board games")), "Board games", "Auch zweimal aufgelöst bleibt es übersetzt")
	Loc.set_code(PINNED)
	t.equal(Loc.resolve(Loc.resolve("Brettspiele")), "Brettspiele", "…und im Deutschen ebenso")
	t.check(Loc.has("ui.close"), "Eine vorhandene Kennung wird erkannt")
	t.check(not Loc.has("ui.nein"), "Eine fehlende Kennung wird nicht behauptet")
	t.suite_done()


func _placeholders() -> void:
	t.suite("Sprachen — Platzhalter")
	Loc.reset()
	Loc.set_code("de")
	t.equal(Loc.t("ui.server_caption", {"state": "offline"}), "Server: offline",
		"Ein benannter Platzhalter wird eingesetzt")
	t.equal(Loc.t("ui.suggest_origin", {"game": "Tetris"}), "Aus: Tetris",
		"Ein zweiter benannter Platzhalter auch")
	t.equal(Loc.f("Punkte: %s", ["12"]), "Punkte: 12", "Eine Vorlage wird übersetzt und dann formatiert")
	t.equal(Loc.f("Points: %s", ["12"]), "Punkte: 12", "Dieselbe Vorlage aus der Quelle")

	Loc.set_code("en")
	t.equal(Loc.t("ui.server_caption", {"state": "offline"}), "Server: offline",
		"Die Übersetzung setzt denselben Platzhalter ein")
	t.equal(Loc.f("Points: %s", ["12"]), "Points: 12", "Die Vorlage wurde vor dem Formatieren übersetzt")
	t.equal(Loc.f("Punkte: %s", ["12"]), "Punkte: 12", "…und im Deutschen übersetzt")

	# A missing argument leaves the hole visible instead of crashing. The
	# alternative is a `%s` in production, which is a crash the player reports.
	t.check(Loc.t("ui.server_caption").contains("{state}"),
		"Ein fehlendes Argument zeigt die Lücke, statt zu reißen")

	# Every entry that is translated has to keep the arguments of its source, or
	# `String % Array` throws in the middle of a game. `Loc` drops such a
	# translation; this asserts that none slipped in and that none is left
	# half-done. The source is skipped: it is the measure, not a translation.
	Loc.reset()
	Loc.boot()
	for code in Loc.codes():
		if code == SOURCE:
			continue
		t.check(Loc.missing(code).is_empty(), "„%s“ verliert keinen Platzhalter" % code)
	t.suite_done()


func _plurals() -> void:
	t.suite("Sprachen — Plural")
	Loc.reset()
	Loc.set_code("de")
	t.check(Loc.tn("ui.queue_waiting", 1).contains("Vorschlag wartet"),
		"Deutsch: ein Wartender wird einzeln genannt")
	t.check(Loc.tn("ui.queue_waiting", 3).contains("3 Vorschläge"),
		"Deutsch: mehrere werden gezählt")

	# The rule most translations get wrong: French counts zero as singular, so
	# "0 suggestions" is wrong and "0 suggestion" is right.
	Loc.set_code("fr")
	t.check(Loc.tn("ui.queue_waiting", 0).contains("0 suggestion "),
		"Französisch zählt die Null zum Singular")
	t.check(Loc.tn("ui.queue_waiting", 1).contains("1 suggestion "),
		"Französisch: einer")
	t.check(Loc.tn("ui.queue_waiting", 3).contains("3 suggestions"),
		"Französisch: mehrere")

	Loc.set_code("en")
	t.check(Loc.tn("ui.queue_waiting", 0).contains("0 suggestions"),
		"Englisch zählt die Null als Plural")
	t.check(Loc.tn("ui.queue_waiting", 1).contains("1 suggestion is"),
		"Englisch: einer ohne s")
	t.suite_done()


func _numbers() -> void:
	t.suite("Sprachen — Zahlen")
	Loc.reset()
	Loc.set_code("de")
	# This used to be hard-coded to `.`, which is right in German and wrong
	# everywhere else — and with a digit between the groups it is not readable
	# at all.
	t.equal(Loc.number(1234567), "1.234.567", "Deutsch: Punkt als Tausendertrenner")
	t.equal(Loc.number(999), "999", "Unter tausend gibt es keine Gruppe")
	t.equal(Loc.number(-4321), "-4.321", "Das Minus bleibt davor")
	t.equal(Loc.decimal(1.5), "1,5", "Deutsch: Komma als Dezimaltrenner")

	Loc.set_code("en")
	t.equal(Loc.number(1234567), "1,234,567", "Englisch: Komma als Tausendertrenner")
	t.equal(Loc.decimal(1.5), "1.5", "Englisch: Punkt als Dezimaltrenner")

	Loc.set_code("fr")
	t.equal(Loc.number(1234567), "1 234 567", "Französisch: schmales Leerzeichen")
	t.equal(Loc.decimal(1.5), "1,5", "Französisch: Komma")

	# `Ui.format_number` had 46 call sites and one hard-coded separator; this is
	# the assertion that they all changed at once.
	Loc.set_code("en")
	t.equal(Ui.format_number(1234567), "1,234,567", "Ui reicht es an die Sprache weiter")
	Loc.set_code("de")
	t.equal(Ui.format_number(1234567), "1.234.567", "…und im Deutschen wieder zurück")
	t.suite_done()


func _switching() -> void:
	t.suite("Sprachen — Wechsel")
	Loc.reset()
	Loc.set_code("de")
	# The device reports `fr_FR`; the catalogue knows `fr`. Falling back silently
	# would leave a French phone in German for no visible reason.
	t.check(Loc.set_code("fr_FR"), "Eine Region wird auf ihre Sprache zurückgeführt")
	t.equal(Loc.code(), "fr", "…und ist danach aktiv")
	t.check(not Loc.set_code("xx"), "Ein unbekannter Code wird abgelehnt")
	t.equal(Loc.code(), "fr", "…und die Sprache bleibt, statt still zu fallen")
	t.check(Loc.set_code("en"), "Ein bekannter Code wird angenommen")
	t.equal(TranslationServer.get_locale(), "en", "Godot wurde mitgezogen")
	t.suite_done()


func _ui() -> void:
	t.suite("Sprachen — Oberfläche")
	Loc.reset()
	Loc.set_code("en")
	# The seam: every caption in the game is created through one of these.
	t.equal(Ui.label("Suggestion").text, "Suggestion", "Ui.label lässt den Quellstring stehen")
	t.equal(Ui.button("Close", Vector2(120, 40)).text, "Close", "Ui.button ebenso")
	t.equal(Ui.title("Horse Course 3D").text, "Horse Course 3D", "Ui.title ebenso")
	Loc.set_code(PINNED)
	t.equal(Ui.label("Vorschlag").text, "Vorschlag", "Im Deutschen bleibt er deutsch")
	t.equal(Ui.title("Pferde-Parcours 3D").text, "Pferde-Parcours 3D", "…auch der Spielname")
	Loc.set_code("en")
	t.equal(Ui.label("Vorschlag").text, "Vorschlag", "Ein deutscher String ist kein Quellstring mehr")
	t.equal(Ui.label("SINGULAR 80").text, "SINGULAR 80", "Der Markenname bleibt wie er ist")
	t.equal(Ui.label("").text, "", "Leerer Text wird nicht erfunden")

	# A caption that changes while the game runs — the mute button, a status
	# line — is the one a translated build forgets, because it never goes through
	# a factory. `SettingsDialog` and both screen bases use these.
	t.check(Loc.t("ui.sound_on") != Loc.t("ui.sound_off"),
		"Der Tonknopf hat zwei verschiedene Beschriftungen")
	t.check(Loc.t("ui.sound_on").contains("♪"), "…mit demselben Symbol")
	t.check(Loc.t("ui.settings_short") == "⚙", "Der Zahnrad-Knopf ist in beiden Sprachen gleich")
	t.check(Loc.t("ui.on") != Loc.t("ui.off"), "Ein Schalter hat zwei verschiedene Zustände")

	# The report dialog offers the reason in the player's language and still
	# reports the German one, which is what the mailbox gets.
	t.equal(AppLegal.reason_label(0), "Insult or hate speech", "Der Meldegrund ist übersetzt")
	t.equal(AppLegal.REASONS[0], "Beleidigung oder Hassrede", "…und die Meldung bleibt deutsch")
	Loc.set_code("de")
	t.equal(AppLegal.reason_label(0), "Beleidigung oder Hassrede", "Im Deutschen ist beides dasselbe")
	t.suite_done()


## `resolve` is the seam the whole language layer stands on: a caption may pass
## through `Ui.label` twice without drifting. Two strings carried that until now
## — the suite below walks every key of every catalogue in every language, and
## then asks the question that decides whether the property holds by accident or
## by construction: can `resolve` ever find a key in a sentence the language
## layer produced itself?
func _idempotence() -> void:
	t.suite("Sprachen — Idempotenz gesamt")
	Loc.reset()
	Loc.boot()
	var source := _read_catalogue(SOURCE)
	t.check(source.has("keys") and source.has("text"), "Die Quelle ist auch als Datei lesbar")

	for code in Loc.codes():
		Loc.set_code(code)
		var catalogue := _read_catalogue(code)
		var drift := PackedStringArray()
		for key in (catalogue.get("keys", {}) as Dictionary):
			var once := Loc.t(str(key))
			if Loc.resolve(once) != once:
				drift.append(str(key))
		t.check(drift.is_empty(),
			"„%s“ übersetzt keine einzige Kennung ein zweites Mal (%d tun es%s)"
			% [code, drift.size(), _first(drift)])

		# The same for the source strings: `Ui.label` hands a caption it has
		# already translated back into `resolve`, and 730 of them are what the
		# game labels with.
		var texts := PackedStringArray()
		for key in (source.get("text", {}) as Dictionary):
			var once := Loc.resolve(str(key))
			if Loc.resolve(once) != once:
				texts.append(str(key))
		t.check(texts.is_empty(),
			"„%s“ übersetzt keinen Quellstring ein zweites Mal (%d tun es%s)"
			% [code, texts.size(), _first(texts)])

	# A translated sentence that is spelled like an English caption is one
	# `resolve` away from being translated twice — and it is invisible until the
	# day one of the two sentences changes. An entry that still reads like the
	# source is not a translation and not a collision: it is the source text, and
	# resolving it gives the same string back. The source language itself is
	# skipped for the same reason, it collides with itself by construction.
	var source_templates := source.get("text", {}) as Dictionary
	for code in Loc.codes():
		if code == SOURCE:
			continue
		var catalogue := _read_catalogue(code)
		var collisions := PackedStringArray()
		for section: String in ["keys", "text"]:
			var want := _units(source, section)
			var have := _units(catalogue, section)
			for unit in have:
				var value := str(have[unit])
				if value == str(want.get(unit, "")):
					continue
				if source_templates.has(value):
					collisions.append("%s/%s" % [section, unit])
		t.check(collisions.is_empty(),
			"„%s“ gibt keinen Satz aus, der zugleich ein englischer Quellstring ist (%d%s)"
			% [code, collisions.size(), _first(collisions)])
	t.suite_done()


## A plural is the one entry shape that can be *half* translated and still look
## done: `coverage` counted the entry, `missing` counts the form. A catalogue
## that lost "other" renders as "3 " in a queue, and a form whose `{name}` names
## differ from the source is an entry `Loc.t` cannot fill at all.
func _plural_forms() -> void:
	t.suite("Sprachen — Pluralformen")
	Loc.reset()
	Loc.boot()
	var source := _read_catalogue(SOURCE)
	var source_keys := source.get("keys", {}) as Dictionary
	var plurals := 0

	for key in source_keys:
		var want: Variant = source_keys[key]
		if not (want is Dictionary):
			continue
		plurals += 1
		for code in Loc.codes():
			var have: Variant = (_read_catalogue(code).get("keys", {}) as Dictionary).get(key, null)
			if not (have is Dictionary):
				t.check(false, "„%s“ führt „%s“ überhaupt als Plural" % [code, key])
				continue
			var want_forms := _sorted((want as Dictionary).keys())
			var have_forms := _sorted((have as Dictionary).keys())
			t.check(want_forms == have_forms,
				"„%s“ hält in „%s“ genau die Formen der Quelle, keine mehr und keine weniger"
				% [code, key])
			for form in want_forms:
				if not (have as Dictionary).has(form):
					continue
				t.check(_names(str((want as Dictionary)[form])) == _names(str((have as Dictionary)[form])),
					"„%s“ behält in „%s/%s“ die Platzhalter der Quelle" % [code, key, form])
	t.check(plurals > 0, "Die Quelle führt überhaupt einen Plural, sonst prüft diese Suite nichts")

	# Which form a number gets. French counts zero as singular — "0 suggestion",
	# not "0 suggestions" — and that is the rule most translations get wrong, so
	# the rule is written out here instead of being read back from `Loc`.
	for code in Loc.codes():
		Loc.set_code(code)
		var found: Variant = (_read_catalogue(code).get("keys", {}) as Dictionary).get(PLURAL, {})
		if not (found is Dictionary):
			t.fail("„%s“ führt „%s“ nicht als Plural, die Zahlen sind ungeprüft" % [code, PLURAL])
			continue
		var forms: Dictionary = found
		for count: int in [0, 1, 2, 3]:
			var sentence := _plural_sentence(forms, code, count)
			t.equal(Loc.tn(PLURAL, count), sentence,
				"„%s“ nennt %d mit der Form, die die Sprache dafür vorsieht" % [code, count])
			# …and a rendered plural has to survive the second pass like any other.
			t.check(Loc.resolve(Loc.tn(PLURAL, count)) == Loc.tn(PLURAL, count),
				"„%s“ übersetzt den fertigen Pluraltext nicht noch einmal" % code)
	t.suite_done()


## `Loc.set_code` persists through `Game.set_language`, and *that* writes the
## whole config — muted, loadout, server address, touch, highscores, stars. In a
## `--script` run the autoload is really there, so a green run would hand the
## developer who started it a game whose settings the suite had overwritten.
func _player_file() -> void:
	t.suite("Sprachen — Spielerdatei")
	var game := _autoload("Game")
	t.check(not Loc.persist, "Ein --script-Lauf schaltet das Mitschreiben der Sprachwahl ab")
	t.check(game != null and game.has_method("set_language"),
		"„Game“ kann die Wahl wirklich speichern — der Schalter ist alles, was davorsteht")

	var keep := str(game.get("language")) if game != null else ""
	var before := FileAccess.get_modified_time(PLAYER_CONFIG)
	Loc.set_code("fr")
	if game != null:
		game.set("language", keep)
	t.equal(Loc.code(), "fr", "Die Sprache wechselt trotzdem")
	t.check(game == null or str(game.get("language")) == keep,
		"Die gespeicherte Sprachwahl des Spielers bleibt von einem Sprachwechsel im Test unberührt")
	t.check(FileAccess.get_modified_time(PLAYER_CONFIG) == before,
		"Ein Sprachwechsel im Test fasst die Spielerdatei nicht an")
	t.suite_done()


## The order `Loc.f` promises: translate, then substitute. Five things follow
## from that and none of them was asserted: a template nobody translated still
## comes out readable, a value that is itself a caption gets translated too, a
## number stays a number, and a wrong number of values must not tear the level
## down.
func _template_contract() -> void:
	t.suite("Sprachen — Vorlagenvertrag")
	Loc.reset()
	Loc.set_code(PINNED)
	t.equal(Loc.f("Points: %s", ["12"]), "Punkte: 12",
		"Eine Vorlage aus der Quelle erscheint als „Punkte: 12“ statt englisch")
	# A composition template is deliberately no catalogue key — there is nothing
	# to translate about a template that is only punctuation — so the values are
	# the only strings in here that ever need translating. This is the call site
	# in `mesh_gallery_screen.gd` and `lobby3d_screen.gd`.
	t.equal(Loc.f("%s  %s", ["◼", "Board games"]), "◼  Brettspiele",
		"Ein eingesetzter Wert wird übersetzt, auch wenn die Vorlage selbst keine Übersetzung hat")
	# Only strings go through `resolve` on purpose: a `%d` handed a String is the
	# runtime formatting error this function exists to prevent.
	t.equal(Loc.f("+%d health", [5]), "+5 Leben",
		"Eine Zahl bleibt eine Zahl, sonst bricht das Formatieren mitten im Spiel ab")
	# Nothing in the catalogue has this one, which is the same path a *dropped*
	# translation takes: `resolve` finds no key and hands the template back.
	t.equal(Loc.f("Ergebnis: %s", ["3"]), "Ergebnis: 3",
		"Eine Vorlage ohne Katalogeintrag bleibt lesbar, statt zu reißen")

	var few := Loc.f("Points: %s", [])
	var many := Loc.f("Points: %s", ["12", "34"])
	t.check(not few.is_empty() and few.contains("Punkte:"),
		"Zu wenige Werte lassen eine lesbare Beschriftung stehen, statt das Level abzureißen")
	t.check(not many.is_empty() and many.contains("Punkte:"),
		"Zu viele Werte ebenso")

	Loc.set_code("en")
	t.equal(Loc.f("Points: %s", ["Close"]), "Points: Close",
		"Im Englischen bleibt der englische Wert stehen, statt übersetzt zu werden")
	Loc.set_code(PINNED)
	t.suite_done()


## A translation whose placeholders no longer match the source is unused, and
## the player gets the source text instead — so a bad translation is not a wrong
## sentence, it is an English one. Writing such a catalogue from here is not
## possible without corrupting the mirror the game ships, so the two halves are
## asserted apart: what the guard would drop, measured with the test's own ruler,
## and what the player gets to read in every language.
func _dropped_placeholders() -> void:
	t.suite("Sprachen — Platzhalterverworfen")
	Loc.reset()
	Loc.boot()
	var source := _read_catalogue(SOURCE)

	for code in Loc.codes():
		if code == SOURCE:
			continue
		var catalogue := _read_catalogue(code)
		var dropped := PackedStringArray()
		for section: String in ["keys", "text"]:
			var want := _units(source, section)
			var have := _units(catalogue, section)
			# A form the translation lost, and a form the source never had.
			for unit in want:
				if not have.has(unit):
					dropped.append("%s/%s" % [section, unit])
			for unit in have:
				if not want.has(unit):
					dropped.append("%s/%s" % [section, unit])
					continue
				if str(have[unit]) == str(want[unit]):
					continue
				# Letters, not a count: `%s` and `%d` both take one argument, so a
				# count would call them interchangeable — and a score handed to
				# `%d` reads "0" on the caption.
				if _signature(str(have[unit]), section == "keys") != _signature(str(want[unit]), section == "keys"):
					dropped.append("%s/%s" % [section, unit])
		t.check(dropped.is_empty(),
			"„%s“ hat keine Übersetzung, die der Wächter verwerfen müsste (%d%s)"
			% [code, dropped.size(), _first(dropped)])

	# And the half the player sees: whatever survived the guard has to be a
	# sentence. 178 templates, every language, nothing may come out with an open
	# `%s` in it or empty.
	for code in Loc.codes():
		Loc.set_code(code)
		var templates := 0
		var unusable := PackedStringArray()
		for key in (source.get("text", {}) as Dictionary):
			var template := str(key)
			# A percent sign in prose is not a placeholder, and handing such a
			# sentence to the formatter is what logs the error.
			if _conversions(template).is_empty():
				continue
			templates += 1
			var rendered := Loc.f(template, _values_for(template))
			if rendered.is_empty() or not _conversions(rendered).is_empty() or rendered.contains("{"):
				unusable.append("%s → %s" % [template, rendered])
		t.check(templates >= 20,
			"„%s“ hat überhaupt Vorlagen mit Platzhaltern, sonst prüft diese Suite nichts (%d)" % [code, templates])
		t.check(unusable.is_empty(),
			"„%s“ zeigt in keiner Vorlage einen offenen Platzhalter (%d von %d%s)"
			% [code, unusable.size(), templates, _first(unusable)])

	# The same for the named placeholders, which `Loc.t` fills and `Loc.f` never
	# sees: an argument that is missing leaves a `{name}` in the caption.
	var source_keys := source.get("keys", {}) as Dictionary
	for code in Loc.codes():
		Loc.set_code(code)
		var named := 0
		var holes := PackedStringArray()
		for key in source_keys:
			var template: Variant = source_keys[key]
			# A plural is filled by `tn`, and the form it picks is its own subject.
			if not (template is String):
				continue
			var wanted := _names(str(template))
			if wanted.is_empty():
				continue
			named += 1
			var args: Dictionary = {}
			for name in wanted:
				args[name.substr(1, name.length() - 2)] = "7"
			var rendered := Loc.t(str(key), args)
			if rendered.is_empty() or rendered.contains("{"):
				holes.append("%s → %s" % [key, rendered])
		t.check(named > 0, "„%s“ hat überhaupt benannte Platzhalter, sonst prüft diese Suite nichts" % code)
		t.check(holes.is_empty(),
			"„%s“ lässt in keiner Beschriftung eine {name}-Lücke stehen (%d von %d%s)"
			% [code, holes.size(), named, _first(holes)])
	t.suite_done()


## `has` is what a caller asks before it uses a key, and it has to answer for
## everything `t` can answer for: `t` falls back to the source catalogue, so a
## dropped or unwritten translation still produces a sentence while a `has`
## that only read the active catalogue would say "no" to a caption that is
## about to be created.
func _known() -> void:
	t.suite("Sprachen — Abfrage")
	Loc.reset()
	Loc.boot()
	var keys := _source_keys(_read_catalogue(SOURCE))
	t.check(keys.size() > 0, "Die Quelle führt überhaupt Einträge")
	for code in Loc.codes():
		Loc.set_code(code)
		var missing := PackedStringArray()
		for key in keys:
			if not Loc.has(key):
				missing.append(key)
		t.check(missing.is_empty(),
			"„%s“ verleugnet keine Kennung, für die Loc.t() eine Antwort hat (%d%s)"
			% [code, missing.size(), _first(missing)])
	Loc.set_code(PINNED)
	t.check(not Loc.has("ui.gibtsnicht"), "Eine Kennung, die in keinem Katalog steht, wird nicht behauptet")
	t.suite_done()


## The boundaries, and the one separator that is a space. Its code point is what
## is asserted: a narrow no-break space is the correct French typography, and a
## test that spells out U+0020 would forbid that fix instead of reporting it.
func _number_edges() -> void:
	t.suite("Sprachen — Zahlenränder")
	Loc.reset()
	Loc.set_code(PINNED)
	t.equal(Loc.number(0), "0", "Die Null bekommt keine leere Gruppe")
	t.equal(Loc.number(999), "999", "Unter tausend gibt es keine Gruppe")
	t.equal(Loc.number(1000), "1.000", "Genau tausend bekommt die erste Gruppe")
	t.equal(Loc.number(-1), "-1", "Das Minus steht vor der ersten Gruppe")
	t.equal(Loc.number(-1000), "-1.000", "…und bleibt auch mit einer Gruppe davor stehen")
	t.equal(Loc.decimal(0.0), "0,0", "Null behält ihre Nachkommastelle")
	t.equal(Loc.percent(0.42), "42 %", "Prozent rundet und hängt das Zeichen an")
	t.equal(Loc.percent(0.0), "0 %", "…auch bei null Prozent")

	Loc.set_code("en")
	t.equal(Loc.number(1000), "1,000", "Englisch steht die erste Gruppe nach drei Ziffern")
	t.equal(Loc.decimal(0.0), "0.0", "…mit Punkt als Dezimaltrenner")

	Loc.set_code("fr")
	var grouped := Loc.number(1000)
	t.check(grouped.length() == 5, "Französisch: fünf Zeichen für eine Tausendergruppe")
	var separator := grouped.unicode_at(1)
	t.check(separator == 0x20 or separator == 0x00A0 or separator == 0x202F,
		"Der französische Trenner ist ein Leerzeichen und kein Komma (U+%04X)" % separator)
	t.check(grouped.substr(2) == "000", "…und die Gruppen stehen dahinter")
	t.equal(Loc.number(-1), "-1", "…auch im Französischen bleibt das Minus vorn")
	t.equal(Loc.decimal(0.0), "0,0", "…mit Komma als Dezimaltrenner")
	t.equal(Loc.percent(0.42), "42 %", "…und einem Leerzeichen vor dem Prozentzeichen")
	t.suite_done()


## `boot()` is the first thing a launch does, and it ends on a locale: the stored
## choice, the device, or the source when nothing is readable. `Control` and
## `tr()` follow `TranslationServer`, so a boot that leaves the engine on a
## different language than `Loc` translates every label that was set dynamically
## — the sound button, a status line — into the wrong one.
func _cold_boot() -> void:
	t.suite("Sprachen — Kaltstart")
	var game := _autoload("Game")
	var keep := str(game.get("language")) if game != null else ""
	# "" is the first start: no choice made yet. "es" is a language this build
	# has no catalogue for — a config from an older build, or one from elsewhere.
	for stored: String in ["", PINNED, SOURCE, "fr", "es"]:
		if game != null:
			game.set("language", stored)
		Loc.reset()
		Loc.boot()
		t.check(not Loc.code().is_empty(),
			"Aus dem Kaltstart mit „%s“ kommt eine Sprache heraus" % stored)
		t.equal(TranslationServer.get_locale(), Loc.code(),
			"Godot steht nach dem Kaltstart mit „%s“ auf derselben Sprache wie Loc" % stored)
		if stored.is_empty() or not Loc.codes().has(stored):
			# The device, or a language the picker can reach again.
			t.check(Loc.code() == SOURCE or Loc.codes().has(Loc.code()),
				"Eine Wahl ohne Katalog („%s“) führt zu einer Sprache, die es im Spiel gibt" % stored)
		else:
			t.equal(Loc.code(), stored,
				"Eine gespeicherte Wahl („%s“) wird übernommen, nicht nebenbei überschrieben" % stored)
	if game != null:
		game.set("language", keep)
	Loc.reset()
	Loc.set_code(PINNED)
	t.suite_done()


## `TranslationServer` keeps every `Translation` it was given for the life of
## the process and resolves a message against the *oldest* one for a locale. A
## reset that does not hand the objects back therefore leaves one catalogue per
## reset in the engine, and `tr()` — which `Control` uses for its own
## re-translation — answers from a stale catalogue while `Loc.t` answers from
## the new one. Godot 4.5 has no `get_loaded_translations()`, so this asks the
## two things that can be asked: the number of locales with a translation, and
## whether the object behind one is a new one.
func _translations() -> void:
	t.suite("Sprachen — Übersetzungen")
	Loc.reset()
	Loc.boot()
	Loc.set_code(PINNED)
	var count := TranslationServer.get_loaded_locales().size()
	var first := TranslationServer.get_translation_object(PINNED)
	t.check(first != null, "Der Katalog ist als Übersetzung beim Server angemeldet")

	Loc.reset()
	Loc.boot()
	Loc.set_code(PINNED)
	t.equal(TranslationServer.get_loaded_locales().size(), count,
		"Ein Reset und ein Boot legen keinen weiteren Katalog beim Server an")
	var second := TranslationServer.get_translation_object(PINNED)
	t.check(second != null and second != first,
		"Der Reset nimmt die angemeldeten Übersetzungen wieder vom Server")

	# And what the engine says afterwards is what the language layer says.
	for code in Loc.codes():
		Loc.set_code(code)
		t.equal(tr("ui.close"), Loc.t("ui.close"),
			"„%s“ liest Godot aus demselben Katalog wie Loc, nicht aus einem alten" % code)
	t.suite_done()


# --- Reading the catalogues --------------------------------------------------

## One catalogue as the file on disk holds it. `Loc` needs no accessor for a
## catalogue's keys — a runtime does not ask "what does the file say" — and a
## test is allowed to read a file, so every question below is asked of the
## mirror the game actually ships.
func _read_catalogue(code: String) -> Dictionary:
	var path := "%s/%s.json" % [Loc.DIR, code]
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed is Dictionary:
		return parsed
	return {}


## One string per form of one entry: `{"ui.close": "Close", "ui.queue_waiting/other": …}`.
## A plural contributes one entry per form, so a comparison never meets a
## `Dictionary` where it expected a sentence.
func _units(catalogue: Dictionary, section: String) -> Dictionary:
	var out: Dictionary = {}
	var entries: Dictionary = catalogue.get(section, {})
	for key in entries:
		var value: Variant = entries[key]
		if value is Dictionary:
			for form in (value as Dictionary):
				out["%s/%s" % [key, form]] = str((value as Dictionary)[form])
		else:
			out[str(key)] = str(value)
	return out


## Every key the source can answer for: the ids of `keys` and the source strings
## of `text`, without the section in front of them.
func _source_keys(catalogue: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for section: String in ["keys", "text"]:
		for key in (catalogue.get(section, {}) as Dictionary):
			out.append(str(key))
	return out


## What a text has to keep to stay substitutable: the `{name}` placeholders, or
## the conversion letters of the `%` placeholders. `%%` is a literal percent sign
## and does not count, and a percent sign followed by a space is prose ("+12 %
## gold") — a letter after the space is a word, not a conversion.
func _signature(text: String, named: bool) -> String:
	return ",".join(_names(text)) if named else ",".join(_conversions(text))


func _names(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	var pattern := RegEx.new()
	pattern.compile("\\{[a-z_][a-z0-9_]*\\}")
	for found in pattern.search_all(text):
		out.append(found.get_string())
	out.sort()
	return out


func _conversions(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	var i := 0
	while i < text.length():
		if text[i] != "%":
			i += 1
			continue
		if i + 1 < text.length() and text[i + 1] == "%":
			i += 2
			continue
		# `%1$s` is positional: the number in front is a flag.
		var j := i + 1
		while j < text.length() and "-+#0123456789.*$".contains(text[j]):
			j += 1
		if j < text.length() and "sdfxXoiegcbu".contains(text[j]):
			out.append(text[j])
		i = j + 1
	return out


## One value per conversion, of the type the conversion wants — a `%d` handed a
## string is the runtime error this whole file is about.
func _values_for(template: String) -> Array:
	var out: Array = []
	for letter in _conversions(template):
		if "sc".contains(letter):
			out.append("7")
		elif "feg".contains(letter):
			out.append(7.0)
		elif "bu".contains(letter):
			out.append(true)
		else:
			out.append(7)
	return out


## Which plural form a language gives a number. CLDR as far as the catalogue
## languages reach: one at exactly one thing, and French counts zero with it.
## Spelled out here rather than read back from `Loc`, because the rule *is* what
## this suite is about.
func _plural_sentence(forms: Dictionary, code: String, count: int) -> String:
	var wanted := "one" if count == 1 or (code.begins_with("fr") and count == 0) else "other"
	if not forms.has(wanted):
		wanted = "other" if forms.has("other") else str(forms.keys()[0])
	var sentence := str(forms[wanted])
	for name in ["count", "n"]:
		sentence = sentence.replace("{%s}" % name, str(count))
	return sentence


func _sorted(values: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for value in values:
		out.append(str(value))
	out.sort()
	return out


## The first offender, for a failure message that has to name something.
func _first(entries: PackedStringArray) -> String:
	return "" if entries.is_empty() else ", zuerst: %s" % entries[0]


## Autoloads are no singletons in a `--script` run, so the node is fetched by
## path — the way `test_screens.gd` does it.
func _autoload(name: String) -> Node:
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null("/root/" + name)
