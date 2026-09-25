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


func suite(name: String) -> void:
	_current = name
	_suite_open = true
	print("\n── %s" % name)


## Last line of every suite body.
func suite_done() -> void:
	_suite_open = false


## Called by a runner after a suite function returned. If the body never
## reached `suite_done()` it was aborted by a runtime error.
func close_suite() -> void:
	if not _suite_open:
		return
	_suite_open = false
	fail("Suite '%s' brach ab (Laufzeitfehler)" % _current)


## Records a failure without an assertion.
func fail(description: String) -> void:
	failed += 1
	failures.append("%s → %s" % [_current, description])
	print("  ✗ %s" % description)


func check(condition: bool, description: String) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		failures.append("%s → %s" % [_current, description])
		print("  ✗ %s" % description)


func equal(actual: Variant, expected: Variant, description: String) -> void:
	var ok := _same(actual, expected)
	if ok:
		passed += 1
	else:
		failed += 1
		failures.append("%s → %s (erwartet %s, war %s)" % [_current, description, str(expected), str(actual)])
		print("  ✗ %s — erwartet %s, war %s" % [description, str(expected), str(actual)])


func almost(actual: float, expected: float, tolerance: float, description: String) -> void:
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
