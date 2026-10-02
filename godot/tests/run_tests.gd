extends SceneTree
## Headless test entry point for the Godot game.
##
##   godot --headless --path godot --script res://tests/run_tests.gd
##
## Runs the pure-logic suites and then boots the real scene tree to exercise
## every screen, so a broken screen fails the build instead of a player's phone.
##
## Scoped runs, so a game agent only pays for its own game:
##
##   … --script res://tests/run_tests.gd -- --only "Pang|Tetris — Eingabe"
##   … --script res://tests/run_tests.gd -- --screens pang,pang_menu
##
## `scripts/scopes.mjs` resolves a scope name to exactly these arguments; that
## is what `npm run test:game -- --scope pang` does. Without them the whole
## catalogue runs, which is correct but slow.

func _initialize() -> void:
	_run.call_deferred()


## `--key value` and `--key=value`, taken from the arguments after a bare `--`.
func _args() -> Dictionary:
	var out := {}
	var list := OS.get_cmdline_user_args()
	var i := 0
	while i < list.size():
		var token := str(list[i])
		if token.begins_with("--"):
			var key := token.substr(2)
			if key.contains("="):
				out[key.get_slice("=", 0)] = key.get_slice("=", 1)
			elif i + 1 < list.size() and not str(list[i + 1]).begins_with("--"):
				out[key] = str(list[i + 1])
				i += 1
		i += 1
	return out


## Suite names a test class declares, read from its own source.
func _suites_of(path: String) -> PackedStringArray:
	var out := PackedStringArray()
	if not FileAccess.file_exists(path):
		return out
	for chunk in FileAccess.get_file_as_string(path).split("t.suite(\""):
		if chunk.is_empty():
			continue
		var name := chunk.get_slice("\"", 0)
		if not name.is_empty():
			out.append(name)
	return out


## True when no `--only` filter is set, or at least one suite of this class is
## selected.
func _wants_class(path: String, only: String) -> bool:
	if only.is_empty():
		return true
	for name in _suites_of(path):
		if only.contains(name):
			return true
	return false


