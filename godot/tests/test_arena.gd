class_name TestArena
extends RefCounted
## Rule tests the arena owns.
##
## They live in this file rather than in the shared `test_improvements.gd`, so
## a second agent improving another game never has to touch the same file. The
## suite names are registered in `SCOPE_SUITES` of `scripts/scopes.mjs`; a suite
## that is not registered there would only ever run in the full sweep.

var t: TestKit


func run(kit: TestKit) -> void:
	t = kit
	_suite(_dash)


## Runs one suite and fails it if it returned before its own `t.suite_done()`,
## which is what a GDScript runtime error does.
func _suite(body: Callable) -> void:
	body.call()
	t.close_suite()


# --- dash --------------------------------------------------------------------

## The dash is the only way out of a swarm, and on a phone it has to be a
## button. These tests pin the promise that button makes: it presses exactly
## the action the dash mechanic listens to, and the ring it draws is the
## mechanic's own cooldown instead of a second number nobody maintains.
func _dash() -> void:
	t.suite("Arena — Dash")

	t.equal(ArenaRuns.DASH_ACTION, "dash", "Der Knopf drückt die Aktion 'dash'")
	t.check(MechanicsIndex.FACTORIES.has(ArenaRuns.DASH_ACTION),
		"Die Aktion des Knopfes ist der, auf die die Dash-Mechanik hört")

	# A finger has to produce the very same input a key produces.
	if not InputMap.has_action(ArenaRuns.DASH_ACTION):
		InputMap.add_action(ArenaRuns.DASH_ACTION)
	ArenaRuns.dash_press(true)
	t.check(Input.is_action_pressed(ArenaRuns.DASH_ACTION), "Der Knopf gedrückt startet den Dash")
	ArenaRuns.dash_press(false)
	t.check(not Input.is_action_pressed(ArenaRuns.DASH_ACTION), "Der Knopf losgelassen beendet ihn wieder")

	# The ring: 0 = ready, 1 = just dashed. The cooldown is handed in from the
	# mechanic, so it is the mechanic's number that is being drawn.
	var cooldown := 1.5
	t.almost(ArenaRuns.dash_cooldown_ratio(0.0, cooldown), 0.0, 0.0001, "Ohne Restzeit ist der Ring leer")
	t.almost(ArenaRuns.dash_cooldown_ratio(cooldown, cooldown), 1.0, 0.0001, "Direkt nach dem Dash ist der Ring voll")
	t.almost(ArenaRuns.dash_cooldown_ratio(cooldown * 0.5, cooldown), 0.5, 0.0001, "Ein halber Ring ist ein halber Dash")
	t.almost(ArenaRuns.dash_cooldown_ratio(-3.0, cooldown), 0.0, 0.0001, "Eine negative Restzeit wird geklemmt")
	t.almost(ArenaRuns.dash_cooldown_ratio(cooldown * 4.0, cooldown), 1.0, 0.0001, "Eine zu große Restzeit wird geklemmt")

	t.check(ArenaRuns.dash_ready(0.0), "Ohne Restzeit ist der Dash bereit")
	t.check(ArenaRuns.dash_ready(-0.5), "Auch eine negative Restzeit ist bereit")
	t.check(not ArenaRuns.dash_ready(0.2), "Während der Abklingzeit ist der Dash gesperrt")
	t.check(ArenaRuns.dash_charge_text(0.0) == "", "Bereit zeigt keine Zahl")
	t.equal(ArenaRuns.dash_charge_text(1.44), "1.4", "Der Knopf zeigt die Restzeit")

	# After-images: the burst has to be visible, otherwise the invulnerable
	# frames are just a blink the player cannot aim with.
	t.equal(ArenaRuns.DASH_TRAIL_STEPS, 3, "Drei Geister hinterlässt der Dash")
	t.check(ArenaRuns.DASH_TRAIL_TIME > 0.0, "Die Spur hat eine Dauer")
	t.almost(ArenaRuns.dash_trail_alpha(1.0), 1.0, 0.0001, "Im Dashframe ist die Spur voll")
	t.almost(ArenaRuns.dash_trail_alpha(0.0), 0.0, 0.0001, "Ohne Leuchten ist die Spur weg")
	t.check(ArenaRuns.dash_trail_alpha(2.0) <= 1.0, "Die Spur wird nicht heller als voll")
	t.check(ArenaRuns.dash_trail_alpha(0.5) < 0.5, "Die Spur blendet weich aus")
	t.check(ArenaRuns.dash_step_alpha(1.0, 0) > ArenaRuns.dash_step_alpha(1.0, 1), "Der jüngste Geist ist der hellste")
	t.check(ArenaRuns.dash_step_alpha(1.0, ArenaRuns.DASH_TRAIL_STEPS) <= 0.0, "Der älteste Geist verlischt")
	t.check(ArenaRuns.dash_step_alpha(0.0, 0) <= 0.0, "Ohne Leuchten zeichnet der Knopf keine Spur")
	t.suite_done()
