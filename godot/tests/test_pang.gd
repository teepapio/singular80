class_name TestPang
extends RefCounted
## Rule tests for "Pang 3D" — the 1990 arcade original.
##
## This file is Pang's own. The shared suites carry the campaign, the arena
## constants and the save data; everything about a *hit*, about the ball budget
## and about the reinforcement waves lives here. The headline rule is the
## two-shot trick — the smallest ball arms itself on the first harpoon and pops
## on the second — because that is the mechanic the original is known for and
## the one a player has to be able to rely on.

var t: TestKit


## Entry point used by `run_tests.gd`.
##
## The three "ball" bodies share one suite header: `scripts/scopes.mjs` maps
## every suite name to the scopes that run it, and that manifest is not this
## file's to change.
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


# --- more balls -------------------------------------------------------------

## Harpoons per second a level asks for: the campaign's pressure curve. It is
## the number that decides whether "more balls" is a fuller screen or a faster
## firing range, so it is measured instead of guessed.
func _pressure(level: int) -> float:
	var layout := Pang.level_data(level)
	return float(Pang.shot_cost(layout)) / float(layout["timeLimit"])


## The campaign ships more balls than the arcade original did: more chain balls,
## a crowd of small ones, and reinforcements from the middle on.
func _more_balls() -> void:
	# The ramp has to be a real one.
	var first := Pang.total_balls(Pang.level_data(1))
	var last := Pang.total_balls(Pang.level_data(Pang.TOTAL_LEVELS))
	t.check(first >= Pang.BALLS_START, "Level 1 öffnet mit mindestens %d Kugeln" % Pang.BALLS_START)
	t.check(last >= 16, "Der letzte Level bringt eine gefüllte Arena (hat %d)" % last)
	t.check(last > first * 2, "Die Kampagne wächst deutlich über ihr Level 1 hinaus")
	t.check(int(Pang.level_config(Pang.TOTAL_LEVELS)["ballCount"]) > int(Pang.level_config(1)["ballCount"]),
		"Die Kettenkugeln selbst werden mehr")

	# The riffle is what makes the arena look busy without making it expensive:
	# only the two smallest sizes, and never bigger than the level's own balls.
	for level in range(1, Pang.TOTAL_LEVELS + 1):
		var layout := Pang.level_data(level)
		var config := Pang.level_config(level)
		var riffle := int(config["riffleCount"])
		var balls: Array = layout["balls"]
		var chain: int = balls.size() - riffle
		t.equal(chain, int(config["ballCount"]), "Level %d legt seine Kettenkugeln einzeln aus" % level)
		if level < Pang.RIFFLE_FIRST_LEVEL:
			t.equal(riffle, 0, "Level %d bleibt noch ohne Kleinzeug" % level)
		for index in range(chain, balls.size()):
			var size := int(balls[index]["size"])
			t.check(size <= Pang.RIFFLE_SIZE, "Die Riffle-Kugel %d in Level %d ist klein" % [index, level])
			t.check(size >= int(config["baseSize"]), "…und nie größer als die Kettenkugeln des Levels")

	# More balls are only free if they also come with seconds. The pressure may
	# rise across the campaign, but it stays inside what a thumb can fire.
	var start_pressure := _pressure(1)
	var end_pressure := _pressure(Pang.TOTAL_LEVELS)
	for level in range(1, Pang.TOTAL_LEVELS + 1):
		var pressure := _pressure(level)
		t.check(pressure >= 0.1, "Level %d verlangt mindestens 0,1 Haken pro Sekunde" % level)
		t.check(pressure <= 3.5, "Level %d verlangt höchstens 3,5 Haken pro Sekunde" % level)
	t.check(end_pressure > start_pressure, "Spätere Level verlangen mehr pro Sekunde")
	t.check(end_pressure <= start_pressure * 20.0, "Der Druck wächst höchstens um das Zwanzigfache")


# --- reinforcement waves ----------------------------------------------------

