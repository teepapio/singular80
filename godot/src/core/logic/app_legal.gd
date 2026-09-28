class_name AppLegal
extends RefCounted
## The app's legal and reporting addresses in one place.
## Google Play demands two things of the suggestion feature: the player must
## **accept the terms before** sending anything, and must be able to **report
## objectionable content** without leaving the game. Both hang on the same
## addresses, which is why they live here and not in two screens.
## Pure logic, no renderer, so the suite can check it without a window.

## Public pages and the moderation mailbox.
##
## **These three constants are the single source.** The comment used to point at
## `googleplay/config/app.json` -> `urls`, which nothing in this repository ever
## reads: the game is built from the literals below, so the JSON was a second,
## unwired copy of the same three values. `googleplay/scripts/preflight.mjs`
## reads *these* lines and refuses a release while they still hold a
## placeholder, and the same preflight run compares them against the JSON, so
## the two ends cannot drift apart unnoticed any more.
##
## They are deliberately still `example.invalid`. An invented address that looks
## real is worse than an obvious one: the preflight has to fail on a build that
## still carries them, and `is_configured()` has to answer false so the report
## dialog says so instead of mailing into the void.
const TERMS_URL := "https://example.invalid/terms"
const PRIVACY_URL := "https://example.invalid/privacy"
## Mailbox the reports go to.
const MODERATION_MAIL := "moderation@example.invalid"

## The three values by name, so `missing()` walks a list instead of repeating
## three `if`s, and a fourth address only has to be added in one place.
const ADDRESSES := {
	"TERMS_URL": TERMS_URL,
	"PRIVACY_URL": PRIVACY_URL,
	"MODERATION_MAIL": MODERATION_MAIL,
}

## The same three as a list, which is what a release check walks:
## `googleplay/scripts/preflight.mjs` matches it against the addresses it
## expects, so a name added on one side only is noticed. That is also why the
## names are spelled out instead of taken from `ADDRESSES` — a release check
## cannot read a GDScript dictionary, only a list it can match against its own.
const ADDRESS_NAMES: Array[String] = ["TERMS_URL", "PRIVACY_URL", "MODERATION_MAIL"];

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
##
## All three are checked, not only the two the dialog needs: a build whose
## privacy page is still a placeholder is a build Play rejects, and finding that
## out from the console is a bad way to find it out.
static func is_configured() -> bool:
	return missing().is_empty()


## The addresses still missing from the config, for the error message and the
## final check in the Play project. Empty means the app may report abuse, and
## `googleplay/scripts/preflight.mjs` treats a non-empty list as a blocker.
static func missing() -> PackedStringArray:
	var out := PackedStringArray()
	for name in ADDRESS_NAMES:
		if str(ADDRESSES.get(name, "")).contains("example.invalid"):
			out.append(name)
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
