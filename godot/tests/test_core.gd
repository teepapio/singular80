class_name TestCore
extends RefCounted
## Tests for the offline suggestion queue: the client's half of an idea that
## was written in a tunnel. Everything decidable without a server lives in
## `SuggestionQueue` and is tested directly: the `clientKey`, the JSON in
## `user://`, the cap and the backoff. The transport is exercised twice for real
## — against a closed port for the failure case, and against a tiny HTTP
## responder built from `TCPServer` for the retry, which is where "the same key
## arrives a second time" is proven instead of assumed.

## By path, not by class name: `--script` mode does not refresh the global
## class cache, so a class added today would not resolve before the next
## import. Every preload below follows that rule.
const QueueClass := preload("res://src/core/logic/suggestion_queue.gd")

## The legal module carries `class_name AppLegal`, which `suggest_dialog.gd`
## uses by name, so it is already part of every screen's load path.
const LegalClass := preload("res://src/core/logic/app_legal.gd")

const ServerDialogClass := preload("res://src/core/ui/server_dialog.gd")

## The suggestion flow composes the label and the player's text before the
## entry is born.
const SuggestionContextClass := preload("res://src/core/logic/suggestion_context.gd")

## A private file, so the suite never touches the queue a real run uses.
const TEST_PATH := "user://test_suggestions.json"

var t: TestKit
var tree: SceneTree


func run(kit: TestKit, scene_tree: SceneTree) -> void:
	t = kit
	tree = scene_tree
	_flow()
	_queueing()
	_close()
	_persistence()
	_close()
	_backoff()
	_close()
	_cap()
	_close()
	await _delivery()
	_legal()
	_server_address()


func _close() -> void:
	t.close_suite()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))


# --- End-to-end -------------------------------------------------------------

## The whole path a player idea takes, in one pass: the screen label is put in
## front of the text, the entry is born with its `clientKey`, it reaches the
## disk before any send is attempted, and the server confirms it — after which
## the queue is empty and the success signal carries the server's id.
func _flow() -> void:
	t.suite("Auftragsweg")

	# 1. The screen label goes in front of the player's text, so the dashboard
	#    can group ideas without the author having to say where it came from.
	var context := SuggestionContextClass.for_screen("tetris")
	t.equal(context, "Tetris", "Die Screen-ID wird zum Spielnamen")
	var composed := SuggestionContextClass.compose(context, "Füge einen Boss hinzu")
	t.equal(composed, "Tetris: Füge einen Boss hinzu", "Der Text wird mit dem Präfix versehen")
	t.check(SuggestionContextClass.compose(context, composed) == composed,
		"Die Komposition ist idempotent")

	# 2. The entry is born with its key and lands on the disk before any send.
	var items: Array[Dictionary] = []
	var item: Dictionary = QueueClass.make_item(composed, "Spieler", "game")
	QueueClass.push(items, item)
	QueueClass.persist(TEST_PATH, items)
	t.check(FileAccess.file_exists(TEST_PATH), "Die Warteschlange steht als Datei in user://")

	# 3. Reading it the way a new process would: only the file, nothing from memory.
	var reloaded: Array[Dictionary] = QueueClass.restore(TEST_PATH)
	t.equal(reloaded.size(), 1, "Ein neuer Prozess findet die Idee wieder")
	t.equal(str(reloaded[0].get("clientKey", "")), str(item.get("clientKey", "")),
		"Der clientKey überlebt den Neustart")
	t.equal(str(reloaded[0].get("text", "")), composed, "…und der Text auch")

	# 4. The POST body the server would receive: text, author, source, clientKey.
	var body: Dictionary = QueueClass.request_body(reloaded[0])
	t.equal(body.size(), 4, "Der Body besteht genau aus text, author, source und clientKey")
	t.equal(str(body.get("text", "")), composed, "Der Text trägt das Präfix")
	t.equal(str(body.get("author", "")), "Spieler", "Der Autor wird übergeben")
	t.equal(str(body.get("source", "")), "game", "Die Quelle ist 'game'")
	t.check(str(body.get("clientKey", "")).begins_with("s80_"),
		"Der clientKey folgt dem Schema")

	# 5. After the server confirms, the entry leaves the queue and the file.
	t.check(QueueClass.remove(reloaded, str(item.get("clientKey", ""))),
		"Ein zugestellter Vorschlag verschwindet auch von der Platte")
	QueueClass.persist(TEST_PATH, reloaded)
	var third: Array[Dictionary] = QueueClass.restore(TEST_PATH)
	t.equal(third.size(), 0, "Nach der Zustellung ist die Warteschlange leer")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))
	t.suite_done()


