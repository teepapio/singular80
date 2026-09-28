class_name AppLegal
extends RefCounted
## The app's legal and reporting addresses in one place.
## Google Play demands two things of the suggestion feature: the player must
## **accept the terms before** sending anything, and must be able to **report
## objectionable content** without leaving the game. Both hang on the same
## addresses, which is why they live here and not in two screens.
## Pure logic, no renderer, so the suite can check it without a window.

## Public pages. `googleplay/config/app.json` -> `urls`.
const TERMS_URL := "https://example.invalid/terms"
const PRIVACY_URL := "https://example.invalid/privacy"
## Mailbox the reports go to.
const MODERATION_MAIL := "moderation@example.invalid"

## The reasons from §4 of the terms, in the same order. The player picks one, so
## the report is classified on arrival and is not just "I don't like it".
## This list is **German and stays that way**: it goes into the report to the
## moderation address unchanged, and that is an internal document, not game text.
## Only what the player reads in the menu is translated — hence `REASON_LOC_KEYS`.
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

## Shortens for display and mail without tearing the meaning apart.
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


## Not filled in yet? Then the suggestion dialog must not enable its send button
## — an honest notice beats an invented address.
static func is_configured() -> bool:
	return not TERMS_URL.contains("example.invalid") and not MODERATION_MAIL.contains("example.invalid")


## The addresses still missing from the config, for the error message and the
## final check in the Play project.
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


## Subject line of the report. The id comes first so reports sort in the mailbox
## without anyone reading the body.
##
## Deliberately German and with no catalogue: this text goes to a human being in a
## mailbox, not to the interface. Translating it would create a second language
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


## `mailto:` URL. On Android that does not always open a composer, which is why
## the dialog also offers the clipboard.
static func report_mailto(id: int, text: String, reason: String, note: String) -> String:
	return "mailto:%s?subject=%s&body=%s" % [
		MODERATION_MAIL.uri_encode(),
		report_subject(id).uri_encode(),
		report_body(id, text, reason, note).uri_encode(),
	]


## The text that goes to the clipboard — identical to the mail body, so a
## reporter without a mail app has nothing to type.
static func report_message(id: int, text: String, reason: String, note: String) -> String:
	return report_body(id, text, reason, note)
