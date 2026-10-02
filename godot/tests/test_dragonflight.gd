class_name TestDragonFlight
extends RefCounted
## Regression tests for "Drachenflug" — the bloodline readout.
##
## The game breeds recessive traits, and a recessive trait needs two carriers.
## Before this readout the roster could not show a carrier at all, so chasing a
## rare gene was a blind gamble. Everything here is pure logic, so it runs in
## the plain logic phase of the headless suite.

var t: TestKit


## Entry point used by `run_tests.gd`.
##
## Every suite is followed by `t.close_suite()`: a GDScript runtime error unwinds
## the suite function without raising, so an aborted suite would look like one
## that simply stopped asserting.
func run(kit: TestKit) -> void:
	t = kit
	_alleles()
	t.close_suite()
	_states()
	t.close_suite()
	_flight_input()
	t.close_suite()
	_candidates()
	t.close_suite()
	_best_pair()
	t.close_suite()
	_egg_readout()
	t.close_suite()
	_purse()
	t.close_suite()


## A dragon with exactly these alleles; the other genes are left empty on
## purpose, so a test only ever sees what it put in.
func _dragon(uid: int, pairs: Dictionary, gen: int = 1) -> Dictionary:
	return {
		"uid": uid, "breed": "ember", "alleles": pairs, "gen": gen,
		"vitality": 1.0, "parents": [], "egg": null, "wins": 0, "runs": 0,
	}


func _profile_with(dragons: Array) -> Dictionary:
	var profile := DragonFlight.default_profile()
	profile["dragons"] = dragons
	profile["next_uid"] = 100
	return profile


# --- alleles ----------------------------------------------------------------

func _alleles() -> void:
	t.suite("Drachenflug — Allele")
	t.equal(DragonFlight.allele_pair({"feueratem": "Fa"}, "feueratem"), "Fa", "Ein Träger liest F a")
	t.equal(DragonFlight.allele_pair({"feueratem": "fF"}, "feueratem"), "Ff", "Die Reihenfolge ist egal")
	t.equal(DragonFlight.allele_pair({}, "feueratem"), "", "Ohne Allele gibt es kein Paar")
	t.equal(DragonFlight.allele_pair({"feueratem": "F"}, "feueratem"), "", "Ein einzelnes Allel ist kein Paar")
	t.equal(DragonFlight.allele_pair({"feueratem": "FF"}, "gibtsnicht"), "", "Unbekanntes Gen bleibt leer")

	# How many lowercase alleles a dragon carries: 0, 1 or 2.
	t.equal(DragonFlight.recessive_allele_count({"riesenwuchs": "RR"}, "riesenwuchs"), 0, "RR trägt nichts")
	t.equal(DragonFlight.recessive_allele_count({"riesenwuchs": "Rr"}, "riesenwuchs"), 1, "Rr trägt eines")
	t.equal(DragonFlight.recessive_allele_count({"riesenwuchs": "rR"}, "riesenwuchs"), 1, "rR zählt genauso")
	t.equal(DragonFlight.recessive_allele_count({"riesenwuchs": "rr"}, "riesenwuchs"), 2, "rr zeigt es")
	t.equal(DragonFlight.recessive_allele_count({}, "riesenwuchs"), 0, "Ohne Gen ist nichts da")
	t.suite_done()


# --- gene states ------------------------------------------------------------