# --- Insert -----------------------------------------------------------------

func _queueing() -> void:
	t.suite("Vorschlags-Warteschlange")
	var items := _file()

	var item: Dictionary = _add(items, "Füge einen Gegner hinzu, der sich teilt.", "Spieler")["item"]
	t.check(item.has("clientKey"), "Ein eingepflegter Vorschlag bekommt einen clientKey")
	t.equal(items.size(), 1, "Der Vorschlag liegt in der Warteschlange")
	t.check(str(item.get("clientKey", "")).length() <= 64, "Der clientKey passt in das 64-Zeichen-Limit")

	# The contract with the server: `clientKey`, camelCase, top level, opaque.
	var body: Dictionary = QueueClass.request_body(item)
	t.check(body.has("clientKey"), "Der POST-Body trägt den clientKey")
	t.equal(str(body.get("clientKey", "")), str(item.get("clientKey", "")), "…unverändert aus dem Eintrag")
	t.equal(body.size(), 4, "Der Body besteht genau aus text, author, source und clientKey")

	# Two identical ideas from one player are two suggestions. Dedup is the
	# server's job and it keys on the clientKey, not on the text.
	_add(items, "Füge einen Gegner hinzu, der sich teilt.", "Spieler")
	t.equal(items.size(), 2, "Zwei wirklich gleiche Ideen bleiben zwei Vorschläge")
	t.equal(QueueClass.distinct_keys(items), 2, "…und bekommen zwei verschiedene clientKeys")

	# A failed attempt must not change the key — that is what makes the retry
	# idempotent on the server.
	var own := str(items[0].get("clientKey", ""))
	var other := str(items[1].get("clientKey", ""))
	t.check(not QueueClass.remove(items, other + "x"), "Ein fremder clientKey entfernt nichts")
	t.equal(str(items[0].get("clientKey", "")), own, "Der Eintrag und sein clientKey bleiben unangetastet")
	t.check(QueueClass.remove(items, own), "Der eigene clientKey entfernt den Eintrag")
	t.equal(items.size(), 1, "…und danach ist die Liste kürzer")

	# Garbage in, usable queue out: a broken file must not take the app down.
	t.check(QueueClass.decode("{kein json").is_empty(), "Kaputtes JSON ergibt eine leere Liste")
	var repaired := QueueClass.decode(JSON.stringify({
		"version": 1,
		"items": [{"text": "ohne Schlüssel"}, {"text": ""}, "kein Objekt"],
	}))
	t.equal(repaired.size(), 1, "Einträge ohne Text fliegen raus, der Rest bleibt")
	t.check(str(repaired[0].get("clientKey", "")) != "", "Ein fehlender clientKey wird ergänzt")
	t.suite_done()


# --- Storage ----------------------------------------------------------------

func _persistence() -> void:
	t.suite("Vorschlags-Warteschlange — Ablage")
	var items := _file()
	var first: Dictionary = _add(items, "Pang: zwei Bälle gleichzeitig", "Spieler")["item"]
	var key := str(first.get("clientKey", ""))
	_add(items, "Drache mit Feueratem", "Anderer")
	t.check(FileAccess.file_exists(TEST_PATH), "Die Warteschlange steht als Datei in user://")

	# Reading it the way a new process would: only the file, nothing from memory.
	var reloaded := QueueClass.restore(TEST_PATH)
	t.equal(reloaded.size(), 2, "Ein neuer Prozess findet beide Ideen wieder")
	t.equal(str(reloaded[0].get("clientKey", "")), key, "Der clientKey überlebt den Neustart")
	t.equal(str(reloaded[1].get("text", "")), "Drache mit Feueratem", "…und der Text auch")

	# A retry after the restart has to send the very same key again.
	var retry: Dictionary = QueueClass.request_body(reloaded[0])
	t.equal(str(retry.get("clientKey", "")), key, "Der Wiederholungsversuch nutzt denselben clientKey")

	# Removing is a file operation too — otherwise a crash would resurrect it.
	t.check(QueueClass.remove(reloaded, key), "Ein zugestellter Vorschlag verschwindet auch von der Platte")
	QueueClass.persist(TEST_PATH, reloaded)
	var third := QueueClass.restore(TEST_PATH)
	t.equal(third.size(), 1, "Nach dem Neuladen ist nur der zweite Vorschlag da")
	t.check(str(third[0].get("clientKey", "")) != key, "…und es ist ein anderer")

	# The on-disk shape is what the next version of the app has to read.
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(TEST_PATH))
	t.check(parsed is Dictionary, "Die Datei ist ein JSON-Objekt")
	t.equal(int((parsed as Dictionary).get("version", 0)), 1, "…mit der Formatversion")
	t.equal(((parsed as Dictionary).get("items", []) as Array).size(), 1, "…und der Liste der Einträge")
	t.check(not FileAccess.file_exists(TEST_PATH + ".tmp"), "Die Temp-Datei der Atomik ist wieder weg")
	t.suite_done()


