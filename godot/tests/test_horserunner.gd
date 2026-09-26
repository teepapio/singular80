class_name TestHorserunner
extends RefCounted
## Rule tests for "Pferde-Parcours 3D" — the three-lane endless run.
##
## The shared `Pferde-Parcours` suite in `test_logic.gd` covers the track
## geometry. The near-miss chain lives here in its own file so the rule
## coverage travels with the game and stays out of everybody else's way.

## Resolution of the jump-timing sweeps. 1 ms is roughly a frame at 60 fps, so a
## band measured with it is what a player can actually hit.
const SWEEP_STEP := 0.001

var t: TestKit


## Entry point used by `run_tests.gd`.
func run(kit: TestKit) -> void:
	t = kit
	_suite(_near_miss)
	_suite(_chain)


## Runs one suite and fails it if it returned before its own `t.suite_done()`,
## which is what a GDScript runtime error does.
func _suite(body: Callable) -> void:
	body.call()
	t.close_suite()


# --- helpers ----------------------------------------------------------------

## Verdict of a pass where the horse stays in the obstacle's lane and had
## pressed "jump" `lead` seconds before the obstacle arrived.
func _jump_verdict(spec: Dictionary, lead: float) -> String:
	return HorseRunner.pass_of(0.0, HorseRunner.jump_height(lead), 0.0, spec)


## Walks the whole jump from take-off to landing in `SWEEP_STEP` steps. A graze
## can only be the leading or the trailing edge of the window that clears the
## block, so the sweep has two bands and the report measures the *longest
## contiguous* one instead of first-to-last.
func _jump_sweep(spec: Dictionary) -> Dictionary:
	var counts := {HorseRunner.PASS_HIT: 0, HorseRunner.PASS_NEAR: 0, HorseRunner.PASS_CLEAR: 0}
	var longest := 0
	var run := 0
	var band_start := -1.0
	var first_near := -1.0
	var clears := -1.0
	var steps: int = int(0.72 / SWEEP_STEP)
	for i in steps + 1:
		var lead: float = float(i) * SWEEP_STEP
		var verdict := _jump_verdict(spec, lead)
		counts[verdict] = int(counts[verdict]) + 1
		if verdict != HorseRunner.PASS_HIT and clears < 0.0:
			clears = lead
		if verdict == HorseRunner.PASS_NEAR:
			if first_near < 0.0:
				first_near = lead
			if run == 0:
				band_start = lead
			run += 1
			longest = maxi(longest, run)
		else:
			run = 0
	return {
		"counts": counts,
		"clears": clears,
		"band": float(longest) * SWEEP_STEP,
		"first_near": first_near,
	}


## Verdict of a pass at hoof height `feet` with the horse `gap` world units
## beside the obstacle in its own lane. A negative gap overlaps the boxes.
func _side_verdict(spec: Dictionary, gap: float, feet: float) -> String:
	var touch: float = float(spec["halfWidth"]) + HorseRunner.HORSE_RADIUS
	return HorseRunner.pass_of(gap + touch, feet, 0.0, spec)


## Sweeps the horse sideways across `spec` at hoof height `feet`, starting
## inside the overlap, and returns the verdicts in order with runs of equal
## verdicts collapsed.
func _side_sweep(spec: Dictionary, feet: float) -> PackedStringArray:
	var out := PackedStringArray()
	var steps: int = int((3.5 + 0.4) / SWEEP_STEP)
	for i in steps + 1:
		var verdict := _side_verdict(spec, -0.4 + float(i) * SWEEP_STEP, feet)
		if out.is_empty() or out[out.size() - 1] != verdict:
			out.append(verdict)
	return out


## One metre of riding, with the chain rule of the screen.
func _advance(state: Dictionary) -> void:
	state["since"] = float(state["since"]) + 1.0
	var lost: int = HorseRunner.chain_after(float(state["since"]))
	if lost <= 0:
		return
	state["chain"] = maxi(0, int(state["chain"]) - lost)
	state["since"] = fmod(float(state["since"]), HorseRunner.CHAIN_HOLD)


## One obstacle skimmed, with the chain rule of the screen.
func _skim(state: Dictionary) -> void:
	state["chain"] = int(state["chain"]) + 1
	state["since"] = 0.0
	state["points"] = int(state["points"]) + HorseRunner.chain_bonus(int(state["chain"]))


