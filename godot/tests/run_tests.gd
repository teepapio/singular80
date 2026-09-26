extends SceneTree
## Headless test entry point for the Godot game.
##
##   godot --headless --path godot --script res://tests/run_tests.gd
##
## Runs the pure-logic suites and then boots the real scene tree to exercise
## every screen, so a broken screen fails the build instead of a player's phone.

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var kit := TestKit.new()
	print("Singular 80 — Spieltests")

	var logic := TestLogic.new()
	logic.run(kit)

	var improvements := TestImprovements.new()
	improvements.run(kit)

	var screens := TestScreens.new()
	await screens.run(kit, self)

	var failures := kit.report()
	if failures > 0:
		print("\nFEHLGESCHLAGEN")
	quit(1 if failures > 0 else 0)
