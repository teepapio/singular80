class_name TestPang
extends RefCounted
## Rule tests for "Pang 3D" — the 1990 arcade original.
##
## This file is Pang's own. The shared suites carry the campaign, the arena
## constants and the save data; everything about a *hit* lives here. The
## headline rule is the two-shot trick — the smallest ball arms itself on the
## first harpoon and pops on the second — because that is the mechanic the
## original is known for and the one a player has to be able to rely on.

var t: TestKit


## Entry point used by `run_tests.gd`.
func run(kit: TestKit) -> void:
	t = kit
	_suite(_take_hits)
	_suite(_two_shot_trick)
	_suite(_ball_budget)


## Runs one suite and fails it if it returned before its own `t.suite_done()`,
## which is what a GDScript runtime error does.
func _suite(body: Callable) -> void:
	body.call()
	t.close_suite()


# --- what one hit does ------------------------------------------------------

## A hit is the only verb the player has besides walking, so the table of what
## it does to a ball of a given size is the game's core.
func _take_hits() -> void:
	t.suite("Pang — Treffer")

	# Everything above the smallest size splits, armed or not: the two-shot
	# trick belongs to the smallest ball alone.
	for size in range(Pang.SIZE_LARGEST, Pang.SIZE_SMALLEST):
		t.equal(Pang.hit_outcome(size, false), Pang.HIT_SPLIT, "Stufe %d teilt sich" % size)
		t.equal(Pang.hit_outcome(size, true), Pang.HIT_SPLIT, "Stufe %d teilt sich auch beim zweiten Versuch" % size)
		t.check(not Pang.needs_two_hits(size), "Stufe %d braucht nur einen Treffer" % size)
		t.equal(Pang.shots_needed(size), 1, "Stufe %d kostet einen Haken" % size)
		# Splitting pays the plain value of the ball, never a bonus.
		t.equal(Pang.hit_points(size, false), Pang.points_for(size), "Stufe %d zahlt seinen normalen Wert" % size)
		t.equal(Pang.hit_points(size, true), Pang.points_for(size), "Stufe %d zahlt auch im zweiten Versuch keinen Bonus" % size)

	# A size outside the table is clamped, never trusted: too big behaves like
	# the smallest size, too small like the largest.
	t.equal(Pang.hit_outcome(99, false), Pang.HIT_ARM, "Eine zu große Stufe zählt als kleinste")
	t.equal(Pang.hit_outcome(99, true), Pang.HIT_POP, "Und verhält sich auch wie sie")
	t.equal(Pang.hit_outcome(-4, false), Pang.HIT_SPLIT, "Eine zu kleine Stufe zählt als größte")
	t.suite_done()


# --- the two-shot trick -----------------------------------------------------