func _states() -> void:
	t.suite("Drachenflug — Blutbild")
	# The core of it: a recessive trait is hidden but visible as a carrier. A
	# dominant one has nothing to hide.
	t.equal(DragonFlight.gene_state({"riesenwuchs": "rr"}, "riesenwuchs"), DragonFlight.GENE_SHOWS, "rr zeigt Riesenwuchs")
	t.equal(DragonFlight.gene_state({"riesenwuchs": "Rr"}, "riesenwuchs"), DragonFlight.GENE_CARRIER, "Rr ist ein Träger")
	t.equal(DragonFlight.gene_state({"riesenwuchs": "RR"}, "riesenwuchs"), DragonFlight.GENE_CLEAR, "RR ist frei")
	t.check(DragonFlight.is_carrier({"riesenwuchs": "Rr"}, "riesenwuchs"), "Ein Träger wird erkannt")
	t.check(not DragonFlight.is_carrier({"riesenwuchs": "RR"}, "riesenwuchs"), "Ein sauberer Drache ist kein Träger")
	# A dominant gene needs only one allele, so there is no blind carrier.
	t.equal(DragonFlight.gene_state({"feueratem": "Fa"}, "feueratem"), DragonFlight.GENE_SHOWS, "Ein Feueratem-Allel zeigt sich")
	t.check(not DragonFlight.is_carrier({"feueratem": "aa"}, "feueratem"), "Dominante Gene werden nie zum Träger")
	t.equal(DragonFlight.gene_state({}, "gibtsnicht"), DragonFlight.GENE_CLEAR, "Unbekanntes Gen ist frei")

	# State and expression must agree, or the readout contradicts the numbers.
	# Two lowercase alleles show a recessive trait and silence a dominant one —
	# the whole inheritance rule per gene, in one line.
	for gene in DragonFlight.TRAITS:
		var id := str(gene["id"])
		var dom := str(gene["dom"])
		var rec := dom.to_lower()
		var recessive: bool = bool(gene.get("recessive", false))
		t.equal(DragonFlight.gene_state({id: rec + rec}, id),
			DragonFlight.GENE_SHOWS if recessive else DragonFlight.GENE_CLEAR,
			"Zwei kleine passen zum Erbgang von '%s'" % id)
		t.equal(DragonFlight.gene_state({id: dom + dom}, id),
			DragonFlight.GENE_CLEAR if recessive else DragonFlight.GENE_SHOWS,
			"Zwei grosse passen zum Erbgang von '%s'" % id)
		t.equal(DragonFlight.gene_state({id: dom + rec}, id),
			DragonFlight.GENE_CARRIER if recessive else DragonFlight.GENE_SHOWS,
			"Gemischtes Paar ist Träger oder sichtbar bei '%s'" % id)

	# Full genotype: one row per trait, in registry order — the screen relies on it.
	var genome := DragonFlight.random_genome()
	var rows := DragonFlight.genotype(genome)
	t.equal(rows.size(), DragonFlight.TRAITS.size(), "Jedes Merkmal hat eine Zeile")
	var shown := 0
	for i in rows.size():
		t.equal(str(rows[i]["id"]), str(DragonFlight.TRAITS[i]["id"]), "Reihenfolge stimmt an Position %d" % i)
		t.check(not str(rows[i]["name"]).is_empty(), "Zeile %d hat einen Namen" % i)
		t.equal(str(rows[i]["state"]), DragonFlight.gene_state(genome, str(rows[i]["id"])), "Zeile %d nennt den Zustand" % i)
		if str(rows[i]["state"]) == DragonFlight.GENE_SHOWS:
			shown += 1
	t.equal(shown, DragonFlight.expressed_traits(genome).size(), "Die angezeigten Merkmale stimmen mit der Expression überein")

	# Hidden carriers only, rarest first: this is the "worth the line" list.
	var carrier := _dragon(1, {"riesenwuchs": "Rr", "nachtfuchs": "Nn", "zaeherz": "Zz"})
	var carried := DragonFlight.carried_traits(carrier["alleles"])
	t.equal(carried, ["nachtfuchs", "riesenwuchs", "zaeherz"], "Alle drei rezessiven Träger, seltenstes zuerst")
	t.equal(DragonFlight.carried_traits({"riesenwuchs": "rr", "nachtfuchs": "NN"}).size(), 0,
		"Ein gezeigtes Merkmal ist kein verdeckter Träger")
	t.equal(DragonFlight.carried_traits({}).size(), 0, "Ohne Allele gibt es keine Träger")
	t.suite_done()


# --- flight control ----------------------------------------------------------

