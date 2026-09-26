class_name TestDragonRpg
extends RefCounted
## Rule tests for "Drachen-RPG" that belong to this game alone: the escape
## burst (Drachenflucht). Everything in `core/logic/dragon_rpg.gd` is pure, so
## it is tested here without a scene tree; the screen only draws what these
## rules decide.

var t: TestKit


## Entry point used by `run_tests.gd`.
func run(kit: TestKit) -> void:
	t = kit
	_suite(_dash_tuning)
	_suite(_dash_direction)
	_suite(_dash_lifecycle)


## Runs one suite and fails it if it returned before its own `t.suite_done()`,
## which is what a GDScript runtime error does.
func _suite(body: Callable) -> void:
	body.call()
	t.close_suite()


# --- tuning -----------------------------------------------------------------

func _dash_tuning() -> void:
	t.suite("Drachen-RPG — Fluchttuning")
	t.check(DragonRpg.DASH_DURATION > 0.0, "Der Drachenflucht dauert")
	t.check(DragonRpg.DASH_COOLDOWN >= DragonRpg.DASH_DURATION, "Die Abklingzeit ist länger als der Stoß")
	t.check(DragonRpg.DASH_SPEED_MULT > 1.0, "Der Stoß ist schneller als Laufen")
	t.check(DragonRpg.DASH_IFRAMES >= DragonRpg.DASH_DURATION, "Die Unverwundbarkeit überdauert den Stoß")
	t.check(DragonRpg.DASH_COOLDOWN <= 1.5, "Die Abklingzeit bleibt kurz genug zum Fliehen")

	var stats := DragonRpg.base_player_stats()
	t.almost(DragonRpg.dash_distance(stats.move_speed),
		stats.move_speed * DragonRpg.DASH_SPEED_MULT * DragonRpg.DASH_DURATION, 0.001,
		"Die Fluchtdistanz folgt dem Lauftempo")
	t.equal(DragonRpg.dash_distance(0.0), 0.0, "Ohne Tempo gibt es keine Fluchtdistanz")
	t.equal(DragonRpg.dash_distance(-5.0), 0.0, "Ein negatives Tempo wird zu keinem")

	# The point of the whole feature: a late-wave dragon is quicker than the
	# player, so walking cannot break away — the dash has to.
	var fastest := 0.0
	for wave in [10, 15, 18, 20]:
		var config := DragonRpg.wave_config(wave)
		for type in (config["pool"] as Array):
			fastest = maxf(fastest, float(DragonRpg.scaled_dragon(type, config)["speed"]))
	t.check(fastest > stats.move_speed, "In späten Wellen ist ein Drache schneller als der Spieler (%.2f)" % fastest)
	t.check(DragonRpg.dash_distance(stats.move_speed) > fastest * DragonRpg.DASH_DURATION,
		"Der Drachenflucht entkommt auch dem schnellsten Drachen")
	t.suite_done()


# --- direction --------------------------------------------------------------

func _dash_direction() -> void:
	t.suite("Drachen-RPG — Fluchtrichtung")

	var stick := DragonRpg.dash_direction(Vector2(1.0, 0.0), Vector2(0.0, -1.0), Vector3.FORWARD)
	t.almost(stick.x, 1.0, 0.001, "Der Stick bestimmt die Richtung")
	t.almost(stick.z, 0.0, 0.001, "…und sonst nichts")
	t.equal(stick.length(), 1.0, "Die Fluchtrichtung ist normiert")

	var partial := DragonRpg.dash_direction(Vector2(0.03, 0.0), Vector2(0.0, -1.0), Vector3.FORWARD)
	t.check(absf(partial.z - 1.0) < 0.001, "Ein verirrter Stick zählt nicht")

	var panic := DragonRpg.dash_direction(Vector2.ZERO, Vector2(0.0, -1.0), Vector3.FORWARD)
	t.almost(panic.z, 1.0, 0.001, "Ohne Stick flieht man vor dem Drachen weg")

	var behind := DragonRpg.dash_direction(Vector2.ZERO, Vector2(5.0, 0.0), Vector3(0.0, 0.0, 1.0))
	t.almost(behind.x, -1.0, 0.001, "Die Richtung liegt zwischen Spieler und Drach")

	var alone := DragonRpg.dash_direction(Vector2.ZERO, Vector2.ZERO, Vector3(0.0, 0.0, -1.0))
	t.almost(alone.z, -1.0, 0.001, "Ganz allein flieht man in Blickrichtung")

	var nothing := DragonRpg.dash_direction(Vector2.ZERO, Vector2.ZERO, Vector3.ZERO)
	t.check(nothing.length() > 0.0, "Auch ohne jede Richtung flieht man irgendwohin")
	t.equal(nothing.y, 0.0, "Die Fluchtrichtung bleibt am Boden")
	t.suite_done()