## Reinforcement: the second and third batch of a level. It has to arrive while
## the level runs, it has to stay inside the ball budget, and a level must never
## be finished before its wave has shown up.
func _reinforcements() -> void:
	t.equal(Pang.wave_count(1), 0, "Level 1 kennt keine Wellen")
	t.equal(Pang.wave_count(Pang.WAVE_FIRST_LEVEL - 1), 0, "…und die Level davor auch nicht")
	t.check(Pang.wave_count(Pang.TOTAL_LEVELS) >= 1, "Der letzte Level schickt mindestens eine Welle")
	t.check(Pang.wave_count(Pang.TOTAL_LEVELS) <= Pang.WAVE_MAX, "Nie mehr Wellen als erlaubt")
	var previous := 0
	for level in range(1, Pang.TOTAL_LEVELS + 1):
		var waves := Pang.wave_count(level)
		t.check(waves >= previous, "Die Wellen kommen später dazu, nicht früher weg (Level %d)" % level)
		previous = waves

	# A wave that never arrives would make its level unclearable, a wave with a
	# negative trigger would arrive on the first frame. Both are rejected.
	var wave := {"index": 0, "trigger": 5, "maxDelay": 11.0, "balls": [{"x": 0.0, "y": 15.0, "size": 3}]}
	t.check(not Pang.wave_due(wave, 20, 0.0), "Ein volles Brett wartet auf die Welle")
	t.check(not Pang.wave_due(wave, 6, 0.0), "Ein randvolles Brett wartet noch")
	t.check(Pang.wave_due(wave, 5, 0.0), "Sobald das Brett dünn ist, kommt sie")
	t.check(Pang.wave_due(wave, 40, 11.0), "Und spätestens nach ihrer eigenen Wartezeit")
	t.check(Pang.wave_due(wave, 40, 99.0), "Auch bei einem dauerhaft vollen Brett")
	t.check(not Pang.wave_due({}, 0, 99.0), "Eine leere Welle kommt nie")
	t.check(Pang.WAVE_TRIGGER > 0, "Die Welle wartet auf ein Brett, das noch Bälle hat")
	t.check(Pang.WAVE_MAX_DELAY > 0.0, "Die Wartezeit ist endlich")

	var base := {"level": 1, "timeLimit": 60.0, "balls": [{"x": 0.0, "y": 8.0, "size": 2}]}
	var with_wave := base.duplicate()
	with_wave["waves"] = [wave]
	t.equal(Pang.validate_level(with_wave).size(), 0, "Eine saubere Welle ist spielbar")
	var empty := base.duplicate()
	empty["waves"] = [{"trigger": 5, "maxDelay": 11.0, "balls": []}]
	t.check(Pang.validate_level(empty).size() > 0, "Eine Welle ohne Kugeln wird erkannt")
	var stalled := base.duplicate()
	stalled["waves"] = [{"trigger": 5, "maxDelay": 0.0, "balls": [{"x": 0.0, "y": 15.0, "size": 3}]}]
	t.check(Pang.validate_level(stalled).size() > 0, "Eine Welle, die nie ankommt, wird erkannt")
	var stranded := base.duplicate()
	stranded["waves"] = [{"trigger": 5, "maxDelay": 11.0, "balls": [{"x": 0.0, "y": 1.0, "size": 3}]}]
	t.check(Pang.validate_level(stranded).size() > 0, "Eine Welle mit Kugeln im Spielersockel wird erkannt")

	# A layout without waves is still a layout: the counters have to read the old
	# shape instead of tripping over the missing key.
	t.equal(Pang.total_balls(base), 1, "Ein Layout ohne Wellen zählt nur seine Kugeln")
	t.equal(Pang.peak_balls(base), Pang.chain_peak(2), "…und misst dieselbe Spitze ohne Wellen")
	t.check(Pang.shot_cost(base) > 0, "…und kostet trotzdem Haken")

	# The wave balls are part of the level, not of the screen: the level select,
	# the budget and the player all count the same ones.
	for level in range(1, Pang.TOTAL_LEVELS + 1):
		var layout := Pang.level_data(level)
		var config := Pang.level_config(level)
		var waves: Array = layout["waves"]
		t.equal(waves.size(), int(config["waves"]), "Level %d bringt genau so viele Wellen mit" % level)
		t.equal(Pang.level_ball_total(level), Pang.total_balls(layout), "Die Kartenzahl stimmt mit dem Layout überein (Level %d)" % level)
		t.equal(Pang.level_ball_total(level), int(config["ballCount"]) + int(config["riffleCount"]) + _sum_wave_balls(waves),
			"…und sie zählt Kette, Riffle und Wellen (Level %d)" % level)
		for wave_entry in waves:
			var batch: Array = (wave_entry as Dictionary)["balls"]
			t.check(not batch.is_empty(), "Eine Welle in Level %d hat Kugeln dabei" % level)
			for ball in batch:
				# The reinforcement is never bigger than the rules ask for, so a
				# wave can never cost more pool slots than the cap reserves.
				t.check(int(ball["size"]) <= Pang.reinforcement_size(int(config["baseSize"])),
					"Der Nachschub in Level %d hält sich an die Größenregel" % level)
		# The layout is reproducible, waves included.
		t.equal(Pang.level_data(level)["waves"], waves, "Die Wellen sind reproduzierbar (Level %d)" % level)

	t.check(Pang.wave_balls(Pang.TOTAL_LEVELS, 1) >= Pang.wave_balls(Pang.TOTAL_LEVELS, 0),
		"Die zweite Welle eines Levels ist mindestens so groß wie die erste")
	t.check(Pang.wave_balls(1, 0) >= Pang.WAVE_BALLS_START, "Eine Welle hat mindestens %d Kugeln" % Pang.WAVE_BALLS_START)
	t.check(Pang.wave_balls(1, 99) <= Pang.WAVE_BALLS_END, "Und wird nicht beliebig groß")
	t.check(Pang.reinforcement_size(Pang.SIZE_LARGEST) > Pang.SIZE_LARGEST, "Der Nachschub ist kleiner als die Kettenkugeln")
	t.check(Pang.reinforcement_size(Pang.SIZE_SMALLEST) <= Pang.SIZE_SMALLEST, "Und bleibt in der Größentabelle")

	# The count sits in front of a noun in the HUD and on the level card.
	t.equal(Pang.wave_label(1), "1 Welle", "Eine einzelne Welle heißt Welle")
	t.equal(Pang.wave_label(0), "0 Wellen", "Keine heißt Wellen")
	t.equal(Pang.wave_label(2), "2 Wellen", "Zwei heißen Wellen")


