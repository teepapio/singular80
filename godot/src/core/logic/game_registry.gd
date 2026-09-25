class_name GameRegistry
extends RefCounted
## Registry of every playable subgame, grouped into the lobby categories.
##
## The 3D lobby maps every category to a walkable plaza and the list lobby uses
## the same grouping, so this file is the single source of truth for what the
## game offers.

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
		"accent_hex": 0x0ea5e9,
		"tagline": "Schnelle Reflexe, kurze Runs",
	},
	{
		"id": CATEGORY_ADVENTURE,
		"name": "3D-Abenteuer",
		"icon": "☄",
		"accent": Color(0.937, 0.267, 0.267),
		"accent_hex": 0xef4444,
		"tagline": "Erkunden, sammeln, kämpfen",
	},
	{
		"id": CATEGORY_BOARD,
		"name": "Brettspiele",
		"icon": "◼",
		"accent": Color(0.851, 0.467, 0.024),
		"accent_hex": 0xd97706,
		"tagline": "Zug um Zug zum Sieg",
	},
	{
		"id": CATEGORY_CARDS,
		"name": "Kartenspiele",
		"icon": "♠",
		"accent": Color(0.133, 0.773, 0.369),
		"accent_hex": 0x22c55e,
		"tagline": "Blatt, Hand, Glück",
	},
	{
		"id": CATEGORY_PUZZLE,
		"name": "Puzzle",
		"icon": "▦",
		"accent": Color(0.659, 0.333, 0.969),
		"accent_hex": 0xa855f7,
		"tagline": "Köpfchen gefragt",
	},
]

