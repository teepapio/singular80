class_name SuggestionContext
extends RefCounted
## Where a suggestion came from. The player should never have to type "this is
## about Tetris" — the game knows: every screen carries a label, which is put in
## front of the submitted text so the dashboard can group ideas by origin.

## Screens that are not playable games still deserve a label.
##
## The label lands in the `{game}` argument of `ui.suggest_origin`. The frame
## around it is translated; these values are the one place a German word would
## survive that, so they get keys and a lookup of their own.
const SCREEN_LOC_KEY := {
	"lobby": "ui.origin.lobby",
	"lobby_list": "ui.origin.lobby_list",
	"main_menu": "ui.origin.main_menu",
	"game_over": "ui.origin.game_over",
	"mesh_gallery": "ui.origin.mesh_gallery",
	"mesh_review": "ui.origin.mesh_review",
	# The two dragon-flight screens below the hangar. The registry names
	# `dragonflight` — the hangar — and the play screen and the hatchery are
	# separate router screens with no registry entry of their own, so without
	# keys they reached the dashboard as the machine id.
	"dragonflight_run": "ui.origin.dragonflight_run",
	"dragonflight_hatchery": "ui.origin.dragonflight_hatchery",
}

## Every key above, in the array form the extractor recognises. They are only
## ever looked up in a dictionary, and a key that is never written down
## anywhere is a key nobody can find when it goes missing.
const SCREEN_LOC_KEYS: Array[String] = [
	"ui.origin.lobby",
	"ui.origin.lobby_list",
	"ui.origin.main_menu",
	"ui.origin.game_over",
	"ui.origin.mesh_gallery",
	"ui.origin.mesh_review",
	"ui.origin.dragonflight_run",
	"ui.origin.dragonflight_hatchery",
	"ui.origin.unknown",
]

## Never let a very long label eat the 2000 characters the server accepts.
const MAX_PREFIX := 48

const UNKNOWN_LOC_KEY := "ui.origin.unknown"

## The fallback label. A key rather than a string, so the dashboard sees the
## word in the player's language too.
static func unknown() -> String:
	return Loc.t(UNKNOWN_LOC_KEY)


## The label for a screen id, from the game registry when the screen belongs to
## a game. Registry names and free text are already in the catalogue, so they go
## through `Loc.resolve`; the screens in `SCREEN_LOC_KEY` have no registry entry
## and get a key.
##
## The registry is consulted by **id and by screen**, exactly as `resolve()`
## does, and for one reason: a game with more than one screen is registered
## under its menu (`pang_menu`, `dragonflight`), so a lookup on `screen` alone
## left every other screen of that game unresolved. The two functions then
## disagreed about the same input — `resolve("pang")` said "Pang 3D" and
## `for_screen("pang")` said "pang" — and it was `for_screen` that the suggest
## dialog calls, so a player who filed an idea mid-level sent the machine id to
## the dashboard.
static func for_screen(screen_id: String) -> String:
	if screen_id == "":
		return unknown()
	for game in GameRegistry.GAMES:
		if str(game.get("id", "")) == screen_id or str(game.get("screen", "")) == screen_id:
			return Loc.resolve(str(game.get("name", screen_id)))
	var key := str(SCREEN_LOC_KEY.get(screen_id, ""))
	if key != "":
		return Loc.t(key)
	return screen_id


## The label for a context that may be a screen id or free text. Free text is
## passed through unchanged (trimmed and shortened), which is what the mesh
## gallery uses for "Mesh gallery · dragons".
static func resolve(context: String) -> String:
	var text := context.strip_edges()
	if text == "":
		return unknown()
	for game in GameRegistry.GAMES:
		if text == str(game.get("id", "")) or text == str(game.get("screen", "")):
			return Loc.resolve(str(game.get("name", text)))
	var key := str(SCREEN_LOC_KEY.get(text, ""))
	if key != "":
		return Loc.t(key)
	if text.length() > MAX_PREFIX:
		return text.substr(0, MAX_PREFIX)
	return text


## The text that is actually submitted: the context in front of what the player
## wrote. Applying it twice changes nothing, so a queued suggestion survives a
## later flush intact.
static func compose(context: String, text: String) -> String:
	var body := text.strip_edges()
	var label := resolve(context)
	if label == "" or label == unknown():
		return body
	var prefix := "%s: " % label
	if body.begins_with(prefix) or body.begins_with("%s — " % label) or body.begins_with("%s —" % label):
		return body
	return prefix + body
