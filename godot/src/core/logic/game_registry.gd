class_name GameRegistry
extends RefCounted
## Registry of every playable subgame, grouped into the lobby categories.
##
## The 3D lobby maps every category to a walkable plaza and the list lobby uses
## the same grouping, so this file is the single source of truth for what the
## game offers.
##
## A game entry carries exactly what a caller needs: `id`, `name`, `icon`,
## `screen`, `accent` (a `Color`, read directly), `category` and
## `highscore_key`. Three fields used to sit here that nothing read — a second
## copy of the accent as a hex int (`accent_hex`, wrong in two entries: `0x0ea5e9`
## for a `#0ea5e5` and `0xf97316` for a `#f87316`), a `star_max` only the
## candy game had, and 18 `description` sentences that were harvested into three
## catalogues and translated, for a screen that never showed them. Dead data
## that is also translated costs three languages a review per change and
## protects nothing, so it is gone rather than maintained.

const CATEGORY_ACTION := "action"
const CATEGORY_ADVENTURE := "adventure"
const CATEGORY_BOARD := "board"
const CATEGORY_CARDS := "cards"
const CATEGORY_PUZZLE := "puzzle"

const CATEGORIES: Array[Dictionary] = [
	{
		"id": CATEGORY_ACTION,
		"name": "Action & Arcade",
		"icon": "◉",
		"accent": Color(0.055, 0.647, 0.898),
		"tagline": "Fast reflexes, short runs",
	},
	{
		"id": CATEGORY_ADVENTURE,
		"name": "3D Adventures",
		"icon": "☄",
		"accent": Color(0.937, 0.267, 0.267),
		"tagline": "Explore, collect, fight",
	},
	{
		"id": CATEGORY_BOARD,
		"name": "Board games",
		"icon": "◼",
		"accent": Color(0.851, 0.467, 0.024),
		"tagline": "Move by move to victory",
	},
	{
		"id": CATEGORY_CARDS,
		"name": "Card games",
		"icon": "♠",
		"accent": Color(0.133, 0.773, 0.369),
		"tagline": "Cards, hands, luck",
	},
	{
		"id": CATEGORY_PUZZLE,
		"name": "Puzzle",
		"icon": "▦",
		"accent": Color(0.659, 0.333, 0.969),
		"tagline": "Use your head",
	},
]

## One extra button in the top bar of a screen, next to "◀ Lobby", "Vorschlag",
## "⚙" and the sound toggle: the companion view a game opens from inside itself.
##
## It is declared here rather than built by the screen because the bar belongs to
## the two base classes, and a screen that wanted a second button had no way to
## say so without editing `Ui.top_bar`. The Crystal Jumper is the case this was
## written for: its merge was a button on the summit panel, which opens once per
## finished tower, so a player asking where the merge is found nothing. One line
## per screen — `label` is the caption, `screen` the route to open, `payload`
## what that screen needs to know.
const COMPANIONS := {
	"crystal3d": {"label": "Merge", "screen": "crystal_forge", "payload": {"theme": "classic", "back": "crystal3d"}},
	"crystal3d_christmas": {"label": "Merge", "screen": "crystal_forge", "payload": {"theme": "christmas", "back": "crystal3d_christmas"}},
	"crystal3d_halloween": {"label": "Merge", "screen": "crystal_forge", "payload": {"theme": "halloween", "back": "crystal3d_halloween"}},
}