func _run() -> void:
	var args := _args()
	var only := str(args.get("only", ""))
	var screen_filter := str(args.get("screens", ""))

	var kit := TestKit.new()
	kit.set_only(only)
	# A screen list *is* the request for the sweep; without this the sweep would
	# be filtered out by name and a scoped run would check no screen at all.
	if screen_filter != "":
		kit.allow("Screens")
	print("Singular 80 — Spieltests")
	if only != "":
		print("Suites: %s" % only.replace("|", ", "))
	if screen_filter != "":
		print("Screens: %s" % screen_filter)

	# Pin the language before anything runs. `Loc` follows the device on a first
	# start, and half this suite asserts on German strings — the queue hint, the
	# report dialog, the file paths. On a French laptop those would fail for a
	# reason that has nothing to do with the code, and the suite would be green
	# only on the machine it was written on.
	Loc.reset()
	Loc.set_code("de")

	# By path, and the reason is the one the screen suites below spell out: a
	# `class_name` used here is resolved while this file *compiles*, which is
	# before `--script` mode has registered the autoloads. A suite whose chain
	# reaches `ui.gd` then dies on "Identifier not found: Sfx" and takes every
	# assertion in it with it. `load()` happens in `_initialize()`'s deferred
	# call, which is after the autoloads exist.
	var logic_suite: GDScript = load("res://tests/test_logic.gd")
	if logic_suite != null:
		logic_suite.new().run(kit)

	# Each extra suite class is skipped wholesale when the scope does not touch
	# it. The filter has to skip whole classes, not just their assertions: an
	# integration suite's *body* opens screens and awaits timers, which is where
	# the wall-clock time goes. Reading the names from the file means a class
	# added later is picked up here without editing this runner.
	if _wants_class("res://tests/test_metro.gd", only):
		TestMetro.new().run(kit)
	if _wants_class("res://tests/test_metro3d.gd", only):
		# By path, like the screen suites below: `--script` mode does not refresh
		# the global class cache, so a class added since the last editor start is
		# unknown and would not resolve before the autoloads are registered.
		var metro3d: GDScript = load("res://tests/test_metro3d.gd")
		await metro3d.new().run(kit, self)
	if _wants_class("res://tests/test_crystal3d.gd", only):
		# By path: the crystal screen is a `WorldScreen`, and `WorldScreen`
		# reaches `fire_glow.gd` -> `ui.gd` -> `Sfx`.
		var crystal_suite: GDScript = load("res://tests/test_crystal3d.gd")
		if crystal_suite != null:
			await crystal_suite.new().run(kit, self)
	if _wants_class("res://tests/test_dame.gd", only):
		var dame_suite: GDScript = load("res://tests/test_dame.gd")
		if dame_suite != null:
			await dame_suite.new().run(kit, self)
	if _wants_class("res://tests/test_dragonflight.gd", only):
		TestDragonFlight.new().run(kit)
	if _wants_class("res://tests/test_candy_match3.gd", only):
		# By path: the match-3 rules reach `asset_registry.gd`, which formats a
		# number through `Ui`, and `Ui` reaches `Sfx`.
		var match3_suite: GDScript = load("res://tests/test_candy_match3.gd")
		if match3_suite != null:
			match3_suite.new().run(kit)
	if _wants_class("res://tests/test_tetris.gd", only):
		var tetris_suite: GDScript = load("res://tests/test_tetris.gd")
		if tetris_suite != null:
			tetris_suite.new().run(kit)
	if _wants_class("res://tests/test_candy3d.gd", only):
		var candy_suite: GDScript = load("res://tests/test_candy3d.gd")
		if candy_suite != null:
			await candy_suite.new().run(kit, self)
	if _wants_class("res://tests/test_merge3d.gd", only):
		var merge_suite: GDScript = load("res://tests/test_merge3d.gd")
		if merge_suite != null:
			await merge_suite.new().run(kit, self)
	if _wants_class("res://tests/test_2048.gd", only):
		var suite_2048: GDScript = load("res://tests/test_2048.gd")
		if suite_2048 != null:
			await suite_2048.new().run(kit, self)
	if _wants_class("res://tests/test_freecell.gd", only):
		var freecell_suite: GDScript = load("res://tests/test_freecell.gd")
		if freecell_suite != null:
			freecell_suite.new().run(kit)
			await freecell_suite.ScreenChecks.new().run(kit, self)
	if _wants_class("res://tests/test_horserunner.gd", only):
		var horserunner: GDScript = load("res://tests/test_horserunner.gd")
		horserunner.new().run(kit)
	if _wants_class("res://tests/test_poker.gd", only):
		var poker_suite: GDScript = load("res://tests/test_poker.gd")
		if poker_suite != null:
			poker_suite.new().run(kit)
	if _wants_class("res://tests/test_arena.gd", only):
		TestArena.new().run(kit)
	if _wants_class("res://tests/test_pang.gd", only):
		TestPang.new().run(kit)
	if _wants_class("res://tests/test_dragonrpg.gd", only):
		var dragonrpg_suite: GDScript = load("res://tests/test_dragonrpg.gd")
		if dragonrpg_suite != null:
			dragonrpg_suite.new().run(kit)
	if _wants_class("res://tests/test_siedler.gd", only):
		var siedler_suite: GDScript = load("res://tests/test_siedler.gd")
		if siedler_suite != null:
			siedler_suite.new().run(kit)
	if _wants_class("res://tests/test_improvements.gd", only):
		# By path for the same reason as `test_logic.gd` above: it reaches
		# `virtual_stick.gd`, and `virtual_stick.gd` reaches `ui.gd`.
		var improvements_suite: GDScript = load("res://tests/test_improvements.gd")
		if improvements_suite != null:
			improvements_suite.new().run(kit)
	if _wants_class("res://tests/test_loc.gd", only):
		var loc_suite: GDScript = load("res://tests/test_loc.gd")
		if loc_suite != null:
			loc_suite.new().run(kit, self)
	if _wants_class("res://tests/test_core.gd", only):
		var core_suite: GDScript = load("res://tests/test_core.gd")
		if core_suite != null:
			# Needs the scene tree: the retry talks to a local socket, and the
			# autoloads only exist in a running tree.
			await core_suite.new().run(kit, self)
	if _wants_class("res://tests/test_metro_screens.gd", only):
		var metro_screens_suite: GDScript = load("res://tests/test_metro_screens.gd")
		if metro_screens_suite != null:
			await metro_screens_suite.new().run(kit, self)

	# The screen sweep is the suite that opens every screen, so it is the one
	# that must not be named as a `class_name` here: `mesh_gallery_screen.gd`
	# and every other screen reach `ui.gd`, and `ui.gd` reaches `Sfx`.
	var screens_suite: GDScript = load("res://tests/test_screens.gd")
	if screens_suite == null:
		print("FEHLGESCHLAGEN")
		print("test_screens.gd liess sich nicht laden — die Screen-Suite ist nicht gelaufen.")
		quit(1)
		return
	await screens_suite.new().run(kit, self, screen_filter)

	var failures := kit.report()
	if failures > 0:
		print("\nFEHLGESCHLAGEN")
	quit(1 if failures > 0 else 0)