## Up has to mean up. The screen's +Y points down and the corridor's +Y points
## up, so the raw vector has to be flipped once — in one named place, or the
## next screen guesses again.
func _flight_input() -> void:
	t.suite("Drachenflug — Flugsteuerung")
	# A finger dragged up is screen (0, -1) and has to become a climb.
	t.check(DragonFlight.flight_direction(Vector2(0.0, -1.0)) == Vector2(0.0, 1.0),
		"Stick nach oben steigt")
	t.check(DragonFlight.flight_direction(Vector2(0.0, 1.0)) == Vector2(0.0, -1.0),
		"Stick nach unten stürzt ab")
	# Roll is already right and must stay untouched: the corridor is symmetric.
	t.check(DragonFlight.flight_direction(Vector2(1.0, 0.0)) == Vector2(1.0, 0.0),
		"Rechts bleibt rechts")
	t.check(DragonFlight.flight_direction(Vector2(-1.0, 0.0)) == Vector2(-1.0, 0.0),
		"Links bleibt links")
	t.check(DragonFlight.flight_direction(Vector2.ZERO) == Vector2.ZERO,
		"Ein ruhender Daumen steuert nicht")

	# A held direction sets the speed at once, and a diagonal really is
	# diagonal — the `elif` this replaces moved the dragon sideways only.
	var diagonal := DragonFlight.flight_velocity(Vector2(0.6, -0.8), Vector2.ZERO, 1.0 / 60.0)
	t.check(diagonal.x > 0.0 and diagonal.y > 0.0, "Diagonal fliegt nach schräg oben")
	t.check(is_equal_approx(diagonal.x, 0.6) and is_equal_approx(diagonal.y, 0.8),
		"Und behält die Stärke des Sticks")

	# Strafing must not keep a climb latched: the axis that is not held levels
	# off, which is what made the old vertical feel arbitrary.
	var pull := DragonFlight.flight_velocity(Vector2(0.0, 1.0), Vector2(0.8, 0.0), 1.0 / 60.0)
	t.check(pull.x < 0.8 and pull.x > 0.0, "Ohne Quersteuerung zieht die Seite ab")
	t.check(is_equal_approx(pull.y, -1.0), "Und ein Sturzflug kommt sofort")
	var after := Vector2.ZERO
	for i in 120:
		after = DragonFlight.flight_velocity(Vector2(1.0, 0.0), after, 1.0 / 60.0)
	t.check(is_equal_approx(after.y, 0.0), "Zwei Sekunden Rechtsflug enden im Horizontalflug")
	t.check(after.x > 0.9, "Und die Seitwärtsgeschwindigkeit bleibt")

	# Releasing the stick coasts out instead of stopping dead, and a thumb on the
	# knob below the deadzone is the same as no thumb.
	var coast := DragonFlight.flight_velocity(Vector2.ZERO, Vector2(0.0, 1.0), 1.0 / 60.0)
	t.check(coast.y > 0.0 and coast.y < 1.0, "Der Drache gleitet aus")
	var idle := Vector2(0.0, 1.0)
	for i in 120:
		idle = DragonFlight.flight_velocity(Vector2(0.5, 0.02), idle, 1.0 / 60.0)
	t.check(is_equal_approx(idle.y, 0.0), "Ein Knopf unter der Totzone ist kein Befehl")
	t.suite_done()


# --- breeding goal ----------------------------------------------------------

func _candidates() -> void:
	t.suite("Drachenflug — Zuchtziel")
	# The score counts the alleles the goal needs: lowercase for a recessive
	# goal, uppercase for a dominant one.
	t.equal(DragonFlight.goal_allele_count({"riesenwuchs": "rr"}, "riesenwuchs"), 2, "Zwei kleine Allele sind die volle Punktzahl")
	t.equal(DragonFlight.goal_allele_count({"riesenwuchs": "Rr"}, "riesenwuchs"), 1, "Ein Träger hat die halbe Punktzahl")
	t.equal(DragonFlight.goal_allele_count({"riesenwuchs": "RR"}, "riesenwuchs"), 0, "Ohne Träger gibt es nichts")
	t.equal(DragonFlight.goal_allele_count({"feueratem": "Fa"}, "feueratem"), 1, "Dominantes Ziel zählt grosse Allele")
	t.equal(DragonFlight.goal_allele_count({"feueratem": "aa"}, "feueratem"), 0, "Kein dominantes Allel, kein Ziel")
	t.equal(DragonFlight.goal_allele_count({}, "gibtsnicht"), 0, "Unbekanntes Ziel ist neutral")

	# Candidate list: carriers first, and only real dragons — never eggs.
	var profile := _profile_with([
		_dragon(1, {"riesenwuchs": "RR"}, 4),
		_dragon(2, {"riesenwuchs": "Rr"}, 2),
		_dragon(3, {"riesenwuchs": "rr"}, 1),
	])
	var egg := _dragon(4, {"riesenwuchs": "rr"}, 9)
	egg["egg"] = {"ready_at": 0, "total": 1}
	profile["dragons"].append(egg)
	var candidates := DragonFlight.target_candidates(profile, "riesenwuchs", 0)
	t.equal(candidates.size(), 2, "Das Ei zählt nicht als Kandidat, der saubere Drache auch nicht")
	var uids: Array[int] = []
	for entry in candidates:
		uids.append(int(entry["uid"]))
	t.equal(uids, [3, 2], "Zeigt das Merkmal zuerst, dann der Träger")
	t.equal(int(candidates[0]["score"]), 2, "Der beste Kandidat hat die volle Punktzahl")
	t.equal(DragonFlight.target_candidates(profile, "riesenwuchs", 1).size(), 1, "Das Limit greift")
	# If nobody carries the goal the list stays open, so the player sees the
	# whole stable instead of an empty list.
	var hopeless := _profile_with([_dragon(1, {"riesenwuchs": "RR"}), _dragon(2, {"riesenwuchs": "RR"})])
	t.equal(DragonFlight.target_candidates(hopeless, "riesenwuchs", 0).size(), 2,
		"Ohne Träger zeigt die Liste den ganzen Stall")

	# The carrier count answers "can I breed this at all".
	t.equal(DragonFlight.goal_carriers(profile, "riesenwuchs"), 2, "Zeiger und Träger zählen als Träger")
	t.equal(DragonFlight.goal_carriers(hopeless, "riesenwuchs"), 0,
		"Ein reiner Bestand bringt kein rezessives Ziel")
	t.equal(DragonFlight.goal_carriers(_profile_with([]), "riesenwuchs"), 0, "Ein leerer Stall bringt nichts")
	t.suite_done()