func _sum_wave_balls(waves: Array) -> int:
	var total := 0
	for wave in waves:
		total += ((wave as Dictionary)["balls"] as Array).size()
	return total


# --- ball budget ------------------------------------------------------------

## Worst case for one layout: every ball splits down to the size above the
## smallest, and the smallest one is cleared with two hits instead of doubling.
## The reinforcement waves are counted, because they are live balls too.
func _peak_balls(layout: Dictionary) -> int:
	return _sum_peak(layout, Pang.SIZE_SMALLEST - 1)


## The same number for a game without the two-shot trick, i.e. every ball
## splitting all the way down.
func _peak_splitting_everything(layout: Dictionary) -> int:
	return _sum_peak(layout, Pang.SIZE_SMALLEST)


func _sum_peak(layout: Dictionary, leaf: int) -> int:
	var peak := 0
	for ball in layout["balls"]:
		peak += 1 << maxi(0, leaf - int(ball["size"]))
	for wave in layout.get("waves", []):
		for ball in (wave as Dictionary)["balls"]:
			peak += 1 << maxi(0, leaf - int(ball["size"]))
	return peak


func _ball_budget() -> void:
	t.suite("Pang — Kugelbudget")

	_more_balls()
	_reinforcements()

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
		# The rule the screen sizes its pool from has to agree with the walk
		# above, otherwise the cap is a coincidence.
		t.equal(Pang.peak_balls(layout), peak, "Die Pool-Regel zählt Level %d genauso" % level)
	t.check(widest > 0, "Die Kampagne hat überhaupt Kugeln")
	t.check(widest < widest_naive, "Der Doppelgriff senkt das Maximum gegenüber dem reinen Teilen")
	t.check(Pang.ORB_SAFE_CAP >= widest_naive, "Der Pool fasst weiterhin auch den ungeschonten Worst Case")
	# Headroom is what lets a wave drop into a board that is already splitting.
	t.check(Pang.ORB_SAFE_CAP >= widest * 2, "Der Pool hat Reserve für eine Welle auf vollem Brett")
	t.suite_done()
