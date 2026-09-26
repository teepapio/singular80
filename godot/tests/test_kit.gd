class_name TestKit
extends RefCounted
## Tiny assertion helpers for the headless GDScript test suite.
##
## Deliberately dependency free: the tests run with
## `godot --headless --path godot --script res://tests/run_tests.gd`, so there is
## nothing to install and nothing to keep in sync with the editor.

var passed: int = 0
var failed: int = 0
var failures: Array[String] = []
var _current: String = ""
## True while a suite is running. A GDScript runtime error unwinds the whole
## function without raising, so a suite that dies half-way would otherwise be
## reported as a pass — `suite_done()`/`close_suite()` turn that into a failure.
var _suite_open: bool = false
## Suite names to run, `|`-separated. Empty means "all". This is what lets a
## game agent verify only its own game instead of the whole catalogue.
var _only: PackedStringArray = PackedStringArray()
## False while a suite that was filtered out is executing, so its assertions
## are counted nowhere.
var _active: bool = true


## Restricts the run to the named suites. `list` is `|`-separated; an empty
## string keeps every suite.
func set_only(list: String) -> void:
	var text := list.strip_edges()
	if text.is_empty():
		return
	_only = PackedStringArray()
	for entry in text.split("|", false):
		var name := entry.strip_edges()
		if not name.is_empty():
			_only.append(name)


func is_selected(name: String) -> bool:
	if _only.is_empty():
		return true
	return _only.has(name)


## Adds a suite to the selection. The screen sweep is requested through
## `--screens` rather than by name, so the runner allows it explicitly —
## otherwise a scoped run would silently skip every screen.
func allow(name: String) -> void:
	if not _only.is_empty() and not _only.has(name):
		_only.append(name)


## Switches to a screen and waits exactly as long as the switch takes.
##
## `Router.go_to` ignores requests while a fade is still running. A fixed sleep
## after another screen's switch is therefore a race: the request is dropped on
## the floor and the suite quietly inspects the *previous* screen — which then
## fails on some property it never had. This drains a running transition,
## issues the request, then polls until the router both reports the new screen
## and accepts requests again. The cap keeps a broken screen from hanging the
## run, and the return value says whether it ever arrived.
func goto(router: Node, tree: SceneTree, screen_id: String, data: Dictionary = {}, cap := 2.0) -> bool:
	if router == null:
		return false
	var waited := 0.0
	while bool(router.transitioning) and waited < cap:
		await tree.process_frame
		waited += 1.0 / 60.0
	router.go_to(screen_id, data)
	waited = 0.0
	while waited < cap:
		await tree.process_frame
		waited += 1.0 / 60.0
		# Both conditions matter: `current_id` flips as soon as the screen is in
		# the tree, but the router only takes the next request once the fade
		# back out has ended.
		if str(router.current_id) == screen_id and not bool(router.transitioning):
			await tree.process_frame
			return true
	return false


func suite(name: String) -> void:
	if not is_selected(name):
		# The body still runs — it is pure logic and cheap — but nothing it
		# asserts is counted. Integration suites that actually cost time gate
		# themselves on `is_selected()` instead.
		_active = false
		_suite_open = false
		return
	_active = true
	_current = name
	_suite_open = true
	print("\n── %s" % name)


## Last line of every suite body.
func suite_done() -> void:
	_suite_open = false
	_active = true


## Called by a runner after a suite function returned. If the body never
## reached `suite_done()` it was aborted by a runtime error.
func close_suite() -> void:
	if not _suite_open:
		return
	_suite_open = false
	fail("Suite '%s' brach ab (Laufzeitfehler)" % _current)


## Records a failure without an assertion.
func fail(description: String) -> void:
	if not _active:
		return
	failed += 1
	failures.append("%s → %s" % [_current, description])
	print("  ✗ %s" % description)


func check(condition: bool, description: String) -> void:
	if not _active:
		return
	if condition:
		passed += 1
	else:
		failed += 1
		failures.append("%s → %s" % [_current, description])
		print("  ✗ %s" % description)


func equal(actual: Variant, expected: Variant, description: String) -> void:
	if not _active:
		return
	var ok := _same(actual, expected)
	if ok:
		passed += 1
	else:
		failed += 1
		failures.append("%s → %s (erwartet %s, war %s)" % [_current, description, str(expected), str(actual)])
		print("  ✗ %s — erwartet %s, war %s" % [description, str(expected), str(actual)])


func almost(actual: float, expected: float, tolerance: float, description: String) -> void:
	if not _active:
		return
	var ok: bool = absf(actual - expected) <= tolerance
	if ok:
		passed += 1
	else:
		failed += 1
		failures.append("%s → %s (erwartet ~%s, war %s)" % [_current, description, str(expected), str(actual)])
		print("  ✗ %s — erwartet ~%s, war %s" % [description, str(expected), str(actual)])


func _same(actual: Variant, expected: Variant) -> bool:
	if actual is float or expected is float:
		if (actual is float or actual is int) and (expected is float or expected is int):
			return absf(float(actual) - float(expected)) < 0.0001
	if actual is Array and expected is Array:
		var a: Array = actual
		var b: Array = expected
		if a.size() != b.size():
			return false
		for i in a.size():
			if not _same(a[i], b[i]):
				return false
		return true
	if actual is Dictionary and expected is Dictionary:
		var ad: Dictionary = actual
		var bd: Dictionary = expected
		if ad.size() != bd.size():
			return false
		for key in ad:
			if not bd.has(key) or not _same(ad[key], bd[key]):
				return false
		return true
	return actual == expected


func report() -> int:
	print("\n═══════════════════════════════════════")
	print("Bestanden: %d   Fehlgeschlagen: %d" % [passed, failed])
	if failed > 0:
		print("\nFehlgeschlagene Prüfungen:")
		for entry in failures:
			print("  • %s" % entry)
	print("═══════════════════════════════════════")
	return failed