const GAMES: Array[Dictionary] = [
	# Named after its genre, not after the app (suggestion #37). It used to be
	# called "Singular 80" — the name the top bar shows as the brand directly
	# above it — and a player filed the resulting confusion. Do not "fix" it
	# back: the app is Singular 80, this is one of its eighteen subgames. Only
	# the display name moved; id, screen and `Game.HS_ARENA` stayed, so the
	# highscores a player already has survive the rename.
	{
		"id": "arena",
		"name": "Space Shoot",
		"icon": "◉",
		"screen": "arena",
		"accent": Color(0.055, 0.647, 0.898),
		"category": CATEGORY_ACTION,
		"highscore_key": Game.HS_ARENA,
	},
	{
		"id": "tetris",
		"name": "Tetris",
		"icon": "▦",
		"screen": "tetris",
		"accent": Color(0.659, 0.333, 0.969),
		"category": CATEGORY_PUZZLE,
		"highscore_key": Game.HS_TETRIS,
	},
	{
		"id": "poker",
		"name": "Texas Hold'em",
		"icon": "♠",
		"screen": "poker",
		"accent": Color(0.937, 0.267, 0.267),
		"category": CATEGORY_CARDS,
		"highscore_key": Game.HS_HOLDEM,
	},
	{
		"id": "freecell",
		"name": "FreeCell",
		"icon": "♣",
		"screen": "freecell",
		"accent": Color(0.133, 0.773, 0.369),
		"category": CATEGORY_CARDS,
		"highscore_key": Game.HS_FREECELL,
	},
	{
		"id": "dame",
		"name": "Checkers",
		"icon": "◼",
		"screen": "dame",
		"accent": Color(0.851, 0.467, 0.024),
		"category": CATEGORY_BOARD,
		"highscore_key": Game.HS_DAME,
	},
	{
		"id": "crystal3d",
		"name": "Crystal Jumper 3D",
		"icon": "◆",
		"screen": "crystal3d",
		"accent": Color(0.024, 0.714, 0.831),
		"category": CATEGORY_ADVENTURE,
		"highscore_key": Game.HS_CRYSTAL,
	},
	{
		"id": "crystal3d-christmas",
		"name": "Christmas Jumper",
		"icon": "✧",
		"screen": "crystal3d_christmas",
		"accent": Color(0.133, 0.773, 0.369),
		"category": CATEGORY_ADVENTURE,
		"highscore_key": Game.HS_CRYSTAL_CHRISTMAS,
	},
	{
		"id": "crystal3d-halloween",
		"name": "Halloween Jumper",
		"icon": "☠",
		"screen": "crystal3d_halloween",
		"accent": Color(0.973, 0.451, 0.086),
		"category": CATEGORY_ADVENTURE,
		"highscore_key": Game.HS_CRYSTAL_HALLOWEEN,
	},
	{
		"id": "merge3d-christmas",
		"name": "Christmas Merge 3D",
		"icon": "✦",
		"screen": "merge3d_christmas",
		"accent": Color(0.133, 0.773, 0.369),
		"category": CATEGORY_PUZZLE,
		"highscore_key": Game.HS_MERGE_CHRISTMAS,
	},
	{
		"id": "merge3d-halloween",
		"name": "Halloween Merge 3D",
		"icon": "☽",
		"screen": "merge3d_halloween",
		"accent": Color(0.973, 0.451, 0.086),
		"category": CATEGORY_PUZZLE,
		"highscore_key": Game.HS_MERGE_HALLOWEEN,
	},
	{
		"id": "horserunner",
		"name": "Horse Course 3D",
		"icon": "♞",
		"screen": "horserunner",
		"accent": Color(0.518, 0.8, 0.086),
		"category": CATEGORY_ACTION,
		"highscore_key": Game.HS_HORSE,
	},
	{
		"id": "dragonrpg",
		"name": "Dragon RPG 3D",
		"icon": "☄",
		"screen": "dragonrpg",
		"accent": Color(0.937, 0.267, 0.267),
		"category": CATEGORY_ADVENTURE,
		"highscore_key": Game.HS_DRAGON,
	},
	{
		"id": "dragonflight",
		"name": "Dragon Flight",
		"icon": "☄",
		"screen": "dragonflight",
		"accent": Color(0.055, 0.647, 0.898),
		"category": CATEGORY_ADVENTURE,
		"highscore_key": Game.HS_DRAGONFLIGHT,
	},
	{
		"id": "pang",
		"name": "Pang 3D",
		"icon": "⇈",
		"screen": "pang_menu",
		"accent": Color(0.961, 0.620, 0.043),
		"category": CATEGORY_ACTION,
		"highscore_key": Game.HS_PANG,
	},
	{
		"id": "metro3d",
		"name": "Metropol 3D",
		"icon": "▣",
		"screen": "metro3d",
		"accent": Color(0.024, 0.714, 0.831),
		"category": CATEGORY_PUZZLE,
		"highscore_key": Game.HS_METRO,
	},
	{
		"id": "2048",
		"name": "2048",
		"icon": "▣",
		"screen": "g2048",
		"accent": Color(0.961, 0.62, 0.043),
		"category": CATEGORY_PUZZLE,
		"highscore_key": Game.HS_2048,
	},
	{
		"id": "candy3d",
		"name": "Candy Crush 3D",
		"icon": "✦",
		"screen": "candy3d",
		"accent": Color(0.957, 0.447, 0.714),
		"category": CATEGORY_PUZZLE,
		"highscore_key": Game.HS_CANDY,
	},
	{
		"id": "siedler",
		"name": "Settlers 3D",
		"icon": "⌂",
		"screen": "siedler",
		"accent": Color(0.518, 0.8, 0.086),
		"category": CATEGORY_BOARD,
		"highscore_key": Game.HS_SIEDLER,
	},
]


static func game_by_id(id: String) -> Dictionary:
	for game in GAMES:
		if str(game.get("id", "")) == id:
			return game
	return {}


## The category with this id, or `{}` when there is none.
##
## An unknown id used to answer with `CATEGORIES[0]`, so a typo in a call site
## put the game under "Action & Arcade" — a category the entry never claimed,
## shown to the player as if it were true. `{}` says what is actually the case,
## and it is the same shape `game_by_id()` already returns for an unknown game,
## so a caller has one rule instead of two.
static func category_by_id(id: String) -> Dictionary:
	for category in CATEGORIES:
		if str(category.get("id", "")) == id:
			return category
	return {}


static func games_in_category(id: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for game in GAMES:
		if str(game.get("category", "")) == id:
			out.append(game)
	return out


## The top-bar companions of a screen, ready to hand to `Ui.top_bar`: a screen
## without one gets an empty list, so the base classes pass the answer on
## unconditionally.
static func companions_of(screen_id: String) -> Array:
	var entry: Variant = COMPANIONS.get(screen_id)
	return [entry] if entry is Dictionary else []


## Screen id for a game id, with a safe fallback to the arena.
static func screen_of(game_id: String) -> String:
	var game := game_by_id(game_id)
	if game.is_empty():
		return "arena"
	return str(game.get("screen", "arena"))