# --- Backoff ----------------------------------------------------------------

func _backoff() -> void:
	t.suite("Vorschlags-Warteschlange — Backoff")
	t.equal(QueueClass.backoff_seconds(0), 0.0, "Die erste Stufe wartet nicht")
	t.equal(QueueClass.backoff_seconds(1), 15.0, "Nach dem ersten Fehlschlag wartet 15 s")
	t.check(QueueClass.backoff_seconds(2) > QueueClass.backoff_seconds(1), "Die Wartezeit wächst")
	t.check(QueueClass.backoff_seconds(3) > QueueClass.backoff_seconds(2), "…weiter")
	t.equal(QueueClass.backoff_seconds(50), 300.0, "Der Backoff ist gedeckelt")
	t.equal(QueueClass.backoff_seconds(1000), 300.0, "…auch nach sehr vielen Fehlschlägen")

	# What the player gets to see.
	t.equal(QueueClass.pending_hint(0), "", "Ohne Warteschlange gibt es nichts anzuzeigen")
	t.equal(QueueClass.pending_hint(1), "1 Vorschlag wartet auf Netz", "Ein Wartender wird einzeln genannt")
	t.equal(QueueClass.pending_hint(3), "3 Vorschläge warten auf Netz", "Mehrere werden gezählt")
	t.suite_done()


# --- Cap ---------------------------------------------------------------------

func _cap() -> void:
	t.suite("Vorschlags-Warteschlange — Obergrenze")
	var items := _file()
	_add(items, "erste", "S", 3)
	_add(items, "zweite", "S", 3)
	_add(items, "dritte", "S", 3)
	t.equal(items.size(), 3, "Unterhalb der Grenze wird nichts verworfen")

	var dropped: Dictionary = _add(items, "vierte", "S", 3)["dropped"]
	t.equal(items.size(), 3, "Die Liste wächst nicht über die Grenze hinaus")
	t.equal(str(items[0].get("text", "")), "zweite", "Der älteste Eintrag weicht")
	t.equal(str(dropped.get("text", "")), "erste", "Der Verworfene wird zurückgegeben")
	var warning := QueueClass.cap_warning(dropped, 3)
	t.check(warning.contains("3"), "Die Warnung nennt die Grenze")
	t.check(warning.contains("erste"), "…und den verlorenen Vorschlag")

	# A lower cap has to bite immediately, not only on the next start.
	var kept: Dictionary = _add(items, "fünfte", "S", 1)["dropped"]
	t.equal(items.size(), 1, "Auch nach dem Laden gilt die Grenze")
	t.equal(str(items[0].get("text", "")), "fünfte", "…und das Neueste gewinnt")
	t.check(str(kept.get("text", "")) == "zweite", "…und der Verlust ist benannt")
	t.suite_done()


# --- Delivery ----------------------------------------------------------------

