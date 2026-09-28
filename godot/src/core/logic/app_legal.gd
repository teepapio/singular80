class_name AppLegal
extends RefCounted
## Rechts- und Meldewege der App an einer Stelle.
##
## Google Play verlangt für die Vorschlagsfunktion zwei Dinge, die früher
## nirgends standen: die Spieler müssen die Nutzungsbedingungen **akzeptieren,
## bevor** sie etwas abschicken, und sie müssen **beanstandeten Inhalt melden
## können**, ohne das Spiel zu verlassen. Beides hängt an denselben Adressen —
## deshalb liegen sie hier, statt in zwei Bildschirmen verteilt zu sein.
##
## Reine Logik, ohne Renderer, damit die Suite sie ohne Fenster prüfen kann.

## Öffentliche Seiten. `googleplay/config/app.json` → `urls`.
const TERMS_URL := "https://example.invalid/terms"
const PRIVACY_URL := "https://example.invalid/privacy"
## Postfach, in das Meldungen gehen.
const MODERATION_MAIL := "moderation@example.invalid"

## Die Gründe aus §4 der Nutzungsbedingungen, in derselben Reihenfolge. Der
## Spieler wählt einen, damit die Meldung sofort eingeordnet werden kann und
## nicht nur „finde ich nicht gut".
##
## Diese Liste ist **deutsch und bleibt es**: sie geht unverändert in die
## Meldung an die Moderation, und die ist ein internes Dokument, kein Spieltext.
## Übersetzt wird nur, was der Spieler im Menü liest — dafür sind die
## Schlüssel in `REASON_LOC_KEYS` da.
const REASONS: Array[String] = [
	"Beleidigung oder Hassrede",
	"Personenbezogene Daten Dritter",
	"Sexueller oder gewaltbezogener Inhalt",
	"Werbung, Betrug oder Phishing",
	"Urheber- oder Markenrechte",
	"Sonstiges",
]

## Translation keys for the picker in the report dialog, parallel to `REASONS`.
##
## The suffix says what the array is *for*: `asset_registry.gd` has a dozen
## `const …_KEYS` lists full of asset names, and the locale extractor needs to
## tell "these are keys" from "these are mesh ids" without guessing.
const REASON_LOC_KEYS: Array[String] = [
	"legal.reason.insult",
	"legal.reason.personal_data",
	"legal.reason.sexual",
	"legal.reason.ad",
	"legal.reason.copyright",
	"legal.reason.other",
]

## Kürzt für Anzeige und Mail, ohne den Sinnezusammenhang zu zerreißen.
const MAX_QUOTE := 240


## The reason in the player's language. The German one goes into the report, the
## translated one into the picker — hence two lists instead of one.
static func reason_label(index: int) -> String:
	if index < 0 or index >= REASON_LOC_KEYS.size():
		index = REASON_LOC_KEYS.size() - 1
	return Loc.t(REASON_LOC_KEYS[index])


static func terms_url() -> String:
	return TERMS_URL


static func privacy_url() -> String:
	return PRIVACY_URL


static func moderation_mail() -> String:
	return MODERATION_MAIL


## Noch nicht ausgefüllt? Dann darf der Vorschlagsdialog den Absenden-Button
## nicht freigeben — lieber ein ehrlicher Hinweis als eine erfundene Adresse.
static func is_configured() -> bool:
	return not TERMS_URL.contains("example.invalid") and not MODERATION_MAIL.contains("example.invalid")


## Die im Konfigurationsfeld fehlenden Adressen, für die Fehlermeldung und
## die Endprüfung im Play-Projekt.
static func missing() -> PackedStringArray:
	var out := PackedStringArray()
	if TERMS_URL.contains("example.invalid"):
		out.append("TERMS_URL")
	if PRIVACY_URL.contains("example.invalid"):
		out.append("PRIVACY_URL")
	if MODERATION_MAIL.contains("example.invalid"):
		out.append("MODERATION_MAIL")
	return out


static func quote(text: String) -> String:
	var flat := text.strip_edges().replace("\n", " ").replace("\r", " ")
	if flat.length() <= MAX_QUOTE:
		return flat
	return flat.substr(0, MAX_QUOTE) + "…"


## Betreffzeile der Meldung. Die ID steht vorn, damit sich Meldungen im Postfach
## sortieren lassen, ohne den Text zu lesen.
##
## Deliberately German and with no catalogue: this text goes to a human being in
## a mailbox, not to the interface. Translating it would create a second language
## somebody has to maintain without a single player ever seeing it.
static func report_subject(id: int) -> String:
	return "Melde: Vorschlag #%d aus Singular 80" % id


static func report_body(id: int, text: String, reason: String, note: String) -> String:
	var parts: Array[String] = [
		"Melde: Vorschlag #%d" % id,
		"Grund: %s" % (reason if reason != "" else REASONS[REASONS.size() - 1]),
		"App: Singular 80 (de.singular80.game)",
		"Text: %s" % quote(text),
	]
	var extra := note.strip_edges()
	if extra != "":
		parts.append("Ergänzung: %s" % extra)
	parts.append("")
	parts.append("Bitte bestätigt kurz, was damit passiert.")
	return "\n".join(parts)


## `mailto:`-URL. Auf Android öffnet das nicht immer einen Composer — der Dialog
## bietet deshalb zusätzlich die Zwischenablage an.
static func report_mailto(id: int, text: String, reason: String, note: String) -> String:
	return "mailto:%s?subject=%s&body=%s" % [
		MODERATION_MAIL.uri_encode(),
		report_subject(id).uri_encode(),
		report_body(id, text, reason, note).uri_encode(),
	]


## Der Text, der in die Zwischenablage wandert — identisch mit dem Mail-Body,
## damit ein Meldende, das keine Mail-App hat, nichts tippen muss.
static func report_message(id: int, text: String, reason: String, note: String) -> String:
	return report_body(id, text, reason, note)