# --- best pair --------------------------------------------------------------

func _best_pair() -> void:
	t.suite("Drachenflug — Beste Paarung")
	# A recessive trait needs two parents that both pass a lowercase allele;
	# only both expressing (rr) is a certainty.
	var two_expressers := _profile_with([
		_dragon(1, {"riesenwuchs": "rr"}),
		_dragon(2, {"riesenwuchs": "rr"}),
	])
	var pair := DragonFlight.best_pair(two_expressers, "riesenwuchs")
	t.check(not pair.is_empty(), "Zwei passende Drachen ergeben eine Paarung")
	t.almost(float(pair["chance"]), 1.0, 0.0001, "Zwei Zeiger bringen das Merkmal sicher")
	t.check(int((pair["a"] as Dictionary)["uid"]) != int((pair["b"] as Dictionary)["uid"]), "Die Eltern sind verschieden")
	t.check(float(pair["chance"]) >= 0.0 and float(pair["chance"]) <= 1.0, "Die Chance liegt zwischen 0 und 1")
	t.almost(float(DragonFlight.best_pair(_profile_with([
		_dragon(1, {"riesenwuchs": "Rr"}), _dragon(2, {"riesenwuchs": "Rr"})]), "riesenwuchs")["chance"]),
		0.25, 0.0001, "Zwei Träger sind nur auf 25 %")

	# The best pair scans the whole stable, not just the first two dragons.
	var mixed := _profile_with([
		_dragon(1, {"riesenwuchs": "RR"}),
		_dragon(2, {"riesenwuchs": "RR"}),
		_dragon(3, {"riesenwuchs": "rr"}),
		_dragon(4, {"riesenwuchs": "rr"}),
	])
	var best := DragonFlight.best_pair(mixed, "riesenwuchs")
	var picked: Array[int] = [int((best["a"] as Dictionary)["uid"]), int((best["b"] as Dictionary)["uid"])]
	picked.sort()
	t.equal(picked, [3, 4], "Die beiden Zeiger sind das beste Paar")
	t.almost(float(best["chance"]), 1.0, 0.0001, "Und bringen es sicher")

	# A single carrier means 0 %, and the screen has to be able to say so.
	var lonely := _profile_with([_dragon(1, {"riesenwuchs": "Rr"}), _dragon(2, {"riesenwuchs": "RR"})])
	t.almost(float(DragonFlight.best_pair(lonely, "riesenwuchs")["chance"]), 0.0, 0.0001,
		"Ein einzelner Träger reicht nicht")
	# For a dominant goal one expresser is enough.
	var fire := _profile_with([
		_dragon(1, {"feueratem": "aa"}), _dragon(2, {"feueratem": "aa"}), _dragon(3, {"feueratem": "FF"})])
	var fire_best := DragonFlight.best_pair(fire, "feueratem")
	t.almost(float(fire_best["chance"]), 1.0, 0.0001, "Ein dominantes Ziel ist mit dem Zeiger sicher")
	t.check(int((fire_best["a"] as Dictionary)["uid"]) == 3 or int((fire_best["b"] as Dictionary)["uid"]) == 3,
		"Für ein dominantes Ziel greift die beste Paarung nach dem Zeiger")
	t.check(DragonFlight.best_pair(_profile_with([_dragon(1, {"riesenwuchs": "rr"})]), "riesenwuchs").is_empty(),
		"Mit einem Drachen gibt es keine Paarung")
	t.check(DragonFlight.best_pair(_profile_with([]), "riesenwuchs").is_empty(), "Ein leerer Stall hat keine beste Paarung")
	t.suite_done()


# --- egg readout ------------------------------------------------------------

