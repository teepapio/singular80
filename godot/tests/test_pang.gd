class_name TestPang
extends RefCounted
## Rule tests for "Pang 3D" — the 1990 arcade original.
##
## This file is Pang's own. The shared suites carry the campaign, the arena
## constants and the save data; everything about a *hit*, about the ball budget
## and about the reinforcement waves lives here. The headline rule is the
## two-shot trick — the smallest ball arms itself on the first harpoon and pops
## on the second — because that is the mechanic the original is known for and
## the one a player has to be able to rely on. The second headline is the wave
## warning: a reinforcement announces the flank it will drop over and counts
## down before it falls, so the arrival is a decision and not an interruption.

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
	_suite(_wave_warning)


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
	# negative trigger would arrive on the first frame. Both are rejected. Being
	# due is not the same as falling: the announcement owns the gap between the
	# two, which is what the warning suite below pins down.
	var wave := {"index": 0, "trigger": 5, "maxDelay": 11.0, "balls": [{"x": 0.0, "y": 15.0, "size": 3}]}
	t.check(not Pang.wave_due(wave, 20, 0.0), "Ein volles Brett wartet auf die Welle")
	t.check(not Pang.wave_due(wave, 6, 0.0), "Ein randvolles Brett wartet noch")
	t.check(Pang.wave_due(wave, 5, 0.0), "Sobald das Brett dünn ist, ist sie fällig")
	t.check(Pang.wave_due(wave, 40, 11.0), "Und spätestens nach ihrer eigenen Wartezeit")
	t.check(Pang.wave_due(wave, 40, 99.0), "Auch bei einem dauerhaft vollen Brett")
	t.check(not Pang.wave_due({}, 0, 99.0), "Eine leere Welle kommt nie")
	t.check(Pang.WAVE_TRIGGER > 0, "Die Welle wartet auf ein Brett, das noch Bälle hat")
	t.check(Pang.WAVE_MAX_DELAY > 0.0, "Die Wartezeit ist endlich")
	t.equal(Pang.wave_stage(wave, 0, 0.0, -1.0), Pang.WAVE_WARNING, "Fällig heißt zuerst: ankündigen, nicht fallen")

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


# --- the wave warning -------------------------------------------------------
# A reinforcement used to fall out of the ceiling with nothing but a sound and
# a shake. It is now announced first: the flank it will arrive over lights up,
# a countdown runs, and only then do the balls drop. The clock keeps ticking
# while the player decides, so the warning is paid for in seconds. Three things
# have to hold for that to be a decision rather than decoration, and each gets
# its own block below:
#
#   * the batch always comes over *one* flank, so there is a safe side to run to
#   * the timeline always runs silent → announced → falling, and never skips a
#     step, not even when the board empties in the same frame
#   * what the floor, the number and the HUD text promise is the same arrival

## A hand-written wave, so the rules can be read without walking a level. Two
## balls over one flank, an own `warnTime` and the usual trigger.
func _left_wave(balls: Array = [{"x": -10.0, "y": 15.0, "size": 3}, {"x": -4.0, "y": 15.0, "size": 3}]) -> Dictionary:
	return {"index": 0, "trigger": 5, "maxDelay": 11.0, "warnTime": 2.0, "balls": balls}


func _wave_warning() -> void:
	t.suite("Pang — Wellenwarnung")

	_flank()
	_timeline()
	_alarm()

	t.suite_done()


