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
	_suite(_draft)
	_suite(_spelling)


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


# --- level offers ------------------------------------------------------------

## The level-up is the only choice the arena ever asks for, and it used to be a
## blind weighted draw: two of three cards could raise the same number and none
## of them said what that was worth. These tests pin the three things the
## improvement promises — three different directions, the numbers on the card,
## and one card that is honestly named as the strongest.
func _draft() -> void:
	t.suite("Arena — Level-Angebote")

	var weapon := {"damage": 10.0, "cooldown": 500.0, "projectileSpeed": 420.0,
		"projectileCount": 1.0, "spread": 0.0, "pierce": 0.0}

	# --- three cards, three directions ---
	var pool: Array = [
		{"id": "damage_a", "name": "Munition A", "stat": "damage_mult", "amount": 0.15, "rarity": "common", "maxStacks": 10},
		{"id": "damage_b", "name": "Munition B", "stat": "damage_mult", "amount": 0.2, "rarity": "common", "maxStacks": 4},
		{"id": "speed", "name": "Stiefel", "stat": "move_speed_mult", "amount": 0.12, "rarity": "common", "maxStacks": 6},
		{"id": "armor", "name": "Panzer", "stat": "armor", "amount": 1.0, "rarity": "uncommon", "maxStacks": 5},
	]
	var one := ArenaRuns.one_per_stat(pool, {})
	t.equal(one.size(), 3, "Je Kennzahl bleibt genau eine Karte")
	var stats_seen: Array[String] = []
	for entry in one:
		stats_seen.append(str((entry as Dictionary)["stat"]))
	t.equal(stats_seen.size(), 3, "Drei verschiedene Kennzahlen im Angebot")
	t.check(stats_seen.has("damage_mult") and stats_seen.has("move_speed_mult") and stats_seen.has("armor"),
		"Keine Kennzahl doppelt, dafür eine dritte Richtung dabei")
	t.equal(str(one[0]["id"]), "damage_a", "Ohne Stacks gewinnt die zuerst gelistete Karte")
	t.equal(str(one[1]["id"]), "speed", "Die Reihenfolge des Angebots bleibt erhalten")
	# With stacks, the card the player has taken least often is the one shown.
	var shifted := ArenaRuns.one_per_stat(pool, {"damage_a": 6, "damage_b": 1})
	t.equal(str(shifted[0]["id"]), "damage_b", "Die seltener genommene Karte gewinnt")
	t.equal(shifted.size(), 3, "Auch nach dem Wechsel bleibt es bei drei Kennzahlen")
	t.equal(ArenaRuns.one_per_stat([], {}).size(), 0, "Ein leeres Angebot bleibt leer")

	# --- the weighted draw ---
	var candidates: Array = [
		{"id": "a", "stat": "armor", "amount": 1.0, "rarity": "common"},
		{"id": "b", "stat": "crit_chance", "amount": 0.06, "rarity": "uncommon"},
		{"id": "c", "stat": "pierce", "amount": 1.0, "rarity": "rare"},
	]
	# Weights are common 10, uncommon 6, rare 3 → 0.0–0.526 picks a,
	# 0.526–0.842 b, 0.842–1.0 c.
	t.equal(str(ArenaRuns.weighted_draft(candidates, 3, PackedFloat32Array([0.1, 0.6, 0.9]))[0]["id"]), "a",
		"Ein niedriger Wurf zieht die gewöhnliche Karte")
	t.equal(str(ArenaRuns.weighted_draft(candidates, 3, PackedFloat32Array([0.6, 0.6, 0.6]))[0]["id"]), "b",
		"Ein mittlerer Wurf zieht die seltene")
	t.equal(str(ArenaRuns.weighted_draft(candidates, 3, PackedFloat32Array([0.95]))[0]["id"]), "c",
		"Ein hoher Wurf zieht die seltenste")
	var drawn := ArenaRuns.weighted_draft(candidates, 3, PackedFloat32Array([0.1, 0.1, 0.1]))
	t.equal(drawn.size(), 3, "Drei Karten werden gezogen")
	var ids: Array[String] = []
	for entry in drawn:
		ids.append(str((entry as Dictionary)["id"]))
	t.equal(ids.size(), 3, "Keine Karte taucht zweimal auf")
	for i in drawn.size():
		for j in range(i + 1, drawn.size()):
			t.check(str(drawn[i]["id"]) != str(drawn[j]["id"]), "Jede Karte kommt nur einmal vor")
	t.equal(ArenaRuns.weighted_draft(candidates, 2, PackedFloat32Array([0.1, 0.1])).size(), 2,
		"Die Anzahl der Karten ist vorgebbar")
	t.equal(ArenaRuns.weighted_draft(candidates, 5, PackedFloat32Array([0.1, 0.1, 0.1])).size(), 3,
		"Mehr Karten als im Angebot gibt es nicht")
	t.equal(ArenaRuns.weighted_draft([], 3, PackedFloat32Array([0.5])).size(), 0, "Ohne Angebot wird nichts gezogen")
	var unweighted: Array = [{"id": "x", "stat": "armor", "amount": 1.0, "rarity": "mystery"}]
	t.equal(ArenaRuns.weighted_draft(unweighted, 3, PackedFloat32Array([0.1])).size(), 0,
		"Eine Karte ohne Seltenheit wiegt nichts und wird nicht gezogen")
	t.equal(ArenaRuns.RARITY_WEIGHT.get("common", 0.0), 10.0, "Gewöhnlich wiegt am schwersten")
	t.check(ArenaRuns.RARITY_WEIGHT.get("common", 0.0) > ArenaRuns.RARITY_WEIGHT.get("epic", 0.0),
		"Eine gewöhnliche Karte ist häufiger als eine epische")

	# --- the fallback cards are three choices, not three copies ---
	var full := PlayerStats.create(weapon)
	var reps: Array[Dictionary] = []
	for slot in ArenaRuns.DRAFT_SIZE:
		reps.append(ArenaRuns.repair_offer(full, slot))
	t.equal(reps.size(), ArenaRuns.DRAFT_SIZE, "Es gibt für jeden Platz eine Reparierkarte")
	var amounts: Array[int] = []
	var names: Array[String] = []
	for entry in reps:
		amounts.append(int(entry["amount"]))
		names.append(str(entry["name"]))
	for i in amounts.size():
		for j in range(i + 1, amounts.size()):
			t.check(amounts[i] != amounts[j], "Die Reparierkarten sind unterschiedlich groß")
			t.check(names[i] != names[j], "Die Reparierkarten haben eigene Namen")
	for i in range(1, amounts.size()):
		t.check(amounts[i] > amounts[i - 1], "Die größte Reparierkarte heilt am meisten")
	t.equal(str(reps[0]["stat"]), "hp", "Eine Reparierkarte heilt")
	var hurt := PlayerStats.create(weapon)
	hurt.hp = 20.0
	t.check(int(ArenaRuns.repair_offer(hurt, 2)["amount"]) > int(ArenaRuns.repair_offer(full, 2)["amount"]),
		"Wer fast tot ist, bekommt die große Reparierkarte angeboten")
	var applied := PlayerStats.create(weapon)
	applied.hp = 10.0
	applied.apply_upgrade(ArenaRuns.repair_offer(applied, 2))
	t.check(applied.hp > 10.0, "Die Reparierkarte heilt wirklich")
	applied.hp = applied.max_hp
	applied.apply_upgrade(ArenaRuns.repair_offer(applied, 0))
	t.almost(applied.hp, applied.max_hp, 0.001, "Volle Leben werden nicht überheilt")

	# --- what the card says ---
	t.equal(ArenaRuns.effect_text({"stat": "max_hp", "amount": 20.0}, full), "Leben  120 → 140",
		"Die Karte nennt die beiden Lebenswerte")
	t.equal(ArenaRuns.effect_text({"stat": "damage_mult", "amount": 0.15}, full), "Schaden  10.0 → 11.5",
		"Schaden wird ausgewiesen, nicht als Prozentsatz")
	t.equal(ArenaRuns.effect_text({"stat": "armor", "amount": 1.0}, full), "Schaden pro Treffer  10.0 → 9.0",
		"Rüstung wird als weniger Schaden pro Treffer erklärt")
	t.equal(ArenaRuns.effect_text({"stat": "xp_mult", "amount": 0.15}, full), "Erfahrung  100 % → 115 %",
		"Erfahrung wird in Prozent gezeigt")
	t.equal(ArenaRuns.effect_text({"stat": "fire_rate", "amount": 0.12}, full, weapon), "Abzug  500 → 446 ms",
		"Feuerrate wird als kürzerer Abzug gezeigt")
	t.equal(ArenaRuns.effect_text({"stat": "fire_rate", "amount": 0.12}, full), "Feuerrate  ×1.00 → ×1.12",
		"Ohne Waffe bleibt die Feuerrate als Faktor stehen")
	t.equal(ArenaRuns.effect_text({"stat": "hp", "amount": 30.0}, full), "+0 Leben",
		"Bei vollen Leben heilt die Karte gar nichts")
	t.equal(ArenaRuns.effect_text({"stat": "unbekannt", "amount": 1.0}, full), "",
		"Eine unbekannte Kennzahl bekommt keine Zeile, die nichts sagt")
	var wounded := PlayerStats.create(weapon)
	wounded.hp = 90.0
	t.equal(ArenaRuns.effect_text({"stat": "hp", "amount": 30.0}, wounded), "+30 Leben",
		"Verwundete sehen, was die Karte wirklich repariert")

	# --- what the card is worth ---
	var attack := ArenaRuns.effect_value({"stat": "damage_mult", "amount": 0.1}, full)
	var guard := ArenaRuns.effect_value({"stat": "max_hp", "amount": 12.0}, full)
	t.check(attack > guard, "Gleicher relativer Gewinn zählt im Angriff mehr als in der Zähigkeit")
	t.check(ArenaRuns.effect_value({"stat": "move_speed_mult", "amount": 0.1}, full) < guard,
		"Tempo wiegt am wenigsten")
	t.check(ArenaRuns.effect_value({"stat": "unbekannt", "amount": 5.0}, full) == 0.0,
		"Eine unbekannte Kennzahl ist nichts wert")
	t.check(ArenaRuns.effect_value({"stat": "damage_mult", "amount": 0.15}, full) > 0.0,
		"Eine Schadenskarte ist etwas wert")
	# The same card is worth less the later it comes: mults stack on a base.
	t.check(ArenaRuns.effect_value({"stat": "damage_mult", "amount": 0.15}, full) >
		ArenaRuns.effect_value({"stat": "damage_mult", "amount": 0.15}, _stacked(full, 4.0)),
		"Der vierte Schadensbonus zählt weniger als der erste")
	# A heal is worth what it repairs and nothing at full health.
	t.almost(ArenaRuns.effect_value({"stat": "hp", "amount": 30.0}, wounded), 30.0 / 120.0 * 0.7, 0.0001,
		"Eine Heilung zählt wie derselbe Anteil am Lebenspool")
	t.almost(ArenaRuns.effect_value({"stat": "hp", "amount": 30.0}, full), 0.0, 0.0001,
		"Bei vollen Leben ist eine Heilung wertlos")
	var almost_dead := PlayerStats.create(weapon)
	almost_dead.hp = 12.0
	t.check(ArenaRuns.effect_value({"stat": "hp", "amount": 100.0}, almost_dead) >
		ArenaRuns.effect_value({"stat": "hp", "amount": 100.0}, wounded),
		"Eine große Reparierkarte ist bei halber Leiste nur halb so viel wert")
	t.almost(ArenaRuns.effect_value({"stat": "hp", "amount": 100.0}, wounded), 30.0 / 120.0 * 0.7, 0.0001,
		"Repariert wird nur, was noch fehlt")
	# Regen is a trickle, judged over a minute against the health pool.
	t.almost(ArenaRuns.effect_value({"stat": "hp_regen", "amount": 0.4}, full),
		ArenaRuns.effect_value({"stat": "max_hp", "amount": 24.0}, full), 0.0001,
		"Eine Minute Regeneration zählt wie 24 zusätzliche Leben")
	t.almost(ArenaRuns.effect_value({"stat": "hp_regen", "amount": 0.8}, full),
		2.0 * ArenaRuns.effect_value({"stat": "hp_regen", "amount": 0.4}, full), 0.0001,
		"Doppelte Regeneration zählt doppelt")
	# The reference numbers the cards are judged against: what a body hit costs
	# and what each axis is called.
	t.almost(ArenaRuns.hit_damage(0.0), ArenaRuns.TOUCH_DAMAGE, 0.001, "Ohne Rüstung trifft es voll")
	t.check(ArenaRuns.hit_damage(4.0) < ArenaRuns.hit_damage(0.0), "Rüstung senkt den Schaden pro Treffer")
	t.check(ArenaRuns.hit_damage(99.0) >= 1.0, "Ein Treffer kostet mindestens 1 Leben")
	t.check(ArenaRuns.axis_of({"stat": "armor"}) == "zaehigkeit", "Rüstung ist Zähigkeit")
	t.equal(ArenaRuns.axis_label({"stat": "armor"}), "Zähigkeit", "Die Achse hat einen deutschen Namen")
	t.equal(ArenaRuns.axis_label({"stat": "damage_mult"}), "Angriff", "Schaden ist Angriff")
	t.equal(ArenaRuns.axis_label({"stat": "xp_mult"}), "Ertrag", "Erfahrung ist Ertrag")

	# --- the bar on the card ---
	t.almost(ArenaRuns.effect_ratio(0.0), 0.0, 0.0001, "Ohne Wirkung bleibt der Balken leer")
	t.almost(ArenaRuns.effect_ratio(ArenaRuns.EFFECT_FULL), 1.0, 0.0001, "Volle Wirkung füllt den Balken")
	t.almost(ArenaRuns.effect_ratio(ArenaRuns.EFFECT_FULL * 4.0), 1.0, 0.0001, "Der Balken läuft nicht über")
	t.almost(ArenaRuns.effect_ratio(-1.0), 0.0, 0.0001, "Ein negativer Wert zeigt nichts an")

	# --- which card the game would take ---
	var offers: Array = [
		{"id": "d", "name": "Munition", "stat": "damage_mult", "amount": 0.15, "rarity": "common"},
		{"id": "p", "name": "Stiefel", "stat": "move_speed_mult", "amount": 0.12, "rarity": "common"},
		{"id": "h", "name": "Reparatur", "stat": "hp", "amount": 60.0, "rarity": "common"},
	]
	t.equal(ArenaRuns.best_offer_index(offers, wounded), 2, "Wer Blut verloren hat, soll heilen")
	t.equal(ArenaRuns.best_offer_index(offers, full), 0, "Bei vollen Lebens ist die Schadenskarte vorn")
	t.equal(ArenaRuns.best_offer_index([], full), -1, "Ein leeres Angebot hat keine Empfehlung")
	var tie: Array = [
		{"id": "a", "name": "A", "stat": "damage_mult", "amount": 0.15},
		{"id": "b", "name": "B", "stat": "damage_mult", "amount": 0.15},
	]
	t.equal(ArenaRuns.best_offer_index(tie, full), 0, "Bei Gleichstand gewinnt die erste Karte")
	t.check(ArenaRuns.draft_headline(offers, full).contains("Munition"),
		"Die Kopfzeile nennt die stärkste Karte")
	t.check(ArenaRuns.draft_headline(offers, full).contains("Angriff"),
		"Die Kopfzeile nennt, worum es geht")
	t.equal(ArenaRuns.draft_headline([], full), "", "Ohne Angebot gibt es keine Kopfzeile")

	# The marked card always exists and is always pickable.
	for entry in offers:
		t.check(ArenaRuns.effect_value(entry, full) >= 0.0, "Keine Karte ist schädlich")

	# Content drift is the real enemy here: a new upgrade without a stat the
	# draft knows would quietly print an empty card — and an upgrade whose
	# stat name the stat block does not know would be a card that does nothing
	# at all. Both are checked against the pack the game actually ships.
	var upgrades := _content_upgrades()
	t.check(upgrades.size() > 0, "Das Upgrade-Paket ist lesbar")
	for upgrade in upgrades:
		var id := str(upgrade.get("id", "?"))
		t.check(ArenaRuns.STAT_AXIS.has(ArenaRuns.stat_key(upgrade)),
			"Jede Kennzahl aus dem Content hat eine Achse: %s" % id)
		t.check(ArenaRuns.axis_label(upgrade) != "", "%s hat eine Achsenbeschriftung" % id)
		t.check(ArenaRuns.effect_text(upgrade, full) != "", "%s zeigt seine Zahlen auf der Karte" % id)
		t.check(ArenaRuns.effect_value(upgrade, full) >= 0.0, "%s ist nie schädlich" % id)
		# The card promises a change — so take the card and see the change.
		if ArenaRuns.stat_key(upgrade) == "hp":
			continue
		var taken := PlayerStats.create(weapon)
		var before := _numbers(taken)
		taken.apply_upgrade(ArenaRuns.applied_form(upgrade))
		var after := _numbers(taken)
		var changed := false
		for i in before.size():
			if not is_equal_approx(float(before[i]), float(after[i])):
				changed = true
		t.check(changed, "%s verändert nach dem Nehmen wirklich etwas" % id)
	t.suite_done()