# --- lifecycle --------------------------------------------------------------

func _dash_lifecycle() -> void:
	t.suite("Drachen-RPG — Drachenflucht")
	var dash := DragonRpg.Dash.new()
	t.check(dash.ready(), "Der Drachenflucht startet bereit")
	t.equal(dash.charge(), 1.0, "Die Abklingzeit ist gefüllt")
	t.equal(dash.step(0.016, 9.0), Vector3.ZERO, "Ohne Stoß bewegt sich niemand")
	t.check(dash.start(Vector3(1.0, 0.0, 0.0)), "Der Stoß startet")
	t.check(not dash.ready(), "Danach ist der Knopf dunkel")
	t.check(dash.charge() < 1.0, "Die Anzeige füllt sich wieder")
	t.check(not dash.start(Vector3(0.0, 0.0, 1.0)), "Zweimal hintereinander geht nicht")
	t.check(dash.direction.is_equal_approx(Vector3.RIGHT), "Die Richtung bleibt die gewählte")

	t.almost(dash.time_left, DragonRpg.DASH_DURATION, 0.0001, "Der Stoß läuft die volle Dauer")
	t.almost(dash.iframes(), DragonRpg.DASH_IFRAMES, 0.0001, "Der Stoß schützt sofort")
	t.check(dash.iframes() > 0.0, "Drachen können den Fliehenden nicht treffen")

	# Summing the frames has to reproduce the advertised distance.
	var travelled := 0.0
	var frames := 0
	while dash.time_left > 0.0 and frames < 60:
		travelled += dash.step(0.016, 9.0).length()
		dash.tick(0.016)
		frames += 1
	t.almost(travelled, DragonRpg.dash_distance(9.0), 0.01, "Der Spieler legt die angegebene Strecke zurück")
	t.check(frames > 1, "Der Stoß besteht aus mehr als einem Frame")

	# A long frame may not throw the player across the arena.
	var late := DragonRpg.Dash.new()
	late.start(Vector3(0.0, 0.0, 1.0))
	t.almost(late.step(2.0, 9.0).length(), DragonRpg.dash_distance(9.0), 0.01,
		"Ein langer Frame überschießt den Stoß nicht")
	t.check(dash.step(0.016, 9.0) == Vector3.ZERO, "Nach dem Stoß geht es normal weiter")
	t.check(dash.time_left <= 0.0, "Der Stoß ist vorbei")

	var no_direction := DragonRpg.Dash.new()
	t.check(not no_direction.start(Vector3.ZERO), "Ohne Richtung gibt es keinen Stoß")
	t.check(no_direction.ready(), "Ein gescheiterter Stoß verbraucht nichts")

	dash.tick(DragonRpg.DASH_IFRAMES)
	t.check(dash.iframes() <= 0.0, "Die Unverwundbarkeit endet")
	t.check(not dash.ready(), "Die Abklingzeit läuft noch")
	dash.tick(DragonRpg.DASH_COOLDOWN)
	t.check(dash.ready(), "Danach ist der Knopf wieder hell")
	t.equal(dash.charge(), 1.0, "Die Anzeige ist wieder gefüllt")
	t.check(dash.start(Vector3(0.0, 0.0, 1.0)), "Der zweite Stoß klappt")
	t.suite_done()