## Where a wave arrives: always one flank, always with a safe side left.
func _flank() -> void:
	# The sides are arithmetic, so a retry sees the same arrival and the tests
	# can name the side they expect.
	for level in range(1, Pang.TOTAL_LEVELS + 1):
		for index in maxi(1, Pang.wave_count(level)):
			var flank := Pang.wave_flank(level, index)
			t.check(flank == -1 or flank == 1, "Die Flanke %d/%d ist eine Seite" % [level, index])
	# Two waves of the same level therefore come from opposite sides.
	var two_wave := -1
	for level in range(1, Pang.TOTAL_LEVELS + 1):
		if Pang.wave_count(level) >= 2:
			t.check(
				Pang.wave_flank(level, 0) != Pang.wave_flank(level, 1),
				"Zwei Wellen in Level %d kommen von verschiedenen Seiten" % level
			)
			two_wave = level
			break
	t.check(two_wave > 0, "Die Kampagne hat überhaupt ein Level mit zwei Wellen")

	# The span each flank offers: inside the arena, mirrored, and leaving the
	# middle free.
	var left := Pang.flank_range(-1)
	var right := Pang.flank_range(1)
	t.almost(left.x, -right.y, 0.001, "Die Flanken sind spiegelbildlich")
	t.almost(left.y, -right.x, 0.001, "…auf beiden Seiten gleich weit vom Rand")
	t.check(left.x >= -Pang.ARENA_HALF_WIDTH and right.y <= Pang.ARENA_HALF_WIDTH, "Keine Flanke ragt aus der Arena")
	t.check(left.y <= -Pang.WAVE_BAND_GAP and right.x >= Pang.WAVE_BAND_GAP, "Die Mitte bleibt frei")
	t.check(Pang.WAVE_BAND_MARGIN > 0.0, "Eine Welle startet nicht an der Wand")

	# The band a wave paints has to be the band its balls fall over — otherwise
	# the warning sends the player to the wrong side of the arena.
	for level in range(1, Pang.TOTAL_LEVELS + 1):
		var layout := Pang.level_data(level)
		for wave in layout["waves"]:
			var entry: Dictionary = wave
			var band: Vector2 = Pang.wave_band(entry)
			for ball in entry["balls"]:
				var spot: Dictionary = ball
				var radius := Pang.radius_of(int(spot["size"]))
				t.check(
					absf(float(spot["x"]) - (band.x + band.y) * 0.5) <= (band.y - band.x) * 0.5,
					"Das Band in Level %d umschließt seine Kugel" % level
				)
				t.check(
					float(spot["x"]) - radius >= band.x - 0.001 and float(spot["x"]) + radius <= band.y + 0.001,
					"…sogar mit ihrem Radius"
				)
			# The whole point of a flank: the other half of the floor stays safe,
			# and there is a spot to run to.
			var centre: float = (band.x + band.y) * 0.5
			var side := Pang.wave_side(band)
			t.check(side != 0, "Das Band in Level %d liegt auf einer Seite" % level)
			var safe := Pang.ARENA_HALF_WIDTH - 1.0 if side < 0 else -Pang.ARENA_HALF_WIDTH + 1.0
			t.check(not Pang.in_wave_band(entry, safe), "…und die andere Hälfte ist sicher (Level %d)" % level)
			t.check(Pang.in_wave_band(entry, centre), "…die Mitte des Bandes gehört dazu")
			t.check(Pang.wave_band(entry) == band, "Das Band ist reproduzierbar (Level %d)" % level)

	# A wave without balls is total, not crashing: the band is then the whole
	# arena and the label says so, because a hand-written layout may say that.
	t.equal(Pang.wave_band({}), Vector2(-Pang.ARENA_HALF_WIDTH, Pang.ARENA_HALF_WIDTH), "Eine Welle ohne Kugeln hat das ganze Feld als Band")
	t.equal(Pang.wave_side_label(_left_wave()), "links", "Ein Band links heißt links")
	t.equal(Pang.wave_side_label(_left_wave([{"x": 10.0, "y": 15.0, "size": 3}])), "rechts", "…und rechts heißt rechts")
	t.equal(Pang.wave_side_label(_left_wave([{"x": 0.0, "y": 15.0, "size": 3}])), "der Mitte", "Eine mittige Welle braucht die dritte Form")

	# The level card names the side, so a player can read a level's plan before
	# the first ball drops.
	t.equal(Pang.wave_flanks_label(1), "", "Ein Level ohne Wellen nennt keine Seite")
	var first_wave_level := 0
	for level in range(1, Pang.TOTAL_LEVELS + 1):
		if Pang.wave_count(level) > 0:
			first_wave_level = level
			break
	t.check(first_wave_level >= Pang.WAVE_FIRST_LEVEL, "Der erste Level mit Welle liegt nicht vor dem Nachschub")
	t.check(Pang.wave_flanks_label(first_wave_level) in ["links", "rechts"], "Eine einzelne Welle nennt genau eine Seite")
	var expected: Array[String] = []
	for index in Pang.wave_count(Pang.TOTAL_LEVELS):
		expected.append("links" if Pang.wave_flank(Pang.TOTAL_LEVELS, index) < 0 else "rechts")
	t.equal(Pang.wave_flanks_label(Pang.TOTAL_LEVELS), ", ".join(expected),
		"Der letzte Level nennt seine Wellen in Ankunftsreihenfolge")
	t.equal(expected.size(), 2, "…und das sind zwei Seiten")