const GAMES: Array[Dictionary] = [
	{
		"id": "arena",
		"name": "Singular 80",
		"description": "Arena-Survival: Überlebe Wellen, sammle XP und verbessere deine Waffe.",
		"icon": "◉",
		"screen": "arena",
		"accent": Color(0.055, 0.647, 0.898),
		"accent_hex": 0x0ea5e9,
		"category": CATEGORY_ACTION,
		"highscore_key": Game.HS_ARENA,
	},
	{
		"id": "tetris",
		"name": "Tetris",
		"description": "Der Klassiker: Stapel Tetrominos, räume Linien und überlebe das immer schnellere Fallen.",
		"icon": "▦",
		"screen": "tetris",
		"accent": Color(0.659, 0.333, 0.969),
		"accent_hex": 0xa855f7,
		"category": CATEGORY_PUZZLE,
		"highscore_key": Game.HS_TETRIS,
	},
	{
		"id": "poker",
		"name": "Texas Hold'em",
		"description": "Poker gegen drei Computer-Gegner: Setze, erhöhe, bluffe und gewinne den Pot am Tisch.",
		"icon": "♠",
		"screen": "poker",
		"accent": Color(0.937, 0.267, 0.267),
		"accent_hex": 0xef4444,
		"category": CATEGORY_CARDS,
		"highscore_key": Game.HS_HOLDEM,
	},
	{
		"id": "freecell",
		"name": "FreeCell",
		"description": "Karten-Solitaire mit vier freien Zellen: Sortiere alle 52 Karten in die Fundamente.",
		"icon": "♣",
		"screen": "freecell",
		"accent": Color(0.133, 0.773, 0.369),
		"accent_hex": 0x22c55e,
		"category": CATEGORY_CARDS,
		"highscore_key": Game.HS_FREECELL,
	},
	{
		"id": "dame",
		"name": "Dame",
		"description": "Der Brett-Klassiker: Ziehe diagonal, schlage die Steine der KI und mache deine Dame zur Königin.",
		"icon": "◼",
		"screen": "dame",
		"accent": Color(0.851, 0.467, 0.024),
		"accent_hex": 0xd97706,
		"category": CATEGORY_BOARD,
		"highscore_key": Game.HS_DAME,
	},
	{
		"id": "crystal3d",
		"name": "Crystal Jumper 3D",
		"description": "Klettere den Turm, sammle Kristalle und verschmelze sie am Gipfel zu Juwelen.",
		"icon": "◆",
		"screen": "crystal3d",
		"accent": Color(0.024, 0.714, 0.831),
		"accent_hex": 0x06b6d4,
		"category": CATEGORY_ADVENTURE,
		"highscore_key": Game.HS_CRYSTAL,
	},
	{
		"id": "crystal3d-christmas",
		"name": "Weihnachts-Jumper",
		"description": "Crystal-Jumper-Weihnachtslevel: Sammle Glaskugeln im Schnee und erreiche den Gipfel.",
		"icon": "✧",
		"screen": "crystal3d_christmas",
		"accent": Color(0.133, 0.773, 0.369),
		"accent_hex": 0x22c55e,
		"category": CATEGORY_ADVENTURE,
		"highscore_key": Game.HS_CRYSTAL_CHRISTMAS,
	},
	{
		"id": "crystal3d-halloween",
		"name": "Halloween-Jumper",
		"description": "Crystal-Jumper-Halloweenlevel: Sammle nachts Kürbisse und verschmelze sie zu Geistern.",
		"icon": "☠",
		"screen": "crystal3d_halloween",
		"accent": Color(0.973, 0.451, 0.086),
		"accent_hex": 0xf97316,
		"category": CATEGORY_ADVENTURE,
		"highscore_key": Game.HS_CRYSTAL_HALLOWEEN,
	},
	{
		"id": "merge3d-christmas",
		"name": "Weihnachts-Merge 3D",
		"description": "3D-Merge-Brett im Weihnachtsstil: Kombiniere 3 oder 5 gleiche Items zu prächtigerem Schmuck.",
		"icon": "✦",
		"screen": "merge3d_christmas",
		"accent": Color(0.133, 0.773, 0.369),
		"accent_hex": 0x22c55e,
		"category": CATEGORY_PUZZLE,
		"highscore_key": Game.HS_MERGE_CHRISTMAS,
	},
	{
		"id": "merge3d-halloween",
		"name": "Halloween-Merge 3D",
		"description": "Dieselben 3er-/5er-Merges als Halloween-Edition — verschmelze Kürbisse zu Geisterkürbissen.",
		"icon": "☽",
		"screen": "merge3d_halloween",
		"accent": Color(0.973, 0.451, 0.086),
		"accent_hex": 0xf97316,
		"category": CATEGORY_PUZZLE,
		"highscore_key": Game.HS_MERGE_HALLOWEEN,
	},
	{
		"id": "horserunner",
		"name": "Pferde-Parcours 3D",
		"description": "Reite mit dem Pferd über den Erdweg, springe über Baumstämme, Felsen und Zäune und weiche den Bäumen aus.",
		"icon": "♞",
		"screen": "horserunner",
		"accent": Color(0.518, 0.8, 0.086),
		"accent_hex": 0x84cc16,
		"category": CATEGORY_ACTION,
		"highscore_key": Game.HS_HORSE,
	},
	{
		"id": "dragonrpg",
		"name": "Drachen-RPG 3D",
		"description": "Action-RPG in der Drachenruine: Erlege Drachenwellen, sammle Gold und Beute und verbessere Waffe und Level.",
		"icon": "☄",
		"screen": "dragonrpg",
		"accent": Color(0.937, 0.267, 0.267),
		"accent_hex": 0xef4444,
		"category": CATEGORY_ADVENTURE,
		"highscore_key": Game.HS_DRAGON,
	},
	{
		"id": "2048",
		"name": "2048",
		"description": "Das Sucht-Puzzle: Verschiebe die Kacheln, verschmelze gleiche Zahlen und baue die 2048.",
		"icon": "▣",
		"screen": "g2048",
		"accent": Color(0.961, 0.62, 0.043),
		"accent_hex": 0xf59e0b,
		"category": CATEGORY_PUZZLE,
		"highscore_key": Game.HS_2048,
	},
]


static func game_by_id(id: String) -> Dictionary:
	for game in GAMES:
		if str(game.get("id", "")) == id:
			return game
	return {}


static func category_by_id(id: String) -> Dictionary:
	for category in CATEGORIES:
		if str(category.get("id", "")) == id:
			return category
	return CATEGORIES[0]


static func games_in_category(id: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for game in GAMES:
		if str(game.get("category", "")) == id:
			out.append(game)
	return out


## Screen id for a game id, with a safe fallback to the arena.
static func screen_of(game_id: String) -> String:
	var game := game_by_id(game_id)
	if game.is_empty():
		return "arena"
	return str(game.get("screen", "arena"))
