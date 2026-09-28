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

var t: TestKit
var tree: SceneTree


func run(kit: TestKit, scene: SceneTree) -> void:
	t = kit
	tree = scene
	_catalogue()
	_resolution()
	_placeholders()
	_plurals()
	_numbers()
	_switching()
	_ui()
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
	// A German string inside an English sentence can never be looked up, because
	// the catalogue is keyed by English.
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