func _two_shot_trick() -> void:
	t.suite("Pang — Doppelgriff")

	t.check(Pang.needs_two_hits(Pang.SIZE_SMALLEST), "Die kleinste Kugel braucht zwei Haken")
	t.equal(Pang.shots_needed(Pang.SIZE_SMALLEST), 2, "Sie kostet zwei Haken")
	t.equal(Pang.hit_outcome(Pang.SIZE_SMALLEST, false), Pang.HIT_ARM, "Der erste Treffer spießt sie nur an")
	t.equal(Pang.hit_outcome(Pang.SIZE_SMALLEST, true), Pang.HIT_POP, "Der zweite platzt sie")

	# The move a player is actually making: two hits, one ball gone, no split.
	var armed := false
	var live := 1
	var seen: Array[String] = []
	for shot in 2:
		var outcome := Pang.hit_outcome(Pang.SIZE_SMALLEST, armed)
		seen.append(outcome)
		if outcome == Pang.HIT_ARM:
			armed = true
		elif outcome == Pang.HIT_POP:
			live = 0
		else:
			live += 1
	t.equal(seen, [Pang.HIT_ARM, Pang.HIT_POP], "Zwei Haken: erst anspießen, dann platzen")
	t.equal(live, 0, "Die kleine Kugel lässt sich ohne Teilen erledigen")

	# The consolation prize has to exist, or the first harpoon feels wasted.
	t.check(Pang.ARM_POINTS > 0, "Der erste Treffer zahlt etwas")
	t.check(Pang.ARM_POINTS < Pang.points_for(Pang.SIZE_SMALLEST), "Er zahlt weniger als die Kugel wert ist")
	t.equal(Pang.hit_points(Pang.SIZE_SMALLEST, false), Pang.ARM_POINTS, "Das Anspießen zahlt die Konsolenzahl")
	t.check(Pang.hit_points(Pang.SIZE_SMALLEST, true) > Pang.points_for(Pang.SIZE_SMALLEST),
		"Der zweite Treffer zahlt mehr als die Kugel")
	t.equal(Pang.hit_points(Pang.SIZE_SMALLEST, true), Pang.points_for(Pang.SIZE_SMALLEST) + Pang.ARM_BONUS,
		"Der Abschluss zahlt Kugelwert plus Bonus")
	t.check(Pang.ARM_BONUS > 0, "Der Bonus ist den zweiten Haken wert")

	# An armed ball has to be chasable, but not ignorable.
	t.check(Pang.ARM_SLOWDOWN > 0.0 and Pang.ARM_SLOWDOWN < 1.0, "Eine angespießte Kugel ist langsamer")
	t.almost(Pang.armed_speed(Pang.SIZE_SMALLEST), Pang.speed_of(Pang.SIZE_SMALLEST) * Pang.ARM_SLOWDOWN, 0.001,
		"Die Laufgeschwindigkeit folgt den Regeln")
	t.check(Pang.armed_speed(Pang.SIZE_SMALLEST) < Pang.speed_of(Pang.SIZE_SMALLEST), "Sie bleibt trotzdem langsamer")

	# The window is a chance, not a promise: long enough to walk over, short
	# enough that a stale ball is not a gift.
	t.check(Pang.ARM_WINDOW >= 3.0, "Das Fenster reicht zum Nachlaufen")
	t.check(Pang.ARM_WINDOW <= 10.0, "Aber nicht beliebig lang")

	# The tell is the only way a player learns a ball is armed, so it has to
	# blink and to be unmistakable in colour.
	t.check(not Pang.ARM_TINT.is_equal_approx(Color.BLACK), "Der Spießt-Blick hat eine eigene Farbe")
	for step in 8:
		var clock: float = float(step) * Pang.ARM_BLINK * 0.25
		t.check(Pang.is_blinking(clock) != Pang.is_blinking(clock + Pang.ARM_BLINK * 0.5),
			"Das Blinken schaltet um (Schritt %d)" % step)
	t.equal(Pang.is_blinking(0.0), Pang.is_blinking(0.0), "Das Blinken ist deterministisch")
	t.check(not Pang.ARM_HINT.is_empty(), "Die HUD lernt die Regel")

	# Nothing about the trick may make a level unclearable: the harpoon limit is
	# per shot, not per level.
	t.check(Pang.max_harpoons(0) > 0, "Es gibt immer mindestens einen Haken")
	t.suite_done()


# --- ball budget ------------------------------------------------------------

## Worst case for one layout: every ball splits down to the size above the
## smallest, and the smallest one is cleared with two hits instead of doubling.
func _peak_balls(layout: Dictionary) -> int:
	var peak := 0
	for ball in layout["balls"]:
		peak += 1 << maxi(0, Pang.SIZE_SMALLEST - 1 - int(ball["size"]))
	return peak


## The same number for a game without the two-shot trick, i.e. every ball
## splitting all the way down.
func _peak_splitting_everything(layout: Dictionary) -> int:
	var peak := 0
	for ball in layout["balls"]:
		peak += 1 << maxi(0, Pang.SIZE_SMALLEST - int(ball["size"]))
	return peak


func _ball_budget() -> void:
	t.suite("Pang — Kugelbudget")

	var widest := 0
	var widest_naive := 0
	for level in range(1, Pang.TOTAL_LEVELS + 1):
		var layout := Pang.level_data(level)
		var peak := _peak_balls(layout)
		var naive := _peak_splitting_everything(layout)
		widest = maxi(widest, peak)
		widest_naive = maxi(widest_naive, naive)
		# Arming a ball never costs a second ball, so the trick can only lower
		# the high-water mark.
		t.check(peak <= naive, "Level %d ballt mit dem Doppelgriff nicht mehr auf" % level)
		t.check(peak <= Pang.ORB_SAFE_CAP, "Level %d passt in den Pool" % level)
	t.check(widest > 0, "Die Kampagne hat überhaupt Kugeln")
	t.check(widest < widest_naive, "Der Doppelgriff senkt das Maximum gegenüber dem reinen Teilen")
	t.check(Pang.ORB_SAFE_CAP >= widest_naive, "Der Pool fasst weiterhin auch den ungeschonten Worst Case")
	t.suite_done()