## The stat block writes `max_hp`, the upgrade pack writes `maxHp`. Both mean
## the same number, and `PlayerStats.apply_upgrade` drops every name it does
## not recognise — which was most of the pack.
func _spelling() -> void:
	t.suite("Arena — Kennzahl-Schreibweisen")

	t.equal(ArenaRuns.stat_key({"stat": "maxHp"}), "max_hp", "maxHp heißt max_hp")
	t.equal(ArenaRuns.stat_key({"stat": "xpMult"}), "xp_mult", "xpMult heißt xp_mult")
	t.equal(ArenaRuns.stat_key({"stat": "fireRate"}), "fire_rate", "fireRate heißt fire_rate")
	t.equal(ArenaRuns.stat_key({"stat": "critChance"}), "crit_chance", "critChance heißt crit_chance")
	t.equal(ArenaRuns.stat_key({"stat": "max_hp"}), "max_hp", "Die Schreibweise des Statblocks bleibt")
	t.equal(ArenaRuns.stat_key({"stat": "armor"}), "armor", "Ein einzelnes Wort bleibt")
	t.equal(ArenaRuns.stat_key({}), "", "Ohne Kennzahl gibt es auch keinen Namen")
	t.equal(ArenaRuns.axis_of({"stat": "maxHp"}), ArenaRuns.axis_of({"stat": "max_hp"}),
		"Beide Schreibweisen landen auf derselben Achse")
	t.check(ArenaRuns.effect_text({"stat": "maxHp", "amount": 20.0}, PlayerStats.create({"damage": 10.0})) != "",
		"Eine Karte aus dem Content zeigt trotzdem ihre Zahlen")

	var packed := {"id": "max_hp", "stat": "maxHp", "amount": 20.0}
	var applied := ArenaRuns.applied_form(packed)
	t.equal(str(applied["stat"]), "max_hp", "Die Form zum Anwenden trägt den bekannten Namen")
	t.equal(str(packed["stat"]), "maxHp", "Das Original bleibt unverändert")
	t.suite_done()


## Every number the stat block carries, for "did taking the card change
## anything at all".
func _numbers(stats: PlayerStats) -> Array:
	var out: Array = []
	for field in PlayerStats.NUMERIC_FIELDS:
		out.append(float(stats.get(field)))
	return out


## A copy of `full` with one multiplier raised, for the stacking comparison.
func _stacked(base: PlayerStats, damage_mult: float) -> PlayerStats:
	var copy := PlayerStats.create({"damage": 10.0, "cooldown": 500.0})
	copy.damage = base.damage
	copy.projectile_speed = base.projectile_speed
	copy.projectile_count = base.projectile_count
	copy.damage_mult = damage_mult
	return copy


## The shipped upgrade pack, read from disk: the draft has to work on what the
## game actually offers, not on what this test imagines.
func _content_upgrades() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var path := "res://assets/content/upgrades.json"
	if not FileAccess.file_exists(path):
		return out
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Array):
		return out
	for entry in (parsed as Array):
		if entry is Dictionary:
			out.append(entry)
	return out