func _ride_state() -> Dictionary:
	return {"chain": 0, "since": 0.0, "points": 0}


# --- suites -----------------------------------------------------------------

## A near miss has to be a real decision: safe riding earns nothing, but a jump
## that clears a block properly must not look like a near miss either.
func _near_miss() -> void:
	t.suite("Pferde-Parcours — Beinahe-Treffer")

	t.check(HorseRunner.GRAZE_MARGIN > 0.0, "Der Beinahe-Spielraum ist positiv")
	t.check(HorseRunner.GRAZE_MARGIN < HorseRunner.LANE_WIDTH - 1.0,
		"und kleiner als eine Spur, damit er nicht von selbst erreicht wird")
	t.equal(HorseRunner.jump_height(0.0), 0.0, "Vor dem Absprung steht das Pferd am Boden")
	t.equal(HorseRunner.jump_height(-1.0), 0.0, "Ein Sprung in der Zukunft auch nicht")
	t.almost(HorseRunner.jump_height(HorseRunner.JUMP_SPEED / HorseRunner.GRAVITY),
		HorseRunner.jump_apex(), 0.0001, "Die Sprungkurve erreicht genau die Sprunghöhe")

	for kind in HorseRunner.KINDS:
		var label := str(kind)
		var spec := HorseRunner.obstacle_spec(label)

		# Sprung über den Block: spät = knapp, zu spät = Sturz, mittig = sicher.
		var sweep := _jump_sweep(spec)
		var counts: Dictionary = sweep["counts"]
		t.check(int(counts[HorseRunner.PASS_HIT]) > 0, "%s: Zu spät gesprungen trifft" % label)
		t.check(int(counts[HorseRunner.PASS_NEAR]) > 0, "%s: Der Haarseil-Sprung zählt" % label)
		t.check(int(counts[HorseRunner.PASS_CLEAR]) > 0, "%s: Ein ruhiger Sprung zählt nicht" % label)
		t.equal(_jump_verdict(spec, 0.02), HorseRunner.PASS_HIT, "%s: 20 ms Vorlauf treffen" % label)
		t.equal(_jump_verdict(spec, HorseRunner.JUMP_SPEED / HorseRunner.GRAVITY), HorseRunner.PASS_CLEAR,
			"%s: Über den Scheitel zu springen ist sicher" % label)
		var band: float = float(sweep["band"])
		t.check(band > 0.04, "%s: Der Haarseil ist breiter als zwei Frames (%.0f ms)" % [label, band * 1000.0])
		t.check(band < 0.25, "%s: Der Haarseil bleibt schwierig (%.0f ms)" % [label, band * 1000.0])
		# Genau dort, wo der Sprung gerade noch trägt, ist auch der Beinahe-Treffer.
		t.check(absf(float(sweep["first_near"]) - float(sweep["clears"])) < 0.01,
			"%s: Der Haarseil liegt an der Kante des Sprungfensters" % label)

		# Nebeneinander: im freien Feld steht das Pferd zu weit weg, erst auf der
		# Linie zwischen zwei Blöcken zählt der Pass.
		t.almost(HorseRunner.lateral_gap(HorseRunner.lane_x(1), HorseRunner.lane_x(0), spec),
			HorseRunner.LANE_WIDTH - float(spec["halfWidth"]) - HorseRunner.HORSE_RADIUS, 0.0001,
			"%s: Abstand zur Nachbarspur" % label)
		t.check(HorseRunner.lateral_gap(HorseRunner.lane_x(1), HorseRunner.lane_x(0), spec) > HorseRunner.GRAZE_MARGIN,
			"%s: Die freie Spur ist kein Beinahe-Treffer" % label)
		t.equal(_side_sweep(spec, 0.0), PackedStringArray([HorseRunner.PASS_HIT, HorseRunner.PASS_NEAR, HorseRunner.PASS_CLEAR]),
			"%s: Seitlich Treffer, dann Haarseil, dann frei" % label)
		t.equal(_side_sweep(spec, HorseRunner.jump_apex()), PackedStringArray([HorseRunner.PASS_CLEAR]),
			"%s: Hoch über dem Block gibt es nichts zu holen" % label)

	# Die Kanten liegen genau auf dem Spielraum.
	var rock := HorseRunner.obstacle_spec(HorseRunner.OBSTACLE_ROCK)
	var touch: float = float(rock["halfWidth"]) + HorseRunner.HORSE_RADIUS
	t.almost(HorseRunner.lateral_gap(touch + HorseRunner.GRAZE_MARGIN, 0.0, rock), HorseRunner.GRAZE_MARGIN, 0.0001,
		"Genau am Spielraum ist der Abstand gemessen")
	t.equal(_side_verdict(rock, HorseRunner.GRAZE_MARGIN, 0.0), HorseRunner.PASS_NEAR, "Genau am Spielraum zählt es noch")
	t.equal(_side_verdict(rock, HorseRunner.GRAZE_MARGIN + 0.01, 0.0), HorseRunner.PASS_CLEAR, "Ein Zentimeter weiter ist frei")
	t.equal(_side_verdict(rock, 0.0, 0.0), HorseRunner.PASS_NEAR, "Anstreifen zählt als knapp")
	t.equal(_side_verdict(rock, -0.05, 0.0), HorseRunner.PASS_HIT, "Ein echter Stoß bleibt ein Treffer")
	t.equal(_side_verdict(rock, -0.05, HorseRunner.jump_apex()), HorseRunner.PASS_CLEAR, "und wird geflogen")
	t.equal(HorseRunner.pass_of(0.0, float(rock["top"]) + 0.001, 0.0, rock), HorseRunner.PASS_NEAR,
		"Knapp über der Kante zählt")
	t.equal(HorseRunner.pass_of(0.0, float(rock["top"]) + HorseRunner.GRAZE_MARGIN + 0.01, 0.0, rock), HorseRunner.PASS_CLEAR,
		"Deutlich darüber nicht mehr")
	t.check(HorseRunner.PASS_HIT != HorseRunner.PASS_NEAR and HorseRunner.PASS_NEAR != HorseRunner.PASS_CLEAR,
		"Die drei Urteile sind unterscheidbar")
	t.suite_done()