func _egg_readout() -> void:
	t.suite("Drachenflug — Ei-Vorschau")
	# The genome is already rolled at lay time, so the screen can tell the truth:
	# what hatches, what is carried on, and whether it is rare enough to wait for.
	var egg := _dragon(9, {"riesenwuchs": "rr", "nachtfuchs": "Nn", "feueratem": "aa"}, 2)
	var readout := DragonFlight.egg_readout(egg)
	t.equal(readout["traits"], ["riesenwuchs"], "Das Ei zeigt genau, was es zeigt")
	t.equal(readout["carriers"], ["nachtfuchs"], "Und was es nur weiterträgt")
	t.equal(str(readout["rarest"]), "nachtfuchs", "Das seltenste Gen kommt zuerst")
	t.check(bool(readout["rare"]), "Nachtfuchs ist selten genug zum Warten")

	var plain := DragonFlight.egg_readout(DragonFlight.random_dragon(10, ["ember"]))
	t.check(plain["traits"] is Array, "Die Vorschau nennt immer die Merkmale")
	t.check(plain["carriers"] is Array, "und immer die Träger")
	t.equal(DragonFlight.egg_readout(_dragon(11, {"feueratem": "FF"}))["rare"], false,
		"Ein häufiges Gen ist kein Grund zu warten")
	t.equal(DragonFlight.egg_readout(_dragon(12, {}))["rarest"], "", "Ein leeres Genom hat nichts Seltenes")
	t.equal(DragonFlight.egg_readout(_dragon(13, {}))["traits"].size(), 0, "und keine Merkmale")
	t.suite_done()


# --- purse & breeding affordability ------------------------------------------

## Why this suite exists: a player reported that breeding was impossible to
## try. Two things were true at once — the hatchery showed what every action
## *cost* but never what the player *had*, and a fresh profile started on an
## empty purse while the cheapest pairing costs 300 ◈. So the balance is now
## one reader, the affordability one answer, and the start budget is pinned to
## a pairing the player can actually pay.
func _purse() -> void:
	t.suite("Drachenflug — Gold & Paarbarkeit")

	# One reader, so the purse line, the buttons and these tests cannot drift.
	var profile := _profile_with([])
	t.equal(DragonFlight.gold_of(profile), DragonFlight.STARTING_GOLD, "Ein neues Profil trägt das Startbudget")
	profile["gold"] = 480
	t.equal(DragonFlight.gold_of(profile), 480, "Der Purse folgt dem Spielstand")
	profile["gold"] = -50
	t.equal(DragonFlight.gold_of(profile), 0, "Und kann nie negativ werden")
	t.check(DragonFlight.can_afford(profile, 0), "Null kostet immer")
	t.check(not DragonFlight.can_afford(profile, 1), "Aber ein Gold zu wenig reicht nicht")
	profile["gold"] = 50
	t.check(DragonFlight.can_afford(profile, 50), "Genau der Preis reicht")

	# "Kann ich züchten?" — one question with three ways to answer no.
	var a := _dragon(1, {"riesenwuchs": "Rr"})
	var b := _dragon(2, {"riesenwuchs": "Rr"})
	profile["gold"] = 99999
	t.check(DragonFlight.can_pair(profile, a, b), "Zwei verschiedene Drachen mit Gold ergeben eine Paarung")
	t.check(not DragonFlight.can_pair(profile, a, a), "Ein Drache paart nicht mit sich selbst")
	t.check(not DragonFlight.can_pair(profile, a, {}), "Ein leerer Platz ist keine Paarung")
	var cost := DragonFlight.pairing_cost(a, b)
	profile["gold"] = cost
	t.check(DragonFlight.can_pair(profile, a, b), "Genau der Paarungspreis reicht")
	profile["gold"] = cost - 1
	t.check(not DragonFlight.can_pair(profile, a, b), "Ein Gold zu wenig sperrt die Paarung")

	# The price has a real ceiling, and the budget has to clear it: two dragons
	# with the very same genome share all twelve genes, which is the worst a
	# starter pair can ever be.
	var genome := DragonFlight.random_genome()
	var twin_a := _dragon(3, genome.duplicate())
	var twin_b := _dragon(4, genome.duplicate())
	t.equal(DragonFlight.pairing_cost(twin_a, twin_b), 600, "Zwei Zwillinge sind der teuerste Fall der Startlinie")
	t.check(DragonFlight.STARTING_GOLD >= DragonFlight.pairing_cost(twin_a, twin_b),
		"Und das Startbudget deckt ihn")

	# And that holds for every random starter pair, not just for a lucky draw.
	var always := true
	for i in 64:
		var fresh := DragonFlight.starter_profile()
		var owned := DragonFlight.dragons_of(fresh)
		if owned.size() < 2 or not DragonFlight.can_pair(fresh, owned[0], owned[1]):
			always = false
	t.check(always, "Jedes Startpaar ist von Anfang an zuchtbar")
	t.suite_done()