## The timeline: silent, announced, falling — and it never skips a step.
func _timeline() -> void:
	var wave := _left_wave()
	var warn := Pang.wave_warn_time(wave)

	# The length of the window is a balance decision: long enough to cross the
	# arena, short enough that the clock is still ticking.
	t.check(Pang.WAVE_WARN_TIME >= 1.5, "Die Warnung reicht zum Überqueren")
	t.check(Pang.WAVE_WARN_TIME <= 5.0, "Aber sie kostet nicht das halbe Level")
	t.almost(warn, 2.0, 0.001, "Die Welle trägt ihre eigene Warnzeit")
	t.check(Pang.wave_warn_time({}) == Pang.WAVE_WARN_TIME, "Eine Welle ohne Angabe nimmt die Vorgabe")
	t.check(Pang.wave_warn_time({"warnTime": -4.0}) >= 0.0, "Eine negative Warnzeit wird auf null geklemmt")

	# Silent while the board is full, silent before the own wait is up.
	t.equal(Pang.wave_stage(wave, 20, 0.0, -1.0), Pang.WAVE_PENDING, "Ein volles Brett hat keinen Nachschub im Blick")
	t.equal(Pang.wave_stage(wave, 6, 0.0, -1.0), Pang.WAVE_PENDING, "Ein randvolles Brett ebenso wenig")
	t.check(not Pang.wave_due(wave, 6, 0.0), "…weil die Welle noch nicht fällig ist")
	# Due the moment the board thins out — that is the moment the warning starts.
	t.equal(Pang.wave_stage(wave, 5, 0.0, -1.0), Pang.WAVE_WARNING, "Ein dünnenes Brett kündigt sie sofort an")
	t.equal(Pang.wave_stage(wave, 0, 0.0, -1.0), Pang.WAVE_WARNING, "Auch ein leeres Brett")
	t.equal(Pang.wave_stage(wave, 40, 11.0, -1.0), Pang.WAVE_WARNING, "Und spätestens nach ihrer eigenen Wartezeit")
	t.check(Pang.wave_due(wave, 40, 11.0), "…weil die Welle dann fällig ist")

	# The warning runs its whole window before anything falls.
	t.equal(Pang.wave_stage(wave, 0, 0.0, 0.0), Pang.WAVE_WARNING, "Im ersten Frame der Warnung fällt noch nichts")
	t.equal(Pang.wave_stage(wave, 0, 0.0, warn * 0.5), Pang.WAVE_WARNING, "…und in der Hälfte auch nicht")
	t.equal(Pang.wave_stage(wave, 0, 0.0, warn), Pang.WAVE_FALLING, "Erst am Ende fällt der Nachschub")
	t.equal(Pang.wave_stage(wave, 0, 0.0, warn + 10.0), Pang.WAVE_FALLING, "Danach bleibt er fällig")
	t.equal(Pang.wave_stage(wave, 99, 99.0, -1.0), Pang.WAVE_WARNING, "Auch ein volles Brett kann sie nicht mehr aufhalten")
	# What decides the moment is the wave's own window, not the constant — so a
	# level that wants a different beat can have one.
	var quick := wave.duplicate()
	quick["warnTime"] = warn * 0.25
	t.equal(Pang.wave_stage(quick, 0, 0.0, warn * 0.5), Pang.WAVE_FALLING, "Eine kürzer angekündigte Welle fällt früher")
	t.equal(Pang.wave_stage(wave, 0, 0.0, warn * 0.5), Pang.WAVE_WARNING, "…eine länger angekündigte eben nicht")

	# A wave with no balls never falls, and an empty timeline never starts.
	t.equal(Pang.wave_stage({}, 0, 0.0, -1.0), Pang.WAVE_PENDING, "Eine leere Welle bleibt still")
	t.equal(Pang.wave_stage({}, 0, 0.0, 99.0), Pang.WAVE_PENDING, "…und fällt auch nicht, wenn die Zeit läuft")

	# Progress: 0 while silent, 1 at the end, and never outside 0..1.
	t.almost(Pang.wave_progress(wave, -1.0), 0.0, 0.001, "Ohne Warnung gibt es keinen Fortschritt")
	t.almost(Pang.wave_progress(wave, 0.0), 0.0, 0.001, "Am Anfang der Warnung auch nicht")
	t.almost(Pang.wave_progress(wave, warn), 1.0, 0.001, "Am Ende ist sie voll")
	t.almost(Pang.wave_progress(wave, warn * 0.5), 0.5, 0.001, "In der Mitte halb")
	t.check(Pang.wave_progress(wave, 99.0) <= 1.0, "Fortschritt läuft nicht über eins hinaus")

	# The countdown every layer prints.
	t.equal(Pang.wave_eta(wave, 20, 0.0, -1.0), -1.0, "Ohne Warnung gibt es keine Restzeit")
	t.almost(Pang.wave_eta(wave, 0, 0.0, 0.0), warn, 0.001, "Am Anfang steht die ganze Warnzeit")
	t.almost(Pang.wave_eta(wave, 0, 0.0, warn * 0.5), warn * 0.5, 0.001, "…und läuft von dort herunter")
	t.equal(Pang.wave_eta(wave, 0, 0.0, warn), 0.0, "Beim Fallen ist keine Zeit mehr übrig")
	t.check(Pang.wave_eta(wave, 0, 0.0, warn + 5.0) >= 0.0, "Und nie eine negative")

	# The whole thing has to fit into the level: a wave that is announced on the
	# very last second would be a warning nobody can use.
	for level in range(1, Pang.TOTAL_LEVELS + 1):
		var config := Pang.level_config(level)
		if int(config["waves"]) > 0:
			t.check(
				float(config["timeLimit"]) > Pang.WAVE_MAX_DELAY + Pang.WAVE_WARN_TIME,
				"Level %d lässt Platz für die ganze Warnung" % level
			)