## The chain is the whole point: it pays more the longer the risky line holds,
## and it bleeds away again when the player plays it safe.
func _chain() -> void:
	t.suite("Pferde-Parcours — Kette")

	t.check(HorseRunner.GRAZE_POINTS > 0, "Ein Beinahe-Treffer zahlt etwas")
	t.check(HorseRunner.CHAIN_HOLD > 20.0, "Eine Kette hält länger als einen Blockabstand")
	t.equal(HorseRunner.chain_bonus(0), HorseRunner.GRAZE_POINTS, "Der erste Pass zahlt die Grundsumme")
	t.equal(HorseRunner.chain_bonus(1), HorseRunner.GRAZE_POINTS, "und bringt die Kette auf 1")
	t.equal(HorseRunner.chain_bonus(12), HorseRunner.GRAZE_POINTS * 12, "Der zwölfte Pass zahlt das Zwölffache")
	t.check(HorseRunner.chain_bonus(40) > HorseRunner.chain_bonus(12), "Die Kette wächst weiter")

	t.equal(HorseRunner.chain_after(0.0), 0, "Frisch gezählt verliert die Kette nichts")
	t.equal(HorseRunner.chain_after(-100.0), 0, "Negative Strecke zählt nicht")
	t.equal(HorseRunner.chain_after(HorseRunner.CHAIN_HOLD - 0.5), 0, "Knapp vor Ablauf bleibt sie")
	t.equal(HorseRunner.chain_after(HorseRunner.CHAIN_HOLD), 1, "Genau nach Ablauf ein Glied")
	t.equal(HorseRunner.chain_after(3.0 * HorseRunner.CHAIN_HOLD + 12.0), 3, "Drei Glieder auf einmal")

	var state := _ride_state()
	for i in 5:
		_advance(state)
		_skim(state)
	t.equal(int(state["chain"]), 5, "Fünf knappe Pässe ergeben eine Kette von 5")
	t.equal(int(state["points"]), HorseRunner.GRAZE_POINTS * 15, "die 1+2+3+4+5 zahlen")
	for i in int(HorseRunner.CHAIN_HOLD):
		_advance(state)
	t.equal(int(state["chain"]), 4, "Nach 70 m ohne Pass fehlt genau ein Glied")
	for i in int(HorseRunner.CHAIN_HOLD) * 6:
		_advance(state)
	t.equal(int(state["chain"]), 0, "Nach sieben Boxen Pause ist die Kette weg")
	t.equal(int(state["points"]), HorseRunner.GRAZE_POINTS * 15, "die Punkte bleiben stehen")
	t.suite_done()
