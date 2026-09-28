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
		"tagline": "Fast reflexes, short runs",
	},
	{
		"id": CATEGORY_ADVENTURE,
		"name": "3D Adventures",
		"icon": "☄",
		"accent": Color(0.937, 0.267, 0.267),
		"accent_hex": 0xef4444,
		"tagline": "Explore, collect, fight",
	},
	{
		"id": CATEGORY_BOARD,
		"name": "Board games",
		"icon": "◼",
		"accent": Color(0.851, 0.467, 0.024),
		"accent_hex": 0xd97706,
		"tagline": "Move by move to victory",
	},
	{
		"id": CATEGORY_CARDS,
		"name": "Card games",
		"icon": "♠",
		"accent": Color(0.133, 0.773, 0.369),
		"accent_hex": 0x22c55e,
		"tagline": "Cards, hands, luck",
	},
	{
		"id": CATEGORY_PUZZLE,
		"name": "Puzzle",
		"icon": "▦",
		"accent": Color(0.659, 0.333, 0.969),
		"accent_hex": 0xa855f7,
		"tagline": "Use your head",
	},
]

const GAMES: Array[Dictionary] = [
	{
		"id": "arena",
		"name": "Singular 80",
		"description": "Arena survival: survive the waves, collect XP and upgrade your weapon.",
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
		"description": "The classic: stack tetrominoes, clear lines and survive the ever-faster drops.",
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
		"description": "Poker against three computer opponents: bet, raise, bluff and win the pot.",
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
		"description": "Card solitaire with four free cells: sort all 52 cards into the foundations.",
		"icon": "♣",
		"screen": "freecell",
		"accent": Color(0.133, 0.773, 0.369),
		"accent_hex": 0x22c55e,
		"category": CATEGORY_CARDS,
		"highscore_key": Game.HS_FREECELL,
	},
	{
		"id": "dame",
		"name": "Checkers",
		"description": "The board classic: move diagonally, capture the AI’s pieces and crown your king.",
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
		"description": "Climb the tower, collect crystals and merge them into jewels at the summit.",
		"icon": "◆",
		"screen": "crystal3d",
		"accent": Color(0.024, 0.714, 0.831),
		"accent_hex": 0x06b6d4,
		"category": CATEGORY_ADVENTURE,
		"highscore_key": Game.HS_CRYSTAL,
	},
	{
		"id": "crystal3d-christmas",
		"name": "Christmas Jumper",
		"description": "Crystal Jumper Christmas level: collect baubles in the snow and reach the summit.",
		"icon": "✧",
		"screen": "crystal3d_christmas",
		"accent": Color(0.133, 0.773, 0.369),
		"accent_hex": 0x22c55e,
		"category": CATEGORY_ADVENTURE,
		"highscore_key": Game.HS_CRYSTAL_CHRISTMAS,
	},
	{
		"id": "crystal3d-halloween",
		"name": "Halloween Jumper",
		"description": "Crystal Jumper Halloween level: collect pumpkins at night and merge them into ghosts.",
		"icon": "☠",
		"screen": "crystal3d_halloween",
		"accent": Color(0.973, 0.451, 0.086),
		"accent_hex": 0xf97316,
		"category": CATEGORY_ADVENTURE,
		"highscore_key": Game.HS_CRYSTAL_HALLOWEEN,
	},
	{
		"id": "merge3d-christmas",
		"name": "Christmas Merge 3D",
		"description": "A 3D merge board in Christmas style: combine 3 or 5 matching items into finer decorations.",
		"icon": "✦",
		"screen": "merge3d_christmas",
		"accent": Color(0.133, 0.773, 0.369),
		"accent_hex": 0x22c55e,
		"category": CATEGORY_PUZZLE,
		"highscore_key": Game.HS_MERGE_CHRISTMAS,
	},
	{
		"id": "merge3d-halloween",
		"name": "Halloween Merge 3D",
		"description": "The same 3- and 5-merges as a Halloween edition — merge pumpkins into ghost pumpkins.",
		"icon": "☽",
		"screen": "merge3d_halloween",
		"accent": Color(0.973, 0.451, 0.086),
		"accent_hex": 0xf97316,
		"category": CATEGORY_PUZZLE,
		"highscore_key": Game.HS_MERGE_HALLOWEEN,
	},
	{
		"id": "horserunner",
		"name": "Horse Course 3D",
		"description": "Ride your horse along the dirt track, jump logs, rocks and fences and dodge the trees.",
		"icon": "♞",
		"screen": "horserunner",
		"accent": Color(0.518, 0.8, 0.086),
		"accent_hex": 0x84cc16,
		"category": CATEGORY_ACTION,
		"highscore_key": Game.HS_HORSE,
	},
	{
		"id": "dragonrpg",
		"name": "Dragon RPG 3D",
		"description": "An action RPG in the dragon ruin: fight off waves of dragons, gather gold and loot, and upgrade your weapon and level.",
		"icon": "☄",
		"screen": "dragonrpg",
		"accent": Color(0.937, 0.267, 0.267),
		"accent_hex": 0xef4444,
		"category": CATEGORY_ADVENTURE,
		"highscore_key": Game.HS_DRAGON,
	},
	{
		"id": "dragonflight",
		"name": "Dragon Flight",
		"description": "Fly your dragon through 30 levels, breed offspring with inherited traits and collect dragon gold.",
		"icon": "☄",
		"screen": "dragonflight",
		"accent": Color(0.055, 0.647, 0.898),
		"accent_hex": 0x0ea5e9,
		"category": CATEGORY_ADVENTURE,
		"highscore_key": Game.HS_DRAGONFLIGHT,
	},
	{
		"id": "pang",
		"name": "Pang 3D",
		"description": "The classic in a 3D diorama: skewer every ball before time runs out — 30 levels and four bonuses.",
		"icon": "⇈",
		"screen": "pang_menu",
		"accent": Color(0.961, 0.620, 0.043),
		"accent_hex": 0xf59e0b,
		"category": CATEGORY_ACTION,
		"highscore_key": Game.HS_PANG,
	},
	{
		"id": "metro3d",
		"name": "Metropol 3D",
		"description": "Build a subway network in a 3D city: draw lines, place trains, survive rush hour.",
		"icon": "▣",
		"screen": "metro3d",
		"accent": Color(0.024, 0.714, 0.831),
		"accent_hex": 0x06b6d4,
		"category": CATEGORY_PUZZLE,
		"highscore_key": Game.HS_METRO,
	},
	{
		"id": "2048",
		"name": "2048",
		"description": "The addictive puzzle: slide the tiles, merge matching numbers and build the 2048 tile.",
		"icon": "▣",
		"screen": "g2048",
		"accent": Color(0.961, 0.62, 0.043),
		"accent_hex": 0xf59e0b,
		"category": CATEGORY_PUZZLE,
		"highscore_key": Game.HS_2048,
	},
	{
		"id": "candy3d",
		"name": "Candy Crush 3D",
		"description": "Match-3 across 6 worlds with 240 levels: swap candies, trigger chains and clear blocks.",
		"icon": "✦",
		"screen": "candy3d",
		"accent": Color(0.957, 0.447, 0.714),
		"accent_hex": 0xf472b6,
		"category": CATEGORY_PUZZLE,
		"highscore_key": Game.HS_CANDY,
		"star_max": 3 * 40 * 6,
	},
	{
		"id": "siedler",
		"name": "Settlers 3D",
		"description": "A settlers-style building game: banners and carriers move your goods, tools and mines go hungry.",
		"icon": "⌂",
		"screen": "siedler",
		"accent": Color(0.518, 0.8, 0.086),
		"accent_hex": 0x84cc16,
		"category": CATEGORY_BOARD,
		"highscore_key": Game.HS_SIEDLER,
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