func _delivery() -> void:
	t.suite("Vorschlags-Warteschlange — Zustellung")
	var api: Node = tree.root.get_node_or_null("/root/Api")
	var game: Node = tree.root.get_node_or_null("/root/Game")
	if api == null or game == null:
		t.fail("Die Autoloads Api und Game fehlen")
		t.suite_done()
		return

	var sent_events: Array = []
	var failed_events: Array = []
	var pending_events: Array = []
	var on_sent := func(id: int, cluster: int) -> void: sent_events.append([id, cluster])
	var on_failed := func(reason: String) -> void: failed_events.append(reason)
	var on_pending := func(count: int) -> void: pending_events.append(count)
	api.suggestion_sent.connect(on_sent)
	api.suggestion_failed.connect(on_failed)
	api.pending_changed.connect(on_pending)
	api._queue.clear()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(QueueClass.PATH))

	# 1. A server address is configured but nothing is listening. This is the
	#    case in which the old code dropped the text on the floor.
	game.set_server_url("http://127.0.0.1:%d" % _closed_port())
	var view: Dictionary = await api.submit_suggestion("Boss mit zwei Leben", "Test")
	t.check(view.is_empty(), "Ein unerreichbarer Server liefert keine Ansicht zurück")
	t.equal(api.pending_count(), 1, "Der Vorschlag bleibt trotzdem in der Warteschlange")
	t.equal(api.pending_hint(), "1 Vorschlag wartet auf Netz", "Der Spieler sieht, dass es wartet")
	t.equal(pending_events.size(), 1, "Der Wartestand wird genau einmal gemeldet")
	t.check(failed_events.size() == 1 and "saved locally" in str(failed_events[0]),
		"Der Spieler wird gewarnt, statt eine Löschung zu melden")
	t.equal(sent_events.size(), 0, "Ohne Server wird kein Erfolg gemeldet")
	var key := str(api._queue[0].get("clientKey", ""))

	# It was on the disk before the attempt, not after: an app kill in between
	# costs a retry, not the idea.
	var stored: Variant = JSON.parse_string(FileAccess.get_file_as_string(str(QueueClass.PATH)))
	var stored_items: Variant = (stored as Dictionary).get("items", []) if stored is Dictionary else []
	t.equal((stored_items as Array).size(), 1, "Die Idee stand auf der Platte, als der Versuch scheiterte")
	t.equal(str(((stored_items as Array)[0] as Dictionary).get("clientKey", "")), key, "…mit demselben clientKey")

	# 2. The network comes back. `wake()` is the path the app-resume
	#    notification takes — no restart involved.
	var server := FakeServer.new()
	tree.root.add_child(server)
	game.set_server_url("http://127.0.0.1:%d" % server.port)
	api.wake()
	var delivered := await _wait_until(func() -> bool: return api.pending_count() == 0, 8.0)
	t.check(delivered, "Nach dem Aufwachen ist die Warteschlange leer")
	t.equal(api.pending_hint(), "", "Ohne Warteschlange verschwindet die Anzeige wieder")
	t.check(server.has_path("/api/health"), "Vor dem Senden wird das Netz geprüft")
	var posts := server.with_path("/api/suggestions")
	t.equal(posts.size(), 1, "Genau ein Vorschlag kam an")
	if posts.size() == 1:
		var body: Dictionary = posts[0]
		t.equal(str(body.get("clientKey", "")), key, "Mit demselben clientKey wie in der Offline-Zeit")
		t.equal(str(body.get("text", "")), "Boss mit zwei Leben", "Und mit dem Text des Spielers")
		t.equal(body.size(), 4, "Der Body hält sich an den Vertrag")
	t.equal(sent_events.size(), 1, "suggestion_sent feuert genau einmal")
	t.equal(sent_events[0][0], 7, "…mit der Id aus der Antwort")

	api.suggestion_sent.disconnect(on_sent)
	api.suggestion_failed.disconnect(on_failed)
	api.pending_changed.disconnect(on_pending)
	server.queue_free()
	game.set_server_url("")
	api._queue.clear()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(QueueClass.PATH))
	t.suite_done()


# --- Helpers ----------------------------------------------------------------

## A queue of its own, on a file nobody else uses.
func _file() -> Array[Dictionary]:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))
	return []


## Adds a suggestion and writes at once — the same order as the autoload:
## first take, then the disk. Returns `{"item": …, "dropped": …}`.
func _add(items: Array[Dictionary], text: String, author: String, limit: int = QueueClass.MAX_ITEMS) -> Dictionary:
	var dropped := QueueClass.push(items, QueueClass.make_item(text, author), limit)
	QueueClass.persist(TEST_PATH, items)
	return {"item": _last(items), "dropped": dropped}


## The last item, i.e. the one that was just added.
func _last(items: Array[Dictionary]) -> Dictionary:
	if items.is_empty():
		return {}
	return (items[items.size() - 1] as Dictionary).duplicate()


## Waits for a condition while yielding frames, so the transport gets to run.
func _wait_until(done: Callable, seconds: float) -> bool:
	var waited := 0.0
	while waited < seconds:
		if done.call():
			return true
		await tree.create_timer(0.05).timeout
		waited += 0.05
	return bool(done.call())