## What the player reads: the HUD line, the marker and the knight all have to
## describe the same arrival.
func _alarm() -> void:
	var wave := _left_wave()
	var warn := Pang.wave_warn_time(wave)

	# Nothing while the wave is still silent — a warning that cries wolf is
	# worse than no warning.
	t.equal(Pang.wave_alert(wave, -1.0), "", "Stille Wellen schweigen im HUD")
	t.equal(Pang.wave_alert({}, 0.0), "", "Und eine leere Welle erst recht")
	t.check(Pang.wave_alert(wave, 0.0).length() > 0, "Angekündigte Wellen schreiben es hin")
	t.check(Pang.wave_alert(wave, 0.0).contains("links"), "…und sagen, von welcher Seite")

	# The number in the text is the number the countdown shows.
	for step in 5:
		var waited: float = warn * float(step) / 4.0
		var text := Pang.wave_alert(wave, waited)
		var eta := Pang.wave_eta(wave, 0, 0.0, waited)
		t.check(text.contains("%.1f" % eta), "Der Text nennt die Restzeit (Schritt %d)" % step)
		t.check(text.contains("noch"), "…und sagt, dass es eine Restzeit ist (Schritt %d)" % step)

	# The band is a real place the player can be told to leave, so the rules
	# have to be able to answer both directions.
	t.check(Pang.in_wave_band(wave, -7.0), "Ein Punkt im Band gehört zum Band")
	t.check(not Pang.in_wave_band(wave, 0.0), "Die Mitte ist außerhalb")
	t.check(not Pang.in_wave_band(wave, Pang.ARENA_HALF_WIDTH - 0.5), "…und die gegenüberliegende Wand auch")
	t.check(Pang.WAVE_BAND_GROW > 0.0, "Das Band wächst im Countdown, damit der Boden mitredet")

	# A wave whose band leaves no safe side, or that lies about its warning, is
	# rejected — the same way an unplayable layout is.
	var base := {"level": 1, "timeLimit": 60.0, "balls": [{"x": 0.0, "y": 8.0, "size": 2}]}
	var wide := base.duplicate()
	wide["waves"] = [{
		"trigger": 5, "maxDelay": 11.0, "warnTime": 2.0,
		"balls": [{"x": -14.0, "y": 15.0, "size": 3}, {"x": 14.0, "y": 15.0, "size": 3}],
	}]
	t.check(Pang.validate_level(wide).size() > 0, "Eine Welle ohne sicheren Platz wird erkannt")
	var thin := base.duplicate()
	# A band that leaves a strip a knight could not stand in is just as useless.
	thin["waves"] = [{
		"trigger": 5, "maxDelay": 11.0, "warnTime": 2.0,
		"balls": [{"x": -12.0, "y": 15.0, "size": 3}, {"x": 12.0, "y": 15.0, "size": 3}],
	}]
	t.check(Pang.validate_level(thin).size() > 0, "Ein zu schmales Band wird erkannt")
	t.check(Pang.WAVE_SAFE_MIN > Pang.PLAYER_HALF_WIDTH * 2.0, "Der sichere Platz ist breiter als der Spieler")
	var too_soon := base.duplicate()
	too_soon["waves"] = [{"trigger": 5, "maxDelay": 11.0, "warnTime": -1.0, "balls": [{"x": -8.0, "y": 15.0, "size": 3}]}]
	t.check(Pang.validate_level(too_soon).size() > 0, "Eine Welle mit negativer Warnzeit wird erkannt")
	var announced := base.duplicate()
	announced["waves"] = [wave]
	t.equal(Pang.validate_level(announced).size(), 0, "Eine sauber angekündigte Welle ist spielbar")
	# A wave that hangs in the middle is unusual but legal: both sides are free,
	# so the player only has to pick one.
	var centred := base.duplicate()
	centred["waves"] = [{"trigger": 5, "maxDelay": 11.0, "warnTime": 2.0, "balls": [{"x": 0.0, "y": 15.0, "size": 3}]}]
	t.equal(Pang.validate_level(centred).size(), 0, "Eine mittige Welle ist ebenfalls spielbar")

	# The layout carries the warning, so the screen and the tests read the number
	# the level was built with.
	for level in range(1, Pang.TOTAL_LEVELS + 1):
		for wave_entry in Pang.level_data(level)["waves"]:
			t.equal(Pang.wave_warn_time(wave_entry), Pang.WAVE_WARN_TIME, "Das Layout nennt seine Warnzeit (Level %d)" % level)
