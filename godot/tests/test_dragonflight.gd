class_name TestDragonFlight
extends RefCounted
## Regression tests for "Drachenflug" — the bloodline readout.
##
## The game breeds recessive traits, and a recessive trait needs two carriers.
## Before this readout the roster could not show a carrier at all, so chasing a
## rare gene was a blind gamble. Everything here is pure logic, so it runs in
## the plain logic phase of the headless suite.

var t: TestKit


func run(kit: TestKit) -> void:
	t = kit
	_alleles()
	_states()
	_candidates()
	_best_pair()
	_egg_readout()
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
