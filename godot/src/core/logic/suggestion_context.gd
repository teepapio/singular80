class_name SuggestionContext
extends RefCounted
## Where a suggestion came from.
##
## The player should never have to type "this is about Tetris" — the game knows.
## Every screen therefore carries a label, and the text that is finally sent gets
## that label in front, so the dashboard can group ideas by origin without the
## author having to think about it.

## Screens that are not playable games still deserve a label.
const SCREEN_LABELS := {
	"lobby": "Lobby",
	"lobby_list": "Spieleliste",
	"main_menu": "Hauptmenü",
	"game_over": "Spielende",
	"mesh_gallery": "Mesh-Galerie",
	"mesh_review": "Mesh-Improvements",
}

## Never let a very long label eat the 2000 characters the server accepts.
const MAX_PREFIX := 48

const UNKNOWN := "Spiel"


## The German label for a screen id, taken from the game registry when the screen
## belongs to a game.
static func for_screen(screen_id: String) -> String:
	if screen_id == "":
		return UNKNOWN
	for game in GameRegistry.GAMES:
		if str(game.get("screen", "")) == screen_id:
			return str(game.get("name", screen_id))
	var label: Variant = SCREEN_LABELS.get(screen_id)
	return str(label) if label != null else screen_id


## The label for a context that may be a screen id or free text.
##
## A free text is passed through unchanged (trimmed and shortened), which is what
## the mesh gallery uses for "Mesh-Galerie · Drachen".
static func resolve(context: String) -> String:
	var text := context.strip_edges()
	if text == "":
		return UNKNOWN
	for game in GameRegistry.GAMES:
		if text == str(game.get("id", "")) or text == str(game.get("screen", "")):
			return str(game.get("name", text))
	var label: Variant = SCREEN_LABELS.get(text)
	if label != null:
		return str(label)
	if text.length() > MAX_PREFIX:
		return text.substr(0, MAX_PREFIX)
	return text


## The text that is actually submitted: the context in front of what the player
## wrote. Applying it twice changes nothing, so a queued suggestion survives a
## later flush intact.
static func compose(context: String, text: String) -> String:
	var body := text.strip_edges()
	var label := resolve(context)
	if label == "" or label == UNKNOWN:
		return body
	var prefix := "%s: " % label
	if body.begins_with(prefix) or body.begins_with("%s — " % label) or body.begins_with("%s —" % label):
		return body
	return prefix + body