## A port nothing listens on: bound for a moment to learn a free number, then
## released. Better than a fixed one, because agents run in parallel.
func _closed_port() -> int:
	var probe := TCPServer.new()
	if probe.listen(0, "127.0.0.1") != OK:
		return 1
	var port := probe.get_local_port()
	probe.stop()
	return port


## The smallest possible backend: answers every request with 200 and remembers
## what it was asked. Enough to prove that a retry arrives with the same key.
class FakeServer extends Node:
	var port: int = 0
	var seen: Array = []
	var reply := {"id": 7, "clusterSize": 2}

	var _tcp := TCPServer.new()
	var _conn: StreamPeerTCP = null
	var _buffer := ""

	func _init() -> void:
		if _tcp.listen(0, "127.0.0.1") == OK:
			port = _tcp.get_local_port()

	## The bodies of all requests that went to `path`.
	func with_path(path: String) -> Array:
		var out: Array = []
		for entry in seen:
			var request: Dictionary = entry
			if str(request.get("path", "")) == path:
				out.append(request.get("body", {}))
		return out

	func has_path(path: String) -> bool:
		return not with_path(path).is_empty()

	func _process(_delta: float) -> void:
		if _conn == null:
			_conn = _tcp.take_connection()
			_buffer = ""
		if _conn == null or _conn.get_available_bytes() <= 0:
			return
		var chunk: Array = _conn.get_data(_conn.get_available_bytes())
		_buffer += (chunk[1] as PackedByteArray).get_string_from_utf8()
		var split := _buffer.find("\r\n\r\n")
		if split < 0:
			return
		var expected := 0
		for line in _buffer.substr(0, split).split("\r\n"):
			if line.begins_with("Content-Length:"):
				expected = int(line.get_slice(":", 1).strip_edges())
		var body := _buffer.substr(split + 4)
		if body.length() < expected:
			return
		var request_line := _buffer.substr(0, split).split(" ")
		seen.append({
			"path": str(request_line[1]) if request_line.size() > 1 else "",
			"body": JSON.parse_string(body),
		})
		var payload := JSON.stringify(reply)
		_conn.put_data(("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % payload.length()).to_utf8_buffer())
		_conn.put_data(payload.to_utf8_buffer())
		_conn = null


# --- Legal & Reporting -------------------------------------------------------

## The reporting and consent paths Google Play requires for user-generated
## content. Pure logic, so testable without a window — and the module is
## renderer-free for exactly that reason.
func _legal() -> void:
	t.suite("Rechtliches & Melden")

	# The reasons are a mandatory field of the platform: the player must be
	# able to say *what* is wrong, and an empty reason would again just be
	# "dislike".
	t.check(LegalClass.REASONS.size() >= 3, "Es gibt mehrere Meldegruende zur Auswahl")
	var reasons_filled := true
	for reason in LegalClass.REASONS:
		reasons_filled = reasons_filled and not str(reason).strip_edges().is_empty()
	t.check(reasons_filled, "Kein Meldegrund ist leer")

	# `is_configured` and `missing` must agree. They check in different
	# places whether the addresses are still placeholders — if one drifts,
	# the dialog would either send a made-up address or refuse a real one.
	t.equal(not LegalClass.is_configured(), not LegalClass.missing().is_empty(),
		"is_configured und missing urteilen gleich")
	if not LegalClass.is_configured():
		t.check(LegalClass.missing().has("MODERATION_MAIL"),
			"Die fehlende Meldeadresse wird auch beim Namen genannt")

	# The quote is what makes the report readable in the mailbox — so it must
	# stay line-break-free and must not land in the subject untruncated.
	var flat := LegalClass.quote("erste Zeile\r\nzweite Zeile")
	t.check(not flat.contains("\n") and not flat.contains("\r"),
		"Ein Zitat bricht keine Zeile um")
	var long_text := "x".repeat(LegalClass.MAX_QUOTE * 2)
	var quoted := LegalClass.quote(long_text)
	t.check(quoted.length() <= LegalClass.MAX_QUOTE + 1,
		"Ein Zitat bleibt kuerzer als %d Zeichen" % LegalClass.MAX_QUOTE)
	t.equal(LegalClass.quote("  rand  "), "rand", "Rand Leerzeichen fallen weg")

	# Subject and body must carry the number, otherwise the mailbox cannot
	# tell what was reported.
	t.check(str(LegalClass.report_subject(7)).contains("7"),
		"Der Betreff nennt die Nummer des Vorschlags")
	var body := LegalClass.report_body(7, "Beleidigung", str(LegalClass.REASONS[0]), "  ")
	t.check(body.contains("7"), "Der Rumpf nennt die Nummer")
	t.check(body.contains(str(LegalClass.REASONS[0])), "Und den gewaehlten Grund")
	t.check(not body.contains("Ergänzung"),
		"Eine leere Ergaenzung landet nicht im Rumpf")
	t.check(LegalClass.report_body(7, "x", "", "Bitte pruefen").contains("Ergänzung"),
		"Eine gefuellte Ergaenzung landet darin")
	t.check(LegalClass.report_body(7, "Beleidigung", "", "n").contains(
			str(LegalClass.REASONS[LegalClass.REASONS.size() - 1])),
		"Ohne gewaehlten Grund greift der letzte, statt ein leerer zu bleiben")

	# `mailto:` breaks on line breaks and non-ASCII, so everything is encoded.
	# Without that, a report with umlauts would arrive as a subject without
	# text.
	var mailto := str(LegalClass.report_mailto(7, "Beleidigung für alle", "Grund", "Notiz"))
	t.check(mailto.begins_with("mailto:"), "Die Meldung ist eine mailto-Adresse")
	t.check(not mailto.contains(" "), "Kein Leerzeichen bricht die URL")
	t.check(mailto.contains("subject=") and mailto.contains("body="),
		"Betreff und Text stehen in der Adresse")
	# An umlaut must be percent-encoded. If it broke the `mailto:` address,
	# some devices would receive only the subject without text — the report
	# would be empty with no error anywhere.
	t.check(not mailto.contains("ü"), "Der Umlaut ist prozentkodiert")
	t.equal(LegalClass.report_message(7, "Beleidigung", "Grund", "n"),
		LegalClass.report_body(7, "Beleidigung", "Grund", "n"),
		"Zwischenablage und Mail tragen denselben Text")
	t.suite_done()


# --- Server address ---------------------------------------------------------

## The dialog through which the backend address is entered. It used to live fixed
## in the arena game's menu, so it was unreachable from every other screen: an
## idea submitted from the main screen without an address sat in `user://` looking
## saved and never arrived. This suite secures both halves — that the address is
## reachable from everywhere, and that it wakes a waiting queue immediately.
func _server_address() -> void:
	t.suite("Server-Adresse")

	# Without an address the button says so. A button showing "Server:
	# offline" needs no further explanation — it *is* the explanation.
	t.equal(ServerDialogClass.label(), "Server: offline",
		"Ohne Adresse steht 'offline' im Knopf")

	# A waiting queue as it looks after an offline suggestion.
	var pending: Array[Dictionary] = []
	QueueClass.push(pending, {
		"text": "Der Knopf des Siedlers ist auf dem Tablet verdeckt.",
		"author": "Test",
		"createdAt": 1,
	})
	Api._queue = pending
	t.equal(Api.pending_count(), 1, "Der Vorschlag liegt in der Warteschlange")

	# The expensive case: the counter has run so far that the backoff time
	# sits at the cap. Exactly here an idea waits five minutes although the
	# player could enter the address at any time.
	Api._attempt = 8
	Api._arm(8)
	t.check(Api._timer.wait_time >= 290.0,
		"Ohne Adresse wartet die Schlange die maximale Backoff-Zeit")

	# And now the address — the moment the idea has to go out.
	ServerDialogClass.apply("http://127.0.0.1:8787")
	t.equal(Game.server_url, "http://127.0.0.1:8787", "Die Adresse ist gesetzt")
	t.check(ServerDialogClass.label().ends_with("http://127.0.0.1:8787"),
		"Der Knopf zeigt die Adresse statt 'offline'")
	t.equal(Api._attempt, 0, "Der Zaehler der Warteversuche ist zurueckgesetzt")
	t.check(Api._timer.wait_time <= 1.0,
		"Die Schlange wird sofort wieder angestoßen, nicht in fuenf Minuten")

	# Cleanup: the remaining suites and screens assume "no server".
	ServerDialogClass.apply("")
	Api._queue.clear()
	Api._attempt = 0
	Api._arm(0)
	t.equal(ServerDialogClass.label(), "Server: offline",
		"Eine leere Adresse stellt den Offline-Zustand wieder her")
	t.suite_done()
