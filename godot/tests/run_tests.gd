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

	var logic := TestLogic.new()
	logic.run(kit)

	# Each extra suite class is skipped wholesale when the scope does not touch
	# it. The filter has to skip whole classes, not just their assertions: an
	# integration suite's *body* opens screens and awaits timers, which is where
	# the wall-clock time goes. Reading the names from the file means a class
	# added later is picked up here without editing this runner.
	if _wants_class("res://tests/test_metro.gd", only):
		TestMetro.new().run(kit)
	if _wants_class("res://tests/test_metro3d.gd", only):
		# By path, like the screen suites below: a class added since the last
		# editor start is not in the global class cache, and a static name
		# would not resolve before the autoloads are registered.
		var metro3d: GDScript = load("res://tests/test_metro3d.gd")
		await metro3d.new().run(kit, self)
	if _wants_class("res://tests/test_crystal3d.gd", only):
		await TestCrystal3d.new().run(kit, self)
	if _wants_class("res://tests/test_candy_match3.gd", only):
		TestCandyMatch3.new().run(kit)
	if _wants_class("res://tests/test_arena.gd", only):
		TestArena.new().run(kit)
	if _wants_class("res://tests/test_poker.gd", only):
		# By path, like the suites above: `--script` mode does not refresh the
		# global class cache, so a class added today is unknown.
		var poker_suite: GDScript = load("res://tests/test_poker.gd")
		if poker_suite != null:
			poker_suite.new().run(kit)
	if _wants_class("res://tests/test_pang.gd", only):
		TestPang.new().run(kit)
	if _wants_class("res://tests/test_horserunner.gd", only):
		# By path: a class added since the last editor start is not in the
		# global class cache, and a static name would not resolve.
		var horserunner: GDScript = load("res://tests/test_horserunner.gd")
		horserunner.new().run(kit)
	if _wants_class("res://tests/test_improvements.gd", only):
		TestImprovements.new().run(kit)
	if _wants_class("res://tests/test_metro_screens.gd", only):
		await TestMetroScreens.new().run(kit, self)

	var screens := TestScreens.new()
	await screens.run(kit, self, screen_filter)

	var failures := kit.report()
	if failures > 0:
		print("\nFEHLGESCHLAGEN")
	quit(1 if failures > 0 else 0)
